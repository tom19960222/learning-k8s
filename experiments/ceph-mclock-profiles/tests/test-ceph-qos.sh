#!/usr/bin/env bash
# Task 6 — lib/ceph.sh 的 QoS gate、capacity 決策表、no-rebench 證據、兩層 clean 判準
# 與各項健康/狀態 helper。
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
fx="$here/fixtures/ceph"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-ceph-qos.XXXXXX")"

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
export POLL_INTERVAL=0.05
export CEPH_FSID="3f2b1c8e-7a41-4c9d-9b0e-2d5a6f7c8b90"
export CEPH_OSD_IDS="0 1 2 3 4 5 6 7"
export QOS_SETTLE_SECS=0
export QOS_CONVERGE_SECS=0
export RAW_NVME_BASELINE_JSON="$fx/raw-nvme-baseline.json"

reset_ssh() { : > "$FAKE_SSH_SCRIPT"; : > "$FAKE_SSH_LOG"; rm -rf "$FAKE_SSH_STATE"; }
expect_ssh() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$FAKE_SSH_SCRIPT"; }

# shellcheck source=../lib/ceph.sh
. "$root/lib/ceph.sh"
inventory_load "$fixture"
cleanup_push "rm -rf '$tmp'"
mkdir -p "$RESULTS_DIR"

# ============================================================ 不得用 HEALTH_OK ==
# 1) clean 判準只能用 spec §5 的兩層定義；字面 HEALTH_OK 在 campaign（掛著 noscrub）
#    永遠不會出現，寫進判準就是永久 timeout。
hasnt "$root/lib/ceph.sh" "HEALTH_OK" "clean 判準不得用字面 HEALTH_OK"

# ================================================================ ceph_qos_gate ==
mk_lock() { # <value> [outfile]
  python3 - "$1" "${2:-$RESULTS_DIR/capacity-lock.json}" <<'PY'
import json, sys
val = float(sys.argv[1])
doc = {"schema_version": 1, "generated_at": "2026-07-25T00:00:00Z", "cov": 0.01,
       "osds": [{"osd": i, "host": "mclock-osd-%d" % (i + 1), "bench_iops": val,
                 "bench_status": "accepted", "raw_fio_iops": 48000.0,
                 "decision": "accepted-consistent", "locked_value": val,
                 "locked_source": "bench", "offset_from_default": False}
                for i in range(8)]}
with open(sys.argv[2], "w") as fh:
    json.dump(doc, fh, indent=1)
PY
}
qos_expect_pass() { # <config-show fixture> <config-dump fixture>
  local i
  for i in 0 1 2 3 4 5 6 7; do
    expect_ssh "tell osd.${i} config show" 0 0 "$1"
  done
  expect_ssh 'config dump' 0 0 "$2"
}

mk_lock 45000
# 2) 完整驗證集合通過 → 機器行 + 結構化 JSON 入 bundle
reset_ssh
bundle="$tmp/bundle-1"; mkdir -p "$bundle"
qos_expect_pass "$fx/config-show-balanced.json" "$fx/config-dump-clean.json"
qos_expect_pass "$fx/config-show-balanced.json" "$fx/config-dump-clean.json"
out="$(ceph_qos_gate balanced "$bundle")" || fail "ceph_qos_gate 應通過"
ok
eq "$out" "qos-gate: PASS balanced" "qos gate 機器行"
[ -s "$bundle/qos.json" ] || fail "qos.json 未寫入 bundle"
ok
eq "$(jget "$bundle/qos.json" verdict)" "pass" "qos.json verdict"
eq "$(jget "$bundle/qos.json" profile)" "balanced" "qos.json 記錄 profile"
eq "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["osds"]))' "$bundle/qos.json")" \
  "8" "qos.json 記錄八顆 OSD"
# 驗證集合必須逐項留證（含 round2 blocker 2 的 osd_op_queue 與 skip_benchmark）
for k in osd_op_queue osd_mclock_profile osd_mclock_max_capacity_iops_ssd \
         osd_mclock_max_sequential_bandwidth_ssd osd_max_backfills \
         osd_recovery_max_active_ssd osd_mclock_override_recovery_settings \
         osd_mclock_skip_benchmark osd_mclock_scheduler_client_res \
         osd_mclock_scheduler_client_wgt osd_mclock_scheduler_client_lim \
         osd_mclock_scheduler_background_recovery_res \
         osd_mclock_scheduler_background_recovery_wgt \
         osd_mclock_scheduler_background_recovery_lim \
         osd_mclock_scheduler_background_best_effort_res \
         osd_mclock_scheduler_background_best_effort_wgt \
         osd_mclock_scheduler_background_best_effort_lim; do
  has "$bundle/qos.json" "$k" "qos.json 驗證集合缺 ${k}"
