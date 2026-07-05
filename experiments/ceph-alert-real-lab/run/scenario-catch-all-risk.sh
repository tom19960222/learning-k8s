#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/monitoring.sh
source "$ROOT/lib/monitoring.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/evidence.sh
source "$ROOT/lib/evidence.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/scenarios.sh
source "$ROOT/lib/scenarios.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/scenario-framework.sh
source "$ROOT/lib/scenario-framework.sh"

# CephClientRisk (ceph_health_detail{name!~"..."} == 1, for: 5m) needs enough
# poll attempts to reliably outlast the 5m `for:` window; the framework
# default of 60 attempts * 5s = 300s is exactly the boundary, so bump it up.
PROMETHEUS_WAIT_ATTEMPTS="${PROMETHEUS_WAIT_ATTEMPTS:-90}"
export PROMETHEUS_WAIT_ATTEMPTS

scenario_inject() {
  run_capture "$RESULT_DIR/config-set-down-out-interval.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph config set mon mon_osd_down_out_interval 0"
}

scenario_rollback() {
  run_capture "$RESULT_DIR/rollback-config-rm-down-out-interval.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph config rm mon mon_osd_down_out_interval" || return 1
}

scenario_verify() {
  wait_ceph_health_check OSD_NO_DOWN_OUT_INTERVAL "$RESULT_DIR"
  wait_prometheus_alert CephClientRisk name OSD_NO_DOWN_OUT_INTERVAL "$RESULT_DIR"
  wait_sink_alert pager CephClientRisk name OSD_NO_DOWN_OUT_INTERVAL "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_main catch-all-risk "$@"
