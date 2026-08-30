#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Validate an existing XMM7260 LTE session without changing modem state."""

from __future__ import annotations

import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Callable


Evidence = tuple[str, str, str, str, str]
BearerLoader = Callable[[str], dict]
AddressLoader = Callable[[str], list]
Probe = Callable[[str, str], tuple[bool, str]]


def clean(value: object) -> str:
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def evidence(check_id: str, status: str, summary: str, details: str = "") -> Evidence:
    return ("modem", check_id, status, summary, details)


def nested(mapping: object, *keys: str, default: object = "") -> object:
    current = mapping
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def missing(value: object) -> bool:
    return value is None or str(value).strip().lower() in {"", "--", "unknown", "none"}


def connected(value: object) -> bool:
    return value is True or str(value).strip().lower() in {"yes", "true", "1"}


def valid_probe_target(value: object) -> str:
    try:
        address = ipaddress.ip_address(str(value))
    except ValueError:
        return "1.1.1.1"
    if address.version == 4 and not address.is_unspecified:
        return str(address)
    return "1.1.1.1"


def global_ipv4_count(payload: object) -> int:
    if not isinstance(payload, list):
        return 0
    return sum(
        1
        for interface in payload
        if isinstance(interface, dict)
        for address in interface.get("addr_info", [])
        if isinstance(address, dict)
        and address.get("family") == "inet"
        and address.get("scope") == "global"
    )


def evaluate(
    modem: dict,
    load_bearer: BearerLoader,
    load_addresses: AddressLoader,
    probe: Probe,
) -> list[Evidence]:
    generic = nested(modem, "modem", "generic", default={})
    threegpp = nested(modem, "modem", "3gpp", default={})
    if not isinstance(generic, dict) or not isinstance(threegpp, dict):
        return [
            evidence("registration", "FAIL", "ModemManager returned incomplete modem state"),
            evidence("ip-traffic", "FAIL", "LTE traffic cannot be validated without modem state"),
        ]

    model = str(generic.get("model", "unknown"))
    sim = generic.get("sim")
    failed_reason = str(generic.get("state-failed-reason", "")).lower()
    if missing(sim) or failed_reason == "sim-missing":
        details = f"model={model} sim=missing"
        return [
            evidence("registration", "SKIP", "No SIM is installed; LTE registration is not required", details),
            evidence("ip-traffic", "SKIP", "No SIM is installed; LTE packet transport is not required", details),
        ]

    registration = str(threegpp.get("registration-state", "unknown")).lower()
    modem_state = str(generic.get("state", "unknown")).lower()
    registration_ok = registration in {"home", "roaming"} and modem_state in {"registered", "connected"}
    registration_details = f"state={modem_state} registration={registration}"
    if not registration_ok:
        return [
            evidence("registration", "FAIL", "SIM is present but the LTE modem is not registered", registration_details),
            evidence("ip-traffic", "FAIL", "LTE packet transport requires a registered modem", registration_details),
        ]

    results = [
        evidence("registration", "PASS", "LTE modem is registered with the mobile network", registration_details)
    ]
    bearer_paths = generic.get("bearers", [])
    if not isinstance(bearer_paths, list) or not bearer_paths:
        results.append(evidence("ip-traffic", "FAIL", "Registered LTE modem has no data bearer"))
        return results

    active_bearer: dict | None = None
    bearer_path = ""
    for candidate in bearer_paths:
        loaded = load_bearer(str(candidate))
        if nested(loaded, "bearer", "status", "connected") is not None and connected(
            nested(loaded, "bearer", "status", "connected")
        ):
            active_bearer = loaded
            bearer_path = str(candidate)
            break
    if active_bearer is None:
        results.append(evidence("ip-traffic", "FAIL", "Registered LTE modem has no connected data bearer"))
        return results

    interface = str(nested(active_bearer, "bearer", "status", "interface", default=""))
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", interface):
        results.append(evidence("ip-traffic", "FAIL", "Connected LTE bearer has no valid network interface"))
        return results
    address_payload = load_addresses(interface)
    address_count = global_ipv4_count(address_payload)
    if address_count == 0:
        results.append(
            evidence(
                "ip-traffic",
                "FAIL",
                "Connected LTE bearer has no configured global IPv4 address",
                f"interface={interface}",
            )
        )
        return results

    gateway = nested(active_bearer, "bearer", "ipv4-config", "gateway", default="")
    target = valid_probe_target(gateway)
    probe_ok, probe_details = probe(interface, target)
    bearer_id = Path(bearer_path).name or "unknown"
    details = f"bearer={bearer_id} interface={interface} addresses={address_count} target={target} {probe_details}".strip()
    if probe_ok:
        results.append(evidence("ip-traffic", "PASS", "LTE bearer exchanged packets over its existing data session", details))
    else:
        results.append(evidence("ip-traffic", "FAIL", "LTE bearer did not return packets over its existing data session", details))
    return results


