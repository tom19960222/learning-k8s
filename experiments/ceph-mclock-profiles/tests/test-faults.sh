#!/usr/bin/env bash
# Task 13 — run/faults.sh：margins 前置、pilot → schedule-estimate → 放行（含
# PILOT-CENSORED 分支）、need-more-n 轉譯成 manifest.py amend、12h 回報（進度／花費／
# 唯讀 az 登入態）與 budget-warning、斷點續跑、薄入口不繞過 pipeline。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./harness-run.sh
. "$here/harness-run.sh"

RT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mclock-faults.XXXXXX")"
trap 'rm -rf "$RT_TMP"' EXIT
export RESULTS_DIR="$RT_TMP/results"
export MANIFEST_PY="$RT_ROOT/lib/manifest.py"
sb="$RT_TMP/sb"
rt_sandbox "$sb" faults.sh
export VERDICT_PY="$sb/fake-verdict.py"

# fake az（唯讀 `az account show` 登入態檢查用）
export PATH="$here/fakes:$PATH"
export FAKE_AZ_SCRIPT="$RT_TMP/az.script" FAKE_AZ_LOG="$RT_TMP/az.log" \
       FAKE_AZ_STATE="$RT_TMP/az.state"
az_script() { # <rc> <次數>
  local i=0
  rm -rf "$FAKE_AZ_STATE"
  : > "$FAKE_AZ_SCRIPT"
  : > "$FAKE_AZ_LOG"
  while [ "$i" -lt "$2" ]; do
    printf 'account show|%s|\n' "$1" >> "$FAKE_AZ_SCRIPT"
    i=$((i + 1))
  done
}

export RT_ESTIMATE_OUT="$RT_TMP/estimate.txt"
export RT_ESTIMATE_RC=0
# 預設：回報週期拉到很長，只有收尾那一次 _faults_report 會跑
export FAULTS_REPORT_SECS=999999
export FAULTS_HOURLY_USD=8
export FAULTS_BUDGET_USD=1000

margins_ok() { printf '{"schema_version":1}\n' > "$RESULTS_DIR/margins.json"; }
journal() { printf '%s\n' "$RESULTS_DIR/schedule-amendments.json"; }

# =============================================================================
# 1. 缺 --yes-really-inject
# =============================================================================
rt_reset
rt_manifest '{"fault":2}' 'osd-down'
az_script 0 40
rt_run "$sb" faults.sh
rt_eq "$RT_RC" "1" "缺 --yes-really-inject 應 die"
rt_eq "$(wc -l < "$RT_TRACE" | tr -d ' ')" "0" "拒跑時不得碰下游"

# =============================================================================
# 2. margins.json 是 faults 的硬前置（非 pilot 模式）
# =============================================================================
rt_reset
rt_manifest '{"fault":2}' 'osd-down'
az_script 0 40
rt_run "$sb" faults.sh --yes-really-inject
rt_eq "$RT_RC" "1" "缺 margins.json 應 die"
rt_has "$RT_OUT" "faults: NO-MARGINS" "要有機器行指出缺 margins"
rt_hasnt "$RT_TRACE" "pipeline_run_execution" "缺 margins 時一個 execution 都不准跑"
rt_hasnt "$RT_TRACE" "reconcile" "缺 margins 連 reconcile 都不必做（前置檢查在最前面）"

