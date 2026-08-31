#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck disable=SC2016,SC2030,SC2031

set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary_root=${TMPDIR:-/tmp}
temporary=$(mktemp -d "$temporary_root/yogabook-validator-test.XXXXXX")
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

required=(
	README.md ATTRIBUTION.md CONTRIBUTING.md LICENSE Makefile
	docs/coverage.md data/acceptance.json
	src/yogabook-validator.sh src/yogabook-validator-ui.sh
	libexec/yogabook-validator-common.sh libexec/yogabook-validator-check.sh
	libexec/yogabook-validator-audio-levels.sh
	libexec/yogabook-validator-audio-analyze.py
	libexec/yogabook-validator-category.sh
	libexec/yogabook-validator-dossier.py libexec/yogabook-validator-dossier.sh
	libexec/yogabook-validator-report.py
	libexec/yogabook-validator-resume.py
	libexec/yogabook-validator-active.sh libexec/yogabook-validator-automated.sh
	libexec/yogabook-validator-apt.sh
	libexec/yogabook-validator-camera.sh
	libexec/yogabook-validator-camera-readiness.sh
	libexec/yogabook-validator-camera-capture.py
	libexec/yogabook-validator-charging.sh
	libexec/yogabook-validator-controls-events.py
	libexec/yogabook-validator-controls.sh
	libexec/yogabook-validator-display.sh
	libexec/yogabook-validator-hdmi-link.py
	libexec/yogabook-validator-headset-events.py
	libexec/yogabook-validator-gnss.sh libexec/yogabook-validator-inputs.sh
	libexec/yogabook-validator-lights.sh
	libexec/yogabook-validator-modem.py libexec/yogabook-validator-modem.sh
	libexec/yogabook-validator-mode-trace.py
	libexec/yogabook-validator-mode-trace-result.py
	libexec/yogabook-validator-pen-result.py
	libexec/yogabook-validator-modes.sh
	libexec/yogabook-validator-passive.sh
	libexec/yogabook-validator-platform.sh
	libexec/yogabook-validator-internal-storage.sh
	libexec/yogabook-validator-quiet.sh
	libexec/yogabook-validator-resources.sh
	libexec/yogabook-validator-stability.sh
	libexec/yogabook-validator-power.sh libexec/yogabook-validator-sensors.sh
	libexec/yogabook-validator-sensor-interactions.py
	libexec/yogabook-validator-sensor-interactions.sh
	libexec/yogabook-validator-storage.sh
	libexec/yogabook-validator-usb.sh libexec/yogabook-validator-usb-cycle.sh
	libexec/yogabook-validator-wireless.sh
	libexec/yogabook-validator-physical.sh libexec/yogabook-validator-full.sh
	libexec/yogabook-validator-bundle.sh ui/yogabook_validator_ui.py
	tests/test-controls-events.py
	tests/test-camera-capture.py
	tests/test-camera-readiness.sh
	tests/test-mode-trace-result.py
	tests/test-pen-result.py
	tests/test-selector-producers.py
	tests/test-audio-analyze.py
	tests/test-internal-storage.sh
	data/org.yogabook.Validator.desktop data/org.yogabook.validator.policy
	data/metainfo/org.yogabook.Validator.metainfo.xml debian/control debian/rules
	debian/yogabook-validator.links
)
for file in "${required[@]}"; do test -f "$root/$file"; done
python3 - "$root/debian/control" <<'PY'
import re
import sys
from pathlib import Path


def parse_paragraph(text):
    fields = {}
    current = None
    for line in text.splitlines():
        if line[:1].isspace():
            if current is None:
                raise AssertionError("orphan continuation in debian/control")
            fields[current] += " " + line.strip()
            continue
        current, separator, value = line.partition(":")
        if not separator:
            raise AssertionError(f"malformed debian/control line: {line!r}")
        fields[current] = value.strip()
    return fields


def require_packages(field_name, value, expected):
    for package in expected:
        pattern = rf"(?<![A-Za-z0-9+.-]){re.escape(package)}(?![A-Za-z0-9+.-])"
        if re.search(pattern, value) is None:
            raise AssertionError(f"{field_name} is missing {package}")


paragraphs = Path(sys.argv[1]).read_text(encoding="utf-8").strip().split("\n\n")
if len(paragraphs) != 2:
    raise AssertionError("debian/control must contain one source and one binary paragraph")
source = parse_paragraph(paragraphs[0])
binary = parse_paragraph(paragraphs[1])
require_packages(
    "Build-Depends",
    source.get("Build-Depends", ""),
    ("debhelper-compat", "gir1.2-adw-1", "gir1.2-gtk-4.0", "python3", "python3-gi"),
)
require_packages(
    "Depends",
    binary.get("Depends", ""),
    ("apt", "libglib2.0-bin", "psmisc", "udev", "usbutils", "v4l-utils"),
)
PY

while IFS= read -r script; do
	test -x "$script"
	bash -n "$script"
