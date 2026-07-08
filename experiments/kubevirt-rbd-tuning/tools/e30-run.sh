#!/bin/bash
# E-30 單 OSD 乾淨 down（degraded 矩陣第一格）。用法：bash e30-run.sh <bundle-dir> <guest-ip> <osd-id>
set -u
BUNDLE=$1; GUEST_IP=$2; OSD=$3; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }

# 1) guest degraded 負載（背景，1800s 上限）
vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*'
vmx 'nohup sudo fio --name=dg-rw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=8 --numjobs=1 --time_based --runtime=1800 --output-format=json --output=/home/ubuntu/dg/dg-rw.json --write_lat_log=/home/ubuntu/dg/dg-rw --log_avg_msec=1000 >/dev/null 2>&1 & nohup sudo fio --name=dg-rr --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=1 --numjobs=1 --time_based --runtime=1800 --output-format=json --output=/home/ubuntu/dg/dg-rr.json --write_lat_log=/home/ubuntu/dg/dg-rr --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; pgrep -c fio'
vmx 'nohup sudo bash -c "dmesg -T -w > /home/ubuntu/dg/dmesg.log 2>&1" >/dev/null 2>&1 & true'
log "load-started"

# 2) health collector（本機背景迴圈）
( while true; do echo "$(date +%s) $(monx 'sudo ceph health detail -f json' 2>/dev/null | tr -d '\n')"; sleep 5; done >> "$BUNDLE/health.jsonl" ) &
HC=$!
trap 'kill $HC 2>/dev/null' EXIT

# 3) 前窗 120s → 注入
sleep 120
monx "sudo ceph osd ok-to-stop osd.$OSD" || { log "ABORT not ok-to-stop"; exit 1; }
log "T0-inject: ceph orch daemon stop osd.$OSD"
monx "sudo ceph orch daemon stop osd.$OSD"

# 4) 覆蓋 down(即刻)→out(600s)→backfill 開始；共 750s
sleep 750
log "T1-recover: ceph orch daemon start osd.$OSD"
monx "sudo ceph orch daemon start osd.$OSD"
for i in $(seq 1 60); do
  st=$(monx 'sudo ceph -s | grep -c HEALTH_OK' 2>/dev/null)
  [ "$st" = "1" ] && break; sleep 10
done
log "health-ok-again"

# 5) 後窗 300s → 收尾
sleep 300
vmx 'sudo pkill fio; sleep 3; sudo pkill -f "dmesg -T -w"; true'
log "load-stopped"
scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$BUNDLE/"
# guest 症狀收集
vmx 'dmesg | grep -iE "hung|readonly|remount|blocked" | tail -20; echo "---touch-test---"; sudo dd if=/dev/vdb of=/dev/null bs=4k count=1 iflag=direct && echo READ-OK' > "$BUNDLE/guest-symptoms.txt" 2>&1
log "E-30 ALL-DONE"
