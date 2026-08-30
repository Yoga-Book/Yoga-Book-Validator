#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "libexec" / "yogabook-validator-controls-events.py"
SPEC = importlib.util.spec_from_file_location("yogabook_validator_controls_events", HELPER)
assert SPEC and SPEC.loader
EVENTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVENTS)


class ControlEventTrackerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tracker = EVENTS.EventTracker()

    def press(self, code: int) -> None:
        self.tracker.observe(EVENTS.EV_KEY, code, 1)

    def lid(self, value: int) -> None:
        self.tracker.observe(EVENTS.EV_SW, EVENTS.SW_LID, value)

    def test_complete_requires_every_button_and_ordered_lid_cycle(self) -> None:
        for code in (EVENTS.KEY_POWER, EVENTS.KEY_VOLUMEUP, EVENTS.KEY_VOLUMEDOWN):
            self.press(code)
        self.lid(1)
        self.lid(0)
        self.assertTrue(self.tracker.complete())
        self.assertTrue(all(self.tracker.statuses().values()))

    def test_initial_open_event_does_not_replace_close_reopen_cycle(self) -> None:
        self.lid(0)
        self.assertFalse(self.tracker.statuses()["lid-open-event"])
        self.lid(1)
        self.lid(0)
        self.assertTrue(self.tracker.statuses()["lid-open-event"])

    def test_key_releases_repeats_and_unrelated_keys_do_not_count(self) -> None:
        self.tracker.observe(EVENTS.EV_KEY, EVENTS.KEY_POWER, 0)
        self.tracker.observe(EVENTS.EV_KEY, EVENTS.KEY_POWER, 2)
        self.tracker.observe(EVENTS.EV_KEY, 30, 1)
        self.assertFalse(any(self.tracker.statuses().values()))

    def test_missing_one_event_is_incomplete_and_reported(self) -> None:
        self.press(EVENTS.KEY_POWER)
        self.press(EVENTS.KEY_VOLUMEUP)
        self.lid(1)
        self.lid(0)
        statuses = self.tracker.statuses()
        self.assertFalse(statuses["volume-down-event"])
        self.assertFalse(self.tracker.complete())


if __name__ == "__main__":
    unittest.main()
