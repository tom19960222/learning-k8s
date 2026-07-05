#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/evidence.sh
source "$ROOT/lib/evidence.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

success_dir="$(mktemp -d)"
failure_dir=""
ready_dir=""
recovered_dir=""
recovery_fail_dir=""
LAB_RECOVERY_ATTEMPTS=1
LAB_RECOVERY_SLEEP=0

cleanup() {
  [[ -n "$success_dir" ]] && rm -rf "$success_dir"
  [[ -n "$failure_dir" ]] && rm -rf "$failure_dir"
  [[ -n "$ready_dir" ]] && rm -rf "$ready_dir"
  [[ -n "$recovered_dir" ]] && rm -rf "$recovered_dir"
  [[ -n "$recovery_fail_dir" ]] && rm -rf "$recovery_fail_dir"
}

trap cleanup EXIT

# shellcheck disable=SC2329
ceph_seed_cmd() {
  printf 'HEALTH_OK SLOW_OPS\n'
}

if ! assert_ceph_health_check SLOW_OPS "$success_dir"; then
  fail "assert_ceph_health_check should pass when the health detail contains SLOW_OPS"
fi
grep -Fq -- 'SLOW_OPS' "$success_dir/health-check-SLOW_OPS.txt" || fail "success capture missing SLOW_OPS"

failure_dir="$(mktemp -d)"
printf 'SLOW_OPS\n' >"$failure_dir/health-check-SLOW_OPS.txt"

# shellcheck disable=SC2329
ceph_seed_cmd() {
  printf 'SLOW_OPS\n'
  return 1
}

if assert_ceph_health_check SLOW_OPS "$failure_dir"; then
  fail "assert_ceph_health_check should fail when ceph_seed_cmd fails"
fi
grep -Fq -- 'SLOW_OPS' "$failure_dir/health-check-SLOW_OPS.txt" || fail "failure capture missing SLOW_OPS"

# shellcheck disable=SC2329
kubectl_lab() {
  printf 'rook-ceph-external Connected HEALTH_OK\n'
}

# shellcheck disable=SC2329
prometheus_query() {
  [[ "$1" == 'up{job="ceph"}' ]] || return 1
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
}

# shellcheck disable=SC2329
ceph_seed_cmd() {
  printf 'HEALTH_OK\n'
}

ready_dir="$(mktemp -d)"
if ! assert_lab_ready "$ready_dir"; then
  fail "assert_lab_ready should pass when Ceph, Rook, and Prometheus are ready"
fi
[[ -s "$ready_dir/ceph-ready.txt" ]] || fail "ready check did not capture Ceph evidence"
[[ -s "$ready_dir/rook-cephcluster-ready.txt" ]] || fail "ready check did not capture Rook evidence"
[[ -s "$ready_dir/prometheus-up-ceph.json" ]] || fail "ready check did not capture Prometheus evidence"

recovered_dir="$(mktemp -d)"
if ! assert_lab_recovered "$recovered_dir"; then
  fail "assert_lab_recovered should pass through assert_lab_ready"
fi

# shellcheck disable=SC2329
ceph_seed_cmd() {
  printf 'HEALTH_ERR still degraded\n'
}

recovery_fail_dir="$(mktemp -d)"
if assert_lab_recovered "$recovery_fail_dir"; then
  fail "assert_lab_recovered should fail when Ceph does not return to HEALTH_OK"
fi
grep -Fq -- 'HEALTH_ERR' "$recovery_fail_dir/ceph-ready.txt" || fail "recovery failure did not save Ceph evidence"

no_alert_dir="$(mktemp -d)"
alert_calls_file="$(mktemp)"

# shellcheck disable=SC2329
ceph_seed_cmd() {
  printf 'call\n' >>"$alert_calls_file"
  printf 'HEALTH_OK\n'
}

if ! clear_bluestore_slow_ops "$no_alert_dir"; then
  fail "clear_bluestore_slow_ops should be a no-op when BLUESTORE_SLOW_OP_ALERT is absent"
