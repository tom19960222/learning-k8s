#!/usr/bin/env bash
# Task 11 — lib/pipeline.sh：Replicate Pipeline 狀態機、Reconciler、claim lease、
# watchdog transition table、taint/abort 重試預算。
#
# 測試策略：pipeline 是**編排器**，它的正確性 = 「以什麼順序、帶什麼參數、在哪些出口
# 呼叫哪些 lib」。因此本檔 source 真的 lib/pipeline.sh，再把外部依賴（ceph/fio/inject/
# collect 的遠端動作）覆寫成 recorder stub，對 trace 逐項斷言順序與分派。
# verdict.py / manifest.py 走「假 CLI」：schemas/freeze 委派給**真的** verdict.py
#（交叉核對要是真的），其餘子命令回可控輸出。
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-pipeline.XXXXXX")"

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

export PATH="$here/fakes:$PATH"
export FAKE_SSH_SCRIPT="$tmp/ssh.script"
export FAKE_SSH_LOG="$tmp/ssh.log"
export FAKE_SSH_STATE="$tmp/ssh.state"
export FAKE_AZ_SCRIPT="$tmp/az.script"
export FAKE_AZ_LOG="$tmp/az.log"
export FAKE_AZ_STATE="$tmp/az.state"
export RESULTS_DIR="$tmp/results"
export POLL_INTERVAL=0.02
export CEPH_OSD_IDS="0 1 2 3 4 5 6 7"
export CEPH_FSID="3f2b1c8e-7a41-4c9d-9b0e-2d5a6f7c8b90"
export RUNNER_ID="runner-test"
export INJECT_CONFIRMED=1
# 每次 tick 都做 coverage 檢查（真跑是 30s cadence）
export COVERAGE_CADENCE_SECS=0
export VERDICT_PY="$tmp/fake-verdict.py"
export MANIFEST_PY="$tmp/fake-manifest.py"
export FAKE_VERDICT_LOG="$tmp/verdict.log"
export FAKE_MANIFEST_LOG="$tmp/manifest.log"
export AZ_RESOURCE_GROUP="rg-mclock"
# 下面四個是「假 verdict.py」的旋鈕，而它是**獨立 process**（不是 shell stub）——
# 先宣告 export 屬性，之後各測試區塊的一般賦值才會真的進到它的環境。
export FAKE_BASELINE_RC FAKE_BASELINE_LINE FAKE_NEED_MORE_N FAKE_AMEND_LINES
: > "$FAKE_SSH_SCRIPT"; : > "$FAKE_AZ_SCRIPT"
: > "$FAKE_VERDICT_LOG"; : > "$FAKE_MANIFEST_LOG"

REAL_VERDICT="$root/lib/verdict.py"

# --- 假 verdict.py：schemas/freeze 委派真檔，其餘回可控輸出 --------------------
cat > "$VERDICT_PY" <<'PY'
import hashlib
import json
import os
import subprocess
import sys

argv = sys.argv[1:]
with open(os.environ["FAKE_VERDICT_LOG"], "a") as fh:
    fh.write(" ".join(argv) + "\n")
cmd = argv[0] if argv else ""
real = os.environ["REAL_VERDICT"]


def delegate():
    raise SystemExit(subprocess.call([sys.executable, real] + argv))


