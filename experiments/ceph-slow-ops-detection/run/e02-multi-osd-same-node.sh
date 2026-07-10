#!/usr/bin/env bash
# SCENARIO: e02-multi-osd-same-node（H-004/H-022 firmware/RAID 卡指紋）
# PREDICTION:
#   signal: R2 = count by (instance)(per-OSD slow increase[2m] > 0)
#   expected: 同 node 3 顆 OSD 同秒 suspend 8s → R2 於注入後 ≤130s 內 == 3，
#             series 僅 instance="ceph-lab-osd-01" 一條
#   window: 注入前 60s ~ 注入後 +180s
# BASELINE: HEALTH_OK（豁免 BLUESTORE_SLOW_OP_ALERT）、9 up
# PRE-CHECK: pre_check；8s < osd heartbeat grace(20s) → 不會觸發 down
# ROLLBACK: dmsetup resume ×3（以 dm state 驗證）
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

EXEMPT='BLUESTORE_SLOW_OP_ALERT'
OSD_HOST="192.168.18.169"
DM0=""; DM1=""; DM2=""

rollback() {
  local d
  for d in "${DM0}" "${DM1}" "${DM2}"; do
    [ -n "${d}" ] && ensure_dm_active "${OSD_HOST}" "${d}"
  done
}
trap rollback EXIT

main() {
  bundle_init e02-multi-osd-same-node
  pre_check "${EXEMPT}"
  baseline_capture
  bundle_clock_skew "${OSD_HOST}"
  ensure_bench_pool
  wait_quiet

  DM0=$(osd_dm "${OSD_HOST}" 0)
  DM1=$(osd_dm "${OSD_HOST}" 1)
  DM2=$(osd_dm "${OSD_HOST}" 2)
  log "devices: osd.0=${DM0} osd.1=${DM1} osd.2=${DM2}"
  [ -n "${DM0}" ] && [ -n "${DM1}" ] && [ -n "${DM2}" ] || die "cannot resolve dm devices"

  local t0 ts_start ts_end t_end
  t0=$(remote_epoch "${ADMIN_HOST}")
  log "bench write 90s, simultaneous 3-dev suspend at +20s"
  bench_write 90 4 512K
  sleep 20
  ts_start=$(remote_epoch "${OSD_HOST}")
  # 同秒注入：單一遠端 shell，三個 suspend 背景化後 wait —— 模擬 RAID 卡/firmware
  # 同時凍住多顆碟
  lab_ssh "${OSD_HOST}" "sudo sh -c 'dmsetup suspend ${DM0} & dmsetup suspend ${DM1} & dmsetup suspend ${DM2} & wait; sleep 8; dmsetup resume ${DM0}; dmsetup resume ${DM1}; dmsetup resume ${DM2}'"
  ts_end=$(remote_epoch "${OSD_HOST}")
  rollback
  bundle_note "3-dev suspend: ${ts_start} .. ${ts_end}"
  bench_wait_done
  bench_collect_logs
  lab_ssh "${ADMIN_HOST}" "sudo rados -p ${BENCH_POOL} cleanup" >&2 || true

  log "settle 90s ..."
  sleep 90
  t_end=$(remote_epoch "${ADMIN_HOST}")

  collect_std "$((t0 - 60))" "${t_end}"
  # 注入後窗（alert 層歸因用；全窗 r2.json 保留當 context）
  prom_range "$(r2_expr)" "${ts_start}" "${t_end}" 5 "${BUNDLE}/r2-postinject.json"
  local i
  for i in 0 1 2; do
    prom_range "$(slow_raw_expr ",ceph_daemon=\"osd.${i}\"")" "$((t0 - 60))" "${t_end}" 5 \
      "${BUNDLE}/raw-slow-osd${i}.json"
  done

  # ---- verdicts（一律用注入後窗，避免上一場景殘留污染歸因）----
  # H-004: 注入後 R2 count 達 3（同 node 全部 3 顆都被抓到）
  check "h004_r2_reaches_3" ge "$(max_or_zero "${BUNDLE}/r2-postinject.json")" 3
  # H-004: R2 第一次達 3 ≤ 注入結束 +130s（2m 窗 + exporter 5s + scrape 10s）
  check "h004_r2_within_130s" le "$(pj first_ts_gt "${BUNDLE}/r2-postinject.json" 2)" "$((ts_end + 130))"
  # H-022: 達到 alert 門檻（≥3）的 instance 恰好一台（= 指紋不跨 node 誤報）
  check "h022_single_instance_ge3" eq "$(pj count_series_max_ge "${BUNDLE}/r2-postinject.json" 3)" 1
  # 三顆 OSD「各自」都有 counter 增量
  for i in 0 1 2; do
    check "h004_osd${i}_delta" ge "$(pj delta_first_last "${BUNDLE}/raw-slow-osd${i}.json")" 1
  done

  assert_health "${EXEMPT}"
  emit_verdict
}

main "$@"
