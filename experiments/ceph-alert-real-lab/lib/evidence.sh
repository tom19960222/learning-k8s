#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"

ceph_seed_cmd() {
  ssh_lab "$LAB_MON_01_HOST" sudo -n cephadm shell -- ceph "$@"
}

collect_baseline() {
  local result_dir=$1 endpoint safe_endpoint
  mkdir -p "$result_dir"

  run_capture "$result_dir/ceph-s.txt" ceph_seed_cmd -s || true
  run_capture "$result_dir/ceph-health-detail.txt" ceph_seed_cmd health detail || true
  run_capture "$result_dir/ceph-osd-tree.txt" ceph_seed_cmd osd tree || true
  run_capture "$result_dir/ceph-quorum-status.json" ceph_seed_cmd quorum_status --format json || true
  for endpoint in $LAB_MGR_ENDPOINTS; do
    safe_endpoint="$(printf '%s' "$endpoint" | sed 's#^https\{0,1\}://##; s#[/:]#-#g')"
    run_capture "$result_dir/mgr-metrics-${safe_endpoint}.txt" curl -fsS "$endpoint/metrics" || true
  done
  run_capture "$result_dir/rook-cephcluster.txt" kubectl_lab -n rook-ceph-external get cephcluster -o wide || true
  run_capture "$result_dir/rook-pods.txt" kubectl_lab -n rook-ceph get pods -o wide || true
}

collect_postcheck() {
  collect_baseline "$1"
}

assert_prometheus_ceph_target_up() {
  local result_dir=$1 output_file
  output_file="$result_dir/prometheus-up-ceph.json"

  prometheus_query 'up{job="ceph"}' >"$output_file"
  jq -e '.data.result[]? | select(.value[1]=="1")' "$output_file" >/dev/null
}

assert_rook_external_ready() {
  local result_dir=$1 output_file
  output_file="$result_dir/rook-cephcluster-ready.txt"

  run_capture "$output_file" kubectl_lab -n rook-ceph-external get cephcluster -o wide || return $?
  grep -Fq -- 'Connected' "$output_file" && grep -Fq -- 'HEALTH_OK' "$output_file"
}

assert_ceph_ready() {
  local result_dir=$1 output_file
  output_file="$result_dir/ceph-ready.txt"

  run_capture "$output_file" ceph_seed_cmd -s || return $?
  grep -Fq -- 'HEALTH_OK' "$output_file"
}

assert_lab_ready() {
  local result_dir=$1
  mkdir -p "$result_dir"

  assert_ceph_ready "$result_dir" || return 1
  assert_rook_external_ready "$result_dir" || return 1
  assert_prometheus_ceph_target_up "$result_dir" || return 1
}

assert_lab_recovered() {
  local result_dir=$1 attempts="${LAB_RECOVERY_ATTEMPTS:-60}" sleep_seconds="${LAB_RECOVERY_SLEEP:-5}"
  mkdir -p "$result_dir"

  poll_until "Ceph/Rook/Prometheus recovered" "$attempts" "$sleep_seconds" assert_lab_ready "$result_dir"
}

assert_ceph_health_check() {
  local check_name=$1
  local result_dir=$2
  local output_file
  output_file="$result_dir/health-check-${check_name}.txt"

  run_capture "$output_file" ceph_seed_cmd health detail || return $?
  grep -Fq -- "$check_name" "$output_file"
}

wait_ceph_health_check() {
  local check_name=$1 result_dir=$2 attempts="${CEPH_HEALTH_CHECK_ATTEMPTS:-60}" sleep_seconds="${CEPH_HEALTH_CHECK_SLEEP:-5}"

  poll_until "Ceph health check $check_name present" "$attempts" "$sleep_seconds" assert_ceph_health_check "$check_name" "$result_dir"
}

_bluestore_slow_op_alert_absent() {
  local result_dir=$1 output_file
  output_file="$result_dir/bluestore-slow-ops-health-poll.txt"
  run_capture "$output_file" ceph_seed_cmd health detail || return 1
  ! grep -Fq 'BLUESTORE_SLOW_OP_ALERT' "$output_file"
}

# clear_bluestore_slow_ops <result_dir> clears the 24h-latched
# BLUESTORE_SLOW_OP_ALERT warning. Any scenario that throttles OSD I/O hard
# enough to also trip BLUESTORE_SLOW_OP_ALERT (a per-OSD latch, distinct from
# the SLOW_OPS health check some scenarios target on purpose) must call this
# from its rollback so assert_lab_recovered can reach HEALTH_OK afterward.
# This used to restart every OSD still reporting it, but on the real cluster
# that rolling restart was disruptive and repeatedly left cephadm's daemon
# inventory in a stale "unknown" state (CEPHADM_FAILED_DAEMON -> HEALTH_WARN
# -> recovery gate timeout). Verified cleaner method: temporarily shrink the
# warning's lifetime/threshold so the latch ages out cluster-wide in ~20s (no
# daemon restart involved), then restore the defaults.
clear_bluestore_slow_ops() {
  local result_dir=$1 health_file rc=0

  health_file="$result_dir/bluestore-slow-ops-health.txt"
  run_capture "$health_file" ceph_seed_cmd health detail || return 0
  grep -Fq 'BLUESTORE_SLOW_OP_ALERT' "$health_file" || return 0

  log "age out latched BLUESTORE_SLOW_OP_ALERT via bluestore_slow_ops_warn_lifetime=1"
  run_capture "$result_dir/bluestore-warn-lifetime-set.txt" \
    ceph_seed_cmd config set osd bluestore_slow_ops_warn_lifetime 1 || rc=1
  run_capture "$result_dir/bluestore-warn-threshold-set.txt" \
    ceph_seed_cmd config set osd bluestore_slow_ops_warn_threshold 1 || rc=1

  poll_until "BLUESTORE_SLOW_OP_ALERT cleared" \
    "${BLUESTORE_CLEAR_ATTEMPTS:-18}" "${BLUESTORE_CLEAR_SLEEP:-5}" \
    _bluestore_slow_op_alert_absent "$result_dir" || rc=1

  # Always restore defaults, even on poll timeout above: a lingering
  # bluestore_slow_ops_warn_lifetime=1 would silently suppress this warning
  # for real incidents later.
  run_capture "$result_dir/bluestore-warn-lifetime-rm.txt" \
    ceph_seed_cmd config rm osd bluestore_slow_ops_warn_lifetime || rc=1
  run_capture "$result_dir/bluestore-warn-threshold-rm.txt" \
    ceph_seed_cmd config rm osd bluestore_slow_ops_warn_threshold || rc=1

  return "$rc"
}