def read(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def write(path, doc):
    with open(path, "w") as fh:
        json.dump(doc, fh, indent=1, sort_keys=True)
        fh.write("\n")


if cmd in ("schemas", "freeze"):
    delegate()
elif cmd == "aggregate":
    bundle = argv[1]
    pred = read(os.path.join(bundle, "prediction.json"), {}) or {}
    write(os.path.join(bundle, "aggregate.json"), {
        "schema_version": 1,
        "cell_id": pred.get("cell_id"),
        "group_id": pred.get("group_id"),
        "profile": pred.get("profile"),
        "endpoints": {"p99_degradation_ratio": 1.2, "max_stall_seconds": 0.0},
        "coverage": {"window": {"start": 1000, "end": 1100}},
    })
    sys.stdout.write("aggregate: OK\n")
elif cmd == "verdict":
    bundle = argv[1]
    pred_path = os.path.join(bundle, "prediction.json")
    pred = read(pred_path, {}) or {}
    with open(pred_path, "rb") as fh:
        sha = hashlib.sha256(fh.read()).hexdigest()
    write(os.path.join(bundle, "verdict.json"), {
        "schema_version": 1,
        "cell_id": pred.get("cell_id"),
        "profile": pred.get("profile"),
        "prediction_sha256": sha,
        "status": "recorded",
    })
    sys.stdout.write("verdict: RECORDED %s\n" % pred.get("cell_id"))
elif cmd == "baseline-check":
    sys.stdout.write(os.environ.get("FAKE_BASELINE_LINE", "baseline-check: OK") + "\n")
    raise SystemExit(int(os.environ.get("FAKE_BASELINE_RC", "0")))
elif cmd == "need-more-n":
    sys.stdout.write(os.environ.get("FAKE_NEED_MORE_N", "need-more-n: OK") + "\n")
    for line in os.environ.get("FAKE_AMEND_LINES", "").splitlines():
        if line.strip():
            sys.stdout.write(line + "\n")
else:
    sys.stderr.write("fake-verdict: 未預期的子命令 %s\n" % cmd)
    raise SystemExit(95)
PY

cat > "$MANIFEST_PY" <<'PY'
import os
import sys

with open(os.environ["FAKE_MANIFEST_LOG"], "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
sys.stdout.write("amend: ok\n")
PY
export REAL_VERDICT

# =============================================================== 載入 pipeline ==
[ -f "$root/lib/pipeline.sh" ] || fail "lib/pipeline.sh 不存在（TDD：先紅）"
# shellcheck source=../lib/pipeline.sh
. "$root/lib/pipeline.sh"
inventory_load "$fixture"
cleanup_push "rm -rf '$tmp'"
mkdir -p "$RESULTS_DIR"

TRACE="$tmp/trace.log"
: > "$TRACE"
t() { printf '%s\n' "$*" >> "$TRACE"; }
reset_trace() { : > "$TRACE"; }
idx() { grep -nF -m1 -- "$1" "$TRACE" 2>/dev/null | head -1 | cut -d: -f1; }
before() { # <先> <後> <說明>
  local a b
  a="$(idx "$1")"; b="$(idx "$2")"
  [ -n "$a" ] || fail "$3：trace 缺 [$1]"
  [ -n "$b" ] || fail "$3：trace 缺 [$2]"
  [ "$a" -lt "$b" ] || fail "$3：[$1](#$a) 應早於 [$2](#$b)"
  ok
}

# --- 外部依賴 stub（覆寫真 lib 的遠端動作）------------------------------------
ceph_adm() { t "ceph_adm $*"; printf '%s\n' "${FAKE_CEPH_ADM_OUT:-}"; return "${FAKE_CEPH_ADM_RC:-0}"; }
ceph_adm_to() { local s="$1"; shift; t "ceph_adm_to $s $*"; return 0; }
node_ssh() { t "node_ssh $*"; return "${FAKE_NODE_SSH_RC:-0}"; }
_node_run() { t "node_run $1 $3"; return "${FAKE_NODE_SSH_RC:-0}"; }
_node_sh() { t "node_sh $1 $3"; return "${FAKE_NODE_SSH_RC:-0}"; }
remote_bg_stop() { t "remote_bg_stop $1 $2"; }
remote_bg_list() { t "remote_bg_list $1"; printf '%s\n' "${FAKE_BG_LIST:-}"; }

ceph_set_profile() {
  t "ceph_set_profile $1"
  printf 'set-profile: SET balanced %s\n' "$1"
  return "${FAKE_SETPROF_RC:-0}"
}
ceph_qos_gate() {
  t "ceph_qos_gate $1"
  mkdir -p "$2"
  printf '{"profile": "%s"}\n' "$1" > "$2/qos.json"
  printf 'qos-gate: PASS %s\n' "$1"
  return "${FAKE_QOS_RC:-0}"
}
ceph_wait_final_clean() { t "ceph_wait_final_clean ${1:-}"; return "${FAKE_FINAL_CLEAN_RC:-0}"; }
ceph_wait_recovery_complete() { t "ceph_wait_recovery_complete $1"; return "${FAKE_RECOVERY_RC:-0}"; }
ceph_health_snapshot() { t "ceph_health_snapshot"; printf '{"final_clean": true}\n' > "$1"; }
ceph_osd_state() { t "ceph_osd_state $1"; printf 'osd.%s up=%s in=%s up_from=10 up_thru=10 down_at=0\n' \
  "$1" "${FAKE_OSD_UP:-1}" "${FAKE_OSD_IN:-1}"; }
ceph_daemon_start() { t "ceph_daemon_start $1"; }
ceph_daemon_stop() { t "ceph_daemon_stop $1"; }
ceph_osd_in() { t "ceph_osd_in $*"; }
ceph_osd_out() { t "ceph_osd_out $*"; }
ceph_check_laggy() { t "ceph_check_laggy"; printf '{"osds": []}\n' > "$1"; }

sampler_start() {
  t "sampler_start $1"
  mkdir -p "$1/sampler"
  printf '{"run_id": "sampler-x", "node": "mclock-admin"}\n' > "$1/sampler/run.json"
  printf 'sampler: STARTED sampler-x 1\n'
}
sampler_assert_alive() { t "sampler_assert_alive"; return "${FAKE_SAMPLER_RC:-0}"; }
sampler_stop() { t "sampler_stop"; printf 'sampler: STOPPED sampler-x\n'; }
bg_collect_assert_alive() { t "bg_collect_assert_alive"; return "${FAKE_BGC_RC:-0}"; }
bg_collect_ensure() { t "bg_collect_ensure"; printf 'bg-collect: RESTARTED 1\n'; }
coverage_check() { t "coverage_check"; return "${FAKE_COV_RC:-0}"; }
coverage_finalize() {
  t "coverage_finalize"
  printf '{"window": {"start": 1000, "end": 1100}, "gaps": [], "tainted": %s}\n' \
    "${FAKE_COV_TAINTED:-false}" > "$1/coverage-proof.json"
  return "${FAKE_COVFIN_RC:-0}"
}
collect_return_backfill() {
  t "collect_return_backfill $2 $3"
  printf '{"heal_t0": %s, "final_clean_t": %s}\n' "$2" "$3" > "$1/return-backfill.json"
}
collect_cell() {
  t "collect_cell $2 $3 $4"
  printf '{"achieved_iops": 1000}\n' > "$1/fio-summary.json"
  printf '{"recovery_bytes_per_sec_median": 1}\n' > "$1/sampler-summary.json"
  printf 'collect-cell: PASS %s missing=0\n' "$1"
}

fio_start_bg() {
  t "fio_start_bg mode=$2 shape=$3 rate=$4"
  mkdir -p "$1/fio"
  printf 'mclock-client-1\tfio-x\t/var/tmp/mclock-fio/x\n' > "$1/fio/run.tsv"
  printf 'mode=%s\nshape=%s\nrate=%s\n' "$2" "$3" "$4" > "$1/fio/run.meta"
  printf 'fio-start: PASS 4\n'
}
fio_readiness_barrier() { t "fio_readiness_barrier"; return "${FAKE_READY_RC:-0}"; }
fio_wait_segments() {
  t "fio_wait_segments deadline=$3"
  local i=0
  while [ "$i" -lt "${FAKE_WAIT_TICKS:-2}" ]; do
    "$2" >/dev/null 2>&1 || true
    i=$((i + 1))
  done
  return "${FAKE_WAIT_RC:-0}"
}
fio_stop() { t "fio_stop"; return "${FAKE_FIO_STOP_RC:-0}"; }
fio_assert_alive() { t "fio_assert_alive"; return "${FAKE_FIO_ALIVE_RC:-0}"; }
fio_run_baseline() {
  t "fio_run_baseline shape=$2 pressure=$3 rate=$4"
  printf '{"shape": "%s", "pressure": "%s", "achieved_iops": 100}\n' "$2" "$3" > "$1/baseline.json"
  printf 'fio-baseline: PASS 100\n'
}
fio_unmap_all() { t "fio_unmap_all"; }
fio_map_all() { t "fio_map_all"; }
fio_smoke_real() { t "fio_smoke_real"; return "${FAKE_SMOKE_RC:-0}"; }
_fio_all_done() { t "fio_all_done"; return "${FAKE_FIO_DONE_RC:-0}"; }

inject_rollback_all() { t "inject_rollback_all"; printf 'inject-rollback: CLEAN\n'; }
inject_cleanup_proof() {
  t "inject_cleanup_proof"
  printf '{"clean": true}\n' > "$1/cleanup-proof.json"
  printf 'inject-cleanup: PASS\n'
}
fault_osd_down() {
  t "fault_osd_down osd=$1 cap=${MEASUREMENT_CAP:-unset} deadline=${MEASUREMENT_DEADLINE:-unset}"
  return "${FAKE_INJECT_RC:-0}"
}
fault_osd_down_recover() { t "fault_osd_down_recover osd=$1"; return "${FAKE_RECOVER_RC:-0}"; }
fault_flapping() { t "fault_flapping osd=$1"; return "${FAKE_INJECT_RC:-0}"; }
fault_node_isolate() { t "fault_node_isolate node=$1"; return "${FAKE_INJECT_RC:-0}"; }
fault_node_heal() { t "fault_node_heal node=$1"; return "${FAKE_RECOVER_RC:-0}"; }
fault_rack_isolate() { t "fault_rack_isolate rack=$1"; return "${FAKE_INJECT_RC:-0}"; }
fault_rack_heal() { t "fault_rack_heal rack=$1"; return "${FAKE_RECOVER_RC:-0}"; }
chaos_run() {
  t "chaos_run seed=$1 duration=$2"
  printf '{"events": []}\n' > "$3/event-seq.json"
  return "${FAKE_CHAOS_RC:-0}"
}
_inject_tree_load() { :; }
_inject_osd_for_node() { printf '%s\n' "${1##*-}"; }   # mclock-osd-3 → 3
_inject_nodes_in_rack() { inv_names osd | head -2; }

mk_exec() { # <out> <kind> <fault> [pressure] [shape] [cell]
  local out="$1" kind="$2" fault="$3" pressure="${4:-mid}" shape="${5:-4k}"
  local cell="${6:-${fault}-${shape}-${pressure}+balanced}"
  python3 - "$out" "$kind" "$fault" "$pressure" "$shape" "$cell" <<'PY'
import json
import sys

out, kind, fault, pressure, shape, cell = sys.argv[1:7]
targets = []
if fault in ("osd-down", "flapping", "node-isolation", "seq-contention"):
    targets = [{"node": "mclock-osd-3", "rack": "rack2"}]
elif fault == "rack-isolation":
    targets = [{"node": "mclock-osd-1", "rack": "rack1"},
               {"node": "mclock-osd-2", "rack": "rack1"}]
fp = {}
cap = None
if kind == "fault":
    cap = 2700
    fp = {"measurement_cap": cap, "guard_margin_secs": 600, "manual_out": True}
    if fault == "flapping":
        fp = {"measurement_cap": cap, "guard_margin_secs": 600, "cycles": 10, "no_out": True}
elif kind == "chaos":
    fp = {"seed": 4242, "duration": 1800, "guard_deadline_secs": 2400}
doc = {
    "cell_id": cell,
    "group_id": "%s-%s-%s" % (fault, shape, pressure),
    "group_index": 3,
    "kind": kind,
    "profile": "balanced",
    "shape": shape,
    "pressure": pressure,
    "fault": fault,
    "fault_params": fp,
    "targets": targets,
    "base_n": 2,
    "replicate_n": 1,
    "replicate": "r1",
    "latin_position": 0,
    "origin": "base",
    "bundle_key": "%s/r1" % cell,
    "manifest_hash": "deadbeefcafe0001",
    "measurement_cap": cap,
    "measurement_cap_source": "base",
    "guard_deadline_secs": (cap + 600) if cap else 2400,
}
with open(out, "w") as fh:
    json.dump(doc, fh, sort_keys=True)
PY
}

reset_state() {
  rm -rf "$RESULTS_DIR"
  mkdir -p "$RESULTS_DIR"
  printf '{"shapes": {"4k": {"ceiling_iops": 40000, "rates": {"low": 10000, "mid": 20000, "high": 32000}}}}\n' \
    > "$RESULTS_DIR/calibration.json"
  reset_trace
  : > "$FAKE_VERDICT_LOG"
  : > "$FAKE_MANIFEST_LOG"
  unset FAKE_WAIT_RC FAKE_COV_RC FAKE_INJECT_RC FAKE_RECOVER_RC FAKE_FINAL_CLEAN_RC 2>/dev/null || true
  FAKE_WAIT_RC=0; FAKE_COV_RC=0; FAKE_INJECT_RC=0; FAKE_RECOVER_RC=0; FAKE_FINAL_CLEAN_RC=0
  FAKE_COV_TAINTED=false; FAKE_COVFIN_RC=0; FAKE_SAMPLER_RC=0; FAKE_BGC_RC=0
  FAKE_READY_RC=0; FAKE_FIO_STOP_RC=0; FAKE_CHAOS_RC=0; FAKE_RECOVERY_RC=0
  FAKE_BASELINE_RC=0; FAKE_BASELINE_LINE="baseline-check: OK"
  FAKE_SETPROF_RC=0; FAKE_QOS_RC=0
  _pipeline_reset_runtime_state
}
reset_state

# ===================================================== 1. 嚴禁自動 deallocate ==
# 原始碼層級的紅線：整份 pipeline 不得出現 deallocate（spec §7 watchdog 第三層）。
hasnt "$root/lib/pipeline.sh" "deallocate" "pipeline.sh 嚴禁自動 deallocate"
has "$root/lib/pipeline.sh" "az vm restart" "watchdog 2b 的唯一 az 例外仍在"

# ================================================================ 2. runner lock ==
out="$(runner_lock_acquire)" || fail "runner_lock_acquire 應成功"
eq "$out" "runner-lock: ACQUIRED runner-test" "runner lock 機器行"
[ -d "$RESULTS_DIR/.runner.lock" ] || fail "runner lock 應是 mkdir 原子目錄"
ok
eq "$(cat "$RESULTS_DIR/.runner.lock/owner")" "runner-test" "runner lock 記 owner"

# 2b) 另一個 runner（心跳新鮮）→ 拒絕
RUNNER_ID="runner-other"
if (runner_lock_acquire) >/dev/null 2>&1; then fail "心跳新鮮時第二個 runner 不該取得 lock"; fi
ok
# 2c) 心跳過期 → 接管
printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$RESULTS_DIR/.runner.lock/hb"
out="$(runner_lock_acquire)" || fail "stale lock 應可接管"
eq "$out" "runner-lock: TAKEOVER runner-other" "stale runner lock 接管機器行"
eq "$(cat "$RESULTS_DIR/.runner.lock/owner")" "runner-other" "接管後 owner 換人"
runner_lock_release >/dev/null
[ -d "$RESULTS_DIR/.runner.lock" ] && fail "release 後 lock 目錄應消失"
ok
RUNNER_ID="runner-test"

# ================================================================ 3. claim lease ==
out="$(claim_acquire "osd-down-4k-mid+balanced" r1)" || fail "claim_acquire 應成功"
eq "$out" "claim: ACQUIRED osd-down-4k-mid+balanced/r1" "claim 機器行"
[ -d "$RESULTS_DIR/osd-down-4k-mid+balanced/r1/.claim" ] || fail "claim 應是 mkdir 原子目錄"
ok
eq "$(cat "$RESULTS_DIR/osd-down-4k-mid+balanced/r1/.claim/owner")" "runner-test" "claim 記 runner id"

RUNNER_ID="runner-other"
if (claim_acquire "osd-down-4k-mid+balanced" r1) >/dev/null 2>&1; then
  fail "心跳新鮮的 claim 不該被搶走"
fi
ok
printf '%s\n' "$(( $(date +%s) - 99999 ))" > "$RESULTS_DIR/osd-down-4k-mid+balanced/r1/.claim/hb"
out="$(claim_acquire "osd-down-4k-mid+balanced" r1)" || fail "stale claim 應可接管"
eq "$out" "claim: TAKEOVER osd-down-4k-mid+balanced/r1" "stale claim 接管機器行"
claim_release "osd-down-4k-mid+balanced" r1 >/dev/null
[ -d "$RESULTS_DIR/osd-down-4k-mid+balanced/r1/.claim" ] && fail "release 後 claim 應消失"
ok
RUNNER_ID="runner-test"

# ================================================================== 4. watchdog ==
reset_state
# 4a) collector heartbeat 失聯 → **只重啟 collector，絕不碰 OSD/cluster**
FAKE_BGC_RC=0
out="$(watchdog_handle collector-heartbeat "$RESULTS_DIR/b1")" || fail "collector 修復應成功"
has "$TRACE" "bg_collect_ensure" "collector trigger 會重啟 collector"
hasnt "$TRACE" "ceph_daemon_start" "collector trigger 不得碰 OSD"
hasnt "$TRACE" "orch daemon restart" "collector trigger 不得 restart daemon"
hasnt "$TRACE" "reboot" "collector trigger 不得 reboot"
eq "$(cat "$FAKE_AZ_STATE/count" 2>/dev/null || echo 0)" "0" "collector trigger 不得呼叫 az"
eq "$out" "watchdog: REPAIRED collector-heartbeat" "watchdog 修復機器行"
# 修復成功 → 該 trigger 計數歸零
eq "$(watchdog_count collector-heartbeat)" "0" "修復成功即 reset 計數"

# 4b) 計數持久化 + 上限後升級（collector 上限 2 → 第三次進層 3）
reset_trace
FAKE_BGC_RC=1
watchdog_handle collector-heartbeat b1 >/dev/null 2>&1 || true
eq "$(watchdog_count collector-heartbeat)" "1" "失敗要留計數（持久化）"
eq "$(jget "$RESULTS_DIR/watchdog-state.json" counts.collector-heartbeat)" "1" "計數寫進 watchdog-state.json"
watchdog_handle collector-heartbeat b1 >/dev/null 2>&1 || true
eq "$(watchdog_count collector-heartbeat)" "2" "第二次失敗計數遞增"
out="$(watchdog_handle collector-heartbeat b1 2>/dev/null)"; rc=$?
eq "$rc" "3" "超過上限 → 層 3（rc 3）"
eq "$out" "watchdog: HUMAN-NEEDED collector-heartbeat b1" "層 3 機器行"
if watchdog_halted; then ok; else fail "層 3 之後佇列必須停"; fi

# 4c) resume 不重置計數（重新載入 state 檔）
_pipeline_reset_runtime_state
eq "$(watchdog_count collector-heartbeat)" "3" "resume 後計數從 state 檔恢復（不重置）"
if watchdog_halted; then ok; else fail "resume 後仍應維持停佇列"; fi

# 4c-2) 沒有任何 OSD down/out 時，stuck node 不可盲選 inventory 第一台
# 真機實測：八顆全部 up+in，卡的是一個 PG 的 recovery，於是原本的 fallback
# 回傳了 mclock-osd-1，watchdog 就重開了一台跟問題完全無關的健康節點。
FAKE_OSD_UP=1; FAKE_OSD_IN=1
FAKE_CEPH_ADM_OUT='[{"pgid":"2.1a","state":"active+recovering+degraded","acting":[4,1],"acting_primary":4}]'
_INJECT_TREE_CACHE="mclock-osd-1 rack1 0
mclock-osd-5 rack3 4"
eq "$(_pipeline_stuck_node)" "mclock-osd-5" \
  "無 down/out 的 OSD 時，目標取自卡住的 PG 的 primary（osd.4 → mclock-osd-5）"
unset FAKE_CEPH_ADM_OUT _INJECT_TREE_CACHE

# 4d) PG 零進展 → 第一段必須是 pg repeer（不動 daemon、不重開機）
# 真機實測：flapping 會讓 PG 的 recovering 清單卡住兩個物件永不完成（被 flap 的
# OSD 進得了 up 卻進不了 acting），client 對那些物件的 read 永遠停在 waiting for
# rw locks。`ceph pg repeer` 一下就解，而重開 node 完全沒用——問題不在任何機器上。
reset_state
FAKE_FINAL_CLEAN_RC=0
FAKE_CEPH_ADM_OUT='[{"pgid":"2.1a","state":"active+recovering+degraded","acting":[4,1],"acting_primary":4}]'
out="$(watchdog_handle pg-no-progress mclock-osd-3)" || fail "pg-no-progress 修復應成功"
has "$TRACE" "ceph pg repeer 2.1a" "pg-no-progress 第一段是對卡住的 PG repeer"
hasnt "$TRACE" "orch daemon restart" "第一段不得動 daemon（repeer 便宜且精準）"
hasnt "$TRACE" "sudo reboot" "第一段更不得重開機"
has "$TRACE" "ceph_wait_final_clean" "pg-no-progress 的成功判準是 final_clean"
hasnt "$TRACE" "bg_collect_ensure" "pg-no-progress 不該去動 collector"
eq "$out" "watchdog: REPAIRED pg-no-progress" "pg-no-progress 修復機器行"

# 4d-2) repeer 沒解決 → 才升級到 restart OSD
reset_state
FAKE_FINAL_CLEAN_RC=1
watchdog_handle pg-no-progress mclock-osd-3 >/dev/null 2>&1 || true
reset_trace
FAKE_FINAL_CLEAN_RC=0
watchdog_handle pg-no-progress mclock-osd-3 >/dev/null 2>&1 || true
has "$TRACE" "orch daemon restart osd.3" "repeer 失敗後才 restart 相關 OSD"

# 4e) pg-no-progress 連續失敗 → 升級到 node reboot（2a），而不是直接叫人
reset_state
FAKE_FINAL_CLEAN_RC=1
watchdog_handle pg-no-progress mclock-osd-3 >/dev/null 2>&1 || true
watchdog_handle pg-no-progress mclock-osd-3 >/dev/null 2>&1 || true
watchdog_handle pg-no-progress mclock-osd-3 >/dev/null 2>&1 || true
reset_trace
watchdog_handle pg-no-progress mclock-osd-3 >/dev/null 2>&1 || true
has "$TRACE" "sudo reboot" "pg-no-progress 上限後升級到 2a（ssh reboot）"
unset FAKE_CEPH_ADM_OUT

# 4f) 2a 失敗 → 2b（az vm restart，唯一 az 例外），且**不得** deallocate
reset_state
FAKE_FINAL_CLEAN_RC=1
printf 'vm restart|0|\n' > "$FAKE_AZ_SCRIPT"
printf 'vm restart|0|\n' >> "$FAKE_AZ_SCRIPT"
watchdog_handle node-ssh-lost mclock-osd-3 >/dev/null 2>&1 || true
watchdog_handle node-ssh-lost mclock-osd-3 >/dev/null 2>&1 || true
reset_trace
watchdog_handle node-ssh-lost mclock-osd-3 >/dev/null 2>&1 || true
has "$FAKE_AZ_LOG" "vm restart" "2a 上限後才用 az vm restart"
hasnt "$FAKE_AZ_LOG" "deallocate" "任何情況都不得 deallocate"

# 4g) mon quorum 異常 → restart mon，不碰 OSD、不 reboot
reset_state
FAKE_CEPH_ADM_OUT='{"quorum": [0, 1, 2]}'
out="$(watchdog_handle mon-quorum mclock-mon-1)" || fail "mon-quorum 修復應成功"
has "$TRACE" "orch daemon restart mon.mclock-mon-1" "mon trigger 只 restart 該 mon"
hasnt "$TRACE" "orch daemon restart osd" "mon trigger 不得 restart OSD"
hasnt "$TRACE" "sudo reboot" "mon trigger 不得 reboot"
unset FAKE_CEPH_ADM_OUT

# 4h) fio client heartbeat 失聯 → unmap/map + smoke，不碰 OSD
reset_state
out="$(watchdog_handle fio-heartbeat "$RESULTS_DIR/b1")" || fail "fio trigger 修復應成功"
has "$TRACE" "fio_unmap_all" "fio trigger 會重做 map"
has "$TRACE" "fio_smoke_real" "fio trigger 的成功判準是 smoke 過"
hasnt "$TRACE" "orch daemon restart" "fio trigger 不得碰 OSD"

# ============================================================ 5. taint 重試預算 ==
reset_state
CELL="osd-down-4k-mid+balanced"
eq "$(pipeline_taint_count "$CELL" r1)" "0" "初始 taint 計數 0"
pipeline_taint_bump "$CELL" r1 "coverage-gap" >/dev/null
pipeline_taint_bump "$CELL" r1 "coverage-gap" >/dev/null
eq "$(pipeline_taint_count "$CELL" r1)" "2" "taint 計數累加"
hasnt "$FAKE_MANIFEST_LOG" "needs-human" "未達預算前不得寫 needs-human"
out="$(pipeline_taint_bump "$CELL" r1 "coverage-gap")"
eq "$(pipeline_taint_count "$CELL" r1)" "3" "第三次 taint"
has "$FAKE_MANIFEST_LOG" "--type needs-human" "連續 3 次 taint → amend needs-human"
has "$FAKE_MANIFEST_LOG" "--key ${CELL}/r1" "needs-human 的 key 是 cell/replicate"
eq "$out" "taint-budget: NEEDS-HUMAN ${CELL}/r1 3" "預算耗盡機器行"
# 佇列跳過：再跑同一 replicate 直接 SKIP，且不得重發 amend
mk_exec "$tmp/ex-budget.json" fault osd-down mid 4k "$CELL"
reset_trace
: > "$FAKE_MANIFEST_LOG"
out="$(pipeline_run_execution "$tmp/ex-budget.json" 2>/dev/null)"; rc=$?
eq "$rc" "5" "預算耗盡的 replicate 應直接 SKIP"
eq "$out" "pipeline: SKIP ${CELL}/r1 needs-human" "SKIP 機器行"
hasnt "$TRACE" "ceph_qos_gate" "SKIP 不該進 preflight"
hasnt "$TRACE" "ceph_set_profile" "SKIP 不該去動叢集的 profile"
hasnt "$FAKE_MANIFEST_LOG" "needs-human" "needs-human 只發一次（不得重發）"
# 成功一次即清零
pipeline_taint_clear "$CELL" r1
eq "$(pipeline_taint_count "$CELL" r1)" "0" "成功後 taint 計數歸零"

# =============================================================== 6. reconcile ====
reset_state
mkdir -p "$RESULTS_DIR/c1/r1/attempts/20260101T000000Z"
mkdir -p "$RESULTS_DIR/c1/r2/attempts/20260101T010000Z"
printf 'kind=fault\n' > "$RESULTS_DIR/c1/r2/attempts/20260101T010000Z/DONE"
FAKE_BG_LIST="$(printf 'fio-c1-r1-x-mclock-client-1 111 alive\nsampler-c1-r1-x 222 alive\nguard-mclock-osd-3 333 alive\nbgc-events 444 alive\n')"
FAKE_OSD_UP=0
FAKE_OSD_IN=0
out="$(reconcile)" || fail "reconcile 應成功"
has "$TRACE" "iptables -F MCLOCK-ISO" "reconcile 掃 MCLOCK-ISO chain 殘留"
has "$TRACE" "ceph_daemon_start 0" "reconcile 把非預期 down 的 OSD 拉起來"
has "$TRACE" "ceph_osd_in 0" "reconcile 把非預期 out 的 OSD 收回"
has "$TRACE" "remote_bg_stop mclock-osd-1 guard-mclock-osd-3" "reconcile 清 registry 殘留 guard"
grep -qF "remote_bg_stop mclock-client-1 fio-c1-r1-x-mclock-client-1" "$TRACE" \
  || fail "reconcile 清 registry 殘留 fio"
ok
hasnt "$TRACE" "remote_bg_stop mclock-admin bgc-events" "reconcile 不得殺 campaign 級 collector"
has "$TRACE" "bg_collect_ensure" "reconcile 會確保 bg collector 活著"
has "$TRACE" "ceph_wait_final_clean" "reconcile 等 final_clean 才放行"
[ -s "$RESULTS_DIR/c1/r1/attempts/20260101T000000Z/ABORTED" ] || fail "未 finalize 的 attempt 應標 aborted"
ok
[ -e "$RESULTS_DIR/c1/r2/attempts/20260101T010000Z/ABORTED" ] && fail "已 DONE 的 attempt 不得標 aborted"
ok
case "$out" in reconcile:*PASS*) ok ;; *) fail "reconcile 機器行（got=[$out]）" ;; esac
runner_lock_release >/dev/null 2>&1 || true
FAKE_OSD_UP=1; FAKE_OSD_IN=1; FAKE_BG_LIST=""

