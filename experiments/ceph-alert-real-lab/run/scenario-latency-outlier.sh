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

# CephOSDLatencyOutlier (ceph_osd_commit_latency_ms > 100 and > 3x the fleet
# median, for: 10m) needs enough poll attempts to reliably outlast the 10m
# `for:` window; the framework default of 60 attempts * 5s = 300s is short
# of that, so bump it up to 200 attempts * 5s = 1000s.
PROMETHEUS_WAIT_ATTEMPTS="${PROMETHEUS_WAIT_ATTEMPTS:-200}"
export PROMETHEUS_WAIT_ATTEMPTS

POOL="${LATENCY_OUTLIER_POOL:-alert-latency-outlier}"
OBJECT="${LATENCY_OUTLIER_OBJECT:-sentinel}"
# Default throttle is wide (4MB/s) on purpose: tight enough to push one OSD's
# commit latency into outlier territory relative to its peers, but not so
# tight it also trips SLOW_OPS (see scenario-slow-ops.sh, which throttles to
# 256KB/s for that purpose). If the fleet median is itself depressed by the
# background bench and 4MB/s isn't enough to clear the 3x-median bar within
# the first wait window, scenario_verify retries once at a tighter rate.
LATENCY_BPS="${LATENCY_BPS:-4194304}"
LATENCY_RETRY_BPS="${LATENCY_RETRY_BPS:-1048576}"
CEPH_VOLUME_METHOD=""
OSD_ID=""
OSD_HOST=""
OSD_DEVICE=""
OSD_SERVICE=""
IO_PATH=""
MAJMIN=""
pool_step=1
cleanup_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

# Mirrors scenario-slow-ops.sh's select_slow_ops_target: pick the first OSD
# in the test object's acting set, then discover its backing device via
# ceph-volume (falling back from host to cephadm-shell invocation) and its
# cgroup v2 io.max path. Not extracted to lib/scenarios.sh because it is
# orchestration specific to this scenario's pool/object naming, not a
# reusable primitive like the io.max/pool-lifecycle helpers it calls into.
select_latency_target() {
  local selected_osd host_name host_ip override_osd="${LATENCY_OUTLIER_OSD_ID:-}" override_host="${LATENCY_OUTLIER_OSD_HOST:-}" override_device="${LATENCY_OUTLIER_DEVICE:-}" discovered_devices
  local map_json="$RESULT_DIR/osd-map.json" find_json="$RESULT_DIR/osd-find.json" ceph_volume_json="$RESULT_DIR/ceph-volume-lvm-list.json"

  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd map $POOL $OBJECT --format json" >"$map_json"
  if [[ -n "$override_osd" ]]; then
    jq -e --arg osd "$override_osd" '.acting[] | tostring | select(.==$osd)' "$map_json" >/dev/null ||
      die "LATENCY_OUTLIER_OSD_ID=$override_osd is not in the acting set for $POOL/$OBJECT"
    selected_osd="$override_osd"
  else
    selected_osd="$(jq -r '.acting[0]' "$map_json")"
  fi
  [[ -n "$selected_osd" && "$selected_osd" != "null" ]] || die "could not select acting OSD for $POOL/$OBJECT"

  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd find $selected_osd --format json" >"$find_json"
  host_name="$(jq -r '.crush_location.host' "$find_json")"
  host_ip="$(lab_osd_host_ip "$host_name")"
  if [[ -n "$override_host" && "$override_host" != "$host_ip" && "$override_host" != "$host_name" ]]; then
    die "LATENCY_OUTLIER_OSD_HOST=$override_host does not match osd.$selected_osd host $host_name/$host_ip"
  fi

  if ssh_lab "$host_ip" "sudo -n ceph-volume lvm list --format json" >"$ceph_volume_json" 2>"$RESULT_DIR/ceph-volume-host.err"; then
    CEPH_VOLUME_METHOD=host
  else
    ssh_lab "$host_ip" "sudo -n cephadm shell -- ceph-volume lvm list --format json" >"$ceph_volume_json" 2>"$RESULT_DIR/ceph-volume-cephadm.err"
    CEPH_VOLUME_METHOD=cephadm
  fi
  discovered_devices="$(jq -r --arg osd "$selected_osd" '(.[$osd] // [])[]? | (.devices? // empty) | if type=="array" then .[] else . end' "$ceph_volume_json")"
  if [[ -n "$override_device" ]]; then
    printf '%s\n' "$discovered_devices" | grep -Fx -- "$override_device" >/dev/null ||
      die "LATENCY_OUTLIER_DEVICE=$override_device is not a ceph-volume device for osd.$selected_osd"
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
  } >"$RESULT_DIR/selected-target.env"
  printf '%s\n' "$CEPH_VOLUME_METHOD" >"$RESULT_DIR/ceph-volume-method.txt"
}

# Launched with nohup on the seed host itself (not backgrounded locally like
# scenario-slow-ops.sh's start_background_capture): the 5-minute write needs
# to keep running independent of this script's own ssh round-trip, so we
# fire-and-forget and record only the launch confirmation as evidence.
start_bench_workload() {
  run_live_step "start-bench" "$LAB_MON_01_HOST" \
    "sudo -n cephadm shell -- sh -c 'nohup rados bench -p $POOL 300 write -b 4194304 -t 16 --no-cleanup >/dev/null 2>&1 & echo started'"
}

scenario_setup() {
  while IFS= read -r pool_cmd; do
    run_live_step "pool-setup-$((pool_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
    pool_step=$((pool_step + 1))
  done < <(pool_create_commands "$POOL")

  select_latency_target
  ssh_lab "$OSD_HOST" "stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs"
}

scenario_inject() {
  run_live_step "throttle" "$OSD_HOST" "$(io_throttle_command "$MAJMIN" "$LATENCY_BPS" "$IO_PATH")"
  start_bench_workload
}

scenario_verify() {
  local ceph_daemon="osd.$OSD_ID"

  if ! wait_prometheus_alert CephOSDLatencyOutlier ceph_daemon "$ceph_daemon" "$RESULT_DIR"; then
    log "CephOSDLatencyOutlier did not fire within the first throttle window; retrying once with a tighter limit (${LATENCY_RETRY_BPS} bps)"
    run_live_step "retry-throttle" "$OSD_HOST" "$(io_throttle_command "$MAJMIN" "$LATENCY_RETRY_BPS" "$IO_PATH")"
    wait_prometheus_alert CephOSDLatencyOutlier ceph_daemon "$ceph_daemon" "$RESULT_DIR"
  fi

  wait_sink_alert slack CephOSDLatencyOutlier ceph_daemon "$ceph_daemon" "$RESULT_DIR" "$SINK_CHECKPOINT"
  assert_sink_absent pager CephOSDLatencyOutlier "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local rc=0

  if [[ -n "$MAJMIN" && -n "$IO_PATH" ]]; then
    run_live_step "rollback-unthrottle" "$OSD_HOST" "$(io_unthrottle_command "$MAJMIN" "$IO_PATH")" || rc=1
  fi
  run_live_step "rollback-kill-rados-bench" "$LAB_MON_01_HOST" \
    "sudo -n cephadm shell -- sh -c 'pkill -f \"[r]ados bench -p $POOL\" || true'" || rc=1

  while IFS= read -r cleanup_cmd; do
    run_live_step "rollback-pool-cleanup-$((cleanup_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $cleanup_cmd" || rc=1
    cleanup_step=$((cleanup_step + 1))
  done < <(pool_cleanup_commands "$POOL")
  return "$rc"
}

scenario_main latency-outlier "$@"
