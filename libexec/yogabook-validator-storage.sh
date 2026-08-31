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
write_test=false
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	--write-test) write_test=true; shift ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
for required in blkid dd find findmnt lsblk mount mountpoint sha256sum stat sync timeout umount; do
	ybv_has_command "$required" || { echo "ERROR: missing command: $required" >&2; exit 2; }
done
ybv_require_x91l || { echo 'ERROR: storage tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }

command_name=storage
[[ $write_test == true ]] && command_name=storage-write
ybv_begin_report "$command_name" "$output_dir"
ybv_register_state_keys 'mount:mmcblk*' 'temporary:validator-mounts'
real_user=$(ybv_real_user)
[[ $real_user != root ]] || real_user=
active_mount=
active_test_file=

cleanup_mount() {
	local cleanup_rc=0
	if [[ -n $active_test_file ]]; then
		if [[ -e $active_test_file ]] && ! rm -f -- "$active_test_file"; then cleanup_rc=1; fi
		if [[ ! -e $active_test_file ]]; then active_test_file=; fi
	fi
	if [[ -n $active_mount ]]; then
		if mountpoint -q "$active_mount" && ! umount "$active_mount"; then cleanup_rc=1; fi
		if ((cleanup_rc == 0)); then
			rmdir "$active_mount" 2>/dev/null || cleanup_rc=1
		fi
		if ((cleanup_rc == 0)); then active_mount=; fi
	fi
	return "$cleanup_rc"
}
ybv_register_restore_callback cleanup_mount
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
	if [[ $write_test == true ]]; then
		ybv_emit storage sd-card SKIP 'No SD card is inserted; write transport was not tested'
		YBV_FINAL_ROLLUP_CHECK_ID=storage-write
		YBV_FINAL_ROLLUP_STATUS=SKIP
		YBV_FINAL_ROLLUP_SUMMARY='Bounded SD write validation was incomplete'
		YBV_FINAL_ROLLUP_DETAILS='partitions-passed=0 skipped=1'
	else
		ybv_emit storage sd-card SKIP 'No SD card is inserted; read transport was not tested'
	fi
	trap - EXIT INT TERM
	YBV_PHYSICAL_RESULT=PENDING
	ybv_finish_report_for_user "$real_user"
	exit
fi
sd_device="/dev/$sd_name"
if [[ $write_test == false ]]; then
	if timeout 10 dd if="$sd_device" of=/dev/null bs=1M count=4 iflag=fullblock status=none; then
		ybv_emit storage sd-block-read PASS 'Read the first 4 MiB from the SD card' "$sd_name"
	else
		ybv_emit storage sd-block-read FAIL 'Bounded SD card block read failed' "$sd_name"
	fi
fi

mapfile -t partitions < <(lsblk -lnpo NAME,TYPE "$sd_device" | awk '$2 == "part" {print $1}')
if ((${#partitions[@]} == 0)); then
	if [[ $write_test == true ]]; then
		ybv_emit storage sd-filesystems SKIP 'The inserted SD card has no partitions to test for writes'
	else
		ybv_emit storage sd-filesystems SKIP 'The inserted SD card has no partitions to mount read-only'
	fi
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
	if [[ $write_test == true ]]; then
		if [[ -n $mount_dir ]]; then
			existing_options=$(findmnt -rn -T "$mount_dir" -o OPTIONS | head -n 1 || true)
			if [[ ,$existing_options, != *,rw,* ]]; then
				ybv_emit storage "partition-${partition##*/}" SKIP 'Existing SD filesystem mount is read-only; it was not remounted' "$fstype"
				continue
			fi
		else
			active_mount=$(mktemp -d /run/yogabook-validator-sd-write.XXXXXX)
			chmod 0700 "$active_mount"
			if mount -t "$fstype" -o rw,nodev,nosuid,noexec "$partition" "$active_mount"; then
				mount_dir=$active_mount
				mounted_here=true
			else
				ybv_emit storage "partition-${partition##*/}" FAIL 'Could not mount SD partition for the bounded write test' "$fstype"
				cleanup_mount || true
				continue
			fi
		fi
		active_test_file=$(mktemp -p "$mount_dir" .yogabook-validator-write-test.XXXXXX 2>>"$YBV_LOG" || true)
		if [[ -z $active_test_file ]]; then
			ybv_emit storage "partition-${partition##*/}" FAIL 'Could not create the bounded SD test file' "$fstype"
		elif timeout 10 dd if=/dev/zero of="$active_test_file" bs=64K count=1 conv=fsync status=none &&
			[[ $(sha256sum "$active_test_file" | cut -d' ' -f1) == $(head -c 65536 /dev/zero | sha256sum | cut -d' ' -f1) ]] &&
			rm -f -- "$active_test_file" && sync -f "$mount_dir"; then
			active_test_file=
			ybv_emit storage "partition-${partition##*/}" PASS 'Created, verified, synchronized and removed a 64 KiB SD test file' "$fstype"
		else
			ybv_emit storage "partition-${partition##*/}" FAIL 'Bounded SD write, verification or cleanup failed' "$fstype"
		fi
		if [[ $mounted_here == true ]]; then
			if cleanup_mount; then
				ybv_emit storage "restore-${partition##*/}" PASS 'Unmounted the temporary writable SD mount'
			else
				ybv_emit storage "restore-${partition##*/}" FAIL 'Could not remove the temporary writable SD mount'
				break
			fi
		elif [[ -n $active_test_file ]] && cleanup_mount; then
			ybv_emit storage "cleanup-${partition##*/}" PASS 'Removed the SD test file after a failed write check'
		fi
		continue
	fi
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

if [[ -n $active_mount || -n $active_test_file ]]; then
	if cleanup_mount; then
		ybv_emit storage state-restore PASS 'Removed temporary SD test state on retry'
	else
		ybv_emit storage state-restore FAIL 'Temporary SD test state remains after cleanup retries'
	fi
fi

if [[ $write_test == true ]]; then
	write_failures=$(awk -F '\t' '$2 == "storage" && $4 == "FAIL" {count++} END {print count+0}' "$YBV_REPORT")
	write_skips=$(awk -F '\t' '$2 == "storage" && $4 == "SKIP" {count++} END {print count+0}' "$YBV_REPORT")
	write_passes=$(awk -F '\t' '$2 == "storage" && $3 ~ /^partition-/ && $4 == "PASS" {count++} END {print count+0}' "$YBV_REPORT")
	if ((write_failures > 0)); then
		YBV_FINAL_ROLLUP_STATUS=FAIL
		YBV_FINAL_ROLLUP_SUMMARY='Bounded SD write validation failed'
		YBV_FINAL_ROLLUP_DETAILS="partitions-passed=$write_passes failures=$write_failures skipped=$write_skips"
	elif ((write_passes == 0 || write_skips > 0)); then
		YBV_FINAL_ROLLUP_STATUS=SKIP
		YBV_FINAL_ROLLUP_SUMMARY='Bounded SD write validation was incomplete'
		YBV_FINAL_ROLLUP_DETAILS="partitions-passed=$write_passes skipped=$write_skips"
	else
		YBV_FINAL_ROLLUP_STATUS=PASS
		YBV_FINAL_ROLLUP_SUMMARY='Every writable SD filesystem passed the bounded write validation'
		YBV_FINAL_ROLLUP_DETAILS="partitions-passed=$write_passes"
	fi
	YBV_FINAL_ROLLUP_CHECK_ID=storage-write
fi

if [[ -z $active_mount && -z $active_test_file ]]; then trap - EXIT INT TERM; fi
YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report_for_user "$real_user"
