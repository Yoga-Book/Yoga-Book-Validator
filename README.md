# Yoga Book Validator

Yoga Book Validator is the integration-test suite for the Lenovo Yoga Book
YB1-X91L. It provides one authoritative command-line engine and a
GTK4/libadwaita interface that displays the same structured reports.

The project validates the complete installed system without taking ownership
of any driver or device configuration. Kernel support, Halo input, sensor
policy, SOF topology/firmware, UCM, PipeWire, ModemManager and desktop services
remain in their own packages.

## What it checks

- DMI identity, running and persistent kernel selection, and current-boot
  fatal journal signatures;
- Cherry Trail SoC drivers, CPU frequency/idle states, thermal sensors and
  cooling devices, eMMC health, root filesystem, periodic discard and RTC wake;
- SOF firmware/topology, the `yogabook` ALSA card, UCM devices, PipeWire and
  raw speaker state;
- Halo keyboard/touchpad/haptics, Wacom pen and display touchscreen presence
  and kernel capability maps;
- the exact Halo keyboard, touchpad, dual-haptic and IIO sensor layout;
- Wi-Fi, Bluetooth, eMMC, SD slot/card, xHCI/USB role and device topology,
  DSI display and platform LEDs;
- XMM7260/ModemManager, adapting expectations when no SIM is installed;
- GNSS transport, both camera sensors, battery and charging;
- BQ27542 fuel-gauge, BQ25892 charger and UPower telemetry consistency;
- direct PCM formats, microphone signal and audio across suspend/resume;
- live data from every IIO sensor channel and state-restoring panel, Halo,
  indicator and charging light controls;
- i915/DRM render access, the native DSI panel, GNOME Shell GPU use, Mutter
  landscape layout, rotation/brightness policy and targeted display faults;
- guided physical acceptance for behavior software cannot prove.

Automated results never imply that a speaker, microphone, pen, camera, sensor,
radio, removable-media slot or hardware button works physically. Every report
therefore contains separate `AUTOMATED_RESULT` and
`PHYSICAL_ACCEPTANCE_RESULT` values.

## Install

Build on Debian or Ubuntu:

```bash
sudo apt install debhelper devscripts shellcheck python3
make test
make deb
sudo apt install ../yogabook-validator_0.14.0_all.deb
```

Open **Yoga Book Validator** from the application menu, or run:

```bash
yogabook-validator automated
yogabook-validator check
yogabook-validator audio
yogabook-validator camera
yogabook-validator display
yogabook-validator haptics
yogabook-validator inputs
yogabook-validator lights
yogabook-validator modes
yogabook-validator platform
yogabook-validator power
yogabook-validator sensors
yogabook-validator storage
yogabook-validator storage-write
yogabook-validator suspend 8
yogabook-validator usb
yogabook-validator wireless
yogabook-validator gnss
yogabook-validator physical
```

Add `--include-suspend` to `automated` only when an automatic eight-second
suspend/resume cycle is appropriate.

The UI and CLI save `results.tsv` and `validator.log` under the user's results
directory. The active audio and suspend tests ask for confirmation and Polkit
authorization. The passive audit needs neither.

## Safety model

The audio and suspend helper is restricted to YB1-X91L by DMI. Before stopping
WirePlumber it snapshots the live ALSA state. It restores that state and starts
the user's PipeWire services on success, failure, interruption, or timeout.
Saving before WirePlumber stops is essential: closing the UCM session can
temporarily disable `Speaker Switch`, and persisting that transient state would
leave the tablet silent.

The tone is a bounded one-second 440 Hz WAV at 8% digital amplitude. Transport
matrix playback uses digital silence. Report bundles exclude WAV recordings
and ALSA state snapshots because they may contain personal or machine-specific
data.

The camera test records which AtomISP sensor links were active, streams only to
`/dev/null`, and restores the original links on success, failure, interruption,
or timeout. It never stores an image.

The sensor test reads every raw ALS, accelerometer, hinge-angle and proximity
channel and confirms that SensorProxy returns live desktop values. The lights
test changes each brightness by only one step, then restores the panel and all
LED brightness and trigger values even if the test is interrupted.

The input-capability test opens event nodes read-only and validates the key,
switch, absolute-axis and force-feedback features exposed by the kernel. It
does not grab devices, monitor events, record user input or inject events.

