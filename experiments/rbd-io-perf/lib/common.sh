#!/usr/bin/env bash
# Common helpers for the rbd-io-perf harness. bash 3.2 compatible.
# stdout is reserved for machine-readable output; logs go to stderr.

RBDPERF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$RBDPERF_ROOT/../.." && pwd)"
PVE_HOST="${PVE_HOST:-192.168.16.7}"
PVE_USER="${PVE_USER:-ioperf}"
SSH_KEY="${SSH_KEY:-$REPO_ROOT/.ssh/id_ed25519}"
RESULTS_DIR="${RESULTS_DIR:-$RBDPERF_ROOT/results}"
POOL="${POOL:-ioperf}"
VMID="${VMID:-1031}"
GUEST_USER="${GUEST_USER:-ubuntu}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

pve_ssh() {
  ssh -i "$SSH_KEY" \
      -o IdentitiesOnly=yes \
      -o IdentityAgent=none \
      -o ConnectTimeout=8 \
      -o StrictHostKeyChecking=accept-new \
      "$PVE_USER@$PVE_HOST" "$@"
}

guest_ssh() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY" \
      -o IdentitiesOnly=yes \
      -o IdentityAgent=none \
      -o ConnectTimeout=8 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "$GUEST_USER@$ip" "$@"
}

require_inject_flag() {
  local a
  for a in "$@"; do
    [ "$a" = "--yes-really-inject" ] && return 0
  done
  die "此腳本會變更遠端狀態，需要 --yes-really-inject"
}

new_bundle() {
  local d
  d="$RESULTS_DIR/$1/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$d" || die "cannot create bundle $d"
  printf '%s\n' "$d"
}
