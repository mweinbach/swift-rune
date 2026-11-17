#!/usr/bin/env python3
"""Probe native Rune windows over AT-SPI in an isolated Linux desktop.

    dbus-run-session -- xvfb-run -a /usr/bin/python3 scripts/test-linux-accessibility.py \
        .build/debug/rune-hello .build/debug/rune-rich-clipboard .build/debug/rune-kit-rich-editor

The editor arguments are optional. A fourth binary, built from Tests/Support/WindowsTextAccessibility,
exercises scrolling via the Component and Text interfaces. The test needs at-spi2-core, python3-gi, gir1.2-atspi-2.0,
dbus, xvfb, xauth, and a working OpenGL driver (Mesa llvmpipe works inside Xvfb).
"""

import contextlib
import os
import subprocess
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib


def wait_for(query):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        while GLib.MainContext.default().iteration(False):
            pass
        if result := query():
            return result
        time.sleep(0.05)
    raise AssertionError("AT-SPI did not report the expected state within 15 seconds")


def descendants(node):
    yield node
    for index in range(node.get_child_count()):
        yield from descendants(node.get_child_at_index(index))


@contextlib.contextmanager
def launched(binary):
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        raise RuntimeError("Run in an isolated D-Bus desktop, e.g. dbus-run-session -- xvfb-run -a")
    with subprocess.Popen([binary]) as app:
        try:
            desktop = Atspi.get_desktop(0)

            def application():
                if app.poll() is not None:
                    raise RuntimeError(f"{binary} exited with status {app.returncode}")
                for i in range(desktop.get_child_count()):
                    candidate = desktop.get_child_at_index(i)
                    if candidate.get_process_id() == app.pid:
                        return candidate

            root = wait_for(application)
            assert root.get_toolkit_name() == "Rune"

            yield root
        finally:
            app.terminate()
            try:
                app.wait(timeout=4)
            except subprocess.TimeoutExpired:
                app.kill()


def test_switch(binary):
    with launched(binary) as root:
        def named(name):
            return next((n for n in descendants(root) if n.get_name() == name), None)

        light = wait_for(lambda: named("Lights"))
        assert light.get_role() == Atspi.Role.TOGGLE_BUTTON
        assert light.get_state_set().contains(Atspi.StateType.CHECKABLE)
        assert not light.get_state_set().contains(Atspi.StateType.CHECKED)
        assert wait_for(lambda: named("Lights off"))
        bounds = light.get_extents(Atspi.CoordType.WINDOW)
        # Fractional logical origins cover one extra integer pixel on the enclosing ATK rectangle.
        assert 38 <= bounds.width <= 39 and 22 <= bounds.height <= 23, (bounds.x, bounds.y, bounds.width, bounds.height)
        assert light.grab_focus()
        wait_for(lambda: light.get_state_set().contains(Atspi.StateType.FOCUSED))
        assert not light.get_state_set().contains(Atspi.StateType.CHECKED), "Focusing a switch activated it"
        actions = [light.get_localized_name(i) for i in range(light.get_n_actions())]
        assert light.do_action(actions.index("press"))
        wait_for(lambda: light.get_state_set().contains(Atspi.StateType.CHECKED))
        wait_for(lambda: named("Lights on"))
        print(f"AT-SPI Rune: Lights {bounds.width}x{bounds.height}; focus, press, checked, Lights on")


def editable_field(root):
    return wait_for(lambda: next((n for n in descendants(root)
                                  if n.get_state_set().contains(Atspi.StateType.EDITABLE)), None))


def test_character_geometry(field):
    value = "Ae\u0301🚀Z"
    assert field.set_text_contents(value)
    wait_for(lambda: Atspi.Text.get_text(field, 0, -1) == value)
    assert field.get_character_count() == len(value)
    relative = []
    for coords in (Atspi.CoordType.WINDOW, Atspi.CoordType.SCREEN, Atspi.CoordType.PARENT):
        box = field.get_extents(coords)
        glyphs = [Atspi.Text.get_character_extents(field, offset, coords) for offset in range(len(value))]
        cells = [(g.x - box.x, g.y - box.y, g.width, g.height) for g in glyphs]
        assert cells[1] == cells[2], ("combining mark has a separate rectangle", coords, cells)
        assert len({cells[i][0] for i in (0, 1, 3, 4)}) == 4, (coords, cells)
        span = Atspi.Text.get_range_extents(field, 1, 4, coords)
        cluster, rocket = glyphs[1], glyphs[3]
        assert (span.x, span.y, span.x + span.width, span.y + span.height) == (
            min(cluster.x, rocket.x), min(cluster.y, rocket.y),
            max(cluster.x + cluster.width, rocket.x + rocket.width),
            max(cluster.y + cluster.height, rocket.y + rocket.height))
        for offset in (0, 1, 3, 4):
            g = glyphs[offset]
            assert g.width > 0 and g.height > 0, (coords, offset, cells)
            x, y = g.x + g.width // 2, g.y + g.height // 2
            assert box.x <= x < box.x + box.width and box.y <= y < box.y + box.height
            assert Atspi.Text.get_offset_at_point(field, x, y, coords) == offset, (coords, offset, cells)
        assert Atspi.Text.get_offset_at_point(field, box.x - 5, box.y - 5, coords) == -1
        relative.append(cells)
    assert relative[0] == relative[1] == relative[2], relative
    cell = field.get_character_extents(3, Atspi.CoordType.SCREEN)
    print(f"AT-SPI Rune: rocket {cell.width}x{cell.height} at screen ({cell.x}, {cell.y}); "
          "grapheme hits in window, screen and parent coordinates")

    rtl = "שלום"
    assert field.set_text_contents(rtl)
    wait_for(lambda: Atspi.Text.get_text(field, 0, -1) == rtl)
    cells = [field.get_character_extents(i, Atspi.CoordType.WINDOW) for i in range(len(rtl))]
    assert all(a.x > b.x for a, b in zip(cells, cells[1:]))
    for offset, rect in enumerate(cells):
        assert field.get_offset_at_point(rect.x + rect.width // 2, rect.y + rect.height // 2,
                                         Atspi.CoordType.WINDOW) == offset
    print("AT-SPI Rune: right-to-left glyph hits preserve logical offsets")

    if not field.get_state_set().contains(Atspi.StateType.SINGLE_LINE):
        return
    # A single-line editor scrolls to keep its caret visible. The same document
    # and offsets must publish new hit rectangles as the visible slice moves.
    row = "Wide editor " * 30
    assert field.set_text_contents(row)
    wait_for(lambda: Atspi.Text.get_text(field, 0, -1) == row)
    for caret, visible, hidden in ((len(row), len(row) - 2, 0), (0, 0, len(row) - 2)):
        assert field.set_caret_offset(caret)
        wait_for(lambda: field.get_caret_offset() == caret)
        wait_for(lambda: field.get_character_extents(hidden, Atspi.CoordType.WINDOW).height < 0)
        cell = field.get_character_extents(visible, Atspi.CoordType.WINDOW)
        assert cell.width > 0 and cell.height > 0, (caret, visible, hidden, cell.height)
        assert field.get_offset_at_point(cell.x + cell.width // 2, cell.y + cell.height // 2,
                                         Atspi.CoordType.WINDOW) == visible
    print("AT-SPI Rune: visible glyph bounds and hits follow horizontal input scrolling")


