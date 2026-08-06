#!/usr/bin/env bash
# ceph-mclock-profiles — chaos 終局佇列入口（Task 14）。
#
# 用法：run/chaos.sh --yes-really-inject
#
# chaos 走的是**同一台** Replicate Pipeline（prediction / verdict / finalize 一個都不少，
# chaos schema 另外要求 `cleanup-proof.json`——多重故障必須證明全數回退）。
# 本檔唯一多做的事是「同 seed 跨 profile 一致」的入口級斷言：3 個 chaos executions
# 只差在 profile，seed/duration 必須完全相同，否則跨 profile 的比較根本不成立。
#
# 離開碼：0 完成／1 錯誤／3 佇列被 watchdog 停
# shellcheck source-path=SCRIPTDIR
set -u

# shellcheck source=./queue.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/queue.sh"

_CHAOS_SEED=""
_CHAOS_DURATION=""

# queue_loop 的 after-hook：對「本次真的送進 pipeline 的」execution 斷言 seed 一致。
_chaos_after_exec() { # <exec-json>
  local seed duration
  seed="$(queue_exec_field "$1" fault_params.seed)"
  duration="$(queue_exec_field "$1" fault_params.duration)"
  if [ -z "$_CHAOS_SEED" ]; then
    _CHAOS_SEED="$seed"
    _CHAOS_DURATION="$duration"
  fi
  [ "$seed" = "$_CHAOS_SEED" ] \
    || die "chaos seed 跨 profile 不一致（${QUEUE_LAST_KEY}：${seed} ≠ ${_CHAOS_SEED}）——事件序列不同就不能比"
  [ "$duration" = "$_CHAOS_DURATION" ] \
    || die "chaos duration 跨 profile 不一致（${QUEUE_LAST_KEY}：${duration} ≠ ${_CHAOS_DURATION}）"
  printf 'chaos: SEED %s %s duration=%s\n' "$QUEUE_LAST_KEY" "$seed" "$duration"
}

# inject_confirm（不是 require_inject_flag）：後者只檢查旗標，前者還會設下
# INJECT_CONFIRMED，注入函式靠它把關。測試全域 export 了該變數，所以只有真機
# 會發現差別——第一次跑故障 pilot 就在注入前被擋下。
inject_confirm "$@"

for arg in "$@"; do
  case "$arg" in
    --yes-really-inject) : ;;
    --resume) : ;;
    *) die "未知參數：${arg}（用法：run/chaos.sh --yes-really-inject）" ;;
  esac
done

inventory_load
queue_init
reconcile || die "reconcile 未過——殘留未清乾淨不得開跑"
cleanup_push runner_lock_release

rc=0
queue_loop chaos _chaos_after_exec 0 || rc=$?
[ "$rc" -eq 3 ] && { printf 'chaos: HALTED %s\n' "$QUEUE_LAST_KEY"; exit 3; }
[ "$rc" -eq 0 ] || die "chaos 佇列異常（rc=${rc}）"

progress="$(queue_progress chaos)"
printf 'chaos: PASS done=%s/%s\n' "${progress%% *}" "${progress##* }"
