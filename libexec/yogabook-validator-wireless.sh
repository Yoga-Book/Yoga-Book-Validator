#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ $EUID -eq 0 && ${YBV_ACTIVE_DISPATCH:-} == 1 ]] || {
	echo 'ERROR: wireless test must be launched through yogabook-validator' >&2
	exit 2
}
output_dir=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
for required in bluetoothctl btmgmt ip ping rfkill timeout; do
	ybv_has_command "$required" || { echo "ERROR: missing command: $required" >&2; exit 2; }
done
ybv_require_x91l || { echo 'ERROR: wireless tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report wireless "$output_dir"
real_user=$(ybv_real_user)
[[ $real_user != root ]] || real_user=

wifi_interface=
for interface in /sys/class/net/*; do
	[[ -d $interface/wireless ]] || continue
	wifi_interface=${interface##*/}
	break
done
if [[ -n $wifi_interface ]]; then
	wifi_state=$(<"/sys/class/net/$wifi_interface/operstate")
	if [[ $wifi_state == up ]]; then
		ybv_emit wireless wifi-link PASS 'Wi-Fi interface is operational' "$wifi_interface"
	else
		ybv_emit wireless wifi-link FAIL 'Wi-Fi interface is not operational' "$wifi_interface state=$wifi_state"
	fi
	default_route=$(ip -4 route show default dev "$wifi_interface" | head -n 1 || true)
	gateway=$(sed -n 's/^default via \([^ ]*\).*/\1/p' <<<"$default_route")
	if [[ -n $gateway ]]; then
		ybv_emit wireless wifi-route PASS 'Wi-Fi has an IPv4 default route' "$wifi_interface"
		if timeout 10 ping -I "$wifi_interface" -c 3 -W 2 "$gateway" >/dev/null 2>&1; then
			ybv_emit wireless wifi-gateway PASS 'Wi-Fi exchanged packets with its default gateway' '3 echo requests'
		else
			ybv_emit wireless wifi-gateway FAIL 'Wi-Fi could not reach its default gateway'
		fi
	else
		ybv_emit wireless wifi-route FAIL 'Wi-Fi has no IPv4 default route' "$wifi_interface"
	fi
else
	ybv_emit wireless wifi-link FAIL 'No Wi-Fi interface is available'
fi

rfkill_path=
for candidate in /sys/class/rfkill/rfkill*; do
	[[ -r $candidate/type ]] || continue
	read -r radio_type <"$candidate/type"
	if [[ $radio_type == bluetooth ]]; then
		rfkill_path=$candidate
		break
	fi
done
if [[ -z $rfkill_path ]]; then
	ybv_emit wireless bluetooth-controller FAIL 'Bluetooth rfkill device is missing'
	if [[ -n $real_user && -d $YBV_REPORT_DIR ]]; then
		chown -R -- "$real_user:" "$YBV_REPORT_DIR" 2>/dev/null || true
	fi
	ybv_finish_report
	exit 1
fi

initial_soft=$(<"$rfkill_path/soft")
controller_name=$([[ -r $rfkill_path/name ]] && cat "$rfkill_path/name" || true)
if [[ $controller_name =~ ^hci([0-9]+)$ ]]; then
	controller_index=${BASH_REMATCH[1]}
else
	ybv_emit wireless bluetooth-controller FAIL 'Bluetooth controller index could not be resolved' "$controller_name"
	if [[ -n $real_user && -d $YBV_REPORT_DIR ]]; then
		chown -R -- "$real_user:" "$YBV_REPORT_DIR" 2>/dev/null || true
	fi
	ybv_finish_report
	exit 1
fi
initial_power=$(bluetoothctl show 2>/dev/null | sed -n 's/^[[:space:]]*Powered: //p' | head -n 1 || true)
[[ $initial_power == yes || $initial_power == no ]] || initial_power=no

restore_wireless() {
	local restore_rc=0 current_soft current_power
	btmgmt --index "$controller_index" stop-find >/dev/null 2>&1 || true
	rfkill unblock bluetooth || restore_rc=1
	sleep 1
	if [[ $initial_power == yes ]]; then
		timeout 5 btmgmt --index "$controller_index" power on >/dev/null 2>&1 || restore_rc=1
	else
		timeout 5 btmgmt --index "$controller_index" power off >/dev/null 2>&1 || restore_rc=1
	fi
	if [[ $initial_soft == 1 ]]; then
		rfkill block bluetooth || restore_rc=1
	fi
	sleep 1
	current_soft=$(<"$rfkill_path/soft")
	current_power=$(bluetoothctl show 2>/dev/null | sed -n 's/^[[:space:]]*Powered: //p' | head -n 1 || true)
	[[ $current_soft == "$initial_soft" ]] || restore_rc=1
	[[ $current_power == "$initial_power" ]] || restore_rc=1
	return "$restore_rc"
}
trap 'restore_wireless || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

powered=false
power_output=
if rfkill unblock bluetooth; then
	for _ in {1..5}; do
		sleep 1
		power_output=$(timeout 5 btmgmt --index "$controller_index" power on 2>&1 || true)
		if bluetoothctl show 2>/dev/null | grep -Fq 'Powered: yes'; then
			powered=true
			break
		fi
	done
fi
printf '\n===== Bluetooth power-on =====\n%s\n' "$power_output" >>"$YBV_LOG"
if [[ $powered == true ]]; then
	ybv_emit wireless bluetooth-power PASS 'Bluetooth controller powered on for the bounded scan'
else
	ybv_emit wireless bluetooth-power FAIL 'Bluetooth controller could not be powered on'
fi

discovery_output=
if [[ $powered == true ]]; then
	discovery_output=$(timeout 8 btmgmt --index "$controller_index" find 2>&1 || true)
fi
if grep -Fq 'Discovery started' <<<"$discovery_output"; then
	ybv_emit wireless bluetooth-scan PASS 'Bluetooth discovery entered the active state' 'bounded scan'
else
	ybv_emit wireless bluetooth-scan FAIL 'Bluetooth discovery did not enter the active state'
fi
btmgmt --index "$controller_index" stop-find >/dev/null 2>&1 || true

if restore_wireless; then
	ybv_emit wireless state-restore PASS 'Restored the original Bluetooth power and rfkill state' "powered=$initial_power soft-blocked=$initial_soft"
	trap - EXIT INT TERM
else
	ybv_emit wireless state-restore FAIL 'Could not restore the original Bluetooth power or rfkill state'
fi

if [[ -n $real_user && -d $YBV_REPORT_DIR ]]; then
	chown -R -- "$real_user:" "$YBV_REPORT_DIR" 2>/dev/null || true
fi
YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
