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

# RECENT_CRASH needs the ceph-crash daemon to notice the crashdump, package
# it, and post it to the mon, which can lag well past the framework's
# default 60 attempts * 5s = 300s window.
CEPH_HEALTH_CHECK_ATTEMPTS="${CEPH_HEALTH_CHECK_ATTEMPTS:-120}"
export CEPH_HEALTH_CHECK_ATTEMPTS

DAEMON_CRASH_HOST="${DAEMON_CRASH_HOST:-ceph-lab-osd-01}"
DAEMON_CRASH_OSD_ID="${DAEMON_CRASH_OSD_ID:-}"
_host_ip=""; _service=""; _pid=""

scenario_setup() {
  _host_ip="$(lab_osd_host_ip "$DAEMON_CRASH_HOST")"
  if [[ -z "$DAEMON_CRASH_OSD_ID" ]]; then
    DAEMON_CRASH_OSD_ID="$(ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd ls-tree $DAEMON_CRASH_HOST" | head -1 | tr -d '[:space:]')"
  fi
  [[ -n "$DAEMON_CRASH_OSD_ID" ]] || die "no OSD found on $DAEMON_CRASH_HOST"
  _service="$(osd_service_name "$LAB_FSID" "$DAEMON_CRASH_OSD_ID")"
  _pid="$(ssh_lab "$_host_ip" "systemctl show -p MainPID --value $_service" | tr -d '[:space:]')"
  [[ -n "$_pid" && "$_pid" != "0" ]] || die "could not resolve MainPID for $_service on $_host_ip"
  printf '%s\n' "$_pid" >"$RESULT_DIR/target-osd-pid.txt"
}

scenario_inject() {
  run_capture "$RESULT_DIR/kill-segv.txt" ssh_lab "$_host_ip" "sudo kill -SEGV $_pid"
}

scenario_verify() {
  wait_ceph_health_check RECENT_CRASH "$RESULT_DIR"
  wait_prometheus_alert CephDaemonRecentCrash "" "" "$RESULT_DIR"
  # RECENT_CRASH is warning severity (not critical), so it must route to
  # slack only -- pin the evidence that it never leaks to the pager receiver.
  wait_sink_alert slack CephDaemonRecentCrash "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
  assert_sink_absent pager CephDaemonRecentCrash "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

osd_service_is_active() {
  ssh_lab "$_host_ip" "systemctl is-active $_service" | grep -qx active
}

scenario_rollback() {
  local rc=0
  run_capture "$RESULT_DIR/rollback-crash-archive-all.txt" ceph_seed_cmd crash archive-all || rc=1
  # A SIGSEGV crash is caught by systemd's on-failure restart policy on ceph
  # OSD units, so the service is usually already active again by the time we
  # get here; poll for that first and only fall back to an explicit start if
  # systemd never brought it back on its own.
  if ! poll_until "osd $_service active again after SEGV" "${DAEMON_CRASH_RESTART_ATTEMPTS:-12}" "${DAEMON_CRASH_RESTART_SLEEP:-5}" osd_service_is_active; then
    run_capture "$RESULT_DIR/rollback-start-osd.txt" ssh_lab "$_host_ip" "sudo systemctl start $_service" || rc=1
  fi
  return "$rc"
}

scenario_main daemon-crash "$@"
