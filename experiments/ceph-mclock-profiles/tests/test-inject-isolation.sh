#!/usr/bin/env bash
# Task 8 — lib/inject.sh 的網路隔離狀態機（node / rack）：規則檔內容、guard 先於 chain、
# guard deadline 不變條件、三段驗證、rack 的 prepare/verify/commit barrier 與單台失敗回退。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
fx="$here/fixtures/ceph"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-inject-iso.XXXXXX")"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"; ok; }
has() { grep -qF -- "$2" "$1" || fail "$3：未含 [$2]"; ok; }
hasnt() { grep -qF -- "$2" "$1" && fail "$3：不該含 [$2]"; ok; }
count_of() { grep -cF -- "$2" "$1" | tr -d ' '; }
lineno_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
before() {
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
export MEASUREMENT_CAP=2700
export ISO_DOWN_SECS=0
export ISO_CLOSED_SECS=0
export ISO_OPEN_SECS=0
export ISO_UP_SECS=0

reset_ssh() { : > "$FAKE_SSH_SCRIPT"; : > "$FAKE_SSH_LOG"; rm -rf "$FAKE_SSH_STATE"; }
expect_ssh() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$FAKE_SSH_SCRIPT"; }
# 從 fake ssh log 還原「實際武裝的 guard 指令」（remote_bg_start 走 base64）
guard_cmd() { # <run-id>
  grep -F "${1}.cmd" "$FAKE_SSH_LOG" | head -1 \
    | sed -e "s/.*printf %s '//" -e "s/'.*//" | base64 --decode
}

mk_dump() { # <outfile> <osd> <up> <in> <up_from> <down_at> [epoch]
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
inject_confirm --yes-really-inject
mkdir -p "$RESULTS_DIR"

printf 'mclock-iso: fired=0\nmclock-iso: flushed\n' > "$tmp/flush-ok.txt"
printf 'mclock-iso: fired=1\nmclock-iso: flushed\n' > "$tmp/flush-fired.txt"

up3="$tmp/up3.json";  mk_dump "$up3" 3 1 1 100 0 600
dn3="$tmp/dn3.json";  mk_dump "$dn3" 3 0 1 100 220 601
rj3="$tmp/rj3.json";  mk_dump "$rj3" 3 1 1 240 220 602
up2="$tmp/up2.json";  mk_dump "$up2" 2 1 1 100 0 600
dn2="$tmp/dn2.json";  mk_dump "$dn2" 2 0 1 100 221 601
rj2="$tmp/rj2.json";  mk_dump "$rj2" 2 1 1 241 221 602

# ================================================================== 規則檔 ==
rules="$tmp/rules.txt"
inject_iso_rules mclock-osd-4 > "$rules" || fail "inject_iso_rules 應成功"
ok
has "$rules" "MCLOCK-ISO" "必須用專用 chain"
# ESTABLISHED,RELATED 只准開給 admin 的 tcp/22——否則既有 Ceph messenger 連線會續存
eq "$(count_of "$rules" 'ESTABLISHED')" "2" "只准兩條 ESTABLISHED 規則（ssh 進/出）"
eq "$(grep -c 'ESTABLISHED' "$rules")" "$(grep 'ESTABLISHED' "$rules" | grep -c '10.60.1.10')" \
  "每條 ESTABLISHED 規則都必須綁 admin private IP"
eq "$(grep -c 'ESTABLISHED' "$rules")" "$(grep 'ESTABLISHED' "$rules" | grep -c ' 22 ')" \
  "每條 ESTABLISHED 規則都必須綁 tcp/22"
eq "$(count_of "$rules" '-j ACCEPT')" "2" "除了 admin ssh 之外不得有任何 ACCEPT"
has "$rules" "-s 10.60.1.10/32 -p tcp --dport 22" "入向 ssh：來源 = admin private IP"
has "$rules" "-d 10.60.1.10/32 -p tcp --sport 22" "出向 ssh：目的 = admin private IP"
has "$rules" "-s 10.60.1.0/24 -j DROP" "其餘 subnet 流量入向 DROP"
has "$rules" "-d 10.60.1.0/24 -j DROP" "其餘 subnet 流量出向 DROP"
hasnt "$rules" "-s /32" "IP 不得是空字串（會 match 全部流量）"
hasnt "$rules" "-d /32" "IP 不得是空字串（會 match 全部流量）"
# 來源必須是 inventory，不是 fixture 硬編碼繞過
eq "$ADMIN_PRIVATE_IP" "10.60.1.10" "admin private IP 取自 inventory"
( ADMIN_PRIVATE_IP="" inject_iso_rules mclock-osd-4 ) >/dev/null 2>&1 \
  && fail "ADMIN_PRIVATE_IP 為空必須 die"
ok
( ADMIN_PRIVATE_IP="not-an-ip" inject_iso_rules mclock-osd-4 ) >/dev/null 2>&1 \
  && fail "ADMIN_PRIVATE_IP 格式不符必須 die"
ok

# ================================================== guard deadline 不變條件 ==
eq "$(inject_guard_secs)" "3300" "guard = measurement_cap + 600"
now="$(date +%s)"
eq "$(MEASUREMENT_DEADLINE=$((now + 2700)) inject_guard_secs)" "3300" \
  "measurement_deadline 一致時通過"
( MEASUREMENT_DEADLINE=$((now + 9000)) inject_guard_secs ) >/dev/null 2>&1 \
  && fail "guard_deadline < measurement_deadline + 600 必須 die"
ok
# chaos 的 guard 用 duration + 600，且不看 measurement cap
eq "$(MEASUREMENT_DEADLINE=$((now + 9000)) inject_guard_secs 1800 -)" "2400" \
  "chaos guard = duration + 600（不套 measurement_deadline）"

# ============================================================ node isolate ==
b1="$tmp/b1"; mkdir -p "$b1"
inject_cache_reset
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'osd metadata 3' 0 0 "$fx/osd-metadata-3.json"
expect_ssh 'osd dump' 0 0 "$up3"
expect_ssh 'nc -z' 0 0 ""                       # 注入前 endpoint 通
expect_ssh 'guard-mclock-osd-4' 0 0 ""          # guard 先武裝
expect_ssh 'mclock-iso: armed' 0 0 ""           # 再套 chain
expect_ssh 'nc -z' 1 0 ""                       # 注入後不通
expect_ssh 'inject-alive' 0 0 ""                # node_ssh 仍通
expect_ssh 'osd dump' 0 0 "$dn3"
expect_ssh 'osd dump' 0 0 "$dn3"
expect_ssh 'osd out 3' 0 0 ""
out="$(fault_node_isolate mclock-osd-4 "$b1")" || fail "fault_node_isolate 應成功"
ok
case "$out" in
  "node-isolate: OK mclock-osd-4 osd.3"*) ok ;;
  *) fail "node-isolate 機器行格式（got=[$out]）" ;;
