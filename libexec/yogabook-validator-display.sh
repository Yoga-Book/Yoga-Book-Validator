#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

output_dir=
while (($#)); do
	case $1 in
	--output)
		[[ $# -ge 2 ]] || { echo 'ERROR: --output requires a directory' >&2; exit 2; }
		output_dir=$2
		shift 2
		;;
	-h | --help)
		echo 'Usage: yogabook-validator display [--output DIRECTORY]'
		exit 0
		;;
	*)
		echo "ERROR: unknown option: $1" >&2
		exit 2
		;;
	esac
done

ybv_require_x91l || { echo 'ERROR: display validation is restricted to Lenovo YB1-X91L' >&2; exit 2; }
for required in busctl gsettings journalctl python3; do
	ybv_has_command "$required" || { echo "ERROR: missing command: $required" >&2; exit 2; }
done

desktop_user=$(ybv_real_user)
if [[ -z $desktop_user || $desktop_user == root ]] || ! id "$desktop_user" >/dev/null 2>&1; then
	echo 'ERROR: display validation must run from the active desktop user session' >&2
	exit 2
fi

ybv_begin_report display "$output_dir"

drm_card=
for candidate in /sys/class/drm/card[0-9]*; do
	[[ -d $candidate ]] || continue
	[[ ${candidate##*/} =~ ^card[0-9]+$ ]] || continue
	driver=$(basename "$(readlink -f "$candidate/device/driver" 2>/dev/null)" 2>/dev/null || true)
	if [[ $driver == i915 ]]; then
		drm_card=$candidate
		break
	fi
done
card_name=${drm_card##*/}
render_node=
if [[ -n $drm_card ]]; then
	card_device=$(readlink -f "$drm_card/device" 2>/dev/null || true)
	for candidate in /sys/class/drm/renderD*; do
		[[ -d $candidate ]] || continue
		if [[ $(readlink -f "$candidate/device" 2>/dev/null || true) == "$card_device" ]]; then
			render_node=${candidate##*/}
			break
		fi
	done
fi
if [[ -n $card_name && -n $render_node && -c /dev/dri/$card_name && -c /dev/dri/$render_node ]]; then
	ybv_emit display drm-driver PASS 'Intel display controller uses i915 and exposes card and render nodes' "$card_name $render_node"
else
	ybv_emit display drm-driver FAIL 'Intel display controller or DRM nodes are incomplete' "card=${card_name:-missing} render=${render_node:-missing}"
fi

dsi_connector=
for candidate in /sys/class/drm/card*-DSI-1; do
	[[ -d $candidate ]] || continue
	dsi_connector=$candidate
	break
done
if [[ -n $dsi_connector ]]; then
	dsi_status=$(ybv_read_first "$dsi_connector/status")
	dsi_enabled=$(ybv_read_first "$dsi_connector/enabled")
	dsi_modes=$(tr '\n' ' ' <"$dsi_connector/modes" 2>/dev/null || true)
	if [[ $dsi_status == connected && $dsi_enabled == enabled && $dsi_modes == *1200x1920* ]]; then
		ybv_emit display dsi-panel PASS 'Internal DSI panel is connected, enabled and exposes its native mode' '1200x1920'
	else
		ybv_emit display dsi-panel FAIL 'Internal DSI panel state or native mode is incorrect' "status=${dsi_status:-unknown} enabled=${dsi_enabled:-unknown} modes=${dsi_modes:-none}"
	fi
else
	ybv_emit display dsi-panel FAIL 'Internal DSI-1 connector is missing'
fi

mutter=$(ybv_mutter_state "$desktop_user" 2>>"$YBV_LOG" || true)
dsi_mutter=$(grep '^connector=DSI-1 ' <<<"$mutter" || true)
if [[ $dsi_mutter =~ ^connector=DSI-1\ mode=1920x1200@[^[:space:]]+\ transform=0\ primary=true\ scale=([0-9]+\.[0-9]+)$ ]]; then
	scale=${BASH_REMATCH[1]}
	if awk -v value="$scale" 'BEGIN {exit !(value >= 1.0 && value <= 3.0)}'; then
		ybv_emit display mutter-layout PASS 'Mutter exposes the built-in panel as the primary landscape display' "$dsi_mutter"
	else
		ybv_emit display mutter-layout FAIL 'Mutter display scale is outside the supported range' "$dsi_mutter"
	fi
else
	ybv_emit display mutter-layout FAIL 'Mutter logical display state is missing or not primary landscape' "${mutter:-unavailable}"
fi

shell_status=$(ybv_run_as_user "$desktop_user" busctl --user status org.gnome.Shell 2>>"$YBV_LOG" || true)
shell_pid=$(sed -n 's/^PID=//p' <<<"$shell_status" | head -n 1)
card_fds=0
render_fds=0
if [[ $shell_pid =~ ^[0-9]+$ && -d /proc/$shell_pid/fd ]]; then
	for fd in /proc/"$shell_pid"/fd/*; do
		target=$(readlink "$fd" 2>/dev/null || true)
		[[ $target == "/dev/dri/$card_name" ]] && card_fds=$((card_fds + 1))
		[[ $target == "/dev/dri/$render_node" ]] && render_fds=$((render_fds + 1))
	done
fi
if ((card_fds > 0 && render_fds > 0)); then
	ybv_emit display compositor-gpu PASS 'GNOME Shell is actively using i915 card and render nodes' "card-fds=$card_fds render-fds=$render_fds"
else
	ybv_emit display compositor-gpu FAIL 'GNOME Shell hardware-rendering access is not established' "pid=${shell_pid:-unknown} card-fds=$card_fds render-fds=$render_fds"
fi

backlight=/sys/class/backlight/intel_backlight
if [[ ! -d $backlight ]]; then
	for candidate in /sys/class/backlight/*; do
		[[ -d $candidate ]] || continue
		backlight=$candidate
		break
	done
fi
brightness=$(ybv_read_first "$backlight/brightness")
maximum=$(ybv_read_first "$backlight/max_brightness")
if [[ $brightness =~ ^[0-9]+$ && $maximum =~ ^[1-9][0-9]*$ ]] && ((brightness >= 0 && brightness <= maximum)); then
	ybv_emit display backlight PASS 'Panel backlight exposes a valid brightness range' "$brightness/$maximum"
else
	ybv_emit display backlight FAIL 'Panel backlight state is missing or invalid' "brightness=${brightness:-unknown} max=${maximum:-unknown}"
fi

orientation_lock=$(ybv_run_as_user "$desktop_user" gsettings get \
	org.gnome.settings-daemon.peripherals.touchscreen orientation-lock 2>>"$YBV_LOG" || true)
if [[ $orientation_lock == false ]]; then
	ybv_emit display rotation-policy PASS 'GNOME automatic display rotation is enabled' 'orientation-lock=false'
else
	ybv_emit display rotation-policy FAIL 'GNOME display rotation is locked or unavailable' "orientation-lock=${orientation_lock:-unknown}"
fi

automatic_brightness=$(ybv_run_as_user "$desktop_user" gsettings get \
	org.gnome.settings-daemon.plugins.power ambient-enabled 2>>"$YBV_LOG" || true)
if [[ $automatic_brightness == false ]]; then
	ybv_emit display brightness-policy PASS 'Aggressive GNOME automatic brightness is disabled' 'ambient-enabled=false'
elif [[ $automatic_brightness == true ]]; then
	ybv_emit display brightness-policy WARN 'GNOME automatic brightness is enabled and may cause visible rapid changes' 'ambient-enabled=true'
else
	ybv_emit display brightness-policy FAIL 'GNOME automatic-brightness policy is unavailable'
fi

display_journal=$(journalctl -b --no-pager -o short-iso 2>>"$YBV_LOG" |
	grep -Ei '(i915|drm|gnome-shell|mutter).*(gpu hang|wedg|reset.*fail|flip_done timed out|atomic.*fail|software render|llvmpipe|failed to initialize.*(egl|renderer))' || true)
if [[ -z $display_journal ]]; then
	ybv_emit display journal PASS 'No targeted GPU, modeset or software-rendering failure occurred in this boot'
else
	printf '\n===== Targeted display journal failures =====\n%s\n' "$display_journal" >>"$YBV_LOG"
	ybv_emit display journal FAIL 'A targeted GPU, modeset or software-rendering failure occurred in this boot' "count=$(wc -l <<<"$display_journal")"
fi

YBV_PHYSICAL_RESULT=PENDING
ybv_finish_report
