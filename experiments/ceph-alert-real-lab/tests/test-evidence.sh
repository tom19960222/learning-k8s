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

cleanup() {
  [[ -n "$success_dir" ]] && rm -rf "$success_dir"
  [[ -n "$failure_dir" ]] && rm -rf "$failure_dir"
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

ok "evidence helpers"
