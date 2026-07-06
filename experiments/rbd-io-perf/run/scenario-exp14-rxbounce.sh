#!/usr/bin/env bash
# E-14 (exp14): krbd rxbounce map option off vs on (H-004: without rxbounce,
# high-concurrency guest reads can trigger krbd "bad crc" -> messenger
# reconnect -> p99 spikes; kernel 6.8.0-52 support already T1-confirmed).
# Same method as exp10. dmesg is watched throughout both sides for "bad crc"
# / "socket closed" signals.
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
IMG="ioperf-rxbounce"
b="$(new_bundle exp14-rxbounce)"
write_prediction "$b" "E-14: 若 rxbounce=off 側 dmesg 出現 bad crc/socket closed，rxbounce=on 側應消失且效能落噪音帶內；兩側皆無訊號時純屬環境未觸發（H-004 機制推論）"

DEV=""
cleanup() {
  vm_set --virtio1 "$BASE" 2>/dev/null || true
  [ -n "$DEV" ] && img_unmap "$DEV" 2>/dev/null || true
  img_rm "$IMG" 2>/dev/null || true
}
trap cleanup EXIT

img_create "$IMG" 16G

for mode in off on; do
  opts=""
  [ "$mode" = "on" ] && opts="rxbounce"
  vm_set --delete virtio1 2>/dev/null || true
  DEV="$(img_map "$IMG" "$opts")"
  [ -n "$DEV" ] || die "map 失敗（rxbounce=${mode}）"
  vm_set --virtio1 "$DEV"
  vm_cold_restart
  ip="$(vm_guest_ip)"
  guest_ssh "$ip" "sudo $(prefill_cmd /dev/vdb)" > "$b/rxbounce-$mode-prefill.json"
  marker="$(collect_dmesg_marker)"
  run_matrix_rounds "$b" "rxbounce-$mode" "$ip" /dev/vdb "$ROUNDS"
  collect_dmesg_delta "$marker" "$b/rxbounce-$mode-dmesg.txt"
  vm_set --delete virtio1
  img_unmap "$DEV"; DEV=""
done

vm_set --virtio1 "$BASE"
vm_cold_restart
printf '%s\n' "$b"
