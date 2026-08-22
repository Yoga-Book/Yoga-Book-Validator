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
	-h | --help) echo 'Usage: yogabook-validator usb [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
ybv_require_x91l || { echo 'ERROR: USB tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report usb "$output_dir"
controller=/sys/bus/pci/devices/0000:00:14.0
controller_driver=$(basename "$(readlink -f "$controller/driver" 2>/dev/null || true)")
vendor=$(ybv_read_first /sys/bus/pci/devices/0000:00:14.0/vendor)
device_id=$(ybv_read_first /sys/bus/pci/devices/0000:00:14.0/device)
if [[ $vendor == 0x8086 && $device_id == 0x22b5 && $controller_driver == xhci_hcd ]]; then
	ybv_emit usb controller PASS 'Intel Cherry Trail USB controller uses xhci_hcd' '0000:00:14.0'
else
	ybv_emit usb controller FAIL 'USB controller identity or driver is incorrect' "vendor=$vendor device=$device_id driver=${controller_driver:-none}"
fi

check_root_hub() {
	local name=$1 generation=$2 expected_product=$3 expected_speed=$4 path="/sys/bus/usb/devices/$1"
	local product speed authorized
	product=$(ybv_read_first "/sys/bus/usb/devices/$name/idProduct")
	speed=$(ybv_read_first "/sys/bus/usb/devices/$name/speed")
	authorized=$(ybv_read_first "/sys/bus/usb/devices/$name/authorized")
	if [[ $product == "$expected_product" && $speed == "$expected_speed" && $authorized == 1 && -d $path ]]; then
		ybv_emit usb "root-hub-$name" PASS "USB $generation root hub is active and authorized" "speed=${speed}M"
	else
		ybv_emit usb "root-hub-$name" FAIL "USB $generation root hub is incomplete" "product=${product:-unreadable} speed=${speed:-unreadable} authorized=${authorized:-unreadable}"
	fi
}
check_root_hub usb1 2.0 0002 480
check_root_hub usb2 3.0 0003 5000

role_path=/sys/class/usb_role/intel_xhci_usb_sw-role-switch/role
role=$(ybv_read_first /sys/class/usb_role/intel_xhci_usb_sw-role-switch/role)
if [[ -r $role_path && -d /sys/module/intel_xhci_usb_role_switch && $role =~ ^(none|host|device)$ ]]; then
	ybv_emit usb role-switch PASS 'Intel xHCI USB role switch is active' "role=$role"
else
	ybv_emit usb role-switch FAIL 'Intel xHCI USB role switch is missing or invalid' "role=${role:-unreadable}"
fi

xmm_device=
for vendor_file in /sys/bus/usb/devices/*/idVendor; do
	[[ -r $vendor_file ]] || continue
	usb_device=${vendor_file%/idVendor}
	[[ $(<"$vendor_file") == 8087 && -r $usb_device/idProduct && $(<"$usb_device/idProduct") == 0911 ]] || continue
	xmm_device=$usb_device
	break
done
if [[ -n $xmm_device ]]; then
	xmm_speed=$(ybv_read_first "$xmm_device/speed")
	xmm_removable=$(ybv_read_first "$xmm_device/removable")
	mbim_interfaces=0
	for interface in "$xmm_device":*; do
		[[ -d $interface ]] || continue
		[[ $(basename "$(readlink -f "$interface/driver" 2>/dev/null || true)") == cdc_mbim ]] && mbim_interfaces=$((mbim_interfaces + 1))
	done
	if [[ $xmm_speed == 5000 && $xmm_removable == fixed && $mbim_interfaces -eq 2 ]]; then
		ybv_emit usb xmm-transport PASS 'Fixed XMM7260 USB transport exposes both cdc_mbim interfaces' 'speed=5000M interfaces=2'
	else
		ybv_emit usb xmm-transport FAIL 'XMM7260 USB transport is incomplete' "speed=${xmm_speed:-unreadable} removable=${xmm_removable:-unreadable} mbim_interfaces=$mbim_interfaces"
	fi
else
	ybv_emit usb xmm-transport FAIL 'XMM7260 USB function is missing'
fi

removable_count=0
authorized_count=0
declare -a removable_speeds=()
for vendor_file in /sys/bus/usb/devices/*/idVendor; do
	[[ -r $vendor_file ]] || continue
	usb_device=${vendor_file%/idVendor}
	usb_vendor=$(<"$vendor_file")
	[[ $usb_vendor != 1d6b ]] || continue
	removable=$(ybv_read_first "$usb_device/removable")
	[[ $removable != fixed ]] || continue
	removable_count=$((removable_count + 1))
	authorized=$(ybv_read_first "$usb_device/authorized")
	[[ $authorized == 1 ]] && authorized_count=$((authorized_count + 1))
	removable_speeds+=("$(ybv_read_first "$usb_device/speed")M")
done
if ((removable_count == 0)); then
	ybv_emit usb removable-device SKIP 'No removable USB accessory is attached; OTG enumeration was not exercised'
elif ((authorized_count == removable_count)); then
	ybv_emit usb removable-device PASS 'All attached removable USB devices are authorized and enumerated' "devices=$removable_count speeds=${removable_speeds[*]}"
else
	ybv_emit usb removable-device FAIL 'One or more removable USB devices are not authorized' "devices=$removable_count authorized=$authorized_count"
fi

if ybv_has_command journalctl; then
	usb_errors=$(journalctl -b -k --no-pager 2>/dev/null | grep -Eic 'device descriptor read.*error|unable to enumerate USB device|xHCI host controller not responding|HC died' || true)
	if ((usb_errors == 0)); then
		ybv_emit usb kernel-errors PASS 'No targeted USB controller or enumeration errors in this boot'
	else
		ybv_emit usb kernel-errors FAIL 'Targeted USB controller or enumeration errors occurred in this boot' "count=$usb_errors"
	fi
else
	ybv_emit usb kernel-errors SKIP 'Kernel journal inspection is unavailable'
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
