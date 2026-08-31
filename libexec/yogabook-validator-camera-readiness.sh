#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

# This file is a sourced helper. Keeping the classifiers side-effect free makes
# every causal failure path testable without loading modules or starting units.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	echo 'ERROR: camera readiness is an internal Validator helper' >&2
	exit 2
fi

ybv_classify_camera_kernel_headers() {
	local package_state=$1 build_tree_state=$2
	if [[ $package_state == installed && $build_tree_state == present ]]; then
		printf 'PASS\n'
	else
		printf 'FAIL\n'
	fi
}

ybv_classify_camera_loopback_module() {
	local headers_status=$1 module_path=$2
	if [[ -n $module_path ]]; then
		printf 'PASS\n'
	elif [[ $headers_status == PASS ]]; then
		printf 'FAIL\n'
	else
		printf 'SKIP\n'
	fi
}

ybv_classify_camera_prepare_service() {
	local module_status=$1 module_loaded=$2 load_state=$3 active_state=$4
	local result=$5 exec_status=$6 front_name=$7 rear_name=$8
	if [[ $module_status != PASS ]]; then
		printf 'SKIP\n'
	elif [[ $module_loaded == yes && $load_state == loaded && $active_state == active &&
		$result == success && $exec_status == 0 && $front_name == 'Front Camera' &&
		$rear_name == 'Rear Camera' ]]; then
		printf 'PASS\n'
	else
		printf 'FAIL\n'
	fi
}

ybv_check_camera_readiness() {
	local kernel=$1 headers_package="linux-headers-$1"
	local headers_dir package_state=missing build_tree_state=missing headers_status
	local modules_root module_path='' module_loaded=no module_status
	local service_properties='' load_state=missing active_state=inactive result=unknown exec_status=unknown
	local front_name='' rear_name='' prepare_status

	headers_dir=$(ybv_path "/lib/modules/$kernel/build")
	if [[ $YBV_SYSROOT == / ]] && ybv_has_command dpkg-query &&
		[[ $(dpkg-query -W -f='${Status}' "$headers_package" 2>/dev/null || true) == 'install ok installed' ]]; then
		package_state=installed
	elif [[ $YBV_SYSROOT != / && -e $headers_dir ]]; then
		package_state=installed
	fi
	if [[ -e $headers_dir && -s $headers_dir/Makefile ]]; then
		build_tree_state=present
	fi
	headers_status=$(ybv_classify_camera_kernel_headers "$package_state" "$build_tree_state")
	if [[ $headers_status == PASS ]]; then
		ybv_emit camera kernel-headers PASS \
			'Headers and build tree match the running kernel' \
			"package=$headers_package path=$headers_dir"
	else
		ybv_emit camera kernel-headers FAIL \
			'The running kernel cannot build required out-of-tree camera modules' \
			"package=$headers_package package-state=$package_state build-tree=$build_tree_state path=$headers_dir"
	fi

	modules_root=$(ybv_path "/lib/modules/$kernel")
	if [[ $YBV_SYSROOT == / ]] && ybv_has_command modinfo; then
		module_path=$(modinfo -k "$kernel" -F filename v4l2loopback 2>/dev/null | head -n 1 || true)
	elif [[ -d $modules_root ]]; then
		module_path=$(find "$modules_root" -type f -name 'v4l2loopback.ko*' -print -quit 2>/dev/null || true)
	fi
	[[ -d $(ybv_path /sys/module/v4l2loopback) ]] && module_loaded=yes
	module_status=$(ybv_classify_camera_loopback_module "$headers_status" "$module_path")
	case $module_status in
	PASS)
		ybv_emit camera v4l2loopback-module PASS \
			'v4l2loopback is installed for the running kernel' \
			"kernel=$kernel path=$module_path loaded=$module_loaded"
		;;
	FAIL)
		ybv_emit camera v4l2loopback-module FAIL \
			'v4l2loopback was not built for the running kernel' \
			"kernel=$kernel headers=PASS path=missing"
		;;
	SKIP)
		ybv_emit camera v4l2loopback-module SKIP \
			'v4l2loopback readiness is blocked by missing matching kernel headers' \
			'blocked_by=camera/kernel-headers'
		;;
	esac

	if [[ $YBV_SYSROOT == / ]] && ybv_has_command systemctl; then
		service_properties=$(systemctl show yogabook-camera-prepare.service \
			-p LoadState -p ActiveState -p Result -p ExecMainStatus 2>/dev/null || true)
		load_state=$(sed -n 's/^LoadState=//p' <<<"$service_properties")
		active_state=$(sed -n 's/^ActiveState=//p' <<<"$service_properties")
		result=$(sed -n 's/^Result=//p' <<<"$service_properties")
		exec_status=$(sed -n 's/^ExecMainStatus=//p' <<<"$service_properties")
	fi
	front_name=$(ybv_read_first /sys/class/video4linux/video10/name)
	rear_name=$(ybv_read_first /sys/class/video4linux/video11/name)
	prepare_status=$(ybv_classify_camera_prepare_service \
		"$module_status" "$module_loaded" "$load_state" "$active_state" \
		"$result" "$exec_status" "$front_name" "$rear_name")
	case $prepare_status in
	PASS)
		ybv_emit camera prepare-service PASS \
			'The camera preparation service created both named loopback devices' \
			"active=$active_state result=$result video10=$front_name video11=$rear_name"
		;;
	SKIP)
		ybv_emit camera prepare-service SKIP \
			'The camera preparation service cannot succeed until v4l2loopback is available' \
			'blocked_by=camera/v4l2loopback-module'
		;;
	FAIL)
		ybv_emit camera prepare-service FAIL \
			'The camera preparation service did not create a healthy loopback pair' \
			"load=$load_state active=$active_state result=$result exit=$exec_status module-loaded=$module_loaded video10=${front_name:-missing} video11=${rear_name:-missing}"
		if ybv_has_command journalctl; then
			printf '\n===== Camera preparation journal =====\n' >>"$YBV_LOG"
			journalctl -b -u yogabook-camera-prepare.service --no-pager -n 30 \
				>>"$YBV_LOG" 2>&1 || true
		fi
		;;
	esac
}