# reconcile 的 final_clean 零進展 → 交 watchdog
reset_state
FAKE_FINAL_CLEAN_RC=3
FAKE_CEPH_ADM_OUT='[{"pgid":"3.7","state":"active+degraded","acting":[2,5],"acting_primary":2}]' 
reconcile >/dev/null 2>&1 || true
has "$TRACE" "ceph pg repeer" "reconcile 的 final_clean 零進展交 watchdog（第一段 = repeer）"
runner_lock_release >/dev/null 2>&1 || true

# ============================================ 7. fault execution：順序與不變條件 ==
reset_state
mk_exec "$tmp/ex-fault.json" fault osd-down mid 4k
out="$(pipeline_run_execution "$tmp/ex-fault.json")" || fail "fault happy path 應成功（got rc=$?）"
eq "$out" "pipeline: DONE osd-down-4k-mid+balanced/r1" "pipeline 完成機器行"

# 7a) 順序：sampler_start → assert → fio 啟動 → readiness → **注入**
before "sampler_start" "sampler_assert_alive" "sampler 先 start 才 assert（順序不可倒）"
before "sampler_assert_alive" "fio_start_bg" "assert 之後才啟動 fio"
before "fio_start_bg" "fio_readiness_barrier" "fio 啟動後才等 readiness"
before "fio_readiness_barrier" "fault_osd_down" "**fio readiness 必須在注入之前**（workload 先行）"
before "ceph_qos_gate" "sampler_start" "preflight 在 sampler 之前"
# Task 0.1：先「設定」profile 才「驗證」——順序倒過來就是第一個非 balanced 的 cell 卡死
before "ceph_set_profile" "ceph_qos_gate" "**profile 切換必須在 qos gate 之前**"
has "$TRACE" "ceph_set_profile balanced" "設定的 profile 取自 execution 的 profile 欄位"
before "fault_osd_down" "fio_wait_segments" "注入後才進量測窗（fio 持續跑）"
before "fio_wait_segments" "fio_stop" "量測窗結束才停 fio"
before "fio_stop" "fault_osd_down_recover" "先停 fio 才回歸"
before "fault_osd_down_recover" "collect_return_backfill" "回歸後才記 H-008 兩時戳"
before "collect_return_backfill" "fio_run_baseline" "safety gate 之後才 baseline 復測"
before "fio_run_baseline" "sampler_stop" "baseline 復測完才停 sampler"
before "sampler_stop" "collect_cell" "sampler 停了才 collect_cell"
before "collect_cell" "coverage_finalize" "coverage_finalize 在 collect_cell 之後"

