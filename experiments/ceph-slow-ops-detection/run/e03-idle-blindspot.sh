#!/usr/bin/env bash
# SCENARIO: e03-idle-blindspot（H-017 無 IO 即無偵測）
# PREDICTION:
#   signal: 4× slow counter（全 OSD）、SLOW_OPS 兩路
#   expected: 叢集無 client 負載時 suspend osd.0 device 15s → 觀察窗內
#             counter 增量 == 0 且 SLOW_OPS == 0（背景 IO 例外需記錄來源）
#   window: 注入前 60s ~ 注入後 +120s
# BASELINE: HEALTH_OK（豁免 BLUESTORE_SLOW_OP_ALERT）、9 up、無 rados bench 在跑
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
  bundle_init e03-idle-blindspot
  pre_check "${EXEMPT}"
  lab_ssh "${ADMIN_HOST}" 'pgrep -x rados >/dev/null' \
    && die "rados bench is running; e03 requires an idle cluster"
  baseline_capture
  bundle_clock_skew "${OSD_HOST}"

  DM=$(osd_dm "${OSD_HOST}" 0)
  [ -n "${DM}" ] || die "cannot resolve osd.0 dm device"

  local t0 ts_start ts_end t_end
  t0=$(remote_epoch "${ADMIN_HOST}")
  ts_start=$(remote_epoch "${OSD_HOST}")
  log "idle suspend 15s on ${DM}"
  lab_ssh "${OSD_HOST}" "sudo sh -c 'dmsetup suspend ${DM}; sleep 15; dmsetup resume ${DM}'"
  ts_end=$(remote_epoch "${OSD_HOST}")
  rollback
  bundle_note "idle suspend: ${ts_start} .. ${ts_end}"

  log "settle 120s ..."
  sleep 120
  t_end=$(remote_epoch "${ADMIN_HOST}")

  collect_std "$((t0 - 60))" "${t_end}"

  # ---- verdicts ----
  check "h017_no_counter_delta" le "$(pj delta_first_last "${BUNDLE}/raw-slow-counters.json")" 0
  check "h017_no_slowops"       le "$(max_or_zero "${BUNDLE}/slowops-daemon.json")" 0
  check "h017_no_r1"            le "$(max_or_zero "${BUNDLE}/r1-all.json")" 0

  assert_health "${EXEMPT}"
  emit_verdict
}

main "$@"
