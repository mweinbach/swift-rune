#!/usr/bin/env python3
"""Summarize the 600 scroll inputs from a Swift or Rust Metal presentation CSV."""
import argparse
import csv
import json
from pathlib import Path


def summarize_presentations(path):
    first_presented = {}
    with path.open() as stream:
        for row in csv.DictReader(stream):
            step = int(row["wheel"])
            when = float(row["presented_seconds"])
            if 1 <= step <= 600 and when > 0:
                first_presented[step] = min(when, first_presented.get(step, when))
    times = sorted(set(first_presented.values()))
    result = {"wheels": 600, "presentedWheels": len(first_presented),
              "distinctPresentationTimes": len(times)}
    if len(times) > 1:
        result["observedFPS"] = (len(times) - 1) / (times[-1] - times[0])
    if len(times) == 600:
        result["displayedFPS"] = result["observedFPS"]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    print(json.dumps(summarize_presentations(parser.parse_args().csv), indent=2))
