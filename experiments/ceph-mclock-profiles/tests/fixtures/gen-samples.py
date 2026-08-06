#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""合成 sampler 的 samples.jsonl fixture（tests 專用）。

格式與 `lib/collect.sh` 的 `_collect_py tick` 產出一致（同一份契約，
真機的欄位正確性由 test-collect.sh 的 tick 測試對真實格式 pg dump fixture 鎖住）。

用法範例：
  gen-samples.py --out samples.jsonl --start 1785000000 --count 60 \
      --interval 5 --rate-bytes 104857600 --hole-at 20 --hole-secs 40
"""

import argparse
import json
import sys


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--start", type=int, required=True, help="第一個樣本的 epoch 秒")
    p.add_argument("--count", type=int, default=60)
    p.add_argument("--interval", type=int, default=5)
    p.add_argument("--rate-bytes", type=float, default=104857600.0,
                   help="recovery bytes/s（用來推 cumulative 差分）")
    p.add_argument("--epoch", type=int, default=514, help="OSDMap epoch")
    p.add_argument("--hole-at", type=int, default=-1,
                   help="相對秒；從這裡開始跳過樣本（模擬 sampler 中斷）")
    p.add_argument("--hole-secs", type=int, default=0)
    p.add_argument("--clean-at", type=int, default=-1,
                   help="相對秒；之後 PG 全 clean、recovery 速率歸零")
    p.add_argument("--down-osd", type=int, default=3)
    p.add_argument("--down-until", type=int, default=-1,
                   help="相對秒；之後 OSD 回到 up+in（預設全程 down）")
    p.add_argument("--cum-start", type=float, default=0.0)
    args = p.parse_args(argv)

    cum_bytes = args.cum_start
    cum_objects = 0.0
    lines = []
    for i in range(args.count):
        t = args.start + i * args.interval
        rel = t - args.start
        if args.hole_at >= 0 and args.hole_at <= rel < args.hole_at + args.hole_secs:
            # 樣本缺席：cumulative 仍照速率前進（回來時看得到補漲）
            if args.clean_at < 0 or rel < args.clean_at:
                cum_bytes += args.rate_bytes * args.interval
                cum_objects += args.rate_bytes * args.interval / 4194304.0
            continue
        clean = args.clean_at >= 0 and rel >= args.clean_at
        down = args.down_until < 0 or rel < args.down_until
        if clean:
            states = {"active+clean": 128}
            counts = {"active": 128, "clean": 128, "peering": 0, "degraded": 0,
                      "recovering": 0, "backfilling": 0, "undersized": 0,
                      "remapped": 0, "inactive": 0}
            degraded = 0
            rate = 0.0
        else:
            states = {"active+clean": 100, "active+undersized+degraded": 20,
                      "active+recovering+degraded": 8}
            counts = {"active": 128, "clean": 100, "peering": 0, "degraded": 28,
                      "recovering": 8, "backfilling": 0, "undersized": 20,
                      "remapped": 0, "inactive": 0}
            degraded = 12000
            rate = args.rate_bytes
        rec = {
            "t": t,
            "osdmap_epoch": args.epoch,
            "pg_total": 128,
            "pg_states": states,
            "pg_counts": counts,
            "recovered_bytes_cum": int(cum_bytes),
            "recovered_objects_cum": int(cum_objects),
            "recovering_bytes_per_sec": int(rate),
            "recovering_objects_per_sec": int(rate / 4194304.0),
            "degraded_objects": degraded,
            "misplaced_objects": 0,
            "num_objects": 76800,
            "num_up_osds": 7 if down else 8,
            "num_in_osds": 7 if down else 8,
            "health": "HEALTH_WARN" if not clean else "HEALTH_WARN",
            "osds_down": [args.down_osd] if down else [],
            "osds_out": [args.down_osd] if down else [],
            "flags": "noscrub,nodeep-scrub",
        }
        lines.append(json.dumps(rec, sort_keys=True))
        cum_bytes += rate * args.interval
        cum_objects += rate * args.interval / 4194304.0

    with open(args.out, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    sys.stdout.write("%d\n" % len(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
