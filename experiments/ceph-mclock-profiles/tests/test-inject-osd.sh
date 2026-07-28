#!/usr/bin/env bash
# Task 8 — lib/inject.sh 的 OSD 級故障狀態機（flapping / osd-down）與共用設施
# （confirm gate、active registry、事件時間軸、rollback）。
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
fx="$here/fixtures/ceph"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-inject-osd.XXXXXX")"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"; ok; }
has() { grep -qF -- "$2" "$1" || fail "$3：未含 [$2]"; ok; }
hasnt() { grep -qF -- "$2" "$1" && fail "$3：不該含 [$2]"; ok; }
count_of() { grep -cF -- "$2" "$1" | tr -d ' '; }
lineno_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
before() { # <file> <pattern-a> <pattern-b> <desc>：a 必須早於 b
  local a b
  a="$(lineno_of "$1" "$2")"; b="$(lineno_of "$1" "$3")"
  [ -n "$a" ] || fail "$4：找不到 [$2]"
  [ -n "$b" ] || fail "$4：找不到 [$3]"
  [ "$a" -lt "$b" ] || fail "$4：[$2]（行 $a）必須早於 [$3]（行 $b）"
  ok
}
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$1" "$2"; }

export PATH="$here/fakes:$PATH"
export FAKE_SSH_SCRIPT="$tmp/ssh.script"
export FAKE_SSH_LOG="$tmp/ssh.log"
export FAKE_SSH_STATE="$tmp/ssh.state"
export RESULTS_DIR="$tmp/results"
export POLL_INTERVAL=0.02
export CEPH_FSID="3f2b1c8e-7a41-4c9d-9b0e-2d5a6f7c8b90"
export CEPH_OSD_IDS="0 1 2 3 4 5 6 7"
export FLAP_CYCLES=2
export FLAP_DOWN_GRACE_SECS=0
export FLAP_FORCE_DOWN_SECS=0
export FLAP_UP_SECS=0

reset_ssh() { : > "$FAKE_SSH_SCRIPT"; : > "$FAKE_SSH_LOG"; rm -rf "$FAKE_SSH_STATE"; }
expect_ssh() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$FAKE_SSH_SCRIPT"; }

# mk_dump <outfile> <osd> <up> <in> <up_from> <down_at> [epoch]
mk_dump() {
  python3 - "$@" <<'PY'
import json
import sys
out, osd, up, inn, up_from, down_at = sys.argv[1:7]
epoch = int(sys.argv[7]) if len(sys.argv) > 7 else 600
osds = []
for i in range(8):
    row = {"osd": i, "up": 1, "in": 1, "weight": 1.0, "up_from": 15,
           "up_thru": 500, "down_at": 0, "state": ["exists", "up"],
           "public_addr": "10.60.1.%d:6801/100%d" % (21 + i, i)}
    if i == int(osd):
        row["up"] = int(up)
        row["in"] = int(inn)
        row["up_from"] = int(up_from)
        row["down_at"] = int(down_at)
        row["state"] = ["exists", "up"] if int(up) else ["exists"]
    osds.append(row)
doc = {"epoch": epoch, "fsid": "3f2b1c8e", "flags": "noscrub,nodeep-scrub",
       "max_osd": 8, "osds": osds,
       "pools": [{"pool": 2, "pool_name": "mclock", "size": 3, "min_size": 2}]}
with open(out, "w") as fh:
    json.dump(doc, fh, indent=1)
PY
}

# shellcheck source=../lib/inject.sh
. "$root/lib/inject.sh"
inventory_load "$fixture"
mkdir -p "$RESULTS_DIR"

up0="$tmp/up0.json";   mk_dump "$up0" 3 1 1 100 0 600
dn1="$tmp/dn1.json";   mk_dump "$dn1" 3 0 1 100 200 601
up1="$tmp/up1.json";   mk_dump "$up1" 3 1 1 210 200 602
dn2="$tmp/dn2.json";   mk_dump "$dn2" 3 0 1 210 300 603
up2="$tmp/up2.json";   mk_dump "$up2" 3 1 1 310 300 604
outed="$tmp/outed.json"; mk_dump "$outed" 3 1 0 210 200 602

