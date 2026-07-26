#!/usr/bin/env bash
# Task 9 — lib/collect.sh：replicate 級 sampler、campaign 級 bg collector、
# coverage supervisor（headline endpoint 的 stall vs gap 證據）、return-backfill（H-008）、
# collect_cell 與 env snapshot 三段。
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
fx="$here/fixtures/collect"
fxc="$here/fixtures/ceph"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-collect.XXXXXX")"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"; ok; }
has() { grep -qF -- "$2" "$1" || fail "$3：未含 [$2]"; ok; }
hasnt() { grep -qF -- "$2" "$1" && fail "$3：不該含 [$2]"; ok; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$1" "$2"; }
jlen() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    if k == "": continue
    d = d[int(k)] if isinstance(d, list) else d[k]
print(len(d))' "$1" "$2"; }

export PATH="$here/fakes:$PATH"
export FAKE_SSH_SCRIPT="$tmp/ssh.script"
export FAKE_SSH_LOG="$tmp/ssh.log"
export FAKE_SSH_STATE="$tmp/ssh.state"
export RESULTS_DIR="$tmp/results"
export POLL_INTERVAL=0.05
export CEPH_FSID="3f2b1c8e-7a41-4c9d-9b0e-2d5a6f7c8b90"
export CEPH_OSD_IDS="0 1 2 3 4 5 6 7"

reset_ssh() { : > "$FAKE_SSH_SCRIPT"; : > "$FAKE_SSH_LOG"; rm -rf "$FAKE_SSH_STATE"; }
expect_ssh() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$FAKE_SSH_SCRIPT"; }
ssh_calls() { [ -f "$FAKE_SSH_STATE/count" ] && cat "$FAKE_SSH_STATE/count" || echo 0; }
b64dec() { # stdin → stdout（macOS 的 base64 沒有 --decode）
  local data; data="$(cat)"
  printf '%s' "$data" | base64 -D 2>/dev/null || printf '%s' "$data" | base64 -d
}
# 把 remote_bg_start 送出去的 base64 內層腳本還原（測試要斷言真正跑在遠端的東西）
decode_bg() { # <call-n> → stdout
  sed -n "s/.*printf %s '\\([A-Za-z0-9+/=]*\\)'.*/\\1/p" "$FAKE_SSH_STATE/call.$1.args" | b64dec
}
call_args() { cat "$FAKE_SSH_STATE/call.$1.args"; }
mkfile() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }

# shellcheck source=../lib/collect.sh
. "$root/lib/collect.sh"
inventory_load "$fixture"
cleanup_push "rm -rf '$tmp'"
mkdir -p "$RESULTS_DIR"

BUNDLE="$RESULTS_DIR/c07/r1/attempts/20260725T031000Z"
mkdir -p "$BUNDLE"
KEY="c07-r1-20260725T031000Z"
SAMPLER_ID="sampler-${KEY}"

# ================================================================= 命名契約 ====
# 1) bundle key / run-id / heartbeat 路徑是 Task 7/11 共用的契約，必須穩定。
eq "$(collect_bundle_key "$BUNDLE")" "$KEY" "collect_bundle_key"
eq "$(collect_sampler_run_id "$BUNDLE")" "$SAMPLER_ID" "sampler run-id"
eq "$(collect_fio_run_id "$BUNDLE" mclock-client-1)" "fio-${KEY}-mclock-client-1" \
  "fio run-id（Task 7 契約）"
eq "$(collect_hb_path "$SAMPLER_ID")" "/run/mclock/${SAMPLER_ID}.hb" "heartbeat 路徑"

# ============================================================ sampler_start ====
# 2) 先取 lock 再 remote_bg_start（順序不可倒：沒 lock 就起會有兩個 sampler 同時寫）
reset_ssh
expect_ssh "mkdir /run/mclock/${SAMPLER_ID}.lock" 0 0 ""
expect_ssh "${SAMPLER_ID}.pid" 0 0 "$tmp/pid.txt"
printf '4242\n' > "$tmp/pid.txt"
out="$(sampler_start "$BUNDLE")" || fail "sampler_start 應成功"
eq "$out" "sampler: STARTED ${SAMPLER_ID} 4242" "sampler_start 機器行"
eq "$(ssh_calls)" "2" "sampler_start 只該打兩通（lock + bg start）"
has "$FAKE_SSH_STATE/call.1.args" "mkdir /run/mclock/${SAMPLER_ID}.lock" "第一通是取 lock"
has "$FAKE_SSH_STATE/call.2.args" "/run/mclock/${SAMPLER_ID}.pid" "第二通才是 bg start（PID registry）"

# 3) 遠端迴圈內容：5s 粒度、pg dump 差分、ceph -s、OSDMap epoch、heartbeat
decode_bg 2 > "$tmp/sampler.sh"
has "$tmp/sampler.sh" "ceph pg dump --format json" "sampler 收 pg dump"
has "$tmp/sampler.sh" "ceph -s --format json" "sampler 收 ceph -s"
has "$tmp/sampler.sh" "ceph osd dump --format json" "sampler 收 OSDMap epoch"
has "$tmp/sampler.sh" "sleep 5" "sampler 為 5s 粒度"
has "$tmp/sampler.sh" "/run/mclock/${SAMPLER_ID}.hb" "sampler 寫 heartbeat"
has "$tmp/sampler.sh" "tick" "sampler 每輪用同一份 python 契約產樣本"
# 全量 pg dump 只留頭尾，逐輪只留差分用的緊緻樣本（45min × 5s 不能存 540 份全量）
has "$tmp/sampler.sh" "pgdump-first.json" "sampler 保留第一份全量 pg dump"
has "$tmp/sampler.sh" "pgdump-last.json" "sampler 保留最後一份全量 pg dump"

