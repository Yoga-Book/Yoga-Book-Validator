#!/usr/bin/env python3
"""Prove that every acceptance selector has executable producer code."""

from __future__ import annotations

from collections import defaultdict
import json
from pathlib import Path
import re
import shlex


ROOT = Path(__file__).resolve().parents[1]
LIBEXEC = ROOT / "libexec"
ACCEPTANCE = ROOT / "data" / "acceptance.json"


def shell_words(source: str, pattern: str) -> list[str]:
    match = re.search(pattern, source, re.DOTALL | re.MULTILINE)
    if not match:
        return []
    return shlex.split(match.group(1), comments=True, posix=True)


def add(producers: dict[str, set[str]], selector: str, source: Path) -> None:
    producers[selector].add(source.relative_to(ROOT).as_posix())


def add_template(templates: dict[str, set[str]], selector: str, source: Path) -> None:
    templates[selector].add(source.relative_to(ROOT).as_posix())


def add_template_match(
    template_matches: dict[str, set[str]], selector: str, concrete: str
) -> None:
    template_matches[selector].add(concrete)


def literal_shell_emits(producers: dict[str, set[str]]) -> None:
    emit = re.compile(
        r"\bybv_emit\s+(['\"]?)([a-z][a-z0-9-]*)\1\s+"
        r"(['\"]?)([a-z][a-z0-9-]*)\3(?=\s|$)",
        re.MULTILINE,
    )
    for source_path in sorted(LIBEXEC.glob("*.sh")):
        source = source_path.read_text(encoding="utf-8").replace("\\\n", " ")
        for match in emit.finditer(source):
            add(producers, f"{match.group(2)}/{match.group(4)}", source_path)


