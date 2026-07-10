#!/bin/bash
# E-39 mClock profile 在 backfill 期的 client latency A/B。
# 設計：兩次獨立注入（各一 profile），同等 backfill 資料量；out 用手動 `ceph osd out` 立即觸發（不等 600s）。
# 用法：bash e39-run.sh <bundle-dir> <guest-ip> <osd-id>
set -u
BUNDLE=$1; GUEST_IP=$2; OSD=$3; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }
wait_ok(){ for i in $(seq 1 120); do [ "$(monx 'sudo ceph health' 2>/dev/null | head -1)" = "HEALTH_OK" ] && return 0; sleep 10; done; log "WARN health not OK after 20min"; return 1; }

# 0) 加大 backfill 資料量：60G scratch image（rbd bench 直寫，不掛載）
monx "sudo rbd info kubevirt/ioperf-fill >/dev/null 2>&1 || sudo rbd create kubevirt/ioperf-fill --size 60G"
log "fill-start"
monx "sudo rbd bench --io-type write --io-size 4M --io-threads 8 --io-total 60G --io-pattern seq kubevirt/ioperf-fill > /dev/null 2>&1" || true
log "fill-done"
wait_ok

for PROFILE in balanced high_client_ops; do
  monx "sudo ceph config set osd osd_mclock_profile $PROFILE"
  log "profile=$PROFILE set"
  D=$BUNDLE/$PROFILE; mkdir -p $D
  # collector：ceph -s json 每 5s（含 recovery 速率）
  ( while true; do echo "$(date +%s) $(monx 'sudo ceph -s -f json' 2>/dev/null | tr -d '\n')"; sleep 5; done >> "$D/status.jsonl" ) &
  HC=$!
  # guest 負載
  vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*'
  vmx 'nohup sudo fio --name=dg-rw --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=8 --numjobs=1 --time_based --runtime=900 --output-format=json --output=/home/ubuntu/dg/dg-rw.json --write_lat_log=/home/ubuntu/dg/dg-rw --log_avg_msec=1000 >/dev/null 2>&1 & nohup sudo fio --name=dg-rr --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=1 --numjobs=1 --time_based --runtime=900 --output-format=json --output=/home/ubuntu/dg/dg-rr.json --write_lat_log=/home/ubuntu/dg/dg-rr --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; pgrep -c fio'
  log "$PROFILE load-started"
  sleep 60
  monx "sudo ceph osd ok-to-stop osd.$OSD" || { log "ABORT not ok-to-stop"; kill $HC; exit 1; }
  log "$PROFILE T0-inject"
  monx "sudo ceph orch daemon stop osd.$OSD && sudo ceph osd out $OSD"
  sleep 240
  log "$PROFILE T1-recover"
  monx "sudo ceph orch daemon start osd.$OSD && sudo ceph osd in $OSD"
  wait_ok
  log "$PROFILE health-ok"
  vmx 'sudo pkill fio; true'; sleep 3
  scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$D/"
  kill $HC 2>/dev/null
  log "$PROFILE done"
done
monx "sudo ceph config set osd osd_mclock_profile balanced && sudo ceph config rm osd osd_mclock_profile"
log "profile restored to default"
log "E-39 ALL-DONE"