# 4) bundle 內留下 run marker（stop/collect/reconcile 都靠它）
[ -s "$BUNDLE/sampler/run.json" ] || fail "sampler_start 未寫 run marker"
ok
eq "$(jget "$BUNDLE/sampler/run.json" run_id)" "$SAMPLER_ID" "run marker 的 run_id"
eq "$(jget "$BUNDLE/sampler/run.json" node)" "mclock-admin" "sampler 跑在 admin"
eq "$(jget "$BUNDLE/sampler/run.json" pid)" "4242" "run marker 記 pid"

# 5) lock 被別人佔住 → 不得啟動（rc≠0）
reset_ssh
rm -rf "$BUNDLE/sampler"
expect_ssh "mkdir /run/mclock/${SAMPLER_ID}.lock" 2 0 ""
if (sampler_start "$BUNDLE") >/dev/null 2>&1; then
  fail "lock busy 時 sampler_start 不該成功"
fi
ok
[ -e "$BUNDLE/sampler/run.json" ] && fail "lock busy 時不該留 run marker"
ok

# ====================================================== sampler_assert_alive ==
mk_marker() { # 重新建立 run marker（供 assert/stop 測試）
  reset_ssh
  expect_ssh "mkdir /run/mclock/${SAMPLER_ID}.lock" 0 0 ""
  expect_ssh "${SAMPLER_ID}.pid" 0 0 "$tmp/pid.txt"
  sampler_start "$BUNDLE" >/dev/null || fail "sampler_start（marker 重建）失敗"
}
mk_marker

# 6) heartbeat 新鮮 → OK
reset_ssh
printf '3 alive\n' > "$tmp/hb.txt"
expect_ssh "/run/mclock/${SAMPLER_ID}.hb" 0 0 "$tmp/hb.txt"
out="$(sampler_assert_alive "$BUNDLE")" || fail "heartbeat 新鮮時應回 0"
eq "$out" "sampler-alive: OK 3" "sampler_assert_alive 機器行"

# 7) heartbeat 過期 → rc 1（不是 die：supervisor 要能把 attempt 標 taint 後續跑）
reset_ssh
printf '900 alive\n' > "$tmp/hb.txt"
expect_ssh "/run/mclock/${SAMPLER_ID}.hb" 0 0 "$tmp/hb.txt"
if (sampler_assert_alive "$BUNDLE") >/dev/null 2>&1; then
  fail "heartbeat 過期應回非 0"
fi
ok

# 8) heartbeat 檔不存在（age=-1）→ rc 1
reset_ssh
printf -- '-1 dead\n' > "$tmp/hb.txt"
expect_ssh "/run/mclock/${SAMPLER_ID}.hb" 0 0 "$tmp/hb.txt"
if (sampler_assert_alive "$BUNDLE") >/dev/null 2>&1; then
  fail "heartbeat 不存在應回非 0"
fi
ok

# ============================================================= sampler_stop ===
# 9) stop：停 bg + 放 lock + 更新 marker
reset_ssh
expect_ssh "remote_bg_stop" 0 0 ""
expect_ssh "rm -rf /run/mclock/${SAMPLER_ID}.lock" 0 0 ""
out="$(sampler_stop "$BUNDLE")" || fail "sampler_stop 應成功"
eq "$out" "sampler: STOPPED ${SAMPLER_ID}" "sampler_stop 機器行"
eq "$(ssh_calls)" "2" "sampler_stop 打兩通（stop + unlock）"
[ -s "$BUNDLE/sampler/stopped.json" ] || fail "sampler_stop 未寫 stopped marker"
ok

# 10) 冪等：第二次 stop 完全不碰 ssh
reset_ssh
out="$(sampler_stop "$BUNDLE")" || fail "重複 sampler_stop 應成功（冪等）"
eq "$(ssh_calls)" "0" "重複 sampler_stop 不得再打 ssh"
eq "$out" "sampler: STOPPED ${SAMPLER_ID}" "重複 stop 仍印同一機器行"

# 11) 從未 start 過的 bundle → stop 是 no-op
reset_ssh
nb="$RESULTS_DIR/c99/r1/attempts/20260101T000000Z"; mkdir -p "$nb"
out="$(sampler_stop "$nb")" || fail "未 start 的 bundle stop 應成功"
eq "$(ssh_calls)" "0" "未 start 的 bundle 不得打 ssh"
eq "$out" "sampler: STOPPED -" "未 start 的 stop 機器行"

# ================================================== sampler tick（python 契約）==
# 12) tick 直接吃真實格式的 pg dump / ceph -s / osd dump → 一行緊緻樣本
rec="$(collect_py_tick 1785000000 "$fx/pg-dump-recovering.json" \
        "$fxc/ceph-s-recovering.json" "$fxc/osd-dump-osd3-down.json")" \
  || fail "tick 應成功"
printf '%s\n' "$rec" > "$tmp/tick.json"
eq "$(jget "$tmp/tick.json" t)" "1785000000" "tick 記錄時戳"
eq "$(jget "$tmp/tick.json" osdmap_epoch)" "512" "tick 取 OSDMap epoch（osd dump 權威）"
eq "$(jget "$tmp/tick.json" recovered_bytes_cum)" "10737418240" "tick 取累計 recovered bytes"
eq "$(jget "$tmp/tick.json" recovered_objects_cum)" "2560" "tick 取累計 recovered objects"
eq "$(jget "$tmp/tick.json" pg_counts.peering)" "1" "tick 分開統計 peering PG"
eq "$(jget "$tmp/tick.json" pg_counts.recovering)" "2" "tick 分開統計 recovering PG"
eq "$(jget "$tmp/tick.json" pg_counts.backfilling)" "1" "tick 統計 backfilling PG"
eq "$(jget "$tmp/tick.json" pg_counts.inactive)" "1" "tick 統計 inactive（peering 不含 active）PG"
eq "$(jget "$tmp/tick.json" degraded_objects)" "12000" "tick 取 degraded objects"
eq "$(jget "$tmp/tick.json" num_up_osds)" "7" "tick 取 up OSD 數"
eq "$(jget "$tmp/tick.json" osds_down.0)" "3" "tick 記錄哪顆 OSD down（H-020 時間軸對齊）"
eq "$(jget "$tmp/tick.json" flags)" "noscrub,nodeep-scrub" "tick 記錄 OSDMap flags"

