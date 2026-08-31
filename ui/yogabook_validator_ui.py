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
import tempfile
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
SOURCE_ROOT = Path(__file__).resolve().parents[1]
INSTALLED_PHYSICAL_IMPORT = Path("/usr/libexec/yogabook-validator/yogabook-validator-physical-import.py")
PHYSICAL_IMPORT = (
    INSTALLED_PHYSICAL_IMPORT
    if INSTALLED_PHYSICAL_IMPORT.exists()
    else SOURCE_ROOT / "libexec" / "yogabook-validator-physical-import.py"
)
INSTALLED_ACCEPTANCE_MATRIX = Path("/usr/share/yogabook-validator/acceptance.json")
ACCEPTANCE_MATRIX = (
    INSTALLED_ACCEPTANCE_MATRIX
    if INSTALLED_ACCEPTANCE_MATRIX.exists()
    else SOURCE_ROOT / "data" / "acceptance.json"
)
ACTIVE_COMMANDS = {
    "audio",
    "automated",
    "camera",
    "category",
    "controls",
    "haptics",
    "headset",
    "inputs",
    "internal-storage",
    "lights",
    "modes",
    "pen-mapping",
    "quiet",
    "rotation",
    "sensor-interactions",
    "storage",
    "storage-write",
    "suspend",
    "usb-cycle",
    "wireless",
}

# Report action IDs are untrusted data. Only IDs in this local allowlist may
# dispatch an existing UI callback; report-provided command text is never run.
EXECUTION_ACTION_HANDLERS = {
    "audit": "on_audit",
    "apt": "on_apt",
    "audio": "on_audio",
    "camera": "on_camera",
    "charging": "on_charging",
    "controls": "on_controls",
    "display": "on_display",
    "gnss": "on_gnss",
    "haptics": "on_haptics",
    "hdmi": "on_display",
    "headset": "on_headset",
    "inputs": "on_inputs",
    "internal-storage": "on_internal_storage",
    "lights": "on_lights",
    "modem": "on_modem",
    "modes": "on_modes",
    "pen-stack": "on_pen_stack",
    "pen-mapping": "on_pen_mapping",
    "physical": "on_physical",
    "platform": "on_platform",
    "power": "on_power",
    "recapture-evidence": "on_passive",
    "resources": "on_resources",
    "rotation": "on_rotation",
    "sensor-interactions": "on_sensor_interactions",
    "sensors": "on_sensors",
    "stability": "on_stability_start",
    "storage": "on_storage",
    "storage-write": "on_storage_write",
    "suspend": "on_suspend",
    "usb": "on_usb",
    "usb-cycle": "on_usb_cycle",
    "wireless": "on_wireless",
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
    ("indicator-leds", "Indicator and charging LEDs visibly follow system and cable state"),
    ("pen-direction", "Pen directions match the display in all axes"),
    ("pen-pressure", "Pen pressure works in a drawing application"),
    ("display-touch", "Display touchscreen works in keyboard and pen modes"),
    ("display-stability", "Display image remains stable without corruption or flicker"),
    ("auto-rotation", "Display rotates correctly and returns to landscape"),
    ("ambient-light-response", "Shading and exposing the ambient-light sensors changes the reported light level"),
    ("proximity-response", "Moving a hand near and away from the SX9310 changes its proximity state"),
    ("hinge-angle", "Opening and folding the Yoga Book changes both reported hinge angles consistently"),
    ("display-brightness", "Display brightness changes smoothly under manual control"),
    ("micro-hdmi", "Micro-HDMI outputs video and audio to an external display"),
    ("front-camera", "Front camera produces a usable image"),
    ("rear-camera", "Rear camera produces a usable image"),
    ("wifi", "Wi-Fi connects and transfers data reliably"),
    ("bluetooth", "Bluetooth can discover, pair and exchange data or audio"),
    ("usb-otg", "Micro-USB OTG detects and cleanly removes an attached device"),
    ("internal-storage", "Applications can save and reopen data on internal storage across a cold boot"),
    ("sd-card", "Inserted SD card can be read and written"),
    ("hardware-buttons", "Power and volume buttons generate the expected actions"),
    ("lid-switch", "Lid or keyboard-cover state is detected correctly"),
    ("lte-data", "LTE data connects (skip when no SIM is installed)"),
    ("gnss", "GNSS receives satellites outdoors"),
    ("suspend-resume", "Suspend/resume preserves working hardware"),
    ("charging", "Battery charges and reports plausible state"),
    ("thermal-stability", "Tablet remains thermally safe and stable under representative use"),
    ("cold-boots", "Three physical cold boots return to the pinned Yoga Book kernel"),
    ("reboot", "A physical reboot returns to a fully working desktop"),
    ("poweroff", "A full shutdown powers the tablet off cleanly"),
]

PHYSICAL_GROUPS = [
    (
        "Audio and headset",
        "Confirm audible quality, microphone intelligibility and wired-headset controls.",
        [
            "speakers",
            "headphones",
            "internal-microphone",
            "headset-microphone",
            "jack-detection",
            "headset-buttons",
        ],
    ),
    (
        "Input, Halo and pen",
        "Confirm tactile input, mode-dependent devices and visible Halo behavior.",
        [
            "halo-keys",
            "halo-touchpad",
            "halo-haptics",
            "halo-backlight",
            "pen-direction",
            "pen-pressure",
            "display-touch",
            "hardware-buttons",
            "lid-switch",
        ],
    ),
    (
        "Sensors and orientation",
        "Confirm physical response from the accelerometers, ambient-light, proximity and hinge sensors.",
        ["auto-rotation", "ambient-light-response", "proximity-response", "hinge-angle"],
    ),
    (
        "Display, cameras and indicators",
        "Confirm image quality, orientation, brightness and externally visible indicators.",
        [
            "display-stability",
            "display-brightness",
            "micro-hdmi",
            "front-camera",
            "rear-camera",
            "indicator-leds",
        ],
    ),
    (
        "Connectivity and storage",
        "Confirm internal-data persistence, real accessories, radio links, removable media and outdoor positioning.",
        ["wifi", "bluetooth", "usb-otg", "internal-storage", "sd-card", "lte-data", "gnss"],
    ),
    (
        "Power and reliability",
        "Confirm behavior that must remain correct across charging, sleep and power cycles.",
        [
            "suspend-resume",
            "charging",
            "thermal-stability",
            "cold-boots",
            "reboot",
            "poweroff",
        ],
    ),
]


