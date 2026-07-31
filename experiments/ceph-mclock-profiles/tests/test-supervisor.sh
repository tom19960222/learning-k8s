#!/usr/bin/env bash
# run/campaign-supervisor.sh — 故障佇列看門程式。
#
# 規格 =「佇列不在了」的四種成因必須分開判：
#   跑完（收工）／watchdog 停佇列（等人）／pilot gate（等人）／真的死了（重啟）。
# 2026-07-31 空轉 40 次就是把第 2 種當成第 4 種。
#
# 測試策略：整支 supervisor 原封不動複製進沙箱跑（不 source、不改），外界一律替身——
#   pgrep → tests/fakes/pgrep（用真的 grep -E 比對假 process 表，所以「pattern 會不會
#           誤中」是真的在測 pattern 本身，不是替身自己定義的）
#   ssh   → tests/fakes/ssh（非預期的叢集指令一律 exit 97 → 可證明「停手前不碰叢集」）
#   manifest.py / faults.sh → 沙箱替身（前者供 pending，後者記下被以什麼參數＋環境啟動）
# 時間旋鈕全調到 0/1，測試不睡覺。
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-sup.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"; ok; }
# 檔案不存在時 grep 一律「找不到」——hasnt 會靜默過關。所以先擋掉不存在的檔案。
has() {
  [ -f "$1" ] || fail "$3：檔案不存在（$1）"
  grep -qF -- "$2" "$1" || fail "$3：未含 [$2]（檔=$1）"
  ok
}
hasnt() {
  [ -f "$1" ] || fail "$3：檔案不存在（$1）"
  grep -qF -- "$2" "$1" && fail "$3：不該含 [$2]（檔=$1）"
  ok
}
lines() { # lines <file>：不存在 = 0 行
  if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else printf '0'; fi
}
count() { # count <file> <字串>：出現行數（不存在 = 0）
  if [ -f "$1" ]; then grep -cF -- "$2" "$1" | tr -d ' '; else printf '0'; fi
}

sb="$tmp/sb"
SUP_LOG_FILE="$sb/results/supervisor.log"
FAULTS_LOG="$sb/results/faults.log"
STATE_JSON="$sb/results/watchdog-state.json"

# --- 沙箱 ---------------------------------------------------------------------

mkdir -p "$sb/run" "$sb/lib"
cp "$root/run/campaign-supervisor.sh" "$sb/run/campaign-supervisor.sh"

# faults.sh 替身：記下「以什麼參數、帶什麼環境」被啟動（真品行為由 test-faults.sh 驗）
cat > "$sb/run/faults.sh" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'faults.sh %s|AZ_RESOURCE_GROUP=%s|SSH_KEY=%s\n' \
  "$*" "${AZ_RESOURCE_GROUP:-}" "${SSH_KEY:-}" >> "$SUP_TRACE"
STUB

# manifest.py 替身：只提供 counts.pending（真品契約見 lib/manifest.py cmd_view）
cat > "$sb/lib/manifest.py" <<'PY'
import json
import os
import sys

