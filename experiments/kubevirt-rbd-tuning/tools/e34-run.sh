#!/bin/bash
# E-34 OSD flapping：osd.3 週期 stop 60s/start 60s ×5，對照 noout on/off。degraded 負載量 client p99。
# 用法：bash e34-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }
wait_ok(){ for i in $(seq 1 90); do [ "$(monx 'sudo ceph health' 2>/dev/null|head -1)" = "HEALTH_OK" ] && return 0; sleep 10; done; }

for MODE in default noout; do
  D=$BUNDLE/$MODE; mkdir -p $D
  [ "$MODE" = "noout" ] && monx "sudo ceph osd set noout" || monx "sudo ceph osd unset noout 2>/dev/null || true"
  ( while true; do echo "$(date +%s) $(monx 'sudo ceph -s -f json' 2>/dev/null | tr -d '\n')"; sleep 5; done >> "$D/status.jsonl" ) &
  HC=$!
  vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*'
  vmx 'nohup sudo fio --name=dg-rr --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=1 --numjobs=1 --time_based --runtime=700 --output-format=json --output=/home/ubuntu/dg/dg-rr.json --write_lat_log=/home/ubuntu/dg/dg-rr --log_avg_msec=1000 >/dev/null 2>&1 & nohup sudo fio --name=dg-rw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=8 --numjobs=1 --time_based --runtime=700 --output-format=json --output=/home/ubuntu/dg/dg-rw.json --write_lat_log=/home/ubuntu/dg/dg-rw --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; pgrep -c fio'
  log "$MODE load-started"
  sleep 60
  log "$MODE T0-flap-start"
  for c in 1 2 3 4 5; do
    monx "sudo ceph orch daemon stop osd.3" >/dev/null 2>&1; log "$MODE cycle$c stop"; sleep 60
    monx "sudo ceph orch daemon start osd.3" >/dev/null 2>&1; log "$MODE cycle$c start"; sleep 60
  done
  log "$MODE flap-done"
  wait_ok; log "$MODE health-ok"
  sleep 60
  vmx 'sudo pkill fio; true'; sleep 3
  scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$D/"
  kill $HC 2>/dev/null
  log "$MODE done"
done
monx "sudo ceph osd unset noout 2>/dev/null || true"
log "E-34 ALL-DONE"
