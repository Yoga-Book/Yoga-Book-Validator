#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d /tmp/yogabook-validator-test.XXXXXX)
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

required=(
	README.md ATTRIBUTION.md CONTRIBUTING.md LICENSE Makefile
	src/yogabook-validator.sh src/yogabook-validator-ui.sh
	libexec/yogabook-validator-common.sh libexec/yogabook-validator-check.sh
	libexec/yogabook-validator-active.sh libexec/yogabook-validator-automated.sh
	libexec/yogabook-validator-camera.sh
	libexec/yogabook-validator-camera-capture.py
	libexec/yogabook-validator-display.sh
	libexec/yogabook-validator-gnss.sh libexec/yogabook-validator-inputs.sh
	libexec/yogabook-validator-lights.sh
	libexec/yogabook-validator-mode-trace.py
	libexec/yogabook-validator-modes.sh
	libexec/yogabook-validator-passive.sh
	libexec/yogabook-validator-platform.sh
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
for private_helper in yogabook-validator-automated.sh yogabook-validator-inputs.sh yogabook-validator-lights.sh yogabook-validator-modes.sh yogabook-validator-storage.sh yogabook-validator-wireless.sh; do
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
grep -Fq 'parec --device="${default_sink}.monitor"' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'pcm0p/sub0/status' "$root/libexec/yogabook-validator-active.sh"
grep -Fq "cget name='Speaker Switch'" "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'Desktop playback required a second full audio-graph restart' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'pactl parec pw-play wpctl systemctl' "$root/libexec/yogabook-validator-active.sh"
grep -Eq '^ python3-evdev, python3-gi, pipewire-bin, pulseaudio-utils,' "$root/debian/control"
grep -Fq 'chown -- "$report_owner:$(id -gn "$report_owner")" "$YBV_RESULTS_BASE"' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'generated_default=true' "$root/libexec/yogabook-validator-common.sh"
grep -Fq 'ybv_chown_tree_to_user "$YBV_AUTO_REPORT_OWNER" "$YBV_REPORT_DIR"' "$root/libexec/yogabook-validator-common.sh"
grep -Fq "trap 'restore_state || true' EXIT INT TERM" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "state-restore FAIL" "$root/libexec/yogabook-validator-active.sh"
if grep -Fq 'set _verb HiFi list _devices' "$root/libexec/yogabook-validator-check.sh"; then
	echo 'passive audit must not activate a UCM verb' >&2
	exit 1
fi
grep -Fq "Built-in Audio Stereo Speakers" "$root/libexec/yogabook-validator-active.sh"
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
for passive_check in check platform display sensors power usb gnss; do
	grep -Fq "run_subtest $passive_check" "$root/libexec/yogabook-validator-passive.sh"
done
if grep -Eq 'camera|audio|haptics|lights|storage|wireless|suspend|pkexec|sudo' "$root/libexec/yogabook-validator-passive.sh"; then
	echo 'passive suite must contain only read-only unprivileged checks' >&2
	exit 1
fi
grep -Fq 'passive                Run every read-only validation as one merged suite' "$root/src/yogabook-validator.sh"
grep -Fq 'self.run_command("passive", [])' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'yogabook-validator-passive.sh' "$root/libexec/yogabook-validator-full.sh"
grep -Fq 'check_package yogabook-validator platform "$YBV_VERSION"' "$root/libexec/yogabook-validator-check.sh"
grep -Fq "check_package libmutter-18-0 display '50.1-0ubuntu2.2+yogabook2'" "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'dpkg --verify "$package"' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'package-integrity PASS' "$root/libexec/yogabook-validator-check.sh"
grep -Fq 'restart_count_before=' "$root/libexec/yogabook-validator-gnss.sh"
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
grep -Fq 'command_timeout = 600 if command == "automated" else 300' "$root/ui/yogabook_validator_ui.py"
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
grep -Fq 'micro-hdmi' "$root/libexec/yogabook-validator-physical.sh"
grep -Fq 'ambient-enabled' "$root/libexec/yogabook-validator-display.sh"
grep -Fq 'software-rendering failure' "$root/libexec/yogabook-validator-display.sh"
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
grep -Fq 'rotation               Verify all four automatic display orientations' "$root/src/yogabook-validator.sh"
grep -Fq 'command in ("modes", "rotation")' "$root/ui/yogabook_validator_ui.py"
grep -Fq 'ecodes.SW_HEADPHONE_INSERT' "$root/libexec/yogabook-validator-inputs.sh"
grep -Fq 'charge_full_design' "$root/libexec/yogabook-validator-power.sh"
grep -Fq 'cht_wcove_pwrsrc' "$root/libexec/yogabook-validator-power.sh"
grep -Fq 'expected_pci_drivers' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'emmc_candidates=()' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq '== MMC' "$root/libexec/yogabook-validator-platform.sh"
if grep -Fq 'emmc=/sys/class/block/mmcblk0' "$root/libexec/yogabook-validator-platform.sh"; then
	echo 'platform validation must discover eMMC by device type, not enumeration order' >&2
	exit 1
fi
grep -Fq 'life_time' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'pre_eol_info' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'rtc0 wake=enabled s2idle=selected' "$root/libexec/yogabook-validator-platform.sh"
grep -Fq 'AtomISP staging' "$root/libexec/yogabook-validator-platform.sh"
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
grep -Fq 'required_settings=(powered connectable discoverable bondable ssp br/edr le advertising secure-conn privacy phy-configuration)' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq "grep -c ' dev_found:'" "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'identities=discarded' "$root/libexec/yogabook-validator-wireless.sh"
# shellcheck disable=SC2016
if grep -Fq 'discovery_output" >>"$YBV_LOG"' "$root/libexec/yogabook-validator-wireless.sh"; then
	echo 'raw Bluetooth discovery output must not be written to reports or logs' >&2
	exit 1
fi
grep -Fq 'restore_route || restore_rc=1' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq "trap 'restore_camera_state || true' EXIT" "$root/libexec/yogabook-validator-camera.sh"
# shellcheck disable=SC2016
grep -Fq 'focus_absolute=$target' "$root/libexec/yogabook-validator-camera.sh"
# shellcheck disable=SC2016
grep -Fq 'focus_absolute=$focus_original' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq 'yogabook-validator-camera-capture.py' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq -- '--stream-to=-' "$root/libexec/yogabook-validator-camera-capture.py"
grep -Fq 'actual_frame_bytes=' "$root/libexec/yogabook-validator-camera-capture.py"
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
grep -Fq 'src" / "yogabook-validator.sh"' "$root/ui/yogabook_validator_ui.py"
grep -Fq "exclude='*.wav'" "$root/libexec/yogabook-validator-bundle.sh"

answers="$temporary/answers.tsv"
printf 'speakers\tPASS\ttest note\nheadphones\tSKIP\tno adapter\n' >"$answers"
YBV_RESULTS_BASE="$temporary/results" YBV_LIBEXEC_DIR="$root/libexec" \
	"$root/src/yogabook-validator.sh" physical --answers "$answers" --output "$temporary/physical"
grep -Fq $'physical\tspeakers\tPASS' "$temporary/physical/results.tsv"
grep -Fq 'PHYSICAL_ACCEPTANCE_RESULT: INCOMPLETE' "$temporary/physical/validator.log"
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
	"$fake/sys/bus/pci/drivers/xhci_hcd" "$fake/dev"
printf 'LenovoYB1-X91L\n' >"$fake/sys/class/dmi/id/product_name"
printf 'LENOVO\n' >"$fake/sys/class/dmi/id/sys_vendor"
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
YBV_SYSROOT="$fake" YBV_LIBEXEC_DIR="$root/libexec" \
	"$root/src/yogabook-validator.sh" check --output "$temporary/check" || true
grep -Fq $'platform\tdmi\tPASS' "$temporary/check/results.tsv"
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

echo 'Yoga Book Validator project checks: PASS'
