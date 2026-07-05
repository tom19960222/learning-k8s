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

NET_SLOW_HEARTBEAT_HOST="${NET_SLOW_HEARTBEAT_HOST:-ceph-lab-osd-03}"
NET_SLOW_HEARTBEAT_ARM_SLEEP="${NET_SLOW_HEARTBEAT_ARM_SLEEP:-900}"
_host_ip=""; _iface=""

scenario_setup() {
  _host_ip="$(lab_osd_host_ip "$NET_SLOW_HEARTBEAT_HOST")"
  _iface="$(ssh_lab "$_host_ip" "ip route get $LAB_MON_01_HOST | sed -n 's/.* dev \([^ ]*\).*/\1/p'" | tr -d '[:space:]')"
  [[ -n "$_iface" ]] || die "could not discover network interface on $_host_ip"
  printf '%s\n' "$_iface" >"$RESULT_DIR/target-iface.txt"
}

# Arm the auto-revert timer BEFORE applying the netem delay below: the qdisc
# we are about to add slows every packet leaving $_iface, including this
# script's own SSH traffic back to $_host_ip. If that makes SSH to the host
# unusable for the rest of the run (dropped session, control-plane hiccup),
# scenario_rollback would have no live channel left to undo the qdisc through
# -- so this pre-armed background sleeper is started first, on the HOST
# itself (a plain `nohup ... &` next to the systemd services, not inside
# `cephadm shell`), and deletes the qdisc unattended after
# NET_SLOW_HEARTBEAT_ARM_SLEEP seconds regardless of whether SSH ever comes
# back. Its stdout/stderr are redirected to /dev/null so this ssh_lab call
# returns as soon as the remote shell backgrounds it and echoes its PID,
# instead of blocking on an inherited pipe for the life of the sleeper.
#
# A non-empty PID only proves the remote fork succeeded, not that the sleeper
# is actually running -- sudo or the backgrounded `sh -c` can still fail right
# after `&`, and `$!` from that shell is echoed regardless. Because this timer
# is the only safety net once the netem delay makes SSH unreliable, arming it
# silently and moving on would leave the destructive qdisc applied with no
# way to auto-revert. So immediately after recording the PID we confirm it is
# alive with `sudo kill -0 <pid>` over the same SSH path and `die` -- before
# any qdisc is ever added -- if that confirmation fails.
arm_auto_revert() {
  local pid
  pid="$(ssh_lab "$_host_ip" "sudo nohup sh -c 'sleep $NET_SLOW_HEARTBEAT_ARM_SLEEP; tc qdisc del dev $_iface root' >/dev/null 2>&1 & echo \$!")"
  pid="$(printf '%s' "$pid" | tr -d '[:space:]')"
  [[ -n "$pid" ]] || die "failed to arm auto-revert sleeper on $_host_ip"
  printf '%s\n' "$pid" >"$RESULT_DIR/armed-revert.pid"
  run_capture "$RESULT_DIR/armed-revert-liveness.txt" ssh_lab "$_host_ip" "sudo kill -0 $pid" \
    || die "auto-revert sleeper pid $pid on $_host_ip failed liveness check -- refusing to apply netem delay with no confirmed safety net"
}

scenario_inject() {
  arm_auto_revert
  run_capture "$RESULT_DIR/tc-qdisc-add.txt" ssh_lab "$_host_ip" "sudo tc qdisc add dev $_iface root netem delay 1200ms"
}

scenario_verify() {
  wait_ceph_health_check OSD_SLOW_PING_TIME "$RESULT_DIR"
  wait_prometheus_alert CephOSDSlowHeartbeat "" "" "$RESULT_DIR"
  wait_sink_alert pager CephOSDSlowHeartbeat "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

# netem_removed_from_iface polls a FRESH ssh session (captured to
# $RESULT_DIR as evidence) for whether the netem qdisc is still present on
# $_iface. Used by scenario_rollback below instead of trusting the tc-del
# command's own ssh exit code -- see the comment there for why.
netem_removed_from_iface() {
  local output_file="$RESULT_DIR/rollback-verify-tc-qdisc-show.txt"
  ssh_lab "$_host_ip" "tc qdisc show dev $_iface" >"$output_file" 2>&1 || return 1
  ! grep -q netem "$output_file"
}

scenario_rollback() {
  local rc=0
  # `tc qdisc del` rides over the very ssh session whose transport runs
  # through $_iface. Deleting the netem delay mid-command can self-disrupt
  # that ssh session and make it exit non-zero (e.g. 255) EVEN THOUGH the
  # remote `tc qdisc del` (guarded by `|| true`) already succeeded --
  # so this command's own ssh exit code is not trustworthy and must NOT
  # gate rc. The verification poll below, over a fresh ssh session started
  # after the delay is gone, is what actually decides rollback success.
  run_capture "$RESULT_DIR/rollback-tc-qdisc-del.txt" ssh_lab "$_host_ip" "sudo tc qdisc del dev $_iface root || true" || true
  # A pkill that finds no matching process (armed sleeper already fired, or
  # never needed) exits 1 even though nothing is wrong; don't gate rc on it.
  run_capture "$RESULT_DIR/rollback-kill-armed-sleeper.txt" ssh_lab "$_host_ip" "sudo pkill -f 'sleep $NET_SLOW_HEARTBEAT_ARM_SLEEP' || true" || true
  poll_until "netem qdisc removed from $_iface on $_host_ip" \
    "${NET_SLOW_HEARTBEAT_ROLLBACK_ATTEMPTS:-6}" "${NET_SLOW_HEARTBEAT_ROLLBACK_SLEEP:-5}" \
    netem_removed_from_iface \
    || rc=1
  return "$rc"
}

scenario_main net-slow-heartbeat "$@"
