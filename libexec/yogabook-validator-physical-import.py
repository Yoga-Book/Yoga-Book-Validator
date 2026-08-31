#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Validate and extract resumable physical observations from a report."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess
from typing import Any


REPORT_SCHEMA = "org.yogabook.validator.report/v1"
VALID_STATUSES = {"PASS", "FAIL", "SKIP"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_inventory(path: Path) -> list[tuple[str, str, str]]:
    rows = []
    with path.open(newline="", encoding="utf-8") as stream:
        for line_number, row in enumerate(csv.reader(stream, delimiter="\t"), start=1):
            if len(row) != 3 or not all(value.strip() for value in row):
                raise ValueError(f"{path.name}:{line_number}: malformed package identity")
            identity = tuple(value.strip() for value in row)
            if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", identity[0]):
                raise ValueError(f"{path.name}:{line_number}: invalid package name")
            rows.append(identity)
    names = [row[0] for row in rows]
    if len(names) != len(set(names)):
        raise ValueError(f"{path.name}: duplicate package identity")
    return sorted(rows)


def current_inventory(reference: list[tuple[str, str, str]]) -> list[tuple[str, str, str]]:
    rows = []
    for package, _version, _architecture in reference:
        completed = subprocess.run(
            ["/usr/bin/dpkg-query", "-W", "-f=${Package}\t${Version}\t${Architecture}", "--", package],
            text=True,
            capture_output=True,
        )
        if completed.returncode != 0:
            raise ValueError(f"current package inventory is missing {package}")
        values = tuple(completed.stdout.strip().split("\t"))
        if len(values) != 3:
            raise ValueError(f"current package identity is malformed for {package}")
        rows.append(values)
    return sorted(rows)


def evidence_entry(model: dict[str, Any], name: str) -> dict[str, Any]:
    for item in model.get("evidence", []):
        if isinstance(item, dict) and item.get("file") == name:
            return item
    raise ValueError(f"report does not declare required evidence {name}")


def verify_evidence(path: Path, item: dict[str, Any]) -> None:
    if not path.is_file():
        raise ValueError(f"required evidence {path.name} is missing")
    if item.get("bytes") != path.stat().st_size or item.get("sha256") != sha256(path):
        raise ValueError(f"{path.name} does not match report integrity metadata")


def parse_environment(path: Path) -> dict[str, str]:
    values = {}
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.reader(stream, delimiter="\t"):
            if len(row) >= 2 and row[0] and row[0] != "key":
                values[row[0]] = row[1]
    return values


def parse_validator_log(path: Path) -> tuple[str, bool]:
    version = ""
    finished = False
    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if line.startswith("Yoga Book Validator "):
                version = line.removeprefix("Yoga Book Validator ").strip()
            elif line.startswith("Finished: "):
                finished = bool(line.removeprefix("Finished: ").strip())
    return version, finished


def parse_physical(path: Path, expected_ids: list[str]) -> list[dict[str, str]]:
    observations = []
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames != ["check_id", "status", "note"]:
            raise ValueError("physical-results.tsv has an unsupported header")
        for line_number, row in enumerate(reader, start=2):
            check_id = (row.get("check_id") or "").strip()
            status = (row.get("status") or "").strip()
            note = (row.get("note") or "").strip()
            if check_id not in expected_ids:
                raise ValueError(f"physical-results.tsv:{line_number}: unknown check ID {check_id!r}")
            if status not in VALID_STATUSES:
                raise ValueError(f"physical-results.tsv:{line_number}: invalid status {status!r}")
            if status in {"FAIL", "SKIP"} and not note:
                raise ValueError(f"physical-results.tsv:{line_number}: {status} requires a reason")
            observations.append({"check_id": check_id, "status": status, "note": note})
    ids = [item["check_id"] for item in observations]
    if len(ids) != len(set(ids)):
        raise ValueError("physical-results.tsv contains duplicate check IDs")
    missing = [check_id for check_id in expected_ids if check_id not in ids]
    if missing:
        raise ValueError(f"physical-results.tsv is incomplete: missing {', '.join(missing)}")
    return observations


def parse_result_observations(
    path: Path, expected_ids: list[str]
) -> dict[str, tuple[str, str, str]]:
    physical = {}
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames != ["timestamp", "subsystem", "check_id", "status", "summary", "details"]:
            raise ValueError("results.tsv has an unsupported header")
        for row in reader:
            if row.get("subsystem") != "physical":
                continue
            check_id = (row.get("check_id") or "").strip()
            status = (row.get("status") or "").strip()
            if check_id not in expected_ids:
                raise ValueError(f"results.tsv contains unknown physical observation {check_id!r}")
            if status not in VALID_STATUSES:
                raise ValueError(f"results.tsv contains invalid physical status {status!r}")
            if check_id in physical:
                raise ValueError(f"results.tsv contains duplicate physical observation {check_id}")
            details = (row.get("details") or "").strip()
            observed_at = (row.get("timestamp") or "").strip()
            marker = re.search(r"(?:^|\s)provenance_observed_at=([^\s]+)\s+provenance_imported=true$", details)
            if marker:
                observed_at = marker.group(1)
                details = details[: marker.start()].rstrip()
            physical[check_id] = (status, details, observed_at)
    if set(physical) != set(expected_ids):
        missing = sorted(set(expected_ids).difference(physical))
        raise ValueError(f"results.tsv is missing physical observations: {', '.join(missing)}")
    return physical


def load_observations(
    directory: Path,
    *,
    expected_version: str,
    expected_device: str,
    expected_ids: list[str],
    matrix: Path,
    current_inventory_path: Path | None,
) -> list[dict[str, str]]:
    directory = directory.expanduser().resolve()
    model_path = directory / "report.json"
    if not model_path.is_file():
        raise ValueError("report.json is missing")
    model = json.loads(model_path.read_text(encoding="utf-8"))
    if model.get("schema") != REPORT_SCHEMA:
        raise ValueError("report schema is incompatible")
    if model.get("integrity", {}).get("status") != "PASS":
        raise ValueError("report evidence integrity did not pass")
    if model.get("acceptance", {}).get("matrix", {}).get("sha256") != sha256(matrix):
        raise ValueError("report uses a different acceptance matrix")

    results_path = directory / "results.tsv"
    inventory_path = directory / "validated-packages.tsv"
    physical_path = directory / "physical-results.tsv"
    environment_path = directory / "environment.tsv"
    log_path = directory / "validator.log"
    verify_evidence(results_path, evidence_entry(model, "results.tsv"))
    verify_evidence(inventory_path, evidence_entry(model, "validated-packages.tsv"))
    verify_evidence(physical_path, evidence_entry(model, "physical-results.tsv"))
    verify_evidence(environment_path, evidence_entry(model, "environment.tsv"))
    verify_evidence(log_path, evidence_entry(model, "validator.log"))
    source_version, source_finished = parse_validator_log(log_path)
    source_environment = parse_environment(environment_path)
    if source_version != expected_version or model.get("validator", {}).get("version") != source_version:
        raise ValueError("report was created by a different Validator release")
    if (
        source_environment.get("device") != expected_device
        or model.get("environment", {}).get("device") != source_environment.get("device")
    ):
        raise ValueError("report belongs to a different Yoga Book model")
    if not source_finished:
        raise ValueError("source report did not finish")
    report_inventory = parse_inventory(inventory_path)
    installed_inventory = (
        parse_inventory(current_inventory_path)
        if current_inventory_path is not None
        else current_inventory(report_inventory)
    )
    if report_inventory != installed_inventory:
        raise ValueError("report package inventory differs from the current runtime")

    observations = parse_physical(physical_path, expected_ids)
    raw_results = parse_result_observations(results_path, expected_ids)
    for item in observations:
        raw = raw_results.get(item["check_id"])
        if raw is None or raw[:2] != (item["status"], item["note"]):
            raise ValueError(f"physical observation {item['check_id']} disagrees with results.tsv")
        item["observed_at"] = raw[2]
    return observations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report_directory", type=Path)
    parser.add_argument("--validator-version", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--matrix", required=True, type=Path)
    parser.add_argument("--check-id", action="append", required=True, dest="check_ids")
    parser.add_argument("--package-inventory", type=Path)
    args = parser.parse_args()
    try:
        observations = load_observations(
            args.report_directory,
            expected_version=args.validator_version,
            expected_device=args.device,
            expected_ids=args.check_ids,
            matrix=args.matrix,
            current_inventory_path=args.package_inventory,
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    print(json.dumps(observations, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
