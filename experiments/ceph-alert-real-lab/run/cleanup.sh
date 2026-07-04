#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/monitoring.sh
source "$ROOT/lib/monitoring.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/scenarios.sh
source "$ROOT/lib/scenarios.sh"

pool_delete_best_effort() {
  local pool=$1
  if ssh_lab "$LAB_MON_01_HOST" \
    "sudo -n cephadm shell -- ceph osd pool delete $pool $pool --yes-i-really-really-mean-it" \
    >/dev/null 2>&1; then
    log "deleted test pool $pool"
    return 0
  fi
  log "skip deleting test pool $pool"
  return 0
}

clear_known_cgroup_throttles() {
  local osd_id osd_host osd_device osd_service majmin io_path
  osd_id="${SLOW_OPS_OSD_ID:-0}"
  osd_host="${SLOW_OPS_OSD_HOST:-$LAB_OSD_01_HOST}"
  osd_device="${SLOW_OPS_DEVICE:-/dev/sdb}"
  osd_service="$(osd_service_name "$LAB_FSID" "$osd_id")"

  if ! ssh_lab "$osd_host" "stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs" >/dev/null 2>&1; then
    log "skip cgroup throttle cleanup on $osd_host: cgroup v2 unavailable"
    return 0
  fi

  majmin="$(ssh_lab "$osd_host" "lsblk -no MAJ:MIN $osd_device | head -1" 2>/dev/null || true)"
  if [[ -z "$majmin" ]]; then
    log "skip cgroup throttle cleanup on $osd_host: could not resolve $osd_device"
    return 0
  fi

  io_path="$(ssh_lab "$osd_host" "$(cgroup_io_max_path_command "$osd_service")" 2>/dev/null || true)"
  if [[ -z "$io_path" ]]; then
    log "skip cgroup throttle cleanup on $osd_host: could not resolve io.max for $osd_service"
    return 0
  fi

  if ssh_lab "$osd_host" "$(io_unthrottle_command "$majmin" "$io_path")" >/dev/null 2>&1; then
    log "cleared known cgroup throttle for $osd_service on $osd_host"
    return 0
  fi

  log "skip cgroup throttle cleanup on $osd_host: unthrottle command failed"
  return 0
}

delete_monitoring_stack >/dev/null 2>&1 || log "skip deleting monitoring namespace $LAB_NAMESPACE"
pool_delete_best_effort alert-slow-ops
pool_delete_best_effort alert-pg-availability
clear_known_cgroup_throttles
log "cleanup completed"
