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
THROTTLE_BPS="${SLOW_OPS_THROTTLE_BPS:-262144}"
RESULT_DIR="$(new_result_dir slow-ops)"
TARGET_FILE="$RESULT_DIR/selected-target.env"
MAP_JSON="$RESULT_DIR/osd-map.json"
FIND_JSON="$RESULT_DIR/osd-find.json"
CEPH_VOLUME_JSON="$RESULT_DIR/ceph-volume-lvm-list.json"
CEPH_VOLUME_METHOD=""
OSD_ID=""
OSD_HOST=""
OSD_DEVICE=""
OSD_SERVICE=""
IO_PATH=""
MAJMIN=""
BENCH_PID=""
BENCH_CHILD_PID_FILE="$RESULT_DIR/rados-bench.child.pid"
CLEANED=0
pool_step=1
cleanup_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

osd_ok_to_stop() {
  local osd=$1
  run_capture "$RESULT_DIR/bluestore-ok-to-stop-osd-${osd}.txt" ceph_seed_cmd osd ok-to-stop "$osd"
}

osd_up_in() {
  local osd=$1 output_file
  output_file="$RESULT_DIR/bluestore-osd-${osd}-dump.json"
  ceph_seed_cmd osd dump --format json >"$output_file"
  jq -e --arg osd "$osd" '.osds[] | select(.osd|tostring==$osd) | select(.up==1 and .in==1)' "$output_file" >/dev/null
}

pgs_active_clean() {
  local output_file
  output_file="$RESULT_DIR/bluestore-pg-status.json"
  ceph_seed_cmd status --format json >"$output_file"
  jq -e '.pgmap.pgs_by_state | length == 1 and .[0].state_name == "active+clean"' "$output_file" >/dev/null
}

clear_bluestore_slow_ops() {
  local health_file osds_file osd find_json host_name host_ip service rc=0

  health_file="$RESULT_DIR/bluestore-slow-ops-health.txt"
  osds_file="$RESULT_DIR/bluestore-slow-ops-osds.txt"
  run_capture "$health_file" ceph_seed_cmd health detail || return 0
  grep -Eo 'osd\.[0-9]+ observed slow operation' "$health_file" |
    sed 's/^osd\.//; s/ observed slow operation$//' |
    sort -nu >"$osds_file" || true

  if [[ ! -s "$osds_file" ]]; then
    return 0
  fi

  while IFS= read -r osd; do
    [[ -n "$osd" ]] || continue
    log "clear BlueStore slow-op health by restarting osd.$osd"
    find_json="$RESULT_DIR/bluestore-osd-find-${osd}.json"
    ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd find $osd --format json" >"$find_json"
    host_name="$(jq -r '.crush_location.host' "$find_json")"
    host_ip="$(lab_osd_host_ip "$host_name")"
    service="$(osd_service_name "$LAB_FSID" "$osd")"

    poll_until "osd.$osd ok-to-stop" 30 5 osd_ok_to_stop "$osd" || {
      rc=1
      continue
    }
    run_live_step "bluestore-restart-osd-${osd}" "$host_ip" "sudo systemctl restart $service" || {
      rc=1
      continue
    }
    poll_until "osd.$osd up/in after BlueStore slow-op restart" 30 5 osd_up_in "$osd" || rc=1
    poll_until "PGs active+clean after osd.$osd restart" 30 5 pgs_active_clean || rc=1
  done <"$osds_file"

  return "$rc"
}

start_background_capture() {
  local output_file=$1 child_pid_file=$2
  shift 2
  (
    local started ended rc child
    started="$(date -u +%FT%TZ)"
    {
      printf '# started: %s\n' "$started"
      printf '# command:'
      printf ' %q' "$@"
      printf '\n'
    } >"$output_file"

    set +e
    "$@" >>"$output_file" 2>&1 &
    child=$!
    printf '%s\n' "$child" >"$child_pid_file"
    trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
    wait "$child"
    rc=$?
    trap - TERM INT
    set -e

    ended="$(date -u +%FT%TZ)"
    {
      printf '\n# ended: %s\n' "$ended"
      printf '# exit_code: %s\n' "$rc"
    } >>"$output_file"
    exit "$rc"
  ) &
  BENCH_PID=$!
  printf '%s\n' "$BENCH_PID" >"$RESULT_DIR/rados-bench.pid"
}

