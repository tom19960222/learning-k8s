#!/usr/bin/env bash
# Task 2 — lib/common.sh（transport seam）+ fake ssh v2 協定。
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-common.XXXXXX")"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"; ok; }
has() { # has <file> <pattern> <desc>
  grep -qF -- "$2" "$1" || fail "$3：log 未含 [$2]"
  ok
}
hasnt() {
  grep -qF -- "$2" "$1" && fail "$3：log 不該含 [$2]"
  ok
}

# --- fake ssh v2 佈署 ---------------------------------------------------------
export PATH="$here/fakes:$PATH"
export FAKE_SSH_SCRIPT="$tmp/ssh.script"
export FAKE_SSH_LOG="$tmp/ssh.log"
export FAKE_SSH_STATE="$tmp/ssh.state"
export RESULTS_DIR="$tmp/results"

reset_ssh() { : > "$FAKE_SSH_SCRIPT"; : > "$FAKE_SSH_LOG"; rm -rf "$FAKE_SSH_STATE"; }
expect_ssh() { # expect_ssh <pattern> <rc> <delay> [stdout-file]
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$FAKE_SSH_SCRIPT"
}
ssh_calls() { cat "$FAKE_SSH_STATE/count" 2>/dev/null || printf '0\n'; }

# shellcheck source=../lib/inventory.sh
. "$root/lib/inventory.sh"
inventory_load "$fixture"
cleanup_push "rm -rf '$tmp'"

# =============================================================== fake ssh v2 ==
reset_ssh
# 1) 非預期指令 → fail（非靜默成功）
if ssh -o Foo=bar ikaros@1.2.3.4 'echo hi' >/dev/null 2>&1; then
  fail "fake ssh 對非預期指令應失敗"
fi
ok
eq "$(ssh_calls)" "1" "fake ssh 呼叫計數"
has "$FAKE_SSH_LOG" "echo hi" "fake ssh 記錄 argv"

# 2) 腳本比對 → rc + stdout-file
reset_ssh
printf 'HEALTH_OK\n' > "$tmp/health.out"
expect_ssh 'ceph -s' 0 0 "$tmp/health.out"
out="$(ssh ikaros@1.2.3.4 'ceph -s')" || fail "腳本化指令應成功"
eq "$out" "HEALTH_OK" "fake ssh 回放 stdout-file"

# 3) 同 pattern 先敗後成（順序消費）
reset_ssh
expect_ssh 'ceph health' 1 0 ""
expect_ssh 'ceph health' 0 0 "$tmp/health.out"
ssh h 'ceph health detail' >/dev/null 2>&1 && fail "第一次應失敗"
ok
out="$(ssh h 'ceph health detail')" || fail "第二次應成功"
eq "$out" "HEALTH_OK" "同 pattern 第二筆才回 stdout"
eq "$(ssh_calls)" "2" "順序消費後計數 = 2"
# 腳本用盡 → 再呼叫即 fail
ssh h 'ceph health detail' >/dev/null 2>&1 && fail "腳本用盡後應失敗"
ok

# ================================================================== node_ssh ==
# 4) admin 直連、無 ProxyJump
reset_ssh
expect_ssh 'ceph -s' 0 0 "$tmp/health.out"
out="$(node_ssh mclock-admin 'ceph -s')" || fail "node_ssh admin 應成功"
eq "$out" "HEALTH_OK" "node_ssh 傳回遠端 stdout"
has "$FAKE_SSH_LOG" "ikaros@20.63.11.5" "admin 走 public IP"
hasnt "$FAKE_SSH_LOG" "ProxyJump" "admin 不需 ProxyJump"
has "$FAKE_SSH_LOG" "BatchMode=yes" "固定選項 BatchMode"
has "$FAKE_SSH_LOG" "ConnectTimeout=10" "固定選項 ConnectTimeout"
has "$FAKE_SSH_LOG" "ServerAliveInterval=15" "固定選項 ServerAliveInterval"
has "$FAKE_SSH_LOG" "ServerAliveCountMax=4" "固定選項 ServerAliveCountMax"

# 5) 非 admin 走 ProxyJump + private IP
reset_ssh
expect_ssh 'lsblk' 0 0 ""
node_ssh mclock-osd-1 'lsblk' >/dev/null || fail "node_ssh osd 應成功"
ok
has "$FAKE_SSH_LOG" "ProxyJump=ikaros@20.63.11.5" "osd 經 admin 跳板"
has "$FAKE_SSH_LOG" "ikaros@10.60.1.21" "osd 用 private IP"

# 6) rc 透傳
reset_ssh
expect_ssh 'false-cmd' 7 0 ""
node_ssh mclock-mon-1 'false-cmd' >/dev/null 2>&1 && fail "rc 應為 7"
ok

