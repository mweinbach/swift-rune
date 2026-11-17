#!/usr/bin/env python3
"""Exercise Rune's context menus and text field actions through X11 and AT-SPI.

    dbus-run-session -- xvfb-run -a /usr/bin/python3 scripts/test-linux-popup.py \
        .build/debug/rune-popup-menu .build/debug/rune-rich-clipboard

Add --spelling Tests/Support/PopupSpelling/.build/debug/PopupSpelling to exercise
an installed en-US dictionary. Build the fixture using swift build --package-path Tests/Support/PopupSpelling.
In a Wayland session, pass --wayland-picker followed by the rune-popup-menu path to test native AT-SPI actions.

Requires xdotool, ImageMagick, Xvfb, D-Bus, at-spi2-core, Python GI and gir1.2-atspi-2.0.
"""

import argparse
import os
import subprocess
import time
from contextlib import contextmanager

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib


def wait_for(query, description):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        while GLib.MainContext.default().iteration(False):
            pass
        try:
            value = query()
            if value:
                return value
        except GLib.Error:
            # Replaced popup rows may disappear during this AT-SPI traversal.
            pass
        time.sleep(0.04)
    raise AssertionError(f"Timed out waiting for {description}")


def descendants(node):
    yield node
    for index in range(node.get_child_count()):
        child = node.get_child_at_index(index)
        if child:
            yield from descendants(child)


def xdo(*args):
    return subprocess.check_output(["xdotool", *map(str, args)], text=True, timeout=8).strip()


