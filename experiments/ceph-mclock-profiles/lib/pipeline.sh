#!/usr/bin/env bash
# ceph-mclock-profiles — Replicate Pipeline 狀態機 + Reconciler + watchdog（Task 11）。
# bash 3.2 相容；stdout 只放機器要抓的那行，log/progress 一律 stderr。
#
# 對外介面
# --------
#   pipeline_run_execution <execution-json>   §Replicate Pipeline 的唯一狀態機
#     rc 0 = DONE（含 right-censored）／3 = 佇列已停／4 = attempt taint／
#     5 = 該 replicate 已 needs-human（跳過）／6 = claim 被別的 runner 持有／1 = abort
#   reconcile                                 crash-resume 前置步（殘留掃描 + final_clean gate）
#   runner_lock_acquire / runner_lock_release 單 runner lock（mkdir 原子 + 心跳 + stale 接管）
#   claim_acquire / claim_release <cell> <rN>  replicate 級 lease（同上）
#   watchdog_handle <trigger> <ctx>           trigger-specific 修復（表見下）
#   watchdog_count <trigger> / watchdog_halted / pipeline_drift_streak
#   pipeline_unhalt <理由> [--clear-counts]   人工排除後解除停佇列（留痕；入口 run/unhalt.sh）
#   pipeline_taint_count|bump|clear <cell> <rN> [reason]   taint/abort 重試預算
#   pipeline_apply_amendments <cell>          verdict.py 的建議 → manifest.py amend
#
# 順序不可變（plan §Replicate Pipeline，測試逐項斷言）
# -------------------------------------------------
#   claim → preflight（set profile → qos gate + final_clean + bg-collector）→ prediction freeze →
#   sampler_start → sampler_assert_alive → **fio 啟動 + readiness barrier（注入之前！）** →
#   fault_t0 + measurement_deadline → 注入 → 量測窗（stop-condition = recovery_complete，
#   撞 cap = right-censored 仍是有效觀測）→ 停 fio → 回歸 → safety gate（final_clean +
#   H-008 兩時戳）→ baseline 復測 + baseline-check → sampler_stop → collect_cell →
#   coverage_finalize → cleanup proof → aggregate → verdict → **schemas --verify** →
#   bundle_finalize → release claim
#
# watchdog transition table（trigger-specific，不得共用 OSD 修復動作）
# -----------------------------------------------------------------
#   collector-heartbeat  只重啟 collector（bg_collect_ensure）        上限 2 → 層 3
#   fio-heartbeat        unmap/map + smoke                            上限 1 → 層 3
#   mon-quorum           restart 該 mon → 等 quorum=3 + final_clean    上限 1 → 層 3
#   pg-no-progress       restart 相關 OSD → final_clean                上限 2 → node reboot(2a)
#   node-ssh-lost        2a：ssh sudo reboot → ssh 回來 + final_clean   上限 2 → 2b
#   （2b）               bastion `az vm restart`（唯一 az 例外）        上限 1 → 層 3
#   層 3                 `watchdog: HUMAN-NEEDED <trigger> <ctx>` + 停佇列
#   計數持久化在 results/watchdog-state.json（resume 不重置）；修復成功即 reset 該 trigger。
#   **本檔絕不自動釋放/停止 VM**：az 只准 `az vm restart`，且只在 2b 這一格。
#
# 與其他 lib 的契約
# ----------------
#   - `bundle_finalize` 只吃必備檔清單 → 交叉核對必須由本檔顯式呼叫
#     `verdict.py schemas <kind> --verify <bundle> --manifest-hash <hash>`。
#   - `verdict.py --emit-amend` 的輸出是建議（無 seq），一律轉譯成 `manifest.py amend`。
#   - `MEASUREMENT_CAP` / `MEASUREMENT_DEADLINE` 由本檔 export，inject.sh 才驗得了
#     guard 不變條件；且**不得**用 `x="$(fault_...)"` 取機器行（subshell 會吃掉 cleanup_push）。
#   - cleanup stack 以「執行前記 mark、出口 unwind 到 mark」做 per-execution scope，
#     LIFO 順序固定為：停 fio → 回退注入 → sampler_stop → 釋放 claim。
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR

[ -n "${MCLOCK_PIPELINE_LOADED:-}" ] && return 0
MCLOCK_PIPELINE_LOADED=1

# shellcheck source=./inject.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inject.sh"
# shellcheck source=./fio.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fio.sh"
# shellcheck source=./collect.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/collect.sh"

# --- 常數 ---------------------------------------------------------------------
MANIFEST_PY="${MANIFEST_PY:-$MCLOCK_LIB/manifest.py}"
RUNNER_ID="${RUNNER_ID:-runner-$$}"
# lease 心跳容忍度：runner lock 每個 execution 邊界更新，claim 每個量測 tick 更新
RUNNER_LOCK_STALE_SECS="${RUNNER_LOCK_STALE_SECS:-3600}"
CLAIM_STALE_SECS="${CLAIM_STALE_SECS:-3600}"
# 同一 replicate 連續幾次 taint/abort 就寫 needs-human 並跳過（plan v4.2/F5-5）
PIPELINE_TAINT_BUDGET="${PIPELINE_TAINT_BUDGET:-3}"
# coverage supervisor 連續幾次退化算「持續 gap」（30s cadence × 3 = 90s）
PIPELINE_COVERAGE_GAP_LIMIT="${PIPELINE_COVERAGE_GAP_LIMIT:-3}"
# 連續幾個 replicate 出現 baseline drift 就停佇列要求 recalibrate 裁決
PIPELINE_DRIFT_LIMIT="${PIPELINE_DRIFT_LIMIT:-3}"
# final_clean 的零進展 deadline（逾時 → watchdog pg-no-progress）
PIPELINE_PROGRESS_SECS="${PIPELINE_PROGRESS_SECS:-600}"
# 量測窗每一輪的最短切片（讓 coverage supervisor 有機會在 cadence 上跑）
PIPELINE_TICK_SECS="${PIPELINE_TICK_SECS:-5}"

# 故障模式的 coverage 容忍值：門檻要反映**儀器自己的時間解析度**，不是我們希望的值。
# 一個監督週期的成本是「coverage 檢查 + sampler 檢查 + 一次 ceph -s」，全都是 ssh
# 往返；叢集受壓時 `ceph -s` 明顯變慢，實測一輪要 13-19s。於是 30s 的 cadence 只能
# 落在 38-40s（真機量到 38.2/40.0），每次檢查都帶 8-10s 的「盲」餘量——10s 的容忍值
# 在故障模式下**從來就達不到**，穩態則幾乎不會踩到（79 個 attempt 只出現過 1 次 13s）。
#
# 這與「為了讓測試過而放寬門檻」不同：這裡是把門檻對齊到儀器能達到的解析度，
# 並且**只放寬故障模式**、只放寬 supervisor 這一項的量級，sampler / fio 心跳的判定
# 完全不動。實測分布（故障）：中位數 1s、p90 17s、最大 19s → 取 25s。
COVERAGE_GAP_TOLERANCE_FAULT_SECS="${COVERAGE_GAP_TOLERANCE_FAULT_SECS:-25}"
WATCHDOG_DAEMON_SECS="${WATCHDOG_DAEMON_SECS:-300}"
WATCHDOG_SSH_SECS="${WATCHDOG_SSH_SECS:-30}"
WATCHDOG_SSH_WAIT_SECS="${WATCHDOG_SSH_WAIT_SECS:-900}"

watchdog_state_path() { printf '%s\n' "${WATCHDOG_STATE_JSON:-$RESULTS_DIR/watchdog-state.json}"; }
runner_lock_path() { printf '%s\n' "${RUNNER_LOCK_DIR:-$RESULTS_DIR/.runner.lock}"; }
_claim_path() { printf '%s/%s/%s/.claim\n' "$RESULTS_DIR" "$1" "$2"; }
_taint_count_path() { printf '%s/%s/%s/.taint-count\n' "$RESULTS_DIR" "$1" "$2"; }
_needs_human_path() { printf '%s/%s/%s/.needs-human\n' "$RESULTS_DIR" "$1" "$2"; }