done
# settle window 是 gate 的一部分：收斂後要再驗一次
eq "$(count_of "$FAKE_SSH_LOG" 'config show')" "16" "收斂 + settle 後各驗一輪"
# 生效驗證只能逐 OSD 讀 effective config（H-018），不得只看 config dump
has "$FAKE_SSH_LOG" "tell osd.5 config show" "逐 OSD 讀 effective config"

# 3) profile 對照：high_client_ops 的九參數
reset_ssh
bundle2="$tmp/bundle-2"; mkdir -p "$bundle2"
qos_expect_pass "$fx/config-show-hco.json" "$fx/config-dump-clean.json"
qos_expect_pass "$fx/config-show-hco.json" "$fx/config-dump-clean.json"
ceph_qos_gate high_client_ops "$bundle2" >/dev/null || fail "high_client_ops gate 應通過"
ok
# 用 balanced 的期望值去驗 high_client_ops 的實際值 → 必須 fail
reset_ssh
qos_expect_pass "$fx/config-show-hco.json" "$fx/config-dump-clean.json"
( ceph_qos_gate balanced "$tmp/bundle-3" ) >/dev/null 2>&1 \
  && fail "profile 不符應 die"
ok

# 4) 逐項 blocker：任一不符就不得放行
qos_reject() { # <desc> <config-show fixture> <config-dump fixture> [profile]
  local desc="$1" cs="$2" cd="$3" prof="${4:-balanced}" b
  b="$tmp/bundle-rej-$asserts"; mkdir -p "$b"
  reset_ssh
  qos_expect_pass "$cs" "$cd"
  ( ceph_qos_gate "$prof" "$b" ) >/dev/null 2>&1 && fail "${desc} 應 die"
  ok
  [ -s "$b/qos.json" ] || fail "${desc}：失敗也必須留下 qos.json 證據"
  ok
  eq "$(jget "$b/qos.json" verdict)" "fail" "${desc}：qos.json verdict=fail"
}
qos_reject "osd_op_queue 非 mclock_scheduler" "$fx/config-show-wpq.json" "$fx/config-dump-clean.json"
qos_reject "osd_max_backfills 被外部改成 3" "$fx/config-show-backfills3.json" "$fx/config-dump-clean.json"
qos_reject "osd_recovery_max_active_ssd 非 10" "$fx/config-show-recovery-active-3.json" "$fx/config-dump-clean.json"
qos_reject "skip_benchmark 非 true" "$fx/config-show-skipfalse.json" "$fx/config-dump-clean.json"
qos_reject "override_recovery_settings 非 false" "$fx/config-show-override-true.json" "$fx/config-dump-clean.json"
qos_reject "seq bandwidth 非 1200MiB/s" "$fx/config-show-seqbw-wrong.json" "$fx/config-dump-clean.json"
qos_reject "capacity 與 lock 檔不符" "$fx/config-show-capwrong.json" "$fx/config-dump-clean.json"
qos_reject "九參數被動過" "$fx/config-show-badres.json" "$fx/config-dump-clean.json"
# H-009：值對但來源錯（mon store 有 override）一樣不得放行
qos_reject "mon store 有 osd_max_backfills override" "$fx/config-show-balanced.json" "$fx/config-dump-polluted.json"
# H-018：九個 key 不該出現在 mon store
qos_reject "mon store 出現九參數之一" "$fx/config-show-balanced.json" "$fx/config-dump-polluted-nine.json"

# 5) H-012：capacity 恰等於 compiled default 21500 → 不得放行（重啟會重跑 bench）
mk_lock 21500
reset_ssh
qos_expect_pass "$fx/config-show-capdefault.json" "$fx/config-dump-clean.json"
( ceph_qos_gate balanced "$tmp/bundle-def" ) >/dev/null 2>&1 \
  && fail "capacity == 21500 應 die（H-012）"
ok
mk_lock 45000

# 6) 八顆必須「同時」收斂：只有 osd.7 落後 → 第一輪不算過
reset_ssh
bundle4="$tmp/bundle-4"; mkdir -p "$bundle4"
for i in 0 1 2 3 4 5 6; do expect_ssh "tell osd.${i} config show" 0 0 "$fx/config-show-balanced.json"; done
expect_ssh 'tell osd.7 config show' 0 0 "$fx/config-show-hco.json"
expect_ssh 'config dump' 0 0 "$fx/config-dump-clean.json"
qos_expect_pass "$fx/config-show-balanced.json" "$fx/config-dump-clean.json"
qos_expect_pass "$fx/config-show-balanced.json" "$fx/config-dump-clean.json"
QOS_CONVERGE_SECS=30 ceph_qos_gate balanced "$bundle4" >/dev/null \
  || fail "落後的 OSD 收斂後應通過"
ok
eq "$(count_of "$FAKE_SSH_LOG" 'config show')" "24" "未收斂就重驗整組（8×3）"

