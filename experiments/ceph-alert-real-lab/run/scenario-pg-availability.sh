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

POOL="${PG_AVAIL_POOL:-alert-pg-availability}"
OBJECT="${PG_AVAIL_OBJECT:-sentinel}"
pool_step=1
stop_step=1
restart_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

scenario_setup() {
  local map_json="$RESULT_DIR/osd-map.json" target_file="$RESULT_DIR/target-osds.txt" target_count

  while IFS= read -r pool_cmd; do
    run_live_step "pool-setup-$((pool_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
    pool_step=$((pool_step + 1))
  done < <(
    printf 'ceph osd pool create %s 1\n' "$POOL"
    printf 'ceph osd pool set %s size 3\n' "$POOL"
    printf 'ceph osd pool set %s min_size 2\n' "$POOL"
    printf 'rados -p %s put %s /etc/hosts\n' "$POOL" "$OBJECT"
  )

  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd map $POOL $OBJECT --format json" >"$map_json"
  jq -r '.acting[:2][]' "$map_json" >"$target_file"

  target_count="$(wc -l <"$target_file" | tr -d ' ')"
  [[ "$target_count" -eq 2 ]] || die "expected two acting OSDs for $POOL/$OBJECT, got $target_count"
}

scenario_inject() {
  local target_file="$RESULT_DIR/target-osds.txt" stopped_file="$RESULT_DIR/stopped-osds.txt"
  local osd find_json host_name host_ip service

  while IFS= read -r osd; do
    [[ -n "$osd" ]] || continue
    find_json="$RESULT_DIR/osd-find-$osd.json"
    ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd find $osd --format json" >"$find_json"
    host_name="$(jq -r '.crush_location.host' "$find_json")"
    host_ip="$(lab_osd_host_ip "$host_name")"
    service="$(osd_service_name "$LAB_FSID" "$osd")"
    printf '%s %s\n' "$host_ip" "$osd" >>"$stopped_file"
    run_live_step "stop-osd-$((stop_step))" "$host_ip" "sudo systemctl stop $service"
    stop_step=$((stop_step + 1))
  done <"$target_file"
}

scenario_verify() {
  wait_ceph_health_check PG_AVAILABILITY "$RESULT_DIR"
  wait_prometheus_alert CephClientBlocked name PG_AVAILABILITY "$RESULT_DIR"
  wait_sink_alert pager CephClientBlocked name PG_AVAILABILITY "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local stopped_file="$RESULT_DIR/stopped-osds.txt" host osd service rc=0

  if [[ -f "$stopped_file" ]]; then
    while IFS=' ' read -r host osd; do
      [[ -n "$host" && -n "$osd" ]] || continue
      service="$(osd_service_name "$LAB_FSID" "$osd")"
      run_live_step "rollback-restart-$((restart_step))" "$host" "sudo systemctl start $service" || rc=1
      restart_step=$((restart_step + 1))
    done <"$stopped_file"
  fi

  run_live_step "rollback-pool-delete" "$LAB_MON_01_HOST" \
    "sudo -n cephadm shell -- $(pool_delete_command "$POOL")" || rc=1
  return "$rc"
}

scenario_main pg-availability "$@"