# --- python 解析器（JSON 判讀集中在這裡）---------------------------------------
_PIPELINE_PY_SRC="$(cat <<'PY'
import json
import os
import sys
import time

SCHEMA_VERSION = 1
FIXED_RATE_PRESSURES = ("low", "mid", "high")


def die(msg, code=1):
    sys.stderr.write("[pipeline] " + msg + "\n")
    sys.exit(code)


def load(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (IOError, OSError, ValueError):
        return default


def dump_atomic(path, doc):
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(doc, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.rename(tmp, path)


# --- watchdog / drift 狀態（resume 不重置：唯一 SoT 是這個檔）-------------------

def _state(path):
    doc = load(path, None) or {}
    doc.setdefault("schema_version", SCHEMA_VERSION)
    doc.setdefault("counts", {})
    doc.setdefault("halted", False)
    doc.setdefault("halt_reason", None)
    doc.setdefault("drift_streak", 0)
    return doc


def cmd_state(path, op, *rest):
    doc = _state(path)
    if op == "count":
        print(int(doc["counts"].get(rest[0], 0)))
        return
    if op == "halted":
        sys.exit(0 if doc.get("halted") else 1)
    if op == "drift":
        print(int(doc.get("drift_streak", 0)))
        return
    if op == "bump":
        n = int(doc["counts"].get(rest[0], 0)) + 1
        doc["counts"][rest[0]] = n
        out = str(n)
    elif op == "clear":
        doc["counts"][rest[0]] = 0
        out = "0"
    elif op == "halt":
        doc["halted"] = True
        doc["halt_reason"] = rest[0]
        out = rest[0]
    elif op == "unhalt":
        # 人工排除問題後解除停佇列。設計約束（Task 0.3）：
        #   - 理由必填：解除是人工裁決，不得無聲清除（留痕進 unhalt_log，append-only）
        #   - **預設保留** trigger counts 與 drift streak：沒被排除的累積不該憑空歸零，
        #     要歸零得明示 --clear-counts（例如 recalibrate 裁決完才清 drift streak）
        clear = False
        positional = []
        for arg in rest:
            if arg == "--clear-counts":
                clear = True
            elif arg.startswith("--"):
                die("unhalt 未知旗標：%s" % arg)
            else:
                positional.append(arg)
        reason = positional[0].strip() if positional else ""
        if not reason:
            die("unhalt 需要理由（留痕）：state <path> unhalt <理由> [--clear-counts]")
        # 未 halted 時仍要讓 --clear-counts 生效：誤報的成因修掉後，殘留的
        # drift_streak / counts 會讓下一個訊號立刻再停。否則就只能手改 JSON——
        # 而這支工具存在的目的正是取代手改。
        if not doc.get("halted") and not clear:
            print("unhalt: NOOP")
            return
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        doc.setdefault("unhalt_log", []).append({
            "at": now, "reason": reason, "cleared_counts": clear,
            "halt_reason": doc.get("halt_reason"),
        })
        doc["halted"] = False
        doc["halt_reason"] = None
        doc["unhalted_at"] = now
        doc["unhalt_reason"] = reason
        if clear:
            doc["counts"] = {}
            doc["drift_streak"] = 0
        out = "unhalt: OK cleared-counts" if clear else "unhalt: OK"
    elif op == "drift-bump":
        n = int(doc.get("drift_streak", 0)) + 1
        doc["drift_streak"] = n
        out = str(n)
    elif op == "drift-clear":
        doc["drift_streak"] = 0
        out = "0"
    else:
        die("未知的 state 操作：%s" % op)
    doc["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    dump_atomic(path, doc)
    print(out)


# --- execution → 排程參數 -----------------------------------------------------

def _rate_for(cal_path, shape, pressure):
    """固定速率壓力才查校準表；extreme = 不限速（rate 0）。"""
    if pressure not in FIXED_RATE_PRESSURES:
        return 0
    cal = load(cal_path, None)
    if cal is None:
        die("找不到 calibration.json（%s）——執行前必須先跑 calibrate" % cal_path)
    rates = ((cal.get("shapes") or {}).get(shape) or {}).get("rates") or {}
    if pressure not in rates:
        die("calibration.json 缺 %s/%s 的目標速率" % (shape, pressure))
    return int(round(float(rates[pressure])))


def cmd_exec_summary(path, cal_path):
    ex = load(path, None)
    if ex is None:
        die("execution JSON 無法解析：%s" % path)
    for field in ("cell_id", "replicate", "kind", "profile", "shape", "pressure"):
        if not ex.get(field):
            die("execution JSON 缺 %s：%s" % (field, path))
    if ex["kind"] not in ("steady", "fault", "chaos"):
        die("未知的 execution kind：%s" % ex["kind"])
    fp = ex.get("fault_params") or {}
    fault = ex.get("fault") or "none"
    targets = ex.get("targets") or []
    target = targets[0] if targets else {}
    fields = [
        ex["cell_id"], ex["replicate"], ex["kind"], ex["profile"], ex["shape"],
        ex["pressure"], fault,
        # seq-contention 的實際機制寫在 fault_params.fault（= osd-down）
        fp.get("fault") or fault,
        ex.get("measurement_cap"), ex.get("guard_deadline_secs"),
        ex.get("manifest_hash"), target.get("node"), target.get("rack"),
        fp.get("seed"), fp.get("duration"),
        _rate_for(cal_path, ex["shape"], ex["pressure"]), ex.get("group_id"),
    ]
    print("\t".join("-" if v is None or v == "" else str(v) for v in fields))


def cmd_prediction(exec_path, out, rate):
    ex = load(exec_path, None)
    if ex is None:
        die("execution JSON 無法解析：%s" % exec_path)
    doc = dict(ex)
    doc.pop("_cap_override", None)
    doc["schema_version"] = SCHEMA_VERSION
    doc["target_iops"] = int(rate) or None
    doc.setdefault("expectations", {})
    dump_atomic(out, doc)


def cmd_censor(out, censored, cap, t0, deadline, end):
    """right-censored 是有效觀測（不是失敗）——basis 一律相對 recovery_complete。"""
    def _int(v):
        return None if v in ("-", "", None) else int(v)
    doc = {
        "schema_version": SCHEMA_VERSION,
        "censored": censored == "true",
        "censor_basis": "recovery_complete",
        "measurement_cap": _int(cap),
        "fault_t0": _int(t0),
        "measurement_deadline": _int(deadline),
        "observed_end": _int(end),
    }
    if doc["censored"] and doc["observed_end"] is not None and doc["fault_t0"] is not None:
        doc["observed_duration_s"] = doc["observed_end"] - doc["fault_t0"]
    dump_atomic(out, doc)


def cmd_amend_lines():
    """verdict.py --emit-amend 的建議（無 seq）→ manifest.py amend 的參數（TSV）。"""
    n = 0
    for line in sys.stdin:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            die("--emit-amend 輸出不是合法 JSON：%s" % line)
        value = rec.get("value")
        if isinstance(value, (dict, list)):
            value = json.dumps(value, sort_keys=True)
        print("%s\t%s\t%s\t%s" % (rec.get("type"), rec.get("key"), value,
                                  rec.get("source") or "verdict.py"))
        n += 1
    if n == 0:
        sys.exit(3)


def cmd_quorum():
    doc = json.load(sys.stdin)
    members = doc.get("quorum")
    if members is None:
        members = doc.get("quorum_names") or []
    print(len(members))


DISPATCH = {
    "state": cmd_state,
    "exec-summary": cmd_exec_summary,
    "prediction": cmd_prediction,
    "censor": cmd_censor,
    "amend-lines": cmd_amend_lines,
    "quorum": cmd_quorum,
}

if len(sys.argv) < 2 or sys.argv[1] not in DISPATCH:
    die("未知子指令：%s" % (sys.argv[1] if len(sys.argv) > 1 else ""))
DISPATCH[sys.argv[1]](*sys.argv[2:])
PY
)"

_pipeline_py() { python3 -c "$_PIPELINE_PY_SRC" "$@"; }

# =============================================================================
# lease：單 runner lock 與 replicate claim（mkdir 原子 + 心跳 + stale 接管）
# =============================================================================

_lease_write() { # <dir>
  printf '%s\n' "$RUNNER_ID" > "$1/owner"
  printf '%s\n' "$$" > "$1/pid"
  printf '%s\n' "$(date +%s)" > "$1/hb"
}

_lease_owner() { # <dir>
  [ -s "$1/owner" ] || { printf '%s\n' '?'; return 0; }
  tr -d ' \r\n' < "$1/owner"
  printf '\n'
}

# _lease_age <dir>：心跳年齡（秒）；沒有心跳一律當成無限舊（可接管）。
_lease_age() {
  local hb now
  [ -s "$1/hb" ] || { printf '%s\n' 999999999; return 0; }
  hb="$(tr -d ' \r\n' < "$1/hb")"
  case "$hb" in ''|*[!0-9]*) printf '%s\n' 999999999; return 0 ;; esac
  now="$(date +%s)"
  printf '%s\n' "$((now - hb))"
}

# _lease_take <dir> <stale-secs> <label>：0=取得 1=別人持有且心跳新鮮 2=stale 接管
_lease_take() {
  local dir="$1" stale="$2" owner age
  mkdir -p "$(dirname "$dir")"
  if mkdir "$dir" 2>/dev/null; then
    _lease_write "$dir"
    return 0
  fi
  owner="$(_lease_owner "$dir")"
  age="$(_lease_age "$dir")"
  if [ "$owner" = "$RUNNER_ID" ]; then
    _lease_write "$dir"
    return 0
  fi
  if [ "$age" -lt "$stale" ]; then
    log "${3} 由 ${owner} 持有（心跳 ${age}s 前，上限 ${stale}s）——不搶"
    return 1
  fi
  log "${3} 的 ${owner} 心跳已過期 ${age}s，接管"
  _lease_write "$dir"
  return 2
}

runner_lock_acquire() {
  local dir rc=0
  dir="$(runner_lock_path)"
  _lease_take "$dir" "$RUNNER_LOCK_STALE_SECS" "runner lock" || rc=$?
  case "$rc" in
    0) printf 'runner-lock: ACQUIRED %s\n' "$RUNNER_ID" ;;
    2) printf 'runner-lock: TAKEOVER %s\n' "$RUNNER_ID" ;;
    *) return 1 ;;
  esac
}

