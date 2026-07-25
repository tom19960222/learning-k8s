#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""合成一個「已 finalize」的 replicate bundle（tests 專用）。

只寫 aggregate/prediction/censor 這幾個分析用檔案 + DONE marker；
fio raw log 由 gen-fio-logs.py 另外產。
"""

import argparse
import json
import os
import sys


def kv(text):
    key, _, val = text.partition("=")
    try:
        val = float(val)
        if val == int(val):
            val = int(val)
    except ValueError:
        pass
    return key, val


def expectation(text):
    """`<endpoint>=separated:a,b,c` 或 `<endpoint>=indistinguishable`。"""
    key, _, rest = text.partition("=")
    relation, _, order = rest.partition(":")
    return key, {"relation": relation,
                 "order": [o for o in order.split(",") if o]}


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--results", required=True)
    p.add_argument("--cell", required=True)
    p.add_argument("--rep", default="r1")
    p.add_argument("--attempt", default="20260724T000000Z")
    p.add_argument("--profile", default="balanced")
    p.add_argument("--group", default="g01")
    p.add_argument("--shape", default="4k-randrw")
    p.add_argument("--pressure", default="mid")
    p.add_argument("--fault", default="osd-down")
    p.add_argument("--manifest-hash")
    p.add_argument("--endpoint", action="append", default=[])
    p.add_argument("--expect", action="append", default=[])
    p.add_argument("--cap", type=int, default=2700)
    p.add_argument("--censored", action="store_true")
    p.add_argument("--tainted", action="store_true")
    p.add_argument("--no-done", action="store_true")
    args = p.parse_args(argv)

    bundle = os.path.join(args.results, args.cell, args.rep, "attempts", args.attempt)
    os.makedirs(bundle, exist_ok=True)

    endpoints = dict(kv(e) for e in args.endpoint)
    expectations = dict(expectation(e) for e in args.expect)

    pred = {
        "cell_id": args.cell,
        "group_id": args.group,
        "profile": args.profile,
        "shape": args.shape,
        "pressure": args.pressure,
        "fault": args.fault,
        "expectations": expectations,
    }
    if args.manifest_hash:
        pred["manifest_hash"] = args.manifest_hash

    agg = {
        "schema_version": 1,
        "cell_id": args.cell,
        "group_id": args.group,
        "profile": args.profile,
        "shape": args.shape,
        "pressure": args.pressure,
        "endpoints": endpoints,
        "censored": args.censored,
        "measurement_cap": args.cap,
    }
    censor = {
        "censored": args.censored,
        "measurement_cap": args.cap,
        "time_to_recovery_complete_s": endpoints.get("time_to_recovery_complete_s"),
    }
    cover = {"window": {"start": 0, "end": 0}, "gaps": [], "tainted": args.tainted}

    def dump(name, obj):
        with open(os.path.join(bundle, name), "w") as fh:
            json.dump(obj, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")

    dump("prediction.json", pred)
    dump("aggregate.json", agg)
    dump("censor-status.json", censor)
    dump("coverage-proof.json", cover)
    if not args.no_done:
        with open(os.path.join(bundle, "DONE"), "w") as fh:
            fh.write("kind=fault\n")
    sys.stdout.write("%s\n" % bundle)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
