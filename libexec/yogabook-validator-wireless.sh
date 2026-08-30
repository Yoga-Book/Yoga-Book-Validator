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
for required in bluetoothctl btmgmt ip mktemp ping rfkill stdbuf timeout; do
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
	ybv_finish_report_for_user "$real_user" || true
	exit 1
fi

initial_soft=$(<"$rfkill_path/soft")
controller_name=$([[ -r $rfkill_path/name ]] && cat "$rfkill_path/name" || true)
if [[ $controller_name =~ ^hci([0-9]+)$ ]]; then
	controller_index=${BASH_REMATCH[1]}
else
	ybv_emit wireless bluetooth-controller FAIL 'Bluetooth controller index could not be resolved' "$controller_name"
	ybv_finish_report_for_user "$real_user" || true
	exit 1
fi
controller_info_rc=0
controller_info=$(timeout 8 bluetoothctl show </dev/null 2>/dev/null) || controller_info_rc=$?
initial_power=$(sed -n 's/^[[:space:]]*Powered: //p' <<<"$controller_info" | head -n 1)
initial_power_known=true
if [[ $initial_power != yes && $initial_power != no ]]; then
	initial_power_known=false
	initial_power=unknown
fi

missing_capabilities=()
[[ $controller_info == *'(0000110b-0000-1000-8000-00805f9b34fb)'* ]] || missing_capabilities+=(classic-audio)
[[ $controller_info == *'(00001801-0000-1000-8000-00805f9b34fb)'* ]] || missing_capabilities+=(low-energy-gatt)
grep -Eq '^[[:space:]]*Roles: central$' <<<"$controller_info" || missing_capabilities+=(central-role)
grep -Eq '^[[:space:]]*Roles: peripheral$' <<<"$controller_info" || missing_capabilities+=(peripheral-role)
advertising_instances=$(sed -n 's/^[[:space:]]*SupportedInstances: //p' <<<"$controller_info" | head -n 1)
[[ -n $advertising_instances && $advertising_instances != '0x00 (0)' ]] || missing_capabilities+=(advertising)
if ((controller_info_rc != 0)) || [[ -z $controller_info ]]; then
	ybv_emit wireless bluetooth-features FAIL 'Bluetooth stack capability inventory is unavailable' "exit=$controller_info_rc bytes=${#controller_info}"
elif ((${#missing_capabilities[@]} == 0)); then
	ybv_emit wireless bluetooth-features PASS 'Bluetooth stack exposes classic, LE and advertising capabilities' 'classic-audio LE-GATT central peripheral advertising'
else
	ybv_emit wireless bluetooth-features FAIL 'Bluetooth stack capability set is incomplete' "missing=${missing_capabilities[*]}"
fi

if [[ $initial_power_known != true ]]; then
	ybv_emit wireless bluetooth-power FAIL 'Bluetooth controller power state could not be captured safely'
	ybv_emit wireless bluetooth-scan SKIP 'Bluetooth discovery was not started because the initial power state is unknown'
	ybv_emit wireless bluetooth-rf SKIP 'Bluetooth RF reception was not exercised because discovery was not started'
	ybv_emit wireless state-restore PASS 'No Bluetooth state was changed after the incomplete initial snapshot'
	ybv_finish_report_for_user "$real_user" || true
	exit 1
fi

discovery_pid=
discovery_file=

restore_wireless() {
	local current_soft current_power
	if [[ -n ${discovery_pid:-} ]]; then
		kill "$discovery_pid" 2>/dev/null || true
		wait "$discovery_pid" 2>/dev/null || true
		discovery_pid=
	fi
	timeout 5 bluetoothctl scan off >/dev/null 2>&1 || true
	timeout 5 btmgmt --index "$controller_index" stop-find >/dev/null 2>&1 || true
	if [[ -n ${discovery_file:-} ]]; then
		rm -f -- "$discovery_file"
		discovery_file=
	fi
	rfkill unblock bluetooth >/dev/null 2>&1 || true
	sleep 1
	if [[ $initial_power == yes ]]; then
		timeout 5 btmgmt --index "$controller_index" power on >/dev/null 2>&1 || true
	else
		timeout 5 btmgmt --index "$controller_index" power off >/dev/null 2>&1 || true
	fi
	if [[ $initial_soft == 1 ]]; then
		rfkill block bluetooth >/dev/null 2>&1 || true
	else
		rfkill unblock bluetooth >/dev/null 2>&1 || true
	fi
	for _ in {1..10}; do
		current_soft=$(<"$rfkill_path/soft")
		current_power=$(timeout 5 bluetoothctl show 2>/dev/null | sed -n 's/^[[:space:]]*Powered: //p' | head -n 1 || true)
		if [[ $current_soft == "$initial_soft" && $current_power == "$initial_power" ]]; then
			return 0
		fi
		sleep 0.5
	done
	return 1
}
ybv_register_restore_callback restore_wireless
trap 'restore_wireless || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

powered=false
power_output=
if rfkill unblock bluetooth; then
	for _ in {1..5}; do
		sleep 1
		power_output=$(timeout 5 btmgmt --index "$controller_index" power on 2>&1 || true)
		if timeout 5 bluetoothctl show 2>/dev/null | grep -Fq 'Powered: yes'; then
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

discovery_started=false
discovery_output=
if [[ $powered == true ]]; then
	discovery_file=$(mktemp /tmp/yogabook-validator-bluetooth.XXXXXX)
	chmod 600 "$discovery_file"
	timeout 12 stdbuf -oL -eL bluetoothctl --timeout 8 scan on >"$discovery_file" 2>&1 &
	discovery_pid=$!
	for _ in {1..25}; do
		if timeout 5 bluetoothctl show 2>/dev/null | grep -Fq 'Discovering: yes'; then
			discovery_started=true
			break
		fi
		kill -0 "$discovery_pid" 2>/dev/null || break
		sleep 0.2
	done
fi
if [[ $discovery_started == true ]]; then
	ybv_emit wireless bluetooth-scan PASS 'Bluetooth discovery entered the active state' 'bounded scan'
	sleep 6
else
	ybv_emit wireless bluetooth-scan FAIL 'Bluetooth discovery did not enter the active state'
fi
timeout 5 bluetoothctl scan off >/dev/null 2>&1 || true
timeout 5 btmgmt --index "$controller_index" stop-find >/dev/null 2>&1 || true
if [[ -n $discovery_pid ]]; then
	wait "$discovery_pid" 2>/dev/null || true
	discovery_pid=
fi
if [[ -n $discovery_file && -r $discovery_file ]]; then
	discovery_output=$(<"$discovery_file")
	rm -f -- "$discovery_file"
	discovery_file=
fi
discovery_reports=$(grep -Ec '\] Device ' <<<"$discovery_output" || true)
if ((discovery_reports > 0)); then
	ybv_emit wireless bluetooth-rf PASS 'Bluetooth received over-the-air discovery reports' "reports=$discovery_reports identities=discarded"
elif [[ $discovery_started == true ]]; then
	ybv_emit wireless bluetooth-rf WARN 'Bluetooth scan completed but no nearby peer was observed' 'identities=discarded'
else
	ybv_emit wireless bluetooth-rf FAIL 'Bluetooth RF reception could not be exercised'
fi

if restore_wireless; then
	ybv_emit wireless state-restore PASS 'Restored the original Bluetooth power and rfkill state' "powered=$initial_power soft-blocked=$initial_soft"
	trap - EXIT INT TERM
else
	ybv_emit wireless state-restore FAIL 'Could not restore the original Bluetooth power or rfkill state'
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report_for_user "$real_user"
