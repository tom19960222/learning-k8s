#!/usr/bin/env python3
"""fio JSON aggregation and 3-state verdict for rbd-io-perf.

summarize FILE...          -> one-line JSON with mean/CoV across runs
compare --metric M --expect E --noise-cov F --baseline A,B --variant C,D
                           -> one-line JSON verdict
"""
import argparse, json, statistics, sys


def _load(path):
    with open(path) as f:
        return json.load(f)["jobs"][0]


def _point(job):
    rd, wr = job.get("read", {}), job.get("write", {})
    iops = float(rd.get("iops", 0)) + float(wr.get("iops", 0))
    bw = float(rd.get("bw_bytes", 0)) + float(wr.get("bw_bytes", 0))
    p99s = []
    for side in (rd, wr):
        v = side.get("clat_ns", {}).get("percentile", {}).get("99.000000", 0)
        if v:
            p99s.append(float(v))
    p99_us = max(p99s) / 1000.0 if p99s else 0.0
    return iops, p99_us, bw / 1e6


def _agg(paths):
    pts = [_point(_load(p)) for p in paths]
    iops = [p[0] for p in pts]
    p99 = [p[1] for p in pts]
    bw = [p[2] for p in pts]

    def cov(xs):
        m = statistics.mean(xs)
        if m == 0 or len(xs) < 2:
            return 0.0
        return statistics.stdev(xs) / m

    return {
        "iops": statistics.mean(iops), "iops_cov": cov(iops),
        "p99_us": statistics.mean(p99), "p99_cov": cov(p99),
        "bw_mbs": statistics.mean(bw), "n": len(pts),
    }


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summarize")
    s.add_argument("files", nargs="+")
    c = sub.add_parser("compare")
    c.add_argument("--metric", choices=["iops", "p99"], required=True)
    c.add_argument("--expect", choices=["better", "worse", "none"], required=True)
    c.add_argument("--noise-cov", type=float, required=True)
    c.add_argument("--baseline", required=True)
    c.add_argument("--variant", required=True)
    args = ap.parse_args()

    if args.cmd == "summarize":
        print(json.dumps(_agg(args.files)))
        return

    base = _agg(args.baseline.split(","))
    var = _agg(args.variant.split(","))
    key = "iops" if args.metric == "iops" else "p99_us"
    if base[key] == 0:
        print(json.dumps({"verdict": "violated", "delta_pct": 0.0,
                          "band_pct": 0.0, "error": "baseline metric is 0"}))
        return
    delta = (var[key] - base[key]) / base[key]
    band = max(2 * args.noise_cov, 0.05)
    # for p99, "better" means the value went DOWN
    improved = delta > 0 if args.metric == "iops" else delta < 0
    if abs(delta) <= band:
        verdict = "confirmed" if args.expect == "none" else "indistinguishable"
    elif args.expect == "none":
        verdict = "violated"
    elif (args.expect == "better") == improved:
        verdict = "confirmed"
    else:
        verdict = "violated"
    print(json.dumps({"verdict": verdict, "delta_pct": round(delta * 100, 2),
                      "band_pct": round(band * 100, 2)}))


if __name__ == "__main__":
    sys.exit(main())
