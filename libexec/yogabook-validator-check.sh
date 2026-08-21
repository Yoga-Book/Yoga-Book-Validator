#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set -Eeuo pipefail
LIBEXEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=yogabook-validator-common.sh
. "$LIBEXEC_DIR/yogabook-validator-common.sh"

output_dir=
while (($#)); do
	case $1 in
	--output)
		[[ $# -ge 2 ]] || { echo 'ERROR: --output requires a directory' >&2; exit 2; }
		output_dir=$2
		shift 2
		;;
	-h | --help)
		echo 'Usage: yogabook-validator check [--output DIRECTORY]'
		exit 0
		;;
	*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
	esac
done

ybv_begin_report check "$output_dir"
product=$(ybv_read_first /sys/class/dmi/id/product_name)
vendor=$(ybv_read_first /sys/class/dmi/id/sys_vendor)
if [[ $product == *YB1-X91L* ]]; then
	ybv_emit platform dmi PASS 'Lenovo Yoga Book YB1-X91L detected' "$vendor $product"
else
	ybv_emit platform dmi FAIL 'Unsupported or unidentified hardware' "$vendor $product"
fi

kernel=$(uname -r)
if [[ $kernel == *yogabook* ]]; then
	ybv_emit platform kernel PASS 'Yoga Book kernel is running' "$kernel"
else
	ybv_emit platform kernel WARN 'Running kernel is not Yoga Book-labelled' "$kernel"
fi
ybv_capture 'Kernel command line' cat "$(ybv_path /proc/cmdline)"

if ybv_has_command grub-editenv; then
	grub_env=$(grub-editenv list 2>/dev/null || true)
	if grep -Eq '^saved_entry=.*yogabook' <<<"$grub_env"; then
		ybv_emit platform grub-default PASS 'Persistent GRUB entry selects a Yoga Book kernel' "$(grep '^saved_entry=' <<<"$grub_env")"
	else
		ybv_emit platform grub-default WARN 'Persistent GRUB entry is not confirmed as Yoga Book' "$grub_env"
	fi
else
	ybv_emit platform grub-default SKIP 'grub-editenv is unavailable'
fi

check_package() {
	local package=$1 subsystem=$2 minimum=${3:-} version
	if ! ybv_has_command dpkg-query; then
		ybv_emit "$subsystem" "package-$package" SKIP 'dpkg-query is unavailable'
		return
	fi
	version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)
	if [[ -z $version ]]; then
		ybv_emit "$subsystem" "package-$package" FAIL "$package is not installed"
	elif [[ -n $minimum ]] && ! dpkg --compare-versions "$version" ge "$minimum"; then
		ybv_emit "$subsystem" "package-$package" FAIL "$package is older than $minimum" "$version"
	else
		ybv_emit "$subsystem" "package-$package" PASS "$package is installed" "$version"
	fi
}

check_package halo-keyboard input
check_package yogabook-sensors sensors
check_package alsa-ucm-conf-yogabook audio 1.6
check_package yogabook-gnss gnss 1.0.1

card_number=$(ybv_find_card_number || true)
if [[ -n $card_number ]]; then
	ybv_emit audio alsa-card PASS 'ALSA card ID yogabook is present' "card $card_number"
	card_longname=$(ybv_read_first "/proc/asound/card${card_number}/id")
	ybv_capture 'ALSA cards' cat "$(ybv_path /proc/asound/cards)"
else
	ybv_emit audio alsa-card FAIL 'ALSA card ID yogabook is missing'
fi

sof_fw_path=$(ybv_read_first /sys/module/snd_sof/parameters/fw_path)
if [[ -n $sof_fw_path && $sof_fw_path != '(null)' ]]; then
	firmware=$(ybv_path "/lib/firmware/${sof_fw_path#/}/sof-cht.ri")
else
	firmware=$(ybv_path /lib/firmware/intel/sof/sof-cht.ri)
fi
topology=$(ybv_path /lib/firmware/intel/sof-tplg/sof-cht-rt5677.tplg)
ucm_alias=$(ybv_path /usr/share/alsa/ucm2/conf.d/SOF/LENOVO-LenovoYB1_X91L-X91L.conf)
[[ -s $firmware ]] && ybv_emit audio sof-firmware PASS 'Effective SOF firmware is installed' "$firmware sha256=$(sha256sum "$firmware" | awk '{print $1}')" || ybv_emit audio sof-firmware FAIL 'Effective SOF firmware is missing' "$firmware"
[[ -s $topology ]] && ybv_emit audio sof-topology PASS 'Yoga Book SOF topology is installed' "$(sha256sum "$topology" | awk '{print $1}')" || ybv_emit audio sof-topology FAIL 'SOF topology is missing' "$topology"
if [[ -L $ucm_alias && -e $ucm_alias ]]; then
	ybv_emit audio ucm-alias PASS 'SOF UCM long-name alias resolves' "$(readlink "$ucm_alias")"
else
	ybv_emit audio ucm-alias FAIL 'SOF UCM long-name alias is missing or broken' "$ucm_alias"
fi

if [[ -n $card_number ]] && ybv_has_command alsaucm; then
	ucm_verbs=$(timeout 10 alsaucm -c hw:yogabook list _verbs 2>&1 || true)
	if grep -Fq 'HiFi' <<<"$ucm_verbs"; then
		ybv_emit audio ucm-import PASS 'Yoga Book UCM imports without changing the active verb' 'HiFi'
	else
		ybv_emit audio ucm-import FAIL 'Yoga Book UCM does not expose the HiFi verb' "$(head -n 1 <<<"$ucm_verbs")"
	fi
	ucm_directory=$(ybv_path /usr/share/alsa/ucm2/cht-yogabook)
	ucm_devices=$(grep -Rh -E '^[[:space:]]*SectionDevice\."' "$ucm_directory" 2>/dev/null || true)
	missing_ucm=()
	for device in Speaker1 Headphones Mic1 Headset; do
		grep -Fq "$device" <<<"$ucm_devices" || missing_ucm+=("$device")
	done
	if ((${#missing_ucm[@]} == 0)); then
		ybv_emit audio ucm-devices PASS 'All Yoga Book UCM devices are available' 'Speaker1 Headphones Mic1 Headset'
	else
		ybv_emit audio ucm-devices FAIL 'UCM device enumeration is incomplete' "missing: ${missing_ucm[*]}"
	fi
	printf '\n===== UCM verbs =====\n%s\n===== UCM device declarations =====\n%s\n' \
		"$ucm_verbs" "$ucm_devices" >>"$YBV_LOG"
else
	ybv_emit audio ucm-devices SKIP 'UCM enumeration is unavailable'
fi

if [[ -n $card_number ]] && ybv_has_command amixer; then
	speaker_state=$(amixer -c "$card_number" cget name='Speaker Switch' 2>&1 || true)
	if grep -Eq 'values=(on|1)' <<<"$speaker_state"; then
		ybv_emit audio speaker-route PASS 'Raw speaker mixer route is enabled'
	elif [[ -n $speaker_state ]]; then
		ybv_emit audio speaker-route INFO 'Raw speaker mixer route is currently idle/disabled' "$(tail -n 1 <<<"$speaker_state")"
	else
		ybv_emit audio speaker-route WARN 'Speaker mixer state could not be read'
	fi
fi

if [[ $YBV_SYSROOT == / ]] && ybv_has_command wpctl; then
	wp_status=$(timeout 10 wpctl status 2>&1 || true)
	if grep -Fq 'Built-in Audio' <<<"$wp_status"; then
		ybv_emit audio pipewire PASS 'PipeWire exposes Built-in Audio'
	else
		ybv_emit audio pipewire WARN 'PipeWire does not currently expose Built-in Audio'
	fi
	printf '\n===== PipeWire =====\n%s\n' "$wp_status" >>"$YBV_LOG"
else
	ybv_emit audio pipewire SKIP 'PipeWire session inspection is unavailable'
fi

input_devices=$(ybv_path /proc/bus/input/devices)
input_text=$([[ -r $input_devices ]] && cat "$input_devices" || true)
check_input_pattern() {
	local id=$1 label=$2 pattern=$3 required=${4:-true}
	if grep -Eiq "$pattern" <<<"$input_text"; then
		ybv_emit input "$id" PASS "$label is present"
	elif [[ $required == true ]]; then
		ybv_emit input "$id" FAIL "$label is missing"
	else
		ybv_emit input "$id" WARN "$label was not detected"
	fi
}
check_input_pattern halo-surface 'Raw Goodix Halo touch surface' '^N: Name="Goodix Capacitive TouchScreen"$'
check_input_pattern halo-keyboard 'Virtual Halo keyboard input' '^N: Name="Halo Keyboard"$'
check_input_pattern halo-touchpad 'Virtual Halo touchpad input' '^N: Name="Halo Keyboard Touchpad"$'
haptic_count=$(grep -Fc 'N: Name="drv260x:haptics"' <<<"$input_text" || true)
if ((haptic_count == 2)); then
	ybv_emit input haptics PASS 'Both DRV2604 haptic input devices are present' '2 devices'
else
	ybv_emit input haptics FAIL 'The dual DRV2604 haptic layout is incomplete' "$haptic_count of 2 devices"
fi
pen_present=false
if grep -Eiq 'Wacom HID 169 Pen|Wacom.*Pen' <<<"$input_text"; then
	pen_present=true
	ybv_emit input wacom-pen PASS 'Wacom pen input is present'
else
	ybv_emit input wacom-pen SKIP 'Wacom pen input is not active; switch the Halo surface to pen mode to inspect it'
fi
check_input_pattern touchscreen 'Display touchscreen input' 'HDP0001:00[[:space:]]+2ABB:8102|HiDeep.*2ABB:8102'
lid_count=$(grep -Fc 'N: Name="Lid Switch"' <<<"$input_text" || true)
gpio_key_count=$(grep -Fc 'N: Name="gpio-keys"' <<<"$input_text" || true)
if ((lid_count >= 1 && gpio_key_count >= 2)); then
	ybv_emit input platform-controls PASS 'Lid and tablet hardware-button inputs are present' "lid=$lid_count gpio-keys=$gpio_key_count"
else
	ybv_emit input platform-controls FAIL 'Lid or tablet hardware-button inputs are incomplete' "lid=$lid_count gpio-keys=$gpio_key_count"
fi

if [[ $YBV_SYSROOT != / ]]; then
	ybv_emit input halo-service SKIP 'Live Halo keyboard service inspection is unavailable'
elif ybv_has_command systemctl && systemctl is-active --quiet halo-keyboard.service; then
	ybv_emit input halo-service PASS 'Halo keyboard service is active'
else
	ybv_emit input halo-service FAIL 'Halo keyboard service is not active'
fi
if [[ -e $(ybv_path /dev/halo_keyboard) ]]; then
	ybv_emit input halo-device PASS 'Halo keyboard source device exists'
else
	ybv_emit input halo-device FAIL 'Halo keyboard source device is missing'
fi

iio_root=$(ybv_path /sys/bus/iio/devices)
iio_count=0
declare -A iio_counts=([als]=0 [accel_3d]=0 [hinge]=0 [sx9310]=0)
for iio_name in "$iio_root"/iio:device*/name; do
	[[ -r $iio_name ]] || continue
	iio_count=$((iio_count + 1))
	read -r sensor_name <"$iio_name" || true
	if [[ -v iio_counts[$sensor_name] ]]; then
		iio_counts[$sensor_name]=$((iio_counts[$sensor_name] + 1))
	fi
done
sensor_layout="als=${iio_counts[als]} accel_3d=${iio_counts[accel_3d]} hinge=${iio_counts[hinge]} sx9310=${iio_counts[sx9310]}"
if ((iio_counts[als] >= 2 && iio_counts[accel_3d] >= 4 && iio_counts[hinge] >= 2 && iio_counts[sx9310] >= 1)); then
	ybv_emit sensors iio-layout PASS 'The complete Yoga Book IIO sensor layout is present' "$sensor_layout"
elif ((iio_count > 0)); then
	ybv_emit sensors iio-layout FAIL 'The Yoga Book IIO sensor layout is incomplete' "$sensor_layout"
else
	ybv_emit sensors iio-layout FAIL 'No IIO sensor devices are present' "$sensor_layout"
fi
if [[ $YBV_SYSROOT != / ]]; then
	ybv_emit sensors sensor-proxy SKIP 'Live iio-sensor-proxy inspection is unavailable'
elif ybv_has_command systemctl && systemctl is-active --quiet iio-sensor-proxy.service; then
	ybv_emit sensors sensor-proxy PASS 'iio-sensor-proxy is active'
else
	ybv_emit sensors sensor-proxy WARN 'iio-sensor-proxy is not active'
fi
if [[ $YBV_SYSROOT == / ]] && ybv_has_command busctl; then
	proxy_accel=$(busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy HasAccelerometer 2>/dev/null || true)
	proxy_light=$(busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy HasAmbientLight 2>/dev/null || true)
	proxy_proximity=$(busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy HasProximity 2>/dev/null || true)
	if [[ $proxy_accel == 'b true' && $proxy_light == 'b true' && $proxy_proximity == 'b true' ]]; then
		ybv_emit sensors sensor-proxy-capabilities PASS 'SensorProxy exposes accelerometer, ambient-light and proximity data'
	else
		ybv_emit sensors sensor-proxy-capabilities FAIL 'SensorProxy capabilities are incomplete' "accel=$proxy_accel light=$proxy_light proximity=$proxy_proximity"
	fi
else
	ybv_emit sensors sensor-proxy-capabilities SKIP 'Live SensorProxy capability inspection is unavailable'
fi

if [[ $YBV_SYSROOT == / ]] && ybv_has_command udevadm; then
	udev_properties=$(udevadm info --export-db 2>/dev/null || true)
	display_accels=$(grep -c '^E: ACCEL_LOCATION=display$' <<<"$udev_properties" || true)
	base_accels=$(grep -c '^E: ACCEL_LOCATION=base$' <<<"$udev_properties" || true)
	matrices=$(grep -c '^E: ACCEL_MOUNT_MATRIX=' <<<"$udev_properties" || true)
	if ((display_accels >= 2 && base_accels >= 2 && matrices >= 4)); then
		ybv_emit sensors accel-policy PASS 'Display/base accelerometers have mount-matrix policy' "display=$display_accels base=$base_accels matrices=$matrices"
	else
		ybv_emit sensors accel-policy FAIL 'Accelerometer classification or mount matrices are incomplete' "display=$display_accels base=$base_accels matrices=$matrices"
	fi
	if grep -Fq 'E: PROXIMITY_NEAR_LEVEL=96' <<<"$udev_properties"; then
		ybv_emit sensors proximity-policy PASS 'SX9310 proximity near threshold is configured' '96'
	else
		ybv_emit sensors proximity-policy FAIL 'SX9310 proximity near threshold is not configured'
	fi
	if [[ $pen_present != true ]]; then
		ybv_emit input pen-calibration SKIP 'Pen calibration is checked when the Wacom device is active'
	elif grep -Fq 'E: LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1' <<<"$udev_properties"; then
		ybv_emit input pen-calibration PASS 'YB1-X91L Wacom calibration matrix is active' '0 1 0 -1 0 1'
	else
		ybv_emit input pen-calibration FAIL 'YB1-X91L Wacom calibration matrix is not active'
	fi
else
	ybv_emit sensors accel-policy SKIP 'Live udev sensor policy inspection is unavailable'
	ybv_emit sensors proximity-policy SKIP 'Live udev proximity policy inspection is unavailable'
	ybv_emit input pen-calibration SKIP 'Live udev pen calibration inspection is unavailable'
fi

if [[ $YBV_SYSROOT == / ]] && ybv_has_command systemctl; then
	if systemctl is-active --quiet yogabook-gnss.service && systemctl is-active --quiet gpsd.socket; then
		ybv_emit gnss services PASS 'Yoga Book GNSS transport and gpsd socket are active'
	else
		ybv_emit gnss services FAIL 'Yoga Book GNSS transport or gpsd socket is not active'
	fi
	gnss_pipe=/var/lib/yogabook-gnss/root/data/gps/nmeapipe
	if [[ -p $gnss_pipe ]]; then
		ybv_emit gnss nmea-pipe PASS 'GNSS NMEA transport pipe is present' "$gnss_pipe"
	else
		ybv_emit gnss nmea-pipe FAIL 'GNSS NMEA transport pipe is missing' "$gnss_pipe"
	fi
else
	ybv_emit gnss services SKIP 'Live GNSS service inspection is unavailable'
	ybv_emit gnss nmea-pipe SKIP 'Live GNSS transport inspection is unavailable'
fi

pci_root=$(ybv_path /sys/bus/pci/devices)
wifi_pci=
usb_pci=
for pci_device in "$pci_root"/*; do
	[[ -r $pci_device/vendor && -r $pci_device/device ]] || continue
	read -r pci_vendor <"$pci_device/vendor"
	read -r pci_id <"$pci_device/device"
	[[ $pci_vendor == 0x14e4 && $pci_id == 0x43ec ]] && wifi_pci=$pci_device
	[[ $pci_vendor == 0x8086 && $pci_id == 0x22b5 ]] && usb_pci=$pci_device
done
if [[ -n $wifi_pci ]]; then
	wifi_driver=$(basename "$(readlink -f "$wifi_pci/driver" 2>/dev/null || true)")
	if [[ $wifi_driver == brcmfmac ]]; then
		ybv_emit wireless wifi-driver PASS 'BCM4356 Wi-Fi uses brcmfmac' "${wifi_pci##*/}"
	else
		ybv_emit wireless wifi-driver FAIL 'BCM4356 Wi-Fi is not bound to brcmfmac' "driver=${wifi_driver:-none}"
	fi
else
	ybv_emit wireless wifi-driver FAIL 'BCM4356 Wi-Fi PCI function is missing'
fi
wifi_interface=
for interface in "$(ybv_path /sys/class/net)"/*; do
	[[ -d $interface/wireless ]] || continue
	wifi_interface=${interface##*/}
	wifi_state=$([[ -r $interface/operstate ]] && cat "$interface/operstate" || echo unknown)
	break
done
if [[ -n $wifi_interface ]]; then
	ybv_emit wireless wifi-interface PASS 'A Wi-Fi network interface is exposed' "$wifi_interface state=$wifi_state"
else
	ybv_emit wireless wifi-interface FAIL 'No Wi-Fi network interface is exposed'
fi

bluetooth_root=$(ybv_path /sys/class/bluetooth)
bluetooth_controller=
for controller in "$bluetooth_root"/hci*; do
	[[ -e $controller ]] || continue
	bluetooth_controller=${controller##*/}
	break
done
if [[ -n $bluetooth_controller ]]; then
	ybv_emit wireless bluetooth-controller PASS 'Bluetooth controller is exposed' "$bluetooth_controller"
else
	ybv_emit wireless bluetooth-controller FAIL 'Bluetooth controller is missing'
fi
if [[ $YBV_SYSROOT == / ]] && ybv_has_command systemctl; then
	if systemctl is-active --quiet bluetooth.service; then
		ybv_emit wireless bluetooth-service PASS 'Bluetooth service is active'
	else
		ybv_emit wireless bluetooth-service WARN 'Bluetooth service is not active'
	fi
else
	ybv_emit wireless bluetooth-service SKIP 'Live Bluetooth service inspection is unavailable'
fi

if [[ -n $usb_pci ]]; then
	usb_driver=$(basename "$(readlink -f "$usb_pci/driver" 2>/dev/null || true)")
	if [[ $usb_driver == xhci_hcd ]]; then
		ybv_emit usb controller PASS 'Intel USB controller uses xhci_hcd' "${usb_pci##*/}"
	else
		ybv_emit usb controller FAIL 'Intel USB controller is not bound to xhci_hcd' "driver=${usb_driver:-none}"
	fi
else
	ybv_emit usb controller FAIL 'Intel USB controller is missing'
fi

mmc_root=$(ybv_path /sys/block)
emmc_device=
sd_device=
for block_device in "$mmc_root"/mmcblk*; do
	[[ -r $block_device/device/type ]] || continue
	read -r mmc_type <"$block_device/device/type"
	case $mmc_type in
	MMC) [[ -z $emmc_device ]] && emmc_device=${block_device##*/} ;;
	SD) [[ -z $sd_device ]] && sd_device=${block_device##*/} ;;
	esac
done
if [[ -n $emmc_device ]]; then
	ybv_emit storage emmc PASS 'Internal eMMC storage is exposed' "$emmc_device"
else
	ybv_emit storage emmc FAIL 'Internal eMMC storage is missing'
fi
sd_host=$(ybv_path /sys/class/mmc_host/mmc1)
if [[ -e $sd_host ]]; then
	ybv_emit storage sd-slot PASS 'The external SD host controller is exposed' 'mmc1'
else
	ybv_emit storage sd-slot FAIL 'The external SD host controller is missing'
fi
if [[ -n $sd_device ]]; then
	ybv_emit storage sd-card PASS 'An SD card is detected' "$sd_device"
else
	ybv_emit storage sd-card SKIP 'No SD card is inserted; media transport was not tested'
fi

if ybv_has_command lsusb && lsusb -d 8087:0911 >/dev/null 2>&1; then
	ybv_emit modem xmm-usb PASS 'XMM7260 modem is in operational USB mode' '8087:0911'
elif ybv_has_command lsusb && lsusb | grep -Eqi '8087:(07ed|095a)'; then
	ybv_emit modem xmm-usb WARN 'XMM7260 is present but not in final operational mode'
else
	ybv_emit modem xmm-usb WARN 'XMM7260 USB function was not detected'
fi

if ybv_has_command mmcli && modem_path=$(mmcli -L 2>/dev/null | sed -n 's#.*\(/org/freedesktop/ModemManager1/Modem/[0-9][0-9]*\).*#\1#p' | head -n1) && [[ -n $modem_path ]]; then
	modem_id=${modem_path##*/}
	modem_info=$(mmcli -m "$modem_id" 2>&1 || true)
	ybv_emit modem modemmanager PASS 'ModemManager exposes the XMM7260 modem' "modem $modem_id"
	if grep -Eiq 'primary sim path:[[:space:]]*--|SIM missing|sim-missing' <<<"$modem_info"; then
		ybv_emit modem sim SKIP 'No SIM is installed; network registration is not required'
	else
		ybv_emit modem sim PASS 'A SIM is exposed by ModemManager'
	fi
	printf '\n===== ModemManager =====\n%s\n' "$modem_info" >>"$YBV_LOG"
else
	ybv_emit modem modemmanager WARN 'ModemManager does not expose a modem'
fi

video_root=$(ybv_path /dev)
video_count=0
for video_device in "$video_root"/video*; do
	[[ -e $video_device ]] && video_count=$((video_count + 1))
done
if ((video_count > 0)); then
	ybv_emit camera video-nodes PASS 'Camera/video device nodes are present' "$video_count nodes"
else
	ybv_emit camera video-nodes FAIL 'No camera/video device node is present'
fi
if [[ $YBV_SYSROOT == / ]] && ybv_has_command media-ctl; then
	media_graph=$(timeout 10 media-ctl --print-topology 2>&1 || true)
	printf '\n===== Camera media topology =====\n%s\n' "$media_graph" >>"$YBV_LOG"
	if grep -Fq 'driver          atomisp-isp2' <<<"$media_graph"; then
		ybv_emit camera atomisp PASS 'AtomISP media controller is present'
	else
		ybv_emit camera atomisp FAIL 'AtomISP media controller is missing'
	fi
	if grep -Fq 'ov2740 2-0010' <<<"$media_graph"; then
		ybv_emit camera front-sensor PASS 'OV2740 front camera sensor is present'
	else
		ybv_emit camera front-sensor FAIL 'OV2740 front camera sensor is missing'
	fi
	if grep -Fq 'ov8858 2-0036' <<<"$media_graph"; then
		ybv_emit camera rear-sensor PASS 'OV8858 rear camera sensor is present'
	else
		ybv_emit camera rear-sensor FAIL 'OV8858 rear camera sensor is missing'
	fi
else
	ybv_emit camera atomisp SKIP 'Camera media topology inspection is unavailable'
	ybv_emit camera front-sensor SKIP 'Front camera identity inspection is unavailable'
	ybv_emit camera rear-sensor SKIP 'Rear camera identity inspection is unavailable'
fi

battery_root=$(ybv_path /sys/class/power_supply)
battery=
charger=
for candidate in "$battery_root"/*; do
	[[ -d $candidate && -r $candidate/type ]] || continue
	power_type=$(<"$candidate/type")
	if [[ $power_type == Battery && -z $battery ]]; then
		battery=$candidate
	elif [[ $power_type == USB || $power_type == Mains ]]; then
		charger=$candidate
	fi
done
if [[ -n $battery ]]; then
	capacity=$([[ -r $battery/capacity ]] && cat "$battery/capacity" || echo unknown)
	status=$([[ -r $battery/status ]] && cat "$battery/status" || echo unknown)
	ybv_emit power battery PASS 'Battery is exposed' "$capacity% $status"
else
	ybv_emit power battery FAIL 'Battery power-supply device is missing'
fi
if [[ -n $charger ]]; then
	online=$([[ -r $charger/online ]] && cat "$charger/online" || echo unknown)
	if [[ $online == 1 ]]; then
		ybv_emit power charger PASS 'External power/charger is online' "${charger##*/}"
	else
		ybv_emit power charger INFO 'External power/charger is currently offline' "${charger##*/}"
	fi
else
	ybv_emit power charger WARN 'No USB or mains power-supply device is exposed'
fi

backlight_root=$(ybv_path /sys/class/backlight)
backlight=
for candidate in "$backlight_root"/*; do [[ -d $candidate ]] && { backlight=$candidate; break; }; done
if [[ -n $backlight && -r $backlight/brightness && -r $backlight/max_brightness ]]; then
	brightness=$(<"$backlight/brightness")
	max_brightness=$(<"$backlight/max_brightness")
	ybv_emit display backlight PASS 'Panel backlight control is exposed' "$brightness/$max_brightness"
else
	ybv_emit display backlight FAIL 'Panel backlight control is missing'
fi
panel_root=$(ybv_path /sys/class/drm)
panel=
for connector in "$panel_root"/card*-DSI-*; do
	[[ -e $connector ]] || continue
	panel=$connector
	break
done
if [[ -n $panel ]]; then
	panel_status=$([[ -r $panel/status ]] && cat "$panel/status" || echo unknown)
	panel_enabled=$([[ -r $panel/enabled ]] && cat "$panel/enabled" || echo unknown)
	panel_modes=$([[ -r $panel/modes ]] && tr '\n' ',' <"$panel/modes" || true)
	if [[ $panel_status == connected && $panel_enabled == enabled ]]; then
		ybv_emit display panel PASS 'Internal DSI panel is connected and enabled' "${panel##*/} modes=${panel_modes%,}"
	else
		ybv_emit display panel FAIL 'Internal DSI panel is not active' "status=$panel_status enabled=$panel_enabled"
	fi
else
	ybv_emit display panel FAIL 'Internal DSI panel connector is missing'
fi
led_root=$(ybv_path /sys/class/leds)
missing_leds=()
for led in 'platform::charging' 'platform::indicator' 'ybwmi::kbd_backlight'; do
	[[ -d $led_root/$led ]] || missing_leds+=("$led")
done
if ((${#missing_leds[@]} == 0)); then
	ybv_emit platform leds PASS 'Charging, indicator and Halo backlight LEDs are exposed'
else
	ybv_emit platform leds FAIL 'Platform LED controls are incomplete' "missing: ${missing_leds[*]}"
fi
if [[ $YBV_SYSROOT == / ]] && ybv_has_command gsettings; then
	ambient_enabled=$(gsettings get org.gnome.settings-daemon.plugins.power ambient-enabled 2>/dev/null || echo unknown)
	light_level=
	if ybv_has_command busctl; then
		light_level=$(busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy LightLevel 2>/dev/null | awk '{print $2}' || true)
	fi
	if [[ $ambient_enabled == true ]]; then
		ybv_emit display auto-brightness INFO 'GNOME automatic brightness is enabled' "ambient light=${light_level:-unknown} lux"
	else
		ybv_emit display auto-brightness INFO 'GNOME automatic brightness is disabled' "$ambient_enabled"
	fi
else
	ybv_emit display auto-brightness SKIP 'Desktop automatic-brightness setting is unavailable'
fi

if [[ $YBV_SYSROOT == / ]] && ybv_has_command journalctl; then
	kernel_log="$YBV_REPORT_DIR/kernel-journal.log"
	journalctl -b -k --no-pager >"$kernel_log" 2>&1 || true
	fatal_pattern='sof.*(ipc|firmware|topology).*(error|fail|timeout)|STREAM_PCM_PARAMS.*(error|fail)|BUG:|kernel panic|Call Trace:|I/O error.*(mmc|nvme)'
	fatal_lines=$(grep -Ei "$fatal_pattern" "$kernel_log" || true)
	if [[ -z $fatal_lines ]]; then
		ybv_emit platform kernel-fatal-scan PASS 'No targeted fatal errors in the current boot journal'
	else
		ybv_emit platform kernel-fatal-scan FAIL 'Current boot journal contains targeted fatal errors' "$(head -n 1 <<<"$fatal_lines")"
	fi
else
	ybv_emit platform kernel-fatal-scan SKIP 'Kernel journal scan is unavailable'
fi

ybv_capture 'PCI devices' lspci -nnk
ybv_capture 'USB devices' lsusb
ybv_capture 'Input devices' cat "$input_devices"
ybv_capture 'IIO devices' sh -c 'for f in "$1"/iio:device*/name; do test -r "$f" && printf "%s: " "$f" && cat "$f"; done' sh "$iio_root"

ybv_finish_report
