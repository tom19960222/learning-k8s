#!/bin/bash
# E-38 pool full 行為：把 full_ratio 設到當前用量(26%)以下→瞬間 FULL，測 client 寫入 hang vs EIO。
# 用調 ratio 注入（不真填），可逆。用法：bash e38-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }
restore(){ monx 'sudo ceph osd set-full-ratio 0.95; sudo ceph osd set-nearfull-ratio 0.85; sudo ceph osd set-backfillfull-ratio 0.90' 2>&1 | tee -a "$BUNDLE/restore.txt"; }
trap restore EXIT

( while true; do echo "$(date +%s) health=$(monx 'sudo ceph health' 2>/dev/null|head -1)"; sleep 5; done >> "$BUNDLE/health.jsonl" ) &
HC=$!

# guest 寫入探針：每 1s 一發 4k O_DIRECT 寫，記起訖與結果
vmx 'cat > /home/ubuntu/wprobe.sh <<"WP"
i=0
while true; do
  off=$(( (i % 1000) * 4096 ))
  t0=$(date +%s.%N)
  if sudo dd if=/dev/zero of=/dev/vdb bs=4k count=1 seek=$off oflag=direct,seek_bytes conv=notrunc status=none 2>/dev/null; then
    echo "$t0 $(date +%s.%N) ok" 
  else
    echo "$t0 $(date +%s.%N) ERR"
  fi
  i=$((i+1)); sleep 1
done
WP
mkdir -p /home/ubuntu/e38; nohup bash /home/ubuntu/wprobe.sh > /home/ubuntu/e38/probe.log 2>&1 & echo started'
log "probe-started"
sleep 30
log "T0-inject: set-full-ratio 0.20 (current usage 26% → FULL)"
monx 'sudo ceph osd set-nearfull-ratio 0.10; sudo ceph osd set-backfillfull-ratio 0.15; sudo ceph osd set-full-ratio 0.20' 2>&1 | tee -a "$BUNDLE/inject.txt"
sleep 90
log "T1-recover: restore ratios"
restore
sleep 60
vmx 'sudo pkill -f wprobe.sh; true'; sleep 2
scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" "ubuntu@[$GUEST_IP]:/home/ubuntu/e38/probe.log" "$BUNDLE/"
vmx 'sudo dmesg 2>/dev/null | grep -iE "full|nospc|error" | tail -5; mount | grep vdb || echo "vdb raw"' > "$BUNDLE/guest-post.txt" 2>&1
kill $HC 2>/dev/null
log "E-38 ALL-DONE"
