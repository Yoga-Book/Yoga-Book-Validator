#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RENDERER = ROOT / "libexec" / "yogabook-validator-report.py"


class ReportRendererTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ybv-report-test-")
        self.report = Path(self.temporary.name)
        (self.report / "results.tsv").write_text(
            "timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n"
            "2026-08-29T10:00:00+02:00\tdisplay\tpanel\tPASS\tPanel is active\tDSI-1\n"
            "2026-08-29T10:00:00+02:00\tgnss\tservices\tPASS\tGNSS service initially active\tunit=active\n"
            "2026-08-29T10:00:01+02:00\tgnss\tservices\tFAIL\tGNSS service is inactive\tunit=failed <unsafe>\n"
            "2026-08-29T10:00:02+02:00\tplatform\tgrub-default\tWARN\tGRUB is not confirmed\t\n"
            "2026-08-29T10:00:03+02:00\tinput\tpen\tSKIP\tPen mode is inactive\t\n"
            "2026-08-29T10:00:04+02:00\tsuite\tgnss\tFAIL\tGNSS validation failed\tfailures=1\n",
            encoding="utf-8",
        )
        (self.report / "validator.log").write_text(
            "Yoga Book Validator 0.24.0\n"
            "Command: automated\n"
            "Started: 2026-08-29T10:00:00+02:00\n\n"
            "AUTOMATED_RESULT: FAIL\n"
            "PHYSICAL_ACCEPTANCE_RESULT: PENDING\n"
            "Finished: 2026-08-29T10:00:10+02:00\n",
            encoding="utf-8",
        )
        (self.report / "environment.tsv").write_text(
            "key\tvalue\ndevice\tLenovo YB1-X91L\nkernel\tLinux test\n",
            encoding="utf-8",
        )
        (self.report / "validated-packages.tsv").write_text(
            "linux-image-yogabook-test\t1.0\tamd64\n"
            "yogabook-validator\t0.62.0\tall\n",
            encoding="utf-8",
        )
        for name in ("state-before.tsv", "state-after.tsv"):
            (self.report / name).write_text(
                "schema\torg.yogabook.validator.state/v1\n",
                encoding="utf-8",
            )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_generates_deduplicated_diagnostic_formats(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(RENDERER), "--print-summary", str(self.report)],
            check=True,
            text=True,
            capture_output=True,
        )
        self.assertIn("1 passed, 1 failed, 1 warnings, 1 skipped", completed.stdout)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        self.assertEqual(model["schema"], "org.yogabook.validator.report/v1")
        self.assertEqual(model["summary"]["checks_total"], 4)
        self.assertEqual(model["summary"]["observations_total"], 5)
        self.assertEqual(model["summary"]["repeated_observations"], 1)
        self.assertEqual(model["summary"]["counts"]["FAIL"], 1)
        self.assertEqual(model["summary"]["suite_rollups"]["counts"]["FAIL"], 1)
        self.assertEqual(model["run"]["duration_seconds"], 10.0)
        self.assertEqual(model["generated_at"], "2026-08-29T10:00:10+02:00")
        self.assertEqual(model["environment"]["device"], "Lenovo YB1-X91L")
        self.assertEqual(model["package_inventory"]["captured"], 2)
        self.assertFalse(model["package_inventory"]["complete"])
        self.assertIn("alsa-ucm-conf-yogabook", model["package_inventory"]["missing"])
        self.assertIn(
            "linux-headers-<running-kernel-release>", model["package_inventory"]["missing"]
        )
        self.assertIn("yogabook-gnss.service", model["findings"][0]["recommended_action"])
        self.assertEqual(model["findings"][0]["observed_statuses"], ["PASS", "FAIL"])
        self.assertEqual(model["data_quality"]["inconsistent_checks"], 1)
        self.assertEqual(model["integrity"]["status"], "FAIL")
        self.assertFalse(model["integrity"]["package_inventory_complete"])
        self.assertIn("conflicting observations", " ".join(model["integrity"]["problems"]))
        self.assertEqual(model["acceptance"]["summary"]["evidence_integrity"], "FAIL")
        self.assertFalse(model["acceptance"]["summary"]["completion_ready"])
        self.assertEqual(model["acceptance"]["summary"]["components_total"], 24)
        self.assertEqual(model["acceptance"]["summary"]["components_complete"], 0)
        self.assertEqual(model["acceptance"]["summary"]["layers"]["structural"]["components_total"], 24)
        self.assertEqual(model["acceptance"]["summary"]["layers"]["structural"]["components_complete"], 0)
        self.assertEqual(model["acceptance"]["summary"]["layers"]["functional"]["components_complete"], 0)
        self.assertEqual(model["acceptance"]["summary"]["layers"]["physical"]["components_complete"], 0)
        self.assertEqual(model["acceptance"]["matrix"]["file"], "acceptance.json")
        self.assertEqual(len(model["acceptance"]["matrix"]["sha256"]), 64)
        execution_plan = model["acceptance"]["execution_plan"]
        self.assertEqual(execution_plan["schema"], "org.yogabook.validator.execution-plan/v1")
        self.assertEqual(execution_plan["selectors_total"], 234)
        self.assertTrue(execution_plan["mapping_complete"])
        self.assertEqual(execution_plan["unmapped_selectors"], [])
        self.assertEqual(
            len({action["id"] for action in execution_plan["actions"]}),
            execution_plan["actions_total"],
        )
        self.assertEqual([action["id"] for action in execution_plan["actions"]], ["recapture-evidence"])
        self.assertTrue(execution_plan["integrity_blocking"])
        self.assertEqual(
            execution_plan["actions"][0]["reasons"],
            sorted(set(model["integrity"]["problems"])),
        )
        build_execution_plan = runpy.run_path(str(RENDERER))["build_execution_plan"]
        selector_plan = build_execution_plan(
            model["acceptance"]["components"], {"status": "PASS", "problems": []}
        )
        physical_action = next(
            action for action in selector_plan["actions"] if action["id"] == "physical"
        )
        self.assertGreater(physical_action["components_affected"], 1)
        self.assertEqual(physical_action["command"], "yogabook-validator physical")
        hdmi_action = next(
            action for action in selector_plan["actions"] if action["id"] == "hdmi"
        )
        self.assertEqual(
            hdmi_action["selectors"],
            ["audio/hdmi-lpe", "audio/hdmi-route", "display/hdmi-link"],
        )
        self.assertEqual(hdmi_action["components"], ["micro-hdmi"])
        gnss = next(item for item in model["acceptance"]["components"] if item["id"] == "gnss")
        self.assertEqual(gnss["status"], "FAIL")
        self.assertEqual(gnss["layers"]["structural"]["status"], "FAIL")
        self.assertEqual(gnss["layers"]["functional"]["status"], "NOT_RUN")
        hdmi = next(item for item in model["acceptance"]["components"] if item["id"] == "micro-hdmi")
        self.assertEqual(hdmi["layers"]["functional"]["status"], "NOT_RUN")
        self.assertIn("display/hdmi-link", hdmi["layers"]["functional"]["missing_selectors"])
        hdmi_link = next(
            blocker for blocker in hdmi["blockers"] if blocker["selector"] == "display/hdmi-link"
        )
        self.assertEqual(hdmi_link["layer"], "functional")
        self.assertEqual(hdmi_link["status"], "NOT_RUN")
        self.assertIn("Micro-HDMI display", hdmi_link["recommended_action"])
        lte = next(item for item in model["acceptance"]["components"] if item["id"] == "lte")
        self.assertEqual(lte["layers"]["functional"]["status"], "NOT_RUN")
        self.assertIn("modem/registration", lte["layers"]["functional"]["missing_selectors"])
        headset = next(item for item in model["acceptance"]["components"] if item["id"] == "headset")
        self.assertEqual(headset["layers"]["functional"]["status"], "NOT_RUN")
        self.assertIn("audio/headset-playback", headset["layers"]["functional"]["missing_selectors"])
        self.assertEqual(
            {item["file"] for item in model["evidence"]},
            {
                "results.tsv",
                "validator.log",
                "environment.tsv",
                "validated-packages.tsv",
                "state-before.tsv",
                "state-after.tsv",
            },
        )
        self.assertTrue((self.report / "report.md").is_file())
        self.assertEqual(
            (self.report / "report.json").stat().st_mode & 0o777,
            (self.report / "results.tsv").stat().st_mode & 0o666,
        )
        rendered_html = (self.report / "report.html").read_text(encoding="utf-8")
        self.assertIn("Independent check totals exclude suite roll-ups", rendered_html)
        self.assertIn("Device acceptance readiness", rendered_html)
        self.assertIn("0/24", rendered_html)
        self.assertIn("Structural ready", rendered_html)
        self.assertIn("Functional ready", rendered_html)
        self.assertIn("Physical ready", rendered_html)
        self.assertIn("Acceptance blockers", rendered_html)
        self.assertIn("Execution plan", rendered_html)
        self.assertIn("action-recapture-evidence", rendered_html)
        self.assertNotIn("action-hdmi", rendered_html)
        self.assertIn("$ yogabook-validator passive", rendered_html)
        self.assertNotIn("<b>Selectors:</b> <code></code>", rendered_html)
        self.assertIn("Evidence integrity · FAIL", rendered_html)
        self.assertIn("Validated package inventory · 2/15", rendered_html)
        self.assertIn("yogabook-validator", rendered_html)
        self.assertIn("Unexpected:", rendered_html)
        self.assertIn("display/hdmi-link", rendered_html)
        self.assertIn("gnss/services=FAIL", rendered_html)
        self.assertIn("Connect a Micro-HDMI display and run Inspect display.", rendered_html)
        self.assertIn("Import a legally obtained BCM4752 runtime", rendered_html)
        self.assertIn("&lt;unsafe&gt;", rendered_html)
        self.assertNotIn("unit=failed <unsafe>", rendered_html)
        rendered_markdown = (self.report / "report.md").read_text(encoding="utf-8")
        self.assertNotIn("unit=failed <unsafe>", rendered_markdown)
        self.assertIn(r"unit=failed \<unsafe\>", rendered_markdown)
        self.assertIn("## Device acceptance readiness", rendered_markdown)
        self.assertIn("## Execution plan", rendered_markdown)
        self.assertIn("Command: `yogabook-validator passive`", rendered_markdown)
        self.assertNotIn("Selectors: \n", rendered_markdown)
        self.assertNotIn("No further validation action is required", rendered_markdown)
        self.assertIn("## Evidence integrity gate", rendered_markdown)
        self.assertIn("## Validated package inventory", rendered_markdown)
        self.assertIn("Missing:", rendered_markdown)
        self.assertIn("0 of 24 components complete", rendered_markdown)
        self.assertIn("Layer readiness:", rendered_markdown)
        self.assertIn("Connect a Micro-HDMI display and run Inspect display.", rendered_markdown)

    def test_rejects_incomplete_report_directory(self) -> None:
        (self.report / "validator.log").unlink()
        completed = subprocess.run(
            [sys.executable, str(RENDERER), str(self.report)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("results.tsv and validator.log", completed.stderr)

    def test_execution_plan_is_empty_when_complete_and_order_independent(self) -> None:
        build_execution_plan = runpy.run_path(str(RENDERER))["build_execution_plan"]

        def component(component_id: str, selector: str, action_id: str) -> dict:
            layers = {
                layer: {"required_selectors": [selector] if layer == "structural" else []}
                for layer in ("structural", "functional", "physical")
            }
            return {
                "id": component_id,
                "layers": layers,
                "root_blockers": [
                    {
                        "selector": selector,
                        "status": "NOT_RUN",
                        "reason": f"{selector} is missing",
                        "action_id": action_id,
                        "blocked_selectors": [],
                    }
                ],
            }

        complete = {
            "id": "complete",
            "layers": {
                layer: {"required_selectors": ["platform/kernel"] if layer == "structural" else []}
                for layer in ("structural", "functional", "physical")
            },
            "root_blockers": [],
        }
        empty = build_execution_plan([complete], {"status": "PASS", "problems": []})
        self.assertEqual(empty["actions"], [])
        self.assertEqual(empty["actions_total"], 0)
        self.assertTrue(empty["mapping_complete"])
        self.assertFalse(empty["integrity_blocking"])

        integrity_failure = {
            "status": "FAIL",
            "problems": ["run metadata is missing", "run metadata is missing", "inventory differs"],
        }
        remediation = build_execution_plan([complete], integrity_failure)
        self.assertEqual(remediation["actions_total"], 1)
        self.assertEqual(remediation["actions"][0]["id"], "recapture-evidence")
        self.assertEqual(
            remediation["actions"][0]["reasons"],
            ["inventory differs", "run metadata is missing"],
        )
        self.assertEqual(remediation["actions"][0]["components"], ["complete"])

        incomplete = [
            component("sources", "platform/apt-update", "apt"),
            component("display", "display/drm-driver", "display"),
            component("storage", "storage/root-file-io", "internal-storage"),
        ]
        forward = build_execution_plan(incomplete, integrity_failure)
        reverse = build_execution_plan(list(reversed(incomplete)), integrity_failure)
        self.assertEqual(forward, reverse)
        self.assertEqual(
            [action["id"] for action in forward["actions"]],
            ["recapture-evidence"],
        )
        trusted = build_execution_plan(incomplete, {"status": "PASS", "problems": []})
        self.assertEqual(
            [action["id"] for action in trusted["actions"]],
            ["display", "internal-storage", "apt"],
        )

    def test_acceptance_marks_stale_pass_but_preserves_stale_failure(self) -> None:
        def render(status: str, observed_at: str = "2026-01-01T00:00:00+00:00") -> dict:
            (self.report / "results.tsv").write_text(
                "timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n"
                f"{observed_at}\tphysical\tcharging\t{status}\tCharging observed\ttest\n"
                "2026-02-02T00:00:00+00:00\tvalidator\tstate-preservation\tPASS\tState preserved\ttest\n",
                encoding="utf-8",
            )
            (self.report / "validator.log").write_text(
                "Yoga Book Validator 0.62.0\nCommand: dossier\n"
                "Started: 2026-02-02T00:00:00+00:00\n\n"
                f"AUTOMATED_RESULT: {'FAIL' if status == 'FAIL' else 'PASS'}\n"
                f"PHYSICAL_ACCEPTANCE_RESULT: {'FAIL' if status == 'FAIL' else 'PASS'}\n"
                "Finished: 2026-02-02T00:00:01+00:00\n",
                encoding="utf-8",
            )
            subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
            return json.loads((self.report / "report.json").read_text(encoding="utf-8"))

        fresh_at_boundary = render("PASS", "2026-02-01T00:00:01+00:00")
        charging = next(
            item for item in fresh_at_boundary["acceptance"]["components"]
            if item["id"] == "battery-charging"
        )
        self.assertEqual(charging["layers"]["physical"]["status"], "PASS")

        stale = render("PASS", "2026-02-01T00:00:00+00:00")
        charging = next(
            item for item in stale["acceptance"]["components"] if item["id"] == "battery-charging"
        )
        self.assertEqual(charging["layers"]["physical"]["status"], "STALE")
        blocker = next(
            item for item in charging["blockers"] if item["selector"] == "physical/charging"
        )
        self.assertEqual(blocker["status"], "STALE")
        self.assertIn("Evidence expired", blocker["reason"])
        self.assertEqual(blocker["stale_matches"][0]["max_age_hours"], 24)
        self.assertFalse(stale["acceptance"]["summary"]["completion_ready"])

        failed = render("FAIL")
        charging = next(
            item for item in failed["acceptance"]["components"] if item["id"] == "battery-charging"
        )
        self.assertEqual(charging["layers"]["physical"]["status"], "FAIL")

    def test_future_imported_physical_provenance_fails_integrity(self) -> None:
        (self.report / "results.tsv").write_text(
            "timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n"
            "2026-02-02T00:00:00+00:00\tphysical\tcharging\tPASS\tCharging observed\t"
            "provenance_observed_at=2026-02-03T00:00:00+00:00 provenance_imported=true\n"
            "2026-02-02T00:00:00+00:00\tvalidator\tstate-preservation\tPASS\tState preserved\ttest\n",
            encoding="utf-8",
        )
        (self.report / "validator.log").write_text(
            "Yoga Book Validator 0.62.0\nCommand: physical\n"
            "Started: 2026-02-02T00:00:00+00:00\n\n"
            "AUTOMATED_RESULT: PASS\nPHYSICAL_ACCEPTANCE_RESULT: PASS\n"
            "Finished: 2026-02-02T00:00:01+00:00\n",
            encoding="utf-8",
        )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        self.assertEqual(model["integrity"]["status"], "FAIL")
        self.assertIn("provenance timestamp is later", " ".join(model["data_quality"]["timestamp_problems"]))

    def test_malformed_result_row_fails_integrity_instead_of_disappearing(self) -> None:
        required = [
            "alsa-ucm-conf-yogabook",
            "gir1.2-mutter-18",
            "gnome-control-center",
            "gnome-control-center-data",
            "halo-keyboard",
            "libmutter-18-0",
            "mutter-common",
            "mutter-common-bin",
            "sof-topology-yogabook",
            "yogabook-camera",
            "yogabook-gnss",
            "yogabook-sensors",
            "yogabook-validator",
            "linux-headers-release-a",
            "linux-image-release-a",
        ]
        (self.report / "validated-packages.tsv").write_text(
            "".join(
                f"{name}\t{'0.62.0-1' if name == 'yogabook-validator' else '1.0'}\tamd64\n"
                for name in required
            ),
            encoding="utf-8",
        )
        (self.report / "results.tsv").write_text(
            "timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n"
            "2026-08-29T10:00:00+02:00\tplatform\tkernel\tPASS\tKernel works\ttest\n"
            "2026-08-29T10:00:01+02:00\tvalidator\tstate-preservation\tPASS\tState preserved\ttest\n",
            encoding="utf-8",
        )
        (self.report / "validator.log").write_text(
            "Yoga Book Validator 0.62.0\nCommand: check\n"
            "Started: 2026-08-29T10:00:00+02:00\n\n"
            "AUTOMATED_RESULT: PASS\nPHYSICAL_ACCEPTANCE_RESULT: PENDING\n"
            "Finished: 2026-08-29T10:00:02+02:00\n",
            encoding="utf-8",
        )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        self.assertEqual(model["summary"]["result"], "PASS")
        self.assertEqual(model["integrity"]["status"], "PASS")

        with (self.report / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write(
                "2026-08-29T10:00:02+02:00\tplatform\thidden-failure\tBROKEN\tHidden failure\tbad row\n"
            )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        self.assertEqual(model["summary"]["result"], "FAIL")
        self.assertEqual(model["integrity"]["status"], "FAIL")
        self.assertEqual(model["integrity"]["data_rows_rejected"], 1)
        self.assertIn("malformed result row", " ".join(model["integrity"]["problems"]))

    def test_package_inventory_requires_exact_names_and_matching_kernel_release(self) -> None:
        required = [
            "alsa-ucm-conf-yogabook",
            "gir1.2-mutter-18",
            "gnome-control-center",
            "gnome-control-center-data",
            "halo-keyboard",
            "libmutter-18-0",
            "mutter-common",
            "mutter-common-bin",
            "sof-topology-yogabook",
            "yogabook-camera",
            "yogabook-gnss",
            "yogabook-sensors",
            "yogabook-validator",
        ]

        def render_inventory(names: list[str]) -> dict[str, object]:
            (self.report / "validated-packages.tsv").write_text(
                "".join(
                    f"{name}\t{'0.24.0-1' if name == 'yogabook-validator' else '1.0'}\tamd64\n"
                    for name in names
                ),
                encoding="utf-8",
            )
            subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
            return json.loads((self.report / "report.json").read_text(encoding="utf-8"))[
                "package_inventory"
            ]

        inventory = render_inventory(
            required + ["linux-headers-release-a", "linux-image-release-b"]
        )
        self.assertEqual(inventory["captured"], 15)
        self.assertFalse(inventory["complete"])
        self.assertFalse(inventory["kernel_release_consistent"])
        self.assertIn("kernel header and image package releases do not match", inventory["problems"])

        inventory = render_inventory(
            required[:-1]
            + ["unrelated-package", "linux-headers-release-a", "linux-image-release-a"]
        )
        self.assertFalse(inventory["complete"])
        self.assertIn("yogabook-validator", inventory["missing"])
        self.assertIn("unrelated-package", inventory["unexpected"])

        inventory = render_inventory(
            required + ["linux-headers-release-a", "linux-image-release-a"]
        )
        self.assertTrue(inventory["complete"])
        self.assertTrue(inventory["kernel_release_consistent"])
        self.assertEqual(inventory["missing"], [])
        self.assertEqual(inventory["unexpected"], [])

        inventory = render_inventory(
            required + ["linux-headers-release-a", "linux-image-release-a"]
        )
        self.assertTrue(inventory["validator_version_matches"])
        self.assertEqual(inventory["declared_validator_version"], "0.24.0")
        self.assertEqual(inventory["installed_validator_version"], "0.24.0-1")

        (self.report / "validated-packages.tsv").write_text(
            "".join(
                f"{name}\t{'0.23.0-1' if name == 'yogabook-validator' else '1.0'}\tamd64\n"
                for name in required + ["linux-headers-release-a", "linux-image-release-a"]
            ),
            encoding="utf-8",
        )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        self.assertFalse(model["package_inventory"]["complete"])
        self.assertFalse(model["package_inventory"]["validator_version_matches"])
        self.assertIn(
            "does not match report version",
            " ".join(model["integrity"]["problems"] + model["package_inventory"]["problems"]),
        )

    def test_marks_component_complete_only_when_all_three_layers_pass(self) -> None:
        with (self.report / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write(
                "2026-08-29T10:00:05+02:00\tinput\tplatform-buttons-capabilities\tPASS\tButtons exposed\t\n"
                "2026-08-29T10:00:05+02:00\tinput\tlid-switch-capabilities\tPASS\tLid exposed\t\n"
            )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        buttons = next(item for item in model["acceptance"]["components"] if item["id"] == "buttons-lid")
        self.assertEqual(buttons["status"], "NOT_RUN")
        self.assertEqual(buttons["layers"]["structural"]["status"], "PASS")
        self.assertEqual(model["acceptance"]["summary"]["components_complete"], 0)
        self.assertEqual(model["acceptance"]["summary"]["layers"]["structural"]["components_complete"], 1)
        self.assertEqual(model["acceptance"]["summary"]["layers"]["functional"]["components_complete"], 0)
        self.assertEqual(model["acceptance"]["summary"]["layers"]["physical"]["components_complete"], 0)

        with (self.report / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write(
                "2026-08-29T10:00:06+02:00\tinput\tpower-button-event\tPASS\tPower observed\t\n"
                "2026-08-29T10:00:06+02:00\tinput\tvolume-up-event\tPASS\tVolume up observed\t\n"
                "2026-08-29T10:00:06+02:00\tinput\tvolume-down-event\tPASS\tVolume down observed\t\n"
                "2026-08-29T10:00:06+02:00\tinput\tlid-close-event\tPASS\tLid close observed\t\n"
                "2026-08-29T10:00:06+02:00\tinput\tlid-open-event\tPASS\tLid open observed\t\n"
                "2026-08-29T10:00:06+02:00\tinput\tcontrols-release\tPASS\tGrabs released\t\n"
            )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        buttons = next(item for item in model["acceptance"]["components"] if item["id"] == "buttons-lid")
        self.assertEqual(buttons["status"], "NOT_RUN")
        self.assertEqual(buttons["layers"]["functional"]["status"], "PASS")
        self.assertEqual(model["acceptance"]["summary"]["layers"]["functional"]["components_complete"], 1)

        with (self.report / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write(
                "2026-08-29T10:00:07+02:00\tphysical\thardware-buttons\tPASS\tButtons observed\t\n"
                "2026-08-29T10:00:07+02:00\tphysical\tlid-switch\tPASS\tLid observed\t\n"
            )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        buttons = next(item for item in model["acceptance"]["components"] if item["id"] == "buttons-lid")
        self.assertEqual(buttons["status"], "PASS")
        self.assertEqual(
            {layer["status"] for layer in buttons["layers"].values()},
            {"PASS"},
        )
        self.assertEqual(model["acceptance"]["summary"]["components_complete"], 1)
        self.assertEqual(model["acceptance"]["summary"]["readiness_percent"], 4.2)
        self.assertEqual(model["acceptance"]["summary"]["layers"]["structural"]["components_complete"], 1)
        self.assertEqual(model["acceptance"]["summary"]["layers"]["functional"]["components_complete"], 1)
        self.assertEqual(model["acceptance"]["summary"]["layers"]["physical"]["components_complete"], 1)

    def test_info_only_never_satisfies_an_acceptance_selector(self) -> None:
        with (self.report / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write(
                "2026-08-29T10:00:05+02:00\tplatform\tfailed-units\tINFO\tFailed units were observed\tcount=1\n"
                "2026-08-29T10:00:05+02:00\tplatform\tkernel-errors\tPASS\tNo errors\t\n"
                "2026-08-29T10:00:05+02:00\tdiagnostic\tcontext\tINFO\tContext captured\ttest\n"
            )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        reboot = next(
            item for item in model["acceptance"]["components"] if item["id"] == "reboot-poweroff"
        )
        structural = reboot["layers"]["structural"]
        self.assertEqual(structural["status"], "INCOMPLETE")
        failed_units = next(
            item for item in structural["evidence"] if item["selector"] == "platform/failed-units"
        )
        self.assertEqual(failed_units["status"], "INCOMPLETE")
        diagnostic = next(item for item in model["subsystems"] if item["name"] == "diagnostic")
        self.assertEqual(diagnostic["health"], "INCOMPLETE")

    def test_internal_storage_requires_targeted_functional_and_physical_evidence(self) -> None:
        rows = [
            ("storage", "emmc"),
            ("storage", "emmc-transport"),
            ("storage", "emmc-health"),
            ("storage", "root-filesystem"),
            ("storage", "discard-maintenance"),
            ("storage", "root-file-io"),
            ("storage", "root-kernel-errors"),
            ("physical", "internal-storage"),
        ]
        with (self.report / "results.tsv").open("a", encoding="utf-8") as stream:
            for subsystem, check_id in rows:
                stream.write(
                    f"2026-08-29T10:00:05+02:00\t{subsystem}\t{check_id}\tPASS\t"
                    f"{check_id} passed\tfixture\n"
                )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        storage = next(
            item for item in model["acceptance"]["components"]
            if item["id"] == "internal-storage"
        )
        self.assertEqual(storage["status"], "PASS")
        self.assertEqual(
            {layer["status"] for layer in storage["layers"].values()},
            {"PASS"},
        )
        functional_selectors = {
            item["selector"] for item in storage["layers"]["functional"]["evidence"]
        }
        self.assertEqual(
            functional_selectors,
            {
                "storage/discard-maintenance",
                "storage/root-file-io",
                "storage/root-kernel-errors",
            },
        )
        self.assertNotIn("platform/kernel-errors", functional_selectors)

        with (self.report / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write(
                "2026-08-29T10:00:06+02:00\tstorage\troot-kernel-errors\tFAIL\t"
                "Root storage error\tfixture\n"
            )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        storage = next(
            item for item in model["acceptance"]["components"]
            if item["id"] == "internal-storage"
        )
        self.assertEqual(storage["layers"]["functional"]["status"], "FAIL")
        self.assertEqual(storage["status"], "FAIL")

    def test_wildcard_selector_contracts_enforce_identity_and_cardinality(self) -> None:
        base_results = (self.report / "results.tsv").read_text(encoding="utf-8")

        def selector(component_id: str, layer: str, selector_id: str, rows: list[str]) -> dict[str, object]:
            (self.report / "results.tsv").write_text(
                base_results + "".join(f"2026-08-29T10:00:05+02:00\t{row}\n" for row in rows),
                encoding="utf-8",
            )
            subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
            model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
            component = next(
                item for item in model["acceptance"]["components"] if item["id"] == component_id
            )
            return next(
                item
                for item in component["layers"][layer]["evidence"]
                if item["selector"] == selector_id
            )

        partial_layout = selector(
            "rotation-sensors",
            "functional",
            "sensors/layout-*",
            ["sensors\tlayout-als\tPASS\tALS layout is complete\t"],
        )
        self.assertEqual(partial_layout["status"], "INCOMPLETE")
        self.assertEqual(partial_layout["matched_count"], 1)
        self.assertEqual(
            partial_layout["missing_match_ids"],
            ["sensors/layout-accel_3d", "sensors/layout-hinge", "sensors/layout-sx9310"],
        )

        complete_layout = selector(
            "rotation-sensors",
            "functional",
            "sensors/layout-*",
            [
                "sensors\tlayout-als\tPASS\tALS layout is complete\t",
                "sensors\tlayout-accel_3d\tPASS\tAccelerometer layout is complete\t",
                "sensors\tlayout-hinge\tPASS\tHinge layout is complete\t",
                "sensors\tlayout-sx9310\tPASS\tProximity layout is complete\t",
            ],
        )
        self.assertEqual(complete_layout["status"], "PASS")
        self.assertEqual(complete_layout["missing_match_ids"], [])

        duplicate_accelerometers = selector(
            "rotation-sensors",
            "functional",
            "sensors/*-accelerometer",
            [
                "sensors\tiio-device0-accelerometer\tPASS\tAccelerometer works\t",
                "sensors\tiio-device0-accelerometer\tPASS\tAccelerometer works again\t",
                "sensors\tiio-device1-accelerometer\tPASS\tAccelerometer works\t",
                "sensors\tiio-device2-accelerometer\tPASS\tAccelerometer works\t",
            ],
        )
        self.assertEqual(duplicate_accelerometers["matched_count"], 3)
        self.assertEqual(duplicate_accelerometers["status"], "INCOMPLETE")

        complete_accelerometers = selector(
            "rotation-sensors",
            "functional",
            "sensors/*-accelerometer",
            [
                f"sensors\tiio-device{index}-accelerometer\tPASS\tAccelerometer works\t"
                for index in range(4)
            ],
        )
        self.assertEqual(complete_accelerometers["matched_count"], 4)
        self.assertEqual(complete_accelerometers["status"], "PASS")

        excessive_accelerometers = selector(
            "rotation-sensors",
            "functional",
            "sensors/*-accelerometer",
            [
                f"sensors\tiio-device{index}-accelerometer\tPASS\tAccelerometer works\t"
                for index in range(5)
            ],
        )
        self.assertEqual(excessive_accelerometers["status"], "INCOMPLETE")

        resources = selector(
            "thermal-resources",
            "functional",
            "resources/*-headroom",
            [
                "resources\thalo-keyboard-headroom\tPASS\tHalo headroom is safe\t",
                "resources\tyogabook-gnss-headroom\tPASS\tGNSS headroom is safe\t",
            ],
        )
        self.assertEqual(resources["status"], "INCOMPLETE")
        self.assertEqual(resources["missing_match_ids"], ["resources/yogabook-camera-headroom"])

        unexpected_root_hub = selector(
            "usb-otg",
            "structural",
            "usb/root-hub-*",
            [
                "usb\troot-hub-usb1\tPASS\tUSB 2 hub works\t",
                "usb\troot-hub-usb2\tPASS\tUSB 3 hub works\t",
                "usb\troot-hub-usb3\tPASS\tUnexpected hub works\t",
            ],
        )
        self.assertEqual(unexpected_root_hub["status"], "INCOMPLETE")
        self.assertEqual(unexpected_root_hub["unexpected_match_ids"], ["usb/root-hub-usb3"])

    def test_rejects_missing_unknown_and_impossible_selector_contracts(self) -> None:
        matrix_path = ROOT / "data" / "acceptance.json"
        original = json.loads(matrix_path.read_text(encoding="utf-8"))

        def rejected(matrix: dict[str, object], expected: str) -> None:
            candidate = self.report / "invalid-acceptance.json"
            candidate.write_text(json.dumps(matrix), encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, str(RENDERER), str(self.report)],
                text=True,
                capture_output=True,
                env={**os.environ, "YBV_ACCEPTANCE_MATRIX": str(candidate)},
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(expected, completed.stderr)

        missing = json.loads(json.dumps(original))
        del missing["selector_contracts"]["usb/root-hub-*"]
        rejected(missing, "selector contracts do not match wildcard selectors")

        unknown_key = json.loads(json.dumps(original))
        unknown_key["selector_contracts"]["usb/root-hub-*"]["minimum_match"] = 2
        rejected(unknown_key, "unknown keys: minimum_match")

        impossible = json.loads(json.dumps(original))
        impossible["selector_contracts"]["usb/root-hub-*"]["minimum_matches"] = 3
        rejected(impossible, "cannot satisfy minimum_matches")

    def test_gnss_dependency_blockers_collapse_to_the_runtime_root(self) -> None:
        blocked = ["services", "nmea-pipe", "transport", "gpsd", "sky", "fix", "service-stability"]
        with (self.report / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write(
                "2026-08-29T10:00:05+02:00\tgnss\truntime-assets\tFAIL\tRuntime missing\timport required\n"
            )
            for check_id in blocked:
                stream.write(
                    f"2026-08-29T10:00:06+02:00\tgnss\t{check_id}\tSKIP\tBlocked by runtime\tblocked_by=gnss/runtime-assets\n"
                )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        gnss = next(item for item in model["acceptance"]["components"] if item["id"] == "gnss")
        runtime = next(
            blocker for blocker in gnss["root_blockers"] if blocker["selector"] == "gnss/runtime-assets"
        )
        self.assertEqual(runtime["blocked_selectors"], [f"gnss/{check_id}" for check_id in sorted(blocked)])
        self.assertFalse(
            any(blocker["selector"] == "gnss/services" for blocker in gnss["root_blockers"])
        )
        build_execution_plan = runpy.run_path(str(RENDERER))["build_execution_plan"]
        trusted_plan = build_execution_plan(
            model["acceptance"]["components"], {"status": "PASS", "problems": []}
        )
        gnss_action = next(
            action
            for action in trusted_plan["actions"]
            if action["id"] == "gnss"
        )
        self.assertIn("gnss/runtime-assets", gnss_action["selectors"])
        self.assertEqual(
            gnss_action["blocked_selectors"],
            [f"gnss/{check_id}" for check_id in sorted(blocked)],
        )
        self.assertEqual(gnss_action["components"], ["gnss"])
        self.assertEqual(model["acceptance"]["execution_plan"]["actions"][0]["id"], "recapture-evidence")

    def test_sd_write_rollup_completes_functional_layer(self) -> None:
        with (self.report / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write(
                "2026-08-29T10:00:05+02:00\tstorage\tsd-slot\tPASS\tSD slot exposed\t\n"
                "2026-08-29T10:00:05+02:00\tstorage\tsd-card\tPASS\tSD card present\t\n"
                "2026-08-29T10:00:06+02:00\tstorage\tsd-block-read\tPASS\tSD block read passed\t\n"
                "2026-08-29T10:00:07+02:00\tsuite\tstorage-write\tPASS\tSD writes passed\t\n"
            )
        subprocess.run([sys.executable, str(RENDERER), str(self.report)], check=True)
        model = json.loads((self.report / "report.json").read_text(encoding="utf-8"))
        sd = next(item for item in model["acceptance"]["components"] if item["id"] == "sd-card")
        self.assertEqual(sd["layers"]["functional"]["status"], "PASS")


if __name__ == "__main__":
    unittest.main()
