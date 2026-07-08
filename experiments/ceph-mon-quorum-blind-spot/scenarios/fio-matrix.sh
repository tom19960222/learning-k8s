#!/bin/sh
# Run an fio matrix (random/seq x single/multi-thread) against a pre-connected pod.
# Designed to run ON the k8s node (.155) where kubectl is local.
# Usage: fio-matrix.sh <phase> [pod] [cell_timeout_s]
#   cell_timeout_s > 0 wraps each kubectl exec in host `timeout` so a blocked-IO
#   cell (e.g. during quorum loss) is bounded instead of hanging forever.
PHASE="$1"; POD="${2:-fio-preconn}"; TMO="${3:-0}"
OUT="/tmp/qio-results/$PHASE"; mkdir -p "$OUT"

run() {
  pat="$1"; t="$2"; bs="$3"
  name="${pat}_${t}t"
  wrap=""; [ "$TMO" -gt 0 ] && wrap="timeout $TMO"
  $wrap sudo kubectl exec "$POD" -- sh -c \
    "fio --name=c --filename=/vol/tf --rw=$pat --bs=$bs --ioengine=libaio --direct=1 --iodepth=1 --numjobs=$t --thread --group_reporting --runtime=12 --time_based --output-format=json 2>/dev/null" \
    > "$OUT/$name.json" 2>/dev/null
  rc=$?
  python3 - "$OUT/$name.json" "$pat" "$t" "$rc" <<'PY'
import json,sys
path,pat,t,rc=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
try:
    d=json.load(open(path)); j=d["jobs"][0]
    io=j["read"] if "read" in pat else j["write"]
    lat=io.get("clat_ns",{}).get("mean",0)/1000.0
    print(f"{pat}\t{t}t\tiops={io['iops']:.0f}\tbw={io['bw']/1024:.1f}MB/s\tlat_us={lat:.0f}\trc={rc}")
except Exception as e:
    print(f"{pat}\t{t}t\tSTALL_or_PARSE_FAIL rc={rc} ({e})")
PY
}

echo "== fio matrix phase=$PHASE tmo=$TMO =="
run randread 1 4k;  run randread 4 4k
run randwrite 1 4k; run randwrite 4 4k
run read 1 1m;      run read 4 1m
run write 1 1m;     run write 4 1m
echo "== end phase=$PHASE =="
