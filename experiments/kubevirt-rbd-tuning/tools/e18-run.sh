#!/bin/bash
# E-18 guest readahead 128/512/4096（A 類 runtime）。精簡矩陣：sr-1m / sr4k-qd1 / rr-qd1(對照)
# 用法：bash e18-run.sh <bundle> <guest-ip>
set -u
BUNDLE=$1; GUEST_IP=$2; mkdir -p "$BUNDLE"
CP=azureuser@20.89.248.121
KEY=$HOME/.ssh/azure-lab
SSHO="-i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
log(){ echo "$(date -u +%s) $*" | tee -a "$BUNDLE/orchestrator.log"; }
vmx(){ ssh $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" ubuntu@$GUEST_IP "$@"; }
vmx 'cat > /home/ubuntu/mini_matrix.sh << "EOF"
#!/bin/bash
OUT=$1; mkdir -p $OUT
run(){ sudo fio --name=$1 --filename=/dev/vdb --direct=1 --ioengine=libaio \
  --rw=$2 --bs=$3 --iodepth=$4 --numjobs=1 --time_based --runtime=60 \
  --ramp_time=15 --randseed=8675309 --group_reporting \
  --output-format=json --output=$OUT/fio-$1.json > /dev/null; }
run sr-1m    read     1M 16
run sr4k-qd1 read     4k 1
run rr-qd1   randread 4k 1
EOF
cat /sys/block/vdb/queue/read_ahead_kb' > "$BUNDLE/ra-default.txt"
log "default read_ahead_kb: $(tail -1 $BUNDLE/ra-default.txt)"
for N in 1 2 3; do
  for RA in 128 512 4096; do
    D="round-$N-ra$RA"
    if [ -d "$BUNDLE/$D" ] && [ "$(ls "$BUNDLE/$D"/fio-*.json 2>/dev/null | wc -l | tr -d ' ')" = "3" ]; then log "skip $D"; continue; fi
    vmx "echo $RA | sudo tee /sys/block/vdb/queue/read_ahead_kb >/dev/null"
    cur=$(vmx 'cat /sys/block/vdb/queue/read_ahead_kb')
    [ "$cur" = "$RA" ] || { log "FATAL verify ra=$RA got $cur"; exit 1; }
    vmx "rm -rf /home/ubuntu/m && bash mini_matrix.sh /home/ubuntu/m" || { log "FATAL fio $D"; exit 1; }
    mkdir -p "$BUNDLE/$D"
    scp -q $SSHO -o ProxyCommand="ssh $SSHO -W %h:%p $CP" -r "ubuntu@[$GUEST_IP]:/home/ubuntu/m/*" "$BUNDLE/$D/"
    log "round $D done"
  done
done
DEF=$(tail -1 "$BUNDLE/ra-default.txt" | tr -d '[:space:]')
vmx "echo $DEF | sudo tee /sys/block/vdb/queue/read_ahead_kb >/dev/null"
log "restored to $DEF"
log "E-18 ALL-DONE"
