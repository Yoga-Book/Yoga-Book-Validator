#!/usr/bin/env bash
set -Eeuo pipefail
yogabook-validator version
yogabook-validator --help >/dev/null
test -x /usr/bin/yogabook-validator-ui
test -x /usr/bin/yogabook-validator.sh
test -L /usr/bin/yogabook-validator
test -x /usr/libexec/yogabook-validator/yogabook-validator-active.sh
desktop-file-validate /usr/share/applications/org.yogabook.Validator.desktop