esac
# guard 必須在 chain 之前武裝（避免「chain 套了、guard 沒起來」的窗口）
before "$FAKE_SSH_LOG" "guard-mclock-osd-4" "mclock-iso: armed" "guard 必須先於 chain 武裝"
# 實際武裝的 guard 指令：deadline = cap + 600，動作 = flush 專用 chain
guard_cmd "guard-mclock-osd-4" > "$tmp/guard.txt"
has "$tmp/guard.txt" "sleep 3300" "guard deadline = measurement_cap + 600"
has "$tmp/guard.txt" "iptables -F MCLOCK-ISO" "guard 動作 = flush 專用 chain"
has "$tmp/guard.txt" "guard-mclock-osd-4.fired" "guard 觸發要留 marker（taint 判定用）"
# 規則以 iptables-restore --noflush 原子套用
has "$FAKE_SSH_LOG" "iptables-restore --noflush" "chain 必須原子套用"
has "$FAKE_SSH_LOG" "-s 10.60.1.0/24 -j DROP" "實際送出的規則含 subnet DROP"
# 三段驗證的實際 endpoint 來自 osd metadata（不是猜 port）
has "$FAKE_SSH_LOG" "nc -z" "必須以 nc 探實際 endpoint"
has "$FAKE_SSH_LOG" "10.60.1.24 6800" "endpoint 來自 osd metadata 的 addr:port"
before "$FAKE_SSH_LOG" "mclock-iso: armed" "osd out 3" "驗證通過後才 commit（out）"
eq "$(jget "$b1/fault-timeline.json" down_map_epoch)" "220" "隔離也要記 OSDMap down epoch"
has "$b1/inject-events.jsonl" '"event": "node-isolate"' "事件時間軸要記隔離"
has "$b1/inject-active.tsv" "node-isolate" "active registry 要登記"

