#!/usr/bin/env bash
# Task 13 — run/steady.sh：薄入口（reconcile → manifest next 迴圈 → pipeline_run_execution）、
# first-cell gate（含 fio_smoke_real 已過的斷言）、margins 為 faults 的前置檔、續跑。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./harness-run.sh
. "$here/harness-run.sh"

RT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mclock-steady.XXXXXX")"
trap 'rm -rf "$RT_TMP"' EXIT
export RESULTS_DIR="$RT_TMP/results"
export MANIFEST_PY="$RT_ROOT/lib/manifest.py"
export FIO_GOLDEN_DIR="$RT_TMP/golden"
sb="$RT_TMP/sb"
rt_sandbox "$sb" steady.sh
export VERDICT_PY="$sb/fake-verdict.py"
export RT_MARGINS_RC=0

golden_ok() { mkdir -p "$FIO_GOLDEN_DIR/c1"; : > "$FIO_GOLDEN_DIR/c1/iops.log"; }
golden_clear() { rm -rf "$FIO_GOLDEN_DIR"; }

# =============================================================================
# 1. 沒有 --yes-really-inject 一律拒跑（mutating 入口的硬規則）
# =============================================================================
rt_reset
rt_manifest '{"steady":1}'
rt_run "$sb" steady.sh
rt_eq "$RT_RC" "1" "缺 --yes-really-inject 應 die"
rt_has "$RT_ERR" "--yes-really-inject" "die 訊息要說明原因"
rt_eq "$(wc -l < "$RT_TRACE" | tr -d ' ')" "0" "拒跑時不得碰任何下游"

# =============================================================================
# 2. first-cell gate：fio_smoke_real 未過 → 一個 execution 都不准跑
# =============================================================================
rt_reset
rt_manifest '{"steady":1}'
golden_clear
rt_run "$sb" steady.sh --yes-really-inject
rt_eq "$RT_RC" "1" "smoke 未過應 die"
rt_has "$RT_OUT" "steady: SMOKE-MISSING" "要有機器行指出 golden log 缺"
rt_hasnt "$RT_TRACE" "pipeline_run_execution" "smoke 未過時不得送任何 execution 進 pipeline"
rt_has "$RT_TRACE" "reconcile" "reconcile 仍先跑（殘留掃描與 smoke 無關）"

# =============================================================================
# 3. first-cell gate：跑完第一個 cell 就停等人工放行（exit 10）
# =============================================================================
rt_reset
rt_manifest '{"steady":2}'
golden_ok
rt_run "$sb" steady.sh --yes-really-inject
rt_eq "$RT_RC" "10" "first-cell gate 應以 exit 10 停等人工"
rt_has "$RT_OUT" "steady: SMOKE-OK" "smoke 斷言要有機器行"
rt_has "$RT_OUT" "steady: FIRST-CELL-GATE" "要印出 gate 的機器行"
rt_eq "$(grep -c 'pipeline_run_execution' "$RT_TRACE")" "1" "gate 前只准跑一個 execution"
rt_hasnt "$RT_VERDICT_LOG" "margins" "尚未跑完全部穩態，不得產 margins"
rt_before "$RT_TRACE" "reconcile" "pipeline_run_execution" "reconcile 必須先於任何 execution"

# =============================================================================
# 4. --resume 續跑：把整個穩態佇列跑完 → margins 產出並驗證
#    （同時驗「斷點續跑」：第 3 段已完成的 execution 不會重跑）
# =============================================================================
before="$(grep -c 'pipeline_run_execution' "$RT_TRACE")"
: > "$RT_TRACE"
rt_run "$sb" steady.sh --yes-really-inject --resume
rt_eq "$RT_RC" "0" "續跑應完成（rc=0）"
rt_eq "$before" "1" "續跑前只完成 1 個"
# trim 後 2 個 steady cell × base_n 3 = 6 executions，已完成 1 → 續跑 5
rt_eq "$(grep -c 'pipeline_run_execution' "$RT_TRACE")" "5" "續跑只補未完成的 execution"
rt_has "$RT_OUT" "steady: PASS done=6/6" "全數完成的機器行"
rt_has "$RT_VERDICT_LOG" "margins" "全穩態完成後要跑 margins"
[ -s "$RESULTS_DIR/margins.json" ] || rt_fail "margins.json（faults 前置檔）未產出"
rt_ok
# margins 必須吃到全部 6 個 steady DONE bundle
rt_eq "$(grep 'margins' "$RT_VERDICT_LOG" | tr ' ' '\n' | grep -c '/attempts/')" "6" \
  "margins 要吃到全部 steady bundle"

