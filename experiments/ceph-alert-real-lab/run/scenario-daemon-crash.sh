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

# Real-lab findings (verified against the cephadm v19.2.3 lab cluster):
#
# 1. ceph-osd is NOT PID 1 inside its container, and systemd's MainPID for the
#    unit is `conmon` (the container monitor), not ceph-osd. `kill`ing either
#    of those (the old approach) just cleanly restarts the container -- no
#    crash is ever produced. The container's PID-1 is `podman-init`, a shim
#    that also does not forward SIGSEGV/SIGABRT to its children, so signaling
#    it via `podman kill` would not work either. The real ceph-osd process is
#    a host-visible child of podman-init; reach it via
#    `podman inspect --format '{{.State.Pid}}'` (-> podman-init's host PID)
#    then `pgrep -P <that pid> ceph-osd`. Killing THAT PID genuinely crashes
#    ceph-osd (verified: container restarts, a real crash meta is written).
# 2. This lab's `ceph-crash` sidecar is broken cluster-wide -- there is no
#    `client.crash` auth entry, so every poll fails with a RADOS permission
#    error and crashes are never posted automatically. Even a healthy sidecar
#    only polls the crash spool every 600s. Either way, RECENT_CRASH would
#    never appear on its own within this scenario's verify window.
#
# So this scenario reads the real crash metadata straight off the OSD host's
# crash spool after the SEGV and posts it itself via the seed node's admin
# `cephadm shell`. This substitutes only the broken transport, not the fault:
# ceph-osd is genuinely SIGSEGV'd; the meta being posted is the crash it
# actually produced.

DAEMON_CRASH_HOST="${DAEMON_CRASH_HOST:-ceph-lab-osd-01}"
DAEMON_CRASH_OSD_ID="${DAEMON_CRASH_OSD_ID:-}"
CRASH_SPOOL_DIR="/var/lib/ceph/${LAB_FSID}/crash"
_host_ip=""; _service=""; _ctr=""; _osd_pid=""; _crash_id=""

scenario_setup() {
  _host_ip="$(lab_osd_host_ip "$DAEMON_CRASH_HOST")"
  if [[ -z "$DAEMON_CRASH_OSD_ID" ]]; then
    DAEMON_CRASH_OSD_ID="$(ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd ls-tree $DAEMON_CRASH_HOST" | head -1 | tr -d '[:space:]')"
  fi
  [[ -n "$DAEMON_CRASH_OSD_ID" ]] || die "no OSD found on $DAEMON_CRASH_HOST"
  _service="$(osd_service_name "$LAB_FSID" "$DAEMON_CRASH_OSD_ID")"
  _ctr="ceph-${LAB_FSID}-osd-${DAEMON_CRASH_OSD_ID}"
  printf '%s\n' "$_ctr" >"$RESULT_DIR/target-osd-container.txt"
  # Snapshot the crash spool BEFORE injection so the post-SEGV poll can tell
  # a freshly-created crash dir apart from any pre-existing (historical)
  # ones -- diffing against this file is what identifies the new crash id.
  ssh_lab "$_host_ip" "sudo -n ls -1 $CRASH_SPOOL_DIR/ 2>/dev/null" >"$RESULT_DIR/crash-spool-before.txt" || true
}

crash_dir_seen() {
  local after_file="$RESULT_DIR/crash-spool-after.txt" new_id
  ssh_lab "$_host_ip" "sudo -n ls -1 $CRASH_SPOOL_DIR/ 2>/dev/null" >"$after_file" || true
  new_id="$(grep -Fvxf "$RESULT_DIR/crash-spool-before.txt" "$after_file" | head -1)"
  [[ -n "$new_id" ]] || return 1
  _crash_id="$new_id"
  printf '%s\n' "$new_id" >"$RESULT_DIR/crash-id.txt"
  return 0
}

scenario_inject() {
  local init_pid b64

  init_pid="$(ssh_lab "$_host_ip" "sudo -n podman inspect --format '{{.State.Pid}}' $_ctr" | tr -d '[:space:]')"
  [[ -n "$init_pid" && "$init_pid" != "0" ]] || die "could not resolve podman-init host PID for $_ctr on $_host_ip"

  _osd_pid="$(ssh_lab "$_host_ip" "sudo -n pgrep -P $init_pid ceph-osd" | head -1 | tr -d '[:space:]')"
  [[ -n "$_osd_pid" && "$_osd_pid" != "0" ]] || die "could not resolve ceph-osd PID under podman-init $init_pid for $_ctr"
  printf '%s\n' "$_osd_pid" >"$RESULT_DIR/target-osd-pid.txt"

  run_capture "$RESULT_DIR/kill-segv.txt" ssh_lab "$_host_ip" "sudo -n kill -SEGV $_osd_pid"

  poll_until "new crash dir under $CRASH_SPOOL_DIR after SEGV" "${DAEMON_CRASH_SPOOL_ATTEMPTS:-24}" "${DAEMON_CRASH_SPOOL_SLEEP:-5}" crash_dir_seen \
    || die "no new crash dir appeared under $CRASH_SPOOL_DIR after SEGV"

  # ceph-crash cannot post on this lab (see comment above), so post the real
  # crash meta ourselves via the seed node's admin shell. ssh_base_opts uses
  # `ssh -n`, so nothing can be piped in over local stdin -- read the meta,
  # base64-encode it, and decode+post it in a single remote command on each
  # side instead.
  b64="$(ssh_lab "$_host_ip" "sudo -n base64 -w0 $CRASH_SPOOL_DIR/${_crash_id}/meta")"
  [[ -n "$b64" ]] || die "empty crash meta read from $CRASH_SPOOL_DIR/${_crash_id}/meta"
  run_capture "$RESULT_DIR/crash-post.txt" ssh_lab "$LAB_MON_01_HOST" "echo $b64 | base64 -d | sudo -n cephadm shell -- ceph crash post -i -"
}

scenario_verify() {
  wait_ceph_health_check RECENT_CRASH "$RESULT_DIR"
  wait_prometheus_alert CephDaemonRecentCrash "" "" "$RESULT_DIR"
  # RECENT_CRASH is warning severity (not critical), so it must route to
  # slack only -- pin the evidence that it never leaks to the pager receiver.
  wait_sink_alert slack CephDaemonRecentCrash "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
  assert_sink_absent pager CephDaemonRecentCrash "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

osd_service_is_active() {
  ssh_lab "$_host_ip" "systemctl is-active $_service" | grep -qx active
}

scenario_rollback() {
  local rc=0
  # Archive only the crash we injected+posted -- archive-all would also
  # silently clear any pre-existing (historical) crashes on the cluster.
  if [[ -n "$_crash_id" ]]; then
    run_capture "$RESULT_DIR/rollback-crash-archive.txt" ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph crash archive $_crash_id" || rc=1
  fi
  # A SIGSEGV crash is caught by systemd's on-failure restart policy on ceph
  # OSD units, so the service is usually already active again by the time we
  # get here; poll for that first and only fall back to an explicit start if
  # systemd never brought it back on its own.
  if ! poll_until "osd $_service active again after SEGV" "${DAEMON_CRASH_RESTART_ATTEMPTS:-12}" "${DAEMON_CRASH_RESTART_SLEEP:-5}" osd_service_is_active; then
    run_capture "$RESULT_DIR/rollback-start-osd.txt" ssh_lab "$_host_ip" "sudo systemctl start $_service" || rc=1
  fi
  return "$rc"
}

scenario_main daemon-crash "$@"
