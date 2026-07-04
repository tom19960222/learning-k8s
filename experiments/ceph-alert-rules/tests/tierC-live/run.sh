#!/usr/bin/env bash
# Tier C2 — live Alertmanager：routing 真送達 + silence 真壓制。spec §4.10→C / §4.14 + devil #9
# silence 斷言用 AM /api/v2/alerts 的 status.state（active/suppressed）→ deterministic，不靠 webhook 時序。
# routing 另用 webhook sink 證明 Prom→AM→receiver 整條 pipe 真的會送。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RESULTS="$HERE/../../results"; mkdir -p "$RESULTS"
SINKPORT=9748; AMPORT=9749
SINKLOG="$(mktemp)"; TMP="$(mktemp -d)"

find_bin() { command -v "$1" 2>/dev/null || { [ -x "$HOME/go/bin/$1" ] && echo "$HOME/go/bin/$1"; } || { [ -x "$HERE/../../.bin/$1" ] && echo "$HERE/../../.bin/$1"; }; }
ALERTMANAGER="$(find_bin alertmanager)"; AMTOOL="$(find_bin amtool)"
[ -z "$ALERTMANAGER" ] && { echo "FATAL: alertmanager not found"; exit 2; }
[ -z "$AMTOOL" ] && { echo "FATAL: amtool not found"; exit 2; }

# shellcheck disable=SC2329
# Invoked by the EXIT trap.
cleanup() {
  [ -n "${AM_PID:-}" ] && kill "$AM_PID" 2>/dev/null
  [ -n "${SINK_PID:-}" ] && kill "$SINK_PID" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$TMP" "$SINKLOG" 2>/dev/null
}
trap cleanup EXIT

fail=0; pass=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL %s\n' "$1"; fail=1; }

# --- 起 sink + alertmanager ---
python3 "$HERE/webhook-sink.py" "$SINKLOG" "$SINKPORT" & SINK_PID=$!
sed "s/__SINKPORT__/$SINKPORT/g" "$HERE/alertmanager-live.yml" > "$TMP/am.yml"
"$ALERTMANAGER" --config.file="$TMP/am.yml" --storage.path="$TMP/data" \
  --web.listen-address="127.0.0.1:$AMPORT" --cluster.listen-address="" \
  --log.level=error >"$TMP/am.log" 2>&1 & AM_PID=$!

ready=0
for _ in $(seq 1 60); do curl -fsS "http://127.0.0.1:$AMPORT/-/ready" >/dev/null 2>&1 && { ready=1; break; }; sleep 0.5; done
[ "$ready" = 1 ] || { echo "FATAL: alertmanager not ready"; sed -n '1,20p' "$TMP/am.log"; exit 1; }

post() {  # $1 = labels JSON
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  curl -fsS -XPOST "http://127.0.0.1:$AMPORT/api/v2/alerts" -H 'Content-Type: application/json' \
    -d "[{\"labels\":$1,\"annotations\":{\"summary\":\"t\"},\"startsAt\":\"$now\"}]" >/dev/null
}
state() {  # $1 alertname  $2 key value -> prints status.state
  curl -fsS "http://127.0.0.1:$AMPORT/api/v2/alerts" 2>/dev/null \
   | jq -r --arg an "$1" --arg kv "$2" \
     '.[] | select(.labels.alertname==$an) | select(($kv=="") or (.labels.hostname==$kv) or (.labels.ceph_daemon==$kv) or (.labels.name==$kv)) | .status.state' | head -1
}
wait_state() {  # $1 an $2 key $3 want
  for _ in $(seq 1 30); do [ "$(state "$1" "$2")" = "$3" ] && return 0; sleep 0.5; done; return 1
}
wait_sink() {  # $1 receiver $2 alertname $3 key
  for _ in $(seq 1 30); do
    awk -F'\t' -v r="$1" -v a="$2" -v k="$3" '$1==r&&$2==a&&$3==k{f=1} END{exit !f}' "$SINKLOG" && return 0
    sleep 0.5
  done; return 1
}

echo "## 場景 1：routing 真送達（Prom→AM→receiver pipe）"
post '{"alertname":"CephOSDHostDownScoped","hostname":"osd-host-a","severity":"critical","source":"ceph_scoped"}'
if wait_state CephOSDHostDownScoped osd-host-a active; then ok "CephOSDHostDownScoped{host-a} active"; else no "host-a not active"; fi
if wait_sink pager CephOSDHostDownScoped osd-host-a; then ok "→ webhook pager 收到 host-a"; else no "pager sink 未收到 host-a"; fi
# 預設 critical aggregate 走 slack（live 版核心斷言）
post '{"alertname":"CephMonDownQuorumAtRisk","type":"ceph_default","severity":"critical"}'
if wait_sink slack CephMonDownQuorumAtRisk -; then ok "預設 aggregate → webhook slack（非 pager）"; else no "aggregate 未到 slack"; fi

echo "## 場景 2：host 粒度 silence 只壓目標台"
"$AMTOOL" --alertmanager.url="http://127.0.0.1:$AMPORT" silence add \
  alertname=CephOSDHostDownScoped hostname=osd-host-a --duration=1h --comment="maint osd-host-a" >/dev/null 2>&1
post '{"alertname":"CephOSDHostDownScoped","hostname":"osd-host-a","severity":"critical","source":"ceph_scoped"}'
if wait_state CephOSDHostDownScoped osd-host-a suppressed; then ok "host-a 被 silence 壓成 suppressed"; else no "host-a 未被壓"; fi
post '{"alertname":"CephOSDHostDownScoped","hostname":"osd-host-b","severity":"critical","source":"ceph_scoped"}'
if wait_state CephOSDHostDownScoped osd-host-b active; then ok "host-b 未被波及（active）"; else no "host-b 被誤壓"; fi

echo "## 場景 3：silence 是 alertname+label 範圍（devil #9）"
# 同 hostname=osd-host-a 但不同 alertname → 不該被 host-a 那條 silence 壓到
post '{"alertname":"CephOSDDaemonDownScoped","hostname":"osd-host-a","ceph_daemon":"osd.5","severity":"critical","source":"ceph_scoped"}'
if wait_state CephOSDDaemonDownScoped osd.5 active; then ok "不同 alertname 同 host 不被誤壓（active）"; else no "alertname-scoping 失效"; fi

echo "## 場景 4：維護 silence 不得壓掉生命線"
post '{"alertname":"CephMonQuorumLost","severity":"critical","source":"ceph_stability"}'
if wait_state CephMonQuorumLost "" active; then ok "CephMonQuorumLost 仍 active（未被壓）"; else no "生命線被誤壓"; fi
post '{"alertname":"CephClientBlocked","name":"PG_AVAILABILITY","severity":"critical","source":"ceph_stability"}'
if wait_state CephClientBlocked PG_AVAILABILITY active; then ok "CephClientBlocked 仍 active（未被壓）"; else no "client-blocked 被誤壓"; fi

echo ""
echo "Tier C2 live: $pass passed, $fail failed"
cp "$SINKLOG" "$RESULTS/tierC-sink.log" 2>/dev/null || true
exit $((fail > 0 ? 1 : 0))
