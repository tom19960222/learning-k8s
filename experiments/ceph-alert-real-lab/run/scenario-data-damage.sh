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
# ceph-objectstore-tool's `set-bytes` overwrites that single OSD's on-disk
# copy of the object's content directly (never against a live/production
# OSD -- it refuses to run while the OSD daemon owns the store, which is
# why the down-poll below is not optional -- and never touching the other
# two replicas). Because two of the three replicas remain intact, `ceph pg
# repair`'s scrub-based majority vote always resolves in the correct
# direction -- the two good copies outvote the one deliberately corrupted
# copy -- so there is no path here that can corrupt real data or repair in
# the wrong direction.
#
# Why `set-bytes` and not `remove`: `remove` deletes the object from the
# replica entirely, which makes it MISSING rather than merely wrong. A
# missing object is exactly what Ceph's ordinary recovery (triggered by the
# OSD rejoining the PG after restart) exists to fix -- recovery copies it
# back from a healthy replica, silently healing the injected damage before
# deep-scrub ever gets a chance to detect it. That made the old injection a
# race between recovery (heals) and deep-scrub (detects): one real-lab run
# got lucky (scrub won, OSD_SCRUB_ERRORS appeared in ~40s), a second run
# lost the race (recovery won first, so the requested deep-scrub found
# nothing wrong, and the OSD_SCRUB_ERRORS wait timed out after 10 minutes).
# `set-bytes` instead leaves the object PRESENT but with corrupted content
# (different length and bytes than the two good replicas), so the PG can
# reach active+clean immediately -- recovery has nothing to fix, since
# nothing is missing -- and the corruption stays latent (and deterministic)
# until a deep-scrub actually reads and checksums it. This removes the
# recovery/scrub race entirely.

# OSD_SCRUB_ERRORS is only raised once ceph's scrub scheduler actually gets
# around to running the deep-scrub this scenario requests (requesting one
# only enqueues it; the OSD decides when to run it), which can lag past a
# single poll window. deep_scrub_wait_with_reissue below re-issues the
# (idempotent) deep-scrub request between bounded sub-windows rather than
# trusting one request to eventually get serviced -- see that function's
# comment for why re-issuing is safe here (content corruption never heals
# on its own, so a later scrub finds the exact same inconsistency an
# earlier one would have).
DATA_DAMAGE_SCRUB_SUBWINDOW_ATTEMPTS="${DATA_DAMAGE_SCRUB_SUBWINDOW_ATTEMPTS:-18}"
DATA_DAMAGE_SCRUB_REISSUE_ROUNDS="${DATA_DAMAGE_SCRUB_REISSUE_ROUNDS:-7}"

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

# with_ceph_health_check_attempts <attempts> <cmd...> mirrors
# with_sink_wait_attempts above, but overrides CEPH_HEALTH_CHECK_ATTEMPTS
# instead -- used by deep_scrub_wait_with_reissue below to bound each
# sub-window poll of wait_ceph_health_check without needing a shared-lib
# change (evidence.sh's wait_ceph_health_check already reads this var).
with_ceph_health_check_attempts() {
  local attempts=$1
  shift
  local saved="${CEPH_HEALTH_CHECK_ATTEMPTS:-60}" rc=0
  CEPH_HEALTH_CHECK_ATTEMPTS="$attempts"
  export CEPH_HEALTH_CHECK_ATTEMPTS
  "$@" || rc=$?
  CEPH_HEALTH_CHECK_ATTEMPTS="$saved"
  export CEPH_HEALTH_CHECK_ATTEMPTS
  return "$rc"
}

# deep_scrub_wait_with_reissue polls for OSD_SCRUB_ERRORS in bounded
# sub-windows (DATA_DAMAGE_SCRUB_SUBWINDOW_ATTEMPTS attempts each, at
# CEPH_HEALTH_CHECK_SLEEP seconds apart), re-issuing the deep-scrub request
# between sub-windows -- up to DATA_DAMAGE_SCRUB_REISSUE_ROUNDS times total
# -- rather than trusting a single request to eventually get serviced by
# ceph's scrub scheduler. This is safe to do repeatedly because the
# injected damage is content corruption (set-bytes), which is a permanent
# PG inconsistency: nothing heals it between rounds, so a re-issued
# deep-scrub always finds exactly the same discrepancy an earlier one
# would have. (Contrast the old `remove`-based injection this replaced,
# where re-issuing a scrub after recovery had already healed the object
# would just find nothing -- re-issuing only became safe once the race
# with recovery was removed by switching to content corruption.)
deep_scrub_wait_with_reissue() {
  local subwindow="${DATA_DAMAGE_SCRUB_SUBWINDOW_ATTEMPTS:-18}"
  local rounds="${DATA_DAMAGE_SCRUB_REISSUE_ROUNDS:-7}"
  local round=1
  while [[ "$round" -le "$rounds" ]]; do
    if with_ceph_health_check_attempts "$subwindow" wait_ceph_health_check OSD_SCRUB_ERRORS "$RESULT_DIR"; then
      return 0
    fi
    log "OSD_SCRUB_ERRORS not observed within sub-window $round/$rounds; re-issuing deep-scrub $PGID"
    run_live_step "deep-scrub-reissue-$round" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph pg deep-scrub $PGID"
    round=$((round + 1))
  done
  return 1
}

