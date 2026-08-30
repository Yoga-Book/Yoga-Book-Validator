#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import csv
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import threading
from datetime import datetime

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango  # noqa: E402


APP_ID = "org.yogabook.Validator"
INSTALLED_CLI = Path("/usr/bin/yogabook-validator")
SOURCE_CLI = Path(__file__).resolve().parents[1] / "src" / "yogabook-validator.sh"
CLI = Path(os.environ.get("YBV_CLI", INSTALLED_CLI if INSTALLED_CLI.exists() else SOURCE_CLI))
ACTIVE_COMMANDS = {
    "audio",
    "automated",
    "camera",
    "category",
    "haptics",
    "inputs",
    "lights",
    "modes",
    "rotation",
    "storage",
    "storage-write",
    "suspend",
    "wireless",
}

PHYSICAL_CHECKS = [
    ("speakers", "Stereo speakers play cleanly"),
    ("headphones", "Headphones play cleanly"),
    ("internal-microphone", "Internal microphone records intelligibly"),
    ("headset-microphone", "Headset microphone records intelligibly"),
    ("jack-detection", "Headset insertion/removal is detected"),
    ("headset-buttons", "Headset buttons work"),
    ("halo-keys", "Halo keyboard keys map correctly"),
    ("halo-touchpad", "Halo touchpad tracks and clicks correctly"),
    ("halo-haptics", "Both Halo haptic actuators respond"),
    ("halo-backlight", "Halo keyboard backlight brightness control works"),
    ("pen-direction", "Pen directions match the display in all axes"),
    ("pen-pressure", "Pen pressure works in a drawing application"),
    ("display-touch", "Display touchscreen works in keyboard and pen modes"),
    ("auto-rotation", "Display rotates correctly and returns to landscape"),
    ("display-brightness", "Display brightness changes smoothly under manual control"),
    ("micro-hdmi", "Micro-HDMI outputs video and audio to an external display"),
    ("front-camera", "Front camera produces a usable image"),
    ("rear-camera", "Rear camera produces a usable image"),
    ("wifi", "Wi-Fi connects and transfers data reliably"),
    ("bluetooth", "Bluetooth can discover, pair and exchange data or audio"),
    ("usb-otg", "Micro-USB OTG detects and cleanly removes an attached device"),
    ("sd-card", "Inserted SD card can be read and written"),
    ("hardware-buttons", "Power and volume buttons generate the expected actions"),
    ("lid-switch", "Lid or keyboard-cover state is detected correctly"),
    ("lte-data", "LTE data connects (skip when no SIM is installed)"),
    ("gnss", "GNSS receives satellites outdoors"),
    ("suspend-resume", "Suspend/resume preserves working hardware"),
    ("charging", "Battery charges and reports plausible state"),
]


def results_root() -> Path:
    documents = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOCUMENTS)
    base = Path(documents) if documents else Path.home() / "Documents"
    path = base / "Yoga Book Validator"
    path.mkdir(parents=True, exist_ok=True)
    return path


