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

require_destructive_ack mon-quorum-lost "$@"
require_cmd jq

RESULT_DIR="$(new_result_dir mon-quorum-lost)"
STOPPED_FILE="$RESULT_DIR/stopped-mons.txt"
STOPPED_MGR_FILE="$RESULT_DIR/stopped-mgr.txt"
ACTIVE_MGR_HOST=""
ACTIVE_MGR_SERVICE=""
CLEANED=0
stop_step=1
restart_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

cleanup() {
  local host mon service mgr_host mgr_service rc=0
  log "rollback mon-quorum-lost scenario"

  if [[ "$CLEANED" -eq 1 ]]; then
    return 0
  fi

  if [[ -f "$STOPPED_FILE" ]]; then
    while IFS=' ' read -r host mon; do
      [[ -n "$host" && -n "$mon" ]] || continue
      service="$(mon_service_name "$LAB_FSID" "$mon")"
      run_live_step "rollback-restart-$((restart_step))" "$host" "sudo systemctl start $service" || rc=1
      restart_step=$((restart_step + 1))
    done <"$STOPPED_FILE"
  fi

  if [[ -f "$STOPPED_MGR_FILE" ]]; then
    while IFS=' ' read -r mgr_host mgr_service; do
      [[ -n "$mgr_host" && -n "$mgr_service" ]] || continue
      run_live_step "rollback-restart-mgr" "$mgr_host" "sudo systemctl start $mgr_service" || rc=1
    done <"$STOPPED_MGR_FILE"
  fi

  collect_postcheck "$RESULT_DIR/postcheck" || true
  assert_lab_recovered "$RESULT_DIR/recovery" || rc=1
  CLEANED=1
  return "$rc"
}

cleanup_on_exit() {
  local rc=$?
  cleanup || true
  exit "$rc"
}

discover_active_mgr() {
  local mgr_dump active_name host_name
  mgr_dump="$RESULT_DIR/mgr-dump-before-stop.json"
  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph mgr dump --format json" >"$mgr_dump"
  active_name="$(jq -r '.active_name // empty' "$mgr_dump")"
  [[ -n "$active_name" ]] || return 0
  host_name="${active_name%%.*}"
  ACTIVE_MGR_HOST="$(lab_mon_host_ip "$host_name")"
  ACTIVE_MGR_SERVICE="ceph-${LAB_FSID}@mgr.${active_name}.service"
  {
    printf 'active_mgr_name=%s\n' "$active_name"
    printf 'active_mgr_host=%s\n' "$ACTIVE_MGR_HOST"
    printf 'active_mgr_service=%s\n' "$ACTIVE_MGR_SERVICE"
  } >"$RESULT_DIR/active-mgr.env"
}

prometheus_mon_quorum_lost() {
  local output_file
  output_file="$RESULT_DIR/prometheus-ceph-mon-quorum-lost-expr.json"
  prometheus_query '(count(ceph_mon_quorum_status == 1) or vector(0)) < 2' >"$output_file"
  jq -e '.data.result | length > 0' "$output_file" >/dev/null
}

stop_active_mgr_exporter() {
  if [[ -z "$ACTIVE_MGR_HOST" || -z "$ACTIVE_MGR_SERVICE" ]]; then
    log "skip active mgr stop: active mgr was not discovered"
    return 0
  fi
  printf '%s %s\n' "$ACTIVE_MGR_HOST" "$ACTIVE_MGR_SERVICE" >"$STOPPED_MGR_FILE"
  run_live_step "stop-active-mgr" "$ACTIVE_MGR_HOST" "sudo systemctl stop $ACTIVE_MGR_SERVICE"
}

trap cleanup_on_exit EXIT

collect_baseline "$RESULT_DIR/baseline"
assert_lab_ready "$RESULT_DIR/ready-before-injection"
discover_active_mgr
record_sink_checkpoint "$RESULT_DIR"

while IFS=' ' read -r host mon; do
  [[ -n "$host" && -n "$mon" ]] || continue
  service="$(mon_service_name "$LAB_FSID" "$mon")"
  printf '%s %s\n' "$host" "$mon" >>"$STOPPED_FILE"
  run_live_step "stop-mon-$((stop_step))" "$host" "sudo systemctl stop $service"
  stop_step=$((stop_step + 1))
done <<EOF
$LAB_MON_01_HOST $LAB_MON_01_NAME
$LAB_MON_03_HOST $LAB_MON_03_NAME
EOF

if ! poll_until "Prometheus mon quorum-loss expression without mgr fallback" "${MON_QUORUM_DIRECT_ATTEMPTS:-12}" "${MON_QUORUM_DIRECT_SLEEP:-5}" prometheus_mon_quorum_lost; then
  log "mon quorum metric stayed stale; stop active mgr exporter to exercise the empty-series alert path"
  stop_active_mgr_exporter
fi
poll_until "mon quorum loss evidence" "${MON_QUORUM_EVIDENCE_ATTEMPTS:-60}" "${MON_QUORUM_EVIDENCE_SLEEP:-5}" prometheus_mon_quorum_lost
wait_prometheus_alert CephMonQuorumLost "" "" "$RESULT_DIR"
wait_sink_alert pager CephMonQuorumLost "" "" "$RESULT_DIR" "$RESULT_DIR/sink-checkpoint-lines.txt"

trap - EXIT
cleanup || exit 1
printf 'result: %s\n' "$RESULT_DIR"