done < <(
	printf '%s\n' "$root"/src/*.sh "$root"/libexec/*.sh "$root"/tests/*.sh "$root"/debian/tests/*.sh
)
test -x "$root/ui/yogabook_validator_ui.py"
for private_helper in yogabook-validator-automated.sh yogabook-validator-camera-readiness.sh yogabook-validator-controls.sh yogabook-validator-inputs.sh yogabook-validator-lights.sh yogabook-validator-modes.sh yogabook-validator-quiet.sh yogabook-validator-sensor-interactions.sh yogabook-validator-stability.sh yogabook-validator-storage.sh yogabook-validator-wireless.sh; do
	set +e
	"$root/libexec/$private_helper" >/dev/null 2>&1
	helper_rc=$?
	set -e
	[[ $helper_rc -eq 2 ]]
done

shopt -s globstar nullglob
for candidate in "$root"/src/** "$root"/libexec/** "$root"/ui/** \
	"$root"/tests/** "$root"/debian/tests/** "$root"/debian/rules; do
	[[ -f $candidate ]] || continue
	IFS= read -r first_line <"$candidate" || true
	[[ $first_line == '#!'* ]] || continue
	case $candidate in
	*.sh | *.py | "$root/debian/rules") ;;
	*) echo "executable source lacks a meaningful extension: $candidate" >&2; exit 1 ;;
	esac
done
if command -v shellcheck >/dev/null; then
	shellcheck -x -P "$root/libexec" "$root"/src/*.sh "$root"/libexec/*.sh "$root"/tests/*.sh "$root"/debian/tests/*.sh
fi
python3 -m py_compile "$root/ui/yogabook_validator_ui.py" "$root"/libexec/*.py
python3 - "$root/libexec/yogabook-validator-report.py" "$root/ui/yogabook_validator_ui.py" <<'PY'
import ast
from pathlib import Path
import sys
from types import SimpleNamespace

report_module = ast.parse(Path(sys.argv[1]).read_text(encoding="utf-8"))
ui_module = ast.parse(Path(sys.argv[2]).read_text(encoding="utf-8"))

def literal_assignment(module, name):
    assignment = next(
        node
        for node in module.body
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == name for target in node.targets)
    )
    return ast.literal_eval(assignment.value)

action_ids = set(literal_assignment(report_module, "ACTION_DEFINITIONS"))
handler_map = literal_assignment(ui_module, "EXECUTION_ACTION_HANDLERS")
assert set(handler_map) == action_ids - {"inspect-selector"}
window = next(
    node
    for node in ui_module.body
    if isinstance(node, ast.ClassDef) and node.name == "ValidatorWindow"
)
method_names = {node.name for node in window.body if isinstance(node, ast.FunctionDef)}
assert set(handler_map.values()) <= method_names
assert handler_map["gnss"] == "on_gnss"
assert handler_map["recapture-evidence"] == "on_passive"

search_function = next(
    node
    for node in ui_module.body
    if isinstance(node, ast.FunctionDef) and node.name == "validation_search_matches"
)
filter_method = next(
    node
    for node in window.body
    if isinstance(node, ast.FunctionDef) and node.name == "apply_validation_filter"
)
search_namespace = {}
exec(
    compile(
        ast.Module(body=[search_function, filter_method], type_ignores=[]),
        "<ui-search>",
        "exec",
    ),
    search_namespace,
)
matches = search_namespace["validation_search_matches"]
assert matches("PEN mapping", "Test rotated pen mapping")
assert matches("input pen", "Input and device modes", "Test rotated pen mapping")
assert matches("", "Test cameras")
assert not matches("camera pen", "Test rotated pen mapping")
assert {
    "on_validation_search_changed",
    "on_validation_search_stopped",
    "apply_validation_filter",
} <= method_names


class FakeWidget:
    def __init__(self):
        self.visible = None
        self.title = ""

    def set_visible(self, visible):
        self.visible = visible

    def set_title(self, title):
        self.title = title


pen_button = object()
camera_button = object()
pen_group, pen_row = FakeWidget(), FakeWidget()
camera_group, camera_row = FakeWidget(), FakeWidget()
no_results, no_results_row = FakeWidget(), FakeWidget()
window_fixture = SimpleNamespace(
    validation_search=SimpleNamespace(get_text=lambda: ""),
    active_subtests=[],
    current_run_button=None,
    validation_groups=[
        (pen_group, "Input and device modes input-modes", [(pen_row, "Test rotated pen mapping", pen_button)]),
        (camera_group, "Audio and media audio-media", [(camera_row, "Test cameras", camera_button)]),
    ],
    validation_button_groups={},
    no_search_results=no_results,
    no_search_results_row=no_results_row,
)
apply_filter = search_namespace["apply_validation_filter"]
apply_filter(window_fixture, "pen")
assert pen_group.visible and pen_row.visible
assert camera_group.visible is False and camera_row.visible is False
assert no_results.visible is False
apply_filter(window_fixture, "missing")
assert pen_group.visible is False and camera_group.visible is False
assert no_results.visible and "missing" in no_results_row.title
window_fixture.current_run_button = camera_button
apply_filter(window_fixture, "missing")
assert camera_group.visible and camera_row.visible
assert no_results.visible is False
PY
grep -Fq 'self.validation_search = Gtk.SearchEntry()' "$root/ui/yogabook_validator_ui.py"
if grep -Fq 'self.validation_search.set_max_length' "$root/ui/yogabook_validator_ui.py"; then
	echo "Gtk.SearchEntry does not support set_max_length on the target runtime" >&2
	exit 1
fi
grep -Fq 'self.no_search_results.set_visible(no_matches)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'integrity.get("status") != "PASS" and action_id != "recapture-evidence"' \
	"$root/ui/yogabook_validator_ui.py"
python3 "$root/tests/test-report.py"
python3 "$root/tests/test-camera-capture.py"
"$root/tests/test-camera-readiness.sh"
python3 "$root/tests/test-mode-trace-result.py"
python3 "$root/tests/test-pen-result.py"
python3 "$root/tests/test-selector-producers.py"
python3 "$root/tests/test-audio-analyze.py"
python3 "$root/tests/test-dossier.py"
python3 "$root/tests/test-hdmi-link.py"
python3 "$root/tests/test-headset-events.py"
python3 "$root/tests/test-controls-events.py"
python3 "$root/tests/test-modem.py"
"$root/tests/test-audio-levels.sh"
"$root/tests/test-internal-storage.sh"
package_inventory_fixture="$temporary/package-inventory-fixture.tsv"
package_inventory_copy="$temporary/package-inventory-copy.tsv"
fixture_validator_version=$(sed -n 's/^YBV_VERSION=//p' "$root/libexec/yogabook-validator-common.sh" | head -n 1)
printf '%s\n' \
	'alsa-ucm-conf-yogabook	1.0	all' \
	'gir1.2-mutter-18	1.0	amd64' \
	'gnome-control-center	1.0	amd64' \
	'gnome-control-center-data	1.0	all' \
	'halo-keyboard	1.0	all' \
	'libmutter-18-0	1.0	amd64' \
	'linux-headers-yogabook-test	1.0	amd64' \
	'linux-image-yogabook-test	1.0	amd64' \
	'mutter-common	1.0	all' \
	'mutter-common-bin	1.0	amd64' \
	'sof-topology-yogabook	1.0	all' \
	'yogabook-camera	1.0	all' \
	'yogabook-gnss	1.0	all' \
	'yogabook-sensors	1.0	all' \
	"yogabook-validator	${fixture_validator_version}	all" >"$package_inventory_fixture"
(
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	YBV_PACKAGE_INVENTORY_SOURCE="$package_inventory_fixture"
	ybv_capture_package_inventory "$package_inventory_copy"
)
cmp "$package_inventory_fixture" "$package_inventory_copy"
python3 - "$root/data/acceptance.json" "$root/docs/coverage.md" "$root/ui/yogabook_validator_ui.py" <<'PY'
import ast
import json
from pathlib import Path
import sys

matrix = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert matrix["schema"] == "org.yogabook.validator.acceptance/v1"
assert len(matrix["components"]) == 24
assert len({item["id"] for item in matrix["components"]}) == 24
for component in matrix["components"]:
    assert set(component["layers"]) == {"structural", "functional", "physical"}
    assert all(component["layers"][layer] for layer in component["layers"])
declared = {
    selector
    for component in matrix["components"]
    for layer in component["layers"].values()
    for selector in layer
}
assert set(matrix["unimplemented_selectors"]) <= declared
assert len(matrix["unimplemented_selectors"]) == 0

table_names = set()
for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines():
    if not line.startswith("|"):
        continue
    name = line.split("|", 2)[1].strip()
    if name not in {"Component", "---"}:
        table_names.add(name)
assert table_names == {item["name"] for item in matrix["components"]}

module = ast.parse(Path(sys.argv[3]).read_text(encoding="utf-8"))
assignment = next(
    node for node in module.body
    if isinstance(node, ast.Assign)
    and any(isinstance(target, ast.Name) and target.id == "PHYSICAL_CHECKS" for target in node.targets)
)
physical_ids = {item[0] for item in ast.literal_eval(assignment.value)}
group_assignment = next(
    node for node in module.body
    if isinstance(node, ast.Assign)
    and any(isinstance(target, ast.Name) and target.id == "PHYSICAL_GROUPS" for target in node.targets)
)
group_ids = [check_id for _title, _description, ids in ast.literal_eval(group_assignment.value) for check_id in ids]
assert len(group_ids) == len(set(group_ids)), "physical groups contain duplicate checks"
assert set(group_ids) == physical_ids, (physical_ids - set(group_ids), set(group_ids) - physical_ids)
required_physical = {
    selector.removeprefix("physical/")
    for component in matrix["components"]
    for selector in component["layers"]["physical"]
}
assert required_physical <= physical_ids, required_physical - physical_ids
PY
state_guard_root="$temporary/state-guard-root"
mkdir -p "$state_guard_root/sys/class/backlight/panel"
printf '10\n' >"$state_guard_root/sys/class/backlight/panel/brightness"
(
	export YBV_SYSROOT="$state_guard_root"
	export YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py"
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	ybv_begin_report state-guard-failure "$temporary/state-guard-failure"
	ybv_register_state_keys 'sysfs:panel:brightness'
	printf '11\n' >"$state_guard_root/sys/class/backlight/panel/brightness"
	finish_rc=0
	ybv_finish_report || finish_rc=$?
	[[ $finish_rc -eq 1 ]]
)
grep -Eq $'validator\tstate-preservation\tFAIL\t' "$temporary/state-guard-failure/results.tsv"
grep -Fq 'sysfs:panel:brightness' "$temporary/state-guard-failure/state-diff.txt"
printf '10\n' >"$state_guard_root/sys/class/backlight/panel/brightness"
(
	export YBV_SYSROOT="$state_guard_root"
	export YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py"
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	ybv_begin_report final-rollup-pass "$temporary/final-rollup-pass"
	YBV_FINAL_ROLLUP_CHECK_ID=storage-write
	YBV_FINAL_ROLLUP_STATUS=PASS
	YBV_FINAL_ROLLUP_SUMMARY='Synthetic write validation passed'
	YBV_FINAL_ROLLUP_DETAILS='partitions-passed=2'
	ybv_finish_report
)
grep -Eq $'suite\tstorage-write\tPASS\t' "$temporary/final-rollup-pass/results.tsv"
(
	export YBV_SYSROOT="$state_guard_root"
	export YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py"
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	ybv_begin_report final-rollup-failure "$temporary/final-rollup-failure"
	ybv_register_state_keys 'sysfs:panel:brightness'
	YBV_FINAL_ROLLUP_CHECK_ID=storage-write
	YBV_FINAL_ROLLUP_STATUS=PASS
	YBV_FINAL_ROLLUP_SUMMARY='Synthetic write validation passed'
	YBV_FINAL_ROLLUP_DETAILS='partitions-passed=2'
	printf '11\n' >"$state_guard_root/sys/class/backlight/panel/brightness"
	finish_rc=0
	ybv_finish_report || finish_rc=$?
	[[ $finish_rc -eq 1 ]]
)
grep -Eq $'suite\tstorage-write\tFAIL\t.*state-preservation=FAIL' "$temporary/final-rollup-failure/results.tsv"
printf '10\n' >"$state_guard_root/sys/class/backlight/panel/brightness"
(
	export YBV_SYSROOT="$state_guard_root"
	export YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py"
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	# Passed by name to ybv_register_restore_callback.
	# shellcheck disable=SC2329
	restore_test_panel() { printf '10\n' >"$state_guard_root/sys/class/backlight/panel/brightness"; }
	ybv_begin_report state-guard-restore "$temporary/state-guard-restore"
	ybv_register_restore_callback restore_test_panel
	printf '11\n' >"$state_guard_root/sys/class/backlight/panel/brightness"
	ybv_finish_report
)
grep -Eq $'validator\tstate-preservation\tPASS\t' "$temporary/state-guard-restore/results.tsv"
test ! -e "$temporary/state-guard-restore/state-diff.txt"
mkdir -p "$state_guard_root/sys/class/leds/ybwmi::kbd_backlight"
printf '[none]\n' >"$state_guard_root/sys/class/leds/ybwmi::kbd_backlight/trigger"
printf '8\n' >"$state_guard_root/sys/class/leds/ybwmi::kbd_backlight/brightness"
(
	export YBV_SYSROOT="$state_guard_root"
	export YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py"
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	ybv_begin_report state-guard-async-halo "$temporary/state-guard-async-halo"
	printf '0\n' >"$state_guard_root/sys/class/leds/ybwmi::kbd_backlight/brightness"
	ybv_finish_report
)
grep -Eq $'validator\tstate-preservation\tPASS\t' "$temporary/state-guard-async-halo/results.tsv"
test ! -e "$temporary/state-guard-async-halo/state-diff.txt"
(
	export YBV_SYSROOT="$state_guard_root"
	export YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py"
	export YBV_SERVICE_SETTLE_RETRIES=2
	export YBV_SERVICE_SETTLE_INTERVAL=0
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	ybv_begin_report state-guard-service-settle "$temporary/state-guard-service-settle"
	ybv_register_state_keys 'system-service:yogabook-camera.service'
	printf 'schema\torg.yogabook.validator.state/v1\nsystem-service:yogabook-camera.service\tstate=active/running restarts=0\n' >"$YBV_STATE_BEFORE"
	capture_attempt=0
	ybv_capture_state_snapshot() {
		capture_attempt=$((capture_attempt + 1))
		if ((capture_attempt == 1)); then
			printf 'schema\torg.yogabook.validator.state/v1\nsystem-service:yogabook-camera.service\tstate=inactive/dead restarts=0\n' >"$1"
		else
			cp -- "$YBV_STATE_BEFORE" "$1"
		fi
	}
	ybv_finish_report
)
grep -Eq $'validator\tstate-preservation\tPASS\tState owned by this test matches after asynchronous resources settled\tsettle-retries=1' \
	"$temporary/state-guard-service-settle/results.tsv"
test ! -e "$temporary/state-guard-service-settle/state-diff.txt"
printf '10\n' >"$state_guard_root/sys/class/backlight/panel/brightness"
(
	export YBV_SYSROOT="$state_guard_root"
	export YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py"
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	ybv_begin_report state-guard-external-drift "$temporary/state-guard-external-drift"
	ybv_register_state_keys 'system-service:yogabook-camera.service'
	printf '12\n' >"$state_guard_root/sys/class/backlight/panel/brightness"
	ybv_finish_report
)
grep -Eq $'validator\texternal-state-drift\tWARN\t.*sysfs:panel:brightness' \
	"$temporary/state-guard-external-drift/results.tsv"
grep -Eq $'validator\tstate-preservation\tPASS\tEvery mutable state key owned by this test was restored' \
	"$temporary/state-guard-external-drift/results.tsv"
test -s "$temporary/state-guard-external-drift/state-diff.txt"
printf '10\n' >"$state_guard_root/sys/class/backlight/panel/brightness"
(
	export YBV_SYSROOT="$state_guard_root"
	export YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py"
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	# Passed by name to ybv_register_restore_callback.
	# shellcheck disable=SC2329
	failing_cleanup() { return 9; }
	ybv_begin_report state-guard-cleanup-failure "$temporary/state-guard-cleanup-failure"
	ybv_register_restore_callback failing_cleanup
	finish_rc=0
	ybv_finish_report || finish_rc=$?
	[[ $finish_rc -eq 1 ]]
)
grep -Eq $'validator\tcleanup\tFAIL\t.*exit=9' "$temporary/state-guard-cleanup-failure/results.tsv"
grep -Eq $'validator\tstate-preservation\tPASS\t' "$temporary/state-guard-cleanup-failure/results.tsv"
(
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	[[ $(ybv_canonical_system_service_state activating/start 558) == \
		'state=activating/restarting restarts=volatile' ]]
	[[ $(ybv_canonical_system_service_state activating/auto-restart 559) == \
		'state=activating/restarting restarts=volatile' ]]
	[[ $(ybv_canonical_system_service_state active/running 0) == \
		'state=active/running restarts=0' ]]
	mkdir -p "$temporary/rfkill/rfkill0"
	printf 'bluetooth\n' >"$temporary/rfkill/rfkill0/type"
	printf '1\n' >"$temporary/rfkill/rfkill0/soft"
	printf '0\n' >"$temporary/rfkill/rfkill0/hard"
	ybv_bluetooth_rfkill_blocked "$temporary/rfkill"
	printf '0\n' >"$temporary/rfkill/rfkill0/soft"
	! ybv_bluetooth_rfkill_blocked "$temporary/rfkill"
)
python3 - <<PY
import ast
import xml.etree.ElementTree as ET
ast.parse(open("$root/ui/yogabook_validator_ui.py", encoding="utf-8").read())
ET.parse("$root/data/metainfo/org.yogabook.Validator.metainfo.xml")
ET.parse("$root/data/org.yogabook.validator.policy")
PY

if command -v desktop-file-validate >/dev/null; then
	desktop-file-validate "$root/data/org.yogabook.Validator.desktop"
fi
if command -v appstreamcli >/dev/null; then
	appstreamcli validate --no-net "$root/data/metainfo/org.yogabook.Validator.metainfo.xml"
fi

package_version=$(dpkg-parsechangelog -l"$root/debian/changelog" -S Version)
cli_version=$(sed -n 's/^YBV_VERSION=//p' "$root/libexec/yogabook-validator-common.sh" | head -n 1)
metainfo_version=$(python3 - "$root/data/metainfo/org.yogabook.Validator.metainfo.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
print(root.find("./releases/release").attrib["version"])
PY
)
[[ $cli_version == "$package_version" ]]
[[ $metainfo_version == "$package_version" ]]
grep -Fq "yogabook-validator_${package_version}_all.deb" "$root/README.md"
grep -Fq 'docs/coverage.md' "$root/debian/yogabook-validator.docs"
grep -Fq 'data/acceptance.json usr/share/yogabook-validator' "$root/debian/yogabook-validator.install"

store_line=$(grep -n 'store yogabook' "$root/libexec/yogabook-validator-active.sh" | head -n1 | cut -d: -f1)
stop_line=$(grep -n 'systemctl --user stop' "$root/libexec/yogabook-validator-active.sh" | head -n1 | cut -d: -f1)
[[ -n $store_line && -n $stop_line && $store_line -lt $stop_line ]]
grep -Fq 'systemctl --user stop wireplumber' "$root/libexec/yogabook-validator-active.sh"
if grep -Fq 'systemctl --user start wireplumber' "$root/libexec/yogabook-validator-active.sh"; then
	echo 'active audio tests must not restore stale clients with a WirePlumber-only start' >&2
	exit 1
fi
if grep -Eq 'systemctl --user (stop|start).*pipewire' "$root/libexec/yogabook-validator-active.sh"; then
	echo 'active audio tests must keep the PipeWire engine and sockets running' >&2
	exit 1
fi
grep -Fq 'systemctl --user restart' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'pipewire.service pipewire-pulse.service wireplumber.service' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'desktop_audio_probe' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'desktop_profile=' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'alsa\.id = "yogabook"' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'awk -v card="$desktop_card"' "$root/libexec/yogabook-validator-active.sh"
if grep -Fq 'alsa_card.platform-cht-yogabook' "$root/libexec/yogabook-validator-active.sh"; then
	echo 'active audio validation must discover the Yoga Book PipeWire card by ALSA identity' >&2
	exit 1
fi
grep -Fq 'pactl set-card-profile' "$root/libexec/yogabook-validator-active.sh"
grep -Fq "cget name='Int Mic Switch'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "cget name='Sto1 ADC MIXL ADC2 Switch'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "cget name='Sto1 ADC MIXR ADC2 Switch'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "speaker-tone WARN 'Bounded speaker transport recovered on one retry" "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'pw-play "$silence_file"' "$root/libexec/yogabook-validator-active.sh"
if grep -Fq 'pw-play "$tone_file"' "$root/libexec/yogabook-validator-active.sh"; then
	echo 'post-restore desktop transport probe must remain silent' >&2
	exit 1
fi
grep -Fq 'yogabook-validator-audio-analyze.py' "$root/libexec/yogabook-validator-active.sh"
grep -Fq -- '--expected-seconds 3 "$capture_file"' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'Retain only derived metrics' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'Enabled and verified HiFi' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'channel-imbalance' "$root/libexec/yogabook-validator-audio-analyze.py"
grep -Fq 'dc-offset' "$root/libexec/yogabook-validator-audio-analyze.py"
grep -Fq 'Bounded speaker tone failed twice' "$root/libexec/yogabook-validator-active.sh"
grep -Fq '. "$LIBEXEC_DIR/yogabook-validator-audio-levels.sh"' "$root/libexec/yogabook-validator-active.sh"
grep -Fq "cget name='1 Master Playback Volume'" "$root/libexec/yogabook-validator-audio-levels.sh"
grep -Fq "cget name='DAC1 Playback Volume'" "$root/libexec/yogabook-validator-audio-levels.sh"
grep -Fq '((master_left <= 24)) || master_left=24' "$root/libexec/yogabook-validator-audio-levels.sh"
grep -Fq '((dac_left <= 87)) || dac_left=87' "$root/libexec/yogabook-validator-audio-levels.sh"
grep -Fq 'playback-level-cap FAIL' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'parec --device="${default_sink}.monitor"' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'pcm0p/sub0/status' "$root/libexec/yogabook-validator-active.sh"
grep -Fq "cget name='Speaker Switch'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'Desktop playback required a second full audio-graph restart' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'pactl parec pw-play wpctl systemctl' "$root/libexec/yogabook-validator-active.sh"
grep -Eq '^ python3-evdev, python3-gi, pipewire-bin, procps, pulseaudio-utils,' "$root/debian/control"
grep -Fq 'chown -- "$report_owner:$(id -gn "$report_owner")" "$YBV_RESULTS_BASE"' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'generated_default=true' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'ybv_chown_tree_to_user "$YBV_AUTO_REPORT_OWNER" "$YBV_REPORT_DIR"' "$root/libexec/yogabook-validator-common.sh"
grep -Fq "trap 'restore_state || true' EXIT" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "trap 'exit 130' INT" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "trap 'exit 143' TERM" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "state-restore FAIL" "$root/libexec/yogabook-validator-active.sh"
if grep -Fq 'set _verb HiFi list _devices' "$root/libexec/yogabook-validator-check.sh"; then
	echo 'passive audit must not activate a UCM verb' >&2
	exit 1
fi
grep -Fq "grep -Fq 'Built-in Audio'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'suspend-playback.log' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'suspend-capture.log' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'stream-xruns' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'yogabook-validator-resume.py" --capture' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'resume-services' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'speaker-muted PASS' "$root/libexec/yogabook-validator-active.sh"
grep -Fq "cset name='Speaker Switch' off" "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'ff.Replay(150, 0)' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'strong_magnitude=0x5000' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'YBV_ACTIVE_DISPATCH=1' "$root/libexec/yogabook-validator-active.sh"
# The following fixed-string assertions intentionally contain literal shell syntax.
# shellcheck disable=SC2016
grep -Fq 'ybv_run_as_user "$real_user" mkdir -p -- "$output_dir"' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'run_subtest audio' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'run_subtest display' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'run_subtest platform' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'run_subtest internal-storage' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'include_suspend == true' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'ybv_classify_gnss_final_state' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'audio-final-state PASS' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'services-final-state PASS' "$root/libexec/yogabook-validator-automated.sh"
gnss_final_line=$(grep -nF 'ybv_emit suite gnss-final-state' "$root/libexec/yogabook-validator-automated.sh" | cut -d: -f1)
audio_run_line=$(grep -nF 'run_subtest audio' "$root/libexec/yogabook-validator-automated.sh" | tail -n 1 | cut -d: -f1)
((gnss_final_line > audio_run_line))
(
	# shellcheck source=../libexec/yogabook-validator-common.sh
	. "$root/libexec/yogabook-validator-common.sh"
	[[ $(ybv_classify_gnss_final_state false false 0 0) == SKIP$'\t'*runtime=missing* ]]
	[[ $(ybv_classify_gnss_final_state true true 4 4) == PASS$'\t'*restarts=4 ]]
	[[ $(ybv_classify_gnss_final_state true true 4 5) == FAIL$'\t'*before=4\ after=5 ]]
	[[ $(ybv_classify_gnss_final_state true false 4 4) == FAIL$'\t'*state\ or\ restart\ counter* ]]
	[[ $(ybv_classify_gnss_final_state true true missing 4) == FAIL$'\t'*state\ or\ restart\ counter* ]]
	[[ $(printf '%s\n' 'clean boot' | ybv_classify_root_storage_journal mmcblk0 mmcblk0p2 0) == PASS$'\t'*device=mmcblk0p2 ]]
	[[ $(printf '%s\n' 'mmcblk0: timed out waiting for hardware interrupt' | ybv_classify_root_storage_journal mmcblk0 mmcblk0p2 0) == FAIL$'\t'*timed\ out* ]]
	[[ $(printf '%s\n' 'blk_update_request: I/O error, dev mmcblk0, sector 8' | ybv_classify_root_storage_journal mmcblk0 mmcblk0p2 0) == FAIL$'\t'*I/O\ error* ]]
	[[ $(printf '%s\n' 'Buffer I/O error on dev mmcblk0p2, logical block 1' | ybv_classify_root_storage_journal mmcblk0 mmcblk0p2 0) == FAIL$'\t'*I/O\ error* ]]
	[[ $(printf '%s\n' 'Buffer I/O error on dev mmcblk1p1, logical block 1' | ybv_classify_root_storage_journal mmcblk0 mmcblk0p2 0) == PASS$'\t'*device=mmcblk0p2 ]]
	[[ $(printf '%s\n' 'clean boot' | ybv_classify_root_storage_journal mmcblk0 mmcblk0p2 1) == SKIP$'\t'*exit=1 ]]
)
for passive_check in check apt platform resources display sensors power charging usb gnss; do
	grep -Fq "run_subtest $passive_check" "$root/libexec/yogabook-validator-passive.sh"
done
if grep -Eq 'camera|audio|haptics|lights|modem|storage|wireless|suspend|pkexec|sudo' "$root/libexec/yogabook-validator-passive.sh"; then
	echo 'passive suite must contain only read-only unprivileged checks' >&2
	exit 1
fi
grep -Fq 'passive                Run every read-only validation as one merged suite' "$root/src/yogabook-validator.sh"
grep -Fq 'resources              Profile Yoga Book services and thermal safeguards' "$root/src/yogabook-validator.sh"
grep -Fq 'stability ACTION       Track operator-confirmed cold-boot validation' "$root/src/yogabook-validator.sh"
grep -Fq 'self.run_command("passive", [])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.run_command("resources", [])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.run_command("modem", [])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.run_command("headset", ["--yes", "--timeout", "90"])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.run_command("quiet", ["--yes"])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.run_command("dossier", [str(source) for source in sources])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'chooser.set_select_multiple(True)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'Layer readiness · ' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.run_command("stability", ["start", "3"])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.run_command("stability", ["check"])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.pointer_overlay.set_can_target(False)' "$root/libexec/yogabook-validator-sensor-interactions.py"
grep -Fq 'motion.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)' "$root/libexec/yogabook-validator-sensor-interactions.py"
grep -Fq 'signal.signal(signal.SIGTERM, stop)' "$root/libexec/yogabook-validator-sensor-interactions.py"
grep -Fq "trap 'cancelled=true' INT TERM" "$root/libexec/yogabook-validator-sensor-interactions.sh"
grep -Fq 'trap - INT TERM' "$root/libexec/yogabook-validator-sensor-interactions.sh"
grep -Fq 'yogabook-validator-passive.sh' "$root/libexec/yogabook-validator-full.sh"
grep -Fq 'check_package yogabook-validator platform "$YBV_VERSION"' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'Persistent GRUB top-level selects the running Yoga Book kernel' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'check_package yogabook-camera camera 0.2.20' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'check_package yogabook-gnss gnss 1.0.3' "$root/libexec/yogabook-validator-check.sh"
grep -Fq "check_package libmutter-18-0 display '50.1-0ubuntu2.2+yogabook5'" "$root/libexec/yogabook-validator-check.sh"
grep -Fq "check_package halo-keyboard input '1.0.0-7'" "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'IntegratedIn=System' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'pen-dynamic-calibration PASS' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'camera_driver_bound /sys/bus/pci/drivers/atomisp-isp2' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'camera_driver_bound /sys/bus/i2c/drivers/ov2740' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'camera_driver_bound /sys/bus/i2c/drivers/ov8858' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'ybv_check_camera_readiness "$kernel"' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'modinfo -k "$kernel" -F filename v4l2loopback' "$root/libexec/yogabook-validator-camera-readiness.sh"
grep -Fq 'blocked_by=camera/kernel-headers' "$root/libexec/yogabook-validator-camera-readiness.sh"
grep -Fq 'blocked_by=camera/v4l2loopback-module' "$root/libexec/yogabook-validator-camera-readiness.sh"
grep -Fq 'dpkg --verify "$package"' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'package-integrity PASS' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'restart_count_before=' "$root/libexec/yogabook-validator-gnss.sh"
grep -Fq 'runtime-assets FAIL' "$root/libexec/yogabook-validator-gnss.sh"
grep -Fq 'yogabook-gnss-build-runtime' "$root/libexec/yogabook-validator-gnss.sh"
grep -Fq "ybv_emit gnss gpsd SKIP 'gpsd cannot expose GNSS reports until the private transport runtime is imported'" "$root/libexec/yogabook-validator-gnss.sh"
grep -Fq 'gnss runtime-assets FAIL' "$root/libexec/yogabook-validator-check.sh"
grep -Fq "ybv_emit gnss services SKIP 'GNSS services cannot start until the private runtime is imported'" \
	"$root/libexec/yogabook-validator-check.sh"
grep -Fq "ybv_emit gnss nmea-pipe SKIP 'The GNSS NMEA pipe cannot exist until the private runtime is imported'" \
	"$root/libexec/yogabook-validator-check.sh"
grep -Fq 'service-stability PASS' "$root/libexec/yogabook-validator-gnss.sh"
grep -Fq 'service-stability FAIL' "$root/libexec/yogabook-validator-gnss.sh"

apt_root="$temporary/apt-root"
fake_apt_get="$temporary/fake-apt-get"
apt_args="$temporary/fake-apt-args"
mkdir -p "$apt_root"
sed 's/^\t//' >"$fake_apt_get" <<'EOF'
	#!/usr/bin/env bash
	set -Eeuo pipefail
	lists_dir=
	print_uris=false
	previous=
	for argument in "$@"; do
		printf '%s\n' "$argument" >>"$YBV_FAKE_APT_ARGS"
		if [[ $previous == -o && $argument == Dir::State::lists=* ]]; then
			lists_dir=${argument#Dir::State::lists=}
		fi
		[[ $argument == --print-uris ]] && print_uris=true
		previous=$argument
	done
	if $print_uris; then
		printf "'https://user:secret@example.invalid/ubuntu/dists/test/InRelease' example_InRelease 0\n"
		exit 0
	fi
	if [[ ${YBV_FAKE_APT_RESULT:-pass} == fail ]]; then
		printf '%s\n' 'Err:1 http://127.0.0.1/ubuntu-offline InRelease' 'E: Connection refused' >&2
		exit 100
	fi
	[[ -n $lists_dir ]]
	mkdir -p "$lists_dir"
	touch "$lists_dir/example_InRelease"
	printf '%s\n' 'Get:1 https://example.invalid/ubuntu test InRelease'
EOF
chmod +x "$fake_apt_get"
YBV_SYSROOT="$apt_root" YBV_APT_GET="$fake_apt_get" YBV_APT_TMP_BASE="$temporary" \
	YBV_FAKE_APT_ARGS="$apt_args" YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	"$root/src/yogabook-validator.sh" apt --output "$temporary/apt-pass"
grep -Fq $'platform\tapt-sources\tPASS\tAPT exposes enabled repository metadata targets' \
	"$temporary/apt-pass/results.tsv"
grep -Fq $'platform\tapt-update\tPASS\tEvery configured APT repository returned valid release metadata' \
	"$temporary/apt-pass/results.tsv"
grep -Eq $'validator\tstate-preservation\tPASS\t' "$temporary/apt-pass/results.tsv"
grep -Fq 'APT::Update::Error-Mode=any' "$apt_args"
grep -Fq 'Acquire::IndexTargets::deb::Packages::DefaultEnabled=false' "$apt_args"
if grep -Fq '/var/lib/apt/lists' "$apt_args"; then
	echo 'APT validation must not use the system list directory' >&2
	exit 1
fi
grep -Fq 'https://[redacted]@example.invalid/' "$temporary/apt-pass/validator.log"
if grep -Fq 'user:secret' "$temporary/apt-pass/validator.log"; then
	echo 'APT validation log leaked repository credentials' >&2
	exit 1
fi
if find "$temporary" -maxdepth 1 -type d -name 'yogabook-validator-apt.*' -print -quit | grep -q .; then
	echo 'APT validation left a disposable workspace behind' >&2
	exit 1
fi

apt_fail_rc=0
: >"$apt_args"
YBV_SYSROOT="$apt_root" YBV_APT_GET="$fake_apt_get" YBV_APT_TMP_BASE="$temporary" \
	YBV_FAKE_APT_ARGS="$apt_args" YBV_FAKE_APT_RESULT=fail \
	YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	"$root/src/yogabook-validator.sh" apt --output "$temporary/apt-fail" || apt_fail_rc=$?
[[ $apt_fail_rc -eq 1 ]]
grep -Fq $'platform\tapt-sources\tPASS\tAPT exposes enabled repository metadata targets' \
	"$temporary/apt-fail/results.tsv"
grep -Fq $'platform\tapt-update\tFAIL\tOne or more configured APT repositories failed an isolated metadata refresh' \
	"$temporary/apt-fail/results.tsv"
grep -Fq '127.0.0.1/ubuntu-offline' "$temporary/apt-fail/validator.log"
grep -Eq $'validator\tstate-preservation\tPASS\t' "$temporary/apt-fail/results.tsv"

charge_root="$temporary/charge-root"
charge_fixture="$temporary/charge-fixture.tsv"
mkdir -p "$charge_root/sys/class/dmi/id"
printf 'LenovoYB1-X91L\n' >"$charge_root/sys/class/dmi/id/product_name"
charge_header=$'epoch\tcharger_online\tsource_online\tcharger_health\tbattery_status\tcapacity_percent\tcharge_now_uah\tcharge_full_uah\tcurrent_ua\tbattery_temp_deci_c\tcharger_temp_deci_c\tcharger_voltage_uv'
printf '%s\n' "$charge_header" \
	$'1\t1\t1\tGood\tFull\t100\t7590000\t7590000\t-6000\t350\t340\t4324000' \
	$'2\t1\t1\tGood\tFull\t100\t7590000\t7590000\t-5000\t351\t341\t4325000' \
	$'3\t1\t1\tGood\tFull\t100\t7590000\t7590000\t-4000\t351\t341\t4325000' >"$charge_fixture"
YBV_SYSROOT="$charge_root" YBV_CHARGE_SAMPLE_SOURCE="$charge_fixture" \
	YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	"$root/src/yogabook-validator.sh" charging --seconds 15 --output "$temporary/charging-full"
grep -Fq $'power\tcharger-continuity\tPASS\t' "$temporary/charging-full/results.tsv"
grep -Fq $'power\tcharge-progress\tPASS\tBattery remained at its terminal full-charge state' \
	"$temporary/charging-full/results.tsv"
grep -Fq $'power\tcharge-session\tPASS\t' "$temporary/charging-full/results.tsv"

printf '%s\n' "$charge_header" \
	$'1\t1\t1\tGood\tCharging\t50\t4000000\t7590000\t-500000\t330\t340\t5000000' \
	$'2\t1\t1\tGood\tCharging\t50\t4001000\t7590000\t-490000\t331\t341\t5001000' \
	$'3\t1\t1\tGood\tCharging\t50\t4003000\t7590000\t-480000\t332\t342\t5002000' >"$charge_fixture"
YBV_SYSROOT="$charge_root" YBV_CHARGE_SAMPLE_SOURCE="$charge_fixture" \
	YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	"$root/src/yogabook-validator.sh" charging --seconds 15 --output "$temporary/charging-progress"
grep -Fq $'power\tcharge-progress\tPASS\tFuel-gauge charge increased' "$temporary/charging-progress/results.tsv"

printf '%s\n' "$charge_header" \
	$'1\t0\t0\tGood\tDischarging\t50\t4000000\t7590000\t250000\t330\t320\t0' \
	$'2\t0\t0\tGood\tDischarging\t50\t3999000\t7590000\t260000\t331\t321\t0' >"$charge_fixture"
YBV_SYSROOT="$charge_root" YBV_CHARGE_SAMPLE_SOURCE="$charge_fixture" \
	YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	"$root/src/yogabook-validator.sh" charging --seconds 15 --output "$temporary/charging-offline"
grep -Fq $'power\tcharger-continuity\tSKIP\t' "$temporary/charging-offline/results.tsv"
grep -Fq $'power\tcharge-session\tSKIP\t' "$temporary/charging-offline/results.tsv"

printf '%s\n' "$charge_header" \
	$'1\t1\t1\tGood\tCharging\t50\t4000000\t7590000\t-500000\t451\t340\t5000000' \
	$'2\t1\t1\tGood\tCharging\t50\t4000000\t7590000\t-500000\t452\t341\t5001000' >"$charge_fixture"
charge_fail_rc=0
YBV_SYSROOT="$charge_root" YBV_CHARGE_SAMPLE_SOURCE="$charge_fixture" \
	YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	"$root/src/yogabook-validator.sh" charging --seconds 15 --output "$temporary/charging-unsafe" || charge_fail_rc=$?
[[ $charge_fail_rc -eq 1 ]]
grep -Fq $'power\tcharge-temperature\tFAIL\t' "$temporary/charging-unsafe/results.tsv"
grep -Fq $'power\tcharge-progress\tFAIL\tNo measurable fuel-gauge charge increase' "$temporary/charging-unsafe/results.tsv"
grep -Fq $'power\tcharge-session\tFAIL\t' "$temporary/charging-unsafe/results.tsv"

gnss_root="$temporary/gnss-root"
gnss_bin="$temporary/gnss-bin"
mkdir -p "$gnss_root" "$gnss_bin"
gnss_missing_rc=0
YBV_SYSROOT="$gnss_root" YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	"$root/src/yogabook-validator.sh" gnss --output "$temporary/gnss-missing" || gnss_missing_rc=$?
[[ $gnss_missing_rc -eq 1 ]]
grep -Fq $'gnss\tdevice\tWARN\tNo dedicated GNSS device node is present' \
	"$temporary/gnss-missing/results.tsv"
grep -Fq $'gnss\tgpsd\tSKIP\tgpsd cannot expose GNSS reports until the private transport runtime is imported' \
	"$temporary/gnss-missing/results.tsv"

mkdir -p "$gnss_root/var/lib/yogabook-gnss/root/system/vendor/bin"
touch "$gnss_root/var/lib/yogabook-gnss/root/system/vendor/bin/gpsd"
chmod +x "$gnss_root/var/lib/yogabook-gnss/root/system/vendor/bin/gpsd"
sed 's/^\t//' >"$gnss_bin/yogabook-gnss-health" <<'EOF'
	#!/usr/bin/env bash
	case ${YBV_FAKE_GNSS_HEALTH:-pass} in
	pass)
		printf '%s\n' \
			'gpsd TPV stream: present' \
			'SKY status: gpsd SKY present' \
			'Fix status: 2D/3D fix present' \
			'HEALTH_RESULT: PASS' \
			'TRANSPORT_RESULT: PASS'
		;;
	transport-only)
		printf '%s\n' 'HEALTH_RESULT: PASS' 'TRANSPORT_RESULT: PASS'
		;;
	fail)
		printf '%s\n' 'HEALTH_RESULT: FAIL' 'TRANSPORT_RESULT: FAIL'
		;;
	*) exit 2 ;;
	esac
EOF
chmod +x "$gnss_bin/yogabook-gnss-health"
PATH="$gnss_bin:$PATH" YBV_SYSROOT="$gnss_root" \
	YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	"$root/src/yogabook-validator.sh" gnss --output "$temporary/gnss-health-pass"
grep -Fq $'gnss\tgpsd\tPASS\tgpsd returned GNSS position reports' \
	"$temporary/gnss-health-pass/results.tsv"
PATH="$gnss_bin:$PATH" YBV_SYSROOT="$gnss_root" YBV_FAKE_GNSS_HEALTH=transport-only \
	YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	"$root/src/yogabook-validator.sh" gnss --output "$temporary/gnss-health-warning"
grep -Fq $'gnss\tgpsd\tWARN\tThe transport passed, but the health probe did not confirm a gpsd TPV stream' \
	"$temporary/gnss-health-warning/results.tsv"
gnss_health_fail_rc=0
PATH="$gnss_bin:$PATH" YBV_SYSROOT="$gnss_root" YBV_FAKE_GNSS_HEALTH=fail \
	YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	"$root/src/yogabook-validator.sh" gnss --output "$temporary/gnss-health-fail" || gnss_health_fail_rc=$?
[[ $gnss_health_fail_rc -eq 1 ]]
grep -Fq $'gnss\tgpsd\tFAIL\tThe GNSS health probe did not observe a working gpsd TPV stream' \
	"$temporary/gnss-health-fail/results.tsv"
for report_writer in yogabook-validator-active.sh yogabook-validator-automated.sh; do
	finish_line=$(grep -nF 'ybv_finish_report || finish_rc=$?' "$root/libexec/$report_writer" | tail -n 1 | cut -d: -f1)
	# shellcheck disable=SC2016
	owner_line=$(grep -nF 'ybv_chown_tree_to_user "$real_user"' "$root/libexec/$report_writer" | tail -n 1 | cut -d: -f1)
	[[ -n $finish_line && -n $owner_line && $finish_line -lt $owner_line ]]
done
grep -Fq 'finish_report_for_user || finish_rc=$?' "$root/libexec/yogabook-validator-active.sh"
same_user=$(id -un)
same_uid=$(id -u)
same_user_runtime=$(bash -c '. "$1"; ybv_run_as_user "$2" sh -c '\''printf %s "$XDG_RUNTIME_DIR"'\''' \
	_ "$root/libexec/yogabook-validator-common.sh" "$same_user")
[[ $same_user_runtime == "/run/user/$same_uid" ]]
# shellcheck disable=SC2016
grep -Fq 'chown -R -- "$user:$group" "$path"' "$root/libexec/yogabook-validator-common.sh"
# shellcheck disable=SC2016
if grep -RqF 'chown -R -- "$real_user:' "$root/libexec"; then
	echo 'report ownership must use the explicit primary group helper' >&2
	exit 1
fi
for report_writer in yogabook-validator-controls.sh yogabook-validator-inputs.sh yogabook-validator-lights.sh yogabook-validator-modes.sh yogabook-validator-storage.sh yogabook-validator-wireless.sh; do
	# shellcheck disable=SC2016
	grep -Fq 'ybv_finish_report_for_user "$real_user"' "$root/libexec/$report_writer"
done
grep -Fq 'Command output' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'Open detailed report' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'suite roll-ups' "$root/ui/yogabook_validator_ui.py"
for validation_group in 'Recommended workflows' 'Audio and media' 'Input and sensors' \
	'Platform and power' 'Connectivity and storage' 'Reliability' 'Guided physical validation'; do
	grep -Fq "$validation_group" "$root/ui/yogabook_validator_ui.py"
done
grep -Fq 'actions.set_header_suffix(category_box)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'category_box.set_halign(Gtk.Align.END)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'row_action_box.set_size_request(76, 44)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'row_status_slot.set_size_request(24, 24)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'row_action_slot.set_size_request(44, 44)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'row_status_icon.set_halign(Gtk.Align.START)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'button.set_halign(Gtk.Align.START)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'category_box.set_size_request(76, 44)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'category_status_slot.set_size_request(24, 24)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'category_action_slot.set_size_request(44, 44)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'category_status_icon.set_halign(Gtk.Align.START)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'category_button.set_halign(Gtk.Align.START)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'category_button.set_size_request(44, 44)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'button = self.create_action_button("media-playback-start-symbolic", 18)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'category_button = self.create_action_button("media-playback-start-symbolic", 24)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'icon.set_halign(Gtk.Align.START)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'content.set_hexpand(True)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.run_button_icons[button].set_from_icon_name(icon_name)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'button_tooltip = title' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'category_tooltip = f"Run all checks in {section_title}"' "$root/ui/yogabook_validator_ui.py"
grep -Fq '"media-playback-stop-symbolic"' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'button.update_property([Gtk.AccessibleProperty.LABEL], [label])' "$root/ui/yogabook_validator_ui.py"
for validation_category in recommended audio-media input-modes platform-power connectivity-storage reliability; do
	grep -Fq "$validation_category)" "$root/libexec/yogabook-validator-category.sh"
	grep -Fq "\"$validation_category\"" "$root/ui/yogabook_validator_ui.py"
done
grep -Fq 'run_subtest automated' "$root/libexec/yogabook-validator-category.sh"
grep -Fq 'run_subtest resources' "$root/libexec/yogabook-validator-category.sh"
grep -Fq 'run_subtest storage-write' "$root/libexec/yogabook-validator-category.sh"
grep -Fq 'run_subtest pen-stack' "$root/libexec/yogabook-validator-category.sh"
grep -Fq 'run_subtest modem' "$root/libexec/yogabook-validator-category.sh"
if grep -Eq 'run_subtest (headset|controls|modes|rotation|sensor-interactions|pen-mapping|usb-cycle)([[:space:]]|$)' \
	"$root/libexec/yogabook-validator-category.sh"; then
	echo 'automatic category runners must not schedule guided physical validation' >&2
	exit 1
fi
grep -Fq '"Guided physical validation"' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'excluded from every automatic category runner' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'run_subtest modem' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'run_subtest pen-stack' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq "cget name='Headphone Jack'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "cget name='Headset Mic Jack'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "cget name='Speaker Switch'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'speakers=off' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'silence.wav' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'yogabook-validator-headset-events.py' "$root/libexec/yogabook-validator-active.sh"
if grep -Fq '.grab(' "$root/libexec/yogabook-validator-headset-events.py"; then
	echo 'headset event validation must not grab the input device' >&2
	exit 1
fi
grep -Fq '["ping", "-I", interface, "-c", "3"' "$root/libexec/yogabook-validator-modem.py"
grep -Fq 'state-failed-reason' "$root/libexec/yogabook-validator-modem.py"
if grep -Eq 'simple-connect|--enable|--disable|connection (up|down)' "$root/libexec/yogabook-validator-modem.py" "$root/libexec/yogabook-validator-modem.sh"; then
	echo 'LTE validation must not change modem or NetworkManager state' >&2
	exit 1
fi
grep -Fq 'run_subtest suspend' "$root/libexec/yogabook-validator-category.sh"
grep -Fq "ybv_emit suite stability SKIP 'A physical cold boot is required" "$root/libexec/yogabook-validator-category.sh"
grep -Fq 'category NAME          Run one compatible validation category as a merged suite' "$root/src/yogabook-validator.sh"
grep -Fq 'report.html' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'yogabook-validator-report.py' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'report DIRECTORY' "$root/src/yogabook-validator.sh"
grep -Fq 'dossier REPORT...      Compose compatible reports into an acceptance dossier' "$root/src/yogabook-validator.sh"
grep -Fq 'apt | charging | check | display | dossier | gnss' "$root/src/yogabook-validator.sh"
python_line=$(grep -nF 'python3 "$LIBEXEC_DIR/yogabook-validator-dossier.py"' "$root/libexec/yogabook-validator-dossier.sh" | cut -d: -f1)
# shellcheck disable=SC2016
owner_line=$(grep -nF 'ybv_chown_tree_to_user "$real_user" "$output_dir"' "$root/libexec/yogabook-validator-dossier.sh" | cut -d: -f1)
[[ -n $python_line && -n $owner_line && $python_line -lt $owner_line ]]
grep -Fq 'quiet                  Run all non-audible, non-haptic automated diagnostics' "$root/src/yogabook-validator.sh"
grep -Fq 'apt                    Verify configured repositories with isolated metadata' "$root/src/yogabook-validator.sh"
grep -Fq 'self.run_command("apt", [])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.run_streaming_command(argv, output)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'GLib.idle_add(self.append_console, line)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'subtest_start = re.match(r"^===== Running ([a-z0-9-]+) =====$", clean)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.set_subtest_running(subtest_start.group(1))' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.set_subtest_result(check_id, status)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'status == "SKIP"' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'media-playback-pause-symbolic' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.set_row_running(self.active_subtests[-1][1])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.set_run_buttons_sensitive(False)' "$root/ui/yogabook_validator_ui.py"
grep -Fq '"Stop validation"' "$root/ui/yogabook_validator_ui.py"
grep -Fq '"Stopping validation…"' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.set_row_running(self.current_run_button)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'icon.set_from_icon_name("emblem-ok-symbolic")' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'icon.set_from_icon_name("dialog-error-symbolic")' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'icon.set_from_icon_name("process-stop-symbolic")' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.cancel_file.touch()' "$root/ui/yogabook_validator_ui.py"
grep -Fq '"camera",' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'cleanup_files=[answers]' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'start_new_session=True' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'CANCELLATION_REQUESTED: stopping the active test and restoring hardware state' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'cancellation file must be inside the report directory' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'ybv_capture_state_snapshot "$YBV_STATE_BEFORE"' "$root/libexec/yogabook-validator-common.sh"
snapshot_service_line=$(grep -n -F 'for unit in halo-keyboard.service yogabook-camera.service' "$root/libexec/yogabook-validator-common.sh" | cut -d: -f1)
snapshot_mount_line=$(grep -n -F "printf 'temporary:validator-mounts" "$root/libexec/yogabook-validator-common.sh" | cut -d: -f1)
[[ -n $snapshot_service_line && -n $snapshot_mount_line ]]
((snapshot_service_line > snapshot_mount_line))
grep -Fq 'ybv_verify_state_preservation || state_rc=$?' "$root/libexec/yogabook-validator-common.sh"
for restoring_runner in active camera lights storage wireless; do
	grep -Fq 'ybv_register_restore_callback' "$root/libexec/yogabook-validator-$restoring_runner.sh"
done
for bounded_bluetooth_command in \
	'timeout 5 btmgmt --index "$controller_index" stop-find' \
	'timeout 5 bluetoothctl show'; do
	grep -Fq "$bounded_bluetooth_command" "$root/libexec/yogabook-validator-wireless.sh"
done
grep -Fq 'does not grab devices' "$root/README.md"
grep -Fq 'capabilities(absinfo=False)' "$root/libexec/yogabook-validator-inputs.sh"
grep -Fq 'capabilities(absinfo=False)' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'LIBINPUT_CALIBRATION_MATRIX' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'Wacom HID 169 Pen' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'HDP0001:00 2ABB:8102' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'stable_samples=10' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'mode-transition.tsv' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'pen-continuity' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'i2c-WCOM0019:00' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'bound:i2c_hid' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'halo-landscape-restored' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'expected=DSI-1 1920x1200 transform=0' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq -- '--all-orientations' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq -- '--pen-mapping' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'pen-mapping-stylus-source' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'raw coordinates discarded' "$root/libexec/yogabook-validator-modes.sh"
python3 "$root/libexec/yogabook-validator-pen-targets.py" --self-test
python3 "$root/libexec/yogabook-validator-mode-trace-result.py" --self-test
python3 "$root/libexec/yogabook-validator-resume.py" --self-test
grep -Fq 'controller.get_current_event_device()' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'Gtk.EventControllerMotion.new()' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'Gtk.GestureStylus.new()' "$root/libexec/yogabook-validator-pen-targets.py"
if grep -Fq 'Gtk.GestureClick.new()' "$root/libexec/yogabook-validator-pen-targets.py"; then
	echo 'pen targets must not rely on generic mouse-click gesture arbitration' >&2
	exit 1
fi
grep -Fq 'self.pen_position = (x, y)' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'Target accepted. Move the pen to the next highlighted circle.' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'last transient crosshair visible' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'event.get_axis(Gdk.AxisUse.PRESSURE)' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'Gdk.ModifierType.BUTTON1_MASK' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'is_tip_contact(has_pressure, pressure, modifiers)' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'device.get_source()' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'event.get_device_tool()' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'self.accepted_event_paths.add(event_path)' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'self.accepted_contacts.append(' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'len(normalized_contacts) == sum(stage_hits.values()) <= 20' \
	"$root/libexec/yogabook-validator-pen-result.py"
grep -Fq 'PASS requires exactly twenty accepted contacts' \
	"$root/libexec/yogabook-validator-pen-result.py"
grep -Fq 'dedicated_stylus=True' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'Keep the application-drawn cursor visible' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'PEN_CONTACT_IGNORED: reason=orientation-not-stable' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'events=$accepted_paths verified-by=$accepted_verifiers' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'PEN_TARGET_HIT: stage=' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'PEN_TARGET_MISS: stage=' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'observed_sensor_orientation' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'Target missed. Keep the yellow crosshair' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'SensorProxy and Mutter agree' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'raw pen coordinates are discarded' "$root/libexec/yogabook-validator-pen-targets.py"
grep -Fq 'rotation-upright-return' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'expected_transform_for_sensor' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'AccelerometerOrientation' "$root/libexec/yogabook-validator-mode-trace.py"
grep -Fq 'GetCurrentState' "$root/libexec/yogabook-validator-mode-trace.py"
grep -Fq -- '--stop-file' "$root/libexec/yogabook-validator-mode-trace.py"
grep -Fq 'ACTION_REQUIRED:' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq "trap 'cancel_modes' INT TERM" "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'wait_for_keyboard 25' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'cancellation-keyboard-restored' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'for _ in {1..300}' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'pen-calibration-deferred SKIP' "$root/libexec/yogabook-validator-check.sh"
if grep -Fq '0 1 0 -1 0 1' "$root/libexec/yogabook-validator-check.sh"; then
	echo 'passive pen audit must not require the removed fixed calibration matrix' >&2
	exit 1
fi
grep -Fq 'GetCurrentState' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'ybv_run_as_user "$real_user" timeout 10 wpctl status' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'ybv_run_as_user "$real_user" gsettings get' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'screen-keyboard-enabled' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'org.gnome.Shell' "$root/libexec/yogabook-validator-display.sh"
grep -Fq '/sys/class/drm/renderD' "$root/libexec/yogabook-validator-display.sh"
grep -Fq -- '-HDMI-A-' "$root/libexec/yogabook-validator-display.sh"
grep -Fq 'hdmi-lpe-audio' "$root/libexec/yogabook-validator-display.sh"
grep -Fq 'yogabook-validator-hdmi-link.py' "$root/libexec/yogabook-validator-display.sh"
grep -Fq 'micro-hdmi' "$root/libexec/yogabook-validator-physical.sh"
grep -Fq 'ambient-enabled' "$root/libexec/yogabook-validator-display.sh"
grep -Fq 'software-rendering failure' "$root/libexec/yogabook-validator-display.sh"
grep -Fq 'atomic_journal_count >= 10' "$root/libexec/yogabook-validator-display.sh"
grep -Fq 'Intermittent atomic display updates missed their commit window' "$root/libexec/yogabook-validator-display.sh"
grep -Fq "name != 'ybwmi::kbd_backlight'" "$root/libexec/yogabook-validator-common.sh"
if grep -Eq '(^|[^[:alpha:]])(read|read_loop|grab)\(' "$root/libexec/yogabook-validator-modes.sh"; then
	echo 'mode-cycle validation must not read or grab input events' >&2
	exit 1
fi
if grep -Fq 'run_subtest modes' "$root/libexec/yogabook-validator-automated.sh"; then
	echo 'physical mode-cycle validation must not be part of automated' >&2
	exit 1
fi
if grep -Fq 'run_subtest rotation' "$root/libexec/yogabook-validator-automated.sh"; then
	echo 'physical all-orientations validation must not be part of automated' >&2
	exit 1
fi
if grep -Fq 'run_subtest pen-mapping' "$root/libexec/yogabook-validator-automated.sh"; then
	echo 'guided post-Mutter pen mapping must not be part of automated' >&2
	exit 1
fi
if grep -Fq 'run_subtest headset' "$root/libexec/yogabook-validator-automated.sh"; then
	echo 'guided headset validation must not be part of automated' >&2
	exit 1
fi
if grep -Fq 'run_subtest controls' "$root/libexec/yogabook-validator-automated.sh"; then
	echo 'guided control event validation must not be part of automated' >&2
	exit 1
fi
for quiet_check in check apt platform internal-storage resources display sensors power charging usb modem gnss camera inputs pen-stack storage wireless lights; do
	grep -Fq "run_subtest $quiet_check" "$root/libexec/yogabook-validator-quiet.sh"
done
if grep -Eq 'run_subtest (audio|controls|headset|haptics|suspend|modes|pen-mapping|rotation|sensor-interactions)([[:space:]]|$)' "$root/libexec/yogabook-validator-quiet.sh"; then
	echo 'quiet diagnostics must not schedule audible, haptic, suspend or guided checks' >&2
	exit 1
fi
grep -Fq "quiet-policy PASS 'Quiet diagnostics excluded audible, haptic, suspend and guided workflows'" "$root/libexec/yogabook-validator-quiet.sh"
grep -Fq 'services-final-state PASS' "$root/libexec/yogabook-validator-quiet.sh"
grep -Fq 'rotation               Verify all four automatic display orientations' "$root/src/yogabook-validator.sh"
grep -Fq 'pen-stack              Inspect the automatic pen-mapping software stack' "$root/src/yogabook-validator.sh"
grep -Fq 'self.run_command("pen-stack", [])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'pen-mode-coherence' "$root/libexec/yogabook-validator-pen-stack.sh"
grep -Fq 'pen-current-transform' "$root/libexec/yogabook-validator-pen-stack.sh"
grep -Fq 'pen-package-integrity' "$root/libexec/yogabook-validator-pen-stack.sh"
if grep -Eq 'ACTION_REQUIRED:|uinput|/dev/uinput' "$root/libexec/yogabook-validator-pen-stack.sh"; then
	echo 'automatic pen-stack validation must not request or synthesize physical input' >&2
	exit 1
fi
grep -Fq 'Halo keyboard is inactive in drawing mode' "$root/libexec/yogabook-validator-inputs.sh"
grep -Fq 'Halo haptics are inactive in drawing mode' "$root/libexec/yogabook-validator-inputs.sh"
grep -Fq 'Halo keyboard service is intentionally inactive in drawing mode' \
	"$root/libexec/yogabook-validator-check.sh"
grep -Fq 'Halo haptic actuator is inactive in drawing mode' "$root/libexec/yogabook-validator-active.sh"
for mode_aware_suite in automated quiet; do
	grep -Fq 'critical_services=(yogabook-camera.service' \
		"$root/libexec/yogabook-validator-$mode_aware_suite.sh"
	grep -Fq 'N: Name="Wacom HID 169 Pen"' \
		"$root/libexec/yogabook-validator-$mode_aware_suite.sh"
done
grep -Fq 'pen-mapping            Verify Wacom pen mapping after every display rotation' "$root/src/yogabook-validator.sh"
grep -Fq 'self.run_command("pen-mapping", ["--yes", "--timeout", "240"])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.run_command("sensor-interactions", ["--yes", "--timeout", "120"])' "$root/ui/yogabook_validator_ui.py"
python3 "$root/libexec/yogabook-validator-sensor-interactions.py" --self-test
grep -Fq 'controls               Observe Power, Volume and lid events without actions' "$root/src/yogabook-validator.sh"
grep -Fq 'self.run_command("controls", ["--yes", "--timeout", "90"])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'device.grab()' "$root/libexec/yogabook-validator-controls-events.py"
grep -Fq 'device.ungrab()' "$root/libexec/yogabook-validator-controls-events.py"
grep -Fq 'finally:' "$root/libexec/yogabook-validator-controls-events.py"
grep -Fq 'controls-release' "$root/libexec/yogabook-validator-controls.sh"
grep -Fq 'if clean.startswith("ACTION_REQUIRED:")' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'ecodes.SW_HEADPHONE_INSERT' "$root/libexec/yogabook-validator-inputs.sh"
grep -Fq 'charge_full_design' "$root/libexec/yogabook-validator-power.sh"
grep -Fq 'cht_wcove_pwrsrc' "$root/libexec/yogabook-validator-power.sh"
grep -Fq 'expected_pci_drivers' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'YBV_RESOURCE_SAMPLE_SECONDS' "$root/libexec/yogabook-validator-resources.sh"
grep -Fq 'CPUQuota=175%' "$root/libexec/yogabook-validator-resources.sh"
grep -Fq 'CPUQuota=100%' "$root/libexec/yogabook-validator-resources.sh"
grep -Fq 'CPUQuota=50%' "$root/libexec/yogabook-validator-resources.sh"
grep -Fq '<SensorType>$invalid_sensor</SensorType>' "$root/libexec/yogabook-validator-resources.sh"
grep -Fq 'journalctl -b -k --no-pager' "$root/libexec/yogabook-validator-resources.sh"
grep -Fq 'COLD_BOOT_STABILITY: PASS' "$root/libexec/yogabook-validator-stability.sh"
grep -Fq 'This boot was already used as the baseline or counted once' "$root/libexec/yogabook-validator-stability.sh"
grep -Fq 'emmc_candidates=()' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq '== MMC' "$root/libexec/yogabook-validator-platform.sh"
if grep -Fq 'emmc=/sys/class/block/mmcblk0' "$root/libexec/yogabook-validator-platform.sh"; then
	echo 'platform validation must discover eMMC by device type, not enumeration order' >&2
	exit 1
fi
grep -Fq 'life_time' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'pre_eol_info' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq '.yogabook-validator-internal-storage-io.XXXXXX' "$root/libexec/yogabook-validator-internal-storage.sh"
grep -Fq 'pattern=0xa5 retained=false' "$root/libexec/yogabook-validator-internal-storage.sh"
grep -Fq 'target is not on the root filesystem' "$root/libexec/yogabook-validator-internal-storage.sh"
grep -Fq 'cleanup_internal_storage' "$root/libexec/yogabook-validator-internal-storage.sh"
grep -Fq 'ybv_classify_root_storage_journal' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'Targeted eMMC or root-filesystem errors occurred in this boot' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'rtc0 wake=enabled s2idle=selected' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq '/sys/module/atomisp/taint' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq '/sys/module/v4l2loopback/taint' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'expected_taint | 4096 | 8192' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'flags attributed to required integration modules' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'serial numbers, CID and manufacturer fields are' "$root/README.md"
grep -Fq 'intel_xhci_usb_sw-role-switch' "$root/libexec/yogabook-validator-usb.sh"
grep -Fq 'removable USB accessory' "$root/libexec/yogabook-validator-usb.sh"
grep -Fq 'usb-cycle              Guide one USB OTG insertion' "$root/src/yogabook-validator.sh"
grep -Fq 'self.run_command("usb-cycle", ["--yes", "--timeout", "90"])' "$root/ui/yogabook_validator_ui.py"
grep -Fq "trap 'cancel_cycle TERM' TERM" "$root/libexec/yogabook-validator-usb-cycle.sh"
grep -Fq 'cycle-control-transfer' "$root/libexec/yogabook-validator-usb-cycle.sh"
grep -Fq 'cycle-state-restore' "$root/libexec/yogabook-validator-usb-cycle.sh"
grep -Fq 'identities=discarded' "$root/libexec/yogabook-validator-usb-cycle.sh"
grep -Fq "trap 'restore_lights || true' EXIT" "$root/libexec/yogabook-validator-lights.sh"
grep -Fq "declare -A expected_counts=([als]=2 [accel_3d]=4 [hinge]=2 [sx9310]=1)" "$root/libexec/yogabook-validator-sensors.sh"
grep -Fq 'mount_options=ro,nodev,nosuid,noexec' "$root/libexec/yogabook-validator-storage.sh"
grep -Fq 'iflag=fullblock' "$root/libexec/yogabook-validator-storage.sh"
grep -Fq 'bs=64K count=1 conv=fsync' "$root/libexec/yogabook-validator-storage.sh"
grep -Fq '.yogabook-validator-write-test.XXXXXX' "$root/libexec/yogabook-validator-storage.sh"
# shellcheck disable=SC2016
grep -Fq 'sync -f "$mount_dir"' "$root/libexec/yogabook-validator-storage.sh"
grep -Fq "YBV_FINAL_ROLLUP_SUMMARY='Every writable SD filesystem passed the bounded write validation'" "$root/libexec/yogabook-validator-storage.sh"
grep -Fq "YBV_FINAL_ROLLUP_SUMMARY='Bounded SD write validation was incomplete'" "$root/libexec/yogabook-validator-storage.sh"
grep -Fq "YBV_FINAL_ROLLUP_SUMMARY='Bounded SD write validation failed'" "$root/libexec/yogabook-validator-storage.sh"
grep -Fq 'state-preservation=FAIL' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'preexisting-service-instability WARN' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'state=activating/restarting restarts=volatile' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'storage-write' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'internal-storage' "$root/libexec/yogabook-validator-active.sh"
if grep -Fq 'run_subtest storage-write' "$root/libexec/yogabook-validator-automated.sh"; then
	echo 'explicit SD write validation must not be part of automated' >&2
	exit 1
fi
grep -Fq 'restore_wireless || true' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'timeout 8 bluetoothctl show' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'missing_capabilities+=(classic-audio)' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'missing_capabilities+=(low-energy-gatt)' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'missing_capabilities+=(central-role)' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'missing_capabilities+=(peripheral-role)' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'missing_capabilities+=(advertising)' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq "grep -Ec '\\] Device '" "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'identities=discarded' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'stdbuf -oL -eL bluetoothctl --timeout 8 scan on' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq "grep -Fq 'Discovering: yes'" "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'mktemp /tmp/yogabook-validator-bluetooth.XXXXXX' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'controller_info=$(timeout 8 bluetoothctl show' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'initial_power_known=false' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'No Bluetooth state was changed after the incomplete initial snapshot' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'rm -f -- "$discovery_file"' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'state=$(timeout 5 bluetoothctl show' "$root/libexec/yogabook-validator-common.sh"
if grep -Fq 'btmgmt info' "$root/libexec/yogabook-validator-common.sh"; then
	echo 'global state snapshots must not invoke the mutating MGMT inventory path' >&2
	exit 1
fi
for suite_runner in automated quiet; do
	if grep -Fq 'critical_services=(halo-keyboard.service yogabook-camera.service iio-sensor-proxy.service bluetooth.service ModemManager.service)' \
		"$root/libexec/yogabook-validator-$suite_runner.sh"; then
		echo "$suite_runner must not require halo-keyboard.service while drawing mode is active" >&2
		exit 1
	fi
done
# shellcheck disable=SC2016
if grep -Fq 'discovery_output" >>"$YBV_LOG"' "$root/libexec/yogabook-validator-wireless.sh"; then
	echo 'raw Bluetooth discovery output must not be written to reports or logs' >&2
	exit 1
fi
grep -Fq 'restore_route || restore_rc=1' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq 'original_pixel_format=' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq -- '--set-fmt-video="width=$original_width,height=$original_height,pixelformat=$original_pixel_format"' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq 'camera tests require root access to private AtomISP devices' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq 'systemctl stop "$camera_service"' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq 'systemctl start --no-block "$camera_service"' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq 'v4l2-ctl -d "$video_device" --set-input="$port"' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq 'ybv_finish_report_for_user "$real_user"' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq '[[ $camera_state_restored == true ]] && return 0' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq '[[ $restore_rc -ne 0 ]] || camera_state_restored=true' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq "trap 'restore_camera_state || true' EXIT" "$root/libexec/yogabook-validator-camera.sh"
# shellcheck disable=SC2016
grep -Fq 'focus_absolute=$target' "$root/libexec/yogabook-validator-camera.sh"
# shellcheck disable=SC2016
grep -Fq 'focus_absolute=$focus_original' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq 'yogabook-validator-camera-capture.py' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq -- '--stream-to=-' "$root/libexec/yogabook-validator-camera-capture.py"
grep -Fq 'actual_frame_bytes=' "$root/libexec/yogabook-validator-camera-capture.py"
grep -Fq 'selectors.DefaultSelector()' "$root/libexec/yogabook-validator-camera-capture.py"
grep -Fq 'atomisp_run_mode=2' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq "test_camera front 'Front camera' 0 ov2740 BG10,BA10 1932 1092 4096 4472832" "$root/libexec/yogabook-validator-camera.sh"
grep -Fq "test_camera rear 'Rear camera' 1 ov8858 BG10 1632 1224 3328 4075520" "$root/libexec/yogabook-validator-camera.sh"
if grep -Eq -- '--stream-to=[^ -]|open\(.+wb|write_bytes' "$root/libexec/yogabook-validator-camera-capture.py"; then
	echo 'camera validation must never store captured image data' >&2
	exit 1
fi
incomplete_analysis=$(python3 -c 'import sys; sys.stdout.buffer.write(bytes(512))' |
	python3 "$root/libexec/yogabook-validator-camera-capture.py" --analyze-stdin 32 8 64 512 5 BG10)
[[ $incomplete_analysis == FAIL$'\t'SKIP$'\t'* ]]
fake_v4l2="$temporary/fake-v4l2-ctl"
sed 's/^\t//' >"$fake_v4l2" <<'EOF'
	#!/usr/bin/env bash
	dd if=/dev/zero bs=512 count=5 status=none
	sleep 30
EOF
chmod +x "$fake_v4l2"
capture_result=$(YBV_V4L2_CTL="$fake_v4l2" YBV_CAMERA_CAPTURE_TIMEOUT=2 \
	python3 "$root/libexec/yogabook-validator-camera-capture.py" /dev/null 32 8 64 512 5 BA10)
[[ $capture_result == PASS$'\t'* ]]
grep -Fq 'src" / "yogabook-validator.sh"' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'bundle source is not a Yoga Book Validator report directory' "$root/libexec/yogabook-validator-bundle.sh"
grep -Fq 'name desktop-monitor.raw' "$root/libexec/yogabook-validator-bundle.sh" && {
	echo 'support bundle allowlist must not include raw desktop monitor audio' >&2
	exit 1
}
grep -Fq 'rm -f -- "$capture_file" "$desktop_probe_file" "$state_file"' "$root/libexec/yogabook-validator-active.sh"
bundle_fixture="$temporary/bundle-report"
mkdir -p "$bundle_fixture/subtest"
printf 'timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n' >"$bundle_fixture/results.tsv"
printf 'Yoga Book Validator fixture\n' >"$bundle_fixture/validator.log"
printf 'nested evidence\n' >"$bundle_fixture/subtest/results.tsv"
printf 'private\n' >"$bundle_fixture/desktop-monitor.raw"
printf 'private\n' >"$bundle_fixture/alsa-state"
printf 'private\n' >"$bundle_fixture/mic1.wav"
printf 'private\n' >"$bundle_fixture/unrelated-secret.txt"
bundle_path=$("$root/libexec/yogabook-validator-bundle.sh" "$bundle_fixture")
bundle_members=$(tar -tzf "$bundle_path")
grep -Fxq 'results.tsv' <<<"$bundle_members"
grep -Fxq 'validator.log' <<<"$bundle_members"
grep -Fxq 'subtest/results.tsv' <<<"$bundle_members"
if grep -Eq 'desktop-monitor\.raw|alsa-state|mic1\.wav|unrelated-secret\.txt' <<<"$bundle_members"; then
	echo 'support bundle retained a non-allowlisted private file' >&2
	exit 1
fi
printf '%s\n' '{"schema":"org.yogabook.validator.pen-mapping/v1","raw_coordinates":[[10,20]]}' \
	>"$bundle_fixture/subtest/pen-mapping.json"
if "$root/libexec/yogabook-validator-bundle.sh" "$bundle_fixture" >/dev/null 2>&1; then
	echo 'support bundle accepted pen evidence outside the privacy-safe schema' >&2
	exit 1
fi
rm -f -- "$bundle_fixture/subtest/pen-mapping.json"
mkdir -p "$temporary/not-a-report"
if "$root/libexec/yogabook-validator-bundle.sh" "$temporary/not-a-report" >/dev/null 2>&1; then
	echo 'support bundle accepted an arbitrary directory' >&2
	exit 1
fi

answers="$temporary/answers.tsv"
printf 'speakers\tPASS\ttest note\nheadphones\tSKIP\tno adapter\n' >"$answers"
if YBV_RESULTS_BASE="$temporary/results" YBV_LIBEXEC_DIR="$root/libexec" \
	YBV_PACKAGE_INVENTORY_SOURCE="$package_inventory_fixture" \
	"$root/src/yogabook-validator.sh" physical --answers "$answers" --output "$temporary/physical-incomplete" \
	2>"$temporary/physical-incomplete.err"; then
	echo 'physical acceptance must reject an incomplete answer set' >&2
	exit 1
fi
grep -Fq 'missing an explicit result for internal-microphone' "$temporary/physical-incomplete.err"
printf 'speakers\tPASS\t\tforged-extra\n' >"$temporary/answers-extra.tsv"
if YBV_RESULTS_BASE="$temporary/results" YBV_LIBEXEC_DIR="$root/libexec" \
	YBV_PACKAGE_INVENTORY_SOURCE="$package_inventory_fixture" \
	"$root/src/yogabook-validator.sh" physical --answers "$temporary/answers-extra.tsv" \
	--output "$temporary/physical-extra" 2>"$temporary/physical-extra.err"; then
	echo 'physical acceptance must reject extra TSV fields' >&2
	exit 1
fi
grep -Fq 'has an invalid provenance observation timestamp' "$temporary/physical-extra.err"
for physical_id in internal-microphone headset-microphone jack-detection headset-buttons \
	halo-keys halo-touchpad halo-haptics halo-backlight indicator-leds pen-direction \
	pen-pressure display-touch display-stability auto-rotation display-brightness micro-hdmi \
	ambient-light-response proximity-response hinge-angle \
	front-camera rear-camera wifi bluetooth usb-otg internal-storage sd-card hardware-buttons lid-switch \
	lte-data gnss suspend-resume charging thermal-stability cold-boots reboot poweroff; do
	printf '%s\tSKIP\tnot exercised by the automated fixture\n' "$physical_id" >>"$answers"
done
YBV_RESULTS_BASE="$temporary/results" YBV_LIBEXEC_DIR="$root/libexec" \
	YBV_PACKAGE_INVENTORY_SOURCE="$package_inventory_fixture" \
	"$root/src/yogabook-validator.sh" physical --answers "$answers" --output "$temporary/physical"
grep -Fq $'physical\tspeakers\tPASS' "$temporary/physical/results.tsv"
grep -Fq 'PHYSICAL_ACCEPTANCE_RESULT: INCOMPLETE' "$temporary/physical/validator.log"
grep -Fq 'PhysicalWindow(self, command="full").present()' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.parent_window.report_path(self.command)' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'self.command,' "$root/ui/yogabook_validator_ui.py"
python3 - "$root/ui/yogabook_validator_ui.py" "$temporary/physical/physical-results.tsv" <<'PY'
import ast
import csv
import sys

module = ast.parse(open(sys.argv[1], encoding="utf-8").read())
assignment = next(
    node for node in module.body
    if isinstance(node, ast.Assign)
    and any(isinstance(target, ast.Name) and target.id == "PHYSICAL_CHECKS" for target in node.targets)
)
ui_ids = [item[0] for item in ast.literal_eval(assignment.value)]
with open(sys.argv[2], newline="", encoding="utf-8") as stream:
    shell_ids = [row["check_id"] for row in csv.DictReader(stream, delimiter="\t")]
assert ui_ids == shell_ids, (ui_ids, shell_ids)
PY
grep -Fq 'for group_title, group_description, check_ids in PHYSICAL_GROUPS:' "$root/ui/yogabook_validator_ui.py"
physical_import_args=()
while IFS=$'\t' read -r physical_id _status _note; do
	[[ $physical_id == check_id ]] && continue
	physical_import_args+=(--check-id "$physical_id")
done <"$temporary/physical/physical-results.tsv"
physical_device=$(awk -F '\t' '$1 == "device" {print $2}' "$temporary/physical/environment.tsv")
python3 "$root/libexec/yogabook-validator-physical-import.py" \
	"$temporary/physical" --validator-version "$package_version" --device "$physical_device" \
	--matrix "$root/data/acceptance.json" --package-inventory "$package_inventory_fixture" \
	"${physical_import_args[@]}" >"$temporary/imported-physical.json"
python3 - "$temporary/imported-physical.json" <<'PY'
import json
import sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(rows) == 38
assert rows[0]["check_id"] == "speakers" and rows[0]["status"] == "PASS" and rows[0]["note"] == "test note"
assert rows[1]["check_id"] == "headphones" and rows[1]["status"] == "SKIP" and rows[1]["note"] == "no adapter"
assert rows[0]["observed_at"] and rows[1]["observed_at"]
PY
python3 - "$temporary/imported-physical.json" "$temporary/answers-reimport.tsv" <<'PY'
import json
import sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
with open(sys.argv[2], "w", encoding="utf-8", newline="") as stream:
    for row in rows:
        stream.write(
            f"{row['check_id']}\t{row['status']}\t{row['note']}\t{row['observed_at']}\n"
        )
PY
YBV_RESULTS_BASE="$temporary/results" YBV_LIBEXEC_DIR="$root/libexec" \
	YBV_PACKAGE_INVENTORY_SOURCE="$package_inventory_fixture" \
	"$root/src/yogabook-validator.sh" physical --answers "$temporary/answers-reimport.tsv" \
	--output "$temporary/physical-reimport"
grep -Fq 'provenance_observed_at=' "$temporary/physical-reimport/results.tsv"
python3 "$root/libexec/yogabook-validator-physical-import.py" \
	"$temporary/physical-reimport" --validator-version "$package_version" --device "$physical_device" \
	--matrix "$root/data/acceptance.json" --package-inventory "$package_inventory_fixture" \
	"${physical_import_args[@]}" >"$temporary/reimported-physical.json"
python3 - "$temporary/imported-physical.json" "$temporary/reimported-physical.json" <<'PY'
import json
import sys

first = {row["check_id"]: row["observed_at"] for row in json.load(open(sys.argv[1], encoding="utf-8"))}
second = {row["check_id"]: row["observed_at"] for row in json.load(open(sys.argv[2], encoding="utf-8"))}
assert first == second
PY
cp -a -- "$temporary/physical" "$temporary/physical-tampered"
sed -i 's/headphones\tSKIP\tno adapter/headphones\tSKIP\tdifferent reason/' \
	"$temporary/physical-tampered/physical-results.tsv"
if python3 "$root/libexec/yogabook-validator-physical-import.py" \
	"$temporary/physical-tampered" --validator-version "$package_version" --device "$physical_device" \
	--matrix "$root/data/acceptance.json" --package-inventory "$package_inventory_fixture" \
	"${physical_import_args[@]}" 2>"$temporary/import-tampered.err"; then
	echo 'physical observation import must reject tampered physical evidence' >&2
	exit 1
fi
grep -Fq 'physical-results.tsv does not match report integrity metadata' "$temporary/import-tampered.err"

fake_passive="$temporary/fake-passive"
fake_physical="$temporary/fake-physical"
sed 's/^\t//' >"$fake_passive" <<'EOF'
	#!/usr/bin/env bash
	set -Eeuo pipefail
	output=
	while (($#)); do
		case $1 in --output) output=$2; shift 2 ;; *) exit 2 ;; esac
	done
	[[ ${YBV_FAKE_PASSIVE_MISSING:-0} != 1 ]] || exit 1
	mkdir -p "$output"
	printf 'timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n' >"$output/results.tsv"
	printf 'now\tplatform\tfake-passive\tPASS\tSynthetic passive check\tfixture\n' >>"$output/results.tsv"
	printf 'now\tsuite\tnested\tPASS\tNested suite rollup\tfixture\n' >>"$output/results.tsv"
	printf 'AUTOMATED_RESULT: PASS\nPHYSICAL_ACCEPTANCE_RESULT: PENDING\n' >"$output/validator.log"
	if [[ ${YBV_FAKE_PASSIVE_FAIL:-0} == 1 ]]; then
		sed -i 's/AUTOMATED_RESULT: PASS/AUTOMATED_RESULT: FAIL/' "$output/validator.log"
		exit 1
	fi
EOF
sed 's/^\t//' >"$fake_physical" <<'EOF'
	#!/usr/bin/env bash
	set -Eeuo pipefail
	output=
	while (($#)); do
		case $1 in --output) output=$2; shift 2 ;; --answers) shift 2 ;; *) exit 2 ;; esac
	done
	mkdir -p "$output"
	printf 'timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n' >"$output/results.tsv"
	printf 'now\tphysical\tspeakers\tSKIP\tSynthetic physical observation\tquiet fixture\n' >>"$output/results.tsv"
	printf 'check_id\tstatus\tnote\nspeakers\tSKIP\tquiet fixture\n' >"$output/physical-results.tsv"
	printf 'AUTOMATED_RESULT: PASS\nPHYSICAL_ACCEPTANCE_RESULT: INCOMPLETE\n' >"$output/validator.log"
EOF
chmod +x "$fake_passive" "$fake_physical"
mkdir -p "$temporary/full-sysroot/proc/sys/kernel/random"
printf 'fixture-boot\n' >"$temporary/full-sysroot/proc/sys/kernel/random/boot_id"
YBV_SYSROOT="$temporary/full-sysroot" YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	YBV_PASSIVE_RUNNER="$fake_passive" YBV_PHYSICAL_RUNNER="$fake_physical" \
	"$root/src/yogabook-validator.sh" full --answers "$answers" --output "$temporary/full"
for report_file in results.tsv validator.log environment.tsv report.json report.md report.html physical-results.tsv; do
	test -s "$temporary/full/$report_file"
done
test -f "$temporary/full/validated-packages.tsv"
test -s "$temporary/full/passive/results.tsv"
test -s "$temporary/full/physical/results.tsv"
grep -Fq $'platform\tfake-passive\tPASS' "$temporary/full/results.tsv"
grep -Fq $'physical\tspeakers\tSKIP' "$temporary/full/results.tsv"
grep -Fq 'PHYSICAL_ACCEPTANCE_RESULT: INCOMPLETE' "$temporary/full/validator.log"
grep -Eq $'validator\tstate-preservation\tPASS\t' "$temporary/full/results.tsv"
python3 - "$temporary/full/report.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
assert report["run"]["command"] == "full"
assert report["run"]["physical_acceptance_result"] == "INCOMPLETE"
assert report["summary"]["checks_total"] == 3
assert report["summary"]["observations_total"] == 3
assert report["summary"]["suite_rollups"]["total"] == 3
assert report["acceptance"]["summary"]["components_total"] == 24
assert report["acceptance"]["summary"]["components_complete"] == 0
PY
full_failure_rc=0
YBV_SYSROOT="$temporary/full-sysroot" YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	YBV_PASSIVE_RUNNER="$fake_passive" YBV_PHYSICAL_RUNNER="$fake_physical" YBV_FAKE_PASSIVE_FAIL=1 \
	"$root/src/yogabook-validator.sh" full --answers "$answers" --output "$temporary/full-failure" || full_failure_rc=$?
[[ $full_failure_rc -eq 1 ]]
grep -Eq $'validator\tpassive-execution\tFAIL\t' "$temporary/full-failure/results.tsv"
grep -Fq 'AUTOMATED_RESULT: FAIL' "$temporary/full-failure/validator.log"
full_missing_rc=0
YBV_SYSROOT="$temporary/full-sysroot" YBV_REPORT_RENDERER="$root/libexec/yogabook-validator-report.py" \
	YBV_PASSIVE_RUNNER="$fake_passive" YBV_PHYSICAL_RUNNER="$fake_physical" YBV_FAKE_PASSIVE_MISSING=1 \
	"$root/src/yogabook-validator.sh" full --answers "$answers" --output "$temporary/full-missing" || full_missing_rc=$?
[[ $full_missing_rc -eq 1 ]]
[[ $(grep -Ec $'validator\tpassive-report\tFAIL\t' "$temporary/full-missing/results.tsv") -eq 1 ]]
if grep -Eq $'validator\tpassive-execution\tFAIL\t' "$temporary/full-missing/results.tsv"; then
	echo 'missing subreport must produce one root failure' >&2
	exit 1
fi

fake="$temporary/root"
mkdir -p "$fake/sys/class/dmi/id" "$fake/proc/asound/card7" "$fake/proc/bus/input" \
	"$fake/lib/firmware/intel/sof" "$fake/lib/firmware/intel/sof-tplg" \
	"$fake/usr/share/alsa/ucm2/conf.d/SOF" "$fake/usr/share/alsa/ucm2/cht-yogabook" \
	"$fake/sys/bus/iio/devices" "$fake/sys/class/power_supply/BAT0" \
	"$fake/sys/class/power_supply/USB0" "$fake/sys/class/backlight/panel" \
	"$fake/sys/class/drm/card1-DSI-1" "$fake/sys/class/net/wlp1s0/wireless" \
	"$fake/sys/class/bluetooth/hci0" "$fake/sys/class/mmc_host/mmc1" \
	"$fake/sys/class/leds/platform::charging" "$fake/sys/class/leds/platform::indicator" \
	"$fake/sys/class/leds/ybwmi::kbd_backlight" "$fake/sys/block/mmcblk0/device" \
	"$fake/sys/block/mmcblk1/device" "$fake/sys/bus/pci/devices/0000:01:00.0" \
	"$fake/sys/bus/pci/devices/0000:00:14.0" "$fake/sys/bus/pci/drivers/brcmfmac" \
	"$fake/sys/bus/pci/drivers/xhci_hcd" "$fake/dev" "$fake/run/thermald" \
	"$fake/sys/class/hwmon/hwmon0" "$fake/sys/class/hwmon/hwmon1" \
	"$fake/sys/class/hwmon/hwmon2" "$fake/sys/class/thermal/thermal_zone0" \
	"$fake/proc/sys/kernel/random" "$fake/etc/default/grub.d" "$fake/boot" \
	"$fake/etc/kernel/postinst.d" "$fake/usr/local/sbin" \
	"$fake/sys/module/snd_intel_dspcfg/parameters"
printf 'LenovoYB1-X91L\n' >"$fake/sys/class/dmi/id/product_name"
printf 'LENOVO\n' >"$fake/sys/class/dmi/id/sys_vendor"
test_kernel=7.2.0-yogabook-test
printf 'GRUB_TOP_LEVEL=/boot/vmlinuz-%s\n' "$test_kernel" >"$fake/etc/default/grub.d/60-yogabook.cfg"
printf 'kernel\n' >"$fake/boot/vmlinuz-$test_kernel"
printf 'initrd\n' >"$fake/boot/initrd.img-$test_kernel"
printf '#!/bin/sh\nexit 0\n' >"$fake/usr/local/sbin/yogabook-select-kernel"
cp "$fake/usr/local/sbin/yogabook-select-kernel" \
	"$fake/etc/kernel/postinst.d/zz-00-yogabook-default"
chmod +x "$fake/usr/local/sbin/yogabook-select-kernel" \
	"$fake/etc/kernel/postinst.d/zz-00-yogabook-default"
printf 'boot-one\n' >"$fake/proc/sys/kernel/random/boot_id"
printf 'snd_sof 0 0 - Live 0x0\n' >"$fake/proc/modules"
printf '0\n' >"$fake/sys/module/snd_intel_dspcfg/parameters/dsp_driver"
printf 'coretemp\n' >"$fake/sys/class/hwmon/hwmon0/name"
for core in 0 1 2 3; do
	channel=$((core + 2))
	printf 'Core %d\n' "$core" >"$fake/sys/class/hwmon/hwmon0/temp${channel}_label"
	printf '42000\n' >"$fake/sys/class/hwmon/hwmon0/temp${channel}_input"
	printf '90000\n' >"$fake/sys/class/hwmon/hwmon0/temp${channel}_crit"
done
printf 'bq27542_0\n' >"$fake/sys/class/hwmon/hwmon1/name"
printf '33000\n' >"$fake/sys/class/hwmon/hwmon1/temp1_input"
printf 'bq25890_charger_0\n' >"$fake/sys/class/hwmon/hwmon2/name"
printf '32000\n' >"$fake/sys/class/hwmon/hwmon2/temp1_input"
printf 'PNIT\n' >"$fake/sys/class/thermal/thermal_zone0/type"
printf '49000\n' >"$fake/sys/class/thermal/thermal_zone0/temp"
for index in 0 1 2 3 4 5; do
	mkdir -p "$fake/sys/class/thermal/cooling_device$index"
	if ((index < 4)); then
		cooling_type=Processor
		maximum=10
	elif ((index == 4)); then
		cooling_type=intel_powerclamp
		maximum=100
	else
		cooling_type=TCHG
		maximum=5
	fi
	printf '%s\n' "$cooling_type" >"$fake/sys/class/thermal/cooling_device$index/type"
	printf '0\n' >"$fake/sys/class/thermal/cooling_device$index/cur_state"
	printf '%s\n' "$maximum" >"$fake/sys/class/thermal/cooling_device$index/max_state"
done
printf '%s\n' \
	'<?xml version="1.0"?>' \
	'<ThermalConfiguration><Platform><ThermalSensors>' \
	'<ThermalSensor><Type>yb_core0</Type><Path>/sys/class/hwmon/hwmon0/temp2_input</Path></ThermalSensor>' \
	'<ThermalSensor><Type>yb_pnit</Type><Path>/sys/class/thermal/thermal_zone0/temp</Path></ThermalSensor>' \
	'<ThermalSensor><Type>yb_battery</Type><Path>/sys/class/hwmon/hwmon1/temp1_input</Path></ThermalSensor>' \
	'<ThermalSensor><Type>yb_charger</Type><Path>/sys/class/hwmon/hwmon2/temp1_input</Path></ThermalSensor>' \
	'</ThermalSensors></Platform></ThermalConfiguration>' \
	>"$fake/run/thermald/thermal-conf.xml.auto"
printf ' 7 [yogabook      ]: sof-cht - sof-cht yogabook\n' >"$fake/proc/asound/cards"
printf 'yogabook\n' >"$fake/proc/asound/card7/id"
printf '%s\n' \
	'N: Name="Goodix Capacitive TouchScreen"' \
	'N: Name="Halo Keyboard"' \
	'N: Name="Halo Keyboard Touchpad"' \
	'N: Name="drv260x:haptics"' \
	'N: Name="drv260x:haptics"' \
	'N: Name="Wacom HID 169 Pen"' \
	'N: Name="HDP0001:00 2ABB:8102"' \
	'N: Name="Lid Switch"' \
	'N: Name="gpio-keys"' \
	'N: Name="gpio-keys"' >"$fake/proc/bus/input/devices"
printf 'firmware\n' >"$fake/lib/firmware/intel/sof/sof-cht.ri"
printf 'topology\n' >"$fake/lib/firmware/intel/sof-tplg/sof-cht-rt5677.tplg"
printf 'SectionUseCase."HiFi" {}\n' >"$fake/usr/share/alsa/ucm2/cht-yogabook/cht-yogabook.conf"
ln -s ../../cht-yogabook/cht-yogabook.conf "$fake/usr/share/alsa/ucm2/conf.d/SOF/LENOVO-LenovoYB1_X91L-X91L.conf"
printf '67\n' >"$fake/sys/class/power_supply/BAT0/capacity"
printf 'Discharging\n' >"$fake/sys/class/power_supply/BAT0/status"
printf 'Battery\n' >"$fake/sys/class/power_supply/BAT0/type"
printf 'USB\n' >"$fake/sys/class/power_supply/USB0/type"
printf '1\n' >"$fake/sys/class/power_supply/USB0/online"
printf '42\n' >"$fake/sys/class/backlight/panel/brightness"
printf '100\n' >"$fake/sys/class/backlight/panel/max_brightness"
for sensor in als als accel_3d accel_3d accel_3d accel_3d hinge hinge sx9310; do
	index=${iio_index:-0}
	mkdir -p "$fake/sys/bus/iio/devices/iio:device$index"
	printf '%s\n' "$sensor" >"$fake/sys/bus/iio/devices/iio:device$index/name"
	iio_index=$((index + 1))
done
printf '0x14e4\n' >"$fake/sys/bus/pci/devices/0000:01:00.0/vendor"
printf '0x43ec\n' >"$fake/sys/bus/pci/devices/0000:01:00.0/device"
ln -s ../../drivers/brcmfmac "$fake/sys/bus/pci/devices/0000:01:00.0/driver"
printf 'up\n' >"$fake/sys/class/net/wlp1s0/operstate"
printf '0x8086\n' >"$fake/sys/bus/pci/devices/0000:00:14.0/vendor"
printf '0x22b5\n' >"$fake/sys/bus/pci/devices/0000:00:14.0/device"
ln -s ../../drivers/xhci_hcd "$fake/sys/bus/pci/devices/0000:00:14.0/driver"
printf 'MMC\n' >"$fake/sys/block/mmcblk0/device/type"
printf 'SD\n' >"$fake/sys/block/mmcblk1/device/type"
printf 'connected\n' >"$fake/sys/class/drm/card1-DSI-1/status"
printf 'enabled\n' >"$fake/sys/class/drm/card1-DSI-1/enabled"
printf '1200x1920\n' >"$fake/sys/class/drm/card1-DSI-1/modes"
touch "$fake/dev/halo_keyboard" "$fake/dev/video0"
YBV_SYSROOT="$fake" YBV_KERNEL_RELEASE="$test_kernel" YBV_LIBEXEC_DIR="$root/libexec" \
	"$root/src/yogabook-validator.sh" check --output "$temporary/check" || true
grep -Fq $'platform\tdmi\tPASS' "$temporary/check/results.tsv"
grep -Fq $'platform\tgrub-default\tPASS' "$temporary/check/results.tsv"
grep -Fq $'platform\tgrub-selection-hook\tPASS' "$temporary/check/results.tsv"
grep -Fq $'audio\talsa-card\tPASS' "$temporary/check/results.tsv"
grep -Fq $'input\thalo-keyboard\tPASS' "$temporary/check/results.tsv"
grep -Fq $'input\thalo-touchpad\tPASS' "$temporary/check/results.tsv"
grep -Fq $'input\thaptics\tPASS' "$temporary/check/results.tsv"
grep -Fq $'sensors\tiio-layout\tPASS' "$temporary/check/results.tsv"
grep -Fq $'wireless\twifi-driver\tPASS' "$temporary/check/results.tsv"
grep -Fq $'wireless\tbluetooth-controller\tPASS' "$temporary/check/results.tsv"
grep -Fq $'usb\tcontroller\tPASS' "$temporary/check/results.tsv"
grep -Fq $'storage\temmc\tPASS' "$temporary/check/results.tsv"
grep -Fq $'storage\tsd-card\tPASS' "$temporary/check/results.tsv"
grep -Fq $'display\tpanel\tPASS' "$temporary/check/results.tsv"
grep -Fq $'platform\tleds\tPASS' "$temporary/check/results.tsv"
grep -Fq $'power\tbattery\tPASS' "$temporary/check/results.tsv"
rm "$fake/etc/kernel/postinst.d/zz-00-yogabook-default"
YBV_SYSROOT="$fake" YBV_KERNEL_RELEASE="$test_kernel" YBV_LIBEXEC_DIR="$root/libexec" \
	"$root/src/yogabook-validator.sh" check --output "$temporary/check-missing-kernel-hook" || true
grep -Fq $'platform\tgrub-selection-hook\tFAIL' \
	"$temporary/check-missing-kernel-hook/results.tsv"
YBV_SYSROOT="$fake" YBV_LIBEXEC_DIR="$root/libexec" \
	"$root/src/yogabook-validator.sh" resources --output "$temporary/resources"
grep -Fq $'thermal\tthermald-policy\tPASS' "$temporary/resources/results.tsv"
grep -Fq $'thermal\tcoretemp-critical\tPASS' "$temporary/resources/results.tsv"
grep -Fq $'thermal\tcooling-capacity\tPASS' "$temporary/resources/results.tsv"
grep -Fq $'thermal\tlive-temperatures\tPASS' "$temporary/resources/results.tsv"
stability_env=(
	YBV_SYSROOT="$fake"
	YBV_LIBEXEC_DIR="$root/libexec"
	YBV_STABILITY_STATE_DIR="$temporary/stability-state"
	YBV_STABILITY_KERNEL_RELEASE=7.2.0-yogabook-test
)
env "${stability_env[@]}" "$root/src/yogabook-validator.sh" \
	stability start 2 --output "$temporary/stability-start"
grep -Fq $'stability\tboot-id\tPASS' "$temporary/stability-start/results.tsv"
grep -Fxq '0' "$temporary/stability-state/passed"
set +e
env "${stability_env[@]}" "$root/src/yogabook-validator.sh" \
	stability check --output "$temporary/stability-same-boot"
stability_rc=$?
set -e
[[ $stability_rc -eq 1 ]]
grep -Fq $'stability\tboot-id\tFAIL' "$temporary/stability-same-boot/results.tsv"
printf 'boot-two\n' >"$fake/proc/sys/kernel/random/boot_id"
printf 'changed topology\n' >"$fake/lib/firmware/intel/sof-tplg/sof-cht-rt5677.tplg"
set +e
env "${stability_env[@]}" "$root/src/yogabook-validator.sh" \
	stability check --output "$temporary/stability-changed-topology"
stability_rc=$?
set -e
[[ $stability_rc -eq 1 ]]
grep -Fq $'stability\ttopology\tFAIL' "$temporary/stability-changed-topology/results.tsv"
printf 'topology\n' >"$fake/lib/firmware/intel/sof-tplg/sof-cht-rt5677.tplg"
env "${stability_env[@]}" "$root/src/yogabook-validator.sh" \
	stability check --output "$temporary/stability-boot-two"
grep -Fxq '1' "$temporary/stability-state/passed"
env "${stability_env[@]}" "$root/src/yogabook-validator.sh" stability status \
	>"$temporary/stability-status.out"
grep -Fq 'COLD_BOOT_STABILITY: 1/2' "$temporary/stability-status.out"
printf 'boot-three\n' >"$fake/proc/sys/kernel/random/boot_id"
env "${stability_env[@]}" "$root/src/yogabook-validator.sh" \
	stability check --output "$temporary/stability-boot-three" \
	>"$temporary/stability-boot-three.out"
grep -Fq 'COLD_BOOT_STABILITY: PASS 2/2' "$temporary/stability-boot-three.out"
grep -Fxq '2' "$temporary/stability-state/passed"
printf '%s\n' \
	'<ThermalConfiguration><Platform><ThermalZones><ThermalZone><TripPoints><TripPoint>' \
	'<SensorType>STR0</SensorType>' \
	'</TripPoint></TripPoints></ThermalZone></ThermalZones></Platform></ThermalConfiguration>' \
	>"$fake/invalid-thermal.xml"
mkdir -p "$fake/sys/class/thermal/thermal_zone1"
printf 'STR0\n' >"$fake/sys/class/thermal/thermal_zone1/type"
printf '%s\n' '-273150' >"$fake/sys/class/thermal/thermal_zone1/temp"
YBV_SYSROOT="$fake" YBV_THERMAL_CONFIG=/invalid-thermal.xml YBV_LIBEXEC_DIR="$root/libexec" \
	"$root/src/yogabook-validator.sh" resources --output "$temporary/resources-invalid" || true
grep -Fq $'thermal\tthermald-policy\tFAIL' "$temporary/resources-invalid/results.tsv"

echo 'Yoga Book Validator project checks: PASS'
