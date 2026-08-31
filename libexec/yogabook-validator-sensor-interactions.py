#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Guided, read-only Yoga Book sensor-response validation."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import signal
import tempfile
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk  # noqa: E402


SCHEMA = "org.yogabook.validator.sensor-interactions/v1"


@dataclass(frozen=True)
class Stage:
    check_id: str
    kind: str
    title: str
    instruction: str


STAGES = (
    Stage(
        "ambient-light-response",
        "als",
        "Ambient-light response",
        "Start with both sensors exposed, shade them, then expose them again. Continue unlocks only after both return near their starting level.",
    ),
    Stage(
        "proximity-response",
        "sx9310",
        "Proximity response",
        "Start with hands away, move one close to the Halo surface, then move it away again.",
    ),
    Stage(
        "hinge-response",
        "hinge",
        "Hinge-angle response",
        "Without switching keyboard/pen mode, move the hinge by at least 15 degrees, then return it to the starting position.",
    ),
)


def read_integer(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def sensor_snapshot(sysroot: Path, kind: str) -> dict[str, tuple[int, ...]]:
    result: dict[str, tuple[int, ...]] = {}
    iio_root = sysroot / "sys/bus/iio/devices"
    for name_path in sorted(iio_root.glob("iio:device*/name")):
        try:
            sensor_name = name_path.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if sensor_name != kind:
            continue
        device = name_path.parent
        attributes = {
            "als": ("in_illuminance_raw", "in_intensity_both_raw"),
            "sx9310": (
                "in_proximity0_raw",
                "in_proximity1_raw",
                "in_proximity2_raw",
                "in_proximity3_comb_raw",
            ),
            "hinge": ("in_angl0_raw", "in_angl1_raw", "in_angl2_raw"),
        }[kind]
        values = tuple(read_integer(device / attribute) for attribute in attributes)
        if all(value is not None for value in values):
            result[device.name] = tuple(int(value) for value in values if value is not None)
    return result


def evaluate_variation(
    kind: str, samples: list[dict[str, tuple[int, ...]]]
) -> tuple[bool, dict[str, object]]:
    expected_devices = {"als": 2, "sx9310": 1, "hinge": 2}[kind]
    common = set.intersection(*(set(sample) for sample in samples)) if samples else set()
    if len(common) != expected_devices:
        return False, {
            "samples": len(samples),
            "devices": len(common),
            "expected_devices": expected_devices,
            "ranges": {},
        }

    ranges: dict[str, list[int]] = {}
    restored: dict[str, bool] = {}
    for device in sorted(common):
        width = len(samples[0][device])
        initial = samples[0][device]
        current = samples[-1][device]
        if kind == "hinge":
            def angular_distance(first: int, second: int) -> int:
                difference = abs(first - second) % 360
                return min(difference, 360 - difference)

            ranges[device] = [
                max(angular_distance(initial[index], sample[device][index]) for sample in samples)
                for index in range(width)
            ]
            restored[device] = all(
                angular_distance(initial[index], current[index]) <= 8
                for index in range(width)
            )
        else:
            ranges[device] = [
                max(sample[device][index] for sample in samples)
                - min(sample[device][index] for sample in samples)
                for index in range(width)
            ]
            tolerances = (
                [max(20, abs(value) // 20) for value in initial]
                if kind == "als"
                else [1] * width
            )
            restored[device] = all(
                abs(current[index] - initial[index]) <= tolerances[index]
                for index in range(width)
            )

    if kind == "als":
        response_detected = all(
            max(device_ranges) >= 50
            for device_ranges in ranges.values()
        )
    elif kind == "sx9310":
        response_detected = any(
            delta >= 1 for device_ranges in ranges.values() for delta in device_ranges
        )
    else:
        response_detected = all(max(device_ranges) >= 15 for device_ranges in ranges.values())
    returned_to_baseline = all(restored.values())
    passed = response_detected and returned_to_baseline
    return passed, {
        "samples": len(samples),
        "devices": len(common),
        "expected_devices": expected_devices,
        "ranges": ranges,
        "response_detected": response_detected,
        "returned_to_baseline": returned_to_baseline,
    }


def atomic_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


class SensorWindow(Adw.ApplicationWindow):
    def __init__(
        self, application: Gtk.Application, output: Path, timeout: int, sysroot: Path
    ) -> None:
        super().__init__(application=application, title="Yoga Book sensor responses")
        self.output = output
        self.deadline = time.monotonic() + timeout
        self.sysroot = sysroot
        self.stage_index = 0
        self.samples: list[dict[str, tuple[int, ...]]] = []
        self.results: list[dict[str, object]] = []
        self.current_details: dict[str, object] = {}
        self.finished = False
        self.pointer_position: tuple[float, float] | None = None

        self.set_default_size(760, 480)
        self.fullscreen()
        overlay = Gtk.Overlay()
        overlay.set_cursor_from_name("crosshair")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20)
        box.set_halign(Gtk.Align.CENTER)
        box.set_valign(Gtk.Align.CENTER)
        box.set_margin_start(48)
        box.set_margin_end(48)
        self.title_label = Gtk.Label()
        self.title_label.add_css_class("title-1")
        self.instruction_label = Gtk.Label()
        self.instruction_label.set_wrap(True)
        self.instruction_label.set_justify(Gtk.Justification.CENTER)
        self.instruction_label.set_max_width_chars(72)
        self.status_label = Gtk.Label()
        self.status_label.add_css_class("dim-label")
        self.progress = Gtk.ProgressBar()
        self.progress.set_size_request(520, -1)
        self.continue_button = Gtk.Button(label="Continue")
        self.continue_button.add_css_class("suggested-action")
        self.continue_button.set_sensitive(False)
        self.continue_button.connect("clicked", self.on_continue)
        cancel_button = Gtk.Button(label="Cancel")
        cancel_button.connect("clicked", lambda _button: self.finish("CANCELLED"))
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        buttons.set_halign(Gtk.Align.CENTER)
        buttons.append(cancel_button)
        buttons.append(self.continue_button)
        for widget in (
            self.title_label,
            self.instruction_label,
            self.status_label,
            self.progress,
            buttons,
        ):
            box.append(widget)
        overlay.set_child(box)
        self.pointer_overlay = Gtk.DrawingArea()
        self.pointer_overlay.set_hexpand(True)
        self.pointer_overlay.set_vexpand(True)
        self.pointer_overlay.set_can_target(False)
        self.pointer_overlay.set_draw_func(self.draw_pointer)
        overlay.add_overlay(self.pointer_overlay)
        self.set_content(overlay)

        motion = Gtk.EventControllerMotion.new()
        motion.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        motion.connect("motion", self.on_pointer_motion)
        overlay.add_controller(motion)
        stylus = Gtk.GestureStylus.new()
        stylus.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        stylus.connect("proximity", self.on_pointer_motion)
        stylus.connect("motion", self.on_pointer_motion)
        stylus.connect("down", self.on_pointer_motion)
        stylus.connect("up", self.on_pointer_motion)
        overlay.add_controller(stylus)
        self.connect("close-request", self.on_close_request)
        self.update_stage()
        GLib.timeout_add(100, self.poll)

    def on_pointer_motion(
        self, _controller: Gtk.EventController, x: float, y: float
    ) -> None:
        self.pointer_position = (x, y)
        self.pointer_overlay.queue_draw()

    def draw_pointer(
        self, _area: Gtk.DrawingArea, context, _width: int, _height: int
    ) -> None:
        if self.pointer_position is None:
            return
        x, y = self.pointer_position
        context.set_line_width(3.0)
        context.set_source_rgb(1.0, 0.82, 0.18)
        context.arc(x, y, 12.0, 0, 2 * math.pi)
        context.stroke()
        context.move_to(x - 18.0, y)
        context.line_to(x + 18.0, y)
        context.move_to(x, y - 18.0)
        context.line_to(x, y + 18.0)
        context.stroke()

    @property
    def stage(self) -> Stage:
        return STAGES[self.stage_index]

    def update_stage(self) -> None:
        self.title_label.set_text(self.stage.title)
        self.instruction_label.set_text(self.stage.instruction)
        self.status_label.set_text("Waiting for a measurable response…")
        self.progress.set_fraction(self.stage_index / len(STAGES))
        self.continue_button.set_label(
            "Finish" if self.stage_index + 1 == len(STAGES) else "Continue"
        )
        self.continue_button.set_sensitive(False)

    def poll(self) -> bool:
        if self.finished:
            return GLib.SOURCE_REMOVE
        if time.monotonic() >= self.deadline:
            self.finish("TIMEOUT")
            return GLib.SOURCE_REMOVE
        self.samples.append(sensor_snapshot(self.sysroot, self.stage.kind))
        passed, details = evaluate_variation(self.stage.kind, self.samples)
        self.current_details = details
        remaining = max(0, int(self.deadline - time.monotonic()))
        if passed:
            self.status_label.set_text(
                f"Response measured from every required device · {remaining}s remaining"
            )
            self.continue_button.set_sensitive(True)
        elif details.get("response_detected"):
            self.status_label.set_text(
                f"Response measured; return to the starting state · {remaining}s remaining"
            )
        else:
            self.status_label.set_text(
                f"Sampling {details['devices']}/{details['expected_devices']} devices · "
                f"{remaining}s remaining"
            )
        return GLib.SOURCE_CONTINUE

    def on_continue(self, _button: Gtk.Button) -> None:
        passed, details = evaluate_variation(self.stage.kind, self.samples)
        if not passed:
            return
        self.results.append(
            {"check_id": self.stage.check_id, "status": "PASS", "details": details}
        )
        print(f"SENSOR_RESPONSE_PASS: {self.stage.check_id}", flush=True)
        if self.stage_index + 1 == len(STAGES):
            self.finish("PASS")
            return
        self.stage_index += 1
        self.samples = []
        self.current_details = {}
        self.update_stage()

    def finish(self, result: str) -> None:
        if self.finished:
            return
        self.finished = True
        completed = {item["check_id"] for item in self.results}
        for stage in STAGES:
            if stage.check_id not in completed:
                details = self.current_details if stage is self.stage else {}
                self.results.append(
                    {"check_id": stage.check_id, "status": "FAIL", "details": details}
                )
        ordered = sorted(
            self.results,
            key=lambda item: [stage.check_id for stage in STAGES].index(str(item["check_id"])),
        )
        atomic_json(
            self.output,
            {
                "schema": SCHEMA,
                "result": result,
                "privacy": "Only sample counts and per-channel ranges are retained; raw samples are discarded.",
                "stages": ordered,
            },
        )
        self.get_application().quit()

    def on_close_request(self, _window: Gtk.Window) -> bool:
        self.finish("CANCELLED")
        return True


def self_test() -> None:
    als = [
        {"a": (1000, 1000), "b": (2000, 2000)},
        {"a": (1100, 1100), "b": (2060, 2060)},
        {"a": (1005, 1005), "b": (2005, 2005)},
    ]
    assert evaluate_variation("als", als)[0]
    assert not evaluate_variation("als", als[:2])[0]
    proximity = [
        {"p": (0, 0, 0, 0)},
        {"p": (0, 2, 0, 0)},
        {"p": (0, 0, 0, 0)},
    ]
    assert evaluate_variation("sx9310", proximity)[0]
    hinge = [
        {"h1": (359, 90, 0), "h2": (359, 90, 0)},
        {"h1": (20, 110, 0), "h2": (18, 108, 0)},
        {"h1": (1, 92, 0), "h2": (0, 91, 0)},
    ]
    assert evaluate_variation("hinge", hinge)[0]
    print("sensor interaction policy: PASS")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.output is None or args.timeout < 1:
        parser.error("--output and a positive --timeout are required")
    application = Adw.Application(application_id="org.yogabook.Validator.SensorInteractions")
    window: SensorWindow | None = None

    def activate(app: Gtk.Application) -> None:
        nonlocal window
        if window is None:
            window = SensorWindow(
                app,
                args.output,
                args.timeout,
                Path(os.environ.get("YBV_SYSROOT", "/")),
            )
        window.present()

    def stop(_signum: int, _frame: object) -> None:
        if window is not None:
            GLib.idle_add(window.finish, "CANCELLED")
        else:
            application.quit()

    application.connect("activate", activate)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    return application.run([])


if __name__ == "__main__":
    raise SystemExit(main())
