#!/usr/bin/env bash
# Best-effort cleanup of everything the harness may have created.
# Safe to re-run; each step tolerates absence. Requires --yes-really-inject.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/rbdimg.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"
require_inject_flag "$@"

log "cleanup: destroy test VM $VMID"
( vm_destroy ) || true

log "cleanup: unmap + remove ioperf- images"
mapped="$(pve_ssh 'sudo -n rbd showmapped' 2>/dev/null || true)"
imgs="$(pve_ssh "sudo -n rbd ls $POOL" 2>/dev/null || true)"
for name in $imgs; do
  case "$name" in
    ioperf-*)
      # rbd showmapped 在預設 namespace 時該欄位印成空字串，awk 預設 FS 會
      # 把它整個吃掉、後面欄位往前擠——不能從左邊數 $4/$6。改由右邊數：
      # image 永遠是倒數第 3 欄、device 永遠是最後一欄，不管 namespace 欄
      # 是否存在都成立。
      dev="$(printf '%s\n' "$mapped" | awk -v img="$name" 'NR>1 && $(NF-2) == img {print $NF}')"
      [ -n "$dev" ] && { img_unmap "$dev" || true; }
      img_rm "$name" || true
      ;;
  esac
done

log "cleanup: remove test storage id ioperf-krbd"
pve_ssh 'sudo -n pvesm remove ioperf-krbd' 2>/dev/null || true
log "cleanup done"
