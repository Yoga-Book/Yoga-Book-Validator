# Yoga Book Validator coverage matrix

This matrix defines the evidence required to claim that a Lenovo Yoga Book
YB1-X91L component works. Presence, package installation and a green passive
probe are necessary but do not replace functional or physical acceptance.

Coverage is complete only when every applicable row has all three evidence
layers satisfied and no required check is `FAIL`, `WARN` or `SKIP`:

1. **Structural** — identity, driver, package, topology and service state.
2. **Functional** — bounded data or state transition with cleanup verified.
3. **Physical** — operator-observed behavior that software cannot prove.

Conditional hardware remains incomplete until the prerequisite is supplied.
Examples include a SIM, headphones, an OTG accessory, an HDMI display, an SD
card, the pen-mode transition and an outdoor GNSS fix.

| Component | Structural evidence | Functional evidence | Physical acceptance gate |
|---|---|---|---|
| Boot and kernel | `check`, `platform`, package integrity | Three distinct cold boots with unchanged kernel/firmware/topology | Power-off and power-on were physical; Yoga Book kernel returned |
| DSI display and GPU | `display` DRM, panel, Mutter and compositor checks | `rotation`, `lights`; no critical/repeated display journal failure | Image is stable, correctly oriented and brightness is usable |
| Micro-HDMI | DRM connector and all three LPE PCM nodes | Connected external display exposes a mode and audio route | External picture and sound are observed |
| Halo keyboard and touchpad | `check`, `inputs`, service/device/resource checks | `modes` completes keyboard to pen to keyboard without restart | Keys, touchpad, click and backlight are observed |
| Haptics | Two DRV2604 devices and force-feedback capabilities | `haptics` pulses both actuators and restores state | Both left and right pulses are felt |
| Pen and drawing surface | Wacom capabilities and calibration matrix in pen mode | `modes` observes stable appearance/disappearance and state restoration | Direction, pressure and contact match a drawing application |
| Display touchscreen | Input identity/capabilities in both modes | Presence remains stable across `modes` and `rotation` | Touch position and gestures are observed in both modes |
| Rotation and sensors | Complete IIO layout, policies and SensorProxy capabilities | `sensors` samples every channel; `rotation` proves all transforms | Screen follows all four physical orientations and returns upright |
| Speakers and microphones | ALSA/SOF/UCM/PipeWire topology | `audio` validates PCM formats, capture signal and quiet bounded tone | Stereo speakers and internal microphone are heard/understood |
| Headset path | UCM devices plus jack/button input capabilities | `inputs` and `audio` with a connected headset | Headphones, headset microphone, jack detection and buttons work |
| Cameras | AtomISP, OV2740, OV8858 and focus control presence | `camera` analyzes changing in-memory frames from both sensors and restores route/focus | Front and rear preview are correctly oriented and usable |
| Wi-Fi | BCM4356/brcmfmac interface and route | `wireless` exchanges packets with the current gateway | Association and sustained real network traffic are observed |
| Bluetooth | Controller, service and classic/LE/security feature set | `wireless` performs bounded RF discovery and restores power/rfkill | Pairing and representative data or audio exchange succeed |
| USB OTG | xHCI hubs, role switch and authorization state | `usb` sees an attached removable accessory without kernel errors | Physical insertion, use and clean removal succeed |
| SD card | Host, media identity and read-only filesystem validation | `storage-write` writes, verifies, syncs and removes its bounded file | Card insertion/removal and normal application access succeed |
| LTE modem | XMM7260 operational USB mode and ModemManager object | With a SIM, registration and IP traffic are required | LTE data works in the intended coverage area |
| GNSS | UART, verified private runtime, service, FIFO and gpsd | `gnss --require-sky` and `--require-fix` outdoors | A userspace map/location consumer receives a plausible fix |
| Battery and charging | BQ27542/BQ25892 identity and UPower consistency | `power` validates live electrical, thermal and charge counters | Cable events and sustained charging are observed |
| Thermals and resources | thermald policy, critical limits and cgroup limits | `resources` samples temperature, CPU, memory, tasks and restarts | No unsafe heat, throttling or instability under representative use |
| Suspend/resume | RTC wake and s2idle plumbing | `suspend` keeps hardware-muted full-duplex transport alive without xruns | Display, input, radios and audio work after resume |
| Lid and hardware buttons | Input devices and switch/key capabilities | Event behavior is recorded through guided physical acceptance | Lid, power and volume actions match their intended desktop behavior |
| Indicator and charging LEDs | LED controls and trigger policy | `lights` performs one-step changes and exact cleanup | Visible charging/indicator behavior matches cable and system state |
| Reboot and poweroff | No failed units or fatal current-boot journal events | Reboot returns to the pinned kernel; poweroff terminates cleanly | At least one physical reboot and one full shutdown are observed |

## Result policy

- `PASS` proves only the stated check and evidence layer.
- `WARN` preserves a non-fatal anomaly that still requires review.
- `SKIP` means the corresponding coverage is incomplete.
- `FAIL` means the component or a prerequisite is not working.
- `validator/state-preservation` must pass for every state-changing action.
- A category or suite roll-up never replaces its individual check results.

The generated report's coverage percentage measures exercised unique checks.
It is diagnostic progress, not by itself a release-readiness percentage. Full
device acceptance additionally requires the physical gates in this matrix and
the installation/backup evidence maintained by the Ubuntu autoinstall project.
