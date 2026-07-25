#!/usr/bin/env bash
# ceph-mclock-profiles — run/ 薄入口共用的佇列迴圈（Task 13/14）。
#
# 設計原則：**入口只做編排**。
#   所有實質工作（preflight / prediction freeze / sampler / fio readiness / 注入 /
#   量測窗 / 回歸 / final_clean / baseline / collect / aggregate / verdict / finalize）
#   都在 `lib/pipeline.sh::pipeline_run_execution` 裡；本檔與 run/*.sh **一律不得**
#   自己拼流程、不得直接下遠端指令（node_ssh / ceph_* / fio_* / fault_* / sampler_*）。
#   唯一例外是 run/all.sh 的收尾（unflags / tuning restore / bg_collect_stop），
#   那是 campaign 級的對稱回退，不屬於任何一個 execution。
#
# 對外介面
# --------
#   queue_init                              建 results 目錄、記 campaign 起算時刻
#   queue_next <kind> <out> [manifest 參數]  rc 0 = 取得（寫入 out）／3 = 佇列耗盡
#                                           其餘 rc 一律 die（**耗盡與錯誤必須分得開**）
#   queue_loop <kind> <hook|-> <limit> [manifest 參數]
#                                           reconcile 之後的主迴圈；rc 0 = 跑完、
#                                           3 = 被 watchdog 停佇列、1 = 卡住（STUCK）
#   queue_progress <kind>                   印 `<done> <total>`（manifest merge 視圖）
#   queue_has_amend <type> <key>            journal 是否已有該筆 amendment（唯讀）
#   queue_done_bundles <kind> [<cell>/<rN>...]  已 finalize 的 attempt 目錄
#   queue_exec_field <exec-json> <a.b>      取 execution JSON 欄位
#   queue_translate_amends                  stdin 的 amend 建議行 → `manifest.py amend`
#   queue_campaign_start                    campaign 起算 epoch（不存在就以現在建立）
#
# 全域變數（呼叫端會讀）
#   QUEUE_DONE_COUNT  最近一次 queue_loop 成功完成的 execution 數
#   QUEUE_LAST_KEY    最近一次取到的 execution key（`<cell>/<rN>`）
#
# 離開碼慣例（三個入口共用）
#   0  正常結束        1 錯誤        3 佇列被 watchdog 停
#   10 人工 gate（等放行，非失敗）    11 PILOT-CENSORED 人工裁示 gate
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR

[ -n "${MCLOCK_QUEUE_LOADED:-}" ] && return 0
MCLOCK_QUEUE_LOADED=1

# shellcheck source=../lib/pipeline.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/pipeline.sh"

# 同一個 execution key 連續回鍋這麼多次仍無進展 → 判定卡住（防無限空轉）。
# 正常情況下 taint 預算（3）會先把它轉成 needs-human 讓 manifest 視圖跳過。
QUEUE_STUCK_LIMIT="${QUEUE_STUCK_LIMIT:-5}"
QUEUE_DONE_COUNT=0
QUEUE_LAST_KEY=""

# --- 小型 JSON 讀取器（判讀集中在這裡，入口腳本不自己 parse）--------------------

_QUEUE_PY_SRC="$(cat <<'PY'
import json
import sys


def die(msg):
    sys.stderr.write("[queue] " + msg + "\n")
    sys.exit(2)


def dig(doc, dotted):
    cur = doc
    for part in dotted.split("."):
        if isinstance(cur, list):
            cur = cur[int(part)]
        elif isinstance(cur, dict):
            if part not in cur:
                return None
            cur = cur[part]
        else:
            return None
    return cur


def main(argv):
    if not argv:
        die("缺子命令")
    cmd = argv[0]
    if cmd == "field":
        with open(argv[1]) as fh:
            doc = json.load(fh)
        val = dig(doc, argv[2])
        if val is None:
            die("execution JSON 缺欄位 %s（%s）" % (argv[2], argv[1]))
        sys.stdout.write("%s\n" % val)
        return 0
    if cmd == "keys":
        # stdin = `manifest.py pilots` 之類的 execution JSONL → 每行印 bundle_key
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            sys.stdout.write("%s\n" % json.loads(line)["bundle_key"])
        return 0
    # 以下皆吃 `manifest.py view` 的 merge 視圖（stdin）
    doc = json.load(sys.stdin)
    if cmd == "progress":
        kind = argv[1]
        execs = [e for e in doc.get("executions", []) if e.get("kind") == kind]
        done = sum(1 for e in execs if e.get("status") == "done")
        sys.stdout.write("%d %d\n" % (done, len(execs)))
        return 0
    if cmd == "has-amend":
        atype, key = argv[1], argv[2]
        for rec in doc.get("amendments", []):
            if rec.get("type") == atype and str(rec.get("key")) == key:
                return 0
        return 1
    die("未知子命令 %s" % cmd)


