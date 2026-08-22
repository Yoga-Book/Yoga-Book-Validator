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
	-h | --help) echo 'Usage: yogabook-validator platform [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
ybv_require_x91l || { echo 'ERROR: platform tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report platform "$output_dir"

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

declare -A expected_pci_drivers=(
	[0000:00:00.0]=iosf_mbi_pci
	[0000:00:02.0]=i915
	[0000:00:03.0]=atomisp-isp2
	[0000:00:0a.0]=intel_ish_ipc
	[0000:00:0b.0]=proc_thermal
	[0000:00:14.0]=xhci_hcd
	[0000:00:1a.0]=mei_txe
	[0000:00:1f.0]=lpc_ich
)
declare -a driver_failures=()
for address in "${!expected_pci_drivers[@]}"; do
	driver=$(basename "$(readlink -f "/sys/bus/pci/devices/$address/driver" 2>/dev/null || true)")
	[[ $driver == "${expected_pci_drivers[$address]}" ]] || driver_failures+=("$address=${driver:-none}")
done
if ((${#driver_failures[@]} == 0)); then
	ybv_emit platform soc-drivers PASS 'All required Cherry Trail platform functions use their expected drivers' 'functions=8'
else
	ybv_emit platform soc-drivers FAIL 'One or more Cherry Trail platform functions lack the expected driver' "${driver_failures[*]}"
fi

present=$(read_value /sys/devices/system/cpu/present 2>/dev/null || true)
possible=$(read_value /sys/devices/system/cpu/possible 2>/dev/null || true)
online=$(read_value /sys/devices/system/cpu/online 2>/dev/null || true)
if [[ $present == 0-3 && $possible == 0-3 && $online == 0-3 ]]; then
	ybv_emit platform cpu-topology PASS 'All four Cherry Trail CPU cores are present and online' 'cores=4'
else
	ybv_emit platform cpu-topology FAIL 'Cherry Trail CPU topology is incomplete' "present=${present:-unreadable} possible=${possible:-unreadable} online=${online:-unreadable}"
fi

policy_count=0
declare -a frequency_failures=() governors=()
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
	[[ -d $policy ]] || continue
	policy_count=$((policy_count + 1))
	driver=$(read_value "$policy/scaling_driver" 2>/dev/null || true)
	governor=$(read_value "$policy/scaling_governor" 2>/dev/null || true)
	minimum=$(read_integer "$policy/scaling_min_freq" 2>/dev/null || true)
	current=$(read_integer "$policy/scaling_cur_freq" 2>/dev/null || true)
	maximum=$(read_integer "$policy/scaling_max_freq" 2>/dev/null || true)
	governors+=("${governor:-unreadable}")
	if [[ $driver != intel_cpufreq || -z $minimum || -z $current || -z $maximum ]] || \
		((minimum <= 0 || maximum < minimum || current < minimum * 95 / 100 || current > maximum * 105 / 100)); then
		frequency_failures+=("${policy##*/}")
	fi
done
if ((policy_count == 4 && ${#frequency_failures[@]} == 0)); then
	ybv_emit platform cpu-frequency PASS 'Every CPU core has a valid intel_cpufreq policy' "policies=4 governors=${governors[*]}"
else
	ybv_emit platform cpu-frequency FAIL 'CPU frequency policy coverage or ranges are invalid' "policies=$policy_count invalid=${frequency_failures[*]:-none}"
fi

idle_driver=$(read_value /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null || true)
declare -A idle_enabled=()
for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
	[[ -d $state ]] || continue
	state_name=$(read_value "$state/name" 2>/dev/null || true)
	disabled=$(read_integer "$state/disable" 2>/dev/null || true)
	[[ -n $state_name ]] && idle_enabled[$state_name]=$disabled
done
declare -a idle_failures=()
for required_state in C1 C6N C6S C7 C7S; do
	[[ ${idle_enabled[$required_state]:-1} == 0 ]] || idle_failures+=("$required_state")
done
if [[ $idle_driver == intel_idle ]] && ((${#idle_failures[@]} == 0)); then
	ybv_emit platform cpu-idle PASS 'Intel idle exposes and enables every expected Cherry Trail low-power state' 'C1 C6N C6S C7 C7S'
else
	ybv_emit platform cpu-idle FAIL 'CPU idle driver or required low-power states are incomplete' "driver=${idle_driver:-unreadable} missing_or_disabled=${idle_failures[*]:-none}"
fi

declare -A thermal_values=()
for zone in /sys/class/thermal/thermal_zone*; do
	[[ -d $zone ]] || continue
	zone_type=$(read_value "$zone/type" 2>/dev/null || true)
	case $zone_type in PNIT | soc_dts0 | soc_dts1)
		thermal_values[$zone_type]=$(read_integer "$zone/temp" 2>/dev/null || true) ;;
	esac
done
declare -a thermal_failures=() thermal_details=()
for zone_type in PNIT soc_dts0 soc_dts1; do
	temperature=${thermal_values[$zone_type]:-}
	thermal_details+=("$zone_type=${temperature:-unreadable}")
	[[ -n $temperature ]] && ((temperature >= -20000 && temperature <= 110000)) || thermal_failures+=("$zone_type")
done
if ((${#thermal_failures[@]} == 0)); then
	ybv_emit platform thermal-sensors PASS 'All functional SoC thermal zones return plausible temperatures' "${thermal_details[*]}"
else
	ybv_emit platform thermal-sensors FAIL 'One or more functional SoC thermal zones are missing or implausible' "${thermal_details[*]}"
fi

processor_cooling=0
powerclamp_cooling=0
charge_cooling=0
invalid_cooling=0
for cooling in /sys/class/thermal/cooling_device*; do
	[[ -d $cooling ]] || continue
	cooling_type=$(read_value "$cooling/type" 2>/dev/null || true)
	current_state=$(read_integer "$cooling/cur_state" 2>/dev/null || true)
	maximum_state=$(read_integer "$cooling/max_state" 2>/dev/null || true)
	if [[ -z $current_state || -z $maximum_state ]] || ((current_state < 0 || maximum_state < current_state)); then
		invalid_cooling=$((invalid_cooling + 1))
	fi
	case $cooling_type in
	Processor) processor_cooling=$((processor_cooling + 1)) ;;
	intel_powerclamp) powerclamp_cooling=$((powerclamp_cooling + 1)) ;;
	TCHG) charge_cooling=$((charge_cooling + 1)) ;;
	esac
done
if ((processor_cooling == 4 && powerclamp_cooling == 1 && charge_cooling == 1 && invalid_cooling == 0)); then
	ybv_emit platform thermal-cooling PASS 'Processor, power-clamp and charger cooling devices are complete' 'processor=4 powerclamp=1 charger=1'
else
	ybv_emit platform thermal-cooling FAIL 'Thermal cooling-device coverage or state is incomplete' "processor=$processor_cooling powerclamp=$powerclamp_cooling charger=$charge_cooling invalid=$invalid_cooling"
fi

emmc=/sys/class/block/mmcblk0
emmc_type=$(read_value "$emmc/device/type" 2>/dev/null || true)
read_only=$(read_integer "$emmc/ro" 2>/dev/null || true)
removable=$(read_integer "$emmc/removable" 2>/dev/null || true)
rotational=$(read_integer "$emmc/queue/rotational" 2>/dev/null || true)
discard_max=$(read_integer "$emmc/queue/discard_max_bytes" 2>/dev/null || true)
if [[ $emmc_type == MMC && $read_only == 0 && $removable == 0 && $rotational == 0 && -n $discard_max ]] && ((discard_max > 0)); then
	ybv_emit storage emmc-transport PASS 'Internal eMMC is writable, non-removable and discard-capable' 'mmcblk0'
else
	ybv_emit storage emmc-transport FAIL 'Internal eMMC block transport attributes are invalid' "type=${emmc_type:-unreadable} ro=${read_only:-unreadable} removable=${removable:-unreadable} rotational=${rotational:-unreadable} discard=${discard_max:-unreadable}"
fi

life_time=$(read_value "$emmc/device/life_time" 2>/dev/null || true)
pre_eol=$(read_value "$emmc/device/pre_eol_info" 2>/dev/null || true)
life_valid=true
life_max=0
for estimate in $life_time; do
	if [[ $estimate =~ ^0x[0-9a-fA-F]{2}$ ]]; then
		estimate_value=$((estimate))
		((estimate_value > life_max)) && life_max=$estimate_value
	else
		life_valid=false
	fi
done
if [[ $life_valid == true && $life_max -ge 1 && $life_max -le 10 && $pre_eol == 0x01 ]]; then
	ybv_emit storage emmc-health PASS 'eMMC lifetime and pre-end-of-life indicators are healthy' "life_time=$life_time pre_eol=$pre_eol"
elif [[ $life_valid == true && $life_max -ge 1 && $life_max -le 10 && $pre_eol == 0x02 ]]; then
	ybv_emit storage emmc-health WARN 'eMMC reports a pre-end-of-life warning' "life_time=$life_time pre_eol=$pre_eol"
else
	ybv_emit storage emmc-health FAIL 'eMMC lifetime or pre-end-of-life indicators are invalid or critical' "life_time=${life_time:-unreadable} pre_eol=${pre_eol:-unreadable}"
fi

root_mount=$(findmnt -rn -o SOURCE,FSTYPE,OPTIONS / 2>/dev/null || true)
read -r root_source root_fstype root_options <<<"$root_mount"
if [[ $root_source == /dev/mmcblk0p* && $root_fstype == ext4 && ,$root_options, == *,rw,* ]]; then
	ybv_emit storage root-filesystem PASS 'Root filesystem is mounted read-write from internal eMMC' "$root_source $root_fstype"
else
	ybv_emit storage root-filesystem FAIL 'Root filesystem is not a read-write ext4 volume on internal eMMC' "${root_mount:-unreadable}"
fi

if ybv_has_command systemctl; then
	trim_enabled=$(systemctl is-enabled fstrim.timer 2>/dev/null || true)
	trim_active=$(systemctl is-active fstrim.timer 2>/dev/null || true)
	if [[ $trim_enabled == enabled && $trim_active == active ]]; then
		ybv_emit storage discard-maintenance PASS 'Periodic filesystem discard is enabled and active'
	else
		ybv_emit storage discard-maintenance WARN 'Periodic filesystem discard is not fully enabled' "enabled=${trim_enabled:-unknown} active=${trim_active:-unknown}"
	fi
else
	ybv_emit storage discard-maintenance SKIP 'systemctl is unavailable'
fi

rtc_name=$(read_value /sys/class/rtc/rtc0/name 2>/dev/null || true)
rtc_wakeup=$(read_value /sys/class/rtc/rtc0/device/power/wakeup 2>/dev/null || true)
mem_sleep=$(read_value /sys/power/mem_sleep 2>/dev/null || true)
power_states=$(read_value /sys/power/state 2>/dev/null || true)
if [[ $rtc_name == rtc_cmos* && $rtc_wakeup == enabled && -e /dev/rtc0 && $mem_sleep == *'[s2idle]'* && " $power_states " == *' mem '* ]]; then
	ybv_emit platform suspend-plumbing PASS 'RTC wake and s2idle suspend capabilities are available' 'rtc0 wake=enabled s2idle=selected'
else
	ybv_emit platform suspend-plumbing FAIL 'RTC wake or s2idle suspend capability is incomplete' "rtc=${rtc_name:-unreadable} wake=${rtc_wakeup:-unreadable} mem_sleep=${mem_sleep:-unreadable} states=${power_states:-unreadable}"
fi

taint=$(read_integer /proc/sys/kernel/tainted 2>/dev/null || true)
if [[ -n $taint ]]; then
	extra_taint=$((taint & ~1024))
	if ((extra_taint == 0)); then
		ybv_emit platform kernel-taint PASS 'Kernel taint is clean apart from the expected AtomISP staging flag' "taint=$taint"
	else
		ybv_emit platform kernel-taint WARN 'Kernel has additional taint flags beyond AtomISP staging' "taint=$taint extra=$extra_taint"
	fi
else
	ybv_emit platform kernel-taint FAIL 'Kernel taint state is unreadable'
fi

if ybv_has_command systemctl; then
	failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd, - || true)
	if [[ -z $failed_units ]]; then
		ybv_emit platform failed-units PASS 'No system service is currently failed'
	else
		failed_count=$(awk -F, '{print NF}' <<<"$failed_units")
		ybv_emit platform failed-units INFO 'One or more unrelated system services are failed' "count=$failed_count units=$failed_units"
	fi
else
	ybv_emit platform failed-units SKIP 'systemctl is unavailable'
fi

if ybv_has_command journalctl; then
	journal_errors=$(journalctl -b -k --no-pager 2>/dev/null | grep -Ei \
		'(mmcblk0|mmc0).*(I/O error|timed out|timeout|CRC error)|EXT4-fs error|remounting filesystem read-only|i915.*(GPU HANG|wedged|reset failed)|thermal.*(critical|trip.*failed)|watchdog: BUG: soft lockup|rcu:.*stall' || true)
	if [[ -z $journal_errors ]]; then
		ybv_emit platform kernel-errors PASS 'No targeted storage, GPU, thermal or lockup errors occurred in this boot'
	else
		ybv_emit platform kernel-errors FAIL 'Targeted platform errors occurred in this boot' "$(head -n 1 <<<"$journal_errors")"
	fi
else
	ybv_emit platform kernel-errors SKIP 'Kernel journal inspection is unavailable'
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
