#!/usr/bin/env bash
# E-01: three-gate krbd feasibility check. Own resources only.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/rbdimg.sh"
require_inject_flag "$@"

CHK_IMG="ioperf-krbdchk"
DEV=""
cleanup() {
  [ -n "$DEV" ] && img_unmap "$DEV" 2>/dev/null || true
  img_rm "$CHK_IMG" 2>/dev/null || true
  pve_ssh 'sudo -n pvesm remove ioperf-krbd' 2>/dev/null || true
}
trap cleanup EXIT

log "關卡 1: map + direct 讀寫"
img_create "$CHK_IMG" 1G
if ! DEV="$(img_map "$CHK_IMG")" || [ -z "$DEV" ]; then
  echo "krbd: unusable (map)"; exit 1
fi
if ! pve_ssh "sudo -n dd if=/dev/zero of=$DEV bs=4k count=16 oflag=direct 2>/dev/null && sudo -n dd if=$DEV of=/dev/null bs=4k count=16 iflag=direct 2>/dev/null"; then
  echo "krbd: unusable (io)"; exit 1
fi

log "關卡 2: 記錄 image features"
img_info "$CHK_IMG" | grep -i features >&2 || true

img_unmap "$DEV"; DEV=""
img_rm "$CHK_IMG"

log "關卡 3: krbd=1 storage 定義"
if ! pve_ssh "sudo -n pvesm add rbd ioperf-krbd --pool $POOL --content images --krbd 1"; then
  echo "krbd: unusable (storage)"; exit 1
fi
pve_ssh 'sudo -n pvesm status' | grep -q ioperf-krbd || { echo "krbd: unusable (storage)"; exit 1; }
pve_ssh 'sudo -n pvesm remove ioperf-krbd'

echo "krbd: usable"
