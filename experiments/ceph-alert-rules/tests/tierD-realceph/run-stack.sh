#!/usr/bin/env bash
# Tier D 觀測 stack：在本機起 Prometheus（scrape 真 ceph mgr + 載真規則）→ Alertmanager（真 routing）
# → webhook sink。前景 hold 住（背景跑），用另開的 curl 查 alert 狀態與 sink。
# 用法：run-stack.sh <MGR_IP>   （active mgr 的 IP，failover 時重啟換 IP）
# for:-縮短版（5m→30s）只為觀測快、縮短叢集降級窗口；精確時長由 Tier A 保證。
set -uo pipefail
MGR_IP="${1:-192.168.18.167}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
PROMPORT=9790; AMPORT=9791; SINKPORT=9792
TMP=/tmp/tierd-stack; mkdir -p "$TMP"
SINKLOG="$TMP/sink.log"; : > "$SINKLOG"

find_bin() { command -v "$1" 2>/dev/null || { [ -x "$HOME/go/bin/$1" ] && echo "$HOME/go/bin/$1"; }; }
PROM="$(find_bin prometheus)"; ALERTMANAGER="$(find_bin alertmanager)"

# 縮短 for: 的真規則副本
sed 's/for: 5m/for: 30s/' "$ROOT/rules/ceph-stability-first.yml" > "$TMP/stability.yml"
sed 's/for: 5m/for: 30s/' "$ROOT/rules/ceph-scoped-availability.yml" > "$TMP/scoped.yml"

# AM 設定指向 sink
sed "s/__SINKPORT__/$SINKPORT/g" "$ROOT/tests/tierC-live/alertmanager-live.yml" > "$TMP/am.yml"

# Prometheus 設定：scrape 真 ceph mgr、載真規則、alert→本機 AM
cat > "$TMP/prometheus.yml" <<EOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s
rule_files:
  - $TMP/stability.yml
  - $TMP/scoped.yml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['127.0.0.1:$AMPORT']
scrape_configs:
  - job_name: ceph
    static_configs:
      - targets: ['$MGR_IP:9283']
EOF

pkill -f "tierd-stack" 2>/dev/null; sleep 1
python3 "$ROOT/tests/tierC-live/webhook-sink.py" "$SINKLOG" "$SINKPORT" &
"$ALERTMANAGER" --config.file="$TMP/am.yml" --storage.path="$TMP/am-data" \
  --web.listen-address="127.0.0.1:$AMPORT" --cluster.listen-address="" --log.level=error &
"$PROM" --config.file="$TMP/prometheus.yml" --storage.tsdb.path="$TMP/prom-data" \
  --web.listen-address="127.0.0.1:$PROMPORT" --log.level=error &
echo "stack up: prom=$PROMPORT am=$AMPORT sink=$SINKPORT mgr=$MGR_IP  (sinklog=$SINKLOG)"
wait
