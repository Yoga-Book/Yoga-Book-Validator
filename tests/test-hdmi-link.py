#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "libexec" / "yogabook-validator-hdmi-link.py"


class HdmiLinkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ybv-hdmi-test-")
        root = Path(self.temporary.name)
        self.connector = root / "card1-HDMI-A-1"
        self.asound = root / "asound"
        self.connector.mkdir()
        self.asound.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_helper(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HELPER), str(self.connector), str(self.asound)],
            text=True,
            capture_output=True,
        )

    def connector_state(self, status: str, enabled: str, modes: str = "") -> None:
        (self.connector / "status").write_text(status + "\n", encoding="utf-8")
        (self.connector / "enabled").write_text(enabled + "\n", encoding="utf-8")
        (self.connector / "modes").write_text(modes, encoding="utf-8")

    def test_disconnected_display_is_explicitly_skipped(self) -> None:
        self.connector_state("disconnected", "disabled")
        completed = self.run_helper()
        self.assertEqual(completed.returncode, 0)
        self.assertIn("display\thdmi-link\tSKIP", completed.stdout)
        self.assertIn("audio\thdmi-route\tSKIP", completed.stdout)

    def test_connected_display_requires_active_video_and_valid_eld(self) -> None:
        self.connector_state("connected", "enabled", "1920x1080\n1280x720\n")
        card = self.asound / "card0"
        card.mkdir()
        (card / "eld#0.0").write_text(
            "monitor_present         1\n"
            "eld_valid               1\n"
            "monitor_name            Test Display\n",
            encoding="utf-8",
        )
        completed = self.run_helper()
        self.assertEqual(completed.returncode, 0)
        self.assertIn("display\thdmi-link\tPASS", completed.stdout)
        self.assertIn("audio\thdmi-route\tPASS", completed.stdout)
        self.assertIn("monitor=Test Display", completed.stdout)

    def test_connected_display_without_valid_eld_fails_audio_route(self) -> None:
        self.connector_state("connected", "enabled", "1920x1080\n")
        completed = self.run_helper()
        self.assertEqual(completed.returncode, 1)
        self.assertIn("display\thdmi-link\tPASS", completed.stdout)
        self.assertIn("audio\thdmi-route\tFAIL", completed.stdout)


if __name__ == "__main__":
    unittest.main()
