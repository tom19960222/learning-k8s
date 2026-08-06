#!/usr/bin/env bash
# run/ 薄入口（Task 13/14）測試共用的沙箱工具。
#
# 測試策略
# --------
# run/*.sh 的正確性 = 「以什麼順序、帶什麼參數呼叫 pipeline / manifest / verdict」，
# 而**不是**它自己做了什麼遠端動作。因此：
#   1. 在 tmp 沙箱裡重建 `run/` + `lib/` 目錄結構，`lib/pipeline.sh` 換成 recorder 替身
#      （真的 `lib/common.sh` 照用——require_inject_flag / cleanup stack / log / die
#      是入口真的會走的路徑）。入口若試圖繞過 pipeline 自己下遠端指令，替身沒有那些
#      函式 → 直接 unbound/command not found，測試會紅。
#   2. `manifest.py` 用**真的**（trim 過的 manifest），所以 `next` 的 exit 3、kind 過濾、
#      amendments journal 的 seq 都是真契約。
#   3. `verdict.py` 用假的（margins / schedule-estimate / audit 的輸出是可控旋鈕）。
# shellcheck shell=bash

RT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- assertion helpers --------------------------------------------------------

RT_ASSERTS=0
rt_fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
rt_ok() { RT_ASSERTS=$((RT_ASSERTS + 1)); }
rt_eq() { [ "$1" = "$2" ] || rt_fail "$3（got=[$1] want=[$2]）"; rt_ok; }
rt_has() { grep -qF -- "$2" "$1" || rt_fail "$3：未含 [$2]"; rt_ok; }
rt_hasnt() { grep -qF -- "$2" "$1" && rt_fail "$3：不該含 [$2]"; rt_ok; }
rt_has_re() { grep -qE -- "$2" "$1" || rt_fail "$3：未匹配 /$2/"; rt_ok; }
# rt_before <file> <a> <b> <msg>：a 必須出現在 b 之前（順序即規格）
rt_before() {
  local ia ib
  ia="$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1)"
  ib="$(grep -nF -- "$3" "$1" | head -1 | cut -d: -f1)"
  [ -n "$ia" ] || rt_fail "$4：找不到 [$2]"
  [ -n "$ib" ] || rt_fail "$4：找不到 [$3]"
  [ "$ia" -lt "$ib" ] || rt_fail "$4：[$2]($ia) 未出現在 [$3]($ib) 之前"
  rt_ok
}

# --- 「薄入口」的靜態斷言 -------------------------------------------------------
# 入口只准編排：實質工作（遠端動作、注入、量測、journal 寫入）一律在 lib/ 裡。
# 這串 token 直接對應各 lib 的對外函式；入口出現任何一個就是繞過 pipeline。
RT_FORBIDDEN=(
  node_ssh ceph_adm ceph_wait_ ceph_daemon_ ceph_osd_ ceph_qos_gate
  fault_flapping fault_osd_down fault_node_isolate fault_rack_isolate chaos_run
  sampler_start sampler_stop coverage_check collect_cell
  fio_start_bg fio_readiness_barrier fio_run_ fio_map_all fio_unmap_all
  inject_rollback_all inject_cleanup_proof remote_bg_start remote_bg_stop
  iptables schedule-amendments
)

rt_assert_thin() { # <file> [白名單 token...]
  local f="$1" tok allow skip code
  shift
  # 只看程式碼（整行註解裡本來就會提到這些函式名，那是說明不是呼叫）
  code="$(grep -v '^[[:space:]]*#' "$f")"
  for tok in "${RT_FORBIDDEN[@]}"; do
    skip=0
    for allow in "$@"; do
      [ "$allow" = "$tok" ] && skip=1
    done
    if [ "$skip" -eq 0 ] && printf '%s\n' "$code" | grep -q -- "$tok"; then
      rt_fail "$(basename "$f") 不該直接用 ${tok}——實質工作必須留在 lib/pipeline.sh"
    fi
    rt_ok
  done
}

# --- 沙箱 ---------------------------------------------------------------------

# rt_sandbox <sandbox-dir> <run-script>...：建出 run/ + lib/ 與各式替身
rt_sandbox() {
  local sb="$1" s
  shift
  mkdir -p "$sb/run" "$sb/lib"
  cp "$RT_ROOT/lib/common.sh" "$sb/lib/common.sh"
  cp "$RT_ROOT/run/queue.sh" "$sb/run/queue.sh"
  for s in "$@"; do
    cp "$RT_ROOT/run/$s" "$sb/run/$s"
  done
  rt_write_pipeline_stub "$sb/lib/pipeline.sh"
  rt_write_verdict_fake "$sb/fake-verdict.py"
}

