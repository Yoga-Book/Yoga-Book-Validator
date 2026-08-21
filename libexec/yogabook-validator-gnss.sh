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
for node in /dev/gnss* /dev/ttyGPS* /dev/ttyS5; do [[ -e $node ]] && gnss_nodes+=("$node"); done
if ((${#gnss_nodes[@]})); then
	ybv_emit gnss device PASS 'GNSS device node is present' "${gnss_nodes[*]}"
else
	ybv_emit gnss device WARN 'No dedicated GNSS device node is present'
fi

if ybv_has_command yogabook-gnss-health; then
	health_args=()
	[[ $requirement == sky ]] && health_args+=(--require-sky)
	[[ $requirement == fix ]] && health_args+=(--require-fix)
	health_output=$(timeout 40 yogabook-gnss-health "${health_args[@]}" 2>&1 || true)
	printf '\n===== Yoga Book GNSS health =====\n%s\n' "$health_output" >>"$YBV_LOG"
	if grep -Fq 'HEALTH_RESULT: PASS' <<<"$health_output" && grep -Fq 'TRANSPORT_RESULT: PASS' <<<"$health_output"; then
		ybv_emit gnss transport PASS 'BCM4752-to-gpsd GNSS transport is healthy' 'TPV and raw GGA/RMC/GSV present'
	else
		ybv_emit gnss transport FAIL 'Yoga Book GNSS integration health check failed' "$(tail -n 1 <<<"$health_output")"
	fi
	if grep -Fq 'SKY status: gpsd SKY present' <<<"$health_output"; then
		ybv_emit gnss sky PASS 'Satellite sky data was received'
	elif [[ $requirement == sky || $requirement == fix ]]; then
		ybv_emit gnss required-sky FAIL 'Complete satellite sky data was required but unavailable'
	else
		ybv_emit gnss sky WARN 'Raw satellite transport works, but complete sky geometry is unavailable indoors'
	fi
	if grep -Fq 'Fix status: 2D/3D fix present' <<<"$health_output"; then
		ybv_emit gnss fix PASS 'A 2D or 3D GNSS fix was observed'
	elif [[ $requirement == fix ]]; then
		ybv_emit gnss required-fix FAIL 'A 2D/3D GNSS fix was required but unavailable'
	else
		ybv_emit gnss fix SKIP 'No GNSS fix was observed; test outdoors with a clear sky'
	fi
	ybv_finish_report
	exit
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
