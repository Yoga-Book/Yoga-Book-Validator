#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

output_dir=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	-h | --help) echo 'Usage: yogabook-validator pen-stack [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
ybv_require_x91l || { echo 'ERROR: pen-stack validation is restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report pen-stack "$output_dir"

package_version() {
	dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

halo_version=$(package_version halo-keyboard)
mutter_version=$(package_version libmutter-18-0)
if [[ -n $halo_version ]]; then
	ybv_emit input pen-halo-package PASS 'Halo keyboard integration is installed' "$halo_version"
else
	ybv_emit input pen-halo-package FAIL 'Halo keyboard integration is not installed'
fi
if [[ -n $mutter_version ]] && dpkg --compare-versions "$mutter_version" ge '50.1-0ubuntu2.2+yogabook5'; then
	ybv_emit display pen-mutter-package PASS 'Mutter includes the Yoga Book dynamic pen-mapping integration' "$mutter_version"
else
	ybv_emit display pen-mutter-package FAIL 'The required Yoga Book Mutter integration is missing or outdated' \
		"${mutter_version:-not-installed}"
fi

wacom_device=/sys/bus/i2c/devices/i2c-WCOM0019:00
modalias=$(ybv_read_first "$wacom_device/modalias")
if [[ -d $wacom_device && $modalias == *WCOM0019* ]]; then
	ybv_emit input pen-hardware-identity PASS 'The firmware exposes the expected Wacom I2C-HID device' "$modalias"
else
	ybv_emit input pen-hardware-identity FAIL 'The Wacom I2C-HID firmware device is missing or unexpected' \
		"${modalias:-unavailable}"
fi

driver=unbound
if [[ -L $wacom_device/driver ]]; then
	driver=$(basename "$(readlink -f "$wacom_device/driver")")
fi
input_text=$(cat /proc/bus/input/devices 2>/dev/null || true)
pen_present=false
halo_keyboard_present=false
halo_touchpad_present=false
grep -Fq 'N: Name="Wacom HID 169 Pen"' <<<"$input_text" && pen_present=true
grep -Fq 'N: Name="Halo Keyboard"' <<<"$input_text" && halo_keyboard_present=true
grep -Fq 'N: Name="Halo Keyboard Touchpad"' <<<"$input_text" && halo_touchpad_present=true
halo_service=false
systemctl is-active --quiet halo-keyboard.service && halo_service=true
halo_device=false
[[ -e /dev/halo_keyboard ]] && halo_device=true

if [[ $halo_service == true && $halo_device == true && $halo_keyboard_present == true &&
	$halo_touchpad_present == true && $pen_present == false && $driver == unbound ]]; then
	ybv_emit input pen-mode-coherence PASS 'Halo keyboard mode has a coherent, mutually exclusive input stack' \
		'halo=active wacom=unbound'
elif [[ $halo_service == false && $halo_device == false && $pen_present == true &&
	$driver == i2c_hid_acpi ]]; then
	ybv_emit input pen-mode-coherence PASS 'Drawing mode has a coherent, mutually exclusive input stack' \
		'halo=inactive wacom=bound:i2c_hid_acpi'
else
	ybv_emit input pen-mode-coherence FAIL 'Halo and Wacom runtime state is internally inconsistent' \
		"halo-service=$halo_service halo-device=$halo_device keyboard=$halo_keyboard_present touchpad=$halo_touchpad_present pen=$pen_present driver=$driver"
fi

libwacom_tablet=/usr/share/libwacom/wacom-yoga-book.tablet
if [[ -r $libwacom_tablet ]] &&
	grep -Fxq 'Name=Wacom HID 169' "$libwacom_tablet" &&
	grep -Fxq 'DeviceMatch=i2c|056a|0169' "$libwacom_tablet" &&
	grep -Fxq 'IntegratedIn=System' "$libwacom_tablet" &&
	grep -Fxq 'Stylus=true' "$libwacom_tablet" &&
	grep -Fxq 'Touch=false' "$libwacom_tablet"; then
	ybv_emit input pen-display-mapping PASS 'libwacom maps the digitizer to the integrated display' \
		'Wacom HID 169; i2c 056a:0169; IntegratedIn=System'
else
	ybv_emit input pen-display-mapping FAIL 'Yoga Book libwacom metadata is missing or incomplete' "$libwacom_tablet"
fi

halo_hwdb=/usr/lib/udev/hwdb.d/61-halo-keyboard.hwdb
if [[ -r $halo_hwdb ]] && ! grep -Fq 'LIBINPUT_CALIBRATION_MATRIX=' "$halo_hwdb"; then
	ybv_emit input pen-dynamic-calibration PASS 'Pen calibration remains neutral for Mutter-controlled rotation'
else
	ybv_emit input pen-dynamic-calibration FAIL 'A fixed calibration can conflict with Mutter rotation' "$halo_hwdb"
fi

if [[ $pen_present == true ]]; then
	udev_properties=$(udevadm info --export-db 2>/dev/null || true)
	pen_record=$(awk 'BEGIN { RS="" } /E: NAME="Wacom HID 169 Pen"/ { print; exit }' <<<"$udev_properties")
	live_calibration=$(sed -n 's/^E: LIBINPUT_CALIBRATION_MATRIX=//p' <<<"$pen_record" | head -n 1)
	if [[ -n $pen_record && (-z $live_calibration || $live_calibration == '1 0 0 0 1 0') ]]; then
		ybv_emit input pen-live-calibration PASS 'The active pen uses neutral live calibration' \
		"${live_calibration:-unset}"
	else
		ybv_emit input pen-live-calibration FAIL 'The active pen has unexpected live calibration' \
		"${live_calibration:-record-missing}"
	fi
else
	ybv_emit input pen-live-calibration SKIP 'Live pen calibration is not applicable in Halo keyboard mode' \
		'dynamic policy validated from installed hwdb'
fi

orientation_lock=$(gsettings get org.gnome.settings-daemon.peripherals.touchscreen orientation-lock 2>/dev/null || true)
if [[ $orientation_lock == false ]]; then
	ybv_emit display pen-rotation-policy PASS 'Automatic display rotation is enabled for dynamic pen mapping' \
		'orientation-lock=false'
else
	ybv_emit display pen-rotation-policy FAIL 'Automatic display rotation is locked or unavailable' \
		"orientation-lock=${orientation_lock:-unknown}"
fi

sensor=$(busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy \
	net.hadess.SensorProxy AccelerometerOrientation 2>/dev/null | sed -n 's/^s "\(.*\)"$/\1/p')
mutter_state=$(ybv_mutter_state "$(id -un)" 2>>"$YBV_LOG" || true)
actual_transform=$(sed -n 's/.*connector=DSI-1 .* transform=\([0-9][0-9]*\) .*/\1/p' <<<"$mutter_state" | head -n 1)
expected_transform=
case $sensor in
	normal) expected_transform=1 ;;
	right-up) expected_transform=0 ;;
	bottom-up) expected_transform=3 ;;
	left-up) expected_transform=2 ;;
esac
if [[ -z $expected_transform || -z $actual_transform ]]; then
	ybv_emit display pen-current-transform FAIL 'SensorProxy and Mutter state could not be correlated automatically' \
		"sensor=${sensor:-unavailable} transform=${actual_transform:-unavailable}"
elif [[ $expected_transform == "$actual_transform" ]]; then
	ybv_emit display pen-current-transform PASS 'Mutter transform matches the current physical orientation' \
		"sensor=$sensor transform=$actual_transform"
else
	ybv_emit display pen-current-transform FAIL 'Mutter transform does not match the current physical orientation' \
		"sensor=$sensor expected=$expected_transform actual=$actual_transform"
fi

modified=()
for package in halo-keyboard libmutter-18-0; do
	verification=$(dpkg --verify "$package" 2>/dev/null || true)
	[[ -z $verification ]] || modified+=("$package")
done
if ((${#modified[@]} == 0)); then
	ybv_emit input pen-package-integrity PASS 'Installed Halo and Mutter files match package checksums' 'packages=2'
else
	ybv_emit input pen-package-integrity FAIL 'Pen-mapping package files differ from installed checksums' \
		"packages=${modified[*]}"
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
