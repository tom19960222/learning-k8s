#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""合成 fio `--output-format=json` 輸出（tests 專用）。

真機 golden 由 `fio_smoke_real` 的 `aggregate --validate-schema` 校正；
在那之前，summary parser 的行為由本產生器的合成資料鎖住。
"""

import argparse
import json
import sys


def direction(iops, bs, p99_ns, p50_ns):
    if iops <= 0:
        return {"io_bytes": 0, "bw_bytes": 0, "iops": 0.0, "runtime": 0,
                "clat_ns": {"min": 0, "max": 0, "mean": 0.0, "stddev": 0.0,
                            "percentile": {}}}
    return {
        "io_bytes": int(iops * bs * 60),
        "bw_bytes": int(iops * bs),
        "iops": float(iops),
        "runtime": 60000,
        "clat_ns": {
            "min": int(p50_ns / 4),
            "max": int(p99_ns * 4),
            "mean": float(p50_ns),
            "stddev": float(p50_ns) / 3.0,
            "percentile": {
                "50.000000": int(p50_ns),
                "90.000000": int(p99_ns * 0.8),
                "95.000000": int(p99_ns * 0.9),
                "99.000000": int(p99_ns),
                "99.900000": int(p99_ns * 2),
            },
        },
    }


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--jobname", default="mclock-4k")
    p.add_argument("--read-iops", type=float, default=0.0)
    p.add_argument("--write-iops", type=float, default=0.0)
    p.add_argument("--bs", type=int, default=4096)
    p.add_argument("--p99-ns", type=float, default=1500000.0)
    p.add_argument("--p50-ns", type=float, default=400000.0)
    p.add_argument("--runtime-ms", type=int, default=60000)
    p.add_argument("--fio-version", default="fio-3.36")
    args = p.parse_args(argv)

    doc = {
        "fio version": args.fio_version,
        "timestamp": 1800000000,
        "jobs": [{
            "jobname": args.jobname,
            "groupid": 0,
            "error": 0,
            "job_runtime": args.runtime_ms,
            "read": direction(args.read_iops, args.bs, args.p99_ns, args.p50_ns),
            "write": direction(args.write_iops, args.bs, args.p99_ns, args.p50_ns),
        }],
    }
    with open(args.out, "w") as fh:
        json.dump(doc, fh, indent=1)
        fh.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