runner_lock_release() {
  local dir
  dir="$(runner_lock_path)"
  rm -rf "$dir"
  printf 'runner-lock: RELEASED %s\n' "$RUNNER_ID"
}

claim_acquire() { # <cell> <rN>
  [ $# -eq 2 ] || die "用法：claim_acquire <cell> <rN>"
  local dir rc=0
  dir="$(_claim_path "$1" "$2")"
  _lease_take "$dir" "$CLAIM_STALE_SECS" "claim ${1}/${2}" || rc=$?
  case "$rc" in
    0) printf 'claim: ACQUIRED %s/%s\n' "$1" "$2" ;;
    2) printf 'claim: TAKEOVER %s/%s\n' "$1" "$2" ;;
    *) return 1 ;;
  esac
}

claim_release() { # <cell> <rN>
  [ $# -eq 2 ] || die "用法：claim_release <cell> <rN>"
  rm -rf "$(_claim_path "$1" "$2")"
  printf 'claim: RELEASED %s/%s\n' "$1" "$2"
}

_claim_touch() { # <cell> <rN>：量測窗每一輪更新心跳（本機檔案寫入，成本可忽略）
  local dir
  dir="$(_claim_path "$1" "$2")"
  [ -d "$dir" ] || return 0
  printf '%s\n' "$(date +%s)" > "$dir/hb"
}

# =============================================================================
# watchdog / drift 狀態
# =============================================================================

watchdog_count() { # <trigger>
  [ $# -eq 1 ] || die "用法：watchdog_count <trigger>"
  _pipeline_py state "$(watchdog_state_path)" count "$1"
}

watchdog_halted() { _pipeline_py state "$(watchdog_state_path)" halted; }

pipeline_drift_streak() { _pipeline_py state "$(watchdog_state_path)" drift; }

# pipeline_unhalt <理由> [--clear-counts]：人工排除問題後解除停佇列（run/unhalt.sh 的核心）。
# 理由必填且會留痕（results/watchdog-state.json 的 unhalt_log）；trigger counts 預設保留。
pipeline_unhalt() {
  [ $# -ge 1 ] || die "用法：pipeline_unhalt <理由> [--clear-counts]"
  _pipeline_py state "$(watchdog_state_path)" unhalt "$@"
}

_pipeline_halt_queue() { # <reason>
  [ $# -eq 1 ] || die "用法：_pipeline_halt_queue <reason>"
  _pipeline_py state "$(watchdog_state_path)" halt "$1" >/dev/null \
    || log "佇列停止狀態寫入失敗（續行）：$1"
  log "佇列已停（需要人工裁決）：$1"
}

# _pipeline_reset_runtime_state：清掉行程內快取，狀態一律重新從 results/ 讀
#（resume / 測試切換 RESULTS_DIR 用；持久計數不會因此歸零）。
_pipeline_reset_runtime_state() {
  _PIPELINE_CLEANUP_MARK=0
  _PIPE_GAP_STREAK=0
  _PIPE_LAST_COV=0
  _PIPE_TAINTED=0
  _PIPE_REASON=""
  inject_cache_reset
}
_pipeline_reset_runtime_state

# =============================================================================
# taint / abort 重試預算（plan v4.2/F5-5）
# =============================================================================

pipeline_taint_count() { # <cell> <rN>
  [ $# -eq 2 ] || die "用法：pipeline_taint_count <cell> <rN>"
  local p
  p="$(_taint_count_path "$1" "$2")"
  if [ -s "$p" ]; then tr -d ' \r\n' < "$p"; printf '\n'; else printf '0\n'; fi
}

pipeline_taint_clear() { # <cell> <rN>
  [ $# -eq 2 ] || die "用法：pipeline_taint_clear <cell> <rN>"
  rm -f "$(_taint_count_path "$1" "$2")"
}

# pipeline_taint_bump <cell> <rN> <reason>：達預算即寫 needs-human（**只寫一次**），
# 之後佇列跳過該 replicate 續跑其餘 cells。
pipeline_taint_bump() {
  [ $# -eq 3 ] || die "用法：pipeline_taint_bump <cell> <rN> <reason>"
  local cell="$1" rep="$2" reason="$3" n p marker
  p="$(_taint_count_path "$cell" "$rep")"
  marker="$(_needs_human_path "$cell" "$rep")"
  mkdir -p "$(dirname "$p")"
  n="$(pipeline_taint_count "$cell" "$rep")"
  n=$((n + 1))
  printf '%s\n' "$n" > "$p"
  if [ "$n" -ge "$PIPELINE_TAINT_BUDGET" ] && [ ! -e "$marker" ]; then
    _pipeline_amend needs-human "${cell}/${rep}" \
      "連續 ${n} 次 taint/abort（最後一次：${reason}）" "pipeline taint-budget" \
      || log "needs-human amendment 寫入失敗（續行；下次仍會嘗試）"
    printf 'reason=%s\nat=%s\n' "$reason" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$marker"
    printf 'taint-budget: NEEDS-HUMAN %s/%s %s\n' "$cell" "$rep" "$n"
    return 0
  fi
  printf 'taint-budget: COUNT %s/%s %s\n' "$cell" "$rep" "$n"
}

# =============================================================================
# amendments：verdict.py 的「建議」→ manifest.py amend（由它配 seq）
# =============================================================================

_pipeline_amend() { # <type> <key> <value> <source>
  [ $# -eq 4 ] || die "用法：_pipeline_amend <type> <key> <value> <source>"
  python3 "$MANIFEST_PY" amend --results "$RESULTS_DIR" \
    --type "$1" --key "$2" --value "$3" --source "$4" >&2
}

# pipeline_apply_amendments <cell>：先問 verdict.py 的建議，再逐筆轉譯成 amend。
# **不得**自己 append journal——seq 是 manifest.py 的職責。
pipeline_apply_amendments() {
  [ $# -eq 1 ] || die "用法：pipeline_apply_amendments <cell>"
  local cell="$1" out lines n=0 atype key value source
  out="$(python3 "$VERDICT_PY" need-more-n "$cell" --emit-amend --results "$RESULTS_DIR")" \
    || { log "need-more-n 失敗：${cell}"; return 1; }
  printf '%s\n' "$out" | grep -v '^{' >&2 || true
  lines="$(printf '%s\n' "$out" | _pipeline_py amend-lines)" || lines=""
  while IFS=$'\t' read -r atype key value source; do
    [ -n "$atype" ] || continue
    _pipeline_amend "$atype" "$key" "$value" "$source" \
      || { log "amend 失敗：${atype} ${key}"; return 1; }
    n=$((n + 1))
  done <<< "$lines"
  printf 'amend: APPLIED %s %s\n' "$cell" "$n"
}

# =============================================================================
# watchdog：trigger-specific 修復（表見檔頭；不同 trigger 絕不共用修復動作）
# =============================================================================

# _watchdog_layer <trigger> <已失敗次數> → 這次要走的動作（human = 層 3）
_watchdog_layer() {
  case "$1" in
    collector-heartbeat) [ "$2" -lt 2 ] && { printf 'collector\n'; return 0; } ;;
    fio-heartbeat)       [ "$2" -lt 1 ] && { printf 'fio\n'; return 0; } ;;
    mon-quorum)          [ "$2" -lt 1 ] && { printf 'mon\n'; return 0; } ;;
    pg-no-progress)
      # 第一段一定是 repeer：真機實測 flapping 會讓 PG 的 recovering 清單卡住兩個
      # 物件永不完成（被 flap 的 OSD 進得了 up 卻進不了 acting），client 對那些
      # 物件的 read 就永遠停在 waiting for rw locks。`ceph pg repeer` 一下就解，
      # 而重開 node 完全沒用——問題不在任何一台機器上。
      [ "$2" -lt 1 ] && { printf 'pg-repeer\n'; return 0; }
      [ "$2" -lt 3 ] && { printf 'osd\n'; return 0; }
      [ "$2" -lt 5 ] && { printf 'node-reboot\n'; return 0; }
      [ "$2" -lt 6 ] && { printf 'az-restart\n'; return 0; }
      ;;
    node-ssh-lost)
      [ "$2" -lt 2 ] && { printf 'node-reboot\n'; return 0; }
      [ "$2" -lt 3 ] && { printf 'az-restart\n'; return 0; }
      ;;
    *) die "未知的 watchdog trigger：$1" ;;
  esac
  printf 'human\n'
}

# watchdog_handle <trigger> <ctx>
#   rc 0 = 修復成功（該 trigger 計數歸零）／1 = 這一層失敗（計數 +1，下次升級）／
#   3 = 層 3（HUMAN-NEEDED，佇列停）。
watchdog_handle() {
  [ $# -eq 2 ] || die "用法：watchdog_handle <trigger> <ctx>"
  local trig="$1" ctx="$2" n layer rc=0 state
  state="$(watchdog_state_path)"
  n="$(watchdog_count "$trig")"
  layer="$(_watchdog_layer "$trig" "$n")" || return 1
  if [ "$layer" = "human" ]; then
    _pipeline_py state "$state" bump "$trig" >/dev/null || log "watchdog 計數寫入失敗"
    _pipeline_halt_queue "watchdog ${trig} ${ctx}"
    printf 'watchdog: HUMAN-NEEDED %s %s\n' "$trig" "$ctx"
    return 3
  fi
  log "watchdog：trigger=${trig} ctx=${ctx} 第 $((n + 1)) 次，動作=${layer}"
  case "$layer" in
    collector)   _watchdog_repair_collector "$ctx" || rc=$? ;;
    fio)         _watchdog_repair_fio "$ctx" || rc=$? ;;
    mon)         _watchdog_repair_mon "$ctx" || rc=$? ;;
    osd)         _watchdog_repair_osd "$ctx" || rc=$? ;;
    pg-repeer)   _watchdog_repair_pg_repeer || rc=$? ;;
    node-reboot) _watchdog_repair_node_reboot "$ctx" || rc=$? ;;
    az-restart)  _watchdog_repair_az "$ctx" || rc=$? ;;
    *) die "內部錯誤：未知的 watchdog 動作 ${layer}" ;;
  esac
  if [ "$rc" -eq 0 ]; then
    _pipeline_py state "$state" clear "$trig" >/dev/null || log "watchdog 計數重置失敗"
    printf 'watchdog: REPAIRED %s\n' "$trig"
    return 0
  fi
  _pipeline_py state "$state" bump "$trig" >/dev/null || log "watchdog 計數寫入失敗"
  printf 'watchdog: FAILED %s %s\n' "$trig" "$layer"
  return 1
}

