#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ $EUID -eq 0 && ${YBV_ACTIVE_DISPATCH:-} == 1 ]] || {
	echo 'ERROR: lights test must be launched through yogabook-validator' >&2
	exit 2
}
output_dir=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
ybv_require_x91l || { echo 'ERROR: lights tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report lights "$output_dir"
ybv_register_state_keys \
	'sysfs:intel_backlight:brightness' \
	'sysfs:ybwmi::kbd_backlight:*' \
	'sysfs:platform::indicator:*' \
	'sysfs:platform::charging:*'
real_user=$(ybv_real_user)
[[ $real_user != root ]] || real_user=
backlight=/sys/class/backlight/intel_backlight
led_root=/sys/class/leds
declare -a led_names=(ybwmi::kbd_backlight platform::indicator platform::charging)
declare -A led_ids=([ybwmi::kbd_backlight]=halo-backlight [platform::indicator]=indicator-led [platform::charging]=charging-led)
declare -A original_brightness original_trigger
original_panel=
state_saved=false

current_trigger() {
	local path=$1 triggers
	read -r triggers <"$path"
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' <<<"$triggers"
}

restore_lights() {
	local restore_rc=0 name path current
	[[ $state_saved == true ]] || return 0
	printf '%s\n' "$original_panel" >"$backlight/brightness" 2>/dev/null || restore_rc=1
	for name in "${led_names[@]}"; do
		path="$led_root/$name"
		printf 'none\n' >"$path/trigger" 2>/dev/null || restore_rc=1
		printf '%s\n' "${original_brightness[$name]}" >"$path/brightness" 2>/dev/null || restore_rc=1
		if [[ ${original_trigger[$name]} != none ]]; then
			printf '%s\n' "${original_trigger[$name]}" >"$path/trigger" 2>/dev/null || restore_rc=1
		fi
	done
	sleep 0.25
	read -r current <"$backlight/brightness" || current=
	[[ $current == "$original_panel" ]] || restore_rc=1
	for name in "${led_names[@]}"; do
		path="$led_root/$name"
		current=$(current_trigger "$path/trigger" 2>/dev/null || true)
		[[ $current == "${original_trigger[$name]}" ]] || restore_rc=1
		if [[ $current == none ]]; then
			read -r current <"$path/brightness" || current=
			[[ $current == "${original_brightness[$name]}" ]] || restore_rc=1
		fi
	done
	return "$restore_rc"
}
trap 'restore_lights || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -w $backlight/brightness || ! -r $backlight/max_brightness ]]; then
	ybv_emit display panel-backlight FAIL 'Panel backlight control is unavailable'
	ybv_finish_report
	exit 1
fi
read -r original_panel <"$backlight/brightness"
for name in "${led_names[@]}"; do
	path="$led_root/$name"
	if [[ ! -w $path/brightness || ! -w $path/trigger || ! -r $path/max_brightness ]]; then
		ybv_emit platform "${led_ids[$name]}" FAIL 'Required Yoga Book LED control is unavailable' "$name"
		ybv_finish_report
		exit 1
	fi
	read -r original_brightness["$name"] <"$path/brightness"
	original_trigger[$name]=$(current_trigger "$path/trigger")
	[[ -n ${original_trigger[$name]} ]] || {
		ybv_emit platform "${led_ids[$name]}" FAIL 'Could not capture the active LED trigger' "$name"
		ybv_finish_report
		exit 1
	}
done
state_saved=true
ybv_register_restore_callback restore_lights

read -r panel_max <"$backlight/max_brightness"
if ((panel_max > 1)); then
	if ((original_panel < panel_max)); then panel_test=$((original_panel + 1)); else panel_test=$((original_panel - 1)); fi
	if printf '%s\n' "$panel_test" >"$backlight/brightness" && sleep 0.25 && [[ $(<"$backlight/brightness") == "$panel_test" ]]; then
		ybv_emit display panel-backlight PASS 'Panel backlight accepted a bounded one-step change' "$original_panel->$panel_test"
	else
		ybv_emit display panel-backlight FAIL 'Panel backlight did not accept a bounded one-step change'
	fi
else
		ybv_emit display panel-backlight FAIL 'Panel backlight range is invalid' "max=$panel_max"
fi

for name in "${led_names[@]}"; do
	path="$led_root/$name"
	read -r maximum <"$path/max_brightness"
	printf 'none\n' >"$path/trigger"
	if ((${original_brightness[$name]} < maximum)); then
		test_value=$((${original_brightness[$name]} + 1))
	else
		test_value=$((${original_brightness[$name]} - 1))
	fi
	if ((maximum > 0)) && printf '%s\n' "$test_value" >"$path/brightness" && sleep 0.15 && [[ $(<"$path/brightness") == "$test_value" ]]; then
		case $name in
		ybwmi::kbd_backlight) summary='Halo keyboard backlight accepted a bounded one-step change' ;;
		platform::indicator) summary='Platform indicator LED accepted a bounded one-step change' ;;
		platform::charging) summary='Charging LED accepted a bounded one-step change' ;;
		esac
		ybv_emit platform "${led_ids[$name]}" PASS "$summary" "${original_brightness[$name]}->$test_value"
	else
		ybv_emit platform "${led_ids[$name]}" FAIL 'LED brightness control did not accept a bounded one-step change' "$name"
	fi
done

if restore_lights; then
	ybv_emit platform state-restore PASS 'Restored panel and LED brightness and trigger state'
	trap - EXIT INT TERM
	state_saved=false
else
	ybv_emit platform state-restore FAIL 'Could not restore panel or LED state'
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report_for_user "$real_user"
