# Yoga Book Validator coverage matrix

This matrix defines the evidence required to claim that a Lenovo Yoga Book
YB1-X91L component works. Presence, package installation and a green passive
probe are necessary but do not replace functional or physical acceptance.
The matching machine-readable selectors in `data/acceptance.json` are evaluated
for every generated report; changes to either representation must keep the same
24 component rows and three evidence layers.

Coverage is complete only when every applicable row has all three evidence
layers satisfied and no required check is `FAIL`, `WARN` or `SKIP`. At the
component level, every layer must therefore be `PASS`; `UNIMPLEMENTED`,
`INCOMPLETE` and `NOT_RUN` are also explicitly blocking:

1. **Structural** — identity, driver, package, topology and service state.
2. **Functional** — bounded data or state transition with cleanup verified.
3. **Physical** — operator-observed behavior that software cannot prove.

Conditional hardware remains incomplete until the prerequisite is supplied.
Examples include a SIM, headphones, an OTG accessory, an HDMI display, an SD
card, the pen-mode transition and an outdoor GNSS fix.

| Component | Structural evidence | Functional evidence | Physical acceptance gate |
|---|---|---|---|
| Boot, kernel and software sources | `check`, isolated `apt` metadata refresh, fallback-safe kernel-selection hook, `platform`, package integrity | Three distinct cold boots with unchanged kernel/firmware/topology | Power-off and power-on were physical; Yoga Book kernel returned |
| DSI display and GPU | `display` DRM, panel, Mutter and compositor checks | `rotation`, `lights`; no critical/repeated display journal failure | Image is stable, correctly oriented and brightness is usable |
| Micro-HDMI | DRM connector and all three LPE PCM nodes | Connected external display exposes a mode and audio route | External picture and sound are observed |
| Halo keyboard and touchpad | `check`, `inputs`, service/device/resource checks | `modes` completes keyboard to pen to keyboard without restart | Keys, touchpad, click and backlight are observed |
| Haptics | Two DRV2604 devices and force-feedback capabilities | `haptics` pulses both actuators and restores state | Both left and right pulses are felt |
| Pen and drawing surface | Wacom capabilities and calibration matrix in pen mode | `modes` proves I2C-HID/Wacom binding, continuous 100 ms presence, disappearance and restored unbound state | Direction, pressure and contact match a drawing application |
| Display touchscreen | Input identity/capabilities in both modes | Presence remains stable across `modes` and `rotation` | Touch position and gestures are observed in both modes |
| Rotation and sensors | Complete IIO layout, policies and SensorProxy capabilities | `sensors` samples every channel; `sensor-interactions` measures response from both ALS and hinge devices plus SX9310; `rotation` proves all transforms | Screen follows all four orientations; ambient-light, proximity and both hinge-angle devices visibly respond to physical changes |
| Speakers and microphones | ALSA/SOF/UCM/PipeWire topology | `audio` validates PCM formats, a quiet bounded tone, and stereo capture transport for signal, clipping, DC offset and imbalance | Stereo speakers and internal microphone are heard/understood |
| Headset path | UCM devices plus jack/button input capabilities | `inputs` and `audio` with a connected headset | Headphones, headset microphone, jack detection and buttons work |
| Cameras | Exact running-kernel headers, `v4l2loopback`, preparation service, named loopback nodes, AtomISP, OV2740, OV8858 and focus control presence | `camera` analyzes changing in-memory frames from both sensors and restores route/focus | Front and rear preview are correctly oriented and usable |
| Wi-Fi | BCM4356/brcmfmac interface and route | `wireless` exchanges packets with the current gateway | Association and sustained real network traffic are observed |
| Bluetooth | Controller, service and classic/LE/security feature set | `wireless` performs bounded RF discovery and restores power/rfkill | Pairing and representative data or audio exchange succeed |
| USB OTG | xHCI hubs, role switch and authorization state | `usb-cycle` proves host role, exactly one authorized enumeration, descriptor transfer, removal, state restoration and a clean kernel log; removable storage also receives a bounded read | The representative accessory works in its intended application |
| Internal eMMC storage | Device identity, transport attributes, lifetime, pre-EOL state and root-filesystem mount | `internal-storage` creates, fsyncs, read-verifies and removes one bounded non-zero 4 MiB file; `platform` verifies discard maintenance and scans the current boot specifically for eMMC/root-filesystem errors | An application can save and reopen data across a physical cold boot |
| SD card | Host, media identity and read-only filesystem validation | `storage-write` writes, verifies, syncs and removes its bounded file | Card insertion/removal and normal application access succeed |
| LTE modem | XMM7260 operational USB mode and ModemManager object | With a SIM, registration and IP traffic are required | LTE data works in the intended coverage area |
| GNSS | UART, verified private runtime, service, FIFO and gpsd | `gnss --require-sky` and `--require-fix` outdoors | A userspace map/location consumer receives a plausible fix |
| Battery and charging | BQ27542/BQ25892 identity and UPower consistency | `power` validates live electrical telemetry; `charging` observes continuity, safe temperatures and charge progression or a stable full terminal state | Cable events and sustained charging are observed |
| Thermals and resources | thermald policy, critical limits and cgroup limits | `resources` samples temperature, CPU, memory, tasks and restarts | No unsafe heat, throttling or instability under representative use |
| Suspend/resume | RTC wake and s2idle plumbing | `suspend` keeps hardware-muted full-duplex transport alive, then verifies display, inputs, sensors, radios, cameras, power, services and applicable storage/modem/GNSS state against a pre-suspend baseline | Display, input, radios and audio work after resume |
| Lid and hardware buttons | Input devices and switch/key capabilities | `controls` observes Power, Volume Up/Down and lid close/reopen while suppressing desktop actions, then releases every grab | Lid, power and volume actions match their intended desktop behavior |
| Indicator and charging LEDs | LED controls and trigger policy | `lights` performs one-step changes and exact cleanup | Visible charging/indicator behavior matches cable and system state |
| Reboot and poweroff | No failed units or fatal current-boot journal events | Reboot returns to the pinned kernel; poweroff terminates cleanly | At least one physical reboot and one full shutdown are observed |

Passing evidence has an explicit freshness contract in `data/acceptance.json`.
Charging, LTE and suspend/resume expire after 24 hours; USB OTG and SD transport
after seven days; physical observations after 30 days unless a shorter
condition-specific override applies. Expiry produces `STALE` acceptance, never
a false failure and never removal of an older FAIL/WARN. Imported physical
observations preserve their original observation timestamp.

## Result policy

- `PASS` proves only the stated check and evidence layer.
- `WARN` preserves a non-fatal anomaly that still requires review.
- `SKIP` means the corresponding coverage is incomplete.
- `INCOMPLETE` means at least one required selector ran but was skipped.
- `NOT_RUN` means a runnable required selector is absent from this report.
- `UNIMPLEMENTED` means the matrix requires evidence that this Validator
  version cannot produce yet; it is an explicit development blocker.
- `FAIL` means the component or a prerequisite is not working.
- `validator/state-preservation` must pass for every state-changing action.
- A category or suite roll-up never replaces its individual check results.

The generated report's coverage percentage measures exercised unique checks.
It is diagnostic progress, not by itself a release-readiness percentage. Full
device acceptance additionally requires the physical gates in this matrix and
the installation/backup evidence maintained by the Ubuntu autoinstall project.