# ============================================================== ceph_set_profile ==
# Task 0.1：qos gate 只**驗證** profile，必須另有地方真的**設定**它，否則第一個非
# balanced 的 cell 會在 preflight 卡到收斂逾時。
prof_file() { # <profile> → 檔案路徑（模擬 `ceph config get` 的輸出）
  printf '%s\n' "$1" > "$tmp/prof-$1.txt"
  printf '%s\n' "$tmp/prof-$1.txt"
}
P_BAL="$(prof_file balanced)"
P_HCO="$(prof_file high_client_ops)"

# 6a) 三個合法 profile 之外一律 die，且**不得**對叢集下任何指令
reset_ssh
( ceph_set_profile mclock_scheduler ) >/dev/null 2>&1 && fail "非法 profile 應 die"
ok
( ceph_set_profile "" ) >/dev/null 2>&1 && fail "空 profile 應 die"
ok
( ceph_set_profile ) >/dev/null 2>&1 && fail "缺參數應 die"
ok
eq "$(cat "$FAKE_SSH_STATE/count" 2>/dev/null || echo 0)" "0" "非法 profile 不得下任何遠端指令"

# 6b) 已經是目標 profile → 冪等，不得重下 config set
reset_ssh
expect_ssh 'config get osd osd_mclock_profile' 0 0 "$P_BAL"
out="$(ceph_set_profile balanced)" || fail "ceph_set_profile balanced 應成功"
ok
eq "$out" "set-profile: NOOP balanced" "冪等時的機器行"
hasnt "$FAKE_SSH_LOG" "config set osd osd_mclock_profile" "已是目標 profile 不得重下指令"

# 6c) 切換：argv 逐字斷言（section 一律 osd，不是 global／osd.N）
reset_ssh
expect_ssh 'config get osd osd_mclock_profile' 0 0 "$P_BAL"
expect_ssh 'config set osd osd_mclock_profile high_client_ops' 0 0 ""
out="$(ceph_set_profile high_client_ops)" || fail "切換到 high_client_ops 應成功"
ok
eq "$out" "set-profile: SET balanced high_client_ops" "切換的機器行（含前一個 profile 留痕）"
has "$FAKE_SSH_LOG" "sudo ceph config set osd osd_mclock_profile high_client_ops" "argv 逐字"
eq "$(count_of "$FAKE_SSH_LOG" 'config set osd osd_mclock_profile')" "1" "切換只下一次指令"
eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "stdout 只有一行機器行"

# 6d) 第三個合法 profile 也要能設
reset_ssh
expect_ssh 'config get osd osd_mclock_profile' 0 0 "$P_HCO"
expect_ssh 'config set osd osd_mclock_profile high_recovery_ops' 0 0 ""
out="$(ceph_set_profile high_recovery_ops)" || fail "切換到 high_recovery_ops 應成功"
ok
eq "$out" "set-profile: SET high_client_ops high_recovery_ops" "high_recovery_ops 機器行"

# 6e) 查不到當下 profile → die（不得盲設）
reset_ssh
expect_ssh 'config get osd osd_mclock_profile' 1 0 ""
( ceph_set_profile high_client_ops ) >/dev/null 2>&1 && fail "查當下 profile 失敗應 die"
ok
hasnt "$FAKE_SSH_LOG" "config set osd osd_mclock_profile" "查詢失敗後不得續下 set"

# 6f) 設定指令失敗 → die（不得靜默續行讓 gate 去撞逾時）
reset_ssh
expect_ssh 'config get osd osd_mclock_profile' 0 0 "$P_BAL"
expect_ssh 'config set osd osd_mclock_profile high_client_ops' 1 0 ""
( ceph_set_profile high_client_ops ) >/dev/null 2>&1 && fail "config set 失敗應 die"
ok

# 6g) H-018：osd_mclock_profile **不在** FORBIDDEN_IN_MON_STORE（九個衍生參數才是
#     set_val_default）——所以「設 profile」與 qos gate 的來源反向斷言不衝突。
has "$fx/config-dump-clean.json" '"name": "osd_mclock_profile"' \
  "乾淨的 config dump 本來就帶 osd_mclock_profile（mon store 有它是正常的）"
reset_ssh
bundle_sp="$tmp/bundle-setprof"; mkdir -p "$bundle_sp"
qos_expect_pass "$fx/config-show-balanced.json" "$fx/config-dump-clean.json"
qos_expect_pass "$fx/config-show-balanced.json" "$fx/config-dump-clean.json"
ceph_qos_gate balanced "$bundle_sp" >/dev/null \
  || fail "mon store 有 osd_mclock_profile 不得讓 qos gate 擋下"
ok

