#!/bin/bash
# E-15 CPU limit throttle（H-018）：Guaranteed(req=lim) vs throttled(lim<vCPU)。guest CPU 壓力+fio，量 p99.9。
# 用法：bash e15-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/log.txt"; }
cpx(){ ssh $SSHO $CP "$@"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$1 "$2"; }
gip(){ cpx "kubectl get vmi -n vmtest baseline -o jsonpath='{.status.interfaces[0].ipAddress}'"; }

set_res(){ # $1=guaranteed|throttled
  if [ "$1" = guaranteed ]; then R='{"requests":{"cpu":"4","memory":"8Gi"},"limits":{"cpu":"4","memory":"8Gi"}}'
  else R='{"requests":{"cpu":"2","memory":"8Gi"},"limits":{"cpu":"2","memory":"8Gi"}}'; fi
  cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/domain/resources\",\"value\":$R}]'" >/dev/null 2>&1 || \
  cpx "kubectl patch vm -n vmtest baseline --type=replace --patch-file=/dev/stdin <<< '{}'" >/dev/null 2>&1 || \
  cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/domain/resources\",\"value\":$R}]'" >/dev/null
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=delete --timeout=300s" >/dev/null 2>&1 || true; sleep 5
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null
}

for V in guaranteed throttled; do
  log "=== $V ==="
  set_res $V
  IP=$(gip); for i in $(seq 1 18); do vmx $IP 'cloud-init status' 2>/dev/null|grep -q done && break; sleep 10; done
  vmx $IP 'which stress-ng || sudo apt-get -qq install -y stress-ng >/dev/null 2>&1; which stress-ng'
  # 生效驗證：virt-launcher pod QoS
  POD=$(cpx "kubectl get pod -n vmtest -l kubevirt.io/domain=baseline --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'")
  cpx "kubectl get pod -n vmtest $POD -o jsonpath='{.status.qosClass} cpu-lim={.spec.containers[?(@.name==\"compute\")].resources.limits.cpu}'; echo" > "$BUNDLE/verify-$V.txt"
  log "$V $(cat $BUNDLE/verify-$V.txt)"
  # guest CPU 壓力 + fio rr-qd8
  vmx $IP 'nohup sudo stress-ng --cpu 4 --timeout 200s >/dev/null 2>&1 & sleep 2; echo stress-started'
  vmx $IP 'DEV=/dev/$(lsblk -bdno NAME,SIZE|awk "\$2==17179869184{print \$1;exit}"); sudo fio --name=t --filename=$DEV --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=8 --numjobs=1 --time_based --runtime=120 --ramp_time=10 --output-format=json --output=/home/ubuntu/e15.json >/dev/null 2>&1; echo fio-done'
  scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" "ubuntu@[$IP]:/home/ubuntu/e15.json" "$BUNDLE/e15-$V.json"
  # worker cgroup throttle 佐證
  NODE=$(cpx "kubectl get pod -n vmtest $POD -o jsonpath='{.spec.nodeName}'"); NIP=$(cpx "kubectl get node $NODE -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'")
  ssh $SSHO azureuser@$NIP "sudo find /sys/fs/cgroup -name cpu.stat -path '*kubepods*' 2>/dev/null | xargs grep -l nr_throttled 2>/dev/null | head -1 | xargs cat 2>/dev/null | grep -E 'nr_throttled|throttled_usec'" > "$BUNDLE/throttle-$V.txt" 2>&1
  vmx $IP 'sudo pkill stress-ng; true'
  log "$V done: $(cat $BUNDLE/throttle-$V.txt | tr '\n' ' ')"
done
# cleanup：移除 resources 限制
cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/template/spec/domain/resources\"}]'" >/dev/null 2>&1 || true
cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'" >/dev/null
cpx "kubectl wait -n vmtest vmi/baseline --for=delete --timeout=300s" >/dev/null 2>&1 || true; sleep 5
cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'" >/dev/null
cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null
log "E-15 ALL-DONE"
