#!/usr/bin/env python3
"""Exercise Rune's XDND source and an independent GTK3 target on a private Xvfb display.

Run `/usr/bin/python3 Tests/Support/X11Drag/test.py` on Linux. Requires clang,
gtk+-3.0, sdl2, OpenGL and X11 development files, PyGObject GTK3, xdotool,
xvfb-run and xauth. Add --preview to verify GPU crop, drag icon pixels and hotspot.
"""
import base64
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time


def receive(action, mime, reject):
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Gdk

    window = Gtk.Window(title="Independent XDND target")
    window.set_default_size(200, 160)
    window.move(330, 30)
    target = Gdk.Atom.intern(mime, False)
    window.drag_dest_set(Gtk.DestDefaults(0), [Gtk.TargetEntry.new(mime, 0, 0)], action)

    def motion(widget, context, x, y, stamp):
        accept = target in context.list_targets() and bool(context.get_actions() & action)
        Gdk.drag_status(context, action if accept else Gdk.DragAction(0), stamp)
        if accept:
            print("offered", flush=True)
        return accept

    def drop(widget, context, x, y, stamp):
        widget.drag_get_data(context, target, stamp)
        return True

    def received(widget, context, x, y, selection, info, stamp):
        data = selection.get_data()
        print("bytes", data.hex() if data is not None else "missing", flush=True)
        Gtk.drag_finish(context, data is not None and not reject, False, stamp)

    window.connect("drag-motion", motion)
    window.connect("drag-drop", drop)
    window.connect("drag-data-received", received)
    window.show_all()
    Gdk.Display.get_default().sync()
    print("ready", flush=True)
    Gtk.main()


def wait_for(process, log, prefix):
    end = time.monotonic() + 12
    while time.monotonic() < end:
        content = log.read_text()
        for line in content.splitlines():
            if line == prefix or line.startswith(prefix + " "):
                return line
        if process.poll() is not None:
            break
        time.sleep(0.02)
    raise RuntimeError(f"Missing {prefix!r} in {log.name}: {log.read_text()}")


def check_icon():
    import gi
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk

    root = Gdk.get_default_root_window()
    # The pointer is at (400,90), the icon is 80×48 and the hotspot is (13,7).
    colors = {(225, 18, 166): (4, 4, 43, 27), (43, 199, 52): (44, 4, 83, 27),
              (32, 96, 240): (4, 28, 43, 51)}
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        image = Gdk.pixbuf_get_from_window(root, 383, 79, 88, 56)
        if image:
            data, stride, channels = image.get_pixels(), image.get_rowstride(), image.get_n_channels()
            observed = {rgb: [] for rgb in colors}
            for y in range(image.get_height()):
                for x in range(image.get_width()):
                    offset = y * stride + x * channels
                    rgb = tuple(data[offset:offset + 3])
                    if rgb in observed:
                        observed[rgb].append((x, y))
            # Bilinear scaling can blend the outer pixel on each swatch.
            bounds = {rgb: (min(x for x, _ in points), min(y for _, y in points),
                            max(x for x, _ in points), max(y for _, y in points))
                      for rgb, points in observed.items() if points}
            if all(rgb in bounds and all(abs(a - b) <= 1 for a, b in zip(bounds[rgb], expected))
                   for rgb, expected in colors.items()):
                return
        time.sleep(0.025)
    raise RuntimeError("GPU drag preview did not appear at the expected size and hotspot")


