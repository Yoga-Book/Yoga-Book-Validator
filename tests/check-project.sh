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
	libexec/yogabook-validator-category.sh
	libexec/yogabook-validator-dossier.py libexec/yogabook-validator-dossier.sh
	libexec/yogabook-validator-report.py
	libexec/yogabook-validator-active.sh libexec/yogabook-validator-automated.sh
	libexec/yogabook-validator-camera.sh
	libexec/yogabook-validator-camera-capture.py
	libexec/yogabook-validator-display.sh
	libexec/yogabook-validator-hdmi-link.py
	libexec/yogabook-validator-headset-events.py
	libexec/yogabook-validator-gnss.sh libexec/yogabook-validator-inputs.sh
	libexec/yogabook-validator-lights.sh
	libexec/yogabook-validator-modem.py libexec/yogabook-validator-modem.sh
	libexec/yogabook-validator-mode-trace.py
	libexec/yogabook-validator-modes.sh
	libexec/yogabook-validator-passive.sh
	libexec/yogabook-validator-platform.sh
	libexec/yogabook-validator-quiet.sh
	libexec/yogabook-validator-resources.sh
	libexec/yogabook-validator-stability.sh
	libexec/yogabook-validator-power.sh libexec/yogabook-validator-sensors.sh
	libexec/yogabook-validator-storage.sh
	libexec/yogabook-validator-usb.sh libexec/yogabook-validator-wireless.sh
	libexec/yogabook-validator-physical.sh libexec/yogabook-validator-full.sh
	libexec/yogabook-validator-bundle.sh ui/yogabook_validator_ui.py
	data/org.yogabook.Validator.desktop data/org.yogabook.validator.policy
	data/metainfo/org.yogabook.Validator.metainfo.xml debian/control debian/rules
	debian/yogabook-validator.links
)
for file in "${required[@]}"; do test -f "$root/$file"; done

while IFS= read -r script; do
	test -x "$script"
	bash -n "$script"
