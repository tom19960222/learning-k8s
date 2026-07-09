#!/usr/bin/env bash
# SCENARIO: e01-single-osd-transient（H-001/002/003/006/007/008/010/011）
# PREDICTION:
#   signal: ceph_bluestore_slow_*_count{osd.0}、R1 表達式、SLOW_OPS 兩路、
#           BLUESTORE_SLOW_OP_ALERT、ceph_osd_commit_latency_ms、op_w 區間均值
#   expected:
#     - 寫負載下 dm suspend 8s：counter 增量 ≥1（H-002），且第一個增量樣本
#       不早於 suspend 結束（H-011：完成時才記帳）
#     - R1 第一次可判真 ≤ suspend 結束 +30s（H-003）
#     - SLOW_OPS 兩路全程 0（H-001）
#     - commit_latency_ms 峰值 < 5000ms（H-006 暫態抓不到量級）
#     - op_w 均值峰值 ≥ 1s（H-007）
#     - BLUESTORE_SLOW_OP_ALERT 於事件後出現（H-008 latch onset）
#     - 讀負載下 suspend 8s：slow_read_* 增量 ≥1（H-010）
#   window: 注入前 60s ~ 第二次注入後 +120s
# BASELINE: HEALTH_OK（豁免 BLUESTORE_SLOW_OP_ALERT）、9 up
# PRE-CHECK: pre_check；rollback = dmsetup resume（以 dm state 驗證）
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

EXEMPT='BLUESTORE_SLOW_OP_ALERT'
OSD_HOST="192.168.18.169"
DM=""

rollback() {
  [ -n "${DM}" ] && ensure_dm_active "${OSD_HOST}" "${DM}"
}
trap rollback EXIT

suspend_for() {
  # suspend_for SECONDS — one remote round-trip so the pause length is not
  # subject to a second ssh handshake latency.
  lab_ssh "${OSD_HOST}" "sudo sh -c 'dmsetup suspend ${DM}; sleep $1; dmsetup resume ${DM}'"
}

main() {
  bundle_init e01-single-osd-transient
  pre_check "${EXEMPT}"
  baseline_capture
  bundle_clock_skew "${OSD_HOST}"
  ensure_bench_pool

  DM=$(osd_dm "${OSD_HOST}" 0)
  log "osd.0 device: ${DM}"
  [ -n "${DM}" ] || die "cannot resolve osd.0 dm device"

  local t0 tw_start tw_end tr_start tr_end t_end
  t0=$(remote_epoch "${ADMIN_HOST}")

  # ---- phase W: write load + 8s suspend ----
  log "phase W: bench write 100s, suspend at +20s"
  bench_write 100 16
  sleep 20
  tw_start=$(remote_epoch "${OSD_HOST}")
  suspend_for 8
  tw_end=$(remote_epoch "${OSD_HOST}")
  ensure_dm_active "${OSD_HOST}" "${DM}"
  bundle_note "W-phase suspend: ${tw_start} .. ${tw_end}"
  bench_wait_done

  # ---- phase R: seq read load + 8s suspend ----
  log "phase R: bench seq 60s, suspend at +15s"
  bench_seq 60 16
  sleep 15
  tr_start=$(remote_epoch "${OSD_HOST}")
  suspend_for 8
  tr_end=$(remote_epoch "${OSD_HOST}")
  ensure_dm_active "${OSD_HOST}" "${DM}"
  bundle_note "R-phase suspend: ${tr_start} .. ${tr_end}"
  bench_wait_done
  bench_collect_logs
  lab_ssh "${ADMIN_HOST}" "sudo rados -p ${BENCH_POOL} cleanup" >&2 || true

  log "settle 90s for scrapes + health propagation ..."
  sleep 90
  t_end=$(remote_epoch "${ADMIN_HOST}")

  # ---- collect（bundle 先於任何 cleanup）----
  collect_std "$((t0 - 60))" "${t_end}"
  prom_range "$(slow_raw_expr ',ceph_daemon="osd.0"')" "$((tw_start - 30))" "$((tw_end + 60))" 5 \
    "${BUNDLE}/raw-slow-osd0-wphase.json"
  prom_range 'sum by (ceph_daemon) ({__name__=~"ceph_bluestore_slow_read_(onode_meta|wait_aio)_count",ceph_daemon="osd.0"})' \
    "$((tr_start - 30))" "$((tr_end + 90))" 5 "${BUNDLE}/raw-slowread-osd0-rphase.json"

  # ---- verdicts ----
  # H-002: 整個窗內 osd.0 counter 增量 ≥ 1
  check "h002_counter_delta" ge "$(pj delta_first_last "${BUNDLE}/raw-slow-osd0.json")" 1
  # H-011: 第一個 counter 上升樣本不得早於 suspend 結束（-6s 容忍 scrape 相位 + 時鐘偏移）
  local base first_rise
  base=$(pj last_val "${BUNDLE}/baseline-slow-counters.json")
  [ "${base}" = "none" ] && base=0
  first_rise=$(pj first_ts_gt "${BUNDLE}/raw-slow-osd0-wphase.json" "${base}")
  check "h011_completion_only" ge "${first_rise}" "$((tw_end - 6))"
  # H-003: R1 第一次可判真 ≤ tw_end + 30
  local r1_first
  r1_first=$(pj first_ts_gt "${BUNDLE}/r1-osd0.json" 0)
  check "h003_r1_within_30s" le "${r1_first}" "$((tw_end + 30))"
  # H-001: SLOW_OPS 兩路全程 0
  check "h001_daemon_slowops_zero" le "$(max_or_zero "${BUNDLE}/slowops-daemon.json")" 0
  check "h001_health_slowops_zero" le "$(max_or_zero "${BUNDLE}/slowops-health.json")" 0
  # H-006: 暫態事件 commit_latency_ms 峰值 < 5000
  check "h006_gauge_misses_transient" lt "$(max_or_zero "${BUNDLE}/commit-latency-osd0.json")" 5000
  # H-007: op_w 區間均值峰值 ≥ 1s
  check "h007_opw_mean_spike" ge "$(max_or_zero "${BUNDLE}/opw-mean-osd0.json")" 1
  # H-008: BLUESTORE_SLOW_OP_ALERT 出現
  check "h008_latch_appears" ne "$(pj first_ts_gt "${BUNDLE}/bluestore-alert.json" 0)" none
  # H-010: 讀路徑 counter 增量 ≥ 1
  check "h010_read_counter" ge "$(pj delta_first_last "${BUNDLE}/raw-slowread-osd0-rphase.json")" 1
  # H-004 對照組：單 OSD 事件不得觸發 R2
  check "h004_no_r2_single_osd" le "$(max_or_zero "${BUNDLE}/r2.json")" 2

  rollback
  assert_health "${EXEMPT}"
  emit_verdict
}

main "$@"
