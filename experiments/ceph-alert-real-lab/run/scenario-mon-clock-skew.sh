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

# MON_CLOCK_SKEW is only raised by a mon's periodic timecheck, which runs on
# a cycle up to 300s -- the framework default of 60 attempts * 5s = 300s is
# exactly the boundary, so bump it up with margin.
CEPH_HEALTH_CHECK_ATTEMPTS="${CEPH_HEALTH_CHECK_ATTEMPTS:-120}"
export CEPH_HEALTH_CHECK_ATTEMPTS

MON_CLOCK_SKEW_NAME="${MON_CLOCK_SKEW_NAME:-ceph-lab-mon-03}"
_host_ip=""; _time_sync_unit=""

# `systemctl is-active` reports "inactive" (not "unknown") for a unit whose
# file does not exist on this host at all -- and "inactive" contains
# "active" as a literal substring, so a bare `grep -n active` cannot tell an
# active unit apart from a merely-absent one by line content. `-x` requires
# the grepped line to equal "active" exactly, which "inactive" never does;
# `head -1` then isolates the one genuinely active line, whose number we map
# back to the unit name at that position in the queried order (timesyncd,
# chrony, chronyd).
discover_time_sync_unit() {
  local raw line_no
  raw="$(ssh_lab "$_host_ip" "systemctl is-active systemd-timesyncd chrony chronyd 2>/dev/null | grep -nx active | head -1")"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  line_no="${raw%%:*}"
  case "$line_no" in
    1) _time_sync_unit="systemd-timesyncd" ;;
    2) _time_sync_unit="chrony" ;;
    3) _time_sync_unit="chronyd" ;;
    *) die "could not detect an active time-sync service on $_host_ip" ;;
  esac
  printf '%s\n' "$_time_sync_unit" >"$RESULT_DIR/time-sync-unit.txt"
}

scenario_setup() {
  _host_ip="$(lab_mon_host_ip "$MON_CLOCK_SKEW_NAME")"
  discover_time_sync_unit
}

scenario_inject() {
  run_capture "$RESULT_DIR/stop-time-sync.txt" ssh_lab "$_host_ip" "sudo systemctl stop $_time_sync_unit"
  # +2s stays well within mon quorum's clock-skew tolerance, so this only
  # trips the warning-level MON_CLOCK_SKEW health check -- it never risks
  # kicking the mon out of quorum.
  run_capture "$RESULT_DIR/skew-clock-forward.txt" ssh_lab "$_host_ip" "sudo date -s '+2 seconds'"
}

scenario_verify() {
  wait_ceph_health_check MON_CLOCK_SKEW "$RESULT_DIR"
  wait_prometheus_alert CephMonClockSkew "" "" "$RESULT_DIR"
  wait_sink_alert pager CephMonClockSkew "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local rc=0
  # Step the clock back to true time BEFORE handing it back to the
  # time-sync service: starting systemd-timesyncd/chrony first, while the
  # clock is still +2s off, would race the service's own gradual correction
  # against this rollback's own date step. Undoing the offset directly
  # first, then restarting the service, avoids that race.
  run_capture "$RESULT_DIR/rollback-skew-clock-back.txt" ssh_lab "$_host_ip" "sudo date -s '-2 seconds'" || rc=1
  run_capture "$RESULT_DIR/rollback-start-time-sync.txt" ssh_lab "$_host_ip" "sudo systemctl start $_time_sync_unit" || rc=1
  return "$rc"
}

scenario_main mon-clock-skew "$@"
