#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Build deterministic human- and machine-readable Validator reports."""

from __future__ import annotations

import argparse
import csv
import fnmatch
import hashlib
import html
import json
import os
import re
import tempfile
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any


SCHEMA = "org.yogabook.validator.report/v1"
VALID_STATUSES = {"PASS", "FAIL", "WARN", "SKIP", "INFO"}
STATUS_ORDER = {"FAIL": 0, "WARN": 1, "SKIP": 2, "PASS": 3, "INFO": 4}
ACCEPTANCE_SCHEMA = "org.yogabook.validator.acceptance/v1"
ACCEPTANCE_LAYERS = ("structural", "functional", "physical")
ACCEPTANCE_STATUS_ORDER = {
    "FAIL": 0,
    "WARN": 1,
    "STALE": 2,
    "UNIMPLEMENTED": 3,
    "INCOMPLETE": 4,
    "NOT_RUN": 5,
    "PASS": 6,
}
REQUIRED_VALIDATED_PACKAGES = {
    "alsa-ucm-conf-yogabook",
    "gir1.2-mutter-18",
    "gnome-control-center",
    "gnome-control-center-data",
    "halo-keyboard",
    "libmutter-18-0",
    "mutter-common",
    "mutter-common-bin",
    "sof-topology-yogabook",
    "yogabook-camera",
    "yogabook-gnss",
    "yogabook-sensors",
    "yogabook-validator",
}
REQUIRED_KERNEL_PACKAGE_PREFIXES = ("linux-headers-", "linux-image-")

CHECK_GUIDANCE = {
    ("platform", "grub-default"): (
        "Confirm the saved GRUB entry and the next-boot default before relying on unattended recovery."
    ),
    ("gnss", "services"): (
        "Inspect yogabook-gnss.service and gpsd.socket status, then correlate their current-boot journals."
    ),
    ("gnss", "runtime-assets"): (
        "Build the private BCM4752 runtime from a legally obtained Lenovo Android 7.1.1 system image, then import the verified archive with yogabook-gnss-import."
    ),
    ("gnss", "nmea-pipe"): (
        "Verify that the GNSS transport service creates its NMEA pipe with the expected ownership before gpsd starts."
    ),
    ("gnss", "transport"): (
        "Run the GNSS health command directly and inspect the transport-service journal for the first failing prerequisite."
    ),
    ("camera", "atomisp"): (
        "Check the running kernel, bound AtomISP/sensor drivers, media graph, and current-boot camera errors before changing userspace."
    ),
    ("camera", "kernel-headers"): (
        "Install the linux-headers package matching the exact running kernel before rebuilding DKMS modules."
    ),
    ("camera", "v4l2loopback-module"): (
        "Rebuild v4l2loopback for the running kernel after its exact headers and build tree are installed."
    ),
    ("camera", "prepare-service"): (
        "Inspect yogabook-camera-prepare.service and its current-boot journal after confirming the matching v4l2loopback module."
    ),
    ("wireless", "bluetooth-features"): (
        "Capture bounded bluetoothctl capability properties and bluetoothd status; distinguish an unavailable controller from a genuinely missing capability."
    ),
    ("wireless", "bluetooth-scan"): (
        "Inspect rfkill, bluetooth.service and btmgmt discovery output while preserving the original radio state."
    ),
    ("wireless", "bluetooth-rf"): (
        "Retry in an environment with a nearby discoverable device after controller power and discovery are confirmed."
    ),
    ("wireless", "state-restore"): (
        "Restore the original rfkill and controller power state first; treat restoration failure as higher priority than scan coverage."
    ),
}

SUBSYSTEM_GUIDANCE = {
    "audio": "Inspect ALSA/UCM, PipeWire and WirePlumber evidence in this report before changing mixer state.",
    "camera": "Correlate media topology, bound drivers and current-boot kernel messages.",
    "display": "Correlate DRM connectors, Mutter state and current-boot i915 messages.",
    "gnss": "Correlate transport, gpsd and ModemManager state from the same boot.",
    "input": "Confirm the expected physical mode before treating an absent conditional device as a defect.",
    "platform": "Confirm the running kernel and persistent boot configuration, then inspect the cited platform evidence.",
    "power": "Compare kernel power-supply values with UPower and charger telemetry from the same sample.",
    "sensors": "Compare raw IIO channels with SensorProxy state and desktop policy.",
    "wireless": "Check rfkill, controller/service state and bounded command output without retaining nearby device identities.",
}

ACTION_DEFINITIONS = {
    "audit": {
        "title": "Run the passive hardware audit",
        "command": "yogabook-validator check",
        "interaction_class": "automatic",
        "safety_note": "Read-only audit of installed packages, boot policy, kernel devices and desktop integration.",
        "prerequisites": [],
    },
    "apt": {
        "title": "Verify software sources",
        "command": "yogabook-validator apt",
        "interaction_class": "automatic",
        "safety_note": "Uses isolated APT metadata directories and does not alter configured sources.",
        "prerequisites": [],
    },
    "platform": {
        "title": "Inspect platform health",
        "command": "yogabook-validator platform",
        "interaction_class": "automatic",
        "safety_note": "Read-only platform inspection; current-boot journal access may require authorization.",
        "prerequisites": [],
    },
    "display": {
        "title": "Inspect display transport",
        "command": "yogabook-validator display",
        "interaction_class": "automatic",
        "safety_note": "Inspects i915, connectors, Mutter and desktop policy without changing layout.",
        "prerequisites": [],
    },
    "hdmi": {
        "title": "Validate Micro-HDMI output",
        "command": "yogabook-validator display",
        "interaction_class": "external",
        "safety_note": "Inspects the existing link and audio route without changing the selected display layout.",
        "prerequisites": ["Connect a Micro-HDMI display and run Inspect display."],
    },
    "rotation": {
        "title": "Validate automatic rotation",
        "command": "yogabook-validator rotation --yes",
        "interaction_class": "guided",
        "safety_note": "Restores the original display orientation and lock policy on every exit path.",
        "prerequisites": ["Hold the tablet free to rotate through all four orientations."],
    },
    "inputs": {
        "title": "Inspect input capabilities",
        "command": "yogabook-validator inputs",
        "interaction_class": "automatic",
        "safety_note": "Reads capability maps without consuming input events.",
        "prerequisites": [],
    },
    "modes": {
        "title": "Validate keyboard and pen modes",
        "command": "yogabook-validator modes --yes",
        "interaction_class": "guided",
        "safety_note": "Verifies cleanup and returns the tablet to its initial Halo or pen mode.",
        "prerequisites": ["Be ready to switch from Halo mode to pen mode and back when prompted."],
    },
    "pen-mapping": {
        "title": "Validate rotated pen mapping",
        "command": "yogabook-validator pen-mapping --yes --timeout 240",
        "interaction_class": "guided",
        "safety_note": "Uses stylus-only targets and restores the initial display and input mode.",
        "prerequisites": ["Have the Yoga Book pen available and leave enough room to rotate the tablet."],
    },
    "pen-stack": {
        "title": "Inspect automatic pen mapping stack",
        "command": "yogabook-validator pen-stack",
        "interaction_class": "automatic",
        "safety_note": "Read-only inspection; does not inject input or change Halo/Wacom mode.",
        "prerequisites": [],
    },
    "controls": {
        "title": "Validate buttons and lid events",
        "command": "yogabook-validator controls --yes",
        "interaction_class": "guided",
        "safety_note": "Temporarily suppresses desktop actions, releases every input grab and verifies cleanup.",
        "prerequisites": ["Press only the control requested by each prompt."],
    },
    "haptics": {
        "title": "Validate Halo haptics",
        "command": "yogabook-validator haptics --yes",
        "interaction_class": "automatic",
        "safety_note": "Pulses each actuator for 150 ms and restores its original state.",
        "prerequisites": [],
    },
    "audio": {
        "title": "Validate speakers and microphones",
        "command": "yogabook-validator audio --yes",
        "interaction_class": "automatic",
        "safety_note": "Caps playback to the minimum audible level and restores ALSA and desktop audio state.",
        "prerequisites": [],
    },
    "headset": {
        "title": "Validate the wired headset path",
        "command": "yogabook-validator headset --yes --timeout 90",
        "interaction_class": "guided",
        "safety_note": "Caps playback volume and restores the original audio route and mixer state.",
        "prerequisites": ["Connect a four-pole headset and follow the unplug, reinsert and button prompts."],
    },
    "camera": {
        "title": "Validate both cameras",
        "command": "yogabook-validator camera --yes",
        "interaction_class": "automatic",
        "safety_note": "Captures bounded transient frames, analyzes signal and restores the original media route.",
        "prerequisites": ["Leave both camera views unobstructed and reasonably lit."],
    },
    "lights": {
        "title": "Validate platform lights",
        "command": "yogabook-validator lights --yes",
        "interaction_class": "automatic",
        "safety_note": "Snapshots and restores every exercised brightness value.",
        "prerequisites": [],
    },
    "wireless": {
        "title": "Validate Wi-Fi and Bluetooth",
        "command": "yogabook-validator wireless --yes",
        "interaction_class": "automatic",
        "safety_note": "Does not pair or retain peer identities and restores Bluetooth and rfkill state.",
        "prerequisites": ["Keep Wi-Fi connected; place a discoverable Bluetooth peer nearby for RF coverage."],
    },
    "usb": {
        "title": "Inspect USB topology",
        "command": "yogabook-validator usb",
        "interaction_class": "automatic",
        "safety_note": "Read-only inspection of controllers, hubs, role state and attached transports.",
        "prerequisites": [],
    },
    "usb-cycle": {
        "title": "Validate a USB OTG cycle",
        "command": "yogabook-validator usb-cycle --yes --timeout 90",
        "interaction_class": "guided",
        "safety_note": "Performs a bounded descriptor or storage read and restores the original cable and role state.",
        "prerequisites": ["Start disconnected and have one USB OTG accessory ready."],
    },
    "storage": {
        "title": "Inspect the SD card",
        "command": "yogabook-validator storage --yes",
        "interaction_class": "automatic",
        "safety_note": "Reads block data and mounts unmounted filesystems read-only, then restores mount state.",
        "prerequisites": ["Insert the SD card to be validated."],
    },
    "storage-write": {
        "title": "Validate SD-card writes",
        "command": "yogabook-validator storage-write --yes",
        "interaction_class": "automatic",
        "safety_note": "Writes, verifies, synchronizes and removes one bounded file, then restores mount state.",
        "prerequisites": ["Insert a writable SD card with a supported filesystem."],
    },
    "internal-storage": {
        "title": "Validate internal storage I/O",
        "command": "yogabook-validator internal-storage --yes",
        "interaction_class": "automatic",
        "safety_note": "Uses one bounded 4 MiB non-zero probe and verifies removal plus directory synchronization.",
        "prerequisites": [],
    },
    "power": {
        "title": "Inspect power telemetry",
        "command": "yogabook-validator power",
        "interaction_class": "automatic",
        "safety_note": "Read-only correlation of kernel, charger and desktop power telemetry.",
        "prerequisites": [],
    },
    "charging": {
        "title": "Observe a charging session",
        "command": "yogabook-validator charging",
        "interaction_class": "guided",
        "safety_note": "Samples telemetry without changing charging policy.",
        "prerequisites": ["Connect the charger unless the battery already reports a stable full state."],
    },
    "sensors": {
        "title": "Validate every sensor channel",
        "command": "yogabook-validator sensors",
        "interaction_class": "automatic",
        "safety_note": "Read-only sampling of IIO channels and SensorProxy state.",
        "prerequisites": [],
    },
    "sensor-interactions": {
        "title": "Measure physical sensor responses",
        "command": "yogabook-validator sensor-interactions --yes --timeout 120",
        "interaction_class": "guided",
        "safety_note": "Reads IIO channels without changing sensor or desktop policy and discards raw samples.",
        "prerequisites": ["Leave room to shade the sensors and move the hinge when prompted."],
    },
    "resources": {
        "title": "Profile service resource safeguards",
        "command": "yogabook-validator resources",
        "interaction_class": "automatic",
        "safety_note": "Profiles bounded CPU and memory use without changing service configuration.",
        "prerequisites": [],
    },
    "modem": {
        "title": "Validate the existing LTE session",
        "command": "yogabook-validator modem",
        "interaction_class": "external",
        "safety_note": "Never enables, connects or disconnects the modem; traffic is bounded to three packets.",
        "prerequisites": ["Insert a working SIM and establish an LTE bearer before running the check."],
    },
    "gnss": {
        "title": "Validate GNSS transport and fix",
        "command": "yogabook-validator gnss --require-fix",
        "interaction_class": "external",
        "safety_note": "Reads bounded GNSS samples and does not retain unrelated location history.",
        "prerequisites": ["Import a legally obtained BCM4752 runtime and move outdoors with a clear sky."],
    },
    "suspend": {
        "title": "Validate suspend and resume",
        "command": "yogabook-validator suspend 8 --yes",
        "interaction_class": "guided",
        "safety_note": "Snapshots state, validates cleanup after resume and keeps playback at minimum audible level.",
        "prerequisites": ["Save open work and keep the charger state unchanged during the test."],
    },
    "stability": {
        "title": "Complete three cold-boot validations",
        "command": "yogabook-validator stability start 3",
        "interaction_class": "physical",
        "safety_note": "The Validator never reboots or powers off the tablet; each boot must be operator initiated.",
        "prerequisites": ["After each full power-off/on, run yogabook-validator stability check."],
    },
    "physical": {
        "title": "Record physical acceptance observations",
        "command": "yogabook-validator physical",
        "interaction_class": "physical",
        "safety_note": "Records operator observations without claiming that software inferred them.",
        "prerequisites": ["Personally observe each requested behavior on this Validator release."],
    },
    "inspect-selector": {
        "title": "Inspect an unrouted acceptance selector",
        "command": "yogabook-validator passive",
        "interaction_class": "external",
        "safety_note": "Fallback route: inspect the detailed report and Validator version before adding evidence.",
        "prerequisites": ["A Validator maintainer must map this selector to an explicit workflow."],
    },
    "recapture-evidence": {
        "title": "Recapture trustworthy validation evidence",
        "command": "yogabook-validator passive",
        "interaction_class": "automatic",
        "safety_note": (
            "Do not promote conclusions from this report. The trusted passive workflow "
            "captures a new evidence directory without executing report-provided command text."
        ),
        "prerequisites": [
            "Inspect and resolve every evidence-integrity problem before relying on acceptance results."
        ],
    },
}

