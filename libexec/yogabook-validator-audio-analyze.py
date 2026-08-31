#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Classify a bounded stereo S16 WAV using transport-level signal metrics."""

from __future__ import annotations

import argparse
import math
from pathlib import Path
import struct
import wave


def analyze(path: Path, expected_seconds: float | None = None) -> tuple[str, str]:
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        width = wav.getsampwidth()
        rate = wav.getframerate()
        frame_count = wav.getnframes()
        payload = wav.readframes(frame_count)
    if channels != 2 or width != 2 or rate != 48000:
        return "FAIL", f"format={channels}ch/{width * 8}bit/{rate}Hz expected=2ch/16bit/48000Hz"
    if frame_count < rate or len(payload) != frame_count * channels * width:
        return "FAIL", f"frames={frame_count} bytes={len(payload)} expected-at-least={rate}"
    duration = frame_count / rate
    if expected_seconds is not None and abs(duration - expected_seconds) > 0.15:
        return "FAIL", f"duration={duration:.2f}s expected={expected_seconds:.2f}s tolerance=0.15s"

    samples = struct.unpack(f"<{len(payload) // 2}h", payload)
    metrics = []
    for channel in range(channels):
        values = samples[channel::channels]
        mean = sum(values) / len(values)
        ac_square = sum((value - mean) ** 2 for value in values) / len(values)
        rms = math.sqrt(ac_square)
        peak = max(abs(value) for value in values)
        clipped = sum(abs(value) >= 32760 for value in values) / len(values)
        metrics.append({"mean": mean, "rms": rms, "peak": peak, "clipped": clipped})

    quieter = min(item["rms"] for item in metrics)
    louder = max(item["rms"] for item in metrics)
    balance_db = 20 * math.log10(louder / quieter) if quieter > 0 else math.inf
    max_dc = max(abs(item["mean"]) / 32768 for item in metrics)
    max_clipped = max(item["clipped"] for item in metrics)
    min_peak = min(item["peak"] for item in metrics)
    min_rms = min(item["rms"] for item in metrics)
    details = (
        f"duration={duration:.2f}s "
        f"left-peak={metrics[0]['peak']} left-rms={metrics[0]['rms']:.2f} left-dc={metrics[0]['mean']:.2f} "
        f"right-peak={metrics[1]['peak']} right-rms={metrics[1]['rms']:.2f} right-dc={metrics[1]['mean']:.2f} "
        f"max-clipped={max_clipped:.6f} channel-imbalance={balance_db:.2f}dB"
    )
    failures = []
    warnings = []
    if min_peak < 32 or min_rms < 1:
        failures.append("empty-or-stuck-channel")
    if max_clipped >= 0.05:
        failures.append("clipping")
    if max_dc >= 0.10:
        failures.append("dc-offset")
    elif max_dc >= 0.03:
        warnings.append("dc-offset")
    if balance_db >= 20:
        failures.append("channel-imbalance")
    elif balance_db >= 12:
        warnings.append("channel-imbalance")
    if failures:
        return "FAIL", details + " gate=" + ",".join(failures)
    if warnings:
        return "WARN", details + " gate=" + ",".join(warnings)
    return "PASS", details


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", type=Path)
    parser.add_argument("--expected-seconds", type=float)
    args = parser.parse_args()
    try:
        status, details = analyze(args.wav, args.expected_seconds)
    except (OSError, EOFError, wave.Error, struct.error, ValueError) as exc:
        status, details = "FAIL", f"invalid-wav={type(exc).__name__}"
    print(f"{status}\t{details}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