# 7) 未載入 inventory → die（不得用空字串亂連）
reset_ssh
if ( unset ADMIN_PUBLIC_IP; node_ssh mclock-admin 'true' ) >/dev/null 2>&1; then
  fail "未載入 inventory 時 node_ssh 應 die"
fi
ok

# =============================================================== node_ssh_to ==
# 8) 遠端包 timeout + base64 payload
reset_ssh
b64="$(printf '%s' 'ceph -s' | base64 | tr -d '\n')"
expect_ssh 'base64' 0 0 "$tmp/health.out"
out="$(node_ssh_to 5 mclock-admin 'ceph -s')" || fail "node_ssh_to 應成功"
eq "$out" "HEALTH_OK" "node_ssh_to 傳回遠端 stdout"
has "$FAKE_SSH_LOG" "timeout 5" "遠端包 coreutils timeout"
has "$FAKE_SSH_LOG" "$b64" "指令以 base64 傳遞（避免引號地獄）"

# 9) 遠端 hang → bastion 端 deadline kill，rc=124 且有界
reset_ssh
expect_ssh 'base64' 0 9 ""
t0=$SECONDS
rc=0
NODE_SSH_KILL_GRACE=1 node_ssh_to 1 mclock-admin 'sleep 99' >/dev/null 2>&1 || rc=$?
elapsed=$((SECONDS - t0))
eq "$rc" "124" "hang 時 node_ssh_to 回 124"
[ "$elapsed" -lt 8 ] || fail "bastion deadline 未生效（elapsed=${elapsed}s）"
ok

# ============================================================= with_deadline ==
# 10) 第 3 次才成功
attempt_file="$tmp/attempts"
: > "$attempt_file"
poll_fn() {
  printf 'x' >> "$attempt_file"
  [ "$(wc -c < "$attempt_file" | tr -d ' ')" -ge 3 ]
}
POLL_INTERVAL=0.1 with_deadline 10 poll_fn || fail "with_deadline 應成功"
ok
eq "$(wc -c < "$attempt_file" | tr -d ' ')" "3" "with_deadline 重試到成功即停"

# 11) 逾時回 124、且會傳參數
never() { [ "$1" = "arg1" ] || return 9; return 1; }
rc=0
POLL_INTERVAL=0.1 with_deadline 1 never arg1 || rc=$?
eq "$rc" "124" "with_deadline 逾時回 124"

# 11b) secs 非整數一律 die（會被組進遠端指令列，不能放行）
if ( with_deadline "10s" true ) >/dev/null 2>&1; then fail "with_deadline 非整數秒應 die"; fi
ok
if ( node_ssh_to "" mclock-admin 'true' ) >/dev/null 2>&1; then fail "node_ssh_to 空秒數應 die"; fi
ok

# ================================================================= remote_bg ==
# 12) start：registry 路徑 + setsid + pid 回 stdout
reset_ssh
printf '4242\n' > "$tmp/pid.out"
expect_ssh '/run/mclock/sampler-1.cmd' 0 0 "$tmp/pid.out"
pid="$(remote_bg_start mclock-admin sampler-1 'while true; do date; sleep 5; done')" \
  || fail "remote_bg_start 應成功"
eq "$pid" "4242" "remote_bg_start 回遠端 pid"
has "$FAKE_SSH_LOG" "/run/mclock/sampler-1.pid" "registry pidfile"
has "$FAKE_SSH_LOG" "/run/mclock/sampler-1.cmd" "cmdline 指紋檔"
has "$FAKE_SSH_LOG" "setsid" "背景 process 脫離 session"
b64="$(printf '%s' 'while true; do date; sleep 5; done' | base64 | tr -d '\n')"
has "$FAKE_SSH_LOG" "$b64" "cmd 以 base64 傳遞"
has "$FAKE_SSH_LOG" "拒絕覆蓋" "registry 已有活著的 pid 時不得覆寫（否則舊 process 變孤兒）"

# 12b) 遠端拒絕重複啟動時 rc 要透傳
reset_ssh
expect_ssh '/run/mclock/sampler-1.cmd' 2 0 ""
rc=0
remote_bg_start mclock-admin sampler-1 'true' >/dev/null 2>&1 || rc=$?
eq "$rc" "2" "remote_bg_start 透傳遠端拒絕碼"

# 13) stop：kill registry pid、冪等
reset_ssh
expect_ssh '/run/mclock/sampler-1.pid' 0 0 ""
remote_bg_stop mclock-admin sampler-1 || fail "remote_bg_stop 應成功"
ok
has "$FAKE_SSH_LOG" "kill" "stop 會 kill"
reset_ssh
expect_ssh '/run/mclock/sampler-1.pid' 0 0 ""
remote_bg_stop mclock-admin sampler-1 || fail "remote_bg_stop 必須冪等"
ok

