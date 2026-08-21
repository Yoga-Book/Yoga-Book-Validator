#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
[[ $# -eq 1 ]] || { echo 'Usage: yogabook-validator bundle DIRECTORY' >&2; exit 2; }
source_directory=$(realpath -e -- "$1")
[[ -d $source_directory ]] || { echo 'ERROR: bundle source must be a directory' >&2; exit 2; }
bundle="${source_directory%/}-$(date +%Y%m%d-%H%M%S).tar.gz"
parent=${source_directory%/*}
name=${source_directory##*/}
tar -C "$parent" -czf "$bundle" --exclude='*.alsa-state' --exclude='*.wav' "$name"
printf '%s\n' "$bundle"
