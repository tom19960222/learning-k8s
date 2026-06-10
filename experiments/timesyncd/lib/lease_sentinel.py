#!/usr/bin/env python3
"""lease_sentinel.py — 5s-deadline sentinel modelled on the ceph mon lease watchdog.

Every --renew-s (1s, CLOCK_MONOTONIC sleep) the lease is renewed. At each tick:
  wall_elapsed > lease_s  -> 'miss'     (clock jumped forward past the lease, or stall)
  wall_elapsed < 0        -> 'backward' (CLOCK_REALTIME went backwards)
raw_elapsed is logged too so analysis can tell clock-jump (wall >> raw) from
process stall (wall ~= raw).

CSV header: raw_s,wall_s,kind,wall_elapsed_ms,raw_elapsed_ms   (kind: miss | backward | hb)
"""
import argparse
import signal
import sys
import time


def classify(wall_elapsed_s, raw_elapsed_s, lease_s=5.0):
    """純函式：一次 tick 的 wall/raw 經過時間 → None | 'miss' | 'backward'。"""
    if wall_elapsed_s < 0:
        return "backward"
    if wall_elapsed_s > lease_s:
        return "miss"
    return None


_stop = False


def _sig(_n, _f):
    global _stop
    _stop = True


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--csv", required=True)
    p.add_argument("--lease-s", type=float, default=5.0)
    p.add_argument("--renew-s", type=float, default=1.0)
    args = p.parse_args()
    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    with open(args.csv, "w", buffering=1) as f:
        f.write("raw_s,wall_s,kind,wall_elapsed_ms,raw_elapsed_ms\n")
        prev_wall = time.time()
        prev_raw = time.clock_gettime(time.CLOCK_MONOTONIC_RAW)
        last_hb = time.monotonic()
        while not _stop:
            time.sleep(args.renew_s)
            w = time.time()
            r = time.clock_gettime(time.CLOCK_MONOTONIC_RAW)
            we, re_ = w - prev_wall, r - prev_raw
            kind = classify(we, re_, args.lease_s)
            if kind:
                f.write(f"{r:.3f},{w:.3f},{kind},{we * 1000:.1f},{re_ * 1000:.1f}\n")
            if time.monotonic() - last_hb >= 60:
                f.write(f"{r:.3f},{w:.3f},hb,,\n")
                last_hb = time.monotonic()
            prev_wall, prev_raw = w, r


if __name__ == "__main__":
    sys.exit(main())