# ====================================================== ceph_capacity_provenance ==
prov_expect() { # <journal fixture for all 8> <cluster-log fixture> <config-show fixture>
  local i
  expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
  expect_ssh 'config dump' 0 0 "$fx/config-dump-bench.json"
  expect_ssh 'log last' 0 0 "$2"
  for i in 0 1 2 3 4 5 6 7; do
    expect_ssh "@osd.${i}.service" 0 0 "$1"
    expect_ssh "tell osd.${i} config show" 0 0 "$3"
  done
}
# 7) bench 有跑、值被採用 → accepted；provenance 帶 host / bench_iops / raw fio
reset_ssh
prov_expect "$fx/journal-boot-bench.txt" "$fx/cluster-log-clean.txt" "$fx/config-show-prelock.json"
ceph_capacity_provenance "$tmp/prov-1.json" >/dev/null || fail "ceph_capacity_provenance 應成功"
ok
eq "$(jget "$tmp/prov-1.json" osds.0.bench_status)" "accepted" "bench 被採用"
eq "$(jget "$tmp/prov-1.json" osds.0.host)" "mclock-osd-1" "osd → host 對應"
eq "$(jget "$tmp/prov-1.json" osds.3.raw_fio_iops)" "48200.0" "帶入 raw NVMe fio 基線"
eq "$(python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["osds"][0]["bench_iops"]))' "$tmp/prov-1.json")" \
  "45282" "從 log 解析 bench iops"
# journal 一律 unit-scoped（裸 journalctl -b 撈不到 container 內的 OSD log）
has "$FAKE_SSH_LOG" "ceph-${CEPH_FSID}@osd.0.service" "journal 以 fsid-scoped unit 取用"

# 8) cluster log 有 threshold 警告 → 該顆是 rejected-out-of-range
reset_ssh
prov_expect "$fx/journal-boot-bench.txt" "$fx/cluster-log-rejected.txt" "$fx/config-show-prelock.json"
ceph_capacity_provenance "$tmp/prov-2.json" >/dev/null || fail "provenance（rejected）應成功"
ok
eq "$(jget "$tmp/prov-2.json" osds.2.bench_status)" "rejected-out-of-range" "osd.2 被判超出範圍"
eq "$(jget "$tmp/prov-2.json" osds.1.bench_status)" "accepted" "其餘 OSD 不受影響"

# 9) 值原本就非預設 → bench 跳過（有正向 log）
reset_ssh
prov_expect "$fx/journal-boot-skipmsg.txt" "$fx/cluster-log-clean.txt" "$fx/config-show-prelock-stored.json"
ceph_capacity_provenance "$tmp/prov-3.json" >/dev/null || fail "provenance（skip）應成功"
ok
eq "$(jget "$tmp/prov-3.json" osds.0.bench_status)" "skipped-existing-nondefault" "skip 分支"
eq "$(python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["osds"][0]["effective_iops"]))' "$tmp/prov-3.json")" \
  "33000" "skip 分支要記下目前生效值"

# 10) bench 執行錯誤 / 完全沒證據
reset_ssh
prov_expect "$fx/journal-boot-bencherr.txt" "$fx/cluster-log-clean.txt" "$fx/config-show-prelock.json"
ceph_capacity_provenance "$tmp/prov-4.json" >/dev/null || fail "provenance（err）應成功"
ok
eq "$(jget "$tmp/prov-4.json" osds.0.bench_status)" "failed" "bench err 分支"
reset_ssh
prov_expect "$fx/journal-boot-nomarker.txt" "$fx/cluster-log-clean.txt" "$fx/config-show-prelock.json"
ceph_capacity_provenance "$tmp/prov-5.json" >/dev/null || fail "provenance（no-result）應成功"
ok
eq "$(jget "$tmp/prov-5.json" osds.0.bench_status)" "no-result" "無任何 bench 證據"

# ========================================================== ceph_capacity_decide ==
mk_prov() { # <outfile> <status> <bench-iops-list...>；raw fio 由 baseline fixture 提供
  local outf="$1" st="$2"; shift 2
  python3 - "$outf" "$st" "$@" <<'PY'
import json, sys
outf, status = sys.argv[1], sys.argv[2]
vals = [float(v) for v in sys.argv[3:]]
osds = []
for i, v in enumerate(vals):
    osds.append({"osd": i, "host": "mclock-osd-%d" % (i + 1),
                 "bench_iops": v, "bench_status": status,
                 "effective_iops": v, "stored_value": v,
                 "raw_fio_iops": None, "log_lines": []})
with open(outf, "w") as fh:
    json.dump({"schema_version": 1, "generated_at": "2026-07-25T00:00:00Z",
               "osds": osds}, fh, indent=1)
PY
}
lockv() { jget "$1" "osds.$2.locked_value"; }
lockd() { jget "$1" "osds.$2.decision"; }

# 11) accepted-consistent：比值在 [0.5, 2] → 鎖 bench 值
mk_prov "$tmp/d1.json" accepted 45282 44980 46001 45510 44720 45899 45120 45330
ceph_capacity_decide "$tmp/d1.json" "$tmp/lock1.json" >/dev/null || fail "decide 應成功"
ok
eq "$(lockd "$tmp/lock1.json" 0)" "accepted-consistent" "accepted + 比值合理"
eq "$(lockv "$tmp/lock1.json" 0)" "45282" "鎖 bench 值"
eq "$(jget "$tmp/lock1.json" osds.0.locked_source)" "bench" "來源標記"

