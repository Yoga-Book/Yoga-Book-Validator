#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Build deterministic human- and machine-readable Validator reports."""

from __future__ import annotations

import argparse
import csv
import fnmatch
import hashlib
import html
import json
import os
import re
import tempfile
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any


SCHEMA = "org.yogabook.validator.report/v1"
VALID_STATUSES = {"PASS", "FAIL", "WARN", "SKIP", "INFO"}
STATUS_ORDER = {"FAIL": 0, "WARN": 1, "SKIP": 2, "PASS": 3, "INFO": 4}
ACCEPTANCE_SCHEMA = "org.yogabook.validator.acceptance/v1"
ACCEPTANCE_LAYERS = ("structural", "functional", "physical")
ACCEPTANCE_STATUS_ORDER = {
    "FAIL": 0,
    "WARN": 1,
    "UNIMPLEMENTED": 2,
    "INCOMPLETE": 3,
    "NOT_RUN": 4,
    "PASS": 5,
}

CHECK_GUIDANCE = {
    ("platform", "grub-default"): (
        "Confirm the saved GRUB entry and the next-boot default before relying on unattended recovery."
    ),
    ("gnss", "services"): (
        "Inspect yogabook-gnss.service and gpsd.socket status, then correlate their current-boot journals."
    ),
    ("gnss", "nmea-pipe"): (
        "Verify that the GNSS transport service creates its NMEA pipe with the expected ownership before gpsd starts."
    ),
    ("gnss", "transport"): (
        "Run the GNSS health command directly and inspect the transport-service journal for the first failing prerequisite."
    ),
    ("camera", "atomisp"): (
        "Check the running kernel, bound AtomISP/sensor drivers, media graph, and current-boot camera errors before changing userspace."
    ),
    ("wireless", "bluetooth-features"): (
        "Capture bounded bluetoothctl capability properties and bluetoothd status; distinguish an unavailable controller from a genuinely missing capability."
    ),
    ("wireless", "bluetooth-scan"): (
        "Inspect rfkill, bluetooth.service and btmgmt discovery output while preserving the original radio state."
    ),
    ("wireless", "bluetooth-rf"): (
        "Retry in an environment with a nearby discoverable device after controller power and discovery are confirmed."
    ),
    ("wireless", "state-restore"): (
        "Restore the original rfkill and controller power state first; treat restoration failure as higher priority than scan coverage."
    ),
}

SUBSYSTEM_GUIDANCE = {
    "audio": "Inspect ALSA/UCM, PipeWire and WirePlumber evidence in this report before changing mixer state.",
    "camera": "Correlate media topology, bound drivers and current-boot kernel messages.",
    "display": "Correlate DRM connectors, Mutter state and current-boot i915 messages.",
    "gnss": "Correlate transport, gpsd and ModemManager state from the same boot.",
    "input": "Confirm the expected physical mode before treating an absent conditional device as a defect.",
    "platform": "Confirm the running kernel and persistent boot configuration, then inspect the cited platform evidence.",
    "power": "Compare kernel power-supply values with UPower and charger telemetry from the same sample.",
    "sensors": "Compare raw IIO channels with SensorProxy state and desktop policy.",
    "wireless": "Check rfkill, controller/service state and bounded command output without retaining nearby device identities.",
}