SELECTOR_ACTION_RULES = (
    ("suite/stability", "stability"),
    ("physical/cold-boots", "stability"),
    ("display/rotation-policy", "display"),
    ("display/rotation-*", "rotation"),
    ("display/panel-backlight", "lights"),
    ("input/pen-mapping-*", "pen-mapping"),
    ("input/pen-dynamic-calibration", "pen-stack"),
    ("input/halo-keyboard", "audit"),
    ("input/halo-touchpad", "audit"),
    ("input/halo-*-capabilities", "inputs"),
    ("input/haptic-capabilities", "inputs"),
    ("input/pen-display-mapping", "pen-stack"),
    ("input/*-button-event", "controls"),
    ("input/volume-*-event", "controls"),
    ("input/lid-*-event", "controls"),
    ("input/controls-release", "controls"),
    ("input/headset-events", "headset"),
    ("audio/headset-*", "headset"),
    ("display/hdmi-link", "hdmi"),
    ("audio/hdmi-*", "hdmi"),
    ("usb/cycle-*", "usb-cycle"),
    ("usb/removable-device", "usb-cycle"),
    ("suite/storage-write", "storage-write"),
    ("storage/root-file-io", "internal-storage"),
    ("storage/discard-maintenance", "platform"),
    ("storage/root-kernel-errors", "platform"),
    ("platform/leds", "lights"),
    ("platform/halo-backlight", "lights"),
    ("platform/indicator-led", "lights"),
    ("platform/charging-led", "lights"),
    ("platform/state-restore", "lights"),
    ("platform/package-integrity", "audit"),
    ("platform/grub-default", "audit"),
    ("platform/failed-units", "audit"),
    ("platform/kernel-errors", "audit"),
    ("suspend/*", "suspend"),
    ("gnss/*", "gnss"),
    ("modem/*", "modem"),
    ("wireless/*", "wireless"),
    ("camera/*", "camera"),
    ("audio/*", "audio"),
    ("input/haptic-*", "haptics"),
    ("input/keyboard-returned", "modes"),
    ("input/halo-*", "modes"),
    ("input/pen-*", "modes"),
    ("input/touchscreen-*", "modes"),
    ("input/*", "inputs"),
    ("display/*", "display"),
    ("sensors/ambient-light-response", "sensor-interactions"),
    ("sensors/proximity-response", "sensor-interactions"),
    ("sensors/hinge-response", "sensor-interactions"),
    ("sensors/*", "sensors"),
    ("resources/*", "resources"),
    ("thermal/*", "resources"),
    ("power/charge-*", "charging"),
    ("power/charger-*", "charging"),
    ("power/*", "power"),
    ("storage/sd-*", "storage"),
    ("storage/*", "platform"),
    ("usb/*", "usb"),
    ("platform/apt-*", "apt"),
    ("platform/*", "platform"),
    ("physical/*", "physical"),
)


def atomic_write(path: Path, content: str) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        reference = path.parent / "results.tsv"
        if reference.is_file():
            os.chmod(temporary, reference.stat().st_mode & 0o666)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def file_evidence(path: Path) -> dict[str, Any]:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"file": path.name, "bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def parse_key_values(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    values: dict[str, str] = {}
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.reader(stream, delimiter="\t"):
            if len(row) >= 2 and row[0]:
                if row[0] == "key" and row[1] == "value":
                    continue
                values[row[0]] = row[1]
    return values


def parse_package_inventory(path: Path) -> list[dict[str, str]]:
    packages = []
    seen = set()
    with path.open(newline="", encoding="utf-8") as stream:
        for line_number, row in enumerate(csv.reader(stream, delimiter="\t"), start=1):
            if len(row) != 3 or not all(value.strip() for value in row):
                raise ValueError(f"{path}:{line_number}: malformed package identity")
            package, version, architecture = (value.strip() for value in row)
            if package in seen:
                raise ValueError(f"{path}:{line_number}: duplicate package identity {package}")
            seen.add(package)
            packages.append({"package": package, "version": version, "architecture": architecture})
    return sorted(packages, key=lambda item: item["package"])


def debian_upstream_version(version: str) -> str:
    without_epoch = version.split(":", 1)[-1]
    return without_epoch.rsplit("-", 1)[0] if "-" in without_epoch else without_epoch


