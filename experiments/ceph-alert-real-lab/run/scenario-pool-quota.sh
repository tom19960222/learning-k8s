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

POOL="${QUOTA_POOL:-alert-quota}"
QUOTA_MAX_BYTES="${QUOTA_MAX_BYTES:-33554432}"       # 32MiB
QUOTA_TMPFILE="${QUOTA_TMPFILE:-/tmp/alert-quota-4mib.bin}"
# 26MiB = 81% of the 32MiB quota: high enough to clear CephPoolNearQuota's
# >80% threshold, comfortably below 100% so the near-quota `for:` window
# never risks crossing into POOL_FULL territory.
#
# Real-lab accounting-overshoot caveat: `ceph df`'s bytes_used does not
# advance by a clean 4MiB per 4MiB put -- on the size=3 replicated pool this
# scenario creates, a single put has been observed to jump bytes_used by
# 8-21MiB (replication fan-out + bluestore allocation rounding), not a fixed
# 4MiB. That is why write_near_quota (below) checks bytes_used after EVERY
# single put and stops at the FIRST one that clears this target, instead of
# precomputing "N puts * 4MiB" up front -- it cannot control how big any one
# jump is, so the only guarantee it can offer is "never issue another
# near-quota put once the target is already cleared."
NEARQUOTA_TARGET_BYTES="${NEARQUOTA_TARGET_BYTES:-27262976}"
NEARQUOTA_MAX_PUTS="${NEARQUOTA_MAX_PUTS:-20}"
# OVERQUOTA_MAX_PUTS bounds the number of past-quota put ATTEMPTS (see
# write_past_quota), not the global object index. Each attempt is a bounded
# (`timeout 30`) put, and real-lab evidence shows POOL_FULL surfaces within
# seconds of sustained write pressure once the pool is actually full, so 40
# attempts (at most 160MiB of put traffic, since a full pool stops accepting
# new bytes once it is actually full) is a generous cap against a
# persistently silent mon rather than an expected steady-state count.
OVERQUOTA_MAX_PUTS="${OVERQUOTA_MAX_PUTS:-40}"
pool_step=1
obj_index=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

# rados put/get for this scenario runs inside `cephadm shell --mount /tmp:/tmp`
# so the container can see the 4MiB tmpfile created directly on the seed
# host below (cephadm shell's default bind mounts do not include /tmp).
quota_shell_cmd() {
  printf 'sudo -n cephadm shell --mount /tmp:/tmp -- %s\n' "$1"
}

pool_bytes_used() {
  local output_file="$RESULT_DIR/ceph-df-check-$((obj_index)).json"
  ceph_seed_cmd df --format json >"$output_file"
  jq -r --arg pool "$POOL" '.pools[] | select(.name==$pool) | .stats.bytes_used' "$output_file"
}

scenario_setup() {
  while IFS= read -r pool_cmd; do
    run_live_step "pool-setup-$((pool_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
    pool_step=$((pool_step + 1))
  done < <(pool_create_commands "$POOL")

  run_live_step "set-quota" "$LAB_MON_01_HOST" \
    "sudo -n cephadm shell -- ceph osd pool set-quota $POOL max_bytes $QUOTA_MAX_BYTES"

  run_capture "$RESULT_DIR/create-tmpfile.txt" ssh_lab "$LAB_MON_01_HOST" \
    "dd if=/dev/zero of=$QUOTA_TMPFILE bs=1M count=4"
}

# write_near_quota puts 4MiB objects one at a time, checking the pool's
# bytes_used between puts, until it clears NEARQUOTA_TARGET_BYTES (a
# CONTROLLED counted loop -- not `rados bench`, whose uncontrolled overshoot
# could blow straight past the quota and skip the near-quota phase). See the
# accounting-overshoot caveat above NEARQUOTA_TARGET_BYTES for why this loop
# cannot precompute how many puts are needed.
write_near_quota() {
  local used=""
  while [[ "$obj_index" -le "$NEARQUOTA_MAX_PUTS" ]]; do
    run_live_step "put-near-quota-$((obj_index))" "$LAB_MON_01_HOST" \
      "$(quota_shell_cmd "rados -p $POOL put obj-$obj_index $QUOTA_TMPFILE")"
    used="$(pool_bytes_used)"
    log "pool-quota: near-quota put $obj_index, bytes_used=${used} (target >= ${NEARQUOTA_TARGET_BYTES})"
    obj_index=$((obj_index + 1))
    if [[ "$used" =~ ^[0-9]+$ ]] && [[ "$used" -ge "$NEARQUOTA_TARGET_BYTES" ]]; then
      return 0
    fi
  done
  die "pool-quota: did not reach near-quota target (${NEARQUOTA_TARGET_BYTES} bytes) after ${NEARQUOTA_MAX_PUTS} puts"
}