# 13) 壞掉／空的輸入 → 不得吐出假樣本（rc≠0，遠端才不會更新 heartbeat）
: > "$tmp/empty.json"
if collect_py_tick 1785000000 "$tmp/empty.json" "$fxc/ceph-s-recovering.json" \
     "$fxc/osd-dump-8up.json" >/dev/null 2>&1; then
  fail "pg dump 壞掉時 tick 不該成功"
fi
ok

# ============================================================== bg_collect ====
# 14) campaign 級：15 台各一個 net collector（fping + sar）+ admin 的 events collector
reset_ssh
n=0
while [ "$n" -lt 16 ]; do
  expect_ssh ".lock" 0 0 ""
  expect_ssh ".pid" 0 0 "$tmp/pid.txt"
  n=$((n + 1))
done
out="$(bg_collect_start)" || fail "bg_collect_start 應成功"
eq "$out" "bg-collect: STARTED 16" "bg_collect_start 機器行（15 net + 1 events）"
eq "$(ssh_calls)" "32" "bg_collect_start 每個 collector 兩通（lock + start）"
decode_bg 2 > "$tmp/bgnet.sh"
has "$tmp/bgnet.sh" "fping" "ping mesh 用 fping（PROVISIONING R §6）"
has "$tmp/bgnet.sh" "-p 1000" "ping mesh 為 1s 間隔"
has "$tmp/bgnet.sh" "10.60.1.34" "ping mesh 目標含全部 node private IP"
has "$tmp/bgnet.sh" "sar -n DEV 10" "NIC 差分用 sar 10s"
has "$tmp/bgnet.sh" "/run/mclock/bgc-net-" "net collector 寫 heartbeat"
decode_bg 32 > "$tmp/bgevt.sh"
has "$tmp/bgevt.sh" "ceph -W cluster" "events collector 收 cluster log（SLOW_OPS）"
has "$tmp/bgevt.sh" "ceph health detail" "events collector 收 health 事件"
has "$tmp/bgevt.sh" "/run/mclock/bgc-events.hb" "events collector 寫 heartbeat"
[ -s "$RESULTS_DIR/bg-collect.json" ] || fail "bg_collect_start 未寫 state 檔"
ok
eq "$(jlen "$RESULTS_DIR/bg-collect.json" entries)" "16" "state 檔記錄 16 個 collector"

# 15) alive 檢查：全新鮮 → ALIVE；任一過期 → DEAD（rc 1，reconcile 據此重啟）
python3 - "$RESULTS_DIR/bg-collect.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["entries"] = [e for e in doc["entries"]
                  if e["run_id"] in ("bgc-net-mclock-admin", "bgc-events")]
json.dump(doc, open(sys.argv[1], "w"), indent=1)
PY
reset_ssh
printf '5 alive\n' > "$tmp/hb.txt"
expect_ssh "bgc-net-mclock-admin.hb" 0 0 "$tmp/hb.txt"
expect_ssh "bgc-events.hb" 0 0 "$tmp/hb.txt"
out="$(bg_collect_assert_alive)" || fail "全新鮮時 bg_collect_assert_alive 應回 0"
eq "$out" "bg-collect: ALIVE 2" "bg_collect_assert_alive 機器行"

reset_ssh
printf '9999 dead\n' > "$tmp/hbdead.txt"
expect_ssh "bgc-net-mclock-admin.hb" 0 0 "$tmp/hbdead.txt"
expect_ssh "bgc-events.hb" 0 0 "$tmp/hb.txt"
out="$(bg_collect_assert_alive)" && fail "有 collector 死掉時應回非 0"
eq "$out" "bg-collect: DEAD 1 bgc-net-mclock-admin" "死掉的 collector 要指名（watchdog 只重啟它）"

# 15b) reconcile 路徑：只重啟死掉的那個 collector，活著的不得被碰
reset_ssh
expect_ssh "bgc-net-mclock-admin.hb" 0 0 "$tmp/hbdead.txt"
expect_ssh "bgc-events.hb" 0 0 "$tmp/hb.txt"
expect_ssh "remote_bg_stop" 0 0 ""
expect_ssh "rm -rf /run/mclock/bgc-net-mclock-admin.lock" 0 0 ""
expect_ssh "mkdir /run/mclock/bgc-net-mclock-admin.lock" 0 0 ""
expect_ssh "bgc-net-mclock-admin.pid" 0 0 "$tmp/pid.txt"
out="$(bg_collect_ensure)" || fail "bg_collect_ensure 應成功"
eq "$out" "bg-collect: RESTARTED 1" "bg_collect_ensure 只重啟死掉的 collector"
eq "$(ssh_calls)" "6" "活著的 collector 不得被重啟（多打 ssh = 誤傷）"
hasnt "$FAKE_SSH_LOG" "mkdir /run/mclock/bgc-events.lock" \
  "events collector 還活著，不得被重啟"

# 16) stop：逐個停 + 放 lock + 回收資料，state 檔轉為 stopped
reset_ssh
tar -C "$fx" -cf "$tmp/bgdata.tar" pg-dump-clean.json
n=0
while [ "$n" -lt 2 ]; do
  expect_ssh "remote_bg_stop" 0 0 ""
  expect_ssh "rm -rf /run/mclock/bgc-" 0 0 ""
  expect_ssh "tar -C /var/tmp/mclock/bgcollect" 0 0 "$tmp/bgdata.tar"
  n=$((n + 1))
done
out="$(bg_collect_stop)" || fail "bg_collect_stop 應成功"
eq "$out" "bg-collect: STOPPED 2" "bg_collect_stop 機器行"
[ -s "$RESULTS_DIR/bg-collect/mclock-admin/pg-dump-clean.json" ] \
  || fail "bg_collect_stop 未回收 collector 資料"
