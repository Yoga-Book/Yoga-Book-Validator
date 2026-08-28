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
	-h | --help) echo 'Usage: yogabook-validator resources [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done

ybv_require_x91l || { echo 'ERROR: resource tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }
sample_seconds=${YBV_RESOURCE_SAMPLE_SECONDS:-3}
if [[ ! $sample_seconds =~ ^[1-9][0-9]*$ ]] || ((sample_seconds > 30)); then
	echo 'ERROR: YBV_RESOURCE_SAMPLE_SECONDS must be between 1 and 30' >&2
	exit 2
fi

ybv_begin_report resources "$output_dir"

read_value() {
	local value
	[[ -r $1 ]] || return 1
	read -r value <"$1" || return 1
	printf '%s\n' "$value"
}

read_integer() {
	local value
	value=$(read_value "$1") || return 1
	[[ $value =~ ^-?[0-9]+$ ]] || return 1
	printf '%s\n' "$value"
}

find_thermal_zone_temperature() {
	local wanted=$1 zone type
	for zone in "$(ybv_path /sys/class/thermal)"/thermal_zone*; do
		[[ -d $zone ]] || continue
		type=$(read_value "$zone/type" 2>/dev/null || true)
		if [[ $type == "$wanted" ]]; then
			read_integer "$zone/temp"
			return
		fi
	done
	return 1
}

find_hwmon_temperature() {
	local wanted=$1 hwmon name
	for hwmon in "$(ybv_path /sys/class/hwmon)"/hwmon*; do
		[[ -d $hwmon ]] || continue
		name=$(read_value "$hwmon/name" 2>/dev/null || true)
		if [[ $name == "$wanted" ]]; then
			read_integer "$hwmon/temp1_input"
			return
		fi
	done
	return 1
}

thermald_exec=
if [[ $YBV_SYSROOT != / ]]; then
	ybv_emit thermal thermald-service SKIP 'Live thermald service inspection is unavailable'
elif ! ybv_has_command systemctl; then
	ybv_emit thermal thermald-service SKIP 'systemctl is unavailable'
elif systemctl is-active --quiet thermald.service; then
	thermald_exec=$(systemctl show thermald.service --property=ExecStart --value 2>/dev/null || true)
	ybv_emit thermal thermald-service PASS 'thermald is active'
else
	ybv_emit thermal thermald-service FAIL 'thermald is not active'
fi

thermal_config=${YBV_THERMAL_CONFIG:-}
if [[ -z $thermal_config && -n $thermald_exec ]]; then
	thermal_config=$(sed -nE 's/.*--config-file(=|[[:space:]])([^ ;}]+).*/\2/p' <<<"$thermald_exec" | tail -n 1)
fi
if [[ -z $thermal_config ]]; then
	for candidate in /run/thermald/thermal-conf.xml.auto /var/run/thermald/thermal-conf.xml.auto /etc/thermald/thermal-conf.xml; do
		candidate=$(ybv_path "$candidate")
		if [[ -r $candidate ]]; then
			thermal_config=$candidate
			break
		fi
	done
elif [[ $YBV_SYSROOT != / && $thermal_config == /* ]]; then
	thermal_config=$(ybv_path "$thermal_config")
fi

invalid_policy_sensors=()
for invalid_sensor in STR0 STR2; do
	invalid_temperature=$(find_thermal_zone_temperature "$invalid_sensor" 2>/dev/null || true)
	if [[ -r $thermal_config ]] && grep -Fq "<SensorType>$invalid_sensor</SensorType>" "$thermal_config" && \
		{ [[ -z $invalid_temperature ]] || ((invalid_temperature < -100000)); }; then
		invalid_policy_sensors+=("$invalid_sensor=${invalid_temperature:-missing}")
	fi
done
policy_paths=()
if [[ -r $thermal_config ]]; then
	mapfile -t policy_paths < <(sed -n 's:.*<Path>\([^<]*\)</Path>.*:\1:p' "$thermal_config")
fi
invalid_policy_paths=()
for sensor_path in "${policy_paths[@]}"; do
	resolved_path=$sensor_path
	[[ $YBV_SYSROOT == / ]] || resolved_path=$(ybv_path "$sensor_path")
	sensor_value=$(read_integer "$resolved_path" 2>/dev/null || true)
	if [[ -z $sensor_value ]] || ((sensor_value < -20000 || sensor_value > 120000)); then
		invalid_policy_paths+=("$sensor_path=${sensor_value:-unreadable}")
	fi
done
if [[ -z $thermal_config || ! -r $thermal_config ]]; then
	ybv_emit thermal thermald-policy FAIL 'The effective thermald policy is unreadable' "${thermal_config:-not discovered}"
elif ((${#invalid_policy_sensors[@]} > 0)); then
	ybv_emit thermal thermald-policy FAIL 'thermald references invalid firmware temperature sensors' "${invalid_policy_sensors[*]} config=$thermal_config"
elif ((${#invalid_policy_paths[@]} > 0)); then
	ybv_emit thermal thermald-policy FAIL 'thermald references missing or implausible explicit sensors' "${invalid_policy_paths[*]} config=$thermal_config"
elif ((${#policy_paths[@]} >= 4)); then
	ybv_emit thermal thermald-policy PASS 'thermald uses plausible explicit sensor paths' "sensors=${#policy_paths[@]} config=$thermal_config"
else
	ybv_emit thermal thermald-policy WARN 'thermald policy does not prove explicit usable sensor bindings' "$thermal_config"
fi

coretemp_root=
for hwmon in "$(ybv_path /sys/class/hwmon)"/hwmon*; do
	[[ -d $hwmon ]] || continue
	[[ $(read_value "$hwmon/name" 2>/dev/null || true) == coretemp ]] && coretemp_root=$hwmon
done
declare -A core_critical=()
if [[ -n $coretemp_root ]]; then
	for label_path in "$coretemp_root"/temp*_label; do
		[[ -r $label_path ]] || continue
		label=$(read_value "$label_path" 2>/dev/null || true)
		[[ $label =~ ^Core[[:space:]]([0-3])$ ]] || continue
		critical=$(read_integer "${label_path%_label}_crit" 2>/dev/null || true)
		core_critical[${BASH_REMATCH[1]}]=$critical
	done
fi
invalid_critical=()
for core in 0 1 2 3; do
	[[ ${core_critical[$core]:-} == 90000 ]] || invalid_critical+=("core$core=${core_critical[$core]:-missing}")
done
if ((${#invalid_critical[@]} == 0)); then
	ybv_emit thermal coretemp-critical PASS 'All four CPU cores expose the 90 C hardware critical limit' 'cores=4 critical=90000'
else
	ybv_emit thermal coretemp-critical FAIL 'Four-core coretemp coverage or critical limits are incomplete' "${invalid_critical[*]}"
fi

processor_cooling=0
powerclamp_cooling=0
charge_cooling=0
invalid_cooling=0
for cooling in "$(ybv_path /sys/class/thermal)"/cooling_device*; do
	[[ -d $cooling ]] || continue
	type=$(read_value "$cooling/type" 2>/dev/null || true)
	current=$(read_integer "$cooling/cur_state" 2>/dev/null || true)
	maximum=$(read_integer "$cooling/max_state" 2>/dev/null || true)
	if [[ -z $current || -z $maximum ]] || ((current < 0 || maximum < current)); then
		invalid_cooling=$((invalid_cooling + 1))
	fi
	case $type in
	Processor) processor_cooling=$((processor_cooling + 1)) ;;
	intel_powerclamp) powerclamp_cooling=$((powerclamp_cooling + 1)) ;;
	TCHG) charge_cooling=$((charge_cooling + 1)) ;;
	esac
done
if ((processor_cooling == 4 && powerclamp_cooling == 1 && charge_cooling == 1 && invalid_cooling == 0)); then
	ybv_emit thermal cooling-capacity PASS 'CPU clamp, processor and charger cooling devices are available' 'Processor=4 intel_powerclamp=1 TCHG=1'
else
	ybv_emit thermal cooling-capacity FAIL 'Required thermal cooling capacity is incomplete' "Processor=$processor_cooling intel_powerclamp=$powerclamp_cooling TCHG=$charge_cooling invalid=$invalid_cooling"
fi

pnit=$(find_thermal_zone_temperature PNIT 2>/dev/null || true)
battery=$(find_hwmon_temperature bq27542_0 2>/dev/null || true)
charger=$(find_hwmon_temperature bq25890_charger_0 2>/dev/null || true)
if [[ -n $pnit && -n $battery && -n $charger ]] && \
	((pnit >= -20000 && pnit <= 110000 && battery >= -20000 && battery <= 80000 && charger >= -20000 && charger <= 100000)); then
	ybv_emit thermal live-temperatures PASS 'Platform, battery and charger temperatures are plausible' "PNIT=$pnit battery=$battery charger=$charger"
else
	ybv_emit thermal live-temperatures FAIL 'A safety-relevant temperature is missing or implausible' "PNIT=${pnit:-missing} battery=${battery:-missing} charger=${charger:-missing}"
fi
if [[ -n $battery ]] && ((battery >= 45000)); then
	ybv_emit thermal battery-temperature WARN 'Battery temperature is at or above the conservative charging threshold' "battery=$battery threshold=45000"
elif [[ -n $battery ]]; then
	ybv_emit thermal battery-temperature PASS 'Battery is below the conservative charging threshold' "battery=$battery threshold=45000"
fi
if [[ -n $charger ]] && ((charger >= 70000)); then
	ybv_emit thermal charger-temperature WARN 'Charger temperature is at or above the conservative charging threshold' "charger=$charger threshold=70000"
elif [[ -n $charger ]]; then
	ybv_emit thermal charger-temperature PASS 'Charger is below the conservative charging threshold' "charger=$charger threshold=70000"
fi

declare -a service_units=(halo-keyboard.service yogabook-camera.service yogabook-gnss.service)
declare -A service_labels=(
	[halo-keyboard.service]='Halo keyboard'
	[yogabook-camera.service]='Camera processor'
	[yogabook-gnss.service]='GNSS transport'
)
declare -A expected_limits=(
	[halo-keyboard.service]='CPUQuota=100% MemoryMax=32M TasksMax=16'
	[yogabook-camera.service]='CPUQuota=175% MemoryHigh=256M MemoryMax=384M TasksMax=64'
	[yogabook-gnss.service]='CPUQuota=50% MemoryHigh=64M MemoryMax=128M TasksMax=32'
)
declare -A memory_maximum=(
	[halo-keyboard.service]=$((32 * 1024 * 1024))
	[yogabook-camera.service]=$((384 * 1024 * 1024))
	[yogabook-gnss.service]=$((128 * 1024 * 1024))
)
declare -A task_maximum=(
	[halo-keyboard.service]=16
	[yogabook-camera.service]=64
	[yogabook-gnss.service]=32
)
declare -A idle_cpu_tenths=(
	[halo-keyboard.service]=50
	[yogabook-camera.service]=100
	[yogabook-gnss.service]=150
)
declare -A quota_cpu_tenths=(
	[halo-keyboard.service]=1000
	[yogabook-camera.service]=1750
	[yogabook-gnss.service]=500
)
declare -A cpu_before=() cpu_before_time=() active_service=() status_text=()

effective_setting() {
	local unit=$1 key=$2
	systemctl cat "$unit" 2>/dev/null | sed -n "s/^[[:space:]]*$key=//p" | tail -n 1
}

if [[ $YBV_SYSROOT != / ]]; then
	ybv_emit resources service-limits SKIP 'Live systemd cgroup inspection is unavailable'
	ybv_emit resources service-usage SKIP 'Live service resource sampling is unavailable'
elif ! ybv_has_command systemctl; then
	ybv_emit resources service-limits SKIP 'systemctl is unavailable'
	ybv_emit resources service-usage SKIP 'systemctl is unavailable'
else
	for unit in "${service_units[@]}"; do
		label=${service_labels[$unit]}
		if ! systemctl is-active --quiet "$unit"; then
			ybv_emit resources "${unit%.service}-limits" SKIP "$label is not active"
			continue
		fi
		active_service[$unit]=true
		actual_limits=()
		limit_mismatches=()
		for pair in ${expected_limits[$unit]}; do
			key=${pair%%=*}
			expected=${pair#*=}
			actual=$(effective_setting "$unit" "$key")
			actual_limits+=("$key=${actual:-missing}")
			[[ $actual == "$expected" ]] || limit_mismatches+=("$key=$expected")
		done
		if ((${#limit_mismatches[@]} == 0)); then
			ybv_emit resources "${unit%.service}-limits" PASS "$label has the packaged cgroup limits" "${actual_limits[*]}"
		else
			ybv_emit resources "${unit%.service}-limits" FAIL "$label cgroup limits differ from the packaged safety envelope" "${actual_limits[*]} expected=${limit_mismatches[*]}"
		fi
		cpu_before_time[$unit]=$(date +%s%N)
		cpu_before[$unit]=$(systemctl show "$unit" --property=CPUUsageNSec --value 2>/dev/null || true)
		status_text[$unit]=$(systemctl show "$unit" --property=StatusText --value 2>/dev/null || true)
	done

	if ((${#active_service[@]} > 0)); then
		sleep "$sample_seconds"
	fi
	for unit in "${service_units[@]}"; do
		[[ ${active_service[$unit]:-false} == true ]] || continue
		label=${service_labels[$unit]}
		cpu_after=$(systemctl show "$unit" --property=CPUUsageNSec --value 2>/dev/null || true)
		cpu_after_time=$(date +%s%N)
		memory=$(systemctl show "$unit" --property=MemoryCurrent --value 2>/dev/null || true)
		tasks=$(systemctl show "$unit" --property=TasksCurrent --value 2>/dev/null || true)
		restarts=$(systemctl show "$unit" --property=NRestarts --value 2>/dev/null || true)
		if [[ $memory =~ ^[0-9]+$ && $tasks =~ ^[0-9]+$ ]] && \
			((memory < memory_maximum[$unit] && tasks <= task_maximum[$unit])); then
			ybv_emit resources "${unit%.service}-headroom" PASS "$label is within its memory and task caps" "memory=$memory/${memory_maximum[$unit]} tasks=$tasks/${task_maximum[$unit]} restarts=${restarts:-unknown}"
		else
			ybv_emit resources "${unit%.service}-headroom" FAIL "$label resource accounting is unavailable or a memory/task cap was reached" "memory=${memory:-unknown}/${memory_maximum[$unit]} tasks=${tasks:-unknown}/${task_maximum[$unit]} restarts=${restarts:-unknown}"
		fi
		if [[ $restarts =~ ^[0-9]+$ ]] && ((restarts > 3)); then
			ybv_emit resources "${unit%.service}-restarts" WARN "$label has restarted repeatedly during this boot" "restarts=$restarts"
		fi
		if [[ ${cpu_before[$unit]:-} =~ ^[0-9]+$ && $cpu_after =~ ^[0-9]+$ ]] && ((cpu_after >= cpu_before[$unit])); then
			elapsed_ns=$((cpu_after_time - cpu_before_time[$unit]))
			((elapsed_ns > 0)) || elapsed_ns=$((sample_seconds * 1000000000))
			cpu_tenths=$(((cpu_after - cpu_before[$unit]) * 1000 / elapsed_ns))
			threshold=${idle_cpu_tenths[$unit]}
			workload=idle
			if [[ $unit == yogabook-camera.service && ${status_text[$unit]} != Camera\ idle:* ]]; then
				threshold=${quota_cpu_tenths[$unit]}
				workload=active
			fi
			if ((cpu_tenths <= threshold)); then
				ybv_emit resources "${unit%.service}-cpu" PASS "$label CPU use is within its $workload envelope" "cpu=$((cpu_tenths / 10)).$((cpu_tenths % 10))% threshold=$((threshold / 10)).$((threshold % 10))% sample_ms=$((elapsed_ns / 1000000))"
			else
				ybv_emit resources "${unit%.service}-cpu" FAIL "$label has sustained CPU use above its $workload envelope" "cpu=$((cpu_tenths / 10)).$((cpu_tenths % 10))% threshold=$((threshold / 10)).$((threshold % 10))% sample_ms=$((elapsed_ns / 1000000))"
			fi
		else
			ybv_emit resources "${unit%.service}-cpu" FAIL "$label CPU accounting is unavailable"
		fi
	done
fi

if [[ $YBV_SYSROOT != / ]]; then
	ybv_emit thermal kernel-events SKIP 'Live kernel journal inspection is unavailable'
elif ybv_has_command journalctl; then
	kernel_events=$(journalctl -b -k --no-pager 2>/dev/null | grep -Ei \
		'critical temperature|temperature above threshold|thermal.*(critical|trip.*failed)|CPU.*throttl|mce:.*thermal|oom-kill|out of memory|task .* blocked for more than' || true)
	if [[ -z $kernel_events ]]; then
		ybv_emit thermal kernel-events PASS 'No thermal, throttling, OOM or hung-task kernel events occurred this boot'
	else
		ybv_emit thermal kernel-events FAIL 'A thermal, throttling, OOM or hung-task kernel event occurred this boot' "$(head -n 1 <<<"$kernel_events")"
	fi
else
	ybv_emit thermal kernel-events SKIP 'journalctl is unavailable'
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
