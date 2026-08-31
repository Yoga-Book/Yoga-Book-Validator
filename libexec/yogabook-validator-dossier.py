#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Compose integrity-checked Validator reports into one acceptance dossier."""

from __future__ import annotations

import argparse
import csv
import fnmatch
import hashlib
import json
import os
import re
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


REPORT_SCHEMA = "org.yogabook.validator.report/v1"
VALID_STATUSES = {"PASS", "FAIL", "WARN", "SKIP", "INFO"}
RESULT_FIELDS = ("timestamp", "subsystem", "check_id", "status", "summary", "details")
OBSERVATION_FIELDS = ("source_index", "source_label", "selected", "selection_reason", *RESULT_FIELDS)
IDENTITY_FIELDS = ("device", "architecture", "operating_system")
CONCLUSIVE_STATUSES = {"PASS", "FAIL", "WARN"}
MAX_FUTURE_SKEW = timedelta(minutes=5)


def result_blocked_by(row: dict[str, str]) -> str | None:
    match = re.search(r"(?:^|\s)blocked_by=([^\s]+)", row.get("details", ""))
    return match.group(1) if match else None


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


def atomic_copy(source: Path, destination: Path) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with source.open("rb") as input_stream, os.fdopen(descriptor, "wb") as output_stream:
            for chunk in iter(lambda: input_stream.read(1024 * 1024), b""):
                output_stream.write(chunk)
            output_stream.flush()
            os.fsync(output_stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
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


def parse_package_inventory(path: Path) -> list[tuple[str, str, str]]:
    packages = []
    seen = set()
    with path.open(newline="", encoding="utf-8") as stream:
        for line_number, row in enumerate(csv.reader(stream, delimiter="\t"), start=1):
            if len(row) != 3 or not all(value.strip() for value in row):
                raise ValueError(f"{path}:{line_number}: malformed package identity")
            identity = tuple(value.strip() for value in row)
            if identity[0] in seen:
                raise ValueError(f"{path}:{line_number}: duplicate package identity {identity[0]}")
            seen.add(identity[0])
            packages.append(identity)
    return sorted(packages)


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
    for name in ("results.tsv", "validator.log", "environment.tsv", "validated-packages.tsv"):
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
    if model.get("integrity", {}).get("status") != "PASS":
        problems = model.get("integrity", {}).get("problems", [])
        detail = "; ".join(str(problem) for problem in problems) or "unknown integrity failure"
        raise ValueError(f"{directory}: source evidence integrity failed: {detail}")
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
    packages = parse_package_inventory(directory / "validated-packages.tsv")
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
        "packages": packages,
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
        if source["packages"] != sources[0]["packages"]:
            raise ValueError(f"{source['directory'].name}: incompatible validated package inventory")


def unique_values(sources: list[dict[str, Any]], field: str) -> list[str]:
    return list(dict.fromkeys(source["environment"].get(field, "unknown") for source in sources))


def render_results(rows: list[dict[str, str]]) -> str:
    lines = ["\t".join(RESULT_FIELDS)]
    for row in rows:
        values = [row[field].replace("\t", " ").replace("\r", " ").replace("\n", " ") for field in RESULT_FIELDS]
        lines.append("\t".join(values))
    return "\n".join(lines) + "\n"


def result_timestamp(row: dict[str, str]) -> datetime:
    source = row["timestamp"]
    if row.get("subsystem") == "physical":
        marker = re.search(r"(?:^|\s)provenance_observed_at=([^\s]+)", row.get("details", ""))
        if marker:
            source = marker.group(1)
    try:
        value = datetime.fromisoformat(source)
    except ValueError as exc:
        raise ValueError(f"invalid result timestamp {source!r}") from exc
    if value.tzinfo is None:
        raise ValueError(f"result timestamp lacks a timezone: {source!r}")
    return value


def load_freshness_policies(path: Path) -> dict[str, int]:
    with path.open(encoding="utf-8") as stream:
        matrix = json.load(stream)
    raw = matrix.get("freshness_policies", {})
    if not isinstance(raw, dict):
        raise ValueError("acceptance matrix freshness_policies must be an object")
    policies: dict[str, int] = {}
    for pattern, policy in raw.items():
        if (
            not isinstance(pattern, str)
            or "/" not in pattern
            or not isinstance(policy, dict)
            or set(policy) != {"max_age_hours"}
            or not isinstance(policy.get("max_age_hours"), int)
            or isinstance(policy.get("max_age_hours"), bool)
            or not 1 <= policy["max_age_hours"] <= 8760
        ):
            raise ValueError(f"invalid freshness policy for {pattern!r}")
        policies[pattern] = policy["max_age_hours"]
    return policies


def freshness_limit(check_id: str, policies: dict[str, int]) -> int | None:
    matching = [
        (sum(character not in "*?[" for character in pattern), pattern, hours)
        for pattern, hours in policies.items()
        if fnmatch.fnmatchcase(check_id, pattern)
    ]
    if not matching:
        return None
    best_specificity = max(item[0] for item in matching)
    best = [item for item in matching if item[0] == best_specificity]
    if len(best) > 1:
        raise ValueError(
            f"equally specific freshness policies match {check_id}: "
            + ", ".join(sorted(item[1] for item in best))
        )
    return best[0][2]


def resolve_observations(
    sources: list[dict[str, Any]],
    as_of: datetime,
    freshness_policies: dict[str, int],
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for source_index, source in enumerate(sources, start=1):
        for row_index, row in enumerate(source["rows"], start=1):
            timestamp = result_timestamp(row)
            if timestamp > as_of + MAX_FUTURE_SKEW:
                raise ValueError(f"result timestamp is in the future: {row['timestamp']!r}")
            record = {
                "source_index": source_index,
                "source_label": source["directory"].name,
                "row_index": row_index,
                "row": row,
            }
            grouped.setdefault((row["subsystem"], row["check_id"]), []).append(record)

    effective: list[dict[str, str]] = []
    ledger: list[dict[str, str]] = []
    for records in grouped.values():
        conclusive = [record for record in records if record["row"]["status"] in CONCLUSIVE_STATUSES]
        blocked = [record for record in records if result_blocked_by(record["row"])]
        informative = [record for record in records if record["row"]["status"] == "INFO"]
        candidates = (conclusive + blocked) or informative or records
        selected = max(
            candidates,
            key=lambda record: (
                result_timestamp(record["row"]),
                record["source_index"],
                record["row_index"],
            ),
        )
        effective_row = dict(selected["row"])
        selected_id = f"{effective_row['subsystem']}/{effective_row['check_id']}"
        max_age_hours = freshness_limit(selected_id, freshness_policies)
        stale_pass = (
            max_age_hours is not None
            and effective_row["status"] == "PASS"
            and as_of - result_timestamp(effective_row) > timedelta(hours=max_age_hours)
        )
        effective.append(effective_row)
        for record in records:
            is_selected = record is selected
            status = record["row"]["status"]
            if is_selected:
                if stale_pass:
                    reason = "latest-conclusive-stale"
                elif result_blocked_by(record["row"]):
                    reason = "latest-blocked"
                else:
                    reason = "latest-conclusive" if conclusive else "latest-available"
            elif status not in CONCLUSIVE_STATUSES and conclusive and not result_blocked_by(record["row"]):
                reason = "non-conclusive"
            else:
                reason = "superseded"
            ledger.append(
                {
                    "source_index": str(record["source_index"]),
                    "source_label": record["source_label"],
                    "selected": "yes" if is_selected else "no",
                    "selection_reason": reason,
                    **record["row"],
                }
            )
    effective.sort(key=lambda row: (result_timestamp(row), row["subsystem"], row["check_id"]))
    ledger.sort(
        key=lambda row: (
            result_timestamp(row),
            int(row["source_index"]),
            row["subsystem"],
            row["check_id"],
        )
    )
    return effective, ledger


def render_observation_ledger(rows: list[dict[str, str]]) -> str:
    lines = ["\t".join(OBSERVATION_FIELDS)]
    for row in rows:
        values = [row[field].replace("\t", " ").replace("\r", " ").replace("\n", " ") for field in OBSERVATION_FIELDS]
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
    freshness_policies = load_freshness_policies(args.matrix.resolve())
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

    started = datetime.now().astimezone()
    rows, observation_ledger = resolve_observations(sources, started, freshness_policies)
    environment = dict(sources[0]["environment"])
    environment["kernel"] = " | ".join(unique_values(sources, "kernel"))
    environment["boot_id"] = " | ".join(unique_values(sources, "boot_id"))
    environment["source_reports"] = str(len(sources))
    environment["source_boots"] = str(len(unique_values(sources, "boot_id")))
    environment["source_observations"] = str(len(observation_ledger))
    environment["effective_observations"] = str(len(rows))
    environment["superseded_observations"] = str(
        sum(row["selected"] == "no" for row in observation_ledger)
    )
    environment["expired_observations"] = str(
        sum(row["selection_reason"] == "latest-conclusive-stale" for row in observation_ledger)
    )

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
        f"Expired evidence: {environment['expired_observations']}\n\n"
        f"AUTOMATED_RESULT: {automated_result(rows)}\n"
        f"PHYSICAL_ACCEPTANCE_RESULT: {physical_result(rows)}\n"
        f"Failures: {counts['FAIL']}\n"
        f"Warnings: {counts['WARN']}\n"
        f"Finished: {finished.isoformat(timespec='seconds')}\n"
    )

    atomic_write(output / "results.tsv", render_results(rows))
    atomic_write(output / "environment.tsv", "\n".join(environment_lines) + "\n")
    atomic_copy(sources[0]["directory"] / "validated-packages.tsv", output / "validated-packages.tsv")
    atomic_write(output / "sources.tsv", "\n".join(source_lines) + "\n")
    atomic_write(output / "observations.tsv", render_observation_ledger(observation_ledger))
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
