#!/usr/bin/env bash
# Tier C3 — 全鏈路端到端：合成 metric → 真 Prometheus（抓取+評估真 recording rule+alert）
#           → 真 Alertmanager（真 routing）→ webhook sink。
# 補 devil #2/#3：證明「live Prometheus 評估真規則產出的 label」與 Tier A 斷言一致，
# 且這組「真實產出的 label」確實被 routing 送到 pager（非手刻 label）。
# 為了不等 5m，用 sed 把 scoped 規則的 for: 縮成 5s（只縮時長，不改邏輯；時長語意由 Tier A 保證）。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
RESULTS="$ROOT/results"; mkdir -p "$RESULTS"
EXPORTER_PORT=9750; SINKPORT=9748; AMPORT=9749; PROMPORT=9751
SINKLOG="$(mktemp)"; TMP="$(mktemp -d)"

find_bin() { command -v "$1" 2>/dev/null || { [ -x "$HOME/go/bin/$1" ] && echo "$HOME/go/bin/$1"; } || { [ -x "$ROOT/.bin/$1" ] && echo "$ROOT/.bin/$1"; }; }
ALERTMANAGER="$(find_bin alertmanager)"; PROM="$(find_bin prometheus)"
[ -z "$ALERTMANAGER" ] && { echo "FATAL: alertmanager not found"; exit 2; }
[ -z "$PROM" ] && { echo "FATAL: prometheus not found"; exit 2; }

# shellcheck disable=SC2329
# Invoked by the EXIT trap.
cleanup() {
  for p in "${PROM_PID:-}" "${AM_PID:-}" "${EXP_PID:-}" "${SINK_PID:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  wait 2>/dev/null; rm -rf "$TMP" "$SINKLOG" 2>/dev/null
}
trap cleanup EXIT

fail=0; pass=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL %s\n' "$1"; fail=1; }

# for:-縮短版 scoped 規則（只改 for，邏輯逐字不動）
sed 's/for: 5m/for: 5s/; s/for: 30s/for: 5s/' "$ROOT/rules/ceph-scoped-availability.yml" > "$TMP/scoped-fast.yml"

# AM 設定（指向 sink）
sed "s/__SINKPORT__/$SINKPORT/g" "$HERE/alertmanager-live.yml" > "$TMP/am.yml"

# Prometheus 設定：抓 exporter、載 short 規則、alert 送 AM
cat > "$TMP/prometheus.yml" <<EOF
global:
  scrape_interval: 1s
  evaluation_interval: 1s
rule_files:
  - $TMP/scoped-fast.yml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['127.0.0.1:$AMPORT']
scrape_configs:
  - job_name: ceph
    static_configs:
      - targets: ['127.0.0.1:$EXPORTER_PORT']
EOF

python3 "$HERE/webhook-sink.py" "$SINKLOG" "$SINKPORT" & SINK_PID=$!
python3 "$HERE/metrics-exporter.py" "$EXPORTER_PORT" & EXP_PID=$!
"$ALERTMANAGER" --config.file="$TMP/am.yml" --storage.path="$TMP/am-data" \
  --web.listen-address="127.0.0.1:$AMPORT" --cluster.listen-address="" --log.level=error >"$TMP/am.log" 2>&1 & AM_PID=$!
"$PROM" --config.file="$TMP/prometheus.yml" --storage.tsdb.path="$TMP/prom-data" \
  --web.listen-address="127.0.0.1:$PROMPORT" --log.level=error >"$TMP/prom.log" 2>&1 & PROM_PID=$!

for _ in $(seq 1 60); do curl -fsS "http://127.0.0.1:$AMPORT/-/ready" >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:$PROMPORT/-/ready" >/dev/null 2>&1 && break; sleep 0.5; done

echo "## 真 Prometheus 評估真規則 → CephOSDHostDownScoped{hostname=osd-host-a} firing"
got_label=""
for _ in $(seq 1 40); do
  got_label="$(curl -fsS "http://127.0.0.1:$PROMPORT/api/v1/alerts" 2>/dev/null \
    | jq -r '.data.alerts[] | select(.labels.alertname=="CephOSDHostDownScoped" and .state=="firing") | .labels.hostname' | head -1)"
  [ "$got_label" = "osd-host-a" ] && break
  sleep 0.5
done
if [ "$got_label" = "osd-host-a" ]; then
  ok "live Prometheus 產出 hostname=osd-host-a（與 Tier A 斷言一致）"
else
  no "Prometheus 未產出預期 alert（got='$got_label'）"
fi

echo "## 真實產出的 label 經真 AM routing 送到 pager sink"
for _ in $(seq 1 40); do
  awk -F'\t' '$1=="pager"&&$2=="CephOSDHostDownScoped"&&$3=="osd-host-a"{f=1} END{exit !f}' "$SINKLOG" && break
  sleep 0.5
done
if awk -F'\t' '$1=="pager"&&$2=="CephOSDHostDownScoped"&&$3=="osd-host-a"{f=1} END{exit !f}' "$SINKLOG"; then
  ok "→ pager 收到（真 label 全鏈路路由正確）"
else
  no "pager sink 未收到真實 alert"
fi

echo ""
echo "Tier C3 e2e: $pass passed, $fail failed"
cp "$SINKLOG" "$RESULTS/tierC3-sink.log" 2>/dev/null || true
exit $((fail > 0 ? 1 : 0))
