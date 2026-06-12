#!/usr/bin/env python3
"""plot_results.py — render the drift lab's headline result charts as static PNGs.

Reads probe CSVs from a results tree (see --results) and writes four figures:
  exp2-slew-vs-step.png      399ms PLL slew (with theory overlay) vs 401ms step
  exp1-1000ppm-sawtooth.png  beyond-MAXFREQ non-convergent sawtooth (eff +1061ppm)
  exp1-boundary-lock.png     boundary cells: eff -439ppm lock walk vs eff +561ppm fragile lock
  exp4-poll-soak-offset.png  steady-state offset, PollIntervalMaxSec 2048 vs 256 (4h soak)

Usage:
  python3 lib/plot_results.py --results results/l4 --out /path/to/diagrams/systemd

Note: 這支在「工作機」上跑（需要 matplotlib），不屬於 VM 端 stdlib-only 工具集。
"""
import argparse
import csv
import math
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

THRESHOLD_MS = 50


def read_probe(path, t0=None):
    """回傳 (t_rel_s[], offset_ms[])；t0=None 時以首筆 raw_s 為 0。"""
    ts, offs = [], []
    with open(path) as f:
        for row in csv.DictReader(f):
            if row["err"].strip() or row["offset_ms"] == "":
                continue
            ts.append(float(row["raw_s"]))
            offs.append(float(row["offset_ms"]))
    base = t0 if t0 is not None else (ts[0] if ts else 0.0)
    return [t - base for t in ts], offs


def read_t0(cell_dir):
    with open(os.path.join(cell_dir, "t0_raw")) as f:
        return float(f.read().strip())


def style(ax, xlabel, ylabel):
    ax.axhline(THRESHOLD_MS, color="crimson", lw=0.8, ls="--", alpha=0.7)
    ax.axhline(-THRESHOLD_MS, color="crimson", lw=0.8, ls="--", alpha=0.7)
    ax.axhline(0, color="gray", lw=0.5, alpha=0.5)
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.grid(alpha=0.25)


def fig_exp2(results, out):
    fig, ax = plt.subplots(figsize=(8.4, 4.6), dpi=150)
    for ms, color, label in ((399, "tab:blue", "399ms（slew）"), (401, "tab:orange", "401ms（step）")):
        d = os.path.join(results, "exp2", f"cell-{ms}ms")
        t, off = read_probe(os.path.join(d, "probe.csv"), read_t0(d))
        pts = [(x, y) for x, y in zip(t, off) if -5 <= x <= 40]
        ax.plot([p[0] for p in pts], [p[1] for p in pts], color=color, lw=1.6,
                marker="o", ms=2.5, label=label)
    # 理論曲線：offset(t) = -399·e^(-t/7.5)，首個 sample 後開始滑
    tt = [x / 10 for x in range(5, 400)]
    ax.plot(tt, [-399 * math.exp(-(x - 0.5) / 7.5) for x in tt],
            color="tab:blue", lw=1.0, ls=":", alpha=0.8,
            label="theory: -399·e^(-t/7.5)")
    style(ax, "time since timesyncd start (s)", "probe offset (ms)  [server - client]")
    ax.set_title("exp2 — NTP_MAX_ADJUST (0.4s) 兩側 1ms：slew vs step")
    ax.legend(loc="lower right")
    fig.tight_layout()
    fig.savefig(os.path.join(out, "exp2-slew-vs-step.png"))
    plt.close(fig)


def fig_exp1_sawtooth(results, out):
    d = os.path.join(results, "exp1", "cell-1h_1000ppm")
    t, off = read_probe(os.path.join(d, "probe.csv"), read_t0(d))
    fig, ax = plt.subplots(figsize=(8.4, 4.2), dpi=150)
    ax.plot(t, off, color="tab:red", lw=0.9)
    ax.set_ylim(-160, 60)
    style(ax, "time since timesyncd start (s)", "probe offset (ms)")
    ax.set_title("exp1 — 1h×1000ppm（eff +1061ppm > MAXFREQ）：永不穩定收斂的鋸齒")
    fig.tight_layout()
    fig.savefig(os.path.join(out, "exp1-1000ppm-sawtooth.png"))
    plt.close(fig)


def fig_exp1_boundary(results, out):
    fig, axes = plt.subplots(2, 1, figsize=(8.4, 6.6), dpi=150, sharex=False)
    cells = (
        ("cell-1h_-500ppm", "eff −439ppm（clamp 內 61ppm）：500.1s 走進鎖定", 500.1, "tab:green"),
        ("cell-1h_500ppm", "eff +561ppm（超 clamp 61ppm）：229.0s 進窗的脆弱鎖定", 229.0, "tab:purple"),
    )
    for ax, (cell, title, tconv, color) in zip(axes, cells):
        d = os.path.join(results, "exp1", cell)
        t, off = read_probe(os.path.join(d, "probe.csv"), read_t0(d))
        ax.plot(t, off, color=color, lw=0.9)
        ax.axvline(tconv, color="black", lw=0.9, ls="-.", alpha=0.7)
        ax.annotate(f"t_converge {tconv}s", (tconv, ax.get_ylim()[1] * 0.0),
                    xytext=(tconv + 30, 70), fontsize=9)
        ax.set_ylim(-120, 120)
        style(ax, "time since timesyncd start (s)", "offset (ms)")
        ax.set_title(title, fontsize=10)
    fig.suptitle("exp1 — MAXFREQ (±500ppm) 邊界兩側的鎖定行為", y=0.99)
    fig.tight_layout()
    fig.savefig(os.path.join(out, "exp1-boundary-lock.png"))
    plt.close(fig)


def fig_exp4_soak(results, out):
    fig, ax = plt.subplots(figsize=(8.4, 4.2), dpi=150)
    for scen, color, label in (("baseline-2048", "tab:orange", "PollIntervalMaxSec=2048（預設）"),
                               ("soak-256", "tab:blue", "PollIntervalMaxSec=256")):
        t, off = read_probe(os.path.join(results, "exp4", scen, "probe.csv"))
        ax.plot([x / 3600 for x in t], off, color=color, lw=0.7, alpha=0.85, label=label)
    style(ax, "soak time (h)", "probe offset (ms)")
    ax.set_title("exp4 — 4h soak 穩態 offset：max poll 2048 vs 256（天然漂移 +61ppm 的 VM）")
    ax.legend(loc="upper right")
    fig.tight_layout()
    fig.savefig(os.path.join(out, "exp4-poll-soak-offset.png"))
    plt.close(fig)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--results", required=True)
    p.add_argument("--out", required=True)
    args = p.parse_args()
    os.makedirs(args.out, exist_ok=True)
    # macOS 上用 PingFang 顯示繁中；沒有就退回預設（標題會變豆腐，axis 仍可讀）
    matplotlib.rcParams["font.sans-serif"] = ["PingFang TC", "Heiti TC", "Arial Unicode MS", "DejaVu Sans"]
    matplotlib.rcParams["axes.unicode_minus"] = False
    fig_exp2(args.results, args.out)
    fig_exp1_sawtooth(args.results, args.out)
    fig_exp1_boundary(args.results, args.out)
    fig_exp4_soak(args.results, args.out)
    print(f"4 charts → {args.out}")


if __name__ == "__main__":
    main()
