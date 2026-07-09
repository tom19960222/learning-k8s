#!/bin/bash
# E-32 gray failure：對 osd.3（cyshih-osd-1, dm-0=252:0）用 systemd cgroup 限速 150 IOPS，
# 製造「慢但不 down」。關鍵斷言：ceph health 全程 OK、osd perf latency 飆、client p99 惡化。
# 用法：bash e32-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174; OSDHOST=azureuser@20.78.146.15
UNIT="ceph-ab33c12c-7a5c-11f1-913a-894a658522d3@osd.3.service"
DEV="252:0"
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }
osdx(){ ssh $SSHO $OSDHOST "$@"; }

# health + osd perf collector
( while true; do echo "$(date +%s) health=$(monx 'sudo ceph health' 2>/dev/null|head -1) $(monx 'sudo ceph osd perf -f json' 2>/dev/null|tr -d '\n')"; sleep 5; done >> "$BUNDLE/health-perf.jsonl" ) &
HC=$!; trap 'kill $HC 2>/dev/null' EXIT

vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*'
vmx 'nohup sudo fio --name=dg-rr --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=1 --numjobs=1 --time_based --runtime=600 --output-format=json --output=/home/ubuntu/dg/dg-rr.json --write_lat_log=/home/ubuntu/dg/dg-rr --log_avg_msec=1000 >/dev/null 2>&1 & nohup sudo fio --name=dg-rw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=8 --numjobs=1 --time_based --runtime=600 --output-format=json --output=/home/ubuntu/dg/dg-rw.json --write_lat_log=/home/ubuntu/dg/dg-rw --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; pgrep -c fio'
log "load-started"
sleep 120
log "T0-inject: throttle osd.3 $DEV to 150 IOPS"
osdx "sudo systemctl set-property --runtime $UNIT IOReadIOPSMax=\"$DEV 150\" IOWriteIOPSMax=\"$DEV 150\"" 2>&1 | tee -a "$BUNDLE/inject.txt"
osdx "systemctl show $UNIT -p IOReadIOPSMax -p IOWriteIOPSMax" >> "$BUNDLE/inject.txt" 2>&1
sleep 300
log "T1-recover: remove throttle"
osdx "sudo systemctl set-property --runtime $UNIT IOReadIOPSMax=\"$DEV 0\" IOWriteIOPSMax=\"$DEV 0\"" 2>&1 | tee -a "$BUNDLE/inject.txt"
sleep 120
vmx 'sudo pkill fio; true'; sleep 3
scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$BUNDLE/"
kill $HC 2>/dev/null
log "E-32 ALL-DONE"
