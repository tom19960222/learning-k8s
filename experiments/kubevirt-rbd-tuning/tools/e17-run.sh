#!/bin/bash
# E-17 guest IO scheduler none vs mq-deadline（A 類 runtime，同 VM 交錯，免重啟）
# 用法：bash e17-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/orchestrator.log"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
vmx 'cat /sys/block/vdb/queue/scheduler' > "$BUNDLE/scheduler-default.txt"
log "default scheduler: $(cat $BUNDLE/scheduler-default.txt)"
scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" "$(dirname "$0")/run_matrix.sh" "ubuntu@[$GUEST_IP]:/home/ubuntu/run_matrix.sh"
for N in 1 2 3; do
  for SCHED in mq-deadline none; do
    D="round-$N-$SCHED"
    if [ -d "$BUNDLE/$D" ] && [ "$(ls "$BUNDLE/$D"/fio-*.json 2>/dev/null | wc -l | tr -d ' ')" = "8" ]; then log "skip $D"; continue; fi
    vmx "echo $SCHED | sudo tee /sys/block/vdb/queue/scheduler >/dev/null; grep -o '\[[a-z-]*\]' /sys/block/vdb/queue/scheduler"
    cur=$(vmx "grep -o '\[[a-z-]*\]' /sys/block/vdb/queue/scheduler")
    [ "$cur" = "[$SCHED]" ] || { log "FATAL verify $SCHED got $cur"; exit 1; }
    log "verify $SCHED ok"
    vmx "rm -rf /home/ubuntu/m && bash run_matrix.sh /home/ubuntu/m" || { log "FATAL fio $D"; exit 1; }
    mkdir -p "$BUNDLE/$D"
    scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/m/*" "$BUNDLE/$D/"
    log "round $D done"
  done
done
# 還原預設
DEF=$(grep -o '\[[a-z-]*\]' "$BUNDLE/scheduler-default.txt" | tr -d '[]')
vmx "echo $DEF | sudo tee /sys/block/vdb/queue/scheduler >/dev/null"
log "restored to $DEF"
log "E-17 ALL-DONE"
