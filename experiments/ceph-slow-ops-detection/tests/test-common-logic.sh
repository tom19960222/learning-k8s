#!/usr/bin/env bash
# Unit tests for pure-logic helpers in lib/common.sh (no network needed:
# only functions that don't ssh are exercised).
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP_DIR="$(dirname "${TESTS_DIR}")"

# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091  # common.sh 位置由 EXP_DIR 動態組出，shellcheck -x 不追
. "${EXP_DIR}/lib/common.sh"

fails=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "${want}" = "${got}" ]; then
    echo "ok   ${label}" >&2
  else
    echo "FAIL ${label}: want=[${want}] got=[${got}]" >&2
    fails=$((fails + 1))
  fi
}

# --- slow_sum_expr（regex 形式，需與 rules/ceph-slow-ops-fast.yml 完全同構）---
e=$(slow_sum_expr 1m '{ceph_daemon="osd.0"}')
expect "expr_sel" \
  'sum by (ceph_daemon, instance) (increase(ceph_bluestore_slow_aio_wait_count{ceph_daemon="osd.0"}[1m]) + increase(ceph_bluestore_slow_committed_kv_count{ceph_daemon="osd.0"}[1m]) + increase(ceph_bluestore_slow_read_onode_meta_count{ceph_daemon="osd.0"}[1m]) + increase(ceph_bluestore_slow_read_wait_aio_count{ceph_daemon="osd.0"}[1m]))' \
  "${e}"
e2=$(slow_sum_expr 2m)
expect "expr_nosel" \
  'sum by (ceph_daemon, instance) (increase(ceph_bluestore_slow_aio_wait_count[2m]) + increase(ceph_bluestore_slow_committed_kv_count[2m]) + increase(ceph_bluestore_slow_read_onode_meta_count[2m]) + increase(ceph_bluestore_slow_read_wait_aio_count[2m]))' \
  "${e2}"

# --- slow_raw_expr ---
expect "raw_expr" \
  'sum by (ceph_daemon) ({__name__=~"ceph_bluestore_slow_(aio_wait|committed_kv|read_onode_meta|read_wait_aio)_count",ceph_daemon="osd.0"})' \
  "$(slow_raw_expr ',ceph_daemon="osd.0"')"

# --- osd_cgroup escaping ---
cg=$(osd_cgroup 0)
expect "cgroup_path" \
  '/sys/fs/cgroup/system.slice/system-ceph\x2d0c9bf37e\x2d514a\x2d11f1\x2db72a\x2dbc24113f1375.slice/ceph-0c9bf37e-514a-11f1-b72a-bc24113f1375@osd.0.service' \
  "${cg}"

# --- check() verdict accounting ---
bundle_init_test() {  # minimal stand-in to avoid mkdir in results/
  BUNDLE=$(mktemp -d)
  VERDICT_FILE="${BUNDLE}/verdict.txt"
  : > "${VERDICT_FILE}"
  # shellcheck disable=SC2034  # emit_verdict 在 common.sh 內讀取
  SCENARIO_NAME="unit"
  SCENARIO_FAILED=0
}
bundle_init_test
check "a" ge 5 3
check "b" le 2 2
expect "no_fail_yet" "0" "${SCENARIO_FAILED}"
check "c" eq 1 2
expect "fail_after_eq" "1" "${SCENARIO_FAILED}"
check "d" eq none none
if grep -q "PASS d" "${VERDICT_FILE}"; then echo "ok   none_eq_none" >&2; else echo "FAIL none_eq_none" >&2; fails=$((fails+1)); fi
check "e" ge none 1
if grep -q "FAIL e" "${VERDICT_FILE}"; then echo "ok   none_ge_fails" >&2; else echo "FAIL none_ge_fails" >&2; fails=$((fails+1)); fi
# 空字串參數不得讓 check 崩潰（pj 失敗時會回空）——視同 none 記 FAIL
check "f" le "" 0
if grep -q "FAIL f" "${VERDICT_FILE}"; then echo "ok   empty_arg_no_crash" >&2; else echo "FAIL empty_arg_no_crash" >&2; fails=$((fails+1)); fi
v=$(emit_verdict)
expect "verdict_line" "VERDICT unit violated" "${v}"

bundle_init_test
check "x" gt 3 1
v=$(emit_verdict)
expect "verdict_confirmed" "VERDICT unit confirmed" "${v}"
rm -rf "${BUNDLE}"

# --- 回歸 tripwire：遠端 pgrep -f "rados bench" 會匹配包住它的 shell cmdline
# （自我匹配 → bench_wait_done 永遠不返回，E-00 曾因此卡死 10 分鐘）。
# 只允許 pgrep -x rados。
if grep -rn 'pgrep -f "rados bench"' "${EXP_DIR}/lib" "${EXP_DIR}/run" >&2; then
  echo "FAIL pgrep_self_match_regression" >&2
  fails=$((fails + 1))
else
  echo "ok   pgrep_self_match_regression" >&2
fi

exit "${fails}"
