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
CLEANED=0
stop_step=1
restart_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

cleanup() {
  local host mon service rc=0
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

assert_mon_quorum_loss() {
  local prometheus_file ceph_file
  prometheus_file="$RESULT_DIR/prometheus-ceph-mon-quorum-status.json"
  ceph_file="$RESULT_DIR/ceph-quorum-after-stop.json"

  if prometheus_query 'sum(ceph_mon_quorum_status)' >"$prometheus_file" &&
    jq -e '.data.result[0].value[1] | tonumber < 2' "$prometheus_file" >/dev/null; then
    return 0
  fi

  if ! run_capture "$ceph_file" ceph_seed_cmd quorum_status --format json; then
    return 0
  fi
  jq -e '(.quorum | length) < 2' "$ceph_file" >/dev/null
}

trap cleanup_on_exit EXIT

collect_baseline "$RESULT_DIR/baseline"
assert_lab_ready "$RESULT_DIR/ready-before-injection"
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

poll_until "mon quorum loss evidence" "${MON_QUORUM_EVIDENCE_ATTEMPTS:-12}" "${MON_QUORUM_EVIDENCE_SLEEP:-5}" assert_mon_quorum_loss
wait_prometheus_alert CephMonQuorumLost "" "" "$RESULT_DIR"
wait_sink_alert pager CephMonQuorumLost "" "" "$RESULT_DIR" "$RESULT_DIR/sink-checkpoint-lines.txt"

trap - EXIT
cleanup || exit 1
printf 'result: %s\n' "$RESULT_DIR"
