#!/bin/bash
# E-51 mapOptions 可調性：改 SC（預期無效）vs kubectl patch PV volumeAttributes（escape hatch）。
# 用法：bash e51-run.sh <bundle> <PV名>
set -u
BUNDLE=$1; PV=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/log.txt"; }
cpx(){ ssh $SSHO $CP "$@"; }
# 讀 data-baseline(16GiB) image 在 VM 所在 node 的 host nr_requests
read_nr(){
  POD=$(cpx "kubectl get pod -n vmtest -l kubevirt.io/domain=baseline --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'")
  NODE=$(cpx "kubectl get pod -n vmtest $POD -o jsonpath='{.spec.nodeName}'")
  NIP=$(cpx "kubectl get node $NODE -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'")
  # 16GiB image = csi-vol-...65ccddc0；用 size 對映 rbd 裝置
  ssh $SSHO azureuser@$NIP 'for d in /sys/bus/rbd/devices/*; do n=${d##*/}; sz=$(cat /sys/block/rbd$n/size 2>/dev/null); if [ "$sz" = "33554432" ]; then echo "rbd$n nr_requests=$(cat /sys/block/rbd$n/queue/nr_requests) config=$(cat $d/config_info|tr "\n" " ")"; fi; done'
}
restart_vm(){
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=delete --timeout=300s" >/dev/null 2>&1 || true; sleep 5
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null
}

log "=== baseline ==="; read_nr | tee "$BUNDLE/step0-baseline.txt"

log "=== step1: 改 SC mapOptions=queue_depth=256（預期對存量 PV 無效）==="
cpx "kubectl patch sc ceph-rbd --type=merge -p '{\"parameters\":{\"mapOptions\":\"krbd:queue_depth=256\"}}'" 2>&1 | tee -a "$BUNDLE/log.txt"
restart_vm
read_nr | tee "$BUNDLE/step1-after-sc.txt"

log "=== step2: patch PV volumeAttributes mapOptions（escape hatch？）==="
cpx "kubectl patch pv $PV --type=merge -p '{\"spec\":{\"csi\":{\"volumeAttributes\":{\"mapOptions\":\"krbd:queue_depth=256\"}}}}'" 2>&1 | tee "$BUNDLE/step2-patch-result.txt"
restart_vm
read_nr | tee "$BUNDLE/step2-after-pv.txt"

log "=== cleanup：還原 SC + PV ==="
cpx "kubectl patch sc ceph-rbd --type=json -p '[{\"op\":\"remove\",\"path\":\"/parameters/mapOptions\"}]'" 2>&1 | tee -a "$BUNDLE/log.txt"
cpx "kubectl patch pv $PV --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/csi/volumeAttributes/mapOptions\"}]'" 2>&1 | tee -a "$BUNDLE/log.txt" || true
restart_vm
read_nr | tee "$BUNDLE/step3-cleanup.txt"
log "E-51 ALL-DONE"
