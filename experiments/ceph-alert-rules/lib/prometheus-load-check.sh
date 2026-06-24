#!/usr/bin/env bash
# Tier C1 — 規則真載入：起一個真 prometheus 載入兩個 rule group，
# 查 /api/v1/rules 斷言每條預期 rule 都在且 health=ok。
# 抓 promtool test 抓不到的問題：recording-rule 順序、unknown function、group 載入失敗。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="$HERE/../rules"
RESULTS="$HERE/../results"
PROM="$(command -v prometheus || true)"
[ -z "$PROM" ] && { echo "FATAL: prometheus binary not found on PATH"; exit 2; }

PORT=9747
TMP="$(mktemp -d)"
cat > "$TMP/prometheus.yml" <<EOF
global:
  evaluation_interval: 5s
rule_files:
  - $RULES_DIR/ceph-stability-first.yml
  - $RULES_DIR/ceph-scoped-availability.yml
EOF

cleanup() { [ -n "${PROM_PID:-}" ] && kill "$PROM_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

"$PROM" --config.file="$TMP/prometheus.yml" \
  --storage.tsdb.path="$TMP/data" \
  --web.listen-address="127.0.0.1:$PORT" \
  --log.level=error >"$TMP/prom.log" 2>&1 &
PROM_PID=$!

# 輪詢 ready（最多 ~30s），不用固定 sleep
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$PORT/-/ready" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
[ "$ready" = 1 ] || { echo "FATAL: prometheus not ready"; sed -n '1,20p' "$TMP/prom.log"; exit 1; }

# 輪詢到「所有 rule 都已第一次評估」（沒有任何 unknown），兩個 group 各自排程故要等齊
rules_json=""
for _ in $(seq 1 40); do
  rules_json="$(curl -fsS "http://127.0.0.1:$PORT/api/v1/rules" 2>/dev/null)"
  n_unknown="$(printf '%s' "$rules_json" | jq -r '[.data.groups[].rules[] | select(.health=="unknown")] | length' 2>/dev/null)"
  [ "$n_unknown" = "0" ] && break
  sleep 0.5
done

expected=(CephClientBlocked CephClientRisk CephMonQuorumLost CephExporterDown CephLowPriorityNotice \
          "ceph:osd_up:with_hostname" "ceph:osd_host_down:scoped" \
          CephOSDHostDownScoped CephOSDDaemonDownScoped CephMonDownScoped)
fail=0
for r in "${expected[@]}"; do
  health="$(printf '%s' "$rules_json" | jq -r --arg n "$r" '.data.groups[].rules[] | select(.name==$n) | .health' | head -1)"
  if [ "$health" = "ok" ]; then printf 'ok    %-28s health=ok\n' "$r"
  else printf 'FAIL  %-28s health=%s\n' "$r" "${health:-MISSING}"; fail=1; fi
done

mkdir -p "$RESULTS"
printf '%s' "$rules_json" | jq '.data.groups[].name' > "$RESULTS/tierC-prom-load.txt" 2>/dev/null || true
[ "$fail" = 0 ] && echo "all rules healthy in a live prometheus" || echo "some rules unhealthy"
exit $fail
