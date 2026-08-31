#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Validate and normalize privacy-safe pen-target result evidence."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import sys
from typing import Any
import unicodedata


STAGE_PLAN = (
    ("landscape-start", "right-up", "0", "upright landscape"),
    ("portrait-right", "normal", "1", "right portrait"),
    ("landscape-inverted", "bottom-up", "3", "upside-down landscape"),
    ("portrait-left", "left-up", "2", "left portrait"),
    ("landscape-return", "right-up", "0", "returned upright landscape"),
)
EXPECTED_STAGES = tuple(stage[0] for stage in STAGE_PLAN)
ALLOWED_TOOLS = {"pen", "pencil", "brush", "airbrush", "unknown"}
ALLOWED_PATHS = {"stylus-down", "stylus-pressure", "pressure-fallback"}
ALLOWED_VERIFIERS = {"gtk-stylus", "pen-source"}
ALLOWED_RESULTS = {"PASS", "TIMEOUT", "CANCELLED"}
ALLOWED_STAGE_STATUSES = {"PASS", "FAIL", "PENDING"}
CONTACT_KEYS = {"stage", "device", "source", "tool", "event_path", "verifier"}
STAGE_KEYS = {
    "check_id", "sensor_orientation", "transform", "label",
    "observed_sensor_orientation", "observed_transform", "status", "hits", "misses",
}
PAYLOAD_KEYS = {
    "schema", "result", "stylus_device", "stylus_source", "stylus_tool",
    "stylus_event_path", "stylus_verifier", "accepted_event_paths",
    "accepted_verifiers", "accepted_contacts", "rejected_events", "privacy", "stages",
}
PRIVACY_STATEMENT = (
    "Target counts and per-contact technical provenance are retained; "
    "raw pen coordinates are discarded."
)
ALLOWED_SENSOR_VALUES = {"right-up", "normal", "bottom-up", "left-up", "undefined", "unavailable"}
ALLOWED_TRANSFORM_VALUES = {"0", "1", "2", "3", "unknown"}
MAX_RESULT_BYTES = 256 * 1024
MAX_FIELD_LENGTH = 512


def require_string(value: Any, name: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > MAX_FIELD_LENGTH
        or any(unicodedata.category(character).startswith("C") for character in value)
    ):
        raise ValueError(f"{name} must be a non-empty single-line string")
    return value


def require_count(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return value


def require_optional_string(value: Any, name: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) > MAX_FIELD_LENGTH
        or any(unicodedata.category(character).startswith("C") for character in value)
    ):
        raise ValueError(f"{name} must be a bounded plain string")
    return value


def valid_contact(contact: dict[str, str]) -> bool:
    if contact["tool"] not in ALLOWED_TOOLS or contact["event_path"] not in ALLOWED_PATHS:
        return False
    if contact["verifier"] == "gtk-stylus":
        return contact["source"] in {"pen", "mouse"}
    return (
        contact["verifier"] == "pen-source"
        and "wacom" in contact["device"].casefold()
        and contact["source"] == "pen"
    )


