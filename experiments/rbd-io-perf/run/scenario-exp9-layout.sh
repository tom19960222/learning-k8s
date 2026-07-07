#!/usr/bin/env bash
# E-09 (exp9): RBD object layout — object-size 4M vs 16M vs 4M/64K-stripe/
# 16-count fancy striping. Own images (ioperf- prefix), attached one at a
# time as the VM's virtio1 data disk via the existing "ioperf" PVE storage
# (librbd datapath — this is about image layout, not krbd vs librbd).
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
b="$(new_bundle exp9-layout)"
write_prediction "$b" "E-09: object-size/striping 對 sr-1m/sw-1m 大順序區塊有感，4k 隨機落噪音帶（機制推論；焦點 sr-1m/sw-1m）"

CUR_IMG=""
CUR_DEV=""
cleanup() {
  vm_set --virtio1 "$BASE" 2>/dev/null || true
  [ -n "$CUR_DEV" ] && img_unmap "$CUR_DEV" 2>/dev/null || true
  [ -n "$CUR_IMG" ] && img_rm "$CUR_IMG" 2>/dev/null || true
}
trap cleanup EXIT

# PVE storage 只認 vm-<id>-disk-N 命名，任意 image 名要走手動 map + raw path
# （E-09 首跑 "unable to parse rbd volume name" 的修正；同 exp10/12/14 手法）
run_layout() {
  local label="$1" img="$2"; shift 2
  CUR_IMG="$img"
  img_create "$img" 16G "$@"
  CUR_DEV="$(img_map "$img")"
  [ -n "$CUR_DEV" ] || die "map ${img} 失敗"
  vm_set --delete virtio1 2>/dev/null || true
  vm_attach_data "$CUR_DEV"
  vm_cold_restart
  local ip
  ip="$(vm_guest_ip)"
  guest_ssh "$ip" "sudo $(prefill_cmd /dev/vdb)" > "$b/$label-prefill.json"
  run_matrix_rounds "$b" "$label" "$ip" /dev/vdb "$ROUNDS"
  vm_set --delete virtio1
  img_unmap "$CUR_DEV"; CUR_DEV=""
  img_rm "$img"
  CUR_IMG=""
}

run_layout lay4m 'ioperf-lay4m' --object-size 4M
run_layout lay16m 'ioperf-lay16m' --object-size 16M
run_layout laystripe 'ioperf-laystripe' --object-size 4M --stripe-unit 64K --stripe-count 16

vm_set --virtio1 "$BASE"
vm_cold_restart
printf '%s\n' "$b"
