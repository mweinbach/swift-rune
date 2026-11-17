#!/usr/bin/env python3
"""Run with /usr/bin/python3 Demand.py /path/to/rune-sparse-atk-probe.

Requires python3-gi, python3-xlib, at-spi2-core, xdotool, dbus-run-session, Xvfb, xauth,
pkg-config, a C compiler and the ATK development headers.
The outer process starts a private X11 display, D-Bus session, and settings directory.
"""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

from gi.repository import Gio, GLib
from Xlib import X, display

ACCESSIBLE = "org.a11y.atspi.Accessible"
PROPERTIES = "org.freedesktop.DBus.Properties"
BUS = ("org.a11y.Bus", "/org/a11y/bus")
REGISTRY = ("org.a11y.atspi.Registry", "/org/a11y/atspi/accessible/root")
DAEMON = ("org.freedesktop.DBus", "/org/freedesktop/DBus")
TITLE = "Rune sparse ATK probe"
ROW = (8, 132, 104, 32)
SCROLLED_ROW = (8, 102, 104, 32)


def call(connection, target, interface, method, signature=None, values=()):
    args = GLib.Variant(signature, values) if signature else None
    return connection.call_sync(*target, interface, method, args, None, Gio.DBusCallFlags.NONE, 3000, None).unpack()


def wait_for(query, message):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        while GLib.MainContext.default().iteration(False):
            pass
        if result := query():
            return result
        time.sleep(0.02)
    raise AssertionError(message)


class Desktop:
    def __init__(self):
        self.session = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def enabled(self):
        return call(self.session, BUS, PROPERTIES, "Get", "(ss)", ("org.a11y.Status", "IsEnabled"))[0]

    def set_enabled(self, enabled):
        call(self.session, BUS, PROPERTIES, "Set", "(ssv)",
             ("org.a11y.Status", "IsEnabled", GLib.Variant("b", enabled)))
        assert self.enabled() == enabled

    @contextmanager
    def connection(self):
        address, = call(self.session, BUS, "org.a11y.Bus", "GetAddress")
        flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
        connection = Gio.DBusConnection.new_for_address_sync(address, flags, None, None)
        try:
            yield connection
        finally:
            connection.close_sync(None)


class Tree:
    def __init__(self, connection):
        self.connection = connection

    def children(self, node):
        return call(self.connection, node, ACCESSIBLE, "GetChildren")[0]

    def root(self, pid):
        def from_process():
            for app in self.children(REGISTRY):
                owner, = call(self.connection, DAEMON, DAEMON[0], "GetConnectionUnixProcessID", "(s)", (app[0],))
                if owner == pid:
                    return app
            return None
        return wait_for(from_process, "AT-SPI registry did not expose the launched process")

    def name(self, node):
        return call(self.connection, node, PROPERTIES, "Get", "(ss)", (ACCESSIBLE, "Name"))[0]

    def named(self, node, name):
        if self.name(node) == name:
            return node
        for child in self.children(node):
            if found := self.named(child, name):
                return found
        return None

    def box(self, node):
        # AT-SPI CoordType.WINDOW is 1.
        return call(self.connection, node, "org.a11y.atspi.Component", "GetExtents", "(u)", (1,))[0]


@contextmanager
def launched(binary, env=None):
    with subprocess.Popen([binary], env=env) as app:
        try:
            def window():
                if app.poll() is not None:
                    raise RuntimeError(f"Rune exited with status {app.returncode}")
                result = subprocess.run(["xdotool", "search", "--onlyvisible", "--all", "--pid", str(app.pid),
                                         "--name", f"^{TITLE}$"],
                                        capture_output=True, text=True)
                return next(iter(result.stdout.splitlines()), None)
            window_id = wait_for(window, "Rune did not show its window")
            subprocess.run(["xdotool", "windowfocus", "--sync", window_id], check=True)
            yield app.pid, window_id
        finally:
            app.terminate()
            try:
                app.wait(timeout=3)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()


def click(window, x, expected_title):
    # SDL publishes the new WM_NAME directly. Xvfb runs without a window manager.
    connection = display.Display()
    try:
        resource = connection.create_resource_object("window", int(window))
        prop = connection.intern_atom("WM_NAME")
        title = f"{TITLE} — {expected_title}".encode()
        def press():
            subprocess.run(["xdotool", "mousemove", "--window", window, str(x), "23", "mousedown", "1",
                            "sleep", "0.08", "mouseup", "1"], check=True)
        press()
        last_press = time.monotonic()
        def applied():
            nonlocal last_press
            if resource.get_full_property(prop, X.AnyPropertyType).value == title:
                return True
            # The first click can focus a just-mapped window while SDL starts up.
            # Rename is idempotent. Each scroll toggles, so it is dispatched once.
            if expected_title == "renamed" and time.monotonic() - last_press >= 0.5:
                press()
                last_press = time.monotonic()
            return False
        wait_for(applied, f"Rune did not apply {expected_title!r}")
    finally:
        connection.close()


