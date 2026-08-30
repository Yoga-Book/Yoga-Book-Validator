#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

matrix=${YBV_ACCEPTANCE_MATRIX:-/usr/share/yogabook-validator/acceptance.json}
[[ -r $matrix ]] || matrix="$LIBEXEC_DIR/../data/acceptance.json"
renderer=${YBV_REPORT_RENDERER:-$LIBEXEC_DIR/yogabook-validator-report.py}

exec python3 "$LIBEXEC_DIR/yogabook-validator-dossier.py" \
	--validator-version "$YBV_VERSION" \
	--matrix "$matrix" \
	--renderer "$renderer" \
	"$@"
