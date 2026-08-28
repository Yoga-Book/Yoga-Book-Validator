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
	printf '%s' 'This test briefly switches the AtomISP route, analyzes three frames from each camera in memory, moves rear focus by one step, and restores all state without saving images. Continue? [y/N] '
	read -r answer
	[[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]] || exit 2
fi

ybv_require_x91l || { echo 'ERROR: camera tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }
for required in media-ctl python3 v4l2-ctl; do
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
focus_device=$(sed -n '/entity .*: wv517s 2-000c/,/^- entity /s/.*device node name \(\/dev\/v4l-subdev[0-9][0-9]*\).*/\1/p' <<<"$media_graph" | head -n 1)
isp_device=$(sed -n '/entity .*: Atom ISP (/,/^- entity /s/.*device node name \(\/dev\/v4l-subdev[0-9][0-9]*\).*/\1/p' <<<"$media_graph" | head -n 1)
if [[ -n $focus_device && -e $focus_device ]]; then
	ybv_emit camera focus-actuator PASS 'WV517S rear-camera focus actuator is present' "$focus_device"
else
	ybv_emit camera focus-actuator FAIL 'WV517S rear-camera focus actuator is missing'
fi
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

original_run_mode=
if [[ -n $isp_device && -e $isp_device ]]; then
	original_run_mode=$(v4l2-ctl -d "$isp_device" --get-ctrl=atomisp_run_mode 2>>"$YBV_LOG" |
		sed -n 's/^atomisp_run_mode:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
fi

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
focus_original=
focus_changed=false
restore_focus() {
	local restored
	[[ $focus_changed == true ]] || return 0
	v4l2-ctl -d "$focus_device" --set-ctrl="focus_absolute=$focus_original" >>"$YBV_LOG" 2>&1 || return 1
	restored=$(v4l2-ctl -d "$focus_device" --get-ctrl=focus_absolute 2>>"$YBV_LOG" |
		sed -n 's/^focus_absolute:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p')
	[[ $restored == "$focus_original" ]] || return 1
	focus_changed=false
}
restore_camera_state() {
	local restore_rc=0
	restore_focus || restore_rc=1
	restore_route || restore_rc=1
	if [[ -n $original_run_mode ]]; then
		v4l2-ctl -d "$isp_device" --set-ctrl="atomisp_run_mode=$original_run_mode" >>"$YBV_LOG" 2>&1 || restore_rc=1
	fi
	return "$restore_rc"
}
trap 'restore_camera_state || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

select_route() {
	local port=$1
	set_link 0 0
	set_link 1 0
	set_link "$port" 1
}

test_camera() {
	local id=$1 label=$2 port=$3 expected=$4 pixel_format=$5 width=$6 height=$7 stride=$8 frame_size=$9
	local input
	local capture_result stream_status signal_status stream_details signal_details
	if ! select_route "$port"; then
		ybv_emit camera "$id-route" FAIL "Could not select the $label route"
		return
	fi
	if [[ -z $isp_device || ! -e $isp_device ]] ||
		! v4l2-ctl -d "$isp_device" --set-ctrl=atomisp_run_mode=2 >>"$YBV_LOG" 2>&1; then
		ybv_emit camera "$id-stream" FAIL "$label raw capture could not be configured"
		ybv_emit camera "$id-signal" SKIP "$label signal integrity was not analyzed"
		return
	fi
	input=$(v4l2-ctl -d "$video_device" --all 2>&1 | sed -n 's/^[[:space:]]*Video input[[:space:]]*:[[:space:]]*//p' | head -n 1)
	if [[ $input == *"$expected"* ]]; then
		ybv_emit camera "$id-route" PASS "$label route selects $expected" "$input"
	else
		ybv_emit camera "$id-route" FAIL "$label route did not select $expected" "$input"
	fi
	capture_result=$(python3 "$LIBEXEC_DIR/yogabook-validator-camera-capture.py" \
		"$video_device" "$width" "$height" "$stride" "$frame_size" 3 "$pixel_format" 2>>"$YBV_LOG" || true)
	IFS=$'\t' read -r stream_status signal_status stream_details signal_details <<<"$capture_result"
	case $stream_status in
	PASS) ybv_emit camera "$id-stream" PASS "$label delivered three complete frames" "$stream_details" ;;
	*) ybv_emit camera "$id-stream" FAIL "$label frame capture failed" "${stream_details:-analyzer produced no result}" ;;
	esac
	case $signal_status in
	PASS) ybv_emit camera "$id-signal" PASS "$label frames contain changing luminance data" "$signal_details" ;;
	WARN) ybv_emit camera "$id-signal" WARN "$label frames may be dark or unusually flat" "$signal_details" ;;
	SKIP) ybv_emit camera "$id-signal" SKIP "$label signal integrity was not analyzed" "$signal_details" ;;
	*) ybv_emit camera "$id-signal" FAIL "$label frames are frozen or invalid" "${signal_details:-analyzer produced no result}" ;;
	esac
}

