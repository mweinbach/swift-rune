#!/usr/bin/env python3
"""Drag files and text from the Swift rune-drag-out example into a separate GTK client.

Run python3 scripts/test-linux-drag-out.py [--wayland] /path/to/rune-drag-out.
Requires Xvfb, xdotool and Python's GTK 3 bindings. Wayland also requires Weston.
"""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


def receive():
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, GLib, Gtk
    window = Gtk.Window(title="Rune native drag receiver")
    width, height = (1000, 620) if os.getenv("RUNE_TEST_LARGE_RECEIVER") else (280, 180)
    window.set_default_size(width, height)
    window.set_decorated(False)
    target = Gtk.EventBox()
    target.add(Gtk.Label(label="Native drop target"))
    window.add(target)

    def data_received(widget, context, x, y, selection, info, timestamp):
        data = selection.get_data()
        if data is not None:
            print(json.dumps({"type": selection.get_target().name(), "data": bytes(data).decode("utf-8")}), flush=True)
        Gtk.drag_finish(context, data is not None, False, timestamp)

    def dropped(widget, context, x, y, timestamp):
        target = widget.drag_dest_find_target(context, None)
        if not target:
            return False
        widget.drag_get_data(context, target, timestamp)
        return True

    control = Path(os.environ["RUNE_TEST_DROP_MODE"])
    ready = control.with_suffix(".ready")
    def set_mode():
        if not control.exists():
            return True
        mode = control.read_text()
        if not mode or ready.exists() and ready.read_text() == mode:
            return True
        types = ["text/uri-list"] if mode == "file" else ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain"]
        target.drag_dest_set(Gtk.DestDefaults.MOTION | Gtk.DestDefaults.HIGHLIGHT,
                             [Gtk.TargetEntry.new(t, 0, i) for i, t in enumerate(types)], Gdk.DragAction.COPY)
        ready.write_text(mode)
        return True
    GLib.timeout_add(30, set_mode)
    target.connect("drag-drop", dropped)
    target.connect("drag-data-received", data_received)
    window.connect("destroy", Gtk.main_quit)
    window.show_all()
    Gtk.main()


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def command(*args, **kwargs):
    return subprocess.check_output(args, timeout=20, text=True, **kwargs).strip()


def wait_for(condition, message, processes=(), timeout=12):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return
        for process in processes:
            if process.poll() is not None:
                raise RuntimeError(f"Process exited {process.returncode} while waiting for {message}")
        time.sleep(0.05)
    raise RuntimeError("Timed out waiting for " + message)


WESTON_WIDTH, WESTON_HEIGHT = 1200, 700


def wayland_desktop(directory, env, cleanup):
    runtime_dir = directory / "wayland-runtime"
    runtime_dir.mkdir(mode=0o700)
    env.update(XDG_RUNTIME_DIR=str(runtime_dir), WAYLAND_DISPLAY="rune-drag-test",
               SDL_VIDEODRIVER="wayland", GDK_BACKEND="wayland", RUNE_TEST_LARGE_RECEIVER="1")
    config = directory / "weston.ini"
    config.write_text("[shell]\npanel-position=none\nlocking=false\nanimation=none\nstartup-animation=none\n")
    log = directory / "weston.log"
    weston = subprocess.Popen([
        "weston", "-B", "x11", "--renderer=pixman", "--shell=desktop-shell.so",
        "--debug", "--idle-time=0", "--config", str(config), "--socket", env["WAYLAND_DISPLAY"],
        f"--width={WESTON_WIDTH}", f"--height={WESTON_HEIGHT}", "--log", str(log),
    ], env=env)
    cleanup.callback(stop, weston)
    wait_for(lambda: (runtime_dir / env["WAYLAND_DISPLAY"]).is_socket() and
             log.exists() and re.search(r"x11 output \d+x\d+, window id (\d+)", log.read_text()),
             "nested Weston output", [weston])
    output = re.search(r"x11 output \d+x\d+, window id (\d+)", log.read_text()).group(1)
    command("xdotool", "windowmove", output, "0", "0")

    def bounds(pid):
        # The top-level surface origin is the SDL content origin, including on libdecor.
        pattern = re.compile(rf"View \d+ \(role xdg_toplevel, PID {pid},[^\n]*\):\s*"
                             r"position: \((-?\d+), (-?\d+)\) -> \((-?\d+), (-?\d+)\)")
        rectangle = {}
        last_change = 0

        def mapped():
            nonlocal last_change
            match = pattern.search(command("weston-debug", "scene-graph", env=env))
            if match:
                x, y, right, bottom = map(int, match.groups())
                current = dict(X=x, Y=y, WIDTH=right - x, HEIGHT=bottom - y)
                if current != rectangle:
                    rectangle.update(current)
                    last_change = time.monotonic()
                return right > x and bottom > y and time.monotonic() - last_change > 0.8
            rectangle.clear()
            return False

        wait_for(mapped, f"Wayland top-level for PID {pid}", [weston], timeout=45)
        return rectangle

    return bounds


