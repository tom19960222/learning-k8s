#!/usr/bin/env bash
# ceph-mclock-profiles — 穩態（negative control）佇列入口（Task 13）。
#
# 用法：run/steady.sh --yes-really-inject [--resume]
#
#   --resume  = **first-cell gate 的人工放行憑證**。第一個 cell 跑完後腳本會停下來
#               （exit 10）讓人檢查 bundle；確認沒問題再帶 --resume 重跑續完佇列。
#
# 流程（薄 orchestrator，實質工作全在 lib/pipeline.sh）：
#   reconcile → [first-cell gate：fio_smoke_real 已過的斷言 + 跑一個 cell + 停]
#             → manifest.py next --kind steady 迴圈 → pipeline_run_execution
#             → 全穩態完成後 `verdict.py margins` 產出並驗證（faults.sh 的前置檔）
#
# 離開碼：0 完成／1 錯誤／3 佇列被 watchdog 停／10 first-cell gate 等人工放行
# shellcheck source-path=SCRIPTDIR
set -u

# shellcheck source=./queue.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/queue.sh"

require_inject_flag "$@"

resume=0
for arg in "$@"; do
  case "$arg" in
    --yes-really-inject) : ;;
    --resume) resume=1 ;;
    *) die "未知參數：${arg}（用法：run/steady.sh --yes-really-inject [--resume]）" ;;
  esac
done

inventory_load
queue_init
reconcile || die "reconcile 未過——殘留未清乾淨不得開跑"
cleanup_push runner_lock_release

# --- first-cell gate ----------------------------------------------------------
# 第一個穩態 cell 是整個 campaign 的第一次真跑：先確認 parser 已用真機 raw log 校正過
#（fio_smoke_real 的 golden log，由 run/calibrate.sh 產出），再跑一個 cell 就停等人工。
done_n="$(queue_progress steady | awk '{print $1}')"
if [ "$done_n" -eq 0 ]; then
  golden="$(fio_golden_dir)"
  if [ ! -d "$golden" ] || [ -z "$(ls -A "$golden" 2>/dev/null)" ]; then
    printf 'steady: SMOKE-MISSING %s\n' "$golden"
    die "first-cell gate：fio_smoke_real 尚未通過（golden log 缺）——parser 未校正不得開跑"
  fi
  printf 'steady: SMOKE-OK %s\n' "$golden"

  rc=0
  queue_loop steady - 1 || rc=$?
  [ "$rc" -eq 3 ] && { printf 'steady: HALTED %s\n' "$QUEUE_LAST_KEY"; exit 3; }
  [ "$rc" -eq 0 ] || die "first cell 佇列異常（rc=${rc}）"
  [ "$QUEUE_DONE_COUNT" -ge 1 ] || die "first cell 未完成——不得放行後續佇列"

  if [ "$resume" -eq 0 ]; then
    printf 'steady: FIRST-CELL-GATE %s\n' "$QUEUE_LAST_KEY"
    log "第一個 cell 已完成，請檢查 bundle 後以 --resume 續跑"
    exit 10
  fi
fi

# --- 全穩態佇列 ---------------------------------------------------------------
rc=0
queue_loop steady - 0 || rc=$?
[ "$rc" -eq 3 ] && { printf 'steady: HALTED %s\n' "$QUEUE_LAST_KEY"; exit 3; }
[ "$rc" -eq 0 ] || die "穩態佇列異常（rc=${rc}）"

# --- margins（faults 的前置檔）-------------------------------------------------
progress="$(queue_progress steady)"
done_n="${progress%% *}"
total_n="${progress##* }"
[ "$done_n" -eq "$total_n" ] || die "穩態尚未全數完成（${done_n}/${total_n}），不產 margins"

bundles=()
while IFS= read -r b; do
  bundles+=("$b")
done < <(queue_done_bundles steady || true)
[ "${#bundles[@]}" -gt 0 ] || die "找不到任何穩態 DONE bundle——margins 無從導出 noise margin"

margins_out="$(python3 "$VERDICT_PY" margins "${bundles[@]+"${bundles[@]}"}" \
                --results "$RESULTS_DIR")" \
  || die "margins 失敗（faults 的前置檔未產出）：${margins_out:-（無輸出）}"
printf '%s\n' "$margins_out"
case "$margins_out" in
  *"margins: OK"*) : ;;
  *) die "margins 未 OK——faults 不得開跑" ;;
esac
[ -s "$RESULTS_DIR/margins.json" ] || die "margins.json 未產出：${RESULTS_DIR}/margins.json"

printf 'steady: PASS done=%s/%s bundles=%s\n' "$done_n" "$total_n" "${#bundles[@]}"
