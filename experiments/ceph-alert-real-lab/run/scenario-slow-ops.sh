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

require_destructive_ack slow-ops "$@"
require_cmd jq

POOL="${SLOW_OPS_POOL:-alert-slow-ops}"
OBJECT="${SLOW_OPS_OBJECT:-sentinel}"
THROTTLE_BPS="${SLOW_OPS_THROTTLE_BPS:-65536}"
RESULT_DIR="$(new_result_dir slow-ops)"
TARGET_FILE="$RESULT_DIR/selected-target.env"
MAP_JSON="$RESULT_DIR/osd-map.json"
FIND_JSON="$RESULT_DIR/osd-find.json"
CEPH_VOLUME_JSON="$RESULT_DIR/ceph-volume-lvm-list.json"
OSD_ID=""
OSD_HOST=""
OSD_DEVICE=""
OSD_SERVICE=""
IO_PATH=""
MAJMIN=""
CLEANED=0
pool_step=1
cleanup_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

cleanup() {
  local rc=0
  log "rollback slow-ops scenario"

  if [[ "$CLEANED" -eq 1 ]]; then
    return 0
  fi

  if [[ -n "$MAJMIN" && -n "$IO_PATH" ]]; then
    run_live_step "rollback-unthrottle" "$OSD_HOST" "$(io_unthrottle_command "$MAJMIN" "$IO_PATH")" || rc=1
  fi

  while IFS= read -r cleanup_cmd; do
    run_live_step "rollback-pool-cleanup-$((cleanup_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $cleanup_cmd" || rc=1
    cleanup_step=$((cleanup_step + 1))
  done < <(pool_cleanup_commands "$POOL")
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

select_slow_ops_target() {
  local selected_osd host_name host_ip override_osd="${SLOW_OPS_OSD_ID:-}" override_host="${SLOW_OPS_OSD_HOST:-}" override_device="${SLOW_OPS_DEVICE:-}" discovered_devices

  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd map $POOL $OBJECT --format json" >"$MAP_JSON"
  if [[ -n "$override_osd" ]]; then
    jq -e --arg osd "$override_osd" '.acting[] | tostring | select(.==$osd)' "$MAP_JSON" >/dev/null ||
      die "SLOW_OPS_OSD_ID=$override_osd is not in the acting set for $POOL/$OBJECT"
    selected_osd="$override_osd"
  else
    selected_osd="$(jq -r '.acting[0]' "$MAP_JSON")"
  fi
  [[ -n "$selected_osd" && "$selected_osd" != "null" ]] || die "could not select acting OSD for $POOL/$OBJECT"

  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd find $selected_osd --format json" >"$FIND_JSON"
  host_name="$(jq -r '.crush_location.host' "$FIND_JSON")"
  host_ip="$(lab_osd_host_ip "$host_name")"
  if [[ -n "$override_host" && "$override_host" != "$host_ip" && "$override_host" != "$host_name" ]]; then
    die "SLOW_OPS_OSD_HOST=$override_host does not match osd.$selected_osd host $host_name/$host_ip"
  fi

  ssh_lab "$host_ip" "sudo ceph-volume lvm list --format json" >"$CEPH_VOLUME_JSON"
  discovered_devices="$(jq -r --arg osd "$selected_osd" '(.[$osd] // [])[]? | (.devices? // empty) | if type=="array" then .[] else . end' "$CEPH_VOLUME_JSON")"
  if [[ -n "$override_device" ]]; then
    printf '%s\n' "$discovered_devices" | grep -Fx -- "$override_device" >/dev/null ||
      die "SLOW_OPS_DEVICE=$override_device is not a ceph-volume device for osd.$selected_osd"
    OSD_DEVICE="$override_device"
  else
    OSD_DEVICE="$(printf '%s\n' "$discovered_devices" | sed -n '1p')"
  fi
  [[ -n "$OSD_DEVICE" ]] || die "could not discover backing device for osd.$selected_osd"

  OSD_ID="$selected_osd"
  OSD_HOST="$host_ip"
  OSD_SERVICE="$(osd_service_name "$LAB_FSID" "$OSD_ID")"
  MAJMIN="$(ssh_lab "$OSD_HOST" "lsblk -no MAJ:MIN $OSD_DEVICE | head -1")"
  [[ -n "$MAJMIN" ]] || die "could not resolve major:minor for $OSD_DEVICE on $OSD_HOST"
  IO_PATH="$(ssh_lab "$OSD_HOST" "$(cgroup_io_max_path_command "$OSD_SERVICE")")"
  [[ -n "$IO_PATH" ]] || die "could not resolve io.max path for $OSD_SERVICE on $OSD_HOST"

  {
    printf 'osd_id=%s\n' "$OSD_ID"
    printf 'osd_host=%s\n' "$OSD_HOST"
    printf 'osd_device=%s\n' "$OSD_DEVICE"
    printf 'osd_service=%s\n' "$OSD_SERVICE"
    printf 'majmin=%s\n' "$MAJMIN"
    printf 'io_path=%s\n' "$IO_PATH"
  } >"$TARGET_FILE"
}

trap cleanup_on_exit EXIT

collect_baseline "$RESULT_DIR/baseline"
assert_lab_ready "$RESULT_DIR/ready-before-injection"

while IFS= read -r pool_cmd; do
  run_live_step "pool-setup-$((pool_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
  pool_step=$((pool_step + 1))
done < <(pool_create_commands "$POOL")

select_slow_ops_target
ssh_lab "$OSD_HOST" "stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs"

record_sink_checkpoint "$RESULT_DIR"
run_live_step "throttle" "$OSD_HOST" "$(io_throttle_command "$MAJMIN" "$THROTTLE_BPS" "$IO_PATH")"

run_capture "$RESULT_DIR/rados-bench.txt" \
  ssh_lab "$LAB_MON_01_HOST" \
  "sudo -n cephadm shell -- rados bench -p $POOL 180 write -b 4194304 -t 16 --no-cleanup" || true

wait_ceph_health_check SLOW_OPS "$RESULT_DIR"
wait_prometheus_alert CephClientBlocked name SLOW_OPS "$RESULT_DIR"
wait_sink_alert pager CephClientBlocked name SLOW_OPS "$RESULT_DIR" "$RESULT_DIR/sink-checkpoint-lines.txt"

trap - EXIT
cleanup || exit 1
printf 'result: %s\n' "$RESULT_DIR"
