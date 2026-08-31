#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

matrix=${YBV_ACCEPTANCE_MATRIX:-/usr/share/yogabook-validator/acceptance.json}
[[ -r $matrix ]] || matrix="$LIBEXEC_DIR/../data/acceptance.json"
renderer=${YBV_REPORT_RENDERER:-$LIBEXEC_DIR/yogabook-validator-report.py}

output_dir=
arguments=("$@")
while (($#)); do
	case $1 in
	--output)
		[[ $# -ge 2 ]] || { echo 'ERROR: --output requires a directory' >&2; exit 2; }
		output_dir=$2
		shift 2
		;;
	--output=*)
		output_dir=${1#--output=}
		shift
		;;
	*) shift ;;
	esac
done

python3 "$LIBEXEC_DIR/yogabook-validator-dossier.py" \
	--validator-version "$YBV_VERSION" \
	--matrix "$matrix" \
	--renderer "$renderer" \
	"${arguments[@]}"

real_user=$(ybv_real_user)
if [[ $EUID -eq 0 && -n $real_user && $real_user != root && -n $output_dir ]]; then
	output_dir=$(realpath -e -- "$output_dir")
	[[ -d $output_dir ]] || { echo 'ERROR: dossier output is not a directory' >&2; exit 1; }
	ybv_chown_tree_to_user "$real_user" "$output_dir"
fi
