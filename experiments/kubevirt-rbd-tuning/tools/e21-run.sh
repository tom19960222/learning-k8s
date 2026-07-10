#!/bin/bash
# E-21 osd_memory_target 4G vs 8G（A 類 runtime，不重啟 VM；交錯 A/B/A/B/A/B 共 6 round）
# 用法：bash e21-run.sh <bundle> <guest-ip>
# 每次切換 osd_memory_target 後等 600s（cache 暖機/回收）才跑矩陣。
# 每 round 前後收 3 台 OSD 節點的 ceph-osd RSS（E-52 行為級證據）。
# 結束把 osd_memory_target 設回 4294967296（baseline）。
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
MON=azureuser@20.89.248.174
OSD_HOSTS="20.89.233.19 20.78.146.15 20.89.232.246"
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%H:%M:%S) $*" | tee -a "$BUNDLE/orchestrator.log"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
monx(){ ssh $SSHO $MON "$@"; }

TARGET_A=4294967296
TARGET_B=8589934592

collect_rss(){ # $1 = output file；三台 OSD 節點各收一次 ceph-osd 行程 RSS
  : > "$1"
  for h in $OSD_HOSTS; do
    echo "=== $h $(date -u +%s) ===" >> "$1"
    ssh $SSHO azureuser@"$h" 'ps -o pid,rss,cmd -C ceph-osd' >> "$1" 2>&1
  done
}

set_target(){ # $1 = value；set 後 get 回讀驗證
  monx "sudo ceph config set osd osd_memory_target $1" >/dev/null
  GOT=$(monx "sudo ceph config get osd osd_memory_target")
  [ "$GOT" = "$1" ] || { log "FATAL config readback mismatch want=$1 got=$GOT"; exit 1; }
  log "osd_memory_target set to $1 (verified via get)"
}

scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" "$(dirname "$0")/run_matrix.sh" "ubuntu@[$GUEST_IP]:/home/ubuntu/run_matrix.sh"

for RND in 1 2 3 4 5 6; do
  case $RND in
    1|3|5) V=A; TARGET=$TARGET_A ;;
    2|4|6) V=B; TARGET=$TARGET_B ;;
  esac
  D="round-$RND-$V"
  if [ -d "$BUNDLE/$D" ] && [ "$(ls "$BUNDLE/$D"/fio-*.json 2>/dev/null | wc -l | tr -d ' ')" = "8" ]; then
    log "skip $D (already done)"; continue
  fi
  set_target "$TARGET"
  log "waiting 600s cache warm/reclaim before $D"
  sleep 600
  mkdir -p "$BUNDLE/$D"
  collect_rss "$BUNDLE/$D/rss-before.txt"
  MON_S=$(monx 'sudo ceph -s')
  echo "$MON_S" > "$BUNDLE/$D/ceph-before.txt"
  echo "$MON_S" | grep -q HEALTH_ERR && { log "FATAL HEALTH_ERR before $D"; exit 1; }
  echo "$MON_S" | grep -qE 'recovery|backfill|degraded' && log "WARN cluster busy $D (round taint 候選)"
  vmx "rm -rf /home/ubuntu/m && bash run_matrix.sh /home/ubuntu/m" || { log "FATAL fio $D"; exit 1; }
  scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/m/*" "$BUNDLE/$D/"
  collect_rss "$BUNDLE/$D/rss-after.txt"
  monx 'sudo ceph -s' > "$BUNDLE/$D/ceph-after.txt"
  log "round $D done"
done

# 收尾回 baseline
set_target "$TARGET_A"
log "E-21 ALL-DONE"
