#!/usr/bin/env python3
"""analyze.py — turn probe/monitor CSVs into convergence times, calibration and verdicts.

Subcommands:
  convergence  --csv F --t0-raw T [--threshold-ms 50] [--hold-s 60]
               JSON to stdout; exit 0 converged / 3 not converged.
               收斂定義（全實驗統一）：|offset| < threshold 持續 hold_s，
               取首次進入時刻（相對 t0-raw，單位秒）。樣本斷流 > 5s 視為 run 中斷。
  calibrate    --csv F --out calibration.json
               最小平方法斜率 → client_ppm = -slope_ms_per_s * 1000。
  soak-verdict --dir D [--expect-steps 0] [--step-min-ms 0]
               讀 ping.txt / steps.csv / sentinel.csv / journal-errors.txt
               → verdict.md + verdict.json；exit 0 PASS / 3 FAIL。
  exp1-summary --results-dir D
               掃 D/cell-*/result.json → markdown 彙總表。
"""
import argparse
import json
import os
import re
import sys


def read_probe_csv(path):
    """[(raw_s, offset_ms)]，跳過量測失敗列。"""
    out = []
    with open(path) as f:
        next(f)  # header
        for line in f:
            parts = line.rstrip("\n").split(",")
            if len(parts) < 5 or parts[4].strip():
                continue
            if parts[2] == "":
                continue
            out.append((float(parts[0]), float(parts[2])))
    return out


def find_convergence(samples, t0, threshold_ms, hold_s, max_gap_s=5.0):
    """首次 |offset|<threshold 連續 hold_s 的進入時刻（相對 t0），找不到回 None。"""
    run_start = None
    prev_raw = None
    for raw, off in samples:
        if raw < t0:
            continue
        if run_start is not None and prev_raw is not None and raw - prev_raw > max_gap_s:
            run_start = None  # probe 斷流，重新計
        if abs(off) < threshold_ms:
            if run_start is None:
                run_start = raw
            if raw - run_start >= hold_s:
                return run_start - t0
        else:
            run_start = None
        prev_raw = raw
    return None


def cmd_convergence(args):
    samples = read_probe_csv(args.csv)
    t = find_convergence(samples, args.t0_raw, args.threshold_ms, args.hold_s)
    last = samples[-1][1] if samples else None
    result = {
        "converged": t is not None,
        "t_converge_s": round(t, 1) if t is not None else None,
        "threshold_ms": args.threshold_ms, "hold_s": args.hold_s,
        "samples": len(samples), "last_offset_ms": last,
    }
    print(json.dumps(result))
    return 0 if t is not None else 3


def cmd_calibrate(args):
    samples = read_probe_csv(args.csv)
    if len(samples) < 60:
        sys.exit(f"calibrate: 樣本太少（{len(samples)} < 60）")
    n = len(samples)
    mx = sum(s[0] for s in samples) / n
    my = sum(s[1] for s in samples) / n
    sxx = sum((s[0] - mx) ** 2 for s in samples)
    sxy = sum((s[0] - mx) * (s[1] - my) for s in samples)
    if sxx == 0:
        sys.exit("calibrate: 所有樣本的 raw_s 相同，量測資料異常")
    slope = sxy / sxx  # ms/s
    cal = {
        "client_ppm": round(-slope * 1000, 3),
        "slope_ms_per_s": round(slope, 6),
        "n": n,
        "duration_s": round(samples[-1][0] - samples[0][0], 1),
    }
    with open(args.out, "w") as f:
        json.dump(cal, f, indent=1)
    print(json.dumps(cal))
    return 0


def count_csv_kind(path, kind):
    if not os.path.exists(path):
        return None
    cnt = 0
    with open(path) as f:
        next(f, None)
        for line in f:
            parts = line.split(",")
            if len(parts) >= 3 and parts[2] == kind:
                cnt += 1
    return cnt


def count_jumps(path, min_ms=0.0):
    """steps.csv 的 jump 事件數；只計 |jump| >= min_ms（區分真 step 與快速 slew 痕跡）。"""
    if not os.path.exists(path):
        return None
    cnt = 0
    with open(path) as f:
        next(f, None)
        for line in f:
            parts = line.rstrip("\n").split(",")
            if len(parts) >= 4 and parts[2] == "jump":
                try:
                    if abs(float(parts[3])) >= min_ms:
                        cnt += 1
                except ValueError:
                    pass
    return cnt


