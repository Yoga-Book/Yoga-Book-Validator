#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Capture and compare privacy-safe hardware health around suspend/resume."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import time
from typing import Any


CORE_SERVICES = (
    "halo-keyboard.service",
    "yogabook-camera.service",
    "iio-sensor-proxy.service",
    "bluetooth.service",
    "ModemManager.service",
)


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return "unavailable"


def run(*argv: str, timeout: float = 5.0) -> tuple[int, str]:
    try:
        completed = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
        return completed.returncode, completed.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 127, "unavailable"


def service_active(name: str) -> bool:
    return run("systemctl", "is-active", "--quiet", name, timeout=3)[0] == 0


def check(applicable: bool, healthy: bool, details: str, fingerprint: str = "") -> dict[str, Any]:
    return {
        "applicable": applicable,
        "healthy": healthy,
        "details": details.replace("\t", " ").replace("\n", " "),
        "fingerprint": fingerprint,
    }


def capture() -> dict[str, Any]:
    checks: dict[str, dict[str, Any]] = {}

    drm = Path("/sys/class/drm")
    dsi = next(iter(sorted(drm.glob("card*-DSI-1"))), None)
    dsi_state = (
        f"{read(dsi / 'status')}/{read(dsi / 'enabled')}" if dsi is not None else "missing"
    )
    backlights = sorted(Path("/sys/class/backlight").glob("*/brightness"))
    checks["resume-display"] = check(
        True,
        dsi is not None and dsi_state == "connected/enabled" and bool(backlights),
        f"dsi={dsi_state} backlights={len(backlights)}",
        dsi.name if dsi is not None else "missing",
    )

    input_text = read(Path("/proc/bus/input/devices"))
    input_names = re.findall(r'^N: Name="([^"]+)"$', input_text, re.MULTILINE)
    selected = Counter(
        name
        for name in input_names
        if any(
            marker in name
            for marker in (
                "Halo Keyboard",
                "Halo Keyboard Touchpad",
                "Wacom HID 169 Pen",
                "Goodix Capacitive TouchScreen",
                "HDP0001:00 2ABB:8102",
                "Lid Switch",
                "gpio-keys",
            )
        )
    )
    required_input = (
        any("TouchScreen" in name or "2ABB:8102" in name for name in selected)
        and any("Lid Switch" in name for name in selected)
        and any(name == "gpio-keys" for name in selected)
        and (
            any("Halo Keyboard" in name for name in selected)
            or any("Wacom HID 169 Pen" in name for name in selected)
        )
    )
    input_fingerprint = json.dumps(sorted(selected.items()), separators=(",", ":"))
    checks["resume-inputs"] = check(
        True,
        required_input,
        f"selected-devices={sum(selected.values())}",
        input_fingerprint,
    )

    iio_names: list[str] = []
    raw_readable = 0
    for device in sorted(Path("/sys/bus/iio/devices").glob("iio:device*")):
        name = read(device / "name")
        if name != "unavailable":
            iio_names.append(name)
        for raw in device.glob("in_*_raw"):
            value = read(raw)
            if re.fullmatch(r"-?[0-9]+", value):
                raw_readable += 1
    iio_counts = Counter(iio_names)
    expected_iio = {"als": 2, "accel_3d": 4, "hinge": 2, "sx9310": 1}
    sensors_healthy = all(iio_counts[name] == count for name, count in expected_iio.items()) and raw_readable > 0
    checks["resume-sensors"] = check(
        True,
        sensors_healthy,
        f"devices={len(iio_names)} raw-readable={raw_readable}",
        json.dumps(sorted(iio_counts.items()), separators=(",", ":")),
    )

    wifi_interface = next(
        (path.parent.name for path in sorted(Path("/sys/class/net").glob("*/wireless"))),
        "",
    )
    wifi_healthy = False
    wifi_details = "interface=missing"
    if wifi_interface:
        state = read(Path("/sys/class/net") / wifi_interface / "operstate")
        route_rc, route = run("ip", "-4", "route", "show", "default", "dev", wifi_interface)
        gateway_match = re.search(r"\bvia ([0-9.]+)", route)
        ping_rc = 1
        if route_rc == 0 and gateway_match:
            ping_rc, _ = run(
                "ping", "-I", wifi_interface, "-c", "1", "-W", "2", gateway_match.group(1), timeout=4
            )
        wifi_healthy = state == "up" and route_rc == 0 and gateway_match is not None and ping_rc == 0
        wifi_details = f"interface={wifi_interface} state={state} route={route_rc} gateway-ping={ping_rc}"
    checks["resume-wifi"] = check(True, wifi_healthy, wifi_details, wifi_interface or "missing")

    bluetooth_nodes = sorted(Path("/sys/class/bluetooth").glob("hci*"))
    bluetooth_rc, bluetooth_output = run("bluetoothctl", "show", timeout=5)
    checks["resume-bluetooth"] = check(
        True,
        bool(bluetooth_nodes) and service_active("bluetooth.service") and bluetooth_rc == 0 and "Controller " in bluetooth_output,
        f"controllers={len(bluetooth_nodes)} service={service_active('bluetooth.service')} cli={bluetooth_rc}",
        ",".join(node.name for node in bluetooth_nodes),
    )

    camera_nodes = sorted(Path("/dev").glob("video*"))
    media_nodes = sorted(Path("/dev").glob("media*"))
    checks["resume-camera"] = check(
        True,
        bool(camera_nodes) and bool(media_nodes) and service_active("yogabook-camera.service"),
        f"video={len(camera_nodes)} media={len(media_nodes)} service={service_active('yogabook-camera.service')}",
        f"video={len(camera_nodes)};media={len(media_nodes)}",
    )

    battery = Path("/sys/class/power_supply/bq27542-0")
    charger = Path("/sys/class/power_supply/bq25890-charger-0")
    source = Path("/sys/class/power_supply/cht_wcove_pwrsrc")
    online, source_online = read(charger / "online"), read(source / "online")
    battery_temp, charger_temp = read(battery / "temp"), read(charger / "temp")
    power_healthy = (
        online in {"0", "1"}
        and online == source_online
        and read(charger / "health") == "Good"
        and re.fullmatch(r"-?[0-9]+", battery_temp) is not None
        and re.fullmatch(r"-?[0-9]+", charger_temp) is not None
        and -100 <= int(battery_temp) <= 450
        and -100 <= int(charger_temp) <= 700
    )
    checks["resume-power"] = check(
        True,
        power_healthy,
        f"online={online}/{source_online} battery-temp={battery_temp} charger-temp={charger_temp}",
        "bq27542+bq25892",
    )

    sd_devices = [
        path.parent.parent
        for path in Path("/sys/block").glob("mmcblk*/device/type")
        if read(path) == "SD"
    ]
    sd_healthy = False
    if sd_devices:
        device_path = Path("/dev") / sd_devices[0].name
        try:
            with device_path.open("rb", buffering=0) as stream:
                sd_healthy = len(stream.read(65536)) == 65536
        except OSError:
            sd_healthy = False
    checks["resume-storage"] = check(
        bool(sd_devices),
        sd_healthy,
        f"sd-devices={len(sd_devices)} bounded-read={sd_healthy}",
        ",".join(device.name for device in sd_devices),
    )

    modem_rc, modem_output = run("mmcli", "-L", timeout=5)
    modem_present = modem_rc == 0 and "/Modem/" in modem_output
    checks["resume-modem"] = check(
        modem_present,
        modem_present and service_active("ModemManager.service"),
        f"present={modem_present} service={service_active('ModemManager.service')}",
        "xmm7260" if modem_present else "absent",
    )

    gnss_runtime = Path("/var/lib/yogabook-gnss/root/system/vendor/bin/gpsd").is_file()
    gnss_healthy = gnss_runtime and service_active("yogabook-gnss.service")
    checks["resume-gnss"] = check(
        gnss_runtime,
        gnss_healthy,
        f"runtime={gnss_runtime} service={service_active('yogabook-gnss.service')}",
        "bcm4752" if gnss_runtime else "runtime-missing",
    )

    service_states = {name: service_active(name) for name in CORE_SERVICES}
    checks["resume-services"] = check(
        True,
        all(service_states.values()),
        " ".join(f"{name}={'active' if state else 'inactive'}" for name, state in service_states.items()),
        json.dumps(service_states, sort_keys=True, separators=(",", ":")),
    )
    return {"schema": "org.yogabook.validator.resume/v1", "captured_at": int(time.time()), "checks": checks}


