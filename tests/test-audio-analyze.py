#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import importlib.util
import math
from pathlib import Path
import struct
import tempfile
import unittest
import wave


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "yogabook_validator_audio_analyze",
    ROOT / "libexec" / "yogabook-validator-audio-analyze.py",
)
assert SPEC and SPEC.loader
ANALYZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYZER)


class AudioAnalyzeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ybv-audio-analyze-")
        self.path = Path(self.temporary.name) / "capture.wav"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, sample) -> None:
        with wave.open(str(self.path), "wb") as wav:
            wav.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
            for index in range(48000 * 2):
                left, right = sample(index)
                wav.writeframesraw(struct.pack("<hh", left, right))

    def test_plausible_stereo_signal_passes(self) -> None:
        self.write(
            lambda index: (
                int(1800 * math.sin(2 * math.pi * 440 * index / 48000)),
                int(1600 * math.sin(2 * math.pi * 445 * index / 48000)),
            )
        )
        status, details = ANALYZER.analyze(self.path)
        self.assertEqual(status, "PASS", details)

    def test_silence_dc_and_clipping_fail(self) -> None:
        self.write(lambda _index: (0, 0))
        self.assertIn("empty-or-stuck-channel", ANALYZER.analyze(self.path)[1])
        self.write(lambda index: (5000 + index % 3, 5000 + index % 3))
        self.assertIn("dc-offset", ANALYZER.analyze(self.path)[1])
        self.write(lambda index: (32767 if index % 2 else -32768, 32767 if index % 2 else -32768))
        self.assertIn("clipping", ANALYZER.analyze(self.path)[1])

    def test_channel_imbalance_warns_then_fails(self) -> None:
        self.write(
            lambda index: (
                int(4000 * math.sin(2 * math.pi * 440 * index / 48000)),
                int(800 * math.sin(2 * math.pi * 440 * index / 48000)),
            )
        )
        status, details = ANALYZER.analyze(self.path)
        self.assertEqual(status, "WARN", details)
        self.write(
            lambda index: (
                int(4000 * math.sin(2 * math.pi * 440 * index / 48000)),
                int(200 * math.sin(2 * math.pi * 440 * index / 48000)),
            )
        )
        status, details = ANALYZER.analyze(self.path)
        self.assertEqual(status, "FAIL", details)

    def test_expected_capture_duration_is_enforced(self) -> None:
        self.write(
            lambda index: (
                int(1800 * math.sin(2 * math.pi * 440 * index / 48000)),
                int(1600 * math.sin(2 * math.pi * 445 * index / 48000)),
            )
        )
        status, details = ANALYZER.analyze(self.path, expected_seconds=3)
        self.assertEqual(status, "FAIL")
        self.assertIn("duration=2.00s expected=3.00s", details)
        self.assertEqual(ANALYZER.analyze(self.path, expected_seconds=2)[0], "PASS")


if __name__ == "__main__":
    unittest.main()
