"""Check the mapped window and post-present resizing through Sway's IPC tree."""

import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time


def wait_for(description, check):
    for _ in range(160):
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for {description}")


def find_window(node):
    if node.get("name") == "Rune float-on-open":
        return node
    for child in node["nodes"] + node["floating_nodes"]:
        match = find_window(child)
        if match:
            return match


def test_window(env, path, mode, scale=1):
    p = subprocess.Popen([path], env=dict(env, RUNE_TEST_FLOAT_IPC=mode),
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        def command(*args):
            return json.loads(subprocess.check_output(["swaymsg", "-r", *args], env=env, timeout=3))

        def window():
            return find_window(command("-t", "get_tree"))

        node = wait_for("the first mapped buffer", window)
        assert select.select([p.stdout], [], [], 5)[0], "Window did not present"
        assert p.stdout.readline().strip() == "presented"
        is_floating = node["type"] == "floating_con"
        assert is_floating == (mode == "floating"), (mode, node["type"])
        if is_floating:
            assert (node["rect"]["width"], node["rect"]["height"]) == (200 // scale, 120 // scale), node["rect"]
            reply = command(f'[con_id={node["id"]}] resize set width 270 px height 150 px')
            assert reply[0]["success"], reply
            wait_for("the compositor-driven resize after first present",
                     lambda: (n := window()) and (n["rect"]["width"], n["rect"]["height"]) == (270, 150))
        print(f"Sway classified {mode} as {node['type']} at {node['rect']}", flush=True)
        output, _ = p.communicate("\n", timeout=5)
        print(output, end="")
        assert p.returncode == 0
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()


def main():
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)
        env = dict(os.environ, XDG_RUNTIME_DIR=temp, WLR_BACKENDS="x11", WLR_RENDERER="pixman",
                   WLR_NO_HARDWARE_CURSORS="1", WLR_LIBINPUT_NO_DEVICES="1")
        env.pop("WAYLAND_DISPLAY", None)
        env.pop("SWAYSOCK", None)
        config = directory / "config"
        config.write_text("xwayland disable\noutput * mode 800x600\ndefault_border none\n"
                          "default_floating_border none\nseat * fallback true\n")
        with (directory / "sway.log").open("w") as log:
            p = subprocess.Popen(["sway", "-c", config], env=env, stdout=log, stderr=log)
            try:
                env["SWAYSOCK"] = str(wait_for("Sway IPC", lambda: next(directory.glob("sway-ipc*.sock"), None)))
                env["WAYLAND_DISPLAY"] = wait_for("Wayland socket", lambda: next(
                    (f.name for f in directory.glob("wayland-*") if f.is_socket()), None))
                env["SDL_VIDEODRIVER"] = "wayland"
                test_window(env, sys.argv[1], "floating")
                test_window(env, sys.argv[1], "tiled")
                subprocess.run(["swaymsg", "output * scale 2"], env=env, check=True, stdout=subprocess.DEVNULL)
                test_window(env, sys.argv[1], "floating", scale=2)
            finally:
                p.terminate()
                p.wait(timeout=5)


if __name__ == "__main__":
    main()
