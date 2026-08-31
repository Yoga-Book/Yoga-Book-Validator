#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ $# -eq 1 ]] || { echo 'Usage: yogabook-validator bundle DIRECTORY' >&2; exit 2; }
source_directory=$(realpath -e -- "$1")
[[ -d $source_directory ]] || { echo 'ERROR: bundle source must be a directory' >&2; exit 2; }
[[ -s $source_directory/results.tsv && -s $source_directory/validator.log ]] || {
	echo 'ERROR: bundle source is not a Yoga Book Validator report directory' >&2
	exit 2
}
IFS= read -r results_header <"$source_directory/results.tsv" || true
[[ $results_header == $'timestamp\tsubsystem\tcheck_id\tstatus\tsummary\tdetails' ]] || {
	echo 'ERROR: bundle source has an unsupported results schema' >&2
	exit 2
}
while IFS= read -r -d '' pen_mapping_result; do
	if ! python3 "$LIBEXEC_DIR/yogabook-validator-pen-result.py" \
		"$pen_mapping_result" >/dev/null; then
		echo 'ERROR: pen mapping evidence violates its privacy-safe schema' >&2
		exit 2
	fi
done < <(find "$source_directory" -type f -name pen-mapping.json -print0)
bundle="${source_directory%/}-$(date +%Y%m%d-%H%M%S).tar.gz"
file_list=$(mktemp)
trap 'rm -f -- "$file_list"' EXIT
find "$source_directory" -type f \( \
	-name results.tsv -o -name validator.log -o -name environment.tsv \
	-o -name validated-packages.tsv -o -name state-before.tsv -o -name state-after.tsv \
	-o -name state-diff.txt -o -name report.json -o -name report.md -o -name report.html \
	-o -name physical-results.tsv -o -name sources.tsv -o -name observations.tsv \
	-o -name charge-samples.tsv -o -name control-events.tsv -o -name mode-transition.tsv \
	-o -name pen-mapping.json -o -name resume-before.json -o -name resume-after.json \
	-o -name transition-journal.log \
	-o -name suspend-playback.log -o -name suspend-capture.log \
\) -printf '%P\0' >"$file_list"
[[ -s $file_list ]] || { echo 'ERROR: bundle contains no approved evidence files' >&2; exit 2; }
tar -C "$source_directory" --null -T "$file_list" -czf "$bundle"
printf '%s\n' "$bundle"
