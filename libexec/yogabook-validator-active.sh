#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

[[ $EUID -eq 0 ]] || { echo 'ERROR: active tests must run as root' >&2; exit 2; }
action=${1:-}
[[ -n $action ]] || { echo 'ERROR: missing active test name' >&2; exit 2; }
shift

category_name=
if [[ $action == category ]]; then
	category_name=${1:-}
	[[ -n $category_name ]] || { echo 'ERROR: category requires a name' >&2; exit 2; }
	shift
fi

output_dir=
cancel_file=
assume_yes=false
include_suspend=false
suspend_seconds=8
mode_timeout=90
while (($#)); do
	case $1 in
	--output)
		[[ $# -ge 2 ]] || { echo 'ERROR: --output requires a directory' >&2; exit 2; }
		output_dir=$2; shift 2 ;;
	--cancel-file)
		[[ $# -ge 2 ]] || { echo 'ERROR: --cancel-file requires a path' >&2; exit 2; }
		cancel_file=$2; shift 2 ;;
	--yes) assume_yes=true; shift ;;
	--include-suspend)
		[[ $action == automated ]] || { echo 'ERROR: --include-suspend is valid only for automated' >&2; exit 2; }
		include_suspend=true; shift ;;
	--seconds)
		[[ $# -ge 2 ]] || { echo 'ERROR: --seconds requires a value' >&2; exit 2; }
		suspend_seconds=$2; shift 2 ;;
	--timeout)
		[[ $action == modes || $action == rotation || $action == headset ]] || { echo 'ERROR: --timeout is valid only for modes, rotation or headset' >&2; exit 2; }
		[[ $# -ge 2 ]] || { echo 'ERROR: --timeout requires a value' >&2; exit 2; }
		mode_timeout=$2; shift 2 ;;
	*)
		if [[ $action == suspend && $1 =~ ^[1-9][0-9]*$ ]]; then suspend_seconds=$1; shift
		else echo "ERROR: unknown option: $1" >&2; exit 2
		fi ;;
	esac
done
[[ $suspend_seconds =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: suspend duration must be a positive integer' >&2; exit 2; }
[[ $mode_timeout =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: mode transition timeout must be a positive integer' >&2; exit 2; }

case $action in
audio)
	prompt='This test temporarily takes exclusive control of Yoga Book audio, plays a quiet one-second tone, and records the internal microphone.' ;;
automated)
	if [[ $include_suspend == true ]]; then
		prompt='This suite runs every automated transport check, including platform health, camera routing, haptics, lights, LTE, wireless, storage, audible audio and an eight-second suspend/resume cycle.'
	else
		prompt='This suite runs every automated transport check, including platform health, camera routing, haptics, lights, LTE, wireless, storage and audible audio; suspend remains opt-in.'
	fi ;;
category)
	case $category_name in
	recommended)
		prompt='This category runs the optimized union of the automated, full-passive, and quick-audit workflows without repeating their overlapping checks.' ;;
	audio-media)
		prompt='This category runs display inspection, both camera captures, reversible light checks, internal audio and a conditional wired-headset test in a safe sequence.' ;;
	input-modes)
		prompt='This interactive category inspects input capabilities, pulses both haptics, then guides you through keyboard, pen, and all four display orientations.' ;;
	platform-power)
		prompt='This category runs the read-only platform, resource, power, thermal, and sensor checks as one report.' ;;
	connectivity-storage)
		prompt='This category tests USB, an existing LTE session and wireless, reads the SD card, then performs the bounded 64 KiB write, verify, synchronize, and delete check.' ;;
	reliability)
		prompt='This category runs the suspend/resume test, then starts, advances, or confirms completion of cold-boot tracking according to its persistent state.' ;;
	*) echo "ERROR: unsupported category: $category_name" >&2; exit 2 ;;
	esac ;;
camera)
	prompt='This test pauses the desktop camera processor, captures three private AtomISP frames from each sensor, checks rear focus, then restores the original route and processor state.' ;;
haptics)
	prompt='This test plays one bounded 150 ms moderate-strength pulse on each Halo haptic actuator.' ;;
headset)
	prompt="This test requires a connected four-pole headset. It plays one quiet one-second tone only through the headphones, records three seconds from the headset microphone, then asks for one unplug, reinsert and button cycle within ${mode_timeout} seconds. Speakers remain muted and all audio state is restored." ;;
inputs)
	prompt='This test reads kernel input capability maps without grabbing devices, monitoring events, or injecting input.' ;;
lights)
	prompt='This test makes one-step changes to panel and platform light brightness, then restores every brightness and trigger value.' ;;
modes)
	prompt='This test observes one physical Halo keyboard to Wacom pen to Halo keyboard mode cycle. It does not read or record input events.' ;;
quiet)
	prompt='This suite runs every non-audible automated diagnostic, including cameras, input capabilities, lights, radios and read-only storage. It excludes playback, capture, haptics, suspend and guided workflows.' ;;
