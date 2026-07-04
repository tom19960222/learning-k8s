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

MON_DOWN_NAME="${MON_DOWN_NAME:-ceph-lab-mon-03}"
_host_ip=""; _service=""

scenario_setup() {
  _host_ip="$(lab_mon_host_ip "$MON_DOWN_NAME")"
  _service="$(mon_service_name "$LAB_FSID" "$MON_DOWN_NAME")"
}

scenario_inject() {
  run_capture "$RESULT_DIR/stop-mon.txt" ssh_lab "$_host_ip" "sudo systemctl stop $_service"
}

scenario_rollback() {
  run_capture "$RESULT_DIR/rollback-start-mon.txt" ssh_lab "$_host_ip" "sudo systemctl start $_service" || return 1
}

scenario_verify() {
  wait_ceph_health_check MON_DOWN "$RESULT_DIR"
  wait_prometheus_alert CephMonDownScoped ceph_daemon "mon.$MON_DOWN_NAME" "$RESULT_DIR"
  assert_prometheus_alert_not_firing CephMonQuorumLost "" "" "$RESULT_DIR"
  wait_sink_alert pager CephMonDownScoped ceph_daemon "mon.$MON_DOWN_NAME" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_main mon-down-single "$@"