# 每個測試案例前重置可觀測狀態（trace / log / rc 腳本）
rt_reset() {
  RT_TRACE="$RT_TMP/trace.log"
  RT_EXECS="$RT_TMP/execs"
  RT_VERDICT_LOG="$RT_TMP/verdict.log"
  RT_PIPELINE_RCS="$RT_TMP/pipeline.rcs"
  RT_AUDIT_SNAPSHOT="$RT_TMP/audit-snapshot"
  export RT_TRACE RT_EXECS RT_VERDICT_LOG RT_PIPELINE_RCS RT_AUDIT_SNAPSHOT
  rm -rf "$RT_EXECS" "$RT_AUDIT_SNAPSHOT"
  mkdir -p "$RT_EXECS"
  : > "$RT_TRACE"
  : > "$RT_VERDICT_LOG"
  : > "$RT_PIPELINE_RCS"
  rm -rf "$RESULTS_DIR"
  mkdir -p "$RESULTS_DIR"
}

# rt_manifest <keep-json> [fault-type,...]：產真 manifest 後 trim（測試跑得完才有意義）
#   keep-json 的 key：steady / fault / chaos = 該 kind 保留幾個 cell；
#   `fault_per_type` = 每個故障型各保留幾個——**pilot 相關測試一定要用它**，因為
#   `manifest.py next --pilot` 會對全部故障型求 pilot，少一型或缺 pilot cell 就直接 die。
rt_manifest() {
  local must=""
  # 完整 manifest（63 cells）與 pilot 清單每個測試檔只算一次，之後複製使用
  if [ ! -s "$RT_TMP/manifest-full.json" ]; then
    python3 "$RT_ROOT/lib/manifest.py" generate \
      --inventory "$RT_ROOT/tests/fixtures/inventory.json" \
      --out "$RT_TMP/manifest-full.json" --results "$RT_TMP" >/dev/null 2>&1 \
      || rt_fail "manifest generate 失敗"
    python3 "$RT_ROOT/lib/manifest.py" pilots --results "$RT_TMP" \
      --manifest "$RT_TMP/manifest-full.json" \
      | python3 -c 'import json,sys
sys.stdout.write(",".join(json.loads(l)["cell_id"] for l in sys.stdin if l.strip()))' \
      > "$RT_TMP/pilot-ids.txt" \
      || rt_fail "取 pilot cell 失敗"
  fi
  mkdir -p "$RESULTS_DIR"
  cp "$RT_TMP/manifest-full.json" "$RESULTS_DIR/manifest.json"
  case "$1" in
    *fault_per_type*) must="$(cat "$RT_TMP/pilot-ids.txt")" ;;
  esac
  python3 - "$RESULTS_DIR/manifest.json" "$1" "${2:-}" "$must" <<'PY' || rt_fail "manifest trim 失敗"
import collections
import json
import sys

path, want_json, fault_csv, must_csv = sys.argv[1:5]
man = json.load(open(path))
want = json.loads(want_json)
faults = [f for f in fault_csv.split(",") if f] or None
must = set(f for f in must_csv.split(",") if f)
cnt = collections.Counter()
kept_ids = set()


def bucket(cell):
    if cell["kind"] == "fault" and "fault_per_type" in want:
        return ("fault", cell["fault"]), want["fault_per_type"]
    return cell["kind"], want.get(cell["kind"], 0)


# pass 1：pilot cell 一律保留（否則 `next --pilot` 找不到 pilot 會 die）
for cell in man["cells"]:
    if cell["cell_id"] in must:
        cnt[bucket(cell)[0]] += 1
        kept_ids.add(cell["cell_id"])
# pass 2：其餘按額度補滿
for cell in man["cells"]:
    if cell["cell_id"] in kept_ids:
        continue
    if faults is not None and cell["kind"] == "fault" and cell["fault"] not in faults:
        continue
    key, limit = bucket(cell)
    if cnt[key] >= limit:
        continue
    cnt[key] += 1
    kept_ids.add(cell["cell_id"])

man["cells"] = [c for c in man["cells"] if c["cell_id"] in kept_ids]
man["counts"] = {"cells": len(man["cells"]),
                 "executions": sum(c["base_n"] for c in man["cells"])}
with open(path, "w") as fh:
    json.dump(man, fh, indent=2, sort_keys=True, ensure_ascii=False)
    fh.write("\n")
PY
}

