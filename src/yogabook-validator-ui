#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -Eeuo pipefail
ui=/usr/lib/yogabook-validator/yogabook_validator_ui.py
if [[ ! -r $ui ]]; then
	ui=$(cd "$(dirname "${BASH_SOURCE[0]}")/../ui" && pwd)/yogabook_validator_ui.py
fi
exec python3 "$ui" "$@"
