#!/usr/bin/env python3
"""Validate a completed mode trace and summarize Wacom continuity."""

from __future__ import annotations

import argparse
import csv
import io
import sys
from pathlib import Path
from typing import TextIO


HEADER = (
    "timestamp",
    "monotonic_ms",
    "sensor_orientation",
    "connector",
    "mode",
    "transform",
    "halo_service",
    "halo_device",
    "halo_keyboard",
    "halo_touchpad",
    "wacom_pen",
)
MAX_TRACE_BYTES = 4 * 1024 * 1024
MAX_TRACE_ROWS = 50_000
MAX_FIELD_CHARS = 512


class TraceError(ValueError):
    """The trace is malformed or cannot prove the requested window."""


def analyze_stream(stream: TextIO, start_ms: int, finish_ms: int) -> tuple[int, int]:
    if start_ms < 0 or finish_ms < start_ms:
        raise TraceError("invalid analysis window")
    reader = csv.reader(stream, delimiter="\t", strict=True)
    try:
        header = tuple(next(reader))
    except StopIteration as error:
        raise TraceError("empty trace") from error
    if header != HEADER:
        raise TraceError("unexpected trace header")

    samples = 0
    dropouts = 0
    previous_monotonic = -1
    for row_count, row in enumerate(reader, start=1):
        if row_count > MAX_TRACE_ROWS:
            raise TraceError("too many trace rows")
        if len(row) != len(HEADER):
            raise TraceError(f"row {row_count} has an unexpected field count")
        if any(len(field) > MAX_FIELD_CHARS for field in row):
            raise TraceError(f"row {row_count} contains an oversized field")
        if any(any(ord(character) < 0x20 for character in field) for field in row):
            raise TraceError(f"row {row_count} contains a control character")
        try:
            monotonic_ms = int(row[1])
        except ValueError as error:
            raise TraceError(f"row {row_count} has an invalid monotonic timestamp") from error
        if monotonic_ms <= previous_monotonic:
            raise TraceError(f"row {row_count} is not strictly monotonic")
        previous_monotonic = monotonic_ms
        for index in range(7, 11):
            if row[index] not in {"0", "1"}:
                raise TraceError(f"row {row_count} has an invalid presence value")
        if start_ms <= monotonic_ms <= finish_ms:
            samples += 1
            if row[10] != "1":
                dropouts += 1
    return samples, dropouts


def analyze_path(path: Path, start_ms: int, finish_ms: int) -> tuple[int, int]:
    try:
        size = path.stat().st_size
    except OSError as error:
        raise TraceError(f"cannot stat trace: {error}") from error
    if size > MAX_TRACE_BYTES:
        raise TraceError("trace is too large")
    try:
        with path.open("r", encoding="utf-8", newline="") as stream:
            return analyze_stream(stream, start_ms, finish_ms)
    except (OSError, UnicodeError, csv.Error) as error:
        raise TraceError(f"cannot parse trace: {error}") from error


def self_test() -> None:
    header = "\t".join(HEADER) + "\n"
    rows = (
        "2026-08-31T16:00:00+02:00\t100\tright-up\tDSI-1\t1920x1200@60\t0\t1\t0\t0\t0\t1\n"
        "2026-08-31T16:00:00+02:00\t200\tright-up\tDSI-1\t1920x1200@60\t0\t1\t0\t0\t0\t0\n"
        "2026-08-31T16:00:00+02:00\t300\tright-up\tDSI-1\t1920x1200@60\t0\t1\t0\t0\t0\t1\n"
    )
    assert analyze_stream(io.StringIO(header + rows), 100, 300) == (3, 1)
    assert analyze_stream(io.StringIO(header + rows), 300, 300) == (1, 0)
    try:
        analyze_stream(io.StringIO(header + rows.replace("\t200\t", "\t100\t")), 100, 300)
    except TraceError:
        pass
    else:
        raise AssertionError("non-monotonic trace was accepted")
    try:
        analyze_stream(io.StringIO(header + rows.replace("\t0\n", "\tunknown\n")), 100, 300)
    except TraceError:
        pass
    else:
        raise AssertionError("invalid presence value was accepted")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("trace", nargs="?", type=Path)
    parser.add_argument("start_ms", nargs="?", type=int)
    parser.add_argument("finish_ms", nargs="?", type=int)
    args = parser.parse_args(argv)
    if args.self_test:
        if args.trace is not None or args.start_ms is not None or args.finish_ms is not None:
            parser.error("--self-test does not accept a trace window")
        self_test()
        print("mode trace result policy: PASS")
        return 0
    if args.trace is None or args.start_ms is None or args.finish_ms is None:
        parser.error("TRACE START_MS and FINISH_MS are required")
    try:
        samples, dropouts = analyze_path(args.trace, args.start_ms, args.finish_ms)
    except TraceError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"{samples}\t{dropouts}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
