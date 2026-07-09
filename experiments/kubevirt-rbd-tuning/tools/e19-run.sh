#!/bin/bash
# E-19 krbd queue_depth（D類）：qd64 vs qd256（vs baseline 128=E-01）。每變體新 SC+PVC，換 data disk。
# 用法：bash e19-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174
FSID=ab33c12c-7a5c-11f1-913a-894a658522d3
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/log.txt"; }
cpx(){ ssh $SSHO $CP "$@"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$1 "$2"; }
gip(){ cpx "kubectl get vmi -n vmtest baseline -o jsonpath='{.status.interfaces[0].ipAddress}'"; }

matrix(){ # $1=ip $2=outdir
  vmx $1 'cat > /home/ubuntu/rm.sh <<"RMEOF"
OUT=$1; mkdir -p $OUT
DEV=/dev/$(lsblk -bdno NAME,SIZE | awk "\$2==17179869184{print \$1; exit}")
run(){ sudo fio --name=$1 --filename=$DEV --direct=1 --ioengine=libaio --rw=$2 --bs=$3 --iodepth=$4 --numjobs=$5 --time_based --runtime=60 --ramp_time=15 --randseed=8675309 --group_reporting --output-format=json --output=$OUT/fio-$1.json >/dev/null; }
run rr-qd1 randread 4k 1 1; run rr-qd32x4 randread 4k 32 4; run rw-qd1 randwrite 4k 1 1; run rw-qd32x4 randwrite 4k 32 4
RMEOF
rm -rf /home/ubuntu/m && bash /home/ubuntu/rm.sh /home/ubuntu/m'
  mkdir -p "$2"; scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$1]:/home/ubuntu/m/*" "$2/"
}

for QD in 64 256; do
  log "=== queue_depth=$QD ==="
  cpx "cat <<YAML | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: ceph-rbd-qd$QD}
provisioner: rbd.csi.ceph.com
parameters:
  clusterID: $FSID
  pool: kubevirt
  imageFeatures: layering
  mapOptions: \"krbd:queue_depth=$QD\"
  csi.storage.k8s.io/fstype: ext4
  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ceph-csi-rbd
  csi.storage.k8s.io/node-stage-secret-name: csi-rbd-secret
  csi.storage.k8s.io/node-stage-secret-namespace: ceph-csi-rbd
  csi.storage.k8s.io/controller-expand-secret-name: csi-rbd-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: ceph-csi-rbd
reclaimPolicy: Delete
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data-qd$QD, namespace: vmtest}
spec: {accessModes: [ReadWriteMany], volumeMode: Block, storageClassName: ceph-rbd-qd$QD, resources: {requests: {storage: 16Gi}}}
YAML" >/dev/null 2>&1
  cpx "kubectl wait -n vmtest pvc/data-qd$QD --for=jsonpath='{.status.phase}'=Bound --timeout=120s" >/dev/null 2>&1
  # 換 data disk 指向新 PVC（disks[1] volume）
  cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/1/persistentVolumeClaim/claimName\",\"value\":\"data-qd$QD\"}]'" >/dev/null
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=delete --timeout=300s" >/dev/null 2>&1 || true; sleep 5
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null
  IP=$(gip); for i in $(seq 1 18); do vmx $IP 'cloud-init status' 2>/dev/null|grep -q done && break; sleep 10; done
  # 生效驗證：host config_info 含 queue_depth=N
  POD=$(cpx "kubectl get pod -n vmtest -l kubevirt.io/domain=baseline --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'")
  NODE=$(cpx "kubectl get pod -n vmtest $POD -o jsonpath='{.spec.nodeName}'"); NIP=$(cpx "kubectl get node $NODE -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'")
  ssh $SSHO azureuser@$NIP 'for d in /sys/bus/rbd/devices/*; do n=${d##*/}; [ "$(cat /sys/block/rbd$n/size)" = "33554432" ] && echo "nr_requests=$(cat /sys/block/rbd$n/queue/nr_requests) $(cat $d/config_info)"; done' > "$BUNDLE/verify-qd$QD.txt"
  log "qd$QD verify: $(cat $BUNDLE/verify-qd$QD.txt | head -c 120)"
  vmx $IP 'sudo fio --name=pf --filename=/dev/$(lsblk -bdno NAME,SIZE|awk "\$2==17179869184{print \$1;exit}") --rw=write --bs=1M --iodepth=8 --direct=1 --size=100% >/dev/null 2>&1; echo prefilled'
  for R in 1 2 3; do matrix $IP "$BUNDLE/qd$QD/round-$R"; log "qd$QD round $R done"; done
  # placement 記錄
  ssh $SSHO $MON 'sudo ceph osd map kubevirt csi-vol-probe 2>/dev/null || true' >> "$BUNDLE/placement.txt" 2>&1
done
# cleanup：換回 baseline PVC、刪變體 SC/PVC
cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/1/persistentVolumeClaim/claimName\",\"value\":\"data-baseline\"}]'" >/dev/null
cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'" >/dev/null
cpx "kubectl wait -n vmtest vmi/baseline --for=delete --timeout=300s" >/dev/null 2>&1 || true; sleep 5
cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'" >/dev/null
cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null
for QD in 64 256; do cpx "kubectl delete pvc -n vmtest data-qd$QD --wait=false; kubectl delete sc ceph-rbd-qd$QD" >/dev/null 2>&1; done
log "E-19 ALL-DONE"