# 注入前 endpoint 就不通 → 之後的「不通」無從解讀，必須 die 且不套 chain
b2="$tmp/b2"; mkdir -p "$b2"
inject_cache_reset
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'osd metadata 3' 0 0 "$fx/osd-metadata-3.json"
expect_ssh 'osd dump' 0 0 "$up3"
expect_ssh 'nc -z' 1 0 ""
( fault_node_isolate mclock-osd-4 "$b2" ) >/dev/null 2>&1 \
  && fail "注入前 endpoint 不通應 die"
ok
hasnt "$FAKE_SSH_LOG" "iptables-restore" "前置驗證失敗不得套 chain"
hasnt "$FAKE_SSH_LOG" "osd out" "前置驗證失敗不得 out"

# 注入後 node_ssh 也斷 → 規則寫錯（把 bastion 一起關在外面），立即回退
b3="$tmp/b3"; mkdir -p "$b3"
inject_cache_reset
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'osd metadata 3' 0 0 "$fx/osd-metadata-3.json"
expect_ssh 'osd dump' 0 0 "$up3"
expect_ssh 'nc -z' 0 0 ""
expect_ssh 'guard-mclock-osd-4' 0 0 ""
expect_ssh 'mclock-iso: armed' 0 0 ""
expect_ssh 'nc -z' 1 0 ""
expect_ssh 'inject-alive' 255 0 ""              # ssh 斷了
expect_ssh 'guard-mclock-osd-4' 0 0 ""          # 回退：先 kill guard
expect_ssh 'mclock-iso: flushed' 0 0 "$tmp/flush-ok.txt"
set +e
fault_node_isolate mclock-osd-4 "$b3" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "node_ssh 斷線應視為注入失敗"
ok
hasnt "$FAKE_SSH_LOG" "osd out" "驗證未過不得 out"
has "$FAKE_SSH_LOG" "mclock-iso: flushed" "驗證未過要立即回退"

# =============================================================== node heal ==
inject_cache_reset
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'guard-mclock-osd-4' 0 0 ""          # 先 kill guard
expect_ssh 'mclock-iso: flushed' 0 0 "$tmp/flush-ok.txt"
expect_ssh 'nc -z' 0 0 ""                       # 恢復通
expect_ssh 'osd dump' 0 0 "$rj3"
expect_ssh 'osd dump' 0 0 "$rj3"
expect_ssh 'osd in 3' 0 0 ""
out="$(fault_node_heal mclock-osd-4 "$b1")" || fail "fault_node_heal 應成功"
ok
eq "$out" "node-heal: OK mclock-osd-4" "node-heal 機器行"
before "$FAKE_SSH_LOG" "guard-mclock-osd-4" "mclock-iso: flushed" "heal 必須先 kill guard 再 flush"
eq "$(grep -c . "$b1/inject-active.tsv")" "0" "heal 後 active registry 清空"
has "$b1/inject-events.jsonl" '"event": "node-heal"' "heal 要留事件"

