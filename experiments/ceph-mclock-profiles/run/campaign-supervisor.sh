#!/usr/bin/env bash
# ceph-mclock-profiles — 故障佇列看門程式（campaign supervisor）。
#
# 用法（在本機 macOS bastion 上 detached 跑，PPID=1）：
#   cd experiments/ceph-mclock-profiles
#   nohup bash run/campaign-supervisor.sh >/dev/null 2>&1 &
#
# 只做一件事：故障佇列（run/faults.sh）**非預期死亡**時，把叢集等回穩定後重新拉起。
# 存在的理由是長跑 campaign 每隔幾小時就會被單點錯誤打斷，人不在的時段叢集空燒 $8/hr。
#
# 「佇列不在了」有四種成因，混為一談就是 2026-07-31 空轉 40 次的根因（被 watchdog 停下的
# 佇列每 2 分鐘被拉起、每次起來立刻再 halt，17:35→18:18 全部白燒）：
#
#   (a) 跑完了              pending=0                                → 收工
#   (b) watchdog 停佇列     results/watchdog-state.json halted=true  → **等人裁決，不重啟**
#   (c) pilot gate 等放行   faults.log 尾巴有 PILOT-GATE/CENSORED    → **等人裁決，不重啟**
#   (d) 真的死了（crash）   其餘                                      → 重啟（有次數上限）
#
# (b)(c) 都是「人要來裁決」，不是故障：**不重啟、不計入重啟次數**，直接收工並在
# results/supervisor.log 留下一眼能懂的訊息。重啟次數上限只用來擋 (d) 的無限迴圈。
#
# 已知盲區（刻意不修，理由寫在各自的位置）：
#   1. 「程序還在、但沒有進展」（卡死）偵測不到——pgrep 只證明 PID 存在。這裡不加心跳：
#      進度語意屬於 lib/pipeline.sh（它已有 coverage/sampler 心跳與 run/faults.sh 的 12h
#      REPORT），在 supervisor 複製第二套判準只會多一個會誤判的東西。真卡死時人得自己看
#      results/faults.log 的時間戳。
#   2. 同時跑兩個 supervisor 會各自重啟佇列；最後一道防線是 faults.sh 的 runner lock
#      （單 runner，會拒絕併發）。啟動前請自己確認沒有第二個在跑。
#   3. 佇列存活判斷靠 pgrep -f 比對 cmdline，所以 repo 路徑含空白時會失準（本 repo 無空白）。
#
# 環境變數（全部有預設；測試靠它們把整支腳本注入沙箱）：
#   SUP_ROOT            實驗根目錄（預設 = 本檔的上一層）
#   SUP_RESULTS         結果目錄（預設 $SUP_ROOT/results）
#   SUP_LOG             本程式的日誌（預設 $SUP_RESULTS/supervisor.log）
#   SUP_FAULTS_LOG      佇列日誌（預設 $SUP_RESULTS/faults.log）
#   SUP_STATE_JSON      watchdog 狀態檔（預設 $SUP_RESULTS/watchdog-state.json）
#   SUP_MANIFEST_PY     manifest.py 路徑（預設 $SUP_ROOT/lib/manifest.py）
#   SUP_SSH_KEY/SUP_ADMIN/SUP_RG   連 Azure admin node 用的 key／目標／resource group
#   SUP_POLL_SECS       佇列還活著時的巡邏間隔（預設 300）
#   SUP_RESTART_WAIT_SECS  重啟後等佇列站穩的秒數（預設 120）
#   SUP_MAX_RESTARTS    重啟次數上限（預設 40）
#   SUP_CLEAN_WAIT_MIN  重啟前等 PG 全 clean 的輪數上限（預設 90 輪 × 60s）
#   SUP_CLEAN_POLL_SECS 等 clean 的輪詢間隔（預設 60）
#   SUP_QUEUE_PATTERN   佇列存活比對用的 pgrep -f pattern
#
# 離開碼：0 = 正常收工（跑完／等人／到重啟上限）；1 = 啟動期環境錯誤。
# 這支程式**沒有** set -e：看門程式不該因為一個暫時性的非 0 就自己死掉。
set -u

SUP_ROOT="${SUP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$SUP_ROOT" || { printf 'supervisor: 無法進入 %s\n' "$SUP_ROOT" >&2; exit 1; }

