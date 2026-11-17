#!/usr/bin/env python3
"""Replay Rune's own large-view benchmarks with the same logical clock and native-window color mode."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

def resolve_revision(checkout, requested):
    if requested is None:
        sync = Path(__file__).resolve().parents[3] / ".upstream-sync.json"
        requested = json.loads(sync.read_text())["syncedCommit"]
    return subprocess.check_output(
        ["git", "-C", checkout, "rev-parse", "--verify", "--end-of-options", requested + "^{commit}"],
        text=True,
    ).strip()


def replace_once(source, original, replacement):
    if source.count(original) != 1:
        raise ValueError(f"Expected one occurrence in the upstream benchmark: {original!r}")
    return source.replace(original, replacement)


def prepare(checkout, fixture, width):
    tests = checkout / "crates/rune-kit/tests"
    source = (tests / f"{fixture}.rs").read_text()
    prefix, benchmark = source.split(f"fn {fixture}_time()", 1)
    benchmark = replace_once(benchmark, "rt.frame(0.0);\n        let first = ms(t);",
                             "rt.set_srgb_blend(true);\n        rt.frame(0.0);\n        let first = ms(t);")
    benchmark = replace_once(benchmark, "rt.frame(f as f64 / 120.0);", "rt.frame(1.0 / 120.0);")
    for marker, index in [("let first = ms(t);", 0), ("frames.push(ms(t));", "f")]:
        benchmark = replace_once(benchmark, marker, f'{marker}\n            capture_scroll(&rt, "{fixture}", {index}, {width}, 1800);')
    benchmark = replace_once(benchmark, "for run in 0..3 {",
                             'for run in 0..if std::env::var_os("RUNE_SCROLL_CAPTURE").is_some() { 1 } else { 3 } {')
    helper = Path(__file__).with_name("oracle.rs").read_text()
    (tests / f"scroll_{fixture}.rs").write_text(prefix + f"fn {fixture}_time()" + benchmark + "\n" + helper)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rust_checkout", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--revision", help="Rust revision to compare (defaults to .upstream-sync.json)")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    revision = resolve_revision(args.rust_checkout, args.revision)
    with tempfile.TemporaryDirectory(prefix="rune-scroll-") as temp:
        checkout = Path(temp) / "rust"
        checkout.mkdir()
        archive = Path(temp) / "source.tar"
        subprocess.run(["git", "-C", args.rust_checkout, "archive", "-o", archive, revision], check=True)
        subprocess.run(["tar", "-xf", archive, "-C", checkout], check=True)
        for name, width in [("table", 1800), ("tree", 720)]:
            prepare(checkout, name, width)
        (output / "rust-revision.txt").write_text(revision + "\n")
        env = {k: v for k, v in os.environ.items() if k != "RUNE_SCROLL_CAPTURE"}
        if "CARGO_TARGET_DIR" not in env:
            env["CARGO_TARGET_DIR"] = str(output / "cargo-target")
        cargo = ["cargo", "test", "--locked", "--profile", "perf", "-j", str(args.jobs), "-p", "rune-kit"]
        for name in ("table", "tree"):
            for purpose, target, capture in [("stock", name, False), ("matched", f"scroll_{name}", False),
                                             ("capture", f"scroll_{name}", True)]:
                with (output / f"{name}-{purpose}.log").open("w") as log:
                    settings = {**env, "RUNE_SCROLL_CAPTURE": str(output)} if capture else env
                    subprocess.run(cargo + ["--test", target, "--", "--ignored", "--exact", "--nocapture", f"{name}_time"],
                                   cwd=checkout, env=settings, stdout=log, check=True)


if __name__ == "__main__":
    main()
