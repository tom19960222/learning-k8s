#!/usr/bin/env bash
# ceph-mclock-profiles — campaign 總入口（Task 14）。
#
# 用法：run/all.sh --yes-really-inject [--resume]
#
#   --resume = 人工放行憑證，同時往下傳給 steady / faults；已完成的段（stage marker
#              `results/.stage-<name>.done`）一律跳過 → 各段可斷點續跑。
#
# **不含 provision / teardown**：15 台 VM 的建立與刪除是 IaC agent 的職責，本檔只負責
# 「叢集已存在」之後的 campaign 執行與收尾。teardown 前置條件是收尾的 audit 過。
#
# 段：calibrate → steady → faults-pilot → faults → chaos → finalize
#
# 收尾順序（plan Task 14／round2 blocker 10——**順序本身就是規格**）：
#   1. 停全部注入 / fio（reconcile 級掃描：MCLOCK-ISO chain、非預期 down/out OSD、
#      /run/mclock registry 的殘留 process）
#   2. `ceph_campaign_unflags` + `client_tuning_restore`
#   3. sampler / bg_collect 全停
#   4. 資料集封閉（此後不再有 writer）
#   5. `verdict.py audit`（唯讀，產 EVIDENCE-SUMMARY）
#   6. 機器行 `campaign: DONE`
#   1–4 **不因 audit 結果而改變**：audit FAIL 也絕不留下 campaign flags 或 writer。
#
# 離開碼：0 campaign DONE／1 失敗（含 audit FAIL）／3 佇列被 watchdog 停／
#         10、11 人工 gate（等放行／等 PILOT-CENSORED 裁示）
# shellcheck source-path=SCRIPTDIR
set -u

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./queue.sh
. "$RUN_DIR/queue.sh"

# inject_confirm（不是 require_inject_flag）：後者只檢查旗標，前者還會設下
# INJECT_CONFIRMED，注入函式靠它把關。測試全域 export 了該變數，所以只有真機
# 會發現差別——第一次跑故障 pilot 就在注入前被擋下。
inject_confirm "$@"

resume=0
for arg in "$@"; do
  case "$arg" in
    --yes-really-inject) : ;;
    --resume) resume=1 ;;
    *) die "未知參數：${arg}（用法：run/all.sh --yes-really-inject [--resume]）" ;;
  esac
done

# 各段共用同一個 runner id：子腳本各自 reconcile 取 lock、離開時釋放，
# 同 owner 可無條件重取，不必等 stale 逾時。
RUNNER_ID="${RUNNER_ID:-campaign-$$}"
export RUNNER_ID

stage_args=(--yes-really-inject)
[ "$resume" -eq 1 ] && stage_args+=(--resume)

_all_stage() { # <name> <cmd...>
  local name="$1" marker rc=0
  shift
  marker="$RESULTS_DIR/.stage-${name}.done"
  if [ -e "$marker" ]; then
    printf 'all: STAGE %s SKIP\n' "$name"
    return 0
  fi
  "$@" || rc=$?
  case "$rc" in
    0) : > "$marker"; printf 'all: STAGE %s PASS\n' "$name" ;;
    10|11) printf 'all: HUMAN-GATE %s rc=%s\n' "$name" "$rc"; exit "$rc" ;;
    3) printf 'all: HALTED %s\n' "$name"; exit 3 ;;
    *) printf 'all: STAGE %s FAIL rc=%s\n' "$name" "$rc"; exit 1 ;;
  esac
}

# 收尾：順序即規格。每一步都「盡力做完」再往下——任何一步失敗都不得跳過後面的回退，
# 否則 audit FAIL 就會留下 noscrub/nodeep-scrub 或還在寫的 collector。
_all_finalize() {
  local sealed="$RESULTS_DIR/DATASET-SEALED" fails=0 rc=0 rec_rc=0

  # 1. 停全部注入 / fio（MCLOCK-ISO chain、down/out OSD、registry 殘留 process）
  reconcile || rec_rc=$?
  # reconcile 取了 runner lock，離開時要對稱釋放；否則下一次 all.sh 是新 PID／新 runner id，
  # 會被自己上一次留下的 lock 擋到 stale 逾時（RUNNER_LOCK_STALE_SECS，預設 1h）。
  cleanup_push runner_lock_release
  if [ "$rec_rc" -eq 0 ]; then
    printf 'all: RECONCILED\n'
  else
    fails=$((fails + 1))
    log "收尾 reconcile 未過——仍繼續回退 flags/tuning 與停 collector（留著更糟）"
  fi

  # 2. campaign flags / client tuning 對稱回退（在 audit **之前**，與 audit 結果無關）
  ceph_campaign_unflags || { fails=$((fails + 1)); log "campaign flags 回退失敗"; }
  client_tuning_restore || { fails=$((fails + 1)); log "client tuning 回退失敗"; }
  printf 'all: UNFLAGGED fails=%s\n' "$fails"

  # 3. sampler / bg collector 全停（reconcile 已按 registry 清掉 replicate 級 sampler）
  bg_collect_stop || { fails=$((fails + 1)); log "bg collector 停止失敗"; }

  # 4. 資料集封閉：此後不再有 writer，audit 才有一致的快照可讀
  printf 'sealed_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$sealed" \
    || die "資料集封閉標記寫入失敗：${sealed}"
  printf 'all: SEALED %s\n' "$sealed"

  # 5. audit：唯讀（只讀 results/ 產 EVIDENCE-SUMMARY，不碰叢集、不再啟動任何遠端動作）
  python3 "$VERDICT_PY" audit "$RESULTS_DIR" || rc=$?

  if [ "$fails" -gt 0 ]; then
    printf 'all: CLEANUP-INCOMPLETE %s\n' "$fails"
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'campaign: AUDIT-FAIL rc=%s\n' "$rc"
    return 1
  fi
  [ "$fails" -eq 0 ] || return 1
  printf 'campaign: DONE\n'
}

inventory_load
queue_init
queue_campaign_start >/dev/null

# calibrate 只吃 --yes-really-inject（它的續跑靠自身冪等 + stage marker，不吃 --resume）
_all_stage calibrate      bash "$RUN_DIR/calibrate.sh" --yes-really-inject
_all_stage steady         bash "$RUN_DIR/steady.sh" "${stage_args[@]+"${stage_args[@]}"}"
_all_stage faults-pilot   bash "$RUN_DIR/faults.sh" "${stage_args[@]+"${stage_args[@]}"}" --pilot
_all_stage faults         bash "$RUN_DIR/faults.sh" "${stage_args[@]+"${stage_args[@]}"}"
_all_stage chaos          bash "$RUN_DIR/chaos.sh" --yes-really-inject
_all_stage finalize       _all_finalize