# rt_stage_stubs <sandbox>：把 all.sh 會呼叫的段替換成 recorder 替身。
# all.sh 自己的規格是「段的順序 / marker 續跑 / 人工 gate 對應 / 收尾順序」，
# 各段內部的正確性由 test-steady.sh / test-faults.sh / 本檔的 chaos 段負責。
rt_stage_stubs() {
  local sb="$1" name
  mkdir -p "$RT_STAGE_RC_DIR"
  for name in calibrate steady faults chaos; do
    cat > "$sb/run/${name}.sh" <<'STAGE'
#!/usr/bin/env bash
set -u
name="$(basename "$0" .sh)"
printf '%s %s\n' "$name" "$*" >> "$RT_TRACE"
rc=0
[ -s "$RT_STAGE_RC_DIR/$name" ] && rc="$(cat "$RT_STAGE_RC_DIR/$name")"
printf '%s: STUB-DONE\n' "$name"
exit "$rc"
STAGE
  done
}

rt_stage_rc() { # <stage> <rc>
  printf '%s\n' "$2" > "$RT_STAGE_RC_DIR/$1"
}

rt_stage_rc_clear() { rm -f "$RT_STAGE_RC_DIR"/*; }

# rt_run <sandbox> <script> [args...]：跑入口，stdout→$RT_OUT、stderr→$RT_ERR、rc→$RT_RC
rt_run() {
  local sb="$1" script="$2"
  shift 2
  RT_OUT="$RT_TMP/stdout.txt"
  RT_ERR="$RT_TMP/stderr.txt"
  RT_RC=0
  # shellcheck disable=SC2034  # RT_RC 是給 source 本檔的 test-*.sh 讀的 out-param
  bash "$sb/run/$script" "$@" > "$RT_OUT" 2> "$RT_ERR" || RT_RC=$?
}

# --- pipeline recorder 替身 ----------------------------------------------------

rt_write_pipeline_stub() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
# 測試替身：只記錄「入口呼叫了什麼」。真流程在 lib/pipeline.sh，已由 test-pipeline.sh 驗。
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
[ -n "${MCLOCK_PIPELINE_LOADED:-}" ] && return 0
MCLOCK_PIPELINE_LOADED=1
# shellcheck source=./common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# inject_confirm 真品在 lib/inject.sh，而沙箱只放 common.sh + pipeline stub。
# 少了它，入口的 `inject_confirm "$@"` 會是 command not found——沒有 set -e 就
# **繼續往下跑**，於是「拒跑時不得碰下游」的斷言看到 inventory_load 而失敗，
# 卻完全沒指出真正的原因。行為與真品一致：檢查旗標並設下確認狀態。
inject_confirm() {
  require_inject_flag "$@"
  INJECT_CONFIRMED=1
  export INJECT_CONFIRMED
}

MANIFEST_PY="${MANIFEST_PY:-$MCLOCK_LIB/manifest.py}"
RUNNER_ID="${RUNNER_ID:-runner-test}"

_rt_trace() { printf '%s\n' "$*" >> "$RT_TRACE"; }

inventory_load() { _rt_trace "inventory_load"; ADMIN_PUBLIC_IP="10.0.0.1"; ADMIN_NAME="admin"; }
reconcile() {
  _rt_trace "reconcile"
  printf 'reconcile: PASS killed=0 aborted=0\n'
  return "${RT_RECONCILE_RC:-0}"
}
runner_lock_release() { _rt_trace "runner_lock_release"; printf 'runner-lock: RELEASED\n'; }
fio_golden_dir() { printf '%s\n' "${FIO_GOLDEN_DIR:-$RESULTS_DIR/golden/fio-smoke}"; }
ceph_campaign_unflags() { _rt_trace "ceph_campaign_unflags"; return "${RT_UNFLAGS_RC:-0}"; }
client_tuning_restore() { _rt_trace "client_tuning_restore"; return "${RT_RESTORE_RC:-0}"; }
bg_collect_stop() { _rt_trace "bg_collect_stop"; printf 'bg-collect: STOPPED 0\n'; return "${RT_BGSTOP_RC:-0}"; }

# verdict.py 的建議 → manifest.py amend（真流程在 lib/pipeline.sh，這裡只證明入口有呼叫）
# 真流程（need-more-n --emit-amend → manifest.py amend）已由 test-pipeline.sh 驗；
# 這裡只證明「入口有呼叫它、而且 journal 是經由 manifest.py 寫的」。
# 每個 cell 只加一次 extra-replicates，否則佇列會被自己撐大成無限迴圈。
pipeline_apply_amendments() {
  local mark="$RESULTS_DIR/$1/.rt-amended"
  _rt_trace "pipeline_apply_amendments $1"
  if [ ! -e "$mark" ]; then
    mkdir -p "$RESULTS_DIR/$1"
    python3 "$MANIFEST_PY" amend --results "$RESULTS_DIR" \
      --type extra-replicates --key "$1" --value 1 --source "verdict.py need-more-n" >&2 \
      || return 1
    : > "$mark"
  fi
  printf 'amend: APPLIED %s 1\n' "$1"
}

_pipeline_amend() {
  _rt_trace "_pipeline_amend $1 $2 $3 $4"
  python3 "$MANIFEST_PY" amend --results "$RESULTS_DIR" \
    --type "$1" --key "$2" --value "$3" --source "$4" >&2
}

_RT_AMEND_PY='
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    d = json.loads(line)
    sys.stdout.write("\t".join([str(d["type"]), str(d["key"]), str(d["value"]),
                                str(d.get("source", ""))]) + "\n")
'
_pipeline_py() {
  [ "$1" = "amend-lines" ] || { printf '[stub] 未預期的 _pipeline_py %s\n' "$1" >&2; return 9; }
  python3 -c "$_RT_AMEND_PY"
}

_RT_SUMMARY_PY='
import json, sys
d = json.load(open(sys.argv[1]))
sys.stdout.write("%s\t%s\t%s\t%s\n" % (d["cell_id"], d["replicate"], d["kind"], d["profile"]))
'

pipeline_run_execution() {
  local exec_json="$1" cell rep kind profile rc n att
  IFS=$'\t' read -r cell rep kind profile \
    < <(python3 -c "$_RT_SUMMARY_PY" "$exec_json")
  n="$(find "$RT_EXECS" -name '*.json' | wc -l | tr -d ' ')"
  cp "$exec_json" "$RT_EXECS/$((n + 1)).json"
  _rt_trace "pipeline_run_execution ${cell}/${rep} ${kind} ${profile}"

  rc=0
  if [ -s "$RT_PIPELINE_RCS" ]; then
    rc="$(head -1 "$RT_PIPELINE_RCS")"
    sed '1d' "$RT_PIPELINE_RCS" > "$RT_PIPELINE_RCS.next"
    mv -f "$RT_PIPELINE_RCS.next" "$RT_PIPELINE_RCS"
  fi
  case "$rc" in ''|*[!0-9]*) rc=0 ;; esac

  if [ "$rc" -eq 0 ]; then
    att="$RESULTS_DIR/$cell/$rep/attempts/$(date -u '+%Y%m%dT%H%M%SZ')-$((n + 1))"
    mkdir -p "$att"
    printf 'kind=%s\nfinalized_at=%s\n' "$kind" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$att/DONE"
    printf 'kind=%s\n' "$kind" > "$RESULTS_DIR/$cell/$rep/DONE"
    printf 'pipeline: DONE %s/%s\n' "$cell" "$rep"
    return 0
  fi
  printf 'pipeline: RC%s %s/%s\n' "$rc" "$cell" "$rep"
  return "$rc"
}
STUB
}

# --- verdict.py 替身 -----------------------------------------------------------

rt_write_verdict_fake() {
  cat > "$1" <<'PY'
import json
import os
import shutil
import sys

argv = sys.argv[1:]
with open(os.environ["RT_VERDICT_LOG"], "a") as fh:
    fh.write(" ".join(argv) + "\n")
cmd = argv[0] if argv else ""
results = os.environ["RESULTS_DIR"]


def env_rc(name):
    return int(os.environ.get(name, "0"))


if cmd == "margins":
    rc = env_rc("RT_MARGINS_RC")
    if rc == 0:
        with open(os.path.join(results, "margins.json"), "w") as fh:
            json.dump({"schema_version": 1, "sources": {"steady": argv[1:]}}, fh)
        sys.stdout.write("margins: OK 4/4 %s\n" % os.path.join(results, "margins.json"))
    else:
        sys.stdout.write("margins: HYPOTHESES-DRIFT max_stall_seconds\n")
    raise SystemExit(rc)

if cmd == "schedule-estimate":
    out = os.environ.get("RT_ESTIMATE_OUT", "")
    if out and os.path.isfile(out):
        sys.stdout.write(open(out).read())
    raise SystemExit(env_rc("RT_ESTIMATE_RC"))

if cmd == "audit":
    # audit 是唯讀的：把「此刻」的 trace 與封閉標記拍快照，測試據此斷言收尾順序，
    # 並用 trace 前後比對證明 audit 之後沒有任何遠端動作。
    snap = os.environ["RT_AUDIT_SNAPSHOT"]
    if not os.path.isdir(snap):
        os.makedirs(snap)
    shutil.copyfile(os.environ["RT_TRACE"], os.path.join(snap, "trace.log"))
    with open(os.path.join(snap, "sealed"), "w") as fh:
        fh.write("1" if os.path.isfile(os.path.join(results, "DATASET-SEALED")) else "0")
    rc = env_rc("RT_AUDIT_RC")
    sys.stdout.write("audit: %s EVIDENCE-SUMMARY.md\n" % ("OK" if rc == 0 else "INCOMPLETE"))
    raise SystemExit(rc)

sys.stderr.write("fake-verdict: 未預期的子命令 %s\n" % cmd)
raise SystemExit(95)
PY
}