ok
[ -e "$RESULTS_DIR/bg-collect.json" ] && fail "stop 後 state 檔應轉為 stopped"
ok
reset_ssh
out="$(bg_collect_stop)" || fail "重複 bg_collect_stop 應成功（冪等）"
eq "$(ssh_calls)" "0" "重複 bg_collect_stop 不得再打 ssh"

# ========================================================= coverage_check =====
mk_marker
# 17) 全部 collector 新鮮 → OK，逐次檢查落 checks.jsonl
reset_ssh
printf '4 alive\n' > "$tmp/hb.txt"
expect_ssh "/run/mclock/${SAMPLER_ID}.hb" 0 0 "$tmp/hb.txt"
for c in 1 2 3 4; do
  expect_ssh "/run/mclock/fio-${KEY}-mclock-client-${c}.hb" 0 0 "$tmp/hb.txt"
done
out="$(coverage_check "$BUNDLE" 1785000100)" || fail "全新鮮時 coverage_check 應回 0"
eq "$out" "coverage-check: OK 5" "coverage_check 機器行（1 sampler + 4 client）"
eq "$(ssh_calls)" "5" "coverage_check 每個 source 一通"
[ -s "$BUNDLE/coverage/checks.jsonl" ] || fail "coverage_check 未寫 checks.jsonl"
ok

# 18) 某個 client 的 fio heartbeat 死掉 → rc 1 且記錄該 source
reset_ssh
expect_ssh "/run/mclock/${SAMPLER_ID}.hb" 0 0 "$tmp/hb.txt"
expect_ssh "/run/mclock/fio-${KEY}-mclock-client-1.hb" 0 0 "$tmp/hbdead.txt"
for c in 2 3 4; do
  expect_ssh "/run/mclock/fio-${KEY}-mclock-client-${c}.hb" 0 0 "$tmp/hb.txt"
done
out="$(coverage_check "$BUNDLE" 1785000130)" && fail "有 source 死掉時 coverage_check 應回非 0"
eq "$out" "coverage-check: DEGRADED 1" "coverage_check 退化機器行"
grep -q "fio:mclock-client-1" "$BUNDLE/coverage/checks.jsonl" \
  || fail "checks.jsonl 未記錄壞掉的 source"
ok

# 18b) fio.sh（Task 7）真正的 heartbeat 在 <workdir>/heartbeat，且 workdir 記在
#      <bundle>/fio/run.tsv；有 run.tsv 就必須走它，不能用 registry 的預設路徑猜。
reset_ssh
mkdir -p "$BUNDLE/fio"
for c in 1 2 3 4; do
  printf 'mclock-client-%s\tfio-segment-mclock-client-%s\t/var/tmp/mclock-fio/fio-segment-mclock-client-%s\n' \
    "$c" "$c" "$c" >> "$BUNDLE/fio/run.tsv"
done
expect_ssh "/run/mclock/${SAMPLER_ID}.hb" 0 0 "$tmp/hb.txt"
for c in 1 2 3 4; do
  expect_ssh "/var/tmp/mclock-fio/fio-segment-mclock-client-${c}/heartbeat" 0 0 "$tmp/hb.txt"
done
out="$(coverage_check "$BUNDLE" 1785000160)" || fail "run.tsv 路徑的 coverage_check 應回 0"
eq "$out" "coverage-check: OK 5" "coverage_check 走 fio.sh 的 workdir heartbeat"
hasnt "$FAKE_SSH_LOG" "/run/mclock/fio-${KEY}-mclock-client-1.hb" \
  "有 run.tsv 時不得改用 registry 的猜測路徑"
rm -rf "$BUNDLE/fio"

# ====================================================== coverage_finalize =====
# 共用：建一個乾淨的量測窗（sampler 5s 樣本 + fio 逐秒 log + 30s cadence 的 checks）
mk_cov_bundle() { # <dir> <start> <secs> [gen-samples 額外參數...]
  local d="$1" start="$2" secs="$3"; shift 3
  rm -rf "$d"; mkdir -p "$d/coverage" "$d/sampler"
  python3 "$here/fixtures/gen-samples.py" --out "$d/sampler/samples.jsonl" \
    --start "$start" --count $((secs / 5)) --interval 5 "$@" >/dev/null
  python3 "$here/fixtures/gen-fio-logs.py" --out "$d/fio/mclock-client-1" \
    --seg seg01 --start "$start" --seconds "$secs" >/dev/null
}
mk_checks() { # <dir> <start> <end> <cadence> [bad-from bad-to bad-source]
  python3 - "$@" <<'PY'
import json, sys
d, start, end, cad = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
bad_from = int(sys.argv[5]) if len(sys.argv) > 5 else -1
bad_to = int(sys.argv[6]) if len(sys.argv) > 6 else -1
bad_src = sys.argv[7] if len(sys.argv) > 7 else ""
rows = []
t = start
while t <= end:
    srcs = {"sampler": {"age_s": 4, "ok": True},
            "fio:mclock-client-1": {"age_s": 4, "ok": True}}
    if bad_src and bad_from <= t <= bad_to:
        srcs[bad_src] = {"age_s": 9999, "ok": False}
    rows.append({"t": t, "max_age_s": 30, "sources": srcs,
                 "ok": all(s["ok"] for s in srcs.values())})
    t += cad
with open(d + "/coverage/checks.jsonl", "w") as fh:
    for r in rows:
        fh.write(json.dumps(r, sort_keys=True) + "\n")
PY
}

# 19) 健康的量測窗 → 無 gap、不 taint
CB="$tmp/cov-clean"
mk_cov_bundle "$CB" 1785000000 300
mk_checks "$CB" 1785000000 1785000300 30
out="$(coverage_finalize "$CB" 1785000000 1785000299)" || fail "健康量測窗不該 taint"
eq "$out" "coverage-proof: OK gaps=0 gap_seconds=0 tainted=false" "coverage_finalize 機器行"
eq "$(jget "$CB/coverage-proof.json" window.start)" "1785000000" "coverage-proof 窗起點"
eq "$(jget "$CB/coverage-proof.json" window.end)" "1785000299" "coverage-proof 窗終點"
eq "$(jget "$CB/coverage-proof.json" tainted)" "False" "健康窗不 taint"
eq "$(jget "$CB/coverage-proof.json" covered_seconds)" "300" "逐秒覆蓋數"

