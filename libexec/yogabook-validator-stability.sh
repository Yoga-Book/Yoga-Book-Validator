#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

readonly topology_path=/lib/firmware/intel/sof-tplg/sof-cht-rt5677.tplg
readonly firmware_path=/lib/firmware/intel/sof/sof-cht.ri
readonly ucm_alias_path=/usr/share/alsa/ucm2/conf.d/SOF/LENOVO-LenovoYB1_X91L-X91L.conf
state_dir=${YBV_STABILITY_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/yogabook-validator/stability}

usage() {
	cat <<'EOF'
Usage:
  yogabook-validator stability start [BOOTS] [--output DIRECTORY]
  yogabook-validator stability check [--output DIRECTORY]
  yogabook-validator stability status

Commands:
  start   Validate the current baseline and arm tracking for three subsequent
          cold boots. BOOTS may be an integer from 1 through 20.
  check   Validate and count the current boot once. The boot ID must differ
          from the last baseline or counted boot.
  status  Show progress without changing state.

The command never reboots, suspends, changes GRUB, or modifies hardware policy.
Run it as the logged-in desktop user after each physical power-off/power-on.
EOF
}

die() {
	echo "ERROR: $*" >&2
	exit 2
}

state_path() {
	printf '%s/%s\n' "$state_dir" "$1"
}

read_state() {
	local name=$1 path
	path=$(state_path "$name")
	[[ -r $path ]] || die "stability state is incomplete; run 'stability start'"
	head -n 1 -- "$path"
}

write_state() {
	local name=$1 value=$2 temporary
	mkdir -p -m 0700 -- "$state_dir"
	temporary=$(mktemp "$state_dir/.${name}.XXXXXX")
	printf '%s\n' "$value" >"$temporary"
	chmod 0600 "$temporary"
	mv -f -- "$temporary" "$(state_path "$name")"
}

sha256_file() {
	sha256sum -- "$1" | awk '{print $1}'
}

current_boot_id() {
	local boot_id
	boot_id=$(ybv_read_first /proc/sys/kernel/random/boot_id)
	[[ -n $boot_id ]] || die 'the current boot ID is unavailable'
	printf '%s\n' "$boot_id"
}

running_kernel() {
	printf '%s\n' "${YBV_STABILITY_KERNEL_RELEASE:-$(uname -r)}"
}

emit_artifact() {
	local check_id=$1 label=$2 path=$3 expected=${4:-} actual
	path=$(ybv_path "$path")
	if [[ ! -s $path ]]; then
		ybv_emit stability "$check_id" FAIL "$label is missing" "$path"
		return
	fi
	actual=$(sha256_file "$path")
	if [[ -z $expected || $actual == "$expected" ]]; then
		ybv_emit stability "$check_id" PASS "$label is present and unchanged" "sha256=$actual"
	else
		ybv_emit stability "$check_id" FAIL "$label changed from the armed baseline" "expected=$expected actual=$actual"
	fi
}

