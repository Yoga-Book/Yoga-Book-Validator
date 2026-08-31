#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import copy
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "yogabook_validator_pen_result",
    ROOT / "libexec" / "yogabook-validator-pen-result.py",
)
assert SPEC and SPEC.loader
PARSER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARSER)


def valid_payload() -> dict:
    stages = []
    contacts = []
    for check_id, sensor, transform, label in PARSER.STAGE_PLAN:
        stages.append(
            {
                "check_id": check_id,
                "sensor_orientation": sensor,
                "transform": transform,
                "label": label,
                "status": "PASS",
                "observed_sensor_orientation": sensor,
                "observed_transform": transform,
                "hits": 4,
                "misses": 0,
            }
        )
        for _target in range(4):
            contacts.append(
                {
                    "stage": check_id,
                    "device": "Wayland logical pointer",
                    "source": "mouse",
                    "tool": "unknown",
                    "event_path": "stylus-down",
                    "verifier": "gtk-stylus",
                }
            )
    return {
        "schema": "org.yogabook.validator.pen-mapping/v1",
        "result": "PASS",
        "stylus_device": "Wayland logical pointer",
        "stylus_source": "mouse",
        "stylus_tool": "unknown",
        "stylus_event_path": "stylus-down",
        "stylus_verifier": "gtk-stylus",
        "stages": stages,
        "accepted_event_paths": ["stylus-down"],
        "accepted_verifiers": ["gtk-stylus"],
        "accepted_contacts": contacts,
        "rejected_events": 2,
        "privacy": PARSER.PRIVACY_STATEMENT,
    }