# guard 曾觸發 = 安全網啟動 → attempt taint（guard 不是 heal 路徑）
b4="$tmp/b4"; mkdir -p "$b4"
printf 'node-isolate\tmclock-osd-4\t3\n' > "$b4/inject-active.tsv"
inject_cache_reset
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'guard-mclock-osd-4' 0 0 ""
expect_ssh 'mclock-iso: flushed' 0 0 "$tmp/flush-fired.txt"
expect_ssh 'nc -z' 0 0 ""
expect_ssh 'osd dump' 0 0 "$rj3"
expect_ssh 'osd dump' 0 0 "$rj3"
expect_ssh 'osd in 3' 0 0 ""
set +e
fault_node_heal mclock-osd-4 "$b4" >/dev/null
rc=$?
set -e
eq "$rc" "4" "guard 曾觸發應標 taint（rc 4）"
has "$b4/inject-taint.json" "guard" "guard 觸發的 taint 要落檔"

# =============================================================== rack barrier ==
# prepare（兩台各自 guard + chain）→ verify（兩台都過）→ commit（一次 out 兩顆）
rack_expect_ok() { # 兩台都通過 barrier 的完整期望
  inject_cache_reset
  reset_ssh
  expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
  expect_ssh 'osd metadata 2' 0 0 "$fx/osd-metadata-2.json"
  expect_ssh 'osd dump' 0 0 "$up2"
  expect_ssh 'osd metadata 3' 0 0 "$fx/osd-metadata-3.json"
  expect_ssh 'osd dump' 0 0 "$up3"
  expect_ssh 'nc -z' 0 0 ""
  expect_ssh 'nc -z' 0 0 ""
  expect_ssh 'guard-mclock-osd-3' 0 0 ""
  expect_ssh 'mclock-iso: armed' 0 0 ""
  expect_ssh 'guard-mclock-osd-4' 0 0 ""
  expect_ssh 'mclock-iso: armed' 0 0 ""
  expect_ssh 'nc -z' 1 0 ""
  expect_ssh 'inject-alive' 0 0 ""
  expect_ssh 'osd dump' 0 0 "$dn2"
  expect_ssh 'osd dump' 0 0 "$dn2"
  expect_ssh 'nc -z' 1 0 ""
  expect_ssh 'inject-alive' 0 0 ""
  expect_ssh 'osd dump' 0 0 "$dn3"
  expect_ssh 'osd dump' 0 0 "$dn3"
  expect_ssh 'osd out 2 3' 0 0 ""
}
b5="$tmp/b5"; mkdir -p "$b5"
rack_expect_ok
out="$(fault_rack_isolate rack2 "$b5")" || fail "fault_rack_isolate 應成功"
ok
case "$out" in
  "rack-isolate: OK rack2 "*) ok ;;
  *) fail "rack-isolate 機器行格式（got=[$out]）" ;;
esac
# commit 必須是「一次 out 兩顆」——backfill 起點單一
eq "$(count_of "$FAKE_SSH_LOG" 'osd out')" "1" "commit 只能下一次 osd out"
has "$FAKE_SSH_LOG" "osd out 2 3" "一次 out 兩顆"
# barrier：兩台都 verified 之後才 commit
before "$FAKE_SSH_LOG" "guard-mclock-osd-3" "mclock-iso: armed" "node-3 guard 先於 chain"
before "$FAKE_SSH_LOG" "guard-mclock-osd-4" "osd out 2 3" "兩台都武裝後才 commit"
eq "$(count_of "$FAKE_SSH_LOG" 'iptables-restore --noflush')" "2" "兩台各自套 chain"
eq "$(jget "$b5/fault-timeline.json" rack)" "rack2" "timeline 記 rack"
[ -n "$(jget "$b5/fault-timeline.json" prepare_skew_s)" ] || fail "缺 prepare_skew_s"
ok
eq "$(grep -c . "$b5/inject-active.tsv")" "2" "兩台都登記進 active registry"
[ -e "$b5/inject-taint.json" ] && fail "prepare 間隔在容忍範圍內不該 taint"
ok