def run(with_preview):
    script = Path(__file__).resolve()
    bridge = script.parents[3] / "Sources/CRuneDesktopServices"
    gl = bridge.parent / "CRuneGL"
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "sdl2", "gtk+-3.0", "x11", "gl"], text=True))
    def pointer(*args):
        subprocess.run(["xdotool", *args], check=True, timeout=5)

    with tempfile.TemporaryDirectory(prefix="rune-xdnd-") as temp:
        tmp = Path(temp)
        source = tmp / "source"
        subprocess.run([os.environ.get("CC", "clang"), "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-I", str(bridge), "-I", str(bridge / "include"),
                        str(script.with_name("source.c")), str(bridge / "storage.c"),
                        str(bridge / "x11_drag.c"), "-I", str(gl / "include"), str(gl / "window_snapshot.c"),
                        "-o", str(source), *flags], check=True)
        payloads = {
            "text": "Rune é — こんにちは 🦦".encode(),
            "uris": b"file:///tmp/Rune%20one.txt\r\nfile:///tmp/Rune%20two.txt\r\n",
            "png": base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z9DxDwAGDwKGS553kQAAAABJRU5ErkJggg=="),
        }
        for name, data in payloads.items():
            (tmp / name).write_bytes(data)
        for operation, result, gdk_action, mime, name in (
            ("copy", 1, "COPY", "text/plain;charset=utf-8", "text"),
            ("move", 2, "MOVE", "text/uri-list", "uris"),
            ("link", 4, "LINK", "image/png", "png"),
            ("cancel", 0, "COPY", "text/plain;charset=utf-8", "text"),
            ("reject", 0, "COPY", "text/plain;charset=utf-8", "text"),
        ):
            sender_log, receiver_log = tmp / "sender.log", tmp / "receiver.log"
            with receiver_log.open("w") as rx, sender_log.open("w") as tx:
                receiver = subprocess.Popen([sys.executable, str(script), "--receive", gdk_action, mime, operation],
                                            stdout=rx, stderr=subprocess.STDOUT)
                preview = ["--preview"] if with_preview and operation == "copy" else []
                sender = subprocess.Popen([str(source), str(result or 1), str(tmp), *preview],
                                          stdout=tx, stderr=subprocess.STDOUT)
                try:
                    wait_for(receiver, receiver_log, "ready")
                    wait_for(sender, sender_log, "ready")
                    pointer("mousemove", "80", "80", "mousedown", "1", "mousemove", "125", "85")
                    wait_for(sender, sender_log, "started")
                    pointer("mousemove", "350", "75", "mousemove", "400", "90")
                    wait_for(receiver, receiver_log, "offered")
                    if preview:
                        check_icon()
                    if operation == "cancel":
                        pointer("key", "Escape")
                    pointer("mouseup", "1")
                    actual = wait_for(sender, sender_log, "result")
                    if actual != f"result {result}":
                        raise RuntimeError(f"{operation}: source returned {actual!r}; {receiver_log.read_text()}")
                    if operation == "cancel":
                        if "bytes " in receiver_log.read_text():
                            raise RuntimeError("Cancelled drag still delivered its payload")
                    elif wait_for(receiver, receiver_log, "bytes") != "bytes " + payloads[name].hex():
                        raise RuntimeError(f"Wrong payload for {operation}: {receiver_log.read_text()}")
                    # Return from the receiver and click immediately, without a
                    # second motion inside the source to refresh SDL's position.
                    pointer("mousemove", "129", "111", "mousedown", "1", "mouseup", "1")
                    second_press = wait_for(sender, sender_log, "press")
                    if second_press != "press 109 91":
                        raise RuntimeError(f"{operation}: expected second press at 109,91; got {second_press}")
                    sender.wait(timeout=5)
                    if sender.returncode != 0:
                        raise RuntimeError(sender_log.read_text())
                    print(f"{operation} passed ({mime})", flush=True)
                finally:
                    for child in (sender, receiver):
                        child.terminate()
                        try:
                            child.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait()


if __name__ == "__main__":
    if sys.argv[1:2] == ["--receive"]:
        import gi
        gi.require_version("Gdk", "3.0")
        from gi.repository import Gdk
        receive(getattr(Gdk.DragAction, sys.argv[2]), sys.argv[3], sys.argv[4] == "reject")
    elif sys.argv[1:2] == ["--inside-xvfb"]:
        run("--preview" in sys.argv[2:])
    else:
        os.environ.update(SDL_VIDEODRIVER="x11", GDK_BACKEND="x11", NO_AT_BRIDGE="1")
        os.execvp("xvfb-run", ["xvfb-run", "-a", sys.executable, __file__, "--inside-xvfb", *sys.argv[1:]])
