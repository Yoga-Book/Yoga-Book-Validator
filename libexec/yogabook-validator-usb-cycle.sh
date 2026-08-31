#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ $EUID -eq 0 && ${YBV_ACTIVE_DISPATCH:-} == 1 ]] || {
	echo 'ERROR: USB OTG cycle must be launched through yogabook-validator' >&2
	exit 2
}
output_dir=
timeout_seconds=90
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	--timeout) [[ $# -ge 2 ]] || exit 2; timeout_seconds=$2; shift 2 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
if [[ ! $timeout_seconds =~ ^[1-9][0-9]*$ ]] || ((timeout_seconds < 30 || timeout_seconds > 300)); then
	echo 'ERROR: USB OTG cycle timeout must be between 30 and 300 seconds' >&2
	exit 2
fi
for required in dd journalctl lsusb timeout; do
	ybv_has_command "$required" || { echo "ERROR: missing command: $required" >&2; exit 2; }
done
ybv_require_x91l || { echo 'ERROR: USB OTG cycle is restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report usb-cycle "$output_dir"
ybv_register_state_keys 'sysfs:platform::charging:*'
real_user=$(ybv_real_user)
role_path=/sys/class/usb_role/intel_xhci_usb_sw-role-switch/role
initial_role=$(ybv_read_first "$role_path")
test_started=$(date --iso-8601=seconds)
baseline_file="$YBV_REPORT_DIR/.usb-baseline"
accessory=
report_finished=false

list_accessories() {
	local vendor_file device removable authorized
	for vendor_file in /sys/bus/usb/devices/*/idVendor; do
		[[ -r $vendor_file ]] || continue
		device=${vendor_file%/idVendor}
		[[ $(<"$vendor_file") != 1d6b ]] || continue
		removable=$(ybv_read_first "$device/removable")
		authorized=$(ybv_read_first "$device/authorized")
		[[ $removable != fixed && $authorized == 1 ]] || continue
		printf '%s\n' "${device##*/}"
	done | LC_ALL=C sort -u
}

accessory_present() {
	local name=$1
	[[ -d /sys/bus/usb/devices/$name && -r /sys/bus/usb/devices/$name/authorized &&
		$(<"/sys/bus/usb/devices/$name/authorized") == 1 ]]
}

finish_for_user() {
	local rc=0
	[[ $report_finished == false ]] || return 0
	report_finished=true
	rm -f -- "$baseline_file"
	# Read by ybv_finish_report from the sourced common library.
	# shellcheck disable=SC2034
	YBV_PHYSICAL_RESULT=PENDING
	ybv_finish_report || rc=$?
	ybv_chown_tree_to_user "$real_user" "$YBV_REPORT_DIR" 2>/dev/null || true
	return "$rc"
}

has_result() {
	awk -F '\t' -v category="$1" -v check="$2" \
		'NR > 1 && $2 == category && $3 == check {found=1} END {exit !found}' \
		"$YBV_REPORT" 2>/dev/null
}

emit_if_missing() {
	local category=$1 check=$2 status=$3 summary=$4 details=${5:-}
	has_result "$category" "$check" || ybv_emit "$category" "$check" "$status" "$summary" "$details"
}

emit_kernel_result() {
	local usb_errors
	usb_errors=$(journalctl -b -k --since "$test_started" --no-pager 2>/dev/null |
		grep -Eic 'device descriptor read.*error|unable to enumerate USB device|xHCI host controller not responding|HC died' || true)
	if ((usb_errors == 0)); then
		emit_if_missing usb cycle-kernel-errors PASS 'No targeted USB transport error occurred during the physical cycle'
	else
		emit_if_missing usb cycle-kernel-errors FAIL 'USB transport errors occurred during the physical cycle' "count=$usb_errors"
	fi
}

cancel_cycle() {
	local signal=${1:-TERM} restore_window current_role attached removed=false
	trap - INT TERM
	printf 'CANCELLATION_REQUESTED: Restore the original cable state and remove every OTG accessory. Waiting for verified cleanup.\n' | tee -a "$YBV_LOG"
	restore_window=$timeout_seconds
	((restore_window <= 30)) || restore_window=30
	deadline=$((SECONDS + restore_window))
	while ((SECONDS < deadline)); do
		current_role=$(ybv_read_first "$role_path")
		attached=$(list_accessories | wc -l)
		[[ -z $accessory ]] || ! accessory_present "$accessory" || { sleep 0.5; continue; }
		removed=true
		[[ $current_role == "$initial_role" && $attached -eq 0 ]] && break
		sleep 0.5
	done
	current_role=$(ybv_read_first "$role_path")
	attached=$(list_accessories | wc -l)
	emit_if_missing usb cycle-role-host SKIP 'USB host-role validation was cancelled before completion' 'blocked_by=validator/cancelled'
	emit_if_missing usb cycle-enumeration SKIP 'OTG accessory enumeration was cancelled before completion' 'blocked_by=validator/cancelled'
	emit_if_missing usb cycle-control-transfer SKIP 'USB descriptor validation was cancelled before completion' 'blocked_by=validator/cancelled'
	if [[ -n $accessory && $removed == true ]]; then
		emit_if_missing usb cycle-removal PASS 'The accepted OTG accessory was removed during cancellation cleanup'
	else
		emit_if_missing usb cycle-removal SKIP 'No accepted accessory required removal validation after cancellation' 'blocked_by=validator/cancelled'
	fi
	if [[ $current_role == "$initial_role" && $attached -eq 0 ]]; then
		emit_if_missing usb cycle-state-restore PASS 'USB role and accessory set returned to the initial state after cancellation' "role=$initial_role"
	else
		emit_if_missing usb cycle-state-restore FAIL 'Cancellation cleanup could not verify the initial USB state' "expected-role=$initial_role actual-role=$current_role attached=$attached"
	fi
	emit_kernel_result
	ybv_emit validator cancelled FAIL 'USB OTG cycle was cancelled' "signal=$signal"
	finish_for_user || true
	exit 130
}

trap 'cancel_cycle INT' INT
trap 'cancel_cycle TERM' TERM

if [[ ! $initial_role =~ ^(none|host|device)$ ]]; then
	ybv_emit usb cycle-baseline FAIL 'The initial USB role could not be captured' "role=${initial_role:-unavailable}"
	finish_for_user
	exit 1
fi
list_accessories >"$baseline_file"
baseline_count=$(wc -l <"$baseline_file")
if ((baseline_count > 0)); then
	ybv_emit usb cycle-baseline FAIL 'Disconnect removable USB accessories before starting the guided OTG cycle' "attached=$baseline_count"
	finish_for_user
	exit 1
fi
ybv_emit usb cycle-baseline PASS 'Captured an accessory-free USB baseline' "role=$initial_role"

printf 'ACTION_REQUIRED: If a charging/data cable is connected, unplug it. Insert one USB OTG accessory within %s seconds and leave it connected. Device identities are not retained.\n' "$timeout_seconds" | tee -a "$YBV_LOG"
deadline=$((SECONDS + timeout_seconds))
while ((SECONDS < deadline)); do
	current_role=$(ybv_read_first "$role_path")
	mapfile -t current_accessories < <(list_accessories)
	if [[ $current_role == host && ${#current_accessories[@]} -eq 1 ]]; then
		accessory=${current_accessories[0]}
		break
	fi
	sleep 0.5
done

if [[ -z $accessory ]]; then
	ybv_emit usb cycle-role-host FAIL 'USB role did not become host with exactly one authorized accessory' "role=$(ybv_read_first "$role_path") attached=$(list_accessories | wc -l)"
	ybv_emit usb cycle-enumeration SKIP 'OTG accessory enumeration was not completed' 'blocked_by=usb/cycle-role-host'
	ybv_emit usb cycle-control-transfer SKIP 'No accessory was available for a control transfer' 'blocked_by=usb/cycle-enumeration'
	ybv_emit usb cycle-removal SKIP 'No accepted accessory was available for removal validation' 'blocked_by=usb/cycle-enumeration'
	ybv_emit usb cycle-state-restore FAIL 'Restore the original cable/accessory state manually' "expected-role=$initial_role"
	finish_for_user
	exit 1
fi
ybv_emit usb cycle-role-host PASS 'Intel USB role switched to host for the inserted accessory'
speed=$(ybv_read_first "/sys/bus/usb/devices/$accessory/speed")
ybv_emit usb cycle-enumeration PASS 'Exactly one new authorized OTG accessory enumerated' "speed=${speed:-unavailable}M identities=discarded"

busnum=$(ybv_read_first "/sys/bus/usb/devices/$accessory/busnum")
devnum=$(ybv_read_first "/sys/bus/usb/devices/$accessory/devnum")
usb_node=
if [[ $busnum =~ ^[0-9]+$ && $devnum =~ ^[0-9]+$ ]]; then
	printf -v usb_node '/dev/bus/usb/%03d/%03d' "$((10#$busnum))" "$((10#$devnum))"
fi
if [[ -n $usb_node && -c $usb_node ]] && timeout 8 lsusb -D "$usb_node" >/dev/null 2>>"$YBV_LOG"; then
	ybv_emit usb cycle-control-transfer PASS 'The OTG accessory completed a bounded USB descriptor transfer' 'identity-output=discarded'
else
	ybv_emit usb cycle-control-transfer FAIL 'The enumerated OTG accessory did not complete a bounded descriptor transfer'
fi

storage_device=
for block in /sys/class/block/*; do
	[[ -e $block ]] || continue
	block_path=$(readlink -f "$block" 2>/dev/null || true)
	[[ $block_path == *"/$accessory/"* || $block_path == *"/$accessory:"* ]] || continue
	[[ $(ybv_read_first "$block/removable") == 1 ]] || continue
	storage_device="/dev/${block##*/}"
	break
done
if [[ -n $storage_device ]] && timeout 10 dd if="$storage_device" of=/dev/null bs=1M count=1 iflag=fullblock status=none; then
	ybv_emit usb cycle-storage-read PASS 'The removable USB storage accessory completed a bounded 1 MiB read'
elif [[ -n $storage_device ]]; then
	ybv_emit usb cycle-storage-read FAIL 'The removable USB storage accessory failed its bounded read'
else
	ybv_emit usb cycle-storage-read SKIP 'The attached OTG accessory is not removable block storage'
fi

printf 'ACTION_REQUIRED: Remove the OTG accessory, then restore the original cable state (for example reconnect the charger) within %s seconds.\n' "$timeout_seconds" | tee -a "$YBV_LOG"
removed=false
role_restored=false
deadline=$((SECONDS + timeout_seconds))
while ((SECONDS < deadline)); do
	accessory_present "$accessory" || removed=true
	[[ $(ybv_read_first "$role_path") == "$initial_role" ]] && role_restored=true
	[[ $removed == true && $role_restored == true ]] && break
	sleep 0.5
done
if [[ $removed == true ]]; then
	ybv_emit usb cycle-removal PASS 'The OTG accessory disappeared cleanly after physical removal'
else
	ybv_emit usb cycle-removal FAIL 'The OTG accessory remained enumerated after the removal window'
fi
if [[ $role_restored == true && $(list_accessories | wc -l) -eq 0 ]]; then
	ybv_emit usb cycle-state-restore PASS 'USB role and accessory set returned to the initial state' "role=$initial_role"
else
	ybv_emit usb cycle-state-restore FAIL 'USB role or accessory set did not return to the initial state' "expected-role=$initial_role actual-role=$(ybv_read_first "$role_path") attached=$(list_accessories | wc -l)"
fi

emit_kernel_result

finish_for_user
