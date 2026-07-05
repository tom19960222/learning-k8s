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

# SAFETY: this scenario only ever touches ONE object ("victim") inside an
# isolated test pool ("alert-unfound", size 2, min_size 1) that this script
# itself creates and deletes on rollback. The deterministic 6-step dance
# below reproduces Ceph's own documented "object unfound" recovery scenario
# (https://docs.ceph.com/en/latest/rados/troubleshooting/troubleshooting-pg/#failures-osd-peering)
# on purpose, entirely within that isolated pool/PG -- it never touches any
# other pool's data.

POOL="${UNFOUND_POOL:-alert-unfound}"
OBJECT="${UNFOUND_OBJECT:-victim}"
OSD_A=""
OSD_B=""
HOST_A=""
HOST_B=""
SERVICE_A=""
SERVICE_B=""
pool_step=1
cleanup_step=1
transition_step=1
health_poll_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

resolve_osd_host() {
  local osd=$1 find_json host_name host_ip service
  find_json="$RESULT_DIR/osd-find-$osd.json"
  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd find $osd --format json" >"$find_json"
  host_name="$(jq -r '.crush_location.host' "$find_json")"
  host_ip="$(lab_osd_host_ip "$host_name")"
  service="$(osd_service_name "$LAB_FSID" "$osd")"
  printf '%s %s\n' "$host_ip" "$service"
}

# osd_tree_status_is <osd-id> <up|down> mirrors scenario-osd-flapping.sh's
# helper of the same name (kept scenario-local rather than shared -- see
# that script's own comment on why), parameterized on OSD id since this
# scenario alternates polling two different OSDs (A then B).
osd_tree_status_is() {
  local osd=$1 expected=$2 output_file
  output_file="$RESULT_DIR/osd-tree-poll-$((transition_step)).json"
  run_capture "$output_file" ceph_seed_cmd osd tree --format json || return 1
  grep -v '^#' "$output_file" | jq -e --arg osd "$osd" --arg state "$expected" \
    '.nodes[] | select(.id == ($osd|tonumber)) | select(.status == $state)' >/dev/null
}

health_detail_clear_of_unfound() {
  local output_file="$RESULT_DIR/rollback-health-poll-$((health_poll_step)).txt"
  run_capture "$output_file" ceph_seed_cmd health detail || return 1
  health_poll_step=$((health_poll_step + 1))
  ! grep -Fq -- 'OBJECT_UNFOUND' "$output_file"
}

scenario_setup() {
  local map_json="$RESULT_DIR/osd-map.json" resolved

  while IFS= read -r pool_cmd; do
    run_live_step "pool-setup-$((pool_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
    pool_step=$((pool_step + 1))
  done < <(
    printf 'ceph osd pool create %s 1\n' "$POOL"
    printf 'ceph osd pool set %s size 2\n' "$POOL"
    printf 'ceph osd pool set %s min_size 1\n' "$POOL"
    printf 'rados -p %s put %s /etc/hosts\n' "$POOL" "$OBJECT"
  )

  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd map $POOL $OBJECT --format json" >"$map_json"
  OSD_A="$(jq -r '.acting[0]' "$map_json")"
  OSD_B="$(jq -r '.acting[1]' "$map_json")"
  [[ -n "$OSD_A" && "$OSD_A" != "null" && -n "$OSD_B" && "$OSD_B" != "null" ]] ||
    die "expected two acting OSDs for $POOL/$OBJECT"

  resolved="$(resolve_osd_host "$OSD_A")"
  HOST_A="${resolved%% *}"
  SERVICE_A="${resolved#* }"
  resolved="$(resolve_osd_host "$OSD_B")"
  HOST_B="${resolved%% *}"
  SERVICE_B="${resolved#* }"
}