rotation)
	prompt='This test observes a Halo-to-pen mode cycle while you rotate the tablet through all four cardinal orientations and return it upright. It does not change display policy or read input events.' ;;
storage)
	prompt='This test reads the inserted SD card and mounts its filesystems read-only, then restores their original mount state.' ;;
storage-write)
	prompt='This test writes, verifies, synchronizes and deletes one 64 KiB temporary file on each writable SD filesystem, then restores its original mount state.' ;;
suspend)
	prompt="This test takes exclusive control of audio and suspends the tablet for ${suspend_seconds} seconds." ;;
wireless)
	prompt='This test verifies Wi-Fi gateway transport, briefly scans with Bluetooth, and restores the original Bluetooth block and power state.' ;;
*) echo "ERROR: unsupported active test: $action" >&2; exit 2 ;;
esac

if [[ $assume_yes != true ]]; then
	[[ -t 0 ]] || { echo 'ERROR: confirmation is required; use --yes after reviewing the operation' >&2; exit 2; }
	printf '%s Continue? [y/N] ' "$prompt"
	read -r answer
	[[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]] || exit 2
fi

ybv_require_x91l || { echo 'ERROR: active tests are restricted to Lenovo YB1-X91L' >&2; exit 2; }
if [[ $action == haptics || $action == inputs || $action == modes || $action == rotation ]]; then
	ybv_has_command python3 || { echo 'ERROR: missing command: python3' >&2; exit 2; }
elif [[ $action == automated || $action == camera || $action == category || $action == lights || $action == quiet || $action == storage || $action == storage-write || $action == wireless ]]; then
	:
else
	for required in alsactl alsaucm amixer aplay arecord pactl parec pw-play wpctl systemctl timeout python3; do
		ybv_has_command "$required" || { echo "ERROR: missing command: $required" >&2; exit 2; }
	done
	[[ $action != suspend ]] || ybv_has_command rtcwake || { echo 'ERROR: missing command: rtcwake' >&2; exit 2; }
fi

real_user=$(ybv_real_user)
if [[ $real_user == root || -z $real_user ]] || ! id "$real_user" >/dev/null 2>&1; then
	real_user=