SUP_RESULTS="${SUP_RESULTS:-$SUP_ROOT/results}"
SUP_LOG="${SUP_LOG:-$SUP_RESULTS/supervisor.log}"
SUP_FAULTS_LOG="${SUP_FAULTS_LOG:-$SUP_RESULTS/faults.log}"
SUP_STATE_JSON="${SUP_STATE_JSON:-$SUP_RESULTS/watchdog-state.json}"
SUP_MANIFEST_PY="${SUP_MANIFEST_PY:-$SUP_ROOT/lib/manifest.py}"
SUP_SSH_KEY="${SUP_SSH_KEY:-${SSH_KEY:-/Users/ikaros/Documents/code/learning-k8s/.ssh/id_ed25519}}"
SUP_ADMIN="${SUP_ADMIN:-ikaros@20.89.226.108}"
SUP_RG="${SUP_RG:-cyshih-ceph-mclock-profiles}"
SUP_POLL_SECS="${SUP_POLL_SECS:-300}"
SUP_RESTART_WAIT_SECS="${SUP_RESTART_WAIT_SECS:-120}"
SUP_MAX_RESTARTS="${SUP_MAX_RESTARTS:-40}"
SUP_CLEAN_WAIT_MIN="${SUP_CLEAN_WAIT_MIN:-90}"
SUP_CLEAN_POLL_SECS="${SUP_CLEAN_POLL_SECS:-60}"

# 佇列存活比對：**必須**要求 cmdline 裡有「bash ... run/faults.sh」，不能只比對
# `run/faults.sh`。後者會把任何「只是提到這個檔名」的程序當成佇列還活著，例如
#   tests/gate.sh 每次跑的 `shellcheck -x -S style .../run/faults.sh`
#   `vim run/faults.sh`、`grep -rn run/faults.sh .`
# 這類誤判的後果比空轉更難查：佇列其實已經死了，supervisor 卻一路睡下去。
SUP_QUEUE_PATTERN="${SUP_QUEUE_PATTERN:-bash [^ ]*run/faults\.sh}"

mkdir -p "$(dirname "$SUP_LOG")" 2>/dev/null || true

slog() { printf '[%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$SUP_LOG"; }

sup_ssh() {
  ssh -i "$SUP_SSH_KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o StrictHostKeyChecking=no "$SUP_ADMIN" "$@" < /dev/null 2>/dev/null
}

# --- 佇列狀態的三種判讀（分開判，不得混為一談）----------------------------------

sup_queue_alive() { pgrep -f "$SUP_QUEUE_PATTERN" >/dev/null 2>&1; }

# sup_halt_reason：佇列是不是被 watchdog **刻意**停下的。
# 唯一 SoT 是 results/watchdog-state.json（由 lib/pipeline.sh 的 watchdog 與 run/unhalt.sh
# 寫入）。這裡直接讀 JSON 而不 source lib/pipeline.sh：supervisor 是長跑的 detached
# 程序，把 54KB 的 pipeline（含 cleanup trap／die 語意）拉進來等於多一個會拖死看門狗的
# 相依；而且 pipeline 只有 watchdog_halted（回傳碼），沒有取 halt_reason 的 getter。
# 輸出：halted → halt_reason（沒填理由則印 "-"）；未 halted 或檔案不存在 → 空字串。
# 讀得到但解析失敗 → rc 2（「不確定」和「確定沒停手」是兩回事，呼叫端分開處理）。
sup_halt_reason() {
  [ -f "$SUP_STATE_JSON" ] || return 0
  python3 - "$SUP_STATE_JSON" <<'PY' || return 2
import json
import sys

try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(2)
if doc.get("halted"):
    sys.stdout.write(str(doc.get("halt_reason") or "-") + "\n")
PY
}

# sup_pilot_gate：佇列是不是停在 pilot gate 等人放行（faults.sh 的 exit 10／11）。
# 這同樣是「等人」而不是故障，重啟只會讓它立刻再停在同一格。
# supervisor 靠輪詢 pgrep 判存活，看不到 faults.sh 的離開碼，所以只能刮日誌尾巴；
# 為了避免刮到上一輪的殘影，只看最後幾行（重啟後 faults.sh 一定會先印
# MARGINS-OK / reconcile / runner-lock 等好幾行，舊的 gate 行不會還留在尾巴）。
sup_pilot_gate() {
  tail -5 "$SUP_FAULTS_LOG" 2>/dev/null \
    | grep -oE '^faults: (PILOT-GATE|PILOT-CENSORED)' | tail -1
}

# sup_pending：還有幾個 execution 沒跑。讀不到印 "?"（不是 0——不確定不等於跑完）。
sup_pending() {
  python3 "$SUP_MANIFEST_PY" view --results "$SUP_RESULTS" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["counts"]["pending"])' \
      2>/dev/null \
    || printf '?\n'
}

# --- 重啟前的叢集整備 -----------------------------------------------------------

