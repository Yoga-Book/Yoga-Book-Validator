#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Record synchronized Yoga Book mode, sensor and Mutter display state."""

from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import signal
import time

from gi.repository import Gio, GLib


DBUS_FLAGS = Gio.DBusCallFlags.NONE
running = True


def stop(_signum: int, _frame: object) -> None:
    global running
    running = False


def property_value(
    bus: Gio.DBusConnection,
    destination: str,
    path: str,
    interface: str,
    name: str,
) -> object:
    reply = bus.call_sync(
        destination,
        path,
        "org.freedesktop.DBus.Properties",
        "Get",
        GLib.Variant("(ss)", (interface, name)),
        GLib.VariantType("(v)"),
        DBUS_FLAGS,
        500,
        None,
    )
    return reply.unpack()[0]


def sensor_orientation(system_bus: Gio.DBusConnection) -> str:
    try:
        return str(
            property_value(
                system_bus,
                "net.hadess.SensorProxy",
                "/net/hadess/SensorProxy",
                "net.hadess.SensorProxy",
                "AccelerometerOrientation",
            )
        )
    except GLib.Error:
        return "unavailable"


def systemd_unit_path(system_bus: Gio.DBusConnection, unit: str) -> str | None:
    try:
        reply = system_bus.call_sync(
            "org.freedesktop.systemd1",
            "/org/freedesktop/systemd1",
            "org.freedesktop.systemd1.Manager",
            "GetUnit",
            GLib.Variant("(s)", (unit,)),
            GLib.VariantType("(o)"),
            DBUS_FLAGS,
            500,
            None,
        )
        return str(reply.unpack()[0])
    except GLib.Error:
        return None


def unit_state(system_bus: Gio.DBusConnection, unit_path: str | None) -> str:
    if unit_path is None:
        return "not-found"
    try:
        return str(
            property_value(
                system_bus,
                "org.freedesktop.systemd1",
                unit_path,
                "org.freedesktop.systemd1.Unit",
                "ActiveState",
            )
        )
    except GLib.Error:
        return "unavailable"


def mutter_state(session_bus: Gio.DBusConnection) -> tuple[str, str, str]:
    try:
        reply = session_bus.call_sync(
            "org.gnome.Mutter.DisplayConfig",
            "/org/gnome/Mutter/DisplayConfig",
            "org.gnome.Mutter.DisplayConfig",
            "GetCurrentState",
            None,
            None,
            DBUS_FLAGS,
            500,
            None,
        )
        _serial, monitors, logical_monitors, _properties = reply.unpack()
        current_modes = {
            spec[0]: next(
                (mode[0] for mode in modes if mode[6].get("is-current", False)),
                "unknown",
            )
            for spec, modes, _monitor_properties in monitors
        }
        for _x, _y, _scale, transform, _primary, specs, _props in logical_monitors:
            for spec in specs:
                if spec[0].startswith("DSI-"):
                    return spec[0], current_modes.get(spec[0], "unknown"), str(transform)
        return "missing", "unknown", "unknown"
    except GLib.Error:
        return "unavailable", "unknown", "unknown"


def input_names() -> set[str]:
    try:
        lines = Path("/proc/bus/input/devices").read_text(encoding="utf-8").splitlines()
    except OSError:
        return set()
    prefix = 'N: Name="'
    return {
        line[len(prefix) : -1]
        for line in lines
        if line.startswith(prefix) and line.endswith('"')
    }


def present(value: bool) -> str:
    return "1" if value else "0"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--interval", type=float, default=0.1)
    parser.add_argument("--stop-file", type=Path)
    args = parser.parse_args()
    if args.interval < 0.05:
        parser.error("--interval must be at least 0.05 seconds")

    system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    session_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    halo_unit = systemd_unit_path(system_bus, "halo-keyboard.service")

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    header = (
        "timestamp\tmonotonic_ms\tsensor_orientation\tconnector\tmode\ttransform\t"
        "halo_service\thalo_device\thalo_keyboard\thalo_touchpad\twacom_pen\n"
    )
    with args.output.open("w", encoding="utf-8", buffering=1) as stream:
        stream.write(header)
        while running and not (args.stop_file and args.stop_file.exists()):
            started = time.monotonic()
            names = input_names()
            connector, mode, transform = mutter_state(session_bus)
            row = (
                datetime.now().astimezone().isoformat(timespec="milliseconds"),
                str(time.monotonic_ns() // 1_000_000),
                sensor_orientation(system_bus),
                connector,
                mode,
                transform,
                unit_state(system_bus, halo_unit),
                present(Path("/dev/halo_keyboard").exists()),
                present("Halo Keyboard" in names),
                present("Halo Keyboard Touchpad" in names),
                present("Wacom HID 169 Pen" in names),
            )
            stream.write("\t".join(row) + "\n")
            remaining = args.interval - (time.monotonic() - started)
            if remaining > 0:
                time.sleep(remaining)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
