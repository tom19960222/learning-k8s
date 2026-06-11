#!/usr/bin/env python3
"""clock_inject.py — adjtimex(clock_adjtime) injection tool for the timesyncd drift lab.

Sign conventions (repo-wide):
  set-offset --ms +X : step CLOCK_REALTIME forward by X ms (client becomes FAST by X)
  set-tick / set-freq --ppm +P : clock runs FAST by P ppm
  NTP probe offset = server - client, so a FAST client reads NEGATIVE probe offset.

Mechanism mapping (spec decision 2):
  accumulated offset -> ADJ_SETOFFSET (atomic, not clamped by MAXPHASE)
  |ppm| >= 100, multiple of 100 -> ADJ_TICK (register untouched by kernel PLL / timesyncd)
  fine ppm (e.g. +-10)          -> ADJ_FREQUENCY (PLL rewrites it; dynamically equivalent)

--dry-run prints the struct fields as JSON without any syscall (works on macOS for L2 tests).
"""
import argparse
import ctypes
import json
import sys

ADJ_OFFSET = 0x0001
ADJ_FREQUENCY = 0x0002
ADJ_MAXERROR = 0x0004
ADJ_ESTERROR = 0x0008
ADJ_STATUS = 0x0010
ADJ_TIMECONST = 0x0020
ADJ_SETOFFSET = 0x0100
ADJ_NANO = 0x2000
ADJ_TICK = 0x4000
STA_PLL = 0x0001
STA_UNSYNC = 0x0040
CLOCK_REALTIME = 0
SYS_clock_adjtime = 305  # x86_64
NSEC_PER_SEC = 1_000_000_000
TICK_DEFAULT_USEC = 10000  # USER_HZ=100

MODE_NAMES = {
    ADJ_OFFSET: "ADJ_OFFSET", ADJ_FREQUENCY: "ADJ_FREQUENCY",
    ADJ_MAXERROR: "ADJ_MAXERROR", ADJ_ESTERROR: "ADJ_ESTERROR",
    ADJ_STATUS: "ADJ_STATUS", ADJ_TIMECONST: "ADJ_TIMECONST",
    ADJ_SETOFFSET: "ADJ_SETOFFSET", ADJ_NANO: "ADJ_NANO", ADJ_TICK: "ADJ_TICK",
}


