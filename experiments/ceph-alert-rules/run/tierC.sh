#!/usr/bin/env bash
# Tier C — live 整合 smoke：C1 規則真載入 prometheus + C2 live alertmanager routing/silence。
# 需要 prometheus（PATH）與 alertmanager/amtool（PATH / ~/go/bin / .bin）。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
rc=0
echo "### C1 — 規則載入真 prometheus"
bash "$ROOT/lib/prometheus-load-check.sh" || rc=1
echo ""
echo "### C2 — live alertmanager routing + silence"
bash "$ROOT/tests/tierC-live/run.sh" || rc=1
echo ""
echo "### C3 — 全鏈路端到端（metric→Prometheus→AM→sink，真 label）"
bash "$ROOT/tests/tierC-live/run-e2e.sh" || rc=1
echo ""
[ "$rc" = 0 ] && echo "TIER C PASS" || echo "TIER C FAIL"
exit "$rc"
