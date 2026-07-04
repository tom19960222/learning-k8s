#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

for path in \
  "$ROOT/lib/common.sh" \
  "$ROOT/lib/scenarios.sh" \
  "$ROOT/lib/monitoring.sh" \
  "$ROOT/lib/evidence.sh" \
  "$ROOT/tests/test-common.sh" \
  "$ROOT/tests/test-scenario-commands.sh" \
  "$ROOT/tests/test-scenario-slow-ops.sh" \
  "$ROOT/tests/test-scenario-pg-availability.sh" \
  "$ROOT/tests/test-evidence.sh" \
  "$ROOT/tests/test-monitoring-render.sh"; do
  [[ -f "$path" ]] || fail "missing $path"
done

bash "$ROOT/tests/test-common.sh"
bash "$ROOT/tests/test-scenario-commands.sh"
bash "$ROOT/tests/test-scenario-slow-ops.sh"
bash "$ROOT/tests/test-scenario-pg-availability.sh"
bash "$ROOT/tests/test-evidence.sh"
bash "$ROOT/tests/test-monitoring-render.sh"
ok "unit tests"
