#!/usr/bin/env python3
"""Run the pinned upstream large views in normal macOS Rune windows."""
import argparse
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
from presentations import summarize_presentations

HERE = Path(__file__).resolve().parent
resolve_revision = runpy.run_path(str(HERE / "rust-oracle.py"))["resolve_revision"]


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
        width, row = 900, 'e.role == "row"'
    elif case == "tree":
        base = source[source.index("use rune::runtime"):source.index("fn files(")]
        base += "".join(definition(source, name) for name in ("struct App {", "fn label(", "fn big()", "fn bench_view("))
        initial = "App { files: big(), picked: Vec::new(), opened: Vec::new() }"
        view = "bench_view(s, cx)"
        width, row = 360, 'e.role == "treeitem"'
    else:
        base = ("use rune::runtime::ElementInfo;\nuse rune::{Cx, El, col, el};\n"
                "use rune_kit::Kit;\nuse rune_kit::diff::{Annotation, DiffState, DiffView, FileDiff, LineRange};\n")
        base += source[source.index("struct App {"):source.index("fn on_key(")]
        base += definition(source, "fn numbered(")
        initial = """
    let (old, new) = numbered(50_000, 7);
    let diff = DiffState::new(vec![FileDiff::from_texts("big.rs", &old, &new)]);
    App { diff, selections: Vec::new(), comments: Vec::new(), visible: Vec::new(), actions: Vec::new() }
"""
        view = "view(s, cx)"
        width, row = 1200, 'e.key.as_deref().is_some_and(|key| key.starts_with("df0"))'
    glue = f"""
fn initial() -> App {{ {initial} }}
fn authored_view(s: &App, cx: &mut Cx<App>) -> El {{ {view} }}
fn is_data_row(e: &ElementInfo) -> bool {{ {row} }}
const TITLE: &str = "Rune Rust Large {case}";
const SIZE: (f32, f32) = ({width}., 900.);
const IS_DIFF: bool = {str(case == "diff").lower()};
const WHEEL_DY: f64 = {-400 if case == "diff" else -48}.;
"""
    target = f"scroll_native_{case}"
    (kit / f"examples/{target}.rs").write_text(base + glue + (HERE / "macOS/window.rs").read_text())
    return target


def summarize(path, case):
    data = json.loads(path.read_text())
    if case == "table":
        expected = [f"f{i}" for i in range(1028, 1060)]
    elif case == "tree":
        expected = [f"pkg{i // 101}" + (f"/file{i % 101 - 1}.rs" if i % 101 else "") for i in range(1200, 1238)]
    else:
        expected = []
        for line in range(10502, 10541):
            if line % 7 == 0:
                expected.extend([f"df0.o{line}", f"df0.n{line}"])
            else:
                expected.append(f"df0.c{line}")
        if {report["wheel"] for report in data["reports"]} != set(range(601)):
            raise ValueError("Diff window missed a native wheel step")
        checkpoints = data["checkpoints"]
        if [c["wheel"] for c in checkpoints] != [0, 1, 24, 60, 300, 600] or any(
            c["scrollY"] != 400 * c["wheel"] for c in checkpoints
        ):
            raise ValueError("Diff native wheel events did not reach the expected scroll offsets")
    visible = data["checkpoints"][-1]["visible"]
    if data["events"] != 600 or [row[0] for row in visible] != expected:
        raise ValueError(f"{case} did not finish at the expected visible rows")
    result = summarize_presentations(path.with_suffix(".csv"))
    result.update(firstVisible=expected[0], lastVisible=expected[-1])
    if case == "diff":
        result["finalScrollY"] = data["checkpoints"][-1]["scrollY"]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rust_checkout", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--revision", help="Rust revision to compare (defaults to .upstream-sync.json)")
    parser.add_argument("--case", choices=("table", "tree", "diff"), dest="cases", action="append",
                        help="Window workload to run, repeatable (defaults to table and tree)")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This native presentation fixture requires macOS and a visible Metal display")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    revision = resolve_revision(args.rust_checkout, args.revision)
    env = dict(os.environ, RUNE_PLAYGROUND="0", RUNE_OPEN_INACTIVE="1")
    target_dir = Path(env.get("CARGO_TARGET_DIR", output / "cargo-target")).resolve()
    env["CARGO_TARGET_DIR"] = str(target_dir)
    with tempfile.TemporaryDirectory(prefix="rune-native-scroll-") as folder:
        tmp = Path(folder)
        checkout = tmp / "rust"
        checkout.mkdir()
        archive = tmp / "source.tar"
        subprocess.run(["git", "-C", args.rust_checkout, "archive", "-o", archive, revision], check=True)
        subprocess.run(["tar", "-xf", archive, "-C", checkout], check=True)
        wheel = tmp / "wheel.o"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-c", HERE / "macOS/NativeWheel.m", "-o", wheel], check=True)
        for case in args.cases or ("table", "tree"):
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
            result["rustRevision"] = revision
            (output / f"{case}-summary.json").write_text(json.dumps(result, indent=2) + "\n")
            print(case, json.dumps(result))


if __name__ == "__main__":
    main()
