#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail

YBV_VERSION=0.29.0
YBV_SYSROOT=${YBV_SYSROOT:-/}
YBV_RESULTS_BASE=${YBV_RESULTS_BASE:-${PWD}/yogabook-validator-results}
YBV_REPORT_DIR=${YBV_REPORT_DIR:-}
YBV_FAILURES=0
YBV_WARNINGS=0
YBV_AUTO_REPORT_OWNER=
YBV_RESTORE_CALLBACK=
YBV_STATE_BEFORE=
YBV_STATE_AFTER=
YBV_COMMON_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ybv_path() {
	local path=$1
	if [[ $YBV_SYSROOT == / ]]; then
		printf '%s\n' "$path"
	else
		printf '%s%s\n' "${YBV_SYSROOT%/}" "$path"
	fi
}

ybv_sanitize() {
	local value=${1:-}
	value=${value//$'\t'/ }
	value=${value//$'\r'/ }
	value=${value//$'\n'/ }
	printf '%s' "$value"
}

ybv_begin_report() {
	local command_name=$1 requested_dir=${2:-}
	local timestamp report_owner generated_default=false
	timestamp=$(date +%Y%m%d-%H%M%S)
	if [[ -n $requested_dir ]]; then
		YBV_REPORT_DIR=$requested_dir
	elif [[ -z $YBV_REPORT_DIR ]]; then
		YBV_REPORT_DIR="$YBV_RESULTS_BASE/${command_name}-${timestamp}"
		generated_default=true
	fi
	mkdir -p -- "$YBV_REPORT_DIR"
	if [[ $generated_default == true && $EUID -eq 0 ]]; then
		report_owner=$(ybv_real_user)
		if [[ -n $report_owner && $report_owner != root ]] && id "$report_owner" >/dev/null 2>&1; then
			YBV_AUTO_REPORT_OWNER=$report_owner
			chown -- "$report_owner:$(id -gn "$report_owner")" "$YBV_RESULTS_BASE" 2>/dev/null || true
			chown -- "$report_owner:$(id -gn "$report_owner")" "$YBV_REPORT_DIR" 2>/dev/null || true
		fi
	fi
	YBV_REPORT="$YBV_REPORT_DIR/results.tsv"
	YBV_LOG="$YBV_REPORT_DIR/validator.log"
	YBV_ENVIRONMENT="$YBV_REPORT_DIR/environment.tsv"
	YBV_STATE_BEFORE="$YBV_REPORT_DIR/state-before.tsv"
	YBV_STATE_AFTER="$YBV_REPORT_DIR/state-after.tsv"
	printf 'timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n' >"$YBV_REPORT"
	{
		printf 'key\tvalue\n'
		printf 'device\t%s\n' "$(ybv_sanitize "$(ybv_read_first /sys/class/dmi/id/product_name)")"
		printf 'kernel\t%s\n' "$(ybv_sanitize "$(uname -srmo 2>/dev/null || true)")"
		printf 'architecture\t%s\n' "$(ybv_sanitize "$(uname -m 2>/dev/null || true)")"
		printf 'operating_system\t%s\n' "$(ybv_sanitize "$(sed -n 's/^PRETTY_NAME=//p' "$(ybv_path /etc/os-release)" 2>/dev/null | head -n 1 | tr -d '\"')")"
		printf 'boot_id\t%s\n' "$(ybv_sanitize "$(ybv_read_first /proc/sys/kernel/random/boot_id)")"
		printf 'desktop\t%s\n' "$(ybv_sanitize "${XDG_CURRENT_DESKTOP:-unknown}")"
		printf 'session_type\t%s\n' "$(ybv_sanitize "${XDG_SESSION_TYPE:-unknown}")"
	} >"$YBV_ENVIRONMENT"
	{
		printf 'Yoga Book Validator %s\n' "$YBV_VERSION"
		printf 'Command: %s\n' "$command_name"
		printf 'Started: %s\n' "$(date --iso-8601=seconds)"
		printf 'Report directory: %s\n\n' "$YBV_REPORT_DIR"
	} >"$YBV_LOG"
	if ! ybv_capture_state_snapshot "$YBV_STATE_BEFORE"; then
		printf 'STATE_SNAPSHOT_ERROR: initial state capture failed\n' | tee -a "$YBV_LOG" >&2
	fi
}

ybv_register_restore_callback() {
	local callback=$1
	[[ $callback =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 2
	declare -F "$callback" >/dev/null || return 2
	YBV_RESTORE_CALLBACK=$callback
}

ybv_snapshot_sysfs_values() {
	local class_dir=$1
	shift
	local directory attribute value name
	[[ -d $class_dir ]] || return 0
	for directory in "$class_dir"/*; do
		[[ -e $directory ]] || continue
		name=${directory##*/}
		for attribute in "$@"; do
			[[ -r $directory/$attribute ]] || continue
			value=$(tr '\n\t' '  ' <"$directory/$attribute" 2>/dev/null || true)
			printf 'sysfs:%s:%s\t%s\n' "$name" "$attribute" "$(ybv_sanitize "$value")"
		done
	done
}

ybv_snapshot_led_state() {
	local class_dir=$1 directory name triggers current brightness
	[[ -d $class_dir ]] || return 0
	for directory in "$class_dir"/*; do
		[[ -e $directory && -r $directory/trigger ]] || continue
		name=${directory##*/}
		triggers=$(tr '\n\t' '  ' <"$directory/trigger" 2>/dev/null || true)
		current=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' <<<"$triggers")
		printf 'sysfs:%s:trigger\t%s\n' "$name" "$(ybv_sanitize "$current")"
		# Trigger-driven brightness may change asynchronously and is not mutable
		# policy. Halo keyboard brightness is likewise owned by halo-keyboard's
		# idle/mode state even while its kernel trigger reads "none". The active
		# lights test snapshots and verifies that control explicitly.
		if [[ $current == none && $name != 'ybwmi::kbd_backlight' && -r $directory/brightness ]]; then
			brightness=$(tr '\n\t' '  ' <"$directory/brightness" 2>/dev/null || true)
			printf 'sysfs:%s:brightness\t%s\n' "$name" "$(ybv_sanitize "$brightness")"
		fi
	done
}

ybv_capture_state_snapshot() {
	local output=$1 temporary real_user user_uid unit state restarts source fstype options
	local sysroot=${YBV_SYSROOT%/}
	[[ -n $sysroot ]] || sysroot=/
	temporary=$(mktemp "${output}.XXXXXX") || return 1
	{
		printf 'schema\torg.yogabook.validator.state/v1\n'
		ybv_snapshot_sysfs_values "$sysroot/sys/class/backlight" brightness
		ybv_snapshot_led_state "$sysroot/sys/class/leds"
		ybv_snapshot_sysfs_values "$sysroot/sys/class/rfkill" type name soft hard

		if [[ $YBV_SYSROOT == / ]]; then
			for unit in halo-keyboard.service yogabook-camera.service yogabook-gnss.service \
				iio-sensor-proxy.service bluetooth.service ModemManager.service; do
				state=$(systemctl show "$unit" --property=ActiveState,SubState --value 2>/dev/null | tr '\n' '/' || true)
				restarts=$(systemctl show "$unit" --property=NRestarts --value 2>/dev/null || true)
				printf 'system-service:%s\tstate=%s restarts=%s\n' "$unit" "${state%/}" "${restarts:-unknown}"
			done

			real_user=$(ybv_real_user)
			if [[ -n $real_user && $real_user != root ]] && id "$real_user" >/dev/null 2>&1; then
				user_uid=$(id -u "$real_user")
				for unit in pipewire.service pipewire-pulse.service wireplumber.service; do
					state=$(ybv_run_as_user "$real_user" systemctl --user show "$unit" \
						--property=ActiveState,SubState --value 2>/dev/null | tr '\n' '/' || true)
					printf 'user-service:%s:%s\t%s\n' "$user_uid" "$unit" "${state%/}"
				done
				if command -v gsettings >/dev/null 2>&1; then
					printf 'desktop:orientation-lock\t%s\n' "$(ybv_run_as_user "$real_user" gsettings get org.gnome.settings-daemon.peripherals.touchscreen orientation-lock 2>/dev/null || true)"
					printf 'desktop:screen-keyboard\t%s\n' "$(ybv_run_as_user "$real_user" gsettings get org.gnome.desktop.a11y.applications screen-keyboard-enabled 2>/dev/null || true)"
				fi
				if declare -F ybv_mutter_state >/dev/null; then
					printf 'desktop:mutter\t%s\n' "$(ybv_mutter_state "$real_user" 2>/dev/null | tr '\n' ';' || true)"
				fi
				if command -v pactl >/dev/null 2>&1; then
					ybv_run_as_user "$real_user" timeout 4 pactl list cards 2>/dev/null |
						awk '
							/^[[:space:]]*Name:/ { card=$2 }
							/^[[:space:]]*alsa\.id = "yogabook"$/ { target=card }
							/^[[:space:]]*Active Profile:/ && card == target {
								sub(/^[[:space:]]*Active Profile:[[:space:]]*/, "")
								print "desktop:audio-profile\\t" target " profile=" $0
							}
						' || true
				fi
			fi

			if command -v amixer >/dev/null 2>&1; then
				timeout 5 amixer -c yogabook contents 2>/dev/null |
					awk '
						/^numid=/ { control=$0; writable=0; next }
						/^[[:space:]]*; type=/ { writable=($0 ~ /access=rw/); next }
						writable && /^[[:space:]]*: values=/ {
							values=$0
							sub(/^[[:space:]]*: values=/, "", values)
							print "audio:alsa-control:" control "\\t" values
						}
					' || true
			fi
			if command -v btmgmt >/dev/null 2>&1; then
				state=$(timeout 5 btmgmt info 2>/dev/null | sed -n 's/^[[:space:]]*current settings: /settings=/p' | head -n 1 || true)
				[[ -z $state ]] || printf 'bluetooth:controller\t%s\n' "$state"
			fi
			if command -v findmnt >/dev/null 2>&1; then
				while read -r source fstype options; do
					[[ $source == /dev/mmcblk* ]] || continue
					printf 'mount:%s\tfstype=%s options=%s\n' "${source##*/}" "$fstype" "$options"
				done < <(findmnt -rn -o SOURCE,FSTYPE,OPTIONS 2>/dev/null)
			fi
			printf 'temporary:validator-mounts\t%s\n' "$(find /run -maxdepth 1 -type d -name 'yogabook-validator-*' -printf '%f\n' 2>/dev/null | sort | tr '\n' ',' || true)"
		fi
	} | LC_ALL=C sort >"$temporary"
	mv -f -- "$temporary" "$output"
}

ybv_verify_state_preservation() {
	local callback_rc=0 diff_file="$YBV_REPORT_DIR/state-diff.txt"
	if [[ -n $YBV_RESTORE_CALLBACK ]]; then
		"$YBV_RESTORE_CALLBACK" || callback_rc=$?
	fi
	if ((callback_rc != 0)); then
		ybv_emit validator cleanup FAIL 'Registered cleanup did not complete successfully' "callback=$YBV_RESTORE_CALLBACK exit=$callback_rc"
	fi
	if [[ ! -s $YBV_STATE_BEFORE ]]; then
		ybv_emit validator state-preservation FAIL 'Initial mutable-state snapshot is unavailable'
		return 1
	fi
	if ! ybv_capture_state_snapshot "$YBV_STATE_AFTER"; then
		ybv_emit validator state-preservation FAIL 'Final mutable-state snapshot could not be captured'
		return 1
	fi
	if cmp -s -- "$YBV_STATE_BEFORE" "$YBV_STATE_AFTER"; then
		rm -f -- "$diff_file"
		ybv_emit validator state-preservation PASS 'Observable mutable state matches the pre-test snapshot'
		return "$callback_rc"
	fi
	diff -u -- "$YBV_STATE_BEFORE" "$YBV_STATE_AFTER" >"$diff_file" || true
	ybv_emit validator state-preservation FAIL 'Observable mutable state differs from the pre-test snapshot' 'See state-diff.txt'
	return 1
}

ybv_emit() {
	local subsystem=$1 check_id=$2 status=$3 summary=$4 details=${5:-}
	local now
	now=$(date --iso-8601=seconds)
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$now" "$(ybv_sanitize "$subsystem")" "$(ybv_sanitize "$check_id")" \
		"$status" "$(ybv_sanitize "$summary")" "$(ybv_sanitize "$details")" \
		>>"$YBV_REPORT"
	printf '[%-4s] %-10s %-26s %s' "$status" "$subsystem" "$check_id" "$summary" | tee -a "$YBV_LOG"
	if [[ -n $details ]]; then
		printf ' -- %s' "$(ybv_sanitize "$details")" | tee -a "$YBV_LOG"
	fi
	printf '\n' | tee -a "$YBV_LOG"
	case $status in
	FAIL) YBV_FAILURES=$((YBV_FAILURES + 1)) ;;
	WARN) YBV_WARNINGS=$((YBV_WARNINGS + 1)) ;;
	esac
}

ybv_finish_report() {
	local automated=${1:-true} result=PASS
	local renderer=${YBV_REPORT_RENDERER:-$YBV_COMMON_DIR/yogabook-validator-report.py}
	ybv_verify_state_preservation || true
	if ((YBV_FAILURES > 0)); then
		result=FAIL
	fi
	{
		printf '\nAUTOMATED_RESULT: %s\n' "$result"
		printf 'PHYSICAL_ACCEPTANCE_RESULT: %s\n' "${YBV_PHYSICAL_RESULT:-PENDING}"
		printf 'Failures: %d\nWarnings: %d\n' "$YBV_FAILURES" "$YBV_WARNINGS"
		printf 'Finished: %s\n' "$(date --iso-8601=seconds)"
	} | tee -a "$YBV_LOG"
	if command -v python3 >/dev/null 2>&1 && [[ -r $renderer ]]; then
		if ! python3 "$renderer" "$YBV_REPORT_DIR"; then
			printf 'REPORT_GENERATION_ERROR: JSON, Markdown and HTML rendering failed\n' | tee -a "$YBV_LOG" >&2
		fi
	else
		printf 'REPORT_GENERATION_ERROR: report renderer or Python 3 is unavailable\n' | tee -a "$YBV_LOG" >&2
	fi
	if [[ -n $YBV_AUTO_REPORT_OWNER ]]; then
		ybv_chown_tree_to_user "$YBV_AUTO_REPORT_OWNER" "$YBV_REPORT_DIR" 2>/dev/null || true
	fi
	printf '%s\n' "$YBV_REPORT_DIR"
	if [[ $automated == true && $result == FAIL ]]; then
		return 1
	fi
}

ybv_read_first() {
	local path
	path=$(ybv_path "$1")
	[[ -r $path ]] && head -n 1 -- "$path" || true
}

ybv_has_command() {
	command -v "$1" >/dev/null 2>&1
}

ybv_capture() {
	local label=$1
	shift
	{
		printf '\n===== %s =====\n' "$label"
		"$@"
	} >>"$YBV_LOG" 2>&1 || true
}

ybv_require_x91l() {
	local product
	product=$(ybv_read_first /sys/class/dmi/id/product_name)
	[[ $product == *YB1-X91L* ]]
}

ybv_find_card_number() {
	local id_file id
	for id_file in "$(ybv_path /proc/asound)"/card*/id; do
		[[ -r $id_file ]] || continue
		read -r id <"$id_file" || true
		if [[ $id == yogabook ]]; then
			id_file=${id_file%/id}
			printf '%s\n' "${id_file##*card}"
			return 0
		fi
	done
	return 1
}

ybv_real_user() {
	local uid=${PKEXEC_UID:-${SUDO_UID:-}}
	if [[ -n $uid && $uid =~ ^[0-9]+$ && $uid -ne 0 ]]; then
		getent passwd "$uid" | cut -d: -f1
	else
		printf '%s\n' "${SUDO_USER:-${USER:-root}}"
	fi
}

ybv_run_as_user() {
	local user=$1
	shift
	local uid
	uid=$(id -u "$user")
	if [[ $(id -u) -eq $uid ]]; then
		env XDG_RUNTIME_DIR="/run/user/$uid" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
	else
		runuser -u "$user" -- env \
			XDG_RUNTIME_DIR="/run/user/$uid" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
	fi
}

ybv_mutter_state() {
	local user=$1
	ybv_run_as_user "$user" python3 - <<'PY'
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

ybv_chown_tree_to_user() {
	local user=$1 path=$2 group
	group=$(id -gn "$user") || return 1
	chown -R -- "$user:$group" "$path"
}

ybv_finish_report_for_user() {
	local user=$1 finish_rc=0
	ybv_finish_report || finish_rc=$?
	if [[ -n $user && -d $YBV_REPORT_DIR ]]; then
		ybv_chown_tree_to_user "$user" "$YBV_REPORT_DIR" 2>/dev/null || true
	fi
	return "$finish_rc"
}
