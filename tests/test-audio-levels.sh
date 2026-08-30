#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/ybv-audio-levels.XXXXXX")
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

mkdir -p "$temporary/bin" "$temporary/state"
cat >"$temporary/bin/amixer" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == -c && $2 == yogabook ]]
operation=$3
control=$4
case $control in
"name=1 Master Playback Volume") key=master ;;
"name=DAC1 Playback Volume") key=dac1 ;;
*) exit 2 ;;
esac
case $operation in
cget)
	printf '  : values=%s\n' "$(<"$FAKE_MIXER_STATE/$key")"
	;;
cset)
	printf '%s=%s\n' "$key" "$5" >>"$FAKE_MIXER_STATE/calls"
	[[ ! -e $FAKE_MIXER_STATE/fail-cset-$key ]] || exit 1
	[[ -e $FAKE_MIXER_STATE/ignore-cset-$key ]] || printf '%s\n' "$5" >"$FAKE_MIXER_STATE/$key"
	;;
*) exit 2 ;;
esac
MOCK
chmod +x "$temporary/bin/amixer"

# shellcheck source=../libexec/yogabook-validator-audio-levels.sh
. "$root/libexec/yogabook-validator-audio-levels.sh"
export FAKE_MIXER_STATE="$temporary/state"
export PATH="$temporary/bin:$PATH"
log_file="$temporary/amixer.log"

reset_mixer() {
	rm -f -- "$temporary/state"/calls "$temporary/state"/fail-cset-* \
		"$temporary/state"/ignore-cset-*
	printf '%s\n' "$1" >"$temporary/state/master"
	printf '%s\n' "$2" >"$temporary/state/dac1"
}

# Values above the ceiling are reduced independently on both channels.
reset_mixer 32,31 127,100
details=$(ybv_enforce_playback_level_cap "$log_file")
[[ $details == 'master=24,24/32 (max -16 dB) dac1=87,87/127 (max 0 dB) tone=8%' ]]
grep -Fxq 'master=24,24' "$temporary/state/calls"
grep -Fxq 'dac1=87,87' "$temporary/state/calls"

# A quieter user channel is never raised while the louder peer is capped.
reset_mixer 10,30 70,90
details=$(ybv_enforce_playback_level_cap "$log_file")
[[ $details == 'master=10,24/32 (max -16 dB) dac1=70,87/127 (max 0 dB) tone=8%' ]]
grep -Fxq 'master=10,24' "$temporary/state/calls"
grep -Fxq 'dac1=70,87' "$temporary/state/calls"

# Unreadable state fails before any mixer mutation.
reset_mixer malformed 87,87
if ybv_enforce_playback_level_cap "$log_file"; then
	echo 'malformed mixer state must fail closed' >&2
	exit 1
fi
test ! -e "$temporary/state/calls"

# A rejected write and a write that cannot be verified both fail closed.
reset_mixer 32,32 87,87
touch "$temporary/state/fail-cset-master"
if ybv_enforce_playback_level_cap "$log_file"; then
	echo 'rejected mixer write must fail closed' >&2
	exit 1
fi
test "$(wc -l <"$temporary/state/calls")" -eq 1

reset_mixer 32,32 87,87
touch "$temporary/state/ignore-cset-master"
if ybv_enforce_playback_level_cap "$log_file"; then
	echo 'unverified mixer write must fail closed' >&2
	exit 1
fi
test "$(wc -l <"$temporary/state/calls")" -eq 2