# =============================================================================
# 3. --pilot 可略過 margins：跑完 pilot → schedule-estimate → cap-update 轉譯 → gate
# =============================================================================
rt_reset
rt_manifest '{"fault_per_type":1}'
az_script 0 40
cat > "$RT_ESTIMATE_OUT" <<'EOF'
schedule-estimate: cap-update osd-down 3600
{"key": "osd-down", "schema_version": 1, "source": "verdict.py schedule-estimate", "type": "cap-update", "value": 3600}
schedule-estimate: OK
EOF
RT_ESTIMATE_RC=0
rt_run "$sb" faults.sh --yes-really-inject --pilot
rt_eq "$RT_RC" "10" "pilot 完成後應以 exit 10 停等人工放行"
rt_has "$RT_OUT" "faults: PILOT-GATE" "要有 pilot gate 機器行"
rt_hasnt "$RT_OUT" "faults: NO-MARGINS" "--pilot 不受 margins 前置限制"
rt_eq "$(grep -c 'pipeline_run_execution' "$RT_TRACE")" "5" "pilot = 每故障型各一個（5 型）"
rt_has_re "$RT_TRACE" 'pipeline_run_execution .*/r1 fault' "pilot 必須是 r1"
rt_has "$RT_VERDICT_LOG" "schedule-estimate" "pilot 完成後要跑 schedule-estimate"
# cap-update 必須經由 manifest.py amend 落 journal（seq 由它配發），入口不自己寫
rt_has "$RT_TRACE" "_pipeline_amend cap-update osd-down 3600" "cap-update 要走 amend 轉譯"
rt_has "$(journal)" '"type": "cap-update"' "journal 要有 cap-update"
rt_has "$(journal)" '"seq": 1' "seq 由 manifest.py 配發"
rt_has "$RT_OUT" "amend: TRANSLATED 1" "轉譯筆數要有機器行"

# =============================================================================
# 4. 人工放行（--resume）：pilot 已完成 → 不重跑，直接 PILOT-PASS
# =============================================================================
: > "$RT_TRACE"
rt_run "$sb" faults.sh --yes-really-inject --pilot --resume
rt_eq "$RT_RC" "0" "放行後 pilot 段應 rc=0"
rt_has "$RT_OUT" "faults: PILOT-PASS" "放行後的機器行"
rt_hasnt "$RT_TRACE" "pipeline_run_execution" "已完成的 pilot 不得重跑（斷點續跑）"

# =============================================================================
# 5. PILOT-CENSORED：撞 cap 的 pilot 不得餵進 2× 公式，--resume 也不能繞過
# =============================================================================
rt_reset
rt_manifest '{"fault_per_type":1}'
az_script 0 40
cat > "$RT_ESTIMATE_OUT" <<'EOF'
schedule-estimate: PILOT-CENSORED osd-down 2700
EOF
RT_ESTIMATE_RC=5
rt_run "$sb" faults.sh --yes-really-inject --pilot --resume
rt_eq "$RT_RC" "11" "PILOT-CENSORED 應以 exit 11 停等人工裁示"
rt_has "$RT_OUT" "faults: PILOT-CENSORED osd-down" "要指名是哪個故障型"
rt_hasnt "$RT_OUT" "faults: PILOT-PASS" "--resume 不得繞過 PILOT-CENSORED"
rt_hasnt "$RT_OUT" "faults: PILOT-GATE" "censored 時不走一般 gate"
if [ -s "$(journal)" ]; then
  rt_hasnt "$(journal)" '"type": "cap-update"' "censored 時不得自動寫 cap-update"
fi
rt_ok

# 人工裁示：以 cap-update amendment 記入 journal 後才准放行
python3 "$MANIFEST_PY" amend --results "$RESULTS_DIR" --type cap-update \
  --key osd-down --value 5400 --source "human: pilot censored 裁示" >/dev/null 2>&1 \
  || rt_fail "人工 cap-update amend 失敗"
: > "$RT_TRACE"
rt_run "$sb" faults.sh --yes-really-inject --pilot --resume
rt_eq "$RT_RC" "0" "有人工 cap-update 裁示後應放行"
rt_has "$RT_OUT" "faults: PILOT-PASS" "放行後的機器行"