# prepare 間隔超過容忍值 = 兩台不算「同時失效」→ 標 taint（但仍完成注入與量測回收）
b5b="$tmp/b5b"; mkdir -p "$b5b"
rack_expect_ok
RACK_PREPARE_MAX_SKEW_SECS=-1 fault_rack_isolate rack2 "$b5b" >/dev/null \
  || fail "skew 超標仍應完成注入（只是標 taint）"
ok
has "$b5b/inject-taint.json" "prepare" "prepare 間隔超標要落 taint 原因"

# 單台 verify 失敗 → 立即回退兩台 + taint，不得降級成單 node fault 續量
b6="$tmp/b6"; mkdir -p "$b6"
inject_cache_reset
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'osd metadata 2' 0 0 "$fx/osd-metadata-2.json"
expect_ssh 'osd dump' 0 0 "$up2"
expect_ssh 'osd metadata 3' 0 0 "$fx/osd-metadata-3.json"
expect_ssh 'osd dump' 0 0 "$up3"
expect_ssh 'nc -z' 0 0 ""
expect_ssh 'nc -z' 0 0 ""
expect_ssh 'guard-mclock-osd-3' 0 0 ""
expect_ssh 'mclock-iso: armed' 0 0 ""
expect_ssh 'guard-mclock-osd-4' 0 0 ""
expect_ssh 'mclock-iso: armed' 0 0 ""
expect_ssh 'nc -z' 1 0 ""
expect_ssh 'inject-alive' 0 0 ""
expect_ssh 'osd dump' 0 0 "$dn2"
expect_ssh 'osd dump' 0 0 "$dn2"
expect_ssh 'nc -z' 0 0 ""                       # node-4 的 endpoint 還通 → barrier 失敗
expect_ssh 'guard-mclock-osd-3' 0 0 ""          # 回退兩台
expect_ssh 'mclock-iso: flushed' 0 0 "$tmp/flush-ok.txt"
expect_ssh 'nc -z' 0 0 ""
expect_ssh 'osd dump' 0 0 "$rj2"
expect_ssh 'osd dump' 0 0 "$rj2"
expect_ssh 'guard-mclock-osd-4' 0 0 ""
expect_ssh 'mclock-iso: flushed' 0 0 "$tmp/flush-ok.txt"
expect_ssh 'nc -z' 0 0 ""
expect_ssh 'osd dump' 0 0 "$rj3"
expect_ssh 'osd dump' 0 0 "$rj3"
set +e
out="$(fault_rack_isolate rack2 "$b6")"
rc=$?
set -e
eq "$rc" "4" "單台 barrier 失敗應 taint（rc 4）"
case "$out" in
  "rack-isolate: TAINT rack2 "*) ok ;;
  *) fail "rack taint 機器行格式（got=[$out]）" ;;
esac
hasnt "$FAKE_SSH_LOG" "osd out" "barrier 失敗不得 commit（降級成單 node fault）"
eq "$(count_of "$FAKE_SSH_LOG" 'mclock-iso: flushed')" "2" "barrier 失敗要回退兩台"
eq "$(grep -c . "$b6/inject-active.tsv")" "0" "回退後 registry 必須清空"
has "$b6/inject-taint.json" "barrier" "barrier 失敗要落 taint 原因"