class Timeval(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_usec", ctypes.c_long)]


class Timex(ctypes.Structure):
    # 對齊 linux/include/uapi/linux/timex.h 的 struct timex（x86_64 LP64，208 bytes）
    _fields_ = [
        ("modes", ctypes.c_uint),
        ("offset", ctypes.c_long), ("freq", ctypes.c_long),
        ("maxerror", ctypes.c_long), ("esterror", ctypes.c_long),
        ("status", ctypes.c_int),
        ("constant", ctypes.c_long), ("precision", ctypes.c_long),
        ("tolerance", ctypes.c_long),
        ("time", Timeval),
        ("tick", ctypes.c_long), ("ppsfreq", ctypes.c_long), ("jitter", ctypes.c_long),
        ("shift", ctypes.c_int),
        ("stabil", ctypes.c_long), ("jitcnt", ctypes.c_long), ("calcnt", ctypes.c_long),
        ("errcnt", ctypes.c_long), ("stbcnt", ctypes.c_long),
        ("tai", ctypes.c_int),
        ("_pad", ctypes.c_int * 11),
    ]


def tx_dump(tx):
    modes = tx.modes
    return {
        "modes": modes,
        "modes_names": [n for v, n in sorted(MODE_NAMES.items()) if modes & v],
        "offset": tx.offset, "freq": tx.freq, "status": tx.status,
        "tick": tx.tick,
        "time_tv_sec": tx.time.tv_sec, "time_tv_usec": tx.time.tv_usec,
    }


def do_call(tx, dry_run):
    if dry_run:
        print(json.dumps(tx_dump(tx)))
        return 0
    if sys.platform != "linux":
        sys.exit("clock_inject: real injection only works on Linux (use --dry-run elsewhere)")
    assert ctypes.sizeof(Timex) == 208, f"struct timex size {ctypes.sizeof(Timex)} != 208"
    libc = ctypes.CDLL(None, use_errno=True)
    ret = libc.syscall(SYS_clock_adjtime, CLOCK_REALTIME, ctypes.byref(tx))
    if ret < 0:
        err = ctypes.get_errno()
        sys.exit(f"clock_adjtime failed: errno={err}")
    return ret


def cmd_set_offset(args):
    total_ns = round(args.ms * 1_000_000)
    tv_sec = total_ns // NSEC_PER_SEC          # floor division：負值正規化
    tv_nsec = total_ns - tv_sec * NSEC_PER_SEC  # 0 <= tv_nsec < 1e9
    tx = Timex()
    tx.modes = ADJ_SETOFFSET | ADJ_NANO
    tx.time.tv_sec = tv_sec
    tx.time.tv_usec = tv_nsec  # ADJ_NANO 時此欄為 ns
    do_call(tx, args.dry_run)


def cmd_set_tick(args):
    if args.ppm % 100 != 0:
        sys.exit("set-tick: ppm 必須是 100 的倍數（tick 粒度 = 100ppm）")
    tick = TICK_DEFAULT_USEC + args.ppm // 100
    if not 9000 <= tick <= 11000:
        sys.exit(f"set-tick: tick {tick} 超出 kernel 範圍 9000–11000")
    tx = Timex()
    tx.modes = ADJ_TICK
    tx.tick = tick
    do_call(tx, args.dry_run)


def cmd_set_freq(args):
    if abs(args.ppm) > 500:
        print(f"warn: |{args.ppm}ppm| > 500，kernel 會 clamp 到 MAXFREQ", file=sys.stderr)
    tx = Timex()
    tx.modes = ADJ_FREQUENCY
    tx.freq = int(args.ppm * 65536)
    do_call(tx, args.dry_run)


def cmd_reset(args):
    # 依序：tick 歸位 → freq 歸零 → 開 PLL 清 time_offset → 標回 UNSYNC（等 timesyncd 接手）
    seq = []
    tx = Timex(); tx.modes = ADJ_TICK; tx.tick = TICK_DEFAULT_USEC; seq.append(tx)
    tx = Timex(); tx.modes = ADJ_FREQUENCY; tx.freq = 0; seq.append(tx)
    tx = Timex(); tx.modes = ADJ_STATUS; tx.status = STA_PLL; seq.append(tx)
    tx = Timex(); tx.modes = ADJ_OFFSET | ADJ_NANO; tx.offset = 0; seq.append(tx)
    tx = Timex(); tx.modes = ADJ_STATUS; tx.status = STA_UNSYNC; seq.append(tx)
    for tx in seq:
        do_call(tx, args.dry_run)
    if not args.dry_run:
        print("reset: tick=10000 freq=0 time_offset=0 status=UNSYNC")


def cmd_status(args):
    tx = Timex()
    tx.modes = 0
    state = do_call(tx, args.dry_run)
    if not args.dry_run:
        d = tx_dump(tx)
        d["freq_ppm"] = tx.freq / 65536
        d["kernel_state"] = state  # 0=TIME_OK 5=TIME_ERROR(unsync)
        print(json.dumps(d))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dry-run", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("set-offset"); s.add_argument("--ms", type=float, required=True); s.set_defaults(fn=cmd_set_offset)
    s = sub.add_parser("set-tick"); s.add_argument("--ppm", type=int, required=True); s.set_defaults(fn=cmd_set_tick)
    s = sub.add_parser("set-freq"); s.add_argument("--ppm", type=float, required=True); s.set_defaults(fn=cmd_set_freq)
    s = sub.add_parser("reset"); s.set_defaults(fn=cmd_reset)
    s = sub.add_parser("status"); s.set_defaults(fn=cmd_status)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
