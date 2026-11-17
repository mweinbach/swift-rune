#!/usr/bin/env python3
"""Run under xvfb-run using the normal rune-hello debug or release executable.

xvfb-run -a python3 Tests/Support/LinuxPacing/run.py .build/debug [results.json]
With libSDL2 headers, clang, ImageMagick, python3-xlib and xdotool installed.
"""
import argparse
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
loader = importlib.util.spec_from_file_location("rune_window", HERE.parents[2] / "scripts/test-linux-window.py")
window = importlib.util.module_from_spec(loader)
loader.loader.exec_module(window)


def swaps(trace):
    return [int(line.split()[1]) for line in trace.read_text().splitlines() if line.startswith("present ")]


def idle(trace):
    deadline = time.monotonic() + 10
    stable_from = time.monotonic()
    previous = []
    while time.monotonic() < deadline:
        current = swaps(trace)
        if current and current == previous and time.monotonic() - stable_from >= 1.0:
            return current
        if current != previous:
            stable_from = time.monotonic()
            previous = current
        time.sleep(0.04)
    raise RuntimeError("The quiet window continued swapping for 10 seconds")


def rest_and_wake(binary, directory, env):
    switch, _ = window.geometry(binary, directory, 320, 200)
    trace = directory / "hello.trace"
    env = dict(env, RUNE_TEST_SWAP_TRACE=str(trace), RUNE_GPU_INFO="1")
    with ExitStack() as stack:
        log = stack.enter_context((directory / "hello.log").open("w+"))
        app = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        stack.callback(window.stop, app)
        wid = window.run("xdotool", "search", "--sync", "--onlyvisible", "--pid", str(app.pid)).decode().splitlines()[0]
        off = window.capture(wid, 320, 200, switch, False, None, "before")
        before = idle(trace)
        clicked_at = time.monotonic_ns()
        window.click(wid, switch)
        on = window.capture(wid, 320, 200, switch, True, None, "after")
        after = idle(trace)
        assert off != on and len(after) > len(before)
        assert after[len(before)] >= clicked_at
        log.flush()
        log.seek(0)
        driver = next(line.strip() for line in log if "Rune GPU:" in line)
        return {"driver": driver, "initialSwaps": len(before), "additionalSwapsAfterInput": len(after) - len(before),
                "firstNewSwapMs": round((after[len(before)] - clicked_at) / 1e6, 3),
                "quietIntervalSecondsEachState": 1.0, "idleSwaps": 0, "pixelsChanged": True,
                "driverInterval": next((line for line in trace.read_text().splitlines() if line.startswith("get_interval ")), None)}


def animation(binary, directory, env, mode, hz):
    trace = directory / f"{mode}-{hz}.trace"
    env = dict(env, RUNE_TEST_SWAP_TRACE=str(trace), RUNE_TEST_SWAP_MODE=mode, RUNE_TEST_DISPLAY_HZ=str(hz))
    native_trace = directory / f"{mode}-{hz}.jsonl"
    subprocess.run([str(binary), "--native", "--trace", str(native_trace), "--frames", "96"], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=30)
    times = swaps(trace)
    interval_reads = [line for line in trace.read_text().splitlines() if line.startswith("get_interval ")]
    expected_interval = f"get_interval {int(mode == 'vsync')}"
    if not interval_reads or any(line != expected_interval for line in interval_reads):
        raise RuntimeError(f"The window did not observe the configured swap interval for {mode} at {hz} Hz")
    if len(times) != 96:
        raise RuntimeError(f"Expected 96 native window swaps for {mode} at {hz} Hz, recorded {len(times)}")
    active = [(b - a) / 1e6 for a, b in zip(times[8:], times[9:])]
    waits = []
    for line in trace.read_text().splitlines():
        if line.startswith("wait "):
            _, stamp, delay = line.split()
            if times[8] < int(stamp) < times[-1]:
                waits.append(int(delay))
    # The host calls SDL_PollEvent directly when the next frame is due. Drivers,
    # compositors and shared CI can all take longer than the requested interval.
    max_wait = max(waits, default=0)
    limit = 0 if mode == "vsync" else (1000 + (hz or 60) - 1) // (hz or 60)
    if max_wait > limit:
        raise RuntimeError(f"{mode} with {hz} Hz requested a {max_wait} ms wait (limit {limit})")
    if mode == "timer" and not waits:
        raise RuntimeError(f"No fallback timer wait was observed at {hz or 60} Hz")
    return {"reportedRefreshHz": hz, "swapIntervalSupported": mode == "vsync", "swaps": len(times),
            "activeIntervals": len(active), "medianActiveIntervalMs": round(statistics.median(active), 3),
            "timerWaitCount": len(waits), "maxRequestedTimerMs": max_wait}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bin", type=Path)
    parser.add_argument("receipt", type=Path, nargs="?")
    args = parser.parse_args()
    directory = args.bin.resolve()
    with tempfile.TemporaryDirectory() as temp:
        tmp = Path(temp)
        lib = tmp / "swaptrace.so"
        subprocess.run(["clang", "-shared", "-fPIC", "-O2", str(HERE / "SwapTrace.c"), "-ldl", "-o", str(lib)], check=True)
        env = dict(os.environ, LD_PRELOAD=str(lib), SDL_VIDEODRIVER="x11", RUNE_PLAYGROUND="0")
        env.pop("RUNE_TEST_SWAP_MODE", None)
        env.pop("RUNE_TEST_DISPLAY_HZ", None)
        reports = {"actualDriver": rest_and_wake(directory / "rune-hello", tmp, env), "simulated": {}}
        for mode, hz in [("vsync", 144), ("timer", 144), ("timer", 0)]:
            reports["simulated"][f"{mode}-{hz}"] = animation(directory / "rune-hello", tmp, env, mode, hz)
        rendered = json.dumps(reports, indent=2)
        if args.receipt:
            args.receipt.write_text(rendered + "\n")
        print(rendered)


if __name__ == "__main__":
    main()
