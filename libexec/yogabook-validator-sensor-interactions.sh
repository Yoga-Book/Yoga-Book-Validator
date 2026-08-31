#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ $EUID -eq 0 && ${YBV_ACTIVE_DISPATCH:-} == 1 ]] || {
	echo 'ERROR: sensor interactions must be launched through yogabook-validator' >&2
	exit 2
}

output_dir=
timeout=120
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	--timeout) [[ $# -ge 2 ]] || exit 2; timeout=$2; shift 2 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
[[ $timeout =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: timeout must be a positive integer' >&2; exit 2; }
ybv_require_x91l || { echo 'ERROR: sensor interactions are restricted to Lenovo YB1-X91L' >&2; exit 2; }
real_user=$(ybv_real_user)
if [[ -z $real_user || $real_user == root ]] || ! id "$real_user" >/dev/null 2>&1; then
	echo 'ERROR: sensor interactions require an invoking desktop user' >&2
	exit 2
fi

ybv_begin_report sensor-interactions "$output_dir"
ybv_register_state_keys 'system-service:halo-keyboard.service' 'desktop:mutter'
cancelled=false
trap 'cancelled=true' INT TERM
result_file="$YBV_REPORT_DIR/sensor-interactions.json"
parsed_file="$YBV_REPORT_DIR/.sensor-interactions.tsv"
touch "$result_file"
chown -- "$real_user:$(id -gn "$real_user")" "$result_file"
wayland_socket=$(find "/run/user/$(id -u "$real_user")" -maxdepth 1 -type s \
	-name 'wayland-*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort | head -n 1)
helper_rc=0
if [[ -n $wayland_socket ]]; then
	printf '%s\n' \
		'ACTION_REQUIRED: Shade/expose both light sensors, move a hand near/away, then open or fold the hinge as requested.' \
		| tee -a "$YBV_LOG"
	ybv_run_as_user "$real_user" env WAYLAND_DISPLAY="$wayland_socket" GDK_BACKEND=wayland \
		"$LIBEXEC_DIR/yogabook-validator-sensor-interactions.py" \
		--output "$result_file" --timeout "$timeout" >>"$YBV_LOG" 2>&1 || helper_rc=$?
else
	helper_rc=1
	printf 'No Wayland compositor socket is available for the desktop user\n' >>"$YBV_LOG"
fi
if [[ -s $result_file ]] && python3 - "$result_file" >"$parsed_file" <<'PY'
import json
import sys

expected = ["ambient-light-response", "proximity-response", "hinge-response"]
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
if payload.get("schema") != "org.yogabook.validator.sensor-interactions/v1":
    raise SystemExit("invalid result schema")
stages = payload.get("stages")
if not isinstance(stages, list) or [item.get("check_id") for item in stages] != expected:
    raise SystemExit("invalid result stage sequence")
for item in stages:
    status = item.get("status")
    details = item.get("details")
    if status not in {"PASS", "FAIL"} or not isinstance(details, dict):
        raise SystemExit("invalid result stage")
    print(item["check_id"], status, json.dumps(details, sort_keys=True), sep="\t")
PY
then
	while IFS=$'\t' read -r check_id status details; do
		case $check_id in
		ambient-light-response) summary='Both ambient-light devices produced a measurable response' ;;
		proximity-response) summary='The SX9310 produced a measurable near/far response' ;;
		hinge-response) summary='Both hinge-angle devices produced a measurable response' ;;
		*) continue ;;
		esac
		ybv_emit sensors "$check_id" "$status" "$summary" "$details"
	done <"$parsed_file"
else
	for check_id in ambient-light-response proximity-response hinge-response; do
		ybv_emit sensors "$check_id" FAIL 'Guided sensor response was not completed' "helper-exit=$helper_rc"
	done
fi

finish_rc=0
YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report_for_user "$real_user" || finish_rc=$?
if $cancelled && ((helper_rc == 0)); then
	helper_rc=130
fi
trap - INT TERM
((helper_rc == 0 && finish_rc == 0))