test_focus() {
	local control_info minimum maximum step target changed
	if [[ -z $focus_device || ! -e $focus_device ]]; then
		ybv_emit camera focus-control FAIL 'Rear-camera focus control could not be exercised'
		return
	fi
	control_info=$(v4l2-ctl -d "$focus_device" --list-ctrls 2>>"$YBV_LOG" |
		sed -n '/focus_absolute/p' | head -n 1)
	if [[ $control_info =~ min=(-?[0-9]+).*max=(-?[0-9]+).*step=([0-9]+) ]]; then
		minimum=${BASH_REMATCH[1]}
		maximum=${BASH_REMATCH[2]}
		step=${BASH_REMATCH[3]}
	else
		ybv_emit camera focus-control FAIL 'Rear-camera focus range is unavailable'
		return
	fi
	focus_original=$(v4l2-ctl -d "$focus_device" --get-ctrl=focus_absolute 2>>"$YBV_LOG" |
		sed -n 's/^focus_absolute:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p')
	if [[ ! $focus_original =~ ^-?[0-9]+$ || $step -le 0 ]]; then
		ybv_emit camera focus-control FAIL 'Rear-camera focus position is invalid' "value=${focus_original:-unreadable}"
		return
	fi
	if ((focus_original + step <= maximum)); then
		target=$((focus_original + step))
	elif ((focus_original - step >= minimum)); then
		target=$((focus_original - step))
	else
		ybv_emit camera focus-control FAIL 'Rear-camera focus range has no safe adjacent step' "min=$minimum max=$maximum value=$focus_original step=$step"
		return
	fi
	focus_changed=true
	if v4l2-ctl -d "$focus_device" --set-ctrl="focus_absolute=$target" >>"$YBV_LOG" 2>&1; then
		changed=$(v4l2-ctl -d "$focus_device" --get-ctrl=focus_absolute 2>>"$YBV_LOG" |
			sed -n 's/^focus_absolute:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p')
	else
		changed=
	fi
	if [[ $changed == "$target" ]]; then
		ybv_emit camera focus-control PASS 'Rear-camera focus accepted one bounded step' "$focus_original->$target range=$minimum..$maximum"
	else
		ybv_emit camera focus-control FAIL 'Rear-camera focus did not accept one bounded step' "expected=$target actual=${changed:-unreadable}"
	fi
	if restore_focus; then
		ybv_emit camera focus-restore PASS 'Restored the original rear-camera focus position' "$focus_original"
	else
		ybv_emit camera focus-restore FAIL 'Could not restore the original rear-camera focus position' "$focus_original"
	fi
}

test_camera front 'Front camera' 0 ov2740 BA10 1932 1092 4096 4472832
test_camera rear 'Rear camera' 1 ov8858 BG10 1632 1224 3328 4075520
test_focus

if restore_camera_state; then
	ybv_emit camera route-restore PASS 'Restored the original AtomISP camera route' "front=$front_was_enabled rear=$rear_was_enabled"
	trap - EXIT INT TERM
else
	ybv_emit camera route-restore FAIL 'Could not restore the original AtomISP camera route'
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
