#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import importlib.util
from pathlib import Path
import random
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "yogabook_validator_camera_capture",
    ROOT / "libexec" / "yogabook-validator-camera-capture.py",
)
assert SPEC and SPEC.loader
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


class CameraSignalTest(unittest.TestCase):
    width = 256
    height = 256
    stride = width * 2 + 16
    frame_size = stride * height
    frames = 5

    def frame(self, pixel_format: str, green, other, padding: int = 0) -> bytes:
        parity = 1 if pixel_format == "BG10" else 0
        payload = bytearray()
        for y in range(self.height):
            for x in range(self.width):
                value = green(x, y) if ((x ^ y) & 1) == parity else other(x, y)
                payload.extend(int(value).to_bytes(2, "little"))
            payload.extend(bytes([padding & 0xFF]) * (self.stride - self.width * 2))
        return bytes(payload)

    def analyze(self, frames: list[bytes], pixel_format: str = "BG10") -> tuple[str, str]:
        return CAPTURE.analyze(
            b"".join(frames),
            self.width,
            self.height,
            self.stride,
            self.frame_size,
            self.frames,
            pixel_format,
        )

    @staticmethod
    def scene(x: int, y: int, offset: int = 0) -> int:
        return 96 + ((x * 3 + y * 5 + ((x // 32) ^ (y // 32)) * 70 + offset) % 820)

    def test_structured_scene_passes_for_both_bayer_parities(self) -> None:
        for pixel_format in ("BG10", "BA10"):
            with self.subTest(pixel_format=pixel_format):
                frames = [
                    self.frame(
                        pixel_format,
                        lambda x, y, offset=offset: self.scene(x, y, offset),
                        lambda x, y, seed=offset: random.Random(y * self.width + x + seed).randrange(1024),
                        padding=offset,
                    )
                    for offset in range(self.frames)
                ]
                status, details = self.analyze(frames, pixel_format)
                self.assertEqual(status, "PASS", details)

    def test_frozen_active_pixels_fail_even_when_padding_changes(self) -> None:
        frames = [
            self.frame("BG10", lambda x, y: self.scene(x, y), lambda x, y: 300, padding=index)
            for index in range(self.frames)
        ]
        status, details = self.analyze(frames)
        self.assertEqual(status, "FAIL")
        self.assertIn("frozen-active-pixels", details)

    def test_random_and_fixed_pattern_noise_fail(self) -> None:
        random_frames = []
        for frame_index in range(self.frames):
            generator = random.Random(1000 + frame_index)
            values = [generator.randrange(1024) for _ in range(self.width * self.height)]
            random_frames.append(
                self.frame(
                    "BG10",
                    lambda x, y, values=values: values[y * self.width + x],
                    lambda x, y: 400,
                )
            )
        status, details = self.analyze(random_frames)
        self.assertEqual(status, "FAIL", details)
        self.assertIn("unstructured-high-amplitude-noise", details)

        generator = random.Random(42)
        base = [generator.randrange(100, 900) for _ in range(self.width * self.height)]
        fixed_frames = [
            self.frame(
                "BG10",
                lambda x, y, offset=offset: min(1023, base[y * self.width + x] + offset),
                lambda x, y: 400,
            )
            for offset in range(self.frames)
        ]
        status, details = self.analyze(fixed_frames)
        self.assertEqual(status, "FAIL", details)
        self.assertIn("unstructured-high-amplitude-noise", details)

    def test_flat_clipped_and_corrupt_frames_do_not_pass(self) -> None:
        flat = [
            self.frame("BG10", lambda x, y, offset=offset: 300 + (x + y + offset) % 10, lambda x, y: 0)
            for offset in range(self.frames)
        ]
        self.assertEqual(self.analyze(flat)[0], "WARN")

        clipped = [
            self.frame("BG10", lambda x, y, offset=offset: 1023 if (x + y + offset) % 20 else 0, lambda x, y: 0)
            for offset in range(self.frames)
        ]
        status, details = self.analyze(clipped)
        self.assertEqual(status, "FAIL", details)
        self.assertIn("severe-clipping", details)

        corrupt = [
            self.frame(
                "BG10",
                lambda x, y, offset=offset: self.scene(x, y, offset) | (0x400 if (x + y) % 51 == 0 else 0),
                lambda x, y: 300,
            )
            for offset in range(self.frames)
        ]
        status, details = self.analyze(corrupt)
        self.assertEqual(status, "FAIL", details)
        self.assertIn("invalid-upper-bits", details)

    def test_truncated_payload_is_incomplete(self) -> None:
        frame = self.frame("BG10", lambda x, y: self.scene(x, y), lambda x, y: 300)
        status, details = self.analyze([frame] * (self.frames - 1))
        self.assertEqual(status, "SKIP")
        self.assertIn("complete_frames=4", details)


if __name__ == "__main__":
    unittest.main()