sys.exit(main(sys.argv[1:]))
PY
)"

_queue_py() { python3 -c "$_QUEUE_PY_SRC" "$@"; }

queue_init() {
  mkdir -p "$RESULTS_DIR" || die "無法建立 results 目錄：${RESULTS_DIR}"
}

# campaign 起算 epoch：12h 回報的花費估算基準；只建立一次，resume 沿用。
queue_campaign_start() {
  local f="$RESULTS_DIR/.campaign-start" v
  if [ ! -s "$f" ]; then
    date +%s > "$f" || die "無法寫入 campaign 起算時刻：${f}"
  fi
  v="$(tr -d ' \r\n' < "$f")"
  case "$v" in ''|*[!0-9]*) die "campaign 起算時刻毀損：${f}" ;; esac
  printf '%s\n' "$v"
}

# --- manifest merge 視圖（唯讀）------------------------------------------------

_queue_view_file() {
  local f="$RESULTS_DIR/.view.json"
  python3 "$MANIFEST_PY" view --results "$RESULTS_DIR" > "$f" \
    || die "manifest view 失敗（results=${RESULTS_DIR}）"
  printf '%s\n' "$f"
}

queue_progress() { # <kind> → `<done> <total>`
  [ $# -eq 1 ] || die "用法：queue_progress <kind>"
  local f
  f="$(_queue_view_file)"
  _queue_py progress "$1" < "$f"
}

queue_has_amend() { # <type> <key>：rc 0 = journal 已有該筆
  [ $# -eq 2 ] || die "用法：queue_has_amend <type> <key>"
  local f
  f="$(_queue_view_file)"
  _queue_py has-amend "$1" "$2" < "$f"
}

queue_exec_field() { # <exec-json> <dotted-key>
  [ $# -eq 2 ] || die "用法：queue_exec_field <exec-json> <dotted-key>"
  _queue_py field "$1" "$2"
}

# stdin = execution JSONL（例如 `manifest.py pilots`）→ 每行印 `<cell>/<rN>`
queue_exec_keys() { _queue_py keys; }

# --- 已 finalize 的 bundle 清單 -----------------------------------------------

# bundle 的 kind 記在 `bundle_finalize` 寫的 DONE 檔（`kind=<kind>`），
# 所以這裡不需要重讀 manifest 就能依 kind 過濾。
_queue_bundle_key() { # <attempt-dir> → `<cell>/<rN>`
  local rdir="${1%/attempts/*}"
  printf '%s/%s\n' "$(basename "$(dirname "$rdir")")" "$(basename "$rdir")"
}

queue_done_bundles() { # <kind> [<cell>/<rN>...]：rc 1 = 一個都沒有
  [ $# -ge 1 ] || die "用法：queue_done_bundles <kind> [<cell>/<rN>...]"
  local kind="$1" d dir key want n=0
  shift
  while IFS= read -r d; do
    grep -q "^kind=${kind}\$" "$d" 2>/dev/null || continue
    dir="$(dirname "$d")"
    if [ $# -gt 0 ]; then
      key="$(_queue_bundle_key "$dir")"
      for want in "$@"; do
        [ "$want" = "$key" ] && { printf '%s\n' "$dir"; n=$((n + 1)); break; }
      done
      continue
    fi
    printf '%s\n' "$dir"
    n=$((n + 1))
  done < <(find "$RESULTS_DIR" -type f -name DONE -path '*/attempts/*' 2>/dev/null | sort)
  [ "$n" -gt 0 ]
}

# --- amendment 轉譯 ------------------------------------------------------------

# stdin = verdict.py 的 amend 建議行（JSON，無 seq）→ 逐筆轉成 `manifest.py amend`。
# **絕不**自己 append journal——seq 由 manifest.py 配發，它才是 journal 的唯一寫入者。
# 解析與寫入沿用 lib/pipeline.sh 既有的 `amend-lines` / `_pipeline_amend`（不重複實作）。
queue_translate_amends() { # → stdout `amend: TRANSLATED <n>`
  local lines atype key value source n=0
  lines="$(_pipeline_py amend-lines)" || lines=""
  while IFS=$'\t' read -r atype key value source; do
    [ -n "$atype" ] || continue
    _pipeline_amend "$atype" "$key" "$value" "$source" \
      || die "amend 寫入失敗：${atype} ${key}"
    n=$((n + 1))
  done <<< "$lines"
  printf 'amend: TRANSLATED %s\n' "$n"
}

# --- 佇列 ---------------------------------------------------------------------

# queue_next <kind> <outfile> [manifest 額外參數...]
#   rc 0 = 取得下一個 execution（JSON 寫進 outfile）
#   rc 3 = 佇列耗盡（**正常結束**，不是錯誤）
#   其餘 = die（manifest.py 真的壞了，絕不可當成「跑完了」）
queue_next() {
  [ $# -ge 2 ] || die "用法：queue_next <kind> <outfile> [manifest 額外參數...]"
  local kind="$1" out="$2" rc=0
  shift 2
  python3 "$MANIFEST_PY" next --results "$RESULTS_DIR" --kind "$kind" "$@" > "${out}.tmp" \
    || rc=$?
  case "$rc" in
    0) : ;;
    3) rm -f "${out}.tmp"; return 3 ;;
    *) rm -f "${out}.tmp"
       die "manifest next 失敗（kind=${kind} rc=${rc}）——這不是佇列耗盡（rc=3），不得續跑" ;;
  esac
  [ -s "${out}.tmp" ] || die "manifest next 回 0 卻沒有輸出（kind=${kind}）"
  mv -f "${out}.tmp" "$out" || die "無法寫入 execution 檔：${out}"
  QUEUE_LAST_KEY="$(queue_exec_field "$out" bundle_key)"
}

# queue_loop <kind> <hook|-> <limit> [manifest 額外參數...]
#   hook  ：每個成功完成的 execution 後以 <exec-json> 呼叫一次（`-` = 不呼叫）
#   limit ：成功幾個就停（0 = 跑到佇列耗盡）——first-cell gate 用
#   rc 0 = 佇列耗盡或達到 limit；3 = watchdog 停佇列；1 = 卡住
queue_loop() {
  [ $# -ge 3 ] || die "用法：queue_loop <kind> <hook|-> <limit> [manifest 額外參數...]"
  local kind="$1" hook="$2" limit="$3" rc last="" stuck=0
  local out="$RESULTS_DIR/.next-${kind}.json"
  shift 3
  QUEUE_DONE_COUNT=0
  while :; do
    rc=0
    queue_next "$kind" "$out" "$@" || rc=$?
    [ "$rc" -eq 3 ] && break

    if [ "$QUEUE_LAST_KEY" = "$last" ]; then
      stuck=$((stuck + 1))
      if [ "$stuck" -ge "$QUEUE_STUCK_LIMIT" ]; then
        printf 'queue: STUCK %s %s\n' "$kind" "$QUEUE_LAST_KEY"
        return 1
      fi
    else
      stuck=0
      last="$QUEUE_LAST_KEY"
    fi

    rc=0
    pipeline_run_execution "$out" || rc=$?
    case "$rc" in
      0)
        QUEUE_DONE_COUNT=$((QUEUE_DONE_COUNT + 1))
        if [ "$hook" != "-" ]; then
          "$hook" "$out" || die "after-hook 失敗：${hook} ${QUEUE_LAST_KEY}"
        fi
        ;;
      3)
        # watchdog 層 3：佇列必須停，不得再開新的 execution
        printf 'queue: HALTED %s %s\n' "$kind" "$QUEUE_LAST_KEY"
        return 3
        ;;
      *)
        # taint(4) / needs-human(5) / busy(6) / abort(1)：狀態已由 pipeline 持久化，
        # 下一輪的 manifest merge 視圖會決定要重試還是跳過——入口不自行判斷。
        log "execution 未完成（rc=${rc}）：${QUEUE_LAST_KEY}"
        ;;
    esac

    if [ "$limit" -gt 0 ] && [ "$QUEUE_DONE_COUNT" -ge "$limit" ]; then
      break
    fi
  done
  return 0
}
