#!/usr/bin/env python3
"""Analyze Prometheus API JSON dumps (query_range / instant query).

Machine-comparison helper for scenario verdicts: stdout carries exactly one
line (the value asked for); all diagnostics go to stderr.

Subcommands:
  max FILE               max value across all series/points; "none" if empty
  first_ts_gt FILE THR   earliest timestamp where any point > THR; "none"
  delta_first_last FILE  sum over series of (last - first); "0" if empty
  series_count FILE      number of series in result
  last_val FILE          value of the last point of the first series; "none"
  first_val FILE         value of the first point of the first series; "none"
"""
import json
import sys


def _load(path):
    with open(path) as f:
        doc = json.load(f)
    if doc.get("status") != "success":
        sys.stderr.write("promjson: non-success status in %s\n" % path)
        sys.exit(2)
    return doc["data"]["result"]


def _points(series):
    if "values" in series:
        return series["values"]
    if "value" in series:
        return [series["value"]]
    return []


def _all_points(result):
    for series in result:
        for ts, val in _points(series):
            try:
                yield float(ts), float(val)
            except ValueError:
                continue  # NaN etc.


def cmd_max(result):
    vals = [v for _, v in _all_points(result)]
    print(max(vals) if vals else "none")


def cmd_first_ts_gt(result, threshold):
    hits = [ts for ts, v in _all_points(result) if v > threshold]
    if not hits:
        print("none")
        return
    ts = min(hits)
    print(int(ts) if ts.is_integer() else ts)


def cmd_delta_first_last(result):
    total = 0.0
    for series in result:
        pts = [(float(t), float(v)) for t, v in _points(series)]
        if len(pts) >= 2:
            total += pts[-1][1] - pts[0][1]
    print(total)


def cmd_series_count(result):
    print(len(result))


def cmd_last_val(result):
    for series in result:
        pts = _points(series)
        if pts:
            print(float(pts[-1][1]))
            return
    print("none")


def cmd_first_val(result):
    for series in result:
        pts = _points(series)
        if pts:
            print(float(pts[0][1]))
            return
    print("none")


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 1
    cmd, path = argv[1], argv[2]
    result = _load(path)
    if cmd == "max":
        cmd_max(result)
    elif cmd == "first_ts_gt":
        cmd_first_ts_gt(result, float(argv[3]))
    elif cmd == "delta_first_last":
        cmd_delta_first_last(result)
    elif cmd == "series_count":
        cmd_series_count(result)
    elif cmd == "last_val":
        cmd_last_val(result)
    elif cmd == "first_val":
        cmd_first_val(result)
    else:
        sys.stderr.write("promjson: unknown subcommand %s\n" % cmd)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
