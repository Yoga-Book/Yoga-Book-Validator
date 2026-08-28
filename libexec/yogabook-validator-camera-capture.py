#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Capture and inspect camera frames in memory without retaining image data."""

from __future__ import annotations

import hashlib
import math
import os
import selectors
import subprocess
import sys
import time


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
    capture = len(sys.argv) == 8 and not analyze_stdin
    if not (analyze_stdin or capture):
        print(
            "Usage: yogabook-validator-camera-capture.py "
            "DEVICE WIDTH HEIGHT STRIDE FRAME_SIZE FRAMES PIXEL_FORMAT",
            file=sys.stderr,
        )
        return 2

    try:
        width, height, stride, frame_size, frames = parse_geometry(sys.argv[2:7])
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
    pixel_format = sys.argv[7]
    command = os.environ.get("YBV_V4L2_CTL", "v4l2-ctl")
    capture_timeout = float(os.environ.get("YBV_CAMERA_CAPTURE_TIMEOUT", "20"))
    actual_frame_size = frame_size
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            [
                command,
                "-d",
                device,
                (
                    f"--set-fmt-video=width={width},height={height},"
                    f"pixelformat={pixel_format}"
                ),
                "--stream-mmap=3",
                f"--stream-count={frames}",
                "--stream-to=-",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if process.stdout is None or process.stderr is None:
            raise OSError("capture pipes are unavailable")
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        payload_buffer = bytearray()
        error_buffer = bytearray()
        deadline = time.monotonic() + capture_timeout
        target_bytes = frame_size * frames
        while len(payload_buffer) < target_bytes and selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            events = selector.select(remaining)
            if not events:
                break
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), 1024 * 1024)
                if not chunk:
                    selector.unregister(key.fileobj)
                elif key.data == "stdout":
                    payload_buffer.extend(chunk[: target_bytes - len(payload_buffer)])
                else:
                    error_buffer.extend(chunk)
        payload = bytes(payload_buffer)
        received = len(payload) // frame_size
        if received >= frames:
            stream_status = "PASS"
            stream_details = (
                f"complete_frames={received} actual_frame_bytes={frame_size} "
                f"advertised_frame_bytes={frame_size}"
            )
        else:
            stream_status = "FAIL"
            error = clean(error_buffer.decode("utf-8", errors="replace"))
            timed_out = time.monotonic() >= deadline
            stream_details = (
                f"{'timeout=' + str(capture_timeout) + 's ' if timed_out else ''}"
                f"exit={process.poll()} bytes={len(payload)} "
                f"expected_frames={frames} error={error or 'none'}"
            )
    except OSError as error:
        payload = b""
        stream_status = "FAIL"
        stream_details = f"capture_error={clean(str(error))}"
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

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
