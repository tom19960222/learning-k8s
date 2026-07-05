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

STOPPED_MGR_HOST=""
STOPPED_MGR_SERVICE=""

mgr_failover_continuity_probe() {
  # A bare instant-vector query (`ceph_health_status`) returns the query
  # evaluation time in each sample, not the scrape timestamp, so a stale or
  # absent series would still report a "fresh-looking" timestamp. Querying
  # `(time() - timestamp(ceph_health_status)) < 30` uses PromQL FILTER
  # semantics (no `bool` modifier): a series whose most recent scrape is
  # <30s old is kept with its AGE in seconds as the value (e.g. "2", "4.83"
  # — never "1"); a stale or absent series is dropped, leaving an empty
  # result. So "result non-empty" alone encodes freshness — do not compare
  # the value against "1" (that would require the `bool` modifier, which
  # this query deliberately does not use so lingering stale series from the
  # old mgr target are silently dropped instead of failing the probe).
  local output_file="$RESULT_DIR/mgr-failover-continuity.json"
  prometheus_query '(time() - timestamp(ceph_health_status)) < 30' >"$output_file"
  jq -e '.data.result | length > 0' "$output_file" >/dev/null
}

discover_standby_mgr() {
  local mgr_dump standby_name host_prefix
  mgr_dump="$RESULT_DIR/mgr-dump-after-fail.json"
  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph mgr dump --format json" >"$mgr_dump"
  standby_name="$(jq -r '.standbys[0].name // empty' "$mgr_dump")"
  [[ -n "$standby_name" ]] || die "no standby mgr found after ceph mgr fail"
  host_prefix="${standby_name%%.*}"
  STOPPED_MGR_HOST="$(lab_mon_host_ip "$host_prefix")"
  STOPPED_MGR_SERVICE="ceph-${LAB_FSID}@mgr.${standby_name}.service"
  {
    printf 'standby_mgr_name=%s\n' "$standby_name"
    printf 'standby_mgr_host=%s\n' "$STOPPED_MGR_HOST"
    printf 'standby_mgr_service=%s\n' "$STOPPED_MGR_SERVICE"
  } >"$RESULT_DIR/standby-mgr.env"
}

scenario_inject() {
  # Phase (a): fail the active mgr. The old active mgr rejoins the cluster
  # as a standby automatically, so this half of the injection needs no
  # rollback step of its own.
  run_capture "$RESULT_DIR/mgr-fail.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph mgr fail"

  poll_until "Prometheus ceph_health_status metric continuity across mgr failover" \
    "${MGR_CONTINUITY_ATTEMPTS:-12}" "${MGR_CONTINUITY_SLEEP:-5}" mgr_failover_continuity_probe
  assert_prometheus_alert_not_firing CephMetricsAbsent "" "" "$RESULT_DIR"

  # Phase (b): stop the (new) standby mgr so no failover capacity remains.
  discover_standby_mgr
  run_capture "$RESULT_DIR/stop-standby-mgr.txt" ssh_lab "$STOPPED_MGR_HOST" "sudo systemctl stop $STOPPED_MGR_SERVICE"
}

scenario_verify() {
  wait_prometheus_alert CephMgrNoStandby "" "" "$RESULT_DIR"
  wait_sink_alert slack CephMgrNoStandby "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
  assert_sink_absent pager CephMgrNoStandby "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  # `ceph mgr fail` from phase (a) needs no rollback here: the old active
  # mgr automatically rejoins the cluster as a standby. Only the standby
  # we stopped in phase (b) needs restarting.
  if [[ -z "$STOPPED_MGR_HOST" || -z "$STOPPED_MGR_SERVICE" ]]; then
    return 0
  fi
  run_capture "$RESULT_DIR/rollback-start-standby-mgr.txt" ssh_lab "$STOPPED_MGR_HOST" "sudo systemctl start $STOPPED_MGR_SERVICE" || return 1
}

scenario_main mgr-failover "$@"
