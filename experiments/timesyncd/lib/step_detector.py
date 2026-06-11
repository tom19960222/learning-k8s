#!/usr/bin/env python3
"""step_detector.py — detect CLOCK_REALTIME discontinuities (steps) vs smooth slew.

Samples d = CLOCK_REALTIME - CLOCK_MONOTONIC_RAW at --interval (default 0.1s).
A step (clock_settime / ADJ_SETOFFSET) moves d by the whole amount within one
sample; slew moves it gradually. Events with |jump| > --threshold-ms are logged.
Heartbeat row every 60s proves the detector was alive for the whole window.

CSV header: raw_s,wall_s,kind,jump_ms   (kind: jump | hb)
"""
import argparse
import signal
import sys
import time


def find_jumps(ds, threshold_ms):
    """純函式：d 序列（ms）→ [(index, jump_ms), ...]，|jump| > threshold 才算。"""
    events = []
    for i in range(1, len(ds)):
        jump = ds[i] - ds[i - 1]
        if abs(jump) > threshold_ms:
            events.append((i, jump))
    return events


def d_ms():
    return (time.clock_gettime_ns(time.CLOCK_REALTIME)
            - time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)) / 1e6


_stop = False


def _sig(_n, _f):
    global _stop
    _stop = True


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--csv", required=True)
    p.add_argument("--interval", type=float, default=0.1)
    p.add_argument("--threshold-ms", type=float, default=1.0)
    args = p.parse_args()
    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    with open(args.csv, "w", buffering=1) as f:
        f.write("raw_s,wall_s,kind,jump_ms\n")
        prev = d_ms()
        last_hb = time.monotonic()
        while not _stop:
            time.sleep(args.interval)
            cur = d_ms()
            jump = cur - prev
            prev = cur
            r = time.clock_gettime(time.CLOCK_MONOTONIC_RAW)
            w = time.time()
            if abs(jump) > args.threshold_ms:
                f.write(f"{r:.3f},{w:.3f},jump,{jump:.3f}\n")
            if time.monotonic() - last_hb >= 60:
                f.write(f"{r:.3f},{w:.3f},hb,\n")
                last_hb = time.monotonic()


if __name__ == "__main__":
    sys.exit(main())