def normalize(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ValueError("pen result must be a JSON object")
    if payload.get("schema") != "org.yogabook.validator.pen-mapping/v1":
        raise ValueError("invalid pen mapping result schema")
    if set(payload) != PAYLOAD_KEYS:
        raise ValueError("pen result has unexpected or missing top-level fields")
    result = require_string(payload.get("result"), "result")
    if result not in ALLOWED_RESULTS:
        raise ValueError("invalid pen mapping result")
    stages = payload.get("stages")
    if not isinstance(stages, list) or len(stages) != len(EXPECTED_STAGES):
        raise ValueError("invalid pen mapping stage set")

    normalized_stages = []
    for plan, stage in zip(STAGE_PLAN, stages, strict=True):
        expected, expected_sensor, expected_transform, expected_label = plan
        if not isinstance(stage, dict) or set(stage) != STAGE_KEYS or stage.get("check_id") != expected:
            raise ValueError("invalid pen mapping stage sequence")
        if (
            stage.get("sensor_orientation") != expected_sensor
            or stage.get("transform") != expected_transform
            or stage.get("label") != expected_label
        ):
            raise ValueError(f"{expected} does not match the fixed orientation plan")
        status = require_string(stage.get("status", "INVALID"), f"{expected}.status")
        if status not in ALLOWED_STAGE_STATUSES:
            raise ValueError(f"{expected}.status is invalid")
        observed_sensor = require_string(
            stage.get("observed_sensor_orientation", "unknown"), f"{expected}.sensor"
        )
        observed_transform = require_string(
            stage.get("observed_transform", "unknown"), f"{expected}.transform"
        )
        if observed_sensor not in ALLOWED_SENSOR_VALUES or observed_transform not in ALLOWED_TRANSFORM_VALUES:
            raise ValueError(f"{expected} has invalid observed orientation data")
        if status == "PASS" and (
            observed_sensor != expected_sensor or observed_transform != expected_transform
        ):
            raise ValueError(f"{expected} PASS contradicts its observed orientation")
        normalized_stages.append(
            {
                "check_id": expected,
                "status": status,
                "label": expected_label,
                "sensor": observed_sensor,
                "transform": observed_transform,
                "hits": require_count(stage.get("hits", 0), f"{expected}.hits"),
                "misses": require_count(stage.get("misses", 0), f"{expected}.misses"),
            }
        )

    def string_list(name: str) -> list[str]:
        values = payload.get(name)
        if not isinstance(values, list):
            raise ValueError(f"{name} must be a list")
        return [require_string(value, name) for value in values]

    accepted_paths = string_list("accepted_event_paths")
    accepted_verifiers = string_list("accepted_verifiers")
    if accepted_paths != sorted(set(accepted_paths)):
        raise ValueError("accepted_event_paths must be sorted and unique")
    if accepted_verifiers != sorted(set(accepted_verifiers)):
        raise ValueError("accepted_verifiers must be sorted and unique")
    contacts = payload.get("accepted_contacts")
    if not isinstance(contacts, list) or len(contacts) > 20:
        raise ValueError("accepted_contacts must be a list of at most twenty entries")
    normalized_contacts = []
    for index, contact in enumerate(contacts):
        if not isinstance(contact, dict) or set(contact) != CONTACT_KEYS:
            raise ValueError(f"accepted_contacts[{index}] has an invalid shape")
        normalized_contacts.append(
            {key: require_string(contact[key], f"accepted_contacts[{index}].{key}") for key in CONTACT_KEYS}
        )

    diagnostics = {
        name: require_optional_string(payload[name], name)
        for name in (
            "stylus_device", "stylus_source", "stylus_tool", "stylus_event_path", "stylus_verifier"
        )
    }
    if require_string(payload["privacy"], "privacy") != PRIVACY_STATEMENT:
        raise ValueError("pen result privacy declaration is invalid")

    stage_hits = {stage["check_id"]: stage["hits"] for stage in normalized_stages}
    contact_counts = Counter(contact["stage"] for contact in normalized_contacts)
    contacts_consistent = (
        set(accepted_paths) <= ALLOWED_PATHS
        and set(accepted_verifiers) <= ALLOWED_VERIFIERS
        and len(normalized_contacts) == sum(stage_hits.values()) <= 20
        and all(valid_contact(contact) for contact in normalized_contacts)
        and contact_counts == Counter(stage_hits)
        and set(accepted_paths) == {contact["event_path"] for contact in normalized_contacts}
        and set(accepted_verifiers) == {contact["verifier"] for contact in normalized_contacts}
    )
    if not contacts_consistent:
        raise ValueError("accepted contact provenance contradicts stage hit counts")

    statuses = [stage["status"] for stage in normalized_stages]
    hits = [stage["hits"] for stage in normalized_stages]
    if result == "PASS":
        if statuses != ["PASS"] * len(STAGE_PLAN) or hits != [4] * len(STAGE_PLAN):
            raise ValueError("PASS requires exactly four hits in every completed stage")
        if len(normalized_contacts) != 20:
            raise ValueError("PASS requires exactly twenty accepted contacts")
        last_contact = normalized_contacts[-1]
        expected_diagnostics = {
            "stylus_device": last_contact["device"],
            "stylus_source": last_contact["source"],
            "stylus_tool": last_contact["tool"],
            "stylus_event_path": last_contact["event_path"],
            "stylus_verifier": last_contact["verifier"],
        }
        if diagnostics != expected_diagnostics:
            raise ValueError("PASS diagnostics do not match the final accepted contact")
    else:
        failed = [index for index, status in enumerate(statuses) if status == "FAIL"]
        if len(failed) != 1:
            raise ValueError(f"{result} requires exactly one interrupted stage")
        interrupted = failed[0]
        if (
            any(status != "PASS" or hits[index] != 4 for index, status in enumerate(statuses[:interrupted]))
            or hits[interrupted] > 3
            or any(
                status != "PENDING" or hits[index] != 0 or normalized_stages[index]["misses"] != 0
                for index, status in enumerate(statuses[interrupted + 1 :], start=interrupted + 1)
            )
        ):
            raise ValueError(f"{result} has an invalid ordered stage state")
    return {
        "result": result,
        "stages": normalized_stages,
        "contact_count": len(normalized_contacts),
        "rejected_events": require_count(payload.get("rejected_events", 0), "rejected_events"),
        "accepted_paths": accepted_paths,
        "accepted_verifiers": accepted_verifiers,
        "provenance_valid": bool(normalized_contacts),
    }


def render_tsv(normalized: dict[str, Any]) -> str:
    rows = []
    result = normalized["result"]
    for stage in normalized["stages"]:
        rows.append(
            [
                "stage",
                stage["check_id"],
                stage["status"],
                stage["label"],
                stage["sensor"],
                stage["transform"],
                str(stage["hits"]),
                str(stage["misses"]),
                result,
                "-", "-", "-", "-", "-", "-", "-", "-",
            ]
        )
    rows.append(
        [
            "summary", "-", "-", "-", "-", "-", "-", "-", result,
            str(normalized["contact_count"]), "-", "-", "-",
            str(normalized["rejected_events"]),
            ",".join(normalized["accepted_paths"]),
            ",".join(normalized["accepted_verifiers"]),
            str(normalized["provenance_valid"]).lower(),
        ]
    )
    return "\n".join("\t".join(row) for row in rows) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("result", type=Path)
    args = parser.parse_args()
    try:
        if args.result.stat().st_size > MAX_RESULT_BYTES:
            raise ValueError("pen result exceeds the bounded input size")
        with args.result.open(encoding="utf-8") as stream:
            payload = json.load(stream)
        print(render_tsv(normalize(payload)), end="")
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
