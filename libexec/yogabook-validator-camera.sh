#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

output_dir=
assume_yes=false
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	--yes) assume_yes=true; shift ;;
	-h | --help) echo 'Usage: yogabook-validator camera [--yes] [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done

if [[ $assume_yes != true ]]; then
	[[ -t 0 ]] || { echo 'ERROR: confirmation is required; use --yes after reviewing the operation' >&2; exit 2; }
	printf '%s' 'This test briefly switches the AtomISP route, captures three frames from each camera to /dev/null, and restores the original route. Continue? [y/N] '
	read -r answer
	[[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]] || exit 2
fi

ybv_require_x91l || { echo 'ERROR: camera tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }
for required in media-ctl timeout v4l2-ctl; do
	ybv_has_command "$required" || { echo "ERROR: missing command: $required" >&2; exit 2; }
done

ybv_begin_report camera "$output_dir"
media_device=
media_graph=
for candidate in /dev/media*; do
	[[ -e $candidate ]] || continue
	graph=$(media-ctl -d "$candidate" --print-topology 2>&1 || true)
	if grep -Fq 'driver          atomisp-isp2' <<<"$graph"; then
		media_device=$candidate
		media_graph=$graph
		break
	fi
done

video_device=$(sed -n '/entity .*: ATOMISP video output/,/entity /s/.*device node name \(\/dev\/video[0-9][0-9]*\).*/\1/p' <<<"$media_graph" | head -n 1)
if [[ -z $media_device || -z $video_device || ! -e $video_device ]]; then
	ybv_emit camera atomisp FAIL 'AtomISP media and video devices could not be discovered'
	ybv_finish_report
	exit 1
fi
ybv_emit camera atomisp PASS 'AtomISP capture devices are present' "$media_device $video_device"

for identity in 'ov2740 2-0010' 'ov8858 2-0036'; do
	if grep -Fq "$identity" <<<"$media_graph"; then
		ybv_emit camera "sensor-${identity%% *}" PASS "$identity is present in the media graph"
	else
		ybv_emit camera "sensor-${identity%% *}" FAIL "$identity is missing from the media graph"
	fi
done
printf '\n===== Original media topology =====\n%s\n' "$media_graph" >>"$YBV_LOG"

link_enabled() {
	local port=$1
	awk -v entity="ATOM ISP CSI2-port${port}" '
		$0 ~ "entity [0-9]+: " entity {inside=1; next}
		inside && /^- entity / {inside=0}
		inside && /-> "Atom ISP":0 \[ENABLED\]/ {found=1}
		END {exit !found}
	' <<<"$media_graph"
}

front_was_enabled=false
rear_was_enabled=false
link_enabled 0 && front_was_enabled=true
link_enabled 1 && rear_was_enabled=true

set_link() {
	local port=$1 enabled=$2
	media-ctl -d "$media_device" --links "\"ATOM ISP CSI2-port${port}\":1 -> \"Atom ISP\":0 [$enabled]" >>"$YBV_LOG" 2>&1
}

restore_route() {
	local restore_rc=0
	set_link 0 0 || restore_rc=1
	set_link 1 0 || restore_rc=1
	if [[ $front_was_enabled == true ]]; then set_link 0 1 || restore_rc=1; fi
	if [[ $rear_was_enabled == true ]]; then set_link 1 1 || restore_rc=1; fi
	return "$restore_rc"
}
trap 'restore_route || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

select_route() {
	local port=$1
	set_link 0 0
	set_link 1 0
	set_link "$port" 1
}

test_camera() {
	local id=$1 label=$2 port=$3 expected=$4 input
	if ! select_route "$port"; then
		ybv_emit camera "$id-route" FAIL "Could not select the $label route"
		return
	fi
	input=$(v4l2-ctl -d "$video_device" --all 2>&1 | sed -n 's/^[[:space:]]*Video input[[:space:]]*:[[:space:]]*//p' | head -n 1)
	if [[ $input == *"$expected"* ]]; then
		ybv_emit camera "$id-route" PASS "$label route selects $expected" "$input"
	else
		ybv_emit camera "$id-route" FAIL "$label route did not select $expected" "$input"
	fi
	if timeout 20 v4l2-ctl -d "$video_device" --stream-mmap=3 --stream-count=3 \
		--stream-to=/dev/null >>"$YBV_LOG" 2>&1; then
		ybv_emit camera "$id-stream" PASS "$label delivered three frames"
	else
		ybv_emit camera "$id-stream" FAIL "$label frame capture failed"
	fi
}

test_camera front 'Front camera' 0 ov2740
test_camera rear 'Rear camera' 1 ov8858

if restore_route; then
	ybv_emit camera route-restore PASS 'Restored the original AtomISP camera route' "front=$front_was_enabled rear=$rear_was_enabled"
	trap - EXIT INT TERM
else
	ybv_emit camera route-restore FAIL 'Could not restore the original AtomISP camera route'
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