def check_late_reader(binary, desktop):
    desktop.set_enabled(False)
    with launched(binary) as (pid, window):
        click(window, 40, "renamed")
        click(window, 360, "scroll 30")
        assert not desktop.enabled()
        # Raw D-Bus avoids the automatic settings changes made by some AT-SPI clients.
        with desktop.connection() as conn:
            tree = Tree(conn)
            root = tree.root(pid)
            frame, = tree.children(root)
            assert tree.children(frame), "late reader's first GetChildren returned an empty frame"
            items = tree.named(frame, "Items")
            assert items, "late reader did not receive current children"
            assert [tree.name(node) for node in tree.children(items)] == ["C", "A edited", "B"]
            row = tree.named(root, "Scroll item")
            assert row and tree.box(row) == SCROLLED_ROW, (row, tree.box(row) if row else None)
            assert not desktop.enabled()
            # An active direct reader keeps its objects across setting-only transitions.
            desktop.set_enabled(True)
            click(window, 360, "scroll 0")
            wait_for(lambda: tree.box(row) == ROW, "retained accessible did not return to its original bounds")
            assert tree.named(root, "Scroll item") == row
            desktop.set_enabled(False)
            click(window, 360, "scroll 30")
            wait_for(lambda: tree.box(row) == SCROLLED_ROW, "retained accessible did not follow scrolling")
            assert tree.named(root, "Scroll item") == row
            print(f"PASS late raw reader with IsEnabled=false saw A edited and held {row} at {SCROLLED_ROW}, "
                  f"{ROW}, {SCROLLED_ROW}", flush=True)


def check_setting(binary, desktop):
    # ATK sends cache messages only to clients. Observe local parent changes without
    # opening an AT-SPI connection, so setting IsEnabled is the only source of demand.
    with tempfile.TemporaryDirectory(prefix="rune-atk-parents-") as work:
        observer = Path(work) / "ObserveParents.so"
        log = Path(work) / "parents.log"
        log.touch()
        compiler = shlex.split(os.environ.get("CC", "")) or [shutil.which("cc") or "clang"]
        flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "atk"], text=True))
        subprocess.run([*compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                        Path(__file__).with_name("ObserveParents.c"), "-o", observer, *flags, "-ldl"], check=True)
        preload = str(observer)
        if inherited := os.environ.get("LD_PRELOAD"):
            preload += ":" + inherited
        env = dict(os.environ, LD_PRELOAD=preload, RUNE_ATK_PARENT_LOG=str(log))

        def observe(start, action, row_y):
            def published():
                lines = log.read_text().splitlines()[start:]
                return (any(line.startswith(f"{action}\tA edited\t") for line in lines)
                        and f"{action}\tScroll item\t8,{row_y},104,32" in lines)
            wait_for(published, f"{action} did not expose both current ATK nodes at row y={row_y}")
            return len(log.read_text().splitlines())

        desktop.set_enabled(False)
        with launched(binary, env) as (pid, window):
            click(window, 40, "renamed")
            click(window, 360, "scroll 30")
            assert not log.read_text(), "Rune published semantic children before any demand"
            desktop.set_enabled(True)
            start = observe(0, "attach", 102)
            desktop.set_enabled(False)
            start = observe(start, "detach", 102)
            click(window, 360, "scroll 0")
            assert len(log.read_text().splitlines()) == start, "disabled scrolling published accessible children"
            desktop.set_enabled(True)
            observe(start, "attach", 132)
            with desktop.connection() as conn:
                tree = Tree(conn)
                root = tree.root(pid)
                assert tree.named(root, "A edited")
                row = tree.named(root, "Scroll item")
                assert row and tree.box(row) == ROW
            print("PASS IsEnabled alone published A edited and the scrolled row at y=102, released both "
                  "while idle, then republished both at the current y=132 before the first reader", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--isolated", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    binary = args.binary.resolve()
    if args.isolated:
        desktop = Desktop()
        check_late_reader(binary, desktop)
        check_setting(binary, desktop)
        return
    with tempfile.TemporaryDirectory(prefix="rune-atspi-demand-") as work:
        env = dict(os.environ, SDL_VIDEODRIVER="x11", LIBGL_ALWAYS_SOFTWARE="1", LP_NUM_THREADS="1")
        for name in ("RUNTIME", "CONFIG", "DATA", "CACHE"):
            path = Path(work) / name.lower()
            path.mkdir(mode=0o700)
            env[f"XDG_{name}_DIR" if name == "RUNTIME" else f"XDG_{name}_HOME"] = str(path)
        for key in ("AT_SPI_BUS_ADDRESS", "DBUS_SESSION_BUS_ADDRESS", "NO_AT_BRIDGE"):
            env.pop(key, None)
        subprocess.run(["dbus-run-session", "--", "xvfb-run", "-a", sys.executable, __file__,
                        "--isolated", str(binary)], env=env, check=True)


if __name__ == "__main__":
    main()