def test_editor(binary):
    with launched(binary) as root:
        field = editable_field(root)
        def contents():
            return Atspi.Text.get_text(field, 0, -1)

        assert field.set_text_contents("hé 🌲 tree")
        wait_for(lambda: contents() == "hé 🌲 tree")
        assert field.add_selection(1, 4)
        wait_for(lambda: Atspi.Text.get_n_selections(field) == 1)
        span = Atspi.Text.get_selection(field, 0)
        assert (span.start_offset, span.end_offset) == (1, 4)
        assert field.get_caret_offset() == 4
        assert Atspi.Text.get_string_at_offset(field, 7, Atspi.TextGranularity.WORD).content == "tree"
        assert field.insert_text(4, "!", 1)
        wait_for(lambda: contents() == "hé 🌲! tree")
        assert field.delete_text(3, 5)
        wait_for(lambda: contents() == "hé  tree")
        print("AT-SPI Rune: Unicode value, range, caret, word boundary, insertion and deletion")
        test_character_geometry(field)


def test_wrapped_editor(binary):
    with launched(binary) as root:
        field = editable_field(root)
        paragraph = "Cedar mist lights the meadow. " * 8
        value = paragraph + "\nSecond paragraph."
        assert field.set_text_contents(value)
        wait_for(lambda: Atspi.Text.get_text(field, 0, -1) == value)
        assert field.set_caret_offset(0)
        wait_for(lambda: field.get_caret_offset() == 0)
        first = field.get_string_at_offset(0, Atspi.TextGranularity.LINE)
        split = first.end_offset
        assert first.start_offset == 0 and 0 < split < len(paragraph), (split, first.content)
        assert first.content == paragraph[:split]
        second = field.get_string_at_offset(split, Atspi.TextGranularity.LINE)
        assert second.start_offset == split and second.end_offset > split
        assert second.content == value[split:second.end_offset]
        whole = field.get_string_at_offset(split, Atspi.TextGranularity.PARAGRAPH)
        assert whole.start_offset == 0 and whole.content.rstrip("\n") == paragraph
        before = field.get_character_extents(0, Atspi.CoordType.WINDOW)
        after = field.get_character_extents(split, Atspi.CoordType.WINDOW)
        assert before.height > 0 and after.height > 0 and after.y > before.y, (before.y, after.y)
        assert field.get_offset_at_point(after.x + after.width // 2, after.y + after.height // 2,
                                         Atspi.CoordType.WINDOW) == split
        print(f"AT-SPI Rune: soft wrap at scalar {split}, next line {after.y - before.y}px lower, paragraph preserved")


def test_scroll_to_field(binary):
    with launched(binary) as root:
        def named(label):
            return wait_for(lambda: next((node for node in descendants(root) if node.get_name() == label), None))

        editor, document = named("Editor"), named("Long document")
        def showing(node):
            node.clear_cache()
            return node.get_state_set().contains(Atspi.StateType.SHOWING)

        assert showing(editor) and not showing(document)
        assert not document.scroll_substring_to(-1, 3, Atspi.ScrollType.ANYWHERE)
        assert document.scroll_to(Atspi.ScrollType.ANYWHERE)
        wait_for(lambda: showing(document) and not showing(editor))
        assert editor.scroll_substring_to(0, -1, Atspi.ScrollType.TOP_EDGE)
        wait_for(lambda: showing(editor) and not showing(document))
        bounds = editor.get_character_extents(0, Atspi.CoordType.WINDOW)
        assert bounds.width > 0 and bounds.height > 0, "Revealed field lost its keyed-root text layout"
        print("AT-SPI Rune: component and text range scrolled an offscreen field into view")


if __name__ == "__main__":
    test_switch(sys.argv[1])
    if len(sys.argv) > 2:
        test_editor(sys.argv[2])
    if len(sys.argv) > 3:
        test_wrapped_editor(sys.argv[3])
    if len(sys.argv) > 4:
        test_scroll_to_field(sys.argv[4])
