#!/usr/bin/env python3
"""ntp_probe.py — independent SNTP probe for the timesyncd drift lab.

Measurement independence: we never trust timesyncd's self-reported offset.
This probe sends its own SNTP queries (plain UDP, stdlib only).

Sign convention (repo-wide): offset = server - client.
A client running FAST by X ms reads offset ~= -X ms.

Modes:
  oneshot --server IP [--port 123] [--samples N]   print median offset_ms to stdout
  run --server IP --csv FILE [--interval 1.0]      1Hz loop -> CSV until SIGTERM/SIGINT
CSV header: raw_s,wall_s,offset_ms,delay_ms,err
"""
import argparse
import signal
import socket
import statistics
import struct
import sys
import time

NTP_EPOCH_OFFSET = 2208988800  # 1900-01-01 -> 1970-01-01


def build_packet():
    pkt = bytearray(48)
    pkt[0] = 0x23  # LI=0 VN=4 Mode=3 (client)
    return bytes(pkt)


def ntp_to_unix(sec, frac):
    return sec - NTP_EPOCH_OFFSET + frac / 2**32


def parse_reply(data, t1, t4):
    """回傳 (offset_s, delay_s)。t1/t4 = client 送出/收到的 time.time()。"""
    if len(data) < 48:
        raise ValueError(f"short packet ({len(data)} bytes)")
    leap = data[0] >> 6
    mode = data[0] & 0x7
    stratum = data[1]
    if mode != 4:
        raise ValueError(f"not a server reply (mode={mode})")
    if leap == 3:
        raise ValueError("server unsynchronized (LI=3)")
    if not 1 <= stratum <= 15:
        raise ValueError(f"bad stratum {stratum}")
    t2s, t2f = struct.unpack("!II", data[32:40])  # receive timestamp
    t3s, t3f = struct.unpack("!II", data[40:48])  # transmit timestamp
    if t3s == 0:
        raise ValueError("zero transmit timestamp")
    t2 = ntp_to_unix(t2s, t2f)
    t3 = ntp_to_unix(t3s, t3f)
    offset = ((t2 - t1) + (t3 - t4)) / 2.0  # server - client
    delay = (t4 - t1) - (t3 - t2)
    return offset, delay


def query(server, port, timeout=1.0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        t1 = time.time()
        sock.sendto(build_packet(), (server, port))
        data, _ = sock.recvfrom(512)
        t4 = time.time()
    finally:
        sock.close()
    return parse_reply(data, t1, t4)


def raw_now():
    return time.clock_gettime(time.CLOCK_MONOTONIC_RAW)


def cmd_oneshot(args):
    offsets = []
    last_err = None
    for _ in range(args.samples):
        try:
            off, _ = query(args.server, args.port)
            offsets.append(off * 1000.0)
        except (OSError, ValueError) as e:
            last_err = e
        time.sleep(0.05)
    if not offsets:
        sys.exit(f"oneshot: all {args.samples} queries failed: {last_err}")
    print(f"{statistics.median(offsets):.3f}")


_stop = False


def _sig(_n, _f):
    global _stop
    _stop = True


def cmd_run(args):
    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    with open(args.csv, "w", buffering=1) as f:
        f.write("raw_s,wall_s,offset_ms,delay_ms,err\n")
        next_t = time.monotonic()
        while not _stop:
            r, w = raw_now(), time.time()
            try:
                off, dly = query(args.server, args.port)
                f.write(f"{r:.3f},{w:.3f},{off * 1000:.3f},{dly * 1000:.3f},\n")
            except (OSError, ValueError) as e:
                f.write(f"{r:.3f},{w:.3f},,,{type(e).__name__}\n")
            next_t += args.interval
            pause = next_t - time.monotonic()
            if pause > 0:
                time.sleep(pause)
            else:
                next_t = time.monotonic()  # 落後就重新對齊，不補打


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("oneshot")
    s.add_argument("--server", required=True)
    s.add_argument("--port", type=int, default=123)
    s.add_argument("--samples", type=int, default=1)
    s.set_defaults(fn=cmd_oneshot)
    s = sub.add_parser("run")
    s.add_argument("--server", required=True)
    s.add_argument("--port", type=int, default=123)
    s.add_argument("--csv", required=True)
    s.add_argument("--interval", type=float, default=1.0)
    s.set_defaults(fn=cmd_run)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