# 7b) prediction freeze 在注入之前，且 manifest_hash 用 manifest.py next 給的值
B="$(ls -d "$RESULTS_DIR/osd-down-4k-mid+balanced/r1/attempts/"*)"
eq "$(jget "$B/prediction.json" manifest_hash)" "deadbeefcafe0001" "prediction 帶 manifest_hash"
eq "$(jget "$B/prediction.json" cell_id)" "osd-down-4k-mid+balanced" "prediction 帶 cell_id"
has "$FAKE_VERDICT_LOG" "freeze" "prediction 有走 verdict.py freeze"
[ -s "$B/.prediction-freeze.json" ] || [ -s "$B/prediction-freeze.json" ] || fail "freeze 應留下 sha 記錄"
ok

# 7c) 量測窗 stop-condition = recovery_complete；deadline = fault_t0 + cap
has "$TRACE" "ceph_wait_recovery_complete" "stop-condition 用 recovery_complete"
T0="$(jget "$B/fault-timeline.json" fault_t0)"
DL="$(jget "$B/fault-timeline.json" measurement_deadline)"
eq "$(jget "$B/fault-timeline.json" measurement_cap)" "2700" "cap 持久化進 fault-timeline"
eq "$((DL - T0))" "2700" "measurement_deadline = fault_t0 + cap"
has "$TRACE" "fio_wait_segments deadline=${DL}" "fio_wait_segments 收到絕對 deadline"