# ============================================================ confirm gate ==
# 1) 沒有 --yes-really-inject 一律不得注入（mutating 全域規則）
b0="$tmp/b0"; mkdir -p "$b0"
reset_ssh
( fault_osd_down 3 "$b0" ) >/dev/null 2>&1 && fail "未確認就注入應 die"
ok
eq "$(cat "$FAKE_SSH_STATE/count" 2>/dev/null || echo 0)" "0" "未確認時不得打出任何 ssh"
( inject_confirm --dry-run ) >/dev/null 2>&1 && fail "旗標不符應 die"
ok
inject_confirm --yes-really-inject || fail "inject_confirm 應接受正確旗標"
ok

# ======================================================== fault_osd_down ==
# 2) stop → 等 down → 立即 osd out；時間軸記 OSDMap down epoch（H-020）
b1="$tmp/b1"; mkdir -p "$b1"
reset_ssh
expect_ssh 'osd dump' 0 0 "$up0"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'list-units' 0 0 'x'
expect_ssh 'systemctl stop' 0 0 ""
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd out 3' 0 0 ""
out="$(fault_osd_down 3 "$b1")" || fail "fault_osd_down 應成功"
ok
case "$out" in
  "osd-down: OK osd.3 "*) ok ;;
  *) fail "fault_osd_down 機器行格式（got=[$out]）" ;;
esac
before "$FAKE_SSH_LOG" "systemctl stop" "osd out 3" "必須 down 之後才 out"
eq "$(jget "$b1/fault-timeline.json" down_map_epoch)" "200" "down_map_epoch = OSDMap down_at"
[ -n "$(jget "$b1/fault-timeline.json" down_epoch_t)" ] || fail "缺 down_epoch_t"
ok
has "$b1/inject-events.jsonl" '"event": "osd-down"' "事件時間軸要記 osd-down"
has "$b1/inject-events.jsonl" '"map_epoch": 200' "事件要帶 OSDMap epoch"
# H-020：注入時刻與 down epoch 是兩個獨立欄位，不可只留一個
has "$b1/fault-timeline.json" "down_map_epoch" "H-020 需要 OSDMap epoch 對齊欄位"
# 注入期間該 fault 必須登記在 active registry（abort 時才回退得了）
has "$b1/inject-active.tsv" "osd-down" "active registry 要登記 osd-down"

# 3) recover：start → 等 up → osd in
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'reset-failed' 0 0 ""
expect_ssh 'systemctl start' 0 0 ""
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'osd in 3' 0 0 ""
fault_osd_down_recover 3 "$b1" >/dev/null || fail "fault_osd_down_recover 應成功"
ok
before "$FAKE_SSH_LOG" "systemctl start" "osd in 3" "必須 up 之後才 in"
eq "$(grep -c . "$b1/inject-active.tsv")" "0" "recover 後 active registry 必須清空"
has "$b1/inject-events.jsonl" '"event": "osd-down-recover"' "recover 要留事件"

# 4) rollback：殘留的 osd-down 由 inject_rollback_all 收拾（cleanup stack 的實作）
b2="$tmp/b2"; mkdir -p "$b2"
reset_ssh
expect_ssh 'osd dump' 0 0 "$up0"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'list-units' 0 0 'x'
expect_ssh 'systemctl stop' 0 0 ""
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd out 3' 0 0 ""
fault_osd_down 3 "$b2" >/dev/null || fail "fault_osd_down 應成功"
ok
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'reset-failed' 0 0 ""
expect_ssh 'systemctl start' 0 0 ""
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'osd in 3' 0 0 ""
inject_rollback_all "$b2" >/dev/null || fail "inject_rollback_all 應成功"
ok
has "$FAKE_SSH_LOG" "systemctl start" "rollback 要把 daemon 拉回來"
has "$FAKE_SSH_LOG" "osd in 3" "rollback 要把 OSD in 回去"
eq "$(grep -c . "$b2/inject-active.tsv")" "0" "rollback 後 registry 清空"
# 冪等：registry 空了就不再打 ssh
reset_ssh
inject_rollback_all "$b2" >/dev/null || fail "inject_rollback_all 應冪等"
ok
eq "$(cat "$FAKE_SSH_STATE/count" 2>/dev/null || echo 0)" "0" "空 registry 不得打 ssh"

