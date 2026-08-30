#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "libexec" / "yogabook-validator-headset-events.py"
SPEC = importlib.util.spec_from_file_location("yogabook_validator_headset_events", HELPER)
assert SPEC and SPEC.loader
EVENTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVENTS)


class HeadsetEventTrackerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tracker = EVENTS.EventTracker()

    def switch(self, code: int, value: int) -> None:
        self.tracker.observe(EVENTS.EV_SW, code, value)

    def button(self, code: int = EVENTS.KEY_PLAYPAUSE) -> None:
        self.tracker.observe(EVENTS.EV_KEY, code, 1)

    def complete_cycle(self) -> None:
        for value in (0, 1):
            self.switch(EVENTS.SW_HEADPHONE_INSERT, value)
            self.switch(EVENTS.SW_MICROPHONE_INSERT, value)
        self.button()

    def test_complete_cycle_requires_removal_insertion_and_button(self) -> None:
        self.complete_cycle()
        self.assertTrue(self.tracker.complete())

    def test_switch_cycle_without_button_is_incomplete(self) -> None:
        for value in (0, 1):
            self.switch(EVENTS.SW_HEADPHONE_INSERT, value)
            self.switch(EVENTS.SW_MICROPHONE_INSERT, value)
        self.assertFalse(self.tracker.complete())

    def test_headset_must_finish_inserted(self) -> None:
        self.complete_cycle()
        self.switch(EVENTS.SW_HEADPHONE_INSERT, 0)
        self.switch(EVENTS.SW_MICROPHONE_INSERT, 0)
        self.assertFalse(self.tracker.complete())
        self.assertIn("final-headphone=0", self.tracker.details())

    def test_unrelated_keys_and_switches_do_not_count(self) -> None:
        self.tracker.observe(EVENTS.EV_KEY, 30, 1)  # KEY_A
        self.tracker.observe(EVENTS.EV_SW, 0, 0)  # SW_LID
        self.assertEqual(self.tracker.button_presses, 0)
        self.assertFalse(self.tracker.complete())


if __name__ == "__main__":
    unittest.main()
