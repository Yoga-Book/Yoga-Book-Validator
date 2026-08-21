#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail

YBV_VERSION=0.2.0
YBV_SYSROOT=${YBV_SYSROOT:-/}
YBV_RESULTS_BASE=${YBV_RESULTS_BASE:-${PWD}/yogabook-validator-results}
YBV_REPORT_DIR=${YBV_REPORT_DIR:-}
YBV_FAILURES=0
YBV_WARNINGS=0

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
	local timestamp
	timestamp=$(date +%Y%m%d-%H%M%S)
	if [[ -n $requested_dir ]]; then
		YBV_REPORT_DIR=$requested_dir
	elif [[ -z $YBV_REPORT_DIR ]]; then
		YBV_REPORT_DIR="$YBV_RESULTS_BASE/${command_name}-${timestamp}"
	fi
	mkdir -p -- "$YBV_REPORT_DIR"
	YBV_REPORT="$YBV_REPORT_DIR/results.tsv"
	YBV_LOG="$YBV_REPORT_DIR/validator.log"
	printf 'timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n' >"$YBV_REPORT"
	{
		printf 'Yoga Book Validator %s\n' "$YBV_VERSION"
		printf 'Command: %s\n' "$command_name"
		printf 'Started: %s\n' "$(date --iso-8601=seconds)"
		printf 'Report directory: %s\n\n' "$YBV_REPORT_DIR"
	} >"$YBV_LOG"
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
	if ((YBV_FAILURES > 0)); then
		result=FAIL
	fi
	{
		printf '\nAUTOMATED_RESULT: %s\n' "$result"
		printf 'PHYSICAL_ACCEPTANCE_RESULT: %s\n' "${YBV_PHYSICAL_RESULT:-PENDING}"
		printf 'Failures: %d\nWarnings: %d\n' "$YBV_FAILURES" "$YBV_WARNINGS"
		printf 'Finished: %s\n' "$(date --iso-8601=seconds)"
	} | tee -a "$YBV_LOG"
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
	runuser -u "$user" -- env \
		XDG_RUNTIME_DIR="/run/user/$uid" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}
