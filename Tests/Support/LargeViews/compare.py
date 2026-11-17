#!/usr/bin/env python3
"""Compare the visible data and full reference frames from two large-view captures."""
import argparse
import json
from pathlib import Path
from struct import iter_unpack


def visible(data):
    return {r["key"]: (r["rect"], r["visible"]) for r in data["rows"]
            if r["key"] != "header" and r["visible"][2] > 0 and r["visible"][3] > 0}


def pixels(lhs, rhs, dimensions):
    a, b = lhs.read_bytes(), rhs.read_bytes()
    count = dimensions[0] * dimensions[1]
    if len(a) != count * 4 or len(b) != len(a):
        raise ValueError(f"Incomplete raw frame: {lhs} or {rhs}")
    exact = within8 = max_delta = 0
    for left, right in zip(iter_unpack("4B", a), iter_unpack("4B", b)):
        if left == right:
            exact += 1
            within8 += 1
        else:
            delta = max(abs(x - y) for x, y in zip(left, right))
            within8 += delta <= 8
            max_delta = max(max_delta, delta)
    return {"samples": count, "exact": exact, "within8": within8, "maxChannelDifference": max_delta}


CHECKPOINTS = (0, 1, 24, 60, 300, 600)


def compare_windows(directory, rust_path, case):
    rust = json.loads(rust_path.read_text())
    if rust["events"] != 600 or [c["wheel"] for c in rust["checkpoints"]] != list(CHECKPOINTS):
        raise ValueError("Incomplete Rust native window capture")
    matched = True
    records = []
    for entry in rust["checkpoints"]:
        frame = entry["wheel"]
        swift = json.loads((directory / f"{case}-{frame}.json").read_text())
        pinned = swift.get("stickyHeaderBottom", 0)
        rows = sorted((r for r in swift["rows"] if r["key"] != "header"
                       and r["visible"][2] > 0 and r["visible"][3] > 0
                       and r["visible"][1] + r["visible"][3] > pinned),
                      key=lambda r: r["visible"][1])
        observed = [(r["key"], r["visible"]) for r in rows]
        expected = [(key, bounds) for key, bounds in entry["visible"]]
        lhs, rhs = dict(observed), dict(expected)
        changed = sorted(k for k in lhs.keys() | rhs.keys() if lhs.get(k) != rhs.get(k))
        same_keys = [k for k, _ in observed] == [k for k, _ in expected]
        record = {"frame": frame, "visibleRows": len(rows), "rowOrderMatches": same_keys,
                  "visibleGeometryMismatches": changed, "swiftMounted": swift["count"],
                  "rustMounted": entry["mounted"]}
        matched &= bool(rows) and same_keys and not changed and len(lhs) == len(observed)
        if case == "diff":
            record["swiftScrollY"] = swift["scrollOffsetY"]
            record["rustScrollY"] = entry["scrollY"]
            matched &= swift["scrollOffsetY"] == entry["scrollY"] == frame * 400
        records.append(record)
    print(json.dumps({case: records}, indent=2))
    return int(not matched)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("swift", type=Path)
    parser.add_argument("rust", type=Path)
    parser.add_argument("--geometry-only", action="store_true",
                        help="compare checkpoint dimensions and row geometry without pixel captures")
    parser.add_argument("--pixel-tolerance", type=int, metavar="0..255",
                        help="also fail if any painted channel exceeds this difference")
    parser.add_argument("--native-window", choices=("table", "tree", "diff"), metavar="CASE",
                        help="compare Swift window captures with the Rust window JSON for this workload")
    args = parser.parse_args()
    if args.native_window:
        if args.pixel_tolerance is not None:
            parser.error("Native window checkpoints contain geometry only")
        return compare_windows(args.swift, args.rust, args.native_window)
    if args.pixel_tolerance is not None and not 0 <= args.pixel_tolerance <= 255:
        parser.error("--pixel-tolerance must be between 0 and 255")
    if args.geometry_only and args.pixel_tolerance is not None:
        parser.error("--pixel-tolerance requires pixel captures")
    mismatched = False
    result = {}
    for case in ("table", "tree"):
        records = []
        for frame in CHECKPOINTS:
            stem = f"{case}-{frame}"
            swift, rust = [json.loads((directory / f"{stem}.json").read_text()) for directory in (args.swift, args.rust)]
            lhs, rhs = visible(swift), visible(rust)
            changed = sorted(k for k in lhs.keys() | rhs.keys() if lhs.get(k) != rhs.get(k))
            size_match = swift["scene"] == rust["scene"]
            mismatched |= bool(changed) or not size_match
            row = {"frame": frame, "swiftMounted": swift["count"], "rustMounted": rust["count"],
                   "dimensionsMatch": size_match, "visibleGeometryMismatches": changed}
            if "nativeInstances" in rust:
                row["rustNativeInstances"] = rust["nativeInstances"]
            if "nativeInstances" in swift:
                row["swiftNativeInstances"] = swift["nativeInstances"]
            if "referencePrimitives" in swift:
                row["swiftReferencePrimitives"] = swift["referencePrimitives"]
            if size_match and frame in (0, 60) and not args.geometry_only:
                row["pixels"] = pixels(args.swift / f"{stem}.rgba", args.rust / f"{stem}.rgba", swift["scene"])
                if args.pixel_tolerance is not None:
                    mismatched |= row["pixels"]["maxChannelDifference"] > args.pixel_tolerance
            records.append(row)
        result[case] = records
    print(json.dumps(result, indent=2))
    return int(mismatched)


if __name__ == "__main__":
    raise SystemExit(main())