fi
if [[ -n $real_user ]]; then
	real_uid=$(id -u "$real_user")
	real_home=$(getent passwd "$real_user" | cut -d: -f6)
	if [[ -z $output_dir ]]; then
		output_dir="/var/tmp/yogabook-validator-${real_uid}/${action}-$(date +%Y%m%d-%H%M%S)"
	fi
	canonical_output=$(realpath -m -- "$output_dir")
	case $canonical_output in
	"${real_home%/}"/* | "/var/tmp/yogabook-validator-${real_uid}"/*) ;;
	*) echo 'ERROR: active report output must be inside the invoking user home or private /var/tmp results directory' >&2; exit 2 ;;
	esac
	output_dir=$canonical_output
	if ! ybv_run_as_user "$real_user" mkdir -p -- "$output_dir"; then
		echo 'ERROR: invoking user cannot create the active report directory' >&2
		exit 2
	fi
fi

if [[ -n $cancel_file ]]; then
	canonical_cancel=$(realpath -m -- "$cancel_file")
	case $canonical_cancel in
	"${output_dir%/}"/*) ;;
	*) echo 'ERROR: cancellation file must be inside the report directory' >&2; exit 2 ;;
	esac
	cancel_file=$canonical_cancel
	owner_pid=$$
	owner_pgid=$(ps -o pgid= -p "$owner_pid" | tr -d '[:space:]')
	[[ $owner_pgid == "$owner_pid" ]] || {
		echo 'ERROR: cancellable active tests require a dedicated process group' >&2
		exit 2
	}
	# The cancellation supervisor expands its positional parameters, not the
	# active test's variables in this parent shell.
	# shellcheck disable=SC2016
	setsid bash -c '
		owner_pid=$1
		owner_pgid=$2
		cancel_file=$3
		while owner_state=$(ps -o stat= -p "$owner_pid" 2>/dev/null) && [[ -n $owner_state && $owner_state != Z* ]]; do
			if [[ -e $cancel_file ]]; then
				printf "CANCELLATION_REQUESTED: stopping the active test and restoring hardware state\n"
				rm -f -- "$cancel_file"
				kill -TERM -- "-$owner_pgid" 2>/dev/null || true
				for _ in {1..150}; do
					owner_state=$(ps -o stat= -p "$owner_pid" 2>/dev/null || true)
					[[ -n $owner_state && $owner_state != Z* ]] || exit 0
					sleep 0.2
				done
				kill -KILL -- "-$owner_pgid" 2>/dev/null || true
				exit 0
			fi
			sleep 0.2
		done
	' _ "$owner_pid" "$owner_pgid" "$cancel_file" &
fi

if [[ $action == automated ]]; then
	automated_args=(--output "$output_dir")
	[[ $include_suspend == true ]] && automated_args+=(--include-suspend)
	exec env YBV_ACTIVE_DISPATCH=1 "$LIBEXEC_DIR/yogabook-validator-automated.sh" "${automated_args[@]}"
fi

if [[ $action == quiet ]]; then
	exec env YBV_ACTIVE_DISPATCH=1 "$LIBEXEC_DIR/yogabook-validator-quiet.sh" --output "$output_dir"
fi

if [[ $action == category ]]; then
	exec env YBV_ACTIVE_DISPATCH=1 "$LIBEXEC_DIR/yogabook-validator-category.sh" "$category_name" --output "$output_dir"
fi

if [[ $action == camera ]]; then
	exec env YBV_ACTIVE_DISPATCH=1 "$LIBEXEC_DIR/yogabook-validator-camera.sh" --yes --output "$output_dir"
fi

if [[ $action == inputs || $action == lights || $action == modes || $action == rotation || $action == storage || $action == storage-write || $action == wireless ]]; then
	active_args=(--output "$output_dir")
	[[ $action == modes || $action == rotation ]] && active_args+=(--timeout "$mode_timeout")
	if [[ $action == rotation ]]; then
		exec env YBV_ACTIVE_DISPATCH=1 "$LIBEXEC_DIR/yogabook-validator-modes.sh" --all-orientations "${active_args[@]}"
	fi
	if [[ $action == storage-write ]]; then
		exec env YBV_ACTIVE_DISPATCH=1 "$LIBEXEC_DIR/yogabook-validator-storage.sh" --write-test "${active_args[@]}"
	fi
	exec env YBV_ACTIVE_DISPATCH=1 "$LIBEXEC_DIR/yogabook-validator-$action.sh" "${active_args[@]}"
fi

ybv_begin_report "$action" "$output_dir"

finish_report_for_user() {
	local finish_rc=0
	YBV_PHYSICAL_RESULT=PENDING
	ybv_finish_report || finish_rc=$?
	if [[ -n $real_user && -d $YBV_REPORT_DIR ]]; then
		ybv_chown_tree_to_user "$real_user" "$YBV_REPORT_DIR" 2>/dev/null || true
	fi
	return "$finish_rc"
}

if [[ $action == haptics ]]; then
	run_haptic() {
		local label=$1 path=$2 details
		if details=$(python3 - "$path" 2>&1 <<'PY'
import sys
import time

from evdev import InputDevice, ecodes, ff

path = sys.argv[1]
device = InputDevice(path)
effect_id = None
try:
    capabilities = device.capabilities(verbose=False).get(ecodes.EV_FF, [])
    if ecodes.FF_RUMBLE not in capabilities:
        raise RuntimeError("FF_RUMBLE is unavailable")
    effect = ff.Effect(
        ecodes.FF_RUMBLE,
        -1,
        0,
        ff.Trigger(0, 0),
        ff.Replay(150, 0),
        ff.EffectType(
            ff_rumble_effect=ff.Rumble(
                strong_magnitude=0x5000,
                weak_magnitude=0,
            )
        ),
    )
    effect_id = device.upload_effect(effect)
    device.write(ecodes.EV_FF, effect_id, 1)
    time.sleep(0.25)
    device.write(ecodes.EV_FF, effect_id, 0)
    print(f"{device.name} at {path}; 150 ms, magnitude 0x5000")
finally:
    if effect_id is not None:
        try:
            device.write(ecodes.EV_FF, effect_id, 0)
            device.erase_effect(effect_id)
        except OSError:
            pass
    device.close()
PY
		); then
			ybv_emit input "haptic-$label" PASS "$label Halo haptic actuator accepted a bounded force-feedback effect" "$details"
		else
			ybv_emit input "haptic-$label" FAIL "$label Halo haptic actuator test failed" "$details"
		fi
	}
	for haptic in left right; do
		device="/dev/${haptic}_vibrator"
		if [[ -e $device ]]; then
			run_haptic "$haptic" "$device"
		else
			ybv_emit input "haptic-$haptic" FAIL "$haptic Halo haptic device is missing" "$device"
		fi
		sleep 0.35
	done
	finish_rc=0
	finish_report_for_user || finish_rc=$?
	exit "$finish_rc"
fi

card_number=$(ybv_find_card_number || true)
if [[ -z $card_number ]]; then
	ybv_emit audio alsa-card FAIL 'ALSA card ID yogabook is missing'
	finish_report_for_user || true
	exit 1
fi

if [[ $action == headset ]]; then
	headphone_inserted=false
	microphone_inserted=false
	amixer -c yogabook cget name='Headphone Jack' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' && headphone_inserted=true
	amixer -c yogabook cget name='Headset Mic Jack' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' && microphone_inserted=true
	if [[ $headphone_inserted != true || $microphone_inserted != true ]]; then
		ybv_emit audio headset-playback SKIP 'No connected four-pole headset is available for playback validation' "headphone=$headphone_inserted microphone=$microphone_inserted"
		ybv_emit audio headset-capture SKIP 'No connected four-pole headset is available for microphone validation' "headphone=$headphone_inserted microphone=$microphone_inserted"
		ybv_emit input headset-events SKIP 'Connect a four-pole headset to validate jack and button events' "headphone=$headphone_inserted microphone=$microphone_inserted"
		finish_rc=0
		finish_report_for_user || finish_rc=$?
		exit "$finish_rc"
	fi
fi

state_file="$YBV_REPORT_DIR/alsa-state"
capture_file="$YBV_REPORT_DIR/mic1.wav"
[[ $action != headset ]] || capture_file="$YBV_REPORT_DIR/headset-mic.wav"
tone_file="$YBV_REPORT_DIR/tone.wav"
silence_file="$YBV_REPORT_DIR/silence.wav"
desktop_probe_file="$YBV_REPORT_DIR/desktop-monitor.raw"
wireplumber_stopped=false
state_saved=false
playback_pid=
capture_pid=
desktop_ready_seconds=
desktop_recovery_used=false
desktop_card=
desktop_profile=
playback_log="$YBV_REPORT_DIR/suspend-playback.log"
capture_log="$YBV_REPORT_DIR/suspend-capture.log"

python3 - "$tone_file" "$silence_file" <<'PY'
import math, struct, sys, wave
rate = 48000
with wave.open(sys.argv[1], "wb") as wav:
    wav.setparams((2, 2, rate, rate, "NONE", "not compressed"))
    for i in range(rate):
        value = int(0.08 * 32767 * math.sin(2 * math.pi * 440 * i / rate))
        wav.writeframesraw(struct.pack("<hh", value, value))
with wave.open(sys.argv[2], "wb") as wav:
    wav.setparams((2, 2, rate, rate, "NONE", "not compressed"))
    wav.writeframes(b"\0" * rate * 2 * 2)
PY

desktop_audio_probe() {
	local monitor_pid playback_probe_pid playback_rc=0 monitor_rc=0
	local default_sink='' sink_running=false pcm_running=false signal='' probe_asset="$tone_file" route='speakers' probe_bytes=0
	[[ $action != headset ]] || probe_asset=$silence_file

	: >"$desktop_probe_file"
	default_sink=$(ybv_run_as_user "$real_user" timeout 3 pactl get-default-sink 2>/dev/null) || return 1
	ybv_run_as_user "$real_user" timeout 5 parec --device="${default_sink}.monitor" \
		--format=s16le --rate=48000 --channels=2 --raw >"$desktop_probe_file" 2>>"$YBV_LOG" &
	monitor_pid=$!
	sleep 0.5
	ybv_run_as_user "$real_user" timeout 5 pw-play "$probe_asset" >>"$YBV_LOG" 2>&1 &
	playback_probe_pid=$!
	for _ in {1..20}; do
		if ybv_run_as_user "$real_user" timeout 2 pactl list sinks short 2>/dev/null |
			awk -v sink="$default_sink" '$2 == sink && $NF == "RUNNING" { found=1 } END { exit !found }'; then
			sink_running=true
		fi
		if grep -Fq 'state: RUNNING' "/proc/asound/card${card_number}/pcm0p/sub0/status" 2>/dev/null; then
			pcm_running=true
		fi
		[[ $sink_running == true && $pcm_running == true ]] && break
		sleep 0.1
	done
	wait "$playback_probe_pid" || playback_rc=$?
	wait "$monitor_pid" || monitor_rc=$?
	[[ $monitor_rc -eq 0 || $monitor_rc -eq 124 ]] || return 1
	[[ $playback_rc -eq 0 && $sink_running == true && $pcm_running == true ]] || return 1
	case $desktop_profile in
	*Headphones* | *Headset*)
		route=headphones
		amixer -c yogabook cget name='Headphone Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' || return 1
		amixer -c yogabook cget name='Speaker Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(off|0)' || return 1
		;;
	*)
		amixer -c yogabook cget name='Speaker Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' || return 1
		;;
	esac
	case $desktop_profile in
	*Mic1*)
		amixer -c yogabook cget name='Int Mic Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' || return 1
		amixer -c yogabook cget name='Sto1 ADC MIXL ADC2 Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' || return 1
		amixer -c yogabook cget name='Sto1 ADC MIXR ADC2 Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' || return 1
		;;
	*Headset*)
		amixer -c yogabook cget name='Headset Mic Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' || return 1
		amixer -c yogabook cget name='Sto1 ADC MIXL ADC1 Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' || return 1
		amixer -c yogabook cget name='Sto1 ADC MIXR ADC1 Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' || return 1
		;;
	esac
	if [[ $action == headset ]]; then
		probe_bytes=$(wc -c <"$desktop_probe_file")
		((probe_bytes > 0)) || return 1
		signal="bytes=$probe_bytes silent=yes"
	else
		signal=$(python3 - "$desktop_probe_file" <<'PY'
import math, struct, sys
raw = open(sys.argv[1], "rb").read()
samples = struct.unpack(f"<{len(raw)//2}h", raw) if raw else ()
peak = max(map(abs, samples), default=0)
rms = math.sqrt(sum(x*x for x in samples) / len(samples)) if samples else 0
print(f"bytes={len(raw)} peak={peak} rms={rms:.2f}")
raise SystemExit(0 if peak and rms else 1)
PY
		) || return 1
	fi
	printf 'desktop probe: sink=RUNNING pcm0=RUNNING route=%s %s\n' "$route" "$signal" >>"$YBV_LOG"
}

restore_state() {
	local pid attempt restore_rc=0 desktop_rc=1 consecutive_ready desktop_wait_started
	for pid in "$playback_pid" "$capture_pid"; do
		[[ -n $pid ]] || continue
		kill -TERM "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	if [[ $state_saved == true ]]; then
		alsactl -f "$state_file" restore yogabook >/dev/null 2>&1 || restore_rc=1
	fi
	if [[ $wireplumber_stopped == true && -n $real_user ]]; then
		for attempt in 1 2; do
			if ((attempt == 2)); then
				desktop_recovery_used=true
				ybv_capture 'Desktop audio probe failure before retry' \
					ybv_run_as_user "$real_user" timeout 3 wpctl status
			fi
			desktop_rc=0
			# Restart the complete graph so desktop clients reconnect instead of
			# retaining stale nodes from the period without a session manager.
			ybv_run_as_user "$real_user" systemctl --user restart \
				pipewire.service pipewire-pulse.service wireplumber.service >/dev/null 2>&1 || desktop_rc=1
			if [[ -n $desktop_profile && $desktop_profile != off ]]; then
				profile_ready=false
				for _ in {1..30}; do
					if ybv_run_as_user "$real_user" timeout 2 pactl list cards short 2>/dev/null |
						awk -v card="$desktop_card" '$2 == card { found=1 } END { exit !found }'; then
						profile_ready=true
						break
					fi
					sleep 0.2
				done
				if [[ $profile_ready == true ]]; then
					# Replay the UCM device enable sequences after restoring the raw
					# mixer snapshot, even when WirePlumber retained the same profile.
					ybv_run_as_user "$real_user" pactl set-card-profile \
						"$desktop_card" off >/dev/null 2>&1 || desktop_rc=1
					ybv_run_as_user "$real_user" pactl set-card-profile \
						"$desktop_card" "$desktop_profile" >/dev/null 2>&1 || desktop_rc=1
				else
					desktop_rc=1
				fi
			fi
			desktop_ready_seconds=
			consecutive_ready=0
			desktop_wait_started=$SECONDS
			for _ in {1..60}; do
				if ybv_run_as_user "$real_user" timeout 2 wpctl status 2>/dev/null |
					grep -Fq 'Built-in Audio'; then
					consecutive_ready=$((consecutive_ready + 1))
					if ((consecutive_ready >= 3)); then
						desktop_ready_seconds=$((SECONDS - desktop_wait_started))
						break
					fi
				else
					consecutive_ready=0
				fi
				sleep 1
			done
			[[ -n $desktop_ready_seconds ]] || desktop_rc=1
			((desktop_rc != 0)) || desktop_audio_probe || desktop_rc=1
			((desktop_rc == 0)) && break
		done
		((desktop_rc == 0)) || restore_rc=1
	fi
	if [[ -n $real_user && -d $YBV_REPORT_DIR ]]; then
		ybv_chown_tree_to_user "$real_user" "$YBV_REPORT_DIR" 2>/dev/null || true
	fi
	return "$restore_rc"
}
ybv_register_restore_callback restore_state
trap 'restore_state || true' EXIT INT TERM

# Save before stopping WirePlumber: closing its UCM session temporarily disables
# output routes, and saving after that point would persist a muted speaker.
if alsactl -f "$state_file" store yogabook; then
	state_saved=true
	ybv_emit audio state-snapshot PASS 'Saved live ALSA state before stopping desktop audio'
else
	ybv_emit audio state-snapshot FAIL 'Could not save live ALSA state'
	ybv_finish_report
	exit 1
fi

if [[ -n $real_user ]]; then
	desktop_cards=$(ybv_run_as_user "$real_user" timeout 3 pactl list cards 2>/dev/null || true)
	desktop_card=$(awk '
		/^[[:space:]]*Name:/ { card=$2 }
		/^[[:space:]]*alsa\.id = "yogabook"$/ { print card; exit }
	' <<<"$desktop_cards")
	desktop_profile=$(awk -v target="$desktop_card" '
		/^[[:space:]]*Name:/ { in_card=($2 == target); next }
		in_card && /^[[:space:]]*Active Profile:/ {
				sub(/^[[:space:]]*Active Profile:[[:space:]]*/, "")
				print
				exit
			}
	' <<<"$desktop_cards")
	if [[ -z $desktop_card || -z $desktop_profile ]]; then
		ybv_emit audio desktop-profile FAIL 'Could not save the active Yoga Book desktop audio profile'
		ybv_finish_report
		exit 1
	fi
	ybv_emit audio desktop-profile PASS 'Saved the active Yoga Book desktop audio profile' "$desktop_card profile=$desktop_profile"