with open(os.environ["FAKE_MANIFEST_LOG"], "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
pending = os.environ.get("FAKE_PENDING", "0")
if pending == "boom":
    sys.stderr.write("fake-manifest: boom\n")
    raise SystemExit(1)
sys.stdout.write(json.dumps({"counts": {"pending": int(pending)}}) + "\n")
PY

export PATH="$here/fakes:$PATH"
export SUP_ADMIN="fake@admin" SUP_SSH_KEY="$tmp/fake.key"
export SUP_POLL_SECS=0 SUP_RESTART_WAIT_SECS=1
export SUP_CLEAN_POLL_SECS=0 SUP_CLEAN_WAIT_MIN=1
export SUP_MAX_RESTARTS=1
export SUP_TRACE="$tmp/trace"
export FAKE_SSH_SCRIPT="$tmp/ssh.script" FAKE_SSH_LOG="$tmp/ssh.log" \
       FAKE_SSH_STATE="$tmp/ssh.state"
export FAKE_PGREP_DIR="$tmp/pgrep" FAKE_PGREP_LOG="$tmp/pgrep.log"
export FAKE_MANIFEST_LOG="$tmp/manifest.log"
export FAKE_PENDING=55

# PG 全 clean，但總數**不是** 129——舊版寫死 grep '129 active+clean'，這份 fixture
# 就是用來證明判準不再綁 PG 總數。
cat > "$tmp/status-clean.json" <<'JSON'
{"pgmap": {"pgs_by_state": [{"state_name": "active+clean", "count": 257}]}}
JSON
# 還有 PG 在 recovering：不得被當成 clean
cat > "$tmp/status-dirty.json" <<'JSON'
{"pgmap": {"pgs_by_state": [{"state_name": "active+clean", "count": 250},
                            {"state_name": "active+recovering", "count": 7}]}}
JSON
cat > "$tmp/pgls-empty.json" <<'JSON'
{"pg_stats": []}
JSON
cat > "$tmp/pgls-stuck.json" <<'JSON'
{"pg_stats": [{"pgid": "1.0", "state": "active+clean"},
              {"pgid": "1.2", "state": "active+recovering+degraded"},
              {"pgid": "1.5", "state": "active+recovery_wait+degraded"},
              {"pgid": "1.7", "state": "peering"}]}
JSON

reset() { # reset [pg-ls fixture] [ceph -s fixture]
  local pgls="${1:-$tmp/pgls-empty.json}" status="${2:-$tmp/status-clean.json}" i=0
  rm -rf "$sb/results" "$FAKE_PGREP_DIR" "$FAKE_SSH_STATE" "$SUP_TRACE"
  mkdir -p "$sb/results" "$FAKE_PGREP_DIR"
  : > "$FAKE_SSH_LOG"
  : > "$FAKE_PGREP_LOG"
  : > "$FAKE_MANIFEST_LOG"
  : > "$FAKE_SSH_SCRIPT"
  while [ "$i" -lt 6 ]; do
    {
      printf 'ceph pg ls --format json|0|0|%s\n' "$pgls"
      printf 'ceph -s --format json|0|0|%s\n' "$status"
      printf 'ceph pg repeer|0|0|\n'
    } >> "$FAKE_SSH_SCRIPT"
    i=$((i + 1))
  done
}

# 沒有任何 table = 沒有任何程序（佇列已死）。pstable <n> <cmdline...> 設第 n 次呼叫的表；
# 空表要用 `: > $FAKE_PGREP_DIR/table.<n>`（沿用規則見 tests/fakes/pgrep）。
pstable() {
  local n="$1"
  shift
  printf '%s\n' "$@" > "$FAKE_PGREP_DIR/table.$n"
}
queue_cmdline() { printf 'bash %s/run/faults.sh --yes-really-inject --resume' "$sb"; }

halt_state() { # halt_state <true|false> [halt_reason JSON 字串]
  printf '{"schema_version": 1, "halted": %s, "halt_reason": %s}\n' \
    "$1" "${2:-null}" > "$STATE_JSON"
}

run_sup() {
  RC=0
  bash "$sb/run/campaign-supervisor.sh" > "$tmp/stdout" 2> "$tmp/stderr" || RC=$?
}

# =============================================================================
# 1. halted=true → 這不是故障，是等人裁決：不重啟、不計次、不碰叢集
# =============================================================================
reset
halt_state true '"baseline-check HUMAN-NEEDED（recalibrate）"'
run_sup
eq "$RC" "0" "1.1 停手是正常收工，不該以錯誤碼結束"
has "$SUP_LOG_FILE" "supervisor: HALTED-BY-WATCHDOG" "1.2 停手要有可 grep 的機器行"
has "$SUP_LOG_FILE" "halt_reason=baseline-check HUMAN-NEEDED（recalibrate）" \
  "1.3 停手訊息要帶 halt_reason，人才知道在等什麼"
has "$SUP_LOG_FILE" "不是故障" "1.4 訊息要一眼看出這不是故障"
has "$SUP_LOG_FILE" "run/unhalt.sh" "1.5 要指出解除的方法"
hasnt "$SUP_LOG_FILE" "supervisor: RESTART" "1.6 halted 時一次都不准重啟"
eq "$(lines "$SUP_TRACE")" "0" "1.7 halted 時不得啟動 faults.sh"
eq "$(lines "$FAKE_SSH_LOG")" "0" "1.8 停手前不得對叢集下任何指令"
eq "$(lines "$FAKE_MANIFEST_LOG")" "0" "1.9 停手前連 manifest 都不必問"
eq "$(wc -c < "$tmp/stdout" | tr -d ' ')" "0" "1.10 日誌一律進 supervisor.log，不得污染 stdout"

# =============================================================================
# 2. halted=false → 照常重啟（新增的檢查不得把正常重啟一併關掉）
# =============================================================================
reset
halt_state false
printf 'FATAL: ceph_wait_recovery 逾時\nqueue: ABORT\n' > "$FAULTS_LOG"
run_sup
eq "$RC" "0" "2.1 重啟路徑也是正常收工"
has "$SUP_LOG_FILE" "supervisor: RESTART 1" "2.2 halted=false 時該重啟"
hasnt "$SUP_LOG_FILE" "supervisor: HALTED-BY-WATCHDOG" "2.3 沒 halted 不該說是被停手"
has "$SUP_TRACE" "faults.sh --yes-really-inject --resume" \
  "2.4 重啟要帶 --yes-really-inject --resume"
has "$SUP_TRACE" "AZ_RESOURCE_GROUP=cyshih-ceph-mclock-profiles" "2.5 重啟要帶 resource group"
has "$SUP_TRACE" "SSH_KEY=$tmp/fake.key" "2.6 重啟要把 ssh key 傳給佇列"
has "$SUP_LOG_FILE" "supervisor: RESTART-LIMIT" "2.7 超過上限要停手（擋真故障的無限迴圈）"
eq "$(count "$SUP_LOG_FILE" "supervisor: RESTART ")" "1" "2.8 上限 1 就只准重啟 1 次"

# =============================================================================
# 3. 狀態檔還不存在（全新 campaign）→ 視為未 halted，照常重啟，且不該吵
# =============================================================================
reset
rm -f "$STATE_JSON"
run_sup
has "$SUP_LOG_FILE" "supervisor: RESTART 1" "3.1 沒有狀態檔不該擋住重啟"
hasnt "$SUP_LOG_FILE" "supervisor: HALTED-BY-WATCHDOG" "3.2 檔案不存在 ≠ 被停手"
hasnt "$SUP_LOG_FILE" "supervisor: STATE-UNREADABLE" "3.3 檔案不存在是正常的，不該報解析失敗"

# =============================================================================
# 4. 狀態檔壞掉 →「不確定」要獨立留痕，不得靜默當成沒 halted
# =============================================================================
reset
printf 'not json at all\n' > "$STATE_JSON"
run_sup
has "$SUP_LOG_FILE" "supervisor: STATE-UNREADABLE" "4.1 解析失敗要有自己的機器行"
has "$SUP_LOG_FILE" "supervisor: RESTART 1" "4.2 不確定時照故障處理（停擺同樣要花錢）"

# =============================================================================
# 5. pending=0 → 跑完了，收工（與「等人」是不同的收工理由）
# =============================================================================
reset
halt_state false
FAKE_PENDING=0 run_sup
has "$SUP_LOG_FILE" "supervisor: DONE" "5.1 跑完要有 DONE"
hasnt "$SUP_LOG_FILE" "supervisor: RESTART" "5.2 跑完不得重啟"
has "$FAKE_MANIFEST_LOG" "view --results" "5.3 pending 要向 manifest.py view 問"

# =============================================================================
# 6. 佇列還活著 → 只是繼續巡邏（也證明真實啟動指令會被 pattern 認得）
# =============================================================================
reset
halt_state false
pstable 1 "$(queue_cmdline)"
pstable 2 "$(queue_cmdline)"
: > "$FAKE_PGREP_DIR/table.3"   # 第 3 輪：佇列自己收工了
FAKE_PENDING=0 run_sup
eq "$(lines "$FAKE_PGREP_LOG")" "3" "6.1 活著的兩輪只巡邏，第 3 輪才看到佇列不在"
has "$SUP_LOG_FILE" "supervisor: DONE" "6.2 佇列自己跑完後才收工"
eq "$(lines "$FAKE_MANIFEST_LOG")" "1" "6.3 佇列活著時不得去問 manifest（存活判斷要在最前面）"

# =============================================================================
# 7. pattern 不得誤中「只是提到 run/faults.sh」的程序
#    誤判成活著 = 真死掉的佇列沒人救（比空轉更難查：日誌上什麼都不會發生）
# =============================================================================
reset
halt_state false
pstable 1 \
  "shellcheck -x -S style $root/lib/common.sh $root/run/faults.sh $root/run/queue.sh" \
  "vim run/faults.sh" \
  "grep -rn run/faults.sh ." \
  "tail -f results/faults.log" \
  "python3 lib/verdict.py audit --results results"
: > "$FAKE_PGREP_DIR/table.4"   # 保險：即使 pattern 誤中，第 4 輪也會結束（測試不掛住）
run_sup
eq "$(lines "$FAKE_PGREP_LOG")" "2" \
  "7.1 這些都不是佇列——誤中的話要多巡邏好幾輪才會發現佇列已死"
has "$SUP_LOG_FILE" "supervisor: RESTART 1" "7.2 佇列已死就要重啟"
has "$SUP_TRACE" "faults.sh --yes-really-inject" "7.3 重啟要真的把佇列拉起來"

# =============================================================================
# 8. 等 PG 排空的判準不得綁死 PG 總數
# =============================================================================
# 8a. 全 clean（總數 257 ≠ 舊版寫死的 129）→ 不該白等到逾時
reset "$tmp/pgls-empty.json" "$tmp/status-clean.json"
halt_state false
run_sup
hasnt "$SUP_LOG_FILE" "supervisor: CLEAN-TIMEOUT" "8.1 PG 全 clean 就該放行，不論總數多少"
has "$SUP_LOG_FILE" "supervisor: RESTART 1" "8.2 前提：確實走到重啟這一步（否則 8.1 空過）"

# 8b. 還有 7 個 PG 在 recovering → 不得當成 clean（等到輪數上限才放行）
reset "$tmp/pgls-empty.json" "$tmp/status-dirty.json"
halt_state false
run_sup
has "$SUP_LOG_FILE" "supervisor: CLEAN-TIMEOUT" "8.3 沒 clean 就得等，等不到才逾時放行"
has "$SUP_LOG_FILE" "supervisor: RESTART 1" "8.4 逾時後仍要重啟（不能因為叢集不乾淨就卡死）"

# =============================================================================
# 9. repeer 只挑真正卡住的 PG（recovery_wait 是排隊中，碰它只會拖慢）
# =============================================================================
reset "$tmp/pgls-stuck.json" "$tmp/status-clean.json"
halt_state false
run_sup
has "$FAKE_SSH_LOG" "ceph pg repeer 1.2" "9.1 recovering 的 PG 要 repeer"
has "$FAKE_SSH_LOG" "ceph pg repeer 1.7" "9.2 peering 卡住的 PG 要 repeer"
hasnt "$FAKE_SSH_LOG" "ceph pg repeer 1.5" "9.3 recovery_wait 不是卡住，不得 repeer"
hasnt "$FAKE_SSH_LOG" "ceph pg repeer 1.0" "9.4 active+clean 不得 repeer"
has "$SUP_LOG_FILE" "supervisor: REPEER 1.2" "9.5 repeer 要留痕"

# =============================================================================
# 10. pilot gate（faults.sh exit 10/11）也是「等人」，不是故障
# =============================================================================
reset
halt_state false
printf 'faults: PILOT-GATE bundles=5\npilot 已完成，請檢查 schedule-estimate.json\n' \
  > "$FAULTS_LOG"
run_sup
has "$SUP_LOG_FILE" "supervisor: PILOT-GATE-WAIT" "10.1 停在 pilot gate 要等人，不是重啟"
hasnt "$SUP_LOG_FILE" "supervisor: RESTART" "10.2 pilot gate 重啟只會立刻再停在同一格"
eq "$(lines "$SUP_TRACE")" "0" "10.3 pilot gate 時不得啟動 faults.sh"

# 只是「日誌裡提到」PILOT-GATE 不算（必須是 faults.sh 印的機器行，行首）
reset
halt_state false
printf 'log: 上一輪曾經 faults: PILOT-GATE 過，已放行\nFATAL: 掛了\n' > "$FAULTS_LOG"
run_sup
hasnt "$SUP_LOG_FILE" "supervisor: PILOT-GATE-WAIT" "10.4 行中提及不算停在 gate"
has "$SUP_LOG_FILE" "supervisor: RESTART 1" "10.5 這是真的死了，要重啟"

# =============================================================================
# 11. pending 讀不到 → 不得當成 0（不確定 ≠ 跑完），且要留痕
# =============================================================================
reset
halt_state false
FAKE_PENDING=boom run_sup
has "$SUP_LOG_FILE" "supervisor: PENDING-UNKNOWN" "11.1 讀不到 pending 要有自己的機器行"
hasnt "$SUP_LOG_FILE" "supervisor: DONE" "11.2 讀不到 pending 不得宣告跑完"
has "$SUP_LOG_FILE" "supervisor: RESTART 1" "11.3 讀不到 pending 時照常重啟"

printf 'test-supervisor: %d assertions passed\n' "$asserts"
