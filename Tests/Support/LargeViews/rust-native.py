#!/usr/bin/env python3
"""Run the pinned upstream table and tree in normal macOS Rune windows."""
import argparse
import csv
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
REVISION = runpy.run_path(str(HERE / "rust-oracle.py"))["REVISION"]


def definition(source, name):
    """Extract one balanced source definition from the pinned fixture."""
    start = source.index(name)
    brace = source.index("{", start)
    depth = 1
    for end in range(brace + 1, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1] + "\n"
    raise ValueError(f"Incomplete upstream fixture definition {name}")


def driver(checkout, case):
    kit = checkout / "crates/rune-kit"
    source = (kit / f"tests/{case}.rs").read_text()
    if case == "table":
        base = source[:source.index("fn runtime(")]
        initial = "App::new(100_000, true)"
        view = "sized(s, 900., 900.)"
        width, role = 900, "row"
    else:
        base = source[source.index("use rune::runtime"):source.index("fn files(")]
        base += "".join(definition(source, name) for name in ("struct App {", "fn label(", "fn big()", "fn bench_view("))
        initial = "App { files: big(), picked: Vec::new(), opened: Vec::new() }"
        view = "bench_view(s, cx)"
        width, role = 360, "treeitem"
    glue = f"""
fn initial() -> App {{ {initial} }}
fn authored_view(s: &App, cx: &mut Cx<App>) -> El {{ {view} }}
const TITLE: &str = "Rune Rust Large {case}";
const SIZE: (f32, f32) = ({width}., 900.);
const ROW_ROLE: &str = "{role}";
"""
    target = f"scroll_native_{case}"
    (kit / f"examples/{target}.rs").write_text(base + glue + (HERE / "macOS/window.rs").read_text())
    return target


def summarize(path, case):
    data = json.loads(path.read_text())
    expected = [f"f{i}" for i in range(1028, 1060)] if case == "table" else [
        f"pkg{i // 101}" + (f"/file{i % 101 - 1}.rs" if i % 101 else "") for i in range(1200, 1238)
    ]
    visible = data["checkpoints"][-1]["visible"]
    if data["events"] != 600 or [row[0] for row in visible] != expected:
        raise ValueError(f"{case} did not finish at the expected visible rows")
    with path.with_suffix(".csv").open() as stream:
        times = {}
        for row in csv.DictReader(stream):
            step, when = int(row["wheel"]), float(row["presented_seconds"])
            if 1 <= step <= 600 and when > 0:
                times.setdefault(step, when)
    values = sorted(set(times.values()))
    result = {"wheels": 600, "presentedWheels": len(times), "distinctPresentationTimes": len(values),
              "firstVisible": expected[0], "lastVisible": expected[-1]}
    if len(values) == 600:
        result["displayedFPS"] = 599 / (values[-1] - values[0])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rust_checkout", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This native presentation fixture requires macOS and a visible Metal display")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, RUNE_PLAYGROUND="0", RUNE_OPEN_INACTIVE="1")
    target_dir = Path(env.get("CARGO_TARGET_DIR", output / "cargo-target")).resolve()
    env["CARGO_TARGET_DIR"] = str(target_dir)
    with tempfile.TemporaryDirectory(prefix="rune-native-scroll-") as folder:
        tmp = Path(folder)
        checkout = tmp / "rust"
        checkout.mkdir()
        archive = tmp / "source.tar"
        subprocess.run(["git", "-C", args.rust_checkout, "archive", "-o", archive, REVISION], check=True)
        subprocess.run(["tar", "-xf", archive, "-C", checkout], check=True)
        wheel = tmp / "wheel.o"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-c", HERE / "macOS/NativeWheel.m", "-o", wheel], check=True)
        for case in ("table", "tree"):
            target = driver(checkout, case)
            subprocess.run(["cargo", "rustc", "--locked", "--profile", "perf", "-j", str(args.jobs),
                            "-p", "rune-kit", "--example", target, "--", "-C", f"link-arg={wheel}",
                            "-C", "link-arg=-framework", "-C", "link-arg=AppKit",
                            "-C", "link-arg=-framework", "-C", "link-arg=QuartzCore"],
                           cwd=checkout, env=env, check=True)
            path = output / f"{case}.json"
            subprocess.run([target_dir / f"perf/examples/{target}"], cwd=checkout,
                           env={**env, "RUNE_SCROLL_OUTPUT": str(path)}, check=True, timeout=300)
            result = summarize(path, case)
            (output / f"{case}-summary.json").write_text(json.dumps(result, indent=2) + "\n")
            print(case, json.dumps(result))


if __name__ == "__main__":
    main()