def dynamic_shell_emits(
    producers: dict[str, set[str]],
    templates: dict[str, set[str]],
    template_matches: dict[str, set[str]],
    template_capacities: dict[str, int],
) -> None:
    check = LIBEXEC / "yogabook-validator-check.sh"
    source = check.read_text(encoding="utf-8")
    for check_id in re.findall(r"^check_input_pattern\s+([a-z][a-z0-9-]*)\b", source, re.MULTILINE):
        add(producers, f"input/{check_id}", check)

    physical = LIBEXEC / "yogabook-validator-physical.sh"
    source = physical.read_text(encoding="utf-8")
    for check_id in shell_words(source, r"declare\s+-a\s+ids=\((.*?)\)"):
        add(producers, f"physical/{check_id}", physical)

    inputs = LIBEXEC / "yogabook-validator-inputs.sh"
    source = inputs.read_text(encoding="utf-8")
    for check_id in re.findall(r'\brow\("([a-z][a-z0-9-]*)"', source):
        add(producers, f"input/{check_id}", inputs)

    controls = LIBEXEC / "yogabook-validator-controls.sh"
    source = controls.read_text(encoding="utf-8")
    for check_id in re.findall(r"^emit_control_result\s+([a-z][a-z0-9-]*)\b", source, re.MULTILINE):
        add(producers, f"input/{check_id}", controls)

    camera = LIBEXEC / "yogabook-validator-camera.sh"
    source = camera.read_text(encoding="utf-8")
    for sensor in re.findall(r"^for identity in\s+([^;]+);\s*do", source, re.MULTILINE):
        for identity in shlex.split(sensor):
            add(producers, f"camera/sensor-{identity.split()[0]}", camera)
    for camera_id in re.findall(r"^test_camera\s+([a-z][a-z0-9-]*)\b", source, re.MULTILINE):
        for suffix in ("route", "stream", "signal"):
            add(producers, f"camera/{camera_id}-{suffix}", camera)

    modes = LIBEXEC / "yogabook-validator-modes.sh"
    source = modes.read_text(encoding="utf-8")
    mapping_ids = shell_words(
        source,
        r"for\s+check_id\s+in\s+(.*?);\s*do\s*\n\s*ybv_emit\s+input\s+\"pen-mapping-\$check_id\"",
    )
    for check_id in mapping_ids:
        add(producers, f"input/pen-mapping-{check_id}", modes)
    for check_id in re.findall(r"^compare_state\s+([a-z][a-z0-9-]*)\b", source, re.MULTILINE):
        add(producers, f"input/{check_id}", modes)
    for match in re.finditer(r"^for\s+device\s+in\s+(.*?);\s*do", source, re.MULTILINE):
        for device in shlex.split(match.group(1), comments=True, posix=True):
            normalized = device.lower().replace(" ", "-")
            if f'"$check_id-restored"' in source[match.end() : match.end() + 500]:
                add(producers, f"input/{normalized}-restored", modes)

    active = LIBEXEC / "yogabook-validator-active.sh"
    source = active.read_text(encoding="utf-8")
    for match in re.finditer(r"^\s*for\s+haptic\s+in\s+(.*?);\s*do", source, re.MULTILINE):
        for check_id in shlex.split(match.group(1), comments=True, posix=True):
            add(producers, f"input/haptic-{check_id}", active)

    lights = LIBEXEC / "yogabook-validator-lights.sh"
    source = lights.read_text(encoding="utf-8")
    led_map = shell_words(source, r"declare\s+-A\s+led_ids=\((.*?)\)")
    for token in led_map:
        if "]=" in token:
            add(producers, f"platform/{token.split(']=', 1)[1]}", lights)

    usb = LIBEXEC / "yogabook-validator-usb.sh"
    source = usb.read_text(encoding="utf-8")
    for hub in re.findall(r"^check_root_hub\s+([a-z][a-z0-9-]*)\b", source, re.MULTILINE):
        concrete = f"usb/root-hub-{hub}"
        add(producers, concrete, usb)
        add_template_match(template_matches, "usb/root-hub-*", concrete)
    if '"root-hub-$name"' in source:
        add_template(templates, "usb/root-hub-*", usb)

    usb_cycle = LIBEXEC / "yogabook-validator-usb-cycle.sh"
    source = usb_cycle.read_text(encoding="utf-8")
    for category, check_id in re.findall(
        r"^\s*emit_if_missing\s+([a-z][a-z0-9-]*)\s+([a-z][a-z0-9-]*)\b",
        source,
        re.MULTILINE,
    ):
        add(producers, f"{category}/{check_id}", usb_cycle)

    storage = LIBEXEC / "yogabook-validator-storage.sh"
    source = storage.read_text(encoding="utf-8")
    for check_id in re.findall(r"^\s*YBV_FINAL_ROLLUP_CHECK_ID=([a-z][a-z0-9-]*)\b", source, re.MULTILINE):
        add(producers, f"suite/{check_id}", storage)

    interactions = LIBEXEC / "yogabook-validator-sensor-interactions.sh"
    source = interactions.read_text(encoding="utf-8")
    for match in re.finditer(r"^\s*for\s+check_id\s+in\s+(.*?);\s*do", source, re.MULTILINE):
        for check_id in shlex.split(match.group(1), comments=True, posix=True):
            if check_id.endswith("-response"):
                add(producers, f"sensors/{check_id}", interactions)

    sensors = LIBEXEC / "yogabook-validator-sensors.sh"
    source = sensors.read_text(encoding="utf-8")
    sensor_names = shell_words(source, r"declare\s+-A\s+expected_counts=\((.*?)\)")
    expected_counts: dict[str, int] = {}
    for token in sensor_names:
        match = re.match(r"\[([^]]+)\]=([0-9]+)$", token)
        if match:
            sensor_name, count = match.group(1), int(match.group(2))
            expected_counts[sensor_name] = count
            concrete = f"sensors/layout-{sensor_name}"
            add(producers, concrete, sensors)
            add_template_match(template_matches, "sensors/layout-*", concrete)
    if '"layout-$sensor_name"' in source:
        add_template(templates, "sensors/layout-*", sensors)
    for branch, body in re.findall(
        r"^\s*([a-z][a-z0-9_]*)\)\s*\n(.*?)(?=^\s*[a-z][a-z0-9_]*\)\s*$|^\s*esac\s*$)",
        source,
        re.DOTALL | re.MULTILINE,
    ):
        suffixes = set(re.findall(r'\"\$device_id-([a-z][a-z0-9-]*)\"', body))
        for suffix in suffixes:
            selector = f"sensors/*-{suffix}"
            add_template(templates, selector, sensors)
            template_capacities[selector] = expected_counts[branch]

    resources = LIBEXEC / "yogabook-validator-resources.sh"
    source = resources.read_text(encoding="utf-8")
    units = shell_words(source, r"declare\s+-a\s+service_units=\((.*?)\)")
    for unit in units:
        service = unit.removesuffix(".service")
        for suffix in re.findall(r'\"\$\{unit%\.service\}-([a-z][a-z0-9-]*)\"', source):
            concrete = f"resources/{service}-{suffix}"
            selector = f"resources/*-{suffix}"
            add(producers, concrete, resources)
            add_template(templates, selector, resources)
            add_template_match(template_matches, selector, concrete)
    for selector, matches in template_matches.items():
        if selector.startswith("resources/*-"):
            template_capacities[selector] = len(matches)


