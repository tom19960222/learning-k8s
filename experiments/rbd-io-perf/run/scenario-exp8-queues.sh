#!/usr/bin/env bash
# E-08 (exp8): virtio-blk num-queues. H-026 confirmed the PVE/QEMU baseline
# already runs AUTO=vCPU-count queues (T1: qemu virtio-blk.c DEFINE_PROP_
# UINT16 num-queues default VIRTIO_BLK_AUTO_NUM_QUEUES; virtio-blk-pci.c
# resolves AUTO to vCPU count) — so this scenario is the reverse of the
# original catalog's framing: baseline = default (multi-queue, --delete args
# clears any leftover forced setting) vs variant = forced single queue via
# `qm set --args`. Verified on the guest via /sys/block/vdb/mq/ entry count,
# not QEMU cmdline (run_qm_variant_scenario's cmdline-only verify doesn't fit
# here), so this scenario is hand-rolled rather than using the shared engine.
#
# NOTE: the exact QEMU `-set device.virtio1.num-queues=1` --args syntax is
# runtime-verified in Phase 2 (H-026 Notes); a deviation there is a runtime
# adjustment to this wrapper, not a bug report.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"
# shellcheck disable=SC1091
. "$here/../lib/scenarios.sh"
require_inject_flag "$@"

ROUNDS="${SCEN_ROUNDS:-3}"
b="$(new_bundle exp8-queues)"
write_prediction "$b" "E-08: 強制 num-queues=1 於高 qd/高 numjobs 下吞吐下降（單佇列序列化競爭）；qd1 單工影響小（H-026 機制推論）"

_exp8_run_side() {
  local side="$1" rnd="$2" ip entry
  ip="$(vm_guest_ip)"
  guest_ssh "$ip" 'ls /sys/block/vdb/mq/ | wc -l' > "$b/$side-r$rnd-mq-count.txt" ||
    die "讀取 guest mq 數失敗"
  for entry in $FIO_PATTERNS; do
    if ! run_pattern_once "$b" "$side-r$rnd" "$ip" /dev/vdb "$entry"; then
      run_pattern_once "$b" "$side-r$rnd-retry" "$ip" /dev/vdb "$entry" ||
        die "連續 tainted（${entry}）"
    fi
  done
  local rd4="$b/$side-r$rnd-numjobs4"
  mkdir -p "$rd4"
  guest_ssh "$ip" "sudo $(fio_cmd_numjobs 'rr-4k-qd8:randread:4k:8' /dev/vdb 4)" \
    > "$rd4/rr-4k-qd8-numjobs4.json" || die "numjobs=4 fio 失敗"
}

_exp8_setup_a() { vm_set --delete args; vm_cold_restart; }
_exp8_setup_b() { vm_set --args "'-set device.virtio1.num-queues=1'"; vm_cold_restart; }
_exp8_run_a() { _exp8_run_side A "$1"; }
_exp8_run_b() { _exp8_run_side B "$1"; }

ab_rounds "$b" "$ROUNDS" _exp8_setup_a _exp8_setup_b _exp8_run_a _exp8_run_b
vm_set --delete args
printf '%s\n' "$b"
