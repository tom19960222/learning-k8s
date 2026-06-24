#!/usr/bin/env bash
# Tier B — Alertmanager routing（amtool config routes test）。無外部服務。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
bash "$ROOT/tests/tierB-routing/routes-test.sh" | tee "$ROOT/results/tierB.txt"
rc=${PIPESTATUS[0]}
echo ""
[ "$rc" = 0 ] && echo "TIER B PASS" || echo "TIER B FAIL"
exit "$rc"
