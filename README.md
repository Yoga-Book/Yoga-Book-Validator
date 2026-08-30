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
  fatal journal signatures, plus installed integration-package integrity;
- Cherry Trail SoC drivers, CPU frequency/idle states, thermal sensors and
  cooling devices, eMMC health, root filesystem, periodic discard and RTC wake;
- effective thermald sensor bindings, four-core critical limits, live thermal
  margins and bounded CPU, memory, task and restart use for Yoga Book services;
- SOF firmware/topology, the `yogabook` ALSA card, UCM devices, PipeWire and
  raw speaker state;
- Halo keyboard/touchpad/haptics, Wacom pen and display touchscreen presence
  and kernel capability maps;
- the exact Halo keyboard, touchpad, dual-haptic and IIO sensor layout;
- Wi-Fi, Bluetooth, eMMC, SD slot/card, xHCI/USB role and device topology,
  DSI display, Micro-HDMI video/audio transport and platform LEDs;
- XMM7260/ModemManager, adapting expectations when no SIM is installed;
- GNSS transport, both camera sensors, battery and charging;
- BQ27542 fuel-gauge, BQ25892 charger and UPower telemetry consistency;
- direct PCM formats, microphone signal and audio across suspend/resume;
- live data from every IIO sensor channel and state-restoring panel, Halo,
  indicator and charging light controls;
- i915/DRM render access, the native DSI panel, Micro-HDMI connector and LPE
  audio PCMs, GNOME Shell GPU use, Mutter landscape layout,
  rotation/brightness policy and targeted display faults;
- guided physical acceptance for behavior software cannot prove.

Automated results never imply that a speaker, microphone, pen, camera, sensor,
radio, removable-media slot or hardware button works physically. Every report
therefore contains separate `AUTOMATED_RESULT` and
`PHYSICAL_ACCEPTANCE_RESULT` values.

The authoritative [coverage matrix](docs/coverage.md) defines which automated,
interactive and physical evidence is required before a component can be
considered fully validated. A skipped conditional test is visible incomplete
coverage, never an implicit pass.

## Install

Build on Debian or Ubuntu:

```bash
sudo apt install debhelper devscripts shellcheck python3
make test
make deb
sudo apt install ../yogabook-validator_0.45.0_all.deb
```

Open **Yoga Book Validator** from the application menu, or run:

```bash
yogabook-validator automated
yogabook-validator check
yogabook-validator passive
yogabook-validator category recommended
yogabook-validator category audio-media
yogabook-validator category input-modes
yogabook-validator category platform-power
yogabook-validator category connectivity-storage
yogabook-validator category reliability
yogabook-validator audio
yogabook-validator camera
yogabook-validator display
yogabook-validator dossier REPORT_DIRECTORY... --output DOSSIER_DIRECTORY
yogabook-validator haptics
yogabook-validator headset
yogabook-validator inputs
yogabook-validator controls
yogabook-validator lights
yogabook-validator modem
yogabook-validator modes
yogabook-validator rotation
yogabook-validator platform
yogabook-validator power
yogabook-validator quiet
yogabook-validator resources
yogabook-validator sensors
yogabook-validator stability start 3
yogabook-validator stability check
yogabook-validator stability status
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

The UI and CLI save one evidence directory per run. `results.tsv` and
`validator.log` remain the raw authoritative evidence. Every completed run also
produces a versioned `report.json`, a readable `report.md`, a self-contained
`report.html`, and a privacy-safe `environment.tsv`. The generated diagnostic
report separates individual checks from suite roll-ups, so a failed subsystem
is not counted twice; it includes coverage, subsystem health, prioritized
findings, suggested next actions, and SHA-256 hashes for the raw evidence.
It also evaluates all 23 hardware components against the structural,
functional and physical layers in the coverage matrix. A component contributes
to acceptance readiness only when every required selector is present and
passes; missing runnable evidence is `NOT_RUN`, unavailable test coverage is
`UNIMPLEMENTED`, and skipped evidence is `INCOMPLETE`. The conservative overall
readiness remains unchanged, while separate structural, functional and physical
readiness metrics show exactly which evidence layer is complete without
promoting a partially validated component.

Use `yogabook-validator report DIRECTORY` to regenerate the derived formats
from an older raw report. Active hardware tests and category suites ask for
confirmation and Polkit authorization. The quick passive audit and full
passive suite need neither.

Every UI category has a compact **Run all checks** action in its header.
Compatible checks execute in a deterministic sequence, share one report and
request administrator access once. While a category is active, its header
spinner remains visible and the currently executing validation row shows its
own spinner before resolving to its individual pass/fail status.
`category recommended` runs the union of the overlapping recommended workflows
without repeating their checks. The reliability category performs suspend/resume and
then starts, advances or confirms the persistent cold-boot workflow; when a
physical cold boot is still required, it records SKIP instead of manufacturing
a same-boot failure. Physical acceptance uses its single guided form because
all checks require operator observation.

Cold-boot stability tracking is read-only and never reboots or changes GRUB.
`stability start 3` validates and records the current kernel, boot ID, SOF
firmware and topology as the baseline. After each physical power-off/power-on,
run `stability check`; it accepts a new boot ID only once and revalidates the
kernel and audio integration before advancing the counter. A boot-ID change
cannot distinguish a cold boot from an ordinary reboot, so the operator must
perform the physical power cycle. `stability status` never changes progress.

## Safety model

Every command captures a deterministic mutable-state snapshot before running
and compares it after cleanup. The contract covers backlight and stable LED
policy, Bluetooth/rfkill, Yoga Book and desktop-audio service state, writable
ALSA controls, the active desktop audio profile, orientation settings, Mutter layout,
removable-media mounts and Validator temporary mounts. A mismatch is a real
`validator/state-preservation` failure with `state-before.tsv`,
`state-after.tsv` and `state-diff.txt` evidence. State-changing runners also
register an idempotent cleanup callback that runs before the comparison, on
both successful and failed checks; their existing exit traps remain the final
safety net for interruption.
The live Halo backlight level is excluded from the generic comparison because
the keyboard service changes it asynchronously for idle and mode transitions;
the dedicated `lights` action snapshots, exercises, restores and verifies that
control explicitly.

The audio and suspend helper is restricted to YB1-X91L by DMI. Before stopping
WirePlumber it snapshots the live ALSA state. It restores that state and starts
the user's complete PipeWire, Pulse and WirePlumber graph on success, failure,
interruption, or timeout.
Saving before WirePlumber stops is essential: closing the UCM session can
temporarily disable `Speaker Switch`, and persisting that transient state would
leave the tablet silent.

The tone is a bounded one-second 440 Hz WAV at 8% digital amplitude. Before an
audible speaker or headset probe, the Validator caps the PCM master at -16 dB
and the codec DAC at 0 dB without ever raising a quieter existing value. If
either cap cannot be read, applied and verified, playback is aborted. Transport
matrix playback uses digital silence. Suspend validation also disables the
physical speaker route while its direct stream crosses sleep, then restores
the saved mixer state. Report bundles exclude WAV recordings
and ALSA state snapshots because they may contain personal or machine-specific
data.

The camera test requests administrator authorization because physical AtomISP
nodes are intentionally private to the system image processor. It records the
active processor and sensor state, pauses the processor, captures three frames
from each sensor into bounded process memory, checks complete payloads,
luminance variation and frame-to-frame change, then immediately discards the
bytes. It also moves the WV517S rear focus actuator by one position and restores
the original position. It restores focus, the selected V4L2 input and the
processor service on success, failure, interruption, or timeout and never
stores or logs an image.

The sensor test reads every raw ALS, accelerometer, hinge-angle and proximity
channel and confirms that SensorProxy returns live desktop values. The lights
test changes each brightness by only one step, then restores the panel and all
LED brightness and trigger values even if the test is interrupted.

The input-capability test opens event nodes read-only and validates the key,
switch, absolute-axis and force-feedback features exposed by the kernel. It
does not grab devices, monitor events, record user input or inject events.

The guided controls test verifies behavior beyond static capability maps. It
opens only the two GPIO button devices and the lid switch, applies exclusive
input grabs so Power and lid events cannot trigger desktop actions, then asks
for one Power press, both Volume presses and one lid close/reopen cycle. A
`finally` cleanup releases every grab on success, timeout or error; closing the
process also makes the kernel release all file-descriptor-owned grabs. The
report keeps these functional events separate from the operator's physical
assessment of the resulting controls.

The mode-cycle test starts in Halo keyboard mode and waits for the user to
switch physically to drawing/pen mode and back. It verifies Wacom position,
pressure, tool and touch capabilities, the libinput calibration matrix, Halo
service recovery, display touchscreen presence, Mutter logical display state,
GNOME orientation-lock and onscreen-keyboard settings, and transition-time
kernel errors. Mode entry and return must remain stable for two seconds before
they are accepted. A 100 ms synchronized trace records SensorProxy orientation,
Mutter transform, Halo service/devices and Wacom presence in
`mode-transition.tsv`; it never reads keys, touches or pen strokes. Because this test
requires physical action, it is intentionally excluded from `automated`.

The automatic-rotation test extends the same state-safe mode cycle. In pen
mode it asks the user to rotate the tablet through all four cardinal
orientations and return it upright. Each SensorProxy orientation must remain
stable with the corresponding Mutter transform before it is accepted. The
test observes and reports desktop policy; it never applies a display transform.

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

The resource test is also read-only and unprivileged. It samples cumulative
systemd CPU accounting for three seconds, checks memory and task headroom, and
verifies the packaged cgroup limits for the Halo keyboard, camera processor and
GNSS transport. It checks thermald's effective sensor bindings, hardware CPU
critical limits, available cooling devices and current platform, battery and
charger temperatures. It reports unsafe or implausible state but never changes
CPU, charging, cooling or service policy.

The USB test validates both xHCI root hubs, the Intel role switch and the fixed
XMM7260 `cdc_mbim` transport. It validates attached removable devices without
logging their identity, or records SKIP when no OTG accessory is connected.

The automated suite requests authorization once, runs all transport checks in
a deterministic order, preserves every subreport and creates a merged
`results.tsv`. It continues after failures so the report contains complete
evidence. Suspend remains opt-in, while the guided wired-headset workflow is a
separate action and part of the Audio/Media category.

`quiet` requests authorization once and runs the complete non-audible automated
subset: passive diagnostics, cameras, input capability inspection, read-only SD
validation, Wi-Fi/Bluetooth, reversible lights and service final-state checks.
It excludes every playback, capture, headset, haptic, suspend and guided action
by construction while retaining cancellation and per-subtest restoration.

`dossier` combines explicitly selected reports from the same Validator release
into one acceptance matrix. Before using any evidence it verifies the report
schema, Validator version, acceptance-matrix digest, device/OS/architecture and
the SHA-256 metadata for every required source artifact. `sources.tsv` records
the source label, command, boot, timestamps and content digests without leaking
absolute filesystem paths. Duplicate observations remain visible and the most
severe result wins, so composing reports can never turn an older failure into a
pass. Reports from another release or device, and modified artifacts, are
rejected instead of silently mixed.

The LTE test never enables, connects or disconnects the modem. Without a SIM it
records explicit conditional skips. With a SIM it requires an already
registered modem and connected bearer, then sends three packets through that
bearer's interface to its gateway (or a fixed public probe when no gateway is
reported). No IMSI, IMEI, APN or operator identity is retained in reports.

The wired-headset test is conditional and exits before opening any PCM unless
both four-pole jack sensors report an inserted headset. It enables only the UCM
`Headphones` and `Headset` routes, verifies that the physical speakers remain
muted, plays one quiet one-second tone, analyzes a three-second microphone
capture, then guides one removal, reinsertion and supported button press. The
event device is never grabbed and the run completes only after the headset is
inserted again. ALSA and desktop audio are restored and verified with a silent
transport probe.

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
`check` performs the quick read-only full-stack audit. `passive` merges the
quick audit with the deeper platform, display, sensor, power, USB and GNSS
checks without administrator access or state changes. `audio` tests PCM0 playback and
capture in S16_LE, S24_LE and S32_LE at 48 kHz stereo, PCM1 deep-buffer
playback, the bounded tone, and non-empty Mic1 capture. `camera` pauses the
desktop image processor, switches the private AtomISP input, validates three
in-memory frames from each sensor for
payload and signal integrity, exercises one bounded rear-focus step, discards
the frames and restores the original focus, input and processor state.
`display` inspects the live i915, DSI, Micro-HDMI DRM and LPE audio, Mutter and
GNOME Shell display stack without changing it. With Micro-HDMI connected it
requires an active mode and valid ALSA ELD audio negotiation, but never plays
sound. `haptics` plays one bounded 150 ms pulse on each
actuator at moderate strength. `headset` validates a connected four-pole
headset's isolated playback, microphone signal and removal/reinsertion/button
events. `inputs` audits kernel capability maps without
reading events. `controls` suppresses desktop actions while observing one
Power, Volume Up, Volume Down and lid close/reopen cycle. `modes` observes one
physical Halo keyboard to Wacom pen to
Halo keyboard cycle and accepts `--timeout SECONDS`. `rotation` extends that
cycle and requires all four sensor orientations to match stable Mutter
transforms before returning upright. `storage` validates an
inserted SD card without writing. `storage-write` performs the separately
confirmed bounded SD write/read/delete check. `platform` validates the SoC
driver set, CPU power management, thermal stack, eMMC health, root filesystem
and RTC wake capability. `power`
validates battery, charger and UPower telemetry. `resources` profiles the three
Yoga Book resident services and audits thermal safeguards without changing
policy. `sensors`
samples the complete IIO layout and SensorProxy. `lights`
exercises and restores the display, Halo, indicator and charging light control
paths. `usb` audits the host hubs, role switch, fixed modem path, attached
accessories and targeted kernel errors. `modem` validates SIM registration and
packet replies over an already-connected LTE bearer without changing modem or
NetworkManager state. `wireless` checks the current Wi-Fi
gateway, Bluetooth controller features and bounded RF discovery while
restoring radio state. `quiet` merges all non-audible automated diagnostics
into one report without scheduling playback, capture, haptics or suspend.
`suspend` keeps hardware-muted full-duplex audio active
across one suspend and reports any recovered ALSA xruns. `gnss` accepts `--require-sky` or
`--require-fix`. `physical` records PASS/FAIL/SKIP observations. `bundle`
compresses an existing report directory while excluding sensitive artifacts.

Run `yogabook-validator --help` for the concise command reference.

## Scope and contributions

This initial release targets YB1-X91L. Read-only checks may be run elsewhere
for development, but active hardware operations refuse unsupported DMI.
Changes should preserve subsystem ownership and must not install quirks,
remove packages, alter GRUB, or deploy firmware. See [ATTRIBUTION.md](ATTRIBUTION.md)
for the source material used to design the checks.
