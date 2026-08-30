#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ $EUID -eq 0 && ${YBV_ACTIVE_DISPATCH:-} == 1 ]] || {
	echo 'ERROR: category suites must be launched through yogabook-validator' >&2
	exit 2
}

category=${1:-}
[[ -n $category ]] || { echo 'ERROR: missing category name' >&2; exit 2; }
shift

output_dir=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done

case $category in
recommended | audio-media | input-modes | platform-power | connectivity-storage | reliability) ;;
*) echo "ERROR: unsupported category: $category" >&2; exit 2 ;;
esac

ybv_require_x91l || { echo 'ERROR: category suites are restricted to Lenovo YB1-X91L' >&2; exit 2; }
real_user=$(ybv_real_user)
if [[ $real_user == root || -z $real_user ]] || ! id "$real_user" >/dev/null 2>&1; then
	echo 'ERROR: category suites require an invoking desktop user' >&2
	exit 2
fi

ybv_begin_report "category-$category" "$output_dir"
suite_root=$YBV_REPORT_DIR

run_as_desktop() {
	ybv_run_as_user "$real_user" "$@"
}

run_subtest() {
	local test_name=$1
	shift
	local report_dir="$suite_root/$test_name" rc=0 result=FAIL failures=0 warnings=0 applicable=0 skipped=0
	printf '\n===== Running %s =====\n' "$test_name" | tee -a "$YBV_LOG"
	"$@" --output "$report_dir" || rc=$?
	if [[ -s $report_dir/results.tsv && -s $report_dir/validator.log ]]; then
		tail -n +2 "$report_dir/results.tsv" >>"$YBV_REPORT"
		failures=$(awk -F '\t' 'NR > 1 && $4 == "FAIL" {count++} END {print count+0}' "$report_dir/results.tsv")
		warnings=$(awk -F '\t' 'NR > 1 && $4 == "WARN" {count++} END {print count+0}' "$report_dir/results.tsv")
		skipped=$(awk -F '\t' 'NR > 1 && $4 == "SKIP" {count++} END {print count+0}' "$report_dir/results.tsv")
		applicable=$(awk -F '\t' 'NR > 1 && $2 != "validator" && $4 != "SKIP" && $4 != "INFO" {count++} END {print count+0}' "$report_dir/results.tsv")
		YBV_FAILURES=$((YBV_FAILURES + failures))
		YBV_WARNINGS=$((YBV_WARNINGS + warnings))
		result=$(sed -n 's/^AUTOMATED_RESULT: //p' "$report_dir/validator.log" | tail -n 1)
	fi
	if ((rc == 0)) && [[ $result == PASS ]] && ((applicable == 0)); then
		ybv_emit suite "$test_name" SKIP "$test_name category validation was not applicable" "skipped=$skipped"
	elif ((rc == 0)) && [[ $result == PASS ]]; then
		ybv_emit suite "$test_name" PASS "$test_name category validation completed" "failures=$failures warnings=$warnings"
	else
		ybv_emit suite "$test_name" FAIL "$test_name category validation failed" "exit=$rc result=${result:-missing} failures=$failures warnings=$warnings"
	fi
}

case $category in
recommended)
	# The automated suite already contains the quick audit and every passive
	# subsystem except resources. Run the union, not three overlapping workflows.
	run_subtest automated "$LIBEXEC_DIR/yogabook-validator-active.sh" automated --yes
	run_subtest resources run_as_desktop "$LIBEXEC_DIR/yogabook-validator-resources.sh"
	;;
audio-media)
	run_subtest display run_as_desktop "$LIBEXEC_DIR/yogabook-validator-display.sh"
	run_subtest camera "$LIBEXEC_DIR/yogabook-validator-camera.sh" --yes
	run_subtest lights "$LIBEXEC_DIR/yogabook-validator-active.sh" lights --yes
	run_subtest audio "$LIBEXEC_DIR/yogabook-validator-active.sh" audio --yes
	run_subtest headset "$LIBEXEC_DIR/yogabook-validator-active.sh" headset --yes --timeout 90
	;;
input-modes)
	run_subtest inputs "$LIBEXEC_DIR/yogabook-validator-active.sh" inputs --yes
	run_subtest haptics "$LIBEXEC_DIR/yogabook-validator-active.sh" haptics --yes
	run_subtest modes "$LIBEXEC_DIR/yogabook-validator-active.sh" modes --yes
	run_subtest rotation "$LIBEXEC_DIR/yogabook-validator-active.sh" rotation --yes
	;;
platform-power)
	run_subtest platform run_as_desktop "$LIBEXEC_DIR/yogabook-validator-platform.sh"
	run_subtest resources run_as_desktop "$LIBEXEC_DIR/yogabook-validator-resources.sh"
	run_subtest power run_as_desktop "$LIBEXEC_DIR/yogabook-validator-power.sh"
	run_subtest sensors run_as_desktop "$LIBEXEC_DIR/yogabook-validator-sensors.sh"
	;;
connectivity-storage)
	run_subtest usb run_as_desktop "$LIBEXEC_DIR/yogabook-validator-usb.sh"
	run_subtest modem run_as_desktop "$LIBEXEC_DIR/yogabook-validator-modem.sh"
	run_subtest wireless "$LIBEXEC_DIR/yogabook-validator-active.sh" wireless --yes
	run_subtest storage "$LIBEXEC_DIR/yogabook-validator-active.sh" storage --yes
	run_subtest storage-write "$LIBEXEC_DIR/yogabook-validator-active.sh" storage-write --yes
	;;
reliability)
	run_subtest suspend "$LIBEXEC_DIR/yogabook-validator-active.sh" suspend --yes --seconds 8
	stability_status=$(run_as_desktop "$LIBEXEC_DIR/yogabook-validator-stability.sh" status 2>&1 || true)
	if grep -Fq 'COLD_BOOT_STABILITY: NOT_STARTED' <<<"$stability_status"; then
		run_subtest stability-start run_as_desktop "$LIBEXEC_DIR/yogabook-validator-stability.sh" start 3
	elif [[ $stability_status =~ COLD_BOOT_STABILITY:[[:space:]]+([0-9]+)/([0-9]+) ]]; then
		passed=${BASH_REMATCH[1]}
		target=${BASH_REMATCH[2]}
		if ((passed >= target)); then
			ybv_emit suite stability PASS 'Cold-boot stability tracking is already complete' "progress=$passed/$target"
		else
			last_boot=$(sed -n 's/^Last counted boot: //p' <<<"$stability_status" | tail -n 1)
			current_boot=$(ybv_read_first /proc/sys/kernel/random/boot_id)
			if [[ -n $last_boot && $current_boot == "$last_boot" ]]; then
				ybv_emit suite stability SKIP 'A physical cold boot is required before the next stability check' "progress=$passed/$target"
			else
				run_subtest stability-check run_as_desktop "$LIBEXEC_DIR/yogabook-validator-stability.sh" check
			fi
		fi
	else
		ybv_emit suite stability FAIL 'Cold-boot stability state could not be read' "${stability_status:-no output}"
	fi
	;;
esac

YBV_PHYSICAL_RESULT=PENDING
finish_rc=0
ybv_finish_report || finish_rc=$?
ybv_chown_tree_to_user "$real_user" "$suite_root" 2>/dev/null || true
exit "$finish_rc"
