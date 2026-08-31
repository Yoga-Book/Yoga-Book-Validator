#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

output_dir=
observation_seconds=${YBV_CHARGE_OBSERVATION_SECONDS:-30}
sample_interval=${YBV_CHARGE_SAMPLE_INTERVAL:-5}
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	--seconds) [[ $# -ge 2 ]] || exit 2; observation_seconds=$2; shift 2 ;;
	-h | --help) echo 'Usage: yogabook-validator charging [--seconds 15..300] [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
if [[ ! $observation_seconds =~ ^[0-9]+$ ]] || ((observation_seconds < 15 || observation_seconds > 300)); then
	echo 'ERROR: charging observation must last between 15 and 300 seconds' >&2
	exit 2
fi
[[ $sample_interval =~ ^[1-9][0-9]*$ ]] || {
	echo 'ERROR: charging sample interval must be a positive integer' >&2
	exit 2
}
ybv_require_x91l || { echo 'ERROR: charging tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report charging "$output_dir"
battery=$(ybv_path /sys/class/power_supply/bq27542-0)
charger=$(ybv_path /sys/class/power_supply/bq25890-charger-0)
power_source=$(ybv_path /sys/class/power_supply/cht_wcove_pwrsrc)
samples="$YBV_REPORT_DIR/charge-samples.tsv"

read_attribute() {
	local path=$1 value
	[[ -r $path ]] || { printf 'unavailable\n'; return; }
	read -r value <"$path" || value=unavailable
	printf '%s\n' "${value:-unavailable}"
}

capture_sample() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$(date +%s)" \
		"$(read_attribute "$charger/online")" \
		"$(read_attribute "$power_source/online")" \
		"$(read_attribute "$charger/health")" \
		"$(read_attribute "$battery/status")" \
		"$(read_attribute "$battery/capacity")" \
		"$(read_attribute "$battery/charge_now")" \
		"$(read_attribute "$battery/charge_full")" \
		"$(read_attribute "$battery/current_now")" \
		"$(read_attribute "$battery/temp")" \
		"$(read_attribute "$charger/temp")" \
		"$(read_attribute "$charger/voltage_now")" >>"$samples"
}

printf 'epoch\tcharger_online\tsource_online\tcharger_health\tbattery_status\tcapacity_percent\tcharge_now_uah\tcharge_full_uah\tcurrent_ua\tbattery_temp_deci_c\tcharger_temp_deci_c\tcharger_voltage_uv\n' >"$samples"
if [[ -n ${YBV_CHARGE_SAMPLE_SOURCE:-} && $YBV_SYSROOT != / ]]; then
	[[ -r $YBV_CHARGE_SAMPLE_SOURCE ]] || { echo 'ERROR: charging sample fixture is unreadable' >&2; exit 2; }
	cp -- "$YBV_CHARGE_SAMPLE_SOURCE" "$samples"
else
	sample_count=$((observation_seconds / sample_interval + 1))
	for ((sample = 1; sample <= sample_count; sample++)); do
		capture_sample
		((sample == sample_count)) || sleep "$sample_interval"
	done
fi

analysis=$(awk -F '\t' '
	NR == 1 { next }
	{
		count++
		if ($2 !~ /^[01]$/ || $3 !~ /^[01]$/ || $4 == "" ||
			$6 !~ /^[0-9]+$/ || $7 !~ /^[0-9]+$/ || $8 !~ /^[1-9][0-9]*$/ ||
			$9 !~ /^-?[0-9]+$/ || $10 !~ /^-?[0-9]+$/ ||
			$11 !~ /^-?[0-9]+$/ || $12 !~ /^[0-9]+$/) invalid=1
		if ($2 == 1) online++
		if ($2 == 0) offline++
		if ($2 != $3 || $4 != "Good") inconsistent=1
		if ($10 < -100 || $10 > 450 || $11 < -100 || $11 > 700) unsafe=1
		if ($12 < 0 || $12 > 15000000) invalid=1
		if ($5 == "Charging") charging++
		else if ($5 == "Full" || $5 == "Not charging") terminal++
		else if ($5 == "Discharging") discharging++
		else bad_status=1
		if (count == 1) {
			first_charge=$7; first_capacity=$6; first_status=$5
		}
		last_charge=$7; last_capacity=$6; last_status=$5
	}
	END {
		printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n",
			count+0, invalid+0, online+0, offline+0, inconsistent+0, unsafe+0,
			charging+0, terminal+0, discharging+0, bad_status+0,
			first_charge+0, last_charge+0, first_capacity+0, last_capacity+0,
			first_status, last_status
	}
' "$samples")
IFS=$'\t' read -r count invalid online offline inconsistent unsafe charging terminal discharging bad_status first_charge last_charge first_capacity last_capacity first_status last_status <<<"$analysis"

continuity_status=PASS
progress_status=PASS
temperature_status=PASS
stability_status=PASS

if ((count < 2 || invalid != 0)); then
	continuity_status=FAIL
	progress_status=FAIL
	temperature_status=FAIL
	stability_status=FAIL
	ybv_emit power charger-continuity FAIL 'Charging-session telemetry is incomplete or malformed' "samples=$count invalid=$invalid"
	ybv_emit power charge-progress FAIL 'Battery charge progression could not be evaluated' 'blocked_by=power/charger-continuity'
	ybv_emit power charge-temperature FAIL 'Charging temperature safety could not be evaluated' 'blocked_by=power/charger-continuity'
	ybv_emit power charge-stability FAIL 'Charging stability could not be evaluated' 'blocked_by=power/charger-continuity'
elif ((online == 0)); then
	continuity_status=SKIP
	progress_status=SKIP
	if ((unsafe != 0)); then temperature_status=FAIL; fi
	stability_status=SKIP
	ybv_emit power charger-continuity SKIP 'No external power was connected during the observation window' "samples=$count seconds=$observation_seconds"
	ybv_emit power charge-progress SKIP 'Connect the charger to observe sustained charge progression' 'blocked_by=power/charger-continuity'
	if ((unsafe == 0)); then
		ybv_emit power charge-temperature PASS 'Battery and charger temperatures remained within conservative limits while offline' "samples=$count"
	else
		ybv_emit power charge-temperature FAIL 'Battery or charger temperature exceeded the conservative safety limit while offline' "samples=$count"
	fi
	ybv_emit power charge-stability SKIP 'Charging stability requires connected external power' 'blocked_by=power/charger-continuity'
else
	if ((offline != 0 || inconsistent != 0)); then
		continuity_status=FAIL
		ybv_emit power charger-continuity FAIL 'External-power continuity or charger/source agreement was lost during observation' "samples=$count online=$online offline=$offline inconsistent=$inconsistent"
	else
		ybv_emit power charger-continuity PASS 'External power remained online and both charger interfaces agreed' "samples=$count seconds=$observation_seconds"
	fi
	if ((unsafe != 0)); then
		temperature_status=FAIL
		ybv_emit power charge-temperature FAIL 'Battery or charger temperature exceeded the conservative charging limit' "samples=$count"
	else
		ybv_emit power charge-temperature PASS 'Battery and charger temperatures stayed within conservative charging limits' "samples=$count"
	fi
	if ((discharging != 0 || bad_status != 0)); then
		progress_status=FAIL
		ybv_emit power charge-progress FAIL 'Battery reported a non-charging state while external power was online' "first=$first_status last=$last_status discharging=$discharging invalid-status=$bad_status"
	elif ((terminal == count && first_capacity >= 99 && last_capacity >= 99)); then
		ybv_emit power charge-progress PASS 'Battery remained at its terminal full-charge state' "samples=$count capacity=$first_capacity%->$last_capacity% charge_uah=$first_charge->$last_charge"
	elif ((charging > 0 && last_charge > first_charge)); then
		ybv_emit power charge-progress PASS 'Fuel-gauge charge increased during the bounded charging session' "samples=$count charge_uah=$first_charge->$last_charge"
	else
		progress_status=FAIL
		ybv_emit power charge-progress FAIL 'No measurable fuel-gauge charge increase occurred during the charging session' "samples=$count status=$first_status->$last_status charge_uah=$first_charge->$last_charge"
	fi
	if [[ $continuity_status == PASS && $progress_status == PASS && $temperature_status == PASS ]]; then
		ybv_emit power charge-stability PASS 'Charging remained electrically and thermally stable for the complete observation' "samples=$count"
	else
		stability_status=FAIL
		ybv_emit power charge-stability FAIL 'Charging did not remain continuously healthy for the complete observation' "continuity=$continuity_status progress=$progress_status temperature=$temperature_status"
	fi
fi

if [[ $continuity_status == PASS && $progress_status == PASS && $temperature_status == PASS && $stability_status == PASS ]]; then
	ybv_emit power charge-session PASS 'Bounded charging-session acceptance completed successfully' "samples=$count seconds=$observation_seconds"
elif [[ $continuity_status == SKIP ]]; then
	ybv_emit power charge-session SKIP 'Charging-session acceptance is incomplete without connected external power' 'blocked_by=power/charger-continuity'
else
	ybv_emit power charge-session FAIL 'Bounded charging-session acceptance found an unsafe or non-progressing state' "continuity=$continuity_status progress=$progress_status temperature=$temperature_status stability=$stability_status"
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