# 20) sampler 中斷 40s、但 fio 還在寫 → 不算 gap（有資料就不遮），但要 taint（證據不足）
CB2="$tmp/cov-sampler-dead"
mk_cov_bundle "$CB2" 1785000000 300 --hole-at 100 --hole-secs 40
mk_checks "$CB2" 1785000000 1785000300 30 1785000100 1785000140 sampler
out="$(coverage_finalize "$CB2" 1785000000 1785000299)" \
  && fail "sampler 中斷 40s 應標 taint（rc≠0）"
eq "$(jget "$CB2/coverage-proof.json" tainted)" "True" "sampler 長中斷 → taint"
eq "$(jget "$CB2/coverage-proof.json" gap_seconds)" "0" "有 fio 資料的秒不得被遮成 gap"
grep -q "sampler" "$CB2/coverage-proof.json" || fail "taint 理由未指名 sampler"
ok

# 21) fio client heartbeat 死 40s 且該區間沒有逐秒樣本 → 記成 gap（工具中斷，不是 stall）
CB3="$tmp/cov-fio-dead"
rm -rf "$CB3"; mkdir -p "$CB3/coverage" "$CB3/sampler"
python3 "$here/fixtures/gen-samples.py" --out "$CB3/sampler/samples.jsonl" \
  --start 1785000000 --count 60 --interval 5 >/dev/null
omit="$(python3 -c 'print(",".join(str(s) for s in range(100, 140)))')"
python3 "$here/fixtures/gen-fio-logs.py" --out "$CB3/fio/mclock-client-1" \
  --seg seg01 --start 1785000000 --seconds 300 --omit-secs "$omit" >/dev/null
mk_checks "$CB3" 1785000000 1785000300 30 1785000100 1785000140 fio:mclock-client-1
out="$(coverage_finalize "$CB3" 1785000000 1785000299)" \
  && fail "fio 工具中斷 40s 應標 taint"
eq "$(jget "$CB3/coverage-proof.json" tainted)" "True" "fio 工具長中斷 → taint"
[ "$(jget "$CB3/coverage-proof.json" gap_seconds)" -ge 30 ] \
  || fail "工具中斷且無樣本的秒必須進 gaps（否則會被誤判成 client 黑掉）"
ok
eq "$(jget "$CB3/coverage-proof.json" gaps.0.source)" "fio:mclock-client-1" "gap 要標來源"
eq "$(jget "$CB3/coverage-proof.json" gaps.0.tolerated)" "False" "≥10s 的 gap 不得標 tolerated"

# 22) 單點 <10s 的小缺口 → 記錄但容忍、不 taint
CB4="$tmp/cov-small-gap"
rm -rf "$CB4"; mkdir -p "$CB4/coverage" "$CB4/sampler"
python3 "$here/fixtures/gen-samples.py" --out "$CB4/sampler/samples.jsonl" \
  --start 1785000000 --count 60 --interval 5 >/dev/null
python3 "$here/fixtures/gen-fio-logs.py" --out "$CB4/fio/mclock-client-1" \
  --seg seg01 --start 1785000000 --seconds 300 --omit-secs "100,101,102,103,104" >/dev/null
# cadence 5：缺口只有 5s，30s cadence 的 supervisor 根本掃不到它
mk_checks "$CB4" 1785000000 1785000300 5 1785000100 1785000104 fio:mclock-client-1
out="$(coverage_finalize "$CB4" 1785000000 1785000299)" || fail "<10s 缺口不該 taint"
eq "$(jget "$CB4/coverage-proof.json" tainted)" "False" "單點小缺口容忍"
eq "$(jget "$CB4/coverage-proof.json" gaps.0.tolerated)" "True" "小缺口標 tolerated"

# 23) supervisor 自己失聯（checks 稀疏）→ 該區間也算證據不足
CB5="$tmp/cov-blind"
mk_cov_bundle "$CB5" 1785000000 300
mk_checks "$CB5" 1785000000 1785000300 150
out="$(coverage_finalize "$CB5" 1785000000 1785000299)" \
  && fail "supervisor 失聯應標 taint"
grep -q "supervisor" "$CB5/coverage-proof.json" || fail "未記錄 supervisor 失聯證據"
ok

# 24) 未給窗 → 由 fault-timeline.json 推導（pipeline 的預設路徑）
CB6="$tmp/cov-derive"
mk_cov_bundle "$CB6" 1785000000 300
mk_checks "$CB6" 1785000000 1785000300 30
python3 - "$CB6/fault-timeline.json" <<'PY'
import json, sys
json.dump({"fault_t0": 1785000060, "down_epoch_t": 1785000065,
           "recovery_complete_t": 1785000260, "measurement_deadline": 1785002760,
           "measurement_cap": 2700, "heal_t0": 1785000270,
           "final_clean_t": 1785000290}, open(sys.argv[1], "w"))
PY
coverage_finalize "$CB6" >/dev/null || true
eq "$(jget "$CB6/coverage-proof.json" window.start)" "1785000000" \
  "推導窗要涵蓋注入前健康基線（fault_t0-60）"
eq "$(jget "$CB6/coverage-proof.json" window.end)" "1785000260" "推導窗以 recovery_complete 收尾"

# 25) 與 verdict.py 的契約：gap 的秒不算 stall；沒有 gap 證據的同樣缺樣本 = stall
mk_agg_bundle() { # <src-cov-bundle> <dst>
  local src="$1" dst="$2"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -R "$src/fio" "$dst/fio"
  cp "$src/coverage-proof.json" "$dst/coverage-proof.json"
  python3 - "$dst/prediction.json" <<'PY'
import json, sys
json.dump({"cell_id": "c07", "group_id": "g01", "profile": "balanced",
           "shape": "4k-randrw", "pressure": "mid", "manifest_hash": "deadbeef",
           "expectations": {}}, open(sys.argv[1], "w"))
PY
}
mk_agg_bundle "$CB3" "$tmp/agg-gap"
python3 "$root/lib/verdict.py" aggregate "$tmp/agg-gap" > "$tmp/agg-gap.out" 2>/dev/null \
  || fail "aggregate（gap 版）應成功"
