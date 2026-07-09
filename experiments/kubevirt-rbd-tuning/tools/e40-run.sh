#!/bin/bash
# E-40 crash consistency：cache=none vs writeback，各 3 次 fio verify 寫入中 kill -9 qemu-kvm → 重啟 → verify_only 回讀。
# 用法：bash e40-run.sh <bundle>
set -u
BUNDLE=$1; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/log.txt"; }
cpx(){ ssh $SSHO $CP "$@"; }
gip(){ cpx "kubectl get vmi -n vmtest baseline -o jsonpath='{.status.interfaces[0].ipAddress}'"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$1 "$2"; }

set_cache(){ # none|writeback
  case $1 in
    none) cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/template/spec/domain/devices/disks/1/cache\"}]'" >/dev/null 2>&1 || true ;;
    writeback) cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/domain/devices/disks/1/cache\",\"value\":\"writeback\"}]'" >/dev/null ;;
  esac
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=delete --timeout=300s" >/dev/null 2>&1 || true; sleep 5
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null
}
wait_ssh(){ local ip=$1; for i in $(seq 1 18); do vmx $ip 'cloud-init status' 2>/dev/null | grep -q done && return 0; sleep 10; done; return 1; }

for CACHE in none writeback; do
  log "=== cache=$CACHE ==="
  for TRY in 1 2 3; do
    set_cache $CACHE
    IP=$(gip); wait_ssh $IP || { log "FATAL cloud-init $CACHE try$TRY"; exit 1; }
    # 生效驗證
    POD=$(cpx "kubectl get pod -n vmtest -l kubevirt.io/domain=baseline --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'")
    CM=$(cpx "kubectl exec -n vmtest $POD -c compute -- sh -c 'tr \"\\0\" \"\\n\" < /proc/\$(pgrep -x qemu-kvm|head -1)/cmdline'" | grep '/dev/data')
    echo "$CM" > "$BUNDLE/verify-$CACHE-$TRY.txt"
    # 寫入 verify 負載（背景），60s 後 kill -9 qemu
    vmx $IP 'sudo pkill fio 2>/dev/null; sudo rm -f /home/ubuntu/vw.*; nohup sudo fio --name=vw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=16 --verify=crc32c --verify_backlog=1024 --do_verify=0 --runtime=300 --time_based --output=/home/ubuntu/vw.json >/dev/null 2>&1 & sleep 1; pgrep -c fio'
    log "$CACHE try$TRY write-started ip=$IP"
    sleep 60
    NODE=$(cpx "kubectl get pod -n vmtest $POD -o jsonpath='{.spec.nodeName}'")
    NIP=$(cpx "kubectl get node $NODE -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'")
    log "$CACHE try$TRY KILL qemu on $NODE"
    ssh $SSHO azureuser@$NIP "sudo pkill -9 -f 'qemu-kvm.*baseline'" 2>/dev/null || cpx "kubectl delete pod -n vmtest $POD --grace-period=0 --force" >/dev/null 2>&1
    cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null 2>&1 || { log "restart wait timeout"; }
    IP2=$(gip); wait_ssh $IP2 || { log "WARN post-kill cloud-init $CACHE try$TRY"; }
    # verify-only 回讀
    R=$(vmx $IP2 'sudo fio --name=vr --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --verify=crc32c --verify_only --verify_backlog=1024 --do_verify=1 2>&1 | grep -iE "verify|error|bad" | head -5; echo "EXIT=$?"')
    echo "$R" > "$BUNDLE/verify-result-$CACHE-$TRY.txt"
    FS=$(vmx $IP2 'sudo dmesg 2>/dev/null | grep -iE "ext4|corrupt|error" | tail -3; mount | grep vdb || echo "vdb not mounted(raw)"')
    echo "$FS" >> "$BUNDLE/verify-result-$CACHE-$TRY.txt"
    log "$CACHE try$TRY verify done: $(echo "$R" | tr '\n' ' ' | head -c 120)"
  done
done
set_cache none
log "E-40 ALL-DONE"
