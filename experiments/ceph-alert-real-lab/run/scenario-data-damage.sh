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

# SAFETY: this scenario only ever touches ONE replica of ONE object
# ("victim") inside an isolated test pool ("alert-damage", size 3, min_size
# 2) that this script itself creates and deletes on rollback.
# ceph-objectstore-tool's `remove` runs directly against that single OSD's
# on-disk copy while its daemon is stopped (never against a live/production
# OSD, and never touching the other two replicas). Because two of the three
# replicas remain intact, `ceph pg repair`'s scrub-based majority vote always
# resolves in the correct direction -- the two good copies outvote the one
# deliberately damaged copy -- so there is no path here that can corrupt real
# data or repair in the wrong direction.

# OSD_SCRUB_ERRORS is only raised once ceph's scrub scheduler actually gets
# around to running the deep-scrub this scenario requests below (requesting
# one only enqueues it; the OSD decides when to run it), which can lag well
# past the framework's default 60 attempts * 5s = 300s window, so bump it up.
CEPH_HEALTH_CHECK_ATTEMPTS="${CEPH_HEALTH_CHECK_ATTEMPTS:-120}"
export CEPH_HEALTH_CHECK_ATTEMPTS

POOL="${DATA_DAMAGE_POOL:-alert-damage}"
OBJECT="${DATA_DAMAGE_OBJECT:-victim}"
PGID=""
OSD_ID=""
OSD_HOST=""
OSD_SERVICE=""
pool_step=1
cleanup_step=1
tree_poll_step=1
pg_poll_step=1
health_poll_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

# with_sink_wait_attempts <attempts> <cmd...> mirrors lib/monitoring.sh's
# with_prometheus_wait_attempts, but overrides SINK_WAIT_ATTEMPTS instead.
# Needed because CephHealthError's own for:5m window is not otherwise
# already spanned by a preceding wait_prometheus_alert call in this scenario
# (unlike e.g. scenario-capacity-ladder.sh, which pairs a
# with_prometheus_wait_attempts 150 wait_prometheus_alert CephHealthError
# call with a default-attempts sink wait right after -- by the time that
# sink wait runs, the for:5m window is already known to have elapsed here).
# This scenario only waits on the sink delivery directly, so that wait alone
# must span the window: the default 60 attempts * 5s = 300s sits exactly at
# the 5m boundary, so push it out with margin.
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

# osd_tree_status_is mirrors scenario-osd-flapping.sh's helper of the same
# name (kept scenario-local rather than shared -- see that script's own
# comment: this is orchestration specific to this scenario's OSD_ID, not a
# reusable primitive).
osd_tree_status_is() {
  local expected=$1 output_file
  output_file="$RESULT_DIR/osd-tree-poll-$((tree_poll_step)).json"
  run_capture "$output_file" ceph_seed_cmd osd tree --format json || return 1
  tree_poll_step=$((tree_poll_step + 1))
  grep -v '^#' "$output_file" | jq -e --arg osd "$OSD_ID" --arg state "$expected" \
    '.nodes[] | select(.id == ($osd|tonumber)) | select(.status == $state)' >/dev/null
}

# pg_query_state_contains polls `ceph pg <pgid> query --format json` (whose
# .state field is a "+"-joined string like "active+clean") for a substring,
# used here to confirm the PG has re-peered to active after the OSD restart.
pg_query_state_contains() {
  local expected=$1 output_file
  output_file="$RESULT_DIR/pg-query-poll-$((pg_poll_step)).json"
  run_capture "$output_file" ceph_seed_cmd pg "$PGID" query --format json || return 1
  pg_poll_step=$((pg_poll_step + 1))
  grep -v '^#' "$output_file" | jq -e --arg s "$expected" \
    'if (.state|type)=="string" then (.state|contains($s)) else false end' >/dev/null
}

health_detail_clear_of_damage() {
  local output_file="$RESULT_DIR/rollback-health-poll-$((health_poll_step)).txt"
  run_capture "$output_file" ceph_seed_cmd health detail || return 1
  health_poll_step=$((health_poll_step + 1))
  ! grep -Fq -- 'OSD_SCRUB_ERRORS' "$output_file" && ! grep -Fq -- 'PG_DAMAGED' "$output_file"
}

