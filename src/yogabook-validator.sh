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
  check                  Run the passive full-stack audit
  audio                  Run state-safe audio transport and signal tests
  suspend [SECONDS]      Run active audio across one suspend/resume cycle
  gnss [OPTIONS]         Inspect GNSS; optionally require sky or a fix
  physical               Record guided physical acceptance
  full                   Run passive audit, then guided physical acceptance
  bundle DIRECTORY       Create a compressed support bundle
  ui                     Open the graphical validator
  version                Print the installed version

Active audio and suspend tests request administrator authorization. Reports
contain results.tsv and validator.log under ./yogabook-validator-results.
EOF
}

command_name=${1:-help}
[[ $# -eq 0 ]] || shift

case $command_name in
check | gnss | physical | full | bundle)
	exec "$LIBEXEC_DIR/yogabook-validator-$command_name.sh" "$@"
	;;
audio | suspend)
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