def results_root() -> Path:
    documents = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOCUMENTS)
    base = Path(documents) if documents else Path.home() / "Documents"
    path = base / "Yoga Book Validator"
    path.mkdir(parents=True, exist_ok=True)
    return path


def validation_search_matches(query: str, *fields: str) -> bool:
    """Match every case-insensitive query token across the supplied metadata."""
    tokens = query.casefold().split()
    searchable_text = " ".join(fields).casefold()
    return all(token in searchable_text for token in tokens)


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
        self.dossier_chooser: Gtk.FileChooserNative | None = None
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
        self.validation_groups: list[
            tuple[Adw.PreferencesGroup, str, list[tuple[Adw.ActionRow, str, Gtk.Button]]]
        ] = []
        self.validation_button_groups: dict[Gtk.Button, Adw.PreferencesGroup] = {}

        search_group = Adw.PreferencesGroup()
        search_box = Gtk.Box()
        search_box.set_margin_bottom(4)
        self.validation_search = Gtk.SearchEntry()
        self.validation_search.set_hexpand(True)
        self.validation_search.set_placeholder_text("Search tests by name, description, or category")
        self.validation_search.set_tooltip_text("Filter the validation tests shown below")
        self.validation_search.update_property(
            [Gtk.AccessibleProperty.LABEL],
            ["Search validation tests"],
        )
        self.validation_search.set_key_capture_widget(self)
        self.validation_search.connect("search-changed", self.on_validation_search_changed)
        self.validation_search.connect("stop-search", self.on_validation_search_stopped)
        search_box.append(self.validation_search)
        search_group.add(search_box)
        page.add(search_group)

        category_actions = {
            "Recommended workflows": (
                "recommended",
                "Run the complete recommended validation?",
                "The optimized union covers the automated, full-passive and quick-audit workflows without repeating their overlapping checks.",
            ),
            "Audio and media": (
                "audio-media",
                "Run all automatic audio and media checks?",
                "The unattended checks run sequentially. Camera routes, lights and audio state are restored after each test; one quiet speaker tone is audible.",
            ),
            "Input and sensors": (
                "input-modes",
                "Run all automatic input and sensor checks?",
                "The unattended sequence inspects input capabilities, pulses both haptics and verifies the complete Halo, Wacom, libwacom, Mutter and orientation stack without injecting events or changing device mode.",
            ),
            "Platform and power": (
                "platform-power",
                "Run all platform and power checks?",
                "These read-only checks inspect platform integration, resources, thermals, charging and every sensor channel as one report.",
            ),
            "Connectivity and storage": (
                "connectivity-storage",
                "Run all connectivity and storage checks?",
                "The checks run sequentially and restore radio and mount state. They exercise one bounded 4 MiB file on the internal root filesystem, then write, verify, synchronize and remove one bounded 64 KiB file from each writable SD filesystem.",
            ),
            "Reliability": (
                "reliability",
                "Run all currently applicable reliability checks?",
                "The suite performs suspend/resume, then automatically starts, advances or confirms cold-boot tracking. If this boot was already counted, it records that a physical cold boot is required instead of producing a false failure.",
            ),
        }
        validation_sections = [
            (
                "Recommended workflows",
                "Build a complete evidence dossier or run a new health assessment.",
                [
                    ("Build acceptance dossier", "Combine selected same-version reports with integrity and provenance checks", self.on_dossier, True),
                    ("Run automated suite", "All non-guided transport checks except suspend, with one authorization", self.on_automated, False),
                    ("Run quiet diagnostics", "All automated checks that do not play, record, vibrate, suspend, or require guidance", self.on_quiet, False),
                    ("Run full passive suite", "All deep read-only checks in one merged report", self.on_passive, False),
                    ("Run passive audit", "Fast read-only checks; no administrator access", self.on_audit, False),
                ],
            ),
            (
                "Audio and media",
                "Sound, cameras, display transport and visible hardware controls.",
                [
                    ("Test audio", "Exclusive PCM transports, a quiet tone, and microphone signal analysis", self.on_audio, False),
                    ("Test cameras", "Analyze both sensors and exercise one rear-focus step", self.on_camera, False),
                    ("Inspect display", "Validate i915, DSI, Micro-HDMI video/audio, and desktop policy", self.on_display, False),
                    ("Test lights", "Exercise and restore the panel, Halo, indicator, and charging lights", self.on_lights, False),
                ],
            ),
            (
                "Input and sensors",
                "Unattended capability, haptic and pen-mapping stack checks.",
                [
                    ("Inspect inputs", "Validate key, switch, touch, pen, jack, and haptic capability maps", self.on_inputs, False),
                    ("Test haptics", "Pulse the left and right Halo actuators for 150 ms", self.on_haptics, False),
                    ("Inspect pen mapping stack", "Verify Wacom, Halo, libwacom, Mutter and current orientation without synthetic input", self.on_pen_stack, False),
                ],
            ),
            (
                "Platform and power",
                "Software sources, core SoC integration, sensors, thermal safeguards and charging.",
                [
                    ("Check software sources", "Refresh signed APT release metadata in disposable cache directories", self.on_apt, False),
                    ("Inspect platform", "Read-only validation of SoC drivers, CPU power, thermals and eMMC health", self.on_platform, False),
                    ("Inspect resources", "Profile Yoga Book services and verify thermal safeguards", self.on_resources, False),
                    ("Inspect power", "Validate battery, charger, fuel-gauge, and desktop telemetry", self.on_power, False),
                    ("Observe charging", "Verify sustained charge progress or a stable full state", self.on_charging, False),
                    ("Test sensors", "Read every ambient-light, accelerometer, hinge, and proximity channel", self.on_sensors, False),
                ],
            ),
            (
                "Connectivity and storage",
                "Radios, USB topology and removable-media coverage.",
                [
                    ("Test wireless", "Verify Wi-Fi plus Bluetooth features and RF reception", self.on_wireless, False),
                    ("Validate LTE", "Check SIM registration and an existing mobile-data bearer without changing it", self.on_modem, False),
                    ("Validate GNSS", "Check private runtime, transport, gpsd, sky data and require an outdoor fix", self.on_gnss, False),
                    ("Inspect USB", "Validate xHCI hubs, role switch, modem transport, and attached accessories", self.on_usb, False),
                    ("Test storage", "Read the inserted SD card and mount filesystems read-only", self.on_storage, False),
                    ("Test internal storage", "Write, verify, synchronize, and remove one bounded root-filesystem file", self.on_internal_storage, False),
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
                "Guided physical validation",
                "Optional end-to-end observations excluded from every automatic category runner.",
                [
                    ("Run passive + physical acceptance", "Combine deep passive diagnostics and guided physical observations", self.on_full, False),
                    ("Validate wired headset controls", "Guided unplug, insertion and media-button observation", self.on_headset, False),
                    ("Validate buttons and lid", "Guided Power, Volume and lid-event observation", self.on_controls, False),
                    ("Validate keyboard/pen transition", "Guided physical Halo-to-pen-to-Halo mode cycle", self.on_modes, False),
                    ("Validate physical rotations", "Guided traversal of all four sensor orientations", self.on_rotation, False),
                    ("Validate live sensor responses", "Guided light, proximity and hinge stimulation", self.on_sensor_interactions, False),
                    ("Validate physical pen mapping", "Guided real-stylus targets across every orientation", self.on_pen_mapping, False),
                    ("Validate USB OTG cycle", "Guided cable insertion, descriptor transfer and removal", self.on_usb_cycle, False),
                    ("Record physical observations", "Document what you can hear, touch, and observe", self.on_physical, False),
                ],
            ),
        ]
        for section_title, section_description, section_rows in validation_sections:
            actions = Adw.PreferencesGroup(title=section_title, description=section_description)
            page.add(actions)
            searchable_rows: list[tuple[Adw.ActionRow, str, Gtk.Button]] = []
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
                searchable_rows.append(
                    (
                        row,
                        " ".join((title, subtitle, section_title, section_description, subtest_name)),
                        button,
                    )
                )
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
                self.validation_button_groups[category_button] = actions
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

            category_id = category_action[0] if category_action is not None else ""
            section_search_text = " ".join((section_title, section_description, category_id))
            self.validation_groups.append((actions, section_search_text, searchable_rows))

        self.no_search_results = Adw.PreferencesGroup()
        self.no_search_results.set_visible(False)
        self.no_search_results_row = Adw.ActionRow(
            title="No tests match your search",
            subtitle="Try a test name, hardware feature, or category.",
        )
        no_results_icon = Gtk.Image.new_from_icon_name("edit-find-symbolic")
        no_results_icon.set_pixel_size(24)
        self.no_search_results_row.add_prefix(no_results_icon)
        self.no_search_results.add(self.no_search_results_row)
        page.add(self.no_search_results)

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

        self.evidence_integrity = Adw.PreferencesGroup(title="Evidence integrity")
        self.evidence_integrity.set_visible(False)
        page.add(self.evidence_integrity)
        self.evidence_integrity_rows: list[Adw.PreferencesRow] = []

        self.execution_plan = Adw.PreferencesGroup(title="Next validation actions")
        self.execution_plan.set_visible(False)
        page.add(self.execution_plan)
        self.execution_plan_rows: list[Adw.ActionRow] = []
        self.execution_plan_buttons: list[Gtk.Button] = []

        self.acceptance = Adw.PreferencesGroup(title="Component acceptance")
        self.acceptance.set_visible(False)
        page.add(self.acceptance)
        self.acceptance_rows: list[Adw.ActionRow] = []

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

    def on_validation_search_changed(self, entry: Gtk.SearchEntry) -> None:
        self.apply_validation_filter(entry.get_text())

    def on_validation_search_stopped(self, entry: Gtk.SearchEntry) -> None:
        entry.set_text("")

    def apply_validation_filter(self, query: str | None = None) -> None:
        query = self.validation_search.get_text() if query is None else query
        active_buttons = {button for _name, button in self.active_subtests}
        if self.current_run_button is not None:
            active_buttons.add(self.current_run_button)

        visible_groups = 0
        for group, section_text, rows in self.validation_groups:
            section_matches = validation_search_matches(query, section_text)
            any_row_visible = False
            for row, row_text, button in rows:
                row_visible = section_matches or validation_search_matches(query, row_text)
                row_visible = row_visible or button in active_buttons
                row.set_visible(row_visible)
                any_row_visible = any_row_visible or row_visible

            category_is_active = any(
                self.validation_button_groups.get(button) is group for button in active_buttons
            )
            group_visible = any_row_visible or category_is_active
            group.set_visible(group_visible)
            visible_groups += int(group_visible)

        no_matches = bool(query.strip()) and visible_groups == 0
        if no_matches:
            self.no_search_results_row.set_title(f"No tests match ‘{query.strip()}’")
        self.no_search_results.set_visible(no_matches)

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
            "The suite runs passive, platform, bounded internal-storage I/O, display, sensor, power, USB, LTE, GNSS, camera, input, storage, wireless, light, haptic, and audible audio tests. Each state-changing test restores its original state. Guided headset and suspend tests are not included. Administrator authorization is required.",
            lambda: self.run_command("automated", ["--yes"]),
        )

    def on_quiet(self, _button) -> None:
        self.confirm(
            "Run quiet hardware diagnostics?",
            "This suite validates platform, bounded internal-storage I/O, display, sensors, power, USB, LTE, GNSS, cameras, input capabilities, storage, Wi-Fi, Bluetooth and lights. It does not play or record audio, vibrate haptics, suspend the tablet, or request guided actions. Every state-changing check restores its original state.",
            lambda: self.run_command("quiet", ["--yes"]),
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
            "Desktop audio is paused temporarily. The test plays a quiet one-second tone, records three seconds from Mic1, checks both channels for signal, clipping, DC offset and imbalance, then restores the previous ALSA and PipeWire state. Listening quality and intelligibility remain separate physical observations. Administrator authorization is required.",
            lambda: self.run_command("audio", ["--yes"]),
        )

    def on_headset(self, _button) -> None:
        self.confirm(
            "Test a connected wired headset?",
            "Connect a four-pole headset first. The validator keeps speakers muted, plays one quiet one-second tone through the headphones, analyzes both captured microphone channels for signal, clipping, DC offset and imbalance, then asks you to unplug, reinsert and press one headset button. Listening quality and intelligibility remain physical observations. It restores the original ALSA and desktop-audio state.",
            lambda: self.run_command("headset", ["--yes", "--timeout", "90"]),
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
            "The validator briefly switches the AtomISP route, discards two warm-up buffers, checks five in-memory Bayer frames per camera for freeze, clipping, corruption, spatial structure and temporal coherence, moves rear focus by one position, and restores the original focus and route. Images are never saved or logged.",
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

    def on_internal_storage(self, _button) -> None:
        self.confirm(
            "Write-test internal storage?",
            "The validator creates one private 4 MiB non-zero file on the internal root filesystem, fsyncs and read-verifies it, removes it, then synchronizes the containing directory. It refuses a target on another mount and reports any residual probe file. Administrator authorization is required.",
            lambda: self.run_command("internal-storage", ["--yes"]),
        )

    def on_inputs(self, _button) -> None:
        self.confirm(
            "Inspect input capabilities?",
            "The validator opens each kernel input node read-only to inspect its capability map. It does not grab devices, monitor events, record keys or touches, or inject input. Administrator authorization is required.",
            lambda: self.run_command("inputs", ["--yes"]),
        )

    def on_pen_stack(self, _button) -> None:
        self.run_command("pen-stack", [])

    def on_controls(self, _button) -> None:
        self.confirm(
            "Test Power, Volume and lid events?",
            "The validator temporarily grabs only the two GPIO button devices and lid switch, preventing desktop power or suspend actions. Press Power, Volume Up and Volume Down once, then close and reopen the lid. Every grab is released even on timeout or cancellation. Administrator authorization is required.",
            lambda: self.run_command("controls", ["--yes", "--timeout", "90"]),
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

    def on_pen_mapping(self, _button) -> None:
        self.confirm(
            "Test pen mapping in every orientation?",
            "Start in Halo keyboard mode. Switch to pen mode when asked, then use only the Wacom pen to hit four targets in upright landscape, both portraits, inverted landscape and returned upright. Finger and mouse input are ignored; raw pen coordinates are never stored. Return to Halo keyboard mode when asked. Administrator authorization is required.",
            lambda: self.run_command("pen-mapping", ["--yes", "--timeout", "240"]),
        )

    def on_sensor_interactions(self, _button) -> None:
        self.confirm(
            "Test physical sensor responses?",
            "Follow the full-screen prompts to shade and expose both ambient-light sensors, move a hand near and away from the Halo surface, then open or fold the hinge. The test reads IIO channels only, stores aggregate ranges rather than raw samples, and changes no sensor or desktop policy. Administrator authorization is required.",
            lambda: self.run_command("sensor-interactions", ["--yes", "--timeout", "120"]),
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

    def on_charging(self, _button) -> None:
        self.confirm(
            "Observe charging for 30 seconds?",
            "This read-only check samples charger continuity, fuel-gauge progression and battery temperatures. Leave the cable state unchanged during the observation.",
            lambda: self.run_command("charging", ["--seconds", "30"]),
        )

    def on_platform(self, _button) -> None:
        self.run_command("platform", [])

    def on_apt(self, _button) -> None:
        self.confirm(
            "Check configured software sources?",
            "The validator contacts every configured APT repository for signed release metadata using disposable list and cache directories. It downloads no package indexes and does not modify the system APT cache.",
            lambda: self.run_command("apt", []),
        )

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

    def on_modem(self, _button) -> None:
        self.confirm(
            "Validate the existing LTE session?",
            "Without a SIM the validator records conditional skips. With a registered, already-connected bearer it sends three packets through that interface. It never enables, connects or disconnects the modem.",
            lambda: self.run_command("modem", []),
        )

    def on_gnss(self, _button) -> None:
        self.confirm(
            "Validate GNSS outdoors?",
            "This check requires the legally imported BCM4752 runtime and a clear view of the sky. It validates the transport, gpsd reports, satellite data and a real position fix without retaining location history.",
            lambda: self.run_command("gnss", ["--require-fix"]),
        )

    def on_usb(self, _button) -> None:
        self.run_command("usb", [])

    def on_usb_cycle(self, _button) -> None:
        self.confirm(
            "Test a USB OTG accessory?",
            "Start with no OTG accessory connected. The validator will ask you to disconnect any cable, insert exactly one accessory, then remove it and restore the original cable state. It verifies host role, enumeration and a bounded descriptor transfer without retaining device identity. Stop still requires the original cable state to be restored.",
            lambda: self.run_command("usb-cycle", ["--yes", "--timeout", "90"]),
        )

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
        self.apply_validation_filter()
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
        self.apply_validation_filter()

    def set_subtest_result(self, name: str, status: str) -> None:
        matches = [index for index, entry in enumerate(self.active_subtests) if entry[0] == name]
        button = self.subtest_buttons.get(name)
        if button is None:
            return
        was_active = bool(matches and matches[-1] == len(self.active_subtests) - 1)
        if matches:
            self.active_subtests.pop(matches[-1])
        if status == "SKIP":
            spinner = self.row_spinners[button]
            icon = self.row_status_icons[button]
            spinner.stop()
            spinner.set_visible(False)
            icon.set_from_icon_name("media-playback-pause-symbolic")
            icon.set_tooltip_text("Skipped or not applicable")
            icon.add_css_class("dim-label")
            icon.set_visible(True)
        elif status == "WARN":
            spinner = self.row_spinners[button]
            icon = self.row_status_icons[button]
            spinner.stop()
            spinner.set_visible(False)
            icon.set_from_icon_name("dialog-warning-symbolic")
            icon.set_tooltip_text("Completed with warnings")
            icon.add_css_class("dim-label")
            icon.set_visible(True)
        else:
            self.set_row_result(button, 0 if status == "PASS" else 1, False)
        if was_active and self.active_subtests:
            self.set_row_running(self.active_subtests[-1][1])
        self.apply_validation_filter()

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
        self.apply_validation_filter()
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
        for row in self.evidence_integrity_rows:
            self.evidence_integrity.remove(row)
        self.evidence_integrity_rows.clear()
        self.evidence_integrity.set_description("")
        self.evidence_integrity.set_visible(False)
        for button in self.execution_plan_buttons:
            if button in self.run_buttons:
                self.run_buttons.remove(button)
            self.row_spinners.pop(button, None)
            self.row_status_icons.pop(button, None)
            self.run_button_icons.pop(button, None)
            self.run_button_tooltips.pop(button, None)
        self.execution_plan_buttons.clear()
        for row in self.execution_plan_rows:
            self.execution_plan.remove(row)
        self.execution_plan_rows.clear()
        self.execution_plan.set_description("")
        self.execution_plan.set_visible(False)
        for row in self.acceptance_rows:
            self.acceptance.remove(row)
        self.acceptance_rows.clear()
        self.acceptance.set_description("")
        self.acceptance.set_visible(False)

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
            acceptance = model.get("acceptance")
            readiness = acceptance.get("summary", {}) if acceptance else {}
            integrity = model.get("integrity", {})
            accepted = readiness.get("components_complete", 0)
            component_total = readiness.get("components_total", 0)
            title = (
                "No problems found" if result == "PASS" else
                "Completed with warnings" if result == "PASS_WITH_WARNINGS" else
                "Problems found"
            )
            if result == "PASS" and acceptance and accepted < component_total:
                title = "Diagnostics passed · acceptance incomplete"
            if integrity.get("status") == "FAIL":
                title = "Evidence integrity failed"
            self.overview_row.set_title(title)
            subtitle = (
                f"{counts['PASS']} passed · {counts['FAIL']} failed · {counts['WARN']} warnings · "
                f"{counts['SKIP']} skipped · {summary['coverage_percent']}% check coverage"
            )
            if acceptance:
                subtitle += f" · {accepted}/{component_total} components accepted"
            if integrity:
                subtitle += f" · integrity {integrity.get('status', 'unknown')}"
            self.overview_row.set_subtitle(subtitle)
            if integrity:
                inventory = model.get("package_inventory", {})
                integrity_status = integrity.get("status", "unknown")
                self.evidence_integrity.set_description(
                    "Only complete, untampered evidence can satisfy device acceptance."
                )
                self.evidence_integrity.set_visible(True)
                gate = Adw.ActionRow(
                    title="Evidence gate",
                    subtitle=(
                        f"State preservation {integrity.get('state_preservation', 'unknown')} · "
                        f"run finished {'yes' if integrity.get('run_finished') else 'no'} · "
                        f"package inventory {'complete' if integrity.get('package_inventory_complete') else 'incomplete'}"
                    ),
                )
                gate_badge = Gtk.Label(label=integrity_status)
                gate_badge.add_css_class("status-badge")
                gate_badge.add_css_class(f"status-{integrity_status.lower()}")
                gate.add_suffix(gate_badge)
                self.evidence_integrity.add(gate)
                self.evidence_integrity_rows.append(gate)
                for problem in integrity.get("problems", []):
                    problem_row = Adw.ActionRow(title=problem, subtitle="This problem invalidates acceptance evidence.")
                    problem_badge = Gtk.Label(label="FAIL")
                    problem_badge.add_css_class("status-badge")
                    problem_badge.add_css_class("status-fail")
                    problem_row.add_suffix(problem_badge)
                    self.evidence_integrity.add(problem_row)
                    self.evidence_integrity_rows.append(problem_row)
                if inventory and not inventory.get("complete", False):
                    inventory_details = []
                    if inventory.get("missing"):
                        inventory_details.append(f"Missing: {', '.join(inventory['missing'])}")
                    if inventory.get("unexpected"):
                        inventory_details.append(f"Unexpected: {', '.join(inventory['unexpected'])}")
                    inventory_details.extend(inventory.get("problems", []))
                    inventory_row = Adw.ActionRow(
                        title="Validated package inventory is incomplete",
                        subtitle=" · ".join(inventory_details) or "The captured package identities are inconsistent.",
                    )
                    inventory_badge = Gtk.Label(label=f"{inventory.get('captured', 0)}/{inventory.get('expected', 0)}")
                    inventory_badge.add_css_class("status-badge")
                    inventory_badge.add_css_class("status-fail")
                    inventory_row.add_suffix(inventory_badge)
                    self.evidence_integrity.add(inventory_row)
                    self.evidence_integrity_rows.append(inventory_row)
            if acceptance:
                execution_plan = acceptance.get("execution_plan", {})
                if execution_plan.get("schema") == "org.yogabook.validator.execution-plan/v1":
                    actions = execution_plan.get("actions", [])
                    plan_scope = (
                        "Evidence integrity blocks every component-specific action until a trusted "
                        "new capture succeeds. "
                        if execution_plan.get("integrity_blocking") or integrity.get("status") != "PASS"
                        else (
                            f"{len(actions)} deduplicated action(s) cover "
                            f"{execution_plan.get('components_affected', 0)} incomplete component(s). "
                        )
                    )
                    self.execution_plan.set_description(
                        plan_scope
                        + "Play icons use local trusted UI actions; command text remains informational."
                    )
                    self.execution_plan.set_visible(True)
                    if not actions:
                        complete_row = Adw.ActionRow(
                            title="No further validation action is required",
                            subtitle="All acceptance selectors have passing evidence.",
                        )
                        complete_badge = Gtk.Label(label="PASS")
                        complete_badge.add_css_class("status-badge")
                        complete_badge.add_css_class("status-pass")
                        complete_row.add_suffix(complete_badge)
                        self.execution_plan.add(complete_row)
                        self.execution_plan_rows.append(complete_row)
                    for index, action in enumerate(actions, start=1):
                        prerequisites = " ".join(action.get("prerequisites", []))
                        details = [
                            f"{action.get('interaction_class', 'unknown').title()} · "
                            f"affects {action.get('components_affected', 0)} component(s)",
                            f"$ {action.get('command', '')}",
                            action.get("safety_note", ""),
                        ]
                        if prerequisites:
                            details.append(f"Prerequisites: {prerequisites}")
                        action_row = Adw.ActionRow(
                            title=f"{index}. {action.get('title', action.get('id', 'Validation action'))}",
                            subtitle="\n".join(item for item in details if item),
                        )
                        action_badge = Gtk.Label(label=action.get("status", "UNKNOWN"))
                        action_badge.add_css_class("status-badge")
                        action_badge.add_css_class(
                            f"status-{action.get('status', 'unknown').lower().replace('_', '-')}"
                        )
                        action_id = action.get("id")
                        handler_name = EXECUTION_ACTION_HANDLERS.get(action_id)
                        if integrity.get("status") != "PASS" and action_id != "recapture-evidence":
                            handler_name = None
                        action_suffix = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
                        action_suffix.set_valign(Gtk.Align.CENTER)
                        action_suffix.append(action_badge)
                        if handler_name is not None:
                            callback = getattr(self, handler_name)
                            action_button = self.create_action_button(
                                "media-playback-start-symbolic", 18
                            )
                            action_button.add_css_class("flat")
                            action_button.set_size_request(36, 36)
                            action_button.set_halign(Gtk.Align.START)
                            action_button.set_valign(Gtk.Align.CENTER)
                            tooltip = f"Run {action.get('title', action_id)}"
                            self.set_action_button_state(
                                action_button,
                                "media-playback-start-symbolic",
                                tooltip,
                            )
                            action_button.connect(
                                "clicked", self.on_run_button_clicked, callback
                            )
                            spinner = Gtk.Spinner()
                            spinner.set_visible(False)
                            status_icon = Gtk.Image()
                            status_icon.set_pixel_size(20)
                            status_icon.set_visible(False)
                            self.run_buttons.append(action_button)
                            self.execution_plan_buttons.append(action_button)
                            self.row_spinners[action_button] = spinner
                            self.row_status_icons[action_button] = status_icon
                            self.run_button_tooltips[action_button] = tooltip
                            action_state = Gtk.Overlay()
                            action_state.set_size_request(24, 24)
                            action_state.set_child(spinner)
                            action_state.add_overlay(status_icon)
                            action_suffix.append(action_state)
                            action_suffix.append(action_button)
                        action_row.add_suffix(action_suffix)
                        self.execution_plan.add(action_row)
                        self.execution_plan_rows.append(action_row)

                layer_readiness = readiness.get("layers", {})
                if all(layer in layer_readiness for layer in ("structural", "functional", "physical")):
                    self.acceptance.set_description(
                        "Layer readiness · "
                        + " · ".join(
                            f"{layer.title()} {layer_readiness[layer]['components_complete']}/{component_total}"
                            for layer in ("structural", "functional", "physical")
                        )
                    )
                self.acceptance.set_visible(True)
                for component in acceptance.get("components", []):
                    layers = component["layers"]
                    row_type = Adw.ActionRow if component["status"] == "PASS" else Adw.ExpanderRow
                    row = row_type(
                        title=component["name"],
                        subtitle=(
                            f"Structural {layers['structural']['status']} · "
                            f"Functional {layers['functional']['status']} · "
                            f"Physical {layers['physical']['status']}"
                        ),
                    )
                    badge = Gtk.Label(label=component["status"])
                    badge.add_css_class("status-badge")
                    badge.add_css_class(f"status-{component['status'].lower().replace('_', '-')}")
                    if isinstance(row, Adw.ExpanderRow):
                        row.add_action(badge)
                        for blocker in component.get("root_blockers", component.get("blockers", [])):
                            blocked_selectors = blocker.get("blocked_selectors", [])
                            dependency_note = (
                                f" Blocks {len(blocked_selectors)} dependent check(s): "
                                f"{', '.join(blocked_selectors)}."
                                if blocked_selectors else ""
                            )
                            blocker_row = Adw.ActionRow(
                                title=f"{blocker['layer'].title()} · {blocker['selector']}",
                                subtitle=(
                                    f"{blocker.get('reason', '')} "
                                    f"{dependency_note} "
                                    f"Next: {blocker.get('recommended_action', '')}"
                                ).strip(),
                            )
                            blocker_badge = Gtk.Label(label=blocker["status"])
                            blocker_badge.add_css_class("status-badge")
                            blocker_badge.add_css_class(
                                f"status-{blocker['status'].lower().replace('_', '-')}"
                            )
                            blocker_row.add_suffix(blocker_badge)
                            row.add_row(blocker_row)
                    else:
                        row.add_suffix(badge)
                    self.acceptance.add(row)
                    self.acceptance_rows.append(row)
        else:
            with report.open(newline="", encoding="utf-8") as stream:
                rows = [row for row in csv.DictReader(stream, delimiter="\t") if row["subsystem"] != "suite"]
            counts = {status: sum(row["status"] == status for row in rows) for status in self.live_counts}
            self.overview_row.set_title("Validation complete")
            self.overview_row.set_subtitle(
                f"{counts['PASS']} passed · {counts['FAIL']} failed · {counts['WARN']} warnings · {counts['SKIP']} skipped"
            )
        severity = {"FAIL": 0, "WARN": 1, "PASS": 2, "SKIP": 3, "INFO": 4}
        findings = {
            finding["id"]: finding
            for finding in model.get("findings", [])
        } if model_path.is_file() else {}
        rows.sort(key=lambda row: (severity.get(row["status"], 5), row["subsystem"], row["check_id"]))
        for result in rows:
            status = result["status"]
            finding = findings.get(f'{result["subsystem"]}/{result["check_id"]}')
            row_type = Adw.ExpanderRow if finding else Adw.ActionRow
            row = row_type(
                title=result["summary"],
                subtitle=f'{result["subsystem"]} · {result["check_id"]}' + (f' — {result["details"]}' if result["details"] else ""),
            )
            badge = Gtk.Label(label=status)
            badge.add_css_class("status-badge")
            badge.add_css_class(f"status-{status.lower()}")
            if isinstance(row, Adw.ExpanderRow) and finding:
                row.add_action(badge)
                row.add_row(
                    Adw.ActionRow(
                        title="Recommended next step",
                        subtitle=finding["recommended_action"],
                    )
                )
            else:
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

    def on_dossier(self, _button) -> None:
        chooser = Gtk.FileChooserNative.new(
            "Select validation report folders",
            self,
            Gtk.FileChooserAction.SELECT_FOLDER,
            "Build dossier",
            "Cancel",
        )
        chooser.set_select_multiple(True)
        chooser.set_current_folder(Gio.File.new_for_path(str(results_root())))
        chooser.connect("response", self.on_dossier_response)
        self.dossier_chooser = chooser
        chooser.show()

    def on_dossier_response(self, chooser: Gtk.FileChooserNative, response: int) -> None:
        if response == Gtk.ResponseType.ACCEPT:
            files = chooser.get_files()
            sources = [
                Path(item.get_path())
                for index in range(files.get_n_items())
                if (item := files.get_item(index)) is not None and item.get_path() is not None
            ]
            if sources:
                self.run_command("dossier", [str(source) for source in sources])
            else:
                self.pending_run_button = None
                self.show_error("No reports selected", "Select at least one Validator report folder.")
        else:
            self.pending_run_button = None
        chooser.hide()
        self.dossier_chooser = None

    def show_error(self, heading: str, body: str) -> None:
        dialog = Adw.MessageDialog.new(self, heading, body)
        dialog.add_response("close", "Close")
        dialog.present()


class PhysicalWindow(Adw.Window):
    def __init__(self, parent: ValidatorWindow, command: str = "physical") -> None:
        title = "Passive + physical acceptance" if command == "full" else "Physical acceptance"
        super().__init__(transient_for=parent, modal=True, title=title)
        self.parent_window = parent
        self.command = command
        self.set_default_size(760, 700)
        self.rows: list[tuple[str, Gtk.DropDown, Gtk.Entry, Gtk.CheckButton]] = []
        self.imported_observed_at: dict[str, str] = {}

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        save = Gtk.Button(label="Start validation" if command == "full" else "Save results")
        save.add_css_class("suggested-action")
        save.connect("clicked", self.on_save)
        header.pack_end(save)
        load = Gtk.Button(label="Load observations")
        load.set_tooltip_text("Load internally consistent reference values from this release and runtime")
        load.connect("clicked", self.on_load)
        header.pack_start(load)
        toolbar.add_top_bar(header)
        page = Adw.PreferencesPage()
        description = (
            "Choose an explicit result for every item. Fail and Not applicable require a reason; "
            "nothing is silently recorded as skipped."
        )
        if command == "full":
            description = "Record the observations to include after deep passive diagnostics. " + description
        page.set_description(description)
        labels = dict(PHYSICAL_CHECKS)
        for group_title, group_description, check_ids in PHYSICAL_GROUPS:
            group = Adw.PreferencesGroup(title=group_title, description=group_description)
            page.add(group)
            for check_id in check_ids:
                row = Adw.ActionRow(title=labels[check_id])
                dropdown = Gtk.DropDown.new_from_strings(
                    ["Choose result", "Pass", "Fail", "Not applicable"]
                )
                dropdown.set_selected(0)
                note = Gtk.Entry(placeholder_text="Optional context for a passing observation")
                note.set_width_chars(18)
                confirmation = Gtk.CheckButton()
                confirmation.set_tooltip_text("Confirm this observation for the current session")
                confirmation.update_property(
                    [Gtk.AccessibleProperty.LABEL],
                    ["Confirmed for the current session"],
                )
                dropdown.connect("notify::selected", self.on_status_changed, note, confirmation)
                row.add_suffix(dropdown)
                row.add_suffix(note)
                row.add_suffix(confirmation)
                group.add(row)
                self.rows.append((check_id, dropdown, note, confirmation))
        toolbar.set_content(page)
        self.set_content(toolbar)

    def on_status_changed(
        self,
        dropdown: Gtk.DropDown,
        _property,
        note: Gtk.Entry,
        confirmation: Gtk.CheckButton,
    ) -> None:
        confirmation.set_active(dropdown.get_selected() != 0)
        if dropdown.get_selected() in (2, 3):
            note.set_placeholder_text("Required reason or observation context")
        else:
            note.set_placeholder_text("Optional context for a passing observation")

    def on_load(self, _button) -> None:
        chooser = Gtk.FileChooserNative.new(
            "Load verified physical observations",
            self,
            Gtk.FileChooserAction.SELECT_FOLDER,
            "Load observations",
            "Cancel",
        )
        chooser.set_current_folder(Gio.File.new_for_path(str(results_root())))
        chooser.connect("response", self.on_load_response)
        self.load_chooser = chooser
        chooser.show()

    def on_load_response(self, chooser: Gtk.FileChooserNative, response: int) -> None:
        report_directory = None
        if response == Gtk.ResponseType.ACCEPT:
            selected = chooser.get_file()
            report_directory = Path(selected.get_path()) if selected and selected.get_path() else None
        chooser.hide()
        self.load_chooser = None
        if response != Gtk.ResponseType.ACCEPT:
            return
        if report_directory is None:
            self.finish_observation_load(None, "No report folder was selected.")
            return
        threading.Thread(
            target=self.load_observations_worker,
            args=(report_directory,),
            daemon=True,
        ).start()

    def load_observations_worker(self, report_directory: Path) -> None:
        try:
            version_result = subprocess.run(
                [str(CLI), "version"],
                text=True,
                capture_output=True,
                timeout=5,
            )
            version_match = re.search(r"(\d+\.\d+\.\d+)", version_result.stdout)
            if version_result.returncode != 0 or version_match is None:
                raise ValueError("The installed Validator version could not be determined.")
            device = Path("/sys/class/dmi/id/product_name").read_text(encoding="utf-8").strip()
            command = [
                sys.executable,
                str(PHYSICAL_IMPORT),
                str(report_directory),
                "--validator-version",
                version_match.group(1),
                "--device",
                device,
                "--matrix",
                str(ACCEPTANCE_MATRIX),
            ]
            for check_id, _label in PHYSICAL_CHECKS:
                command.extend(["--check-id", check_id])
            completed = subprocess.run(command, text=True, capture_output=True, timeout=15)
            if completed.returncode != 0:
                message = completed.stderr.strip().splitlines()[-1] if completed.stderr.strip() else "Import failed."
                raise ValueError(message.removeprefix("yogabook-validator-physical-import.py: error: "))
            imported = {
                item["check_id"]: item
                for item in json.loads(completed.stdout)
            }
            GLib.idle_add(self.finish_observation_load, imported, "")
        except (OSError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as exc:
            GLib.idle_add(self.finish_observation_load, None, str(exc))

    def finish_observation_load(
        self,
        imported: dict[str, dict[str, str]] | None,
        error: str,
    ) -> bool:
        if imported is not None:
            selected_index = {"PASS": 1, "FAIL": 2, "SKIP": 3}
            for check_id, dropdown, note, confirmation in self.rows:
                item = imported[check_id]
                dropdown.set_selected(selected_index[item["status"]])
                note.set_text(item["note"])
                confirmation.set_active(False)
                self.imported_observed_at[check_id] = item["observed_at"]
            dialog = Adw.MessageDialog.new(
                self,
                "Reference observations loaded",
                "The source is internally consistent and matches this model, Validator release, acceptance matrix and installed package inventory. Reconfirm every observation for the current session before saving.",
            )
            dialog.add_response("close", "Review observations")
            dialog.present()
        else:
            dialog = Adw.MessageDialog.new(
                self,
                "Observations could not be loaded",
                error,
            )
            dialog.add_response("close", "Close")
            dialog.present()
        return GLib.SOURCE_REMOVE

    def on_save(self, _button) -> None:
        missing_results = []
        missing_context = []
        unconfirmed = []
        labels = dict(PHYSICAL_CHECKS)
        for check_id, dropdown, note, confirmation in self.rows:
            selected = dropdown.get_selected()
            if selected == 0:
                missing_results.append(labels[check_id])
            elif selected in (2, 3) and not note.get_text().strip():
                missing_context.append(labels[check_id])
            elif not confirmation.get_active():
                unconfirmed.append(labels[check_id])
        if missing_results or missing_context or unconfirmed:
            details = []
            if missing_results:
                details.append(f"Choose a result for {len(missing_results)} item(s).")
            if missing_context:
                details.append(f"Add a reason for {len(missing_context)} failed or unavailable item(s).")
            if unconfirmed:
                details.append(f"Reconfirm {len(unconfirmed)} imported observation(s) for this session.")
            dialog = Adw.MessageDialog.new(
                self,
                "Physical observations are incomplete",
                " ".join(details) + " No result has been saved.",
            )
            dialog.add_response("close", "Review observations")
            dialog.present()
            return
        cache = Path(GLib.get_user_cache_dir()) / "yogabook-validator"
        cache.mkdir(mode=0o700, parents=True, exist_ok=True)
        cache.chmod(0o700)
        descriptor, answer_name = tempfile.mkstemp(prefix=f"{self.command}-", suffix=".tsv", dir=cache)
        answers = Path(answer_name)
        values = [None, "PASS", "FAIL", "SKIP"]
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
            for check_id, dropdown, note, _confirmation in self.rows:
                clean_note = note.get_text().strip().replace("\t", " ").replace("\n", " ")
                status = values[dropdown.get_selected()]
                if status is None:
                    raise RuntimeError("physical observation validation was bypassed")
                observed_at = self.imported_observed_at.get(check_id, "")
                stream.write(f"{check_id}\t{status}\t{clean_note}\t{observed_at}\n")
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
            .status-skip, .status-info, .status-stale, .status-unimplemented, .status-incomplete, .status-not-run { background: alpha(currentColor, .10); }
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
