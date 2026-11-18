#!/usr/bin/env python3
"""Summarize a Swift or Rust scroll benchmark's Metal presentation CSV."""
import argparse
import csv
import json
import math
from pathlib import Path
from statistics import median


def summarize_presentations(path, refresh_hz=None, steps=600):
    first_presented = {}
    with path.open(newline="") as stream:
        for row in csv.DictReader(stream):
            step = int(row["wheel"])
            when = float(row["presented_seconds"])
            if 1 <= step <= steps and math.isfinite(when) and when > 0:
                first_presented[step] = min(when, first_presented.get(step, when))
    times = sorted(set(first_presented.values()))
    result = {"wheels": steps, "presentedWheels": len(first_presented),
              "distinctPresentationTimes": len(times)}
    if len(times) > 1:
        result["observedFPS"] = (len(times) - 1) / (times[-1] - times[0])
    ordered = [first_presented[step] for step in sorted(first_presented)]
    intervals = [b - a for a, b in zip(ordered, ordered[1:])]
    result["allWheelsInPresentationOrder"] = len(times) == steps and all(dt > 0 for dt in intervals)
    if result["allWheelsInPresentationOrder"]:
        result["displayedFPS"] = result["observedFPS"]
        result["medianIntervalMS"] = 1000 * median(intervals)
        result["p95IntervalMS"] = 1000 * sorted(intervals)[math.ceil(len(intervals) * 0.95) - 1]
        if refresh_hz is not None:
            result["refreshHz"] = refresh_hz
            result["missedRefreshes"] = sum(max(0, math.floor(dt * refresh_hz + 0.5) - 1)
                                            for dt in intervals)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    parser.add_argument("--steps", type=int, choices=(60, 600), default=600,
                        help="expected number of wheels sent by ScrollBench (default: 600)")
    parser.add_argument("--refresh-hz", type=float, help="fixed refresh rate used for the run")
    parser.add_argument("--max-missed-refreshes", type=int,
                        help="fail if any wheel lacks an ordered presentation or the missed-refresh count exceeds this limit")
    args = parser.parse_args()
    if args.refresh_hz is not None and (not math.isfinite(args.refresh_hz) or args.refresh_hz <= 0):
        parser.error("--refresh-hz must be finite and greater than zero")
    if args.max_missed_refreshes is not None and (args.refresh_hz is None or args.max_missed_refreshes < 0):
        parser.error("--max-missed-refreshes requires --refresh-hz and a nonnegative limit")
    report = summarize_presentations(args.csv, args.refresh_hz, args.steps)
    print(json.dumps(report, indent=2))
    if args.max_missed_refreshes is not None:
        raise SystemExit(0 if report.get("missedRefreshes", math.inf) <= args.max_missed_refreshes else 1)