eq "$(jget "$tmp/agg-gap/aggregate.json" endpoints.max_stall_seconds)" "0" \
  "被 coverage-proof 標成 gap 的秒不得算成 stall"
[ "$(jget "$tmp/agg-gap/aggregate.json" coverage.gap_seconds)" -ge 30 ] \
  || fail "aggregate 未吃到 coverage-proof 的 gap"
ok
# 同一份 fio log，但 coverage 說工具全程健康 → 同樣的空秒就是 client 真的黑掉
mk_agg_bundle "$CB3" "$tmp/agg-stall"
python3 - "$tmp/agg-stall/coverage-proof.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["gaps"] = []
doc["tainted"] = False
json.dump(doc, open(sys.argv[1], "w"))
PY
python3 "$root/lib/verdict.py" aggregate "$tmp/agg-stall" >/dev/null 2>&1 \
  || fail "aggregate（stall 版）應成功"
[ "$(jget "$tmp/agg-stall/aggregate.json" endpoints.max_stall_seconds)" -ge 30 ] \
  || fail "沒有 gap 證據時，空秒必須算成 stall"
ok

# ==================================================== return-backfill（H-008）==
# 26) 回歸期間兩時戳 + 該區間 recovery bytes/s（唯一 lim binding 的場景）
RB="$tmp/rb"; rm -rf "$RB"; mkdir -p "$RB/sampler"
python3 "$here/fixtures/gen-samples.py" --out "$tmp/rb-samples.jsonl" \
  --start 1785000000 --count 121 --interval 5 --rate-bytes 100000000 >/dev/null
mkdir -p "$RB/sampler"
cp "$tmp/rb-samples.jsonl" "$RB/sampler/samples.jsonl"
python3 - "$RB/sampler/run.json" <<'PY'
import json, sys
json.dump({"run_id": "sampler-x", "node": "mclock-admin",
           "data_dir": "/var/tmp/mclock/sampler/sampler-x"}, open(sys.argv[1], "w"))
PY
reset_ssh
tar -C "$RB/sampler" -cf "$tmp/sampler.tar" samples.jsonl
expect_ssh "tar -C /var/tmp/mclock/sampler/sampler-x" 0 0 "$tmp/sampler.tar"
out="$(collect_return_backfill "$RB" 1785000100 1785000300)" \
  || fail "collect_return_backfill 應成功"
eq "$out" "return-backfill: OK 200 100000000.0" "return-backfill 機器行"
eq "$(jget "$RB/return-backfill.json" heal_t0)" "1785000100" "return-backfill 記回歸起點"
eq "$(jget "$RB/return-backfill.json" final_clean_t)" "1785000300" "return-backfill 記 final_clean"
eq "$(jget "$RB/return-backfill.json" duration_s)" "200" "return-backfill 區間長度"
eq "$(jget "$RB/return-backfill.json" recovery_bytes_per_sec)" "100000000.0" \
  "return-backfill 速率 = 該區間累計差分 / 時間"
eq "$(jget "$RB/return-backfill.json" qos_class)" "background_best_effort" \
  "回歸 backfill 屬 best_effort class（H-008）"

# =========================================================== collect_cell =====
CC="$RESULTS_DIR/c07/r1/attempts/20260725T031000Z"
mk_marker
python3 "$here/fixtures/gen-samples.py" --out "$tmp/cc-samples.jsonl" \
  --start 1785000000 --count 121 --interval 5 --rate-bytes 200000000 \
  --clean-at 400 >/dev/null
python3 - "$CC/fault-timeline.json" <<'PY'
import json, sys
json.dump({"fault_t0": 1785000060, "down_epoch_t": 1785000065,
           "recovery_complete_t": 1785000500, "measurement_deadline": 1785002760,
           "measurement_cap": 2700, "heal_t0": 1785000520,
           "final_clean_t": 1785000560}, open(sys.argv[1], "w"))
PY
mkdir -p "$tmp/fiotar/seg"
python3 "$here/fixtures/gen-fio-logs.py" --out "$tmp/fiotar" --seg seg01 \
  --start 1785000000 --seconds 60 >/dev/null
python3 - "$tmp/fiotar/seg01.json" <<'PY'
import json, sys
json.dump({"fio version": "fio-3.36", "jobs": [
    {"jobname": "seg01", "error": 0,
     "read": {"iops": 900.0, "bw_bytes": 3686400,
              "clat_ns": {"percentile": {"99.000000": 1200000}}},
     "write": {"iops": 400.0, "bw_bytes": 1638400,
               "clat_ns": {"percentile": {"99.000000": 2400000}}}}]},
          open(sys.argv[1], "w"))
PY
printf '0\n' > "$tmp/fiotar/fio-run.exit"
tar -C "$tmp/fiotar" -cf "$tmp/fio.tar" .
mkdir -p "$tmp/samplertar"
cp "$tmp/cc-samples.jsonl" "$tmp/samplertar/samples.jsonl"
cp "$fx/pg-dump-recovering.json" "$tmp/samplertar/pgdump-first.json"
cp "$fx/pg-dump-clean.json" "$tmp/samplertar/pgdump-last.json"
tar -C "$tmp/samplertar" -cf "$tmp/sampler2.tar" .
printf '{"status":"success","data":{"resultType":"matrix","result":[{"metric":{},"values":[[1785000000,"1"]]}]}}\n' \
  > "$tmp/prom.json"