# 12) H-012 不變條件：bench 值恰等於 compiled default → 偏移 1 IOPS
mk_prov "$tmp/d2.json" accepted 21500 21500 21500 21500 21500 21500 21500 21500
python3 - "$tmp/raw-21k.json" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    json.dump({"mclock-osd-%d" % (i + 1): {"iops": 22000.0} for i in range(8)}, fh)
PY
RAW_NVME_BASELINE_JSON="$tmp/raw-21k.json" \
  ceph_capacity_decide "$tmp/d2.json" "$tmp/lock2.json" >/dev/null \
  || fail "decide（default 值）應成功"
ok
[ "$(lockv "$tmp/lock2.json" 0)" != "21500" ] || fail "locked_value 不得等於 compiled default 21500"
ok
eq "$(lockv "$tmp/lock2.json" 0)" "21499" "偏移 1 IOPS"
eq "$(jget "$tmp/lock2.json" osds.0.offset_from_default)" "True" "偏移要留紀錄"

# 13) accepted-inconsistent：比值出界 → 鎖 min(raw_fio, 72000)、標 fio-derived
mk_prov "$tmp/d3.json" accepted 5000 5100 5050 4980 5020 5090 5010 5060
ceph_capacity_decide "$tmp/d3.json" "$tmp/lock3.json" >/dev/null || fail "decide（inconsistent）應成功"
ok
eq "$(lockd "$tmp/lock3.json" 0)" "accepted-inconsistent" "比值出界"
eq "$(lockv "$tmp/lock3.json" 0)" "48000" "鎖 raw fio 值"
eq "$(jget "$tmp/lock3.json" osds.0.locked_source)" "fio-derived" "標記 fio-derived"

# 13b) fio 值超過 72000 → 取上限
python3 - "$tmp/raw-high.json" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    json.dump({"mclock-osd-%d" % (i + 1): {"iops": 90000.0} for i in range(8)}, fh)
PY
RAW_NVME_BASELINE_JSON="$tmp/raw-high.json" \
  ceph_capacity_decide "$tmp/d3.json" "$tmp/lock3b.json" >/dev/null || fail "decide（cap 72000）應成功"
ok
eq "$(lockv "$tmp/lock3b.json" 0)" "72000" "fio-derived 上限 72000"

# 14) rejected-out-of-range → fio-derived
mk_prov "$tmp/d4.json" rejected-out-of-range 128000 128100 127900 128200 128000 128050 127950 128010
ceph_capacity_decide "$tmp/d4.json" "$tmp/lock4.json" >/dev/null || fail "decide（rejected）應成功"
ok
eq "$(lockd "$tmp/lock4.json" 0)" "rejected-out-of-range" "被 Ceph 丟棄"
eq "$(jget "$tmp/lock4.json" osds.0.locked_source)" "fio-derived" "改用 fio 值"

# 15) skipped-existing-nondefault：對 stored 值做同一比值檢查
mk_prov "$tmp/d5.json" skipped-existing-nondefault 45000 44900 45100 45200 44800 45300 44950 45050
ceph_capacity_decide "$tmp/d5.json" "$tmp/lock5.json" >/dev/null || fail "decide（skipped-consistent）應成功"
ok
eq "$(lockd "$tmp/lock5.json" 0)" "skipped-existing-nondefault" "沿用既有值的分支"
eq "$(jget "$tmp/lock5.json" osds.0.locked_source)" "stored" "consistent → 鎖 stored"
mk_prov "$tmp/d6.json" skipped-existing-nondefault 5000 5100 5050 4980 5020 5090 5010 5060
ceph_capacity_decide "$tmp/d6.json" "$tmp/lock6.json" >/dev/null || fail "decide（skipped-inconsistent）應成功"
ok
eq "$(jget "$tmp/lock6.json" osds.0.locked_source)" "fio-derived" "inconsistent → 改用 fio 值"

# 16) failed / no-result → 一律 die（不得自動選值）
mk_prov "$tmp/d7.json" failed 0 0 0 0 0 0 0 0
outerr="$( ( ceph_capacity_decide "$tmp/d7.json" "$tmp/lock7.json" ) 2>&1 )" \
  && fail "failed 狀態應 die"
ok
case "$outerr" in *"capacity-decide: HUMAN-NEEDED"*) ok ;; *) fail "缺 HUMAN-NEEDED 訊息：${outerr}" ;; esac
mk_prov "$tmp/d8.json" no-result 0 0 0 0 0 0 0 0
( ceph_capacity_decide "$tmp/d8.json" "$tmp/lock8.json" ) >/dev/null 2>&1 \
  && fail "no-result 狀態應 die"
ok

