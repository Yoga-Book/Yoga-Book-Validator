#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Capture and inspect camera frames in memory without retaining image data."""

from __future__ import annotations

import hashlib
import math
import os
import selectors
import statistics
import subprocess
import sys
import time
from array import array


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
    pixel_format: str,
) -> tuple[str, str]:
    received_frames = len(payload) // frame_size
    if received_frames < requested_frames:
        return "SKIP", f"complete_frames={received_frames} expected={requested_frames}"

    if pixel_format not in {"BG10", "BA10"} or stride < width * 2:
        return "FAIL", f"pixel-format={clean(pixel_format)} stride={stride} expected-active-row={width * 2}"

    def correlation(count: int, sx: float, sy: float, sxx: float, syy: float, sxy: float) -> float:
        if count < 2:
            return 0.0
        numerator = count * sxy - sx * sy
        denominator = math.sqrt(max(0.0, count * sxx - sx * sx) * max(0.0, count * syy - sy * sy))
        return numerator / denominator if denominator else 0.0

    def vector_correlation(left: list[float], right: list[float]) -> float:
        return correlation(
            len(left),
            sum(left),
            sum(right),
            sum(value * value for value in left),
            sum(value * value for value in right),
            sum(a * b for a, b in zip(left, right)),
        )

    spans: list[int] = []
    deviations: list[float] = []
    lag_correlations: list[float] = []
    coherences: list[float] = []
    clipping_fractions: list[float] = []
    invalid_fractions: list[float] = []
    tile_vectors: list[list[float]] = []
    row_cardinalities: list[int] = []
    digests: set[bytes] = set()
    green_parity = 1 if pixel_format == "BG10" else 0
    sample_step = max(1, math.ceil(math.sqrt((width * height / 2) / 65536)))
    tile_columns = min(16, max(1, width // 2))
    tile_rows = min(16, height)
    tile_count = tile_columns * tile_rows
    for frame_index in range(requested_frames):
        start = frame_index * frame_size
        frame = payload[start : start + frame_size]
        active_digest = hashlib.sha256()
        row_digests: set[bytes] = set()
        samples: list[int] = []
        total = total_square = clipped = invalid = green_count = 0
        pair_count = 0
        pair_x = pair_y = pair_xx = pair_yy = pair_xy = 0
        tile_sums = [0] * tile_count
        tile_counts = [0] * tile_count
        for y in range(height):
            row = frame[y * stride : y * stride + width * 2]
            if len(row) != width * 2:
                return "FAIL", f"frame={frame_index + 1} active-payload=incomplete"
            active_digest.update(row)
            row_digests.add(hashlib.blake2s(row, digest_size=8).digest())
            words = array("H")
            words.frombytes(row)
            if sys.byteorder != "little":
                words.byteswap()
            previous_green: int | None = None
            for x, word in enumerate(words):
                if word > 1023:
                    invalid += 1
                value = word & 1023
                if ((x ^ y) & 1) != green_parity:
                    continue
                green_count += 1
                total += value
                total_square += value * value
                clipped += value in {0, 1023}
                tile = (
                    min(tile_rows - 1, y * tile_rows // height) * tile_columns
                    + min(tile_columns - 1, x * tile_columns // width)
                )
                tile_sums[tile] += value
                tile_counts[tile] += 1
                if y % sample_step == 0 and x % (sample_step * 2) in {0, 1}:
                    samples.append(value)
                if previous_green is not None:
                    pair_count += 1
                    pair_x += previous_green
                    pair_y += value
                    pair_xx += previous_green * previous_green
                    pair_yy += value * value
                    pair_xy += previous_green * value
                previous_green = value
        if not green_count or not samples or any(count == 0 for count in tile_counts):
            return "FAIL", f"frame={frame_index + 1} green-plane=incomplete"
        samples.sort()
        p01 = samples[min(len(samples) - 1, len(samples) // 100)]
        p99 = samples[min(len(samples) - 1, len(samples) * 99 // 100)]
        mean = total / green_count
        deviation = math.sqrt(max(0.0, total_square / green_count - mean * mean))
        tile_means = [value / count for value, count in zip(tile_sums, tile_counts)]
        tile_deviation = statistics.pstdev(tile_means)
        spans.append(p99 - p01)
        deviations.append(deviation)
        lag_correlations.append(
            correlation(pair_count, pair_x, pair_y, pair_xx, pair_yy, pair_xy)
        )
        coherences.append(tile_deviation / deviation if deviation else 0.0)
        clipping_fractions.append(clipped / green_count)
        invalid_fractions.append(invalid / (width * height))
        tile_vectors.append(tile_means)
        row_cardinalities.append(len(row_digests))
        digests.add(active_digest.digest())

    temporal_correlations = [
        vector_correlation(left, right) for left, right in zip(tile_vectors, tile_vectors[1:])
    ]
    temporal_mads = [
        statistics.median(abs(a - b) for a, b in zip(left, right))
        for left, right in zip(tile_vectors, tile_vectors[1:])
    ]
    median_span = int(statistics.median(spans))
    median_deviation = statistics.median(deviations)
    median_lag = statistics.median(abs(value) for value in lag_correlations)
    median_coherence = statistics.median(coherences)
    median_clipping = statistics.median(clipping_fractions)
    max_invalid = max(invalid_fractions)
    median_temporal_correlation = statistics.median(temporal_correlations) if temporal_correlations else 1.0
    median_temporal_mad = statistics.median(temporal_mads) if temporal_mads else 0.0
    details = (
        f"frames={requested_frames} resolution={width}x{height} pixel-format={pixel_format} "
        f"median-robust-span={median_span} median-green-stddev={median_deviation:.2f} "
        f"median-lag2-correlation={median_lag:.3f} median-block-coherence={median_coherence:.3f} "
        f"median-clipping={median_clipping:.4f} max-invalid-words={max_invalid:.4f} "
        f"median-temporal-correlation={median_temporal_correlation:.3f} "
        f"median-temporal-tile-mad={median_temporal_mad:.2f} "
        f"minimum-unique-rows={min(row_cardinalities)} unique-active-frames={len(digests)}"
    )
    if max_invalid > 0.001:
        return "FAIL", details + " gate=invalid-upper-bits"
    if len(digests) < 2:
        return "FAIL", details + " gate=frozen-active-pixels"
    if min(clipping_fractions) > 0.90:
        return "FAIL", details + " gate=severe-clipping"
    if all(
        span >= 512 and abs(lag) < 0.02 and coherence < 0.10
        for span, lag, coherence in zip(spans, lag_correlations, coherences)
    ):
        return "FAIL", details + " gate=unstructured-high-amplitude-noise"
    warning_gates = []
    if median_span < 16 or median_deviation < 1.0:
        warning_gates.append("flat-signal")
    if median_clipping > 0.25:
        warning_gates.append("clipping")
    if median_span >= 128 and median_lag < 0.08 and median_coherence < 0.15:
        warning_gates.append("weak-spatial-structure")
    if median_temporal_correlation < 0.10 and median_temporal_mad > 16:
        warning_gates.append("temporal-incoherence")
    if warning_gates:
        return "WARN", details + " gate=" + ",".join(warning_gates)
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
    analyze_stdin = len(sys.argv) == 8 and sys.argv[1] == "--analyze-stdin"
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
        pixel_format = sys.argv[7]
        payload = sys.stdin.buffer.read(frame_size * frames + 1)
        received = len(payload) // frame_size
        stream_status = "PASS" if received >= frames else "FAIL"
        stream_details = f"complete_frames={received} expected={frames}"
        signal_status, signal_details = analyze(
            payload, width, height, stride, frame_size, frames, pixel_format
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
                "--stream-skip=2",
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
            payload, width, height, stride, actual_frame_size, frames, pixel_format
        )
    else:
        signal_status = "SKIP"
        signal_details = "capture transport did not complete"
    emit(stream_status, signal_status, stream_details, signal_details)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
