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
OSD_ID="${SLOW_OPS_OSD_ID:-0}"
OSD_HOST="${SLOW_OPS_OSD_HOST:-$LAB_OSD_01_HOST}"
OSD_DEVICE="${SLOW_OPS_DEVICE:-/dev/sdb}"
THROTTLE_BPS="${SLOW_OPS_THROTTLE_BPS:-65536}"
RESULT_DIR="$(new_result_dir slow-ops)"
OSD_SERVICE="$(osd_service_name "$LAB_FSID" "$OSD_ID")"
IO_PATH=""
MAJMIN=""

cleanup() {
  log "rollback slow-ops scenario"

  if [[ -n "$MAJMIN" && -n "$IO_PATH" ]]; then
    ssh_lab "$OSD_HOST" "$(io_unthrottle_command "$MAJMIN" "$IO_PATH")" || true
  fi

  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $(pool_cleanup_commands "$POOL")" || true
  collect_postcheck "$RESULT_DIR/postcheck" || true
}

trap cleanup EXIT

collect_baseline "$RESULT_DIR/baseline"

while IFS= read -r pool_cmd; do
  ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
done < <(pool_create_commands "$POOL")

ssh_lab "$OSD_HOST" "stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs"
MAJMIN="$(ssh_lab "$OSD_HOST" "lsblk -no MAJ:MIN $OSD_DEVICE | head -1")"
[[ -n "$MAJMIN" ]] || die "could not resolve major:minor for $OSD_DEVICE on $OSD_HOST"

IO_PATH="$(ssh_lab "$OSD_HOST" "$(cgroup_io_max_path_command "$OSD_SERVICE")")"
[[ -n "$IO_PATH" ]] || die "could not resolve io.max path for $OSD_SERVICE on $OSD_HOST"

ssh_lab "$OSD_HOST" "$(io_throttle_command "$MAJMIN" "$THROTTLE_BPS" "$IO_PATH")"

run_capture "$RESULT_DIR/rados-bench.txt" \
  ssh_lab "$LAB_MON_01_HOST" \
  "sudo -n cephadm shell -- rados bench -p $POOL 180 write -b 4194304 -t 16 --no-cleanup" || true

assert_ceph_health_check SLOW_OPS "$RESULT_DIR"
wait_prometheus_alert CephClientBlocked name SLOW_OPS "$RESULT_DIR"
wait_sink_alert pager CephClientBlocked name SLOW_OPS "$RESULT_DIR"

trap - EXIT
cleanup
printf 'result: %s\n' "$RESULT_DIR"
