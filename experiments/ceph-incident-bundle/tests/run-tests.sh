#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

for path in \
  "$ROOT/run/collect.sh" \
  "$ROOT/lib/common.sh" \
  "$ROOT/lib/collect-cluster-cephadm.sh" \
  "$ROOT/lib/collect-cluster-rook.sh" \
  "$ROOT/lib/collect-node.sh" \
  "$ROOT/lib/verify-bundle.sh"; do
  [[ -f "$path" ]] || fail "missing $path"
done

for path in "$ROOT/run/collect.sh" "$ROOT/lib/verify-bundle.sh"; do
  [[ -x "$path" ]] || fail "not executable $path"
done

ok "required files exist"
