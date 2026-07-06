#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
V="$here/../lib/verdict.py"
FX="$here/fixtures"

s="$(python3 "$V" summarize "$FX/fio-sample-a1.json" "$FX/fio-sample-a2.json")"
python3 - "$s" <<'EOF' || exit 1
import json,sys
d=json.loads(sys.argv[1])
assert d["n"]==2, d
assert abs(d["iops"]-1020.0)<0.01, d
assert abs(d["p99_us"]-2050.0)<0.01, d
assert 0 < d["iops_cov"] < 0.05, d
EOF

# baseline→variant IOPS +~50%，noise 2% → band 5% → confirmed
c="$(python3 "$V" compare --metric iops --expect better --noise-cov 0.02 \
     --baseline "$FX/fio-sample-a1.json,$FX/fio-sample-a2.json" \
     --variant  "$FX/fio-sample-b1.json,$FX/fio-sample-b2.json")"
echo "$c" | grep -q '"verdict": "confirmed"' || { echo "want confirmed: $c"; exit 1; }

# 反向預期 → violated
c="$(python3 "$V" compare --metric iops --expect worse --noise-cov 0.02 \
     --baseline "$FX/fio-sample-a1.json,$FX/fio-sample-a2.json" \
     --variant  "$FX/fio-sample-b1.json,$FX/fio-sample-b2.json")"
echo "$c" | grep -q '"verdict": "violated"' || { echo "want violated: $c"; exit 1; }

# 同組對打 → indistinguishable（expect better 落帶內）
c="$(python3 "$V" compare --metric iops --expect better --noise-cov 0.02 \
     --baseline "$FX/fio-sample-a1.json,$FX/fio-sample-a2.json" \
     --variant  "$FX/fio-sample-a1.json,$FX/fio-sample-a2.json")"
echo "$c" | grep -q '"verdict": "indistinguishable"' || { echo "want indistinguishable: $c"; exit 1; }

# p99 下降 = better → confirmed
c="$(python3 "$V" compare --metric p99 --expect better --noise-cov 0.02 \
     --baseline "$FX/fio-sample-a1.json,$FX/fio-sample-a2.json" \
     --variant  "$FX/fio-sample-b1.json,$FX/fio-sample-b2.json")"
echo "$c" | grep -q '"verdict": "confirmed"' || { echo "want p99 confirmed: $c"; exit 1; }
echo OK
