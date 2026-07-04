#!/usr/bin/env bash
# Tier A — 規則邏輯單元測試（promtool）+ 防漂移 guard + lint。無外部服務。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
PROMTOOL="$(command -v promtool || true)"
[ -z "$PROMTOOL" ] && { echo "FATAL: promtool not found"; exit 2; }

echo "### guard：rules 與頁面一致"
bash "$ROOT/lib/check-rules-match-page.sh" || exit 1
echo ""
echo "### promtool check rules（lint）"
"$PROMTOOL" check rules "$ROOT"/rules/ceph-stability-first.yml "$ROOT"/rules/ceph-scoped-availability.yml \
  "$ROOT"/rules/ceph-production-coverage.yml "$ROOT"/rules/_default-mixin.yml \
  "$ROOT"/rules/ceph-mon-quorum-dynamic.yml || exit 1
echo ""
echo "### promtool test rules（單元測試）"
"$PROMTOOL" test rules "$ROOT"/tests/tierA-promtool/*.test.yml | tee "$ROOT/results/tierA.txt"
rc=${PIPESTATUS[0]}
echo ""
[ "$rc" = 0 ] && echo "TIER A PASS" || echo "TIER A FAIL"
exit "$rc"
