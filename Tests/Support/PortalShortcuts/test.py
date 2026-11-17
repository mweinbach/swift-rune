#!/usr/bin/env python3
"""Test the native GIO shortcut bridge on a private session bus.

Pass --app /path/to/rune-shortcut-probe to also run the Swift app under Weston.
This mode uses Weston's headless backend and requires a Wayland-capable GL driver.
"""

import argparse
import ctypes
import os
from pathlib import Path
import queue
import selectors
import shlex
import subprocess
import sys
import tempfile
import threading
import time

from gi.repository import Gio, GLib

ROOT = Path(__file__).resolve().parents[3]
NAME = "org.freedesktop.portal.Desktop"
PATH = "/org/freedesktop/portal/desktop"
IFACE = "org.freedesktop.portal.GlobalShortcuts"
SESSION = "org.freedesktop.portal.Session"
REQUEST = "org.freedesktop.portal.Request"
SINK = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p)
OK, UNKNOWN_ID, UNSUPPORTED, DENIED = 0, 3, 4, 5

API = Gio.DBusNodeInfo.new_for_xml(f"""
<node>
  <interface name="{IFACE}">
    <property name="version" type="u" access="read"/>
    <method name="CreateSession"><arg type="a{{sv}}" direction="in"/><arg type="o" direction="out"/></method>
    <method name="BindShortcuts"><arg type="o" direction="in"/><arg type="a(sa{{sv}})" direction="in"/>
      <arg type="s" direction="in"/><arg type="a{{sv}}" direction="in"/><arg type="o" direction="out"/></method>
    <signal name="Activated"><arg type="o"/><arg type="s"/><arg type="t"/><arg type="a{{sv}}"/></signal>
  </interface>
  <interface name="{SESSION}"><method name="Close"/><signal name="Closed"><arg type="a{{sv}}"/></signal></interface>
</node>""")


class Portal:
    def __init__(self):
        # The fixture and Rune each own a separate connection to the private bus.
        flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
        self.bus = Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SESSION_BUS_ADDRESS"], flags, None, None)
        self.bus.register_object(PATH, API.interfaces[0], self.method, self.property, None)
        self.paths = {}
        self.registrations = {}
        self.closed = queue.Queue()
        self.created = 0
        self.trigger = {}
        self.bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                           GLib.Variant("(su)", (NAME, 0)), GLib.VariantType.new("(u)"),
                           Gio.DBusCallFlags.NONE, 3000, None)

    def property(self, *args):
        return GLib.Variant("u", 1)

    def method(self, bus, sender, path, interface, method, args, invocation):
        if method == "Close":
            self.closed.put(path)
            invocation.return_value(GLib.Variant("()", ()))
            return

        sender_path = sender.removeprefix(":").replace(".", "_")
        options = args.unpack()[-1]
        request = f"{PATH}/request/{sender_path}/{options['handle_token']}"
        status = 0
        if method == "CreateSession":
            self.created += 1
            session = f"{PATH}/session/{sender_path}/{options['session_handle_token']}"
            self.registrations[session] = self.bus.register_object(session, API.interfaces[1], self.method, None, None)
            # Existing desktops send the session handle as a string or as an object path.
            results = {"session_handle": GLib.Variant("s" if self.created % 2 else "o", session)}
        else:
            session, shortcuts, _, _ = args.unpack()
            [(shortcut, details)] = shortcuts
            self.paths[shortcut] = (sender, session)
            self.trigger[shortcut] = details["preferred_trigger"]
            status = 1 if shortcut == "43" else 0
            returned = [] if shortcut == "44" else [(shortcut, {})]
            results = {"shortcuts": GLib.Variant("a(sa{sv})", returned)}

        # A fast portal can signal acceptance or cancellation before replying to the method.
        bus.emit_signal(sender, request, REQUEST, "Response", GLib.Variant("(ua{sv})", (status, results)))
        invocation.return_value(GLib.Variant("(o)", (request,)))

    def activate(self, session_id, shortcut, token):
        sender, session = self.paths[str(session_id)]
        self.bus.emit_signal(sender, PATH, IFACE, "Activated", GLib.Variant(
            "(osta{sv})", (session, str(shortcut), 123, {"activation_token": GLib.Variant("s", token)})))

    def revoke(self, shortcut):
        sender, session = self.paths[str(shortcut)]
        self.bus.emit_signal(sender, session, SESSION, "Closed", GLib.Variant("(a{sv})", ({},)))
        self.bus.unregister_object(self.registrations.pop(session))


