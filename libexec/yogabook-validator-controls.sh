#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ ${YBV_ACTIVE_DISPATCH:-} == 1 && $EUID -eq 0 ]] || {
	echo 'ERROR: controls must be dispatched by yogabook-validator-active.sh' >&2
	exit 2
}

output_dir=
event_timeout=90
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	--timeout) [[ $# -ge 2 ]] || exit 2; event_timeout=$2; shift 2 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
[[ $event_timeout =~ ^[1-9][0-9]*$ ]] || {
	echo 'ERROR: control event timeout must be a positive integer' >&2
	exit 2
}

real_user=$(ybv_real_user)
if [[ -z $real_user || $real_user == root ]] || ! id "$real_user" >/dev/null 2>&1; then
	echo 'ERROR: controls must be launched by the active desktop user through sudo or Polkit' >&2
	exit 2
fi

ybv_begin_report controls "$output_dir"
event_file="$YBV_REPORT_DIR/control-events.tsv"
helper_rc=0
set +e
timeout "$((event_timeout + 5))" python3 \
	"$LIBEXEC_DIR/yogabook-validator-controls-events.py" \
	--timeout "$event_timeout" | tee -a "$YBV_LOG" "$event_file"
helper_rc=${PIPESTATUS[0]}
set -e

details=$(awk -F '\t' '$1 == "details" {print $2; exit}' "$event_file")
error=$(awk -F '\t' '$1 == "error" {print $2; exit}' "$event_file")
[[ -z $error ]] || details="${details:+$details }error=$error"

emit_control_result() {
	local check_id=$1 summary=$2 status
	status=$(awk -F '\t' -v wanted="$check_id" '$1 == wanted {print $2; exit}' "$event_file")
	if [[ $status == PASS ]]; then
		ybv_emit input "$check_id" PASS "$summary" "$details"
	else
		ybv_emit input "$check_id" FAIL "${summary/Observed/Did not observe}" \
			"exit=$helper_rc ${details:-no event result}"
	fi
}

emit_control_result power-button-event 'Observed one physical Power button press'
emit_control_result volume-up-event 'Observed one physical Volume Up button press'
emit_control_result volume-down-event 'Observed one physical Volume Down button press'
emit_control_result lid-close-event 'Observed the lid switch close transition'
emit_control_result lid-open-event 'Observed the lid switch reopen transition'

release_status=$(awk -F '\t' '$1 == "controls-release" {print $2; exit}' "$event_file")
if [[ $release_status == PASS ]]; then
	ybv_emit input controls-release PASS \
		'Released every temporary exclusive input grab' "$details"
else
	ybv_emit input controls-release FAIL \
		'Could not verify release of every temporary exclusive input grab' \
		"exit=$helper_rc ${details:-no cleanup result}"
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report_for_user "$real_user"