scenario_setup() {
  local map_json="$RESULT_DIR/osd-map.json" find_json host_name

  while IFS= read -r pool_cmd; do
    run_live_step "pool-setup-$((pool_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
    pool_step=$((pool_step + 1))
  done < <(
    printf 'ceph osd pool create %s 1\n' "$POOL"
    printf 'ceph osd pool set %s size 3\n' "$POOL"
    printf 'ceph osd pool set %s min_size 2\n' "$POOL"
    printf 'rados -p %s put %s /etc/hosts\n' "$POOL" "$OBJECT"
  )

  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd map $POOL $OBJECT --format json" >"$map_json"
  PGID="$(jq -r '.pgid' "$map_json")"
  OSD_ID="$(jq -r '.acting[1]' "$map_json")"
  [[ -n "$PGID" && "$PGID" != "null" ]] || die "could not resolve pgid for $POOL/$OBJECT"
  [[ -n "$OSD_ID" && "$OSD_ID" != "null" ]] || die "expected a non-primary acting OSD for $POOL/$OBJECT"

  find_json="$RESULT_DIR/osd-find.json"
  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd find $OSD_ID --format json" >"$find_json"
  host_name="$(jq -r '.crush_location.host' "$find_json")"
  OSD_HOST="$(lab_osd_host_ip "$host_name")"
  OSD_SERVICE="$(osd_service_name "$LAB_FSID" "$OSD_ID")"
}

scenario_inject() {
  run_live_step "stop-osd" "$OSD_HOST" "sudo systemctl stop $OSD_SERVICE"
  poll_until "osd.$OSD_ID down before objectstore-tool" "${DATA_DAMAGE_POLL_ATTEMPTS:-24}" "${DATA_DAMAGE_POLL_SLEEP:-5}" osd_tree_status_is down

  # ceph-objectstore-tool runs directly on the target OSD's own host (not the
  # seed mon) via that OSD's own cephadm shell identity, and refuses to touch
  # the object store while its daemon is still running against it -- the
  # poll above is not optional, it is what makes this safe.
  run_capture "$RESULT_DIR/objectstore-tool-remove.txt" ssh_lab "$OSD_HOST" \
    "sudo -n cephadm shell --name osd.$OSD_ID -- ceph-objectstore-tool --data-path /var/lib/ceph/osd/ceph-$OSD_ID --pgid $PGID $OBJECT remove"

  run_live_step "start-osd" "$OSD_HOST" "sudo systemctl start $OSD_SERVICE"
  poll_until "osd.$OSD_ID up after objectstore-tool" "${DATA_DAMAGE_POLL_ATTEMPTS:-24}" "${DATA_DAMAGE_POLL_SLEEP:-5}" osd_tree_status_is up
  poll_until "pg $PGID active after osd.$OSD_ID restart" "${DATA_DAMAGE_PG_POLL_ATTEMPTS:-60}" "${DATA_DAMAGE_PG_POLL_SLEEP:-5}" pg_query_state_contains active

  run_live_step "deep-scrub" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph pg deep-scrub $PGID"
}

scenario_verify() {
  wait_ceph_health_check OSD_SCRUB_ERRORS "$RESULT_DIR"
  wait_prometheus_alert CephDataDamage "" "" "$RESULT_DIR"
  wait_sink_alert pager CephDataDamage "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
  # PG_DAMAGED/OSD_SCRUB_ERRORS also drives cluster health to HEALTH_ERR,
  # which trips the default mixin's CephHealthError (for:5m) -- see the
  # with_sink_wait_attempts comment above for why this call carries its own
  # extended attempts budget.
  with_sink_wait_attempts 150 wait_sink_alert pager CephHealthError "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local rc=0

  # Safety net: if scenario_inject failed after stopping the OSD but before
  # its own restart step ran (e.g. ceph-objectstore-tool itself failed), the
  # OSD would otherwise be left down. `systemctl start` on an already-started
  # unit (the normal path, where scenario_inject already restarted it) is a
  # no-op success, so this is safe to always run.
  if [[ -n "$OSD_HOST" && -n "$OSD_SERVICE" ]]; then
    run_live_step "rollback-ensure-osd-started" "$OSD_HOST" "sudo systemctl start $OSD_SERVICE" || rc=1
  fi

  if [[ -n "$PGID" ]]; then
    run_live_step "rollback-pg-repair" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph pg repair $PGID" || rc=1
  fi

  # Repair direction is inherently correct here (see the SAFETY comment at
  # the top of this file) -- but health takes time to reflect the repair, so
  # poll with a generous budget rather than assuming it clears instantly.
  poll_until "OSD_SCRUB_ERRORS/PG_DAMAGED cleared from health detail" \
    "${DATA_DAMAGE_REPAIR_ATTEMPTS:-120}" "${DATA_DAMAGE_REPAIR_SLEEP:-5}" health_detail_clear_of_damage || rc=1

  while IFS= read -r cleanup_cmd; do
    run_live_step "rollback-pool-cleanup-$((cleanup_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $cleanup_cmd" || rc=1
    cleanup_step=$((cleanup_step + 1))
  done < <(pool_cleanup_commands "$POOL")
  return "$rc"
}

scenario_main data-damage "$@"