# 7d) cap / guard 不變條件：pipeline 必須 export，inject 才驗得了
has "$TRACE" "fault_osd_down osd=3 cap=2700 deadline=${DL}" "MEASUREMENT_CAP/DEADLINE 由 pipeline export"
GUARD="$(jget "$B/fault-timeline.json" guard_deadline_secs)"
[ "$GUARD" -ge 3300 ] || fail "guard_deadline 必須 >= cap + 600（got=${GUARD}）"
ok
NOW="$(date +%s)"
[ $(( NOW + GUARD )) -ge $(( DL + 600 )) ] || fail "guard 不變條件：guard 絕不可先於 measurement_deadline+600"
ok

# 7e) 交叉核對必須顯式呼叫（verdict.py schemas --verify）+ finalize
has "$FAKE_VERDICT_LOG" "schemas fault --verify" "**必須顯式呼叫 schemas --verify**（cross-check）"
has "$FAKE_VERDICT_LOG" "--manifest-hash deadbeefcafe0001" "cross-check 帶 manifest hash"
before "coverage_finalize" "inject_cleanup_proof" "cleanup proof 在 coverage 之後"
[ -s "$B/DONE" ] || fail "happy path 應 finalize"
ok
eq "$(jget "$B/censor-status.json" censored)" "False" "未撞 cap → censored=false"
eq "$(jget "$B/censor-status.json" measurement_cap)" "2700" "censor-status 記 per-replicate cap"

