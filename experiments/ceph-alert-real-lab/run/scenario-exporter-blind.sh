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

# CephMetricsAbsent (absent(ceph_health_status), for: 5m) and CephExporterAllDown
# ((count(up{job="ceph"} == 1) or vector(0)) == 0, for: 5m) both need enough
# poll attempts to reliably outlast the 5m `for:` window; the framework
# default of 60 attempts * 5s = 300s is exactly the boundary, so bump it up.
PROMETHEUS_WAIT_ATTEMPTS="${PROMETHEUS_WAIT_ATTEMPTS:-90}"
export PROMETHEUS_WAIT_ATTEMPTS

scenario_inject() {
  run_capture "$RESULT_DIR/disable-prometheus-module.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph mgr module disable prometheus"
}

scenario_rollback() {
  run_capture "$RESULT_DIR/rollback-enable-prometheus-module.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph mgr module enable prometheus" || return 1
}

# NOTE: while the prometheus mgr module is disabled, CephMonQuorumLost's
# `(count(ceph_mon_quorum_status == 1) or vector(0)) < 2` expression also
# evaluates to firing, because ceph_mon_quorum_status is exported by the
# same disabled module (empty series -> `or vector(0)` -> 0 < 2). This
# scenario intentionally does not assert on CephMonQuorumLost either way:
# co-firing here is a documented trade-off of the F1 empty-series fix
# (silence-on-total-blackout is exactly the failure mode F1 closed), not a
# bug in this scenario.
scenario_verify() {
  wait_prometheus_alert CephMetricsAbsent "" "" "$RESULT_DIR"
  wait_prometheus_alert CephExporterAllDown "" "" "$RESULT_DIR"
  wait_sink_alert pager CephMetricsAbsent "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
  wait_sink_alert pager CephExporterAllDown "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_main exporter-blind "$@"
