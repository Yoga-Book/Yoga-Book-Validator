#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

output_dir=
requirement=available
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	--require-sky) requirement=sky; shift ;;
	--require-fix) requirement=fix; shift ;;
	-h | --help) echo 'Usage: yogabook-validator gnss [--require-sky|--require-fix] [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done

ybv_begin_report gnss "$output_dir"
gnss_nodes=()
for node in /dev/gnss* /dev/ttyGPS*; do [[ -e $node ]] && gnss_nodes+=("$node"); done
if ((${#gnss_nodes[@]})); then
	ybv_emit gnss device PASS 'GNSS device node is present' "${gnss_nodes[*]}"
else
	ybv_emit gnss device WARN 'No dedicated GNSS device node is present'
fi

sample=
if ybv_has_command gpspipe; then
	sample=$(timeout 12 gpspipe -w -n 8 2>&1 || true)
	printf '\n===== gpsd sample =====\n%s\n' "$sample" >>"$YBV_LOG"
	if grep -q '"class":"TPV"' <<<"$sample"; then
		ybv_emit gnss gpsd PASS 'gpsd returned GNSS position reports'
	else
		ybv_emit gnss gpsd WARN 'gpsd did not return a position report in 12 seconds'
	fi
else
	ybv_emit gnss gpsd SKIP 'gpspipe is not installed'
fi

sky=false
fix=false
grep -q '"class":"SKY"' <<<"$sample" && sky=true
grep -Eq '"mode":[23]' <<<"$sample" && fix=true
$sky && ybv_emit gnss sky PASS 'Satellite sky data was received' || ybv_emit gnss sky WARN 'No satellite sky data was received in the bounded sample'
$fix && ybv_emit gnss fix PASS 'A 2D or 3D GNSS fix was observed' || ybv_emit gnss fix SKIP 'No GNSS fix was observed; test outdoors with a clear sky'

case $requirement in
sky) $sky || ybv_emit gnss required-sky FAIL '--require-sky was requested but no SKY report arrived' ;;
fix) $fix || ybv_emit gnss required-fix FAIL '--require-fix was requested but no 2D/3D fix arrived' ;;
esac
ybv_finish_report
