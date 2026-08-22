#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail

LIBEXEC_DIR=${YBV_LIBEXEC_DIR:-/usr/libexec/yogabook-validator}
if [[ ! -r $LIBEXEC_DIR/yogabook-validator-common.sh ]]; then
	LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../libexec" && pwd)
fi
# shellcheck source=../libexec/yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

usage() {
	cat <<'EOF'
Usage: yogabook-validator COMMAND [OPTIONS]

Commands:
  automated              Run all non-suspend automated validation
  check                  Run the passive full-stack audit
  passive                Run every read-only validation as one merged suite
  audio                  Run state-safe audio transport and signal tests
  camera                 Stream three frames from both cameras and restore route
  display                Inspect i915, DSI, Mutter and desktop display policy
  haptics                Pulse both Halo haptic actuators for 150 ms
  inputs                 Inspect kernel capabilities without reading events
  lights                 Exercise and restore panel and platform lights
  modes                  Observe a physical keyboard to pen to keyboard cycle
  rotation               Verify all four automatic display orientations
  platform               Inspect SoC, CPU, thermal, eMMC and RTC health
  power                  Validate battery, charger and desktop telemetry
  sensors                Sample every Yoga Book IIO sensor channel
  storage                Read the inserted SD card without writing to it
  storage-write          Write/read/delete a bounded SD filesystem test file
  suspend [SECONDS]      Run active audio across one suspend/resume cycle
  usb                    Inspect USB hubs, role switch and device transport
  wireless               Test Wi-Fi gateway and bounded Bluetooth discovery
  gnss [OPTIONS]         Inspect GNSS; optionally require sky or a fix
  physical               Record guided physical acceptance
  full                   Run full passive suite, then physical acceptance
  bundle DIRECTORY       Create a compressed support bundle
  ui                     Open the graphical validator
  version                Print the installed version

Active and combined tests request administrator authorization. Reports contain
results.tsv and validator.log under ./yogabook-validator-results.
EOF
}

command_name=${1:-help}
[[ $# -eq 0 ]] || shift

case $command_name in
check | camera | display | gnss | passive | physical | full | bundle | platform | power | sensors | usb)
	exec "$LIBEXEC_DIR/yogabook-validator-$command_name.sh" "$@"
	;;
audio | automated | haptics | inputs | lights | modes | rotation | storage | storage-write | suspend | wireless)
	if [[ $EUID -eq 0 ]]; then
		exec "$LIBEXEC_DIR/yogabook-validator-active.sh" "$command_name" "$@"
	elif command -v pkexec >/dev/null 2>&1; then
		exec pkexec "$LIBEXEC_DIR/yogabook-validator-active.sh" "$command_name" "$@"
	else
		echo "ERROR: $command_name requires root; install pkexec or run with sudo" >&2
		exit 2
	fi
	;;
ui)
	ui_command=/usr/bin/yogabook-validator-ui
	[[ -x $ui_command ]] || ui_command=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/yogabook-validator-ui.sh
	exec "$ui_command" "$@"
	;;
version | --version)
	printf 'yogabook-validator %s\n' "$YBV_VERSION"
	;;
help | -h | --help)
	usage
	;;
*)
	echo "ERROR: unknown command: $command_name" >&2
	usage >&2
	exit 2
	;;
esac