reset_ssh
export COLLECT_PROM_QUERIES="health_status=ceph_health_status
pg_degraded=ceph_pg_degraded"
for c in 1 2 3 4; do
  expect_ssh "tar -C /var/tmp/mclock/fio/${KEY}/mclock-client-${c}" 0 0 "$tmp/fio.tar"
done
expect_ssh "tar -C /var/tmp/mclock/sampler/${SAMPLER_ID}" 0 0 "$tmp/sampler2.tar"
for i in 0 1 2 3 4 5 6 7; do
  expect_ssh "ceph tell osd.${i} config show" 0 0 "$fxc/config-show-balanced.json"
done
expect_ssh "ceph df --format json" 0 0 "$fxc/ceph-s-clean.json"
expect_ssh "query_range" 0 0 "$tmp/prom.json"
expect_ssh "query_range" 0 0 "$tmp/prom.json"
out="$(collect_cell "$CC" fault)" || fail "collect_cell 應成功"
case "$out" in
  "collect-cell: PASS ${CC} missing="*) ok ;;
  *) fail "collect_cell 機器行格式（got=[$out]）" ;;
esac
# 產出物：fio 回收、sampler 截斷歸檔 + summary、逐 OSD config show、ceph df、prometheus
[ -s "$CC/fio/mclock-client-1/seg01_iops.1.log" ] || fail "fio 逐秒 log 未回收"
ok
[ -s "$CC/fio-summary.json" ] || fail "未產生 fio-summary.json"
ok
eq "$(jget "$CC/fio-summary.json" clients_n)" "4" "fio-summary 記錄四個 client"
eq "$(jget "$CC/fio-summary.json" nonzero_exits)" "0" "fio exit proof 全 0"
[ -s "$CC/sampler/samples.jsonl" ] || fail "sampler 原始樣本未回收"
ok
[ -s "$CC/sampler/samples.window.jsonl" ] || fail "sampler 樣本未依量測窗截斷歸檔"
ok
[ -s "$CC/sampler-summary.json" ] || fail "未產生 sampler-summary.json"
ok
eq "$(jget "$CC/sampler-summary.json" recovery_bytes_per_sec_median)" "200000000.0" \
  "sampler-summary 的 recovery bytes/s（verdict.py aggregate 的必要欄位）"
[ "$(jget "$CC/sampler-summary.json" peering_seconds)" -ge 0 ] || fail "缺 peering 區間統計"
ok
[ -s "$CC/config-show/osd.7.json" ] || fail "逐 OSD config show 快照缺件"
ok
[ -s "$CC/ceph-df.json" ] || fail "缺 ceph df"
ok
[ -s "$CC/prometheus/health_status.json" ] || fail "缺 prometheus 時窗 export"
ok
eq "$(jget "$CC/prometheus/index.json" window.start)" "1785000000" \
  "prometheus export 用量測窗（含前後 padding）的起點"
has "$FAKE_SSH_LOG" "api/v1/query_range" "prometheus 走 query_range"

# 27) 產出物清單對齊 verdict.py schemas：缺件數要如實回報，不得謊報 PASS
missing="${out##*missing=}"
[ "$missing" -gt 0 ] || fail "本 bundle 尚缺 prediction/verdict 等檔，missing 應 > 0"
ok
python3 "$root/lib/verdict.py" schemas fault > "$tmp/req.txt"
grep -qx "sampler-summary.json" "$tmp/req.txt" || fail "schema 應要求 sampler-summary.json"
ok

# 28) prometheus 失敗不致命（不在 required schema 內），其餘產出仍完成
reset_ssh
CC2="$RESULTS_DIR/c08/r1/attempts/20260725T040000Z"; mkdir -p "$CC2"
cp "$CC/fault-timeline.json" "$CC2/fault-timeline.json"
cp -R "$BUNDLE/sampler" "$CC2/sampler"
for c in 1 2 3 4; do
  expect_ssh "tar -C /var/tmp/mclock/fio/" 0 0 "$tmp/fio.tar"
done
expect_ssh "tar -C /var/tmp/mclock/sampler/" 0 0 "$tmp/sampler2.tar"
for i in 0 1 2 3 4 5 6 7; do
  expect_ssh "config show" 0 0 "$fxc/config-show-balanced.json"
done
expect_ssh "ceph df --format json" 0 0 "$fxc/ceph-s-clean.json"
expect_ssh "query_range" 7 0 ""
expect_ssh "query_range" 7 0 ""
out="$(collect_cell "$CC2" fault)" || fail "prometheus 失敗不該讓 collect_cell 失敗"
ok
[ -s "$CC2/sampler-summary.json" ] || fail "prometheus 失敗後其餘產出仍要完成"
ok

# 28c) fio 輸出來源：run.tsv 有 workdir 就用它；已經收回 bundle 的 client 不再重拉
reset_ssh
FB="$RESULTS_DIR/c09/r1/attempts/20260725T050000Z"
mkdir -p "$FB/fio/mclock-client-1"
printf '1785000000, 100, 0, 4096, 0\n' > "$FB/fio/mclock-client-1/seg01_iops.1.log"
for c in 2 3 4; do
  printf 'mclock-client-%s\tfio-segment-mclock-client-%s\t/var/tmp/mclock-fio/wd-%s\n' \
    "$c" "$c" "$c" >> "$FB/fio/run.tsv"
done
for c in 2 3 4; do
  expect_ssh "tar -C /var/tmp/mclock-fio/wd-${c}" 0 0 "$tmp/fio.tar"
done
_collect_fetch_fio "$FB"
eq "$(ssh_calls)" "3" "已回收的 client 不得重拉，其餘走 run.tsv 的 workdir"
[ -s "$FB/fio/mclock-client-2/seg01.json" ] || fail "run.tsv 路徑的 fio 輸出未回收"
ok

# 28b) 含空白的 promQL 會被遠端指令列截斷 → 當場死，不得靜默送出半截查詢
reset_ssh
if (COLLECT_PROM_QUERIES="bad=rate(x[5m]) by (osd)" \
     _collect_prometheus "$tmp/promguard" 1 2) >/dev/null 2>&1; then
  fail "含空白的 prometheus query 應 die"
