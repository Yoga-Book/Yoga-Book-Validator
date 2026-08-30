#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

# Enforce the temporary analogue playback ceiling used by every audible probe.
# The caller must save the complete ALSA state and register restoration first.
ybv_enforce_playback_level_cap() {
	local log_file=$1
	local master_left='' master_right='' dac_left='' dac_right=''

	read -r master_left master_right < <(
		amixer -c yogabook cget name='1 Master Playback Volume' 2>>"$log_file" |
			sed -n 's/.*values=\([0-9][0-9]*\),\([0-9][0-9]*\).*/\1 \2/p'
	) || true
	read -r dac_left dac_right < <(
		amixer -c yogabook cget name='DAC1 Playback Volume' 2>>"$log_file" |
			sed -n 's/.*values=\([0-9][0-9]*\),\([0-9][0-9]*\).*/\1 \2/p'
	) || true

	[[ $master_left =~ ^[0-9]+$ && $master_right =~ ^[0-9]+$ &&
		$dac_left =~ ^[0-9]+$ && $dac_right =~ ^[0-9]+$ ]] || return 1
	((master_left <= 24)) || master_left=24
	((master_right <= 24)) || master_right=24
	((dac_left <= 87)) || dac_left=87
	((dac_right <= 87)) || dac_right=87

	amixer -c yogabook cset name='1 Master Playback Volume' \
		"$master_left,$master_right" >>"$log_file" 2>&1 || return 1
	amixer -c yogabook cset name='DAC1 Playback Volume' \
		"$dac_left,$dac_right" >>"$log_file" 2>&1 || return 1
	amixer -c yogabook cget name='1 Master Playback Volume' 2>>"$log_file" |
		grep -Fq "values=$master_left,$master_right" || return 1
	amixer -c yogabook cget name='DAC1 Playback Volume' 2>>"$log_file" |
		grep -Fq "values=$dac_left,$dac_right" || return 1

	printf 'master=%s,%s/32 (max -16 dB) dac1=%s,%s/127 (max 0 dB) tone=8%%\n' \
		"$master_left" "$master_right" "$dac_left" "$dac_right"
}