# 7f) 出口清乾淨：claim 釋放、taint 計數歸零
[ -d "$RESULTS_DIR/osd-down-4k-mid+balanced/r1/.claim" ] && fail "成功出口應釋放 claim"
ok
eq "$(pipeline_taint_count osd-down-4k-mid+balanced r1)" "0" "成功後 taint 計數歸零"

# ============================================== 8. censored（撞 cap）仍是有效觀測 ==
reset_state
mk_exec "$tmp/ex-cen.json" fault osd-down extreme 4k "osd-down-4k-extreme+balanced"
FAKE_WAIT_RC=124
out="$(pipeline_run_execution "$tmp/ex-cen.json")" || fail "censored 仍應完成（right-censored 是有效資料）"
B2="$(ls -d "$RESULTS_DIR/osd-down-4k-extreme+balanced/r1/attempts/"*)"
eq "$(jget "$B2/censor-status.json" censored)" "True" "撞 cap → censored=true"
eq "$(jget "$B2/censor-status.json" censor_basis)" "recovery_complete" "censor 相對 recovery_complete"
[ -s "$B2/DONE" ] || fail "censored replicate 仍要 finalize"
ok
eq "$out" "pipeline: DONE osd-down-4k-extreme+balanced/r1" "censored 也算完成"
FAKE_WAIT_RC=0

# ================================================ 9. coverage gap → taint（不 finalize）==
reset_state
mk_exec "$tmp/ex-gap.json" fault osd-down mid 4k
FAKE_COV_RC=1
FAKE_WAIT_TICKS=3
out="$(pipeline_run_execution "$tmp/ex-gap.json" 2>/dev/null)"; rc=$?
eq "$rc" "4" "coverage 持續 gap → attempt taint（rc 4）"
case "$out" in "pipeline: TAINT"*) ok ;; *) fail "taint 機器行（got=[$out]）" ;; esac
B3="$(ls -d "$RESULTS_DIR/osd-down-4k-mid+balanced/r1/attempts/"*)"
[ -s "$B3/inject-taint.json" ] || fail "coverage gap 必須標 taint"
ok
[ -e "$B3/DONE" ] && fail "tainted attempt 禁止 finalize"
ok
# 量測仍跑完（保 cluster 安全回收）＋ 全出口清理
has "$TRACE" "fio_stop" "taint 後仍要停 fio（安全回收）"
has "$TRACE" "inject_rollback_all" "taint 後仍要回退注入"
has "$TRACE" "sampler_stop" "taint 後仍要停 sampler"
eq "$(pipeline_taint_count osd-down-4k-mid+balanced r1)" "1" "taint 計入重試預算"
FAKE_COV_RC=0
FAKE_WAIT_TICKS=2

# fio 失聯（fio_wait_segments rc 2）→ taint
reset_state
mk_exec "$tmp/ex-fio.json" fault osd-down mid 4k
FAKE_WAIT_RC=2
rc=0
out="$(pipeline_run_execution "$tmp/ex-fio.json" 2>/dev/null)" || rc=$?
eq "$rc" "4" "fio 失聯 → taint（rc 4）"
has "$TRACE" "fio_smoke_real" "fio 失聯要走 watchdog 的 fio trigger（重做 map + smoke）"
FAKE_WAIT_RC=0

# ================================================ 10. 注入失敗：cleanup stack 全出口 ==
reset_state
mk_exec "$tmp/ex-abort.json" fault osd-down mid 4k
FAKE_INJECT_RC=1
rc=0
out="$(pipeline_run_execution "$tmp/ex-abort.json" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "注入失敗不該回 0"
ok
before "fio_stop" "inject_rollback_all" "cleanup stack LIFO：先停 fio 再回退注入"
before "inject_rollback_all" "sampler_stop" "cleanup stack LIFO：回退注入後才停 sampler"
[ -d "$RESULTS_DIR/osd-down-4k-mid+balanced/r1/.claim" ] && fail "失敗出口也要釋放 claim"
ok
B4="$(ls -d "$RESULTS_DIR/osd-down-4k-mid+balanced/r1/attempts/"*)"
[ -e "$B4/DONE" ] && fail "失敗的 attempt 不得 finalize"
ok
FAKE_INJECT_RC=0