The mode-cycle test starts in Halo keyboard mode and waits for the user to
switch physically to drawing/pen mode and back. It verifies Wacom position,
pressure, tool and touch capabilities, the libinput calibration matrix, Halo
service recovery, display touchscreen presence, Mutter logical display state,
GNOME orientation-lock and onscreen-keyboard settings, and transition-time
kernel errors. It never reads keys, touches or pen strokes. Because this test
requires physical action, it is intentionally excluded from `automated`.

The display test is passive. It validates the i915 DRM card and render node,
the native DSI panel, GNOME Shell's live GPU file descriptors, Mutter's
primary landscape layout, the unlocked rotation policy, the intentionally
disabled aggressive automatic-brightness policy, and targeted display errors.
It does not rotate the screen, change brightness or capture screen contents.

The power test reads the battery fuel gauge and charger without changing any
charging policy. It validates health, electrical and charge-counter ranges,
cross-checks both charger interfaces, and confirms that UPower exposes the
battery to the desktop.

The platform test reads CPU, thermal, RTC, block and kernel status without
changing policy or power state. It reports only eMMC wear indicators and block
properties; card identifiers, serial numbers, CID and manufacturer fields are
never collected.

The USB test validates both xHCI root hubs, the Intel role switch and the fixed
XMM7260 `cdc_mbim` transport. It validates attached removable devices without
logging their identity, or records SKIP when no OTG accessory is connected.

The automated suite requests authorization once, runs all transport checks in
a deterministic order, preserves every subreport and creates a merged
`results.tsv`. It continues after failures so the report contains complete
evidence. Suspend remains opt-in.

The wireless test sends three packets only to the current Wi-Fi gateway. It
briefly unblocks, powers and scans with Bluetooth without pairing, then restores
the original Bluetooth power and rfkill state. Nearby device identities are
discarded rather than written to reports. It validates classic Bluetooth, LE,
security, advertising, privacy and PHY-management capabilities, and reports
only the number of received RF discovery events. The storage test performs a
bounded raw read and mounts recognized SD filesystems with read-only, nodev,
nosuid and noexec options. It never writes to removable media and removes every
temporary mount in its exit trap.

The separate `storage-write` action is never included in `automated`. After
explicit confirmation, it creates one generic 64 KiB test file on each
writable SD filesystem, verifies and synchronizes the contents, removes the
file, and restores the original mount state. It never logs removable-media
identities and does not remount an existing read-only filesystem.

## Commands

`automated` runs every non-suspend automated check and merges its reports.
`check` performs the read-only full-stack audit. `audio` tests PCM0 playback and
capture in S16_LE, S24_LE and S32_LE at 48 kHz stereo, PCM1 deep-buffer
playback, the bounded tone, and non-empty Mic1 capture. `camera` switches the
AtomISP media route, captures three frames from each sensor to `/dev/null`, and
restores the original route. `display` inspects the live i915, DSI, Mutter and
GNOME Shell display stack without changing it. `haptics` plays one bounded 150 ms pulse on each
actuator at moderate strength. `inputs` audits kernel capability maps without
reading events. `modes` observes one physical Halo keyboard to Wacom pen to
Halo keyboard cycle and accepts `--timeout SECONDS`. `storage` validates an
inserted SD card without writing. `storage-write` performs the separately
confirmed bounded SD write/read/delete check. `platform` validates the SoC
driver set, CPU power management, thermal stack, eMMC health, root filesystem
and RTC wake capability. `power`
validates battery, charger and UPower telemetry. `sensors`
samples the complete IIO layout and SensorProxy. `lights`
exercises and restores the display, Halo, indicator and charging light control
paths. `usb` audits the host hubs, role switch, fixed modem path, attached
accessories and targeted kernel errors. `wireless` checks the current Wi-Fi
gateway, Bluetooth controller features and bounded RF discovery while
restoring radio state. `suspend` keeps silent
full-duplex audio active across one suspend. `gnss` accepts `--require-sky` or
`--require-fix`. `physical` records PASS/FAIL/SKIP observations. `bundle`
compresses an existing report directory while excluding sensitive artifacts.

Run `yogabook-validator --help` for the concise command reference.

## Scope and contributions

This initial release targets YB1-X91L. Read-only checks may be run elsewhere
for development, but active hardware operations refuse unsupported DMI.
Changes should preserve subsystem ownership and must not install quirks,
remove packages, alter GRUB, or deploy firmware. See [ATTRIBUTION.md](ATTRIBUTION.md)
for the source material used to design the checks.
