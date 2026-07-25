#!/usr/bin/env bash
# ceph-mclock-profiles — 故障 cells 佇列入口（Task 13）。
#
# 用法：run/faults.sh --yes-really-inject [--pilot] [--resume]
#
#   --pilot   = 只跑每故障型的 pilot（預期最慢組合 × r1），跑完做 schedule-estimate
#               推導各故障型的 measurement_cap，然後停等人工放行。
#   --resume  = 人工放行憑證（pilot gate 用）。
#
# 前置條件
#   `results/margins.json`（run/steady.sh 全穩態完成後產出）。**--pilot 模式除外**：
#   pilot 的目的就是推 cap，不需要 margins。缺檔即 die——沒有 noise/production 雙軌
#   margin，verdict 的 indistinguishable 分不出「等效」與「靈敏度不足」。
#
# 流程（薄 orchestrator，實質工作全在 lib/pipeline.sh）：
#   reconcile → manifest.py next --kind fault 迴圈 → pipeline_run_execution
#             → 每 cell n=2 後 verdict.py need-more-n → 轉譯成 manifest.py amend
#             → 每 12h 回報（進度 + 累計花費估算 + 唯讀 az 登入態檢查 + budget-warning）
#
# 離開碼：0 完成／1 錯誤／3 佇列被 watchdog 停／10 pilot gate 等人工放行／
#         11 PILOT-CENSORED 等人工裁示（**禁止**把 censored 值餵進 2× 公式）
# shellcheck source-path=SCRIPTDIR
set -u

# shellcheck source=./queue.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/queue.sh"

# 幾個 replicate 完成後就問一次 need-more-n（plan：每 cell n=2 後）
FAULTS_NEED_MORE_N_AT="${FAULTS_NEED_MORE_N_AT:-2}"
# 回報週期（秒）與成本模型（README §怠轉成本：停佇列不停機 ≈ $8/hr）
FAULTS_REPORT_SECS="${FAULTS_REPORT_SECS:-43200}"
FAULTS_HOURLY_USD="${FAULTS_HOURLY_USD:-8}"
FAULTS_BUDGET_USD="${FAULTS_BUDGET_USD:-1000}"

# --- 12h 回報 -----------------------------------------------------------------

# 唯讀登入態檢查：campaign 期間只有兩個 az 例外，這是其中之一（另一個是 watchdog 2b
# 的 `az vm restart`）。hour 60+ 憑證失效會讓 2b 救不回來 → 失效即當 pre-HUMAN 警示。
_faults_az_state() {
  command -v az >/dev/null 2>&1 || { printf 'missing\n'; return 0; }
  if az account show --output json >/dev/null 2>&1; then
    printf 'ok\n'
  else
    printf 'stale\n'
  fi
}

_faults_report() { # <now-epoch>
  local now="$1" start elapsed_h cost az_state progress
  start="$(queue_campaign_start)"
  elapsed_h="$(awk -v s="$((now - start))" 'BEGIN{printf "%.2f", s / 3600}')"
  cost="$(awk -v h="$elapsed_h" -v r="$FAULTS_HOURLY_USD" 'BEGIN{printf "%.0f", h * r}')"
  progress="$(queue_progress fault)"
  az_state="$(_faults_az_state)"
  printf 'faults: REPORT done=%s/%s elapsed_h=%s cost_usd=%s az=%s\n' \
    "${progress%% *}" "${progress##* }" "$elapsed_h" "$cost" "$az_state"
  if [ "$az_state" != "ok" ]; then
    printf 'faults: AZ-LOGIN-STALE %s\n' "$az_state"
    log "az 登入態異常（${az_state}）——watchdog 2b 的 az vm restart 會失效，視為 pre-HUMAN 事件"
  fi
  if [ "$(awk -v c="$cost" -v t="$FAULTS_BUDGET_USD" \
          'BEGIN{print (c + 0 >= t + 0) ? 1 : 0}')" = "1" ]; then
    printf 'budget-warning: cost_usd=%s threshold=%s\n' "$cost" "$FAULTS_BUDGET_USD"
  fi
}

_faults_maybe_report() {
  local f="$RESULTS_DIR/.faults-last-report" now last=0
  now="$(date +%s)"
  [ -s "$f" ] && last="$(tr -d ' \r\n' < "$f")"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$FAULTS_REPORT_SECS" ] || return 0
  printf '%s\n' "$now" > "$f"
  _faults_report "$now"
}

# --- need-more-n → amend --------------------------------------------------------

