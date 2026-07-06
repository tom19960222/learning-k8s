#!/usr/bin/env bash
# E-15 (exp15): librbd conf_rbd_cache axis (H-028: QEMU's cache= mode maps
# directly to librbd's rbd_cache setting on this datapath) on the *baseline
# data volume*.
#
# STUB — NOT IMPLEMENTED. img_meta_set/img_meta_get (lib/rbdimg.sh) refuse
# any image name that doesn't start with "ioperf-" as an own-resource safety
# guard (_img_guard). The baseline data disk is a PVE-managed volume named
# vm-1031-disk-N (N assigned at creation time by baseline.sh), which that
# guard correctly rejects — this harness must never touch an image it can't
# prove it owns by name via automation. Running this scenario against the
# real baseline volume requires a manual, human-supervised step in Phase 2:
#
#   1. Find the real volume name:
#        ssh ... "sudo -n qm config 1031 | grep virtio1"
#      (e.g. "ioperf:vm-1031-disk-2,...")
#   2. For each value in false true:
#        ssh ... "sudo -n rbd image-meta set ioperf/vm-1031-disk-2 conf_rbd_cache <value>"
#        ssh ... "sudo -n qm stop 1031 && sudo -n qm start 1031"
#        (wait for guest agent, then run the fio matrix the same way the
#        other scenarios do via run_matrix_rounds)
#   3. Verify the effect took:
#        ssh ... "sudo -n rbd image-meta get ioperf/vm-1031-disk-2 conf_rbd_cache"
#
# This script only validates the invocation gate; it intentionally exits 2
# (distinct from exit 1 = real failure) so an automated chain (run/all.sh)
# can tell "known stub" apart from "something broke". run/all.sh tolerates
# exit 2 from this step specifically.
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

log "E-15 需要 per-volume image-meta 於 PVE volume 命名（vm-1031-disk-N），與 ioperf- 前綴防呆衝突——Phase 2 以人工步驟執行（附指令，見本檔開頭註解）"
exit 2