def wayland_drop_point(source, dest):
    # The native receiver is behind Rune. Choose an exposed part of its window.
    left = max(0, dest["X"]) + 10
    right = min(WESTON_WIDTH, dest["X"] + dest["WIDTH"]) - 10
    top = max(0, dest["Y"]) + 10
    bottom = min(WESTON_HEIGHT, dest["Y"] + dest["HEIGHT"]) - 10
    free = [
        (left, top, min(right, source["X"] - 12), bottom),
        (max(left, source["X"] + source["WIDTH"] + 12), top, right, bottom),
        (left, top, right, min(bottom, source["Y"] - 32)),
        (left, max(top, source["Y"] + source["HEIGHT"] + 12), right, bottom),
    ]
    choices = [(x, y, r, b) for x, y, r, b in free if r > x and b > y]
    if not choices:
        raise RuntimeError(f"Wayland drag target is obscured: source={source}, receiver={dest}")
    x, y, r, b = max(choices, key=lambda area: (area[2] - area[0]) * (area[3] - area[1]))
    return (x + r) // 2, (y + b) // 2


def drag(from_point, to_point, cancel=False):
    def move(point):
        command("xdotool", "mousemove", str(point[0]), str(point[1]))

    x, y = from_point
    move((x, y))
    command("xdotool", "mousedown", "1")
    try:
        time.sleep(0.10)
        move((x + 12, y))
        time.sleep(0.25)
        for i in range(1, 13):
            move((x + 12 + round((to_point[0] - x - 12) * i / 12), y + round((to_point[1] - y) * i / 12)))
            time.sleep(0.022)
        time.sleep(0.20)
        if cancel:
            command("xdotool", "key", "Escape")
            time.sleep(0.12)
    finally:
        command("xdotool", "mouseup", "1")


