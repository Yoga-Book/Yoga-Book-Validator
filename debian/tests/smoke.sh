#!/usr/bin/env bash
set -Eeuo pipefail

smoke_root=${YBV_SMOKE_ROOT:-}

installed_path() {
	printf '%s%s\n' "$smoke_root" "$1"
}

if [[ -n $smoke_root ]]; then
	: "${YBV_SMOKE_VERSION:?YBV_SMOKE_VERSION is required with YBV_SMOKE_ROOT}"
	expected_version=$YBV_SMOKE_VERSION
	version_output=$(
		YBV_LIBEXEC_DIR=$(installed_path /usr/libexec/yogabook-validator) \
			"$(installed_path /usr/bin/yogabook-validator.sh)" version
	)
else
	expected_version=$(dpkg-query -W -f='${Version}' yogabook-validator)
	version_output=$(yogabook-validator version)
fi
grep -Fq "$expected_version" <<<"$version_output"
YBV_LIBEXEC_DIR=$(installed_path /usr/libexec/yogabook-validator) \
	"$(installed_path /usr/bin/yogabook-validator.sh)" --help >/dev/null
test -x "$(installed_path /usr/bin/yogabook-validator-ui.sh)"
test -x "$(installed_path /usr/bin/yogabook-validator.sh)"
test -L "$(installed_path /usr/bin/yogabook-validator)"
test "$(readlink -f "$(installed_path /usr/bin/yogabook-validator)")" = \
	"$(installed_path /usr/bin/yogabook-validator.sh)"

required_commands=(
	alsactl alsaucm amixer aplay arecord apt-get bash bluetoothctl btmgmt busctl
	dd find findmnt fuser gsettings ip journalctl lsblk lsusb media-ctl mktemp mount
	mountpoint pactl parec ping pkexec pw-play python3 rfkill rtcwake sha256sum stat
	stdbuf sync systemctl timeout udevadm umount v4l2-ctl wpctl
)
for command_name in "${required_commands[@]}"; do
	command -v "$command_name" >/dev/null
done

helper_count=0
while IFS= read -r helper; do
	test -f "$helper"
	test -x "$helper"
	helper_count=$((helper_count + 1))
done < <(find "$(installed_path /usr/libexec/yogabook-validator)" -maxdepth 1 -type f -name 'yogabook-validator-*' -print)
test "$helper_count" -ge 49

for helper_name in \
	yogabook-validator-apt.sh \
	yogabook-validator-camera-readiness.sh \
	yogabook-validator-charging.sh \
	yogabook-validator-internal-storage.sh \
	yogabook-validator-mode-trace-result.py \
	yogabook-validator-pen-stack.sh \
	yogabook-validator-pen-result.py \
	yogabook-validator-pen-targets.py \
	yogabook-validator-physical-import.py \
	yogabook-validator-resume.py \
	yogabook-validator-sensor-interactions.py \
	yogabook-validator-sensor-interactions.sh \
	yogabook-validator-usb-cycle.sh; do
	test -x "$(installed_path "/usr/libexec/yogabook-validator/$helper_name")"
done

python3 -B "$(installed_path /usr/libexec/yogabook-validator/yogabook-validator-mode-trace-result.py)" --self-test
python3 -B "$(installed_path /usr/libexec/yogabook-validator/yogabook-validator-pen-targets.py)" --self-test
python3 -B "$(installed_path /usr/libexec/yogabook-validator/yogabook-validator-sensor-interactions.py)" --self-test
python3 -B - \
	"$(installed_path /usr/share/yogabook-validator/acceptance.json)" \
	"$(installed_path /usr/lib/yogabook-validator/yogabook_validator_ui.py)" <<'PY'
import json
import runpy
import sys
from pathlib import Path

acceptance = json.loads(
    Path(sys.argv[1]).read_text(encoding="utf-8")
)
selectors = [
    selector
    for component in acceptance["components"]
    for layer in component["layers"].values()
    for selector in layer
]
assert len(acceptance["components"]) == 24
assert len(selectors) == 246
assert len(set(selectors)) == 234
runpy.run_path(
    sys.argv[2],
    run_name="yogabook_validator_autopkgtest",
)
PY

desktop-file-validate "$(installed_path /usr/share/applications/org.yogabook.Validator.desktop)"
