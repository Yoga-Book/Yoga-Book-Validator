#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

output_dir=
while (($#)); do
	case $1 in
	--output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
	-h | --help) echo 'Usage: yogabook-validator apt [--output DIRECTORY]'; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done

ybv_begin_report apt "$output_dir"

apt_get=${YBV_APT_GET:-apt-get}
apt_timeout=${YBV_APT_TIMEOUT:-60}
apt_workspace=

sanitize_apt_output() {
	sed -E "s#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]']+@#\1[redacted]@#g"
}

cleanup_apt_workspace() {
	[[ -n $apt_workspace && -d $apt_workspace ]] || return 0
	case ${apt_workspace##*/} in
	yogabook-validator-apt.*) rm -rf -- "$apt_workspace" ;;
	*) return 1 ;;
	esac
}

trap 'cleanup_apt_workspace || true' EXIT

if ! command -v "$apt_get" >/dev/null 2>&1; then
	ybv_emit platform apt-sources FAIL 'apt-get is unavailable, so configured software sources cannot be inspected'
	ybv_emit platform apt-update SKIP 'Repository metadata cannot be refreshed without apt-get'
	ybv_finish_report
	exit
fi

apt_tmp_base=${YBV_APT_TMP_BASE:-${TMPDIR:-/tmp}}
apt_workspace=$(mktemp -d "$apt_tmp_base/yogabook-validator-apt.XXXXXX")
ybv_register_restore_callback cleanup_apt_workspace
lists_dir="$apt_workspace/lists"
cache_dir="$apt_workspace/cache"
archives_dir="$cache_dir/archives"
mkdir -p "$lists_dir/partial" "$archives_dir/partial"

apt_options=(
	-o "Dir::State::lists=$lists_dir"
	-o "Dir::Cache=$cache_dir"
	-o "Dir::Cache::archives=$archives_dir"
	-o "APT::Sandbox::User=$(id -un)"
	-o APT::Get::List-Cleanup=0
	-o APT::Update::Error-Mode=any
	-o Acquire::Languages=none
	-o Acquire::IndexTargets::deb::Packages::DefaultEnabled=false
	-o Acquire::IndexTargets::deb::Translations::DefaultEnabled=false
	-o Acquire::IndexTargets::deb::DEP-11::DefaultEnabled=false
	-o Acquire::IndexTargets::deb::CNF::DefaultEnabled=false
)

print_output=
print_rc=0
set +e
print_output=$(timeout "$apt_timeout" "$apt_get" "${apt_options[@]}" --print-uris update 2>&1)
print_rc=$?
set -e
printf '\n===== APT configured targets =====\n' >>"$YBV_LOG"
sanitize_apt_output <<<"$print_output" >>"$YBV_LOG"
planned_targets=$(grep -Ec "^'[^']+'" <<<"$print_output" || true)
if ((print_rc == 0 && planned_targets > 0)); then
	ybv_emit platform apt-sources PASS 'APT exposes enabled repository metadata targets' "targets=$planned_targets"
elif ((print_rc == 124)); then
	ybv_emit platform apt-sources FAIL 'APT source inspection timed out' "timeout=${apt_timeout}s"
else
	ybv_emit platform apt-sources FAIL 'APT did not expose any usable repository metadata target' \
		"exit=$print_rc targets=$planned_targets"
fi

update_output=
update_rc=0
set +e
update_output=$(timeout "$apt_timeout" "$apt_get" "${apt_options[@]}" update 2>&1)
update_rc=$?
set -e
printf '\n===== Isolated APT metadata refresh =====\n' >>"$YBV_LOG"
sanitize_apt_output <<<"$update_output" >>"$YBV_LOG"
release_count=$(find "$lists_dir" -maxdepth 1 -type f \( -name '*InRelease' -o -name '*Release' \) -printf . | wc -c)
if ((update_rc == 0 && release_count > 0)); then
	ybv_emit platform apt-update PASS 'Every configured APT repository returned valid release metadata' \
		"releases=$release_count isolated-lists=true package-indexes=false"
elif ((update_rc == 124)); then
	ybv_emit platform apt-update FAIL 'APT repository metadata refresh timed out' "timeout=${apt_timeout}s isolated-lists=true"
else
	last_error=$(sanitize_apt_output <<<"$update_output" | grep -E '(^|[[:space:]])(Err:|E:|W:)' | tail -n 1 || true)
	ybv_emit platform apt-update FAIL 'One or more configured APT repositories failed an isolated metadata refresh' \
		"exit=$update_rc releases=$release_count ${last_error:-see validator.log}"
fi

ybv_finish_report
