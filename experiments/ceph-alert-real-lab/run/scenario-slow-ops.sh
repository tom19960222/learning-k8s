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

POOL="${SLOW_OPS_POOL:-alert-slow-ops}"
OBJECT="${SLOW_OPS_OBJECT:-sentinel}"
THROTTLE_BPS="${SLOW_OPS_THROTTLE_BPS:-262144}"
# ceph_daemon_health_metrics{type="SLOW_OPS"} is a gauge of *currently*
# slow ops that oscillates as the throttled OSD's op queue drains and
# refills, while CephDaemonSlowOps requires it to sit CONTINUOUSLY > 0
# for 3m (its `for: 3m`). Slow ops only start ramping up ~30-60s after
# the throttle+bench begin, so the bench must keep the queue backed up
# well past ramp-up + the 3m for: window (real-lab evidence: a 180s
# bench let the gauge drop to 0 before ever sustaining 3 continuous
# minutes, so the for: clock kept resetting and the alert timed out even
# though the metric genuinely spiked to 16). 420s gives ~60s ramp + 180s
# for: + scrape/evaluation margin, all under continuous load.
SLOW_OPS_BENCH_SECONDS="${SLOW_OPS_BENCH_SECONDS:-420}"
# Duration alone isn't sufficient: real-lab evidence at this same 262144
# throttle with the previous -t 16 bench threads showed SLOW_OPS is BURSTY
# -- the op queue drains between bench write bursts, so
# ceph_health_detail{name="SLOW_OPS"} and
# ceph_daemon_health_metrics{type="SLOW_OPS"} oscillate 1->0->1, resetting
# both alerts' for: clocks (one run fired CephClientBlocked, an identical
# rerun of the same throttle did not). The fix is higher write concurrency,
# not a harder throttle: more in-flight ops keep the throttled device's
# queue continuously non-empty, so SLOW_OPS stays > 0 across both the
# for:1m and for:3m windows without any added flap risk (a harder 128KB/s
# throttle was tested and made the OSD flap DOWN because its own
# housekeeping IO got throttled too -- so the throttle rate itself must
# stay unchanged; only concurrency goes up).
SLOW_OPS_BENCH_THREADS="${SLOW_OPS_BENCH_THREADS:-64}"
CEPH_VOLUME_METHOD=""
OSD_ID=""
OSD_HOST=""
OSD_DEVICE=""
OSD_SERVICE=""
IO_PATH=""
MAJMIN=""
BENCH_PID=""
pool_step=1
cleanup_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

bluestore_slow_op_alert_cleared() {
  local output_file="$RESULT_DIR/bluestore-slow-ops-health-poll.txt"
  run_capture "$output_file" ceph_seed_cmd health detail || return 1
  ! grep -Fq 'BLUESTORE_SLOW_OP_ALERT' "$output_file"
}

# clear_bluestore_slow_ops clears the 24h-latched BLUESTORE_SLOW_OP_ALERT
# warning. This used to restart every OSD still reporting it, but on the real
# cluster that rolling restart was disruptive and repeatedly left cephadm's
# daemon inventory in a stale "unknown" state (CEPHADM_FAILED_DAEMON ->
# HEALTH_WARN -> recovery gate timeout). Verified cleaner method: temporarily
# shrink the warning's lifetime/threshold so the latch ages out cluster-wide
# in ~20s (no daemon restart involved), then restore the defaults.
clear_bluestore_slow_ops() {
  local health_file rc=0

  health_file="$RESULT_DIR/bluestore-slow-ops-health.txt"
  run_capture "$health_file" ceph_seed_cmd health detail || return 0
  grep -Fq 'BLUESTORE_SLOW_OP_ALERT' "$health_file" || return 0

  log "age out latched BLUESTORE_SLOW_OP_ALERT via bluestore_slow_ops_warn_lifetime=1"
  run_capture "$RESULT_DIR/bluestore-warn-lifetime-set.txt" \
    ceph_seed_cmd config set osd bluestore_slow_ops_warn_lifetime 1 || rc=1
  run_capture "$RESULT_DIR/bluestore-warn-threshold-set.txt" \
    ceph_seed_cmd config set osd bluestore_slow_ops_warn_threshold 1 || rc=1

  poll_until "BLUESTORE_SLOW_OP_ALERT cleared" \
    "${BLUESTORE_CLEAR_ATTEMPTS:-18}" "${BLUESTORE_CLEAR_SLEEP:-5}" \
    bluestore_slow_op_alert_cleared || rc=1

  # Always restore defaults, even on poll timeout above: a lingering
  # bluestore_slow_ops_warn_lifetime=1 would silently suppress this warning
  # for real incidents later.
  run_capture "$RESULT_DIR/bluestore-warn-lifetime-rm.txt" \
    ceph_seed_cmd config rm osd bluestore_slow_ops_warn_lifetime || rc=1
  run_capture "$RESULT_DIR/bluestore-warn-threshold-rm.txt" \
    ceph_seed_cmd config rm osd bluestore_slow_ops_warn_threshold || rc=1

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
  start_background_capture "$RESULT_DIR/rados-bench.txt" "$RESULT_DIR/rados-bench.child.pid" \
    ssh_lab "$LAB_MON_01_HOST" \
    "sudo -n cephadm shell -- rados bench -p $POOL $SLOW_OPS_BENCH_SECONDS write -b 4194304 -t $SLOW_OPS_BENCH_THREADS --no-cleanup"
}