# 17) 跨 8 顆 dispersion gate：CoV > 20% → die（異質 NVMe 防線）
#     osd.7 的 raw NVMe 基線只有 12000 IOPS → bench/raw 比值出界 → 鎖 fio-derived
#     12000，與其餘七顆的 ~45000 拉開離散度。
mk_prov "$tmp/d9.json" accepted 45000 45100 44900 45200 44800 45300 44950 45350
outerr="$( ( RAW_NVME_BASELINE_JSON="$fx/raw-nvme-baseline-outlier.json" \
             ceph_capacity_decide "$tmp/d9.json" "$tmp/lock9.json" ) 2>&1 )" \
  && fail "CoV 超標應 die"
ok
case "$outerr" in *capacity-dispersion-high*) ok ;; *) fail "缺 capacity-dispersion-high：${outerr}" ;; esac
[ -f "$tmp/lock9.json" ] && fail "dispersion 超標不得寫出 lock 檔"
ok

# 18) 不足 8 顆 → die
python3 - "$tmp/d10.json" <<'PY'
import json, sys
osds = [{"osd": i, "host": "mclock-osd-%d" % (i + 1), "bench_iops": 45000.0,
         "bench_status": "accepted", "effective_iops": 45000.0,
         "stored_value": 45000.0, "raw_fio_iops": None, "log_lines": []}
        for i in range(6)]
with open(sys.argv[1], "w") as fh:
    json.dump({"schema_version": 1, "osds": osds}, fh)
PY
( ceph_capacity_decide "$tmp/d10.json" "$tmp/lock10.json" ) >/dev/null 2>&1 \
  && fail "決策表未齊 8 顆應 die"
ok

# ============================================================ ceph_lock_capacity ==
# 19) 逐顆 set 值 + skip_benchmark=true，並回讀驗證
mk_lock 45000 "$tmp/lock-apply.json"
reset_ssh
for i in 0 1 2 3 4 5 6 7; do
  expect_ssh "config set osd.${i} osd_mclock_max_capacity_iops_ssd" 0 0 ""
  expect_ssh "config set osd.${i} osd_mclock_skip_benchmark true" 0 0 ""
done
for i in 0 1 2 3 4 5 6 7; do
  expect_ssh "tell osd.${i} config show" 0 0 "$fx/config-show-balanced.json"
done
out="$(ceph_lock_capacity "$tmp/lock-apply.json")" || fail "ceph_lock_capacity 應成功"
ok
eq "$out" "capacity-lock: PASS 8" "lock 機器行"
eq "$(count_of "$FAKE_SSH_LOG" 'osd_mclock_skip_benchmark true')" "8" "八顆都要設 skip_benchmark"
has "$FAKE_SSH_LOG" "config set osd.3 osd_mclock_max_capacity_iops_ssd 45000" "逐顆鎖值"

# 20) 回讀值不符 → die
mk_lock 51000 "$tmp/lock-bad.json"
reset_ssh
for i in 0 1 2 3 4 5 6 7; do
  expect_ssh "config set osd.${i} osd_mclock_max_capacity_iops_ssd" 0 0 ""
  expect_ssh "config set osd.${i} osd_mclock_skip_benchmark true" 0 0 ""
done
for i in 0 1 2 3 4 5 6 7; do
  expect_ssh "tell osd.${i} config show" 0 0 "$fx/config-show-balanced.json"
done
( ceph_lock_capacity "$tmp/lock-bad.json" ) >/dev/null 2>&1 && fail "鎖定值回讀不符應 die"
ok

# ========================================================= ceph_verify_no_rebench ==
mk_lock 45000
BOOT_OLD="11111111-2222-3333-4444-555555555555"
BOOT_NEW="99999999-8888-7777-6666-555555555555"
printf '%s\n' "$BOOT_NEW" > "$tmp/boot-new.out"
printf '%s\n' "$BOOT_OLD" > "$tmp/boot-old.out"
norebench_expect() { # <boot-id fixture> <journal fixture> <config-show fixture>
  expect_ssh 'boot_id' 0 0 "$1"
  expect_ssh "@osd.0.service" 0 0 "$2"
  expect_ssh 'tell osd.0 config show' 0 0 "$3"
}
# 21) current-boot 合取全過 → PASS
reset_ssh
norebench_expect "$tmp/boot-new.out" "$fx/journal-boot-nobench.txt" "$fx/config-show-balanced.json"
out="$(ceph_verify_no_rebench 0 mclock-osd-1 "$BOOT_OLD" "$tmp/norebench.json")" \
  || fail "ceph_verify_no_rebench 應通過"
ok
eq "$out" "no-rebench: PASS osd.0" "no-rebench 機器行"
# unit-scoped 且限定本次 boot；不得用 pre-reboot cursor / 裸 journalctl -b
has "$FAKE_SSH_LOG" "journalctl -b -u ceph-${CEPH_FSID}@osd.0.service" "unit-scoped + current boot"
hasnt "$FAKE_SSH_LOG" "--cursor" "不得使用 pre-reboot cursor"
hasnt "$FAKE_SSH_LOG" "--since" "不得用時間游標取代 current-boot 證據"
eq "$(jget "$tmp/norebench.json" boot_id_changed)" "True" "證據：boot ID 已變更"
eq "$(jget "$tmp/norebench.json" positive_control)" "True" "證據：positive control 命中（H-013）"

