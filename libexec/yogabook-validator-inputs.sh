#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ $EUID -eq 0 && ${YBV_ACTIVE_DISPATCH:-} == 1 ]] || {
	echo 'ERROR: inputs test must be launched through yogabook-validator' >&2
	exit 2
}
output_dir=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
ybv_has_command python3 || { echo 'ERROR: missing command: python3' >&2; exit 2; }
ybv_require_x91l || { echo 'ERROR: input tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report inputs "$output_dir"
real_user=$(ybv_real_user)
[[ $real_user != root ]] || real_user=

if capabilities=$(python3 - <<'PY'
from evdev import InputDevice, ecodes, list_devices


devices = [InputDevice(path) for path in list_devices()]


def matching(name):
    return [device for device in devices if device.name == name]


def codes(device, event_type):
    return set(device.capabilities(absinfo=False).get(event_type, []))


def has_codes(device, event_type, required):
    return set(required).issubset(codes(device, event_type))


def row(check_id, status, summary, details=""):
    clean = str(details).replace("\t", " ").replace("\r", " ").replace("\n", " ")
    print(f"{check_id}\t{status}\t{summary}\t{clean}")


keyboard = matching("Halo Keyboard")
keyboard_keys = {
    ecodes.KEY_A, ecodes.KEY_Z, ecodes.KEY_ENTER, ecodes.KEY_SPACE,
    ecodes.KEY_LEFTCTRL, ecodes.KEY_LEFTSHIFT, ecodes.KEY_LEFTALT,
    ecodes.KEY_LEFTMETA, ecodes.KEY_VOLUMEUP, ecodes.KEY_VOLUMEDOWN,
    ecodes.KEY_BRIGHTNESSUP, ecodes.KEY_BRIGHTNESSDOWN,
    ecodes.BTN_LEFT, ecodes.BTN_RIGHT,
}
if len(keyboard) == 1 and has_codes(keyboard[0], ecodes.EV_KEY, keyboard_keys):
    row("halo-keyboard-capabilities", "PASS", "Halo keyboard exposes typing, modifier, media and click keys", keyboard[0].path)
else:
    row("halo-keyboard-capabilities", "FAIL", "Halo keyboard capability map is incomplete", f"devices={len(keyboard)}")

touchpads = matching("Halo Keyboard Touchpad")
touchpad_abs = {
    ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_MT_SLOT,
    ecodes.ABS_MT_POSITION_X, ecodes.ABS_MT_POSITION_Y,
    ecodes.ABS_MT_TRACKING_ID,
}
if len(touchpads) == 1 and has_codes(touchpads[0], ecodes.EV_ABS, touchpad_abs) and has_codes(touchpads[0], ecodes.EV_KEY, {ecodes.BTN_TOUCH}):
    row("halo-touchpad-capabilities", "PASS", "Halo touchpad exposes absolute and multitouch axes", touchpads[0].path)
else:
    row("halo-touchpad-capabilities", "FAIL", "Halo touchpad capability map is incomplete", f"devices={len(touchpads)}")

raw_halo = matching("Goodix Capacitive TouchScreen")
raw_abs = {ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_MT_POSITION_X, ecodes.ABS_MT_POSITION_Y}
raw_keys = {ecodes.BTN_TOUCH, ecodes.KEY_F1, ecodes.KEY_F2, ecodes.KEY_F3, ecodes.KEY_F4, ecodes.KEY_F5, ecodes.KEY_F6}
if len(raw_halo) == 1 and has_codes(raw_halo[0], ecodes.EV_ABS, raw_abs) and has_codes(raw_halo[0], ecodes.EV_KEY, raw_keys):
    row("halo-surface-capabilities", "PASS", "Raw Halo surface exposes touch axes and mode-key channels", raw_halo[0].path)
else:
    row("halo-surface-capabilities", "FAIL", "Raw Halo surface capability map is incomplete", f"devices={len(raw_halo)}")

touchscreens = matching("HDP0001:00 2ABB:8102")
touch_abs = {ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_MT_POSITION_X, ecodes.ABS_MT_POSITION_Y, ecodes.ABS_MT_TRACKING_ID}
if len(touchscreens) == 1 and has_codes(touchscreens[0], ecodes.EV_ABS, touch_abs) and has_codes(touchscreens[0], ecodes.EV_KEY, {ecodes.BTN_TOUCH}):
    x_info = touchscreens[0].absinfo(ecodes.ABS_X)
    y_info = touchscreens[0].absinfo(ecodes.ABS_Y)
    if x_info.max >= 1200 and y_info.max >= 1920:
        row("display-touch-capabilities", "PASS", "Display touchscreen exposes full-resolution multitouch axes", f"x={x_info.min}..{x_info.max} y={y_info.min}..{y_info.max}")
    else:
        row("display-touch-capabilities", "FAIL", "Display touchscreen coordinate range is incomplete", f"x={x_info.min}..{x_info.max} y={y_info.min}..{y_info.max}")
else:
    row("display-touch-capabilities", "FAIL", "Display touchscreen capability map is incomplete", f"devices={len(touchscreens)}")

gpio_devices = matching("gpio-keys")
gpio_keys = set().union(*(codes(device, ecodes.EV_KEY) for device in gpio_devices)) if gpio_devices else set()
if len(gpio_devices) >= 2 and {ecodes.KEY_POWER, ecodes.KEY_VOLUMEUP, ecodes.KEY_VOLUMEDOWN}.issubset(gpio_keys):
    row("platform-buttons-capabilities", "PASS", "GPIO power and volume buttons expose the expected key codes", f"devices={len(gpio_devices)}")
else:
    row("platform-buttons-capabilities", "FAIL", "GPIO power or volume button capabilities are incomplete", f"devices={len(gpio_devices)}")

lid = matching("Lid Switch")
if len(lid) == 1 and has_codes(lid[0], ecodes.EV_SW, {ecodes.SW_LID}):
    row("lid-switch-capabilities", "PASS", "Lid switch exposes SW_LID", lid[0].path)
else:
    row("lid-switch-capabilities", "FAIL", "Lid switch capability is missing", f"devices={len(lid)}")

jack = matching("sof-cht yogabook Headset Jack")
jack_switches = {ecodes.SW_HEADPHONE_INSERT, ecodes.SW_MICROPHONE_INSERT}
jack_keys = {ecodes.KEY_VOLUMEUP, ecodes.KEY_VOLUMEDOWN, ecodes.KEY_PLAYPAUSE, ecodes.KEY_VOICECOMMAND}
if len(jack) == 1 and has_codes(jack[0], ecodes.EV_SW, jack_switches) and has_codes(jack[0], ecodes.EV_KEY, jack_keys):
    row("headset-jack-capabilities", "PASS", "Headset jack exposes headphone, microphone and button events", jack[0].path)
else:
    row("headset-jack-capabilities", "FAIL", "Headset jack event capabilities are incomplete", f"devices={len(jack)}")

haptics = matching("drv260x:haptics")
if len(haptics) == 2 and all(has_codes(device, ecodes.EV_FF, {ecodes.FF_RUMBLE}) for device in haptics):
    row("haptic-capabilities", "PASS", "Both haptic devices expose force-feedback rumble", "devices=2")
else:
    row("haptic-capabilities", "FAIL", "Dual haptic force-feedback capabilities are incomplete", f"devices={len(haptics)}")

intel_hid = matching("Intel HID events")
hid_keys = {ecodes.KEY_POWER, ecodes.KEY_VOLUMEUP, ecodes.KEY_VOLUMEDOWN, ecodes.KEY_BRIGHTNESSUP, ecodes.KEY_BRIGHTNESSDOWN, ecodes.KEY_RFKILL}
if len(intel_hid) == 1 and has_codes(intel_hid[0], ecodes.EV_KEY, hid_keys):
    row("intel-hid-capabilities", "PASS", "Intel HID exposes power, volume, brightness and radio keys", intel_hid[0].path)
else:
    row("intel-hid-capabilities", "FAIL", "Intel HID capability map is incomplete", f"devices={len(intel_hid)}")

video_bus = matching("Video Bus")
video_keys = {ecodes.KEY_BRIGHTNESSUP, ecodes.KEY_BRIGHTNESSDOWN, ecodes.KEY_DISPLAY_OFF}
if len(video_bus) == 1 and has_codes(video_bus[0], ecodes.EV_KEY, video_keys):
    row("video-bus-capabilities", "PASS", "Video bus exposes brightness and display-off controls", video_bus[0].path)
else:
    row("video-bus-capabilities", "FAIL", "Video bus display-control capabilities are incomplete", f"devices={len(video_bus)}")

pens = [device for device in devices if "Wacom" in device.name and "Pen" in device.name]
pen_abs = {ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_PRESSURE}
pen_keys = {ecodes.BTN_TOOL_PEN, ecodes.BTN_TOUCH}
if not pens:
    row("wacom-pen-capabilities", "SKIP", "Wacom pen is not active; switch to pen mode to validate capabilities")
elif len(pens) == 1 and has_codes(pens[0], ecodes.EV_ABS, pen_abs) and has_codes(pens[0], ecodes.EV_KEY, pen_keys):
    row("wacom-pen-capabilities", "PASS", "Wacom pen exposes position, pressure, tool and touch capabilities", pens[0].path)
else:
    row("wacom-pen-capabilities", "FAIL", "Wacom pen capability map is incomplete", f"devices={len(pens)}")

for device in devices:
    device.close()
PY
); then
	while IFS=$'\t' read -r check_id status summary details; do
		[[ -n $check_id ]] || continue
		ybv_emit input "$check_id" "$status" "$summary" "$details"
	done <<<"$capabilities"
else
	ybv_emit input capability-reader FAIL 'Could not inspect kernel input capabilities' "$capabilities"
fi

if [[ -n $real_user && -d $YBV_REPORT_DIR ]]; then
	chown -R -- "$real_user:" "$YBV_REPORT_DIR" 2>/dev/null || true
fi
YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