start_bench_workload() {
  start_background_capture "$RESULT_DIR/rados-bench.txt" "$BENCH_CHILD_PID_FILE" \
    ssh_lab "$LAB_MON_01_HOST" \
    "sudo -n cephadm shell -- rados bench -p $POOL 180 write -b 4194304 -t 16 --no-cleanup"
}

stop_bench_workload() {
  local reason=$1 child_pid="" i
  if [[ -z "$BENCH_PID" ]]; then
    return 0
  fi

  log "stop rados bench workload ($reason)"
  if [[ -f "$BENCH_CHILD_PID_FILE" ]]; then
    child_pid="$(cat "$BENCH_CHILD_PID_FILE")"
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
      kill "$child_pid" 2>/dev/null || true
      i=0
      while [[ "$i" -lt 20 ]] && kill -0 "$child_pid" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
      done
      if kill -0 "$child_pid" 2>/dev/null; then
        kill -KILL "$child_pid" 2>/dev/null || true
      fi
    fi
  fi
  if kill -0 "$BENCH_PID" 2>/dev/null; then
    kill "$BENCH_PID" 2>/dev/null || true
  fi
  wait "$BENCH_PID" 2>/dev/null || true
  BENCH_PID=""
  return 0
}

cleanup() {
  local rc=0
  log "rollback slow-ops scenario"

  if [[ "$CLEANED" -eq 1 ]]; then
    return 0
  fi

  stop_bench_workload "before unthrottle"

  if [[ -n "$MAJMIN" && -n "$IO_PATH" ]]; then
    run_live_step "rollback-unthrottle" "$OSD_HOST" "$(io_unthrottle_command "$MAJMIN" "$IO_PATH")" || rc=1
  fi
  stop_bench_workload "after unthrottle"
  run_live_step "rollback-kill-rados-bench" "$LAB_MON_01_HOST" \
    "sudo -n cephadm shell -- sh -c 'pkill -f \"[r]ados bench -p $POOL\" || true'" || rc=1

  while IFS= read -r cleanup_cmd; do
    run_live_step "rollback-pool-cleanup-$((cleanup_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $cleanup_cmd" || rc=1
    cleanup_step=$((cleanup_step + 1))
  done < <(pool_cleanup_commands "$POOL")
  collect_postcheck "$RESULT_DIR/postcheck" || true
  clear_bluestore_slow_ops || rc=1
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

  if ssh_lab "$host_ip" "sudo -n ceph-volume lvm list --format json" >"$CEPH_VOLUME_JSON" 2>"$RESULT_DIR/ceph-volume-host.err"; then
    CEPH_VOLUME_METHOD=host
  else
    ssh_lab "$host_ip" "sudo -n cephadm shell -- ceph-volume lvm list --format json" >"$CEPH_VOLUME_JSON" 2>"$RESULT_DIR/ceph-volume-cephadm.err"
    CEPH_VOLUME_METHOD=cephadm
  fi
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
  MAJMIN="$(printf '%s' "$MAJMIN" | tr -d '[:space:]')"
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
    printf 'ceph_volume_method=%s\n' "$CEPH_VOLUME_METHOD"
  } >"$TARGET_FILE"
  printf '%s\n' "$CEPH_VOLUME_METHOD" >"$RESULT_DIR/ceph-volume-method.txt"
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

start_bench_workload

wait_ceph_health_check SLOW_OPS "$RESULT_DIR"
wait_prometheus_alert CephClientBlocked name SLOW_OPS "$RESULT_DIR"
wait_sink_alert pager CephClientBlocked name SLOW_OPS "$RESULT_DIR" "$RESULT_DIR/sink-checkpoint-lines.txt"

trap - EXIT
cleanup || exit 1
printf 'result: %s\n' "$RESULT_DIR"
