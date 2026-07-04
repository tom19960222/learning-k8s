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

OSD_DOWN_HOST="${OSD_DOWN_HOST:-ceph-lab-osd-01}"
OSD_DOWN_ID="${OSD_DOWN_ID:-}"
_host_ip=""; _service=""

scenario_setup() {
  _host_ip="$(lab_osd_host_ip "$OSD_DOWN_HOST")"
  if [[ -z "$OSD_DOWN_ID" ]]; then
    OSD_DOWN_ID="$(ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd ls-tree $OSD_DOWN_HOST" | head -1 | tr -d '[:space:]')"
  fi
  [[ -n "$OSD_DOWN_ID" ]] || die "no OSD found on $OSD_DOWN_HOST"
  _service="$(osd_service_name "$LAB_FSID" "$OSD_DOWN_ID")"
}

scenario_inject() {
  run_capture "$RESULT_DIR/stop-osd.txt" ssh_lab "$_host_ip" "sudo systemctl stop $_service"
}

scenario_rollback() {
  run_capture "$RESULT_DIR/rollback-start-osd.txt" ssh_lab "$_host_ip" "sudo systemctl start $_service" || return 1
}

scenario_verify() {
  wait_ceph_health_check OSD_DOWN "$RESULT_DIR"
  wait_prometheus_alert CephOSDDaemonDownScoped ceph_daemon "osd.$OSD_DOWN_ID" "$RESULT_DIR"
  assert_prometheus_alert_not_firing CephOSDHostDownScoped hostname "$OSD_DOWN_HOST" "$RESULT_DIR"
  wait_sink_alert pager CephOSDDaemonDownScoped ceph_daemon "osd.$OSD_DOWN_ID" "$RESULT_DIR" "$SINK_CHECKPOINT"
  wait_sink_alert slack CephOSDDown "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_main osd-daemon-down "$@"
