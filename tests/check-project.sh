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
	libexec/yogabook-validator-active.sh libexec/yogabook-validator-camera.sh
	libexec/yogabook-validator-gnss.sh libexec/yogabook-validator-lights.sh
	libexec/yogabook-validator-sensors.sh libexec/yogabook-validator-storage.sh
	libexec/yogabook-validator-wireless.sh
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
for private_helper in yogabook-validator-lights.sh yogabook-validator-storage.sh yogabook-validator-wireless.sh; do
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
	shellcheck "$root"/src/*.sh "$root"/libexec/*.sh "$root"/tests/*.sh "$root"/debian/tests/*.sh
fi
python3 -m py_compile "$root/ui/yogabook_validator_ui.py"
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

store_line=$(grep -n 'store yogabook' "$root/libexec/yogabook-validator-active.sh" | head -n1 | cut -d: -f1)
stop_line=$(grep -n 'systemctl --user stop' "$root/libexec/yogabook-validator-active.sh" | head -n1 | cut -d: -f1)
[[ -n $store_line && -n $stop_line && $store_line -lt $stop_line ]]
grep -Fq "trap 'restore_state || true' EXIT INT TERM" "$root/libexec/yogabook-validator-active.sh"
grep -Fq "state-restore FAIL" "$root/libexec/yogabook-validator-active.sh"
if grep -Fq 'set _verb HiFi list _devices' "$root/libexec/yogabook-validator-check.sh"; then
	echo 'passive audit must not activate a UCM verb' >&2
	exit 1
fi
grep -Fq "Built-in Audio Stereo Speakers" "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'ff.Replay(150, 0)' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'strong_magnitude=0x5000' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'YBV_ACTIVE_DISPATCH=1' "$root/libexec/yogabook-validator-active.sh"
grep -Fq 'ybv_run_as_user "$real_user" mkdir -p -- "$output_dir"' "$root/libexec/yogabook-validator-active.sh"
grep -Fq "trap 'restore_lights || true' EXIT" "$root/libexec/yogabook-validator-lights.sh"
grep -Fq "declare -A expected_counts=([als]=2 [accel_3d]=4 [hinge]=2 [sx9310]=1)" "$root/libexec/yogabook-validator-sensors.sh"
grep -Fq 'mount_options=ro,nodev,nosuid,noexec' "$root/libexec/yogabook-validator-storage.sh"
grep -Fq 'iflag=fullblock' "$root/libexec/yogabook-validator-storage.sh"
grep -Fq 'restore_wireless || true' "$root/libexec/yogabook-validator-wireless.sh"
grep -Fq 'restore_route || true' "$root/libexec/yogabook-validator-camera.sh"
grep -Fq -- '--stream-to=/dev/null' "$root/libexec/yogabook-validator-camera.sh"
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