# rack heal：兩台 kill guard → flush → 驗恢復 → 等兩顆 up → 一次 in 兩顆
# （heal 逐台重查 endpoint：拿上一台的 ip:port 去探測會探出假陽性）
inject_cache_reset
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'osd metadata 2' 0 0 "$fx/osd-metadata-2.json"
expect_ssh 'guard-mclock-osd-3' 0 0 ""
expect_ssh 'mclock-iso: flushed' 0 0 "$tmp/flush-ok.txt"
expect_ssh 'nc -z' 0 0 ""
expect_ssh 'osd metadata 3' 0 0 "$fx/osd-metadata-3.json"
expect_ssh 'guard-mclock-osd-4' 0 0 ""
expect_ssh 'mclock-iso: flushed' 0 0 "$tmp/flush-ok.txt"
expect_ssh 'nc -z' 0 0 ""
expect_ssh 'osd dump' 0 0 "$rj2"
expect_ssh 'osd dump' 0 0 "$rj2"
expect_ssh 'osd dump' 0 0 "$rj3"
expect_ssh 'osd dump' 0 0 "$rj3"
expect_ssh 'osd in 2 3' 0 0 ""
out="$(fault_rack_heal rack2 "$b5")" || fail "fault_rack_heal 應成功"
ok
eq "$out" "rack-heal: OK rack2" "rack-heal 機器行"
eq "$(count_of "$FAKE_SSH_LOG" 'osd in')" "1" "一次 in 兩顆"
has "$FAKE_SSH_LOG" "osd in 2 3" "in 的是同一 rack 的兩顆"
# 回歸測試：每台都要用**自己的** endpoint 驗恢復（沿用上一台的 ip:port 會探出假陽性）
has "$FAKE_SSH_LOG" "nc -z -w 3 10.60.1.23 6800" "node-3 用自己的 endpoint 驗恢復"
has "$FAKE_SSH_LOG" "nc -z -w 3 10.60.1.24 6800" "node-4 用自己的 endpoint 驗恢復"
eq "$(grep -c . "$b5/inject-active.tsv")" "0" "heal 後 registry 清空"

# ============================================================ cleanup proof ==
cat > "$tmp/probe-clean.txt" <<'EOF'
iso-rules=0
guards=0
mclock-iso: probe-done
EOF
cat > "$tmp/probe-dirty.txt" <<'EOF'
iso-rules=4
guards=1
mclock-iso: probe-done
EOF
b7="$tmp/b7"; mkdir -p "$b7"
reset_ssh
for _ in 1 2 3 4 5 6 7 8; do expect_ssh 'mclock-iso: probe-done' 0 0 "$tmp/probe-clean.txt"; done
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-8up.json"
inject_cleanup_proof "$b7" >/dev/null || fail "全乾淨時 cleanup proof 應通過"
ok
eq "$(jget "$b7/cleanup-proof.json" verified)" "True" "cleanup-proof verified"
eq "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["nodes"]))' \
  "$b7/cleanup-proof.json")" "8" "八台 OSD node 都要查"
b8="$tmp/b8"; mkdir -p "$b8"
reset_ssh
expect_ssh 'mclock-iso: probe-done' 0 0 "$tmp/probe-dirty.txt"
for _ in 2 3 4 5 6 7 8; do expect_ssh 'mclock-iso: probe-done' 0 0 "$tmp/probe-clean.txt"; done
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-8up.json"
set +e
inject_cleanup_proof "$b8" >/dev/null
rc=$?
set -e
eq "$rc" "1" "有殘留規則/guard 時 cleanup proof 必須失敗"
eq "$(jget "$b8/cleanup-proof.json" verified)" "False" "殘留時 verified=false"

# endpoint parser：舊格式（無 addrvec 方括號）也要吃得下
eq "$(printf '%s' "$(cat "$fx/osd-metadata-4-v1only.json")" | inject_parse_endpoint)" \
  "10.60.1.25 6801" "v1-only metadata 的 endpoint"
eq "$(printf '%s' "$(cat "$fx/osd-metadata-3.json")" | inject_parse_endpoint)" \
  "10.60.1.24 6800" "addrvec 優先取 v2"

_CLEANUP_STACK=()
rm -rf "$tmp"
printf 'test-inject-isolation.sh: %d assertions passed\n' "$asserts"