# 22) boot ID 沒變 → die（根本沒重開機，證據無意義）
reset_ssh
norebench_expect "$tmp/boot-old.out" "$fx/journal-boot-nobench.txt" "$fx/config-show-balanced.json"
( ceph_verify_no_rebench 0 mclock-osd-1 "$BOOT_OLD" ) >/dev/null 2>&1 \
  && fail "boot ID 未變應 die"
ok

# 23) 本次 boot 有 bench log → die
reset_ssh
norebench_expect "$tmp/boot-new.out" "$fx/journal-boot-rebench.txt" "$fx/config-show-balanced.json"
( ceph_verify_no_rebench 0 mclock-osd-1 "$BOOT_OLD" ) >/dev/null 2>&1 \
  && fail "重跑 bench 應 die"
ok

# 24) H-013：撈不到已知必存在的 log → 視為 log 管道壞掉，不得假通過
reset_ssh
norebench_expect "$tmp/boot-new.out" "$fx/journal-boot-nomarker.txt" "$fx/config-show-balanced.json"
outerr="$( ( ceph_verify_no_rebench 0 mclock-osd-1 "$BOOT_OLD" ) 2>&1 )" \
  && fail "缺 positive control 應 die"
ok
case "$outerr" in *"positive control"*) ok ;; *) fail "die 訊息要指出 positive control：${outerr}" ;; esac
reset_ssh
norebench_expect "$tmp/boot-new.out" "$fx/journal-empty.txt" "$fx/config-show-balanced.json"
( ceph_verify_no_rebench 0 mclock-osd-1 "$BOOT_OLD" ) >/dev/null 2>&1 \
  && fail "空 journal 應 die"
ok

# 25) effective skip_benchmark 不是 true / capacity 值變了 → die
reset_ssh
norebench_expect "$tmp/boot-new.out" "$fx/journal-boot-nobench.txt" "$fx/config-show-skipfalse.json"
( ceph_verify_no_rebench 0 mclock-osd-1 "$BOOT_OLD" ) >/dev/null 2>&1 \
  && fail "skip_benchmark 非 true 應 die"
ok
reset_ssh
norebench_expect "$tmp/boot-new.out" "$fx/journal-boot-nobench.txt" "$fx/config-show-capwrong.json"
( ceph_verify_no_rebench 0 mclock-osd-1 "$BOOT_OLD" ) >/dev/null 2>&1 \
  && fail "capacity 值改變應 die"
ok

# =================================================== ceph_wait_recovery_complete ==
# 26) 當下 up set 下 PG 全 active+clean 即達成（target 仍 down+out 也算）
reset_ssh
expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-recovering.json"
expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-clean-osd-out.json"
now="$(date +%s)"
out="$(ceph_wait_recovery_complete "$((now + 60))")" || fail "recovery_complete 應達成"
ok
case "$out" in "recovery-complete: reached"*) ok ;; *) fail "機器行不符：${out}" ;; esac

# 27) 撞 cap → 124 + censored（right-censored 是有效觀測，不是失敗）
reset_ssh
expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-recovering.json"
rc=0
out="$(ceph_wait_recovery_complete "$((now - 1))")" || rc=$?
eq "$rc" "124" "撞 measurement cap 回 124"
case "$out" in "recovery-complete: censored"*) ok ;; *) fail "censored 機器行不符：${out}" ;; esac

# ======================================================== ceph_wait_final_clean ==
# 28) OSD 全 up+in + PG clean + 只剩自設 flags → PASS
reset_ssh
expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-clean.json"
out="$(ceph_wait_final_clean 60)" || fail "final_clean 應通過"
ok
eq "$out" "final-clean: PASS" "final-clean 機器行"

# 29) 有 OSD 還 down/out → 不算 final_clean；零進展 → exit 3 交 watchdog
reset_ssh
for _ in 1 2 3 4 5 6 7 8 9 10; do
  expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-clean-osd-out.json"
done
rc=0
out="$(ceph_wait_final_clean 1)" || rc=$?
eq "$rc" "3" "PG 零進展交 watchdog（exit 3）"
case "$out" in "final-clean: NO-PROGRESS"*) ok ;; *) fail "no-progress 機器行不符：${out}" ;; esac

# 30) 非自設的 health check（例：POOL_APP_NOT_ENABLED）→ 不算 final_clean
reset_ssh
for _ in 1 2 3 4 5 6 7 8 9 10; do
  expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-extra-warn.json"
done
rc=0
ceph_wait_final_clean 1 >/dev/null || rc=$?
eq "$rc" "3" "額外 health warning 不得算 clean"

# 31) noout 之類的額外 flag 不在白名單
reset_ssh
for _ in 1 2 3 4 5 6 7 8 9 10; do
  expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-noout-flag.json"
