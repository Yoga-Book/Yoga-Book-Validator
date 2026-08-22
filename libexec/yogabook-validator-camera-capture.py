#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Capture and inspect camera frames in memory without retaining image data."""

from __future__ import annotations

import hashlib
import math
import os
import subprocess
import sys


def clean(value: str) -> str:
    return " ".join(value.replace("\t", " ").split())


def parse_geometry(arguments: list[str]) -> tuple[int, int, int, int, int]:
    try:
        width, height, stride, frame_size, frames = map(int, arguments)
    except (TypeError, ValueError) as error:
        raise ValueError("invalid frame geometry") from error
    if min(width, height, stride, frame_size, frames) <= 0:
        raise ValueError("frame geometry must be positive")
    if stride < width or frame_size < stride * height:
        raise ValueError("frame geometry is inconsistent")
    if frames > 10 or frame_size * frames > 128 * 1024 * 1024:
        raise ValueError("capture request exceeds the bounded memory limit")
    return width, height, stride, frame_size, frames


def analyze(
    payload: bytes,
    width: int,
    height: int,
    stride: int,
    frame_size: int,
    requested_frames: int,
) -> tuple[str, str]:
    received_frames = len(payload) // frame_size
    if received_frames < requested_frames:
        return "SKIP", f"complete_frames={received_frames} expected={requested_frames}"

    ranges: list[int] = []
    deviations: list[float] = []
    digests: set[bytes] = set()
    for frame_index in range(requested_frames):
        start = frame_index * frame_size
        frame = payload[start : start + frame_size]
        luma = b"".join(
            frame[row * stride : row * stride + width] for row in range(height)
        )
        if len(luma) != width * height:
            return "FAIL", f"frame={frame_index + 1} luma_payload=incomplete"
        minimum = min(luma)
        maximum = max(luma)
        mean = sum(luma) / len(luma)
        mean_square = sum(value * value for value in luma) / len(luma)
        ranges.append(maximum - minimum)
        deviations.append(math.sqrt(max(0.0, mean_square - mean * mean)))
        digests.add(hashlib.sha256(luma).digest())

    minimum_range = min(ranges)
    minimum_deviation = min(deviations)
    details = (
        f"frames={requested_frames} resolution={width}x{height} "
        f"minimum-luma-range={minimum_range} "
        f"minimum-luma-stddev={minimum_deviation:.2f} "
        f"unique-frames={len(digests)}"
    )
    if len(digests) < 2:
        return "FAIL", details
    if minimum_range < 8 or minimum_deviation < 1.0:
        return "WARN", details
    return "PASS", details


def emit(
    stream_status: str,
    signal_status: str,
    stream_details: str,
    signal_details: str,
) -> None:
    print(
        "\t".join(
            clean(value)
            for value in (stream_status, signal_status, stream_details, signal_details)
        )
    )


def main() -> int:
    analyze_stdin = len(sys.argv) == 7 and sys.argv[1] == "--analyze-stdin"
    capture = len(sys.argv) == 7 and not analyze_stdin
    if not (analyze_stdin or capture):
        print(
            "Usage: yogabook-validator-camera-capture.py "
            "DEVICE WIDTH HEIGHT STRIDE FRAME_SIZE FRAMES",
            file=sys.stderr,
        )
        return 2

    try:
        width, height, stride, frame_size, frames = parse_geometry(sys.argv[2:])
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    if analyze_stdin:
        payload = sys.stdin.buffer.read(frame_size * frames + 1)
        received = len(payload) // frame_size
        stream_status = "PASS" if received >= frames else "FAIL"
        stream_details = f"complete_frames={received} expected={frames}"
        signal_status, signal_details = analyze(
            payload, width, height, stride, frame_size, frames
        )
        emit(stream_status, signal_status, stream_details, signal_details)
        return 0

    device = sys.argv[1]
    command = os.environ.get("YBV_V4L2_CTL", "v4l2-ctl")
    actual_frame_size = frame_size
    try:
        completed = subprocess.run(
            [
                command,
                "-d",
                device,
                "--stream-mmap=3",
                f"--stream-count={frames}",
                "--stream-to=-",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
        )
        payload = completed.stdout
        actual_frame_size = len(payload) // frames if len(payload) % frames == 0 else 0
        received = frames if actual_frame_size >= stride * height else 0
        if completed.returncode == 0 and received == frames:
            stream_status = "PASS"
            stream_details = (
                f"complete_frames={received} actual_frame_bytes={actual_frame_size} "
                f"advertised_frame_bytes={frame_size}"
            )
        else:
            stream_status = "FAIL"
            error = clean(completed.stderr.decode("utf-8", errors="replace"))
            stream_details = (
                f"exit={completed.returncode} bytes={len(payload)} "
                f"expected_frames={frames} error={error or 'none'}"
            )
    except subprocess.TimeoutExpired as error:
        payload = error.stdout or b""
        received = len(payload) // frame_size
        stream_status = "FAIL"
        stream_details = f"timeout=20s complete_frames={received} expected={frames}"
    except OSError as error:
        payload = b""
        stream_status = "FAIL"
        stream_details = f"capture_error={clean(str(error))}"

    if stream_status == "PASS":
        signal_status, signal_details = analyze(
            payload, width, height, stride, actual_frame_size, frames
        )
    else:
        signal_status = "SKIP"
        signal_details = "capture transport did not complete"
    emit(stream_status, signal_status, stream_details, signal_details)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
