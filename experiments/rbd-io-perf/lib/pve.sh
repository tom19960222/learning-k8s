#!/usr/bin/env bash
# Test-VM lifecycle via qm. Only VMIDs 1031-1039 are allowed.
# Requires lib/common.sh and lib/collect.sh (qemu_pid).

_vmid_guard() {
  case "$VMID" in
    103[1-9]) : ;;
    *) die "VMID $VMID 不在允許範圍 1031-1039" ;;
  esac
}

# Upload a cloud-init user-data snippet that installs qemu-guest-agent
# (NOT in Ubuntu cloud images by default — without it vm_guest_ip can never
# work) plus fio/sysstat, and embeds the given public key.
vm_upload_snippet() {
  local pubkey_line="$1"
  pve_ssh "sudo -n tee $SNIPPET_PATH >/dev/null" <<EOF
#cloud-config
hostname: ioperf-test
users:
  - name: $GUEST_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $pubkey_line
package_update: true
packages:
  - qemu-guest-agent
  - fio
  - sysstat
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF
}

vm_create() {
  local img="$1"
  _vmid_guard
  pve_ssh "sudo -n qm create $VMID --name ioperf-test --cores 4 --memory 4096 \
--net0 virtio,bridge=vmbr1 --scsihw virtio-scsi-single --agent 1 --ostype l26"
  pve_ssh "sudo -n qm set $VMID --virtio0 $POOL:0,import-from=$img"
  pve_ssh "sudo -n qm disk resize $VMID virtio0 10G"
  pve_ssh "sudo -n qm set $VMID --ide2 $POOL:cloudinit --cicustom user=$SNIPPET_VOL \
--ipconfig0 ip=dhcp --boot order=virtio0"
}

vm_attach_data() {
  _vmid_guard
  pve_ssh "sudo -n qm set $VMID --virtio1 $1"
}

vm_set() {
  _vmid_guard
  pve_ssh "sudo -n qm set $VMID $*"
}

vm_cold_restart() {
  _vmid_guard
  pve_ssh "sudo -n qm stop $VMID" || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    pve_ssh "sudo -n qm status $VMID" | grep -q stopped && break
    [ "$i" -eq 12 ] && die "VM $VMID 停不下來"
    sleep 5
  done
  pve_ssh "sudo -n qm start $VMID"
  # timeout: qm agent ping blocks for minutes when no agent is listening;
  # bound each attempt so 30 attempts stay ~5 minutes total.
  for i in $(seq 1 30); do
    if pve_ssh "sudo -n timeout 10 qm agent $VMID ping >/dev/null 2>&1 && echo up" | grep -q up; then
      return 0
    fi
    sleep 5
  done
  die "VM $VMID 重啟後 guest agent 無回應"
}

vm_config() { _vmid_guard; pve_ssh "sudo -n qm config $VMID"; }

vm_assert_config() {
  vm_config | grep -qE "$1" || die "生效驗證失敗: qm config 缺 '$1'"
}

vm_cmdline() {
  _vmid_guard
  local pid
  pid="$(qemu_pid "$VMID")"
  pve_ssh "sudo -n tr '\\0' ' ' < /proc/$pid/cmdline"
}

vm_assert_cmdline() {
  vm_cmdline | grep -qE "$1" || die "生效驗證失敗: QEMU cmdline 缺 '$1'"
}

vm_guest_ip() {
  _vmid_guard
  pve_ssh "sudo -n timeout 10 qm agent $VMID network-get-interfaces" | python3 -c '
import json, sys
d = json.load(sys.stdin)
# PVE 9 qm prints the bare list; older wrappers use {"result": [...]}
itfs = d.get("result", []) if isinstance(d, dict) else d
for itf in itfs:
    for a in itf.get("ip-addresses", []):
        ip = a.get("ip-address", "")
        if a.get("ip-address-type") == "ipv4" and ip.startswith("192.168.18."):
            print(ip); raise SystemExit
raise SystemExit("no 192.168.18.x address")'
}

vm_destroy() {
  _vmid_guard
  pve_ssh "sudo -n qm stop $VMID" || true
  pve_ssh "sudo -n qm destroy $VMID --purge" || true
}