# 卡住的 PG 先 repeer（只挑真正卡住的，不碰 recovery_wait——那是排隊中，會自己好）
sup_repeer_stuck() {
  local pg
  for pg in $(sup_ssh 'sudo ceph pg ls --format json' | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for p in doc.get("pg_stats") or []:
    st = str(p.get("state", "")).split("+")
    if "recovering" in st or "peering" in st:
        print(p["pgid"])
' 2>/dev/null); do
    sup_ssh "sudo ceph pg repeer $pg" >/dev/null 2>&1
    slog "supervisor: REPEER ${pg}"
  done
}

# sup_cluster_clean：PG 是不是全部 active+clean。
# 舊寫法是 `ceph -s | grep -q '129 active+clean'`——把「叢集乾淨」和「PG 總數剛好是 129」
# 綁在一起。PG 數只要變動（pg_autoscaler、加 pool、加 OSD、改 pg_num）條件就永遠不成立，
# 於是每次重啟都白等滿 90 分鐘，而且只會多印一行逾時，看不出是判準壞了。
# 改成解析 `ceph -s --format json` 的 pgmap.pgs_by_state 比對 clean == total，
# 與 lib/ceph.sh 的 pg_states() 同一份 JSON 契約（不另立第二套語意）。
# ssh 失敗／輸出不是 JSON → 一律當成「還沒 clean」，由上層的輪數上限收尾。
sup_cluster_clean() {
  sup_ssh 'sudo ceph -s --format json' | python3 -c '
import json, sys
try:
    pgmap = json.load(sys.stdin).get("pgmap", {})
except Exception:
    raise SystemExit(1)
total = clean = 0
for entry in pgmap.get("pgs_by_state", []):
    n = int(entry.get("count", 0))
    total += n
    if set(str(entry.get("state_name", "")).split("+")) == set(("active", "clean")):
        clean += n
raise SystemExit(0 if total > 0 and clean == total else 1)
'
}

sup_wait_clean() {
  local w=0
  until sup_cluster_clean; do
    w=$((w + 1))
    if [ "$w" -gt "$SUP_CLEAN_WAIT_MIN" ]; then
      slog "supervisor: CLEAN-TIMEOUT 等 PG 全 clean 超過 ${SUP_CLEAN_WAIT_MIN} 輪，仍照常重啟"
      return 0
    fi
    sleep "$SUP_CLEAN_POLL_SECS"
  done
}

# --- 主迴圈 ---------------------------------------------------------------------

restarts=0
while :; do
  # 佇列還在 → 什麼都不做（注意：這只證明 PID 在，不證明有進展；見開頭盲區 1）
  if sup_queue_alive; then
    sleep "$SUP_POLL_SECS"
    continue
  fi

  # 佇列不在了。以下三種「不是故障」的情況必須先排除，才輪得到重啟。
  halt_rc=0
  halt_reason="$(sup_halt_reason)" || halt_rc=$?
  if [ "$halt_rc" -ne 0 ]; then
    # 讀不到狀態檔內容 ≠ 沒有 halt。分不出來時照故障處理（停擺同樣要花錢），
    # 但一定要留下這一行，讓人知道判斷是在資訊不全的情況下做的。
    slog "supervisor: STATE-UNREADABLE ${SUP_STATE_JSON} 解析失敗——分不出『刻意停手』與『故障』，本輪按故障處理"
  elif [ -n "$halt_reason" ]; then
    slog "supervisor: HALTED-BY-WATCHDOG 佇列是被 watchdog 刻意停下的，不是故障——不重啟、不計入重啟次數。halt_reason=${halt_reason}"
    slog "supervisor: 等你裁決。排除原因後跑 run/unhalt.sh \"<理由>\" 解除，再重新啟動本 supervisor。收工。"
    break
  fi

  gate="$(sup_pilot_gate)"
  if [ -n "$gate" ]; then
    slog "supervisor: PILOT-GATE-WAIT 佇列停在 ${gate}，等人工放行／裁示——不重啟、不計入重啟次數。收工。"
    break
  fi

  pend="$(sup_pending)"
  if [ "$pend" = "0" ]; then
    slog "supervisor: DONE 佇列已跑完（pending=0），收工"
    break
  fi
  if [ "$pend" = "?" ]; then
    slog "supervisor: PENDING-UNKNOWN manifest.py view 讀不到 pending——當作還有工作，照常重啟"
  fi

  restarts=$((restarts + 1))
  if [ "$restarts" -gt "$SUP_MAX_RESTARTS" ]; then
    slog "supervisor: RESTART-LIMIT 重啟次數超過 ${SUP_MAX_RESTARTS}，停手等人介入"
    break
  fi

  why="$(grep -vE 'Permanently added|Warning: ' "$SUP_FAULTS_LOG" 2>/dev/null \
         | tail -3 | tr '\n' '|')"
  slog "supervisor: RESTART ${restarts} 佇列已死（pending=${pend}）。最後日誌：${why}"

  sup_repeer_stuck
  sup_wait_clean

  AZ_RESOURCE_GROUP="$SUP_RG" SSH_KEY="$SUP_SSH_KEY" \
    nohup bash "$SUP_ROOT/run/faults.sh" --yes-really-inject --resume \
    >> "$SUP_FAULTS_LOG" 2>&1 &
  slog "supervisor: RESTARTED 已重啟佇列"
  sleep "$SUP_RESTART_WAIT_SECS"
done

exit 0
