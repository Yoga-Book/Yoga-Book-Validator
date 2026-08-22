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
	-h | --help) echo 'Usage: yogabook-validator passive [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done

ybv_begin_report passive "$output_dir"
suite_root=$YBV_REPORT_DIR

run_subtest() {
	local test_name=$1
	shift
	local report_dir="$suite_root/$test_name" rc=0 result=FAIL failures=0 warnings=0
	printf '\n===== Running %s =====\n' "$test_name" | tee -a "$YBV_LOG"
	"$@" --output "$report_dir" || rc=$?
	if [[ -s $report_dir/results.tsv && -s $report_dir/validator.log ]]; then
		tail -n +2 "$report_dir/results.tsv" >>"$YBV_REPORT"
		failures=$(awk -F '\t' 'NR > 1 && $4 == "FAIL" {count++} END {print count+0}' "$report_dir/results.tsv")
		warnings=$(awk -F '\t' 'NR > 1 && $4 == "WARN" {count++} END {print count+0}' "$report_dir/results.tsv")
		YBV_FAILURES=$((YBV_FAILURES + failures))
		YBV_WARNINGS=$((YBV_WARNINGS + warnings))
		result=$(sed -n 's/^AUTOMATED_RESULT: //p' "$report_dir/validator.log" | tail -n 1)
	fi
	if ((rc == 0)) && [[ $result == PASS ]]; then
		ybv_emit suite "$test_name" PASS "$test_name passive validation completed" "failures=$failures warnings=$warnings"
	else
		ybv_emit suite "$test_name" FAIL "$test_name passive validation failed" "exit=$rc result=${result:-missing} failures=$failures warnings=$warnings"
	fi
}

run_subtest check "$LIBEXEC_DIR/yogabook-validator-check.sh"
run_subtest platform "$LIBEXEC_DIR/yogabook-validator-platform.sh"
run_subtest display "$LIBEXEC_DIR/yogabook-validator-display.sh"
run_subtest sensors "$LIBEXEC_DIR/yogabook-validator-sensors.sh"
run_subtest power "$LIBEXEC_DIR/yogabook-validator-power.sh"
run_subtest usb "$LIBEXEC_DIR/yogabook-validator-usb.sh"
run_subtest gnss "$LIBEXEC_DIR/yogabook-validator-gnss.sh"

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