# ========================================================= fault_flapping ==
# 5) attempt 開始設 noout、結束 unset；10 輪（測試 2 輪）stop/down/start/up/PG gate；
#    全程不得 out。
b3="$tmp/b3"; mkdir -p "$b3"
reset_ssh
expect_ssh 'osd set noout' 0 0 ""
# cycle 1
expect_ssh 'osd dump' 0 0 "$up0"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'list-units' 0 0 'x'
expect_ssh 'systemctl stop' 0 0 ""
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'reset-failed' 0 0 ""
expect_ssh 'systemctl start' 0 0 ""
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'pg ls-by-osd 3' 0 0 "$fx/pg-ls-by-osd-active.json"
expect_ssh 'osd dump' 0 0 "$up1"
# cycle 2（host 已快取 → 不再查 osd tree；unit 存在性每次 stop 仍驗）
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'list-units' 0 0 'x'
expect_ssh 'systemctl stop' 0 0 ""
expect_ssh 'osd dump' 0 0 "$dn2"
expect_ssh 'osd dump' 0 0 "$dn2"
expect_ssh 'reset-failed' 0 0 ""
expect_ssh 'systemctl start' 0 0 ""
expect_ssh 'osd dump' 0 0 "$up2"
expect_ssh 'osd dump' 0 0 "$up2"
expect_ssh 'pg ls-by-osd 3' 0 0 "$fx/pg-ls-by-osd-active.json"
expect_ssh 'osd dump' 0 0 "$up2"
# 解除 noout 前先確認 OSD 已回到 up（否則 auto-out 會啟動非計畫 backfill）
expect_ssh 'osd dump' 0 0 "$up2"
expect_ssh 'osd unset noout' 0 0 ""
out="$(fault_flapping 3 "$b3")" || fail "fault_flapping 應成功"
ok
eq "$out" "flapping: OK osd.3 cycles=2" "flapping 機器行"
before "$FAKE_SSH_LOG" "osd set noout" "systemctl stop" "noout 必須在第一次 stop 之前"
before "$FAKE_SSH_LOG" "systemctl start" "osd unset noout" "unset noout 在最後"
hasnt "$FAKE_SSH_LOG" "osd out 3" "flapping 全程不得 out"
eq "$(count_of "$FAKE_SSH_LOG" 'systemctl stop')" "2" "跑滿設定的輪數"
eq "$(count_of "$FAKE_SSH_LOG" 'pg ls-by-osd 3')" "2" "每輪都要過 PG active gate"
eq "$(count_of "$FAKE_SSH_LOG" 'osd unset noout')" "1" "unset noout 恰一次"
# laggy 逐輪記錄（covariate，不 gate）
[ -s "$b3/laggy/cycle-1.json" ] || fail "缺 cycle-1 的 laggy covariate"
ok
[ -s "$b3/laggy/cycle-2.json" ] || fail "缺 cycle-2 的 laggy covariate"
ok
eq "$(grep -c '"event": "flap-cycle"' "$b3/inject-events.jsonl")" "2" "逐輪事件時間軸"
has "$b3/inject-events.jsonl" '"down_map_epoch": 200' "逐輪記 down 的 OSDMap epoch"
has "$b3/inject-events.jsonl" '"up_map_epoch": 310' "逐輪記 up 的 OSDMap epoch"
# 6) 超 grace 未判 down → 顯式 ceph osd down（不是靜靜等下去）
b4="$tmp/b4"; mkdir -p "$b4"
reset_ssh
expect_ssh 'osd set noout' 0 0 ""
expect_ssh 'osd dump' 0 0 "$up0"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'list-units' 0 0 'x'
expect_ssh 'systemctl stop' 0 0 ""
expect_ssh 'osd dump' 0 0 "$up0"          # 還沒判 down（grace 用完）
expect_ssh 'osd down 3' 0 0 ""            # 顯式標記
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'reset-failed' 0 0 ""
expect_ssh 'systemctl start' 0 0 ""
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'pg ls-by-osd 3' 0 0 "$fx/pg-ls-by-osd-active.json"
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'osd unset noout' 0 0 ""
FLAP_CYCLES=1 fault_flapping 3 "$b4" >/dev/null || fail "顯式 osd down 後應續行"
ok
has "$FAKE_SSH_LOG" "osd down 3" "超 grace 要顯式 ceph osd down"
before "$FAKE_SSH_LOG" "systemctl stop" "osd down 3" "先 stop 再顯式標記"
# noout 的對稱 unset 必須也在 cleanup stack（abort path 也要解）——上面這次呼叫沒有走
# command substitution，cleanup_push 才留得在本 shell 的 stack 裡。
printf '%s\n' "${_CLEANUP_STACK[@]+"${_CLEANUP_STACK[@]}"}" > "$tmp/stack.txt"
has "$tmp/stack.txt" "unset noout" "noout 必須以 cleanup_push 對稱註冊"