# =============================================================================
# 5. 冪等：佇列已耗盡時再跑一次 → 不再送 execution，但 margins 仍重算
# =============================================================================
: > "$RT_TRACE"
rt_run "$sb" steady.sh --yes-really-inject --resume
rt_eq "$RT_RC" "0" "佇列耗盡再跑仍應 rc=0"
rt_hasnt "$RT_TRACE" "pipeline_run_execution" "佇列耗盡不得再送 execution"

# =============================================================================
# 6. margins 失敗 = 硬失敗（faults 的前置檔不可缺）
# =============================================================================
RT_MARGINS_RC=1
rm -f "$RESULTS_DIR/margins.json"
rt_run "$sb" steady.sh --yes-really-inject --resume
rt_eq "$RT_RC" "1" "margins 失敗要讓 steady 失敗"
rt_hasnt "$RT_OUT" "steady: PASS" "margins 沒過就不准宣告 PASS"
RT_MARGINS_RC=0

# =============================================================================
# 7. manifest next 的「佇列耗盡（exit 3）」與「錯誤」必須分得開
# =============================================================================
rt_reset
rt_manifest '{"steady":1}'
golden_ok
# 只有 `next` 壞掉（rc=2）：其餘子命令照常委派真的 manifest.py，
# 這樣測到的就是「next 的 rc≠3 不得被當成佇列耗盡」這一點本身。
export RT_REAL_MANIFEST="$RT_ROOT/lib/manifest.py"
cat > "$RT_TMP/broken-manifest.py" <<'PY'
import os
import subprocess
import sys

if len(sys.argv) > 1 and sys.argv[1] == "next":
    sys.stderr.write("boom\n")
    sys.exit(2)
sys.exit(subprocess.call([sys.executable, os.environ["RT_REAL_MANIFEST"]] + sys.argv[1:]))
PY
MANIFEST_PY="$RT_TMP/broken-manifest.py" rt_run "$sb" steady.sh --yes-really-inject --resume
rt_eq "$RT_RC" "1" "manifest 真的壞掉要 die，不得當成佇列跑完"
rt_has "$RT_ERR" "不是佇列耗盡" "die 訊息要點出與 exit 3 的差別"
rt_hasnt "$RT_TRACE" "pipeline_run_execution" "manifest 壞掉不得送 execution"

# =============================================================================
# 8. watchdog 停佇列（pipeline rc=3）→ steady 以 exit 3 收場，不繼續開新 execution
# =============================================================================
rt_reset
rt_manifest '{"steady":2}'
golden_ok
printf '3\n' > "$RT_PIPELINE_RCS"
rt_run "$sb" steady.sh --yes-really-inject --resume
rt_eq "$RT_RC" "3" "佇列被停應以 exit 3 收場"
rt_has "$RT_OUT" "steady: HALTED" "要有 HALTED 機器行"
rt_eq "$(grep -c 'pipeline_run_execution' "$RT_TRACE")" "1" "停佇列後不得再開新的 execution"
rt_hasnt "$RT_VERDICT_LOG" "margins" "佇列沒跑完不得產 margins"

# =============================================================================
# 10. descope（§7.3）：被裁決不跑的 cell 不得卡住「全數完成」的判準
#     （Task 0.2：descope 的佇列端效果要一路貫穿到 queue_progress 的分母）
# =============================================================================
rt_reset
rt_manifest '{"steady":2}'
golden_ok
cell_dropped="$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print([c["cell_id"] for c in d["cells"] if c["kind"] == "steady"][0])' "$RESULTS_DIR/manifest.json")"
python3 -c 'import json,sys
json.dump({"cells": [{"cell_id": sys.argv[2], "reason": "descope-① 成本天花板"}]},
          open(sys.argv[1], "w"))' "$RESULTS_DIR/descope.json" "$cell_dropped"
rt_run "$sb" steady.sh --yes-really-inject --resume
rt_eq "$RT_RC" "0" "descope 後仍應正常跑完（不得卡在 done<total）"
rt_has "$RT_OUT" "steady: PASS done=3/3" "descoped 的 executions 不計入分母"
rt_eq "$(grep -c 'pipeline_run_execution' "$RT_TRACE")" "3" "descoped 的 cell 一個 execution 都不跑"
[ -s "$RESULTS_DIR/margins.json" ] || rt_fail "descope 後 margins 仍應產出"
rt_ok

# =============================================================================
# 9. 靜態斷言：薄入口不得繞過 pipeline 自己下遠端指令
# =============================================================================
rt_assert_thin "$RT_ROOT/run/steady.sh"
rt_assert_thin "$RT_ROOT/run/queue.sh"

printf 'test-steady: %d asserts passed\n' "$RT_ASSERTS"
