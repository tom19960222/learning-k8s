#!/usr/bin/env bash
# E-12 (exp12): krbd alloc_size map option — 4096 vs 65536. Same method as
# exp10 (own image, host-mapped, passed through as virtio1). Expect no
# measurable fio effect (expect=none) — alloc_size only changes
# minimum_io_size/discard-granularity reporting, not the actual IO path.
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
IMG="ioperf-alloc"
b="$(new_bundle exp12-allocsize)"
write_prediction "$b" "E-12: alloc_size 4096 vs 65536 對 fio 數字無感（expect none），差異只反映在 minimum_io_size（機制推論）"

DEV=""
cleanup() {
  vm_set --virtio1 "$BASE" 2>/dev/null || true
  [ -n "$DEV" ] && img_unmap "$DEV" 2>/dev/null || true
  img_rm "$IMG" 2>/dev/null || true
}
trap cleanup EXIT

img_create "$IMG" 16G

for alloc in 4096 65536; do
  vm_set --delete virtio1 2>/dev/null || true
  DEV="$(img_map "$IMG" "alloc_size=$alloc")"
  [ -n "$DEV" ] || die "map 失敗（alloc_size=${alloc}）"
  vm_set --virtio1 "$DEV"
  vm_cold_restart
  ip="$(vm_guest_ip)"
  guest_ssh "$ip" "sudo $(prefill_cmd /dev/vdb)" > "$b/alloc$alloc-prefill.json"
  devname="${DEV#/dev/}"
  pve_ssh "cat /sys/block/$devname/queue/minimum_io_size" > "$b/alloc$alloc-minimum_io_size.txt" 2>/dev/null || true
  run_matrix_rounds "$b" "alloc$alloc" "$ip" /dev/vdb "$ROUNDS"
  vm_set --delete virtio1
  img_unmap "$DEV"; DEV=""
done

vm_set --virtio1 "$BASE"
vm_cold_restart
printf '%s\n' "$b"
