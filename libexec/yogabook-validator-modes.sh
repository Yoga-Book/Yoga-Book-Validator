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
stable_samples=10
stable_interval=0.2
all_orientations=false
transition_trace_pid=
transition_trace_stop_file=
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
	--all-orientations)
		all_orientations=true
		shift
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

report_name=modes
[[ $all_orientations == false ]] || report_name=rotation
ybv_begin_report "$report_name" "$output_dir"

finish_modes() {
	local finish_rc=0
	YBV_PHYSICAL_RESULT=PENDING
	ybv_finish_report_for_user "$real_user" || finish_rc=$?
	return "$finish_rc"
}

stop_transition_trace() {
	if [[ -n ${transition_trace_pid:-} ]]; then
		[[ -n ${transition_trace_stop_file:-} ]] && touch "$transition_trace_stop_file"
		for _attempt in {1..50}; do
			kill -0 "$transition_trace_pid" 2>/dev/null || break
			sleep 0.1
		done
		kill "$transition_trace_pid" 2>/dev/null || true
		wait "$transition_trace_pid" 2>/dev/null || true
		transition_trace_pid=
	fi
	if [[ -n ${transition_trace_stop_file:-} ]]; then
		rm -f -- "$transition_trace_stop_file"
		transition_trace_stop_file=
	fi
}

trap 'stop_transition_trace' EXIT INT TERM

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

find_pen_node() {
	python3 - <<'PY'
import glob

from evdev import InputDevice, ecodes

fallback = None
required_absolute = {ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_PRESSURE}
required_keys = {ecodes.BTN_TOOL_PEN, ecodes.BTN_TOUCH}
for path in sorted(glob.glob("/dev/input/event*")):
    try:
        device = InputDevice(path)
        name = device.name
        capabilities = device.capabilities(absinfo=False)
        device.close()
    except OSError:
        continue
    if name != "Wacom HID 169 Pen":
        continue
    fallback = fallback or path
    if (required_absolute <= set(capabilities.get(ecodes.EV_ABS, [])) and
            required_keys <= set(capabilities.get(ecodes.EV_KEY, []))):
        print(path)
        raise SystemExit(0)
if fallback:
    print(fallback)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

halo_ready() {
	systemctl is-active --quiet halo-keyboard.service &&
		[[ -e /dev/halo_keyboard ]] &&
		input_present 'Halo Keyboard' &&
		input_present 'Halo Keyboard Touchpad'
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
	local deadline=$((SECONDS + transition_timeout)) consecutive=0
	while ((SECONDS < deadline)); do
		if input_present 'Wacom HID 169 Pen'; then
			((++consecutive))
			if ((consecutive >= stable_samples)); then
				return 0
			fi
		else
			consecutive=0
		fi
		sleep "$stable_interval"
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
	local deadline=$((SECONDS + transition_timeout)) consecutive=0
	while ((SECONDS < deadline)); do
		if ! input_present 'Wacom HID 169 Pen' && halo_ready; then
			((++consecutive))
			if ((consecutive >= stable_samples)); then
				return 0
			fi
		else
			consecutive=0
		fi
		sleep "$stable_interval"
	done
	return 1
}

start_transition_trace() {
	local trace_file="$YBV_REPORT_DIR/mode-transition.tsv"
	transition_trace_stop_file="$YBV_REPORT_DIR/.mode-transition.stop"
	rm -f -- "$transition_trace_stop_file"
	touch "$trace_file"
	chown -- "$real_user:$(id -gn "$real_user")" "$trace_file"
	ybv_run_as_user "$real_user" \
		"$LIBEXEC_DIR/yogabook-validator-mode-trace.py" \
		--output "$trace_file" --interval 0.1 \
		--stop-file "$transition_trace_stop_file" >>"$YBV_LOG" 2>&1 &
	transition_trace_pid=$!
	for _attempt in {1..20}; do
		[[ $(wc -l <"$trace_file") -ge 2 ]] && return 0
		kill -0 "$transition_trace_pid" 2>/dev/null || return 1
		sleep 0.1
	done
	return 1
}

check_halo_landscape() {
	local check_id=$1 timing=$2 display_state=$3 status
	if [[ $display_state == *'connector=DSI-1 mode=1920x1200@'* &&
		$display_state == *' transform=0 '* ]]; then
		ybv_emit display "$check_id" PASS \
			"Mutter uses the upright landscape transform $timing" "$display_state"
	else
		status=FAIL
		[[ $timing == 'at the start' ]] && status=WARN
		ybv_emit display "$check_id" "$status" \
			"Mutter does not use the upright landscape transform $timing" \
			"actual=${display_state:-unavailable}; expected=DSI-1 1920x1200 transform=0"
	fi
}

expected_transform_for_sensor() {
	case $1 in
	normal) printf '1\n' ;;
	right-up) printf '0\n' ;;
	bottom-up) printf '3\n' ;;
	left-up) printf '2\n' ;;
	*) return 1 ;;
	esac
}

