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
NEARQUOTA_TARGET_BYTES="${NEARQUOTA_TARGET_BYTES:-27262976}"
NEARQUOTA_MAX_PUTS="${NEARQUOTA_MAX_PUTS:-20}"
OVERQUOTA_MAX_PUTS="${OVERQUOTA_MAX_PUTS:-20}"
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
# could blow straight past the quota and skip the near-quota phase).
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

# write_past_quota continues puts past the near-quota checkpoint until
# either `ceph df` reports bytes_used at/above the quota, or a put itself
# fails -- a quota rejection IS the expected signal here, so its failure is
# tolerated (`|| put_rc=$?`) and confirmed via the POOL_FULL health check in
# scenario_verify rather than treated as a scenario error.
write_past_quota() {
  local used="" put_rc=0
  while [[ "$obj_index" -le "$OVERQUOTA_MAX_PUTS" ]]; do
    put_rc=0
    run_live_step "put-past-quota-$((obj_index))" "$LAB_MON_01_HOST" \
      "$(quota_shell_cmd "rados -p $POOL put obj-$obj_index $QUOTA_TMPFILE")" || put_rc=$?
    if [[ "$put_rc" -ne 0 ]]; then
      log "pool-quota: put rejected (rc=$put_rc) -- treating this as the expected quota-full signal"
      obj_index=$((obj_index + 1))
      return 0
    fi
    used="$(pool_bytes_used)"
    log "pool-quota: past-quota put $obj_index, bytes_used=${used} (quota ${QUOTA_MAX_BYTES})"
    obj_index=$((obj_index + 1))
    if [[ "$used" =~ ^[0-9]+$ ]] && [[ "$used" -ge "$QUOTA_MAX_BYTES" ]]; then
      return 0
    fi
  done
  die "pool-quota: pool did not fill past the quota (${QUOTA_MAX_BYTES} bytes) after ${OVERQUOTA_MAX_PUTS} puts"
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
  # rollback step is needed.
  run_live_step "rollback-pool-delete" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $(pool_delete_command "$POOL")" || rc=1
  run_capture "$RESULT_DIR/rollback-remove-tmpfile.txt" ssh_lab "$LAB_MON_01_HOST" "rm -f $QUOTA_TMPFILE" || rc=1
  return "$rc"
}

scenario_main pool-quota "$@"
