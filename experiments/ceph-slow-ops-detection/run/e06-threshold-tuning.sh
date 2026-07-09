#!/usr/bin/env bash
# SCENARIO: e06-threshold-tuning（H-016 bluestore_log_op_age 靈敏度旋鈕）
# PREDICTION:
#   signal: 4× slow counter（osd.0）
#   expected:
#     - a 段（預設 log_op_age=5s）：suspend 3s → counter 增量 == 0（3s < 5s 門檻）
#     - b 段（ceph config set osd.0 bluestore_log_op_age 2，runtime 生效）：
#       suspend 3s → counter 增量 ≥ 1
#   window: 各段注入前 30s ~ 注入後 +60s
# BASELINE: HEALTH_OK（豁免 BLUESTORE_SLOW_OP_ALERT）、9 up
# ROLLBACK: dmsetup resume + ceph config rm（以 ceph tell 讀回值驗證 = 5）
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

EXEMPT='BLUESTORE_SLOW_OP_ALERT'
OSD_HOST="192.168.18.169"
DM=""

rollback() {
  [ -n "${DM}" ] && ensure_dm_active "${OSD_HOST}" "${DM}"
  ceph_admin ceph config rm osd.0 bluestore_log_op_age >&2 || true
  local v
  v=$(ceph_admin "ceph tell osd.0 config get bluestore_log_op_age" | tr -d '\" {}\n' | cut -d: -f2)
  case "${v}" in
    5|5.0*) log "rollback verified: bluestore_log_op_age=${v}" ;;
    *) die "rollback failed: bluestore_log_op_age=${v}" ;;
  esac
}
trap rollback EXIT

instant_osd0_sum() {
  local out="$1"
  prom_instant "$(slow_raw_expr ',ceph_daemon="osd.0"')" "${out}"
  pj last_val "${out}"
}

main() {
  bundle_init e06-threshold-tuning
  pre_check "${EXEMPT}"
  baseline_capture
  bundle_clock_skew "${OSD_HOST}"
  ensure_bench_pool

  DM=$(osd_dm "${OSD_HOST}" 0)
  [ -n "${DM}" ] || die "cannot resolve osd.0 dm device"

  local t0 v_base v_after_a v_after_b
  t0=$(remote_epoch "${ADMIN_HOST}")
  log "bench write 180s (covers both sub-phases)"
  bench_write 180 4 512K
  sleep 15

  # ---- a 段：預設門檻 5s，3s suspend ----
  v_base=$(instant_osd0_sum "${BUNDLE}/counters-a-before.json")
  lab_ssh "${OSD_HOST}" "sudo sh -c 'dmsetup suspend ${DM}; sleep 3; dmsetup resume ${DM}'"
  ensure_dm_active "${OSD_HOST}" "${DM}"
  log "a-phase injected; settle 40s"
  sleep 40
  v_after_a=$(instant_osd0_sum "${BUNDLE}/counters-a-after.json")
  bundle_note "a: base=${v_base} after=${v_after_a}"

  # ---- b 段：門檻降到 2s（runtime），3s suspend ----
  ceph_admin ceph config set osd.0 bluestore_log_op_age 2 >&2
  sleep 10
  ceph_admin "ceph tell osd.0 config get bluestore_log_op_age" > "${BUNDLE}/config-b.json" 2>&1
  grep -q '"2' "${BUNDLE}/config-b.json" || die "runtime config did not reach osd.0: $(cat "${BUNDLE}/config-b.json")"
  lab_ssh "${OSD_HOST}" "sudo sh -c 'dmsetup suspend ${DM}; sleep 3; dmsetup resume ${DM}'"
  ensure_dm_active "${OSD_HOST}" "${DM}"
  log "b-phase injected; settle 40s"
  sleep 40
  v_after_b=$(instant_osd0_sum "${BUNDLE}/counters-b-after.json")
  bundle_note "b: after=${v_after_b}"

  rollback
  bench_wait_done
  bench_collect_logs
  lab_ssh "${ADMIN_HOST}" "sudo rados -p ${BENCH_POOL} cleanup" >&2 || true
  collect_std "$((t0 - 30))" "$(remote_epoch "${ADMIN_HOST}")"

  # ---- verdicts ----
  local da db
  da=$(python3 -c "print(float('${v_after_a}') - float('${v_base}'))")
  db=$(python3 -c "print(float('${v_after_b}') - float('${v_after_a}'))")
  bundle_note "delta_a=${da} delta_b=${db}"
  check "h016_default_blind_to_3s" le "${da}" 0
  check "h016_tuned_sees_3s"       ge "${db}" 1

  assert_health "${EXEMPT}"
  emit_verdict
}

main "$@"
