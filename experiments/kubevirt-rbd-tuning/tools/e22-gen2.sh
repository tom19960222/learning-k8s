#!/bin/bash
# E-22 osd_op_num_shards_ssd 8 vs 16（C類 rolling restart）。量效果 + rolling restart 的 client 代價。
# 用法：bash e22-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.78.164.180; MON=azureuser@20.78.164.206
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/log.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }
wait_ok(){ for i in $(seq 1 60); do [ "$(monx 'sudo ceph health' 2>/dev/null|head -1)" = "HEALTH_OK" ] && return 0; sleep 5; done; }
matrix(){ vmx "cat > /home/ubuntu/rm.sh <<'RMEOF'
OUT=\$1; mkdir -p \$OUT
DEV=/dev/\$(lsblk -bdno NAME,SIZE | awk '\$2==17179869184{print \$1; exit}')
run(){ sudo fio --name=\$1 --filename=\$DEV --direct=1 --ioengine=libaio --rw=\$2 --bs=\$3 --iodepth=\$4 --numjobs=\$5 --time_based --runtime=60 --ramp_time=15 --randseed=8675309 --group_reporting --output-format=json --output=\$OUT/fio-\$1.json >/dev/null; }
run rr-qd1 randread 4k 1 1; run rr-qd32x4 randread 4k 32 4; run rw-qd32x4 randwrite 4k 32 4
RMEOF
rm -rf /home/ubuntu/m && bash /home/ubuntu/rm.sh /home/ubuntu/m"
  mkdir -p "$1"; scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/m/*" "$1/"; }

rolling_restart(){ # 帶 degraded 負載收 client p99
  local tag=$1
  vmx 'mkdir -p /home/ubuntu/dg && sudo rm -f /home/ubuntu/dg/*; nohup sudo fio --name=dg --filename=/dev/vdb --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=1 --time_based --runtime=600 --output=/home/ubuntu/dg/dg.json --write_lat_log=/home/ubuntu/dg/dg --log_avg_msec=1000 >/dev/null 2>&1 & sleep 1; echo dg-started'
  log "$tag rolling-start"
  for o in $(seq 0 5); do
    monx "sudo ceph osd ok-to-stop osd.$o" >/dev/null 2>&1 && monx "sudo ceph orch daemon restart osd.$o" >/dev/null 2>&1
    log "$tag restarted osd.$o"; wait_ok
  done
  log "$tag rolling-done"
  vmx 'sudo pkill fio; true'; sleep 2
  mkdir -p "$BUNDLE/$tag-rolling"; scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/dg/*" "$BUNDLE/$tag-rolling/"
}

log "=== shards=8 (default) baseline ==="
matrix "$BUNDLE/shards8"
log "=== set shards=16 + rolling restart ==="
monx "sudo ceph config set osd osd_op_num_shards_ssd 16"
rolling_restart "to16"
monx "sudo ceph config show osd.0 osd_op_num_shards_ssd" > "$BUNDLE/verify-16.txt" 2>&1
log "verify: $(cat $BUNDLE/verify-16.txt)"
matrix "$BUNDLE/shards16"
log "=== revert shards=8 + rolling restart ==="
monx "sudo ceph config rm osd osd_op_num_shards_ssd"
rolling_restart "to8"
log "E-22 ALL-DONE"
