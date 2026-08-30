#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Observe a complete wired-headset removal, insertion and button cycle."""

from __future__ import annotations

import argparse
import glob
import select
import time

# Stable Linux input-event ABI values. python-evdev is imported lazily only
# when the live device is opened, so the pure state machine remains testable on
# package builders without input hardware.
EV_KEY = 0x01
EV_SW = 0x05
SW_HEADPHONE_INSERT = 0x02
SW_MICROPHONE_INSERT = 0x04
KEY_VOLUMEDOWN = 114
KEY_VOLUMEUP = 115
KEY_PLAYPAUSE = 164
KEY_VOICECOMMAND = 582

EXPECTED_SWITCHES = {SW_HEADPHONE_INSERT, SW_MICROPHONE_INSERT}
EXPECTED_KEYS = {
    KEY_VOLUMEUP,
    KEY_VOLUMEDOWN,
    KEY_PLAYPAUSE,
    KEY_VOICECOMMAND,
}


class EventTracker:
    def __init__(self) -> None:
        self.switch_values = {code: set() for code in EXPECTED_SWITCHES}
        self.final_switch_values: dict[int, int] = {}
        self.button_presses = 0

    def observe(self, event_type: int, code: int, value: int) -> None:
        if event_type == EV_SW and code in EXPECTED_SWITCHES and value in {0, 1}:
            self.switch_values[code].add(value)
            self.final_switch_values[code] = value
        elif event_type == EV_KEY and code in EXPECTED_KEYS and value == 1:
            self.button_presses += 1

    def complete(self) -> bool:
        return (
            all(values == {0, 1} for values in self.switch_values.values())
            and all(self.final_switch_values.get(code) == 1 for code in EXPECTED_SWITCHES)
            and self.button_presses > 0
        )

    def details(self) -> str:
        headphone = self.switch_values[SW_HEADPHONE_INSERT]
        microphone = self.switch_values[SW_MICROPHONE_INSERT]
        final_headphone = self.final_switch_values.get(SW_HEADPHONE_INSERT, -1)
        final_microphone = self.final_switch_values.get(SW_MICROPHONE_INSERT, -1)
        return (
            f"headphone-values={','.join(map(str, sorted(headphone))) or 'none'} "
            f"microphone-values={','.join(map(str, sorted(microphone))) or 'none'} "
            f"button-presses={self.button_presses} "
            f"final-headphone={final_headphone} final-microphone={final_microphone}"
        )


def find_headset_device():
    from evdev import InputDevice

    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            device = InputDevice(path)
        except OSError:
            continue
        if device.name == "sof-cht yogabook Headset Jack":
            capabilities = device.capabilities(absinfo=False)
            if (
                EXPECTED_SWITCHES <= set(capabilities.get(EV_SW, []))
                and EXPECTED_KEYS <= set(capabilities.get(EV_KEY, []))
            ):
                return device
            device.close()
            raise RuntimeError("Yoga Book headset input capabilities are incomplete")
        device.close()
    raise RuntimeError("Yoga Book headset input device was not found")


def observe(timeout_seconds: int) -> tuple[bool, str]:
    device = find_headset_device()
    tracker = EventTracker()
    deadline = time.monotonic() + timeout_seconds
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([device.fd], [], [], min(0.5, deadline - time.monotonic()))
            if not ready:
                continue
            try:
                events = device.read()
            except BlockingIOError:
                continue
            for event in events:
                tracker.observe(event.type, event.code, event.value)
            if tracker.complete():
                return True, tracker.details()
        return False, tracker.details()
    finally:
        device.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    try:
        complete, details = observe(args.timeout)
    except (OSError, RuntimeError) as error:
        print(f"error={str(error).replace(chr(10), ' ')}")
        return 2
    print(details)
    return 0 if complete else 1


if __name__ == "__main__":
    raise SystemExit(main())