def check_native(library):
    native = ctypes.CDLL(library)
    open_ = native.rune_portal_hotkeys_open
    open_.argtypes = [SINK, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    open_.restype = ctypes.c_void_p
    register = native.rune_portal_hotkeys_register
    register.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint8, ctypes.c_char_p]
    unregister = native.rune_portal_hotkeys_unregister
    unregister.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    close = native.rune_portal_hotkeys_close
    close.argtypes = [ctypes.c_void_p]
    close.restype = None
    loop = GLib.MainLoop()
    thread = threading.Thread(target=loop.run, daemon=True)
    thread.start()
    received = queue.Queue()

    @SINK
    def sink(context, shortcut, token):
        received.put((context, shortcut, token))

    salt = 101
    status = ctypes.c_int()
    assert not open_(sink, salt, ctypes.byref(status)) and status.value == UNSUPPORTED
    portal = Portal()
    manager = open_(sink, salt, ctypes.byref(status))
    assert manager and status.value == OK
    try:
        assert register(manager, 41, 5, b"f8") == OK
        assert register(manager, 42, 1, b"j") == OK
        assert portal.trigger["41"] == "CTRL+SHIFT+F8"
        assert portal.trigger["42"].lower() == "ctrl+j"
        assert portal.paths["41"][1] != portal.paths["42"][1]
        for rejected in (43, 44):
            assert register(manager, rejected, 1, b"k") == DENIED
            assert portal.closed.get(timeout=3) == portal.paths[str(rejected)][1]

        portal.activate(42, 41, "wrong-session")
        portal.activate(41, 41, "valid-first")
        assert received.get(timeout=3) == (salt, 41, b"valid-first")
        assert unregister(manager, 41) == OK
        assert portal.closed.get(timeout=3) == portal.paths["41"][1]
        assert unregister(manager, 41) == UNKNOWN_ID
        portal.activate(41, 41, "stale")
        portal.activate(42, 42, "valid-second")
        assert received.get(timeout=3) == (salt, 42, b"valid-second")
        assert register(manager, 45, 1, b"r") == OK
        portal.revoke(45)
        portal.activate(45, 45, "revoked")
        portal.activate(42, 42, "still-active")
        assert received.get(timeout=3) == (salt, 42, b"still-active")
        assert unregister(manager, 45) == OK, "Releasing a portal-revoked session failed"
        assert received.empty()
    finally:
        close(manager)
    assert portal.closed.get(timeout=3) == portal.paths["42"][1]

    # The application must be able to release local bindings after the portal restarts.
    manager = open_(sink, salt, ctypes.byref(status))
    assert manager and status.value == OK
    try:
        assert register(manager, 46, 1, b"q") == OK
        portal.bus.close_sync(None)
        assert unregister(manager, 46) == OK, "A vanished portal left a binding stuck"
    finally:
        close(manager)
    loop.quit()
    thread.join()
    print("Portal shortcut integration passed: absence, early replies, consent, activation, revocation and teardown.")


def check_app(binary, directory):
    socket = directory / "rune-wayland"
    weston_log = directory / "weston.log"
    env = dict(os.environ, XDG_RUNTIME_DIR=str(directory), WAYLAND_DISPLAY=socket.name,
               SDL_VIDEODRIVER="wayland", RUNE_GPU_INFO="1")
    weston = subprocess.Popen([
        "weston", "-B", "headless", "--renderer=pixman", "--shell=kiosk-shell.so", "--no-config",
        "--idle-time=0", f"--socket={socket.name}", f"--log={weston_log}",
    ], env=env)
    try:
        deadline = time.monotonic() + 15
        while not socket.is_socket():
            if weston.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError(weston_log.read_text() if weston_log.exists() else "Weston did not start")
            time.sleep(0.05)

        service = Portal()
        loop = GLib.MainLoop()
        thread = threading.Thread(target=loop.run, daemon=True)
        thread.start()
        try:
            with subprocess.Popen([binary], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  bufsize=0) as app:
                try:
                    expect_line(app.stdout, b"READY")
                    ids = {chord: key for key, chord in service.trigger.items()}
                    assert set(ids) == {"CTRL+ALT+SHIFT+LOGO+k", "CTRL+ALT+SHIFT+F11"}, ids
                    primary, secondary = ids["CTRL+ALT+SHIFT+LOGO+k"], ids["CTRL+ALT+SHIFT+F11"]
                    assert service.closed.get(timeout=3) == service.paths[secondary][1]
                    service.activate(primary, primary, "rune-wayland-test")
                    expect_line(app.stdout, b"FIRED 1")
                    app.stdin.close()
                    assert app.wait(timeout=15) == 0
                    assert service.closed.get(timeout=3) == service.paths[primary][1]
                finally:
                    if app.poll() is None:
                        app.kill()
        finally:
            service.bus.close_sync(None)
            loop.quit()
            thread.join()
    finally:
        if weston.poll() is None:
            weston.terminate()
            try:
                weston.wait(timeout=5)
            except subprocess.TimeoutExpired:
                weston.kill()
                weston.wait()
    print("Swift Wayland app registered two shortcuts, handled a portal activation, and closed both sessions.")


def expect_line(stream, expected):
    with selectors.DefaultSelector() as selector:
        selector.register(stream, selectors.EVENT_READ)
        if not selector.select(timeout=25):
            raise TimeoutError(f"Swift app did not report {expected!r}")
        actual = stream.readline().strip()
        assert actual == expected, (actual, expected)


def run(app):
    with tempfile.TemporaryDirectory(prefix="rune-portal-shortcuts-") as tmp:
        temp = Path(tmp)
        source = ROOT / "Sources/CRuneDesktopServices"
        library = temp / "libportalhotkeys.so"
        flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "gio-2.0"], text=True))
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-fPIC", "-shared", "-pthread", "-Werror",
                        "-Wall", "-Wextra", "-I", str(source / "include"), str(source / "PortalHotkeys.c"),
                        "-o", str(library), *flags], check=True)

        # No service directories: even the absent-service check cannot auto-start a desktop portal.
        config = temp / "bus.conf"
        config.write_text(f"""<busconfig><type>session</type><listen>unix:tmpdir={tmp}</listen>
            <policy context="default"><allow own="*"/><allow send_destination="*"/>
            <allow receive_sender="*"/></policy></busconfig>""")
        command = ["dbus-run-session", "--config-file", str(config), "--", sys.executable,
                   str(Path(__file__).resolve()), "--client", str(library)]
        if app:
            command.extend(["--app", str(app.resolve())])
        subprocess.run(command, check=True, timeout=100 if app else 45)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, metavar="RUNE_SHORTCUT_PROBE")
    parser.add_argument("--client", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.client:
        check_native(args.client)
        if args.app:
            check_app(args.app, args.client.parent)
    else:
        run(args.app)
