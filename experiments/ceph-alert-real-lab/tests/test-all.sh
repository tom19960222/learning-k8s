#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
before_dirs_file="$(mktemp)"
after_dirs_file="$(mktemp)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$before_dirs_file" "$after_dirs_file"
}

trap cleanup EXIT

find "$ROOT/results" -maxdepth 1 -type d | sort >"$before_dirs_file"

set +e
bash "$ROOT/run/all.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "all.sh should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'all requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
cmp -s "$before_dirs_file" "$after_dirs_file" || fail "all.sh created result dirs before destructive ack"

ok "all.sh destructive ack guard"

# Structural regression check for the all.sh v2 scenario order (config-only
# first, then service-level, single-daemon up/down, degradation, pg-availability,
# capacity stages, data-integrity, low-priority-notice, most-disruptive-last,
# cleanup). This greps the script's own text rather than executing it, since a
# real run would require the actual lab.
expected_order_file="$(mktemp)"
actual_order_file="$(mktemp)"
cat >"$expected_order_file" <<'EOF'
deploy-monitoring.sh
baseline.sh
scenario-catch-all-risk.sh
scenario-mon-disk-low.sh
scenario-mon-clock-skew.sh
scenario-mgr-failover.sh
scenario-exporter-blind.sh
scenario-osd-daemon-down.sh
scenario-mon-down-single.sh
scenario-osd-host-down.sh
scenario-daemon-crash.sh
scenario-osd-flapping.sh
scenario-slow-ops.sh
scenario-latency-outlier.sh
scenario-net-slow-heartbeat.sh
scenario-pg-availability.sh
scenario-pool-quota.sh
scenario-capacity-ladder.sh
scenario-capacity-forecast.sh
scenario-data-damage.sh
scenario-object-unfound.sh
scenario-low-priority-notice.sh
scenario-mon-quorum-lost.sh
cleanup.sh
EOF
grep -oE 'run/[A-Za-z0-9_-]+\.sh' "$ROOT/run/all.sh" | sed 's#run/##' >"$actual_order_file"
diff "$expected_order_file" "$actual_order_file" >/dev/null ||
  fail "all.sh v2 scenario order does not match the spec order: $(diff "$expected_order_file" "$actual_order_file" || true)"
rm -f "$expected_order_file" "$actual_order_file"

ok "all.sh v2 scenario order matches the spec"