# 7) 目標 OSD 被 out（auto-out 逃過 noout）→ taint（rc 4）且仍要 unset noout
b5="$tmp/b5"; mkdir -p "$b5"
reset_ssh
expect_ssh 'osd set noout' 0 0 ""
expect_ssh 'osd dump' 0 0 "$up0"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'list-units' 0 0 'x'
expect_ssh 'systemctl stop' 0 0 ""
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'reset-failed' 0 0 ""
expect_ssh 'systemctl start' 0 0 ""
expect_ssh 'osd dump' 0 0 "$outed"
expect_ssh 'osd dump' 0 0 "$outed"
expect_ssh 'pg ls-by-osd 3' 0 0 "$fx/pg-ls-by-osd-active.json"
expect_ssh 'osd dump' 0 0 "$outed"
# 解除 noout 前的「確認已 up」檢查（osd 已 up，不需要拉起）
expect_ssh 'osd dump' 0 0 "$outed"
expect_ssh 'osd unset noout' 0 0 ""
set +e
out="$(fault_flapping 3 "$b5")"
rc=$?
set -e
eq "$rc" "4" "被 out 應回 taint（rc 4）"
case "$out" in
  "flapping: TAINT osd.3 "*) ok ;;
  *) fail "taint 機器行格式（got=[$out]）" ;;
esac
has "$b5/inject-taint.json" "out" "taint 原因要落檔"
eq "$(count_of "$FAKE_SSH_LOG" 'systemctl stop')" "1" "taint 後不得續跑下一輪"
has "$FAKE_SSH_LOG" "osd unset noout" "taint 也要 unset noout"

# 8) PG gate 沒過也算 taint（每輪 gate 是硬條件）
b6="$tmp/b6"; mkdir -p "$b6"
reset_ssh
expect_ssh 'osd set noout' 0 0 ""
expect_ssh 'osd dump' 0 0 "$up0"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'list-units' 0 0 'x'
expect_ssh 'systemctl stop' 0 0 ""
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd dump' 0 0 "$dn1"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'reset-failed' 0 0 ""
expect_ssh 'systemctl start' 0 0 ""
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'osd dump' 0 0 "$up1"
expect_ssh 'pg ls-by-osd 3' 0 0 "$fx/pg-ls-by-osd-peering.json"
expect_ssh 'osd unset noout' 0 0 ""
set +e
FLAP_PG_SECS=0 fault_flapping 3 "$b6" >/dev/null
rc=$?
set -e
eq "$rc" "4" "PG 未回 active 應 taint"
has "$FAKE_SSH_LOG" "osd unset noout" "PG taint 也要 unset noout"

# =============================================== 事件時間軸 / timeline 合併 ==
b7="$tmp/b7"; mkdir -p "$b7"
inject_timeline_set "$b7" fault_t0=1700000000 measurement_cap=2700
inject_timeline_set "$b7" down_epoch_t=1700000021
eq "$(jget "$b7/fault-timeline.json" fault_t0)" "1700000000" "timeline 合併不得覆蓋既有 key"
eq "$(jget "$b7/fault-timeline.json" down_epoch_t)" "1700000021" "timeline 合併寫入新 key"
eq "$(jget "$b7/fault-timeline.json" measurement_cap)" "2700" "timeline 保留 cap"
inject_event "$b7" probe map_epoch=42 note=hello
has "$b7/inject-events.jsonl" '"event": "probe"' "inject_event 落 JSONL"
python3 -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert rows[-1]["map_epoch"] == 42, rows[-1]
assert isinstance(rows[-1]["t"], int), rows[-1]
' "$b7/inject-events.jsonl" || fail "事件必須有整數 epoch t 與數值 map_epoch"
ok

_CLEANUP_STACK=()
rm -rf "$tmp"
printf 'test-inject-osd.sh: %d assertions passed\n' "$asserts"
