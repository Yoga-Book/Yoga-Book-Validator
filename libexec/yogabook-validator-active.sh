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

output_dir=
assume_yes=false
include_suspend=false
suspend_seconds=8
mode_timeout=90
while (($#)); do
	case $1 in
	--output)
		[[ $# -ge 2 ]] || { echo 'ERROR: --output requires a directory' >&2; exit 2; }
		output_dir=$2; shift 2 ;;
	--yes) assume_yes=true; shift ;;
	--include-suspend)
		[[ $action == automated ]] || { echo 'ERROR: --include-suspend is valid only for automated' >&2; exit 2; }
		include_suspend=true; shift ;;
	--seconds)
		[[ $# -ge 2 ]] || { echo 'ERROR: --seconds requires a value' >&2; exit 2; }
		suspend_seconds=$2; shift 2 ;;
	--timeout)
		[[ $action == modes ]] || { echo 'ERROR: --timeout is valid only for modes' >&2; exit 2; }
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
		prompt='This suite runs every automated transport check, including platform health, camera routing, haptics, lights, wireless, storage, audible audio and an eight-second suspend/resume cycle.'
	else
		prompt='This suite runs every automated transport check, including platform health, camera routing, haptics, lights, wireless, storage and audible audio; suspend remains opt-in.'
	fi ;;
haptics)
	prompt='This test plays one bounded 150 ms moderate-strength pulse on each Halo haptic actuator.' ;;
inputs)
	prompt='This test reads kernel input capability maps without grabbing devices, monitoring events, or injecting input.' ;;
lights)
	prompt='This test makes one-step changes to panel and platform light brightness, then restores every brightness and trigger value.' ;;
modes)
	prompt='This test observes one physical Halo keyboard to Wacom pen to Halo keyboard mode cycle. It does not read or record input events.' ;;
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
if [[ $action == haptics || $action == inputs || $action == modes ]]; then
	ybv_has_command python3 || { echo 'ERROR: missing command: python3' >&2; exit 2; }
elif [[ $action == automated || $action == lights || $action == storage || $action == storage-write || $action == wireless ]]; then
	:
else
	for required in alsactl alsaucm aplay arecord timeout python3; do
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

if [[ $action == automated ]]; then
	automated_args=(--output "$output_dir")
	[[ $include_suspend == true ]] && automated_args+=(--include-suspend)
	exec env YBV_ACTIVE_DISPATCH=1 "$LIBEXEC_DIR/yogabook-validator-automated.sh" "${automated_args[@]}"
fi

if [[ $action == inputs || $action == lights || $action == modes || $action == storage || $action == storage-write || $action == wireless ]]; then
	active_args=(--output "$output_dir")
	[[ $action == modes ]] && active_args+=(--timeout "$mode_timeout")
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

state_file="$YBV_REPORT_DIR/alsa-state"
capture_file="$YBV_REPORT_DIR/mic1.wav"
wireplumber_stopped=false
state_saved=false
playback_pid=
capture_pid=
desktop_ready_seconds=

restore_state() {
	local pid restore_rc=0
	for pid in "$playback_pid" "$capture_pid"; do
		[[ -n $pid ]] || continue
		kill -TERM "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	if [[ $state_saved == true ]]; then
		alsactl -f "$state_file" restore yogabook >/dev/null 2>&1 || restore_rc=1
	fi
	if [[ $wireplumber_stopped == true && -n $real_user ]]; then
		ybv_run_as_user "$real_user" systemctl --user start wireplumber >/dev/null 2>&1 || restore_rc=1
		if ybv_has_command wpctl; then
			consecutive_ready=0
			desktop_wait_started=$SECONDS
			for _ in {1..30}; do
				if ybv_run_as_user "$real_user" timeout 2 wpctl status 2>/dev/null |
					grep -Fq 'Built-in Audio Stereo Speakers'; then
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
			[[ -n $desktop_ready_seconds ]] || restore_rc=1
		else
			restore_rc=1
		fi
	fi
	if [[ -n $real_user && -d $YBV_REPORT_DIR ]]; then
		ybv_chown_tree_to_user "$real_user" "$YBV_REPORT_DIR" 2>/dev/null || true
	fi
	return "$restore_rc"
}
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
	# WirePlumber owns the ALSA/UCM nodes. Stopping only the session manager
	# releases the PCM devices while keeping PipeWire's RTKit-initialized engine
	# alive, avoiding a minute-long desktop audio restart on this platform.
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

if alsaucm -c hw:yogabook set _verb HiFi set _enadev Speaker1 set _enadev Mic1 >>"$YBV_LOG" 2>&1; then
	ybv_emit audio ucm-routes PASS 'Enabled HiFi Speaker1 and Mic1 routes'
else
	ybv_emit audio ucm-routes FAIL 'Could not enable UCM audio routes'
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

	tone_file="$YBV_REPORT_DIR/tone.wav"
	python3 - "$tone_file" <<'PY'
import math, struct, sys, wave
rate = 48000
with wave.open(sys.argv[1], "wb") as wav:
    wav.setparams((2, 2, rate, rate, "NONE", "not compressed"))
    for i in range(rate):
        value = int(0.08 * 32767 * math.sin(2 * math.pi * 440 * i / rate))
        wav.writeframesraw(struct.pack("<hh", value, value))
PY
	run_pcm speaker-tone 'Played bounded one-second 440 Hz tone at 8% digital amplitude' \
		aplay -q -D hw:yogabook,0 "$tone_file"
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
else
	stream_seconds=$((suspend_seconds + 14))
	test_start=$(date --iso-8601=seconds)
	timeout "$((stream_seconds + 10))" aplay -q -D hw:yogabook,0 -t raw -f S32_LE -r 48000 -c 2 -d "$stream_seconds" /dev/zero &
	playback_pid=$!
	timeout "$((stream_seconds + 10))" arecord -q -D hw:yogabook,0 -t raw -f S32_LE -r 48000 -c 2 -d "$stream_seconds" /dev/null &
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
		ybv_emit audio state-restore PASS 'Restored ALSA state and verified the desktop speaker sink' "ready after ${desktop_ready_seconds}s"
	else
		ybv_emit audio state-restore PASS 'Restored ALSA state; no desktop user services were managed'
	fi
else
	ybv_emit audio state-restore FAIL 'ALSA state or desktop audio service restoration failed; EXIT trap will retry'
fi
finish_rc=0
finish_report_for_user || finish_rc=$?
exit "$finish_rc"
