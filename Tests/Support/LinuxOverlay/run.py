#!/usr/bin/env python3
"""Exercise the public Rune floating overlay under isolated X11, Sway and Weston sessions.

Build with swift build --package-path Tests/Support/LinuxOverlay. Run as a non-root
user: python3 Tests/Support/LinuxOverlay/run.py {x11,sway,weston} /path/to/OverlayProbe
[captures]. Requires Xvfb, xauth, xdotool, xcompmgr, python3-pil, python3-pyatspi, python3-xlib, ImageMagick,
libgtk-layer-shell0, Sway/swaymsg and grim for wlroots, and Weston for the
missing-protocol check.
"""
import argparse
from contextlib import ExitStack
from io import BytesIO
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from PIL import Image


def wait(description, predicate, timeout=12):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(0.06)
    raise RuntimeError(f"Timed out waiting for {description}")


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def test(args, directory, runtime):
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), RUNE_GPU_INFO="1",
               RUNE_PLAYGROUND="0", SDL_AUDIODRIVER="dummy", GALLIUM_DRIVER="llvmpipe",
               LIBGL_ALWAYS_SOFTWARE="1", XDG_CACHE_HOME=str(runtime))
    env.pop("NO_AT_BRIDGE", None)
    # Set DISPLAY only via this invocation's Xvfb. The native Wayland app receives
    # just the isolated socket, even if the shell running the test uses XWayland.
    for key in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "SWAYSOCK", "I3SOCK"):
        env.pop(key, None)

    def run(*args):
        return subprocess.check_output(args, env=env, timeout=4)

    with ExitStack() as children:
        def launch(name, args, child_env=env):
            log = children.enter_context((directory / f"{name}.log").open("wb"))
            proc = subprocess.Popen(args, env=child_env, stdin=subprocess.PIPE, stdout=log, stderr=log)
            children.callback(stop, proc)
            return proc

        if args.backend == "x11":
            env.update(SDL_VIDEODRIVER="x11", GDK_BACKEND="x11", XDG_SESSION_TYPE="x11")
            launch("xcompmgr", ["xcompmgr", "-n"])
        else:
            if args.backend == "sway":
                config = directory / "sway.conf"
                config.write_text("xwayland disable\noutput * mode 800x600\n"
                                  "default_border none\nseat * fallback true\n")
                launch("sway", ["sway", "-c", config],
                       dict(env, WLR_BACKENDS="x11", WLR_RENDERER="pixman",
                            WLR_NO_HARDWARE_CURSORS="1", WLR_LIBINPUT_NO_DEVICES="1"))
                env["SWAYSOCK"] = str(wait("private Sway IPC", lambda:
                    next((p for p in runtime.glob("sway-ipc*.sock") if p.is_socket()), None)))
            else:
                launch("weston", ["weston", "-B", "x11", "--renderer=pixman", "--no-config",
                                  "--width=800", "--height=600", "--idle-time=0"])
            socket = wait("private compositor", lambda:
                next((p for p in runtime.glob("wayland-*") if p.is_socket()), None))
            env.update(SDL_VIDEODRIVER="wayland", GDK_BACKEND="wayland",
                       WAYLAND_DISPLAY=socket.name, XDG_SESSION_TYPE="wayland")

        client_env = dict(env)
        if args.backend != "x11":
            client_env.pop("DISPLAY", None)
            client_env["WAYLAND_DEBUG"] = "client"
        app = launch("probe", [args.binary], client_env)
        log = directory / "probe.log"

        def lines():
            if app.poll() is not None:
                raise RuntimeError(f"Probe exited {app.returncode}: {log.read_text(errors='replace')}")
            return log.read_text(errors="replace").splitlines()

        def send_command(command):
            previous = lines().count("command " + command)
            app.stdin.write((command + "\n").encode())
            app.stdin.flush()
            wait(command, lambda: lines().count("command " + command) > previous)

        def snapshot():
            if args.backend == "sway":
                data = run("grim", "-")
            else:
                data = run("import", "-silent", "-window", "root", "png:-")
            return Image.open(BytesIO(data)).convert("RGB")

        def set_input(mode):
            previous = len(lines())
            send_command(mode)
            # A public setter queues native work. Wait for the host's input region
            # before issuing the pointer event from a second client.
            if args.backend == "sway":
                def committed():
                    surface = None
                    for line in lines()[previous:]:
                        if ".set_input_region(" in line and (mode != "all" or "(nil)" in line):
                            surface = line.partition(".set_input_region(")[0].split()[-1]
                        elif surface and surface + ".commit()" in line:
                            return True
                    return False
                wait(mode + " input region commit", committed)
                snapshot()
            else:
                from Xlib import display
                from Xlib.ext import shape
                connection = display.Display(env["DISPLAY"])
                try:
                    xid = int(run("xdotool", "search", "--onlyvisible", "--name", "^Rune overlay probe$").splitlines()[0])
                    window = connection.create_resource_object("window", xid)
                    wait(mode + " X Shape input region", lambda:
                        bool(window.shape_get_rectangles(shape.SK.Input).rectangles) == (mode == "all"))
                finally:
                    connection.close()

        def click(x, y):
            if args.backend == "sway":
                run("swaymsg", "-s", env["SWAYSOCK"], f"seat seat0 cursor set {x} {y}")
                run("swaymsg", "-s", env["SWAYSOCK"], "seat seat0 cursor press button1")
                run("swaymsg", "-s", env["SWAYSOCK"], "seat seat0 cursor release button1")
            else:
                run("xdotool", "mousemove", str(x), str(y), "click", "1")

        def assert_color(label, xy, rgb):
            def match():
                if app.poll() is not None:
                    raise RuntimeError(f"Probe exited {app.returncode} during {label}. See {log}")
                frame = snapshot()
                px = frame.getpixel(xy)
                return frame if max(abs(a - b) for a, b in zip(px, rgb)) < 6 else None
            try:
                result = wait(label, match)
            except RuntimeError:
                snapshot().save(directory / (label + "-failed.png"))
                raise
            result.save(directory / (label + ".png"))
            return result

        if args.backend == "weston":
            send_command("create")
            def rejected():
                send_command("status")
                return any(line.startswith("status unavailable ") and "zwlr_layer_shell_v1" in line
                           for line in lines())
            wait("unsupported native layer-shell", rejected)
            assert not any(".get_layer_surface(" in line for line in lines())
        else:
            blue, green, magenta = (0, 0, 255), (0, 255, 0), (255, 0, 255)
            width, height = assert_color("underlay", (400, 86), blue).size
            hit = (width // 2, 36 + 50)
            # A compositor using software cursors can include the cursor in grim's image.
            sample = (hit[0] - 16, hit[1])
            empty = (width // 2 - 72, 36 + 50)
            send_command("prewarm")
            wait("hidden custom GPU pass", lambda: "hidden-pass OpenGL 180x100" in lines())
            assert_color("prewarm-hidden", sample, blue)
            send_command("status")
            assert [line for line in lines() if line.startswith("frame ")][-1].split()[-1] == "0"
            send_command("release")
            click(*hit)
            wait("underlay input", lambda: "underlay-click 1" in lines())
            send_command("create")
            assert_color("regions-off", sample, green)
            wait("visible custom GPU pass", lambda: "shown-pass OpenGL 180x100" in lines())
            send_command("status")
            stats = [line.split() for line in lines() if line.startswith("frame ")][-1]
            assert stats[1:3] == ["180", "100"] and int(stats[3]) > 0
            expected_surface = "Wayland layer-shell" if args.backend == "sway" else "X11"
            assert any(line.startswith(f"status available {expected_surface} OpenGL") for line in lines())
            assert any(line.startswith("created ") for line in lines())
            if args.backend == "sway":
                assert any("zwlr_layer_shell_v1" in line and ".get_layer_surface(" in line for line in lines())
            assert_color("through-transparent", empty, blue)
            click(*empty)
            wait("underlay click in transparent region", lambda: "underlay-click 2" in lines())
            click(*hit)
            wait("overlay click", lambda: "overlay-click 1" in lines())
            assert_color("regions-on", sample, magenta)
            wait("Linux popup result", lambda: "popup-answered true" in lines())
            set_input("none")
            click(*hit)
            wait("passthrough over visible control", lambda: "underlay-click 3" in lines())
            assert_color("noninteractive-visible", sample, magenta)
            set_input("all")
            click(*empty)
            click(*hit)
            wait("positive all-mode hit", lambda: "overlay-click 2" in lines())
            assert "underlay-click 4" not in lines(), "all-mode transparent padding passed a click"
            send_command("bottom")
            bottom = (width // 2, height - 28 - 50)
            bottom_sample = (bottom[0] - 16, bottom[1])
            assert_color("moved", bottom_sample, green)
            assert_color("old-position-clear", sample, blue)
            creation_count = sum(line.startswith("created ") for line in lines())
            send_command("hide")
            assert_color("hidden", bottom_sample, blue)
            click(*bottom)
            wait("hidden input recovery", lambda: "underlay-click 4" in lines())
            send_command("show")
            assert_color("restored", bottom_sample, green)
            restored_count = sum(line.startswith("created ") for line in lines())
            assert restored_count == creation_count + (args.backend == "sway"), "unexpected native host recreation"
            import pyatspi
            from gi.repository import GLib
            desktop = pyatspi.Registry.getDesktop(0)

            def find_control():
                context = GLib.MainContext.default()
                while context.pending():
                    context.iteration(False)
                return pyatspi.findDescendant(desktop, lambda obj:
                    obj.name == "Overlay toggle" and obj.getRole() == pyatspi.ROLE_PUSH_BUTTON)

            toggle = wait("AT-SPI overlay button", find_control)
            action = toggle.queryAction()
            assert action.nActions >= 1 and action.doAction(0), "AT-SPI press was rejected"
            wait("AT-SPI dispatch to Rune", lambda: "overlay-click 3" in lines())
            assert_color("assistive-press", bottom_sample, magenta)
            # Feed real pointer motion into the private display. On Sway this
            # goes through its nested X11 input backend and reaches Rune on Wayland.
            run("xdotool", "mousemove", *map(str, bottom), "mousedown", "1")
            wait("drag press", lambda: "drag-press" in lines())
            run("xdotool", "mousemove", str(bottom[0]+20), str(bottom[1]))
            wait("Linux drag result", lambda: "drag-answered true" in lines())
            run("xdotool", "mouseup", "1")
            send_command("release")
            assert_color("released", bottom_sample, blue)
            wait("AT-SPI overlay removal", lambda: not find_control())
            click(*bottom)
            wait("released input recovery", lambda: "underlay-click 5" in lines())

        app.stdin.write(b"quit\n")
        app.stdin.flush()
        assert app.wait(timeout=5) == 0
        print(f"{args.backend} native overlay passed. Evidence in {directory}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("backend", choices=["x11", "sway", "weston"])
    parser.add_argument("binary", type=lambda p: str(Path(p).resolve()))
    parser.add_argument("captures", nargs="?", type=Path)
    parser.add_argument("--private-display", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not args.private_display:
        if os.geteuid() == 0 and args.backend == "sway":
            parser.error("Run the private Sway session as an unprivileged user.")
        env = {k: v for k, v in os.environ.items() if k not in (
            "DISPLAY", "WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DBUS_SESSION_BUS_ADDRESS", "SWAYSOCK", "I3SOCK")}
        with tempfile.TemporaryDirectory(prefix="rune-overlay-x-") as tmp:
            env.update(XDG_CACHE_HOME=tmp, XDG_CONFIG_HOME=tmp)
            authority = Path(tmp) / "Xauthority"
            authority.touch(mode=0o600)
            sys.exit(subprocess.call([
                "dbus-run-session", "--", "xvfb-run", "-a", "-f", authority,
                "-s", "-screen 0 800x600x24 +extension GLX +extension Composite",
                sys.executable, __file__, "--private-display", *sys.argv[1:]
            ], env=env))
    with tempfile.TemporaryDirectory(prefix="rune-overlay-wl-") as runtime:
        if args.captures:
            args.captures.mkdir(parents=True, exist_ok=True)
            test(args, args.captures.resolve(), Path(runtime))
        else:
            with tempfile.TemporaryDirectory() as tmp:
                test(args, Path(tmp), Path(runtime))