def cmd_soak_verdict(args):
    d = args.dir
    checks = []  # (name, value_desc, ok)
    ping_path = os.path.join(d, "ping.txt")
    if os.path.exists(ping_path):
        m = re.search(r"(\d+) packets transmitted, (\d+) (?:packets )?received",
                      open(ping_path).read())
        if m:
            tx, rx = int(m.group(1)), int(m.group(2))
            checks.append(("ping 0 丟包", f"{tx} tx / {rx} rx / lost {tx - rx}", tx == rx and tx > 0))
        else:
            checks.append(("ping 0 丟包", "ping.txt 沒有 summary（被 kill -9?）", False))
    else:
        checks.append(("ping 0 丟包", "ping.txt 不存在", False))
    steps = count_jumps(os.path.join(d, "steps.csv"), args.step_min_ms)
    label = f"step 事件 ≤ {args.expect_steps}"
    if args.step_min_ms > 0:
        label += f"（只計 |jump| ≥ {args.step_min_ms:g}ms）"
    checks.append((label,
                   f"{steps} 筆" if steps is not None else "steps.csv 不存在",
                   steps is not None and steps <= args.expect_steps))
    miss = count_csv_kind(os.path.join(d, "sentinel.csv"), "miss")
    back = count_csv_kind(os.path.join(d, "sentinel.csv"), "backward")
    ok_sent = miss is not None and miss == 0 and back == 0
    checks.append(("lease sentinel 0 miss/backward",
                   f"miss={miss} backward={back}" if miss is not None else "sentinel.csv 不存在",
                   ok_sent))
    je_path = os.path.join(d, "journal-errors.txt")
    if os.path.exists(je_path):
        nerr = sum(1 for line in open(je_path) if line.strip())
        checks.append(("journal 無 error", f"{nerr} 行", nerr == 0))
    else:
        checks.append(("journal 無 error", "journal-errors.txt 不存在", False))

    verdict = all(ok for _, _, ok in checks)
    lines = [f"# soak verdict: {'PASS' if verdict else 'FAIL'}", "",
             "| 判準 | 實測 | 結果 |", "|---|---|---|"]
    for name, val, ok in checks:
        lines.append(f"| {name} | {val} | {'✅' if ok else '❌'} |")
    md = "\n".join(lines) + "\n"
    with open(os.path.join(d, "verdict.md"), "w") as f:
        f.write(md)
    with open(os.path.join(d, "verdict.json"), "w") as f:
        json.dump({"pass": verdict,
                   "checks": [{"name": n, "value": v, "ok": o} for n, v, o in checks]},
                  f, ensure_ascii=False, indent=1)
    print(md)
    return 0 if verdict else 3


def cmd_exp1_summary(args):
    rows = []
    for name in sorted(os.listdir(args.results_dir)):
        rj = os.path.join(args.results_dir, name, "result.json")
        if not os.path.exists(rj):
            continue
        r = json.load(open(rj))
        rows.append(r)
    rows.sort(key=lambda r: (r.get("duration_h", 0), r.get("ppm", 0)))
    lines = ["| cell | 折疊 offset (ms) | ppm（注入/有效） | 收斂 | t_converge (s) |",
             "|---|---|---|---|---|"]
    for r in rows:
        eff = r.get("effective_ppm")
        lines.append("| {} | {} | {} / {} | {} | {} |".format(
            r.get("cell", "?"), r.get("injected_offset_ms", "?"),
            r.get("ppm", "?"), eff if eff is not None else "—",
            "✅" if r.get("converged") else "❌（timeout）",
            r.get("t_converge_s", "—")))
    md = "\n".join(lines) + "\n"
    out = os.path.join(args.results_dir, "summary.md")
    with open(out, "w") as f:
        f.write(md)
    print(md)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("convergence")
    s.add_argument("--csv", required=True)
    s.add_argument("--t0-raw", type=float, required=True)
    s.add_argument("--threshold-ms", type=float, default=50.0)
    s.add_argument("--hold-s", type=float, default=60.0)
    s.set_defaults(fn=cmd_convergence)
    s = sub.add_parser("calibrate")
    s.add_argument("--csv", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_calibrate)
    s = sub.add_parser("soak-verdict")
    s.add_argument("--dir", required=True)
    s.add_argument("--expect-steps", type=int, default=0)
    s.add_argument("--step-min-ms", type=float, default=0.0)
    s.set_defaults(fn=cmd_soak_verdict)
    s = sub.add_parser("exp1-summary")
    s.add_argument("--results-dir", required=True)
    s.set_defaults(fn=cmd_exp1_summary)
    args = p.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
