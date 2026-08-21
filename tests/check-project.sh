#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d /tmp/yogabook-validator-test.XXXXXX)
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

required=(
	README.md ATTRIBUTION.md CONTRIBUTING.md LICENSE Makefile
	src/yogabook-validator src/yogabook-validator-ui
	libexec/yogabook-validator-common libexec/yogabook-validator-check
	libexec/yogabook-validator-active libexec/yogabook-validator-gnss
	libexec/yogabook-validator-physical libexec/yogabook-validator-full
	libexec/yogabook-validator-bundle ui/yogabook_validator_ui.py
	data/org.yogabook.Validator.desktop data/org.yogabook.validator.policy
	data/metainfo/org.yogabook.Validator.metainfo.xml debian/control debian/rules
)
for file in "${required[@]}"; do test -f "$root/$file"; done

while IFS= read -r script; do bash -n "$script"; done < <(
	printf '%s\n' "$root"/src/* "$root"/libexec/* "$root"/tests/*.sh "$root"/debian/tests/*
)
if command -v shellcheck >/dev/null; then
	shellcheck "$root"/src/* "$root"/libexec/* "$root"/tests/*.sh "$root"/debian/tests/*
fi
python3 -m py_compile "$root/ui/yogabook_validator_ui.py"
python3 - <<PY
import ast
import xml.etree.ElementTree as ET
ast.parse(open("$root/ui/yogabook_validator_ui.py", encoding="utf-8").read())
ET.parse("$root/data/metainfo/org.yogabook.Validator.metainfo.xml")
ET.parse("$root/data/org.yogabook.validator.policy")
PY

if command -v desktop-file-validate >/dev/null; then
	desktop-file-validate "$root/data/org.yogabook.Validator.desktop"
fi
if command -v appstreamcli >/dev/null; then
	appstreamcli validate --no-net "$root/data/metainfo/org.yogabook.Validator.metainfo.xml"
fi

store_line=$(grep -n 'store yogabook' "$root/libexec/yogabook-validator-active" | head -n1 | cut -d: -f1)
stop_line=$(grep -n 'systemctl --user stop' "$root/libexec/yogabook-validator-active" | head -n1 | cut -d: -f1)
[[ -n $store_line && -n $stop_line && $store_line -lt $stop_line ]]
grep -Fq "trap 'restore_state || true' EXIT INT TERM" "$root/libexec/yogabook-validator-active"
grep -Fq "state-restore FAIL" "$root/libexec/yogabook-validator-active"
grep -Fq "exclude='*.wav'" "$root/libexec/yogabook-validator-bundle"

answers="$temporary/answers.tsv"
printf 'speakers\tPASS\ttest note\nheadphones\tSKIP\tno adapter\n' >"$answers"
YBV_RESULTS_BASE="$temporary/results" YBV_LIBEXEC_DIR="$root/libexec" \
	"$root/src/yogabook-validator" physical --answers "$answers" --output "$temporary/physical"
grep -Fq $'physical\tspeakers\tPASS' "$temporary/physical/results.tsv"
grep -Fq 'PHYSICAL_ACCEPTANCE_RESULT: INCOMPLETE' "$temporary/physical/validator.log"

fake="$temporary/root"
mkdir -p "$fake/sys/class/dmi/id" "$fake/proc/asound/card7" "$fake/proc/bus/input" \
	"$fake/lib/firmware/intel/sof" "$fake/lib/firmware/intel/sof-tplg" \
	"$fake/usr/share/alsa/ucm2/conf.d/SOF" "$fake/usr/share/alsa/ucm2/cht-yogabook" \
	"$fake/sys/bus/iio/devices" "$fake/sys/class/power_supply/BAT0" \
	"$fake/sys/class/power_supply/USB0" "$fake/sys/class/backlight/panel" "$fake/dev"
printf 'LenovoYB1-X91L\n' >"$fake/sys/class/dmi/id/product_name"
printf 'LENOVO\n' >"$fake/sys/class/dmi/id/sys_vendor"
printf ' 7 [yogabook      ]: sof-cht - sof-cht yogabook\n' >"$fake/proc/asound/cards"
printf 'yogabook\n' >"$fake/proc/asound/card7/id"
printf 'Wacom HID 169 Pen\nHiDeep Touchscreen\nHalo Keyboard\n' >"$fake/proc/bus/input/devices"
printf 'firmware\n' >"$fake/lib/firmware/intel/sof/sof-cht.ri"
printf 'topology\n' >"$fake/lib/firmware/intel/sof-tplg/sof-cht-rt5677.tplg"
printf 'SectionUseCase."HiFi" {}\n' >"$fake/usr/share/alsa/ucm2/cht-yogabook/cht-yogabook.conf"
ln -s ../../cht-yogabook/cht-yogabook.conf "$fake/usr/share/alsa/ucm2/conf.d/SOF/LENOVO-LenovoYB1_X91L-X91L.conf"
printf '67\n' >"$fake/sys/class/power_supply/BAT0/capacity"
printf 'Discharging\n' >"$fake/sys/class/power_supply/BAT0/status"
printf 'Battery\n' >"$fake/sys/class/power_supply/BAT0/type"
printf 'USB\n' >"$fake/sys/class/power_supply/USB0/type"
printf '1\n' >"$fake/sys/class/power_supply/USB0/online"
printf '42\n' >"$fake/sys/class/backlight/panel/brightness"
printf '100\n' >"$fake/sys/class/backlight/panel/max_brightness"
touch "$fake/dev/halo_keyboard" "$fake/dev/video0"
YBV_SYSROOT="$fake" YBV_LIBEXEC_DIR="$root/libexec" \
	"$root/src/yogabook-validator" check --output "$temporary/check" || true
grep -Fq $'platform\tdmi\tPASS' "$temporary/check/results.tsv"
grep -Fq $'audio\talsa-card\tPASS' "$temporary/check/results.tsv"
grep -Fq $'power\tbattery\tPASS' "$temporary/check/results.tsv"

echo 'Yoga Book Validator project checks: PASS'
