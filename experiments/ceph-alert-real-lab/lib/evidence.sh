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
