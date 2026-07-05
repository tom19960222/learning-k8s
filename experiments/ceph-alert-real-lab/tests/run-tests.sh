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
  "$ROOT/tests/test-all.sh" \
  "$ROOT/tests/test-cleanup.sh" \
  "$ROOT/tests/test-scenario-commands.sh" \
  "$ROOT/tests/test-scenario-slow-ops.sh" \
  "$ROOT/tests/test-scenario-pg-availability.sh" \
  "$ROOT/tests/test-scenario-mon-quorum-lost.sh" \
  "$ROOT/tests/test-scenario-osd-daemon-down.sh" \
  "$ROOT/tests/test-scenario-osd-host-down.sh" \
  "$ROOT/tests/test-scenario-mon-down-single.sh" \
  "$ROOT/tests/test-scenario-exporter-blind.sh" \
  "$ROOT/tests/test-scenario-mgr-failover.sh" \
  "$ROOT/tests/test-scenario-catch-all-risk.sh" \
  "$ROOT/tests/test-scenario-low-priority-notice.sh" \
  "$ROOT/tests/test-scenario-latency-outlier.sh" \
  "$ROOT/tests/test-scenario-net-slow-heartbeat.sh" \
  "$ROOT/tests/test-scenario-mon-clock-skew.sh" \
  "$ROOT/tests/test-scenario-daemon-crash.sh" \
  "$ROOT/tests/test-scenario-osd-flapping.sh" \
  "$ROOT/tests/test-scenario-capacity-ladder.sh" \
  "$ROOT/tests/test-scenario-pool-quota.sh" \
  "$ROOT/tests/test-scenario-capacity-forecast.sh" \
  "$ROOT/tests/test-scenario-framework.sh" \
  "$ROOT/tests/test-evidence.sh" \
  "$ROOT/tests/test-monitoring-render.sh"; do
  [[ -f "$path" ]] || fail "missing $path"
done

bash "$ROOT/tests/test-common.sh"
bash "$ROOT/tests/test-all.sh"
bash "$ROOT/tests/test-cleanup.sh"
bash "$ROOT/tests/test-scenario-commands.sh"
bash "$ROOT/tests/test-scenario-slow-ops.sh"
bash "$ROOT/tests/test-scenario-pg-availability.sh"
bash "$ROOT/tests/test-scenario-mon-quorum-lost.sh"
bash "$ROOT/tests/test-scenario-osd-daemon-down.sh"
bash "$ROOT/tests/test-scenario-osd-host-down.sh"
bash "$ROOT/tests/test-scenario-mon-down-single.sh"
bash "$ROOT/tests/test-scenario-exporter-blind.sh"
bash "$ROOT/tests/test-scenario-mgr-failover.sh"
bash "$ROOT/tests/test-scenario-catch-all-risk.sh"
bash "$ROOT/tests/test-scenario-low-priority-notice.sh"
bash "$ROOT/tests/test-scenario-latency-outlier.sh"
bash "$ROOT/tests/test-scenario-net-slow-heartbeat.sh"
bash "$ROOT/tests/test-scenario-mon-clock-skew.sh"
bash "$ROOT/tests/test-scenario-daemon-crash.sh"
bash "$ROOT/tests/test-scenario-osd-flapping.sh"
bash "$ROOT/tests/test-scenario-capacity-ladder.sh"
bash "$ROOT/tests/test-scenario-pool-quota.sh"
bash "$ROOT/tests/test-scenario-capacity-forecast.sh"
bash "$ROOT/tests/test-scenario-framework.sh"
bash "$ROOT/tests/test-evidence.sh"
bash "$ROOT/tests/test-monitoring-render.sh"
ok "unit tests"
