#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

from __future__ import annotations

import csv
import os
from pathlib import Path
import subprocess
import sys
import threading
from datetime import datetime

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402


APP_ID = "org.yogabook.Validator"
INSTALLED_CLI = Path("/usr/bin/yogabook-validator")
SOURCE_CLI = Path(__file__).resolve().parents[1] / "src" / "yogabook-validator.sh"
CLI = Path(os.environ.get("YBV_CLI", INSTALLED_CLI if INSTALLED_CLI.exists() else SOURCE_CLI))

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
        self.set_default_size(900, 680)
        self.last_report: Path | None = None

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        toolbar.add_top_bar(header)

        page = Adw.PreferencesPage()
        page.set_title("Hardware status")
        page.set_description("Automated transport checks and physical acceptance are reported separately.")
        toolbar.set_content(page)
        self.set_content(toolbar)

        actions = Adw.PreferencesGroup(title="Validation")
        page.add(actions)
        for title, subtitle, callback, suggested in [
            ("Run automated suite", "All transport checks except suspend, with one authorization", self.on_automated, True),
            ("Run passive audit", "Read-only checks; no administrator access", self.on_audit, False),
            ("Test audio", "Exclusive PCM tests, a quiet tone, and microphone capture", self.on_audio, False),
            ("Test cameras", "Stream three frames from both sensors and restore the original route", self.on_camera, False),
            ("Test haptics", "Pulse the left and right Halo actuators for 150 ms", self.on_haptics, False),
            ("Inspect inputs", "Validate key, switch, touch, pen, jack, and haptic capability maps", self.on_inputs, False),
            ("Test lights", "Exercise and restore the panel, Halo, indicator, and charging lights", self.on_lights, False),
            ("Inspect power", "Validate battery, charger, fuel-gauge, and desktop telemetry", self.on_power, False),
            ("Test sensors", "Read every ambient-light, accelerometer, hinge, and proximity channel", self.on_sensors, False),
            ("Test storage", "Read the inserted SD card and mount filesystems read-only", self.on_storage, False),
            ("Inspect USB", "Validate xHCI hubs, role switch, modem transport, and attached accessories", self.on_usb, False),
            ("Test wireless", "Verify Wi-Fi gateway transport and briefly scan with Bluetooth", self.on_wireless, False),
            ("Test suspend", "Full-duplex audio across one suspend/resume cycle", self.on_suspend, False),
            ("Physical acceptance", "Record what you can hear, touch, and observe", self.on_physical, False),
        ]:
            row = Adw.ActionRow(title=title, subtitle=subtitle)
            button = Gtk.Button(label="Run")
            if suggested:
                button.add_css_class("suggested-action")
            button.set_valign(Gtk.Align.CENTER)
            button.connect("clicked", callback)
            row.add_suffix(button)
            actions.add(row)

        self.summary = Adw.PreferencesGroup(title="Results")
        page.add(self.summary)
        self.result_rows: list[Adw.ActionRow] = []
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
        export_row = Adw.ActionRow(
            title="Reports",
            subtitle="TSV results and a human-readable log are saved together.",
        )
        export_row.add_suffix(self.open_button)
        exports.add(export_row)

        self.spinner = Gtk.Spinner()
        self.spinner.set_visible(False)
        header.pack_start(self.spinner)

    def report_path(self, command: str) -> Path:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        return results_root() / f"{command}-{stamp}"

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

    def on_automated(self, _button) -> None:
        self.confirm(
            "Run the automated hardware suite?",
            "The suite runs passive, sensor, power, USB, GNSS, camera, input, storage, wireless, light, haptic, and audible audio tests. Each state-changing test restores its original state. Suspend is not included. Administrator authorization is required.",
            lambda: self.run_command("automated", ["--yes"]),
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
            "The validator briefly switches the AtomISP media route, captures three frames from each camera to /dev/null, and restores the original route. Images are not saved.",
            lambda: self.run_command("camera", ["--yes"]),
        )

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

    def on_inputs(self, _button) -> None:
        self.confirm(
            "Inspect input capabilities?",
            "The validator opens each kernel input node read-only to inspect its capability map. It does not grab devices, monitor events, record keys or touches, or inject input. Administrator authorization is required.",
            lambda: self.run_command("inputs", ["--yes"]),
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

    def on_wireless(self, _button) -> None:
        self.confirm(
            "Test Wi-Fi and Bluetooth?",
            "The validator pings the Wi-Fi gateway, briefly enables Bluetooth discovery without pairing, then restores the original Bluetooth power and rfkill state.",
            lambda: self.run_command("wireless", ["--yes"]),
        )

    def on_usb(self, _button) -> None:
        self.run_command("usb", [])

    def run_command(self, command: str, extra: list[str], output: Path | None = None) -> None:
        output = output or self.report_path(command)
        output.mkdir(parents=True, exist_ok=True)
        argv = [str(CLI), command, *extra, "--output", str(output)]
        self.spinner.set_visible(True)
        self.spinner.start()
        self.set_sensitive(False)

        def worker() -> None:
            try:
                command_timeout = 600 if command == "automated" else 300
                completed = subprocess.run(argv, text=True, capture_output=True, timeout=command_timeout, check=False)
                error = completed.stderr.strip() if completed.returncode not in (0, 1) else ""
            except (OSError, subprocess.TimeoutExpired) as exc:
                error = str(exc)
            GLib.idle_add(self.command_finished, output, error)

        threading.Thread(target=worker, daemon=True).start()

    def command_finished(self, output: Path, error: str) -> bool:
        self.set_sensitive(True)
        self.spinner.stop()
        self.spinner.set_visible(False)
        report = output / "results.tsv"
        if report.exists():
            self.last_report = output
            self.render_report(report)
            self.open_button.set_sensitive(True)
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
        with report.open(newline="", encoding="utf-8") as stream:
            rows = list(csv.DictReader(stream, delimiter="\t"))
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

    def on_physical(self, _button) -> None:
        PhysicalWindow(self).present()

    def show_error(self, heading: str, body: str) -> None:
        dialog = Adw.MessageDialog.new(self, heading, body)
        dialog.add_response("close", "Close")
        dialog.present()


class PhysicalWindow(Adw.Window):
    def __init__(self, parent: ValidatorWindow) -> None:
        super().__init__(transient_for=parent, modal=True, title="Physical acceptance")
        self.parent_window = parent
        self.set_default_size(760, 700)
        self.rows: list[tuple[str, Gtk.DropDown, Gtk.Entry]] = []

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        save = Gtk.Button(label="Save results")
        save.add_css_class("suggested-action")
        save.connect("clicked", self.on_save)
        header.pack_end(save)
        toolbar.add_top_bar(header)
        page = Adw.PreferencesPage()
        page.set_description("Choose Skip for unavailable accessories or conditions, such as LTE without a SIM.")
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
        answers = cache / f"physical-{os.getpid()}.tsv"
        values = ["SKIP", "PASS", "FAIL"]
        with answers.open("w", encoding="utf-8", newline="") as stream:
            for check_id, dropdown, note in self.rows:
                clean_note = note.get_text().replace("\t", " ").replace("\n", " ")
                stream.write(f"{check_id}\t{values[dropdown.get_selected()]}\t{clean_note}\n")
        output = self.parent_window.report_path("physical")
        self.close()
        self.parent_window.run_command("physical", ["--answers", str(answers)], output)


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
