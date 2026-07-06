#!/usr/bin/env bash
# E-10 (exp10): krbd queue_depth map option — 64 / 128 / 256 (H-011: krbd's
# nr_hw_queues = num_present_cpus(), so a single "queue_depth" number's
# host-side in-flight meaning needs the nr_requests + scheduler reading
# alongside it, not just the map option itself). Own image, host-mapped and
# passed straight through to the VM as virtio1.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/rbdimg.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"
# shellcheck disable=SC1091
. "$here/../lib/scenarios.sh"
require_inject_flag "$@"

ROUNDS="${SCEN_ROUNDS:-3}"
BASE="${DATA_SPEC:-ioperf:vm-1031-disk-1}"
IMG="ioperf-qd"
b="$(new_bundle exp10-qdepth)"
write_prediction "$b" "E-10: queue_depth 越高，高 qd fio pattern 吞吐略升，qd1 落噪音帶（H-011 機制推論）"

DEV=""
cleanup() {
  vm_set --virtio1 "$BASE" 2>/dev/null || true
  [ -n "$DEV" ] && img_unmap "$DEV" 2>/dev/null || true
  img_rm "$IMG" 2>/dev/null || true
}
trap cleanup EXIT

img_create "$IMG" 16G

for qd in 64 128 256; do
  vm_set --delete virtio1 2>/dev/null || true
  DEV="$(img_map "$IMG" "queue_depth=$qd")"
  [ -n "$DEV" ] || die "map 失敗（queue_depth=${qd}）"
  vm_set --virtio1 "$DEV"
  vm_cold_restart
  ip="$(vm_guest_ip)"
  guest_ssh "$ip" "sudo $(prefill_cmd /dev/vdb)" > "$b/qd$qd-prefill.json"
  devname="${DEV#/dev/}"
  pve_ssh "cat /sys/block/$devname/queue/nr_requests" > "$b/qd$qd-nr_requests.txt" 2>/dev/null || true
  pve_ssh "cat /sys/block/$devname/queue/scheduler" > "$b/qd$qd-scheduler.txt" 2>/dev/null || true
  run_matrix_rounds "$b" "qd$qd" "$ip" /dev/vdb "$ROUNDS"
  vm_set --delete virtio1
  img_unmap "$DEV"; DEV=""
done

vm_set --virtio1 "$BASE"
vm_cold_restart
printf '%s\n' "$b"