# 14) list：回 registry 內容
reset_ssh
printf 'sampler-1 4242 alive\nfio-c1 4300 dead\n' > "$tmp/list.out"
expect_ssh '/run/mclock' 0 0 "$tmp/list.out"
eq "$(remote_bg_list mclock-admin | wc -l | tr -d ' ')" "2" "remote_bg_list 行數"
eq "$(remote_bg_list mclock-admin 2>/dev/null | head -1)" "" "腳本用盡時不應偽造輸出"

# ============================================================= cleanup stack ==
# 15) LIFO + 正常結束時執行
cat > "$tmp/cleanup-test.sh" <<EOF
set -u
. "$root/lib/inventory.sh"
cleanup_push "echo A >> '$tmp/cleanup.log'"
cleanup_push "echo B >> '$tmp/cleanup.log'"
exit 0
EOF
: > "$tmp/cleanup.log"
bash "$tmp/cleanup-test.sh" >/dev/null 2>&1 || fail "cleanup 測試腳本應正常結束"
eq "$(tr '\n' ' ' < "$tmp/cleanup.log")" "B A " "cleanup stack 為 LIFO"

# 16) die 也會走 cleanup
cat > "$tmp/cleanup-die.sh" <<EOF
set -u
. "$root/lib/inventory.sh"
cleanup_push "echo DIED >> '$tmp/cleanup.log'"
die "boom"
EOF
: > "$tmp/cleanup.log"
bash "$tmp/cleanup-die.sh" >/dev/null 2>&1 && fail "die 應回非 0"
eq "$(tr -d '\n' < "$tmp/cleanup.log")" "DIED" "die 路徑也執行 cleanup"

# 16b) 空 stack 也要能安全收工（set -u 下展開空陣列的地雷）
cat > "$tmp/cleanup-empty.sh" <<EOF
set -u
. "$root/lib/inventory.sh"
exit 0
EOF
bash "$tmp/cleanup-empty.sh" >/dev/null 2>&1 || fail "空 cleanup stack 不該讓腳本失敗"
ok

# ==================================================================== bundle ==
# 17) new_bundle：穩定 key + attempts 時間戳
b1="$(new_bundle c07-balanced-4k-osd-down r2)"
[ -d "$b1" ] || fail "new_bundle 未建目錄"
ok
case "$b1" in
  "$RESULTS_DIR/c07-balanced-4k-osd-down/r2/attempts/"*) ok ;;
  *) fail "bundle 路徑不符：$b1" ;;
esac
eq "$(printf '%s' "$b1" | wc -l | tr -d ' ')" "0" "new_bundle stdout 只有一行"
b2="$(new_bundle c07-balanced-4k-osd-down r2)"
[ "$b1" != "$b2" ] || fail "同秒內第二次 attempt 應是新目錄"
ok

# 18) bundle_finalize：schema 全過才寫 DONE
cat > "$tmp/verdict-stub.py" <<'PY'
import sys
KIND = {
    "steady": ["prediction.json", "qos.json", "aggregate.json", "verdict.json"],
    "fault": ["prediction.json", "coverage-proof.json"],
}
if len(sys.argv) >= 3 and sys.argv[1] == "schemas" and sys.argv[2] in KIND:
    print("\n".join(KIND[sys.argv[2]]))
    sys.exit(0)
sys.exit(2)
PY
export VERDICT_PY="$tmp/verdict-stub.py"

bundle_is_done "$b1" && fail "新 bundle 不該是 DONE"
ok
printf '{}' > "$b1/prediction.json"
bundle_finalize "$b1" fault >/dev/null 2>&1 && fail "缺件時不該 finalize"
ok
[ ! -f "$b1/DONE" ] || fail "缺件時不得寫 DONE"
ok
printf '{}' > "$b1/coverage-proof.json"
bundle_finalize "$b1" fault >/dev/null 2>&1 || fail "齊件時 finalize 應成功"
ok
[ -f "$b1/DONE" ] || fail "finalize 後應有 DONE"
ok
bundle_is_done "$b1" || fail "bundle_is_done 應為真"
ok
[ -f "$RESULTS_DIR/c07-balanced-4k-osd-down/r2/DONE" ] || fail "replicate 級 DONE 缺失"
ok
# 未知 kind → die
if ( bundle_finalize "$b1" nope ) >/dev/null 2>&1; then fail "未知 kind 應 die"; fi
ok

# ====================================================================== misc ==
# 19) require_inject_flag
if ( require_inject_flag --dry-run ) >/dev/null 2>&1; then fail "無旗標應被擋"; fi
ok
( require_inject_flag --yes-really-inject ) || fail "帶旗標不該被擋"
ok

# 20) log 只走 stderr
eq "$(log '這行應該在 stderr' 2>/dev/null)" "" "log 不得污染 stdout"

printf 'test-common.sh: %d assertions passed\n' "$asserts"
