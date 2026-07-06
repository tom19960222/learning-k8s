#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"

# VMID guard
if ( VMID=103 vm_destroy ) 2>/dev/null; then echo "vmid guard missing"; exit 1; fi

cp "$here/fixtures/qm-config-baseline.txt" "$FAKE_SSH_DIR/qm config 1031"
vm_assert_config 'scsihw: virtio-scsi-single' || { echo "assert_config false negative"; exit 1; }
if ( vm_assert_config 'aio=native' ) 2>/dev/null; then echo "assert_config false positive"; exit 1; fi

cp "$here/fixtures/qm-agent-ip.json" "$FAKE_SSH_DIR/network-get-interfaces"
ip="$(vm_guest_ip)"
[ "$ip" = "192.168.18.77" ] || { echo "guest ip=$ip"; exit 1; }

vm_set --virtio1 'ioperf:vm-1031-disk-1,aio=native,cache=none'
grep -q "qm set 1031 --virtio1 ioperf:vm-1031-disk-1,aio=native,cache=none" "$FAKE_SSH_LOG" || { echo "vm_set cmd wrong"; exit 1; }

printf '9999\n' > "$FAKE_SSH_DIR/1031.pid"
printf 'x\0y\0z\0' | tr '\0' ' ' > "$FAKE_SSH_DIR/proc"
c="$(vm_cmdline)"
echo "$c" | grep -q 'x y z' || { echo "cmdline=$c"; exit 1; }

# vm_create, vm_attach_data, vm_cold_restart smoke tests
# Set up fixtures for vm_cold_restart wait loops
printf 'stopped\n' > "$FAKE_SSH_DIR/qm status 1031"
printf 'up\n' > "$FAKE_SSH_DIR/qm agent 1031 ping"

# Set environment for VM functions
export VMID=1031 POOL="ioperf" GUEST_USER="root"

# vm_create smoke test: check command structure
vm_create /mnt/img.raw /home/ioperf/k.pub
grep -q 'qm create 1031' "$FAKE_SSH_LOG" || { echo "vm_create missing 'qm create 1031'"; cat "$FAKE_SSH_LOG"; exit 1; }
grep -q 'import-from=/mnt/img.raw' "$FAKE_SSH_LOG" || { echo "vm_create missing 'import-from=/mnt/img.raw'"; cat "$FAKE_SSH_LOG"; exit 1; }
grep -q -- '--ide2 ioperf:cloudinit' "$FAKE_SSH_LOG" || { echo "vm_create missing '--ide2 ioperf:cloudinit'"; cat "$FAKE_SSH_LOG"; exit 1; }

# vm_attach_data smoke test
: > "$FAKE_SSH_LOG"  # Clear log for cleaner assertions
vm_attach_data 'ioperf:16'
grep -q 'qm set 1031 --virtio1 ioperf:16' "$FAKE_SSH_LOG" || { echo "vm_attach_data cmd wrong"; cat "$FAKE_SSH_LOG"; exit 1; }

# vm_cold_restart smoke test: check return code and commands
: > "$FAKE_SSH_LOG"  # Clear log
vm_cold_restart || { echo "vm_cold_restart failed"; exit 1; }
grep -q 'qm stop 1031' "$FAKE_SSH_LOG" || { echo "vm_cold_restart missing 'qm stop 1031'"; cat "$FAKE_SSH_LOG"; exit 1; }
grep -q 'qm start 1031' "$FAKE_SSH_LOG" || { echo "vm_cold_restart missing 'qm start 1031'"; cat "$FAKE_SSH_LOG"; exit 1; }

echo OK