fi

if [[ -n $real_user ]]; then
	# WirePlumber owns the ALSA/UCM nodes. Stopping only the session manager
	# releases the PCM devices; restoration later resets the complete graph so
	# existing desktop clients cannot retain stale links.
	ybv_run_as_user "$real_user" systemctl --user stop wireplumber || true
	wireplumber_stopped=true
	sleep 2
fi

if ybv_has_command fuser && fuser /dev/snd/pcm* >/dev/null 2>&1; then
	ybv_capture 'PCM users after stopping desktop audio' fuser -v /dev/snd/pcm*
	ybv_emit audio exclusive-access FAIL 'A PCM device remains open'
	ybv_finish_report
	exit 1
else
	ybv_emit audio exclusive-access PASS 'No competing PCM client remains'
fi

if [[ $action == headset ]]; then
	ucm_playback=Headphones
	ucm_capture=Headset
else
	ucm_playback=Speaker1
	ucm_capture=Mic1
fi
if alsaucm -c hw:yogabook set _verb HiFi set _enadev "$ucm_playback" set _enadev "$ucm_capture" >>"$YBV_LOG" 2>&1; then
	ybv_emit audio ucm-routes PASS "Enabled HiFi $ucm_playback and $ucm_capture routes"
else
	ybv_emit audio ucm-routes FAIL 'Could not enable UCM audio routes'
