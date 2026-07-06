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
# Real-lab evidence: a fixed 27GiB-raw-used target never reached on this
# ~900GiB cluster after 10 rounds of throttled (default concurrency) 30s
# `rados bench` writes into a 1-PG pool -- raw used topped out around 900MB
# and even regressed round-over-round (920->836->865MB), because a single PG
# serializes all writes onto one placement group. It also left a latched
# BLUESTORE_SLOW_OP_ALERT that the old rollback never cleared.
#
# This design gives up on hitting a fixed byte target. Instead it fills with
# a MODEST amount of data as fast as this lab can take it (more PGs for
# parallelism, high bench concurrency), measures the fullest OSD's ACTUAL
# utilization afterward, and derives the three ladder ratios as fractions of
# that measurement -- so the ladder always trips regardless of how little (or
# much) data actually landed. CAPACITY_MAX_ROUNDS (default 8) *
# CAPACITY_ROUND_SECONDS (default 60s) of unthrottled -t 64 writes is at most
# a few GiB -- a rounding error against this lab's ~900GiB raw capacity.
CAPACITY_TARGET_OSD_UTIL="${CAPACITY_TARGET_OSD_UTIL:-0.5}"        # percent
CAPACITY_MAX_ROUNDS="${CAPACITY_MAX_ROUNDS:-8}"
CAPACITY_ROUND_SECONDS="${CAPACITY_ROUND_SECONDS:-60}"
# Below this, the fullest OSD's utilization is implausible (bench likely
# wrote nothing at all) -- fatal rather than deriving a near-zero ladder.
CAPACITY_MIN_PLAUSIBLE_UTIL="${CAPACITY_MIN_PLAUSIBLE_UTIL:-0.01}" # percent
MEASURED_UTIL_PERCENT=""
NEARFULL_RATIO=""
BACKFILLFULL_RATIO=""
FULL_RATIO=""
bench_round=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

# fullest_osd_util_percent <df_json> prints the highest per-OSD `utilization`
# field from `ceph osd df --format json` (a PERCENT, e.g. 0.5 means 0.5%
# full), or 0 if the file is missing/unparseable/has no OSD nodes.
fullest_osd_util_percent() {
  local df_json=$1
  jq -r '([.nodes[]? | select(.type=="osd") | .utilization] | max) // 0' "$df_json" 2>/dev/null || printf '0\n'
}

# ratio_fraction_of <util_percent> <fraction> prints, to 5 decimal places,
# <fraction> * (<util_percent> / 100) -- a ceph *-ratio value sitting at
# <fraction> of the measured fullest-OSD utilization ratio. bash has no float
# math, hence awk.
ratio_fraction_of() {
  local util_percent=$1 fraction=$2
  awk -v u="$util_percent" -v f="$fraction" 'BEGIN{printf "%.5f", (u/100)*f}'
}

ratio_is_positive() {
  awk -v r="$1" 'BEGIN{exit !(r+0 > 0)}'
}

# fill_capacity runs high-concurrency, unthrottled `rados bench` write rounds
# against $POOL until the FULLEST OSD's real utilization (from `ceph osd df
# --format json`) reaches CAPACITY_TARGET_OSD_UTIL percent, or
# CAPACITY_MAX_ROUNDS rounds elapse -- whichever comes first. Hitting the
# round cap before the target is NOT a failure: compute_ladder_ratios (below)
# derives the ladder from whatever utilization was actually measured, so it
# always trips. The only real failure is a cluster that received essentially
# no data at all (CAPACITY_MIN_PLAUSIBLE_UTIL guards that).
fill_capacity() {
  local df_json util=0
  while [[ "$bench_round" -le "$CAPACITY_MAX_ROUNDS" ]]; do
    run_live_step "bench-round-$((bench_round))" "$LAB_MON_01_HOST" \
      "sudo -n cephadm shell -- rados bench -p $POOL $CAPACITY_ROUND_SECONDS write -b 4194304 -t 64 --no-cleanup"
    df_json="$RESULT_DIR/osd-df-round-$((bench_round)).json"
    ceph_seed_cmd osd df --format json >"$df_json"
    util="$(fullest_osd_util_percent "$df_json")"
    log "capacity-ladder: round $bench_round fullest OSD utilization = ${util}% (target ${CAPACITY_TARGET_OSD_UTIL}%)"
    if awk -v u="$util" -v t="$CAPACITY_TARGET_OSD_UTIL" 'BEGIN{exit !(u+0 >= t+0)}'; then
      break
    fi
    bench_round=$((bench_round + 1))
  done

  if awk -v u="$util" -v m="$CAPACITY_MIN_PLAUSIBLE_UTIL" 'BEGIN{exit !(u+0 < m+0)}'; then
    die "capacity-ladder: fullest OSD utilization implausibly low (${util}%) after ${CAPACITY_MAX_ROUNDS} round(s) of writes -- bench may not be writing"
  fi

  MEASURED_UTIL_PERCENT="$util"
  printf '%s\n' "$util" >"$RESULT_DIR/measured-fullest-osd-util-percent.txt"
  awk -v u="$util" 'BEGIN{printf "%.6f\n", u/100}' >"$RESULT_DIR/measured-fullest-osd-util-ratio.txt"
}

