#!/bin/bash
# E-14 dedicatedIOThread 對照 orchestrator（A=留空, io=dedicatedIOThread:true）
# 交錯 N=1..3 × [A, io]；bash experiments/kubevirt-rbd-tuning/tools/e14-orchestrator.sh <bundle-dir>
# 全程冪等可中斷：round 目錄已存在且含 8 個 json 就跳過。
set -u
BUNDLE=$1; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
MON=azureuser@20.89.248.174
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%H:%M:%S) $*" | tee -a "$BUNDLE/orchestrator.log"; }
cpx(){ ssh $SSHO $CP "$@"; }
GUEST_IP=""
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
vmscp(){ scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:$1" "$2"; }

apply_variant(){ # $1 = A | wt | wb
  case $1 in
    A)  cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/template/spec/domain/devices/disks/1/dedicatedIOThread\"}]'" >/dev/null 2>&1 || true ;;
    io) cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/domain/devices/disks/1/dedicatedIOThread\",\"value\":true}]'" >/dev/null ;;
  esac
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=delete --timeout=300s" >/dev/null 2>&1 || true
  sleep 5
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null
  GUEST_IP=$(cpx "kubectl get vmi -n vmtest baseline -o jsonpath='{.status.interfaces[0].ipAddress}'")
  log "variant $1 up, guest=$GUEST_IP"
  # 等 ssh 通
  ok=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if vmx 'true' 2>/dev/null; then ok=1; break; fi; sleep 10
  done
  [ "$ok" = 1 ] || { log "FATAL guest ssh unreachable"; exit 1; }
  # containerDisk boot 每次重啟重置：等 cloud-init 重裝 fio，重推 run_matrix.sh
  vmx 'cloud-init status --wait >/dev/null 2>&1; which fio' >/dev/null || { log "FATAL fio missing after boot"; exit 1; }
  scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" \
    "$(dirname "$0")/run_matrix.sh" "ubuntu@[$GUEST_IP]:/home/ubuntu/run_matrix.sh"
}

verify_variant(){ # $1 = A | wt | wb ；斷言 /dev/data 的 direct 與 ua-data 的 write-cache
  POD=$(cpx "kubectl get pod -n vmtest -l kubevirt.io/domain=baseline --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'")
  CMD=$(cpx "kubectl exec -n vmtest $POD -c compute -- sh -c 'tr \"\\0\" \"\\n\" < /proc/\$(pgrep -x qemu-kvm | head -1)/cmdline'")
  echo "$CMD" > "$BUNDLE/effect-verify-$1.txt"
  node=$(echo "$CMD" | grep '"filename":"/dev/data"')
  dev=$(echo "$CMD" | grep '"id":"ua-data"')
  case $1 in
    A)  echo "$dev" | grep -q '"iothread"' && { log "FATAL verify A: iothread present: $dev"; exit 1; } || true ;;
    io) echo "$dev" | grep -q '"iothread"' || { log "FATAL verify io: iothread missing: $dev"; exit 1; } ;;
  esac
  log "verify $1 ok (iothread check passed)"
}

guardrail(){
  ssh $SSHO $MON 'sudo ceph -s' > "$BUNDLE/ceph-last.txt" 2>&1
  grep -q HEALTH_ERR "$BUNDLE/ceph-last.txt" && { log "FATAL HEALTH_ERR"; exit 1; }
  grep -qE 'recovery|backfill|degraded' "$BUNDLE/ceph-last.txt" && log "WARN cluster busy (round taint 候選)" || true
}

run_round(){ # $1 = round dir name（如 round-1-wt）
  if [ -d "$BUNDLE/$1" ] && [ "$(ls "$BUNDLE/$1"/fio-*.json 2>/dev/null | wc -l | tr -d ' ')" = "8" ]; then
    log "skip $1 (already done)"; return
  fi
  guardrail
  vmx "rm -rf /home/ubuntu/m && bash run_matrix.sh /home/ubuntu/m" || { log "FATAL fio $1"; exit 1; }
  mkdir -p "$BUNDLE/$1"
  vmscp "/home/ubuntu/m/*" "$BUNDLE/$1/"
  cp "$BUNDLE/ceph-last.txt" "$BUNDLE/$1/ceph-before.txt"
  log "round $1 done"
}

for N in 1 2 3; do
  for V in A io; do
    apply_variant $V
    verify_variant $V
    run_round "round-$N-$V"
  done
done
# 收尾回 baseline
apply_variant A
verify_variant A
log "E-14 ALL-DONE"
