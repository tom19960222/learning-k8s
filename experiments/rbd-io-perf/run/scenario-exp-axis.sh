#!/usr/bin/env bash
# E-04 (exp-axis): librbd (PVE default datapath, H-027) vs krbd (host-mapped
# raw device passed straight through as virtio1). This is the headline PVE-
# only experiment (KubeVirt+ceph-csi can't switch datapath on the same host).
# A = baseline DATA_SPEC (librbd); B = own image "ioperf-axis", krbd-mapped
# on the PVE host. Verify A via QEMU cmdline containing "rbd:" (librbd
# protocol string); verify B via qm config showing the /dev/rbd path — two
# different verify targets, so this doesn't fit run_qm_variant_scenario's
# single cmdline-only verify and is hand-rolled with ab_rounds directly.
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
IMG="ioperf-axis"
b="$(new_bundle exp-axis)"
write_prediction "$b" "E-04: librbd vs krbd 差異多落在高 qd（協定/cache 層機制不同，H-027/H-028），qd1 接近（機制推論）"

DEV=""
cleanup() {
  vm_set --virtio1 "$BASE" 2>/dev/null || true
  [ -n "$DEV" ] && img_unmap "$DEV" 2>/dev/null || true
  img_rm "$IMG" 2>/dev/null || true
}
trap cleanup EXIT

img_create "$IMG" 16G

_axis_setup_a() {
  vm_set --delete virtio1 2>/dev/null || true
  vm_set --virtio1 "$BASE"
  vm_cold_restart
  vm_assert_cmdline '"driver":"rbd"'
}
_axis_setup_b() {
  vm_set --delete virtio1 2>/dev/null || true
  if [ -z "$DEV" ]; then
    DEV="$(img_map "$IMG")"
    [ -n "$DEV" ] || die "krbd map 失敗"
  fi
  vm_set --virtio1 "$DEV"
  vm_cold_restart
  vm_assert_config '/dev/rbd'
  local ip
  ip="$(vm_guest_ip)"
  guest_ssh "$ip" "sudo $(prefill_cmd /dev/vdb)" > "$b/axis-b-prefill.json"
}
_axis_run_side() {
  # NOTE: deliberately not run_matrix_rounds here — its label always gets
  # its own internal "-r$r" suffix appended (n starts back at 1 every call),
  # so combining a round-numbered label ("A-r$rnd") with n=1 would nest into
  # "A-r$rnd-r1". Looping run_pattern_once directly keeps "A-r$rnd" as the
  # final directory name, matching run_qm_variant_scenario's own pattern.
  local side="$1" rnd="$2" ip entry
  ip="$(vm_guest_ip)"
  for entry in $FIO_PATTERNS; do
    if ! run_pattern_once "$b" "$side-r$rnd" "$ip" /dev/vdb "$entry"; then
      run_pattern_once "$b" "$side-r$rnd-retry" "$ip" /dev/vdb "$entry" ||
        die "連續 tainted（${entry}）"
    fi
  done
}
_axis_run_a() { _axis_run_side A "$1"; }
_axis_run_b() { _axis_run_side B "$1"; }

ab_rounds "$b" "$ROUNDS" _axis_setup_a _axis_setup_b _axis_run_a _axis_run_b

vm_set --virtio1 "$BASE"
vm_cold_restart
printf '%s\n' "$b"
