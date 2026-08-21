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

declare -a ids=(speakers headphones internal-microphone headset-microphone jack-detection headset-buttons halo-keys halo-touchpad halo-haptics pen-direction pen-pressure display-touch auto-rotation front-camera rear-camera lte-data gnss suspend-resume charging)
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
	'Pen directions match the display in all axes'
	'Pen pressure works in a drawing application'
	'Display touchscreen works in keyboard and pen modes'
	'Display rotates correctly and returns to landscape'
	'Front camera produces a usable image'
	'Rear camera produces a usable image'
	'LTE data connects (skip when no SIM is installed)'
	'GNSS receives satellites outdoors'
	'Suspend/resume preserves working hardware'
	'Battery charges and reports plausible state'
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
