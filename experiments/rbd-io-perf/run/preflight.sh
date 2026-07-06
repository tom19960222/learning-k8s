#!/usr/bin/env bash
# E-00: read-only environment snapshot. stdout prints the snapshot path only.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"

b="$(new_bundle preflight)"
snap="$b/snapshot.txt"

section() { printf '=== %s ===\n' "$1" >> "$snap"; }

section "versions"
pve_ssh "pveversion -v | grep -E 'pve-manager|pve-qemu|^ceph:'; uname -r" >> "$snap"
section "ceph -s"
pve_ssh 'sudo -n ceph -s' >> "$snap"
section "ceph df"
pve_ssh 'sudo -n ceph df' >> "$snap"
section "osd tree"
pve_ssh 'sudo -n ceph osd tree' >> "$snap"
section "pool ioperf"
pve_ssh 'sudo -n ceph osd pool ls detail' | grep -A1 "'$POOL'" >> "$snap" || true
section "storage.cfg"
pve_ssh 'sudo -n cat /etc/pve/storage.cfg' >> "$snap"
section "mclock (read-only)"
pve_ssh 'sudo -n ceph config get osd osd_op_queue; sudo -n ceph config get osd osd_mclock_profile' >> "$snap"
section "mgmt nic speed"
pve_ssh 'sudo -n ethtool enp5s0 | grep Speed' >> "$snap" || true
section "memory"
pve_ssh 'free -g' >> "$snap"
section "fio"
pve_ssh 'which fio || echo fio-missing' >> "$snap"
section "vmid range"
pve_ssh 'sudo -n qm list' | awk '$1 >= 1031 && $1 <= 1039' >> "$snap" || true
if grep -qE '^\s*103[1-9]\s' "$snap"; then log "警示: VMID 1031-1039 範圍有既存 VM"; fi

printf '%s\n' "$snap"
