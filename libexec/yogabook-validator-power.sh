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
	-h | --help) echo 'Usage: yogabook-validator power [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
ybv_require_x91l || { echo 'ERROR: power tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report power "$output_dir"
battery=/sys/class/power_supply/bq27542-0
charger=/sys/class/power_supply/bq25890-charger-0
power_source=/sys/class/power_supply/cht_wcove_pwrsrc

read_value() {
	local path=$1 value
	[[ -r $path ]] || return 1
	read -r value <"$path" || return 1
	printf '%s\n' "$value"
}

read_integer() {
	local value
	value=$(read_value "$1") || return 1
	[[ $value =~ ^-?[0-9]+$ ]] || return 1
	printf '%s\n' "$value"
}

if [[ -d $battery ]] && [[ $(read_value "$battery/model_name" 2>/dev/null || true) == BQ27542 || $(read_value "$battery/manufacturer" 2>/dev/null || true) == 'Texas Instruments' ]]; then
	ybv_emit power battery-identity PASS 'BQ27542 battery fuel gauge is exposed' 'Texas Instruments'
else
	ybv_emit power battery-identity FAIL 'BQ27542 battery fuel gauge is missing or unidentified'
fi

present=$(read_integer "$battery/present" 2>/dev/null || true)
health=$(read_value "$battery/health" 2>/dev/null || true)
technology=$(read_value "$battery/technology" 2>/dev/null || true)
if [[ $present == 1 && $health == Good && $technology == Li-ion ]]; then
	ybv_emit power battery-health PASS 'Battery is present and reports healthy Li-ion state'
else
	ybv_emit power battery-health FAIL 'Battery presence, health or chemistry is unexpected' "present=${present:-unreadable} health=${health:-unreadable} technology=${technology:-unreadable}"
fi

capacity=$(read_integer "$battery/capacity" 2>/dev/null || true)
status=$(read_value "$battery/status" 2>/dev/null || true)
capacity_level=$(read_value "$battery/capacity_level" 2>/dev/null || true)
if [[ -n $capacity ]] && ((capacity >= 0 && capacity <= 100)) && [[ $status =~ ^(Unknown|Charging|Discharging|Not\ charging|Full)$ ]]; then
	ybv_emit power battery-capacity PASS 'Battery capacity and charge state are plausible' "capacity=$capacity% status=$status level=${capacity_level:-unknown}"
else
	ybv_emit power battery-capacity FAIL 'Battery capacity or charge state is invalid' "capacity=${capacity:-unreadable} status=${status:-unreadable}"
fi

voltage=$(read_integer "$battery/voltage_now" 2>/dev/null || true)
temperature=$(read_integer "$battery/temp" 2>/dev/null || true)
current=$(read_integer "$battery/current_now" 2>/dev/null || true)
cycles=$(read_integer "$battery/cycle_count" 2>/dev/null || true)
if [[ -n $voltage && -n $temperature && -n $current && -n $cycles ]] && \
	((voltage >= 2800000 && voltage <= 4500000 && temperature >= -100 && temperature <= 700 && current >= -10000000 && current <= 10000000 && cycles >= 0)); then
	ybv_emit power battery-telemetry PASS 'Battery voltage, temperature, current and cycle count are plausible' "voltage_uv=$voltage temp_deci_c=$temperature current_ua=$current cycles=$cycles"
else
	ybv_emit power battery-telemetry FAIL 'Battery telemetry is missing or outside plausible limits' "voltage_uv=${voltage:-unreadable} temp_deci_c=${temperature:-unreadable} current_ua=${current:-unreadable} cycles=${cycles:-unreadable}"
fi

charge_design=$(read_integer "$battery/charge_full_design" 2>/dev/null || true)
charge_full=$(read_integer "$battery/charge_full" 2>/dev/null || true)
charge_now=$(read_integer "$battery/charge_now" 2>/dev/null || true)
if [[ -n $charge_design && -n $charge_full && -n $charge_now ]] && \
	((charge_design > 0 && charge_full > 0 && charge_full <= charge_design * 12 / 10 && charge_now >= 0 && charge_now <= charge_design * 12 / 10)); then
	health_percent=$((charge_full * 100 / charge_design))
	ybv_emit power battery-charge-data PASS 'Fuel-gauge charge counters are internally plausible' "now_uah=$charge_now full_uah=$charge_full design_uah=$charge_design health=$health_percent%"
else
	ybv_emit power battery-charge-data FAIL 'Fuel-gauge charge counters are missing or inconsistent' "now_uah=${charge_now:-unreadable} full_uah=${charge_full:-unreadable} design_uah=${charge_design:-unreadable}"
fi

charger_model=$(read_value "$charger/model_name" 2>/dev/null || true)
charger_vendor=$(read_value "$charger/manufacturer" 2>/dev/null || true)
if [[ $charger_model == BQ25892 && $charger_vendor == 'Texas Instruments' ]]; then
	ybv_emit power charger-identity PASS 'BQ25892 charger is exposed' "$charger_vendor"
else
	ybv_emit power charger-identity FAIL 'BQ25892 charger is missing or unidentified' "model=${charger_model:-unreadable} vendor=${charger_vendor:-unreadable}"
fi

charger_online=$(read_integer "$charger/online" 2>/dev/null || true)
source_online=$(read_integer "$power_source/online" 2>/dev/null || true)
charger_health=$(read_value "$charger/health" 2>/dev/null || true)
charger_status=$(read_value "$charger/status" 2>/dev/null || true)
if [[ $charger_online =~ ^[01]$ && $source_online == "$charger_online" && $charger_health == Good ]]; then
	ybv_emit power charger-state PASS 'Charger and Whiskey Cove power-source state agree' "online=$charger_online status=${charger_status:-unknown} health=$charger_health"
else
	ybv_emit power charger-state FAIL 'Charger health or online state is inconsistent' "charger_online=${charger_online:-unreadable} source_online=${source_online:-unreadable} health=${charger_health:-unreadable}"
fi

charger_voltage=$(read_integer "$charger/voltage_now" 2>/dev/null || true)
charger_temperature=$(read_integer "$charger/temp" 2>/dev/null || true)
if [[ -n $charger_voltage && -n $charger_temperature ]] && \
	((charger_voltage >= 0 && charger_voltage <= 15000000 && charger_temperature >= -100 && charger_temperature <= 1000)); then
	ybv_emit power charger-telemetry PASS 'Charger voltage and temperature are plausible' "voltage_uv=$charger_voltage temp_deci_c=$charger_temperature"
else
	ybv_emit power charger-telemetry FAIL 'Charger telemetry is missing or outside plausible limits' "voltage_uv=${charger_voltage:-unreadable} temp_deci_c=${charger_temperature:-unreadable}"
fi

if ybv_has_command upower; then
	upower_device=$(upower -e 2>/dev/null | grep '/battery_' | head -n 1 || true)
	upower_info=$([[ -n $upower_device ]] && upower -i "$upower_device" 2>/dev/null || true)
	if grep -Eq '^[[:space:]]*present:[[:space:]]+yes$' <<<"$upower_info" && grep -Eq 'percentage:[[:space:]]+[0-9]+%' <<<"$upower_info"; then
		ybv_emit power upower PASS 'UPower exposes the Yoga Book battery to the desktop'
	else
		ybv_emit power upower FAIL 'UPower does not expose valid battery state'
	fi
	upower_metrics=$(grep -E '^[[:space:]]*(state|energy|energy-full|energy-full-design|energy-rate|voltage|charge-cycles|percentage|temperature|capacity):' <<<"$upower_info" || true)
	printf '\n===== UPower battery metrics =====\n%s\n' "$upower_metrics" >>"$YBV_LOG"
else
	ybv_emit power upower SKIP 'UPower command-line client is unavailable'
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