class PenResultTest(unittest.TestCase):
    def test_complete_per_contact_provenance_passes(self) -> None:
        normalized = PARSER.normalize(valid_payload())
        self.assertTrue(normalized["provenance_valid"])
        self.assertEqual(normalized["contact_count"], 20)
        rendered = PARSER.render_tsv(normalized)
        rows = [line.split("\t") for line in rendered.splitlines()]
        self.assertEqual(len(rows), 6)
        self.assertTrue(all(len(row) == 17 for row in rows))
        self.assertEqual(rows[-1][0], "summary")
        self.assertEqual(rows[-1][8:10], ["PASS", "20"])
        self.assertEqual(rows[-1][13:17], ["2", "stylus-down", "gtk-stylus", "true"])
        self.assertIn("\nsummary\t", rendered)

    def test_physical_pen_fallback_requires_wacom_pen_source(self) -> None:
        payload = valid_payload()
        contact = payload["accepted_contacts"][0]
        contact.update(
            device="Wacom HID 169 Pen", source="pen", tool="pen",
            event_path="pressure-fallback", verifier="pen-source"
        )
        payload["accepted_event_paths"] = sorted(
            payload["accepted_event_paths"] + ["pressure-fallback"]
        )
        payload["accepted_verifiers"].append("pen-source")
        self.assertTrue(PARSER.normalize(payload)["provenance_valid"])
        contact["device"] = "Generic pen"
        with self.assertRaises(ValueError):
            PARSER.normalize(payload)

    def test_missing_duplicate_or_wrong_stage_contacts_fail_closed(self) -> None:
        for mutate in ("missing", "duplicate", "wrong-stage"):
            with self.subTest(mutate=mutate):
                payload = valid_payload()
                if mutate == "missing":
                    payload["accepted_contacts"].pop()
                elif mutate == "duplicate":
                    payload["accepted_contacts"].append(copy.deepcopy(payload["accepted_contacts"][0]))
                else:
                    payload["accepted_contacts"][0]["stage"] = "unknown"
                if mutate == "duplicate":
                    with self.assertRaises(ValueError):
                        PARSER.normalize(payload)
                else:
                    with self.assertRaises(ValueError):
                        PARSER.normalize(payload)

    def test_disallowed_tool_path_and_mismatched_summaries_fail_closed(self) -> None:
        mutations = (
            ("tool", "eraser"),
            ("event_path", "mouse-click"),
            ("verifier", "untrusted"),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                payload = valid_payload()
                payload["accepted_contacts"][0][key] = value
                with self.assertRaises(ValueError):
                    PARSER.normalize(payload)
        payload = valid_payload()
        payload["accepted_event_paths"] = ["stylus-pressure"]
        with self.assertRaises(ValueError):
            PARSER.normalize(payload)
        payload = valid_payload()
        payload["accepted_verifiers"] = ["pen-source"]
        with self.assertRaises(ValueError):
            PARSER.normalize(payload)

    def test_timeout_requires_one_ordered_interrupted_stage(self) -> None:
        payload = valid_payload()
        payload["result"] = "TIMEOUT"
        payload["accepted_contacts"] = []
        payload["accepted_event_paths"] = []
        payload["accepted_verifiers"] = []
        for index, stage in enumerate(payload["stages"]):
            stage["status"] = "FAIL" if index == 0 else "PENDING"
            stage["hits"] = 0
            stage["misses"] = 0
        normalized = PARSER.normalize(payload)
        self.assertFalse(normalized["provenance_valid"])
        payload = valid_payload()
        payload["result"] = "TIMEOUT"
        with self.assertRaises(ValueError):
            PARSER.normalize(payload)

    def test_pass_rejects_contradictory_status_hit_distribution_and_diagnostics(self) -> None:
        payload = valid_payload()
        payload["stages"][0]["status"] = "FAIL"
        with self.assertRaises(ValueError):
            PARSER.normalize(payload)
        payload = valid_payload()
        payload["stages"][0]["hits"] = 3
        payload["stages"][1]["hits"] = 5
        with self.assertRaises(ValueError):
            PARSER.normalize(payload)
        payload = valid_payload()
        payload["stylus_tool"] = "pen"
        with self.assertRaises(ValueError):
            PARSER.normalize(payload)

    def test_malformed_schema_shape_and_counts_are_rejected(self) -> None:
        cases = []
        payload = valid_payload()
        payload["schema"] = "invalid"
        cases.append(payload)
        payload = valid_payload()
        payload["stages"].reverse()
        cases.append(payload)
        payload = valid_payload()
        payload["stages"][0]["hits"] = -1
        cases.append(payload)
        payload = valid_payload()
        payload["accepted_contacts"][0]["extra"] = "bad"
        cases.append(payload)
        payload = valid_payload()
        payload["raw_coordinates"] = [[10, 20]]
        cases.append(payload)
        payload = valid_payload()
        payload["stages"][0]["raw_coordinates"] = [[10, 20]]
        cases.append(payload)
        payload = valid_payload()
        payload["rejected_events"] = True
        cases.append(payload)
        payload = valid_payload()
        payload["result"] = "INVALID"
        cases.append(payload)
        payload = valid_payload()
        payload["stages"][0]["status"] = "UNKNOWN"
        cases.append(payload)
        payload = valid_payload()
        payload["accepted_event_paths"] *= 2
        cases.append(payload)
        payload = valid_payload()
        payload["accepted_contacts"].append(copy.deepcopy(payload["accepted_contacts"][0]))
        cases.append(payload)
        payload = valid_payload()
        payload["accepted_contacts"][0]["device"] = "x" * (PARSER.MAX_FIELD_LENGTH + 1)
        cases.append(payload)
        payload = valid_payload()
        payload["accepted_contacts"][0]["device"] = "bad\x1b[2J"
        cases.append(payload)
        for control in ("\x08", "\x7f", "\x9b", "\u200b"):
            payload = valid_payload()
            payload["accepted_contacts"][0]["device"] = f"bad{control}text"
            cases.append(payload)
        for payload in cases:
            with self.subTest(payload=payload):
                with self.assertRaises(ValueError):
                    PARSER.normalize(payload)

    def test_command_rejects_oversized_input_before_json_decode(self) -> None:
        with tempfile.NamedTemporaryFile() as stream:
            stream.write(b" " * (PARSER.MAX_RESULT_BYTES + 1))
            stream.flush()
            helper = ROOT / "libexec" / "yogabook-validator-pen-result.py"
            completed = subprocess.run(
                [sys.executable, str(helper), stream.name],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("bounded input size", completed.stderr)


if __name__ == "__main__":
    unittest.main()
