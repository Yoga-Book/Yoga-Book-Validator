#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import json
from pathlib import Path
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
        self.assertIn("yogabook-gnss.service", model["findings"][0]["recommended_action"])
        self.assertEqual(model["findings"][0]["observed_statuses"], ["PASS", "FAIL"])
        self.assertEqual(model["data_quality"]["inconsistent_checks"], 1)
        self.assertEqual(model["acceptance"]["summary"]["components_total"], 23)
        self.assertEqual(model["acceptance"]["summary"]["components_complete"], 0)
        self.assertEqual(model["acceptance"]["matrix"]["file"], "acceptance.json")
        self.assertEqual(len(model["acceptance"]["matrix"]["sha256"]), 64)
        gnss = next(item for item in model["acceptance"]["components"] if item["id"] == "gnss")
        self.assertEqual(gnss["status"], "FAIL")
        self.assertEqual(gnss["layers"]["structural"]["status"], "FAIL")
        self.assertEqual(gnss["layers"]["functional"]["status"], "NOT_RUN")
        hdmi = next(item for item in model["acceptance"]["components"] if item["id"] == "micro-hdmi")
        self.assertEqual(hdmi["layers"]["functional"]["status"], "NOT_RUN")
        self.assertIn("display/hdmi-link", hdmi["layers"]["functional"]["missing_selectors"])
        lte = next(item for item in model["acceptance"]["components"] if item["id"] == "lte")
        self.assertEqual(lte["layers"]["functional"]["status"], "NOT_RUN")
        self.assertIn("modem/registration", lte["layers"]["functional"]["missing_selectors"])
        self.assertEqual(
            {item["file"] for item in model["evidence"]},
            {"results.tsv", "validator.log", "environment.tsv", "state-before.tsv", "state-after.tsv"},
        )
        self.assertTrue((self.report / "report.md").is_file())
        self.assertEqual(
            (self.report / "report.json").stat().st_mode & 0o777,
            (self.report / "results.tsv").stat().st_mode & 0o666,
        )
        rendered_html = (self.report / "report.html").read_text(encoding="utf-8")
        self.assertIn("Independent check totals exclude suite roll-ups", rendered_html)
        self.assertIn("Device acceptance readiness", rendered_html)
        self.assertIn("0/23", rendered_html)
        self.assertIn("&lt;unsafe&gt;", rendered_html)
        self.assertNotIn("unit=failed <unsafe>", rendered_html)
        rendered_markdown = (self.report / "report.md").read_text(encoding="utf-8")
        self.assertNotIn("unit=failed <unsafe>", rendered_markdown)
        self.assertIn(r"unit=failed \<unsafe\>", rendered_markdown)
        self.assertIn("## Device acceptance readiness", rendered_markdown)
        self.assertIn("0 of 23 components complete", rendered_markdown)

    def test_rejects_incomplete_report_directory(self) -> None:
        (self.report / "validator.log").unlink()
        completed = subprocess.run(
            [sys.executable, str(RENDERER), str(self.report)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("results.tsv and validator.log", completed.stderr)

    def test_marks_component_complete_only_when_all_three_layers_pass(self) -> None:
        with (self.report / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write(
                "2026-08-29T10:00:05+02:00\tinput\tplatform-buttons-capabilities\tPASS\tButtons exposed\t\n"
                "2026-08-29T10:00:05+02:00\tinput\tlid-switch-capabilities\tPASS\tLid exposed\t\n"
                "2026-08-29T10:00:06+02:00\tphysical\thardware-buttons\tPASS\tButtons observed\t\n"
                "2026-08-29T10:00:06+02:00\tphysical\tlid-switch\tPASS\tLid observed\t\n"
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
        self.assertEqual(model["acceptance"]["summary"]["readiness_percent"], 4.3)


if __name__ == "__main__":
    unittest.main()
