#!/usr/bin/env bash
# E-05 (exp1): cache=writethrough / writeback vs PVE baseline (cache=none;
# H-001 confirmed KubeVirt leaves it none when unset, PVE's default disk spec
# is likewise none). H-023: rewritten prediction — buffered (--direct=0) and
# buffered+fsync=1 jobs are separate diagnostics, not part of the A/B
# interleave, since fsync=1 can make writeback/writethrough converge.
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
BASE="${DATA_SPEC:-ioperf:vm-1031-disk-1}"

# PVE9 -blockdev JSON 的生效特徵（F4 first-contact 實測）：
#   writethrough → device token 帶 write-cache=off
#   writeback    → virtio1 的 rbd drive token 帶 "direct":false 且 device write-cache=on
verify_for() {
  case "$1" in
    writethrough) printf 'drive=drive-virtio1[^ ]*write-cache=off' ;;
    writeback)    printf '"direct":false[^ ]*vm-1031-disk-1.*drive=drive-virtio1[^ ]*write-cache=on' ;;
  esac
}
for cache in writethrough writeback; do
  run_qm_variant_scenario "exp1-cache-$cache" \
    "E-05: cache=$cache 相對 none 於 rr/rw 4k 差異落噪音帶內（無 host page cache 前提下機制推論；H-023）" \
    "$BASE" "$BASE,cache=$cache" "$(verify_for "$cache")" "$ROUNDS"
done

# 另兩條 buffered job（H-023）：--direct=0 與 --direct=0 --fsync=1，皆用
# rw-4k-qd1 pattern，在 cache=none 磁碟上跑（page cache 效應本身就是重點）。
b="$(new_bundle exp1-buffered)"
write_prediction "$b" "E-05: buffered write（--direct=0）繞過 O_DIRECT，數字受 guest page cache 影響僅供對照；加 --fsync=1 後應與 direct 結果趨近（H-023 機制推論）"
vm_set --virtio1 "$BASE,cache=none"
vm_cold_restart
ip="$(vm_guest_ip)"
for r in $(seq 1 "$ROUNDS"); do
  rd="$b/buffered-r$r"; mkdir -p "$rd"
  collect_ceph_status "$rd/ceph-pre.txt"
  [ -s "$b/ceph-baseline.txt" ] || cp "$rd/ceph-pre.txt" "$b/ceph-baseline.txt"
  guard_check "$rd/ceph-pre.txt" "$b/ceph-baseline.txt"
  cmd_nodirect="$(fio_cmd "rw-4k-qd1:randwrite:4k:1" /dev/vdb | sed 's/--direct=1/--direct=0/')"
  guest_ssh "$ip" "sudo $cmd_nodirect" > "$rd/nodirect.json" || die "buffered（無 fsync）fio 失敗"
  guest_ssh "$ip" "sudo $cmd_nodirect --fsync=1" > "$rd/nodirect-fsync.json" || die "buffered（fsync=1）fio 失敗"
  collect_ceph_status "$rd/ceph-post.txt"
  guard_check "$rd/ceph-post.txt" "$b/ceph-baseline.txt"
done
vm_set --virtio1 "$BASE"
vm_cold_restart
printf '%s\n' "$b"