done < <(
	printf '%s\n' "$root"/src/*.sh "$root"/libexec/*.sh "$root"/tests/*.sh "$root"/debian/tests/*.sh
)
test -x "$root/ui/yogabook_validator_ui.py"
for private_helper in yogabook-validator-automated.sh yogabook-validator-inputs.sh yogabook-validator-lights.sh yogabook-validator-modes.sh yogabook-validator-quiet.sh yogabook-validator-stability.sh yogabook-validator-storage.sh yogabook-validator-wireless.sh; do
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
python3 "$root/tests/test-report.py"
python3 "$root/tests/test-dossier.py"
python3 "$root/tests/test-hdmi-link.py"
python3 "$root/tests/test-headset-events.py"
python3 "$root/tests/test-modem.py"
python3 - "$root/data/acceptance.json" "$root/docs/coverage.md" "$root/ui/yogabook_validator_ui.py" <<'PY'
import ast
import json
from pathlib import Path
import sys

matrix = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert matrix["schema"] == "org.yogabook.validator.acceptance/v1"
assert len(matrix["components"]) == 23
assert len({item["id"] for item in matrix["components"]}) == 23
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
grep -Fq 'speaker-tone-retry WARN' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'Bounded speaker tone failed twice' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'parec --device="${default_sink}.monitor"' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'pcm0p/sub0/status' "$root/libexec/yogabook-validator-active.sh"
grep -Fq "cget name='Speaker Switch'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'Desktop playback required a second full audio-graph restart' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'pactl parec pw-play wpctl systemctl' "$root/libexec/yogabook-validator-active.sh"
grep -Eq '^ python3-evdev, python3-gi, pipewire-bin, procps, pulseaudio-utils,' "$root/debian/control"
grep -Fq 'chown -- "$report_owner:$(id -gn "$report_owner")" "$YBV_RESULTS_BASE"' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'generated_default=true' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'ybv_chown_tree_to_user "$YBV_AUTO_REPORT_OWNER" "$YBV_REPORT_DIR"' "$root/libexec/yogabook-validator-common.sh"
grep -Fq "trap 'restore_state || true' EXIT INT TERM" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "state-restore FAIL" "$root/libexec/yogabook-validator-active.sh"
if grep -Fq 'set _verb HiFi list _devices' "$root/libexec/yogabook-validator-check.sh"; then
	echo 'passive audit must not activate a UCM verb' >&2
	exit 1
fi
grep -Fq "grep -Fq 'Built-in Audio'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'suspend-playback.log' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'suspend-capture.log' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'stream-xruns' "$root/libexec/yogabook-validator-active.sh"
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
grep -Fq 'include_suspend == true' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'gnss-final-state PASS' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'audio-final-state PASS' "$root/libexec/yogabook-validator-automated.sh"
grep -Fq 'services-final-state PASS' "$root/libexec/yogabook-validator-automated.sh"
gnss_final_line=$(grep -nF 'gnss-final-state PASS' "$root/libexec/yogabook-validator-automated.sh" | cut -d: -f1)
audio_run_line=$(grep -nF 'run_subtest audio' "$root/libexec/yogabook-validator-automated.sh" | tail -n 1 | cut -d: -f1)
((gnss_final_line > audio_run_line))
for passive_check in check platform resources display sensors power usb gnss; do
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
grep -Fq 'yogabook-validator-passive.sh' "$root/libexec/yogabook-validator-full.sh"
grep -Fq 'check_package yogabook-validator platform "$YBV_VERSION"' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'Persistent GRUB top-level selects the running Yoga Book kernel' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'check_package yogabook-camera camera 0.2.20' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'check_package yogabook-gnss gnss 1.0.3' "$root/libexec/yogabook-validator-check.sh"
grep -Fq "check_package libmutter-18-0 display '50.1-0ubuntu2.2+yogabook3'" "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'camera_driver_bound /sys/bus/pci/drivers/atomisp-isp2' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'camera_driver_bound /sys/bus/i2c/drivers/ov2740' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'camera_driver_bound /sys/bus/i2c/drivers/ov8858' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'dpkg --verify "$package"' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'package-integrity PASS' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'restart_count_before=' "$root/libexec/yogabook-validator-gnss.sh"
grep -Fq 'runtime-assets FAIL' "$root/libexec/yogabook-validator-gnss.sh"
grep -Fq 'yogabook-gnss-build-runtime' "$root/libexec/yogabook-validator-gnss.sh"
grep -Fq 'gnss runtime-assets FAIL' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'service-stability PASS' "$root/libexec/yogabook-validator-gnss.sh"
grep -Fq 'service-stability FAIL' "$root/libexec/yogabook-validator-gnss.sh"
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
for report_writer in yogabook-validator-inputs.sh yogabook-validator-lights.sh yogabook-validator-modes.sh yogabook-validator-storage.sh yogabook-validator-wireless.sh; do
	# shellcheck disable=SC2016
	grep -Fq 'ybv_finish_report_for_user "$real_user"' "$root/libexec/$report_writer"
done
grep -Fq 'Command output' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'Open detailed report' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'suite roll-ups' "$root/ui/yogabook_validator_ui.py"
for validation_group in 'Recommended workflows' 'Audio and media' 'Input and device modes' \
	'Platform and power' 'Connectivity and storage' 'Reliability' 'Physical acceptance'; do
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
grep -Fq 'run_subtest headset' "$root/libexec/yogabook-validator-category.sh"
grep -Fq 'run_subtest modem' "$root/libexec/yogabook-validator-category.sh"
grep -Fq 'run_subtest modem' "$root/libexec/yogabook-validator-automated.sh"
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
grep -Fq 'check | display | dossier | gnss' "$root/src/yogabook-validator.sh"
grep -Fq 'quiet                  Run all non-audible, non-haptic automated diagnostics' "$root/src/yogabook-validator.sh"
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
grep -Fq 'ybv_verify_state_preservation || true' "$root/libexec/yogabook-validator-common.sh"
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
grep -Fq 'halo-landscape-restored' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'expected=DSI-1 1920x1200 transform=0' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq -- '--all-orientations' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'rotation-upright-return' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'expected_transform_for_sensor' "$root/libexec/yogabook-validator-modes.sh"
grep -Fq 'AccelerometerOrientation' "$root/libexec/yogabook-validator-mode-trace.py"
grep -Fq 'GetCurrentState' "$root/libexec/yogabook-validator-mode-trace.py"
grep -Fq -- '--stop-file' "$root/libexec/yogabook-validator-mode-trace.py"
grep -Fq 'ACTION_REQUIRED:' "$root/libexec/yogabook-validator-modes.sh"
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
if grep -Fq 'run_subtest headset' "$root/libexec/yogabook-validator-automated.sh"; then
	echo 'guided headset validation must not be part of automated' >&2
	exit 1
fi
for quiet_check in check platform resources display sensors power usb modem gnss camera inputs storage wireless lights; do
	grep -Fq "run_subtest $quiet_check" "$root/libexec/yogabook-validator-quiet.sh"
done
if grep -Eq 'run_subtest (audio|headset|haptics|suspend|modes|rotation)([[:space:]]|$)' "$root/libexec/yogabook-validator-quiet.sh"; then
	echo 'quiet diagnostics must not schedule audible, haptic, suspend or guided checks' >&2
	exit 1
fi
grep -Fq "quiet-policy PASS 'Quiet diagnostics excluded audible, haptic, suspend and guided workflows'" "$root/libexec/yogabook-validator-quiet.sh"
grep -Fq 'services-final-state PASS' "$root/libexec/yogabook-validator-quiet.sh"
grep -Fq 'rotation               Verify all four automatic display orientations' "$root/src/yogabook-validator.sh"
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
grep -Fq 'rtc0 wake=enabled s2idle=selected' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq '/sys/module/atomisp/taint' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq '/sys/module/v4l2loopback/taint' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'expected_taint | 4096 | 8192' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'flags attributed to required integration modules' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'serial numbers, CID and manufacturer fields are' "$root/README.md"
grep -Fq 'intel_xhci_usb_sw-role-switch' "$root/libexec/yogabook-validator-usb.sh"
grep -Fq 'removable USB accessory' "$root/libexec/yogabook-validator-usb.sh"
grep -Fq "trap 'restore_lights || true' EXIT" "$root/libexec/yogabook-validator-lights.sh"
grep -Fq "declare -A expected_counts=([als]=2 [accel_3d]=4 [hinge]=2 [sx9310]=1)" "$root/libexec/yogabook-validator-sensors.sh"
grep -Fq 'mount_options=ro,nodev,nosuid,noexec' "$root/libexec/yogabook-validator-storage.sh"
grep -Fq 'iflag=fullblock' "$root/libexec/yogabook-validator-storage.sh"
grep -Fq 'bs=64K count=1 conv=fsync' "$root/libexec/yogabook-validator-storage.sh"
grep -Fq '.yogabook-validator-write-test.XXXXXX' "$root/libexec/yogabook-validator-storage.sh"
# shellcheck disable=SC2016
grep -Fq 'sync -f "$mount_dir"' "$root/libexec/yogabook-validator-storage.sh"
grep -Fq 'storage-write' "$root/libexec/yogabook-validator-active.sh"
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
	grep -Fq 'critical_services=(halo-keyboard.service yogabook-camera.service iio-sensor-proxy.service bluetooth.service ModemManager.service)' \
		"$root/libexec/yogabook-validator-$suite_runner.sh"
done
# shellcheck disable=SC2016
if grep -Fq 'discovery_output" >>"$YBV_LOG"' "$root/libexec/yogabook-validator-wireless.sh"; then
	echo 'raw Bluetooth discovery output must not be written to reports or logs' >&2
	exit 1
fi
grep -Fq 'restore_route || restore_rc=1' "$root/libexec/yogabook-validator-camera.sh"
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
grep -Fq "test_camera front 'Front camera' 0 ov2740 BA10 1932 1092 4096 4472832" "$root/libexec/yogabook-validator-camera.sh"
grep -Fq "test_camera rear 'Rear camera' 1 ov8858 BG10 1632 1224 3328 4075520" "$root/libexec/yogabook-validator-camera.sh"
if grep -Eq -- '--stream-to=[^ -]|open\(.+wb|write_bytes' "$root/libexec/yogabook-validator-camera-capture.py"; then
	echo 'camera validation must never store captured image data' >&2
	exit 1
fi
camera_analysis=$(python3 -c 'import sys
for offset in (0, 1, 2):
    sys.stdout.buffer.write(bytes((16 + offset, 48 + offset, 96 + offset, 192 + offset, 32 + offset, 64 + offset, 128 + offset, 224 + offset, 128, 128, 128, 128)))' |
	python3 "$root/libexec/yogabook-validator-camera-capture.py" --analyze-stdin 4 2 4 12 3)
[[ $camera_analysis == PASS$'\t'PASS$'\t'* ]]
frozen_analysis=$(python3 -c 'import sys; sys.stdout.buffer.write(bytes((16, 48, 96, 192, 32, 64, 128, 224, 128, 128, 128, 128)) * 3)' |
	python3 "$root/libexec/yogabook-validator-camera-capture.py" --analyze-stdin 4 2 4 12 3)
[[ $frozen_analysis == PASS$'\t'FAIL$'\t'* ]]
incomplete_analysis=$(python3 -c 'import sys; sys.stdout.buffer.write(bytes(12))' |
	python3 "$root/libexec/yogabook-validator-camera-capture.py" --analyze-stdin 4 2 4 12 3)
[[ $incomplete_analysis == FAIL$'\t'SKIP$'\t'* ]]
fake_v4l2="$temporary/fake-v4l2-ctl"
sed 's/^\t//' >"$fake_v4l2" <<'EOF'
	#!/usr/bin/env bash
	printf '\001\002\003\004\005\006\007\010\000\000\000\000%.0s' {1..3}
	sleep 30
EOF
chmod +x "$fake_v4l2"
capture_result=$(YBV_V4L2_CTL="$fake_v4l2" YBV_CAMERA_CAPTURE_TIMEOUT=2 \
	python3 "$root/libexec/yogabook-validator-camera-capture.py" /dev/null 4 2 4 12 3 BA10)
[[ $capture_result == PASS$'\t'* ]]
grep -Fq 'src" / "yogabook-validator.sh"' "$root/ui/yogabook_validator_ui.py"
grep -Fq "exclude='*.wav'" "$root/libexec/yogabook-validator-bundle.sh"

answers="$temporary/answers.tsv"
printf 'speakers\tPASS\ttest note\nheadphones\tSKIP\tno adapter\n' >"$answers"
YBV_RESULTS_BASE="$temporary/results" YBV_LIBEXEC_DIR="$root/libexec" \
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
assert report["acceptance"]["summary"]["components_total"] == 23
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
	"$fake/sys/module/snd_intel_dspcfg/parameters"
printf 'LenovoYB1-X91L\n' >"$fake/sys/class/dmi/id/product_name"
printf 'LENOVO\n' >"$fake/sys/class/dmi/id/sys_vendor"
test_kernel=7.2.0-yogabook-test
printf 'GRUB_TOP_LEVEL=/boot/vmlinuz-%s\n' "$test_kernel" >"$fake/etc/default/grub.d/60-yogabook.cfg"
printf 'kernel\n' >"$fake/boot/vmlinuz-$test_kernel"
printf 'initrd\n' >"$fake/boot/initrd.img-$test_kernel"
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
