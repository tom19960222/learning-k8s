#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""合成 fio 逐秒 log fixture（tests 專用）。

真機 golden log 之後在 first-cell gate 用 `aggregate --validate-schema` 校正；
在那之前，parser 的行為由本產生器的合成資料鎖住。

產出（fio 的自然命名）：
  <out>/<seg>_iops.<job>.log
  <out>/<seg>_lat.<job>.log
  <out>/<seg>_clat_hist.<job>.log
"""

import argparse
import os
import sys

FIO_IO_U_PLAT_BITS = 6
FIO_IO_U_PLAT_VAL = 1 << FIO_IO_U_PLAT_BITS


def plat_idx_to_val(idx):
    if idx < (FIO_IO_U_PLAT_VAL << 1):
        return float(idx)
    error_bits = (idx >> FIO_IO_U_PLAT_BITS) - 1
    base = 1 << (error_bits + FIO_IO_U_PLAT_BITS)
    k = idx % FIO_IO_U_PLAT_VAL
    return float(base + ((k + 0.5) * (1 << error_bits)))


def bin_for(value, nbins):
    """找出「值 >= value」的最小 bin index（fixture 用，不求精確反函式）。"""
    for idx in range(nbins):
        if plat_idx_to_val(idx) >= value:
            return idx
    return nbins - 1


def parse_secs(text):
    if not text:
        return set()
    return set(int(x) for x in text.split(",") if x.strip() != "")


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--seg", default="seg01")
    p.add_argument("--job", default="1")
    p.add_argument("--start", type=int, required=True, help="epoch 秒")
    p.add_argument("--seconds", type=int, default=120)
    p.add_argument("--iops", type=float, default=1000.0, help="每個 direction 每秒的 IOPS")
    p.add_argument("--bs", type=int, default=4096)
    p.add_argument("--lat-ns", type=float, default=500000.0)
    p.add_argument("--samples", type=int, default=200, help="每秒放進 histogram 的樣本數")
    p.add_argument("--stall-secs", default="", help="相對秒；iops 樣本存在但值 = 0")
    p.add_argument("--omit-secs", default="", help="相對秒；完全不寫任何樣本")
    p.add_argument("--brownout-secs", default="", help="相對秒；該秒 p99 拉到 --brownout-ns")
    p.add_argument("--brownout-ns", type=float, default=2.0e9)
    p.add_argument("--dup-secs", default="", help="相對秒；重複寫一筆（parser 應丟棄第二筆）")
    p.add_argument("--bins", type=int, default=1856, help="1856=ns 版；1216=us 版")
    p.add_argument("--directions", default="0,1")
    args = p.parse_args(argv)

    stall = parse_secs(args.stall_secs)
    omit = parse_secs(args.omit_secs)
    brownout = parse_secs(args.brownout_secs)
    dup = parse_secs(args.dup_secs)
    directions = [int(d) for d in args.directions.split(",")]
    nbins = args.bins
    unit_div = 1.0 if nbins == 1856 else 1000.0  # us 版的 bin 值單位是 us

    if not os.path.isdir(args.out):
        os.makedirs(args.out)
    base = os.path.join(args.out, args.seg)
    f_iops = open("%s_iops.%s.log" % (base, args.job), "w")
    f_lat = open("%s_lat.%s.log" % (base, args.job), "w")
    f_hist = open("%s_clat_hist.%s.log" % (base, args.job), "w")

    normal_bin = bin_for(args.lat_ns / unit_div, nbins)
    slow_bin = bin_for(args.brownout_ns / unit_div, nbins)

    for rel in range(args.seconds):
        if rel in omit:
            continue
        t_ms = (args.start + rel) * 1000
        for direction in directions:
            iops = 0.0 if rel in stall else args.iops
            reps = 2 if rel in dup else 1
            for _ in range(reps):
                f_iops.write("%d, %d, %d, %d, 0\n" % (t_ms, int(iops), direction, args.bs))
                f_lat.write("%d, %d, %d, %d, 0\n"
                            % (t_ms, int(args.lat_ns), direction, args.bs))
            if rel in stall:
                continue
            bins = [0] * nbins
            n = args.samples
            slow = max(1, int(n * 0.02)) if rel in brownout else 0
            bins[normal_bin] = n - slow
            if slow:
                bins[slow_bin] = slow
            row = "%d, %d, %d, %s\n" % (t_ms, direction, args.bs,
                                        ", ".join(str(b) for b in bins))
            for _ in range(reps):
                f_hist.write(row)

    f_iops.close()
    f_lat.close()
    f_hist.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
