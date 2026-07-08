#!/bin/bash
# E-42 live migration 的 IO 代價 + E-50 可調性真機確認（合併）。
# 流程：dg 負載中 → patch cache=writethrough（不重啟）→ 斷言 RestartRequired →
#       migration ×3（量 IO 暫停窗）→ 每次後斷言 cmdline cache 仍 =none（H-001 T3）→ revert patch。
# 用法：bash e42-run.sh <bundle-dir> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
cpx(){ ssh $SSHO $CP "$@"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }

cmdline_cache(){
  POD=$(cpx "kubectl get pod -n vmtest -l kubevirt.io/domain=baseline --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'")
  cpx "kubectl exec -n vmtest $POD -c compute -- sh -c 'tr \"\\0\" \"\\n\" < /proc/\$(pgrep -x qemu-kvm | head -1)/cmdline'" | grep '"filename":"/dev/data"'
}

# 1) 負載
vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*'
vmx 'nohup sudo fio --name=dg-rw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=8 --numjobs=1 --time_based --runtime=1200 --output-format=json --output=/home/ubuntu/dg/dg-rw.json --write_lat_log=/home/ubuntu/dg/dg-rw --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; pgrep -c fio'
log "load-started"
sleep 30

# 2) E-50 前半：patch 不重啟 → RestartRequired
cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/domain/devices/disks/1/cache\",\"value\":\"writethrough\"}]'" >/dev/null
sleep 10
cpx "kubectl get vm -n vmtest baseline -o jsonpath='{.status.conditions}'" > "$BUNDLE/vm-conditions-after-patch.json"
grep -q RestartRequired "$BUNDLE/vm-conditions-after-patch.json" && log "E-50: RestartRequired condition PRESENT" || log "E-50: WARN RestartRequired NOT found"
cmdline_cache > "$BUNDLE/cmdline-before-mig.txt"

# 3) migration ×3
for M in 1 2 3; do
  log "mig-$M-create"
  NAME=$(cpx "cat <<EOF | kubectl create -f - -o jsonpath='{.metadata.name}'
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  generateName: e42-mig-
  namespace: vmtest
spec:
  vmiName: baseline
EOF")
  for i in $(seq 1 60); do
    PH=$(cpx "kubectl get vmim -n vmtest $NAME -o jsonpath='{.status.phase}'" 2>/dev/null)
    [ "$PH" = "Succeeded" ] || [ "$PH" = "Failed" ] && break
    sleep 5
  done
  log "mig-$M-phase=$PH"
  cmdline_cache > "$BUNDLE/cmdline-after-mig-$M.txt"
  grep -q '"direct":true' "$BUNDLE/cmdline-after-mig-$M.txt" && log "mig-$M H-001: cache STILL none (direct:true) ✓" || log "mig-$M H-001 VIOLATED: cache changed!"
  sleep 60
done

# 4) revert patch + 條件觀察
cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/template/spec/domain/devices/disks/1/cache\"}]'" >/dev/null
sleep 10
cpx "kubectl get vm -n vmtest baseline -o jsonpath='{.status.conditions}'" > "$BUNDLE/vm-conditions-after-revert.json"
grep -q RestartRequired "$BUNDLE/vm-conditions-after-revert.json" && log "E-50: RestartRequired persists after revert" || log "E-50: RestartRequired cleared after revert"

# 5) 收尾
vmx 'sudo pkill fio; true'; sleep 3
scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$BUNDLE/"
log "E-42 ALL-DONE"
