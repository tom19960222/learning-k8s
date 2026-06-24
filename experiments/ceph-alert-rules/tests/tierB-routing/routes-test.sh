#!/usr/bin/env bash
# Tier B — Alertmanager routing：每個 label set → 正確 receiver。spec §4.13
# 核心斷言：帶 type=ceph_default 的預設 aggregate（除 CephHealthError）一律 slack，不得 pager。
# 用 `amtool config routes test` deterministic 驗證，無需起服務。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HERE/../../rules/alertmanager-route.yml"

# 找 amtool：PATH 優先，否則 ~/go/bin、harness .bin
AMTOOL="$(command -v amtool || true)"
[ -z "$AMTOOL" ] && [ -x "$HOME/go/bin/amtool" ] && AMTOOL="$HOME/go/bin/amtool"
[ -z "$AMTOOL" ] && [ -x "$HERE/../../.bin/amtool" ] && AMTOOL="$HERE/../../.bin/amtool"
if [ -z "$AMTOOL" ]; then echo "FATAL: amtool not found (PATH / ~/go/bin / .bin)"; exit 2; fi

fail=0; pass=0
check() {  # $1=expected receiver；其餘=label set
  local want="$1"; shift
  local got
  got="$("$AMTOOL" config routes test --config.file="$CFG" "$@" 2>&1)"
  if [ "$got" = "$want" ]; then
    printf 'ok   %-12s <- %s\n' "$got" "$*"; pass=$((pass+1))
  else
    printf 'FAIL want=%s got=%s <- %s\n' "$want" "$got" "$*"; fail=$((fail+1))
  fi
}

echo "## pager-ceph：CephHealthError + 自訂 stability/scoped 主訊號"
check pager-ceph alertname=CephHealthError      type=ceph_default
check pager-ceph alertname=CephClientBlocked    source=ceph_stability
check pager-ceph alertname=CephClientRisk       source=ceph_stability
check pager-ceph alertname=CephMonQuorumLost    source=ceph_stability
check pager-ceph alertname=CephExporterDown     source=ceph_stability
check pager-ceph alertname=CephOSDHostDownScoped   source=ceph_scoped
check pager-ceph alertname=CephOSDDaemonDownScoped source=ceph_scoped
check pager-ceph alertname=CephMonDownScoped     source=ceph_scoped

echo "## slack-ceph：LowPriority + 預設 aggregate（含 critical 的 aggregate 也不可 pager）"
check slack-ceph alertname=CephLowPriorityNotice source=ceph_stability
check slack-ceph alertname=CephHealthWarning      type=ceph_default
check slack-ceph alertname=CephMonDownQuorumAtRisk type=ceph_default   # critical aggregate → 仍 slack
check slack-ceph alertname=CephOSDDownHigh         type=ceph_default   # critical aggregate → 仍 slack
check slack-ceph alertname=CephMonDown             type=ceph_default
check slack-ceph alertname=CephOSDDown             type=ceph_default
check slack-ceph alertname=CephOSDHostDown         type=ceph_default

echo "## 兜底：無 match → 預設 slack-ceph"
check slack-ceph alertname=SomethingUnrelated

echo ""
echo "Tier B routing: $pass passed, $fail failed"
exit $((fail > 0 ? 1 : 0))
