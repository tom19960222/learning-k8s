#!/usr/bin/env bash
# SCENARIO: e04-sustained-throttle（H-005/006/007/009/021 + R1 vs R3 vs 舊規則延遲對決）
# PREDICTION:
#   signal: ceph_daemon_health_metrics{type="SLOW_OPS",osd.0}、R1、
#           ceph_osd_commit_latency_ms、node_disk io_time_weighted、ceph_disk_occupation
#   expected:
#     - io.max wiops=8 節流 150s（寫負載持續）→ SLOW_OPS 第一次 >0 落在
#       [T_inj+35, T_inj+90]（30s complaint + OSD→mgr→module→scrape 傳播）（H-005）
#     - R1 第一次可判真 < SLOW_OPS 第一次出現（counter 路徑更快）（H-003/005 對照）
#     - commit_latency_ms 峰值 ≥ 1000（持續事件 gauge 看得到）（H-006）
#     - op_w 均值 ≥ 1s（H-007）
#     - node_disk io_time_weighted rate（osd-01）節流中峰值 ≥ 注入前峰值 ×5（H-009）
#     - ceph_disk_occupation{ceph_daemon="osd.0"} series 存在（H-021 join 可行）
#   window: 注入前 120s ~ 解除後 +120s
# BASELINE: HEALTH_OK（豁免 BLUESTORE_SLOW_OP_ALERT）、9 up
# PRE-CHECK: pre_check + ok-to-stop osd.0（最壞情況＝該 OSD 實質停擺，先確認可承受）
# ROLLBACK: io.max 恢復 max（以 io.max 內容驗證）；SLOW_OPS 需自然排空後 HEALTH_OK
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

EXEMPT='BLUESTORE_SLOW_OP_ALERT'
OSD_HOST="192.168.18.169"
MAJMIN=""

rollback() {
  [ -n "${MAJMIN}" ] && ensure_io_unlimited "${OSD_HOST}" 0 "${MAJMIN}"
}
trap rollback EXIT

main() {
  bundle_init e04-sustained-throttle
  pre_check "${EXEMPT}"
  ceph_admin ceph osd ok-to-stop osd.0 >&2 || die "osd.0 not ok-to-stop"
  baseline_capture
  bundle_clock_skew "${OSD_HOST}"
  ensure_bench_pool

  local dm majnum minnum
  dm=$(osd_dm "${OSD_HOST}" 0)
  [ -n "${dm}" ] || die "cannot resolve osd.0 dm device"
  majnum=$(lab_ssh "${OSD_HOST}" "stat -c '%Hr' ${dm}")
  minnum=$(lab_ssh "${OSD_HOST}" "stat -c '%Lr' ${dm}")
  MAJMIN="${majnum}:${minnum}"
  log "osd.0 device ${dm} = ${MAJMIN}"

  local t0 t_inj t_rel t_end
  t0=$(remote_epoch "${ADMIN_HOST}")
  log "bench write 300s, throttle at +30s for 150s"
  bench_write 300 16
  sleep 30
  t_inj=$(remote_epoch "${OSD_HOST}")
  io_max_set "${OSD_HOST}" 0 "${MAJMIN}" "wiops=8"
  log "io.max now: $(io_max_get "${OSD_HOST}" 0)"
  sleep 150
  t_rel=$(remote_epoch "${OSD_HOST}")
  rollback
  bundle_note "throttle window: ${t_inj} .. ${t_rel} (${MAJMIN} wiops=8)"

  log "waiting for bench to drain + settle ..."
  bench_wait_done
  bench_collect_logs
  lab_ssh "${ADMIN_HOST}" "sudo rados -p ${BENCH_POOL} cleanup" >&2 || true
  sleep 90
  t_end=$(remote_epoch "${ADMIN_HOST}")

  collect_std "$((t0 - 120))" "${t_end}"
  prom_instant 'ceph_disk_occupation{ceph_daemon="osd.0"}' "${BUNDLE}/disk-occupation-osd0.json"
  prom_range 'rate(node_disk_io_time_weighted_seconds_total{instance="ceph-lab-osd-01"}[1m])' \
    "$((t0 - 120))" "$((t_inj - 5))" 5 "${BUNDLE}/node-disk-preinject.json"
  prom_range 'rate(node_disk_io_time_weighted_seconds_total{instance="ceph-lab-osd-01"}[1m])' \
    "${t_inj}" "${t_rel}" 5 "${BUNDLE}/node-disk-throttled.json"
  prom_range 'ceph_daemon_health_metrics{type="SLOW_OPS",ceph_daemon="osd.0"}' \
    "$((t0 - 120))" "${t_end}" 5 "${BUNDLE}/slowops-osd0.json"

  # ---- verdicts ----
  local t_slowops t_r1
  t_slowops=$(pj first_ts_gt "${BUNDLE}/slowops-osd0.json" 0)
  t_r1=$(pj first_ts_gt "${BUNDLE}/r1-osd0.json" 0)
  bundle_note "t_inj=${t_inj} t_r1=${t_r1} t_slowops=${t_slowops}"
  # H-005: SLOW_OPS 出現時刻窗
  check "h005_slowops_after_35s"  ge "${t_slowops}" "$((t_inj + 35))"
  check "h005_slowops_before_90s" le "${t_slowops}" "$((t_inj + 90))"
  # R1 比 SLOW_OPS 快
  check "h005_r1_beats_slowops" lt "${t_r1}" "${t_slowops}"
  # R1 絕對延遲：注入後 ≤ 45s 可判真
  check "h003_r1_within_45s_sustained" le "${t_r1}" "$((t_inj + 45))"
  # H-006: 持續事件 gauge 有反應
  check "h006_gauge_sees_sustained" ge "$(max_or_zero "${BUNDLE}/commit-latency-osd0.json")" 1000
  # H-007: op_w 均值 ≥ 1s
  check "h007_opw_mean_sustained" ge "$(max_or_zero "${BUNDLE}/opw-mean-osd0.json")" 1
  # H-009: node_disk 節流中 ≥ 注入前 ×5
  local pre_max thr_max ratio_ok
  pre_max=$(max_or_zero "${BUNDLE}/node-disk-preinject.json")
  thr_max=$(max_or_zero "${BUNDLE}/node-disk-throttled.json")
  ratio_ok=$(python3 -c "print(1 if float('${thr_max}') >= 5*max(float('${pre_max}'), 0.001) else 0)")
  check "h009_node_disk_ratio" eq "${ratio_ok}" 1
  bundle_note "node_disk pre_max=${pre_max} throttled_max=${thr_max}"
  # H-021: disk occupation join 存在
  check "h021_disk_occupation" ge "$(pj series_count "${BUNDLE}/disk-occupation-osd0.json")" 1

  assert_health "${EXEMPT}"
  emit_verdict
}

main "$@"
