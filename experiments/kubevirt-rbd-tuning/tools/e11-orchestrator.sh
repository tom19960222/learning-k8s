#!/bin/bash
# E-11 bus 對照（A=virtio-blk, scsi=virtio-scsi）。⚠ scsi 變體 guest 資料盤名變 /dev/sdX，
# run_matrix filename 動態偵測（16GiB 盤）。交錯 N=1..3 × [A, scsi]。
# 全程冪等可中斷：round 目錄已存在且含 8 個 json 就跳過。
set -u
BUNDLE=$1; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
MON=azureuser@20.89.248.174
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%H:%M:%S) $*" | tee -a "$BUNDLE/orchestrator.log"; }
cpx(){ ssh $SSHO $CP "$@"; }
GUEST_IP=""
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
vmscp(){ scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:$1" "$2"; }

apply_variant(){ # $1 = A | wt | wb
  case $1 in
    A)    cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/domain/devices/disks/1/disk/bus\",\"value\":\"virtio\"}]'" >/dev/null ;;
    scsi) cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/domain/devices/disks/1/disk/bus\",\"value\":\"scsi\"}]'" >/dev/null ;;
  esac
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=delete --timeout=300s" >/dev/null 2>&1 || true
  sleep 5
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null
  GUEST_IP=$(cpx "kubectl get vmi -n vmtest baseline -o jsonpath='{.status.interfaces[0].ipAddress}'")
  log "variant $1 up, guest=$GUEST_IP"
  # 等 ssh 通
  ok=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if vmx 'true' 2>/dev/null; then ok=1; break; fi; sleep 10
  done
  [ "$ok" = 1 ] || { log "FATAL guest ssh unreachable"; exit 1; }
  # containerDisk boot 每次重啟重置：等 cloud-init 重裝 fio，重推 run_matrix.sh
  vmx 'cloud-init status --wait >/dev/null 2>&1; which fio' >/dev/null || { log "FATAL fio missing after boot"; exit 1; }
}

verify_variant(){ # $1 = A | wt | wb ；斷言 /dev/data 的 direct 與 ua-data 的 write-cache
  POD=$(cpx "kubectl get pod -n vmtest -l kubevirt.io/domain=baseline --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'")
  CMD=$(cpx "kubectl exec -n vmtest $POD -c compute -- sh -c 'tr \"\\0\" \"\\n\" < /proc/\$(pgrep -x qemu-kvm | head -1)/cmdline'")
  echo "$CMD" > "$BUNDLE/effect-verify-$1.txt"
  node=$(echo "$CMD" | grep '"filename":"/dev/data"')
  dev=$(echo "$CMD" | grep '"id":"ua-data"')
  case $1 in
    A)    echo "$CMD" | grep -q "virtio-blk-pci" || { log "FATAL verify A: no virtio-blk-pci"; exit 1; } ;;
    scsi) echo "$CMD" | grep -q "scsi-hd\|virtio-scsi" || { log "FATAL verify scsi: no scsi device"; exit 1; } ;;
  esac
  log "verify $1 ok (bus check passed)"
}

guardrail(){
  ssh $SSHO $MON 'sudo ceph -s' > "$BUNDLE/ceph-last.txt" 2>&1
  grep -q HEALTH_ERR "$BUNDLE/ceph-last.txt" && { log "FATAL HEALTH_ERR"; exit 1; }
  grep -qE 'recovery|backfill|degraded' "$BUNDLE/ceph-last.txt" && log "WARN cluster busy (round taint 候選)" || true
}

run_round(){ # $1 = round dir name（如 round-1-wt）
  if [ -d "$BUNDLE/$1" ] && [ "$(ls "$BUNDLE/$1"/fio-*.json 2>/dev/null | wc -l | tr -d ' ')" = "8" ]; then
    log "skip $1 (already done)"; return
  fi
  guardrail
  vmx 'cat > /home/ubuntu/run_matrix.sh <<"RMEOF"
OUT=$1; mkdir -p $OUT
DEV=/dev/$(lsblk -bdno NAME,SIZE | awk "\$2==17179869184{print \$1; exit}")
run(){ sudo fio --name=$1 --filename=$DEV --direct=1 --ioengine=libaio --rw=$2 --bs=$3 --iodepth=$4 --numjobs=1 --time_based --runtime=60 --ramp_time=15 --randseed=8675309 --group_reporting --output-format=json --output=$OUT/fio-$1.json --write_lat_log=$OUT/fio-$1 --log_avg_msec=1000 >/dev/null; }
run rr-qd1 randread 4k 1; run rr-qd8 randread 4k 8; run rr-qd32 randread 4k 32
run rw-qd1 randwrite 4k 1; run rw-qd8 randwrite 4k 8; run rw-qd32 randwrite 4k 32
run sr-1m read 1M 16; run sw-1m write 1M 16
RMEOF'
  vmx "rm -rf /home/ubuntu/m && bash /home/ubuntu/run_matrix.sh /home/ubuntu/m" || { log "FATAL fio $1"; exit 1; }
  mkdir -p "$BUNDLE/$1"
  vmscp "/home/ubuntu/m/*" "$BUNDLE/$1/"
  cp "$BUNDLE/ceph-last.txt" "$BUNDLE/$1/ceph-before.txt"
  log "round $1 done"
}

for N in 1 2 3; do
  for V in A scsi; do
    apply_variant $V
    verify_variant $V
    run_round "round-$N-$V"
  done
done
# 收尾回 baseline
apply_variant A
verify_variant A
log "E-11 ALL-DONE"