# compute_ladder_ratios derives the three ladder ratios as fractions
# (0.6/0.7/0.8) of the fullest OSD's measured utilization (set by
# fill_capacity), so all three always sit below it -- guaranteeing
# OSD_NEARFULL/OSD_BACKFILLFULL/OSD_FULL all trip -- while preserving ceph's
# required nearfull < backfillfull < full ordering (0.6*U < 0.7*U < 0.8*U for
# any U > 0).
compute_ladder_ratios() {
  NEARFULL_RATIO="$(ratio_fraction_of "$MEASURED_UTIL_PERCENT" 0.6)"
  BACKFILLFULL_RATIO="$(ratio_fraction_of "$MEASURED_UTIL_PERCENT" 0.7)"
  FULL_RATIO="$(ratio_fraction_of "$MEASURED_UTIL_PERCENT" 0.8)"
  ratio_is_positive "$NEARFULL_RATIO" ||
    die "capacity-ladder: measured fullest OSD utilization (${MEASURED_UTIL_PERCENT}%) is too small to derive a positive nearfull ratio -- raise CAPACITY_TARGET_OSD_UTIL or CAPACITY_MAX_ROUNDS and retry"
}

scenario_setup() {
  # More PGs than the old 1-PG pool, so bench's -t 64 concurrency can
  # actually parallelize writes instead of serializing onto one placement
  # group (the real-lab root cause of the old design's near-zero throughput).
  run_live_step "pool-create" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool create $POOL 8"
  run_live_step "pool-set-size" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool set $POOL size 3"
  run_live_step "pool-set-min-size" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool set $POOL min_size 2"

  fill_capacity
  compute_ladder_ratios
}

scenario_inject() {
  # Rung 1: nearfull. CephOSDNearFull's expr matches a single health check
  # name (no regex alternation), so no label match is needed to disambiguate
  # -- for: 10m, so bump the wait_prometheus_alert budget to outlast it.
  run_live_step "set-nearfull-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-nearfull-ratio $NEARFULL_RATIO"
  wait_ceph_health_check OSD_NEARFULL "$RESULT_DIR"
  with_prometheus_wait_attempts 200 wait_prometheus_alert CephOSDNearFull "" "" "$RESULT_DIR"
  wait_sink_alert slack CephOSDNearFull "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
  assert_sink_absent pager CephOSDNearFull "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"

  # Rung 2: backfillfull. for: 5m.
  run_live_step "set-backfillfull-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-backfillfull-ratio $BACKFILLFULL_RATIO"
  with_prometheus_wait_attempts 120 wait_prometheus_alert CephOSDBackfillFull "" "" "$RESULT_DIR"
  wait_sink_alert pager CephOSDBackfillFull "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"

  # Rung 3: full. OSD_FULL is one of several names CephClientBlocked's expr
  # matches via regex alternation, so the "name" label must be pinned to
  # disambiguate. CephClientBlocked's for: 1m needs no attempts override.
  run_live_step "set-full-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-full-ratio $FULL_RATIO"
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
  local rc=0

  # Restore order full -> backfillfull -> nearfull (reverse of injection) to
  # ceph's stock defaults -- this scenario no longer restores whatever ratios
  # happened to be in effect before injection (see design note above), then
  # clear the BLUESTORE_SLOW_OP_ALERT the heavy fill can trigger, then delete
  # the pool.
  run_live_step "rollback-set-full-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-full-ratio 0.95" || rc=1
  run_live_step "rollback-set-backfillfull-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-backfillfull-ratio 0.9" || rc=1
  run_live_step "rollback-set-nearfull-ratio" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set-nearfull-ratio 0.85" || rc=1
  clear_bluestore_slow_ops "$RESULT_DIR" || rc=1
  run_live_step "rollback-pool-delete" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $(pool_delete_command "$POOL")" || rc=1
  return "$rc"
}

scenario_main capacity-ladder "$@"
