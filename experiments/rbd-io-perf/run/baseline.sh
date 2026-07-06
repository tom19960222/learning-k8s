#!/usr/bin/env bash
# E-03: create the test VM with PVE defaults, prefill, run the matrix
# BASELINE_ROUNDS times, emit per-pattern noise (CoV).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/rbdimg.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"
# shellcheck disable=SC1091
. "$here/../lib/scenarios.sh"
require_inject_flag "$@"

ROUNDS="${BASELINE_ROUNDS:-5}"
CLOUDIMG="${CLOUDIMG:-/mnt/pve/cephfs/template/iso/noble-server-cloudimg-amd64.img}"

pve_ssh "ls $CLOUDIMG" >/dev/null 2>&1 || die "cloud image 不存在: ${CLOUDIMG}（下載: wget -O ${CLOUDIMG} https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img）"

b="$(new_bundle baseline)"
write_prediction "$b" "E-03: 量噪音帶（CoV）與虛擬化稅占比（H-003 無先驗預測）。guest /sys/block/vdb/mq 預期 = vCPU 數（H-026）。"

pve_ssh 'cat > /home/ioperf/ioperf.pub' < "$SSH_KEY.pub"
vm_create "$CLOUDIMG" /home/ioperf/ioperf.pub
vm_attach_data "$POOL:16"
vm_cold_restart
ip="$(vm_guest_ip)"
log "guest ip: $ip"

guest_ssh "$ip" 'which fio >/dev/null 2>&1 || (sudo apt-get update -qq && sudo apt-get install -y -qq fio)' >/dev/null
guest_ssh "$ip" 'which iostat >/dev/null 2>&1 || sudo apt-get install -y -qq sysstat' >/dev/null

vm_config > "$b/qm-config.txt"
vm_cmdline > "$b/qemu-cmdline.txt"
guest_ssh "$ip" 'ls /sys/block/vdb/mq/' > "$b/guest-mq.txt" || true

log "prefill guest /dev/vdb"
guest_ssh "$ip" "sudo $(prefill_cmd /dev/vdb)" > "$b/prefill.json"

run_matrix_rounds "$b" base "$ip" /dev/vdb "$ROUNDS"

# per-pattern noise
: > "$b/noise.json"
for entry in $FIO_PATTERNS; do
  name="${entry%%:*}"
  files=""
  for r in $(seq 1 "$ROUNDS"); do
    # tainted rounds land in base-r<N>-retry; pick up whichever attempt survived
    for f in "$b/base-r$r/$name.json" "$b/base-r$r-retry/$name.json"; do
      [ -s "$f" ] && files="$files $f"
    done
  done
  if [ -z "$files" ]; then
    log "警示: pattern ${name} 無有效輪次，noise.json 略過該點"
    continue
  fi
  # shellcheck disable=SC2086  # word-splitting files list is intended
  s="$(python3 "$RBDPERF_ROOT/lib/verdict.py" summarize $files)"
  printf '{"pattern": "%s", "summary": %s}\n' "$name" "$s" >> "$b/noise.json"
done

printf '%s\n' "$b"
