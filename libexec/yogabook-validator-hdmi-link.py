#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Evaluate a Micro-HDMI video link and its negotiated ALSA ELD without playback."""

from __future__ import annotations

import argparse
from pathlib import Path


def clean(value: object) -> str:
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def emit(subsystem: str, check_id: str, status: str, summary: str, details: str = "") -> None:
    print("\t".join(clean(value) for value in (subsystem, check_id, status, summary, details)))


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def parse_eld(path: Path) -> dict[str, str]:
    values = {}
    for line in read(path).splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            values[parts[0]] = parts[1].strip()
    return values


def evaluate(connector: Path, asound_root: Path) -> int:
    status = read(connector / "status")
    enabled = read(connector / "enabled")
    modes = read(connector / "modes").splitlines()
    connector_name = connector.name

    if status == "disconnected":
        details = f"{connector_name} status=disconnected"
        emit("display", "hdmi-link", "SKIP", "No external Micro-HDMI display is connected", details)
        emit("audio", "hdmi-route", "SKIP", "Micro-HDMI audio negotiation requires a connected display", details)
        return 0

    if status != "connected":
        details = f"{connector_name} status={status or 'unreadable'} enabled={enabled or 'unreadable'}"
        emit("display", "hdmi-link", "FAIL", "Micro-HDMI connector state is unreadable", details)
        emit("audio", "hdmi-route", "FAIL", "Micro-HDMI audio route cannot be validated", details)
        return 1

    if enabled == "enabled" and modes:
        emit(
            "display",
            "hdmi-link",
            "PASS",
            "Connected Micro-HDMI display has an active mode",
            f"{connector_name} modes={','.join(modes)}",
        )
    else:
        emit(
            "display",
            "hdmi-link",
            "FAIL",
            "Connected Micro-HDMI display has no active video link",
            f"{connector_name} enabled={enabled or 'unreadable'} modes={','.join(modes) or 'none'}",
        )

    eld_paths = sorted(set(asound_root.glob("card*/eld*")) | set(asound_root.glob("*/eld*")))
    valid_eld = []
    for path in eld_paths:
        values = parse_eld(path)
        if values.get("monitor_present") == "1" and values.get("eld_valid") == "1":
            valid_eld.append((path, values))
    if valid_eld:
        path, values = valid_eld[0]
        monitor = values.get("monitor_name", "unnamed display")
        emit(
            "audio",
            "hdmi-route",
            "PASS",
            "Connected Micro-HDMI display negotiated a valid audio route",
            f"eld={path.name} monitor={monitor}",
        )
        return 0 if enabled == "enabled" and modes else 1

    emit(
        "audio",
        "hdmi-route",
        "FAIL",
        "Connected Micro-HDMI display has no valid ALSA ELD audio route",
        f"eld_files={len(eld_paths)}",
    )
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("connector", type=Path)
    parser.add_argument("asound_root", type=Path)
    args = parser.parse_args()
    return evaluate(args.connector, args.asound_root)


if __name__ == "__main__":
    raise SystemExit(main())
