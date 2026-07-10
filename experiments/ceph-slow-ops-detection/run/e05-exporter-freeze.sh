#!/usr/bin/env bash
# SCENARIO: e05-exporter-freeze（H-013 observer lying/stale）
# PREDICTION:
#   signal: .169:9926/metrics 的 HTTP 行為與 osd.0/osd.1 series 值、up{ceph-exporter}
#   expected: SIGSTOP osd.0（15s，輕負載持續）期間：
#     - exporter /metrics 仍回 200（HTTP 不掛）
#     - osd.0 的 txc_commit_lat_count 凍在舊值（stale），SIGCONT 後恢復上升
#     - Prometheus 對 osd-01 exporter 的 up 全程 == 1（observer 表面健康）
#   （osd.1 在凍結期間是否照常更新＝資料收集，不下 verdict：結果決定
#    exporter 是 per-socket stale 還是整台 stale，兩者緩解不同）
#   window: 凍結前 60s ~ SIGCONT 後 +60s
# BASELINE: HEALTH_OK（豁免 BLUESTORE_SLOW_OP_ALERT）、9 up
# PRE-CHECK: pre_check；15s < heartbeat grace(20s) → 不觸發 down
# ROLLBACK: SIGCONT（以 ps state 非 T 驗證）
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

EXEMPT='BLUESTORE_SLOW_OP_ALERT'
OSD_HOST="192.168.18.169"
OSD_PID=""

rollback() {
  if [ -n "${OSD_PID}" ]; then
    lab_ssh "${OSD_HOST}" "sudo kill -CONT ${OSD_PID} 2>/dev/null" || true
    local st
    st=$(lab_ssh "${OSD_HOST}" "ps -o stat= -p ${OSD_PID}" || true)
    case "${st}" in
      *T*) die "rollback failed: osd.0 pid ${OSD_PID} still stopped (${st})" ;;
      *) log "rollback verified: osd.0 state=${st}" ;;
    esac
  fi
}
trap rollback EXIT

fetch_counters() {
  # fetch_counters TAG — grab both osd.0/osd.1 txc counters from the exporter
  # with a hard curl timeout; HTTP code goes to the file's first line.
  local tag="$1"
  lab_ssh "${OSD_HOST}" \
    "curl -s -m 5 -w 'HTTP_CODE=%{http_code}\n' http://localhost:9926/metrics | grep -E 'HTTP_CODE|^ceph_bluestore_txc_commit_lat_count' ; true" \
    > "${BUNDLE}/exporter-${tag}.txt"
}

counter_val() {
  # counter_val TAG OSD — extract one osd's txc count from a fetch
  awk -v d="ceph_daemon=\"osd.$2\"" '$0 ~ d {print $2}' "${BUNDLE}/exporter-$1.txt" | head -1
}

main() {
  bundle_init e05-exporter-freeze
  pre_check "${EXEMPT}"
  baseline_capture
  bundle_clock_skew "${OSD_HOST}"
  ensure_bench_pool

  OSD_PID=$(osd_pid "${OSD_HOST}" 0)
  [ -n "${OSD_PID}" ] || die "cannot resolve osd.0 pid"
  log "osd.0 pid = ${OSD_PID}"

  local t0 tf_start tf_end t_end
  t0=$(remote_epoch "${ADMIN_HOST}")
  log "light bench write 90s; freeze at +20s for 15s"
  bench_write 90 4 512K
  sleep 20

  fetch_counters pre
  tf_start=$(remote_epoch "${OSD_HOST}")
  lab_ssh "${OSD_HOST}" "sudo kill -STOP ${OSD_PID}"
  sleep 6
  fetch_counters frozen1
  sleep 6
  fetch_counters frozen2
  sleep 3
  lab_ssh "${OSD_HOST}" "sudo kill -CONT ${OSD_PID}"
  tf_end=$(remote_epoch "${OSD_HOST}")
  rollback
  bundle_note "freeze window: ${tf_start} .. ${tf_end}"

  sleep 30
  fetch_counters post
  bench_wait_done
  bench_collect_logs
  lab_ssh "${ADMIN_HOST}" "sudo rados -p ${BENCH_POOL} cleanup" >&2 || true
  sleep 30
  t_end=$(remote_epoch "${ADMIN_HOST}")

  collect_std "$((t0 - 60))" "${t_end}"
  prom_range 'up{instance="ceph-lab-osd-01"}' "$((t0 - 60))" "${t_end}" 5 "${BUNDLE}/up-osd01.json"

  # ---- verdicts ----
  # exporter HTTP 全程 200
  local c
  for c in pre frozen1 frozen2 post; do
    check "h013_http_${c}" eq "$(grep -c 'HTTP_CODE=200' "${BUNDLE}/exporter-${c}.txt")" 1
  done
  # osd.0 凍結期間 series 仍在且值凍住（stale, 不是消失）
  local v_pre v_f1 v_f2 v_post
  v_pre=$(counter_val pre 0); v_f1=$(counter_val frozen1 0)
  v_f2=$(counter_val frozen2 0); v_post=$(counter_val post 0)
  bundle_note "osd.0 txc count: pre=${v_pre} f1=${v_f1} f2=${v_f2} post=${v_post}"
  bundle_note "osd.1 txc count: pre=$(counter_val pre 1) f1=$(counter_val frozen1 1) f2=$(counter_val frozen2 1) post=$(counter_val post 1)"
  [ -z "${v_f1}" ] && v_f1=none
  [ -z "${v_f2}" ] && v_f2=none
  check "h013_osd0_series_present" ne "${v_f2}" none
  check "h013_osd0_stale"          eq "${v_f1}" "${v_f2}"
  check "h013_osd0_resumes"        gt "${v_post:-none}" "${v_f2}"
  # Prometheus 端 up 全程 1（min==1 → max(1-up)==0 的等價寫法：range 內最小值）
  prom_range '1 - up{instance="ceph-lab-osd-01"}' "$((tf_start - 30))" "$((tf_end + 30))" 5 \
    "${BUNDLE}/up-inverted.json"
  check "h013_up_never_drops" le "$(max_or_zero "${BUNDLE}/up-inverted.json")" 0

  assert_health "${EXEMPT}"
  emit_verdict
}

main "$@"