# =============================================================================
# 6. 全佇列：每 cell n=2 後 need-more-n → manifest.py amend（入口不直接寫 journal）
# =============================================================================
rt_reset
rt_manifest '{"fault":1}' 'osd-down'
az_script 0 40
margins_ok
rt_run "$sb" faults.sh --yes-really-inject
rt_eq "$RT_RC" "0" "全佇列應跑完"
rt_has "$RT_OUT" "faults: MARGINS-OK" "margins 前置通過要有機器行"
# base_n=2 → r1、r2；n=2 觸發 need-more-n → +1 replicate → r3
rt_eq "$(grep -c 'pipeline_run_execution' "$RT_TRACE")" "3" "extra-replicates 應讓 r3 進佇列"
rt_eq "$(grep -c 'pipeline_apply_amendments' "$RT_TRACE")" "2" "n=2 與 n=3 各問一次 need-more-n"
rt_has "$(journal)" '"type": "extra-replicates"' "extra-replicates 要落 journal"
rt_has "$(journal)" '"seq": 1' "seq 由 manifest.py 配發（入口不自己編號）"
rt_eq "$(grep -c 'extra-replicates' "$(journal)")" "1" "同 cell 只加一次（測試替身的守則）"
rt_has "$RT_OUT" "faults: PASS done=3/3" "完成的機器行"
rt_before "$RT_TRACE" "reconcile" "pipeline_run_execution" "reconcile 必須先於任何 execution"

# 斷點續跑：再跑一次不得重跑已完成的 execution
: > "$RT_TRACE"
rt_run "$sb" faults.sh --yes-really-inject
rt_eq "$RT_RC" "0" "續跑應 rc=0"
rt_hasnt "$RT_TRACE" "pipeline_run_execution" "已完成的 execution 不得重跑"

# =============================================================================
# 7. 12h 回報：進度 + 累計花費估算 + 唯讀 az 登入態；成本逼近門檻要 budget-warning
# =============================================================================
rt_reset
rt_manifest '{"fault":1}' 'osd-down'
az_script 0 40
margins_ok
# campaign 已跑 500000s ≈ 138.89h → 138.89 × $8 ≈ $1111 ≥ $1000
printf '%s\n' "$(( $(date +%s) - 500000 ))" > "$RESULTS_DIR/.campaign-start"
FAULTS_REPORT_SECS=0 rt_run "$sb" faults.sh --yes-really-inject
rt_eq "$RT_RC" "0" "回報不應影響佇列結果"
rt_has_re "$RT_OUT" '^faults: REPORT done=[0-9]+/[0-9]+ elapsed_h=[0-9.]+ cost_usd=[0-9]+ az=ok$' \
  "12h 回報的機器行格式"
rt_has "$RT_OUT" "budget-warning: cost_usd=1111 threshold=1000" "成本逼近 \$1000 要 budget-warning"
rt_has "$FAKE_AZ_LOG" "account show" "az 登入態檢查必須是唯讀的 account show"
rt_hasnt "$FAKE_AZ_LOG" "vm restart" "12h 回報不得動用任何 mutating az 指令"
rt_hasnt "$FAKE_AZ_LOG" "vm deallocate" "嚴禁 deallocate"

# az 登入態失效 → pre-HUMAN 警示
rt_reset
rt_manifest '{"fault":1}' 'osd-down'
az_script 1 40
margins_ok
FAULTS_REPORT_SECS=0 rt_run "$sb" faults.sh --yes-really-inject
rt_eq "$RT_RC" "0" "az 失效不擋佇列（只是預警）"
rt_has "$RT_OUT" "faults: AZ-LOGIN-STALE stale" "az 失效要有 pre-HUMAN 警示機器行"
rt_has_re "$RT_OUT" '^faults: REPORT .* az=stale$' "回報行要標記 az=stale"

# =============================================================================
# 8. watchdog 停佇列 → exit 3；不繼續開新 execution
# =============================================================================
rt_reset
rt_manifest '{"fault":2}' 'osd-down'
az_script 0 40
margins_ok
printf '3\n' > "$RT_PIPELINE_RCS"
rt_run "$sb" faults.sh --yes-really-inject
rt_eq "$RT_RC" "3" "佇列被停應以 exit 3 收場"
rt_has "$RT_OUT" "faults: HALTED" "要有 HALTED 機器行"
rt_eq "$(grep -c 'pipeline_run_execution' "$RT_TRACE")" "1" "停佇列後不得再開新的 execution"

# =============================================================================
# 9. 靜態斷言：薄入口不得繞過 pipeline
# =============================================================================
rt_assert_thin "$RT_ROOT/run/faults.sh"

printf 'test-faults: %d asserts passed\n' "$RT_ASSERTS"
