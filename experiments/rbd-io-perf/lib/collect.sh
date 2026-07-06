#!/usr/bin/env bash
# Cluster/host observation, taint detection and courtesy guardrails.
# Requires lib/common.sh to be sourced first.

collect_ceph_status() {
  pve_ssh 'sudo -n ceph -s' > "$1"
}

taint_check() {
  if grep -qiE 'recovery|backfill|degraded' "$1"; then
    log "taint: 背景 recovery/backfill/degraded 活動"
    return 1
  fi
  return 0
}

guard_check() {
  local cur="$1" base="$2"
  if grep -q 'HEALTH_ERR' "$cur"; then
    die "guardrail: HEALTH_ERR 出現，立即中止（見 ${cur}）"
  fi
  if grep -qi 'slow ops' "$cur" && ! grep -qi 'slow ops' "$base"; then
    die "guardrail: 新增 slow ops（baseline 無），立即中止"
  fi
  return 0
}

collect_dmesg_marker() {
  pve_ssh 'sudo -n dmesg | wc -l' | tr -d '[:space:]'
}

collect_dmesg_delta() {
  local marker="$1" out="$2"
  pve_ssh "sudo -n dmesg | tail -n +$((marker + 1))" > "$out" || true
  if grep -qiE 'bad crc|socket closed' "$out"; then
    log "警示: dmesg 出現 bad crc / socket closed（rxbounce 徵兆，見 ${out}）"
  fi
}

qemu_pid() {
  pve_ssh "sudo -n cat /var/run/qemu-server/$1.pid" | tr -d '[:space:]'
}

sample_iostat_host() {
  local dev="$1" secs="$2" out="$3"
  pve_ssh "iostat -x 1 $secs $dev" > "$out" || true
}

sample_iostat_guest() {
  local ip="$1" dev="$2" secs="$3" out="$4"
  guest_ssh "$ip" "iostat -x 1 $secs $dev" > "$out" || true
}