validate_current_boot() {
	local phase=$1 output_dir=$2 expected_boot=${3:-} expected_kernel=${4:-}
	local expected_topology=${5:-} expected_firmware=${6:-}
	local boot_id kernel topology firmware alias dsp_driver modules card_number kernel_log fatal
	local ucm_verbs real_user pipewire_status

	boot_id=$(current_boot_id)
	kernel=$(running_kernel)
	topology=$(ybv_path "$topology_path")
	firmware=$(ybv_path "$firmware_path")
	alias=$(ybv_path "$ucm_alias_path")

	ybv_begin_report "stability-$phase" "$output_dir"
	if ybv_require_x91l; then
		ybv_emit stability dmi PASS 'Lenovo Yoga Book YB1-X91L detected'
	else
		ybv_emit stability dmi FAIL 'Cold-boot stability tracking is restricted to Lenovo YB1-X91L'
	fi

	if [[ -z $expected_boot ]]; then
		ybv_emit stability boot-id PASS 'Captured the baseline boot ID' "$boot_id"
	elif [[ $boot_id != "$expected_boot" ]]; then
		ybv_emit stability boot-id PASS 'A new boot ID is present' "previous=$expected_boot current=$boot_id"
	else
		ybv_emit stability boot-id FAIL 'This boot was already used as the baseline or counted once' "$boot_id"
	fi

	if [[ -z $expected_kernel || $kernel == "$expected_kernel" ]]; then
		ybv_emit stability kernel PASS 'Running kernel matches the armed baseline' "$kernel"
	else
		ybv_emit stability kernel FAIL 'Running kernel changed from the armed baseline' "expected=$expected_kernel actual=$kernel"
	fi

	emit_artifact topology 'SOF topology' "$topology_path" "$expected_topology"
	emit_artifact firmware 'SOF firmware' "$firmware_path" "$expected_firmware"

	if [[ -L $alias ]] && readlink -e -- "$alias" >/dev/null; then
		ybv_emit stability ucm-alias PASS 'SOF UCM alias resolves' "$(readlink -- "$alias")"
	else
		ybv_emit stability ucm-alias FAIL 'SOF UCM alias is missing or broken' "$alias"
	fi

	card_number=$(ybv_find_card_number 2>/dev/null || true)
	if [[ -n $card_number ]]; then
		ybv_emit stability alsa-card PASS 'Yoga Book ALSA card is present' "card=$card_number"
	else
		ybv_emit stability alsa-card FAIL 'Yoga Book ALSA card is missing'
	fi
	if [[ $YBV_SYSROOT != / ]]; then
		ybv_emit stability ucm-import SKIP 'Live Yoga Book UCM import is unavailable'
	elif [[ -n $card_number ]] && ybv_has_command alsaucm; then
		ucm_verbs=$(timeout 10 alsaucm -c hw:yogabook list _verbs 2>&1 || true)
		if grep -Fq HiFi <<<"$ucm_verbs"; then
			ybv_emit stability ucm-import PASS 'Yoga Book UCM imports without changing the active verb' 'HiFi'
		else
			ybv_emit stability ucm-import FAIL 'Yoga Book UCM does not expose the HiFi verb' "$(head -n 1 <<<"$ucm_verbs")"
		fi
	else
		ybv_emit stability ucm-import FAIL 'Yoga Book UCM import cannot be tested'
	fi

	dsp_driver=$(ybv_read_first /sys/module/snd_intel_dspcfg/parameters/dsp_driver)
	modules=$(ybv_path /proc/modules)
	if [[ $dsp_driver == 3 ]]; then
		ybv_emit stability sof-selection PASS 'SOF is explicitly selected' 'dsp_driver=3'
	elif [[ $dsp_driver == 0 && -n $card_number && -s $firmware && -s $topology && -r $modules ]] &&
		grep -q '^snd_sof' "$modules"; then
		ybv_emit stability sof-selection PASS 'Automatic DSP selection resolved to SOF' 'dsp_driver=0'
	else
		ybv_emit stability sof-selection FAIL 'SOF selection could not be proven' "dsp_driver=${dsp_driver:-unavailable}"
	fi

	if [[ $YBV_SYSROOT != / ]]; then
		ybv_emit stability pipewire SKIP 'Live PipeWire session inspection is unavailable'
	elif ybv_has_command wpctl; then
		real_user=$(ybv_real_user)
		pipewire_status=$(ybv_run_as_user "$real_user" timeout 10 wpctl status 2>&1 || true)
		if grep -Fq 'Built-in Audio Stereo Speakers' <<<"$pipewire_status" &&
			grep -Fq 'Built-in Audio Internal Digital Microphone on DMIC1' <<<"$pipewire_status"; then
			ybv_emit stability pipewire PASS 'PipeWire exposes the Yoga Book speaker and internal microphone'
		else
			ybv_emit stability pipewire FAIL 'PipeWire does not expose both Yoga Book audio endpoints'
		fi
		printf '\n===== PipeWire =====\n%s\n' "$pipewire_status" >>"$YBV_LOG"
	else
		ybv_emit stability pipewire FAIL 'wpctl is unavailable'
	fi

	if [[ $YBV_SYSROOT != / ]]; then
		ybv_emit stability kernel-events SKIP 'Live current-boot kernel journal inspection is unavailable'
	elif ! ybv_has_command journalctl; then
		ybv_emit stability kernel-events SKIP 'journalctl is unavailable'
	elif kernel_log=$(journalctl -b -k --no-pager 2>/dev/null); then
		fatal=$(grep -Ei 'sof.*(ipc|firmware|topology).*(error|fail|timeout)|STREAM_PCM_PARAMS.*(error|fail)|BUG:|kernel panic|Call Trace:|I/O error.*(mmc|nvme)' <<<"$kernel_log" || true)
		if [[ -z $fatal ]]; then
			ybv_emit stability kernel-events PASS 'No current-boot SOF, kernel or storage fatal signature was found'
		else
			ybv_emit stability kernel-events FAIL 'A current-boot fatal signature was found' "$(head -n 1 <<<"$fatal")"
		fi
	else
		ybv_emit stability kernel-events WARN 'Current-boot kernel journal is not readable by this user'
	fi

	YBV_PHYSICAL_RESULT=PENDING
	ybv_finish_report
}

