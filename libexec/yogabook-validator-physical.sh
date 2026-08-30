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

ybv_begin_report physical "$output_dir"
physical_file="$YBV_REPORT_DIR/physical-results.tsv"
printf 'check_id\tstatus\tnote\n' >"$physical_file"

declare -a ids=(speakers headphones internal-microphone headset-microphone jack-detection headset-buttons halo-keys halo-touchpad halo-haptics halo-backlight indicator-leds pen-direction pen-pressure display-touch display-stability auto-rotation display-brightness micro-hdmi front-camera rear-camera wifi bluetooth usb-otg sd-card hardware-buttons lid-switch lte-data gnss suspend-resume charging thermal-stability cold-boots reboot poweroff)
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
	'Display brightness changes smoothly under manual control'
	'Micro-HDMI outputs video and audio to an external display'
	'Front camera produces a usable image'
	'Rear camera produces a usable image'
	'Wi-Fi connects and transfers data reliably'
	'Bluetooth can discover, pair and exchange data or audio'
	'Micro-USB OTG detects and cleanly removes an attached device'
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

answer_for() {
	local id=$1 label=$2 status note line
	if [[ -n $answers_file ]]; then
		line=$(awk -F '\t' -v wanted="$id" '$1 == wanted {print $0; exit}' "$answers_file")
		status=$(cut -f2 <<<"$line")
		note=$(cut -f3- <<<"$line")
	else
		printf '\n%s [p=pass, f=fail, s=skip]: ' "$label" >/dev/tty
		read -r status </dev/tty
		printf 'Optional note: ' >/dev/tty
		read -r note </dev/tty
	fi
	case ${status,,} in
	p | pass) status=PASS ;;
	f | fail) status=FAIL ;;
	s | skip | '') status=SKIP ;;
	*) status=FAIL; note="invalid answer: $status ${note:-}" ;;
	esac
	printf '%s\t%s\t%s\n' "$id" "$status" "$(ybv_sanitize "${note:-}")" >>"$physical_file"
	ybv_emit physical "$id" "$status" "$label" "${note:-}"
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
