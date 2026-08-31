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
restart_count_before=
if [[ $YBV_SYSROOT == / ]] && ybv_has_command systemctl; then
	restart_count_before=$(systemctl show yogabook-gnss.service --property=NRestarts --value 2>/dev/null || true)
fi
gnss_nodes=()
dev_root=$(ybv_path /dev)
shopt -s nullglob
for node in "$dev_root"/gnss* "$dev_root"/ttyGPS* "$dev_root"/ttyS5; do
	[[ -e $node ]] || continue
	node_path=${node#"${YBV_SYSROOT%/}"}
	gnss_nodes+=("$node_path")
done
shopt -u nullglob
if ((${#gnss_nodes[@]})); then
	ybv_emit gnss device PASS 'GNSS device node is present' "${gnss_nodes[*]}"
else
	ybv_emit gnss device WARN 'No dedicated GNSS device node is present'
fi

gnss_runtime_path=/var/lib/yogabook-gnss/root/system/vendor/bin/gpsd
gnss_runtime=$(ybv_path "$gnss_runtime_path")
if [[ ! -x $gnss_runtime ]]; then
	ybv_emit gnss runtime-assets FAIL 'The private BCM4752 transport runtime has not been imported' \
		'Build it from a legally obtained Lenovo Android 7.1.1 system image with yogabook-gnss-build-runtime, then run sudo yogabook-gnss-import ARCHIVE'
	ybv_emit gnss transport SKIP 'GNSS transport cannot start until its private runtime is imported' 'blocked_by=gnss/runtime-assets'
	ybv_emit gnss gpsd SKIP 'gpsd cannot expose GNSS reports until the private transport runtime is imported' 'blocked_by=gnss/runtime-assets'
	ybv_emit gnss sky SKIP 'Satellite reception cannot be sampled until GNSS transport is available' 'blocked_by=gnss/runtime-assets'
	ybv_emit gnss fix SKIP 'A position fix cannot be sampled until GNSS transport is available' 'blocked_by=gnss/runtime-assets'
	ybv_emit gnss service-stability SKIP 'GNSS service stability cannot be measured before runtime import' 'blocked_by=gnss/runtime-assets'
	ybv_finish_report
	exit
fi
ybv_emit gnss runtime-assets PASS 'The verified private BCM4752 transport runtime is installed' "$gnss_runtime_path"

if ybv_has_command yogabook-gnss-health; then
	health_args=()
	[[ $requirement == sky ]] && health_args+=(--require-sky)
	[[ $requirement == fix ]] && health_args+=(--require-fix)
	health_output=$(timeout 40 yogabook-gnss-health "${health_args[@]}" 2>&1 || true)
	printf '\n===== Yoga Book GNSS health =====\n%s\n' "$health_output" >>"$YBV_LOG"
	health_ok=false
	transport_ok=false
	grep -Fq 'HEALTH_RESULT: PASS' <<<"$health_output" && health_ok=true
	grep -Fq 'TRANSPORT_RESULT: PASS' <<<"$health_output" && transport_ok=true
	if $health_ok && $transport_ok; then
		ybv_emit gnss transport PASS 'BCM4752-to-gpsd GNSS transport is healthy' 'TPV and raw GGA/RMC/GSV present'
	else
		ybv_emit gnss transport FAIL 'Yoga Book GNSS integration health check failed' "$(tail -n 1 <<<"$health_output")"
	fi
	if grep -Fq 'gpsd TPV stream: present' <<<"$health_output"; then
		ybv_emit gnss gpsd PASS 'gpsd returned GNSS position reports'
	elif $health_ok && $transport_ok; then
		ybv_emit gnss gpsd WARN 'The transport passed, but the health probe did not confirm a gpsd TPV stream'
	else
		ybv_emit gnss gpsd FAIL 'The GNSS health probe did not observe a working gpsd TPV stream'
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
	restart_count_after=
	if [[ $YBV_SYSROOT == / ]]; then
		restart_count_after=$(systemctl show yogabook-gnss.service --property=NRestarts --value 2>/dev/null || true)
	fi
	if [[ $restart_count_before =~ ^[0-9]+$ && $restart_count_after =~ ^[0-9]+$ ]]; then
		if ((restart_count_after == restart_count_before)); then
			ybv_emit gnss service-stability PASS 'GNSS transport did not restart during the bounded health capture' "historical-restarts=$restart_count_after"
		else
			ybv_emit gnss service-stability FAIL 'GNSS transport restarted during the bounded health capture' "before=$restart_count_before after=$restart_count_after"
		fi
	else
		ybv_emit gnss service-stability SKIP 'GNSS service restart counter is unavailable'
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
if $sky; then
	ybv_emit gnss sky PASS 'Satellite sky data was received'
else
	ybv_emit gnss sky WARN 'No satellite sky data was received in the bounded sample'
fi
if $fix; then
	ybv_emit gnss fix PASS 'A 2D or 3D GNSS fix was observed'
else
	ybv_emit gnss fix SKIP 'No GNSS fix was observed; test outdoors with a clear sky'
fi

case $requirement in
sky) $sky || ybv_emit gnss required-sky FAIL '--require-sky was requested but no SKY report arrived' ;;
fix) $fix || ybv_emit gnss required-fix FAIL '--require-fix was requested but no 2D/3D fix arrived' ;;
esac
ybv_finish_report
