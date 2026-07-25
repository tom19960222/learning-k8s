#!/usr/bin/env bash
# Task 14 — run/chaos.sh（同一 pipeline、同 seed 跨 profile 一致）與 run/all.sh
#（段的順序 / 斷點續跑 / 人工 gate / **收尾順序即規格** / audit 唯讀 / audit FAIL 不留殘態）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./harness-run.sh
. "$here/harness-run.sh"

RT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mclock-chaosall.XXXXXX")"
trap 'rm -rf "$RT_TMP"' EXIT
export RESULTS_DIR="$RT_TMP/results"
export MANIFEST_PY="$RT_ROOT/lib/manifest.py"
export RT_STAGE_RC_DIR="$RT_TMP/stage-rc"

sb_chaos="$RT_TMP/sb-chaos"
sb_all="$RT_TMP/sb-all"
rt_sandbox "$sb_chaos" chaos.sh
rt_sandbox "$sb_all" all.sh
rt_stage_stubs "$sb_all"
export VERDICT_PY="$sb_chaos/fake-verdict.py"
export RT_AUDIT_RC=0

# =============================================================================
# chaos 1. 缺 --yes-really-inject
# =============================================================================
rt_reset
rt_manifest '{"chaos":3}'
rt_run "$sb_chaos" chaos.sh
rt_eq "$RT_RC" "1" "缺 --yes-really-inject 應 die"
rt_eq "$(wc -l < "$RT_TRACE" | tr -d ' ')" "0" "拒跑時不得碰下游"

# =============================================================================
# chaos 2. 3 個 chaos executions 走同一台 pipeline，且同 seed 跨 profile 一致
# =============================================================================
rt_reset
rt_manifest '{"chaos":3}'
rt_run "$sb_chaos" chaos.sh --yes-really-inject
rt_eq "$RT_RC" "0" "chaos 佇列應跑完"
rt_eq "$(grep -c 'pipeline_run_execution' "$RT_TRACE")" "3" "chaos = 3 executions（3 profiles × n=1）"
rt_has "$RT_OUT" "chaos: PASS done=3/3" "完成的機器行"
rt_before "$RT_TRACE" "reconcile" "pipeline_run_execution" "reconcile 必須先於任何 execution"
# 走的是同一個 pipeline 入口（沒有 chaos 專用旁路）
rt_eq "$(grep -c 'pipeline_run_execution .* chaos ' "$RT_TRACE")" "3" \
  "chaos 也必須經由 pipeline_run_execution（prediction/verdict/finalize 一個都不能少）"
# 三個 profile 都被涵蓋，且 seed / duration 完全相同
rt_eq "$(grep 'pipeline_run_execution' "$RT_TRACE" | awk '{print $4}' | sort -u | wc -l | tr -d ' ')" \
  "3" "三個 profile 各一個 chaos execution"
seeds="$(python3 -c '
import glob, json, sys
vals = set()
durs = set()
for p in sorted(glob.glob(sys.argv[1] + "/*.json")):
    d = json.load(open(p))
    vals.add(d["fault_params"]["seed"])
    durs.add(d["fault_params"]["duration"])
print("%s %s %s" % (len(vals), sorted(vals)[0], len(durs)))' "$RT_EXECS")"
rt_eq "$seeds" "1 4242 1" "同 seed（4242）與同 duration 跨 profile 一致"
rt_eq "$(grep -c '^chaos: SEED ' "$RT_OUT")" "3" "每個 execution 都要印 seed 機器行"

# 斷點續跑
: > "$RT_TRACE"
rt_run "$sb_chaos" chaos.sh --yes-really-inject
rt_eq "$RT_RC" "0" "續跑應 rc=0"
rt_hasnt "$RT_TRACE" "pipeline_run_execution" "已完成的 chaos execution 不得重跑"

# =============================================================================
# chaos 3. watchdog 停佇列 → exit 3
# =============================================================================
rt_reset
rt_manifest '{"chaos":3}'
printf '3\n' > "$RT_PIPELINE_RCS"
rt_run "$sb_chaos" chaos.sh --yes-really-inject
rt_eq "$RT_RC" "3" "佇列被停應以 exit 3 收場"
rt_has "$RT_OUT" "chaos: HALTED" "要有 HALTED 機器行"
rt_eq "$(grep -c 'pipeline_run_execution' "$RT_TRACE")" "1" "停佇列後不得再開新的 execution"

rt_assert_thin "$RT_ROOT/run/chaos.sh"

