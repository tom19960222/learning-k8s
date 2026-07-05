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

# CephLowPriorityNotice (ceph_health_detail{name=~"...|OSDMAP_FLAGS|..."} == 1,
# for: 30m) needs enough poll attempts to reliably outlast the 30m `for:`
# window; the framework default of 60 attempts * 5s = 300s is far short of
# that, so bump it up to 450 attempts * 5s = 2250s (37.5m), comfortably
# covering the 30m window. NOTE: a real (--yes-really-inject) run of this
# scenario therefore takes MORE THAN 30 MINUTES of wall-clock time — do not
# run it interactively without expecting a long wait.
PROMETHEUS_WAIT_ATTEMPTS="${PROMETHEUS_WAIT_ATTEMPTS:-450}"
export PROMETHEUS_WAIT_ATTEMPTS

scenario_inject() {
  run_capture "$RESULT_DIR/config-set-noout.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set noout"
}

scenario_rollback() {
  run_capture "$RESULT_DIR/rollback-config-unset-noout.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd unset noout" || return 1
}

scenario_verify() {
  wait_ceph_health_check OSDMAP_FLAGS "$RESULT_DIR"
  wait_prometheus_alert CephLowPriorityNotice name OSDMAP_FLAGS "$RESULT_DIR"
  wait_sink_alert slack CephLowPriorityNotice name OSDMAP_FLAGS "$RESULT_DIR" "$SINK_CHECKPOINT"
  assert_sink_absent pager CephLowPriorityNotice "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_main low-priority-notice "$@"
