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

ok "evidence helpers"
