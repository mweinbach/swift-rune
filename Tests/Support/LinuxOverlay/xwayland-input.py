#!/usr/bin/env python3
"""Test native XWayland input at 2x on a private Weston/Xvfb session.
Requires clang, GTK 3, SDL2, libXtst-dev, Weston with XWayland, Xvfb and xauth.
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[3]
if len(sys.argv) == 1:
    with tempfile.TemporaryDirectory(prefix="rune-xwayland-input-") as work:
        exe = str(Path(work) / "probe")
        flags = shlex.split(subprocess.check_output([
            "pkg-config", "--cflags", "--libs", "gtk+-3.0", "sdl2", "egl", "xi",
            "xtst", "xext", "x11", "wayland-client"
        ], text=True))
        subprocess.run(["clang", "-ffunction-sections", "-Wl,--gc-sections", "-Wall", "-Wextra", "-Werror",
                        "-I", "Sources/CRuneLinux/include", "-I", "Sources/CRuneNotify/include", "-I", "Sources/CRuneGPUSelection/include",
                        "Sources/CRuneLinux/LinuxOverlay.c", "Sources/CRuneLinux/RuneLinux.c", "Sources/CRuneGPUSelection/LinuxDevice.c",
                        "Tests/Support/LinuxOverlay/XWaylandInput.c", "-o", exe, *flags, "-lm", "-ldl"],
                       cwd=root, check=True)
        subprocess.run(["xvfb-run", "-a", "-s", "-screen 0 800x600x24", sys.executable,
                        __file__, work, exe], check=True)
else:
    work, exe = sys.argv[1:]
    env = dict(os.environ, XDG_RUNTIME_DIR=work, XDG_CACHE_HOME=work, SDL_VIDEODRIVER="wayland",
               WAYLAND_DISPLAY="rune-test", GDK_SCALE="2", GALLIUM_DRIVER="llvmpipe", LIBGL_ALWAYS_SOFTWARE="1")
    for key in ("GDK_BACKEND", "WAYLAND_SOCKET"):
        env.pop(key, None)
    log = Path(work) / "weston.log"
    compositor = subprocess.Popen(["weston", "--backend=x11", "--renderer=pixman", "--shell=kiosk", "--no-config",
                                   "--socket=rune-test", "--xwayland", f"--log={log}"], env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        until = time.monotonic() + 8
        while time.monotonic() < until and compositor.poll() is None:
            match = re.search(r"(?:X server listening at display|xserver listening on display) (:\d+)",
                              log.read_text() if log.exists() else "", re.I)
            if match:
                subprocess.run([exe], env=dict(env, DISPLAY=match[1]), timeout=20, check=True)
                break
            time.sleep(.05)
        else:
            raise RuntimeError(log.read_text() if log.exists() else "Weston failed to start")
    finally:
        compositor.terminate()
        compositor.wait(timeout=5)
