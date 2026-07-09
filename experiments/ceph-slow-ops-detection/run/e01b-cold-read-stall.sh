#!/usr/bin/env bash
# SCENARIO: e01b-cold-read-stall（H-010 讀路徑 counter，修正 e01 的 cache 汙染）
# e01 的讀段零增量：512K×589 物件全在 BlueStore cache，讀沒碰到被 suspend 的碟。
# 此場景先灌資料（4M×16t，counter 噪音無妨——只對讀窗下 verdict），restart osd.0
# 清 cache + 清 counter，再對冷資料 seq read + suspend。
# PREDICTION:
#   signal: ceph_bluestore_slow_read_{onode_meta,wait_aio}_count{osd.0}
#   expected: 冷讀 + 8s suspend → slow_read_* 增量 ≥ 1（讀窗內）
#   window: restart 完成後 ~ 讀 bench 結束 +90s
# BASELINE: HEALTH_OK（豁免 BLUESTORE_SLOW_OP_ALERT）、9 up
# PRE-CHECK: pre_check + ok-to-stop osd.0（restart 需要）
# ROLLBACK: dmsetup resume（以 dm state 驗證）
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

EXEMPT='BLUESTORE_SLOW_OP_ALERT'
OSD_HOST="192.168.18.169"
DM=""

rollback() {
  [ -n "${DM}" ] && ensure_dm_active "${OSD_HOST}" "${DM}"
}
trap rollback EXIT

main() {
  bundle_init e01b-cold-read-stall
  pre_check "${EXEMPT}"
  baseline_capture
  bundle_clock_skew "${OSD_HOST}"
  ensure_bench_pool

  DM=$(osd_dm "${OSD_HOST}" 0)
  [ -n "${DM}" ] || die "cannot resolve osd.0 dm device"

  # ---- fill：大物件快速灌資料（噪音無妨，不在此窗 verdict）----
  log "fill: bench write 60s 4M x16 (noise ok)"
  bench_write 60 16 4M
  bench_wait_done

  # ---- restart osd.0 清 BlueStore cache + counter ----
  ceph_admin ceph osd ok-to-stop osd.0 >&2 || die "osd.0 not ok-to-stop"
  ceph_admin ceph orch daemon restart osd.0 >&2
  local tries=0
  sleep 15
  while ! ceph_admin ceph osd tree | grep -E '^ *0 ' | grep -q up; do
    tries=$((tries + 1))
    [ "${tries}" -gt 30 ] && die "osd.0 did not come back up"
    sleep 10
  done
  log "osd.0 back up; wait for peering to settle"
  sleep 30
  # DM 可能因 restart 重新對應（LVM 不會變，但保險重解析）
  DM=$(osd_dm "${OSD_HOST}" 0)

  # ---- 冷讀 + suspend ----
  local t0 ts_start ts_end t_end
  t0=$(remote_epoch "${ADMIN_HOST}")
  log "cold seq read 60s, suspend at +10s"
  bench_seq 60 4
  sleep 10
  ts_start=$(remote_epoch "${OSD_HOST}")
  lab_ssh "${OSD_HOST}" "sudo sh -c 'dmsetup suspend ${DM}; sleep 8; dmsetup resume ${DM}'"
  ts_end=$(remote_epoch "${OSD_HOST}")
  rollback
  bundle_note "cold-read suspend: ${ts_start} .. ${ts_end}"
  bench_wait_done
  bench_collect_logs
  lab_ssh "${ADMIN_HOST}" "sudo rados -p ${BENCH_POOL} cleanup" >&2 || true

  log "settle 60s ..."
  sleep 60
  t_end=$(remote_epoch "${ADMIN_HOST}")

  collect_std "$((t0 - 30))" "${t_end}"
  prom_range 'sum by (ceph_daemon) ({__name__=~"ceph_bluestore_slow_read_(onode_meta|wait_aio)_count",ceph_daemon="osd.0"})' \
    "${t0}" "${t_end}" 5 "${BUNDLE}/raw-slowread-osd0.json"

  # ---- verdicts ----
  check "h010_cold_read_counter" ge "$(pj delta_first_last "${BUNDLE}/raw-slowread-osd0.json")" 1

  assert_health "${EXEMPT}"
  emit_verdict
}

main "$@"
