#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../libexec/yogabook-validator-common.sh
. "$root/libexec/yogabook-validator-common.sh"
# shellcheck source=../libexec/yogabook-validator-camera-readiness.sh
. "$root/libexec/yogabook-validator-camera-readiness.sh"

[[ $(ybv_classify_camera_kernel_headers installed present) == PASS ]]
[[ $(ybv_classify_camera_kernel_headers missing missing) == FAIL ]]
[[ $(ybv_classify_camera_kernel_headers installed missing) == FAIL ]]

[[ $(ybv_classify_camera_loopback_module PASS /lib/modules/test/v4l2loopback.ko.zst) == PASS ]]
[[ $(ybv_classify_camera_loopback_module PASS '') == FAIL ]]
[[ $(ybv_classify_camera_loopback_module FAIL '') == SKIP ]]
[[ $(ybv_classify_camera_loopback_module FAIL /lib/modules/test/v4l2loopback.ko.zst) == PASS ]]

[[ $(ybv_classify_camera_prepare_service PASS yes loaded active success 0 'Front Camera' 'Rear Camera') == PASS ]]
[[ $(ybv_classify_camera_prepare_service SKIP no loaded inactive unknown unknown '' '') == SKIP ]]
[[ $(ybv_classify_camera_prepare_service FAIL no loaded inactive unknown unknown '' '') == SKIP ]]
[[ $(ybv_classify_camera_prepare_service PASS no loaded active success 0 'Front Camera' 'Rear Camera') == FAIL ]]
[[ $(ybv_classify_camera_prepare_service PASS yes loaded failed exit-code 1 'Front Camera' 'Rear Camera') == FAIL ]]
[[ $(ybv_classify_camera_prepare_service PASS yes loaded active success 0 'wrong' 'Rear Camera') == FAIL ]]

printf 'camera readiness policy: PASS\n'
