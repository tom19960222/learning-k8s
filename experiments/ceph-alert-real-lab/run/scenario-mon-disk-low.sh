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

WARN_THRESHOLD=""
CRIT_THRESHOLD=""

# derive_disk_thresholds reads mon-01's ACTUAL host-level disk usage (a plain
# `df`, not `cephadm shell -- ceph ...` -- /var/lib/ceph is a host path, and
# querying it from inside the cephadm shell container would see the
# container's own mounts instead) so mon_data_avail_warn/crit below are
# guaranteed to bracket the real free% -- a hardcoded threshold could
# silently never fire (or always fire) if the lab disk's usage drifts.
derive_disk_thresholds() {
  local df_output="$RESULT_DIR/mon-01-df.txt" used_pct free_pct
  ssh_lab "$LAB_MON_01_HOST" "df --output=pcent /var/lib/ceph" >"$df_output"
  used_pct="$(tail -n 1 "$df_output" | tr -dc '0-9')"
  [[ -n "$used_pct" ]] || die "could not parse df --output=pcent /var/lib/ceph output on mon-01"
  free_pct=$((100 - used_pct))
  [[ "$free_pct" -lt 97 ]] || die "mon-01 free space (${free_pct}%) is too high: mon_data_avail_warn/crit thresholds derived from it would need to exceed 100"
  WARN_THRESHOLD=$((free_pct + 3))
  CRIT_THRESHOLD=$((free_pct + 1))
  {
    printf 'used_pct=%s\n' "$used_pct"
    printf 'free_pct=%s\n' "$free_pct"
    printf 'warn_threshold=%s\n' "$WARN_THRESHOLD"
    printf 'crit_threshold=%s\n' "$CRIT_THRESHOLD"
  } >"$RESULT_DIR/mon-disk-thresholds.env"
}

scenario_setup() {
  derive_disk_thresholds
}

scenario_inject() {
  # Phase (1): warn threshold. Ceph's HealthMonitor reports MON_DISK_CRIT
  # instead of MON_DISK_LOW once avail% drops below the crit threshold, so
  # this phase's checks (Low fires, reaches Slack only) must fully complete
  # before phase (2) sets mon_data_avail_crit below -- otherwise the
  # isolated "warn only" state can never be observed.
  run_capture "$RESULT_DIR/config-set-warn.txt" ceph_seed_cmd config set mon mon_data_avail_warn "$WARN_THRESHOLD"
  wait_ceph_health_check MON_DISK_LOW "$RESULT_DIR"
  with_prometheus_wait_attempts 200 wait_prometheus_alert CephMonDiskLow "" "" "$RESULT_DIR"
  wait_sink_alert slack CephMonDiskLow "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
  assert_sink_absent pager CephMonDiskLow "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"

  # Phase (2): crit threshold escalation.
  run_capture "$RESULT_DIR/config-set-crit.txt" ceph_seed_cmd config set mon mon_data_avail_crit "$CRIT_THRESHOLD"
  wait_ceph_health_check MON_DISK_CRIT "$RESULT_DIR"
}

scenario_verify() {
  wait_prometheus_alert CephMonDiskCritical "" "" "$RESULT_DIR"
  wait_sink_alert pager CephMonDiskCritical "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local rc=0
  run_capture "$RESULT_DIR/rollback-config-rm-crit.txt" ceph_seed_cmd config rm mon mon_data_avail_crit || rc=1
  run_capture "$RESULT_DIR/rollback-config-rm-warn.txt" ceph_seed_cmd config rm mon mon_data_avail_warn || rc=1
  return "$rc"
}

scenario_main mon-disk-low "$@"