done
rc=0
ceph_wait_final_clean 1 >/dev/null || rc=$?
eq "$rc" "3" "flags 白名單只含 noscrub/nodeep-scrub"

# 32) 有進展就繼續等（不得誤判 no-progress）
reset_ssh
expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-recovering.json"
expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-clean-osd-out.json"
expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-clean.json"
ceph_wait_final_clean 5 >/dev/null || fail "有進展時應繼續等到 clean"
ok

# ============================================================== OSD 狀態 helper ==
# 33) ceph_osd_state 以 up_from / down_at 表達
reset_ssh
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-8up.json"
st="$(ceph_osd_state 3)" || fail "ceph_osd_state 應成功"
ok
eq "$st" "osd.3 up=1 in=1 up_from=15 up_thru=512 down_at=0" "osd_state 機器行"

# 34) 相對 pre-state 判定 down（不是只看 up=0）
reset_ssh
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-8up.json"
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-osd3-down.json"
ceph_wait_osd_down 3 "$st" 30 >/dev/null || fail "應判定 osd.3 已 down"
ok

# 35) 舊的 down_at（早於 pre-state 的 up_from）不算這次的 down
reset_ssh
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-8up.json"
rc=0
ceph_wait_osd_down 3 "osd.3 up=1 in=1 up_from=600 up_thru=700 down_at=0" 0 >/dev/null || rc=$?
eq "$rc" "124" "陳舊 down 事件不得誤判"

# 36) rejoin：up_from 前進才算重新上線
reset_ssh
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-osd3-down.json"
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-osd3-rejoined.json"
ceph_wait_osd_up 3 "osd.3 up=0 in=1 up_from=15 up_thru=512 down_at=520" 30 >/dev/null \
  || fail "應判定 osd.3 已重新 up"
ok

# 37) pg ls-by-osd 全 active（flapping 每輪的 gate）
reset_ssh
expect_ssh 'pg ls-by-osd 3' 0 0 "$fx/pg-ls-by-osd-active.json"
ceph_wait_pgs_active_for_osd 3 30 || fail "全 active 應通過"
ok
reset_ssh
expect_ssh 'pg ls-by-osd 3' 0 0 "$fx/pg-ls-by-osd-peering.json"
rc=0
ceph_wait_pgs_active_for_osd 3 0 || rc=$?
eq "$rc" "124" "peering 中不得放行"
reset_ssh
expect_ssh 'pg ls-by-osd 3' 0 0 "$fx/pg-ls-by-osd-array.json"
ceph_wait_pgs_active_for_osd 3 30 || fail "舊版純陣列格式也要吃得下"
ok
reset_ssh
expect_ssh 'pg ls-by-osd 3' 0 0 "$fx/pg-ls-by-osd-empty.json"
ceph_wait_pgs_active_for_osd 3 30 || fail "沒有 PG 的 OSD 視為通過"
ok

# 38) daemon stop/start 走 orch，不猜 systemd unit 名
reset_ssh
expect_ssh 'orch daemon stop osd.3' 0 0 ""
ceph_daemon_stop 3 || fail "ceph_daemon_stop 應成功"
ok
expect_ssh 'orch daemon start osd.3' 0 0 ""
ceph_daemon_start 3 || fail "ceph_daemon_start 應成功"
ok
hasnt "$FAKE_SSH_LOG" "systemctl" "不得直接操作 systemd unit"
hasnt "$FAKE_SSH_LOG" "ceph-osd@" "不得猜 systemd unit 名"

# 39) out/in 支援一次多顆（rack 場景 backfill 起點要單一）
reset_ssh
expect_ssh 'osd out 6 7' 0 0 ""
ceph_osd_out 6 7 || fail "ceph_osd_out 應成功"
ok
expect_ssh 'osd in 6 7' 0 0 ""
ceph_osd_in 6 7 || fail "ceph_osd_in 應成功"
ok

# 40) health snapshot
reset_ssh
expect_ssh 'ceph -s' 0 0 "$fx/ceph-s-recovering.json"
ceph_health_snapshot "$tmp/health.json" || fail "ceph_health_snapshot 應成功"
ok
has "$tmp/health.json" "OSD_DOWN" "health snapshot 要留 checks"
has "$tmp/health.json" "degraded_objects" "health snapshot 要留 pgmap"

# 41) laggy 只記 covariate，永遠不 gate（round2 REGRESSED 修正）
reset_ssh
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-8up.json"
ceph_check_laggy "$tmp/laggy.json" || fail "ceph_check_laggy 必須永遠回 0"
ok
eq "$(jget "$tmp/laggy.json" osds.3.laggy_probability)" "0.12" "記錄 laggy_probability"
reset_ssh
expect_ssh 'osd dump' 1 0 ""
ceph_check_laggy "$tmp/laggy2.json" || fail "連查詢失敗都不得讓 laggy 擋住流程"
ok

printf 'test-ceph-qos.sh: %d assertions passed\n' "$asserts"
