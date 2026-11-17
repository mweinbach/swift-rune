#!/usr/bin/env python3
"""Exercise a real Rune Hello window on X11 or nested Wayland.

Run: xvfb-run -a python3 scripts/test-linux-window.py [--wayland [--scale 2]] /path/to/rune-hello [capture-dir]
On a GPU-backed X server, use --wayland --weston-renderer gl to test GPU composition as well.
Requires xdotool, ImageMagick, python3-xlib and, for --wayland, Weston.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack
from pathlib import Path

from Xlib import X, display, protocol


def run(*args, **kwargs):
    return subprocess.check_output(args, timeout=20, **kwargs)


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def weston_window(directory, env, children, scale, renderer):
    env.update(XDG_RUNTIME_DIR=str(directory), WAYLAND_DISPLAY="rune-smoke")
    log = directory / "weston.log"
    weston = subprocess.Popen([
        "weston", "-B", "x11", f"--renderer={renderer}", "--shell=kiosk-shell.so", "--no-config",
        "--width=320", "--height=200", f"--scale={scale}", "--idle-time=0", f"--socket={env['WAYLAND_DISPLAY']}", f"--log={log}"
    ], env=env)
    children.callback(stop, weston)
    deadline = time.monotonic() + 15
    while weston.poll() is None and time.monotonic() < deadline:
        if log.exists() and (directory / env["WAYLAND_DISPLAY"]).is_socket():
            match = re.search(rf"x11 output {320 * scale}x{200 * scale}, window id (\d+)", log.read_text())
            if match:
                return match.group(1)
        time.sleep(0.05)
    raise RuntimeError(log.read_text() if log.exists() else "Weston failed to start")


def geometry(binary, directory, width, height):
    tree = directory / "tree.json"
    run(binary, "--tree", tree, "--size", f"{width}x{height}")
    elements = json.loads(tree.read_text())["elements"]
    x, y, w, h = next(node["rect"] for node in elements if node.get("key") == "switch")
    label = next(node["rect"] for node in elements if node.get("text") == "Lights off")
    return (round(x + h / 2), round(x + w - h / 2), round(y + h / 2)), label


def pixel(rgb, width, x, y):
    index = 3 * (y * width + x)
    return rgb[index:index + 3]


def capture(window, width, height, switch, on, captures, name, background=None):
    left, right, y = switch
    deadline = time.monotonic() + 12
    sampled = None
    while time.monotonic() < deadline:
        frame = run("import", "-silent", "-window", hex(int(window)), "-depth", "8", "rgb:-")
        if len(frame) == width * height * 3:
            a, b = pixel(frame, width, left, y), pixel(frame, width, right, y)
            knob, track = (b, a) if on else (a, b)
            sampled = (tuple(a), tuple(b))
            right_color = track[2] - track[0] > 80 if on else max(track) - min(track) < 15
            # During resize Weston can center the old surface until the client acknowledges the new size.
            corners = ((4, 4), (width - 5, 4), (4, height - 5), (width - 5, height - 5))
            filled = background is None or all(pixel(frame, width, x, y) == background for x, y in corners)
            if min(knob) > 210 and min(track) < 140 and right_color and filled:
                if captures:
                    run("convert", "-size", f"{width}x{height}", "-depth", "8", "rgb:-",
                        captures / f"{name}.png", input=frame)
                return frame
        time.sleep(0.05)
    raise RuntimeError(f"{name}: expected switch at {switch} in {width}x{height}, sampled {sampled}")


def click(window, location):
    run("xdotool", "mousemove", "--window", window, str(location[0]), str(location[2]), "click", "1")
    # A nested compositor includes its cursor in its presented image.
    run("xdotool", "mousemove", "--window", window, "290", "12")


def request_close(window, app):
    connection = display.Display()
    try:
        target = connection.create_resource_object("window", int(window))
        target.send_event(protocol.event.ClientMessage(
            window=target, client_type=connection.intern_atom("WM_PROTOCOLS"),
            data=(32, [connection.intern_atom("WM_DELETE_WINDOW"), X.CurrentTime, 0, 0, 0])))
        connection.flush()
        if app.wait(timeout=5) != 0:
            raise RuntimeError("Application exited unsuccessfully after WM_DELETE_WINDOW")
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wayland", action="store_true")
    parser.add_argument("--scale", type=int, choices=(1, 2), default=1, help="Nested Wayland output scale")
    parser.add_argument("--weston-renderer", choices=("pixman", "gl"), default="pixman")
    parser.add_argument("binary", type=Path)
    parser.add_argument("captures", type=Path, nargs="?")
    args = parser.parse_args()
    scale = args.scale
    if not args.wayland and (scale != 1 or args.weston_renderer != "pixman"):
        parser.error("Output scale and Weston renderer options require --wayland")
    binary = args.binary.resolve()
    if args.captures:
        args.captures.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp, ExitStack() as children:
        directory = Path(tmp)
        original, label = geometry(binary, directory, 320, 200)
        resized, _ = geometry(binary, directory, 480, 320)
        original = tuple(v * scale for v in original)
        resized = tuple(v * scale for v in resized)
        width, height = 320 * scale, 200 * scale
        new_width, new_height = 480 * scale, 320 * scale
        env = dict(os.environ, SDL_VIDEODRIVER="wayland" if args.wayland else "x11",
                   RUNE_GPU_INFO="1", RUNE_PLAYGROUND="0")
        window = weston_window(directory, env, children, scale, args.weston_renderer) if args.wayland else None
        log = children.enter_context((directory / "app.log").open("w+"))
        app = subprocess.Popen([binary], stdout=log, stderr=log, env=env)
        children.callback(stop, app)
        try:
            if window is None:
                window = run("xdotool", "search", "--sync", "--onlyvisible", "--all", "--pid", str(app.pid),
                             "--name", "^Hello$").decode().splitlines()[0]
            off = capture(window, width, height, original, False, args.captures, "off")
            click(window, original)
            on = capture(window, width, height, original, True, args.captures, "on")
            x, y, w, h = (v * scale for v in label)
            label_pixels = [3 * (row * width + col) for row in range(int(y), round(y + h))
                            for col in range(int(x), round(x + w))]
            ink = sum(min(off[i:i + 3]) > 130 for i in label_pixels)
            changed = sum(abs(off[i] - on[i]) > 40 for i in label_pixels)
            if ink < 25 or changed < 10:
                raise RuntimeError(f"Label did not repaint (ink={ink}, changed={changed})")
            run("xdotool", "windowsize", "--sync", window, str(new_width), str(new_height))
            background = pixel(off, width, 4, 4)
            grown = capture(window, new_width, new_height, resized, True, args.captures, "resized", background)
            if pixel(grown, new_width, original[0], original[2]) != background:
                raise RuntimeError("Old switch location still occupied after resize")
            click(window, resized)
            capture(window, new_width, new_height, resized, False, args.captures, "resized-off")
            run("xdotool", "windowfocus", "--sync", window, "key", "space")
            capture(window, new_width, new_height, resized, True, args.captures, "keyboard-on")
            if not args.wayland:
                request_close(window, app)
            log.seek(0)
            if not any(line.startswith("Rune GPU: OpenGL | ") for line in log):
                raise RuntimeError("Rune did not identify an active OpenGL adapter")
            print(f"{env['SDL_VIDEODRIVER']} at {scale}×: switch, text, resize and keyboard passed (label ink={ink}, changed={changed})")
        finally:
            log.seek(0)
            sys.stderr.write(log.read())


if __name__ == "__main__":
    main()
