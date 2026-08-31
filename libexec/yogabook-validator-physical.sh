#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

output_dir=
answers_file=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	--answers) [[ $# -ge 2 ]] || exit 2; answers_file=$2; shift 2 ;;
	-h | --help) echo 'Usage: yogabook-validator physical [--answers FILE] [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done
[[ -z $answers_file || -r $answers_file ]] || { echo "ERROR: answers file is unreadable: $answers_file" >&2; exit 2; }

declare -a ids=(speakers headphones internal-microphone headset-microphone jack-detection headset-buttons halo-keys halo-touchpad halo-haptics halo-backlight indicator-leds pen-direction pen-pressure display-touch display-stability auto-rotation ambient-light-response proximity-response hinge-angle display-brightness micro-hdmi front-camera rear-camera wifi bluetooth usb-otg internal-storage sd-card hardware-buttons lid-switch lte-data gnss suspend-resume charging thermal-stability cold-boots reboot poweroff)
declare -a labels=(
	'Stereo speakers play cleanly'
	'Headphones play cleanly'
	'Internal microphone records intelligibly'
	'Headset microphone records intelligibly'
	'Headset insertion/removal is detected'
	'Headset buttons work'
	'Halo keyboard keys map correctly'
	'Halo touchpad tracks and clicks correctly'
	'Both Halo haptic actuators respond'
	'Halo keyboard backlight brightness control works'
	'Indicator and charging LEDs visibly follow system and cable state'
	'Pen directions match the display in all axes'
	'Pen pressure works in a drawing application'
	'Display touchscreen works in keyboard and pen modes'
	'Display image remains stable without corruption or flicker'
	'Display rotates correctly and returns to landscape'
	'Shading and exposing the ambient-light sensors changes the reported light level'
	'Moving a hand near and away from the SX9310 changes its proximity state'
	'Opening and folding the Yoga Book changes both reported hinge angles consistently'
	'Display brightness changes smoothly under manual control'
	'Micro-HDMI outputs video and audio to an external display'
	'Front camera produces a usable image'
	'Rear camera produces a usable image'
	'Wi-Fi connects and transfers data reliably'
	'Bluetooth can discover, pair and exchange data or audio'
	'Micro-USB OTG detects and cleanly removes an attached device'
	'Applications can save and reopen data on internal storage across a cold boot'
	'Inserted SD card can be read and written'
	'Power and volume buttons generate the expected actions'
	'Lid or keyboard-cover state is detected correctly'
	'LTE data connects (skip when no SIM is installed)'
	'GNSS receives satellites outdoors'
	'Suspend/resume preserves working hardware'
	'Battery charges and reports plausible state'
	'Tablet remains thermally safe and stable under representative use'
	'Three physical cold boots return to the pinned Yoga Book kernel'
	'A physical reboot returns to a fully working desktop'
	'A full shutdown powers the tablet off cleanly'
)

declare -A validated_status=() validated_note=() validated_observed_at=()

validate_answers_file() {
	local file=$1 line=0 raw_line without_tabs tab_count id remainder status note observed_at expected_id normalized
	local -A expected=() seen=()
	for expected_id in "${ids[@]}"; do expected[$expected_id]=true; done
	while IFS= read -r raw_line || [[ -n ${raw_line:-} ]]; do
		line=$((line + 1))
		without_tabs=${raw_line//$'\t'/}
		tab_count=$((${#raw_line} - ${#without_tabs}))
		[[ $tab_count -eq 2 || $tab_count -eq 3 ]] || {
			echo "ERROR: answers file line $line must contain exactly three or four TSV fields" >&2
			return 1
		}
		id=${raw_line%%$'\t'*}
		remainder=${raw_line#*$'\t'}
		status=${remainder%%$'\t'*}
		note=${remainder#*$'\t'}
		observed_at=
		if [[ $tab_count -eq 3 ]]; then
			observed_at=${note#*$'\t'}
			note=${note%%$'\t'*}
		fi
		[[ -n ${id:-} && -v expected[$id] ]] || {
			echo "ERROR: answers file line $line has an unknown or empty check ID: ${id:-empty}" >&2
			return 1
		}
		[[ ! -v seen[$id] ]] || {
			echo "ERROR: answers file line $line duplicates check ID: $id" >&2
			return 1
		}
		seen[$id]=true
		case ${status,,} in
		p | pass) normalized=PASS ;;
		f | fail | s | skip)
			[[ ${note:-} =~ [^[:space:]] ]] || {
				echo "ERROR: $id requires a reason when marked ${status^^}" >&2
				return 1
			}
			[[ ${status,,} == f || ${status,,} == fail ]] && normalized=FAIL || normalized=SKIP
			;;
		*)
			echo "ERROR: answers file line $line has invalid status for $id: ${status:-empty}" >&2
			return 1
			;;
		esac
		[[ $note != *provenance_observed_at=* ]] || {
			echo "ERROR: $id note contains a reserved provenance field" >&2
			return 1
		}
		if [[ -n $observed_at && ! $observed_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)$ ]]; then
			echo "ERROR: $id has an invalid provenance observation timestamp" >&2
			return 1
		fi
		validated_status[$id]=$normalized
		validated_note[$id]=$note
		validated_observed_at[$id]=$observed_at
	done <"$file"
	for expected_id in "${ids[@]}"; do
		[[ -v seen[$expected_id] ]] || {
			echo "ERROR: answers file is missing an explicit result for $expected_id" >&2
			return 1
		}
	done
}

if [[ -n $answers_file ]]; then
	validate_answers_file "$answers_file" || exit 2
fi

ybv_begin_report physical "$output_dir"
physical_file="$YBV_REPORT_DIR/physical-results.tsv"
printf 'check_id\tstatus\tnote\n' >"$physical_file"

answer_for() {
	local id=$1 label=$2 status note observed_at details
	if [[ -n $answers_file ]]; then
		status=${validated_status[$id]}
		note=${validated_note[$id]}
		observed_at=${validated_observed_at[$id]}
	else
		while true; do
			printf '\n%s [p=pass, f=fail, s=not applicable]: ' "$label" >/dev/tty
			read -r status </dev/tty
			case ${status,,} in
			p | pass | f | fail | s | skip) break ;;
			*) printf 'Choose p, f or s; an explicit observation is required.\n' >/dev/tty ;;
			esac
		done
		case ${status,,} in
		f | fail | s | skip)
			while true; do
				printf 'Required reason/context: ' >/dev/tty
				read -r note </dev/tty
				[[ $note =~ [^[:space:]] ]] && break
				printf 'A reason is required for Fail and Not applicable.\n' >/dev/tty
			done
			;;
		*)
			printf 'Optional context: ' >/dev/tty
			read -r note </dev/tty
			;;
		esac
	fi
	if [[ -z $answers_file ]]; then
		case ${status,,} in
		p | pass) status=PASS ;;
		f | fail) status=FAIL ;;
		s | skip) status=SKIP ;;
		esac
	fi
	printf '%s\t%s\t%s\n' "$id" "$status" "$(ybv_sanitize "${note:-}")" >>"$physical_file"
	details=${note:-}
	if [[ -n ${observed_at:-} ]]; then
		details="${details:+$details }provenance_observed_at=$observed_at provenance_imported=true"
	fi
	ybv_emit physical "$id" "$status" "$label" "$details"
}

for index in "${!ids[@]}"; do answer_for "${ids[$index]}" "${labels[$index]}"; done

if awk -F '\t' '$2 == "FAIL" {found=1} END {exit !found}' "$physical_file"; then
	YBV_PHYSICAL_RESULT=FAIL
elif awk -F '\t' '$2 == "SKIP" {found=1} END {exit !found}' "$physical_file"; then
	YBV_PHYSICAL_RESULT=INCOMPLETE
else
	YBV_PHYSICAL_RESULT=PASS
fi
ybv_finish_report false
[[ $YBV_PHYSICAL_RESULT != FAIL ]]