_faults_cell_done_n() { # <cell>
  local d n=0
  for d in "$RESULTS_DIR/$1"/r*/DONE; do
    [ -f "$d" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# queue_loop 的 after-hook：每個 execution 完成後跑一次。
_faults_after_exec() { # <exec-json>
  local cell n marker
  cell="$(queue_exec_field "$1" cell_id)"
  n="$(_faults_cell_done_n "$cell")"
  if [ "$n" -ge "$FAULTS_NEED_MORE_N_AT" ]; then
    marker="$RESULTS_DIR/$cell/.need-more-n.$n"
    if [ ! -e "$marker" ]; then
      # verdict.py need-more-n 的輸出只是**建議**（無 seq）；一律由
      # pipeline_apply_amendments 轉譯成 `manifest.py amend`——入口絕不直接寫 journal。
      pipeline_apply_amendments "$cell" || log "need-more-n 轉譯失敗（續行）：${cell}"
      : > "$marker"
    fi
  fi
  _faults_maybe_report
}

# --- pilot --------------------------------------------------------------------

_faults_pilot_keys() {
  python3 "$MANIFEST_PY" pilots --results "$RESULTS_DIR" | queue_exec_keys
}

# pilot 全數完成後推導 cap；PILOT-CENSORED 走人工裁示分支。
_faults_pilot_estimate() { # <resume 0|1>
  local resume="$1" keys=() bundles=() k b f out translated rc=0 censored blocked=""
  while IFS= read -r k; do
    keys+=("$k")
  done < <(_faults_pilot_keys)
  [ "${#keys[@]}" -gt 0 ] || die "manifest 沒有 pilot executions——無從推導 cap"

  while IFS= read -r b; do
    bundles+=("$b")
  done < <(queue_done_bundles fault "${keys[@]+"${keys[@]}"}" || true)
  [ "${#bundles[@]}" -gt 0 ] || die "pilot bundle 一個都沒有（keys=${#keys[@]}）"

  out="$(python3 "$VERDICT_PY" schedule-estimate "${bundles[@]+"${bundles[@]}"}" \
          --results "$RESULTS_DIR")" || rc=$?
  printf '%s\n' "$out" | grep -v '^{' || true

  case "$rc" in
    0|5) : ;;
    6) die "schedule-estimate 沒有 recovery 觀測（NO-DATA）——cap 無從推導" ;;
    *) die "schedule-estimate 失敗（rc=${rc}）" ;;
  esac

  # 非 censored 的建議 → 轉譯成 manifest.py amend（cap-update 只影響尚未執行者）
  translated="$(printf '%s\n' "$out" | grep '^{' | queue_translate_amends)" \
    || die "cap-update amendment 轉譯失敗"
  printf '%s\n' "$translated"

  if [ "$rc" -eq 5 ]; then
    # pilot 自己撞 cap：recovery 值只是下界，**禁止**餵進 2× 公式。
    # 人工裁示（cap×2 重跑 pilot 或人工指定 cap）必須先以 cap-update amendment 落 journal，
    # 之後才准放行——`--resume` 單獨並不足以繞過這一格。
    censored="$(printf '%s\n' "$out" \
                | awk '/^schedule-estimate: PILOT-CENSORED /{print $3}')"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      queue_has_amend cap-update "$f" || blocked="${blocked}${blocked:+,}${f}"
    done <<< "$censored"
    if [ -n "$blocked" ]; then
      printf 'faults: PILOT-CENSORED %s\n' "$blocked"
      log "pilot 撞 cap 且尚無人工 cap-update 裁示：${blocked}"
      log "處置二選一：(a) manifest.py amend --type cap-update --key <fault> --value <cap×2> 後重跑 pilot；(b) 人工指定 cap 並記入 journal"
      exit 11
    fi
    log "PILOT-CENSORED 已有人工 cap-update 裁示，放行：${censored}"
  fi

  if [ "$resume" -eq 0 ]; then
    printf 'faults: PILOT-GATE bundles=%s\n' "${#bundles[@]}"
    log "pilot 已完成，請檢查 schedule-estimate.json 後以 --resume 放行"
    exit 10
  fi
  printf 'faults: PILOT-PASS bundles=%s\n' "${#bundles[@]}"
  # 刻意不在同一次呼叫接著跑全佇列：全佇列的 margins 前置在 --pilot 模式下被略過，
  # 若直接續跑就等於繞過它。全佇列一律另起一次（all.sh 也是分兩段跑）。
  log "下一步：run/faults.sh --yes-really-inject（全佇列；需要 run/steady.sh 產出的 margins.json）"
}

# --- 主流程 -------------------------------------------------------------------

require_inject_flag "$@"

pilot=0
resume=0
for arg in "$@"; do
  case "$arg" in
    --yes-really-inject) : ;;
    --pilot) pilot=1 ;;
    --resume) resume=1 ;;
    *) die "未知參數：${arg}（用法：run/faults.sh --yes-really-inject [--pilot] [--resume]）" ;;
  esac
done

inventory_load
queue_init

if [ "$pilot" -eq 0 ]; then
  margins_json="$RESULTS_DIR/margins.json"
  if [ ! -s "$margins_json" ]; then
    printf 'faults: NO-MARGINS %s\n' "$margins_json"
    die "缺 margins.json——請先跑 run/steady.sh 至全穩態完成（--pilot 模式才可略過）"
  fi
  printf 'faults: MARGINS-OK %s\n' "$margins_json"
fi

reconcile || die "reconcile 未過——殘留未清乾淨不得開跑"
cleanup_push runner_lock_release
queue_campaign_start >/dev/null

rc=0
if [ "$pilot" -eq 1 ]; then
  queue_loop fault - 0 --pilot || rc=$?
else
  _faults_maybe_report
  queue_loop fault _faults_after_exec 0 || rc=$?
fi
[ "$rc" -eq 3 ] && { printf 'faults: HALTED %s\n' "$QUEUE_LAST_KEY"; exit 3; }
[ "$rc" -eq 0 ] || die "故障佇列異常（rc=${rc}）"

if [ "$pilot" -eq 1 ]; then
  _faults_pilot_estimate "$resume"
  exit 0
fi

_faults_report "$(date +%s)"
progress="$(queue_progress fault)"
printf 'faults: PASS done=%s/%s\n' "${progress%% *}" "${progress##* }"