# collector trigger：**只重啟 collector**——sampler/bg-collector 死掉是量測工具問題，
# 動 OSD/cluster 只會把工具故障放大成叢集故障（plan §7 watchdog 第三層前的紅線）。
_watchdog_repair_collector() {
  log "collector 修復：${1}"
  bg_collect_ensure >&2 || log "bg_collect_ensure 失敗（續行判定）"
  bg_collect_assert_alive >&2
}

# fio trigger：client 側資料路徑重做（unmap/map）+ smoke 當成功判準；不碰 OSD。
_watchdog_repair_fio() {
  local smoke
  log "fio client 修復：${1}"
  smoke="${WATCHDOG_SMOKE_BUNDLE:-$RESULTS_DIR/.watchdog/fio-smoke}"
  fio_unmap_all >&2 || log "unmap 失敗（續行）"
  fio_map_all >&2 || { log "重新 map 失敗"; return 1; }
  rm -rf "$smoke"
  mkdir -p "$smoke"
  fio_smoke_real "$smoke" >&2
}

_watchdog_quorum_ok() {
  local n
  n="$(ceph_adm "ceph quorum_status --format json" 2>/dev/null | _pipeline_py quorum)" || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -eq 3 ]
}

# mon trigger：只 restart 該 mon；不得碰 OSD、不得 reboot node。
_watchdog_repair_mon() {
  local mon="$1"
  # handler 是同步的：整個修復期間佇列本來就取不到下一個 execution（= 停佇列）。
  ceph_adm_to "$WATCHDOG_DAEMON_SECS" "ceph orch daemon restart mon.${mon}" >&2 \
    || log "mon restart 指令失敗（續行判定 quorum）"
  with_deadline "$MON_QUORUM_SECS" _watchdog_quorum_ok || return 1
  ceph_wait_final_clean "$PIPELINE_PROGRESS_SECS" >&2
}

_pipeline_osd_for_node() { # <node> → osd id
  _inject_tree_load
  _inject_osd_for_node "$1"
}

# pg-no-progress：restart 相關 OSD（成功判準 = final_clean）；不碰 collector。
_watchdog_repair_osd() {
  local node="$1" id
  id="$(_pipeline_osd_for_node "$node")" || { log "查不到 ${node} 的 OSD id"; return 1; }
  ceph_adm_to "$WATCHDOG_DAEMON_SECS" "ceph orch daemon restart osd.${id}" >&2 \
    || log "osd.${id} restart 指令失敗（續行判定 final_clean）"
  ceph_wait_final_clean "$PIPELINE_PROGRESS_SECS" >&2
}

# pg-repeer：對每個非 active+clean 的 PG 下 repeer，重啟它的 peering/recovery
# 狀態機。不動任何 daemon、不重開機，是這個 trigger 最該先試的一段。
_watchdog_repair_pg_repeer() {
  local pgs pg n=0
  pgs="$(ceph_adm "ceph pg ls --format json" 2>/dev/null \
         | _ceph_py pgs-not-clean 2>/dev/null)" || pgs=""
  [ -n "$pgs" ] || { log "pg-repeer：查不到非 clean 的 PG（改由後續層級處理）"; return 1; }
  for pg in $pgs; do
    ceph_adm "ceph pg repeer ${pg}" >&2 || log "repeer 失敗（續行）：${pg}"
    n=$((n + 1))
  done
  log "pg-repeer：已對 ${n} 個 PG 下 repeer"
  ceph_wait_final_clean "$PIPELINE_PROGRESS_SECS" >&2
}

