#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ $EUID -eq 0 && ${YBV_ACTIVE_DISPATCH:-} == 1 ]] || {
	echo 'ERROR: storage test must be launched through yogabook-validator' >&2
	exit 2
}
output_dir=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
for required in blkid dd find findmnt lsblk mount mountpoint stat timeout umount; do
	ybv_has_command "$required" || { echo "ERROR: missing command: $required" >&2; exit 2; }
done
ybv_require_x91l || { echo 'ERROR: storage tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report storage "$output_dir"
real_user=$(ybv_real_user)
[[ $real_user != root ]] || real_user=
active_mount=

cleanup_mount() {
	local cleanup_rc=0
	if [[ -n $active_mount ]]; then
		if mountpoint -q "$active_mount" && ! umount "$active_mount"; then cleanup_rc=1; fi
		if ((cleanup_rc == 0)); then
			rmdir "$active_mount" 2>/dev/null || cleanup_rc=1
		fi
		if ((cleanup_rc == 0)); then active_mount=; fi
	fi
	return "$cleanup_rc"
}
trap 'cleanup_mount || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sd_name=
for candidate in /sys/block/mmcblk*; do
	[[ -r $candidate/device/type ]] || continue
	read -r media_type <"$candidate/device/type"
	if [[ $media_type == SD ]]; then
		sd_name=${candidate##*/}
		break
	fi
done
if [[ -z $sd_name ]]; then
	ybv_emit storage sd-card SKIP 'No SD card is inserted; read transport was not tested'
	if [[ -n $real_user && -d $YBV_REPORT_DIR ]]; then
		chown -R -- "$real_user:" "$YBV_REPORT_DIR" 2>/dev/null || true
	fi
	trap - EXIT INT TERM
	YBV_PHYSICAL_RESULT=PENDING
	ybv_finish_report
	exit
fi
sd_device="/dev/$sd_name"
if timeout 10 dd if="$sd_device" of=/dev/null bs=1M count=4 iflag=fullblock status=none; then
	ybv_emit storage sd-block-read PASS 'Read the first 4 MiB from the SD card' "$sd_name"
else
	ybv_emit storage sd-block-read FAIL 'Bounded SD card block read failed' "$sd_name"
fi

mapfile -t partitions < <(lsblk -lnpo NAME,TYPE "$sd_device" | awk '$2 == "part" {print $1}')
if ((${#partitions[@]} == 0)); then
	ybv_emit storage sd-filesystems SKIP 'The inserted SD card has no partitions to mount read-only'
fi
for partition in "${partitions[@]}"; do
	fstype=$(blkid -o value -s TYPE "$partition" 2>/dev/null || true)
	if [[ -z $fstype ]]; then
		ybv_emit storage "partition-${partition##*/}" SKIP 'Partition has no recognized filesystem'
		continue
	fi
	existing_mount=$(findmnt -rn -S "$partition" -o TARGET | head -n 1 || true)
	mount_dir=$existing_mount
	mounted_here=false
	if [[ -z $mount_dir ]]; then
		active_mount=$(mktemp -d /run/yogabook-validator-sd.XXXXXX)
		chmod 0700 "$active_mount"
		mount_options=ro,nodev,nosuid,noexec
		[[ $fstype == ext4 ]] && mount_options+=,noload
		if mount -t "$fstype" -o "$mount_options" "$partition" "$active_mount"; then
			mount_dir=$active_mount
			mounted_here=true
		else
			ybv_emit storage "partition-${partition##*/}" FAIL 'Could not mount SD partition read-only' "$fstype"
			cleanup_mount || true
			continue
		fi
	fi
	sample_file=
	while IFS= read -r -d '' candidate; do sample_file=$candidate; break; done < <(find "$mount_dir" -xdev -type f -readable -print0 2>/dev/null)
	if [[ -n $sample_file ]]; then
		if timeout 5 head -c 4096 -- "$sample_file" >/dev/null; then
			if [[ $mounted_here == true ]]; then
				ybv_emit storage "partition-${partition##*/}" PASS 'Mounted SD filesystem read-only and read file data' "$fstype"
			else
				ybv_emit storage "partition-${partition##*/}" PASS 'Read file data from an existing SD mount without writing' "$fstype"
			fi
		else
			ybv_emit storage "partition-${partition##*/}" FAIL 'Mounted SD filesystem but could not read file data' "$fstype"
		fi
	elif stat "$mount_dir" >/dev/null; then
		ybv_emit storage "partition-${partition##*/}" PASS 'Mounted empty SD filesystem read-only and read metadata' "$fstype"
	else
		ybv_emit storage "partition-${partition##*/}" FAIL 'Could not read SD filesystem metadata' "$fstype"
	fi
	if [[ $mounted_here == true ]]; then
		if cleanup_mount; then
			ybv_emit storage "restore-${partition##*/}" PASS 'Unmounted the temporary read-only SD mount'
		else
			ybv_emit storage "restore-${partition##*/}" FAIL 'Could not remove the temporary SD mount'
			break
		fi
	fi
done

if [[ -n $active_mount ]]; then
	if cleanup_mount; then
		ybv_emit storage state-restore PASS 'Removed the temporary SD mount on retry'
	else
		ybv_emit storage state-restore FAIL 'A temporary SD mount remains after cleanup retries' "$active_mount"
	fi
fi

if [[ -n $real_user && -d $YBV_REPORT_DIR ]]; then
	chown -R -- "$real_user:" "$YBV_REPORT_DIR" 2>/dev/null || true
fi
if [[ -z $active_mount ]]; then trap - EXIT INT TERM; fi
YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
