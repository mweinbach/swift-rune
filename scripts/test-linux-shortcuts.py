#!/usr/bin/env python3
"""Exercise Rune's X11 shortcut bridge on a private, two-screen X server.

Requires xvfb-run, xauth, python3-xlib, a C compiler and libxcb development files.
Usage: python3 scripts/test-linux-shortcuts.py [path/to/rune-shortcut-probe]
"""

import argparse
import ctypes as c
import os
from pathlib import Path
import queue
import selectors
import shutil
import subprocess
import sys
import tempfile
import time

from Xlib import X, XK, display, error
from Xlib.ext import xtest


class Shortcuts:
    callback_type = c.CFUNCTYPE(None, c.c_void_p, c.c_uint32, c.c_char_p)
    ok, conflict, invalid, unknown = range(4)

    def __init__(self, library):
        self.lib = library
        self.lib.rune_x11_hotkeys_open.argtypes = [self.callback_type, c.c_void_p, c.POINTER(c.c_int)]
        self.lib.rune_x11_hotkeys_open.restype = c.c_void_p
        self.lib.rune_x11_hotkeys_register.argtypes = [c.c_void_p, c.c_uint32, c.c_uint8, c.c_char_p]
        self.lib.rune_x11_hotkeys_unregister.argtypes = [c.c_void_p, c.c_uint32]
        self.lib.rune_x11_hotkeys_close.argtypes = [c.c_void_p]
        self.lib.rune_x11_hotkeys_close.restype = None
        self.events = queue.Queue()
        self.callback = self.callback_type(lambda context, hotkey_id, token: self.events.put((hotkey_id, token)))
        status = c.c_int(-1)
        self.manager = self.lib.rune_x11_hotkeys_open(self.callback, None, c.byref(status))
        assert self.manager and status.value == self.ok, f"Cannot open shortcut manager: {status.value}"

    def register(self, hotkey_id, modifiers, key):
        return self.lib.rune_x11_hotkeys_register(self.manager, hotkey_id, modifiers, key.encode("ascii"))

    def unregister(self, hotkey_id):
        return self.lib.rune_x11_hotkeys_unregister(self.manager, hotkey_id)

    def close(self):
        if self.manager:
            self.lib.rune_x11_hotkeys_close(self.manager)
            self.manager = None


def code(connection, name):
    keycode = connection.keysym_to_keycode(XK.string_to_keysym(name))
    assert keycode, f"Missing X11 key {name}"
    return keycode


def press(connection, name, pressed):
    xtest.fake_input(connection, X.KeyPress if pressed else X.KeyRelease, code(connection, name))
    connection.sync()


def tap(connection, name):
    press(connection, name, True)
    press(connection, name, False)


def grab(connection, root, keycode, mask):
    errors = error.CatchError()
    root.grab_key(keycode, mask, False, X.GrabModeAsync, X.GrabModeAsync, onerror=errors)
    connection.sync()
    return errors.get_error()


def check(connection, shortcuts):
    first, second = (connection.screen(i).root for i in (0, 1))
    focused = first.create_window(0, 0, 120, 80, 0, X.CopyFromParent, X.InputOutput,
                                  X.CopyFromParent, event_mask=X.KeyPressMask | X.KeyReleaseMask)
    focused.map()
    focused.set_input_focus(X.RevertToParent, X.CurrentTime)
    connection.sync()
    key = code(connection, "h")
    ctrl, ctrl_caps = X.ControlMask, X.ControlMask | X.LockMask
    hotkey_id = 0xF0000123

    # The second screen holds just one lock variant. A failed partial registration
    # must return every earlier grab, including the first screen's unlocked chord.
    assert grab(connection, second, key, ctrl_caps) is None
    assert shortcuts.register(hotkey_id, 1, "h") == shortcuts.conflict
    for root in (first, second):
        assert grab(connection, root, key, ctrl) is None, "Failed registration left a grab behind"
        root.ungrab_key(key, ctrl)
    second.ungrab_key(key, ctrl_caps)
    connection.sync()

    assert shortcuts.unregister(hotkey_id) == shortcuts.unknown
    assert shortcuts.register(hotkey_id, 1, "unknown-key") == shortcuts.invalid
    assert shortcuts.register(hotkey_id, 1, "h") == shortcuts.ok
    assert shortcuts.register(87, 1, "h") == shortcuts.conflict
    assert isinstance(grab(connection, second, key, ctrl), error.BadAccess)

    # Establish that this server actually sends auto-repeated events while a key is held.
    connection.change_keyboard_control(auto_repeat_mode=X.AutoRepeatModeOn)
    press(connection, "j", True)
    time.sleep(1.3)
    press(connection, "j", False)
    repeats = 0
    while connection.pending_events():
        event = connection.next_event()
        if event.type == X.KeyPress and event.detail == code(connection, "j"):
            repeats += 1
    assert repeats > 1, "Server did not generate autorepeat"

    numcode = code(connection, "Num_Lock")
    num_mask = next(1 << i for i, keys in enumerate(connection.get_modifier_mapping()) if numcode in keys)
    for toggle, expected_locks in [(None, 0), ("Caps_Lock", X.LockMask),
                                   ("Num_Lock", X.LockMask | num_mask), ("Caps_Lock", num_mask)]:
        if toggle:
            tap(connection, toggle)
        locks = first.query_pointer().mask & (num_mask | X.LockMask)
        assert locks == expected_locks, f"Unexpected lock state {locks:#x}"
        press(connection, "Control_L", True)
        press(connection, "h", True)
        assert shortcuts.events.get(timeout=5) == (hotkey_id, None)
        if toggle is None:
            time.sleep(1.3)
        press(connection, "h", False)
        press(connection, "Control_L", False)

    tap(connection, "Num_Lock")
    assert shortcuts.unregister(hotkey_id) == shortcuts.ok
    assert grab(connection, first, key, ctrl_caps) is None
    first.ungrab_key(key, ctrl_caps)
    connection.sync()
    # Map the H position to Q as on a different keyboard layout before registering.
    # A global physical shortcut must follow this keycode, not look up the H keysym.
    other_key = code(connection, "q")
    original = connection.get_keyboard_mapping(key, 1)
    other = connection.get_keyboard_mapping(other_key, 1)
    connection.change_keyboard_mapping(key, other)
    connection.change_keyboard_mapping(other_key, original)
    connection.sync()
    assert connection.get_keyboard_mapping(key, 1)[0][0] == XK.string_to_keysym("q")
    # A different ID also identifies stale or repeat deliveries.
    assert shortcuts.register(11, 1, "h") == shortcuts.ok
    press(connection, "Control_L", True)
    xtest.fake_input(connection, X.KeyPress, key)
    xtest.fake_input(connection, X.KeyRelease, key)
    press(connection, "Control_L", False)
    assert shortcuts.events.get(timeout=5) == (11, None), "Repeated or stale shortcut"
    shortcuts.close()
    for root in (first, second):
        assert grab(connection, root, key, ctrl) is None, "Closing left a grab behind"
    assert shortcuts.events.empty(), "A held shortcut fired more than once"