sensor_transform_matches() {
	local display_state=$1 trace_file="$YBV_REPORT_DIR/mode-transition.tsv"
	local sensor actual expected
	sensor=$(tail -n 1 "$trace_file" | cut -f3)
	actual=$(sed -n 's/.* transform=\([0-9][0-9]*\).*/\1/p' <<<"$display_state")
	if ! expected=$(expected_transform_for_sensor "$sensor"); then
		ybv_emit display mutter-pen-orientation WARN \
			'Could not correlate Mutter with SensorProxy in pen mode' \
			"sensor=${sensor:-unavailable}; display=$display_state"
		return
	fi
	if [[ $actual == "$expected" ]]; then
		ybv_emit display mutter-pen-orientation PASS \
			'Mutter pen-mode transform matches the stable physical orientation' \
			"sensor=$sensor transform=$actual"
	else
		ybv_emit display mutter-pen-orientation FAIL \
			'Mutter pen-mode transform does not match the stable physical orientation' \
			"sensor=$sensor expected-transform=$expected actual-transform=${actual:-unavailable}"
	fi
}

exercise_all_orientations() {
	local trace_file="$YBV_REPORT_DIR/mode-transition.tsv"
	local deadline=$((SECONDS + transition_timeout)) line timestamp monotonic sensor
	local connector mode transform expected pair last_pair= last_monotonic= consecutive=0
	local completed=false missing
	local -a orientations=(right-up normal bottom-up left-up)
	declare -A observed=()

	action_required "Rotate the tablet slowly through both portrait orientations and upside-down landscape, then return to upright landscape within ${transition_timeout} seconds."
	while ((SECONDS < deadline)); do
		line=$(tail -n 1 "$trace_file")
		IFS=$'\t' read -r timestamp monotonic sensor connector mode transform _rest <<<"$line"
		if [[ -z $monotonic || $monotonic == "$last_monotonic" ]]; then
			sleep 0.1
			continue
		fi
		last_monotonic=$monotonic
		if expected=$(expected_transform_for_sensor "$sensor") &&
			[[ $connector == DSI-1 && $mode == 1920x1200@* && $transform == "$expected" ]]; then
			pair="$sensor:$transform"
			if [[ $pair == "$last_pair" ]]; then
				((++consecutive))
			else
				last_pair=$pair
				consecutive=1
			fi
			if ((consecutive >= stable_samples)) && [[ -z ${observed[$sensor]:-} ]]; then
				observed[$sensor]=$transform
				action_required "Detected stable $sensor orientation; continue through the remaining orientations and finish upright."
			fi
			if ((${#observed[@]} == ${#orientations[@]})) &&
				[[ $sensor == right-up && $transform == 0 ]]; then
				completed=true
				break
			fi
		else
			last_pair=
			consecutive=0
		fi
		sleep 0.1
	done

	missing=()
	for sensor in "${orientations[@]}"; do
		expected=$(expected_transform_for_sensor "$sensor")
		if [[ ${observed[$sensor]:-} == "$expected" ]]; then
			ybv_emit display "rotation-$sensor" PASS \
				"SensorProxy and Mutter reached a stable $sensor orientation" \
				"sensor=$sensor transform=$expected"
		else
			missing+=("$sensor:$expected")
			ybv_emit display "rotation-$sensor" FAIL \
				"SensorProxy and Mutter did not reach a stable $sensor orientation" \
				"expected-transform=$expected"
		fi
	done
	if [[ $completed == true ]]; then
		ybv_emit display rotation-upright-return PASS \
			'Automatic rotation returned to upright landscape' \
			'sensor=right-up transform=0'
		return 0
	fi
	ybv_emit display rotation-upright-return FAIL \
		'Automatic rotation did not complete all orientations and return upright' \
		"missing=${missing[*]:-upright-return}"
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
if input_present 'HDP0001:00 2ABB:8102'; then
	ybv_emit input touchscreen-start PASS 'Display touchscreen is present at the start'
else
	ybv_emit input touchscreen-start FAIL 'Display touchscreen is missing at the start'
fi
if input_present 'Wacom HID 169 Pen'; then
	ybv_emit input pen-start FAIL 'Wacom pen is already active; start this test in Halo keyboard mode'
else
	ybv_emit input pen-start PASS 'Wacom pen is inactive in Halo keyboard mode'
fi

baseline_display=$(ybv_mutter_state "$real_user" 2>>"$YBV_LOG" || true)
if [[ -n $baseline_display ]]; then
	ybv_emit display mutter-start PASS 'Captured the initial Mutter logical display state' "$baseline_display"
	check_halo_landscape halo-landscape-start 'at the start' "$baseline_display"
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
if start_transition_trace; then
	ybv_emit display transition-trace PASS 'Started synchronized mode-transition tracing' 'mode-transition.tsv; interval=100ms'
else
	ybv_emit display transition-trace FAIL 'Could not start synchronized mode-transition tracing'
	finish_rc=0
	finish_modes || finish_rc=$?
	exit "$finish_rc"
fi
action_required "Switch the Yoga Book from Halo keyboard mode to drawing/pen mode within ${transition_timeout} seconds."
if wait_for_pen; then
	pen_node=$(find_pen_node)
	ybv_emit input pen-appeared PASS 'Wacom pen remained present for two seconds after the physical mode switch'
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
    def capability_name(value):
        if isinstance(value, (tuple, list)):
            return "/".join(str(alias) for alias in value)
        return str(value)
    raise RuntimeError("missing capabilities: " + ", ".join(map(capability_name, missing)))
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
if input_present 'HDP0001:00 2ABB:8102'; then
	ybv_emit input touchscreen-pen-mode PASS 'Display touchscreen remains present in pen mode'
else
	ybv_emit input touchscreen-pen-mode FAIL 'Display touchscreen disappeared in pen mode'
fi
pen_display=$(ybv_mutter_state "$real_user" 2>>"$YBV_LOG" || true)
sensor_transform_matches "$pen_display"
pen_settings=$(desktop_settings 2>>"$YBV_LOG" || true)
compare_state settings-pen-mode 'GNOME orientation-lock and onscreen-keyboard settings in pen mode' "$baseline_settings" "$pen_settings"
if [[ $all_orientations == true ]]; then
	exercise_all_orientations || true
fi

action_required "Switch the Yoga Book back to Halo keyboard mode within ${transition_timeout} seconds."
if wait_for_keyboard; then
	ybv_emit input keyboard-returned PASS 'Halo keyboard state remained complete for two seconds after the physical mode switch'
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
if input_present 'HDP0001:00 2ABB:8102'; then
	ybv_emit input touchscreen-restored PASS 'Display touchscreen remains present after the mode cycle'
else
	ybv_emit input touchscreen-restored FAIL 'Display touchscreen is missing after the mode cycle'
fi
final_display=$(ybv_mutter_state "$real_user" 2>>"$YBV_LOG" || true)
check_halo_landscape halo-landscape-restored 'after the mode cycle' "$final_display"
final_settings=$(desktop_settings 2>>"$YBV_LOG" || true)
compare_state settings-restored 'GNOME orientation-lock and onscreen-keyboard settings after the mode cycle' "$baseline_settings" "$final_settings"

stop_transition_trace
trace_samples=$(($(wc -l <"$YBV_REPORT_DIR/mode-transition.tsv") - 1))
if ((trace_samples > 0)); then
	ybv_emit display transition-trace-complete PASS 'Captured synchronized SensorProxy, Mutter and input-mode samples' "samples=$trace_samples; mode-transition.tsv"
else
	ybv_emit display transition-trace-complete FAIL 'The synchronized mode-transition trace is empty'
fi
scan_transition_journal

finish_rc=0
finish_modes || finish_rc=$?
exit "$finish_rc"
