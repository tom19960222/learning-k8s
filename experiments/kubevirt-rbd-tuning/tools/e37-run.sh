#!/bin/bash
# E-37 deep-scrub 干擾 × osd_scrub_sleep。兩段：sleep=0（激進）vs sleep=0.1，各段對測試 pool 全 PG 觸發 deep-scrub，量 client p99。
# 用法：bash e37-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }

for SLEEP in 0 0.1; do
  monx "sudo ceph config set osd osd_scrub_sleep $SLEEP"
  log "osd_scrub_sleep=$SLEEP set"
  D=$BUNDLE/sleep-$SLEEP; mkdir -p $D
  ( while true; do echo "$(date +%s) $(monx 'sudo ceph -s -f json' 2>/dev/null | tr -d '\n')"; sleep 5; done >> "$D/status.jsonl" ) &
  HC=$!
  vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*'
  vmx 'nohup sudo fio --name=dg-rr --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=1 --numjobs=1 --time_based --runtime=600 --output-format=json --output=/home/ubuntu/dg/dg-rr.json --write_lat_log=/home/ubuntu/dg/dg-rr --log_avg_msec=1000 >/dev/null 2>&1 & nohup sudo fio --name=dg-rw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=8 --numjobs=1 --time_based --runtime=600 --output-format=json --output=/home/ubuntu/dg/dg-rw.json --write_lat_log=/home/ubuntu/dg/dg-rw --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; pgrep -c fio'
  log "sleep=$SLEEP load-started"
  sleep 60
  log "sleep=$SLEEP T0-scrub-trigger"
  for pg in $(monx 'sudo ceph pg ls-by-pool kubevirt -f json' 2>/dev/null | python3 -c 'import json,sys;print(" ".join(p["pgid"] for p in json.load(sys.stdin)["pg_stats"]))' 2>/dev/null); do
    monx "sudo ceph pg deep-scrub $pg" >/dev/null 2>&1
  done
  sleep 420
  log "sleep=$SLEEP window-done"
  vmx 'sudo pkill fio; true'; sleep 3
  scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$D/"
  kill $HC 2>/dev/null
  log "sleep=$SLEEP done"
done
monx "sudo ceph config rm osd osd_scrub_sleep"
log "E-37 ALL-DONE"