fi

if [[ $action != suspend ]]; then
	master_left='' master_right='' dac_left='' dac_right=''
	read -r master_left master_right < <(
		amixer -c yogabook cget name='1 Master Playback Volume' 2>>"$YBV_LOG" |
			sed -n 's/.*values=\([0-9][0-9]*\),\([0-9][0-9]*\).*/\1 \2/p'
	) || true
	read -r dac_left dac_right < <(
		amixer -c yogabook cget name='DAC1 Playback Volume' 2>>"$YBV_LOG" |
			sed -n 's/.*values=\([0-9][0-9]*\),\([0-9][0-9]*\).*/\1 \2/p'
	) || true
	if [[ $master_left =~ ^[0-9]+$ && $master_right =~ ^[0-9]+$ &&
		$dac_left =~ ^[0-9]+$ && $dac_right =~ ^[0-9]+$ ]]; then
		((master_left > 24)) && master_left=24
		((master_right > 24)) && master_right=24
		((dac_left > 87)) && dac_left=87
		((dac_right > 87)) && dac_right=87
	fi
	if [[ $master_left =~ ^[0-9]+$ && $master_right =~ ^[0-9]+$ &&
		$dac_left =~ ^[0-9]+$ && $dac_right =~ ^[0-9]+$ ]] &&
		amixer -c yogabook cset name='1 Master Playback Volume' "$master_left,$master_right" >>"$YBV_LOG" 2>&1 &&
		amixer -c yogabook cset name='DAC1 Playback Volume' "$dac_left,$dac_right" >>"$YBV_LOG" 2>&1 &&
		amixer -c yogabook cget name='1 Master Playback Volume' 2>>"$YBV_LOG" |
			grep -Fq "values=$master_left,$master_right" &&
		amixer -c yogabook cget name='DAC1 Playback Volume' 2>>"$YBV_LOG" |
			grep -Fq "values=$dac_left,$dac_right"; then
		ybv_emit audio playback-level-cap PASS 'Capped active-test playback below the saved user level' \
			"master=$master_left,$master_right/32 (max -16 dB) dac1=$dac_left,$dac_right/127 (max 0 dB) tone=8%"
	else
		ybv_emit audio playback-level-cap FAIL 'Could not enforce the bounded active-test playback level'
		ybv_finish_report
		exit 1
	fi
