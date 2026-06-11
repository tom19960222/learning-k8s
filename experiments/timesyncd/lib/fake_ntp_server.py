#!/usr/bin/env python3
"""fake_ntp_server.py — SNTP server anchored to CLOCK_MONOTONIC_RAW (L3 single-kernel rig).

CLOCK_MONOTONIC_RAW is immune to adjtimex, so after this server starts,
its replies stay on the *undisturbed* timeline no matter what clock_inject
does to CLOCK_REALTIME on the same kernel.

MUST be started BEFORE injecting any error (it anchors to wall time at startup).

--skew-ms N : deliberately serve time N ms ahead of the anchor (for rig self-tests).
"""
import argparse
import socket
import struct
import sys
import time

NTP_EPOCH_OFFSET = 2208988800


def raw_now():
    return time.clock_gettime(time.CLOCK_MONOTONIC_RAW)


def unix_to_ntp(t):
    sec = int(t)
    frac = int((t - sec) * 2**32)
    return sec + NTP_EPOCH_OFFSET, frac


def make_reply(request, truth_s):
    """48-byte server reply。origin ← request transmit（timesyncd 會驗）。"""
    pkt = bytearray(48)
    pkt[0] = (0 << 6) | (4 << 3) | 4  # LI=0 VN=4 Mode=4 (server)
    pkt[1] = 2                        # stratum 2
    pkt[2] = request[2]               # poll: echo client
    pkt[3] = 0xEC                     # precision ~2^-20
    # root delay / root dispersion = 0（bytes 4-12），refid = 'RAWC'
    pkt[12:16] = b"RAWC"
    sec, frac = unix_to_ntp(truth_s)
    pkt[16:24] = struct.pack("!II", sec, frac)  # reference timestamp
    pkt[24:32] = request[40:48]                 # origin ← client transmit
    pkt[32:40] = struct.pack("!II", sec, frac)  # receive (T2)
    pkt[40:48] = struct.pack("!II", sec, frac)  # transmit (T3)
    return bytes(pkt)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--port", type=int, default=123)
    p.add_argument("--skew-ms", type=float, default=0.0)
    args = p.parse_args()

    anchor_wall = time.time()
    anchor_raw = raw_now()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    print(f"fake_ntp_server: {args.bind}:{args.port} anchored "
          f"wall={anchor_wall:.3f} raw={anchor_raw:.3f} skew={args.skew_ms}ms",
          flush=True)
    while True:
        try:
            data, addr = sock.recvfrom(512)
        except KeyboardInterrupt:
            return
        if len(data) < 48 or (data[0] & 0x7) != 3:
            continue  # 不是 client request
        truth = anchor_wall + (raw_now() - anchor_raw) + args.skew_ms / 1000.0
        sock.sendto(make_reply(data, truth), addr)


if __name__ == "__main__":
    sys.exit(main())