fi
calls="$(wc -l <"$alert_calls_file" | tr -d ' ')"
[[ "$calls" -eq 1 ]] || fail "clear_bluestore_slow_ops should only check health detail once when the alert is absent, saw $calls calls"
rm -rf "$no_alert_dir"
rm -f "$alert_calls_file"

clear_success_dir="$(mktemp -d)"
clear_health_calls_file="$(mktemp)"
BLUESTORE_CLEAR_ATTEMPTS=5
BLUESTORE_CLEAR_SLEEP=0

# shellcheck disable=SC2329
ceph_seed_cmd() {
  if [[ "$1 $2" == "health detail" ]]; then
    calls=0
    [[ -f "$clear_health_calls_file" ]] && calls="$(cat "$clear_health_calls_file")"
    calls=$((calls + 1))
    printf '%s' "$calls" >"$clear_health_calls_file"
    if [[ "$calls" -le 2 ]]; then
      printf 'HEALTH_WARN BLUESTORE_SLOW_OP_ALERT 1 OSD(s) experiencing BlueStore slow operation(s)\n'
    else
      printf 'HEALTH_OK\n'
    fi
    return 0
  fi
  printf '%s\n' "$*"
}

if ! clear_bluestore_slow_ops "$clear_success_dir"; then
  fail "clear_bluestore_slow_ops should succeed once the alert ages out"
fi
grep -Fq -- 'config set osd bluestore_slow_ops_warn_lifetime 1' "$clear_success_dir/bluestore-warn-lifetime-set.txt" || fail "missing lifetime=1 config set"
grep -Fq -- 'config set osd bluestore_slow_ops_warn_threshold 1' "$clear_success_dir/bluestore-warn-threshold-set.txt" || fail "missing threshold=1 config set"
grep -Fq -- 'config rm osd bluestore_slow_ops_warn_lifetime' "$clear_success_dir/bluestore-warn-lifetime-rm.txt" || fail "missing lifetime restore"
grep -Fq -- 'config rm osd bluestore_slow_ops_warn_threshold' "$clear_success_dir/bluestore-warn-threshold-rm.txt" || fail "missing threshold restore"
health_polls="$(cat "$clear_health_calls_file")"
[[ "$health_polls" -ge 3 ]] || fail "expected clear_bluestore_slow_ops to poll health detail repeatedly before it cleared, saw $health_polls"
rm -rf "$clear_success_dir"
rm -f "$clear_health_calls_file"

clear_timeout_dir="$(mktemp -d)"
BLUESTORE_CLEAR_ATTEMPTS=2
BLUESTORE_CLEAR_SLEEP=0

# shellcheck disable=SC2329
ceph_seed_cmd() {
  if [[ "$1 $2" == "health detail" ]]; then
    printf 'HEALTH_WARN BLUESTORE_SLOW_OP_ALERT 1 OSD(s) experiencing BlueStore slow operation(s)\n'
    return 0
  fi
  printf '%s\n' "$*"
}

if clear_bluestore_slow_ops "$clear_timeout_dir"; then
  fail "clear_bluestore_slow_ops should fail when the alert never clears"
fi
grep -Fq -- 'config set osd bluestore_slow_ops_warn_lifetime 1' "$clear_timeout_dir/bluestore-warn-lifetime-set.txt" || fail "missing lifetime=1 config set on timeout path"
grep -Fq -- 'config rm osd bluestore_slow_ops_warn_lifetime' "$clear_timeout_dir/bluestore-warn-lifetime-rm.txt" || fail "restore must still run after a poll timeout"
grep -Fq -- 'config rm osd bluestore_slow_ops_warn_threshold' "$clear_timeout_dir/bluestore-warn-threshold-rm.txt" || fail "restore must still run after a poll timeout"
rm -rf "$clear_timeout_dir"

ok "evidence helpers"