_watchdog_ssh_ok() { node_ssh "$_WATCHDOG_NODE" true >/dev/null 2>&1; }

# 2a：先用其他路徑（admin → 目標 node 的 ping）留一筆證據，再下 ssh reboot。
_watchdog_probe_from_admin() {
  local ip
  ip="$(inv_ip "$1" 2>/dev/null)" || return 0
  _node_sh "$ADMIN_NAME" "$WATCHDOG_SSH_SECS" \
    "ping -c 2 -W 2 ${ip} > /dev/null 2>&1 && echo ping-ok || echo ping-fail" >&2 \
    || log "admin 端 ping 探測失敗（續行）"
}

_watchdog_repair_node_reboot() {
  local node="$1"
  _watchdog_probe_from_admin "$node"
  _node_run "$node" "$WATCHDOG_SSH_SECS" "sudo reboot" >&2 \
    || log "ssh reboot 未正常回傳（node 可能已斷線）——續行等待恢復"
  _WATCHDOG_NODE="$node"
  with_deadline "$WATCHDOG_SSH_WAIT_SECS" _watchdog_ssh_ok || return 1
  # final_clean 的定義已含「OSD 全 up+in」，故 OSD rejoin 不另外判。
  ceph_wait_final_clean "$PIPELINE_PROGRESS_SECS" >&2
}

# 2b：ssh 完全失聯時的唯一 az 例外。**只重開機，絕不做任何會讓 VM 停止計費狀態的操作**
#（停機會讓本機磁碟資料與叢集狀態一起失去，且無人能在遠端把它開回來）。
_watchdog_repair_az() {
  local node="$1" rg="${AZ_RESOURCE_GROUP:-}"
  [ -n "$rg" ] || { log "AZ_RESOURCE_GROUP 未設定——無法走 2b"; return 1; }
  command -v az >/dev/null 2>&1 || { log "找不到 az CLI——無法走 2b"; return 1; }
  az vm restart --resource-group "$rg" --name "$node" --only-show-errors >&2 \
    || { log "az vm restart 失敗：${node}"; return 1; }
  _WATCHDOG_NODE="$node"
  with_deadline "$WATCHDOG_SSH_WAIT_SECS" _watchdog_ssh_ok || return 1
  ceph_wait_final_clean "$PIPELINE_PROGRESS_SECS" >&2
}

# =============================================================================
# per-execution cleanup scope（共用 common.sh 的 stack，只 unwind 自己那一段）
# =============================================================================

_pipeline_cleanup_mark() { _PIPELINE_CLEANUP_MARK="${#_CLEANUP_STACK[@]}"; }

