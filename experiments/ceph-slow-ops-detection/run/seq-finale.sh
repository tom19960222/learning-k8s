#!/usr/bin/env bash
# SCENARIO: seq-finale（H-008 latch 清除 + H-020 counter reset 不假陽性 + 全域善後）
# PREDICTION:
#   signal: ceph_health_detail{name="BLUESTORE_SLOW_OP_ALERT"}、R1、raw counters
#   expected:
#     - 依序 restart osd-01 上的 osd.0/1/2 後：latch 於 10 分鐘內清除（H-008 後半）
#     - osd.0 counter 歸 0（in-memory queue/counter 隨 daemon 重啟消失）
#     - restart 後 4 分鐘觀察窗內 R1 不為真（increase 對 reset 不產生假陽性，H-020）
#   window: restart 前 60s ~ restart 後 +300s
# BASELINE: 實驗序列尾態（預期帶 BLUESTORE_SLOW_OP_ALERT latch）
# ROLLBACK: 本身就是善後（bench pool 刪除、mon_allow_pool_delete 還原 false）
# ASSERT: 最終 HEALTH_OK（無豁免）
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

main() {
  bundle_init seq-finale
  # 序列尾態允許 latch 存在
  pre_check 'BLUESTORE_SLOW_OP_ALERT'
  baseline_capture

  local t0 t_end i
  t0=$(remote_epoch "${ADMIN_HOST}")

  # ---- 依序 restart osd.0/1/2（等 up 才做下一顆）----
  for i in 0 1 2; do
    ceph_admin ceph osd ok-to-stop "osd.${i}" >&2 || die "osd.${i} not ok-to-stop"
    log "restarting osd.${i} ..."
    ceph_admin ceph orch daemon restart "osd.${i}" >&2
    local tries=0
    sleep 15
    while ! ceph_admin ceph osd tree | grep -E "^ *${i} " | grep -q up; do
      tries=$((tries + 1))
      [ "${tries}" -gt 30 ] && die "osd.${i} did not come back up"
      sleep 10
    done
    log "osd.${i} is up"
  done

  # ---- latch 清除觀察（≤10min）----
  local tries=0 latch_cleared=0
  while [ "${tries}" -lt 60 ]; do
    if ! ceph_admin ceph health detail | grep -q BLUESTORE_SLOW_OP_ALERT; then
      latch_cleared=1
      break
    fi
    tries=$((tries + 1))
    sleep 10
  done
  bundle_note "latch_cleared=${latch_cleared} after ~$((tries * 10))s"

  log "settle 240s for the H-020 no-false-positive window ..."
  sleep 240
  t_end=$(remote_epoch "${ADMIN_HOST}")

  collect_std "$((t0 - 60))" "${t_end}"

  # ---- verdicts ----
  check "h008_latch_clears_on_restart" eq "${latch_cleared}" 1
  # counter reset：osd.0 現值 == 0
  prom_instant "$(slow_raw_expr ',ceph_daemon="osd.0"')" "${BUNDLE}/counters-post-restart.json"
  check "h020_counter_reset_to_zero" le "$(pj last_val "${BUNDLE}/counters-post-restart.json")" 0
  # H-020: restart 之後（+60s 起，排除 restart 前殘留窗）R1 不為真
  prom_range "$(slow_sum_expr 1m)" "$((t0 + 60))" "${t_end}" 5 "${BUNDLE}/r1-post-restart.json"
  check "h020_no_fp_after_reset" le "$(max_or_zero "${BUNDLE}/r1-post-restart.json")" 0

  # ---- 善後：刪 bench pool（雙開關），還原設定 ----
  if ceph_admin ceph osd pool ls | grep -qx "${BENCH_POOL}"; then
    ceph_admin ceph config set mon mon_allow_pool_delete true >&2
    ceph_admin ceph osd pool delete "${BENCH_POOL}" "${BENCH_POOL}" --yes-i-really-really-mean-it >&2
    ceph_admin ceph config set mon mon_allow_pool_delete false >&2
    log "bench pool deleted, mon_allow_pool_delete restored to false"
  fi

  # 最終 assert：完全 HEALTH_OK，無豁免
  assert_health
  ceph_admin ceph -s > "${BUNDLE}/final-ceph-s.txt" 2>&1
  emit_verdict
}

main "$@"