# =============================================================================
# all 1. 全段跑完 → 收尾順序 → campaign: DONE
# =============================================================================
export VERDICT_PY="$sb_all/fake-verdict.py"
rt_reset
rt_stage_rc_clear
rt_manifest '{"chaos":3}'
rt_run "$sb_all" all.sh --yes-really-inject
rt_eq "$RT_RC" "0" "全段完成應 rc=0"
rt_has "$RT_OUT" "campaign: DONE" "收尾成功的機器行"

# 段的順序（calibrate → steady → faults --pilot → faults → chaos）
rt_before "$RT_TRACE" "calibrate " "steady " "calibrate 必須先於 steady"
rt_before "$RT_TRACE" "steady " "faults --yes-really-inject --pilot" "steady 必須先於 faults pilot"
rt_before "$RT_TRACE" "faults --yes-really-inject --pilot" "chaos " "pilot 必須先於 chaos"
rt_has "$RT_TRACE" "chaos --yes-really-inject" "chaos 段要跑"
rt_eq "$(grep -c '^faults ' "$RT_TRACE")" "2" "faults 分 pilot 與全佇列兩段"

# **收尾順序即規格**：停注入/fio（reconcile）→ unflags + tuning restore →
# collector 全停 → 資料集封閉 → audit
rt_before "$RT_TRACE" "chaos --yes-really-inject" "reconcile" "收尾的 reconcile 在所有段之後"
rt_before "$RT_TRACE" "reconcile" "ceph_campaign_unflags" "先停注入/fio 才回退 flags"
rt_before "$RT_TRACE" "ceph_campaign_unflags" "client_tuning_restore" "flags 與 tuning 都要回退"
rt_before "$RT_TRACE" "client_tuning_restore" "bg_collect_stop" "回退之後才停 collector"
rt_has "$RT_OUT" "all: SEALED" "資料集封閉要有機器行"
rt_has "$RT_TRACE" "runner_lock_release" "收尾取的 runner lock 要對稱釋放（否則下次會被自己擋住）"
[ -s "$RESULTS_DIR/DATASET-SEALED" ] || rt_fail "資料集封閉標記未寫出"
rt_ok

# audit 的前置與唯讀性：快照證明 audit 執行「當下」殘態已清乾淨、資料集已封閉
[ -d "$RT_AUDIT_SNAPSHOT" ] || rt_fail "audit 未被呼叫"
rt_ok
rt_eq "$(cat "$RT_AUDIT_SNAPSHOT/sealed")" "1" "audit 之前資料集必須已封閉"
rt_has "$RT_AUDIT_SNAPSHOT/trace.log" "ceph_campaign_unflags" "audit 之前 flags 必須已回退"
rt_has "$RT_AUDIT_SNAPSHOT/trace.log" "client_tuning_restore" "audit 之前 tuning 必須已回退"
rt_has "$RT_AUDIT_SNAPSHOT/trace.log" "bg_collect_stop" "audit 之前 collector 必須已停"
# audit 之後只准有 lease 釋放（本機檔案操作），不得再有任何叢集／資料集動作
if ! diff -q <(grep -v 'runner_lock_release' "$RT_AUDIT_SNAPSHOT/trace.log") \
             <(grep -v 'runner_lock_release' "$RT_TRACE") >/dev/null; then
  rt_fail "audit 之後仍有叢集動作——audit 必須是唯讀的收官步驟"
fi
rt_ok

# =============================================================================
# all 2. 斷點續跑：所有段的 marker 都在 → 全部 SKIP
# =============================================================================
: > "$RT_TRACE"
rt_run "$sb_all" all.sh --yes-really-inject
rt_eq "$RT_RC" "0" "續跑應 rc=0"
for stage in calibrate steady faults-pilot faults chaos finalize; do
  rt_has "$RT_OUT" "all: STAGE ${stage} SKIP" "已完成的段要跳過：${stage}"
done
rt_hasnt "$RT_TRACE" "steady " "全部 SKIP 時不得重跑任何段"
rt_hasnt "$RT_TRACE" "reconcile" "全部 SKIP 時不得再做收尾掃描"
rt_hasnt "$RT_TRACE" "ceph_campaign_unflags" "全部 SKIP 時不得再動 campaign flags"

# =============================================================================
# all 3. 人工 gate：steady 回 10 → HUMAN-GATE、停在該段、不寫 marker
# =============================================================================
rt_reset
rt_stage_rc_clear
rt_manifest '{"chaos":3}'
rt_stage_rc steady 10
rt_run "$sb_all" all.sh --yes-really-inject
rt_eq "$RT_RC" "10" "人工 gate 要把離開碼原樣往上傳"
rt_has "$RT_OUT" "all: HUMAN-GATE steady rc=10" "要指出是哪一段在等放行"
rt_hasnt "$RT_TRACE" "faults " "gate 之後不得續跑後面的段"
[ -e "$RESULTS_DIR/.stage-steady.done" ] && rt_fail "gate 未通過不得寫 stage marker"
rt_ok
[ -e "$RESULTS_DIR/.stage-calibrate.done" ] || rt_fail "gate 之前已完成的段仍要記 marker"
rt_ok

