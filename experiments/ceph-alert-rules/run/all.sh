#!/usr/bin/env bash
# 一鍵跑 Tier A→B→C。逐 tier 印 PASS/FAIL，任一非 0 即整體 FAIL。
# Tier D 是真 ceph 對照表（人工），不在此自動跑。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
overall=0
for t in A B C; do
  echo "========================================"
  echo "===============  TIER $t  ==============="
  echo "========================================"
  bash "$HERE/tier${t}.sh" || overall=1
  echo ""
done
echo "========================================"
[ "$overall" = 0 ] && echo "ALL PASS" || echo "ALL FAIL（見上方哪個 tier）"
exit "$overall"
