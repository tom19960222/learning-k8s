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

POOL="${CAPACITY_POOL:-alert-capacity}"
# ~3% of this lab cluster's raw capacity; comfortably clears the artificially
# lowered nearfull/backfillfull/full ratios set by the ladder below.
CAPACITY_TARGET_RAW_BYTES="${CAPACITY_TARGET_RAW_BYTES:-28991029248}"
CAPACITY_MAX_ROUNDS="${CAPACITY_MAX_ROUNDS:-10}"
RATIOS_BEFORE_FILE=""
pool_step=1
bench_round=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

# read_ratio <field> <default> reads a ratio recorded in ratios-before.json
# (the full `ceph osd dump --format json` output captured during setup),
# falling back to <default> if the file is missing, unparseable, or the
# field is absent/null.
read_ratio() {
  local field=$1 default=$2 value=""
  if [[ -f "$RATIOS_BEFORE_FILE" ]]; then
    value="$(jq -r --arg f "$field" '.[$f] // empty' "$RATIOS_BEFORE_FILE" 2>/dev/null || true)"
  fi
  if [[ -n "$value" && "$value" != "null" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}

# fill_capacity runs `rados bench` write rounds against $POOL until
# `ceph df`'s raw used bytes clears CAPACITY_TARGET_RAW_BYTES, or dies after
# CAPACITY_MAX_ROUNDS rounds (a setup failure here still lets scenario_main's
# EXIT trap run scenario_rollback, which deletes the pool).
fill_capacity() {
  local df_json used
  while [[ "$bench_round" -le "$CAPACITY_MAX_ROUNDS" ]]; do
    run_live_step "bench-round-$((bench_round))" "$LAB_MON_01_HOST" \
      "sudo -n cephadm shell -- rados bench -p $POOL 30 write --no-cleanup"
    df_json="$RESULT_DIR/ceph-df-round-$((bench_round)).json"
    ceph_seed_cmd df --format json >"$df_json"
    used="$(jq -r '.stats.total_used_raw_bytes' "$df_json")"
    log "capacity-ladder: round $bench_round raw used = ${used} bytes (target ${CAPACITY_TARGET_RAW_BYTES})"
    if [[ "$used" =~ ^[0-9]+$ ]] && [[ "$used" -ge "$CAPACITY_TARGET_RAW_BYTES" ]]; then
      return 0
    fi
    bench_round=$((bench_round + 1))
  done
  die "capacity-ladder: raw used bytes did not reach ${CAPACITY_TARGET_RAW_BYTES} after ${CAPACITY_MAX_ROUNDS} rounds"
}

scenario_setup() {
  while IFS= read -r pool_cmd; do
    run_live_step "pool-setup-$((pool_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
    pool_step=$((pool_step + 1))
  done < <(pool_create_commands "$POOL")

  RATIOS_BEFORE_FILE="$RESULT_DIR/ratios-before.json"
  ceph_seed_cmd osd dump --format json >"$RATIOS_BEFORE_FILE"

  fill_capacity
}

scenario_inject() {
  # Rung 1: nearfull. CephOSDNearFull's expr matches a single health check
  # name (no regex alternation), so no label match is needed to disambiguate
  # -- for: 10m, so bump the wait_prometheus_alert budget to outlast it.
  run_live_step "set-nearfull-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-nearfull-ratio 0.02"
  wait_ceph_health_check OSD_NEARFULL "$RESULT_DIR"
  with_prometheus_wait_attempts 200 wait_prometheus_alert CephOSDNearFull "" "" "$RESULT_DIR"
  wait_sink_alert slack CephOSDNearFull "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
  assert_sink_absent pager CephOSDNearFull "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"

  # Rung 2: backfillfull. for: 5m.
  run_live_step "set-backfillfull-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-backfillfull-ratio 0.022"
  with_prometheus_wait_attempts 120 wait_prometheus_alert CephOSDBackfillFull "" "" "$RESULT_DIR"
  wait_sink_alert pager CephOSDBackfillFull "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"

  # Rung 3: full. OSD_FULL is one of several names CephClientBlocked's expr
  # matches via regex alternation, so the "name" label must be pinned to
  # disambiguate. CephClientBlocked's for: 1m needs no attempts override.
  run_live_step "set-full-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-full-ratio 0.025"
  wait_ceph_health_check OSD_FULL "$RESULT_DIR"
  wait_prometheus_alert CephClientBlocked name OSD_FULL "$RESULT_DIR"
  wait_sink_alert pager CephClientBlocked name OSD_FULL "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_verify() {
  # Cluster HEALTH_ERR (driven by OSD_FULL) also trips the default mixin's
  # CephHealthError, for: 5m -- this is the ladder's final rung.
  with_prometheus_wait_attempts 150 wait_prometheus_alert CephHealthError "" "" "$RESULT_DIR"
  wait_sink_alert pager CephHealthError "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local rc=0 full backfillfull nearfull
  full="$(read_ratio full_ratio 0.95)"
  backfillfull="$(read_ratio backfillfull_ratio 0.90)"
  nearfull="$(read_ratio nearfull_ratio 0.85)"

  # Restore order full -> backfillfull -> nearfull (reverse of injection),
  # then delete the pool.
  run_live_step "rollback-set-full-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-full-ratio $full" || rc=1
  run_live_step "rollback-set-backfillfull-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-backfillfull-ratio $backfillfull" || rc=1
  run_live_step "rollback-set-nearfull-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-nearfull-ratio $nearfull" || rc=1
  run_live_step "rollback-pool-delete" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $(pool_delete_command "$POOL")" || rc=1
  return "$rc"
}

scenario_main capacity-ladder "$@"
