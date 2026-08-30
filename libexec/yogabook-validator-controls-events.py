#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Observe Yoga Book power, volume and lid events while suppressing actions."""

from __future__ import annotations

import argparse
import glob
import select
import time

# Stable Linux input-event ABI values. python-evdev is imported lazily so the
# state machine remains testable without access to physical input devices.
EV_KEY = 0x01
EV_SW = 0x05
SW_LID = 0x00
KEY_POWER = 116
KEY_VOLUMEDOWN = 114
KEY_VOLUMEUP = 115

EXPECTED_KEYS = {KEY_POWER, KEY_VOLUMEUP, KEY_VOLUMEDOWN}


class EventTracker:
    def __init__(self) -> None:
        self.keys: set[int] = set()
        self.lid_closed = False
        self.lid_reopened = False

    def observe(self, event_type: int, code: int, value: int) -> None:
        if event_type == EV_KEY and code in EXPECTED_KEYS and value == 1:
            self.keys.add(code)
        elif event_type == EV_SW and code == SW_LID and value == 1:
            self.lid_closed = True
        elif (
            event_type == EV_SW
            and code == SW_LID
            and value == 0
            and self.lid_closed
        ):
            self.lid_reopened = True

    def statuses(self) -> dict[str, bool]:
        return {
            "power-button-event": KEY_POWER in self.keys,
            "volume-up-event": KEY_VOLUMEUP in self.keys,
            "volume-down-event": KEY_VOLUMEDOWN in self.keys,
            "lid-close-event": self.lid_closed,
            "lid-open-event": self.lid_reopened,
        }

    def complete(self) -> bool:
        return all(self.statuses().values())

    def details(self) -> str:
        names = {
            KEY_POWER: "power",
            KEY_VOLUMEUP: "volume-up",
            KEY_VOLUMEDOWN: "volume-down",
        }
        pressed = ",".join(names[code] for code in sorted(self.keys)) or "none"
        return (
            f"pressed={pressed} lid-closed={str(self.lid_closed).lower()} "
            f"lid-reopened={str(self.lid_reopened).lower()}"
        )


def find_control_devices():
    from evdev import InputDevice

    buttons = []
    lids = []
    button_codes: set[int] = set()
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            device = InputDevice(path)
            capabilities = device.capabilities(absinfo=False)
        except OSError:
            continue
        if device.name == "gpio-keys":
            supported = EXPECTED_KEYS & set(capabilities.get(EV_KEY, []))
            if supported:
                buttons.append(device)
                button_codes.update(supported)
                continue
        if device.name == "Lid Switch" and SW_LID in capabilities.get(EV_SW, []):
            lids.append(device)
            continue
        device.close()
    if button_codes != EXPECTED_KEYS or len(lids) != 1:
        for device in buttons + lids:
            device.close()
        missing = ",".join(map(str, sorted(EXPECTED_KEYS - button_codes))) or "none"
        raise RuntimeError(
            f"control input topology is incomplete: missing-keys={missing} "
            f"lid-devices={len(lids)}"
        )
    return buttons + lids


def observe(timeout_seconds: int) -> tuple[EventTracker, bool, int]:
    devices = find_control_devices()
    grabbed = []
    tracker = EventTracker()
    cleanup_ok = True
    deadline = time.monotonic() + timeout_seconds
    try:
        for device in devices:
            device.grab()
            grabbed.append(device)
        print(
            "ACTION_REQUIRED: Press Power, Volume Up and Volume Down once, "
            "then close and reopen the lid. System actions are temporarily "
            "suppressed until the test completes.",
            flush=True,
        )
        while time.monotonic() < deadline and not tracker.complete():
            remaining = max(0.0, deadline - time.monotonic())
            ready, _, _ = select.select(
                [device.fd for device in devices], [], [], min(0.5, remaining)
            )
            for fd in ready:
                device = next(candidate for candidate in devices if candidate.fd == fd)
                try:
                    events = device.read()
                except BlockingIOError:
                    continue
                for event in events:
                    tracker.observe(event.type, event.code, event.value)
    finally:
        for device in reversed(grabbed):
            try:
                device.ungrab()
            except OSError:
                cleanup_ok = False
        for device in devices:
            device.close()
    return tracker, cleanup_ok, len(grabbed)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    try:
        tracker, cleanup_ok, grabbed = observe(args.timeout)
    except (OSError, RuntimeError) as error:
        print(f"error\t{str(error).replace(chr(10), ' ')}")
        return 2
    for check_id, passed in tracker.statuses().items():
        print(f"{check_id}\t{'PASS' if passed else 'FAIL'}")
    print(f"controls-release\t{'PASS' if cleanup_ok else 'FAIL'}")
    print(f"details\t{tracker.details()} grabbed-devices={grabbed}")
    return 0 if tracker.complete() and cleanup_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