# --resume 要往下傳給 steady / faults（人工放行憑證）
rt_stage_rc steady 0
: > "$RT_TRACE"
rt_run "$sb_all" all.sh --yes-really-inject --resume
rt_has "$RT_TRACE" "steady --yes-really-inject --resume" "--resume 要傳給 steady"
rt_has "$RT_TRACE" "faults --yes-really-inject --resume --pilot" "--resume 要傳給 faults pilot"

# =============================================================================
# all 4. PILOT-CENSORED（rc 11）也是人工 gate
# =============================================================================
rt_reset
rt_stage_rc_clear
rt_manifest '{"chaos":3}'
rt_stage_rc faults 11
rt_run "$sb_all" all.sh --yes-really-inject
rt_eq "$RT_RC" "11" "rc 11 要原樣往上傳"
rt_has "$RT_OUT" "all: HUMAN-GATE faults-pilot rc=11" "PILOT-CENSORED 停在 pilot 段"

# =============================================================================
# all 5. audit FAIL：仍然不得留下 campaign flags 或 writer
# =============================================================================
rt_reset
rt_stage_rc_clear
rt_manifest '{"chaos":3}'
RT_AUDIT_RC=1 rt_run "$sb_all" all.sh --yes-really-inject
rt_eq "$RT_RC" "1" "audit FAIL 要讓 all.sh 失敗"
rt_has "$RT_OUT" "campaign: AUDIT-FAIL" "要有 AUDIT-FAIL 機器行"
rt_hasnt "$RT_OUT" "campaign: DONE" "audit 沒過不得宣告 DONE"
rt_has "$RT_TRACE" "ceph_campaign_unflags" "audit FAIL 也必須已回退 campaign flags"
rt_has "$RT_TRACE" "client_tuning_restore" "audit FAIL 也必須已回退 client tuning"
rt_has "$RT_TRACE" "bg_collect_stop" "audit FAIL 也必須已停掉 collector"
[ -s "$RESULTS_DIR/DATASET-SEALED" ] || rt_fail "audit FAIL 時資料集仍應已封閉"
rt_ok
[ -e "$RESULTS_DIR/.stage-finalize.done" ] && rt_fail "audit FAIL 不得寫 finalize marker（要能續跑）"
rt_ok

# 修好之後續跑：只重做 finalize
: > "$RT_TRACE"
rt_run "$sb_all" all.sh --yes-really-inject
rt_eq "$RT_RC" "0" "audit 修好後續跑應 rc=0"
rt_has "$RT_OUT" "campaign: DONE" "續跑要能收官"
rt_hasnt "$RT_TRACE" "steady " "續跑不得重跑已完成的段"
rt_has "$RT_TRACE" "ceph_campaign_unflags" "finalize 重跑要重新確認回退（冪等）"

# =============================================================================
# all 6. 收尾回退失敗 → 仍然把後面的回退做完，只是不宣告 DONE
# =============================================================================
rt_reset
rt_stage_rc_clear
rt_manifest '{"chaos":3}'
RT_UNFLAGS_RC=1 rt_run "$sb_all" all.sh --yes-really-inject
rt_eq "$RT_RC" "1" "回退失敗要讓 all.sh 失敗"
rt_has "$RT_OUT" "all: CLEANUP-INCOMPLETE" "要有殘態未清的機器行"
rt_has "$RT_TRACE" "client_tuning_restore" "unflags 失敗仍要繼續 restore（留著更糟）"
rt_has "$RT_TRACE" "bg_collect_stop" "unflags 失敗仍要停掉 collector"

# =============================================================================
# all 7. 靜態斷言：薄入口 + **不含 provision / teardown**（IaC agent 的職責）
# =============================================================================
rt_assert_thin "$RT_ROOT/run/all.sh"
for token in 'az vm create' 'az group' 'az vm delete' 'deallocate' 'terraform' 'bicep'; do
  grep -q -- "$token" "$RT_ROOT/run/all.sh" \
    && rt_fail "run/all.sh 不得涉及 provision/teardown（命中 ${token}）"
  rt_ok
done

printf 'test-chaos-all: %d asserts passed\n' "$RT_ASSERTS"
