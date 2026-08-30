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
	-h | --help) echo 'Usage: yogabook-validator modem [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
ybv_require_x91l || { echo 'ERROR: modem validation is restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report modem "$output_dir"
modem_evidence_rc=0
modem_evidence=$(python3 "$LIBEXEC_DIR/yogabook-validator-modem.py" 2>>"$YBV_LOG") || modem_evidence_rc=$?
if [[ -z $modem_evidence || $modem_evidence_rc -gt 1 ]]; then
	ybv_emit modem registration FAIL 'LTE functional evaluator did not produce evidence' "exit=$modem_evidence_rc"
	ybv_emit modem ip-traffic FAIL 'LTE packet evaluator did not produce evidence' "exit=$modem_evidence_rc"
else
	while IFS=$'\t' read -r subsystem check_id status summary details; do
		[[ -n $check_id ]] || continue
		ybv_emit "$subsystem" "$check_id" "$status" "$summary" "$details"
	done <<<"$modem_evidence"
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
