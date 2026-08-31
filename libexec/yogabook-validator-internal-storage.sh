#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

active_storage_file=

cleanup_internal_storage() {
	local cleanup_rc=0
	if [[ -n $active_storage_file ]]; then
		rm -f -- "$active_storage_file" 2>/dev/null || cleanup_rc=1
		[[ -e $active_storage_file ]] || active_storage_file=
	fi
	return "$cleanup_rc"
}

ybv_internal_storage_probe() {
	local probe_dir=$1 root_device probe_device probe_mount probe_fstype expected_sha actual_sha retained
	local -a residues=()
	root_device=$(findmnt -rn -T / -o MAJ:MIN 2>/dev/null || true)
	probe_device=$(findmnt -rn -T "$probe_dir" -o MAJ:MIN 2>/dev/null || true)
	probe_mount=$(findmnt -rn -T "$probe_dir" -o TARGET 2>/dev/null || true)
	probe_fstype=$(findmnt -rn -T "$probe_dir" -o FSTYPE 2>/dev/null || true)
	if [[ -z $root_device || -z $probe_device || $probe_device != "$root_device" ]]; then
		ybv_emit storage root-file-io FAIL 'Bounded filesystem I/O target is not on the root filesystem' \
			"root_device=${root_device:-unreadable} target_device=${probe_device:-unreadable} target_mount=${probe_mount:-unreadable}"
		return 1
	fi
	if [[ ! -d $probe_dir || ! -w $probe_dir ]]; then
		ybv_emit storage root-file-io FAIL 'Root-filesystem probe directory is unavailable or not writable' \
			"target_mount=${probe_mount:-unreadable}"
		return 1
	fi
	if ! ybv_has_command bash || ! ybv_has_command cut || ! ybv_has_command dd ||
		! ybv_has_command findmnt || ! ybv_has_command mktemp || ! ybv_has_command rm ||
		! ybv_has_command sha256sum || ! ybv_has_command stat || ! ybv_has_command sync ||
		! ybv_has_command timeout || ! ybv_has_command tr; then
		ybv_emit storage root-file-io SKIP 'Required bounded filesystem-I/O tools are unavailable'
		return 0
	fi

	shopt -s nullglob
	residues=("$probe_dir"/.yogabook-validator-internal-storage-io.*)
	shopt -u nullglob
	if ((${#residues[@]} > 0)); then
		ybv_emit storage root-file-io FAIL 'A previous internal-storage probe did not clean up its temporary file' \
			"residual_files=${#residues[@]} target_mount=${probe_mount:-unreadable}"
		return 1
	fi

	active_storage_file=$(mktemp -p "$probe_dir" .yogabook-validator-internal-storage-io.XXXXXX 2>>"$YBV_LOG" || true)
	expected_sha=8c7631389970cde5de2c18211fd7b0e8f0618c6ea0221542f518ce4336149203
	# The inner Bash expands its own positional parameter after timeout starts it.
	# shellcheck disable=SC2016
	if [[ -n $active_storage_file ]] &&
		timeout 15 bash -o pipefail -c \
			'dd if=/dev/zero bs=1M count=4 status=none | tr "\000" "\245" | dd of="$1" bs=1M conv=fsync status=none' \
			_ "$active_storage_file" &&
		[[ $(stat -c %s "$active_storage_file" 2>/dev/null || true) == 4194304 ]] &&
		actual_sha=$(sha256sum "$active_storage_file" | cut -d' ' -f1) &&
		[[ $actual_sha == "$expected_sha" ]] &&
		[[ ${YBV_TEST_FORCE_STORAGE_FAILURE:-0} != 1 ]] &&
		rm -f -- "$active_storage_file" && sync -f "$probe_dir" && [[ ! -e $active_storage_file ]]; then
		active_storage_file=
		ybv_emit storage root-file-io PASS 'Created, synchronized, read-verified and removed a bounded non-zero file on the root filesystem' \
			"bytes=4194304 pattern=0xa5 retained=false device=$probe_device filesystem=$probe_fstype mount=$probe_mount"
		return 0
	fi
	cleanup_internal_storage || true
	retained=false
	[[ -z $active_storage_file ]] || retained=true
	ybv_emit storage root-file-io FAIL 'Bounded root-filesystem I/O, verification or cleanup failed' \
		"bytes=4194304 pattern=0xa5 cleanup_attempted=true retained=$retained device=$probe_device mount=$probe_mount"
	return 1
}

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
	return 0
fi

[[ $EUID -eq 0 && ${YBV_ACTIVE_DISPATCH:-} == 1 || ${YBV_TESTING:-} == 1 ]] || {
	echo 'ERROR: internal-storage test must be launched through yogabook-validator' >&2
	exit 2
}

output_dir=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
ybv_require_x91l || { echo 'ERROR: internal-storage test is restricted to Lenovo YB1-X91L' >&2; exit 2; }

ybv_begin_report internal-storage "$output_dir"
ybv_register_restore_callback cleanup_internal_storage
trap 'cleanup_internal_storage || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ${YBV_TESTING:-} == 1 && -n ${YBV_INTERNAL_STORAGE_PROBE_DIR:-} ]]; then
	probe_dir=$YBV_INTERNAL_STORAGE_PROBE_DIR
else
	probe_dir=/var/tmp
	root_device=$(findmnt -rn -T / -o MAJ:MIN 2>/dev/null || true)
	var_tmp_device=$(findmnt -rn -T /var/tmp -o MAJ:MIN 2>/dev/null || true)
	[[ -n $root_device && $var_tmp_device == "$root_device" ]] || probe_dir=/
fi

ybv_internal_storage_probe "$probe_dir" || true
YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