def check_swift_app(executable):
    # The probe owns no visible window; focus stays with a different X11 client.
    connection = display.Display()
    first = connection.screen(0).root
    focused = first.create_window(0, 0, 120, 80, 0, X.CopyFromParent, X.InputOutput, X.CopyFromParent)
    focused.map()
    focused.set_input_focus(X.RevertToParent, X.CurrentTime)
    connection.sync()
    env = {**os.environ, "SDL_VIDEODRIVER": "x11", "RUNE_GPU_INFO": "1"}
    with subprocess.Popen([executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env) as app:
        try:
            def expect(line):
                with selectors.DefaultSelector() as selector:
                    selector.register(app.stdout, selectors.EVENT_READ)
                    assert selector.select(timeout=45), f"Timed out waiting for {line!r}"
                    actual = app.stdout.readline().strip()
                assert actual == line, f"Expected {line!r}, read {actual!r}"

            expect(b"READY")
            conflict = subprocess.run([executable, "--probe-conflict"], env=env, check=True,
                                      capture_output=True, timeout=45)
            assert b"CONFLICT" in conflict.stdout.splitlines(), conflict.stderr

            assert connection.get_input_focus().focus == focused
            keys = ["Super_L", "Control_L", "Alt_L", "Shift_L", "k"]
            for key in keys:
                press(connection, key, True)
            for key in reversed(keys):
                press(connection, key, False)
            expect(b"FIRED 1")
            app.stdin.close()
            assert app.wait(timeout=15) == 0
            print("Swift shortcut probe registered, fired with external focus, rejected a second process and closed.")
        finally:
            if app.poll() is None:
                app.kill()
            connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", nargs="?", type=Path)
    parser.add_argument("--private-xvfb", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not args.private_xvfb:
        command = ["xvfb-run", "-a", "-s", "-screen 0 320x200x24 -screen 1 320x200x24"]
        if args.executable:
            command += ["dbus-run-session", "--"]
        command += [sys.executable, __file__, "--private-xvfb"]
        if args.executable:
            command.append(str(args.executable.resolve()))
        subprocess.run(command, check=True)
        return
    sources = Path(__file__).resolve().parents[1] / "Sources" / "CRuneDesktopServices"
    with tempfile.TemporaryDirectory() as directory:
        library = Path(directory) / "hotkeys.so"
        compiler = os.environ.get("CC") or shutil.which("cc") or "clang"
        subprocess.run([compiler, "-std=c11", "-D_GNU_SOURCE", "-fPIC", "-shared",
                        "-I", str(sources / "include"), str(sources / "LinuxHotkeys.c"),
                        "-lxcb", "-pthread", "-o", str(library)], check=True)
        shortcuts = Shortcuts(c.CDLL(str(library)))
        connection = display.Display()
        try:
            check(connection, shortcuts)
        finally:
            shortcuts.close()
            connection.close()
    if args.executable:
        check_swift_app(args.executable)
    print("Rune X11 shortcuts passed held-key, Caps/Num Lock, two-screen conflict rollback and teardown checks.")


if __name__ == "__main__":
    main()