class ValidatorWindow(Adw.ApplicationWindow):
    def __init__(self, application: Adw.Application) -> None:
        super().__init__(application=application, title="Yoga Book Validator")
        self.set_default_size(1200, 720)
        self.last_report: Path | None = None
        self.pending_run_button: Gtk.Button | None = None
        self.current_run_button: Gtk.Button | None = None
        self.current_process: subprocess.Popen[str] | None = None
        self.cancel_file: Path | None = None
        self.cancel_requested = False
        self.current_cleanup_files: list[Path] = []
        self.active_subtests: list[tuple[str, Gtk.Button]] = []
        self.live_counts = {status: 0 for status in ("PASS", "FAIL", "WARN", "SKIP", "INFO")}

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        toolbar.add_top_bar(header)

        page = Adw.PreferencesPage()
        page.set_title("Hardware status")
        page.set_description("Automated transport checks and physical acceptance are reported separately.")
        split = Gtk.Paned.new(Gtk.Orientation.HORIZONTAL)
        split.set_wide_handle(True)
        split.set_resize_start_child(True)
        split.set_shrink_start_child(False)
        split.set_resize_end_child(True)
        split.set_shrink_end_child(False)
        split.set_start_child(page)

        console = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        console.set_margin_top(12)
        console.set_margin_bottom(12)
        console.set_margin_start(12)
        console.set_margin_end(12)
        console_title = Gtk.Label(label="Command output")
        console_title.add_css_class("heading")
        console_title.set_halign(Gtk.Align.START)
        console.append(console_title)

        self.console_buffer = Gtk.TextBuffer()
        self.console_view = Gtk.TextView(buffer=self.console_buffer)
        self.console_view.set_editable(False)
        self.console_view.set_cursor_visible(False)
        self.console_view.set_monospace(True)
        self.console_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.console_view.set_left_margin(8)
        self.console_view.set_right_margin(8)
        self.console_view.set_top_margin(8)
        self.console_view.set_bottom_margin(8)
        self.console_end = self.console_buffer.create_mark(None, self.console_buffer.get_end_iter(), False)
        console_scroller = Gtk.ScrolledWindow()
        console_scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        console_scroller.set_hexpand(True)
        console_scroller.set_vexpand(True)
        console_scroller.set_min_content_width(360)
        console_scroller.set_child(self.console_view)
        console.append(console_scroller)
        split.set_end_child(console)
        split.set_position(760)

        toolbar.set_content(split)
        self.set_content(toolbar)

        self.run_buttons: list[Gtk.Button] = []
        self.row_spinners: dict[Gtk.Button, Gtk.Spinner] = {}
        self.row_status_icons: dict[Gtk.Button, Gtk.Image] = {}
        self.run_button_icons: dict[Gtk.Button, Gtk.Image] = {}
        self.run_button_tooltips: dict[Gtk.Button, str] = {}
        self.subtest_buttons: dict[str, Gtk.Button] = {}
        category_actions = {
            "Recommended workflows": (
                "recommended",
                "Run the complete recommended validation?",
                "The optimized union covers the automated, full-passive and quick-audit workflows without repeating their overlapping checks.",
            ),
            "Audio and media": (
                "audio-media",
                "Run display, camera, light and audio checks?",
                "The checks run sequentially. Camera routes, lights and audio state are restored after each test; a quiet speaker tone is audible.",
            ),
            "Input and device modes": (
                "input-modes",
                "Run all input and mode checks?",
                "This interactive sequence inspects capabilities, pulses both haptics, then asks you to switch between keyboard and pen modes and rotate through all four orientations.",
            ),
            "Platform and power": (
                "platform-power",
                "Run all platform and power checks?",
                "These read-only checks inspect platform integration, resources, thermals, charging and every sensor channel as one report.",
            ),
            "Connectivity and storage": (
                "connectivity-storage",
                "Run all connectivity and storage checks?",
                "The checks run sequentially and restore radio and mount state. The final SD test writes, verifies, synchronizes and removes one bounded 64 KiB file from each writable filesystem.",
            ),
            "Reliability": (
                "reliability",
                "Run all currently applicable reliability checks?",
                "The suite performs suspend/resume, then automatically starts, advances or confirms cold-boot tracking. If this boot was already counted, it records that a physical cold boot is required instead of producing a false failure.",
            ),
            "Physical acceptance": (
                "physical",
                "",
                "",
            ),
        }
        validation_sections = [
            (
                "Recommended workflows",
                "Start here for a complete or non-invasive health assessment.",
                [
                    ("Complete device acceptance", "Combine deep passive diagnostics and physical observations in one report", self.on_full, True),
                    ("Run automated suite", "All transport checks except suspend, with one authorization", self.on_automated, False),
                    ("Run full passive suite", "All deep read-only checks in one merged report", self.on_passive, False),
                    ("Run passive audit", "Fast read-only checks; no administrator access", self.on_audit, False),
                ],
            ),
            (
                "Audio and media",
                "Sound, cameras, display transport and visible hardware controls.",
                [
                    ("Test audio", "Exclusive PCM tests, a quiet tone, and microphone capture", self.on_audio, False),
                    ("Test cameras", "Analyze both sensors and exercise one rear-focus step", self.on_camera, False),
                    ("Inspect display", "Validate i915, DSI, Micro-HDMI video/audio, and desktop policy", self.on_display, False),
                    ("Test lights", "Exercise and restore the panel, Halo, indicator, and charging lights", self.on_lights, False),
                ],
            ),
            (
                "Input and device modes",
                "Halo keyboard, touch, pen, haptics and orientation transitions.",
                [
                    ("Inspect inputs", "Validate key, switch, touch, pen, jack, and haptic capability maps", self.on_inputs, False),
                    ("Test haptics", "Pulse the left and right Halo actuators for 150 ms", self.on_haptics, False),
                    ("Test keyboard/pen modes", "Observe one physical keyboard to pen to keyboard transition", self.on_modes, False),
                    ("Test automatic rotation", "Verify all four sensor orientations and return upright", self.on_rotation, False),
                ],
            ),
            (
                "Platform and power",
                "Core SoC integration, sensors, thermal safeguards and charging.",
                [
                    ("Inspect platform", "Validate SoC drivers, CPU power, thermals, eMMC health, and RTC wake", self.on_platform, False),
                    ("Inspect resources", "Profile Yoga Book services and verify thermal safeguards", self.on_resources, False),
                    ("Inspect power", "Validate battery, charger, fuel-gauge, and desktop telemetry", self.on_power, False),
                    ("Test sensors", "Read every ambient-light, accelerometer, hinge, and proximity channel", self.on_sensors, False),
                ],
            ),
            (
                "Connectivity and storage",
                "Radios, USB topology and removable-media coverage.",
                [
                    ("Test wireless", "Verify Wi-Fi plus Bluetooth features and RF reception", self.on_wireless, False),
                    ("Inspect USB", "Validate xHCI hubs, role switch, modem transport, and attached accessories", self.on_usb, False),
                    ("Test storage", "Read the inserted SD card and mount filesystems read-only", self.on_storage, False),
                    ("Test SD writes", "Write, verify, synchronize, and remove a bounded test file", self.on_storage_write, False),
                ],
            ),
            (
                "Reliability",
                "Resume and repeated cold-boot acceptance over time.",
                [
                    ("Test suspend", "Full-duplex audio across one suspend/resume cycle", self.on_suspend, False),
                    ("Start cold-boot tracking", "Validate a baseline and track three physical cold boots", self.on_stability_start, False),
                    ("Check current cold boot", "Validate and count this boot after a physical power cycle", self.on_stability_check, False),
                ],
            ),
            (
                "Physical acceptance",
                "Record behavior that software cannot prove automatically.",
                [
                    ("Record physical observations", "Document what you can hear, touch, and observe", self.on_physical, False),
                ],
            ),
        ]
        for section_title, section_description, section_rows in validation_sections:
            actions = Adw.PreferencesGroup(title=section_title, description=section_description)
            page.add(actions)
            for title, subtitle, callback, suggested in section_rows:
                row = Adw.ActionRow(title=title, subtitle=subtitle)
                button = self.create_action_button("media-playback-start-symbolic", 18)
                button.add_css_class("flat")
                button_tooltip = title
                self.set_action_button_state(
                    button,
                    "media-playback-start-symbolic",
                    button_tooltip,
                )
                if suggested:
                    button.add_css_class("suggested-action")
                button.set_size_request(36, 36)
                button.set_halign(Gtk.Align.START)
                button.set_valign(Gtk.Align.CENTER)
                button.connect("clicked", self.on_run_button_clicked, callback)
                self.run_buttons.append(button)
                row_spinner = Gtk.Spinner()
                row_spinner.set_visible(False)
                row_spinner.set_halign(Gtk.Align.START)
                row_spinner.set_valign(Gtk.Align.CENTER)
                row_status_icon = Gtk.Image()
                row_status_icon.set_pixel_size(20)
                row_status_icon.set_visible(False)
                row_status_icon.set_halign(Gtk.Align.START)
                row_status_icon.set_valign(Gtk.Align.CENTER)
                self.row_spinners[button] = row_spinner
                self.row_status_icons[button] = row_status_icon
                self.run_button_tooltips[button] = button_tooltip
                subtest_name = callback.__name__.removeprefix("on_").replace("_", "-")
                if subtest_name == "audit":
                    subtest_name = "check"
                self.subtest_buttons[subtest_name] = button
                row_status_slot = Gtk.Overlay()
                row_status_slot.set_size_request(24, 24)
                row_status_slot.set_valign(Gtk.Align.CENTER)
                row_status_slot.set_child(row_spinner)
                row_status_slot.add_overlay(row_status_icon)
                row_action_slot = Gtk.Box()
                row_action_slot.set_size_request(44, 44)
                row_action_slot.set_halign(Gtk.Align.START)
                row_action_slot.append(button)
                row_action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
                row_action_box.set_size_request(76, 44)
                row_action_box.set_halign(Gtk.Align.END)
                row_action_box.append(row_status_slot)
                row_action_box.append(row_action_slot)
                row.add_suffix(row_action_box)
                actions.add(row)
            category_action = category_actions.get(section_title)
            if category_action is not None:
                category, heading, body = category_action
                category_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
                category_box.set_size_request(76, 44)
                category_box.set_halign(Gtk.Align.END)
                category_spinner = Gtk.Spinner()
                category_spinner.set_visible(False)
                category_spinner.set_halign(Gtk.Align.START)
                category_spinner.set_valign(Gtk.Align.CENTER)
                category_status_icon = Gtk.Image()
                category_status_icon.set_pixel_size(20)
                category_status_icon.set_visible(False)
                category_status_icon.set_halign(Gtk.Align.START)
                category_status_icon.set_valign(Gtk.Align.CENTER)
                category_button = self.create_action_button("media-playback-start-symbolic", 24)
                category_button.add_css_class("flat")
                category_button.set_size_request(44, 44)
                category_button.set_halign(Gtk.Align.START)
                category_button.set_valign(Gtk.Align.CENTER)
                category_tooltip = f"Run all checks in {section_title}"
                category_button.set_tooltip_text(category_tooltip)
                category_button.update_property(
                    [Gtk.AccessibleProperty.LABEL],
                    [category_tooltip],
                )
                category_button.connect(
                    "clicked",
                    self.on_run_button_clicked,
                    lambda _button, category=category, heading=heading, body=body: self.on_category(
                        category, heading, body
                    ),
                )
                self.run_buttons.append(category_button)
                self.run_button_tooltips[category_button] = category_tooltip
                self.row_spinners[category_button] = category_spinner
                self.row_status_icons[category_button] = category_status_icon
                category_status_slot = Gtk.Overlay()
                category_status_slot.set_size_request(24, 24)
                category_status_slot.set_valign(Gtk.Align.CENTER)
                category_status_slot.set_child(category_spinner)
                category_status_slot.add_overlay(category_status_icon)
                category_action_slot = Gtk.Box()
                category_action_slot.set_size_request(44, 44)
                category_action_slot.set_halign(Gtk.Align.START)
                category_action_slot.append(category_button)
                category_box.append(category_status_slot)
                category_box.append(category_action_slot)
                actions.set_header_suffix(category_box)

        self.summary = Adw.PreferencesGroup(title="Results")
        page.add(self.summary)
        self.result_rows: list[Adw.ActionRow] = []
        self.overview_row = Adw.ActionRow(
            title="Ready to validate",
            subtitle="Independent checks are counted separately from suite roll-ups.",
        )
        self.summary.add(self.overview_row)
        self.placeholder = Adw.ActionRow(
            title="No validation has run yet",
            subtitle="Start with the passive audit.",
        )
        self.summary.add(self.placeholder)

        exports = Adw.PreferencesGroup(title="Evidence")
        page.add(exports)
        self.open_button = Gtk.Button(label="Open report folder")
        self.open_button.set_sensitive(False)
        self.open_button.connect("clicked", self.on_open_report)
        self.detailed_report_button = Gtk.Button(label="Open detailed report")
        self.detailed_report_button.add_css_class("suggested-action")
        self.detailed_report_button.set_sensitive(False)
        self.detailed_report_button.connect("clicked", self.on_open_detailed_report)
        export_row = Adw.ActionRow(
            title="Reports",
            subtitle="Shareable HTML, Markdown, JSON, raw TSV and logs are saved together.",
        )
        export_row.add_suffix(self.detailed_report_button)
        export_row.add_suffix(self.open_button)
        exports.add(export_row)

        self.spinner = Gtk.Spinner()
        self.spinner.set_visible(False)
        header.pack_start(self.spinner)
        self.action_label = Gtk.Label()
        self.action_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.action_label.set_visible(False)
        header.pack_start(self.action_label)

    def report_path(self, command: str) -> Path:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        return results_root() / f"{command}-{stamp}"

    def on_run_button_clicked(self, button: Gtk.Button, callback) -> None:
        if button is self.current_run_button:
            self.stop_current_command()
            return
        self.pending_run_button = button
        callback(button)

    def confirm(self, heading: str, body: str, callback) -> None:
        dialog = Adw.MessageDialog.new(self, heading, body)
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("continue", "Continue")
        dialog.set_response_appearance("continue", Adw.ResponseAppearance.SUGGESTED)
        dialog.set_default_response("cancel")
        dialog.set_close_response("cancel")
        dialog.connect("response", lambda _dialog, response: callback() if response == "continue" else None)
        dialog.present()

    def on_audit(self, _button) -> None:
        self.run_command("check", [])

    def on_passive(self, _button) -> None:
        self.run_command("passive", [])

    def on_automated(self, _button) -> None:
        self.confirm(
            "Run the automated hardware suite?",
            "The suite runs passive, platform, display, sensor, power, USB, GNSS, camera, input, storage, wireless, light, haptic, and audible audio tests. Each state-changing test restores its original state. Suspend is not included. Administrator authorization is required.",
            lambda: self.run_command("automated", ["--yes"]),
        )

    def on_category(self, category: str, heading: str, body: str) -> None:
        if category == "physical":
            self.on_physical(None)
            return
        self.confirm(
            heading,
            body + " Administrator authorization is requested once for the complete category.",
            lambda: self.run_command(
                "category",
                [category, "--yes"],
                self.report_path(f"category-{category}"),
            ),
        )

    def on_audio(self, _button) -> None:
        self.confirm(
            "Run active audio test?",
            "Desktop audio is paused temporarily. The test plays a quiet one-second tone, records three seconds from Mic1, then restores the previous ALSA and PipeWire state. Administrator authorization is required.",
            lambda: self.run_command("audio", ["--yes"]),
        )

    def on_suspend(self, _button) -> None:
        self.confirm(
            "Suspend this tablet?",
            "The validator opens silent playback and capture streams, suspends for eight seconds, checks them after resume, and restores the previous audio state. Administrator authorization is required.",
            lambda: self.run_command("suspend", ["--yes", "--seconds", "8"]),
        )

    def on_camera(self, _button) -> None:
        self.confirm(
            "Test both cameras?",
            "The validator briefly switches the AtomISP route, checks three in-memory frames per camera, moves rear focus by one position, discards the frames, and restores the original focus and route. Images are never saved or logged.",
            lambda: self.run_command("camera", ["--yes"]),
        )

    def on_display(self, _button) -> None:
        self.run_command("display", [])

    def on_haptics(self, _button) -> None:
        self.confirm(
            "Test both haptic actuators?",
            "The validator plays one moderate-strength 150 ms force-feedback pulse on the left actuator and then the right actuator. Administrator authorization is required.",
            lambda: self.run_command("haptics", ["--yes"]),
        )

    def on_storage(self, _button) -> None:
        self.confirm(
            "Test inserted SD card?",
            "The validator reads the first 4 MiB and mounts recognized filesystems read-only. It does not write to the card and removes every temporary mount.",
            lambda: self.run_command("storage", ["--yes"]),
        )

    def on_storage_write(self, _button) -> None:
        self.confirm(
            "Write-test the inserted SD card?",
            "The validator creates one 64 KiB temporary file on each writable SD filesystem, verifies and synchronizes it, deletes it, and restores the original mount state. Existing read-only mounts are not changed. Administrator authorization is required.",
            lambda: self.run_command("storage-write", ["--yes"]),
        )

    def on_inputs(self, _button) -> None:
        self.confirm(
            "Inspect input capabilities?",
            "The validator opens each kernel input node read-only to inspect its capability map. It does not grab devices, monitor events, record keys or touches, or inject input. Administrator authorization is required.",
            lambda: self.run_command("inputs", ["--yes"]),
        )

    def on_modes(self, _button) -> None:
        self.confirm(
            "Test the keyboard and pen mode cycle?",
            "Start in Halo keyboard mode. After continuing, follow the live instruction in the window: switch to drawing/pen mode, then switch back only when asked. The validator observes device metadata but never reads keys, touches, or pen strokes. Administrator authorization is required.",
            lambda: self.run_command("modes", ["--yes"]),
        )

    def on_rotation(self, _button) -> None:
        self.confirm(
            "Test all automatic orientations?",
            "Start in Halo keyboard mode. Follow the live instructions to enter pen mode, rotate the tablet slowly through both portrait orientations and upside-down landscape, return it upright, then return to Halo mode. The validator observes SensorProxy and Mutter but never changes display policy or reads input events. Administrator authorization is required.",
            lambda: self.run_command("rotation", ["--yes"]),
        )

    def on_lights(self, _button) -> None:
        self.confirm(
            "Test panel and platform lights?",
            "The validator applies a one-step brightness change to the display backlight and each Yoga Book LED, then restores all brightness and trigger values. Administrator authorization is required.",
            lambda: self.run_command("lights", ["--yes"]),
        )

    def on_sensors(self, _button) -> None:
        self.run_command("sensors", [])

    def on_power(self, _button) -> None:
        self.run_command("power", [])

    def on_platform(self, _button) -> None:
        self.run_command("platform", [])

    def on_resources(self, _button) -> None:
        self.run_command("resources", [])

    def on_stability_start(self, _button) -> None:
        self.confirm(
            "Start cold-boot stability tracking?",
            "The validator checks the current baseline and replaces any previous cold-boot counter. It does not reboot or change GRUB. After it succeeds, fully power off and start the tablet before each check.",
            lambda: self.run_command("stability", ["start", "3"]),
        )

    def on_stability_check(self, _button) -> None:
        self.run_command("stability", ["check"])

    def on_wireless(self, _button) -> None:
        self.confirm(
            "Test Wi-Fi and Bluetooth?",
            "The validator pings the Wi-Fi gateway, validates classic/LE Bluetooth features, and briefly scans for RF reports without retaining device identities or pairing. It then restores the original Bluetooth power and rfkill state.",
            lambda: self.run_command("wireless", ["--yes"]),
        )

    def on_usb(self, _button) -> None:
        self.run_command("usb", [])

    def run_command(
        self,
        command: str,
        extra: list[str],
        output: Path | None = None,
        cleanup_files: list[Path] | None = None,
    ) -> None:
        output = output or self.report_path(command)
        output.mkdir(parents=True, exist_ok=True)
        argv = [str(CLI), command, *extra, "--output", str(output)]
        self.cancel_file = output / ".cancel-requested" if command in ACTIVE_COMMANDS else None
        if self.cancel_file is not None:
            self.cancel_file.unlink(missing_ok=True)
            argv.extend(["--cancel-file", str(self.cancel_file)])
        self.cancel_requested = False
        self.active_subtests = []
        self.current_cleanup_files = list(cleanup_files or [])
        self.live_counts = {status: 0 for status in ("PASS", "FAIL", "WARN", "SKIP", "INFO")}
        self.overview_row.set_title("Validation running…")
        self.overview_row.set_subtitle("Waiting for the first completed check.")
        self.detailed_report_button.set_sensitive(False)
        self.current_run_button = self.pending_run_button
        self.pending_run_button = None
        self.spinner.set_visible(True)
        self.spinner.start()
        self.set_run_buttons_sensitive(False)
        if self.current_run_button is not None:
            self.set_row_running(self.current_run_button)
            self.set_action_button_state(
                self.current_run_button,
                "media-playback-stop-symbolic",
                "Stop validation",
            )
            self.current_run_button.remove_css_class("suggested-action")
            self.current_run_button.add_css_class("destructive-action")
            self.current_run_button.set_sensitive(True)
        self.console_buffer.set_text(f"$ {shlex.join(argv)}\n\n")
        self.console_buffer.move_mark(self.console_end, self.console_buffer.get_end_iter())
        self.run_streaming_command(argv, output)

    def run_streaming_command(self, argv: list[str], output: Path) -> None:
        def worker() -> None:
            error = ""
            lines: list[str] = []
            returncode: int | None = None
            try:
                process = subprocess.Popen(
                    argv,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                self.current_process = process
                if self.cancel_requested and self.cancel_file is None:
                    os.killpg(process.pid, signal.SIGTERM)
                assert process.stdout is not None
                for line in process.stdout:
                    clean = line.strip()
                    lines.append(clean)
                    GLib.idle_add(self.append_console, line)
                    if clean.startswith("ACTION_REQUIRED:"):
                        GLib.idle_add(self.show_action, clean.removeprefix("ACTION_REQUIRED:").strip())
                returncode = process.wait()
                if returncode not in (0, 1):
                    error = "\n".join(lines[-12:])
            except OSError as exc:
                error = str(exc)
            GLib.idle_add(self.command_finished, output, error, returncode)

        threading.Thread(target=worker, daemon=True).start()

    def stop_current_command(self) -> None:
        if self.cancel_requested:
            return
        self.cancel_requested = True
        self.append_console("\nCANCELLATION_REQUESTED: waiting for safe hardware restoration\n")
        if self.current_run_button is not None:
            self.set_action_button_state(
                self.current_run_button,
                "process-stop-symbolic",
                "Stopping validation…",
            )
            self.current_run_button.set_sensitive(False)
        if self.cancel_file is not None:
            self.cancel_file.touch()
            return
        process = self.current_process
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def append_console(self, text: str) -> bool:
        self.console_buffer.insert(self.console_buffer.get_end_iter(), text)
        self.console_buffer.move_mark(self.console_end, self.console_buffer.get_end_iter())
        self.console_view.scroll_mark_onscreen(self.console_end)
        clean = text.strip()
        subtest_start = re.match(r"^===== Running ([a-z0-9-]+) =====$", clean)
        if subtest_start:
            self.set_subtest_running(subtest_start.group(1))
        match = re.match(
            r"^\[(PASS|FAIL|WARN|SKIP|INFO)\]\s+(\S+)\s+(\S+)\s+(.+?)(?:\s+--\s+.*)?$",
            clean,
        )
        if match:
            status, subsystem, check_id, summary = match.groups()
            if subsystem == "suite":
                self.set_subtest_result(check_id, status)
            if subsystem != "suite":
                self.live_counts[status] += 1
            completed = sum(self.live_counts.values())
            self.overview_row.set_title(f"Validation running · {completed} checks completed")
            self.overview_row.set_subtitle(
                f"{self.live_counts['PASS']} passed · {self.live_counts['FAIL']} failed · "
                f"{self.live_counts['WARN']} warnings · {self.live_counts['SKIP']} skipped"
            )
            self.action_label.set_text(f"{status} · {subsystem}/{check_id} · {summary}")
            self.action_label.set_tooltip_text(summary)
            self.action_label.set_visible(True)
        return GLib.SOURCE_REMOVE

    def set_run_buttons_sensitive(self, sensitive: bool) -> None:
        for button in self.run_buttons:
            button.set_sensitive(sensitive)

    def stop_row_spinner(self, button: Gtk.Button) -> None:
        spinner = self.row_spinners[button]
        spinner.stop()
        spinner.set_visible(False)

    def set_subtest_running(self, name: str) -> None:
        button = self.subtest_buttons.get(name)
        if button is None:
            return
        if self.active_subtests:
            self.stop_row_spinner(self.active_subtests[-1][1])
        self.active_subtests = [entry for entry in self.active_subtests if entry[0] != name]
        self.active_subtests.append((name, button))
        self.set_row_running(button)

    def set_subtest_result(self, name: str, status: str) -> None:
        matches = [index for index, entry in enumerate(self.active_subtests) if entry[0] == name]
        button = self.subtest_buttons.get(name)
        if button is None:
            return
        was_active = bool(matches and matches[-1] == len(self.active_subtests) - 1)
        if matches:
            self.active_subtests.pop(matches[-1])
        self.set_row_result(button, 0 if status == "PASS" else 1, False)
        if was_active and self.active_subtests:
            self.set_row_running(self.active_subtests[-1][1])

    def create_action_button(self, icon_name: str, icon_size: int) -> Gtk.Button:
        icon = Gtk.Image.new_from_icon_name(icon_name)
        icon.set_pixel_size(icon_size)
        icon.set_halign(Gtk.Align.START)
        icon.set_valign(Gtk.Align.CENTER)
        content = Gtk.Box()
        content.set_hexpand(True)
        content.set_halign(Gtk.Align.FILL)
        content.append(icon)
        button = Gtk.Button()
        button.set_child(content)
        self.run_button_icons[button] = icon
        return button

    def set_action_button_state(self, button: Gtk.Button, icon_name: str, label: str) -> None:
        self.run_button_icons[button].set_from_icon_name(icon_name)
        button.set_tooltip_text(label)
        button.update_property([Gtk.AccessibleProperty.LABEL], [label])

    def set_row_running(self, button: Gtk.Button) -> None:
        spinner = self.row_spinners[button]
        icon = self.row_status_icons[button]
        icon.set_visible(False)
        for css_class in ("success", "error", "dim-label"):
            icon.remove_css_class(css_class)
        spinner.set_visible(True)
        spinner.start()

    def set_row_result(self, button: Gtk.Button, returncode: int | None, cancelled: bool) -> None:
        spinner = self.row_spinners[button]
        icon = self.row_status_icons[button]
        spinner.stop()
        spinner.set_visible(False)
        if cancelled:
            icon.set_from_icon_name("process-stop-symbolic")
            icon.set_tooltip_text("Cancelled")
            icon.add_css_class("dim-label")
        elif returncode == 0:
            icon.set_from_icon_name("emblem-ok-symbolic")
            icon.set_tooltip_text("Passed")
            icon.add_css_class("success")
        else:
            icon.set_from_icon_name("dialog-error-symbolic")
            icon.set_tooltip_text("Failed")
            icon.add_css_class("error")
        icon.set_visible(True)

    def show_action(self, message: str) -> bool:
        self.action_label.set_text(message)
        self.action_label.set_tooltip_text(message)
        self.action_label.set_visible(True)
        return GLib.SOURCE_REMOVE

    def command_finished(self, output: Path, error: str, returncode: int | None) -> bool:
        was_cancelled = self.cancel_requested
        if self.cancel_file is not None:
            self.cancel_file.unlink(missing_ok=True)
        for cleanup_file in self.current_cleanup_files:
            cleanup_file.unlink(missing_ok=True)
        self.current_cleanup_files = []
        for _name, subtest_button in self.active_subtests:
            self.set_row_result(subtest_button, returncode, was_cancelled)
        self.active_subtests = []
        if self.current_run_button is not None:
            self.set_row_result(self.current_run_button, returncode, was_cancelled)
            self.set_action_button_state(
                self.current_run_button,
                "media-playback-start-symbolic",
                self.run_button_tooltips[self.current_run_button],
            )
            self.current_run_button.remove_css_class("destructive-action")
            if self.current_run_button is self.run_buttons[0]:
                self.current_run_button.add_css_class("suggested-action")
        self.current_process = None
        self.current_run_button = None
        self.cancel_file = None
        self.cancel_requested = False
        self.set_run_buttons_sensitive(True)
        self.spinner.stop()
        self.spinner.set_visible(False)
        self.action_label.set_visible(False)
        report = output / "results.tsv"
        if report.exists():
            self.last_report = output
            self.render_report(report)
            self.open_button.set_sensitive(True)
            self.detailed_report_button.set_sensitive((output / "report.html").is_file())
        else:
            self.show_error("Validation did not produce a report", error or "The command ended unexpectedly.")
        return GLib.SOURCE_REMOVE

    def clear_results(self) -> None:
        if self.placeholder is not None:
            self.summary.remove(self.placeholder)
            self.placeholder = None
        for row in self.result_rows:
            self.summary.remove(row)
        self.result_rows.clear()

    def render_report(self, report: Path) -> None:
        self.clear_results()
        model_path = report.parent / "report.json"
        if model_path.is_file():
            with model_path.open(encoding="utf-8") as stream:
                model = json.load(stream)
            rows = model.get("checks", [row for row in model["results"] if row.get("kind") == "check"])
            summary = model["summary"]
            counts = summary["counts"]
            result = summary["result"]
            self.overview_row.set_title(
                "No problems found" if result == "PASS" else
                "Completed with warnings" if result == "PASS_WITH_WARNINGS" else
                "Problems found"
            )
            self.overview_row.set_subtitle(
                f"{counts['PASS']} passed · {counts['FAIL']} failed · {counts['WARN']} warnings · "
                f"{counts['SKIP']} skipped · {summary['coverage_percent']}% coverage"
            )
        else:
            with report.open(newline="", encoding="utf-8") as stream:
                rows = [row for row in csv.DictReader(stream, delimiter="\t") if row["subsystem"] != "suite"]
            counts = {status: sum(row["status"] == status for row in rows) for status in self.live_counts}
            self.overview_row.set_title("Validation complete")
            self.overview_row.set_subtitle(
                f"{counts['PASS']} passed · {counts['FAIL']} failed · {counts['WARN']} warnings · {counts['SKIP']} skipped"
            )
        severity = {"FAIL": 0, "WARN": 1, "PASS": 2, "SKIP": 3, "INFO": 4}
        rows.sort(key=lambda row: (severity.get(row["status"], 5), row["subsystem"], row["check_id"]))
        for result in rows:
            status = result["status"]
            row = Adw.ActionRow(
                title=result["summary"],
                subtitle=f'{result["subsystem"]} · {result["check_id"]}' + (f' — {result["details"]}' if result["details"] else ""),
            )
            badge = Gtk.Label(label=status)
            badge.add_css_class("status-badge")
            badge.add_css_class(f"status-{status.lower()}")
            row.add_suffix(badge)
            self.summary.add(row)
            self.result_rows.append(row)

    def on_open_report(self, _button) -> None:
        if self.last_report:
            Gio.AppInfo.launch_default_for_uri(self.last_report.as_uri(), None)

    def on_open_detailed_report(self, _button) -> None:
        if self.last_report:
            detailed = self.last_report / "report.html"
            if detailed.is_file():
                Gio.AppInfo.launch_default_for_uri(detailed.as_uri(), None)

    def on_physical(self, _button) -> None:
        PhysicalWindow(self).present()

    def on_full(self, _button) -> None:
        PhysicalWindow(self, command="full").present()

    def show_error(self, heading: str, body: str) -> None:
        dialog = Adw.MessageDialog.new(self, heading, body)
        dialog.add_response("close", "Close")
        dialog.present()


class PhysicalWindow(Adw.Window):
    def __init__(self, parent: ValidatorWindow, command: str = "physical") -> None:
        title = "Complete device acceptance" if command == "full" else "Physical acceptance"
        super().__init__(transient_for=parent, modal=True, title=title)
        self.parent_window = parent
        self.command = command
        self.set_default_size(760, 700)
        self.rows: list[tuple[str, Gtk.DropDown, Gtk.Entry]] = []

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        save = Gtk.Button(label="Start validation" if command == "full" else "Save results")
        save.add_css_class("suggested-action")
        save.connect("clicked", self.on_save)
        header.pack_end(save)
        toolbar.add_top_bar(header)
        page = Adw.PreferencesPage()
        description = "Choose Skip for unavailable accessories or conditions, such as LTE without a SIM."
        if command == "full":
            description = "Record the observations to include after deep passive diagnostics. " + description
        page.set_description(description)
        group = Adw.PreferencesGroup(title="Observed hardware behavior")
        page.add(group)
        for check_id, label in PHYSICAL_CHECKS:
            row = Adw.ActionRow(title=label)
            dropdown = Gtk.DropDown.new_from_strings(["Skip", "Pass", "Fail"])
            dropdown.set_selected(0)
            note = Gtk.Entry(placeholder_text="Optional note")
            note.set_width_chars(18)
            row.add_suffix(dropdown)
            row.add_suffix(note)
            group.add(row)
            self.rows.append((check_id, dropdown, note))
        toolbar.set_content(page)
        self.set_content(toolbar)

    def on_save(self, _button) -> None:
        cache = Path(GLib.get_user_cache_dir()) / "yogabook-validator"
        cache.mkdir(parents=True, exist_ok=True)
        answers = cache / f"{self.command}-{os.getpid()}.tsv"
        values = ["SKIP", "PASS", "FAIL"]
        with answers.open("w", encoding="utf-8", newline="") as stream:
            for check_id, dropdown, note in self.rows:
                clean_note = note.get_text().replace("\t", " ").replace("\n", " ")
                stream.write(f"{check_id}\t{values[dropdown.get_selected()]}\t{clean_note}\n")
        output = self.parent_window.report_path(self.command)
        self.close()
        self.parent_window.run_command(
            self.command,
            ["--answers", str(answers)],
            output,
            cleanup_files=[answers],
        )


class ValidatorApplication(Adw.Application):
    def __init__(self) -> None:
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.DEFAULT_FLAGS)

    def do_startup(self) -> None:
        Adw.Application.do_startup(self)
        css = Gtk.CssProvider()
        css.load_from_string("""
            .status-badge { border-radius: 999px; font-weight: bold; padding: 3px 9px; }
            .status-pass { background: alpha(@success_color, .18); color: @success_color; }
            .status-fail { background: alpha(@error_color, .18); color: @error_color; }
            .status-warn { background: alpha(@warning_color, .18); color: @warning_color; }
            .status-skip, .status-info { background: alpha(currentColor, .10); }
        """)
        display = Gdk.Display.get_default()
        if display:
            Gtk.StyleContext.add_provider_for_display(
                display, css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

    def do_activate(self) -> None:
        window = self.props.active_window or ValidatorWindow(self)
        window.present()


def main() -> int:
    return ValidatorApplication().run(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())
