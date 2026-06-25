#!/usr/bin/env bash
# 發現二緩解的真機對照驗證：同一個 Prometheus 同時載 mgr-based 規則與 out-of-band probe 規則，
# 停 2/3 mon（quorum 真失守），觀測：
#   CephMonQuorumLost（讀 mgr 匯出的 ceph_mon_quorum_status）→ 凍結沉默（重現 S4 盲區）
#   CephMonQuorumLostExternal（讀 TCP 探針的 ceph_mon_tcp_up）→ FIRE（緩解生效）
# trap 保證一定重啟兩台 mon。for: 縮 30s 加速觀測。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
FSID=0c9bf37e-514a-11f1-b72a-bc24113f1375
CN=/tmp/cnode.sh
PROMPORT=9790; PROBEPORT=9793
TMP=/tmp/tierd-ext; mkdir -p "$TMP"
find_bin() { command -v "$1" 2>/dev/null || { [ -x "$HOME/go/bin/$1" ] && echo "$HOME/go/bin/$1"; }; }
PROM="$(find_bin prometheus)"

sed 's/for: 1m/for: 30s/' "$ROOT/rules/ceph-stability-first.yml" > "$TMP/stability.yml"
sed 's/for: 1m/for: 30s/' "$ROOT/rules/ceph-mon-external.yml" > "$TMP/external.yml"
cat > "$TMP/prom.yml" <<EOF
global: { scrape_interval: 5s, evaluation_interval: 5s }
rule_files: [ $TMP/stability.yml, $TMP/external.yml ]
scrape_configs:
  - job_name: ceph
    static_configs: [ { targets: ['192.168.18.167:9283'] } ]
  - job_name: ceph-mon-probe
    static_configs: [ { targets: ['127.0.0.1:$PROBEPORT'] } ]
EOF

pkill -f "tierd-ext" 2>/dev/null; pkill -f "mon-tcp-probe" 2>/dev/null; sleep 1
python3 "$HERE/mon-tcp-probe.py" "$PROBEPORT" \
  ceph-lab-mon-01=192.168.18.166 ceph-lab-mon-02=192.168.18.167 ceph-lab-mon-03=192.168.18.164 & PROBE_PID=$!
"$PROM" --config.file="$TMP/prom.yml" --storage.tsdb.path="$TMP/data" \
  --web.listen-address="127.0.0.1:$PROMPORT" --log.level=error & PROM_PID=$!

restore() {
  echo ">>> RESTORE (trap): start mon-01 + mon-03"
  bash $CN 192.168.18.166 "sudo systemctl start ceph-$FSID@mon.ceph-lab-mon-01.service" 2>&1 | tail -1
  bash $CN 192.168.18.164 "sudo systemctl start ceph-$FSID@mon.ceph-lab-mon-03.service" 2>&1 | tail -1
  kill "$PROM_PID" "$PROBE_PID" 2>/dev/null; rm -rf "$TMP" 2>/dev/null
}
trap restore EXIT

for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$PROMPORT/-/ready" >/dev/null 2>&1 && break; sleep 1; done
st() { curl -s "http://127.0.0.1:$PROMPORT/api/v1/alerts" | jq -r --arg a "$1" '[.data.alerts[]?|select(.labels.alertname==$a)]|if length==0 then "—" else (.[0].state) end'; }
mgrc() { curl -s "http://127.0.0.1:$PROMPORT/api/v1/query" --data-urlencode 'query=count(ceph_mon_quorum_status == 1)' | jq -r '.data.result[]?|.value[1]'; }
extc() { curl -s "http://127.0.0.1:$PROMPORT/api/v1/query" --data-urlencode 'query=count(ceph_mon_tcp_up == 1)' | jq -r '.data.result[]?|.value[1]'; }

echo "### baseline: mgr_count=$(mgrc) probe_count=$(extc)"
echo "### stop mon-03 then mon-01 (quorum lost)"
bash $CN 192.168.18.164 "sudo systemctl stop ceph-$FSID@mon.ceph-lab-mon-03.service" 2>&1 | tail -1
bash $CN 192.168.18.166 "sudo systemctl stop ceph-$FSID@mon.ceph-lab-mon-01.service" 2>&1 | tail -1
echo "### observe ~80s — mgr rule should stay silent, external rule should FIRE"
for i in $(seq 1 16); do
  printf '  [%ss] mgr: count=%s alert=%-8s | probe: count=%s alert=%s\n' \
    "$((i*5))" "$(mgrc)" "$(st CephMonQuorumLost)" "$(extc)" "$(st CephMonQuorumLostExternal)"
  sleep 5
done
echo "### done; trap restores"
