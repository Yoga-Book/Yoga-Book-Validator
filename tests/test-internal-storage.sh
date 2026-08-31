#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/probe"

cat >"$temporary/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
target=
field=
while (($#)); do
	case $1 in
	-T) target=$2; shift 2 ;;
	-o) field=$2; shift 2 ;;
	*) shift ;;
	esac
done
case $field in
MAJ:MIN)
	[[ $target == / ]] && printf '%s\n' 1:1 || printf '%s\n' "${FAKE_PROBE_DEVICE:-1:1}"
	;;
TARGET) printf '%s\n' / ;;
FSTYPE) printf '%s\n' ext4 ;;
*) exit 2 ;;
esac
EOF
chmod +x "$temporary/bin/findmnt"

export PATH="$temporary/bin:$PATH"
# shellcheck source=../libexec/yogabook-validator-internal-storage.sh
. "$root/libexec/yogabook-validator-internal-storage.sh"

reset_report() {
	YBV_REPORT=$temporary/results.tsv
	YBV_LOG=$temporary/validator.log
	YBV_FAILURES=0
	printf 'timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails\n' >"$YBV_REPORT"
	: >"$YBV_LOG"
}

reset_report
ybv_internal_storage_probe "$temporary/probe"
grep -Fq $'storage\troot-file-io\tPASS' "$YBV_REPORT"
grep -Fq 'pattern=0xa5 retained=false' "$YBV_REPORT"
if compgen -G "$temporary/probe/.yogabook-validator-internal-storage-io.*" >/dev/null; then
	echo 'successful probe retained a temporary file' >&2
	exit 1
fi

reset_report
export YBV_TEST_FORCE_STORAGE_FAILURE=1
if ybv_internal_storage_probe "$temporary/probe"; then
	echo 'forced I/O failure unexpectedly passed' >&2
	exit 1
fi
unset YBV_TEST_FORCE_STORAGE_FAILURE
grep -Fq $'storage\troot-file-io\tFAIL' "$YBV_REPORT"
grep -Fq 'cleanup_attempted=true retained=false' "$YBV_REPORT"
if compgen -G "$temporary/probe/.yogabook-validator-internal-storage-io.*" >/dev/null; then
	echo 'failed probe retained a temporary file after cleanup' >&2
	exit 1
fi

reset_report
export FAKE_PROBE_DEVICE=2:2
if ybv_internal_storage_probe "$temporary/probe"; then
	echo 'non-root mount unexpectedly passed' >&2
	exit 1
fi
unset FAKE_PROBE_DEVICE
grep -Fq 'target is not on the root filesystem' "$YBV_REPORT"
if compgen -G "$temporary/probe/.yogabook-validator-internal-storage-io.*" >/dev/null; then
	echo 'rejected non-root target created a temporary file' >&2
	exit 1
fi

reset_report
touch "$temporary/probe/.yogabook-validator-internal-storage-io.residual"
if ybv_internal_storage_probe "$temporary/probe"; then
	echo 'residual probe file unexpectedly passed' >&2
	exit 1
fi
grep -Fq 'previous internal-storage probe did not clean up' "$YBV_REPORT"
rm -f -- "$temporary/probe/.yogabook-validator-internal-storage-io.residual"

echo 'Internal storage probe tests: PASS'