# ==================================================== 11. 穩態：同一狀態機參數化 ==
reset_state
mk_exec "$tmp/ex-steady.json" steady none mid 4k "none-4k-mid+balanced"
out="$(pipeline_run_execution "$tmp/ex-steady.json")" || fail "穩態應成功"
eq "$out" "pipeline: DONE none-4k-mid+balanced/r1" "穩態完成機器行"
before "sampler_start" "fio_start_bg" "穩態同樣 sampler 先行"
before "fio_readiness_barrier" "fio_wait_segments" "穩態也走同一量測窗"
hasnt "$TRACE" "fault_osd_down" "穩態不得注入"
hasnt "$TRACE" "ceph_wait_recovery_complete" "穩態的 stop-condition 不是 recovery_complete"
has "$TRACE" "fio_start_bg mode=steady" "穩態用 steady 模式（單段 300s）"
B5="$(ls -d "$RESULTS_DIR/none-4k-mid+balanced/r1/attempts/"*)"
[ -s "$B5/DONE" ] || fail "穩態應 finalize"
ok
[ -e "$B5/censor-status.json" ] && fail "穩態不該有 censor-status（schema 不要求）"
ok
has "$FAKE_VERDICT_LOG" "schemas steady --verify" "穩態同樣要 cross-check"

# ============================================================ 12. chaos 參數化路徑 ==
reset_state
mk_exec "$tmp/ex-chaos.json" chaos chaos extreme 4k "chaos-4k-extreme+balanced"
out="$(pipeline_run_execution "$tmp/ex-chaos.json")" || fail "chaos 應成功"
eq "$out" "pipeline: DONE chaos-4k-extreme+balanced/r1" "chaos 完成機器行"
before "fio_readiness_barrier" "chaos_run" "chaos 也是 workload 先行"
has "$TRACE" "chaos_run seed=4242 duration=1800" "chaos 參數來自 fault_params"
has "$TRACE" "fio_start_bg mode=segment" "chaos 用 segment 模式與 fio 平行"
has "$FAKE_VERDICT_LOG" "schemas chaos --verify" "chaos 同樣要 cross-check"
B6="$(ls -d "$RESULTS_DIR/chaos-4k-extreme+balanced/r1/attempts/"*)"
[ -s "$B6/DONE" ] || fail "chaos 應 finalize"
ok
[ -s "$B6/cleanup-proof.json" ] || fail "chaos 必須有 cleanup-proof（多重故障全回退證明）"
ok

# ============================================ 13. rack / flapping / node 的分派 ==
reset_state
mk_exec "$tmp/ex-rack.json" fault rack-isolation mid 4k "rack-isolation-4k-mid+balanced"
pipeline_run_execution "$tmp/ex-rack.json" >/dev/null || fail "rack 應成功"
has "$TRACE" "fault_rack_isolate rack=rack1" "rack 故障分派到 rack 狀態機"
has "$TRACE" "fault_rack_heal rack=rack1" "rack 回歸走 rack_heal"
hasnt "$TRACE" "fault_osd_down " "rack 不得誤用 osd-down 狀態機"

reset_state
mk_exec "$tmp/ex-flap.json" fault flapping low 4k "flapping-4k-low+balanced"
pipeline_run_execution "$tmp/ex-flap.json" >/dev/null || fail "flapping 應成功"
has "$TRACE" "fault_flapping osd=3" "flapping 分派到 flapping 狀態機"
hasnt "$TRACE" "ceph_osd_in " "flapping 不 out → 回歸不該 osd in"

reset_state
mk_exec "$tmp/ex-node.json" fault node-isolation mid 4k "node-isolation-4k-mid+balanced"
pipeline_run_execution "$tmp/ex-node.json" >/dev/null || fail "node-isolation 應成功"
has "$TRACE" "fault_node_isolate node=mclock-osd-3" "node 故障分派到 node 狀態機"
has "$TRACE" "fault_node_heal node=mclock-osd-3" "node 回歸走 node_heal"

# ================================================== 14. baseline drift（漂移分級）==
reset_state
mk_exec "$tmp/ex-drift.json" fault osd-down mid 4k
FAKE_BASELINE_LINE="baseline-drift achieved_ratio -22.0"
pipeline_run_execution "$tmp/ex-drift.json" >/dev/null || fail "單次 drift 只記 covariate，不該擋"
eq "$(pipeline_drift_streak)" "1" "單次 drift → streak=1（covariate）"
watchdog_halted && fail "單次 drift 不得停佇列"
ok
# 連續 3 次 → HUMAN gate
for _i in 2 3; do
  rm -rf "$RESULTS_DIR/osd-down-4k-mid+balanced"
  pipeline_run_execution "$tmp/ex-drift.json" >/dev/null 2>&1 || true
done
eq "$(pipeline_drift_streak)" "3" "連續 3 次 drift"
if watchdog_halted; then ok; else fail "連續 3 次 drift 必須停佇列要求 recalibrate 裁決"; fi
FAKE_BASELINE_LINE="baseline-check: OK"

# ==================================== 15. --emit-amend 建議必須轉譯成 manifest amend ==
reset_state
FAKE_NEED_MORE_N="need-more-n: EXTRA c9 1 cov_over=max_stall_seconds"
FAKE_AMEND_LINES='{"key": "c9", "schema_version": 1, "source": "verdict.py cov-upgrade", "type": "extra-replicates", "value": 1}'
out="$(pipeline_apply_amendments c9)" || fail "amend 轉譯應成功"
has "$FAKE_VERDICT_LOG" "need-more-n c9 --emit-amend" "先問 verdict.py 的建議"
has "$FAKE_MANIFEST_LOG" "--type extra-replicates" "建議必須轉譯成 manifest.py amend"
has "$FAKE_MANIFEST_LOG" "--key c9" "amend 帶 key"
has "$FAKE_MANIFEST_LOG" "--value 1" "amend 帶 value"
hasnt "$RESULTS_DIR/schedule-amendments.json" "seq" "pipeline 不得自己 append journal（seq 由 manifest.py 配）"
eq "$out" "amend: APPLIED c9 1" "amend 轉譯機器行"
unset FAKE_AMEND_LINES FAKE_NEED_MORE_N

# ======================================================== 16. 佇列停止後不再開工 ==
reset_state
_pipeline_halt_queue "test"
mk_exec "$tmp/ex-halt.json" fault osd-down mid 4k
rc=0
out="$(pipeline_run_execution "$tmp/ex-halt.json" 2>/dev/null)" || rc=$?
eq "$rc" "3" "佇列已停 → 不得再開新 execution"
hasnt "$TRACE" "ceph_qos_gate" "佇列停止後不該進 preflight"
hasnt "$TRACE" "ceph_set_profile" "佇列停止後不該去動叢集的 profile"

# ================================ 17. Task 0.1：qos gate 仍是 preflight 的唯一判準 ==
# 設定 profile 只是「下指令」，通過與否一律由 gate（八顆同時收斂）判定。
reset_state
mk_exec "$tmp/ex-qosfail.json" fault osd-down mid 4k
FAKE_QOS_RC=1
rc=0
out="$(pipeline_run_execution "$tmp/ex-qosfail.json" 2>/dev/null)" || rc=$?
eq "$rc" "1" "gate 未過 → abort（設定成功不算數）"
eq "$out" "pipeline: ABORT osd-down-4k-mid+balanced/r1 qos-gate" "abort 理由是 qos-gate"
has "$TRACE" "ceph_set_profile balanced" "gate 未過前 profile 已設定過"
hasnt "$TRACE" "sampler_start" "gate 未過不得往下走"
FAKE_QOS_RC=0

