#!/bin/bash
# E-33 封包遺失：osd-1 網卡 netem loss 0.1% 然後 0.5%，量 client p99.9 放大。
# 用法：bash e33-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174; OSDHOST=azureuser@20.78.146.15
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }
osdx(){ ssh $SSHO $OSDHOST "$@"; }
clean(){ osdx 'sudo tc qdisc del dev eth0 root 2>/dev/null; sudo tc qdisc del dev eth1 root 2>/dev/null; true'; }
trap clean EXIT

( while true; do echo "$(date +%s) health=$(monx 'sudo ceph health' 2>/dev/null|head -1)"; sleep 5; done >> "$BUNDLE/health.jsonl" ) &
HC=$!

for LOSS in 0.1% 0.5%; do
  D=$BUNDLE/loss-$LOSS; mkdir -p $D
  vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*'
  vmx 'nohup sudo fio --name=dg-rr --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=1 --numjobs=1 --time_based --runtime=420 --output-format=json --output=/home/ubuntu/dg/dg-rr.json --write_lat_log=/home/ubuntu/dg/dg-rr --log_avg_msec=1000 >/dev/null 2>&1 & nohup sudo fio --name=dg-rw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=8 --numjobs=1 --time_based --runtime=420 --output-format=json --output=/home/ubuntu/dg/dg-rw.json --write_lat_log=/home/ubuntu/dg/dg-rw --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; pgrep -c fio'
  log "loss=$LOSS load-started"
  sleep 90
  log "loss=$LOSS T0-inject"
  osdx "sudo tc qdisc add dev eth0 root netem loss $LOSS; sudo tc qdisc add dev eth1 root netem loss $LOSS; tc qdisc show dev eth0" 2>&1 | tee -a "$BUNDLE/inject.txt"
  sleep 180
  log "loss=$LOSS T1-recover"
  clean
  sleep 60
  vmx 'sudo pkill fio; true'; sleep 3
  scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$D/"
  log "loss=$LOSS done"
done
kill $HC 2>/dev/null
log "E-33 ALL-DONE"
