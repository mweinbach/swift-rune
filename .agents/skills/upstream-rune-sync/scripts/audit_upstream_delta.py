#!/usr/bin/env python3
"""Audit upstream anomalyco/rune changes and map them to swift-rune targets."""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from collections import defaultdict


RUST_PUB_RE = re.compile(
    r"^[+-]\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:const\s+)?"
    r"(fn|struct|enum|trait|type|mod|const|static)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
RUST_STRICT_PUB_RE = re.compile(
    r"^[+-]\s*pub(?:\([^)]*\))?\s+(?:async\s+)?(?:unsafe\s+)?(?:const\s+)?"
    r"(fn|struct|enum|trait|type|mod)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
WGSL_ENTRY_RE = re.compile(
    r"^[+-]\s*(?:@(vertex|fragment|compute)[^\n]*\s*)?fn\s+([A-Za-z_][A-Za-z0-9_]*)"
)


def run_git(repo: str, args: list[str]) -> str:
    res = subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if res.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {res.stderr.strip()}")
    return res.stdout


def load_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def build_lookup(umap: dict):
    """Build prefix/file lookup tables from upstream-map.json."""
    file_to_entry = {}
    crate_entries = []
    for entry in umap.get("crates", []) + umap.get("themes", []):
        up_prefix = entry["upstreamPath"].rstrip("/") + "/"
        crate_entries.append((up_prefix, entry))
        for m in entry.get("moduleMappings", []):
            full_up = up_prefix + m["upstream"]
            file_to_entry[full_up] = (entry, m["swift"])

    example_entries = {}
    for ex in umap.get("examples", []):
        example_entries[ex["upstreamPath"].rstrip("/")] = ex

    return file_to_entry, crate_entries, example_entries


def scan_unmapped(upstream: str, swift_root: str, umap: dict, crate_filter: str | None):
    file_to_entry, crate_entries, example_entries = build_lookup(umap)
    known_crate_paths = {e["upstreamPath"].rstrip("/") for _, e in crate_entries}

    unmapped_crates = []
    unmapped_files = []
    missing_swift_paths = set()

    crates_dir = os.path.join(upstream, "crates")
    if os.path.isdir(crates_dir):
        for name in sorted(os.listdir(crates_dir)):
            rel_crate = f"crates/{name}"
            if crate_filter and crate_filter not in (name, rel_crate):
                continue
            full_crate = os.path.join(crates_dir, name)
            if not os.path.isdir(full_crate):
                continue
            if rel_crate not in known_crate_paths:
                unmapped_crates.append(rel_crate)
                continue
            src_dir = os.path.join(full_crate, "src")
            if os.path.isdir(src_dir):
                for p in sorted(glob.glob(src_dir + "/**/*", recursive=True)):
                    if os.path.isfile(p) and p.endswith((".rs", ".wgsl")):
                        rel_file = os.path.relpath(p, upstream)
                        if rel_file not in file_to_entry:
                            unmapped_files.append(rel_file)

    themes_dir = os.path.join(upstream, "themes")
    if os.path.isdir(themes_dir) and not crate_filter:
        for name in sorted(os.listdir(themes_dir)):
            rel_theme = f"themes/{name}"
            full_theme = os.path.join(themes_dir, name)
            if not os.path.isdir(full_theme):
                continue
            if rel_theme not in known_crate_paths:
                unmapped_crates.append(rel_theme)
                continue
            src_dir = os.path.join(full_theme, "src")
            if os.path.isdir(src_dir):
                for p in sorted(glob.glob(src_dir + "/**/*", recursive=True)):
                    if os.path.isfile(p) and p.endswith((".rs", ".wgsl")):
                        rel_file = os.path.relpath(p, upstream)
                        if rel_file not in file_to_entry:
                            unmapped_files.append(rel_file)

    unmapped_examples = []
    examples_dir = os.path.join(upstream, "examples")
    if os.path.isdir(examples_dir) and not crate_filter:
        for name in sorted(os.listdir(examples_dir)):
            rel_ex = f"examples/{name}"
            if os.path.isdir(os.path.join(examples_dir, name)) and rel_ex not in example_entries:
                unmapped_examples.append(rel_ex)

    for entry in umap.get("crates", []) + umap.get("themes", []):
        if crate_filter and crate_filter not in (
            entry["upstreamPath"],
            os.path.basename(entry["upstreamPath"]),
            entry["swiftTarget"],
        ):
            continue
        for m in entry.get("moduleMappings", []):
            for sw in m.get("swift", []):
                if not os.path.exists(os.path.join(swift_root, sw)):
                    missing_swift_paths.add(sw)

    return {
        "unmappedCrates": unmapped_crates,
        "unmappedFiles": unmapped_files,
        "unmappedExamples": unmapped_examples,
        "missingSwiftPaths": sorted(missing_swift_paths),
    }


def extract_symbols(upstream: str, since: str, to_ref: str, files: list[str]) -> dict[str, list[dict]]:
    if not files:
        return {}
    diff_text = run_git(upstream, ["diff", "--unified=0", f"{since}..{to_ref}", "--", *files])
    symbols_by_file: dict[str, list[dict]] = defaultdict(list)
    current_file = None
    seen = set()

    for line in diff_text.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
            continue
        if current_file is None:
            continue
        if line.startswith(("+++", "---", "@@")):
            continue
        if not line.startswith(("+", "-")):
            continue

        change = "added" if line.startswith("+") else "removed"
        if current_file.endswith(".wgsl"):
            m = WGSL_ENTRY_RE.match(line)
            if m:
                kind = f"wgsl:{m.group(1) or 'fn'}"
                name = m.group(2)
                key = (current_file, change, kind, name)
                if key not in seen:
                    seen.add(key)
                    symbols_by_file[current_file].append(
                        {"change": change, "kind": kind, "name": name}
                    )
        else:
            m = RUST_STRICT_PUB_RE.match(line)
            if m:
                kind, name = m.group(1), m.group(2)
                key = (current_file, change, kind, name)
                if key not in seen:
                    seen.add(key)
                    symbols_by_file[current_file].append(
                        {"change": change, "kind": kind, "name": name}
                    )
    return dict(symbols_by_file)


def map_changed_file(rel_path: str, file_to_entry, crate_entries, example_entries):
    if rel_path in file_to_entry:
        entry, swift_files = file_to_entry[rel_path]
        return {
            "swiftTarget": entry["swiftTarget"],
            "testTarget": entry.get("testTarget", ""),
            "swiftFiles": swift_files,
            "mapped": True,
        }
    for prefix, entry in crate_entries:
        if rel_path.startswith(prefix):
            return {
                "swiftTarget": entry["swiftTarget"],
                "testTarget": entry.get("testTarget", ""),
                "swiftFiles": [entry["swiftPath"]],
                "mapped": False,
            }
    for ex_prefix, ex in example_entries.items():
        if rel_path.startswith(ex_prefix + "/") or rel_path == ex_prefix:
            return {
                "swiftTarget": ex["swiftTarget"],
                "testTarget": "",
                "swiftFiles": [ex["swiftPath"]],
                "mapped": True,
            }
    return {
        "swiftTarget": "(unmapped)",
        "testTarget": "",
        "swiftFiles": [],
        "mapped": False,
    }


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_map = os.path.abspath(os.path.join(script_dir, "..", "references", "upstream-map.json"))
    default_swift_root = os.path.abspath(os.path.join(script_dir, "..", "..", "..", ".."))

    parser = argparse.ArgumentParser(description="Audit upstream anomalyco/rune delta vs swift-rune.")
    parser.add_argument("--upstream", required=True, help="Path to upstream anomalyco/rune git clone")
    parser.add_argument("--since", help="Base commit SHA (defaults to syncedCommit in .upstream-sync.json)")
    parser.add_argument("--to", default="HEAD", help="Target git ref (default: HEAD)")
    parser.add_argument("--crate", help="Filter to a specific crate or Swift target")
    parser.add_argument("--symbols", action="store_true", help="Extract added/removed Rust pub & WGSL symbols")
    parser.add_argument("--json", action="store_true", help="Output machine-readable JSON")
    parser.add_argument("--map", default=default_map, help="Path to upstream-map.json")
    parser.add_argument("--swift-root", default=default_swift_root, help="Path to swift-rune repo root")
    args = parser.parse_args()

    umap = load_json(args.map)
    sync_file = os.path.join(args.swift_root, ".upstream-sync.json")
    since = args.since
    if not since and os.path.exists(sync_file):
        since = load_json(sync_file).get("syncedCommit")

    head_sha = run_git(args.upstream, ["rev-parse", args.to]).strip()
    unmapped_report = scan_unmapped(args.upstream, args.swift_root, umap, args.crate)

    file_to_entry, crate_entries, example_entries = build_lookup(umap)

    commits = []
    changed_files = []
    symbols_by_file = {}
    checklist_by_target: dict[str, dict] = {}

    if since:
        log_out = run_git(args.upstream, ["log", "--oneline", f"{since}..{args.to}"]).strip()
        if log_out:
            commits = log_out.splitlines()
        diff_status = run_git(args.upstream, ["diff", "--name-status", f"{since}..{args.to}"]).strip()
        for line in diff_status.splitlines():
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            status = parts[0]
            rel_path = parts[-1]
            if args.crate and args.crate not in rel_path:
                continue
            info = map_changed_file(rel_path, file_to_entry, crate_entries, example_entries)
            changed_files.append({"status": status, "upstream": rel_path, **info})
            target = info["swiftTarget"]
            bucket = checklist_by_target.setdefault(
                target,
                {
                    "swiftTarget": target,
                    "testTarget": info["testTarget"],
                    "upstreamFiles": [],
                    "swiftFiles": set(),
                },
            )
            bucket["upstreamFiles"].append({"status": status, "path": rel_path})
            for sf in info["swiftFiles"]:
                bucket["swiftFiles"].add(sf)

        if args.symbols and changed_files:
            code_files = [
                c["upstream"] for c in changed_files if c["upstream"].endswith((".rs", ".wgsl"))
            ]
            symbols_by_file = extract_symbols(args.upstream, since, args.to, code_files)

    checklist = []
    for target, data in sorted(checklist_by_target.items()):
        test_cmd = (
            f"xcrun swift test --filter {data['testTarget']}"
            if data["testTarget"]
            else "(build/run executable target)"
        )
        checklist.append(
            {
                "swiftTarget": target,
                "testTarget": data["testTarget"],
                "testCommand": test_cmd,
                "swiftFiles": sorted(data["swiftFiles"]),
                "upstreamFiles": data["upstreamFiles"],
            }
        )

    result = {
        "upstream": args.upstream,
        "since": since,
        "to": head_sha,
        "commitsAhead": len(commits),
        "commits": commits,
        "mappingAudit": unmapped_report,
        "changedFiles": changed_files,
        "symbols": symbols_by_file,
        "portingChecklist": checklist,
    }

    if args.json:
        print(json.dumps(result, indent=2))
        return

    print("=== Upstream Parity & Delta Audit ===")
    print(f"Upstream : {args.upstream}")
    print(f"Range    : {since or '(none)'} .. {head_sha}")
    print(f"Commits  : {len(commits)}")
    print("")
    print("--- Mapping Coverage ---")
    print(f"Unmapped crates/themes : {len(unmapped_report['unmappedCrates'])}")
    for c in unmapped_report["unmappedCrates"]:
        print(f"  - {c}")
    print(f"Unmapped src files     : {len(unmapped_report['unmappedFiles'])}")
    for f in unmapped_report["unmappedFiles"][:30]:
        print(f"  - {f}")
    print(f"Unmapped examples      : {len(unmapped_report['unmappedExamples'])}")
    for ex in unmapped_report["unmappedExamples"]:
        print(f"  - {ex}")
    print(f"Missing Swift paths    : {len(unmapped_report['missingSwiftPaths'])}")
    for mp in unmapped_report["missingSwiftPaths"]:
        print(f"  - {mp}")

    if commits:
        print("")
        print("--- Commits ---")
        for c in commits[:30]:
            print(f"  {c}")

    if checklist:
        print("")
        print("--- Per-Target Swift Porting Checklist ---")
        for item in checklist:
            print(f"[{item['swiftTarget']}] -> {item['testCommand']}")
            for sf in item["swiftFiles"]:
                print(f"  Swift   : {sf}")
            for uf in item["upstreamFiles"]:
                print(f"  Upstream: ({uf['status']}) {uf['path']}")
                for sym in symbols_by_file.get(uf["path"], []):
                    print(f"    * {sym['change']} {sym['kind']} {sym['name']}")
    elif since:
        print("")
        print("No changed upstream files in range.")


if __name__ == "__main__":
    main()
