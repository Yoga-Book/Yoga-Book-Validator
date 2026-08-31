#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ $EUID -eq 0 && ${YBV_ACTIVE_DISPATCH:-} == 1 ]] || {
	echo 'ERROR: quiet diagnostics must be launched through yogabook-validator' >&2
	exit 2
}
output_dir=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
ybv_require_x91l || { echo 'ERROR: quiet diagnostics are restricted to Lenovo YB1-X91L' >&2; exit 2; }

real_user=$(ybv_real_user)
if [[ $real_user == root || -z $real_user ]] || ! id "$real_user" >/dev/null 2>&1; then
	echo 'ERROR: quiet diagnostics require an invoking desktop user' >&2
	exit 2
fi

ybv_begin_report quiet "$output_dir"
suite_root=$YBV_REPORT_DIR

# Passed by name to run_subtest and invoked indirectly.
# shellcheck disable=SC2329
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
		ybv_emit suite "$test_name" SKIP "$test_name quiet validation was not applicable" "skipped=$skipped"
	elif ((rc == 0)) && [[ $result == PASS ]]; then
		ybv_emit suite "$test_name" PASS "$test_name quiet validation completed" "failures=$failures warnings=$warnings"
	else
		ybv_emit suite "$test_name" FAIL "$test_name quiet validation failed" "exit=$rc result=${result:-missing} failures=$failures warnings=$warnings"
	fi
}

run_subtest check run_as_desktop "$LIBEXEC_DIR/yogabook-validator-check.sh"
run_subtest apt run_as_desktop "$LIBEXEC_DIR/yogabook-validator-apt.sh"
run_subtest platform "$LIBEXEC_DIR/yogabook-validator-platform.sh"
run_subtest internal-storage "$LIBEXEC_DIR/yogabook-validator-active.sh" internal-storage --yes
run_subtest resources run_as_desktop "$LIBEXEC_DIR/yogabook-validator-resources.sh"
run_subtest display run_as_desktop "$LIBEXEC_DIR/yogabook-validator-display.sh"
run_subtest sensors run_as_desktop "$LIBEXEC_DIR/yogabook-validator-sensors.sh"
run_subtest power run_as_desktop "$LIBEXEC_DIR/yogabook-validator-power.sh"
run_subtest charging run_as_desktop "$LIBEXEC_DIR/yogabook-validator-charging.sh"
run_subtest usb run_as_desktop "$LIBEXEC_DIR/yogabook-validator-usb.sh"
run_subtest modem run_as_desktop "$LIBEXEC_DIR/yogabook-validator-modem.sh"
run_subtest gnss run_as_desktop "$LIBEXEC_DIR/yogabook-validator-gnss.sh"
run_subtest camera "$LIBEXEC_DIR/yogabook-validator-camera.sh" --yes
run_subtest inputs "$LIBEXEC_DIR/yogabook-validator-active.sh" inputs --yes
run_subtest pen-stack run_as_desktop "$LIBEXEC_DIR/yogabook-validator-pen-stack.sh"
run_subtest storage "$LIBEXEC_DIR/yogabook-validator-active.sh" storage --yes
run_subtest wireless "$LIBEXEC_DIR/yogabook-validator-active.sh" wireless --yes
run_subtest lights "$LIBEXEC_DIR/yogabook-validator-active.sh" lights --yes

ybv_emit validator quiet-policy PASS 'Quiet diagnostics excluded audible, haptic, suspend and guided workflows' 'scheduled=18'

critical_services=(yogabook-camera.service iio-sensor-proxy.service bluetooth.service ModemManager.service)
if ! grep -Fq 'N: Name="Wacom HID 169 Pen"' /proc/bus/input/devices 2>/dev/null; then
	critical_services+=(halo-keyboard.service)
fi
inactive_services=()
for service in "${critical_services[@]}"; do
	systemctl is-active --quiet "$service" || inactive_services+=("$service")
done
if ((${#inactive_services[@]} == 0)); then
	ybv_emit suite services-final-state PASS 'All critical Yoga Book integration services remain active after quiet diagnostics' "services=${#critical_services[@]}"
else
	ybv_emit suite services-final-state FAIL 'One or more critical Yoga Book integration services are inactive after quiet diagnostics' "services=${inactive_services[*]}"
fi

YBV_PHYSICAL_RESULT=PENDING
finish_rc=0
ybv_finish_report || finish_rc=$?
ybv_chown_tree_to_user "$real_user" "$suite_root" 2>/dev/null || true
exit "$finish_rc"