def test(binary, wayland):
    with tempfile.TemporaryDirectory(prefix="rune-drag-") as tmp, ExitStack() as cleanup:
        tmp = Path(tmp)
        app_file = tmp / "Rune app Å 漢字.desktop"
        app_file.touch()
        driver = "wayland" if wayland else "x11"
        env = dict(os.environ, TMPDIR=str(tmp), SDL_VIDEODRIVER=driver, GDK_BACKEND=driver,
                   DRAG_OUT_APP=str(app_file), RUNE_GPU_INFO="1", RUNE_PLAYGROUND="0",
                   RUNE_TEST_DROP_MODE=str(tmp/"drop-mode"))
        if wayland:
            bounds = wayland_desktop(tmp, env, cleanup)
        target_log = tmp / "target.jsonl"
        app_log = tmp / "app.log"
        out = cleanup.enter_context(app_log.open("w"))
        rec = cleanup.enter_context(target_log.open("w"))
        receiver = subprocess.Popen([sys.executable, __file__, "--receive"], env=env, stdout=rec)
        cleanup.callback(stop, receiver)
        if wayland:
            dest = bounds(receiver.pid)
        app = subprocess.Popen(["stdbuf", "-oL", str(binary)], env=env, stdout=out, stderr=out)
        cleanup.callback(stop, app)
        try:
            if wayland:
                source = bounds(app.pid)
            else:
                wx = command("xdotool", "search", "--sync", "--onlyvisible", "--pid", str(app.pid), "--name", "^Drag Out$").splitlines()[0]
                gx = command("xdotool", "search", "--sync", "--onlyvisible", "--name", "^Rune native drag receiver$").splitlines()[0]
                command("xdotool", "windowmove", "--sync", wx, "20", "40")
                command("xdotool", "windowmove", "--sync", gx, "620", "40")
                command("xdotool", "windowfocus", "--sync", wx)
                def geometry(window):
                    return {key: int(value) for key, value in
                            (line.split("=") for line in command("xdotool", "getwindowgeometry", "--shell", window).splitlines())}
                source = geometry(wx)
                dest = geometry(gx)
            tree = tmp / "tree.json"
            command(binary, "--tree", tree, "--size", f"{source['WIDTH']}x{source['HEIGHT']}", env=env)
            if wayland:
                current = bounds(app.pid)
                if current != source:
                    source = current
                    command(binary, "--tree", tree, "--size", f"{source['WIDTH']}x{source['HEIGHT']}", env=env)
            nodes = json.loads(tree.read_text())["elements"]
            def tile(key):
                x, y, w, h = next(node["rect"] for node in nodes if node.get("key") == key)
                return source["X"] + round(x + w / 2), source["Y"] + round(y + h / 2)
            drop_point = wayland_drop_point(source, dest) if wayland else (
                dest["X"] + dest["WIDTH"] // 2, dest["Y"] + dest["HEIGHT"] // 2)
            text_file = tmp / "Dragged out of Rune.txt"
            cases = [
                ("file", True, text_file.as_uri(), "copied"),
                ("text", False, "Hello from Rune", "copied"),
                ("app", False, str(app_file), "copied"),
                ("text", False, None, "cancelled"),
                ("file", True, text_file.as_uri(), "copied"),
            ]
            results = []
            received = 0
            for key, wants_file, expected, outcome in cases:
                cancelled = expected is None
                # Weston 13 owns the drag's keyboard grab. Its native cancellation
                # path is a release over a receiver that refuses this MIME type.
                mode = "file" if wants_file or (wayland and cancelled) else "text"
                control = Path(env["RUNE_TEST_DROP_MODE"])
                control.write_text(mode)
                ready = control.with_suffix(".ready")
                wait_for(lambda: ready.exists() and ready.read_text() == mode, "GTK target format", [receiver])
                drag(tile(key), drop_point, cancel=cancelled and not wayland)
                status = f"drag-end {key} {outcome}"
                results.append(status)
                def observed():
                    return [line for line in app_log.read_text().splitlines() if line.startswith("drag-end ")]
                wait_for(lambda: observed() == results, status, [app, receiver])
                if expected is not None:
                    wait_for(lambda: len(target_log.read_text().splitlines()) > received, expected, [app, receiver])
                    payload = json.loads(target_log.read_text().splitlines()[received])
                    received += 1
                    if wants_file:
                        assert payload["type"] == "text/uri-list", payload
                    else:
                        assert payload["type"] in ("text/plain;charset=utf-8", "UTF8_STRING", "text/plain"), payload
                    assert payload["data"].rstrip("\r\n\x00") == expected, payload
            time.sleep(0.25)
            assert observed() == results, f"Duplicate or missing end callbacks: {observed()}"
            assert len(target_log.read_text().splitlines()) == received, "The receiver accepted a cancelled drag"
            cancellation = "refused drop" if wayland else "Escape"
            print(f"{driver}: Rune → GTK verified URI list, text, Unicode file path as text, and {cancellation} with one callback per drag")
        except BaseException:
            print(app_log.read_text(), target_log.read_text(), file=sys.stderr)
            raise


if __name__ == "__main__":
    if sys.argv[1:] == ["--receive"]:
        receive()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("binary", type=Path)
        parser.add_argument("--wayland", action="store_true")
        parser.add_argument("--private-display", action="store_true", help=argparse.SUPPRESS)
        arguments = parser.parse_args()
        if arguments.private_display:
            test(arguments.binary.resolve(), arguments.wayland)
        else:
            options = ["--wayland"] if arguments.wayland else []
            subprocess.run(["dbus-run-session", "--", "xvfb-run", "-a", "-s", "-screen 0 1500x900x24",
                            sys.executable, __file__, str(arguments.binary.resolve()), "--private-display", *options], check=True)
