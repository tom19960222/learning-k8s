#!/usr/bin/env bash
# Task 8 — lib/inject.sh 的 chaos 事件序列：min_size 安全不變條件、同 seed 重播一致、
# 展開後序列的執行（guard deadline = duration + 600、結束全回退）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
fx="$here/fixtures/ceph"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-inject-chaos.XXXXXX")"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"; ok; }
has() { grep -qF -- "$2" "$1" || fail "$3：未含 [$2]"; ok; }
hasnt() { grep -qF -- "$2" "$1" && fail "$3：不該含 [$2]"; ok; }
count_of() { grep -cF -- "$2" "$1" | tr -d ' '; }
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
export INJECT_TOPOLOGY_JSON="$fx/chaos-topology.json"
export ISO_DOWN_SECS=0
export ISO_CLOSED_SECS=0
export ISO_OPEN_SECS=0
export ISO_UP_SECS=0
export CHAOS_NO_SLEEP=1

reset_ssh() { : > "$FAKE_SSH_SCRIPT"; : > "$FAKE_SSH_LOG"; rm -rf "$FAKE_SSH_STATE"; }
expect_ssh() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$FAKE_SSH_SCRIPT"; }
guard_cmd() {
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

# 展開後的完整事件序列必須滿足 min_size=2 不變條件：
# 任一時刻的併發故障 OSD 只能落在同一個 rack（pool size=3 / failure domain=rack）。
check_invariant() { # <event-seq.json> [--expect-violation]
  python3 - "$@" <<'PY'
import json
import sys
doc = json.load(open(sys.argv[1]))
expect_violation = "--expect-violation" in sys.argv[2:]
events = doc["events"]
active = {}
violations = []
last_t = None
for ev in events:
    t = ev["t"]
    if last_t is not None and t < last_t:
        violations.append("事件未按時間排序：%s" % ev)
    last_t = t
    if ev["action"] in ("osd-stop", "node-isolate"):
        active[ev["node"]] = ev["rack"]
    elif ev["action"] in ("osd-start", "node-heal"):
        active.pop(ev["node"], None)
    else:
        violations.append("未知 action：%s" % ev["action"])
    racks = set(active.values())
    if len(racks) > 1:
        violations.append("t=%s 併發故障跨 %d 個 rack（PG 會低於 min_size=2）"
                          % (t, len(racks)))
    if len(active) > 2:
        violations.append("t=%s 併發故障 %d 顆 OSD" % (t, len(active)))
if active:
    violations.append("序列結束仍有未回退的故障：%s" % sorted(active))
if expect_violation:
    if not violations:
        sys.stderr.write("預期偵測到違反卻沒有\n")
        sys.exit(1)
    sys.exit(0)
if violations:
    sys.stderr.write("min_size 不變條件違反：\n  %s\n" % "\n  ".join(violations))
    sys.exit(1)
print(len(events))
PY
}

# shellcheck source=../lib/inject.sh
. "$root/lib/inject.sh"
inventory_load "$fixture"
inject_confirm --yes-really-inject
mkdir -p "$RESULTS_DIR"

# ==================================================== 產生器：安全不變條件 ==
# 1) 預設 seed 4242、真實 duration → 展開後的完整序列滿足 min_size 不變條件
chaos_generate 4242 1800 "$tmp/seq-4242.json" >/dev/null || fail "chaos_generate 應成功"
ok
n="$(check_invariant "$tmp/seq-4242.json")" || fail "seed 4242 的序列違反 min_size 不變條件"
ok
[ "$n" -ge 4 ] || fail "1800s 的 chaos 序列只有 ${n} 個事件，太稀疏"
ok
eq "$(jget "$tmp/seq-4242.json" seed)" "4242" "序列記錄 seed"
eq "$(jget "$tmp/seq-4242.json" duration_s)" "1800" "序列記錄 duration"
eq "$(jget "$tmp/seq-4242.json" invariant.min_size)" "2" "序列記錄 min_size 不變條件"
eq "$(jget "$tmp/seq-4242.json" invariant.max_concurrent_racks)" "1" \
  "併發故障只准落在單一 rack"
eq "$(jget "$tmp/seq-4242.json" invariant.verified)" "True" "產生器自我驗證"

# 2) 多個 seed / duration 都不得產出違反不變條件的序列
for s in 1 7 4242 99991; do
  for d in 600 1200 1800; do
    chaos_generate "$s" "$d" "$tmp/seq-$s-$d.json" >/dev/null \
      || fail "chaos_generate seed=$s duration=$d 應成功"
    check_invariant "$tmp/seq-$s-$d.json" >/dev/null \
      || fail "seed=$s duration=$d 違反 min_size 不變條件"
  done
done
ok

# 3) 同 seed 重播完全一致；不同 seed 會不同
chaos_generate 4242 1800 "$tmp/seq-again.json" >/dev/null || fail "重播應成功"
python3 -c 'import json,sys
a=json.load(open(sys.argv[1]))["events"]; b=json.load(open(sys.argv[2]))["events"]
assert a == b, "同 seed 的事件序列不一致"' "$tmp/seq-4242.json" "$tmp/seq-again.json" \
  || fail "同 seed 必須重播一致"
ok
python3 -c 'import json,sys
a=json.load(open(sys.argv[1]))["events"]; b=json.load(open(sys.argv[2]))["events"]
assert a != b, "不同 seed 卻產出相同序列"' "$tmp/seq-4242.json" "$tmp/seq-1-1800.json" \
  || fail "不同 seed 應產出不同序列"
ok

# 4) 事件都在 [0, duration] 內、每個 fault 都有對應 heal
python3 -c 'import json,sys
doc=json.load(open(sys.argv[1])); d=doc["duration_s"]
for ev in doc["events"]:
    assert 0 <= ev["t"] <= d, ev
    assert ev["node"] and ev["osd"] is not None and ev["rack"], ev
' "$tmp/seq-4242.json" || fail "事件必須落在 duration 內且欄位齊全"
ok

# 5) 不變條件檢查器不是空砲：跨 rack 併發的序列必須被抓出來
python3 - "$tmp/seq-bad.json" <<'PY'
import json
import sys
doc = {"schema_version": 1, "seed": 0, "duration_s": 600,
       "invariant": {"min_size": 2, "max_concurrent_racks": 1, "verified": False},
       "events": [
           {"t": 10, "action": "osd-stop", "node": "mclock-osd-1", "osd": 0, "rack": "rack1"},
           {"t": 20, "action": "node-isolate", "node": "mclock-osd-3", "osd": 2, "rack": "rack2"},
           {"t": 30, "action": "node-heal", "node": "mclock-osd-3", "osd": 2, "rack": "rack2"},
           {"t": 40, "action": "osd-start", "node": "mclock-osd-1", "osd": 0, "rack": "rack1"}]}
json.dump(doc, open(sys.argv[1], "w"), indent=1)
PY
check_invariant "$tmp/seq-bad.json" --expect-violation >/dev/null \
  || fail "檢查器必須抓到跨 rack 併發"
ok
# 產生器自己的驗證器也必須拒絕它（不是只有測試在檢查）
( inject_chaos_verify "$tmp/seq-bad.json" ) >/dev/null 2>&1 \
  && fail "inject_chaos_verify 必須拒絕跨 rack 併發的序列"
ok
inject_chaos_verify "$tmp/seq-4242.json" >/dev/null || fail "合法序列應通過驗證器"
ok

# ==================================================== chaos_run：執行序列 ==
up2="$tmp/up2.json";  mk_dump "$up2" 2 1 1 100 0 600
dn2="$tmp/dn2.json";  mk_dump "$dn2" 2 0 1 100 221 601
rj2="$tmp/rj2.json";  mk_dump "$rj2" 2 1 1 241 221 602
up3="$tmp/up3.json";  mk_dump "$up3" 3 1 1 100 0 600
dn3="$tmp/dn3.json";  mk_dump "$dn3" 3 0 1 100 220 601
rj3="$tmp/rj3.json";  mk_dump "$rj3" 3 1 1 240 220 602
printf 'mclock-iso: fired=0\nmclock-iso: flushed\n' > "$tmp/flush-ok.txt"

b1="$tmp/b1"; mkdir -p "$b1"
python3 - "$b1/event-seq.json" <<'PY'
import json
import sys
doc = {"schema_version": 1, "seed": 4242, "duration_s": 60,
       "params": {"note": "fixed for test"},
       "invariant": {"min_size": 2, "max_concurrent_faults": 2,
                     "max_concurrent_racks": 1, "verified": True},
       "events": [
           {"t": 1, "action": "osd-stop", "node": "mclock-osd-3", "osd": 2, "rack": "rack2"},
           {"t": 2, "action": "node-isolate", "node": "mclock-osd-4", "osd": 3, "rack": "rack2"},
           {"t": 3, "action": "node-heal", "node": "mclock-osd-4", "osd": 3, "rack": "rack2"},
           {"t": 4, "action": "osd-start", "node": "mclock-osd-3", "osd": 2, "rack": "rack2"}]}
json.dump(doc, open(sys.argv[1], "w"), indent=1)
PY
inject_cache_reset
reset_ssh
# osd-stop
expect_ssh 'osd dump' 0 0 "$up2"
expect_ssh 'orch daemon stop osd.2' 0 0 ""
expect_ssh 'osd dump' 0 0 "$dn2"
expect_ssh 'osd dump' 0 0 "$dn2"
# node-isolate（chaos 不 out）
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'osd metadata 3' 0 0 "$fx/osd-metadata-3.json"
expect_ssh 'osd dump' 0 0 "$up3"
expect_ssh 'nc -z' 0 0 ""
expect_ssh 'guard-mclock-osd-4' 0 0 ""
expect_ssh 'mclock-iso: armed' 0 0 ""
expect_ssh 'nc -z' 1 0 ""
expect_ssh 'inject-alive' 0 0 ""
expect_ssh 'osd dump' 0 0 "$dn3"
expect_ssh 'osd dump' 0 0 "$dn3"
# node-heal（chaos 不 in）
expect_ssh 'guard-mclock-osd-4' 0 0 ""
expect_ssh 'mclock-iso: flushed' 0 0 "$tmp/flush-ok.txt"
expect_ssh 'nc -z' 0 0 ""
expect_ssh 'osd dump' 0 0 "$rj3"
expect_ssh 'osd dump' 0 0 "$rj3"
# osd-start
expect_ssh 'orch daemon start osd.2' 0 0 ""
expect_ssh 'osd dump' 0 0 "$rj2"
expect_ssh 'osd dump' 0 0 "$rj2"
out="$(chaos_run 4242 60 "$b1")" || fail "chaos_run 應成功"
ok
eq "$out" "chaos: OK seed=4242 events=4" "chaos 機器行"
# 既有 event-seq.json（同 seed/duration）= resume 的唯一 SoT，不得重新產生
eq "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["events"]))' \
  "$b1/event-seq.json")" "4" "既有事件序列必須沿用"
# chaos 的 guard deadline = duration + 600（與 measurement cap 無關）
guard_cmd "guard-mclock-osd-4" > "$tmp/guard.txt"
has "$tmp/guard.txt" "sleep 660" "chaos guard deadline = duration + 600"
# chaos 只做 stop/start 與 isolate/heal，不 out/in（backfill 語意由故障區塊負責）
hasnt "$FAKE_SSH_LOG" "osd out" "chaos 不得 osd out"
hasnt "$FAKE_SSH_LOG" "osd in" "chaos 不得 osd in"
# 事件時間軸：逐事件 epoch + OSDMap epoch
eq "$(grep -c '"event": "chaos-event"' "$b1/inject-events.jsonl")" "4" "逐事件落時間軸"
has "$b1/inject-events.jsonl" '"map_epoch": 221' "事件要帶 OSDMap epoch"
# 結束時全數回退
eq "$(grep -c . "$b1/inject-active.tsv")" "0" "chaos 結束後 active registry 必須清空"

# seed/duration 與既有 event-seq.json 不符 → 重新產生（避免拿舊序列硬跑）
b2="$tmp/b2"; mkdir -p "$b2"
cp "$b1/event-seq.json" "$b2/event-seq.json"
inject_cache_reset
reset_ssh
chaos_prepare_seq 7 900 "$b2" >/dev/null || fail "chaos_prepare_seq 應成功"
ok
eq "$(jget "$b2/event-seq.json" seed)" "7" "seed 不符要重新產生"
eq "$(jget "$b2/event-seq.json" duration_s)" "900" "duration 不符要重新產生"
check_invariant "$b2/event-seq.json" >/dev/null || fail "重新產生的序列也要守不變條件"
ok

# 未確認旗標不得跑 chaos
b3="$tmp/b3"; mkdir -p "$b3"
reset_ssh
( INJECT_CONFIRMED='' chaos_run 4242 60 "$b3" ) >/dev/null 2>&1 \
  && fail "未確認就跑 chaos 應 die"
ok
eq "$(cat "$FAKE_SSH_STATE/count" 2>/dev/null || echo 0)" "0" "未確認時不得打出任何 ssh"

_CLEANUP_STACK=()
rm -rf "$tmp"
printf 'test-inject-chaos.sh: %d assertions passed\n' "$asserts"
