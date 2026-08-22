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
	-h | --help) echo 'Usage: yogabook-validator sensors [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
ybv_require_x91l || { echo 'ERROR: sensor tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report sensors "$output_dir"
iio_root=/sys/bus/iio/devices
declare -A expected_counts=([als]=2 [accel_3d]=4 [hinge]=2 [sx9310]=1)
declare -A observed_counts=([als]=0 [accel_3d]=0 [hinge]=0 [sx9310]=0)

read_integer() {
	local attribute=$1 value
	[[ -r $attribute ]] || return 1
	read -r value <"$attribute" || return 1
	[[ $value =~ ^-?[0-9]+$ ]] || return 1
	printf '%s\n' "$value"
}

for name_file in "$iio_root"/iio:device*/name; do
	[[ -r $name_file ]] || continue
	device=${name_file%/name}
	device_id="iio-device${device##*iio:device}"
	read -r sensor_name <"$name_file"
	[[ -v expected_counts[$sensor_name] ]] || continue
	observed_counts[$sensor_name]=$((observed_counts[$sensor_name] + 1))
	case $sensor_name in
	als)
		illuminance=$(read_integer "$device/in_illuminance_raw" || true)
		intensity=$(read_integer "$device/in_intensity_both_raw" || true)
		if [[ -n $illuminance && -n $intensity ]]; then
			ybv_emit sensors "$device_id-als" PASS 'Ambient-light channels return live integer samples' "illuminance=$illuminance intensity=$intensity"
		else
			ybv_emit sensors "$device_id-als" FAIL 'Ambient-light channels could not be sampled'
		fi
		;;
	accel_3d)
		x=$(read_integer "$device/in_accel_x_raw" || true)
		y=$(read_integer "$device/in_accel_y_raw" || true)
		z=$(read_integer "$device/in_accel_z_raw" || true)
		if [[ -n $x && -n $y && -n $z ]] && ((x != 0 || y != 0 || z != 0)); then
			ybv_emit sensors "$device_id-accelerometer" PASS 'Accelerometer axes return a non-zero live vector' "x=$x y=$y z=$z"
		else
			ybv_emit sensors "$device_id-accelerometer" FAIL 'Accelerometer axes did not return a plausible live vector' "x=${x:-unreadable} y=${y:-unreadable} z=${z:-unreadable}"
		fi
		;;
	hinge)
		hinge=$(read_integer "$device/in_angl0_raw" || true)
		screen=$(read_integer "$device/in_angl1_raw" || true)
		keyboard=$(read_integer "$device/in_angl2_raw" || true)
		labels=$(printf '%s %s %s' "$(<"$device/in_angl0_label")" "$(<"$device/in_angl1_label")" "$(<"$device/in_angl2_label")" 2>/dev/null || true)
		if [[ $labels == 'hinge screen keyboard' && -n $hinge && -n $screen && -n $keyboard ]] && \
			((hinge >= 0 && hinge <= 360 && screen >= 0 && screen <= 360 && keyboard >= 0 && keyboard <= 360)); then
			ybv_emit sensors "$device_id-hinge" PASS 'Hinge channels return labelled angles in range' "hinge=$hinge screen=$screen keyboard=$keyboard"
		else
			ybv_emit sensors "$device_id-hinge" FAIL 'Hinge channels or labels are invalid' "labels=$labels hinge=${hinge:-unreadable} screen=${screen:-unreadable} keyboard=${keyboard:-unreadable}"
		fi
		;;
	sx9310)
		proximity=()
		for channel in 0 1 2 3_comb; do
			value=$(read_integer "$device/in_proximity${channel}_raw" || true)
			[[ -n $value ]] && proximity+=("$channel=$value")
		done
		if ((${#proximity[@]} == 4)); then
			ybv_emit sensors "$device_id-proximity" PASS 'All SX9310 proximity channels return live integer samples' "${proximity[*]}"
		else
			ybv_emit sensors "$device_id-proximity" FAIL 'One or more SX9310 proximity channels could not be sampled' "${proximity[*]:-none}"
		fi
		;;
	esac
done

for sensor_name in als accel_3d hinge sx9310; do
	if ((observed_counts[$sensor_name] == expected_counts[$sensor_name])); then
		ybv_emit sensors "layout-$sensor_name" PASS "Expected $sensor_name sensor count is active" "${observed_counts[$sensor_name]}"
	else
		ybv_emit sensors "layout-$sensor_name" FAIL "Unexpected $sensor_name sensor count" "expected=${expected_counts[$sensor_name]} observed=${observed_counts[$sensor_name]}"
	fi
done

if ybv_has_command busctl; then
	orientation=$(busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy AccelerometerOrientation 2>/dev/null || true)
	light=$(busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy LightLevel 2>/dev/null || true)
	proximity_near=$(busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy ProximityNear 2>/dev/null || true)
	if [[ $orientation =~ ^s\ \"(normal|bottom-up|left-up|right-up|undefined)\"$ && $light =~ ^d\  && $proximity_near =~ ^b\ (true|false)$ ]]; then
		ybv_emit sensors sensor-proxy-live PASS 'SensorProxy returns live orientation, light and proximity values' "orientation=${orientation#s } light=${light#d } proximity=${proximity_near#b }"
	else
		ybv_emit sensors sensor-proxy-live FAIL 'SensorProxy live values are incomplete' "orientation=$orientation light=$light proximity=$proximity_near"
	fi
else
		ybv_emit sensors sensor-proxy-live SKIP 'busctl is unavailable'
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