fi
ok

# ======================================================== env snapshot ×3 =====
mk_prov_blob() {
  cat > "$tmp/prov.txt" <<'BLOB'
##kernel
6.8.0-45-generic
##osrelease
NAME="Ubuntu"
VERSION_ID="22.04"
ID=ubuntu
##packages
fio	3.36-1build1
fping	5.1-1
sysstat	12.5.2-2ubuntu0.2
python3	3.10.6-1~22.04
ceph-common	19.2.2-1jammy
##fio
fio-3.36
##nproc
4
##meminfo
MemTotal:       16341234 kB
##bootid
7f9d0c2e-1111-2222-3333-444455556666
##uptime
12345.67 98765.43
##timesync
yes
##end
BLOB
}
mk_prov_blob
# 29) provision 段：15 台、含 fio 版本（parser 校正的前提）與 kernel/套件
reset_ssh
n=0
while [ "$n" -lt 15 ]; do expect_ssh "dpkg-query -W" 0 0 "$tmp/prov.txt"; n=$((n + 1)); done
out="$(env_snapshot_provision)" || fail "env_snapshot_provision 應成功"
eq "$out" "env-snapshot: PASS provision 15" "env_snapshot_provision 機器行"
eq "$(jget "$RESULTS_DIR/env/env-provision.json" nodes.mclock-osd-1.fio_version)" "fio-3.36" \
  "provision snapshot 必須記 fio 版本"
eq "$(jget "$RESULTS_DIR/env/env-provision.json" nodes.mclock-osd-1.kernel)" "6.8.0-45-generic" \
  "provision snapshot 記 kernel"
eq "$(jget "$RESULTS_DIR/env/env-provision.json" nodes.mclock-client-4.packages.fping)" "5.1-1" \
  "provision snapshot 記套件版本"
has "$FAKE_SSH_LOG" "fio --version" "provision 段有查 fio 版本"

# 30) provision 段的前置：任一台收不到 → die（不得留半套 snapshot）
reset_ssh
rm -f "$RESULTS_DIR/env/env-provision.json"
expect_ssh "dpkg-query -W" 0 0 "$tmp/prov.txt"
expect_ssh "dpkg-query -W" 255 0 ""
if (env_snapshot_provision) >/dev/null 2>&1; then
  fail "有 node 收不到時 env_snapshot_provision 應失敗"
fi
ok
[ -e "$RESULTS_DIR/env/env-provision.json" ] && fail "失敗時不得留下半套 snapshot"
ok

# 31) cluster 段：前置（cluster 已部署）不成立就 die
reset_ssh
expect_ssh "ceph -s --format json" 1 0 ""
if (env_snapshot_cluster) >/dev/null 2>&1; then
  fail "cluster 未就緒時 env_snapshot_cluster 應 die"
fi
ok

reset_ssh
expect_ssh "ceph -s --format json" 0 0 "$fxc/ceph-s-clean.json"
expect_ssh "ceph versions" 0 0 "$fxc/versions-ok.json"
expect_ssh "ceph osd crush tree" 0 0 "$fxc/crush-tree.json"
expect_ssh "ceph osd pool ls detail" 0 0 "$fxc/pool-get-size.json"
expect_ssh "ceph osd dump" 0 0 "$fxc/osd-dump-8up.json"
expect_ssh "ceph config dump" 0 0 "$fxc/config-dump-clean.json"
out="$(env_snapshot_cluster)" || fail "env_snapshot_cluster 應成功"
eq "$out" "env-snapshot: PASS cluster" "env_snapshot_cluster 機器行"
eq "$(jget "$RESULTS_DIR/env/env-cluster.json" osdmap.flags)" "noscrub,nodeep-scrub" \
  "cluster snapshot 記 OSDMap flags"
[ -n "$(jget "$RESULTS_DIR/env/env-cluster.json" crush_tree)" ] || fail "cluster snapshot 缺 crush tree"
ok

# 32) map 段：前置（image 已 map）不成立就 die
printf '##showmapped\n[]\n##devices\n##end\n' > "$tmp/map-empty.txt"
reset_ssh
expect_ssh "rbd showmapped" 0 0 "$tmp/map-empty.txt"
if (env_snapshot_map) >/dev/null 2>&1; then
  fail "尚未 map 時 env_snapshot_map 應 die"
fi
ok

cat > "$tmp/map.txt" <<'BLOB'
##showmapped
[{"id":"0","pool":"mclock","namespace":"","name":"fio-c1","snap":"-","device":"/dev/rbd0"}]
##devices
#dev rbd0
[none] mq-deadline
128
1024
0
##end
BLOB
reset_ssh
for c in 1 2 3 4; do expect_ssh "rbd showmapped" 0 0 "$tmp/map.txt"; done
out="$(env_snapshot_map)" || fail "env_snapshot_map 應成功"
eq "$out" "env-snapshot: PASS map 4" "env_snapshot_map 機器行"
eq "$(jget "$RESULTS_DIR/env/env-map.json" nodes.mclock-client-1.mapped.0.name)" "fio-c1" \
  "map snapshot 記 rbdX 對應"
eq "$(jget "$RESULTS_DIR/env/env-map.json" nodes.mclock-client-1.devices.rbd0.scheduler)" \
  "[none] mq-deadline" "map snapshot 記 client scheduler"
eq "$(jget "$RESULTS_DIR/env/env-map.json" nodes.mclock-client-1.devices.rbd0.read_ahead_kb)" \
  "128" "map snapshot 記 readahead"

# ============================================================== 家規檢查 ======
# 33) 遠端指令一律有界（不得出現裸 ssh 無 timeout 的長指令）；bash 3.2 禁用語法
hasnt "$root/lib/collect.sh" "mapfile" "bash 3.2：不得用 mapfile"
hasnt "$root/lib/collect.sh" "declare -A" "bash 3.2：不得用 declare -A"

printf 'test-collect: %d asserts passed\n' "$asserts"