def run(command: list[str], timeout: int = 10) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    return subprocess.run(command, text=True, capture_output=True, timeout=timeout, env=environment)


def run_json(command: list[str]) -> tuple[object, str]:
    try:
        completed = run(command)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {}, clean(error)
    if completed.returncode != 0:
        return {}, clean(completed.stderr or completed.stdout or f"exit={completed.returncode}")
    try:
        return json.loads(completed.stdout), ""
    except json.JSONDecodeError as error:
        return {}, f"invalid JSON: {clean(error)}"


def emit_all(results: list[Evidence]) -> int:
    for row in results:
        print("\t".join(clean(value) for value in row))
    return 1 if any(row[2] == "FAIL" for row in results) else 0


def main() -> int:
    required = [command for command in ("mmcli", "ip", "ping") if shutil.which(command) is None]
    if required:
        details = f"missing={','.join(required)}"
        return emit_all([
            evidence("registration", "FAIL", "LTE validation dependencies are unavailable", details),
            evidence("ip-traffic", "FAIL", "LTE packet validation dependencies are unavailable", details),
        ])

    inventory, inventory_error = run_json(["mmcli", "-L", "-J"])
    modem_paths = inventory.get("modem-list", []) if isinstance(inventory, dict) else []
    if inventory_error or not isinstance(modem_paths, list) or not modem_paths:
        details = inventory_error or "modems=0"
        return emit_all([
            evidence("registration", "FAIL", "ModemManager does not expose an LTE modem", details),
            evidence("ip-traffic", "FAIL", "LTE packet transport cannot be validated without a modem", details),
        ])

    modem: dict | None = None
    modem_error = ""
    for modem_path in modem_paths:
        modem_id = Path(str(modem_path)).name
        candidate, candidate_error = run_json(["mmcli", "-m", modem_id, "-J"])
        if candidate_error or not isinstance(candidate, dict):
            modem_error = candidate_error
            continue
        model = str(nested(candidate, "modem", "generic", "model", default=""))
        if "XMM7260" in model:
            modem = candidate
            break
    if modem is None:
        return emit_all([
            evidence("registration", "FAIL", "ModemManager XMM7260 state is unavailable", modem_error),
            evidence("ip-traffic", "FAIL", "LTE packet transport cannot be validated without XMM7260 state", modem_error),
        ])

    def load_bearer(path: str) -> dict:
        payload, _error = run_json(["mmcli", "-b", Path(path).name, "-J"])
        return payload if isinstance(payload, dict) else {}

    def load_addresses(interface: str) -> list:
        payload, _error = run_json(["ip", "-j", "-4", "address", "show", "dev", interface])
        return payload if isinstance(payload, list) else []

    def probe(interface: str, target: str) -> tuple[bool, str]:
        try:
            completed = run(["ping", "-I", interface, "-c", "3", "-W", "2", target], timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return False, "replies=0/3"
        return completed.returncode == 0, "replies=3/3" if completed.returncode == 0 else "replies=0/3"

    return emit_all(evaluate(modem, load_bearer, load_addresses, probe))


if __name__ == "__main__":
    raise SystemExit(main())