SELECTOR_ACTIONS = (
    ("suite/stability", "Complete the three-cold-boot tracker and include its final report in the dossier."),
    ("physical/cold-boots", "Complete the three-cold-boot tracker, then record the observed cold-boot result."),
    ("physical/reboot", "Perform and observe one normal reboot, then record the result in Physical acceptance."),
    ("physical/poweroff", "Perform and observe one full shutdown, then record the result in Physical acceptance."),
    ("display/rotation-upright-return", "Run Test automatic rotation and complete all four orientations."),
    ("input/keyboard-returned", "Run Test keyboard/pen modes and complete the Halo-to-pen-to-Halo cycle."),
    ("input/halo-*", "Run Test keyboard/pen modes and complete the Halo-to-pen-to-Halo cycle."),
    ("input/pen-*", "Run Test keyboard/pen modes with the Wacom surface active."),
    ("input/touchscreen-*", "Run Test keyboard/pen modes and confirm touchscreen restoration in both modes."),
    ("audio/headset-*", "Connect a four-pole headset and run Test wired headset."),
    ("input/headset-events", "Connect a four-pole headset and complete its unplug, reinsert and button cycle."),
    ("physical/head*", "Connect a four-pole headset and record the audible or microphone observation."),
    ("physical/jack-detection", "Connect a four-pole headset and record its removal and insertion detection."),
    ("display/hdmi-link", "Connect a Micro-HDMI display and run Inspect display."),
    ("audio/hdmi-route", "Connect a Micro-HDMI display with audio capability and run Inspect display."),
    ("physical/micro-hdmi", "Connect a Micro-HDMI display and record visible video plus audible HDMI output."),
    ("usb/removable-device", "Connect a removable USB OTG device and run Inspect USB."),
    ("physical/usb-otg", "Connect a removable USB OTG device and record insertion, use and clean removal."),
    ("modem/registration", "Insert a working SIM, establish LTE service and run Validate LTE."),
    ("modem/ip-traffic", "Establish an LTE bearer with a working SIM and run Validate LTE."),
    ("physical/lte-data", "Insert a working SIM and record real LTE data transfer."),
    ("gnss/*", "Import a legally obtained BCM4752 runtime, then run GNSS outdoors with a clear sky."),
    ("physical/gnss", "After legally importing the BCM4752 runtime, record an outdoor satellite fix."),
    ("wireless/bluetooth-rf", "Place a discoverable Bluetooth peer nearby and run Test wireless."),
    ("suite/storage-write", "Insert an SD card and run Test SD writes."),
    ("suspend/*", "Run Test suspend and verify the tablet after resume."),
    ("physical/*", "Record the operator observation in the grouped Physical acceptance checklist."),
)


def atomic_write(path: Path, content: str) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        reference = path.parent / "results.tsv"
        if reference.is_file():
            os.chmod(temporary, reference.stat().st_mode & 0o666)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def file_evidence(path: Path) -> dict[str, Any]:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"file": path.name, "bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def parse_key_values(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    values: dict[str, str] = {}
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.reader(stream, delimiter="\t"):
            if len(row) >= 2 and row[0]:
                if row[0] == "key" and row[1] == "value":
                    continue
                values[row[0]] = row[1]
    return values


