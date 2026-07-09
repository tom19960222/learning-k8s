#!/bin/bash
# E-32 gray failure（v3）：對 cyshih-osd-1（osd.3/4/5）的 public+cluster 網卡加 50ms netem 延遲，
# 製造「回應慢的 OSD host」。1/3 primary 變慢。關鍵斷言：ceph health 儘量 OK、client p99 惡化。
# 用法：bash e32-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174; OSDHOST=azureuser@20.78.146.15
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }
osdx(){ ssh $SSHO $OSDHOST "$@"; }

( while true; do echo "$(date +%s) health=$(monx 'sudo ceph health' 2>/dev/null|head -1)"; sleep 5; done >> "$BUNDLE/health.jsonl" ) &
HC=$!; trap 'kill $HC 2>/dev/null' EXIT

vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*'
vmx 'nohup sudo fio --name=dg-rr --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=1 --numjobs=1 --time_based --runtime=540 --output-format=json --output=/home/ubuntu/dg/dg-rr.json --write_lat_log=/home/ubuntu/dg/dg-rr --log_avg_msec=1000 >/dev/null 2>&1 & nohup sudo fio --name=dg-rw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=8 --numjobs=1 --time_based --runtime=540 --output-format=json --output=/home/ubuntu/dg/dg-rw.json --write_lat_log=/home/ubuntu/dg/dg-rw --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; pgrep -c fio'
log "load-started"
sleep 120
log "T0-inject: netem delay 50ms on osd-1 eth0+eth1"
osdx 'sudo tc qdisc add dev eth0 root netem delay 50ms; sudo tc qdisc add dev eth1 root netem delay 50ms; tc qdisc show dev eth0; tc qdisc show dev eth1' 2>&1 | tee -a "$BUNDLE/inject.txt"
sleep 240
log "T1-recover: remove netem"
osdx 'sudo tc qdisc del dev eth0 root 2>/dev/null; sudo tc qdisc del dev eth1 root 2>/dev/null; echo reverted' 2>&1 | tee -a "$BUNDLE/inject.txt"
sleep 120
vmx 'sudo pkill fio; true'; sleep 3
scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$BUNDLE/"
# 保險：再次確認 netem 已清
osdx 'tc qdisc show dev eth0; tc qdisc show dev eth1' >> "$BUNDLE/inject.txt" 2>&1
kill $HC 2>/dev/null
log "E-32 ALL-DONE"
