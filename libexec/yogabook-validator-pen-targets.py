#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later

"""Guided post-Mutter stylus target validation for the Yoga Book display."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import math
import os
from pathlib import Path
import signal
import tempfile
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402


DBUS_FLAGS = Gio.DBusCallFlags.NONE
ORIENTATIONS = (
    ("landscape-start", "right-up", "0", "upright landscape"),
    ("portrait-right", "normal", "1", "right portrait"),
    ("landscape-inverted", "bottom-up", "3", "upside-down landscape"),
    ("portrait-left", "left-up", "2", "left portrait"),
    ("landscape-return", "right-up", "0", "returned upright landscape"),
)
TARGETS = ((0.14, 0.18), (0.86, 0.18), (0.86, 0.82), (0.14, 0.82))
ALLOWED_STYLUS_TOOLS = {
    Gdk.DeviceToolType.PEN,
    Gdk.DeviceToolType.PENCIL,
    Gdk.DeviceToolType.BRUSH,
    Gdk.DeviceToolType.AIRBRUSH,
    Gdk.DeviceToolType.UNKNOWN,
}


@dataclass
class StageResult:
    check_id: str
    sensor_orientation: str
    transform: str
    label: str
    observed_sensor_orientation: str = "unavailable"
    observed_transform: str = "unknown"
    status: str = "PENDING"
    hits: int = 0
    misses: int = 0


def atomic_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def is_tip_contact(has_pressure: bool, pressure: float, modifiers: Gdk.ModifierType) -> bool:
    return (has_pressure and pressure > 0.01) or bool(
        modifiers & Gdk.ModifierType.BUTTON1_MASK
    )


def stylus_identity_values(
    name: str,
    source: Gdk.InputSource,
    tool_type: Gdk.DeviceToolType | None,
    *,
    dedicated_stylus: bool = False,
) -> tuple[str, str, str, str] | None:
    """Return a privacy-safe identity only for a Wacom pen-tip event."""
    normalized = name.casefold()
    if dedicated_stylus:
        # GtkGestureStylus is already a stylus-only controller. On Wayland,
        # get_current_event_device() may expose a generic logical pointer when
        # the tip enters proximity, while optional device-tool metadata may be
        # absent. Reject only an explicitly non-stylus tool here.
        if tool_type is not None and tool_type not in ALLOWED_STYLUS_TOOLS:
            return None
    else:
        # EventControllerMotion is only a pressure fallback and therefore must
        # retain the stricter physical Wacom PEN-source identity.
        if "wacom" not in normalized or source != Gdk.InputSource.PEN:
            return None
        if tool_type is not None and tool_type not in ALLOWED_STYLUS_TOOLS:
            return None
    return (
        name,
        source.value_nick,
        tool_type.value_nick if tool_type is not None else "unknown",
        "gtk-stylus" if dedicated_stylus else "pen-source",
    )


def property_value(
    bus: Gio.DBusConnection,
    destination: str,
    path: str,
    interface: str,
    name: str,
) -> object:
    reply = bus.call_sync(
        destination,
        path,
        "org.freedesktop.DBus.Properties",
        "Get",
        GLib.Variant("(ss)", (interface, name)),
        GLib.VariantType("(v)"),
        DBUS_FLAGS,
        500,
        None,
    )
    return reply.unpack()[0]


def sensor_orientation(bus: Gio.DBusConnection) -> str:
    try:
        return str(
            property_value(
                bus,
                "net.hadess.SensorProxy",
                "/net/hadess/SensorProxy",
                "net.hadess.SensorProxy",
                "AccelerometerOrientation",
            )
        )
    except GLib.Error:
        return "unavailable"


def mutter_display_state(bus: Gio.DBusConnection) -> tuple[str, str, str]:
    try:
        reply = bus.call_sync(
            "org.gnome.Mutter.DisplayConfig",
            "/org/gnome/Mutter/DisplayConfig",
            "org.gnome.Mutter.DisplayConfig",
            "GetCurrentState",
            None,
            None,
            DBUS_FLAGS,
            500,
            None,
        )
        _serial, monitors, logical_monitors, _properties = reply.unpack()
        current_modes = {
            spec[0]: next(
                (mode[0] for mode in modes if mode[6].get("is-current", False)),
                "unknown",
            )
            for spec, modes, _monitor_properties in monitors
        }
        for _x, _y, _scale, transform, _primary, specs, _props in logical_monitors:
            for spec in specs:
                if spec[0].startswith("DSI-"):
                    return spec[0], current_modes.get(spec[0], "unknown"), str(transform)
    except GLib.Error:
        pass
    return "unavailable", "unknown", "unknown"


class PenTargetsWindow(Gtk.ApplicationWindow):
    def __init__(
        self,
        application: Gtk.Application,
        output: Path,
        timeout: int,
    ) -> None:
        super().__init__(application=application, title="Yoga Book pen mapping")
        self.output = output
        self.deadline = time.monotonic() + timeout
        self.stages = [StageResult(*stage) for stage in ORIENTATIONS]
        self.stage_index = 0
        self.target_index = 0
        self.stable_since: float | None = None
        self.last_sensor = "unavailable"
        self.last_transform = "unknown"
        self.stylus_device = ""
        self.stylus_source = ""
        self.stylus_tool = ""
        self.stylus_event_path = ""
        self.stylus_verifier = ""
        self.accepted_event_paths: set[str] = set()
        self.accepted_verifiers: set[str] = set()
        self.accepted_contacts: list[dict[str, str]] = []
        self.rejected_events = 0
        self.logged_identity = ""
        self.pen_position: tuple[float, float] | None = None
        self.pen_seen_at = 0.0
        self.last_press_at = 0.0
        self.feedback_until = 0.0
        self.feedback_text = ""
        self.pointer_contact_active = False
        self.stylus_contact_active = False
        self.orientation_mismatches = 0
        self.finished = False
        self.system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.session_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

        self.set_decorated(False)
        self.fullscreen()

        overlay = Gtk.Overlay()
        self.canvas = Gtk.DrawingArea()
        self.canvas.set_hexpand(True)
        self.canvas.set_vexpand(True)
        self.canvas.set_cursor_from_name("crosshair")
        self.canvas.set_draw_func(self.draw)
        overlay.set_child(self.canvas)

        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        panel.set_halign(Gtk.Align.CENTER)
        panel.set_valign(Gtk.Align.START)
        panel.set_margin_top(32)
        panel.add_css_class("card")
        panel.set_size_request(540, -1)
        self.title_label = Gtk.Label()
        self.title_label.add_css_class("title-2")
        self.instruction_label = Gtk.Label()
        self.instruction_label.set_wrap(True)
        self.instruction_label.set_justify(Gtk.Justification.CENTER)
        self.progress_label = Gtk.Label()
        self.progress_label.add_css_class("dim-label")
        for label in (self.title_label, self.instruction_label, self.progress_label):
            label.set_margin_start(18)
            label.set_margin_end(18)
            panel.append(label)
        panel.set_margin_bottom(16)
        overlay.add_overlay(panel)
        self.set_child(overlay)

        motion = Gtk.EventControllerMotion.new()
        motion.connect("motion", self.on_pointer_motion)
        motion.connect("leave", self.on_pointer_leave)
        self.canvas.add_controller(motion)
        self.motion = motion

        stylus = Gtk.GestureStylus.new()
        stylus.connect("proximity", self.on_stylus_proximity)
        stylus.connect("motion", self.on_stylus_motion)
        stylus.connect("down", self.on_stylus_down)
        stylus.connect("up", self.on_stylus_up)
        self.canvas.add_controller(stylus)
        self.stylus = stylus

        self.connect("close-request", self.on_close_request)
        GLib.timeout_add(250, self.poll_state)
        self.update_labels()

    @property
    def stage(self) -> StageResult:
        return self.stages[self.stage_index]

    def update_labels(self) -> None:
        stage = self.stage
        self.title_label.set_text(f"Pen mapping: {stage.label}")
        ready = (
            self.stable_since is not None
            and time.monotonic() - self.stable_since >= 1.0
        )
        if time.monotonic() < self.feedback_until:
            self.instruction_label.set_text(self.feedback_text)
        elif ready:
            if self.pen_seen_at == 0.0:
                self.instruction_label.set_text(
                    "No Wacom stylus event detected yet. Hover the pen over the blue target, then press the tip."
                )
            elif self.last_press_at == 0.0:
                self.instruction_label.set_text(
                    "Pen hover detected. Press the tip inside the blue target; the yellow crosshair stays visible."
                )
            else:
                self.instruction_label.set_text(
                    "Touch the highlighted target with the pen. Finger and mouse input are ignored."
                )
        else:
            self.instruction_label.set_text(
                f"Rotate slowly to {stage.label} and hold it steady. "
                "The target appears only after SensorProxy and Mutter agree."
            )
        remaining = max(0, math.ceil(self.deadline - time.monotonic()))
        self.progress_label.set_text(
            f"Orientation {self.stage_index + 1}/{len(self.stages)}  ·  "
            f"Target {self.target_index + 1}/{len(TARGETS)}  ·  {remaining}s remaining"
        )
        self.canvas.queue_draw()

    def stage_ready(self) -> bool:
        return self.stable_since is not None and time.monotonic() - self.stable_since >= 1.0

    def poll_state(self) -> bool:
        if self.finished:
            return GLib.SOURCE_REMOVE
        if time.monotonic() >= self.deadline:
            self.finish("TIMEOUT")
            return GLib.SOURCE_REMOVE

        stage = self.stage
        sensor = sensor_orientation(self.system_bus)
        connector, mode, transform = mutter_display_state(self.session_bus)
        stage.observed_sensor_orientation = sensor
        stage.observed_transform = transform
        matching = (
            sensor == stage.sensor_orientation
            and connector == "DSI-1"
            and mode.startswith("1920x1200@")
            and transform == stage.transform
        )
        if matching:
            self.orientation_mismatches = 0
            if self.stable_since is None:
                self.stable_since = time.monotonic()
        else:
            self.orientation_mismatches += 1
            if self.orientation_mismatches >= 3:
                self.stable_since = None
        self.last_sensor = sensor
        self.last_transform = transform
        self.update_labels()
        return GLib.SOURCE_CONTINUE

    def target_position(self, width: int, height: int) -> tuple[float, float, float]:
        relative_x, relative_y = TARGETS[self.target_index]
        radius = max(34.0, min(width, height) * 0.065)
        return width * relative_x, height * relative_y, radius

    def draw(self, _area: Gtk.DrawingArea, context, width: int, height: int) -> None:
        context.set_source_rgb(0.055, 0.067, 0.086)
        context.paint()
        if self.stage_ready():
            x, y, radius = self.target_position(width, height)
            context.set_line_width(max(5.0, radius * 0.14))
            context.set_source_rgb(0.20, 0.72, 1.0)
            context.arc(x, y, radius, 0, 2 * math.pi)
            context.stroke()
            context.set_source_rgba(0.20, 0.72, 1.0, 0.28)
            context.arc(x, y, radius * 0.55, 0, 2 * math.pi)
            context.fill()

        # Keep the application-drawn cursor visible even while orientation
        # readiness is temporarily unavailable.
        if self.pen_position is not None:
            pen_x, pen_y = self.pen_position
            context.set_line_width(3.0)
            context.set_source_rgb(1.0, 0.82, 0.18)
            context.arc(pen_x, pen_y, 15.0, 0, 2 * math.pi)
            context.stroke()
            context.move_to(pen_x - 22.0, pen_y)
            context.line_to(pen_x + 22.0, pen_y)
            context.move_to(pen_x, pen_y - 22.0)
            context.line_to(pen_x, pen_y + 22.0)
            context.stroke()

    def stylus_identity(
        self, controller: Gtk.EventController, *, dedicated_stylus: bool = False
    ) -> tuple[str, str, str, str] | None:
        device = controller.get_current_event_device()
        if device is None:
            self.rejected_events += 1
            return None
        name = device.get_name() or ""
        event = controller.get_current_event()
        tool = event.get_device_tool() if event is not None else None
        identity = stylus_identity_values(
            name,
            device.get_source(),
            tool.get_tool_type() if tool is not None else None,
            dedicated_stylus=dedicated_stylus,
        )
        if identity is None:
            self.rejected_events += 1
            return None
        diagnostic = "/".join(identity)
        if diagnostic != self.logged_identity:
            self.logged_identity = diagnostic
            print(
                f"PEN_INPUT_IDENTIFIED: device={identity[0]} "
                f"source={identity[1]} tool={identity[2]} verified-by={identity[3]}",
                flush=True,
            )
        return identity

    def update_pen_position(
        self,
        x: float,
        y: float,
        identity: tuple[str, str, str, str],
    ) -> None:
        self.stylus_device, self.stylus_source, self.stylus_tool = identity[:3]
        self.stylus_verifier = identity[3]
        self.pen_position = (x, y)
        self.pen_seen_at = time.monotonic()
        self.canvas.queue_draw()

    def on_pointer_motion(
        self,
        controller: Gtk.EventControllerMotion,
        x: float,
        y: float,
    ) -> None:
        identity = self.stylus_identity(controller)
        if identity is None:
            return
        self.update_pen_position(x, y, identity)
        if not self.stage_ready():
            self.pointer_contact_active = False
            return
        event = controller.get_current_event()
        if event is None:
            self.pointer_contact_active = False
            return
        has_pressure, pressure = event.get_axis(Gdk.AxisUse.PRESSURE)
        modifiers = event.get_modifier_state()
        contact = is_tip_contact(has_pressure, pressure, modifiers)
        if contact and not self.pointer_contact_active:
            self.stylus_event_path = "pressure-fallback"
            self.accept_target(x, y, identity, "pressure-fallback")
        self.pointer_contact_active = contact

    def on_pointer_leave(self, _controller: Gtk.EventControllerMotion) -> None:
        # Mutter may emit leave immediately after a stylus tip press. Keep the
        # last transient crosshair visible until the next Wacom motion or stage.
        pass

    def on_stylus_proximity(
        self,
        gesture: Gtk.GestureStylus,
        x: float,
        y: float,
    ) -> None:
        identity = self.stylus_identity(gesture, dedicated_stylus=True)
        if identity is None:
            return
        self.update_pen_position(x, y, identity)

    def on_stylus_motion(
        self,
        gesture: Gtk.GestureStylus,
        x: float,
        y: float,
    ) -> None:
        identity = self.stylus_identity(gesture, dedicated_stylus=True)
        if identity is None:
            return
        self.update_pen_position(x, y, identity)
        has_pressure, pressure = gesture.get_axis(Gdk.AxisUse.PRESSURE)
        if self.stage_ready() and has_pressure and pressure > 0.01 and not self.stylus_contact_active:
            self.accept_target(x, y, identity, "stylus-pressure")
        self.stylus_contact_active = has_pressure and pressure > 0.01

    def on_stylus_down(
        self,
        gesture: Gtk.GestureStylus,
        x: float,
        y: float,
    ) -> None:
        identity = self.stylus_identity(gesture, dedicated_stylus=True)
        if identity is None:
            return
        self.update_pen_position(x, y, identity)
        self.stylus_contact_active = True
        if not self.stage_ready():
            self.feedback_text = "Pen contact detected, but the orientation is not stable yet. Hold the tablet steady and touch again."
            self.feedback_until = time.monotonic() + 1.5
            print("PEN_CONTACT_IGNORED: reason=orientation-not-stable", flush=True)
            self.update_labels()
            return
        self.accept_target(x, y, identity, "stylus-down")

    def on_stylus_up(
        self,
        gesture: Gtk.GestureStylus,
        x: float,
        y: float,
    ) -> None:
        identity = self.stylus_identity(gesture, dedicated_stylus=True)
        if identity is not None:
            self.update_pen_position(x, y, identity)
        self.stylus_contact_active = False

    def accept_target(
        self,
        x: float,
        y: float,
        identity: tuple[str, str, str, str],
        event_path: str,
    ) -> None:
        now = time.monotonic()
        if now - self.last_press_at < 0.15:
            return
        self.last_press_at = now
        self.update_pen_position(x, y, identity)
        width, height = self.canvas.get_width(), self.canvas.get_height()
        target_x, target_y, radius = self.target_position(width, height)
        if math.hypot(x - target_x, y - target_y) > radius:
            self.stage.misses += 1
            self.feedback_text = "Target missed. Keep the yellow crosshair inside the blue circle and touch again."
            self.feedback_until = now + 1.5
            print(
                f"PEN_TARGET_MISS: stage={self.stage.check_id} "
                f"hits={self.stage.hits} misses={self.stage.misses}",
                flush=True,
            )
            self.update_labels()
            return
        self.stage.hits += 1
        self.stylus_event_path = event_path
        self.accepted_event_paths.add(event_path)
        self.accepted_verifiers.add(identity[3])
        self.accepted_contacts.append(
            {
                "stage": self.stage.check_id,
                "device": identity[0],
                "source": identity[1],
                "tool": identity[2],
                "event_path": event_path,
                "verifier": identity[3],
            }
        )
        self.target_index += 1
        self.feedback_text = "Target accepted. Move the pen to the next highlighted circle."
        print(
            f"PEN_TARGET_HIT: stage={self.stage.check_id} "
            f"hits={self.stage.hits} misses={self.stage.misses}",
            flush=True,
        )
        self.feedback_until = now + 1.2
        if self.target_index < len(TARGETS):
            self.update_labels()
            return

        self.stage.status = "PASS"
        self.target_index = 0
        self.stable_since = None
        if self.stage_index + 1 == len(self.stages):
            self.finish("PASS")
            return
        self.stage_index += 1
        # Preserve the last crosshair across the orientation transition. GTK
        # may not emit another proximity event until the pen moves, and hiding
        # it here made a successful target look like lost pen input.
        self.pointer_contact_active = False
        self.stylus_contact_active = False
        self.update_labels()

    def payload(self, result: str) -> dict[str, object]:
        return {
            "schema": "org.yogabook.validator.pen-mapping/v1",
            "result": result,
            "stylus_device": self.stylus_device,
            "stylus_source": self.stylus_source,
            "stylus_tool": self.stylus_tool,
            "stylus_event_path": self.stylus_event_path,
            "stylus_verifier": self.stylus_verifier,
            "accepted_event_paths": sorted(self.accepted_event_paths),
            "accepted_verifiers": sorted(self.accepted_verifiers),
            "accepted_contacts": self.accepted_contacts,
            "rejected_events": self.rejected_events,
            "privacy": "Target counts and per-contact technical provenance are retained; raw pen coordinates are discarded.",
            "stages": [asdict(stage) for stage in self.stages],
        }

    def finish(self, result: str) -> None:
        if self.finished:
            return
        self.finished = True
        if result != "PASS" and self.stages[self.stage_index].status == "PENDING":
            self.stages[self.stage_index].status = "FAIL"
        atomic_json(self.output, self.payload(result))
        self.get_application().quit()

    def on_close_request(self, _window: Gtk.Window) -> bool:
        self.finish("CANCELLED")
        return True


class PenTargetsApplication(Gtk.Application):
    def __init__(self, output: Path, timeout: int) -> None:
        super().__init__(application_id="org.yogabook.Validator.PenTargets")
        self.output = output
        self.timeout = timeout
        self.window: PenTargetsWindow | None = None

    def do_activate(self) -> None:
        if self.window is None:
            self.window = PenTargetsWindow(self, self.output, self.timeout)
        self.window.present()


def self_test() -> int:
    assert [stage[0] for stage in ORIENTATIONS] == [
        "landscape-start",
        "portrait-right",
        "landscape-inverted",
        "portrait-left",
        "landscape-return",
    ]
    assert ORIENTATIONS[0][1:3] == ORIENTATIONS[-1][1:3] == ("right-up", "0")
    assert len(set((stage[1], stage[2]) for stage in ORIENTATIONS[:-1])) == 4
    assert all(0.0 < x < 1.0 and 0.0 < y < 1.0 for x, y in TARGETS)
    assert not is_tip_contact(True, 0.0, Gdk.ModifierType(0))
    assert is_tip_contact(True, 0.5, Gdk.ModifierType(0))
    assert is_tip_contact(False, 0.0, Gdk.ModifierType.BUTTON1_MASK)
    assert stylus_identity_values(
        "Wacom HID 169 Pen stylus", Gdk.InputSource.PEN, Gdk.DeviceToolType.PEN
    ) == ("Wacom HID 169 Pen stylus", "pen", "pen", "pen-source")
    assert stylus_identity_values(
        "wacom hid pen", Gdk.InputSource.PEN, None
    ) == ("wacom hid pen", "pen", "unknown", "pen-source")
    assert stylus_identity_values(
        "Wacom HID 169 Pen stylus", Gdk.InputSource.MOUSE, Gdk.DeviceToolType.PEN
    ) is None
    assert stylus_identity_values(
        "Wayland logical pointer",
        Gdk.InputSource.MOUSE,
        Gdk.DeviceToolType.PEN,
        dedicated_stylus=True,
    ) == (
        "Wayland logical pointer",
        "mouse",
        "pen",
        "gtk-stylus",
    )
    assert stylus_identity_values(
        "Wayland logical pointer",
        Gdk.InputSource.MOUSE,
        None,
        dedicated_stylus=True,
    ) == (
        "Wayland logical pointer",
        "mouse",
        "unknown",
        "gtk-stylus",
    )
    assert stylus_identity_values(
        "Wayland logical pointer", Gdk.InputSource.PEN, Gdk.DeviceToolType.PEN
    ) is None
    assert stylus_identity_values(
        "Wacom HID 169 Pen stylus", Gdk.InputSource.PEN, Gdk.DeviceToolType.ERASER
    ) is None
    assert stylus_identity_values(
        "Wacom HID 169 Pen stylus",
        Gdk.InputSource.MOUSE,
        Gdk.DeviceToolType.ERASER,
        dedicated_stylus=True,
    ) is None
    print("pen target plan: PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.output is None:
        parser.error("--output is required")
    if args.timeout < 30:
        parser.error("--timeout must be at least 30 seconds")

    application = PenTargetsApplication(args.output, args.timeout)

    def stop(_signum: int, _frame: object) -> None:
        if application.window is not None:
            GLib.idle_add(application.window.finish, "CANCELLED")
        else:
            application.quit()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    return application.run([])


if __name__ == "__main__":
    raise SystemExit(main())