command_start() {
	local boots=3 output_dir= baseline_boot baseline_kernel topology firmware report_rc=0

	if (($# > 0)) && [[ $1 != --* ]]; then
		boots=$1
		shift
	fi
	while (($#)); do
		case $1 in
		--output) [[ $# -ge 2 ]] || die '--output requires a directory'; output_dir=$2; shift 2 ;;
		*) die "unknown start option: $1" ;;
		esac
	done
	[[ $boots =~ ^[1-9][0-9]*$ ]] && ((boots <= 20)) || die 'BOOTS must be an integer from 1 through 20'

	baseline_boot=$(current_boot_id)
	baseline_kernel=$(running_kernel)
	topology=$(ybv_path "$topology_path")
	firmware=$(ybv_path "$firmware_path")
	validate_current_boot baseline "$output_dir" || report_rc=$?
	((report_rc == 0)) || return "$report_rc"

	rm -f -- "$(state_path last-passed-at)"
	write_state target "$boots"
	write_state passed 0
	write_state last-boot-id "$baseline_boot"
	write_state kernel "$baseline_kernel"
	write_state topology-sha256 "$(sha256_file "$topology")"
	write_state firmware-sha256 "$(sha256_file "$firmware")"
	write_state started-at "$(date --iso-8601=seconds)"
	printf 'COLD_BOOT_STABILITY: ARMED 0/%s\n' "$boots"
}

command_check() {
	local output_dir= target passed previous_boot expected_kernel expected_topology expected_firmware
	local current report_rc=0

	while (($#)); do
		case $1 in
		--output) [[ $# -ge 2 ]] || die '--output requires a directory'; output_dir=$2; shift 2 ;;
		*) die "unknown check option: $1" ;;
		esac
	done
	target=$(read_state target)
	passed=$(read_state passed)
	previous_boot=$(read_state last-boot-id)
	expected_kernel=$(read_state kernel)
	expected_topology=$(read_state topology-sha256)
	expected_firmware=$(read_state firmware-sha256)
	[[ $target =~ ^[1-9][0-9]*$ && $passed =~ ^[0-9]+$ && $passed -le $target ]] || die 'stability state is invalid'
	((passed < target)) || die "cold-boot stability is already complete ($passed/$target)"

	validate_current_boot cold-boot "$output_dir" "$previous_boot" "$expected_kernel" \
		"$expected_topology" "$expected_firmware" || report_rc=$?
	((report_rc == 0)) || return "$report_rc"
	current=$(current_boot_id)
	passed=$((passed + 1))
	write_state passed "$passed"
	write_state last-boot-id "$current"
	write_state last-passed-at "$(date --iso-8601=seconds)"
	if ((passed == target)); then
		printf 'COLD_BOOT_STABILITY: PASS %s/%s\n' "$passed" "$target"
	else
		printf 'COLD_BOOT_STABILITY: IN_PROGRESS %s/%s\n' "$passed" "$target"
	fi
}

command_status() {
	local target passed
	if [[ ! -r $(state_path target) ]]; then
		echo 'COLD_BOOT_STABILITY: NOT_STARTED'
		return
	fi
	target=$(read_state target)
	passed=$(read_state passed)
	printf 'COLD_BOOT_STABILITY: %s/%s\n' "$passed" "$target"
	printf 'Started: %s\n' "$(read_state started-at)"
	printf 'Expected kernel: %s\n' "$(read_state kernel)"
	printf 'Last counted boot: %s\n' "$(read_state last-boot-id)"
}

action=${1:-}
[[ -n $action ]] || { usage >&2; exit 2; }
shift
case $action in
	start) command_start "$@" ;;
	check) command_check "$@" ;;
	status) [[ $# -eq 0 ]] || die 'status takes no options'; command_status ;;
	-h | --help | help) usage ;;
	*) usage >&2; die "unknown stability command: $action" ;;
esac