# scenario_inject reproduces Ceph's documented unfound-object dance as a
# deterministic 6-step sequence. Order is load-bearing at every step:
#   1. Stop OSD A (the primary) -- B alone stays up to serve I/O (min_size 1).
#   2. Write a NEW version of the object -- with A down, it only lands on B.
#   3. Freeze recovery (`norecover`) so step 4's restart of A does not just
#      quietly backfill B's newer copy onto A, which would erase the very
#      race this scenario needs to reproduce OBJECT_UNFOUND.
#   4. Start OSD A -- recovery is frozen, so A rejoins still holding its
#      stale copy, not B's newer one.
#   5. Stop OSD B -- the only OSD holding the newer copy is now unavailable.
#      The (live, primary-again) acting set knows a newer version existed
#      but cannot serve it: this is what actually raises OBJECT_UNFOUND.
#   6. Unfreeze recovery -- B (the only OSD with the correct data) is still
#      down at this point, so this does not resolve the unfound state; it
#      only stops suppressing recovery once B eventually returns (rollback).
scenario_inject() {
  run_capture "$RESULT_DIR/step-1-stop-osd-a.txt" ssh_lab "$HOST_A" "sudo systemctl stop $SERVICE_A"
  poll_until "osd.$OSD_A down (step 1)" "${UNFOUND_POLL_ATTEMPTS:-24}" "${UNFOUND_POLL_SLEEP:-5}" osd_tree_status_is "$OSD_A" down
  transition_step=$((transition_step + 1))

  run_capture "$RESULT_DIR/step-2-put-new-version.txt" ssh_lab "$LAB_MON_01_HOST" \
    "sudo -n cephadm shell -- rados -p $POOL put $OBJECT /etc/os-release"

  run_capture "$RESULT_DIR/step-3-set-norecover.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd set norecover"

  run_capture "$RESULT_DIR/step-4-start-osd-a.txt" ssh_lab "$HOST_A" "sudo systemctl start $SERVICE_A"
  poll_until "osd.$OSD_A up (step 4)" "${UNFOUND_POLL_ATTEMPTS:-24}" "${UNFOUND_POLL_SLEEP:-5}" osd_tree_status_is "$OSD_A" up
  transition_step=$((transition_step + 1))

  run_capture "$RESULT_DIR/step-5-stop-osd-b.txt" ssh_lab "$HOST_B" "sudo systemctl stop $SERVICE_B"
  poll_until "osd.$OSD_B down (step 5)" "${UNFOUND_POLL_ATTEMPTS:-24}" "${UNFOUND_POLL_SLEEP:-5}" osd_tree_status_is "$OSD_B" down
  transition_step=$((transition_step + 1))

  run_capture "$RESULT_DIR/step-6-unset-norecover.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd unset norecover"
}

scenario_verify() {
  wait_ceph_health_check OBJECT_UNFOUND "$RESULT_DIR"
  wait_prometheus_alert CephObjectUnfound "" "" "$RESULT_DIR"
  wait_sink_alert pager CephObjectUnfound "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local rc=0 dump_output flag_count

  # Safety net: if scenario_inject failed after step 1 (stop A) but before
  # step 4 (start A) restored it, A would otherwise be left down. `systemctl
  # start` on an already-started unit (the normal path, where step 4 already
  # started it) is a no-op success, so this is safe to always run.
  if [[ -n "$HOST_A" && -n "$SERVICE_A" ]]; then
    run_capture "$RESULT_DIR/rollback-ensure-osd-a-started.txt" ssh_lab "$HOST_A" "sudo systemctl start $SERVICE_A" || rc=1
  fi

  # Order matters: OBJECT_UNFOUND only clears once OSD B (the OSD holding
  # the correct/newer copy of the object) is back up and Ceph can recover
  # from it -- starting B must happen before polling for the health check to
  # clear, and the pool must not be deleted before that clears either.
  if [[ -n "$HOST_B" && -n "$SERVICE_B" ]]; then
    run_capture "$RESULT_DIR/rollback-start-osd-b.txt" ssh_lab "$HOST_B" "sudo systemctl start $SERVICE_B" || rc=1
  fi

  poll_until "OBJECT_UNFOUND cleared from health detail" \
    "${UNFOUND_RECOVERY_ATTEMPTS:-60}" "${UNFOUND_RECOVERY_SLEEP:-5}" health_detail_clear_of_unfound || rc=1

  # Step 6 in scenario_inject already unsets norecover -- this is a
  # defensive, idempotent safety net (`ceph osd unset norecover` on an
  # already-unset flag is a no-op success) in case an earlier inject step
  # failed partway (e.g. after step 3's `ceph osd set norecover` but before
  # step 6 ran).
  dump_output="$RESULT_DIR/rollback-osd-dump-flags.txt"
  run_capture "$dump_output" ceph_seed_cmd osd dump || rc=1
  flag_count="$(grep -c 'norecover' "$dump_output" || true)"
  if [[ "$flag_count" -ne 0 ]]; then
    log "norecover flag still set during rollback; unsetting defensively"
    run_capture "$RESULT_DIR/rollback-unset-norecover.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd unset norecover" || true
  fi

  while IFS= read -r cleanup_cmd; do
    run_live_step "rollback-pool-cleanup-$((cleanup_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $cleanup_cmd" || rc=1
    cleanup_step=$((cleanup_step + 1))
  done < <(pool_cleanup_commands "$POOL")
  return "$rc"
}

scenario_main object-unfound "$@"
