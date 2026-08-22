#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ ${YBV_ACTIVE_DISPATCH:-} == 1 && $EUID -eq 0 ]] || {
	echo 'ERROR: modes must be dispatched by yogabook-validator-active.sh' >&2
	exit 2
}

output_dir=
transition_timeout=90
while (($#)); do
	case $1 in
	--output)
		[[ $# -ge 2 ]] || { echo 'ERROR: --output requires a directory' >&2; exit 2; }
		output_dir=$2
		shift 2
		;;
	--timeout)
		[[ $# -ge 2 ]] || { echo 'ERROR: --timeout requires a value' >&2; exit 2; }
		transition_timeout=$2
		shift 2
		;;
	*)
		echo "ERROR: unknown option: $1" >&2
		exit 2
		;;
	esac
done
[[ $transition_timeout =~ ^[1-9][0-9]*$ ]] || {
	echo 'ERROR: transition timeout must be a positive integer' >&2
	exit 2
}

for required in gsettings journalctl python3 systemctl udevadm; do
	ybv_has_command "$required" || { echo "ERROR: missing command: $required" >&2; exit 2; }
done

real_user=$(ybv_real_user)
if [[ -z $real_user || $real_user == root ]] || ! id "$real_user" >/dev/null 2>&1; then
	echo 'ERROR: modes must be launched by the active desktop user through sudo or Polkit' >&2
	exit 2
fi

ybv_begin_report modes "$output_dir"

finish_modes() {
	local finish_rc=0
	YBV_PHYSICAL_RESULT=PENDING
	ybv_finish_report_for_user "$real_user" || finish_rc=$?
	return "$finish_rc"
}

find_input_node() {
	local wanted=$1
	python3 - "$wanted" <<'PY'
import glob
import sys

from evdev import InputDevice

wanted = sys.argv[1]
for path in sorted(glob.glob("/dev/input/event*")):
    try:
        device = InputDevice(path)
        name = device.name
        device.close()
    except OSError:
        continue
    if name == wanted:
        print(path)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

input_present() {
	find_input_node "$1" >/dev/null 2>&1
}

halo_ready() {
	systemctl is-active --quiet halo-keyboard.service &&
		[[ -e /dev/halo_keyboard ]] &&
		input_present 'Halo Keyboard' &&
		input_present 'Halo Keyboard Touchpad'
}

mutter_state() {
	ybv_run_as_user "$real_user" python3 - <<'PY'
from gi.repository import Gio

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
reply = bus.call_sync(
    "org.gnome.Mutter.DisplayConfig",
    "/org/gnome/Mutter/DisplayConfig",
    "org.gnome.Mutter.DisplayConfig",
    "GetCurrentState",
    None,
    None,
    Gio.DBusCallFlags.NONE,
    5000,
    None,
)
_serial, monitors, logical_monitors, _properties = reply.unpack()
current_modes = {}
for monitor_spec, modes, _monitor_properties in monitors:
    connector = monitor_spec[0]
    current_modes[connector] = next(
        (mode[0] for mode in modes if mode[6].get("is-current", False)),
        "unknown",
    )
rows = []
for _x, _y, scale, transform, primary, monitor_specs, _logical_properties in logical_monitors:
    for monitor_spec in monitor_specs:
        connector = monitor_spec[0]
        rows.append(
            f"connector={connector} mode={current_modes.get(connector, 'unknown')} "
            f"transform={transform} primary={str(primary).lower()} scale={scale:.6f}"
        )
print("\n".join(sorted(rows)))
PY
}

desktop_settings() {
	local orientation onscreen
	orientation=$(ybv_run_as_user "$real_user" gsettings get \
		org.gnome.settings-daemon.peripherals.touchscreen orientation-lock)
	onscreen=$(ybv_run_as_user "$real_user" gsettings get \
		org.gnome.desktop.a11y.applications screen-keyboard-enabled)
	printf 'orientation-lock=%s screen-keyboard-enabled=%s\n' "$orientation" "$onscreen"
}

action_required() {
	printf 'ACTION_REQUIRED: %s\n' "$1" | tee -a "$YBV_LOG"
}

wait_for_pen() {
	local deadline=$((SECONDS + transition_timeout))
	while ((SECONDS < deadline)); do
		if input_present 'Wacom HID 169 Pen'; then
			return 0
		fi
		sleep 1
	done
	return 1
}

scan_transition_journal() {
	local journal_file="$YBV_REPORT_DIR/transition-journal.log"
	journalctl -b --since "$transition_started" --no-pager -o short-iso 2>>"$YBV_LOG" |
		grep -Ei 'halo|wacom|goodix' >"$journal_file" || true
	if grep -Eiq '(^|[^[:alpha:]])(fail(ed|ure)?|error|timed?[ -]?out|timeout|hung|oops|bug|warning)([^[:alpha:]]|$)' "$journal_file"; then
		ybv_emit input transition-journal FAIL 'Halo, Wacom or Goodix failure found during the mode cycle' 'See transition-journal.log'
	else
		ybv_emit input transition-journal PASS 'No Halo, Wacom or Goodix failure was logged during the mode cycle'
	fi
}

wait_for_keyboard() {
	local deadline=$((SECONDS + transition_timeout))
	while ((SECONDS < deadline)); do
		if ! input_present 'Wacom HID 169 Pen' && halo_ready; then
			return 0
		fi
		sleep 1
	done
	return 1
}

compare_state() {
	local check_id=$1 label=$2 expected=$3 actual=$4
	if [[ $actual == "$expected" ]]; then
		ybv_emit input "$check_id" PASS "$label is unchanged" "$actual"
	else
		ybv_emit input "$check_id" FAIL "$label changed during the mode cycle" "before=$expected; now=$actual"
	fi
}

if systemctl is-active --quiet halo-keyboard.service; then
	baseline_restarts=$(systemctl show halo-keyboard.service --property=NRestarts --value 2>>"$YBV_LOG" || true)
	ybv_emit input halo-service-start PASS 'Halo keyboard service is active at the start' "restarts=${baseline_restarts:-unknown}"
else
	baseline_restarts=
	ybv_emit input halo-service-start FAIL 'Halo keyboard service is not active at the start'
fi
if [[ -e /dev/halo_keyboard ]]; then
	ybv_emit input halo-device-start PASS '/dev/halo_keyboard is present at the start'
else
	ybv_emit input halo-device-start FAIL '/dev/halo_keyboard is missing at the start'
fi
for device in 'Halo Keyboard' 'Halo Keyboard Touchpad'; do
	check_id=${device,,}
	check_id=${check_id// /-}
	if input_present "$device"; then
		ybv_emit input "$check_id-start" PASS "$device is present at the start"
	else
		ybv_emit input "$check_id-start" FAIL "$device is missing at the start"
	fi
done
if input_present 'Goodix Capacitive TouchScreen'; then
	ybv_emit input touchscreen-start PASS 'Display touchscreen is present at the start'
else
	ybv_emit input touchscreen-start FAIL 'Display touchscreen is missing at the start'
fi
if input_present 'Wacom HID 169 Pen'; then
	ybv_emit input pen-start FAIL 'Wacom pen is already active; start this test in Halo keyboard mode'
else
	ybv_emit input pen-start PASS 'Wacom pen is inactive in Halo keyboard mode'
fi

baseline_display=$(mutter_state 2>>"$YBV_LOG" || true)
if [[ -n $baseline_display ]]; then
	ybv_emit display mutter-start PASS 'Captured the initial Mutter logical display state' "$baseline_display"
else
	ybv_emit display mutter-start FAIL 'Could not capture the initial Mutter logical display state'
fi
baseline_settings=$(desktop_settings 2>>"$YBV_LOG" || true)
if [[ -n $baseline_settings ]]; then
	ybv_emit desktop settings-start PASS 'Captured orientation-lock and onscreen-keyboard settings' "$baseline_settings"
else
	ybv_emit desktop settings-start FAIL 'Could not capture GNOME input settings'
fi

if ((YBV_FAILURES > 0)); then
	ybv_emit input mode-start FAIL 'Mode-cycle prerequisites are not satisfied; no transition was requested'
	finish_rc=0
	finish_modes || finish_rc=$?
	exit "$finish_rc"
fi

transition_started=$(date --iso-8601=seconds)
action_required "Switch the Yoga Book from Halo keyboard mode to drawing/pen mode within ${transition_timeout} seconds."
if wait_for_pen; then
	pen_node=$(find_input_node 'Wacom HID 169 Pen')
	ybv_emit input pen-appeared PASS 'Wacom pen appeared after the physical mode switch'
else
	ybv_emit input pen-appeared FAIL "Wacom pen did not appear within ${transition_timeout} seconds"
	scan_transition_journal
	finish_rc=0
	finish_modes || finish_rc=$?
	exit "$finish_rc"
fi

if pen_details=$(python3 - "$pen_node" 2>&1 <<'PY'
import sys

from evdev import InputDevice, ecodes

device = InputDevice(sys.argv[1])
try:
    capabilities = device.capabilities(absinfo=False)
finally:
    device.close()
absolute = set(capabilities.get(ecodes.EV_ABS, []))
keys = set(capabilities.get(ecodes.EV_KEY, []))
required_absolute = {ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_PRESSURE}
required_keys = {ecodes.BTN_TOOL_PEN, ecodes.BTN_TOUCH}
missing = [ecodes.bytype[ecodes.EV_ABS].get(code, str(code)) for code in sorted(required_absolute - absolute)]
missing += [ecodes.bytype[ecodes.EV_KEY].get(code, str(code)) for code in sorted(required_keys - keys)]
if missing:
    raise RuntimeError("missing capabilities: " + ", ".join(missing))
print("position=ABS_X+ABS_Y pressure=ABS_PRESSURE tool=BTN_TOOL_PEN touch=BTN_TOUCH")
PY
); then
	ybv_emit input pen-capabilities PASS 'Wacom pen exposes position, pressure, tool and touch capabilities' "$pen_details"
else
	ybv_emit input pen-capabilities FAIL 'Wacom pen capability map is incomplete' "$pen_details"
fi

calibration=$(
	udevadm info --query=property --name="$pen_node" 2>>"$YBV_LOG" |
		sed -n 's/^LIBINPUT_CALIBRATION_MATRIX=//p' | head -n 1 || true
)
if [[ $calibration == '0 1 0 -1 0 1' ]]; then
	ybv_emit input pen-calibration PASS 'Wacom pen has the Yoga Book libinput calibration matrix' "$calibration"
else
	ybv_emit input pen-calibration FAIL 'Wacom pen calibration matrix is missing or incorrect' "actual=${calibration:-unset}; expected=0 1 0 -1 0 1"
fi
if input_present 'Goodix Capacitive TouchScreen'; then
	ybv_emit input touchscreen-pen-mode PASS 'Display touchscreen remains present in pen mode'
else
	ybv_emit input touchscreen-pen-mode FAIL 'Display touchscreen disappeared in pen mode'
fi
pen_display=$(mutter_state 2>>"$YBV_LOG" || true)
compare_state mutter-pen-mode 'Mutter logical display state in pen mode' "$baseline_display" "$pen_display"
pen_settings=$(desktop_settings 2>>"$YBV_LOG" || true)
compare_state settings-pen-mode 'GNOME orientation-lock and onscreen-keyboard settings in pen mode' "$baseline_settings" "$pen_settings"

action_required "Switch the Yoga Book back to Halo keyboard mode within ${transition_timeout} seconds."
if wait_for_keyboard; then
	ybv_emit input keyboard-returned PASS 'Halo keyboard service and virtual devices returned after the physical mode switch'
else
	ybv_emit input keyboard-returned FAIL "Halo keyboard mode was not ready within ${transition_timeout} seconds"
fi

if input_present 'Wacom HID 169 Pen'; then
	ybv_emit input pen-disappeared FAIL 'Wacom pen remains active after returning to keyboard mode'
else
	ybv_emit input pen-disappeared PASS 'Wacom pen is inactive after returning to keyboard mode'
fi
if systemctl is-active --quiet halo-keyboard.service; then
	ybv_emit input halo-service-restored PASS 'Halo keyboard service is active after the mode cycle'
else
	ybv_emit input halo-service-restored FAIL 'Halo keyboard service is inactive after the mode cycle'
fi
final_restarts=$(systemctl show halo-keyboard.service --property=NRestarts --value 2>>"$YBV_LOG" || true)
if [[ -n $baseline_restarts && $final_restarts == "$baseline_restarts" ]]; then
	ybv_emit input halo-service-restarts PASS 'Halo keyboard service did not restart during the mode cycle' "restarts=$final_restarts"
else
	ybv_emit input halo-service-restarts FAIL 'Halo keyboard service restart count changed or became unavailable' "before=${baseline_restarts:-unknown}; now=${final_restarts:-unknown}"
fi
if [[ -e /dev/halo_keyboard ]]; then
	ybv_emit input halo-device-restored PASS '/dev/halo_keyboard is restored after the mode cycle'
else
	ybv_emit input halo-device-restored FAIL '/dev/halo_keyboard is missing after the mode cycle'
fi
for device in 'Halo Keyboard' 'Halo Keyboard Touchpad'; do
	check_id=${device,,}
	check_id=${check_id// /-}
	if input_present "$device"; then
		ybv_emit input "$check_id-restored" PASS "$device is restored after the mode cycle"
	else
		ybv_emit input "$check_id-restored" FAIL "$device is missing after the mode cycle"
	fi
done
if input_present 'Goodix Capacitive TouchScreen'; then
	ybv_emit input touchscreen-restored PASS 'Display touchscreen remains present after the mode cycle'
else
	ybv_emit input touchscreen-restored FAIL 'Display touchscreen is missing after the mode cycle'
fi
final_display=$(mutter_state 2>>"$YBV_LOG" || true)
compare_state mutter-restored 'Mutter logical display state after the mode cycle' "$baseline_display" "$final_display"
final_settings=$(desktop_settings 2>>"$YBV_LOG" || true)
compare_state settings-restored 'GNOME orientation-lock and onscreen-keyboard settings after the mode cycle' "$baseline_settings" "$final_settings"

scan_transition_journal

finish_rc=0
finish_modes || finish_rc=$?
exit "$finish_rc"