fi

if [[ $action == suspend ]]; then
	if amixer -c yogabook cset name='Speaker Switch' off >>"$YBV_LOG" 2>&1 &&
		amixer -c yogabook cget name='Speaker Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(off|0)'; then
		ybv_emit suspend speaker-muted PASS 'Muted the physical speaker during the direct suspend transport stream'
	else
		ybv_emit suspend speaker-muted FAIL 'Could not mute the physical speaker before suspend'
		ybv_finish_report
		exit 1
	fi
fi

run_pcm() {
	local id=$1 summary=$2
	shift 2
	if timeout 15 "$@" >>"$YBV_LOG" 2>&1; then
		ybv_emit audio "$id" PASS "$summary"
	else
		ybv_emit audio "$id" FAIL "$summary failed"
	fi
}

if [[ $action == audio ]]; then
	for format in S16_LE S24_LE S32_LE; do
		run_pcm "pcm0-play-${format,,}" "PCM0 playback opens as $format, 48 kHz stereo" \
			aplay -q -D hw:yogabook,0 -t raw -f "$format" -r 48000 -c 2 -d 1 /dev/zero
		run_pcm "pcm0-capture-${format,,}" "PCM0 capture opens as $format, 48 kHz stereo" \
			arecord -q -D hw:yogabook,0 -t raw -f "$format" -r 48000 -c 2 -d 1 /dev/null
	done
	run_pcm pcm1-deep-buffer 'PCM1 deep-buffer playback opens at 48 kHz stereo' \
		aplay -q -D hw:yogabook,1 -t raw -f S32_LE -r 48000 -c 2 -d 1 /dev/zero

	if timeout 15 aplay -q -D hw:yogabook,0 "$tone_file" >>"$YBV_LOG" 2>&1; then
		ybv_emit audio speaker-tone PASS 'Played bounded one-second 440 Hz tone at 8% digital amplitude'
	else
		# PCM1 teardown can transiently race the following PCM0 write on this
		# SOF IPC3 platform. Preserve that evidence and distinguish recovery
		# from a persistent playback failure.
		sleep 1
		if timeout 15 aplay -q -D hw:yogabook,0 "$tone_file" >>"$YBV_LOG" 2>&1; then
			ybv_emit audio speaker-tone-retry WARN 'PCM0 tone recovered on one retry after the deep-buffer transition'
		else
			ybv_emit audio speaker-tone FAIL 'Bounded speaker tone failed twice after the deep-buffer transition'
		fi
	fi
	run_pcm mic-capture 'Recorded three-second Mic1 WAV' \
		arecord -q -D hw:yogabook,0 -t wav -f S16_LE -r 48000 -c 2 -d 3 "$capture_file"
	if [[ -s $capture_file ]]; then
		if signal=$(python3 - "$capture_file" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], "rb") as wav:
    frames = wav.readframes(wav.getnframes())
