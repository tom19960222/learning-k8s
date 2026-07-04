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

require_destructive_ack pg-availability "$@"
require_cmd jq

POOL="${PG_AVAIL_POOL:-alert-pg-availability}"
OBJECT="${PG_AVAIL_OBJECT:-sentinel}"
RESULT_DIR="$(new_result_dir pg-availability)"
STOPPED_FILE="$RESULT_DIR/stopped-osds.txt"
TARGET_FILE="$RESULT_DIR/target-osds.txt"
MAP_JSON="$RESULT_DIR/osd-map.json"
pool_step=1
stop_step=1
restart_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

osd_host_ip() {
  local host_name=$1
  case "$host_name" in
    ceph-lab-osd-01) printf '%s\n' "$LAB_OSD_01_HOST" ;;
    ceph-lab-osd-02) printf '%s\n' "$LAB_OSD_02_HOST" ;;
    ceph-lab-osd-03) printf '%s\n' "$LAB_OSD_03_HOST" ;;
    *) die "unknown OSD host for PG availability scenario: $host_name" ;;
  esac
}

cleanup() {
  local host osd service
  log "rollback pg-availability scenario"

  if [[ -f "$STOPPED_FILE" ]]; then
    while IFS=' ' read -r host osd; do
      [[ -n "$host" && -n "$osd" ]] || continue
      service="$(osd_service_name "$LAB_FSID" "$osd")"
      run_live_step "rollback-restart-$((restart_step))" "$host" "sudo systemctl start $service" || true
      restart_step=$((restart_step + 1))
    done <"$STOPPED_FILE"
  fi

  run_live_step "rollback-pool-delete" "$LAB_MON_01_HOST" \
    "sudo -n cephadm shell -- ceph osd pool delete $POOL $POOL --yes-i-really-really-mean-it" || true
  collect_postcheck "$RESULT_DIR/postcheck" || true
}

trap cleanup EXIT

collect_baseline "$RESULT_DIR/baseline"

while IFS= read -r pool_cmd; do
  run_live_step "pool-setup-$((pool_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
  pool_step=$((pool_step + 1))
done < <(
  printf 'ceph osd pool create %s 1\n' "$POOL"
  printf 'ceph osd pool set %s size 3\n' "$POOL"
  printf 'ceph osd pool set %s min_size 2\n' "$POOL"
  printf 'rados -p %s put %s /etc/hosts\n' "$POOL" "$OBJECT"
)

ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd map $POOL $OBJECT --format json" >"$MAP_JSON"
jq -r '.acting[:2][]' "$MAP_JSON" >"$TARGET_FILE"

target_count="$(wc -l <"$TARGET_FILE" | tr -d ' ')"
[[ "$target_count" -eq 2 ]] || die "expected two acting OSDs for $POOL/$OBJECT, got $target_count"

while IFS= read -r osd; do
  [[ -n "$osd" ]] || continue
  find_json="$RESULT_DIR/osd-find-$osd.json"
  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd find $osd --format json" >"$find_json"
  host_name="$(jq -r '.crush_location.host' "$find_json")"
  host_ip="$(osd_host_ip "$host_name")"
  service="$(osd_service_name "$LAB_FSID" "$osd")"
  printf '%s %s\n' "$host_ip" "$osd" >>"$STOPPED_FILE"
  run_live_step "stop-osd-$((stop_step))" "$host_ip" "sudo systemctl stop $service"
  stop_step=$((stop_step + 1))
done <"$TARGET_FILE"

assert_ceph_health_check PG_AVAILABILITY "$RESULT_DIR"
wait_prometheus_alert CephClientBlocked name PG_AVAILABILITY "$RESULT_DIR"
wait_sink_alert pager CephClientBlocked name PG_AVAILABILITY "$RESULT_DIR"

trap - EXIT
cleanup
printf 'result: %s\n' "$RESULT_DIR"
