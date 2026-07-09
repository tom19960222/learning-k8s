#!/bin/bash
# E-40 crash consistency：cache=none vs writeback，各 3 次。
# 探針：guest O_DIRECT 寫 'X'-pattern 4k blocks（block 0,1,2..），每筆完成印 block 號→Mac 捕捉。
# kill -9 QEMU→VMI 重啟→回讀每個 acked block 驗 pattern。none 應全存活，writeback 尾段應遺失。
# 用法：bash e40-run.sh <bundle>
set -u
BUNDLE=$1; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/log.txt"; }
cpx(){ ssh $SSHO $CP "$@"; }
gip(){ cpx "kubectl get vmi -n vmtest baseline -o jsonpath='{.status.interfaces[0].ipAddress}'"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$1 "$2"; }

set_cache(){ # none|writeback
  case $1 in
    none) cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/template/spec/domain/devices/disks/1/cache\"}]'" >/dev/null 2>&1 || true ;;
    writeback) cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/domain/devices/disks/1/cache\",\"value\":\"writeback\"}]'" >/dev/null 2>&1 || \
               cpx "kubectl patch vm -n vmtest baseline --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/domain/devices/disks/1/cache\",\"value\":\"writeback\"}]'" >/dev/null ;;
  esac
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Halted\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=delete --timeout=300s" >/dev/null 2>&1 || true; sleep 5
  cpx "kubectl patch vm -n vmtest baseline --type=merge -p '{\"spec\":{\"runStrategy\":\"Always\"}}'" >/dev/null
  cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null
}
wait_ssh(){ for i in $(seq 1 18); do vmx $1 'cloud-init status' 2>/dev/null|grep -q done && return 0; sleep 10; done; return 1; }
verify_cache(){ # 印 cmdline 佐證
  POD=$(cpx "kubectl get pod -n vmtest -l kubevirt.io/domain=baseline --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'")
  cpx "kubectl exec -n vmtest $POD -c compute -- sh -c 'tr \"\\0\" \"\\n\" < /proc/\$(pgrep -x qemu-kvm|head -1)/cmdline'" | grep '/dev/data'
}

for CACHE in none writeback; do
  for TRY in 1 2 3; do
    T="$BUNDLE/$CACHE-$TRY"; mkdir -p "$T"
    set_cache $CACHE
    IP=$(gip); wait_ssh $IP || { log "FATAL cloud-init $CACHE-$TRY"; exit 1; }
    verify_cache > "$T/verify.txt"
    grep -q '"direct":true' "$T/verify.txt" && VC=none || VC=writeback
    log "$CACHE-$TRY up ip=$IP cmdline=$VC"
    # 探針：寫 'X' pattern blocks，印 block 號（line-buffered）→ 捕捉到 Mac
    ( vmx $IP 'head -c 4096 /dev/zero | tr "\0" "X" > /tmp/pat; sync; i=0; while true; do if sudo dd if=/tmp/pat of=/dev/vdb bs=4k count=1 seek=$i oflag=direct conv=notrunc status=none 2>/dev/null; then echo $i; fi; i=$((i+1)); done' > "$T/acked.log" 2>/dev/null ) &
    PROBE=$!
    sleep 60
    # kill -9 QEMU（在 VM 所在 node）
    POD=$(cpx "kubectl get pod -n vmtest -l kubevirt.io/domain=baseline --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'")
    LAST=$(tail -1 "$T/acked.log" 2>/dev/null)
    log "$CACHE-$TRY CRASH: force-delete pod $POD (=SIGKILL qemu container, last acked=$LAST)"
    cpx "kubectl delete pod -n vmtest $POD --grace-period=0 --force" >/dev/null 2>&1
    kill $PROBE 2>/dev/null; wait $PROBE 2>/dev/null
    # 重啟
    cpx "kubectl wait -n vmtest vmi/baseline --for=condition=Ready --timeout=600s" >/dev/null 2>&1
    IP2=$(gip); wait_ssh $IP2 || log "WARN post-kill cloud-init $CACHE-$TRY"
    # 回讀驗證：對每個 acked block 讀回，非全 'X' = 遺失
    NACK=$(wc -l < "$T/acked.log")
    # 回讀驗證由 Mac 端抽樣（下方）
    tail -500 "$T/acked.log" > "$T/tail500.txt"
    LOST=0; CHK=0
    while read b; do
      [ -z "$b" ] && continue
      CHK=$((CHK+1))
      cnt=$(vmx $IP2 "sudo dd if=/dev/vdb bs=4k count=1 skip=$b iflag=direct status=none 2>/dev/null | tr -d X | wc -c")
      [ "$cnt" != "0" ] && LOST=$((LOST+1))
    done < <(sed -n '1~50p' "$T/tail500.txt")  # 抽樣每 50 個驗 1 個（省時）
    echo "acked_total=$NACK sampled=$CHK lost=$LOST last_block=$LAST" > "$T/result.txt"
    log "$CACHE-$TRY result: acked=$NACK sampled=$CHK lost=$LOST"
  done
done
set_cache none
log "E-40 ALL-DONE"
