#!/bin/bash
# E-31 OSD node 硬斷：az vm stop cyshih-osd-2（3 OSD 同時失效）。size=3/min_size=2 → IO 應續（degraded）。
# 用法：bash e31-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174
RG=CYSHIH-KUBEVIRT-CEPH-LAB; OSDVM=cyshih-osd-2
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "timeout 20 $*"; }
recover(){ log "RECOVER: az start $OSDVM"; az vm start --resource-group $RG --name $OSDVM 2>&1 | tail -1; }
trap recover EXIT

( while true; do echo "$(date +%s) $(monx 'sudo ceph -s' 2>/dev/null | grep -E 'health|osd:|pgs:' | tr '\n' '|')"; sleep 5; done >> "$BUNDLE/ceph.log" ) &
HC=$!
vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*; nohup sudo fio --name=dg-rr --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=1 --time_based --runtime=600 --output=/home/ubuntu/dg/dg-rr.json --write_lat_log=/home/ubuntu/dg/dg-rr --log_avg_msec=1000 >/dev/null 2>&1 & nohup sudo fio --name=dg-rw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=8 --time_based --runtime=600 --output=/home/ubuntu/dg/dg-rw.json --write_lat_log=/home/ubuntu/dg/dg-rw --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; echo started'
log "load-started"; sleep 90
log "T0-inject: az vm stop $OSDVM --skip-shutdown (3 OSD 同時失效)"
az vm stop --resource-group $RG --name $OSDVM --skip-shutdown --no-wait 2>&1 | tail -1
log "az-stop-issued"
sleep 240   # 觀察 down-但-未-out（<600s），min_size=2 應撐住
IOALIVE=$(vmx 'timeout 15 sudo dd if=/dev/vdb of=/dev/null bs=4k count=1 iflag=direct 2>&1 | grep -c copied || echo 0')
log "T0+240 guest read alive=$IOALIVE health=$(monx 'sudo ceph health' 2>/dev/null | head -1)"
log "T1-recover: az start $OSDVM"
recover; trap - EXIT
for i in $(seq 1 90); do [ "$(monx 'sudo ceph health 2>/dev/null|head -1')" = "HEALTH_OK" ] && break; sleep 10; done
log "health-ok-again"
sleep 60
vmx 'sudo pkill fio; true'; sleep 2
scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$BUNDLE/" 2>/dev/null
kill $HC 2>/dev/null
log "E-31 ALL-DONE"