# _pipeline_unwind：LIFO 執行並彈出「本次 execution 之後」推入的所有項目。
# 保留 mark 之前的項目（campaign 級：unflags、bg collector、暫存目錄…）。
_pipeline_unwind() {
  local mark="${_PIPELINE_CLEANUP_MARK:-0}" last cmd
  while [ "${#_CLEANUP_STACK[@]}" -gt "$mark" ]; do
    last=$(( ${#_CLEANUP_STACK[@]} - 1 ))
    cmd="${_CLEANUP_STACK[$last]}"
    unset "_CLEANUP_STACK[$last]"
    eval "$cmd" || log "cleanup 失敗（續行）：${cmd}"
  done
}

_pipeline_cleanup_fio() { # <bundle>：正常流程已收過就不重收（避免二次 remote 動作）
  [ -e "${1}/.fio-stopped" ] && return 0
  [ -s "${1}/fio/run.tsv" ] || return 0
  fio_stop "$1" >&2 || log "cleanup：fio_stop 非正常結束（exit proof 見 bundle）"
  : > "${1}/.fio-stopped"
  return 0
}

_pipeline_cleanup_inject() { # <bundle>：registry 是唯一 SoT，空的就不打 ssh
  inject_rollback_all "$1" >&2 || log "cleanup：注入回退未完全成功（見 log）"
  return 0
}

_pipeline_cleanup_sampler() { # <bundle>
  [ -e "${1}/.sampler-stopped" ] && return 0
  sampler_stop "$1" >&2 || log "cleanup：sampler_stop 失敗"
  : > "${1}/.sampler-stopped"
  return 0
}

_pipeline_cleanup_claim() { # <cell> <rN>
  claim_release "$1" "$2" >&2 || log "cleanup：claim 釋放失敗（${1}/${2}）"
  return 0
}

# =============================================================================
# Reconciler（crash-resume 的前置步；每個 run 腳本啟動時必跑）
# =============================================================================

_reconcile_flush_chains() {
  local node n=0
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    _node_sh "$node" "$INJECT_CMD_SECS" \
      "sudo iptables -F ${INJECT_CHAIN} 2>/dev/null || true" >/dev/null 2>&1 \
      || log "reconcile：${node} 的 ${INJECT_CHAIN} flush 失敗（續行）"
    n=$((n + 1))
  done <<< "$(inv_names osd)"
  log "reconcile：已掃過 ${n} 台 OSD node 的 ${INJECT_CHAIN} 殘留"
}

_reconcile_osds() {
  local id state up inn n=0
  for id in $(ceph_osd_ids); do
    state="$(ceph_osd_state "$id" 2>/dev/null)" || continue
    up="$(_ceph_state_field "$state" up)"
    inn="$(_ceph_state_field "$state" in)"
    if [ "$up" != "1" ]; then
      log "reconcile：osd.${id} 非預期 down，拉起"
      ceph_daemon_start "$id" || log "reconcile：osd.${id} start 失敗（續行）"
      n=$((n + 1))
    fi
    if [ "$inn" != "1" ]; then
      log "reconcile：osd.${id} 非預期 out，收回"
      ceph_osd_in "$id" || log "reconcile：osd.${id} in 失敗（續行）"
      n=$((n + 1))
    fi
  done
  log "reconcile：OSD 殘留修正 ${n} 次"
}

# registry 殘留：replicate 級的 fio / sampler / guard 一律清掉；
# campaign 級 collector（bgc-*）**不得**殺——它要跨 execution 活著。
_reconcile_registry() {
  local node runid pid st n=0
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    while read -r runid pid st; do
      [ -n "$runid" ] || continue
      case "$runid" in bgc-*) continue ;; esac
      log "reconcile：清除殘留背景 process ${runid}@${node}（pid=${pid:-?} ${st:-?}）"
      remote_bg_stop "$node" "$runid" >/dev/null 2>&1 \
        || log "reconcile：${runid}@${node} 清除失敗（續行）"
      n=$((n + 1))
    done <<< "$(remote_bg_list "$node" 2>/dev/null)"
  done <<< "$(inv_names)"
  printf '%s\n' "$n"
}

_reconcile_attempts() {
  local d n=0
  for d in "$RESULTS_DIR"/*/*/attempts/*; do
    [ -d "$d" ] || continue
    [ -e "$d/DONE" ] && continue
    [ -e "$d/ABORTED" ] && continue
    printf 'aborted_at=%s\nreason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      "reconcile：attempt 未 finalize（crash/中斷）" > "$d/ABORTED"
    log "reconcile：標記未 finalize 的 attempt 為 aborted：${d}"
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# PG 零進展時要交給 watchdog 的 node：優先取仍非 up+in 的那顆，
# 都正常就退回第一台 OSD node（restart 是有界動作，且 final_clean 是成功判準）。
_pipeline_stuck_node() {
  local id state node
  for id in $(ceph_osd_ids); do
    state="$(ceph_osd_state "$id" 2>/dev/null)" || continue
    [ "$(_ceph_state_field "$state" up)" = "1" ] \
      && [ "$(_ceph_state_field "$state" in)" = "1" ] && continue
    node="$(printf '%s\n' "${_INJECT_TREE_CACHE:-}" | awk -v i="$id" '$3 == i {print $1}')"
    if [ -n "$node" ]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  # 沒有任何 OSD 是 down/out 時，卡住的原因不在某台機器上（真機實測：八顆全部
  # up+in，卡的是一個 PG 的 recovery）。原本這裡直接回傳 inventory 第一台，
  # watchdog 於是重開了一台跟問題完全無關的健康節點。改成先問「卡住的 PG 的
  # primary 是誰」，問不出來才退回第一台並明講這是猜的。
  node="$(_pipeline_stuck_pg_primary_node)" || node=""
  if [ -n "$node" ]; then
    printf '%s\n' "$node"
    return 0
  fi
  log "_pipeline_stuck_node：無 down/out 的 OSD 也找不到卡住的 PG primary，退回第一台（此為猜測）"
  inv_names osd | head -1
}

# 卡住的 PG 的 primary 所在的 node（找不到就回非 0）。
_pipeline_stuck_pg_primary_node() {
  local id
  id="$(ceph_adm "ceph pg ls --format json" 2>/dev/null \
        | _ceph_py pgs-not-clean-primary 2>/dev/null | head -1)" || return 1
  [ -n "$id" ] || return 1
  printf '%s\n' "$(printf '%s\n' "${_INJECT_TREE_CACHE:-}" | awk -v i="$id" '$3 == i {print $1}')"
}

reconcile() {
  local killed aborted rc=0
  runner_lock_acquire >&2 || die "reconcile：runner lock 被其他 runner 持有（拒絕併發）"
  _pipeline_reset_runtime_state
  _reconcile_flush_chains
  _reconcile_osds
  killed="$(_reconcile_registry)"
  aborted="$(_reconcile_attempts)"
  bg_collect_ensure >&2 || log "reconcile：bg collector 重啟失敗（續行）"
  ceph_wait_final_clean "$PIPELINE_PROGRESS_SECS" >&2 || rc=$?
  if [ "$rc" -eq 3 ]; then
    log "reconcile：final_clean 零進展，交 watchdog"
    watchdog_handle pg-no-progress "$(_pipeline_stuck_node)" >&2 || {
      printf 'reconcile: BLOCKED pg-no-progress\n'
      return 1
    }
  elif [ "$rc" -ne 0 ]; then
    printf 'reconcile: BLOCKED final-clean rc=%s\n' "$rc"
    return 1
  fi
  printf 'reconcile: PASS killed=%s aborted=%s\n' "$killed" "$aborted"
}

# =============================================================================
# Replicate Pipeline（steady / fault / chaos 是同一台狀態機的參數化路徑）
# =============================================================================

# 量測窗的 supervisor：每一輪都做 coverage / sampler 檢查，再判停止條件。
# stop-fn 的契約由 fio_wait_segments 定義（rc 0 = 停止條件成立）。
_pipeline_measure_tick() {
  local now slice _pipe_rcout _pipe_rcrc
  now="$(date +%s)"
  _claim_touch "$_PIPE_CELL" "$_PIPE_REP"
  _pipeline_coverage_tick "$now"
  _pipeline_sampler_tick
  case "$_PIPE_KIND" in
    fault)
      # 把「等 recovery_complete」切成 cadence 大小的片段，coverage supervisor 才跑得到
      slice=$((now + PIPELINE_TICK_SECS))
      [ "$slice" -gt "$_PIPE_DEADLINE" ] && slice="$_PIPE_DEADLINE"
      # 時間戳一定要落進 timeline：原本只把 `recovery-complete: reached <epoch>`
      # 印到 stderr 就丟掉，於是 fault-timeline.json 永遠沒有 recovery_complete_t，
      # time_to_recovery_complete_s 這個 endpoint 每個故障 cell 都是 null——
      # 明明 censor-status 已經判定 censored=false（recovery 確實完成了）。
      _pipe_rcout="$(ceph_wait_recovery_complete "$slice")"
      _pipe_rcrc=$?
      printf '%s\n' "$_pipe_rcout" >&2
      case "$_pipe_rcout" in
        "recovery-complete: reached "*)
          inject_timeline_set "$_PIPE_BUNDLE" \
            recovery_complete_t="${_pipe_rcout##* }" >&2
          ;;
      esac
      return "$_pipe_rcrc"
      ;;
    *)
      _FIO_WD_BUNDLE="$_PIPE_BUNDLE"
      _fio_all_done
      ;;
  esac
}

# _pipeline_fio_crashed <bundle>：exit proof 裡有沒有「非 0 且非 TIMEOUT」的 client。
# TIMEOUT 代表被故障卡住（有效觀測）；非 0 exit code 才是工具自己崩了。
_pipeline_fio_crashed() {
  local proof="$1/fio-exit-proof.json"
  [ -s "$proof" ] || return 1
  python3 - "$proof" <<'PY'
import json
import sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for info in (doc.get("clients") or {}).values():
    rc = info.get("exit_code")
    if rc is not None and int(rc) != 0:
        sys.exit(0)
sys.exit(1)
PY
}

_pipeline_taint_attempt() { # <reason>
  [ "$_PIPE_TAINTED" = "1" ] && return 0
  _PIPE_TAINTED=1
  _PIPE_REASON="$1"
  inject_taint "$_PIPE_BUNDLE" "$1"
}

_pipeline_coverage_tick() { # <now>
  local now="$1"
  [ $((now - _PIPE_LAST_COV)) -ge "$COVERAGE_CADENCE_SECS" ] || return 0
  _PIPE_LAST_COV="$now"
  if coverage_check "$_PIPE_BUNDLE" "$now" >&2; then
    _PIPE_GAP_STREAK=0
    return 0
  fi
  _PIPE_GAP_STREAK=$((_PIPE_GAP_STREAK + 1))
  log "coverage supervisor：第 ${_PIPE_GAP_STREAK} 次連續退化"
  if [ "$_PIPE_GAP_STREAK" -ge "$PIPELINE_COVERAGE_GAP_LIMIT" ]; then
    # 量測**繼續**跑（保 cluster 安全回收），但這個 attempt 不得 finalize 為有效 replicate
    _pipeline_taint_attempt "coverage-gap（連續 ${_PIPE_GAP_STREAK} 次 heartbeat 退化）"
    watchdog_handle collector-heartbeat "$_PIPE_BUNDLE" >&2 || true
  fi
  return 0
}

_pipeline_sampler_tick() {
  sampler_assert_alive "$_PIPE_BUNDLE" >&2 && return 0
  _pipeline_taint_attempt "sampler heartbeat 失聯"
  watchdog_handle collector-heartbeat "$_PIPE_BUNDLE" >&2 || true
  return 0
}

_pipeline_final_clean_gate() {
  local rc=0
  ceph_wait_final_clean "$PIPELINE_PROGRESS_SECS" >&2 || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 3 ]; then
    # PG 零進展 → watchdog（它自己的成功判準就是 final_clean）
    watchdog_handle pg-no-progress "$(_pipeline_stuck_node)" >&2 || return 1
    return 0
  fi
  return 1
}

_pipeline_inject() {
  local b="$_PIPE_BUNDLE" id
  case "$_PIPE_MECH" in
    osd-down)
      id="$(_pipeline_osd_for_node "$_PIPE_NODE")" || return 1
      _PIPE_OSD="$id"
      fault_osd_down "$id" "$b" >&2
      ;;
    flapping)
      id="$(_pipeline_osd_for_node "$_PIPE_NODE")" || return 1
      _PIPE_OSD="$id"
      fault_flapping "$id" "$b" >&2
      ;;
    node-isolation) fault_node_isolate "$_PIPE_NODE" "$b" >&2 ;;
    rack-isolation) fault_rack_isolate "$_PIPE_RACK" "$b" >&2 ;;
    *) die "未支援的故障機制：${_PIPE_MECH}" ;;
  esac
}

_pipeline_recover() {
  local b="$_PIPE_BUNDLE"
  case "$_PIPE_MECH" in
    osd-down)       fault_osd_down_recover "$_PIPE_OSD" "$b" >&2 ;;
    flapping)       : ;;   # 不 out、10 輪結束即回到 up+in，沒有額外回歸動作
    node-isolation) fault_node_heal "$_PIPE_NODE" "$b" >&2 ;;
    rack-isolation) fault_rack_heal "$_PIPE_RACK" "$b" >&2 ;;
    *) die "未支援的故障機制：${_PIPE_MECH}" ;;
  esac
}

# drift gate：單次只記 covariate，連續 PIPELINE_DRIFT_LIMIT 次才停佇列要求 recalibrate。
_pipeline_baseline_gate() {
  local out rc=0 streak
  out="$(python3 "$VERDICT_PY" baseline-check "$_PIPE_BUNDLE" --results "$RESULTS_DIR")" || rc=$?
  printf '%s\n' "$out" >&2
  case "$out" in
    *baseline-drift*)
      streak="$(_pipeline_py state "$(watchdog_state_path)" drift-bump)" || streak=0
      log "baseline drift：連續 ${streak} 個 replicate"
      if [ "${streak:-0}" -ge "$PIPELINE_DRIFT_LIMIT" ]; then
        _pipeline_halt_queue "baseline drift 連續 ${streak} 次——需要 recalibrate 裁決"
      fi
      ;;
    *)
      _pipeline_py state "$(watchdog_state_path)" drift-clear >/dev/null || true
      ;;
  esac
  if [ "$rc" -eq 4 ]; then
    _pipeline_halt_queue "baseline-check HUMAN-NEEDED（recalibrate）"
  fi
  return 0
}

_pipeline_freeze_prediction() {
  local src="${_PIPE_BUNDLE}/.prediction-src.json" rc=0
  _pipeline_py prediction "$_PIPE_EXEC" "$src" "$_PIPE_RATE" || return 1
  python3 "$VERDICT_PY" freeze "$_PIPE_BUNDLE" --prediction "$src" >&2 || rc=1
  rm -f "$src"
  return "$rc"
}

# _pipeline_attempt：rc 0 = 可 finalize／4 = attempt taint（不得 finalize）／1 = abort。
# 呼叫端負責 cleanup unwind 與重試預算，本函式只跑序列。
_pipeline_attempt() {
  local b="$_PIPE_BUNDLE" mode t0 deadline guard t_in t_clean wrc=0 irc=0

  # --- preflight：設 profile → qos gate（含 mclock scheduler / skip_benchmark）
  #     + final_clean + collector ---
  # 順序不可倒：`ceph_set_profile` 只下指令（冪等），八顆是否同時收斂到該 profile
  # 一律由 `ceph_qos_gate` 判定——gate 仍是 preflight 的唯一通過判準。
  ceph_set_profile "$_PIPE_PROFILE" >&2 || { _PIPE_REASON="set-profile"; return 1; }
  ceph_qos_gate "$_PIPE_PROFILE" "$b" >&2 || { _PIPE_REASON="qos-gate"; return 1; }
  _pipeline_final_clean_gate || { _PIPE_REASON="preflight-final-clean"; return 1; }
  bg_collect_assert_alive >&2 || bg_collect_ensure >&2 \
    || { _PIPE_REASON="bg-collector"; return 1; }

  # --- prediction freeze（注入之前；寫入後不可變）---
  _pipeline_freeze_prediction || { _PIPE_REASON="prediction-freeze"; return 1; }

  # --- sampler：先 start 才 assert（順序不可倒）---
  sampler_start "$b" >&2 || { _PIPE_REASON="sampler-start"; return 1; }
  cleanup_push "_pipeline_cleanup_sampler '$b'"
  # 注入回退先於 fio 推入，LIFO 才會是「停 fio → 回退注入 → sampler_stop → 釋放 claim」；
  # registry 空的時候它是 no-op，所以提早推入沒有副作用。
  cleanup_push "_pipeline_cleanup_inject '$b'"
  sampler_assert_alive "$b" >&2 || { _PIPE_REASON="sampler-dead"; return 1; }

  # --- fio 先行：workload 必須在注入之前就已進入穩定窗 ---
  case "$_PIPE_KIND" in
    steady) mode=steady ;;
    *)      mode=segment ;;
  esac
  fio_start_bg "$b" "$mode" "$_PIPE_SHAPE" "$_PIPE_RATE" >&2 \
    || { _PIPE_REASON="fio-start"; return 1; }
  cleanup_push "_pipeline_cleanup_fio '$b'"
  fio_readiness_barrier "$b" >&2 || { _PIPE_REASON="fio-readiness"; return 1; }

  t0="$(date +%s)"
  _PIPE_T0="$t0"
  _PIPE_WIN_START="$t0"
  # 從窗一開始就讓 supervisor 打卡——注入期間（flapping 要 9 分鐘）量測迴圈還沒
  # 開始跑，少了這個覆寫，那整段都會被記成「supervisor 中斷」而作廢。
  # shellcheck disable=SC2329
  # 間接呼叫：with_deadline 在每輪輪詢會叫 progress_tick（common.sh 的預設 no-op 覆寫點）。
  progress_tick() { _pipeline_coverage_tick "$(date +%s)"; _pipeline_sampler_tick; }

  case "$_PIPE_KIND" in
    fault)
      [ "$_PIPE_CAP" = "-" ] && die "fault execution 缺 measurement_cap（${_PIPE_CELL}）"
      deadline=$((t0 + _PIPE_CAP))
      _PIPE_DEADLINE="$deadline"
      # inject.sh 要靠這兩個 env 才驗得了 guard 不變條件
      MEASUREMENT_CAP="$_PIPE_CAP"
      MEASUREMENT_DEADLINE="$deadline"
      export MEASUREMENT_CAP MEASUREMENT_DEADLINE
      guard="$(inject_guard_secs "$_PIPE_CAP" "$deadline")"
      inject_timeline_set "$b" fault_t0="$t0" measurement_cap="$_PIPE_CAP" \
        measurement_deadline="$deadline" guard_deadline_secs="$guard" \
        fault="$_PIPE_FAULT" mechanism="$_PIPE_MECH"
      _pipeline_inject || irc=$?
      if [ "$irc" -eq 4 ]; then
        _pipeline_taint_attempt "注入回報 taint（rc 4）"
      elif [ "$irc" -ne 0 ]; then
        _PIPE_REASON="inject-failed"
        return 1
      fi
      # 量測窗：fio 續跑至 recovery_complete 或 measurement_deadline
      fio_wait_segments "$b" _pipeline_measure_tick "$deadline" || wrc=$?
      ;;
    steady)
      unset MEASUREMENT_DEADLINE
      deadline=$((t0 + FIO_STEADY_SECS + FIO_RAMP_SECS + FIO_RUN_SLACK_SECS))
      _PIPE_DEADLINE="$deadline"
      fio_wait_segments "$b" _pipeline_measure_tick "$deadline" || wrc=$?
      ;;
    chaos)
      unset MEASUREMENT_DEADLINE
      [ "$_PIPE_DURATION" = "-" ] && die "chaos execution 缺 fault_params.duration"
      _PIPE_DEADLINE=$((t0 + _PIPE_DURATION))
      # chaos 沒有 measurement cap：guard 錨在 duration（plan v4.2/F5-9）
      guard="$(inject_guard_secs "$_PIPE_DURATION" -)"
      inject_timeline_set "$b" chaos_t0="$t0" guard_deadline_secs="$guard"
      # 事件序列與 fio 平行跑到 duration 結束；coverage 的連續性由 coverage_finalize 驗
      chaos_run "$_PIPE_SEED" "$_PIPE_DURATION" "$b" >&2 \
        || { _PIPE_REASON="chaos-run"; return 1; }
      ;;
  esac
  _PIPE_WIN_END="$(date +%s)"

  case "$wrc" in
    0) : ;;
    124)
      if [ "$_PIPE_KIND" = "fault" ]; then
        _PIPE_CENSORED=true
        log "撞 measurement cap（right-censored——是有效觀測，不是失敗）"
      else
        _PIPE_REASON="workload-timeout"
        return 1
      fi
      ;;
    2)
      _pipeline_taint_attempt "fio 失聯（fio_wait_segments rc 2）"
      watchdog_handle fio-heartbeat "$b" >&2 || true
      ;;
    *) _PIPE_REASON="measure-rc-${wrc}"; return 1 ;;
  esac

  # --- 停 fio（收 exit proof）---
  # fio 收尾異常分兩種，後果完全不同：
  #   * 非 0 exit code = fio 自己崩了 → 那段沒有資料是**工具壞掉**，attempt 作廢。
  #   * TIMEOUT 但心跳仍活 = fio 被故障卡在 D-state（H-033）→ 那正是要量的現象，
  #     是有效觀測，不作廢（devstat 逐秒仍在記，coverage 有證據）。
  # 這個區分在 coverage 改用 gaps 判定之後尤其重要：少了它，崩掉的 fio 會被 devstat
  # 的覆蓋蓋過去，變成「一段很長的 stall」被當成真實現象記進報告。
  fio_stop "$b" >&2 || log "fio 非正常結束（exit proof 見 bundle）"
  if _pipeline_fio_crashed "$b"; then
    _pipeline_taint_attempt "fio 以非 0 exit code 結束（crash，非故障造成的卡住）"
  fi
  : > "${b}/.fio-stopped"

  # --- 回歸 + safety gate（H-008：記回歸開始與 final_clean 兩時戳）---
  if [ "$_PIPE_KIND" = "fault" ]; then
    _pipeline_recover || { _PIPE_REASON="recover-failed"; return 1; }
    t_in="$(date +%s)"
    _pipeline_final_clean_gate || { _PIPE_REASON="safety-final-clean"; return 1; }
    t_clean="$(date +%s)"
    ceph_health_snapshot "${b}/final-clean-proof.json"
    ceph_check_laggy "${b}/laggy.json"
    collect_return_backfill "$b" "$t_in" "$t_clean" >&2 \
      || log "return-backfill 產生失敗（續行）"
  elif [ "$_PIPE_KIND" = "chaos" ]; then
    _pipeline_final_clean_gate || { _PIPE_REASON="safety-final-clean"; return 1; }
    ceph_check_laggy "${b}/laggy.json"
  fi

  # --- baseline 復測（60s，同形態同壓力固定速率）+ drift gate ---
  fio_run_baseline "$b" "$_PIPE_SHAPE" "$_PIPE_PRESSURE" "$_PIPE_RATE" >&2 \
    || log "baseline 復測失敗（drift gate 會據此判定）"
  _pipeline_baseline_gate

  # --- 收尾：sampler 停了才收資料，coverage proof 要有本地樣本才驗得了 ---
  sampler_stop "$b" >&2 || log "sampler 停止失敗（續行）"
  : > "${b}/.sampler-stopped"
  collect_cell "$b" "$_PIPE_KIND" "$_PIPE_WIN_START" "$_PIPE_WIN_END" >&2 \
    || { _PIPE_REASON="collect-cell"; return 1; }
  [ "$_PIPE_KIND" = "steady" ] \
    || COVERAGE_GAP_TOLERANCE_SECS="$COVERAGE_GAP_TOLERANCE_FAULT_SECS"
  coverage_finalize "$b" "$_PIPE_WIN_START" "$_PIPE_WIN_END" >&2 \
    || _pipeline_taint_attempt "coverage-proof 標記 tainted"
  if [ "$_PIPE_KIND" != "steady" ]; then
    inject_cleanup_proof "$b" >&2 || _pipeline_taint_attempt "cleanup proof 不乾淨"
  fi
  if [ "$_PIPE_KIND" = "fault" ]; then
    _pipeline_py censor "${b}/censor-status.json" "$_PIPE_CENSORED" "$_PIPE_CAP" \
      "$_PIPE_T0" "$_PIPE_DEADLINE" "$_PIPE_WIN_END" \
      || { _PIPE_REASON="censor-status"; return 1; }
  fi

  # tainted 的 attempt 禁止 finalize 為有效 replicate（證據仍留在 bundle 供診斷）
  [ "$_PIPE_TAINTED" = "1" ] && return 4

  python3 "$VERDICT_PY" aggregate "$b" >&2 || { _PIPE_REASON="aggregate"; return 1; }
  python3 "$VERDICT_PY" verdict "$b" >&2 || { _PIPE_REASON="verdict"; return 1; }
  # 交叉核對（cell/profile/manifest-hash/時間窗/freeze sha/tainted）——bundle_finalize
  # 只吃必備檔清單，所以這一步一定要顯式呼叫，否則核對永遠不會執行。
  python3 "$VERDICT_PY" schemas "$_PIPE_KIND" --verify "$b" \
    --manifest-hash "$_PIPE_HASH" >&2 || { _PIPE_REASON="cross-check"; return 1; }
  bundle_finalize "$b" "$_PIPE_KIND" >&2 || { _PIPE_REASON="finalize"; return 1; }
  return 0
}

pipeline_run_execution() { # <execution-json>
  [ $# -eq 1 ] || die "用法：pipeline_run_execution <execution-json>"
  local exec_json="$1" summary key rc=0
  [ -s "$exec_json" ] || die "execution JSON 不存在或是空的：${exec_json}"
  summary="$(_pipeline_py exec-summary "$exec_json" "$(calibration_path)")" \
    || die "execution JSON 解析失敗：${exec_json}"
  IFS=$'\t' read -r _PIPE_CELL _PIPE_REP _PIPE_KIND _PIPE_PROFILE _PIPE_SHAPE \
    _PIPE_PRESSURE _PIPE_FAULT _PIPE_MECH _PIPE_CAP _PIPE_GUARD _PIPE_HASH \
    _PIPE_NODE _PIPE_RACK _PIPE_SEED _PIPE_DURATION _PIPE_RATE _PIPE_GROUP \
    <<< "$summary"
  _PIPE_EXEC="$exec_json"
  key="${_PIPE_CELL}/${_PIPE_REP}"
  [ "$_PIPE_HASH" = "-" ] && die "execution 缺 manifest_hash（${key}）——prediction 無從綁定排程"

  # 層 3 之後佇列必須停：不得再開新的 execution
  if watchdog_halted; then
    printf 'pipeline: HALTED %s\n' "$key"
    return 3
  fi
  # 重試預算耗盡的 replicate：跳過續跑其餘 cells（needs-human 已在 journal）
  if [ -e "$(_needs_human_path "$_PIPE_CELL" "$_PIPE_REP")" ]; then
    printf 'pipeline: SKIP %s needs-human\n' "$key"
    return 5
  fi
  claim_acquire "$_PIPE_CELL" "$_PIPE_REP" >&2 || {
    printf 'pipeline: BUSY %s\n' "$key"
    return 6
  }
  _pipeline_cleanup_mark
  cleanup_push "_pipeline_cleanup_claim '$_PIPE_CELL' '$_PIPE_REP'"
  _PIPE_BUNDLE="$(new_bundle "$_PIPE_CELL" "$_PIPE_REP")"
  _PIPE_GAP_STREAK=0
  _PIPE_LAST_COV=0
  _PIPE_TAINTED=0
  _PIPE_REASON=""
  _PIPE_CENSORED=false
  _PIPE_OSD="-"
  _PIPE_T0=0
  _PIPE_DEADLINE=0
  _PIPE_WIN_START=0
  _PIPE_WIN_END=0
  log "execution 開始：${key} kind=${_PIPE_KIND} profile=${_PIPE_PROFILE} bundle=${_PIPE_BUNDLE}"

  _pipeline_attempt || rc=$?
  # 任何出口（成功/taint/abort/中斷）都走同一個 cleanup stack
  _pipeline_unwind

  case "$rc" in
    0)
      pipeline_taint_clear "$_PIPE_CELL" "$_PIPE_REP"
      printf 'pipeline: DONE %s\n' "$key"
      return 0
      ;;
    4)
      pipeline_taint_bump "$_PIPE_CELL" "$_PIPE_REP" "${_PIPE_REASON:-taint}" >&2
      printf 'pipeline: TAINT %s %s\n' "$key" "${_PIPE_REASON:-taint}"
      return 4
      ;;
    *)
      pipeline_taint_bump "$_PIPE_CELL" "$_PIPE_REP" "${_PIPE_REASON:-abort}" >&2
      printf 'pipeline: ABORT %s %s\n' "$key" "${_PIPE_REASON:-abort}"
      return 1
      ;;
  esac
}
