#!/bin/bash
# E-35 mon 階梯：down 1/3(quorum 撐)→down 2/3(quorum 失)→疊 OSD kill(複合)→systemctl 全恢復。
# ⚠quorum 失時 ceph CLI 會 hang，恢復全走 systemctl。trap 保底：任何退出都 start 回所有 mon+osd。
# 用法：bash e35-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
M0=azureuser@20.89.248.174; M1=azureuser@40.74.64.220; M2=azureuser@20.89.232.116
OSD1=azureuser@20.78.146.15
FSID=ab33c12c-7a5c-11f1-913a-894a658522d3
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
munit(){ echo "ceph-$FSID@mon.$1.service"; }
recover_all(){
  log "RECOVER: start all mons + osd.3"
  ssh $SSHO $M1 "sudo systemctl start $(munit cyshih-mon-1)" 2>/dev/null
  ssh $SSHO $M2 "sudo systemctl start $(munit cyshih-mon-2)" 2>/dev/null
  ssh $SSHO $OSD1 "sudo systemctl start ceph-$FSID@osd.3.service" 2>/dev/null
}
trap recover_all EXIT

# guest 穩態負載（輕，觀察是否持續）
vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*; nohup sudo fio --name=dg --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=1 --time_based --runtime=900 --output=/home/ubuntu/dg/dg.json --write_lat_log=/home/ubuntu/dg/dg --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; echo started'
log "load-started"; sleep 30

# 段1：down mon-2（1/3）→ quorum 撐（2/3）
log "STAGE1: stop mon.cyshih-mon-2 (1/3 down)"
ssh $SSHO $M2 "sudo systemctl stop $(munit cyshih-mon-2)"
sleep 60
S1=$(ssh $SSHO $M0 'timeout 15 sudo ceph -s 2>/dev/null | grep -E "mon:|health:" | tr "\n" " "')
log "STAGE1 ceph -s: $S1"

# 段2：down mon-1（2/3）→ quorum 失
log "STAGE2: stop mon.cyshih-mon-1 (2/3 down → quorum LOST)"
ssh $SSHO $M1 "sudo systemctl stop $(munit cyshih-mon-1)"
log "STAGE2: quorum lost, observing steady IO 180s (ceph CLI will hang)"
sleep 180
# guest IO 是否還活著（穩態 IO 不需 mon）
IOALIVE=$(vmx 'timeout 10 sudo dd if=/dev/vdb of=/dev/null bs=4k count=1 iflag=direct 2>&1 | grep -c copied || echo 0')
log "STAGE2 guest steady-read alive=$IOALIVE (1=IO 仍通)"

# 段3：quorum 失狀態下 kill osd.3（複合）
log "STAGE3: stop osd.3 while quorum lost (compound failure)"
ssh $SSHO $OSD1 "sudo systemctl stop ceph-$FSID@osd.3.service"
sleep 120
# 對 osd.3 的 PG 寫入是否 hang（client 拿不到新 osdmap）
IOTEST=$(vmx 'timeout 30 sudo dd if=/dev/zero of=/dev/vdb bs=4k count=1 seek=99999 oflag=direct 2>&1 | grep -c copied || echo 0')
log "STAGE3 guest write (may hang) result=$IOTEST (1=成功 0=hang/timeout)"

# 恢復：先 mon 回 quorum → osd → HEALTH_OK
log "RECOVERY: start mon-1 mon-2 → quorum"
ssh $SSHO $M1 "sudo systemctl start $(munit cyshih-mon-1)"; ssh $SSHO $M2 "sudo systemctl start $(munit cyshih-mon-2)"
sleep 30
log "RECOVERY: start osd.3"
ssh $SSHO $OSD1 "sudo systemctl start ceph-$FSID@osd.3.service"
for i in $(seq 1 60); do [ "$(ssh $SSHO $M0 'timeout 15 sudo ceph health 2>/dev/null|head -1')" = "HEALTH_OK" ] && break; sleep 10; done
log "RECOVERY: $(ssh $SSHO $M0 'timeout 15 sudo ceph quorum_status -f json 2>/dev/null | python3 -c "import json,sys;print(\"quorum\",json.load(sys.stdin)[\"quorum_names\"])"')"
vmx 'sudo pkill fio; true'; sleep 2
scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$BUNDLE/" 2>/dev/null
log "E-35 ALL-DONE"