# write_past_quota keeps REAL client write pressure on the pool once it is
# at or past its quota, instead of stopping after a single over-quota put.
#
# Real-lab evidence: a single put that lands over quota, followed by no
# further write activity, does NOT reliably surface the POOL_FULL health
# check within a normal poll window (observed: wait_ceph_health_check
# POOL_FULL timed out after ~6.5min with zero ongoing writes once the prior
# version of this function stopped after one over-quota put). Ceph's mon
# only raises POOL_FULL while a client is actively hitting the quota wall --
# write, get blocked/rejected, write again -- so this loop keeps putting
# objects and polling `ceph health detail` after every attempt, stopping the
# instant POOL_FULL appears (confirmed again, via the poll in
# scenario_verify, once this returns).
#
# Each put is wrapped in a remote `timeout 30` so a put that BLOCKS on the
# quota (rather than failing outright with EDQUOT) cannot hang the scenario:
# exit 124 is the EXPECTED signal here -- it IS the pool-full pressure
# signal, on equal footing with any other nonzero exit from a rejected put --
# and is tolerated (`|| put_rc=$?`), not treated as a scenario failure.
write_past_quota() {
  local used="" put_rc=0 attempt=0
  while [[ "$attempt" -lt "$OVERQUOTA_MAX_PUTS" ]]; do
    attempt=$((attempt + 1))
    put_rc=0
    run_live_step "put-past-quota-$((obj_index))" "$LAB_MON_01_HOST" \
      "$(quota_shell_cmd "timeout 30 rados -p $POOL put obj-$obj_index $QUOTA_TMPFILE")" || put_rc=$?
    case "$put_rc" in
      0)
        used="$(pool_bytes_used)"
        log "pool-quota: past-quota put $obj_index succeeded, bytes_used=${used} (quota ${QUOTA_MAX_BYTES})"
        ;;
      124)
        log "pool-quota: past-quota put $obj_index timed out after 30s -- pool is enforcing the quota (expected write-pressure signal)"
        ;;
      *)
        log "pool-quota: past-quota put $obj_index rejected (rc=$put_rc) -- expected quota-full signal"
        ;;
    esac
    obj_index=$((obj_index + 1))
    if assert_ceph_health_check POOL_FULL "$RESULT_DIR"; then
      return 0
    fi
  done
  die "pool-quota: POOL_FULL health check did not appear after ${OVERQUOTA_MAX_PUTS} past-quota put attempts"
}

scenario_inject() {
  write_near_quota
  with_prometheus_wait_attempts 200 wait_prometheus_alert CephPoolNearQuota name "$POOL" "$RESULT_DIR"
  wait_sink_alert slack CephPoolNearQuota name "$POOL" "$RESULT_DIR" "$SINK_CHECKPOINT"

  write_past_quota
}

scenario_verify() {
  wait_ceph_health_check POOL_FULL "$RESULT_DIR"
  wait_prometheus_alert CephClientBlocked name POOL_FULL "$RESULT_DIR"
  wait_sink_alert pager CephClientBlocked name POOL_FULL "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local rc=0
  # The quota dies with the pool -- no separate `ceph osd pool set-quota ... 0`
  # rollback step is needed. Any past-quota put still in flight is bounded by
  # its own remote `timeout 30` (see write_past_quota), and this pool delete
  # starves anything left once that timeout has (or is about to have) fired.
  run_live_step "rollback-pool-delete" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $(pool_delete_command "$POOL")" || rc=1
  run_capture "$RESULT_DIR/rollback-remove-tmpfile.txt" ssh_lab "$LAB_MON_01_HOST" "rm -f $QUOTA_TMPFILE" || rc=1
  return "$rc"
}

scenario_main pool-quota "$@"
