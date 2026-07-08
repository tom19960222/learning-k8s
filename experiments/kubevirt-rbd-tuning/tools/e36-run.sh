#!/bin/bash
# E-36 卡死邊界 × osd_request_timeout。停掉同一 PG 的兩顆 OSD（min_size 不滿→該 PG inactive），
# 對照 vdb（timeout=0，預期無限 hang）vs t30 盤（timeout=30，預期 ~30s 轉 EIO）。
# ⚠ 故意不做 ok-to-stop（本實驗就是要製造 inactive PG）；Azure 專屬環境、Gate 2 弱化版適用。
# 用法：bash e36-run.sh <bundle> <guest-ip> <osdA> <osdB>
set -u
BUNDLE=$1; GUEST_IP=$2; OA=$3; OB=$4; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121; MON=azureuser@20.89.248.174
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/timeline.txt"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }

# 1) probe 腳本（0.2s 一發 4k direct write，記每發起訖與結果）
vmx 'cat > /home/ubuntu/probe.sh << "EOF"
#!/bin/bash
DEV=$1; OUT=$2; BLK=$3
i=0
while true; do
  off=$(( (i * 65537) % BLK ))
  t0=$(date +%s.%N)
  if sudo dd if=/dev/zero of=$DEV bs=4k count=1 seek=$off oflag=direct,seek_bytes conv=notrunc status=none 2>>${OUT}.err; then
    echo "$t0 $(date +%s.%N) ok $off" >> $OUT
  else
    echo "$t0 $(date +%s.%N) ERR $off" >> $OUT
  fi
  i=$((i+1)); sleep 0.2
done
EOF
mkdir -p /home/ubuntu/e36 && sudo rm -f /home/ubuntu/e36/*
lsblk -bdno NAME,SIZE | sort'
# 偵測 t30 盤（8GiB）與 baseline 盤（16GiB）
DEVT30=$(vmx 'lsblk -bdno NAME,SIZE | awk "\$2==8589934592{print \$1; exit}"')
DEVB=$(vmx 'lsblk -bdno NAME,SIZE | awk "\$2==17179869184{print \$1; exit}"')
log "devices: baseline=/dev/$DEVB t30=/dev/$DEVT30"
[ -n "$DEVT30" ] && [ -n "$DEVB" ] || { log "FATAL device detect"; exit 1; }
# seek_bytes 用 byte 偏移
vmx "nohup bash /home/ubuntu/probe.sh /dev/$DEVB  /home/ubuntu/e36/probe-b.log  17179869184 >/dev/null 2>&1 &
nohup bash /home/ubuntu/probe.sh /dev/$DEVT30 /home/ubuntu/e36/probe-t30.log 8589934592 >/dev/null 2>&1 &
nohup sudo bash -c 'dmesg -T -w > /home/ubuntu/e36/dmesg.log 2>&1' >/dev/null 2>&1 & sleep 1; pgrep -c -f probe.sh"
log "probes-started"
( while true; do echo "$(date +%s) $(monx 'sudo ceph health detail -f json' 2>/dev/null | tr -d '\n')"; sleep 5; done >> "$BUNDLE/health.jsonl" ) &
HC=$!; trap 'kill $HC 2>/dev/null' EXIT

sleep 60
log "T0-inject: stop osd.${OA} osd.${OB} (PG acting overlap, min_size violated)"
monx "sudo ceph orch daemon stop osd.${OA}; sudo ceph orch daemon stop osd.${OB}"
sleep 300
log "T1-recover: start osd.${OA} osd.${OB}"
monx "sudo ceph orch daemon start osd.${OA}; sudo ceph orch daemon start osd.${OB}"
for i in $(seq 1 90); do [ "$(monx 'sudo ceph health' 2>/dev/null | head -1)" = "HEALTH_OK" ] && break; sleep 10; done
log "health-ok"
sleep 120
vmx 'sudo pkill -f probe.sh; sudo pkill -f "dmesg -T -w"; true'
log "probes-stopped"
scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/e36/*" "$BUNDLE/"
vmx "dmesg 2>/dev/null | tail -5; sudo dd if=/dev/$DEVB of=/dev/null bs=4k count=1 iflag=direct && echo B-READ-OK; sudo dd if=/dev/$DEVT30 of=/dev/null bs=4k count=1 iflag=direct && echo T30-READ-OK" > "$BUNDLE/guest-post.txt" 2>&1
log "E-36 ALL-DONE"