def package_inventory_status(
    packages: list[dict[str, str]], declared_validator_version: str | None
) -> dict[str, Any]:
    captured_names = {item["package"] for item in packages}
    expected_names = set(REQUIRED_VALIDATED_PACKAGES)
    kernel_matches: dict[str, list[str]] = {}
    for prefix in REQUIRED_KERNEL_PACKAGE_PREFIXES:
        matches = sorted(name for name in captured_names if name.startswith(prefix))
        kernel_matches[prefix] = matches
        if len(matches) == 1:
            expected_names.add(matches[0])

    missing = sorted(REQUIRED_VALIDATED_PACKAGES.difference(captured_names))
    for prefix, matches in kernel_matches.items():
        if len(matches) != 1:
            missing.append(f"{prefix}<running-kernel-release>")
    unexpected = sorted(captured_names.difference(expected_names))
    kernel_releases = {
        matches[0][len(prefix) :]
        for prefix, matches in kernel_matches.items()
        if len(matches) == 1
    }
    kernel_release_consistent = (
        all(len(matches) == 1 for matches in kernel_matches.values())
        and len(kernel_releases) == 1
    )
    problems = []
    if all(len(matches) == 1 for matches in kernel_matches.values()) and not kernel_release_consistent:
        problems.append("kernel header and image package releases do not match")
    validator_package = next(
        (item for item in packages if item["package"] == "yogabook-validator"), None
    )
    installed_validator_version = validator_package["version"] if validator_package else None
    validator_version_matches = bool(
        declared_validator_version
        and installed_validator_version
        and debian_upstream_version(installed_validator_version) == declared_validator_version
    )
    if not declared_validator_version:
        problems.append("Validator version is missing from validator.log")
    elif installed_validator_version and not validator_version_matches:
        problems.append(
            "installed yogabook-validator package version "
            f"{installed_validator_version} does not match report version {declared_validator_version}"
        )
    complete = (
        not missing
        and not unexpected
        and kernel_release_consistent
        and validator_version_matches
        and len(packages) == 15
    )
    return {
        "expected": 15,
        "captured": len(packages),
        "complete": complete,
        "missing": missing,
        "unexpected": unexpected,
        "kernel_release_consistent": kernel_release_consistent,
        "declared_validator_version": declared_validator_version,
        "installed_validator_version": installed_validator_version,
        "validator_version_matches": validator_version_matches,
        "problems": problems,
        "packages": packages,
    }


