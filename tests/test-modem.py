#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "libexec" / "yogabook-validator-modem.py"
SPEC = importlib.util.spec_from_file_location("yogabook_validator_modem", HELPER)
assert SPEC and SPEC.loader
MODEM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODEM)


def modem(*, sim: str = "/org/freedesktop/ModemManager1/SIM/0", state: str = "connected", registration: str = "home", bearers=None):
    return {
        "modem": {
            "generic": {
                "model": "XMM7260",
                "sim": sim,
                "state": state,
                "state-failed-reason": "--",
                "bearers": ["/org/freedesktop/ModemManager1/Bearer/0"] if bearers is None else bearers,
            },
            "3gpp": {"registration-state": registration},
        }
    }


def bearer(*, connected: str = "yes", interface: str = "wwp0s20u5", gateway: str = "10.0.0.1"):
    return {
        "bearer": {
            "status": {"connected": connected, "interface": interface},
            "ipv4-config": {"gateway": gateway},
        }
    }


ADDRESSES = [{"addr_info": [{"family": "inet", "scope": "global", "local": "10.0.0.2"}]}]


class ModemEvaluatorTest(unittest.TestCase):
    def test_missing_sim_skips_registration_and_traffic(self) -> None:
        payload = modem(sim="--", state="failed")
        payload["modem"]["generic"]["state-failed-reason"] = "sim-missing"
        results = MODEM.evaluate(payload, lambda _path: self.fail("bearer read"), lambda _dev: [], lambda _dev, _target: (False, ""))
        self.assertEqual([row[2] for row in results], ["SKIP", "SKIP"])

    def test_registered_connected_bearer_and_packet_replies_pass(self) -> None:
        probes = []
        results = MODEM.evaluate(
            modem(),
            lambda _path: bearer(),
            lambda _dev: ADDRESSES,
            lambda device, target: (probes.append((device, target)) is None, "replies=3/3"),
        )
        self.assertEqual([row[2] for row in results], ["PASS", "PASS"])
        self.assertEqual(probes, [("wwp0s20u5", "10.0.0.1")])

    def test_present_sim_without_registration_fails_both_layers(self) -> None:
        results = MODEM.evaluate(modem(state="enabled", registration="searching"), lambda _path: bearer(), lambda _dev: ADDRESSES, lambda _dev, _target: (True, ""))
        self.assertEqual([row[2] for row in results], ["FAIL", "FAIL"])

    def test_registered_modem_without_bearer_fails_traffic_only(self) -> None:
        results = MODEM.evaluate(modem(state="registered", bearers=[]), lambda _path: bearer(), lambda _dev: ADDRESSES, lambda _dev, _target: (True, ""))
        self.assertEqual([row[2] for row in results], ["PASS", "FAIL"])

    def test_connected_bearer_requires_configured_interface_address(self) -> None:
        results = MODEM.evaluate(modem(), lambda _path: bearer(), lambda _dev: [], lambda _dev, _target: (True, ""))
        self.assertEqual([row[2] for row in results], ["PASS", "FAIL"])
        self.assertIn("no configured global IPv4", results[1][3])


if __name__ == "__main__":
    unittest.main()