# profile 設定失敗 → 不得進 gate（避免拿舊 profile 去撞收斂逾時）
reset_state
mk_exec "$tmp/ex-spfail.json" fault osd-down mid 4k
FAKE_SETPROF_RC=1
rc=0
out="$(pipeline_run_execution "$tmp/ex-spfail.json" 2>/dev/null)" || rc=$?
eq "$rc" "1" "profile 設定失敗 → abort"
eq "$out" "pipeline: ABORT osd-down-4k-mid+balanced/r1 set-profile" "abort 理由是 set-profile"
hasnt "$TRACE" "ceph_qos_gate" "profile 沒設成功就不該進 gate"
FAKE_SETPROF_RC=0

# ============================== 18. Task 0.3：halted 的解除路徑（人工排除後恢復）==
reset_state
W="$(watchdog_state_path)"
_pipeline_py state "$W" bump collector-heartbeat >/dev/null
_pipeline_py state "$W" bump collector-heartbeat >/dev/null
_pipeline_py state "$W" drift-bump >/dev/null
_pipeline_halt_queue "collector-heartbeat 修不好"
if watchdog_halted; then ok; else fail "前置：佇列應為 halted"; fi

# 18a) 理由是必填（不得無聲清除）
_pipeline_py state "$W" unhalt >/dev/null 2>&1 && fail "unhalt 缺理由應失敗"
ok
_pipeline_py state "$W" unhalt "" >/dev/null 2>&1 && fail "unhalt 空理由應失敗"
ok
if watchdog_halted; then ok; else fail "失敗的 unhalt 不得改動狀態"; fi

# 18b) 正常解除：清 halted / halt_reason、**保留** trigger counts、留痕
out="$(_pipeline_py state "$W" unhalt "collector 已人工重啟")" || fail "unhalt 應成功"
ok
eq "$out" "unhalt: OK" "unhalt 機器行"
if watchdog_halted; then fail "unhalt 後 watchdog_halted 必須回 false"; else ok; fi
eq "$(jget "$W" halted)" "False" "halted 已清"
eq "$(jget "$W" halt_reason)" "None" "halt_reason 已清"
eq "$(watchdog_count collector-heartbeat)" "2" "**預設保留 trigger counts**（沒排除的不得歸零）"
eq "$(pipeline_drift_streak)" "1" "預設保留 drift streak"
eq "$(jget "$W" unhalt_reason)" "collector 已人工重啟" "理由留痕"
has "$W" "unhalted_at" "寫入解除時刻"
eq "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["unhalt_log"]))' "$W")" \
  "1" "解除事件進 append-only 留痕清單"

# 18c) --clear-counts：明示才歸零（counts + drift streak 一起）
_pipeline_halt_queue "第二次停"
out="$(_pipeline_py state "$W" unhalt "recalibrate 已完成" --clear-counts)" || fail "unhalt --clear-counts 應成功"
ok
eq "$out" "unhalt: OK cleared-counts" "帶旗標的機器行不同（人看得出做了什麼）"
eq "$(watchdog_count collector-heartbeat)" "0" "--clear-counts 才歸零 trigger counts"
eq "$(pipeline_drift_streak)" "0" "--clear-counts 一併歸零 drift streak"
eq "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["unhalt_log"]))' "$W")" \
  "2" "第二次解除不得覆蓋第一次的留痕"
eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["unhalt_log"][1]["cleared_counts"])' "$W")" \
  "True" "留痕記下是否清了計數"

# 18d) 沒停佇列時解除 → 明示 no-op（不得假裝有做事）
out="$(_pipeline_py state "$W" unhalt "重複解除")" || fail "重複 unhalt 不該報錯"
ok
eq "$out" "unhalt: NOOP" "本來就沒停 → NOOP"
eq "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["unhalt_log"]))' "$W")" \
  "2" "NOOP 不寫留痕"

# 18e) 未停佇列時 --clear-counts 仍要生效：誤報成因修掉後，殘留的 drift_streak
#      會讓下一個訊號立刻再停；否則就只能手改 JSON，而這支工具就是為了取代手改。
_pipeline_py state "$W" drift-bump >/dev/null
_pipeline_py state "$W" drift-bump >/dev/null
eq "$(jget "$W" drift_streak)" "2" "前置：drift_streak 已累積"
out="$(_pipeline_py state "$W" unhalt "成因已修，清計數" --clear-counts)" \
  || fail "未停佇列時的 --clear-counts 應成功"
ok
eq "$out" "unhalt: OK cleared-counts" "--clear-counts 不得回 NOOP"
eq "$(jget "$W" drift_streak)" "0" "drift_streak 必須歸零"

# 18e) pipeline_unhalt：shell 層薄包裝（run/unhalt.sh 用）
_pipeline_halt_queue "第三次停"
out="$(pipeline_unhalt "節點已換掉")" || fail "pipeline_unhalt 應成功"
ok
eq "$out" "unhalt: OK" "pipeline_unhalt 機器行"
if watchdog_halted; then fail "pipeline_unhalt 後應恢復"; else ok; fi
( pipeline_unhalt ) >/dev/null 2>&1 && fail "pipeline_unhalt 缺理由應 die"
ok

# 18g) run/unhalt.sh：run 層薄入口（以子行程真的跑一次）
_pipeline_halt_queue "第四次停"
out="$(bash "$root/run/unhalt.sh" "磁碟已換")" || fail "run/unhalt.sh 應成功"
ok
eq "$out" "unhalt: OK" "run/unhalt.sh 機器行"
if watchdog_halted; then fail "run/unhalt.sh 後應恢復"; else ok; fi
bash "$root/run/unhalt.sh" >/dev/null 2>&1 && fail "run/unhalt.sh 缺理由應非 0"
ok
_pipeline_halt_queue "第五次停"
out="$(bash "$root/run/unhalt.sh" "recalibrate 完成" --clear-counts)" || fail "run/unhalt.sh --clear-counts 應成功"
ok
eq "$out" "unhalt: OK cleared-counts" "run/unhalt.sh 旗標透傳"

# 18f) 解除後佇列真的能再開工（不是只有 JSON 好看）
reset_state
_pipeline_halt_queue "擋住"
mk_exec "$tmp/ex-unhalt.json" fault osd-down mid 4k
rc=0
pipeline_run_execution "$tmp/ex-unhalt.json" >/dev/null 2>&1 || rc=$?
eq "$rc" "3" "解除前佇列仍停"
pipeline_unhalt "已排除" >/dev/null || fail "unhalt 應成功"
reset_trace
out="$(pipeline_run_execution "$tmp/ex-unhalt.json")" || fail "解除後應能開工"
eq "$out" "pipeline: DONE osd-down-4k-mid+balanced/r1" "解除後 execution 正常完成"
has "$TRACE" "ceph_qos_gate" "解除後 preflight 恢復"

printf 'test-pipeline: %d assertions passed\n' "$asserts"
