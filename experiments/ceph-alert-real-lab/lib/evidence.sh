#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"

ceph_seed_cmd() {
  ssh_lab "$LAB_MON_01_HOST" sudo -n cephadm shell -- ceph "$@"
}

collect_baseline() {
  local result_dir=$1
  mkdir -p "$result_dir"

  run_capture "$result_dir/ceph-s.txt" ceph_seed_cmd -s || true
  run_capture "$result_dir/ceph-health-detail.txt" ceph_seed_cmd health detail || true
  run_capture "$result_dir/ceph-osd-tree.txt" ceph_seed_cmd osd tree || true
  run_capture "$result_dir/ceph-quorum-status.json" ceph_seed_cmd quorum_status --format json || true
  run_capture "$result_dir/mgr-metrics-health-detail.txt" curl -fsS "$LAB_MGR_ENDPOINT/metrics" || true
  run_capture "$result_dir/rook-cephcluster.txt" kubectl_lab -n rook-ceph-external get cephcluster -o wide || true
  run_capture "$result_dir/rook-pods.txt" kubectl_lab -n rook-ceph get pods -o wide || true
}

collect_postcheck() {
  collect_baseline "$1"
}

assert_ceph_health_check() {
  local check_name=$1
  local result_dir=$2
  local output_file="$result_dir/health-check-${check_name}.txt"

  run_capture "$output_file" ceph_seed_cmd health detail || return $?
  grep -Fq -- "$check_name" "$output_file"
}
