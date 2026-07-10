#!/usr/bin/env bash
# SCENARIO: e00-negative-control（H-015 負向對照）
# PREDICTION:
#   signal: sum(4× ceph_bluestore_slow_*_count) 全 OSD、ceph_daemon_health_metrics{type="SLOW_OPS"}
#   expected: 全速 rados bench（write 90s + seq 60s）期間與之後，slow counter 增量 == 0、SLOW_OPS == 0
#   window: bench 開始前 60s ~ 結束後 60s
# BASELINE: HEALTH_OK（或僅 BLUESTORE_SLOW_OP_ALERT 豁免）、9 osd up
# PRE-CHECK: pre_check；無注入 → 無 rollback（rollback 段為 no-op）
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

EXEMPT='BLUESTORE_SLOW_OP_ALERT'

main() {
  bundle_init e00-negative-control
  pre_check "${EXEMPT}"
  baseline_capture
  bundle_clock_skew 192.168.18.169
  ensure_bench_pool

  local t0 t_end
  t0=$(remote_epoch "${ADMIN_HOST}")
  log "bench write 90s ..."
  bench_write 90 16
  bench_wait_done
  log "bench seq 60s ..."
  bench_seq 60 16
  bench_wait_done
  bench_collect_logs
  lab_ssh "${ADMIN_HOST}" "sudo rados -p ${BENCH_POOL} cleanup" >&2 || true

  log "settle 45s for scrapes ..."
  sleep 45
  t_end=$(remote_epoch "${ADMIN_HOST}")

  collect_std "$((t0 - 60))" "${t_end}"

  # verdict
  check "h015_no_counter_delta" le "$(pj delta_first_last "${BUNDLE}/raw-slow-counters.json")" 0
  check "h015_no_slowops"       le "$(max_or_zero "${BUNDLE}/slowops-daemon.json")" 0
  check "h015_no_r1"            le "$(max_or_zero "${BUNDLE}/r1-all.json")" 0

  assert_health "${EXEMPT}"
  emit_verdict
}

main "$@"