def parse_log(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8", errors="replace")
    patterns = {
        "version": r"^Yoga Book Validator (.+)$",
        "command": r"^Command: (.+)$",
        "started": r"^Started: (.+)$",
        "finished": r"^Finished: (.+)$",
        "automated_result": r"^AUTOMATED_RESULT: (.+)$",
        "physical_result": r"^PHYSICAL_ACCEPTANCE_RESULT: (.+)$",
    }
    result: dict[str, Any] = {}
    for key, pattern in patterns.items():
        matches = re.findall(pattern, text, flags=re.MULTILINE)
        if matches:
            result[key] = matches[-1]
    try:
        started = datetime.fromisoformat(result["started"])
        finished = datetime.fromisoformat(result["finished"])
        result["duration_seconds"] = max(0, round((finished - started).total_seconds(), 3))
    except (KeyError, ValueError):
        result["duration_seconds"] = None
    return result


def parse_results(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    required = {"timestamp", "subsystem", "check_id", "status", "summary", "details"}
    rows: list[dict[str, str]] = []
    problems: list[str] = []
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        missing = required.difference(reader.fieldnames or [])
        if missing:
            raise ValueError(f"results.tsv is missing columns: {', '.join(sorted(missing))}")
        for line_number, source in enumerate(reader, start=2):
            row = {key: (source.get(key) or "").strip() for key in required}
            if row["status"] not in VALID_STATUSES:
                problems.append(f"line {line_number}: unknown status {row['status']!r}")
                continue
            if not row["subsystem"] or not row["check_id"] or not row["summary"]:
                problems.append(f"line {line_number}: missing subsystem, check_id or summary")
                continue
            row["kind"] = "suite-rollup" if row["subsystem"] == "suite" else "check"
            rows.append(row)
    return rows, problems


def load_acceptance_matrix() -> tuple[dict[str, Any], Path]:
    configured = os.environ.get("YBV_ACCEPTANCE_MATRIX")
    candidates = [
        Path(configured) if configured else None,
        Path(__file__).resolve().parents[1] / "data" / "acceptance.json",
        Path("/usr/share/yogabook-validator/acceptance.json"),
    ]
    path = next((candidate for candidate in candidates if candidate and candidate.is_file()), None)
    if path is None:
        raise FileNotFoundError("acceptance matrix is unavailable")
    with path.open(encoding="utf-8") as stream:
        matrix = json.load(stream)
    if matrix.get("schema") != ACCEPTANCE_SCHEMA or not isinstance(matrix.get("components"), list):
        raise ValueError("acceptance matrix has an unsupported schema")
    ids = [component.get("id") for component in matrix["components"]]
    if not ids or any(not item for item in ids) or len(ids) != len(set(ids)):
        raise ValueError("acceptance matrix component IDs must be present and unique")
    for component in matrix["components"]:
        layers = component.get("layers", {})
        for layer in ACCEPTANCE_LAYERS:
            selectors = layers.get(layer)
            if not isinstance(selectors, list) or not selectors or any("/" not in item for item in selectors):
                raise ValueError(f"acceptance component {component['id']} has invalid {layer} selectors")
    declared_selectors = {
        selector
        for component in matrix["components"]
        for layer in ACCEPTANCE_LAYERS
        for selector in component["layers"][layer]
    }
    unimplemented = matrix.get("unimplemented_selectors", [])
    if not isinstance(unimplemented, list) or any(selector not in declared_selectors for selector in unimplemented):
        raise ValueError("acceptance matrix has invalid unimplemented selectors")
    return matrix, path


def build_acceptance(rows: list[dict[str, str]]) -> dict[str, Any]:
    matrix, matrix_path = load_acceptance_matrix()
    unimplemented_catalog = set(matrix.get("unimplemented_selectors", []))
    observations: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        observations[f"{row['subsystem']}/{row['check_id']}"].append(row)

    def selector_evidence(selector: str) -> dict[str, Any] | None:
        matched = []
        for check_id, check_rows in observations.items():
            if not fnmatch.fnmatchcase(check_id, selector):
                continue
            statuses = [row["status"] for row in check_rows]
            status = min(statuses, key=lambda value: STATUS_ORDER[value])
            if status == "SKIP":
                status = "INCOMPLETE"
            elif status == "INFO":
                status = "PASS"
            matched.append(
                {
                    "id": check_id,
                    "status": status,
                    "observations": len(check_rows),
                    "observed_statuses": statuses,
                }
            )
        if not matched:
            return None
        return {
            "selector": selector,
            "status": min((item["status"] for item in matched), key=lambda value: ACCEPTANCE_STATUS_ORDER[value]),
            "matches": matched,
        }

    components = []
    for source in matrix["components"]:
        layers = {}
        for layer_name in ACCEPTANCE_LAYERS:
            evidence = []
            missing = []
            unimplemented = []
            for selector in source["layers"][layer_name]:
                item = selector_evidence(selector)
                if item is None:
                    if selector in unimplemented_catalog:
                        unimplemented.append(selector)
                    else:
                        missing.append(selector)
                else:
                    evidence.append(item)
            statuses = [item["status"] for item in evidence]
            if "FAIL" in statuses:
                status = "FAIL"
            elif "WARN" in statuses:
                status = "WARN"
            elif unimplemented:
                status = "UNIMPLEMENTED"
            elif "INCOMPLETE" in statuses:
                status = "INCOMPLETE"
            elif missing:
                status = "NOT_RUN"
            else:
                status = "PASS"
            layers[layer_name] = {
                "status": status,
                "required_selectors": source["layers"][layer_name],
                "missing_selectors": missing,
                "unimplemented_selectors": unimplemented,
                "evidence": evidence,
            }
        overall = min(
            (layers[layer]["status"] for layer in ACCEPTANCE_LAYERS),
            key=lambda value: ACCEPTANCE_STATUS_ORDER[value],
        )
        components.append({"id": source["id"], "name": source["name"], "status": overall, "layers": layers})

    counts = Counter(component["status"] for component in components)
    complete = counts["PASS"]
    total = len(components)
    layer_readiness = {}
    for layer_name in ACCEPTANCE_LAYERS:
        layer_counts = Counter(component["layers"][layer_name]["status"] for component in components)
        layer_complete = layer_counts["PASS"]
        layer_readiness[layer_name] = {
            "components_complete": layer_complete,
            "components_total": total,
            "readiness_percent": round(layer_complete / total * 100, 1) if total else 0.0,
            "counts": {
                status: layer_counts[status]
                for status in ("PASS", "FAIL", "WARN", "UNIMPLEMENTED", "INCOMPLETE", "NOT_RUN")
            },
        }
    return {
        "schema": matrix["schema"],
        "matrix": file_evidence(matrix_path),
        "summary": {
            "components_total": total,
            "components_complete": complete,
            "readiness_percent": round(complete / total * 100, 1) if total else 0.0,
            "counts": {
                status: counts[status]
                for status in ("PASS", "FAIL", "WARN", "UNIMPLEMENTED", "INCOMPLETE", "NOT_RUN")
            },
            "layers": layer_readiness,
            "note": "A component is complete only when structural, functional and physical layers all pass.",
        },
        "components": components,
    }


def severity_for(row: dict[str, str]) -> str:
    if row["status"] == "WARN":
        return "medium"
    if row["check_id"].endswith("state-restore") or "restore" in row["summary"].lower():
        return "critical"
    return "high"


def guidance_for(row: dict[str, str]) -> str:
    return CHECK_GUIDANCE.get(
        (row["subsystem"], row["check_id"]),
        SUBSYSTEM_GUIDANCE.get(
            row["subsystem"],
            "Inspect the cited evidence and validator.log from this same run before changing the system.",
        ),
    )


def build_model(directory: Path) -> dict[str, Any]:
    results_path = directory / "results.tsv"
    log_path = directory / "validator.log"
    if not results_path.is_file() or not log_path.is_file():
        raise FileNotFoundError("report directory must contain results.tsv and validator.log")

    rows, data_problems = parse_results(results_path)
    log = parse_log(log_path)
    environment = parse_key_values(directory / "environment.tsv")
    checks = [row for row in rows if row["kind"] == "check"]
    rollups = [row for row in rows if row["kind"] == "suite-rollup"]
    grouped_checks: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in checks:
        grouped_checks[(row["subsystem"], row["check_id"])].append(row)
    aggregate_rank = {"FAIL": 0, "WARN": 1, "PASS": 2, "INFO": 3, "SKIP": 4}
    aggregated_checks: list[dict[str, Any]] = []
    inconsistencies = []
    for (subsystem, check_id), observations in sorted(grouped_checks.items()):
        selected = min(observations, key=lambda row: aggregate_rank[row["status"]])
        aggregate: dict[str, Any] = dict(selected)
        statuses = [row["status"] for row in observations]
        aggregate["observation_count"] = len(observations)
        aggregate["observed_statuses"] = statuses
        aggregate["observations"] = observations
        aggregated_checks.append(aggregate)
        if len(set(statuses)) > 1:
            inconsistencies.append(
                {
                    "id": f"{subsystem}/{check_id}",
                    "statuses": statuses,
                    "timestamps": [row["timestamp"] for row in observations],
                    "note": "The same check produced different outcomes during this run; inspect execution-stage evidence.",
                }
            )
    counts = Counter(row["status"] for row in aggregated_checks)
    rollup_counts = Counter(row["status"] for row in rollups)
    subsystem_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in aggregated_checks:
        subsystem_rows[row["subsystem"]].append(row)

    subsystems = []
    for name, subsystem_checks in sorted(subsystem_rows.items()):
        subsystem_counts = Counter(row["status"] for row in subsystem_checks)
        if subsystem_counts["FAIL"]:
            health = "FAIL"
        elif subsystem_counts["WARN"]:
            health = "WARN"
        elif subsystem_counts["SKIP"]:
            health = "INCOMPLETE"
        else:
            health = "PASS"
        subsystems.append({"name": name, "health": health, "counts": dict(subsystem_counts)})

    findings = []
    for row in sorted(
        (row for row in aggregated_checks if row["status"] in {"FAIL", "WARN"}),
        key=lambda item: (STATUS_ORDER[item["status"]], item["subsystem"], item["check_id"]),
    ):
        findings.append(
            {
                "id": f"{row['subsystem']}/{row['check_id']}",
                "severity": severity_for(row),
                "status": row["status"],
                "summary": row["summary"],
                "evidence": row["details"] or "No additional detail was emitted.",
                "recommended_action": guidance_for(row),
                "timestamp": row["timestamp"],
                "observation_count": row["observation_count"],
                "observed_statuses": row["observed_statuses"],
            }
        )

    total = len(aggregated_checks)
    exercised = total - counts["SKIP"]
    derived_result = "FAIL" if counts["FAIL"] else "PASS"
    if not counts["FAIL"] and counts["WARN"]:
        derived_result = "PASS_WITH_WARNINGS"
    acceptance = build_acceptance(rows)
    model = {
        "schema": SCHEMA,
        "generated_at": log.get("finished") or datetime.now().astimezone().isoformat(timespec="seconds"),
        "validator": {"version": log.get("version", "unknown")},
        "run": {
            "command": log.get("command", "unknown"),
            "started": log.get("started"),
            "finished": log.get("finished"),
            "duration_seconds": log.get("duration_seconds"),
            "automated_result": log.get("automated_result", derived_result),
            "physical_acceptance_result": log.get("physical_result", "PENDING"),
        },
        "summary": {
            "result": derived_result,
            "checks_total": total,
            "observations_total": len(checks),
            "repeated_observations": len(checks) - total,
            "checks_exercised": exercised,
            "coverage_percent": round((exercised / total * 100), 1) if total else 0.0,
            "counts": {status: counts[status] for status in ("PASS", "FAIL", "WARN", "SKIP", "INFO")},
            "suite_rollups": {
                "total": len(rollups),
                "counts": {status: rollup_counts[status] for status in ("PASS", "FAIL", "WARN", "SKIP", "INFO")},
                "note": "Suite roll-ups are excluded from check totals to avoid double-counting root findings.",
            },
        },
        "acceptance": acceptance,
        "environment": environment,
        "subsystems": subsystems,
        "findings": findings,
        "inconsistencies": inconsistencies,
        "skipped_checks": [row for row in aggregated_checks if row["status"] == "SKIP"],
        "checks": sorted(
            aggregated_checks,
            key=lambda row: (STATUS_ORDER[row["status"]], row["subsystem"], row["check_id"]),
        ),
        "results": sorted(
            rows,
            key=lambda row: (row["kind"] != "check", STATUS_ORDER[row["status"]], row["subsystem"], row["check_id"]),
        ),
        "data_quality": {
            "valid_rows": len(rows),
            "problems": data_problems,
            "repeated_check_observations": len(checks) - total,
            "inconsistent_checks": len(inconsistencies),
        },
        "evidence": [
            file_evidence(path)
            for name in (
                "results.tsv",
                "validator.log",
                "environment.tsv",
                "state-before.tsv",
                "state-after.tsv",
                "state-diff.txt",
                "sources.tsv",
            )
            if (path := directory / name).is_file()
        ],
    }
    return model


def markdown_escape(value: Any) -> str:
    rendered = str(value if value is not None else "").replace("\n", " ")
    for character in ("\\", "`", "*", "_", "[", "]", "|", "<", ">"):
        rendered = rendered.replace(character, f"\\{character}")
    return rendered


def acceptance_layer_blockers(layer: dict[str, Any]) -> list[str]:
    details = list(layer["missing_selectors"])
    details.extend(f"unimplemented: {selector}" for selector in layer["unimplemented_selectors"])
    details.extend(
        f"{item['selector']}={item['status']}"
        for item in layer["evidence"]
        if item["status"] != "PASS"
    )
    return details


def acceptance_selector_action(blocker: str) -> str:
    selector = blocker.removeprefix("unimplemented: ").split("=", 1)[0]
    for pattern, action in SELECTOR_ACTIONS:
        if fnmatch.fnmatchcase(selector, pattern):
            return action
    return "Run the Validator workflow that emits this selector and inspect its detailed report."


def render_markdown(model: dict[str, Any]) -> str:
    run = model["run"]
    summary = model["summary"]
    counts = summary["counts"]
    acceptance = model["acceptance"]
    readiness = acceptance["summary"]
    lines = [
        "# Yoga Book Validator diagnostic report",
        "",
        f"**Result:** {summary['result']}  ",
        f"**Command:** `{markdown_escape(run['command'])}`  ",
        f"**Started:** {markdown_escape(run['started'])}  ",
        f"**Duration:** {markdown_escape(run['duration_seconds'])} seconds  ",
        f"**Physical acceptance:** {markdown_escape(run['physical_acceptance_result'])}",
        "",
        "## Executive summary",
        "",
        f"{summary['checks_total']} unique checks across {summary['observations_total']} observations: **{counts['PASS']} passed**, "
        f"**{counts['FAIL']} failed**, **{counts['WARN']} warnings**, "
        f"**{counts['SKIP']} skipped**. Coverage: **{summary['coverage_percent']}%**.",
        "Suite roll-up rows are not counted twice in these totals.",
        "",
        "## Device acceptance readiness",
        "",
        f"**{readiness['components_complete']} of {readiness['components_total']} components complete "
        f"({readiness['readiness_percent']}%).** Structural, functional and physical layers must all pass.",
        "Layer readiness: "
        + ", ".join(
            f"**{layer.title()} {readiness['layers'][layer]['components_complete']}/"
            f"{readiness['layers'][layer]['components_total']} "
            f"({readiness['layers'][layer]['readiness_percent']}%)**"
            for layer in ACCEPTANCE_LAYERS
        )
        + ".",
        f"Matrix SHA-256: `{acceptance['matrix']['sha256']}`.",
        "",
        "| Component | Overall | Structural | Functional | Physical |",
        "|---|---:|---:|---:|---:|",
    ]
    for component in acceptance["components"]:
        layers = component["layers"]
        lines.append(
            f"| {markdown_escape(component['name'])} | {component['status']} | "
            f"{layers['structural']['status']} | {layers['functional']['status']} | {layers['physical']['status']} |"
        )
    lines.extend([
        "",
        "### Acceptance blockers",
        "",
    ])
    for component in acceptance["components"]:
        if component["status"] == "PASS":
            continue
        blockers = []
        for layer_name in ACCEPTANCE_LAYERS:
            layer = component["layers"][layer_name]
            if layer["status"] == "PASS":
                continue
            details = acceptance_layer_blockers(layer)
            blockers.append(f"{layer_name} {layer['status']}: {', '.join(details) or 'review evidence'}")
        lines.append(f"- **{markdown_escape(component['name'])}** — {markdown_escape('; '.join(blockers))}")
        actionable = [detail for layer in component["layers"].values() for detail in acceptance_layer_blockers(layer)]
        for detail in actionable:
            lines.append(
                f"  - `{markdown_escape(detail)}` — {markdown_escape(acceptance_selector_action(detail))}"
            )
    lines.extend([
        "",
        "## Priority findings",
        "",
    ])
    if not model["findings"]:
        lines.extend(["No failed checks or warnings were recorded.", ""])
    for finding in model["findings"]:
        lines.extend(
            [
                f"### {finding['severity'].upper()} · `{finding['id']}`",
                "",
                f"**{markdown_escape(finding['summary'])}**",
                "",
                f"Evidence: {markdown_escape(finding['evidence'])}",
                "",
                f"Recommended next step: {markdown_escape(finding['recommended_action'])}",
                "",
            ]
        )
    lines.extend(["## Subsystem health", "", "| Subsystem | Health | Pass | Fail | Warn | Skip |", "|---|---:|---:|---:|---:|---:|"])
    for subsystem in model["subsystems"]:
        c = subsystem["counts"]
        lines.append(
            f"| {markdown_escape(subsystem['name'])} | {subsystem['health']} | "
            f"{c.get('PASS', 0)} | {c.get('FAIL', 0)} | {c.get('WARN', 0)} | {c.get('SKIP', 0)} |"
        )
    lines.extend(["", "## Incomplete coverage", ""])
    if not model["skipped_checks"]:
        lines.append("No checks were skipped.")
    else:
        for row in model["skipped_checks"]:
            lines.append(f"- `{row['subsystem']}/{row['check_id']}` — {markdown_escape(row['summary'])}")
    lines.extend(["", "## Complete check results", "", "| Status | Check | Observations | Summary | Evidence |", "|---|---|---:|---|---|"])
    for row in model["checks"]:
        lines.append(
            f"| {row['status']} | `{row['subsystem']}/{row['check_id']}` | "
            f"{row['observation_count']} | {markdown_escape(row['summary'])} | {markdown_escape(row['details'])} |"
        )
    lines.extend(["", "## Evidence integrity", ""])
    for evidence in model["evidence"]:
        lines.append(f"- `{evidence['file']}` — {evidence['bytes']} bytes — SHA-256 `{evidence['sha256']}`")
    lines.extend(["", f"Schema: `{model['schema']}`", ""])
    return "\n".join(lines)


def render_html(model: dict[str, Any]) -> str:
    summary = model["summary"]
    counts = summary["counts"]
    acceptance = model["acceptance"]
    readiness = acceptance["summary"]
    layer_metrics = "".join(
        f"<div class='metric'><b>{readiness['layers'][layer]['components_complete']}/"
        f"{readiness['layers'][layer]['components_total']}</b>{html.escape(layer.title())} ready</div>"
        for layer in ACCEPTANCE_LAYERS
    )
    status_class = "fail" if counts["FAIL"] else ("warn" if counts["WARN"] else "pass")
    finding_cards = []
    for finding in model["findings"]:
        finding_cards.append(
            f"<article class='finding {html.escape(finding['severity'])}'>"
            f"<div class='finding-head'><span class='badge {html.escape(finding['status'].lower())}'>{html.escape(finding['status'])}</span>"
            f"<code>{html.escape(finding['id'])}</code><strong>{html.escape(finding['severity'].upper())}</strong></div>"
            f"<h3>{html.escape(finding['summary'])}</h3>"
            f"<p><b>Evidence:</b> {html.escape(finding['evidence'])}</p>"
            f"<p><b>Recommended next step:</b> {html.escape(finding['recommended_action'])}</p></article>"
        )
    if not finding_cards:
        finding_cards.append("<p class='empty'>No failed checks or warnings were recorded.</p>")
    subsystem_rows = "".join(
        f"<tr><td>{html.escape(item['name'])}</td><td><span class='badge {item['health'].lower()}'>{item['health']}</span></td>"
        f"<td>{item['counts'].get('PASS', 0)}</td><td>{item['counts'].get('FAIL', 0)}</td>"
        f"<td>{item['counts'].get('WARN', 0)}</td><td>{item['counts'].get('SKIP', 0)}</td></tr>"
        for item in model["subsystems"]
    )
    acceptance_rows = "".join(
        f"<tr><td>{html.escape(item['name'])}</td>"
        f"<td><span class='badge {item['status'].lower().replace('_', '-')}'>{html.escape(item['status'])}</span></td>"
        + "".join(
            f"<td><span class='badge {item['layers'][layer]['status'].lower().replace('_', '-')}'>{html.escape(item['layers'][layer]['status'])}</span>"
            f"<small>{html.escape(', '.join(acceptance_layer_blockers(item['layers'][layer])))}</small></td>"
            for layer in ACCEPTANCE_LAYERS
        )
        + "</tr>"
        for item in acceptance["components"]
    )
    acceptance_blockers = []
    for component in acceptance["components"]:
        if component["status"] == "PASS":
            continue
        layer_items = []
        for layer_name in ACCEPTANCE_LAYERS:
            layer = component["layers"][layer_name]
            if layer["status"] == "PASS":
                continue
            details = acceptance_layer_blockers(layer)
            detail_items = "".join(
                f"<li><code>{html.escape(detail)}</code> — "
                f"{html.escape(acceptance_selector_action(detail))}</li>"
                for detail in details
            ) or "<li>Review the detailed evidence for this layer.</li>"
            layer_items.append(
                f"<li><b>{html.escape(layer_name.title())} {html.escape(layer['status'])}</b>"
                f"<ul>{detail_items}</ul></li>"
            )
        acceptance_blockers.append(
            f"<li><strong>{html.escape(component['name'])}</strong><ul>{''.join(layer_items)}</ul></li>"
        )
    result_rows = "".join(
        f"<tr><td><span class='badge {row['status'].lower()}'>{row['status']}</span></td>"
        f"<td><code>{html.escape(row['subsystem'])}/{html.escape(row['check_id'])}</code></td>"
        f"<td>{row['observation_count']}</td><td>{html.escape(row['summary'])}</td><td>{html.escape(row['details'])}</td></tr>"
        for row in model["checks"]
    )
    environment = "".join(
        f"<dt>{html.escape(key.replace('_', ' ').title())}</dt><dd>{html.escape(value)}</dd>"
        for key, value in sorted(model["environment"].items())
    ) or "<dt>Environment</dt><dd>Not recorded by this Validator version</dd>"
    evidence = "".join(
        f"<li><code>{html.escape(item['file'])}</code> · {item['bytes']} bytes · SHA-256 <code>{item['sha256']}</code></li>"
        for item in model["evidence"]
    )
    return f"""<!doctype html>
<html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Yoga Book Validator report</title><style>
:root{{--bg:#f5f6f8;--surface:#fff;--text:#202124;--muted:#68707a;--line:#dfe3e8;--pass:#16794b;--fail:#b42318;--warn:#a15c00;--info:#52606d}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,sans-serif}}
main{{max-width:1180px;margin:auto;padding:32px 20px 64px}}h1{{margin:.2rem 0}}h2{{margin-top:2rem}}code{{overflow-wrap:anywhere}}
.muted{{color:var(--muted)}}.hero,.panel,.finding{{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:20px;box-shadow:0 2px 8px #0000000a}}
.hero{{border-left:7px solid var(--{status_class})}}.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px;margin:20px 0}}
.metric{{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:16px}}.metric b{{display:block;font-size:1.8rem}}
.findings{{display:grid;gap:14px}}.finding{{border-left:5px solid var(--fail)}}.finding.medium{{border-left-color:var(--warn)}}
.finding.high,.finding.critical{{background:#fffafa}}.finding.medium{{border-left-color:var(--warn);background:#fffdf8}}
.finding-head{{display:flex;gap:10px;align-items:center}}.finding-head strong{{margin-left:auto;color:var(--fail)}}.finding.medium .finding-head strong{{color:var(--warn)}}
.badge{{display:inline-block;padding:2px 8px;border-radius:999px;font-size:.78rem;font-weight:750}}.badge.pass{{color:var(--pass);background:#e8f5ee}}
.badge.fail{{color:var(--fail);background:#fff0ee}}.badge.warn{{color:var(--warn);background:#fff4df}}.badge.skip,.badge.unimplemented,.badge.incomplete,.badge.not-run,.badge.info{{color:var(--info);background:#edf1f4}}
.table-wrap{{overflow:auto}}table{{border-collapse:collapse;width:100%}}th,td{{padding:10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}}th{{position:sticky;top:0;background:var(--surface)}}
td small{{display:block;color:var(--muted);margin-top:4px;overflow-wrap:anywhere}}dl{{display:grid;grid-template-columns:max-content 1fr;gap:7px 18px}}dt{{font-weight:700}}dd{{margin:0}}details{{margin-top:20px}}@media(max-width:620px){{main{{padding:18px 10px}}dl{{grid-template-columns:1fr}}}}
</style></head><body><main>
<section class='hero'><p class='muted'>Yoga Book Validator {html.escape(model['validator']['version'])}</p><h1>Diagnostic report</h1>
<p><b>{html.escape(summary['result'])}</b> · {html.escape(str(model['run']['command']))} · {html.escape(str(model['run']['started']))}</p>
<p class='muted'>Independent check totals exclude suite roll-ups. Repeated observations remain available for consistency analysis.</p></section>
<section class='cards'><div class='metric'><b>{counts['PASS']}</b>Passed</div><div class='metric'><b>{counts['FAIL']}</b>Failed</div>
<div class='metric'><b>{counts['WARN']}</b>Warnings</div><div class='metric'><b>{counts['SKIP']}</b>Skipped</div><div class='metric'><b>{summary['coverage_percent']}%</b>Check coverage</div>
<div class='metric'><b>{readiness['components_complete']}/{readiness['components_total']}</b>Components accepted</div>{layer_metrics}</section>
<h2>Device acceptance readiness · {readiness['readiness_percent']}%</h2><p class='muted'>A component is complete only when structural, functional and physical evidence all pass. Matrix SHA-256: <code>{html.escape(acceptance['matrix']['sha256'])}</code>.</p>
<section class='panel table-wrap'><table><thead><tr><th>Component</th><th>Overall</th><th>Structural</th><th>Functional</th><th>Physical</th></tr></thead><tbody>{acceptance_rows}</tbody></table></section>
<h2>Acceptance blockers</h2><section class='panel'><ul>{''.join(acceptance_blockers)}</ul></section>
<h2>Priority findings</h2><section class='findings'>{''.join(finding_cards)}</section>
<h2>Subsystem health</h2><section class='panel table-wrap'><table><thead><tr><th>Subsystem</th><th>Health</th><th>Pass</th><th>Fail</th><th>Warn</th><th>Skip</th></tr></thead><tbody>{subsystem_rows}</tbody></table></section>
<h2>Run context</h2><section class='panel'><dl>{environment}</dl><p>Physical acceptance: <b>{html.escape(str(model['run']['physical_acceptance_result']))}</b></p></section>
<details><summary><b>Complete check results ({summary['checks_total']})</b></summary><section class='panel table-wrap'><table><thead><tr><th>Status</th><th>Check</th><th>Observations</th><th>Summary</th><th>Evidence</th></tr></thead><tbody>{result_rows}</tbody></table></section></details>
<h2>Evidence integrity</h2><section class='panel'><ul>{evidence}</ul><p class='muted'>Schema: {html.escape(model['schema'])}</p></section>
</main></body></html>"""


def generate(directory: Path) -> dict[str, Any]:
    directory = directory.resolve()
    model = build_model(directory)
    atomic_write(directory / "report.json", json.dumps(model, indent=2, ensure_ascii=False) + "\n")
    atomic_write(directory / "report.md", render_markdown(model))
    atomic_write(directory / "report.html", render_html(model))
    return model


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report_directory", type=Path)
    parser.add_argument("--print-summary", action="store_true")
    args = parser.parse_args()
    try:
        model = generate(args.report_directory)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    if args.print_summary:
        summary = model["summary"]
        counts = summary["counts"]
        print(
            f"{summary['result']}: {counts['PASS']} passed, {counts['FAIL']} failed, "
            f"{counts['WARN']} warnings, {counts['SKIP']} skipped"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