LABELS = {
    "resume-display": "Display and backlight returned after resume",
    "resume-inputs": "Input topology returned after resume",
    "resume-sensors": "IIO sensors returned readable after resume",
    "resume-wifi": "Wi-Fi link and gateway traffic returned after resume",
    "resume-bluetooth": "Bluetooth controller returned after resume",
    "resume-camera": "Camera nodes and service returned after resume",
    "resume-power": "Battery and charger telemetry returned safely after resume",
    "resume-storage": "Inserted SD storage remained readable after resume",
    "resume-modem": "Present LTE modem returned after resume",
    "resume-gnss": "Installed GNSS transport returned after resume",
    "resume-services": "Critical integration services returned after resume",
}


def compare(before: dict[str, Any], after: dict[str, Any]) -> list[tuple[str, str, str, str]]:
    if before.get("schema") != "org.yogabook.validator.resume/v1" or after.get("schema") != before.get("schema"):
        raise ValueError("resume snapshot schema mismatch")
    rows: list[tuple[str, str, str, str]] = []
    before_checks = before.get("checks", {})
    after_checks = after.get("checks", {})
    if set(before_checks) != set(LABELS) or set(after_checks) != set(LABELS):
        raise ValueError("resume snapshot check set mismatch")
    for check_id, summary in LABELS.items():
        initial = before_checks[check_id]
        final = after_checks[check_id]
        if not initial.get("applicable", False):
            rows.append((check_id, "SKIP", f"{summary} was not applicable before suspend", str(initial.get("details", ""))))
        elif not initial.get("healthy", False):
            rows.append((check_id, "SKIP", f"{summary} could not be proven from an unhealthy baseline", str(initial.get("details", ""))))
        elif not final.get("applicable", False) or not final.get("healthy", False):
            rows.append((check_id, "FAIL", summary.replace(" returned", " did not return"), str(final.get("details", ""))))
        elif initial.get("fingerprint") != final.get("fingerprint"):
            rows.append((check_id, "FAIL", f"{summary}, but its topology changed", f"before={initial.get('fingerprint')} after={final.get('fingerprint')}"))
        else:
            rows.append((check_id, "PASS", summary, str(final.get("details", ""))))
    return rows


