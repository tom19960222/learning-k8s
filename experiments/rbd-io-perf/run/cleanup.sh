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
vm_destroy || true

log "cleanup: unmap + remove ioperf- images"
mapped="$(pve_ssh 'sudo -n rbd showmapped' 2>/dev/null || true)"
imgs="$(pve_ssh "sudo -n rbd ls $POOL" 2>/dev/null || true)"
for name in $imgs; do
  case "$name" in
    ioperf-*)
      dev="$(printf '%s\n' "$mapped" | awk -v img="$name" '$4 == img {print $6}')"
      [ -n "$dev" ] && { img_unmap "$dev" || true; }
      img_rm "$name" || true
      ;;
  esac
done

log "cleanup: remove test storage id ioperf-krbd"
pve_ssh 'sudo -n pvesm remove ioperf-krbd' 2>/dev/null || true
log "cleanup done"