samples = struct.unpack(f"<{len(frames)//2}h", frames) if frames else ()
peak = max(map(abs, samples), default=0)
rms = math.sqrt(sum(x*x for x in samples) / len(samples)) if samples else 0
print(f"peak={peak} ({peak/32768:.6f} FS), rms={rms:.2f} ({rms/32768:.6f} FS)")
raise SystemExit(0 if peak and rms else 1)
PY
		); then
			ybv_emit audio mic-signal PASS 'Mic1 capture contains a non-empty signal' "$signal"
		else
			ybv_emit audio mic-signal FAIL 'Mic1 capture is digitally empty' "${signal:-no samples}"
		fi
	else
		ybv_emit audio mic-signal FAIL 'Mic1 WAV was not created'
	fi
elif [[ $action == headset ]]; then
	headset_route_ready=true
	amixer -c yogabook cget name='Speaker Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(off|0)' || headset_route_ready=false
	amixer -c yogabook cget name='Headphone Switch' 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' || headset_route_ready=false
	if [[ $headset_route_ready == true ]] && timeout 15 aplay -q -D hw:yogabook,0 "$tone_file" >>"$YBV_LOG" 2>&1; then
		ybv_emit audio headset-playback PASS 'Headphone-only UCM route played a bounded one-second tone' '440 Hz, 8% digital amplitude; speakers=off'
	else
		ybv_emit audio headset-playback FAIL 'Headphone-only playback route or bounded tone failed' "route-ready=$headset_route_ready"
	fi

	headset_capture_ready=true
	for control in 'Headset Mic Switch' 'Sto1 ADC MIXL ADC1 Switch' 'Sto1 ADC MIXR ADC1 Switch'; do
		amixer -c yogabook cget name="$control" 2>>"$YBV_LOG" | grep -Eq 'values=(on|1)' || headset_capture_ready=false
	done
	if [[ $headset_capture_ready == true ]] &&
		timeout 15 arecord -q -D hw:yogabook,0 -t wav -f S16_LE -r 48000 -c 2 -d 3 "$capture_file" >>"$YBV_LOG" 2>&1 &&
		[[ -s $capture_file ]]; then
		if signal=$(python3 - "$capture_file" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], "rb") as wav:
    frames = wav.readframes(wav.getnframes())
samples = struct.unpack(f"<{len(frames)//2}h", frames) if frames else ()
peak = max(map(abs, samples), default=0)
rms = math.sqrt(sum(x*x for x in samples) / len(samples)) if samples else 0
clipped = sum(abs(x) >= 32760 for x in samples) / len(samples) if samples else 1
print(f"peak={peak} ({peak/32768:.6f} FS), rms={rms:.2f} ({rms/32768:.6f} FS), clipped={clipped:.6f}")
raise SystemExit(0 if peak >= 32 and rms >= 1 and clipped < 0.05 else 1)
PY
		); then
			ybv_emit audio headset-capture PASS 'Headset microphone capture contains a plausible non-clipped signal' "$signal"
		else
			ybv_emit audio headset-capture FAIL 'Headset microphone capture is empty, implausibly weak or clipped' "${signal:-no samples}"
		fi
	else
		ybv_emit audio headset-capture FAIL 'Headset microphone route or three-second capture failed' "route-ready=$headset_capture_ready"
	fi

	printf 'ACTION_REQUIRED: Unplug the wired headset, reinsert it fully, then press one headset media or volume button within %s seconds. Leave it inserted.\n' "$mode_timeout" | tee -a "$YBV_LOG"
	headset_event_rc=0
	headset_event_details=$(timeout "$((mode_timeout + 5))" python3 \
		"$LIBEXEC_DIR/yogabook-validator-headset-events.py" --timeout "$mode_timeout" 2>>"$YBV_LOG") || headset_event_rc=$?
	if ((headset_event_rc == 0)); then
		ybv_emit input headset-events PASS 'Observed headset removal, reinsertion and a supported button press' "$headset_event_details"
	else
		ybv_emit input headset-events FAIL 'Headset event cycle did not complete with the jack reinserted' "exit=$headset_event_rc ${headset_event_details:-no events}"
	fi
