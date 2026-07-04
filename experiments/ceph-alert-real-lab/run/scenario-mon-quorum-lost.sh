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
stop_step=1
restart_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

cleanup() {
  local host mon service
  log "rollback mon-quorum-lost scenario"

  if [[ -f "$STOPPED_FILE" ]]; then
    while IFS=' ' read -r host mon; do
      [[ -n "$host" && -n "$mon" ]] || continue
      service="$(mon_service_name "$LAB_FSID" "$mon")"
      run_live_step "rollback-restart-$((restart_step))" "$host" "sudo systemctl start $service" || true
      restart_step=$((restart_step + 1))
    done <"$STOPPED_FILE"
  fi

  collect_postcheck "$RESULT_DIR/postcheck" || true
}

trap cleanup EXIT

collect_baseline "$RESULT_DIR/baseline"

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

wait_prometheus_alert CephMonQuorumLost "" "" "$RESULT_DIR"
wait_sink_alert pager CephMonQuorumLost "" "" "$RESULT_DIR"

trap - EXIT
cleanup
printf 'result: %s\n' "$RESULT_DIR"