class Window:
    def __init__(self, root, window_id):
        self.root = root
        self.window_id = window_id

    def lookup(self, name=None, role=None, state=None):
        self.root.clear_cache()
        return next((node for node in descendants(self.root)
                     if (name is None or (node.get_name() or "").split() == name.split())
                     and (role is None or node.get_role() == role)
                     and (state is None or node.get_state_set().contains(state))), None)

    def find(self, name=None, role=None, state=None):
        return wait_for(lambda: self.lookup(name, role, state), f"{name or role or state}")

    def click(self, node, button=1):
        rect = node.get_extents(Atspi.CoordType.SCREEN)
        assert rect.width > 0 and rect.height > 0, node.get_name()
        xdo("mousemove", rect.x + rect.width // 2, rect.y + rect.height // 2, "click", button)

    def keys(self, *keys):
        xdo("key", "--clearmodifiers", "--delay", "85", *keys)

    def closed(self):
        wait_for(lambda: self.lookup(role=Atspi.Role.MENU) is None, "popup dismissal")

    def pixels(self):
        return subprocess.check_output(
            ["import", "-window", self.window_id, "-depth", "8", "rgb:-"], timeout=8
        )


@contextmanager
def launched(binary, title, driver="x11"):
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        raise RuntimeError("Run this test inside dbus-run-session and Xvfb")
    env = dict(os.environ, SDL_VIDEODRIVER=driver)
    with subprocess.Popen([binary], env=env) as app:
        try:
            desktop = Atspi.get_desktop(0)

            def root():
                if app.poll() is not None:
                    raise RuntimeError(f"{binary} exited with code {app.returncode}")
                return next((child for i in range(desktop.get_child_count())
                             if (child := desktop.get_child_at_index(i))
                             and child.get_process_id() == app.pid), None)

            accessible = wait_for(root, "Rune AT-SPI application")
            assert accessible.get_toolkit_name() == "Rune"
            window_id = None
            if driver == "x11":
                window_id = xdo("search", "--sync", "--onlyvisible", "--name", f"^{title}$").splitlines()[0]
                xdo("windowfocus", "--sync", window_id)
            try:
                yield Window(accessible, window_id)
            except AssertionError:
                accessible.clear_cache()
                for node in descendants(accessible):
                    print(node.get_role_name(), repr(node.get_name()), flush=True)
                raise
        finally:
            if app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    app.kill()


def test_example(binary, other_window):
    with launched(binary, "Rune pop-up menus") as ui:
        def context():
            ui.click(ui.find("Secondary-click for a context menu"), 3)
            return ui.find("Context menu", Atspi.Role.MENU)

        def last(value):
            ui.find(f"Last: {value}  ·  native menus: true")

        def select_copy():
            context()
            ui.click(ui.find("Copy", Atspi.Role.MENU_ITEM))
            ui.closed()
            last("copy")

        last("-")
        before = ui.pixels()
        context()
        disabled = ui.find("Paste", Atspi.Role.MENU_ITEM)
        assert not disabled.get_state_set().contains(Atspi.StateType.ENABLED)
        def changed_pixels():
            current = ui.pixels()
            assert len(before) == len(current)
            changed = sum(max(abs(current[i+j] - before[i+j]) for j in range(3)) > 15
                          for i in range(0, len(before), 3))
            return changed if changed > 700 else None
        changed = wait_for(changed_pixels, "native window to draw the popup")
        ui.click(disabled)
        ui.click(ui.find("Share"))
        ui.click(ui.find("Mail", Atspi.Role.MENU_ITEM))
        ui.closed()
        last("mail")

        context()
        ui.keys("End", "Right")
        ui.find("Messages", Atspi.Role.MENU_ITEM)
        ui.keys("End", "Return")
        ui.closed()
        last("messages")

        context()
        ui.keys("Escape")
        ui.closed()
        last("(dismissed)")
        select_copy()
        context()
        xdo("mousemove", "--window", ui.window_id, 1, 1, "click", 1)
        ui.closed()
        last("(dismissed)")
        select_copy()
        context()
        with launched(other_window, "Rich Clipboard"):
            ui.closed()
            last("(dismissed)")
        xdo("windowfocus", "--sync", ui.window_id)

        ui.click(ui.find("System"))
        system = ui.find("System", state=Atspi.StateType.CHECKED)
        assert system.get_state_set().contains(Atspi.StateType.ENABLED)
        ui.click(ui.find("Dark", Atspi.Role.MENU_ITEM))
        ui.closed()
        ui.click(ui.find("Dark"))
        ui.find("Dark", state=Atspi.StateType.CHECKED)
        ui.keys("Escape")
        ui.closed()
        print(f"PASS secondary press changed {changed} window pixels", flush=True)
        print("PASS nested pointer and keyboard selection, disabled item, cancellation and anchored picker", flush=True)


def test_field(binary):
    with launched(binary, "Rich Clipboard") as ui:
        field = ui.find(state=Atspi.StateType.EDITABLE)
        text = "Text selected in Rune"
        ui.click(field)
        assert field.set_text_contents(text)
        wait_for(lambda: Atspi.Text.get_text(field, 0, -1) == text, "field contents")
        ui.keys("Menu")
        ui.click(ui.find("Select All", Atspi.Role.MENU_ITEM))
        ui.closed()

        def selected():
            field = ui.lookup(state=Atspi.StateType.EDITABLE)
            if not field:
                return False
            if Atspi.Text.get_n_selections(field) != 1:
                return False
            span = Atspi.Text.get_selection(field, 0)
            return (span.start_offset, span.end_offset) == (0, len(text))
        wait_for(selected, "field selection after the popup action")
        ui.keys("Shift_L+F10")
        cut = ui.find("Cut", Atspi.Role.MENU_ITEM)
        assert cut.get_state_set().contains(Atspi.StateType.ENABLED)
        ui.click(cut)
        ui.closed()
        field = ui.find(state=Atspi.StateType.EDITABLE)
        wait_for(lambda: Atspi.Text.get_text(field, 0, -1) == "", "Cut deleting the selection")
        print("PASS field context key, Select All, enabled Cut and edited text", flush=True)


def test_spelling(binary):
    with launched(binary, "Popup spelling probe") as ui:
        def word():
            field = ui.lookup(state=Atspi.StateType.EDITABLE)
            return Atspi.Text.get_text(field, 0, -1) if field else None

        wait_for(lambda: word() == "wrold", "misspelled word")
        ui.click(ui.find(state=Atspi.StateType.EDITABLE), 3)
        ui.find("world", Atspi.Role.MENU_ITEM)
        ui.keys("Escape")
        ui.closed()
        assert word() == "wrold"
        ui.click(ui.find(state=Atspi.StateType.EDITABLE), 3)
        ui.click(ui.find("world", Atspi.Role.MENU_ITEM))
        ui.closed()
        wait_for(lambda: word() == "world", "accepted spelling correction")
        print("PASS en-US suggestion after secondary press, dismissed without editing, then corrected wrold to world", flush=True)


def test_wayland_picker(binary):
    def press(node):
        while node:
            for index in range(node.get_n_actions()):
                if node.get_localized_name(index) == "press":
                    assert node.do_action(index)
                    return
            node = node.get_parent()
        raise AssertionError("The picker has no accessible press action")

    with launched(binary, "Rune pop-up menus", driver="wayland") as ui:
        press(ui.find("System"))
        ui.find("System", state=Atspi.StateType.CHECKED)
        press(ui.find("Dark", Atspi.Role.MENU_ITEM))
        ui.closed()
        press(ui.find("Dark"))
        ui.find("Dark", state=Atspi.StateType.CHECKED)
        print("PASS native Wayland picker opened, chose Dark through AT-SPI and retained the checked selection", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("popup_demo")
    parser.add_argument("rich_clipboard", nargs="?")
    parser.add_argument("--spelling", metavar="PROBE", help="optional PopupSpelling fixture")
    parser.add_argument("--wayland-picker", action="store_true", help="run the picker using a Wayland compositor and AT-SPI")
    args = parser.parse_args()
    if args.wayland_picker:
        test_wayland_picker(args.popup_demo)
    else:
        if not args.rich_clipboard:
            parser.error("the X11 tests require the rune-rich-clipboard binary")
        test_example(args.popup_demo, args.rich_clipboard)
        test_field(args.rich_clipboard)
        if args.spelling:
            test_spelling(args.spelling)
