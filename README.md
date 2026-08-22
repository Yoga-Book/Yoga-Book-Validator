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
- SOF firmware/topology, the `yogabook` ALSA card, UCM devices, PipeWire and
  raw speaker state;
- Halo keyboard/touchpad/haptics, Wacom pen and display touchscreen presence;
- the exact Halo keyboard, touchpad, dual-haptic and IIO sensor layout;
- Wi-Fi, Bluetooth, eMMC, SD slot/card, USB, DSI display and platform LEDs;
- XMM7260/ModemManager, adapting expectations when no SIM is installed;
- GNSS transport, both camera sensors, battery and charging;
- direct PCM formats, microphone signal and audio across suspend/resume;
- live data from every IIO sensor channel and state-restoring panel, Halo,
  indicator and charging light controls;
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
sudo apt install ../yogabook-validator_0.5.0_all.deb
```

Open **Yoga Book Validator** from the application menu, or run:

```bash
yogabook-validator check
yogabook-validator audio
yogabook-validator camera
yogabook-validator haptics
yogabook-validator lights
yogabook-validator sensors
yogabook-validator storage
yogabook-validator suspend 8
yogabook-validator wireless
yogabook-validator gnss
yogabook-validator physical
```

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

The wireless test sends three packets only to the current Wi-Fi gateway. It
briefly unblocks, powers and scans with Bluetooth without pairing, then restores
the original Bluetooth power and rfkill state. Nearby device identities are
discarded rather than written to reports. The storage test performs a
bounded raw read and mounts recognized SD filesystems with read-only, nodev,
nosuid and noexec options. It never writes to removable media and removes every
temporary mount in its exit trap.

## Commands

`check` performs the read-only full-stack audit. `audio` tests PCM0 playback and
capture in S16_LE, S24_LE and S32_LE at 48 kHz stereo, PCM1 deep-buffer
playback, the bounded tone, and non-empty Mic1 capture. `camera` switches the
AtomISP media route, captures three frames from each sensor to `/dev/null`, and
restores the original route. `haptics` plays one bounded 150 ms pulse on each
actuator at moderate strength. `storage` validates an inserted SD card without
writing. `sensors` samples the complete IIO layout and SensorProxy. `lights`
exercises and restores the display, Halo, indicator and charging light control
paths. `wireless` checks the current Wi-Fi gateway and bounded Bluetooth
discovery while restoring radio state. `suspend` keeps silent
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