else
	stream_seconds=$((suspend_seconds + 14))
	test_start=$(date --iso-8601=seconds)
	timeout "$((stream_seconds + 10))" aplay -q -D hw:yogabook,0 -t raw -f S32_LE -r 48000 -c 2 -d "$stream_seconds" /dev/zero >"$playback_log" 2>&1 &
	playback_pid=$!
	timeout "$((stream_seconds + 10))" arecord -q -D hw:yogabook,0 -t raw -f S32_LE -r 48000 -c 2 -d "$stream_seconds" /dev/null >"$capture_log" 2>&1 &
	capture_pid=$!
	sleep 3
	if kill -0 "$playback_pid" 2>/dev/null && kill -0 "$capture_pid" 2>/dev/null; then
		ybv_emit suspend streams-before PASS 'Full-duplex streams remained active before suspend'
	else
		ybv_emit suspend streams-before FAIL 'Full-duplex streams exited before suspend'
	fi
	if rtcwake -m mem -s "$suspend_seconds" >>"$YBV_LOG" 2>&1; then
		ybv_emit suspend rtcwake PASS 'Tablet resumed from suspend' "${suspend_seconds}s requested"
	else
		ybv_emit suspend rtcwake FAIL 'rtcwake suspend/resume failed'
	fi
	if wait "$playback_pid"; then ybv_emit suspend playback-after PASS 'Playback completed after resume'; else ybv_emit suspend playback-after FAIL 'Playback failed across suspend'; fi
	playback_pid=
	if wait "$capture_pid"; then ybv_emit suspend capture-after PASS 'Capture completed after resume'; else ybv_emit suspend capture-after FAIL 'Capture failed across suspend'; fi
	capture_pid=
	{
		printf '\n===== Suspend playback client =====\n'
		cat "$playback_log"
		printf '\n===== Suspend capture client =====\n'
		cat "$capture_log"
	} >>"$YBV_LOG"
	xrun_count=$(awk 'BEGIN { IGNORECASE=1 } /underrun|overrun/ { count++ } END { print count + 0 }' "$playback_log" "$capture_log")
	if ((xrun_count > 0)); then
		xrun_details=$(awk 'BEGIN { IGNORECASE=1 } /underrun|overrun/ { print; if (++count == 2) exit }' "$playback_log" "$capture_log" | tr '\n' ' ')
		ybv_emit suspend stream-xruns WARN 'Direct ALSA streams recovered after suspend with xruns' "events=$xrun_count ${xrun_details% }"
	else
		ybv_emit suspend stream-xruns PASS 'Direct ALSA streams resumed without reporting an xrun'
	fi
	journal_slice=$(journalctl -k --since "$test_start" --no-pager 2>&1 || true)
	printf '\n===== Suspend test kernel journal =====\n%s\n' "$journal_slice" >>"$YBV_LOG"
	fatal=$(grep -Ei 'TRIG_STOP|unexpected fault|ipc.*(error|fail|timeout)|STREAM_PCM_PARAMS.*(-110|error|fail)|error: ipc' <<<"$journal_slice" || true)
	if [[ -z $fatal ]]; then
		ybv_emit suspend fatal-scan PASS 'No SOF/IPC fatal signature appeared during the test'
	else
		ybv_emit suspend fatal-scan FAIL 'SOF/IPC fatal signature appeared during the test' "$(head -n1 <<<"$fatal")"
	fi
fi

# Restore now so its outcome is part of the report; the EXIT trap is a second
# idempotent safety net for interruption and unexpected failures.
if restore_state; then
	state_saved=false
	wireplumber_stopped=false
	if [[ -n $real_user ]]; then
		if [[ $desktop_recovery_used == true ]]; then
			ybv_emit audio desktop-recovery WARN 'Desktop playback required a second full audio-graph restart'
		fi
		if [[ $action == headset ]]; then
			ybv_emit audio state-restore PASS 'Restored ALSA state and verified silent desktop playback transport through the original sink' "ready after ${desktop_ready_seconds}s"
		else
			ybv_emit audio state-restore PASS 'Restored ALSA state and verified desktop playback through the original sink' "ready after ${desktop_ready_seconds}s"
		fi
	else
		ybv_emit audio state-restore PASS 'Restored ALSA state; no desktop user services were managed'
	fi
else
	ybv_emit audio state-restore FAIL 'ALSA state or desktop audio service restoration failed; EXIT trap will retry'
fi
finish_rc=0
finish_report_for_user || finish_rc=$?
exit "$finish_rc"
