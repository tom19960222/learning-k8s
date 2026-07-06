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
echo OK