def self_test() -> int:
    healthy = {key: check(True, True, "ok", key) for key in LABELS}
    before = {"schema": "org.yogabook.validator.resume/v1", "checks": healthy}
    after = json.loads(json.dumps(before))
    assert all(row[1] == "PASS" for row in compare(before, after))
    after["checks"]["resume-camera"]["healthy"] = False
    assert dict((row[0], row[1]) for row in compare(before, after))["resume-camera"] == "FAIL"
    after = json.loads(json.dumps(before))
    before["checks"]["resume-storage"] = check(False, False, "absent")
    assert dict((row[0], row[1]) for row in compare(before, after))["resume-storage"] == "SKIP"
    before = {"schema": "org.yogabook.validator.resume/v1", "checks": healthy}
    after = json.loads(json.dumps(before))
    after["checks"]["resume-inputs"]["fingerprint"] = "changed"
    assert dict((row[0], row[1]) for row in compare(before, after))["resume-inputs"] == "FAIL"
    print("resume probe policy: PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--compare", nargs=2, type=Path, metavar=("BEFORE", "AFTER"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.capture is not None:
        args.capture.write_text(json.dumps(capture(), indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return 0
    if args.compare is not None:
        before = json.loads(args.compare[0].read_text(encoding="utf-8"))
        after = json.loads(args.compare[1].read_text(encoding="utf-8"))
        for row in compare(before, after):
            print("\t".join(value.replace("\t", " ").replace("\n", " ") for value in row))
        return 0
    parser.error("choose --capture, --compare or --self-test")


if __name__ == "__main__":
    raise SystemExit(main())
