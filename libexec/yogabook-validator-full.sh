#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

output_dir=
answers_file=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	--answers) [[ $# -ge 2 ]] || exit 2; answers_file=$2; shift 2 ;;
	-h | --help) echo 'Usage: yogabook-validator full [--answers FILE] [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
[[ -z $answers_file || -r $answers_file ]] || { echo "ERROR: answers file is unreadable: $answers_file" >&2; exit 2; }

passive_runner=${YBV_PASSIVE_RUNNER:-$LIBEXEC_DIR/yogabook-validator-passive.sh}
physical_runner=${YBV_PHYSICAL_RUNNER:-$LIBEXEC_DIR/yogabook-validator-physical.sh}

ybv_begin_report full "$output_dir"
suite_root=$YBV_REPORT_DIR

emit_rollup() {
	local failures=$YBV_FAILURES warnings=$YBV_WARNINGS
	ybv_emit "$@"
	YBV_FAILURES=$failures
	YBV_WARNINGS=$warnings
}

merge_subreport() {
	local name=$1 directory=$2 rc=$3 result=missing failures=0 warnings=0 report_complete=false
	if [[ -s $directory/results.tsv && -s $directory/validator.log ]]; then
		report_complete=true
		tail -n +2 "$directory/results.tsv" >>"$YBV_REPORT"
		failures=$(awk -F '\t' 'NR > 1 && $2 != "suite" && $4 == "FAIL" {count++} END {print count+0}' "$directory/results.tsv")
		warnings=$(awk -F '\t' 'NR > 1 && $2 != "suite" && $4 == "WARN" {count++} END {print count+0}' "$directory/results.tsv")
		YBV_FAILURES=$((YBV_FAILURES + failures))
		YBV_WARNINGS=$((YBV_WARNINGS + warnings))
		result=$(sed -n 's/^AUTOMATED_RESULT: //p' "$directory/validator.log" | tail -n 1)
	else
		ybv_emit validator "$name-report" FAIL "$name validation did not produce a complete subreport" \
			"exit=$rc directory=$directory"
	fi
	if ((rc == 0)) && [[ $result == PASS ]]; then
		emit_rollup suite "$name" PASS "$name validation completed" \
			"failures=$failures warnings=$warnings"
	else
		if [[ $report_complete == true ]] && ((failures == 0)); then
			ybv_emit validator "$name-execution" FAIL "$name validation did not complete successfully" \
				"exit=$rc result=$result"
		fi
		emit_rollup suite "$name" FAIL "$name validation failed" \
			"exit=$rc result=$result failures=$failures warnings=$warnings"
	fi
}

passive_dir=$suite_root/passive
physical_dir=$suite_root/physical

printf '\n===== Running passive =====\n' | tee -a "$YBV_LOG"
passive_rc=0
"$passive_runner" --output "$passive_dir" || passive_rc=$?
merge_subreport passive "$passive_dir" "$passive_rc"

printf '\n===== Recording physical acceptance =====\n' | tee -a "$YBV_LOG"
physical_args=(--output "$physical_dir")
if [[ -n $answers_file ]]; then
	physical_args+=(--answers "$answers_file")
fi
physical_rc=0
"$physical_runner" "${physical_args[@]}" || physical_rc=$?
merge_subreport physical "$physical_dir" "$physical_rc"

if [[ -s $physical_dir/physical-results.tsv ]]; then
	cp -- "$physical_dir/physical-results.tsv" "$suite_root/physical-results.tsv"
fi
YBV_PHYSICAL_RESULT=$(sed -n 's/^PHYSICAL_ACCEPTANCE_RESULT: //p' "$physical_dir/validator.log" 2>/dev/null | tail -n 1)
YBV_PHYSICAL_RESULT=${YBV_PHYSICAL_RESULT:-PENDING}

finish_rc=0
ybv_finish_report || finish_rc=$?
printf 'Full validation directory: %s\n' "$suite_root"
((finish_rc == 0 && passive_rc == 0 && physical_rc == 0))
