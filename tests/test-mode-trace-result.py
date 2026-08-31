#!/usr/bin/env python3
"""Unit tests for strict mode-transition continuity evidence."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "libexec" / "yogabook-validator-mode-trace-result.py"
SPEC = importlib.util.spec_from_file_location("mode_trace_result", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def trace_text(rows: list[tuple[int, str]]) -> str:
    header = "\t".join(MODULE.HEADER) + "\n"
    return header + "".join(
        f"2026-08-31T16:00:00+02:00\t{monotonic}\tright-up\tDSI-1\t"
        f"1920x1200@60\t0\t1\t0\t0\t0\t{wacom}\n"
        for monotonic, wacom in rows
    )


class ModeTraceResultTests(unittest.TestCase):
    def analyze(self, content: str, start: int = 100, finish: int = 400) -> tuple[int, int]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mode-transition.tsv"
            path.write_text(content, encoding="utf-8")
            return MODULE.analyze_path(path, start, finish)

    def test_continuous_window(self) -> None:
        self.assertEqual(self.analyze(trace_text([(100, "1"), (200, "1"), (300, "1")])), (3, 0))

    def test_dropout_is_counted_only_inside_window(self) -> None:
        content = trace_text([(50, "0"), (100, "1"), (200, "0"), (500, "0")])
        self.assertEqual(self.analyze(content), (2, 1))

    def test_empty_window_is_not_manufactured(self) -> None:
        self.assertEqual(self.analyze(trace_text([(10, "1"), (20, "1")])), (0, 0))

    def test_rejects_wrong_header_and_field_count(self) -> None:
        with self.assertRaises(MODULE.TraceError):
            self.analyze("wrong\theader\n")
        with self.assertRaises(MODULE.TraceError):
            self.analyze("\t".join(MODULE.HEADER) + "\nshort\trow\n")

    def test_rejects_non_monotonic_or_invalid_presence(self) -> None:
        with self.assertRaises(MODULE.TraceError):
            self.analyze(trace_text([(100, "1"), (100, "1")]))
        with self.assertRaises(MODULE.TraceError):
            self.analyze(trace_text([(100, "unknown")]))

    def test_rejects_oversized_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mode-transition.tsv"
            with path.open("wb") as stream:
                stream.truncate(MODULE.MAX_TRACE_BYTES + 1)
            with self.assertRaises(MODULE.TraceError):
                MODULE.analyze_path(path, 0, 1)


if __name__ == "__main__":
    unittest.main()