def dynamic_python_emits(producers: dict[str, set[str]]) -> None:
    resume = LIBEXEC / "yogabook-validator-resume.py"
    source = resume.read_text(encoding="utf-8")
    for check_id in re.findall(r'checks\["(resume-[a-z0-9-]+)"\]\s*=', source):
        add(producers, f"suspend/{check_id}", resume)


def declared_selectors(matrix: dict) -> set[str]:
    return {
        selector
        for component in matrix["components"]
        for selectors in component["layers"].values()
        for selector in selectors
    }


def wildcard_errors(
    selector: str,
    contract: dict,
    templates: dict[str, set[str]],
    template_matches: dict[str, set[str]],
    template_capacities: dict[str, int],
) -> list[str]:
    errors = []
    matches = template_matches.get(selector, set())
    required = set(contract.get("required_match_ids", []))
    optional = set(contract.get("optional_match_ids", []))
    count = template_capacities.get(selector, len(matches))
    if selector not in templates:
        errors.append("producer-template=missing")
    if not required <= matches:
        errors.append("missing-required=" + ",".join(sorted(required - matches)))
    minimum = contract.get("minimum_matches")
    maximum = contract.get("maximum_matches")
    if minimum is not None and count < minimum:
        errors.append(f"matches={count} below-minimum={minimum}")
    if maximum is not None and count > maximum:
        errors.append(f"matches={count} above-maximum={maximum}")
    if contract.get("allow_additional_matches") is False:
        additional = matches - required - optional
        if additional:
            errors.append("additional=" + ",".join(sorted(additional)))
    return errors


def self_test_wildcard_contract() -> None:
    templates = {"example/*": {"producer.sh"}}
    matches = {"example/*": {"example/one", "example/two"}}
    capacities = {"example/*": 2}
    contract = {
        "required_match_ids": ["example/one"],
        "optional_match_ids": ["example/two"],
        "minimum_matches": 2,
        "maximum_matches": 2,
        "allow_additional_matches": False,
    }
    assert not wildcard_errors("example/*", contract, templates, matches, capacities)
    assert wildcard_errors("example/*", {**contract, "minimum_matches": 3}, templates, matches, capacities)
    assert wildcard_errors("example/*", {**contract, "maximum_matches": 1}, templates, matches, capacities)
    assert wildcard_errors(
        "example/*", {**contract, "required_match_ids": ["example/missing"]}, templates, matches, capacities
    )
    assert wildcard_errors(
        "example/*", contract, templates, {"example/*": matches["example/*"] | {"example/three"}}, capacities
    )
    assert not wildcard_errors(
        "example/*",
        {**contract, "maximum_matches": 3, "allow_additional_matches": True},
        templates,
        {"example/*": matches["example/*"] | {"example/three"}},
        {"example/*": 3},
    )
    assert wildcard_errors("example/*", contract, {}, matches, capacities)


def main() -> None:
    matrix = json.loads(ACCEPTANCE.read_text(encoding="utf-8"))
    required = declared_selectors(matrix)
    producers: dict[str, set[str]] = defaultdict(set)
    templates: dict[str, set[str]] = defaultdict(set)
    template_matches: dict[str, set[str]] = defaultdict(set)
    template_capacities: dict[str, int] = {}
    self_test_wildcard_contract()
    literal_shell_emits(producers)
    dynamic_shell_emits(producers, templates, template_matches, template_capacities)
    dynamic_python_emits(producers)

    missing = []
    for selector in sorted(required):
        if any(character in selector for character in "*?["):
            contract = matrix.get("selector_contracts", {}).get(selector, {})
            errors = wildcard_errors(
                selector, contract, templates, template_matches, template_capacities
            )
            if errors:
                missing.append(f"{selector} ({'; '.join(errors)})")
        elif selector not in producers:
            missing.append(selector)

    if missing:
        raise AssertionError("acceptance selectors without executable producers:\n  " + "\n  ".join(missing))

    print(f"selector producer contract: PASS ({len(required)} selectors, {len(producers)} concrete producers)")


if __name__ == "__main__":
    main()
