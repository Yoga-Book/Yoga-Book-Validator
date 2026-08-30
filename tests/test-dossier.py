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
DOSSIER = ROOT / "libexec" / "yogabook-validator-dossier.py"
RENDERER = ROOT / "libexec" / "yogabook-validator-report.py"
MATRIX = ROOT / "data" / "acceptance.json"
VERSION = "0.38.0"


class DossierTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ybv-dossier-test-")
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_source(
        self,
        name: str,
        rows: list[str],
        *,
        version: str = VERSION,
        device: str = "Lenovo YB1-X91L",
        command: str = "quiet",
        boot_id: str = "boot-one",
    ) -> Path:
        directory = self.root / name
        directory.mkdir()
        (directory / "results.tsv").write_text(
            "timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n"
            + "\n".join(rows)
            + "\n",
            encoding="utf-8",
        )
        (directory / "validator.log").write_text(
            f"Yoga Book Validator {version}\n"
            f"Command: {command}\n"
            "Started: 2026-08-30T08:00:00+02:00\n\n"
            "AUTOMATED_RESULT: PASS\n"
            "PHYSICAL_ACCEPTANCE_RESULT: PENDING\n"
            "Finished: 2026-08-30T08:00:10+02:00\n",
            encoding="utf-8",
        )
        (directory / "environment.tsv").write_text(
            "key\tvalue\n"
            f"device\t{device}\n"
            "kernel\tLinux test\n"
            "architecture\tx86_64\n"
            "operating_system\tUbuntu 26.04.1 LTS\n"
            f"boot_id\t{boot_id}\n",
            encoding="utf-8",
        )
        subprocess.run([sys.executable, str(RENDERER), str(directory)], check=True)
        return directory

    def run_dossier(self, output: Path, *sources: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(DOSSIER),
                "--validator-version",
                VERSION,
                "--matrix",
                str(MATRIX),
                "--renderer",
                str(RENDERER),
                "--output",
                str(output),
                *(str(source) for source in sources),
            ],
            check=check,
            text=True,
            capture_output=True,
        )

    def test_composes_provenance_and_conservative_results(self) -> None:
        quiet = self.make_source(
            "quiet-current",
            [
                "2026-08-30T08:00:01+02:00\tplatform\tkernel\tPASS\tKernel is current\ttest",
                "2026-08-30T08:00:02+02:00\tdisplay\tjournal\tWARN\tDisplay warning\tcount=1",
            ],
        )
        physical = self.make_source(
            "physical-current",
            [
                "2026-08-30T08:01:01+02:00\tphysical\tauto-rotation\tPASS\tRotation works\tobserved",
                "2026-08-30T08:01:02+02:00\tphysical\tmicro-hdmi\tSKIP\tHDMI unavailable\tno adapter",
            ],
            command="physical",
            boot_id="boot-two",
        )
        output = self.root / "dossier"
        completed = self.run_dossier(output, quiet, physical)
        self.assertEqual(completed.stdout.strip(), str(output))
        model = json.loads((output / "report.json").read_text(encoding="utf-8"))
        self.assertEqual(model["run"]["command"], "dossier")
        self.assertEqual(model["run"]["automated_result"], "PASS_WITH_WARNINGS")
        self.assertEqual(model["run"]["physical_acceptance_result"], "INCOMPLETE")
        self.assertEqual(model["environment"]["source_reports"], "2")
        self.assertEqual(model["environment"]["source_boots"], "2")
        self.assertIn("sources.tsv", {item["file"] for item in model["evidence"]})
        provenance = (output / "sources.tsv").read_text(encoding="utf-8")
        self.assertIn("quiet-current", provenance)
        self.assertIn("physical-current", provenance)
        self.assertNotIn(str(self.root), provenance)
        self.assertEqual((output / "results.tsv").stat().st_mode & 0o777, 0o600)

        with (output / "sources.tsv").open("a", encoding="utf-8") as stream:
            stream.write("tampered provenance\n")
        completed = self.run_dossier(self.root / "nested-output", output, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("sources.tsv does not match report.json integrity metadata", completed.stderr)

    def test_rejects_tampered_or_incompatible_sources(self) -> None:
        good = self.make_source(
            "good",
            ["2026-08-30T08:00:01+02:00\tplatform\tkernel\tPASS\tKernel is current\ttest"],
        )
        tampered = self.make_source(
            "tampered",
            ["2026-08-30T08:00:01+02:00\tplatform\tkernel\tPASS\tKernel is current\ttest"],
        )
        with (tampered / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write("2026-08-30T08:00:02+02:00\tplatform\tkernel\tFAIL\tTampered\t\n")
        completed = self.run_dossier(self.root / "tampered-output", good, tampered, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("does not match report.json integrity metadata", completed.stderr)

        wrong_version = self.make_source(
            "wrong-version",
            ["2026-08-30T08:00:01+02:00\tplatform\tkernel\tPASS\tKernel is current\ttest"],
            version="0.33.0",
        )
        completed = self.run_dossier(self.root / "version-output", good, wrong_version, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("does not match 0.38.0", completed.stderr)

        other_device = self.make_source(
            "other-device",
            ["2026-08-30T08:00:01+02:00\tplatform\tkernel\tPASS\tKernel is current\ttest"],
            device="Different tablet",
        )
        completed = self.run_dossier(self.root / "identity-output", good, other_device, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("incompatible environment fields: device", completed.stderr)


if __name__ == "__main__":
    unittest.main()