# osd_tree_status_is mirrors scenario-osd-flapping.sh's helper of the same
# name (kept scenario-local rather than shared -- see that script's own
# comment: this is orchestration specific to this scenario's OSD_ID, not a
# reusable primitive). Captures stdout-only into $output_file so it holds
# clean, directly-jq-able JSON as evidence -- `cephadm shell` prints a
# multi-line "Inferring fsid/config .../Using ceph image ..." banner to
# stderr on every invocation, which is NOT '#'-prefixed and would otherwise
# corrupt the JSON body if merged in (e.g. via run_capture's 2>&1). That
# banner is preserved separately as evidence in $output_file.log.
osd_tree_status_is() {
  local expected=$1 output_file
  output_file="$RESULT_DIR/osd-tree-poll-$((tree_poll_step)).json"
  ceph_seed_cmd osd tree --format json >"$output_file" 2>"$output_file.log" || return 1
  tree_poll_step=$((tree_poll_step + 1))
  jq -e --arg osd "$OSD_ID" --arg state "$expected" \
    '.nodes[] | select(.id == ($osd|tonumber)) | select(.status == $state)' "$output_file" >/dev/null
}

# pg_query_state_contains polls `ceph pg <pgid> query --format json` (whose
# .state field is a "+"-joined string like "active+clean") for a substring,
# used here to confirm the PG has fully re-peered to active+clean (i.e.
# recovery has finished, not merely started re-peering) after the OSD
# restart -- required before issuing the deep-scrub below, since the
# corrupted object is present the moment the PG goes clean (recovery has
# nothing to fix; nothing is missing), so there is no need to wait any
# longer than that. Same stdout/stderr split as osd_tree_status_is above,
# and for the same reason: the cephadm banner on stderr is not
# '#'-prefixed and would corrupt the JSON body if merged in.
pg_query_state_contains() {
  local expected=$1 output_file
  output_file="$RESULT_DIR/pg-query-poll-$((pg_poll_step)).json"
  ceph_seed_cmd pg "$PGID" query --format json >"$output_file" 2>"$output_file.log" || return 1
  pg_poll_step=$((pg_poll_step + 1))
  jq -e --arg s "$expected" \
    'if (.state|type)=="string" then (.state|contains($s)) else false end' "$output_file" >/dev/null
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
  #
  # `set-bytes` positional syntax verified against the vendored source
  # (ceph/src/tools/ceph_objectstore_tool.cc): the positional_options
  # description binds `<object> <objcmd> [<arg1>] [<arg2>]` (pd.add("object",
  # 1).add("objcmd", 1).add("arg1", 1).add("arg2", 1)), and the "set-bytes"
  # branch (do_set_bytes) reads arg1 as a file path to open() and use as the
  # new object content when arg1 is given and isn't "-" -- so `<object>
  # set-bytes <file>` (not stdin) is exact. The garbage file is written
  # first inside the same `sh -c` invocation, sized at 64KiB so it differs
  # in both length and content from the tiny /etc/hosts object this scenario
  # seeded, guaranteeing deep-scrub's digest/size compare flags a mismatch.
  run_capture "$RESULT_DIR/objectstore-tool-corrupt.txt" ssh_lab "$OSD_HOST" \
    "sudo -n cephadm shell --name osd.$OSD_ID -- sh -c 'head -c 65536 /dev/urandom >/tmp/data-damage-garbage && ceph-objectstore-tool --data-path /var/lib/ceph/osd/ceph-$OSD_ID --pgid $PGID $OBJECT set-bytes /tmp/data-damage-garbage'"

  run_live_step "start-osd" "$OSD_HOST" "sudo systemctl start $OSD_SERVICE"
  poll_until "osd.$OSD_ID up after objectstore-tool" "${DATA_DAMAGE_POLL_ATTEMPTS:-24}" "${DATA_DAMAGE_POLL_SLEEP:-5}" osd_tree_status_is up
  poll_until "pg $PGID active+clean after osd.$OSD_ID restart" "${DATA_DAMAGE_PG_POLL_ATTEMPTS:-60}" "${DATA_DAMAGE_PG_POLL_SLEEP:-5}" pg_query_state_contains "active+clean"

  run_live_step "deep-scrub" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph pg deep-scrub $PGID"
}

scenario_verify() {
  deep_scrub_wait_with_reissue
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
