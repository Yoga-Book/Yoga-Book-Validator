#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import json
from datetime import datetime, timedelta
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DOSSIER = ROOT / "libexec" / "yogabook-validator-dossier.py"
RENDERER = ROOT / "libexec" / "yogabook-validator-report.py"
MATRIX = ROOT / "data" / "acceptance.json"
VERSION = "0.62.0"


class DossierTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ybv-dossier-test-")
        self.root = Path(self.temporary.name)
        self.fixture_anchor = datetime.fromisoformat("2026-08-30T08:00:00+02:00")
        self.fresh_anchor = datetime.now().astimezone().replace(microsecond=0) - timedelta(hours=6)

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
        package_version: str = VERSION,
        camera_package_version: str = "1.0",
    ) -> Path:
        directory = self.root / name
        directory.mkdir()
        automated_result = (
            "FAIL" if any(row.split("\t")[3] == "FAIL" for row in rows)
            else "PASS_WITH_WARNINGS" if any(row.split("\t")[3] == "WARN" for row in rows)
            else "PASS"
        )
        fresh_rows = []
        observed_times = []
        for row in rows:
            fields = row.split("\t")
            observed = datetime.fromisoformat(fields[0])
            translated = self.fresh_anchor + (observed - self.fixture_anchor)
            fields[0] = translated.isoformat(timespec="seconds")
            fresh_rows.append("\t".join(fields))
            observed_times.append(translated)
        state_time = max(observed_times, default=self.fresh_anchor) + timedelta(seconds=1)
        rows = [
            *fresh_rows,
            f"{state_time.isoformat(timespec='seconds')}\tvalidator\tstate-preservation\tPASS\tState preserved\ttest",
        ]
        (directory / "results.tsv").write_text(
            "timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n"
            + "\n".join(rows)
            + "\n",
            encoding="utf-8",
        )
        (directory / "validator.log").write_text(
            f"Yoga Book Validator {version}\n"
            f"Command: {command}\n"
            f"Started: {(min(observed_times, default=self.fresh_anchor) - timedelta(seconds=1)).isoformat(timespec='seconds')}\n\n"
            f"AUTOMATED_RESULT: {automated_result}\n"
            "PHYSICAL_ACCEPTANCE_RESULT: PENDING\n"
            f"Finished: {(state_time + timedelta(seconds=1)).isoformat(timespec='seconds')}\n",
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
        (directory / "validated-packages.tsv").write_text(
            "alsa-ucm-conf-yogabook\t1.0\tall\n"
            "gir1.2-mutter-18\t1.0\tamd64\n"
            "gnome-control-center\t1.0\tamd64\n"
            "gnome-control-center-data\t1.0\tall\n"
            "halo-keyboard\t1.0\tall\n"
            "libmutter-18-0\t1.0\tamd64\n"
            "linux-headers-yogabook-test\t1.0\tamd64\n"
            "linux-image-yogabook-test\t1.0\tamd64\n"
            "mutter-common\t1.0\tall\n"
            "mutter-common-bin\t1.0\tamd64\n"
            "sof-topology-yogabook\t1.0\tall\n"
            f"yogabook-camera\t{camera_package_version}\tall\n"
            "yogabook-gnss\t1.0\tall\n"
            "yogabook-sensors\t1.0\tall\n"
            f"yogabook-validator\t{package_version}\tall\n",
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
        self.assertEqual(model["package_inventory"]["captured"], 15)
        self.assertEqual(
            (output / "validated-packages.tsv").read_text(encoding="utf-8"),
            (quiet / "validated-packages.tsv").read_text(encoding="utf-8"),
        )
        self.assertIn("sources.tsv", {item["file"] for item in model["evidence"]})
        self.assertIn("observations.tsv", {item["file"] for item in model["evidence"]})
        provenance = (output / "sources.tsv").read_text(encoding="utf-8")
        self.assertIn("quiet-current", provenance)
        self.assertIn("physical-current", provenance)
        self.assertNotIn(str(self.root), provenance)
        self.assertEqual((output / "results.tsv").stat().st_mode & 0o777, 0o600)
        self.assertEqual(model["environment"]["source_observations"], "6")
        self.assertEqual(model["environment"]["effective_observations"], "5")
        self.assertEqual(model["environment"]["superseded_observations"], "1")

        with (output / "sources.tsv").open("a", encoding="utf-8") as stream:
            stream.write("tampered provenance\n")
        completed = self.run_dossier(self.root / "nested-output", output, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("sources.tsv does not match report.json integrity metadata", completed.stderr)

    def test_latest_conclusive_evidence_supersedes_history_without_skip_poisoning(self) -> None:
        older = self.make_source(
            "older",
            [
                "2026-08-30T08:00:01+02:00\tinput\thaptic-left\tSKIP\tNot exercised\tquiet run",
                "2026-08-30T08:00:02+02:00\tdisplay\tjournal\tFAIL\tOld failure\tbefore fix",
                "2026-08-30T08:00:03+02:00\tphysical\tauto-rotation\tSKIP\tNot observed\toperator absent",
            ],
        )
        newer = self.make_source(
            "newer",
            [
                "2026-08-30T09:00:01+02:00\tinput\thaptic-left\tPASS\tActuator works\tfocused run",
                "2026-08-30T09:00:02+02:00\tdisplay\tjournal\tPASS\tFailure resolved\tafter fix",
                "2026-08-30T09:00:03+02:00\tphysical\tauto-rotation\tPASS\tRotation observed\toperator confirmed",
            ],
            command="physical",
            boot_id="boot-two",
        )
        later_skip = self.make_source(
            "later-skip",
            ["2026-08-30T10:00:01+02:00\tinput\thaptic-left\tSKIP\tLater quiet run\tnot exercised"],
            boot_id="boot-two",
        )
        output = self.root / "resolved-dossier"
        completed = self.run_dossier(output, newer, older, later_skip, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        model = json.loads((output / "report.json").read_text(encoding="utf-8"))
        effective = {
            (row["subsystem"], row["check_id"]): row["status"]
            for row in model["results"]
        }
        self.assertEqual(effective[("input", "haptic-left")], "PASS")
        self.assertEqual(effective[("display", "journal")], "PASS")
        self.assertEqual(effective[("physical", "auto-rotation")], "PASS")
        self.assertEqual(model["run"]["automated_result"], "PASS")
        self.assertEqual(model["run"]["physical_acceptance_result"], "PASS")
        self.assertEqual(model["environment"]["source_observations"], "10")
        self.assertEqual(model["environment"]["effective_observations"], "4")
        self.assertEqual(model["environment"]["superseded_observations"], "6")
        ledger = (output / "observations.tsv").read_text(encoding="utf-8")
        self.assertIn("older\tno\tnon-conclusive", ledger)
        self.assertIn("older\tno\tsuperseded", ledger)
        self.assertIn("newer\tyes\tlatest-conclusive", ledger)

    def test_latest_dependency_block_supersedes_stale_downstream_failure(self) -> None:
        older = self.make_source(
            "runtime-present-service-broken",
            [
                "2026-08-30T08:00:01+02:00\tgnss\truntime-assets\tPASS\tRuntime installed\ttest",
                "2026-08-30T08:00:02+02:00\tgnss\tservices\tFAIL\tService failed\ttest",
            ],
        )
        newer = self.make_source(
            "runtime-removed",
            [
                "2026-08-30T09:00:01+02:00\tgnss\truntime-assets\tFAIL\tRuntime missing\ttest",
                "2026-08-30T09:00:02+02:00\tgnss\tservices\tSKIP\tService is blocked\tblocked_by=gnss/runtime-assets",
            ],
        )
        output = self.root / "blocked-dossier"
        self.run_dossier(output, older, newer)
        model = json.loads((output / "report.json").read_text(encoding="utf-8"))
        effective = {
            (row["subsystem"], row["check_id"]): row["status"]
            for row in model["results"]
        }
        self.assertEqual(effective[("gnss", "runtime-assets")], "FAIL")
        self.assertEqual(effective[("gnss", "services")], "SKIP")
        ledger = (output / "observations.tsv").read_text(encoding="utf-8")
        self.assertIn("runtime-removed\tyes\tlatest-blocked", ledger)

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
            package_version="0.33.0-1",
        )
        completed = self.run_dossier(self.root / "version-output", good, wrong_version, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("does not match 0.62.0", completed.stderr)

        other_device = self.make_source(
            "other-device",
            ["2026-08-30T08:00:01+02:00\tplatform\tkernel\tPASS\tKernel is current\ttest"],
            device="Different tablet",
        )
        completed = self.run_dossier(self.root / "identity-output", good, other_device, check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("incompatible environment fields: device", completed.stderr)

        different_packages = self.make_source(
            "different-packages",
            ["2026-08-30T08:00:01+02:00\tplatform\tkernel\tPASS\tKernel is current\ttest"],
            camera_package_version="0.45.0",
        )
        completed = self.run_dossier(
            self.root / "package-output", good, different_packages, check=False
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("incompatible validated package inventory", completed.stderr)

        invalid_integrity = self.make_source(
            "invalid-integrity",
            ["2026-08-30T08:00:01+02:00\tplatform\tkernel\tPASS\tKernel is current\ttest"],
        )
        with (invalid_integrity / "results.tsv").open("a", encoding="utf-8") as stream:
            stream.write(
                "2026-08-30T08:00:02+02:00\tplatform\tkernel\tFAIL\tConflicting kernel result\ttest\n"
            )
        subprocess.run([sys.executable, str(RENDERER), str(invalid_integrity)], check=True)
        completed = self.run_dossier(
            self.root / "integrity-output", good, invalid_integrity, check=False
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("source evidence integrity failed", completed.stderr)


if __name__ == "__main__":
    unittest.main()