stop_bench_workload() {
  local reason=$1 child_pid_file="$RESULT_DIR/rados-bench.child.pid" child_pid="" i
  if [[ -z "$BENCH_PID" ]]; then
    return 0
  fi

  log "stop rados bench workload ($reason)"
  if [[ -f "$child_pid_file" ]]; then
    child_pid="$(cat "$child_pid_file")"
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

select_slow_ops_target() {
  local selected_osd host_name host_ip override_osd="${SLOW_OPS_OSD_ID:-}" override_host="${SLOW_OPS_OSD_HOST:-}" override_device="${SLOW_OPS_DEVICE:-}" discovered_devices
  local map_json="$RESULT_DIR/osd-map.json" find_json="$RESULT_DIR/osd-find.json" ceph_volume_json="$RESULT_DIR/ceph-volume-lvm-list.json"

  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd map $POOL $OBJECT --format json" >"$map_json"
  if [[ -n "$override_osd" ]]; then
    jq -e --arg osd "$override_osd" '.acting[] | tostring | select(.==$osd)' "$map_json" >/dev/null ||
      die "SLOW_OPS_OSD_ID=$override_osd is not in the acting set for $POOL/$OBJECT"
    selected_osd="$override_osd"
  else
    selected_osd="$(jq -r '.acting[0]' "$map_json")"
  fi
  [[ -n "$selected_osd" && "$selected_osd" != "null" ]] || die "could not select acting OSD for $POOL/$OBJECT"

  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd find $selected_osd --format json" >"$find_json"
  host_name="$(jq -r '.crush_location.host' "$find_json")"
  host_ip="$(lab_osd_host_ip "$host_name")"
  if [[ -n "$override_host" && "$override_host" != "$host_ip" && "$override_host" != "$host_name" ]]; then
    die "SLOW_OPS_OSD_HOST=$override_host does not match osd.$selected_osd host $host_name/$host_ip"
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
  } >"$RESULT_DIR/selected-target.env"
  printf '%s\n' "$CEPH_VOLUME_METHOD" >"$RESULT_DIR/ceph-volume-method.txt"
}

# with_sink_wait_attempts <attempts> <cmd...> mirrors lib/monitoring.sh's
# with_prometheus_wait_attempts, but overrides SINK_WAIT_ATTEMPTS instead
# (kept scenario-local like scenario-data-damage.sh's helper of the same
# name -- see that script's own comment for why this isn't hoisted into
# lib/monitoring.sh). Needed alongside the elevated CephDaemonSlowOps
# prometheus wait below: real-lab evidence showed the per-daemon SLOW_OPS
# gauge only sustains > 0 continuously late in a long bench run, so both
# the alert-firing wait and the sink-delivery wait for CephDaemonSlowOps
# need the same generous budget as SLOW_OPS_BENCH_SECONDS.
with_sink_wait_attempts() {
  local attempts=$1
  shift
  local saved="${SINK_WAIT_ATTEMPTS:-60}" rc=0
  SINK_WAIT_ATTEMPTS="$attempts"
  export SINK_WAIT_ATTEMPTS
  "$@" || rc=$?
  SINK_WAIT_ATTEMPTS="$saved"
  export SINK_WAIT_ATTEMPTS
  return "$rc"
}

scenario_setup() {
  while IFS= read -r pool_cmd; do
    run_live_step "pool-setup-$((pool_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
    pool_step=$((pool_step + 1))
  done < <(pool_create_commands "$POOL")

  select_slow_ops_target
  ssh_lab "$OSD_HOST" "stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs"
}

scenario_inject() {
  run_live_step "throttle" "$OSD_HOST" "$(io_throttle_command "$MAJMIN" "$THROTTLE_BPS" "$IO_PATH")"
  start_bench_workload
}

scenario_verify() {
  wait_ceph_health_check SLOW_OPS "$RESULT_DIR"
  wait_prometheus_alert CephClientBlocked name SLOW_OPS "$RESULT_DIR"
  wait_sink_alert pager CephClientBlocked name SLOW_OPS "$RESULT_DIR" "$SINK_CHECKPOINT"
  # CephDaemonSlowOps' for:3m needs the per-daemon SLOW_OPS gauge to stay
  # continuously > 0 for a full 3 minutes; that window can start late into
  # the bench run (after the two CephClientBlocked waits above already ate
  # into it), so give both the firing wait and the sink-delivery wait the
  # same 84*5s=420s budget as SLOW_OPS_BENCH_SECONDS instead of the default
  # 60*5s=300s -- otherwise the wait can time out even though the bench
  # keeps the throttled OSD backed up long enough for the alert to fire.
  with_prometheus_wait_attempts 84 wait_prometheus_alert CephDaemonSlowOps ceph_daemon "osd.$OSD_ID" "$RESULT_DIR"
  with_sink_wait_attempts 84 wait_sink_alert slack CephDaemonSlowOps ceph_daemon "osd.$OSD_ID" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

# Note: clear_bluestore_slow_ops (aging out the latched BLUESTORE_SLOW_OP_ALERT
# warning) must run as part of rollback so HEALTH_OK can be reached before
# scenario_main's assert_lab_recovered polls. Previously this ran after
# collect_postcheck but before assert_lab_recovered; the framework now always
# runs collect_postcheck immediately after scenario_rollback returns, so the
# postcheck evidence snapshot is taken slightly later (after the BlueStore
# warning is cleared) than before. Final pass/fail behavior of recovery is
# unchanged.
scenario_rollback() {
  local rc=0

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
  clear_bluestore_slow_ops || rc=1
  return "$rc"
}

scenario_main slow-ops "$@"
