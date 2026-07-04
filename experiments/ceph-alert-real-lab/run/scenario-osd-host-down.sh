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

OSD_HOST_DOWN_HOST="${OSD_HOST_DOWN_HOST:-ceph-lab-osd-02}"
_host_ip=""
stop_step=1
restart_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

scenario_setup() {
  local target_file="$RESULT_DIR/target-osds.txt" target_count
  _host_ip="$(lab_osd_host_ip "$OSD_HOST_DOWN_HOST")"
  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd ls-tree $OSD_HOST_DOWN_HOST" >"$target_file"
  target_count="$(wc -l <"$target_file" | tr -d ' ')"
  [[ "$target_count" -gt 0 ]] || die "no OSDs found on $OSD_HOST_DOWN_HOST"
}

scenario_inject() {
  local target_file="$RESULT_DIR/target-osds.txt" osd service
  while IFS= read -r osd; do
    [[ -n "$osd" ]] || continue
    service="$(osd_service_name "$LAB_FSID" "$osd")"
    run_live_step "stop-osd-$((stop_step))" "$_host_ip" "sudo systemctl stop $service"
    stop_step=$((stop_step + 1))
  done <"$target_file"
}

scenario_verify() {
  local target_file="$RESULT_DIR/target-osds.txt" osd
  wait_prometheus_alert CephOSDHostDownScoped hostname "$OSD_HOST_DOWN_HOST" "$RESULT_DIR"
  while IFS= read -r osd; do
    [[ -n "$osd" ]] || continue
    assert_prometheus_alert_not_firing CephOSDDaemonDownScoped ceph_daemon "osd.$osd" "$RESULT_DIR"
  done <"$target_file"
  wait_sink_alert pager CephOSDHostDownScoped hostname "$OSD_HOST_DOWN_HOST" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local target_file="$RESULT_DIR/target-osds.txt" osd service rc=0
  if [[ -f "$target_file" ]]; then
    while IFS= read -r osd; do
      [[ -n "$osd" ]] || continue
      service="$(osd_service_name "$LAB_FSID" "$osd")"
      run_live_step "rollback-start-$((restart_step))" "$_host_ip" "sudo systemctl start $service" || rc=1
      restart_step=$((restart_step + 1))
    done <"$target_file"
  fi
  return "$rc"
}

scenario_main osd-host-down "$@"