def parse_log(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8", errors="replace")
    patterns = {
        "version": r"^Yoga Book Validator (.+)$",
        "command": r"^Command: (.+)$",
        "started": r"^Started: (.+)$",
        "finished": r"^Finished: (.+)$",
        "automated_result": r"^AUTOMATED_RESULT: (.+)$",
        "physical_result": r"^PHYSICAL_ACCEPTANCE_RESULT: (.+)$",
    }
    result: dict[str, Any] = {}
    for key, pattern in patterns.items():
        matches = re.findall(pattern, text, flags=re.MULTILINE)
        if matches:
            result[key] = matches[-1]
    try:
        started = datetime.fromisoformat(result["started"])
        finished = datetime.fromisoformat(result["finished"])
        result["duration_seconds"] = max(0, round((finished - started).total_seconds(), 3))
    except (KeyError, ValueError):
        result["duration_seconds"] = None
    return result


def parse_results(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    required = {"timestamp", "subsystem", "check_id", "status", "summary", "details"}
    rows: list[dict[str, str]] = []
    problems: list[str] = []
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        missing = required.difference(reader.fieldnames or [])
        if missing:
            raise ValueError(f"results.tsv is missing columns: {', '.join(sorted(missing))}")
        for line_number, source in enumerate(reader, start=2):
            row = {key: (source.get(key) or "").strip() for key in required}
            if row["status"] not in VALID_STATUSES:
                problems.append(f"line {line_number}: unknown status {row['status']!r}")
                continue
            if not row["subsystem"] or not row["check_id"] or not row["summary"]:
                problems.append(f"line {line_number}: missing subsystem, check_id or summary")
                continue
            row["kind"] = "suite-rollup" if row["subsystem"] == "suite" else "check"
            rows.append(row)
    return rows, problems


def load_acceptance_matrix() -> tuple[dict[str, Any], Path]:
    configured = os.environ.get("YBV_ACCEPTANCE_MATRIX")
    candidates = [
        Path(configured) if configured else None,
        Path(__file__).resolve().parents[1] / "data" / "acceptance.json",
        Path("/usr/share/yogabook-validator/acceptance.json"),
    ]
    path = next((candidate for candidate in candidates if candidate and candidate.is_file()), None)
    if path is None:
        raise FileNotFoundError("acceptance matrix is unavailable")
    with path.open(encoding="utf-8") as stream:
        matrix = json.load(stream)
    if matrix.get("schema") != ACCEPTANCE_SCHEMA or not isinstance(matrix.get("components"), list):
        raise ValueError("acceptance matrix has an unsupported schema")
    ids = [component.get("id") for component in matrix["components"]]
    if not ids or any(not item for item in ids) or len(ids) != len(set(ids)):
        raise ValueError("acceptance matrix component IDs must be present and unique")
    for component in matrix["components"]:
        layers = component.get("layers", {})
        for layer in ACCEPTANCE_LAYERS:
            selectors = layers.get(layer)
            if not isinstance(selectors, list) or not selectors or any("/" not in item for item in selectors):
                raise ValueError(f"acceptance component {component['id']} has invalid {layer} selectors")
    declared_selectors = {
        selector
        for component in matrix["components"]
        for layer in ACCEPTANCE_LAYERS
        for selector in component["layers"][layer]
    }
    freshness_policies = matrix.get("freshness_policies", {})
    if not isinstance(freshness_policies, dict):
        raise ValueError("acceptance matrix freshness_policies must be an object")
    for pattern, policy in freshness_policies.items():
        if (
            not isinstance(pattern, str)
            or "/" not in pattern
            or not isinstance(policy, dict)
            or set(policy) != {"max_age_hours"}
            or not isinstance(policy.get("max_age_hours"), int)
            or isinstance(policy.get("max_age_hours"), bool)
            or not 1 <= policy["max_age_hours"] <= 8760
        ):
            raise ValueError(f"acceptance matrix has invalid freshness policy for {pattern!r}")
        if not any(fnmatch.fnmatchcase(selector, pattern) for selector in declared_selectors):
            raise ValueError(f"freshness policy {pattern} does not match a declared selector")
    for selector in declared_selectors:
        matching = [pattern for pattern in freshness_policies if fnmatch.fnmatchcase(selector, pattern)]
        if matching:
            best_specificity = max(
                sum(character not in "*?[" for character in pattern) for pattern in matching
            )
            best = [
                pattern for pattern in matching
                if sum(character not in "*?[" for character in pattern) == best_specificity
            ]
        else:
            best = []
        if len(best) > 1:
            raise ValueError(
                f"equally specific freshness policies overlap for {selector}: {', '.join(sorted(best))}"
            )
    unimplemented = matrix.get("unimplemented_selectors", [])
    if not isinstance(unimplemented, list) or any(selector not in declared_selectors for selector in unimplemented):
        raise ValueError("acceptance matrix has invalid unimplemented selectors")
    contracts = matrix.get("selector_contracts", {})
    if not isinstance(contracts, dict):
        raise ValueError("acceptance matrix selector_contracts must be an object")
    wildcard_selectors = {selector for selector in declared_selectors if any(char in selector for char in "*?[")}
    if set(contracts) != wildcard_selectors:
        missing = sorted(wildcard_selectors.difference(contracts))
        unknown = sorted(set(contracts).difference(wildcard_selectors))
        raise ValueError(
            "acceptance matrix selector contracts do not match wildcard selectors: "
            f"missing={','.join(missing) or 'none'} unknown={','.join(unknown) or 'none'}"
        )
    for selector, contract in contracts.items():
        if not isinstance(contract, dict):
            raise ValueError(f"selector contract {selector} must be an object")
        allowed_contract_keys = {
            "required_match_ids",
            "optional_match_ids",
            "allow_additional_matches",
            "minimum_matches",
            "maximum_matches",
        }
        unknown_keys = sorted(set(contract).difference(allowed_contract_keys))
        if unknown_keys:
            raise ValueError(
                f"selector contract {selector} has unknown keys: {', '.join(unknown_keys)}"
            )
        required = contract.get("required_match_ids", [])
        optional = contract.get("optional_match_ids", [])
        allow_additional = contract.get("allow_additional_matches")
        minimum = contract.get("minimum_matches")
        maximum = contract.get("maximum_matches")
        if (
            not isinstance(required, list)
            or not isinstance(optional, list)
            or any(not isinstance(item, str) or not item for item in required + optional)
            or len(required) != len(set(required))
            or len(optional) != len(set(optional))
            or set(required).intersection(optional)
        ):
            raise ValueError(f"selector contract {selector} has invalid match IDs")
        if any(not fnmatch.fnmatchcase(item, selector) for item in required + optional):
            raise ValueError(f"selector contract {selector} contains an ID outside its pattern")
        if not isinstance(allow_additional, bool):
            raise ValueError(f"selector contract {selector} must declare allow_additional_matches")
        if not required and minimum is None:
            raise ValueError(f"selector contract {selector} must declare required IDs or minimum_matches")
        if minimum is not None and (not isinstance(minimum, int) or isinstance(minimum, bool) or minimum < 1):
            raise ValueError(f"selector contract {selector} has invalid minimum_matches")
        if maximum is not None and (not isinstance(maximum, int) or isinstance(maximum, bool) or maximum < 1):
            raise ValueError(f"selector contract {selector} has invalid maximum_matches")
        effective_minimum = minimum if minimum is not None else len(required)
        if maximum is not None and (maximum < effective_minimum or maximum < len(required)):
            raise ValueError(f"selector contract {selector} has inconsistent cardinality")
        if not allow_additional and not required and not optional:
            raise ValueError(f"selector contract {selector} rejects every possible match")
        if not allow_additional and effective_minimum > len(required) + len(optional):
            raise ValueError(f"selector contract {selector} cannot satisfy minimum_matches")
    return matrix, path


def build_acceptance(rows: list[dict[str, str]], as_of: datetime) -> dict[str, Any]:
    matrix, matrix_path = load_acceptance_matrix()
    unimplemented_catalog = set(matrix.get("unimplemented_selectors", []))
    observations: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        observations[f"{row['subsystem']}/{row['check_id']}"].append(row)

    def observation_time(row: dict[str, str]) -> datetime | None:
        source = row["timestamp"]
        if row.get("subsystem") == "physical":
            marker = re.search(r"(?:^|\s)provenance_observed_at=([^\s]+)", row.get("details", ""))
            if marker:
                source = marker.group(1)
        try:
            value = datetime.fromisoformat(source)
        except (TypeError, ValueError):
            return None
        return value if value.tzinfo is not None else None

    def freshness_policy(check_id: str) -> tuple[str, int] | None:
        matching = [
            (
                sum(character not in "*?[" for character in pattern),
                pattern,
                policy["max_age_hours"],
            )
            for pattern, policy in matrix.get("freshness_policies", {}).items()
            if fnmatch.fnmatchcase(check_id, pattern)
        ]
        if not matching:
            return None
        best_specificity = max(item[0] for item in matching)
        best = [item for item in matching if item[0] == best_specificity]
        if len(best) > 1:
            raise ValueError(f"multiple equally specific freshness policies match {check_id}")
        return best[0][1], best[0][2]

    def selector_evidence(selector: str) -> dict[str, Any] | None:
        matched = []
        for check_id, check_rows in observations.items():
            if not fnmatch.fnmatchcase(check_id, selector):
                continue
            statuses = [row["status"] for row in check_rows]
            status = min(statuses, key=lambda value: STATUS_ORDER[value])
            policy = freshness_policy(check_id)
            observed_times = [value for row in check_rows if (value := observation_time(row))]
            observed_at = max(observed_times) if observed_times else None
            age_seconds = max(0, int((as_of - observed_at).total_seconds())) if observed_at else None
            max_age_hours = policy[1] if policy else None
            freshness = "NOT_APPLICABLE"
            expires_at = None
            if policy:
                freshness = "UNKNOWN" if observed_at is None else (
                    "STALE" if age_seconds is not None and age_seconds > max_age_hours * 3600 else "FRESH"
                )
                if observed_at is not None:
                    expires_at = (observed_at + timedelta(hours=max_age_hours)).isoformat(timespec="seconds")
            if status == "SKIP":
                status = "INCOMPLETE"
            elif status == "INFO":
                status = "INCOMPLETE"
            elif status == "PASS" and freshness in {"STALE", "UNKNOWN"}:
                status = "STALE"
            matched.append(
                {
                    "id": check_id,
                    "status": status,
                    "observations": len(check_rows),
                    "observed_statuses": statuses,
                    "freshness": freshness,
                    "freshness_policy": policy[0] if policy else None,
                    "observed_at": observed_at.isoformat(timespec="seconds") if observed_at else None,
                    "age_seconds": age_seconds,
                    "max_age_hours": max_age_hours,
                    "expires_at": expires_at,
                    "blocked_by": sorted(
                        {
                            match.group(1)
                            for row in check_rows
                            if (match := re.search(r"(?:^|\s)blocked_by=([^\s]+)", row.get("details", "")))
                        }
                    ),
                }
            )
        if not matched:
            return None
        contract = matrix.get("selector_contracts", {}).get(selector)
        required = list(contract.get("required_match_ids", [])) if contract else []
        optional = list(contract.get("optional_match_ids", [])) if contract else []
        matched_ids = {item["id"] for item in matched}
        missing = sorted(set(required).difference(matched_ids))
        unexpected = []
        below_minimum = False
        above_maximum = False
        if contract:
            if not contract["allow_additional_matches"]:
                unexpected = sorted(matched_ids.difference(required).difference(optional))
            minimum = contract.get("minimum_matches", len(required))
            maximum = contract.get("maximum_matches")
            below_minimum = len(matched_ids) < minimum
            above_maximum = maximum is not None and len(matched_ids) > maximum
        status = min(
            (item["status"] for item in matched),
            key=lambda value: ACCEPTANCE_STATUS_ORDER[value],
        )
        if status not in {"FAIL", "WARN"} and (missing or unexpected or below_minimum or above_maximum):
            status = "INCOMPLETE"
        return {
            "selector": selector,
            "status": status,
            "matched_count": len(matched_ids),
            "required_match_ids": required,
            "missing_match_ids": missing,
            "unexpected_match_ids": unexpected,
            "minimum_matches": contract.get("minimum_matches") if contract else None,
            "maximum_matches": contract.get("maximum_matches") if contract else None,
            "blocked_by": sorted(
                {dependency for item in matched for dependency in item.get("blocked_by", [])}
            ),
            "stale_matches": [
                {
                    "id": item["id"],
                    "observed_at": item["observed_at"],
                    "expires_at": item["expires_at"],
                    "age_seconds": item["age_seconds"],
                    "max_age_hours": item["max_age_hours"],
                }
                for item in matched
                if item.get("freshness") == "STALE"
            ],
            "matches": matched,
        }

    components = []
    for source in matrix["components"]:
        layers = {}
        for layer_name in ACCEPTANCE_LAYERS:
            evidence = []
            missing = []
            unimplemented = []
            for selector in source["layers"][layer_name]:
                item = selector_evidence(selector)
                if item is None:
                    if selector in unimplemented_catalog:
                        unimplemented.append(selector)
                    else:
                        missing.append(selector)
                else:
                    evidence.append(item)
            statuses = [item["status"] for item in evidence]
            if "FAIL" in statuses:
                status = "FAIL"
            elif "WARN" in statuses:
                status = "WARN"
            elif "STALE" in statuses:
                status = "STALE"
            elif unimplemented:
                status = "UNIMPLEMENTED"
            elif "INCOMPLETE" in statuses:
                status = "INCOMPLETE"
            elif missing:
                status = "NOT_RUN"
            else:
                status = "PASS"
            layers[layer_name] = {
                "status": status,
                "required_selectors": source["layers"][layer_name],
                "missing_selectors": missing,
                "unimplemented_selectors": unimplemented,
                "evidence": evidence,
            }
        overall = min(
            (layers[layer]["status"] for layer in ACCEPTANCE_LAYERS),
            key=lambda value: ACCEPTANCE_STATUS_ORDER[value],
        )
        components.append({"id": source["id"], "name": source["name"], "status": overall, "layers": layers})

    counts = Counter(component["status"] for component in components)
    complete = counts["PASS"]
    total = len(components)
    layer_readiness = {}
    for layer_name in ACCEPTANCE_LAYERS:
        layer_counts = Counter(component["layers"][layer_name]["status"] for component in components)
        layer_complete = layer_counts["PASS"]
        layer_readiness[layer_name] = {
            "components_complete": layer_complete,
            "components_total": total,
            "readiness_percent": round(layer_complete / total * 100, 1) if total else 0.0,
            "counts": {
                status: layer_counts[status]
                for status in ("PASS", "FAIL", "WARN", "STALE", "UNIMPLEMENTED", "INCOMPLETE", "NOT_RUN")
            },
        }
    return {
        "schema": matrix["schema"],
        "matrix": file_evidence(matrix_path),
        "summary": {
            "components_total": total,
            "components_complete": complete,
            "readiness_percent": round(complete / total * 100, 1) if total else 0.0,
            "counts": {
                status: counts[status]
                for status in ("PASS", "FAIL", "WARN", "STALE", "UNIMPLEMENTED", "INCOMPLETE", "NOT_RUN")
            },
            "layers": layer_readiness,
            "note": "A component is complete only when structural, functional and physical layers all pass.",
        },
        "components": components,
    }


def severity_for(row: dict[str, str]) -> str:
    if row["status"] == "WARN":
        return "medium"
    if row["check_id"].endswith("state-restore") or "restore" in row["summary"].lower():
        return "critical"
    return "high"


def guidance_for(row: dict[str, str]) -> str:
    return CHECK_GUIDANCE.get(
        (row["subsystem"], row["check_id"]),
        SUBSYSTEM_GUIDANCE.get(
            row["subsystem"],
            "Inspect the cited evidence and validator.log from this same run before changing the system.",
        ),
    )


def build_model(directory: Path) -> dict[str, Any]:
    results_path = directory / "results.tsv"
    log_path = directory / "validator.log"
    if not results_path.is_file() or not log_path.is_file():
        raise FileNotFoundError("report directory must contain results.tsv and validator.log")

    rows, data_problems = parse_results(results_path)
    log = parse_log(log_path)
    parsed_started = None
    parsed_finished = None
    timestamp_problems = []
    try:
        parsed_started = datetime.fromisoformat(log["started"]) if log.get("started") else None
        parsed_finished = datetime.fromisoformat(log["finished"]) if log.get("finished") else None
        if (parsed_started and parsed_started.tzinfo is None) or (parsed_finished and parsed_finished.tzinfo is None):
            raise ValueError("run timestamp lacks a timezone")
    except (TypeError, ValueError) as exc:
        timestamp_problems.append(f"invalid run timestamp: {exc}")
    report_as_of = parsed_finished or datetime.now().astimezone()
    for row in rows:
        try:
            observed = datetime.fromisoformat(row["timestamp"])
            if observed.tzinfo is None:
                raise ValueError("timestamp lacks a timezone")
            if observed > report_as_of + timedelta(minutes=5):
                raise ValueError("timestamp is more than five minutes after report completion")
            if log.get("command") != "dossier" and parsed_started and observed < parsed_started - timedelta(minutes=5):
                raise ValueError("timestamp predates run start by more than five minutes")
            if row.get("subsystem") == "physical":
                marker = re.search(
                    r"(?:^|\s)provenance_observed_at=([^\s]+)", row.get("details", "")
                )
                if marker:
                    provenance_time = datetime.fromisoformat(marker.group(1))
                    if provenance_time.tzinfo is None:
                        raise ValueError("provenance timestamp lacks a timezone")
                    if provenance_time > observed + timedelta(minutes=5):
                        raise ValueError("provenance timestamp is later than its confirmation")
        except (TypeError, ValueError) as exc:
            timestamp_problems.append(
                f"{row['subsystem']}/{row['check_id']} has an invalid observation timestamp: {exc}"
            )
    environment = parse_key_values(directory / "environment.tsv")
    package_inventory = parse_package_inventory(directory / "validated-packages.tsv")
    checks = [row for row in rows if row["kind"] == "check"]
    rollups = [row for row in rows if row["kind"] == "suite-rollup"]
    grouped_checks: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in checks:
        grouped_checks[(row["subsystem"], row["check_id"])].append(row)
    aggregate_rank = {"FAIL": 0, "WARN": 1, "PASS": 2, "INFO": 3, "SKIP": 4}
    aggregated_checks: list[dict[str, Any]] = []
    inconsistencies = []
    for (subsystem, check_id), observations in sorted(grouped_checks.items()):
        selected = min(observations, key=lambda row: aggregate_rank[row["status"]])
        aggregate: dict[str, Any] = dict(selected)
        statuses = [row["status"] for row in observations]
        aggregate["observation_count"] = len(observations)
        aggregate["observed_statuses"] = statuses
        aggregate["observations"] = observations
        aggregated_checks.append(aggregate)
        if len(set(statuses)) > 1:
            inconsistencies.append(
                {
                    "id": f"{subsystem}/{check_id}",
                    "statuses": statuses,
                    "timestamps": [row["timestamp"] for row in observations],
                    "note": "The same check produced different outcomes during this run; inspect execution-stage evidence.",
                }
            )
    counts = Counter(row["status"] for row in aggregated_checks)
    rollup_counts = Counter(row["status"] for row in rollups)
    subsystem_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in aggregated_checks:
        subsystem_rows[row["subsystem"]].append(row)

    subsystems = []
    for name, subsystem_checks in sorted(subsystem_rows.items()):
        subsystem_counts = Counter(row["status"] for row in subsystem_checks)
        if subsystem_counts["FAIL"]:
            health = "FAIL"
        elif subsystem_counts["WARN"]:
            health = "WARN"
        elif subsystem_counts["SKIP"]:
            health = "INCOMPLETE"
        elif subsystem_counts["INFO"] and not subsystem_counts["PASS"]:
            health = "INCOMPLETE"
        else:
            health = "PASS"
        subsystems.append({"name": name, "health": health, "counts": dict(subsystem_counts)})

    findings = []
    for row in sorted(
        (row for row in aggregated_checks if row["status"] in {"FAIL", "WARN"}),
        key=lambda item: (STATUS_ORDER[item["status"]], item["subsystem"], item["check_id"]),
    ):
        findings.append(
            {
                "id": f"{row['subsystem']}/{row['check_id']}",
                "severity": severity_for(row),
                "status": row["status"],
                "summary": row["summary"],
                "evidence": row["details"] or "No additional detail was emitted.",
                "recommended_action": guidance_for(row),
                "timestamp": row["timestamp"],
                "observation_count": row["observation_count"],
                "observed_statuses": row["observed_statuses"],
            }
        )

    total = len(aggregated_checks)
    exercised = total - counts["SKIP"]
    check_result = "FAIL" if counts["FAIL"] else "PASS"
    if not counts["FAIL"] and counts["WARN"]:
        check_result = "PASS_WITH_WARNINGS"
    inventory_status = package_inventory_status(package_inventory, log.get("version"))
    integrity_problems = []
    if not total:
        integrity_problems.append("no valid independent check was recorded")
    if data_problems:
        integrity_problems.append(f"{len(data_problems)} malformed result row(s) were rejected")
    if timestamp_problems:
        integrity_problems.append(f"{len(timestamp_problems)} observation or run timestamp(s) are invalid")
    if inconsistencies:
        integrity_problems.append(f"{len(inconsistencies)} check(s) have conflicting observations")
    if not inventory_status["complete"]:
        integrity_problems.append("validated package inventory is incomplete or inconsistent")
    if not log.get("started") or not log.get("finished"):
        integrity_problems.append("run start or finish metadata is missing")
    state_rows = [
        row for row in aggregated_checks
        if row["subsystem"] == "validator" and row["check_id"] == "state-preservation"
    ]
    if len(state_rows) != 1 or state_rows[0]["status"] != "PASS":
        integrity_problems.append("validator/state-preservation is missing or did not pass")
    declared_result = log.get("automated_result")
    if not declared_result:
        integrity_problems.append("AUTOMATED_RESULT is missing")
    elif declared_result != check_result and not (
        declared_result == "PASS" and check_result == "PASS_WITH_WARNINGS"
    ):
        integrity_problems.append(
            f"AUTOMATED_RESULT={declared_result} disagrees with independent checks={check_result}"
        )
    integrity = {
        "status": "FAIL" if integrity_problems else "PASS",
        "problems": integrity_problems,
        "data_rows_rejected": len(data_problems),
        "conflicting_checks": len(inconsistencies),
        "state_preservation": state_rows[0]["status"] if len(state_rows) == 1 else "MISSING",
        "package_inventory_complete": inventory_status["complete"],
        "run_finished": bool(log.get("finished")),
    }
    derived_result = "FAIL" if check_result == "FAIL" or integrity_problems else check_result
    acceptance = build_acceptance(rows, report_as_of)
    for component in acceptance["components"]:
        component["blockers"] = []
        for layer_name, layer in component["layers"].items():
            layer["blockers"] = acceptance_layer_blocker_records(layer)
            component["blockers"].extend(
                {"layer": layer_name, **blocker} for blocker in layer["blockers"]
            )
        root_blockers = [blocker for blocker in component["blockers"] if not blocker.get("blocked_by")]
        for blocker in root_blockers:
            blocker["blocked_selectors"] = sorted(
                dependent["selector"]
                for dependent in component["blockers"]
                if blocker["selector"] in dependent.get("blocked_by", [])
            )
        component["root_blockers"] = root_blockers
    acceptance["execution_plan"] = build_execution_plan(acceptance["components"], integrity)
    acceptance["integrity"] = integrity
    acceptance["summary"]["evidence_integrity"] = integrity["status"]
    acceptance["summary"]["completion_ready"] = (
        integrity["status"] == "PASS"
        and acceptance["summary"]["components_complete"] == acceptance["summary"]["components_total"]
    )
    acceptance["summary"]["overall_status"] = (
        "FAIL" if integrity["status"] == "FAIL"
        else "PASS" if acceptance["summary"]["completion_ready"]
        else "INCOMPLETE"
    )
    model = {
        "schema": SCHEMA,
        "generated_at": log.get("finished") or datetime.now().astimezone().isoformat(timespec="seconds"),
        "validator": {"version": log.get("version", "unknown")},
        "run": {
            "command": log.get("command", "unknown"),
            "started": log.get("started"),
            "finished": log.get("finished"),
            "duration_seconds": log.get("duration_seconds"),
            "automated_result": log.get("automated_result", check_result),
            "physical_acceptance_result": log.get("physical_result", "PENDING"),
        },
        "summary": {
            "result": derived_result,
            "checks_total": total,
            "observations_total": len(checks),
            "repeated_observations": len(checks) - total,
            "checks_exercised": exercised,
            "coverage_percent": round((exercised / total * 100), 1) if total else 0.0,
            "counts": {status: counts[status] for status in ("PASS", "FAIL", "WARN", "SKIP", "INFO")},
            "suite_rollups": {
                "total": len(rollups),
                "counts": {status: rollup_counts[status] for status in ("PASS", "FAIL", "WARN", "SKIP", "INFO")},
                "note": "Suite roll-ups are excluded from check totals to avoid double-counting root findings.",
            },
        },
        "acceptance": acceptance,
        "environment": environment,
        "package_inventory": inventory_status,
        "integrity": integrity,
        "subsystems": subsystems,
        "findings": findings,
        "inconsistencies": inconsistencies,
        "skipped_checks": [row for row in aggregated_checks if row["status"] == "SKIP"],
        "checks": sorted(
            aggregated_checks,
            key=lambda row: (STATUS_ORDER[row["status"]], row["subsystem"], row["check_id"]),
        ),
        "results": sorted(
            rows,
            key=lambda row: (row["kind"] != "check", STATUS_ORDER[row["status"]], row["subsystem"], row["check_id"]),
        ),
        "data_quality": {
            "valid_rows": len(rows),
            "problems": data_problems,
            "repeated_check_observations": len(checks) - total,
            "inconsistent_checks": len(inconsistencies),
            "timestamp_problems": timestamp_problems,
        },
        "evidence": [
            file_evidence(path)
            for name in (
                "results.tsv",
                "validator.log",
                "environment.tsv",
                "validated-packages.tsv",
                "state-before.tsv",
                "state-after.tsv",
                "state-diff.txt",
                "physical-results.tsv",
                "sources.tsv",
                "observations.tsv",
            )
            if (path := directory / name).is_file()
        ],
    }
    return model


def markdown_escape(value: Any) -> str:
    rendered = str(value if value is not None else "").replace("\n", " ")
    for character in ("\\", "`", "*", "_", "[", "]", "|", "<", ">"):
        rendered = rendered.replace(character, f"\\{character}")
    return rendered


def acceptance_layer_blockers(layer: dict[str, Any]) -> list[str]:
    details = list(layer["missing_selectors"])
    details.extend(f"unimplemented: {selector}" for selector in layer["unimplemented_selectors"])
    for item in layer["evidence"]:
        if item["status"] == "PASS":
            continue
        contract_details = []
        if item.get("missing_match_ids"):
            contract_details.append(f"missing {','.join(item['missing_match_ids'])}")
        if item.get("unexpected_match_ids"):
            contract_details.append(f"unexpected {','.join(item['unexpected_match_ids'])}")
        if item.get("stale_matches"):
            contract_details.append(
                "expired " + ",".join(match["id"] for match in item["stale_matches"])
            )
        minimum = item.get("minimum_matches")
        maximum = item.get("maximum_matches")
        count = item.get("matched_count")
        if minimum is not None and count is not None and count < minimum:
            contract_details.append(f"matches {count}, minimum {minimum}")
        if maximum is not None and count is not None and count > maximum:
            contract_details.append(f"matches {count}, maximum {maximum}")
        suffix = f" ({'; '.join(contract_details)})" if contract_details else ""
        details.append(f"{item['selector']}={item['status']}{suffix}")
    return details


def acceptance_selector_action_id(selector: str) -> str:
    selector = selector.removeprefix("unimplemented: ").split("=", 1)[0]
    matching = [
        (sum(character not in "*?[" for character in pattern), pattern, action_id)
        for pattern, action_id in SELECTOR_ACTION_RULES
        if fnmatch.fnmatchcase(selector, pattern)
    ]
    if not matching:
        return "inspect-selector"
    best_specificity = max(item[0] for item in matching)
    best = [item for item in matching if item[0] == best_specificity]
    action_ids = {item[2] for item in best}
    if len(action_ids) != 1:
        patterns = ", ".join(item[1] for item in best)
        raise ValueError(f"multiple equally specific action routes match {selector}: {patterns}")
    return best[0][2]


def acceptance_selector_action(selector: str) -> str:
    action = ACTION_DEFINITIONS[acceptance_selector_action_id(selector)]
    prerequisites = " ".join(action["prerequisites"])
    suffix = f" Prerequisites: {prerequisites}" if prerequisites else ""
    return f"{action['title']}. Run `{action['command']}`.{suffix}"


def build_execution_plan(
    components: list[dict[str, Any]], integrity: dict[str, Any] | None = None
) -> dict[str, Any]:
    grouped: dict[str, dict[str, Any]] = {}
    declared_selectors = {
        selector
        for component in components
        for layer in component["layers"].values()
        for selector in layer["required_selectors"]
    }
    unmapped_selectors = sorted(
        selector
        for selector in declared_selectors
        if acceptance_selector_action_id(selector) == "inspect-selector"
    )
    if integrity is not None and integrity.get("status") == "FAIL":
        definition = ACTION_DEFINITIONS["recapture-evidence"]
        component_ids = sorted(component["id"] for component in components)
        action = {
            "id": "recapture-evidence",
            "title": definition["title"],
            "command": definition["command"],
            "interaction_class": definition["interaction_class"],
            "safety_note": definition["safety_note"],
            "prerequisites": list(definition["prerequisites"]),
            "selectors": [],
            "blocked_selectors": [],
            "components": component_ids,
            "statuses": ["FAIL"],
            "status": "FAIL",
            "reasons": sorted(set(integrity.get("problems", []))),
            "components_affected": len(component_ids),
            "selectors_affected": 0,
            "prerequisite_required": True,
            "acceptance_blocking": True,
        }
        return {
            "schema": "org.yogabook.validator.execution-plan/v1",
            "selectors_total": len(declared_selectors),
            "mapping_complete": not unmapped_selectors,
            "unmapped_selectors": unmapped_selectors,
            "actions_total": 1,
            "components_affected": len(component_ids),
            "counts_by_interaction": {
                "automatic": 1,
                "guided": 0,
                "physical": 0,
                "external": 0,
            },
            "integrity_blocking": True,
            "actions": [action],
        }
    for component in components:
        for blocker in component.get("root_blockers", component.get("blockers", [])):
            action_id = blocker["action_id"]
            action = ACTION_DEFINITIONS[action_id]
            record = grouped.setdefault(
                action_id,
                {
                    "id": action_id,
                    "title": action["title"],
                    "command": action["command"],
                    "interaction_class": action["interaction_class"],
                    "safety_note": action["safety_note"],
                    "prerequisites": list(action["prerequisites"]),
                    "selectors": set(),
                    "blocked_selectors": set(),
                    "components": set(),
                    "statuses": set(),
                    "reasons": set(),
                },
            )
            record["selectors"].add(blocker["selector"])
            record["blocked_selectors"].update(blocker.get("blocked_selectors", []))
            record["components"].add(component["id"])
            record["statuses"].add(blocker["status"])
            if blocker.get("reason"):
                record["reasons"].add(blocker["reason"])

    interaction_order = {"automatic": 0, "guided": 1, "physical": 2, "external": 3}
    actions = []
    for record in grouped.values():
        statuses = sorted(
            record.pop("statuses"),
            key=lambda value: ACCEPTANCE_STATUS_ORDER[value],
        )
        record["status"] = statuses[0]
        record["statuses"] = statuses
        for key in ("selectors", "blocked_selectors", "components", "reasons"):
            record[key] = sorted(record[key])
        record["components_affected"] = len(record["components"])
        record["selectors_affected"] = len(
            set(record["selectors"]).union(record["blocked_selectors"])
        )
        record["prerequisite_required"] = bool(record["prerequisites"])
        actions.append(record)
    actions.sort(
        key=lambda item: (
            interaction_order[item["interaction_class"]],
            STATUS_ORDER.get(item["status"], ACCEPTANCE_STATUS_ORDER.get(item["status"], 99)),
            item["title"],
            item["id"],
        )
    )
    counts = Counter(action["interaction_class"] for action in actions)
    return {
        "schema": "org.yogabook.validator.execution-plan/v1",
        "selectors_total": len(declared_selectors),
        "mapping_complete": not unmapped_selectors,
        "unmapped_selectors": unmapped_selectors,
        "actions_total": len(actions),
        "components_affected": len(
            {component_id for action in actions for component_id in action["components"]}
        ),
        "counts_by_interaction": {
            interaction: counts[interaction]
            for interaction in ("automatic", "guided", "physical", "external")
        },
        "integrity_blocking": False,
        "actions": actions,
    }


def acceptance_layer_blocker_records(layer: dict[str, Any]) -> list[dict[str, Any]]:
    records = []
    for selector in layer["missing_selectors"]:
        records.append(
            {
                "selector": selector,
                "status": "NOT_RUN",
                "reason": "No matching evidence was recorded.",
                "action_id": acceptance_selector_action_id(selector),
                "recommended_action": acceptance_selector_action(selector),
            }
        )
    for selector in layer["unimplemented_selectors"]:
        records.append(
            {
                "selector": selector,
                "status": "UNIMPLEMENTED",
                "reason": "The acceptance matrix declares this evidence unavailable.",
                "action_id": acceptance_selector_action_id(selector),
                "recommended_action": acceptance_selector_action(selector),
            }
        )
    for item in layer["evidence"]:
        if item["status"] == "PASS":
            continue
        reasons = []
        if item.get("missing_match_ids"):
            reasons.append(f"Missing matches: {', '.join(item['missing_match_ids'])}.")
        if item.get("unexpected_match_ids"):
            reasons.append(f"Unexpected matches: {', '.join(item['unexpected_match_ids'])}.")
        if item.get("stale_matches"):
            stale = item["stale_matches"]
            reasons.append(
                "Evidence expired: "
                + ", ".join(
                    f"{match['id']} observed {match['observed_at']} expired {match['expires_at']}"
                    for match in stale
                )
                + "."
            )
        minimum = item.get("minimum_matches")
        maximum = item.get("maximum_matches")
        count = item.get("matched_count")
        if minimum is not None and count is not None and count < minimum:
            reasons.append(f"Observed {count} distinct matches; at least {minimum} are required.")
        if maximum is not None and count is not None and count > maximum:
            reasons.append(f"Observed {count} distinct matches; at most {maximum} are allowed.")
        if not reasons:
            reasons.append(f"Observed acceptance status is {item['status']}.")
        records.append(
            {
                "selector": item["selector"],
                "status": item["status"],
                "reason": " ".join(reasons),
                "action_id": acceptance_selector_action_id(item["selector"]),
                "recommended_action": acceptance_selector_action(item["selector"]),
                "matched_count": item.get("matched_count"),
                "missing_match_ids": item.get("missing_match_ids", []),
                "unexpected_match_ids": item.get("unexpected_match_ids", []),
                "blocked_by": item.get("blocked_by", []),
                "stale_matches": item.get("stale_matches", []),
            }
        )
    return records


def render_markdown(model: dict[str, Any]) -> str:
    run = model["run"]
    summary = model["summary"]
    counts = summary["counts"]
    acceptance = model["acceptance"]
    readiness = acceptance["summary"]
    inventory = model["package_inventory"]
    integrity = model["integrity"]
    lines = [
        "# Yoga Book Validator diagnostic report",
        "",
        f"**Result:** {summary['result']}  ",
        f"**Command:** `{markdown_escape(run['command'])}`  ",
        f"**Started:** {markdown_escape(run['started'])}  ",
        f"**Duration:** {markdown_escape(run['duration_seconds'])} seconds  ",
        f"**Physical acceptance:** {markdown_escape(run['physical_acceptance_result'])}",
        "",
        "## Executive summary",
        "",
        f"{summary['checks_total']} unique checks across {summary['observations_total']} observations: **{counts['PASS']} passed**, "
        f"**{counts['FAIL']} failed**, **{counts['WARN']} warnings**, "
        f"**{counts['SKIP']} skipped**. Coverage: **{summary['coverage_percent']}%**.",
        "Suite roll-up rows are not counted twice in these totals.",
        "",
        "## Evidence integrity gate",
        "",
        f"Status: **{integrity['status']}**. State preservation: "
        f"**{integrity['state_preservation']}**. Package inventory complete: "
        f"**{str(integrity['package_inventory_complete']).lower()}**. Run finished: "
        f"**{str(integrity['run_finished']).lower()}**.",
        "",
        f"Problems: **{'; '.join(integrity['problems']) or 'none'}**.",
        "",
        "## Validated package inventory",
        "",
        f"Captured **{inventory['captured']} of {inventory['expected']}** required package identities. "
        f"Complete: **{str(inventory['complete']).lower()}**.",
        "",
        f"Missing: **{', '.join(inventory['missing']) or 'none'}**. "
        f"Unexpected: **{', '.join(inventory['unexpected']) or 'none'}**.",
        "",
        f"Inventory problems: **{', '.join(inventory['problems']) or 'none'}**.",
        "",
        "| Package | Version | Architecture |",
        "|---|---|---|",
        *(
            f"| `{markdown_escape(item['package'])}` | `{markdown_escape(item['version'])}` | "
            f"`{markdown_escape(item['architecture'])}` |"
            for item in inventory["packages"]
        ),
        "",
        "## Device acceptance readiness",
        "",
        f"**{readiness['components_complete']} of {readiness['components_total']} components complete "
        f"({readiness['readiness_percent']}%).** Structural, functional and physical layers must all pass.",
        "Layer readiness: "
        + ", ".join(
            f"**{layer.title()} {readiness['layers'][layer]['components_complete']}/"
            f"{readiness['layers'][layer]['components_total']} "
            f"({readiness['layers'][layer]['readiness_percent']}%)**"
            for layer in ACCEPTANCE_LAYERS
        )
        + ".",
        f"Matrix SHA-256: `{acceptance['matrix']['sha256']}`.",
        "",
        "| Component | Overall | Structural | Functional | Physical |",
        "|---|---:|---:|---:|---:|",
    ]
    for component in acceptance["components"]:
        layers = component["layers"]
        lines.append(
            f"| {markdown_escape(component['name'])} | {component['status']} | "
            f"{layers['structural']['status']} | {layers['functional']['status']} | {layers['physical']['status']} |"
        )
    lines.extend([
        "",
        "## Execution plan",
        "",
        f"**{acceptance['execution_plan']['actions_total']} deduplicated actions** cover "
        f"**{acceptance['execution_plan']['components_affected']} incomplete components**.",
        "",
    ])
    if not acceptance["execution_plan"]["actions"]:
        lines.extend(["No further validation action is required.", ""])
    for index, action in enumerate(acceptance["execution_plan"]["actions"], start=1):
        lines.extend([
            f"### {index}. {markdown_escape(action['title'])}",
            "",
            f"**Type:** {markdown_escape(action['interaction_class'])} · "
            f"**Status:** {markdown_escape(action['status'])} · "
            f"**Components affected:** {action['components_affected']}" +
            (" · **Acceptance blocking:** yes" if action.get("acceptance_blocking") else ""),
            "",
            f"Command: `{markdown_escape(action['command'])}`",
            "",
            f"Safety: {markdown_escape(action['safety_note'])}",
            "",
        ])
        if action["prerequisites"]:
            lines.append(
                "Prerequisites: "
                + markdown_escape(" ".join(action["prerequisites"]))
            )
            lines.append("")
        if action["selectors"]:
            lines.append(
                "Selectors: "
                + ", ".join(f"`{markdown_escape(selector)}`" for selector in action["selectors"])
            )
        if action["blocked_selectors"]:
            lines.append(
                "Also unlocks: "
                + ", ".join(
                    f"`{markdown_escape(selector)}`" for selector in action["blocked_selectors"]
                )
            )
        lines.append("")
    lines.extend([
        "",
        "### Acceptance blockers",
        "",
    ])
    for component in acceptance["components"]:
        if component["status"] == "PASS":
            continue
        blockers = []
        for layer_name in ACCEPTANCE_LAYERS:
            layer = component["layers"][layer_name]
            if layer["status"] == "PASS":
                continue
            blockers.append(f"{layer_name} {layer['status']}")
        lines.append(f"- **{markdown_escape(component['name'])}** — {markdown_escape('; '.join(blockers))}")
        for blocker in component.get("root_blockers", component.get("blockers", [])):
            blocked = blocker.get("blocked_selectors", [])
            blocked_note = f" Blocks {len(blocked)} dependent selectors: {', '.join(blocked)}." if blocked else ""
            lines.append(
                f"  - `{markdown_escape(blocker['selector'])}` ({blocker['status']}) — "
                f"{markdown_escape(blocker.get('reason', ''))}{markdown_escape(blocked_note)} "
                f"{markdown_escape(blocker['recommended_action'])}"
            )
    lines.extend([
        "",
        "## Priority findings",
        "",
    ])
    if not model["findings"]:
        lines.extend(["No failed checks or warnings were recorded.", ""])
    for finding in model["findings"]:
        lines.extend(
            [
                f"### {finding['severity'].upper()} · `{finding['id']}`",
                "",
                f"**{markdown_escape(finding['summary'])}**",
                "",
                f"Evidence: {markdown_escape(finding['evidence'])}",
                "",
                f"Recommended next step: {markdown_escape(finding['recommended_action'])}",
                "",
            ]
        )
    lines.extend(["## Subsystem health", "", "| Subsystem | Health | Pass | Fail | Warn | Skip |", "|---|---:|---:|---:|---:|---:|"])
    for subsystem in model["subsystems"]:
        c = subsystem["counts"]
        lines.append(
            f"| {markdown_escape(subsystem['name'])} | {subsystem['health']} | "
            f"{c.get('PASS', 0)} | {c.get('FAIL', 0)} | {c.get('WARN', 0)} | {c.get('SKIP', 0)} |"
        )
    lines.extend(["", "## Incomplete coverage", ""])
    if not model["skipped_checks"]:
        lines.append("No checks were skipped.")
    else:
        for row in model["skipped_checks"]:
            lines.append(f"- `{row['subsystem']}/{row['check_id']}` — {markdown_escape(row['summary'])}")
    lines.extend(["", "## Complete check results", "", "| Status | Check | Observations | Summary | Evidence |", "|---|---|---:|---|---|"])
    for row in model["checks"]:
        lines.append(
            f"| {row['status']} | `{row['subsystem']}/{row['check_id']}` | "
            f"{row['observation_count']} | {markdown_escape(row['summary'])} | {markdown_escape(row['details'])} |"
        )
    lines.extend(["", "## Evidence files", ""])
    for evidence in model["evidence"]:
        lines.append(f"- `{evidence['file']}` — {evidence['bytes']} bytes — SHA-256 `{evidence['sha256']}`")
    lines.extend(["", f"Schema: `{model['schema']}`", ""])
    return "\n".join(lines)


def render_html(model: dict[str, Any]) -> str:
    summary = model["summary"]
    counts = summary["counts"]
    acceptance = model["acceptance"]
    readiness = acceptance["summary"]
    inventory = model["package_inventory"]
    integrity = model["integrity"]
    layer_metrics = "".join(
        f"<div class='metric'><b>{readiness['layers'][layer]['components_complete']}/"
        f"{readiness['layers'][layer]['components_total']}</b>{html.escape(layer.title())} ready</div>"
        for layer in ACCEPTANCE_LAYERS
    )
    status_class = "fail" if summary["result"] == "FAIL" else ("warn" if summary["result"] == "PASS_WITH_WARNINGS" else "pass")
    integrity_problems = "".join(f"<li>{html.escape(problem)}</li>" for problem in integrity["problems"])
    if not integrity_problems:
        integrity_problems = "<li>No evidence-integrity problem was detected.</li>"
    finding_cards = []
    for finding in model["findings"]:
        finding_cards.append(
            f"<article class='finding {html.escape(finding['severity'])}'>"
            f"<div class='finding-head'><span class='badge {html.escape(finding['status'].lower())}'>{html.escape(finding['status'])}</span>"
            f"<code>{html.escape(finding['id'])}</code><strong>{html.escape(finding['severity'].upper())}</strong></div>"
            f"<h3>{html.escape(finding['summary'])}</h3>"
            f"<p><b>Evidence:</b> {html.escape(finding['evidence'])}</p>"
            f"<p><b>Recommended next step:</b> {html.escape(finding['recommended_action'])}</p></article>"
        )
    if not finding_cards:
        finding_cards.append("<p class='empty'>No failed checks or warnings were recorded.</p>")
    subsystem_rows = "".join(
        f"<tr><td>{html.escape(item['name'])}</td><td><span class='badge {item['health'].lower()}'>{item['health']}</span></td>"
        f"<td>{item['counts'].get('PASS', 0)}</td><td>{item['counts'].get('FAIL', 0)}</td>"
        f"<td>{item['counts'].get('WARN', 0)}</td><td>{item['counts'].get('SKIP', 0)}</td></tr>"
        for item in model["subsystems"]
    )
    acceptance_rows = "".join(
        f"<tr><td>{html.escape(item['name'])}</td>"
        f"<td><span class='badge {item['status'].lower().replace('_', '-')}'>{html.escape(item['status'])}</span></td>"
        + "".join(
            f"<td><span class='badge {item['layers'][layer]['status'].lower().replace('_', '-')}'>{html.escape(item['layers'][layer]['status'])}</span>"
            f"<small>{html.escape(', '.join(acceptance_layer_blockers(item['layers'][layer])))}</small></td>"
            for layer in ACCEPTANCE_LAYERS
        )
        + "</tr>"
        for item in acceptance["components"]
    )
    execution_cards = []
    for index, action in enumerate(acceptance["execution_plan"]["actions"], start=1):
        prerequisites = "".join(
            f"<li>{html.escape(item)}</li>" for item in action["prerequisites"]
        )
        prerequisites_html = (
            f"<p><b>Prerequisites</b></p><ul>{prerequisites}</ul>" if prerequisites else ""
        )
        selectors = ", ".join(action["selectors"])
        selectors_html = (
            f"<p><b>Selectors:</b> <code>{html.escape(selectors)}</code></p>"
            if selectors
            else ""
        )
        unlocks = ", ".join(action["blocked_selectors"])
        unlocks_html = (
            f"<p><b>Also unlocks:</b> <code>{html.escape(unlocks)}</code></p>" if unlocks else ""
        )
        execution_cards.append(
            f"<article class='action-card' id='action-{html.escape(action['id'])}'>"
            f"<div class='action-head'><span class='action-number'>{index}</span>"
            f"<span class='badge info'>{html.escape(action['interaction_class'].upper())}</span>"
            f"<span class='badge {html.escape(action['status'].lower().replace('_', '-'))}'>"
            f"{html.escape(action['status'])}</span></div>"
            f"<h3>{html.escape(action['title'])}</h3>"
            f"<p><code>$ {html.escape(action['command'])}</code></p>"
            f"<p>{html.escape(action['safety_note'])}</p>{prerequisites_html}"
            f"<p><b>Affects {action['components_affected']} component(s):</b> "
            f"{html.escape(', '.join(action['components']))}</p>"
            + ("<p><b>Acceptance blocking:</b> yes</p>" if action.get("acceptance_blocking") else "")
            + f"{selectors_html}{unlocks_html}</article>"
        )
    if not execution_cards:
        execution_cards.append("<p class='empty'>No further validation action is required.</p>")
    acceptance_blockers = []
    for component in acceptance["components"]:
        if component["status"] == "PASS":
            continue
        layer_items = []
        for blocker in component.get("root_blockers", component.get("blockers", [])):
            blocked = blocker.get("blocked_selectors", [])
            blocked_note = (
                f" Blocks {len(blocked)} dependent selectors: {', '.join(blocked)}."
                if blocked else ""
            )
            layer_items.append(
                f"<li><b>{html.escape(blocker['layer'].title())} · "
                f"<code>{html.escape(blocker['selector'])}</code> · {html.escape(blocker['status'])}</b> — "
                f"{html.escape(blocker.get('reason', ''))}{html.escape(blocked_note)} "
                f"{html.escape(blocker['recommended_action'])}</li>"
            )
        acceptance_blockers.append(
            f"<li><strong>{html.escape(component['name'])}</strong><ul>{''.join(layer_items)}</ul></li>"
        )
    result_rows = "".join(
        f"<tr><td><span class='badge {row['status'].lower()}'>{row['status']}</span></td>"
        f"<td><code>{html.escape(row['subsystem'])}/{html.escape(row['check_id'])}</code></td>"
        f"<td>{row['observation_count']}</td><td>{html.escape(row['summary'])}</td><td>{html.escape(row['details'])}</td></tr>"
        for row in model["checks"]
    )
    environment = "".join(
        f"<dt>{html.escape(key.replace('_', ' ').title())}</dt><dd>{html.escape(value)}</dd>"
        for key, value in sorted(model["environment"].items())
    ) or "<dt>Environment</dt><dd>Not recorded by this Validator version</dd>"
    evidence = "".join(
        f"<li><code>{html.escape(item['file'])}</code> · {item['bytes']} bytes · SHA-256 <code>{item['sha256']}</code></li>"
        for item in model["evidence"]
    )
    package_rows = "".join(
        f"<tr><td><code>{html.escape(item['package'])}</code></td>"
        f"<td><code>{html.escape(item['version'])}</code></td>"
        f"<td>{html.escape(item['architecture'])}</td></tr>"
        for item in inventory["packages"]
    )
    return f"""<!doctype html>
<html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Yoga Book Validator report</title><style>
:root{{--bg:#f5f6f8;--surface:#fff;--text:#202124;--muted:#68707a;--line:#dfe3e8;--pass:#16794b;--fail:#b42318;--warn:#a15c00;--info:#52606d}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,sans-serif}}
main{{max-width:1180px;margin:auto;padding:32px 20px 64px}}h1{{margin:.2rem 0}}h2{{margin-top:2rem}}code{{overflow-wrap:anywhere}}
.muted{{color:var(--muted)}}.hero,.panel,.finding{{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:20px;box-shadow:0 2px 8px #0000000a}}
.hero{{border-left:7px solid var(--{status_class})}}.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px;margin:20px 0}}
.metric{{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:16px}}.metric b{{display:block;font-size:1.8rem}}
.findings{{display:grid;gap:14px}}.finding{{border-left:5px solid var(--fail)}}.finding.medium{{border-left-color:var(--warn)}}
.finding.high,.finding.critical{{background:#fffafa}}.finding.medium{{border-left-color:var(--warn);background:#fffdf8}}
.finding-head{{display:flex;gap:10px;align-items:center}}.finding-head strong{{margin-left:auto;color:var(--fail)}}.finding.medium .finding-head strong{{color:var(--warn)}}
.execution-plan{{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:14px}}.action-card{{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:18px}}
.action-head{{display:flex;gap:8px;align-items:center}}.action-number{{display:grid;place-items:center;width:28px;height:28px;border-radius:50%;background:#e8edf2;font-weight:800}}
.badge{{display:inline-block;padding:2px 8px;border-radius:999px;font-size:.78rem;font-weight:750}}.badge.pass{{color:var(--pass);background:#e8f5ee}}
.badge.fail{{color:var(--fail);background:#fff0ee}}.badge.warn{{color:var(--warn);background:#fff4df}}.badge.skip,.badge.unimplemented,.badge.incomplete,.badge.not-run,.badge.info{{color:var(--info);background:#edf1f4}}
.table-wrap{{overflow:auto}}table{{border-collapse:collapse;width:100%}}th,td{{padding:10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}}th{{position:sticky;top:0;background:var(--surface)}}
td small{{display:block;color:var(--muted);margin-top:4px;overflow-wrap:anywhere}}dl{{display:grid;grid-template-columns:max-content 1fr;gap:7px 18px}}dt{{font-weight:700}}dd{{margin:0}}details{{margin-top:20px}}@media(max-width:620px){{main{{padding:18px 10px}}dl{{grid-template-columns:1fr}}}}
</style></head><body><main>
<section class='hero'><p class='muted'>Yoga Book Validator {html.escape(model['validator']['version'])}</p><h1>Diagnostic report</h1>
<p><b>{html.escape(summary['result'])}</b> · {html.escape(str(model['run']['command']))} · {html.escape(str(model['run']['started']))}</p>
<p class='muted'>Independent check totals exclude suite roll-ups. Repeated observations remain available for consistency analysis.</p></section>
<section class='cards'><div class='metric'><b>{counts['PASS']}</b>Passed</div><div class='metric'><b>{counts['FAIL']}</b>Failed</div>
<div class='metric'><b>{counts['WARN']}</b>Warnings</div><div class='metric'><b>{counts['SKIP']}</b>Skipped</div><div class='metric'><b>{summary['coverage_percent']}%</b>Check coverage</div>
<div class='metric'><b>{integrity['status']}</b>Evidence integrity</div><div class='metric'><b>{readiness['components_complete']}/{readiness['components_total']}</b>Components accepted</div>{layer_metrics}</section>
<h2>Evidence integrity · {integrity['status']}</h2><section class='panel'><p>State preservation: <b>{html.escape(str(integrity['state_preservation']))}</b> · Package inventory complete: <b>{str(integrity['package_inventory_complete']).lower()}</b> · Run finished: <b>{str(integrity['run_finished']).lower()}</b></p><ul>{integrity_problems}</ul></section>
<h2>Device acceptance readiness · {readiness['readiness_percent']}%</h2><p class='muted'>A component is complete only when structural, functional and physical evidence all pass. Matrix SHA-256: <code>{html.escape(acceptance['matrix']['sha256'])}</code>.</p>
<section class='panel table-wrap'><table><thead><tr><th>Component</th><th>Overall</th><th>Structural</th><th>Functional</th><th>Physical</th></tr></thead><tbody>{acceptance_rows}</tbody></table></section>
<h2>Execution plan · {acceptance['execution_plan']['actions_total']} actions</h2><p class='muted'>Actions are deduplicated across components and ordered by interaction class. Commands are informational and should be launched through the trusted Validator UI or CLI.</p>
<section class='execution-plan'>{''.join(execution_cards)}</section>
<h2>Acceptance blockers</h2><section class='panel'><ul>{''.join(acceptance_blockers)}</ul></section>
<h2>Priority findings</h2><section class='findings'>{''.join(finding_cards)}</section>
<h2>Subsystem health</h2><section class='panel table-wrap'><table><thead><tr><th>Subsystem</th><th>Health</th><th>Pass</th><th>Fail</th><th>Warn</th><th>Skip</th></tr></thead><tbody>{subsystem_rows}</tbody></table></section>
<h2>Run context</h2><section class='panel'><dl>{environment}</dl><p>Physical acceptance: <b>{html.escape(str(model['run']['physical_acceptance_result']))}</b></p></section>
<h2>Validated package inventory · {inventory['captured']}/{inventory['expected']}</h2><section class='panel table-wrap'><p>Complete: <b>{str(inventory['complete']).lower()}</b></p><p>Missing: <b>{html.escape(', '.join(inventory['missing']) or 'none')}</b> · Unexpected: <b>{html.escape(', '.join(inventory['unexpected']) or 'none')}</b></p><p>Inventory problems: <b>{html.escape(', '.join(inventory['problems']) or 'none')}</b></p><table><thead><tr><th>Package</th><th>Version</th><th>Architecture</th></tr></thead><tbody>{package_rows}</tbody></table></section>
<details><summary><b>Complete check results ({summary['checks_total']})</b></summary><section class='panel table-wrap'><table><thead><tr><th>Status</th><th>Check</th><th>Observations</th><th>Summary</th><th>Evidence</th></tr></thead><tbody>{result_rows}</tbody></table></section></details>
<h2>Evidence files</h2><section class='panel'><ul>{evidence}</ul><p class='muted'>Schema: {html.escape(model['schema'])}</p></section>
</main></body></html>"""


def generate(directory: Path) -> dict[str, Any]:
    directory = directory.resolve()
    model = build_model(directory)
    atomic_write(directory / "report.json", json.dumps(model, indent=2, ensure_ascii=False) + "\n")
    atomic_write(directory / "report.md", render_markdown(model))
    atomic_write(directory / "report.html", render_html(model))
    return model


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report_directory", type=Path)
    parser.add_argument("--print-summary", action="store_true")
    args = parser.parse_args()
    try:
        model = generate(args.report_directory)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    if args.print_summary:
        summary = model["summary"]
        counts = summary["counts"]
        print(
            f"{summary['result']}: {counts['PASS']} passed, {counts['FAIL']} failed, "
            f"{counts['WARN']} warnings, {counts['SKIP']} skipped"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
