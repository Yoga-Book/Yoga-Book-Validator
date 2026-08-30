#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Compose integrity-checked Validator reports into one acceptance dossier."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from collections import Counter
from datetime import datetime
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


REPORT_SCHEMA = "org.yogabook.validator.report/v1"
VALID_STATUSES = {"PASS", "FAIL", "WARN", "SKIP", "INFO"}
RESULT_FIELDS = ("timestamp", "subsystem", "check_id", "status", "summary", "details")
IDENTITY_FIELDS = ("device", "architecture", "operating_system")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write(path: Path, content: str) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def parse_environment(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.reader(stream, delimiter="\t"):
            if len(row) >= 2 and row[0] and row[0] != "key":
                values[row[0]] = row[1]
    return values


def parse_results(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        missing = set(RESULT_FIELDS).difference(reader.fieldnames or [])
        if missing:
            raise ValueError(f"{path}: results.tsv is missing {', '.join(sorted(missing))}")
        for line_number, source in enumerate(reader, start=2):
            row = {field: (source.get(field) or "").strip() for field in RESULT_FIELDS}
            if row["status"] not in VALID_STATUSES:
                raise ValueError(f"{path}:{line_number}: invalid status {row['status']!r}")
            if not row["subsystem"] or not row["check_id"] or not row["summary"]:
                raise ValueError(f"{path}:{line_number}: incomplete result row")
            rows.append(row)
    return rows


def evidence_map(model: dict[str, Any]) -> dict[str, dict[str, Any]]:
    evidence = model.get("evidence")
    if not isinstance(evidence, list):
        return {}
    return {
        item["file"]: item
        for item in evidence
        if isinstance(item, dict) and isinstance(item.get("file"), str)
    }


def validate_evidence(directory: Path, model: dict[str, Any]) -> None:
    declared = evidence_map(model)
    for name in ("results.tsv", "validator.log", "environment.tsv"):
        if name not in declared:
            raise ValueError(f"{directory}: required evidence {name} is missing")
    for name, item in declared.items():
        if Path(name).name != name:
            raise ValueError(f"{directory}: invalid evidence path {name!r}")
        path = directory / name
        if not path.is_file():
            raise ValueError(f"{directory}: declared evidence {name} is missing")
        if item.get("bytes") != path.stat().st_size or item.get("sha256") != sha256(path):
            raise ValueError(f"{directory}: {name} does not match report.json integrity metadata")


def load_source(directory: Path, expected_version: str, expected_matrix: str) -> dict[str, Any]:
    directory = directory.expanduser().resolve()
    model_path = directory / "report.json"
    if not model_path.is_file():
        raise ValueError(f"{directory}: report.json is missing")
    try:
        model = json.loads(model_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{directory}: report.json is invalid: {exc}") from exc
    if model.get("schema") != REPORT_SCHEMA:
        raise ValueError(f"{directory}: unsupported report schema")
    version = model.get("validator", {}).get("version")
    if version != expected_version:
        raise ValueError(
            f"{directory}: Validator version {version or 'missing'} does not match {expected_version}"
        )
    matrix_sha = model.get("acceptance", {}).get("matrix", {}).get("sha256")
    if matrix_sha != expected_matrix:
        raise ValueError(f"{directory}: acceptance matrix does not match the installed release")
    validate_evidence(directory, model)
    environment = parse_environment(directory / "environment.tsv")
    missing_identity = [field for field in IDENTITY_FIELDS if not environment.get(field)]
    if missing_identity:
        raise ValueError(f"{directory}: environment identity is missing {', '.join(missing_identity)}")
    run = model.get("run", {})
    if not run.get("command") or not run.get("finished"):
        raise ValueError(f"{directory}: run metadata is incomplete")
    return {
        "directory": directory,
        "model": model,
        "environment": environment,
        "rows": parse_results(directory / "results.tsv"),
        "report_sha256": sha256(model_path),
    }


def ensure_compatible(sources: list[dict[str, Any]]) -> None:
    baseline = sources[0]["environment"]
    for source in sources[1:]:
        differences = [
            field
            for field in IDENTITY_FIELDS
            if source["environment"].get(field) != baseline.get(field)
        ]
        if differences:
            label = source["directory"].name
            raise ValueError(f"{label}: incompatible environment fields: {', '.join(differences)}")


def unique_values(sources: list[dict[str, Any]], field: str) -> list[str]:
    return list(dict.fromkeys(source["environment"].get(field, "unknown") for source in sources))


def render_results(rows: list[dict[str, str]]) -> str:
    lines = ["\t".join(RESULT_FIELDS)]
    for row in rows:
        values = [row[field].replace("\t", " ").replace("\r", " ").replace("\n", " ") for field in RESULT_FIELDS]
        lines.append("\t".join(values))
    return "\n".join(lines) + "\n"


def physical_result(rows: list[dict[str, str]]) -> str:
    statuses = [row["status"] for row in rows if row["subsystem"] == "physical"]
    if not statuses:
        return "PENDING"
    if "FAIL" in statuses:
        return "FAIL"
    if "SKIP" in statuses:
        return "INCOMPLETE"
    return "PASS"


def automated_result(rows: list[dict[str, str]]) -> str:
    statuses = [
        row["status"]
        for row in rows
        if row["subsystem"] not in {"physical", "suite"}
    ]
    if "FAIL" in statuses:
        return "FAIL"
    if "WARN" in statuses:
        return "PASS_WITH_WARNINGS"
    return "PASS"


def compose(args: argparse.Namespace) -> Path:
    matrix_sha = sha256(args.matrix.resolve())
    source_paths = [path.expanduser().resolve() for path in args.sources]
    if len(source_paths) != len(set(source_paths)):
        raise ValueError("each source report directory may be selected only once")
    output = args.output.expanduser().resolve()
    for source in source_paths:
        if output == source or output.is_relative_to(source) or source.is_relative_to(output):
            raise ValueError("the dossier output and source report directories must not contain each other")
    sources = [load_source(path, args.validator_version, matrix_sha) for path in source_paths]
    ensure_compatible(sources)
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any(output.iterdir()):
        raise ValueError(f"{output}: output directory is not empty")
    os.chmod(output, 0o700)

    rows = [row for source in sources for row in source["rows"]]
    environment = dict(sources[0]["environment"])
    environment["kernel"] = " | ".join(unique_values(sources, "kernel"))
    environment["boot_id"] = " | ".join(unique_values(sources, "boot_id"))
    environment["source_reports"] = str(len(sources))
    environment["source_boots"] = str(len(unique_values(sources, "boot_id")))

    started = datetime.now().astimezone()
    source_started = [source["model"].get("run", {}).get("started") for source in sources]
    source_finished = [source["model"].get("run", {}).get("finished") for source in sources]
    finished = datetime.now().astimezone()
    result_rank = {"FAIL": 0, "WARN": 1, "PASS": 2, "INFO": 3, "SKIP": 4}
    independent: dict[tuple[str, str], str] = {}
    for row in rows:
        if row["subsystem"] == "suite":
            continue
        key = (row["subsystem"], row["check_id"])
        previous = independent.get(key)
        if previous is None or result_rank[row["status"]] < result_rank[previous]:
            independent[key] = row["status"]
    counts = Counter(independent.values())

    environment_lines = ["key\tvalue"] + [
        f"{key}\t{value.replace(chr(9), ' ').replace(chr(10), ' ')}"
        for key, value in environment.items()
    ]
    source_lines = [
        "index\tlabel\tcommand\tvalidator_version\tboot_id\tstarted\tfinished\tresults_sha256\treport_sha256"
    ]
    for index, source in enumerate(sources, start=1):
        model = source["model"]
        run = model["run"]
        source_lines.append(
            "\t".join(
                (
                    str(index),
                    source["directory"].name.replace("\t", " ").replace("\n", " "),
                    str(run["command"]),
                    args.validator_version,
                    source["environment"].get("boot_id", "unknown"),
                    str(run.get("started") or "unknown"),
                    str(run["finished"]),
                    sha256(source["directory"] / "results.tsv"),
                    source["report_sha256"],
                )
            )
        )
    log = (
        f"Yoga Book Validator {args.validator_version}\n"
        "Command: dossier\n"
        f"Started: {started.isoformat(timespec='seconds')}\n"
        f"Sources: {len(sources)}\n"
        f"Evidence span: {min(filter(None, source_started), default='unknown')} -> "
        f"{max(filter(None, source_finished), default='unknown')}\n\n"
        f"AUTOMATED_RESULT: {automated_result(rows)}\n"
        f"PHYSICAL_ACCEPTANCE_RESULT: {physical_result(rows)}\n"
        f"Failures: {counts['FAIL']}\n"
        f"Warnings: {counts['WARN']}\n"
        f"Finished: {finished.isoformat(timespec='seconds')}\n"
    )

    atomic_write(output / "results.tsv", render_results(rows))
    atomic_write(output / "environment.tsv", "\n".join(environment_lines) + "\n")
    atomic_write(output / "sources.tsv", "\n".join(source_lines) + "\n")
    atomic_write(output / "validator.log", log)
    subprocess.run([sys.executable, str(args.renderer), str(output)], check=True)
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validator-version", required=True)
    parser.add_argument("--matrix", required=True, type=Path)
    parser.add_argument("--renderer", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("sources", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        output = compose(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.error(str(exc))
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
