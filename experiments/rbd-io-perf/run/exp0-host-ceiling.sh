#!/usr/bin/env bash
# E-02: host-level ceiling on /dev/rbdX, libaio vs io_uring. VM not involved.
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
. "$here/../lib/scenarios.sh"
require_inject_flag "$@"

ROUNDS="${EXP0_ROUNDS:-3}"
IMG="ioperf-ceiling"
DEV=""
cleanup() {
  [ -n "$DEV" ] && img_unmap "$DEV" 2>/dev/null || true
  img_rm "$IMG" 2>/dev/null || true
}
trap cleanup EXIT

b="$(new_bundle exp0)"
write_prediction "$b" "E-02: 高 QD 下 libaio vs io_uring 差異落噪音帶內；qd1 io_uring 略優。此組數字為 ceph 側天花板。"

img_create "$IMG" 16G
DEV="$(img_map "$IMG")"
[ -n "$DEV" ] || die "map 失敗"
log "prefill $DEV"
pve_ssh "sudo -n $(prefill_cmd "$DEV")" > "$b/prefill.json"

for engine in libaio io_uring; do
  for r in $(seq 1 "$ROUNDS"); do
    rd="$b/$engine-r$r"; mkdir -p "$rd"
    collect_ceph_status "$rd/ceph-pre.txt"
    [ -s "$b/ceph-baseline.txt" ] || cp "$rd/ceph-pre.txt" "$b/ceph-baseline.txt"
    guard_check "$rd/ceph-pre.txt" "$b/ceph-baseline.txt"
    for entry in $FIO_PATTERNS; do
      name="${entry%%:*}"
      cmd="$(fio_cmd "$entry" "$DEV" | sed "s/--ioengine=libaio/--ioengine=$engine/")"
      pve_ssh "sudo -n $cmd" > "$rd/$name.json" || die "fio $name ($engine) 失敗"
    done
    collect_ceph_status "$rd/ceph-post.txt"
    guard_check "$rd/ceph-post.txt" "$b/ceph-baseline.txt"
    taint_check "$rd/ceph-post.txt" || log "警示: ${engine}-r${r} 輪有背景活動（host 天花板輪不重試，僅標記）"
  done
done

printf '%s\n' "$b"
