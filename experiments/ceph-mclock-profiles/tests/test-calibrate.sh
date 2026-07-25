#!/usr/bin/env bash
# Task 12 — run/calibrate.sh：固定順序、reboot canary 的 current-boot 證據、
# capacity 五狀態決策表 + 跨 8 顆 CoV gate、冪等重入（斷點續跑）、失敗即停、
# `--yes-really-inject` gate。
#
# 測試策略
# --------
# source run/calibrate.sh（main 有 BASH_SOURCE guard，不會自動執行），把「lib 級」的
# 遠端動作覆寫成 recorder stub；calibrate **自己實作**的部分（reboot canary、iperf3
# 網路基線）走真的 transport（fake ssh），因此證據紀律（unit-scoped journalctl、
# 不得有 pre-reboot cursor）驗的是真指令。capacity 決策走**真的**
# `ceph_capacity_decide`、canary 證據走**真的** `ceph_verify_no_rebench`、
# manifest 走**真的** `lib/manifest.py`——這三處正是 Task 12 要斷言的規格所在。
#
# 順序斷言以 calibrate 自己寫的 `calibrate/journal.log` 為準（涵蓋 canary 與
# net-baseline 這種沒有 lib 呼叫的步驟），lib 級順序另以 trace 交叉驗證。
#
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
fx="$here/fixtures/ceph"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-calibrate.XXXXXX")"

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
export RESULTS_DIR="$tmp/results"
export INVENTORY_JSON="$fixture"
export POLL_INTERVAL=0.02
export CEPH_FSID="3f2b1c8e-7a41-4c9d-9b0e-2d5a6f7c8b90"
export CEPH_OSD_IDS="0 1 2 3 4 5 6 7"
export CALIB_IPERF_SECS=1
export CALIB_REBOOT_SECS=5
# 假的 verify-provision.sh（含 az preflight）——真檔要 15 台 ssh，這裡只驗「有被呼叫」
export VERIFY_PROVISION_SH="$tmp/fake-verify-provision.sh"
# 下面這些是 stub 的旋鈕，先宣告 export 屬性，之後一般賦值才會傳進 subshell
export FAKE_VP_RC FAKE_RAW_IOPS FAKE_RAW_OUTLIER_NODE FAKE_RAW_OUTLIER_IOPS
export FAKE_PROV_MODE FAKE_APPLY_OSDS_RC FAKE_ENV_CLUSTER_RC
FAKE_VP_RC=0
FAKE_RAW_IOPS=48000
FAKE_RAW_OUTLIER_NODE=""
FAKE_RAW_OUTLIER_IOPS=12000
FAKE_PROV_MODE=mixed
FAKE_APPLY_OSDS_RC=0
FAKE_ENV_CLUSTER_RC=0

cat > "$VERIFY_PROVISION_SH" <<VP
#!/usr/bin/env bash
set -u
printf 'verify-provision %s\n' "\$*" >> "$tmp/trace.log"
printf 'verify-provision: PASS 24/24\n'
exit "\${FAKE_VP_RC:-0}"
VP
chmod +x "$VERIFY_PROVISION_SH"

# ============================================================ 載入 calibrate ==
[ -f "$root/run/calibrate.sh" ] || fail "run/calibrate.sh 不存在（TDD：先紅）"
# shellcheck source=../run/calibrate.sh
. "$root/run/calibrate.sh"
inventory_load "$fixture"

TRACE="$tmp/trace.log"
: > "$TRACE"
t() { printf '%s\n' "$*" >> "$TRACE"; }
idx() { grep -nF -m1 -- "$1" "$TRACE" 2>/dev/null | head -1 | cut -d: -f1; }
before() { # <先> <後> <說明>
  local a b
  a="$(idx "$1")"; b="$(idx "$2")"
  [ -n "$a" ] || fail "$3：trace 缺 [$1]"
  [ -n "$b" ] || fail "$3：trace 缺 [$2]"
  [ "$a" -lt "$b" ] || fail "$3：[$1](#$a) 應早於 [$2](#$b)"
  ok
}

# --- lib 級外部依賴 stub -------------------------------------------------------
env_snapshot_provision() { t "env_snapshot_provision"; printf 'env-snapshot: PASS provision 15\n'; }
env_snapshot_cluster() {
  t "env_snapshot_cluster"
  [ "${FAKE_ENV_CLUSTER_RC:-0}" -eq 0 ] || return "$FAKE_ENV_CLUSTER_RC"
  printf 'env-snapshot: PASS cluster\n'
}
env_snapshot_map() { t "env_snapshot_map"; printf 'env-snapshot: PASS map 4\n'; }

fio_raw_nvme_baseline() {
  local iops="${FAKE_RAW_IOPS:-48000}"
  [ "$1" = "${FAKE_RAW_OUTLIER_NODE:-}" ] && iops="${FAKE_RAW_OUTLIER_IOPS:-12000}"
  t "fio_raw_nvme_baseline $1"
  python3 - "$(raw_nvme_baseline_path)" "$1" "$iops" <<'PY'
import json
import os
import sys

path, node, iops = sys.argv[1], sys.argv[2], float(sys.argv[3])
doc = {}
if os.path.exists(path):
    with open(path) as fh:
        doc = json.load(fh)
doc[node] = {"iops": iops, "bw_bytes": int(iops * 4096)}
d = os.path.dirname(path)
if d and not os.path.isdir(d):
    os.makedirs(d)
with open(path, "w") as fh:
    json.dump(doc, fh, indent=1, sort_keys=True)
PY
  printf 'raw-nvme-baseline: PASS %s %s\n' "$1" "$iops"
}

ceph_gen_campaign_key() { t "ceph_gen_campaign_key"; }
ceph_bootstrap() { t "ceph_bootstrap"; }
ceph_add_hosts() { t "ceph_add_hosts"; }
ceph_apply_mons() { t "ceph_apply_mons"; }
ceph_apply_osds() { t "ceph_apply_osds"; return "${FAKE_APPLY_OSDS_RC:-0}"; }
ceph_verify_versions() { t "ceph_verify_versions"; }
ceph_setup_crush() { t "ceph_setup_crush"; }
ceph_create_pool() { t "ceph_create_pool"; }
ceph_setup_client_auth() { t "ceph_setup_client_auth"; }
ceph_campaign_flags() {
  t "ceph_campaign_flags"
  # 真 lib 在設定當下即註冊對稱 unset；calibrate 成功收尾要把它交棒給 campaign
  cleanup_push "t campaign-unflag"
  printf 'campaign-flags: PASS\n'
}
ceph_wait_final_clean() { t "ceph_wait_final_clean"; }

# capacity：provenance 用 fixture（五狀態決策表的輸入），decide 用**真的**
ceph_capacity_provenance() {
  t "ceph_capacity_provenance"
  python3 - "$(capacity_provenance_path)" "${FAKE_PROV_MODE:-mixed}" <<'PY'
import json
import os
import sys

out, mode = sys.argv[1], sys.argv[2]
# (bench_status, bench_iops)：五狀態決策表的四個「有出口」狀態 + 其餘 accepted
mixed = [
    ("accepted", 45000.0),                   # accepted-consistent（canary 要用 45000）
    ("accepted", 5000.0),                    # accepted-inconsistent（比值出界）
    ("rejected-out-of-range", 128000.0),     # 被 Ceph 丟棄
    ("skipped-existing-nondefault", 45000.0),
    ("accepted", 45500.0),
    ("accepted", 45600.0),
    ("accepted", 45400.0),
    ("accepted", 45700.0),
]
if mode in ("failed", "no-result"):
    rows = [(mode, 0.0)] * 8
else:
    rows = mixed
osds = []
for i, (status, val) in enumerate(rows):
    osds.append({"osd": i, "host": "mclock-osd-%d" % (i + 1),
                 "bench_iops": val, "bench_status": status,
                 "effective_iops": val, "stored_value": val,
                 "raw_fio_iops": None, "log_lines": []})
d = os.path.dirname(out)
if d and not os.path.isdir(d):
    os.makedirs(d)
with open(out, "w") as fh:
    json.dump({"schema_version": 1, "generated_at": "2026-07-25T00:00:00Z",
               "osds": osds}, fh, indent=1)
PY
  printf 'capacity-provenance: PASS 8\n'
}
ceph_lock_capacity() { t "ceph_lock_capacity"; printf 'capacity-lock: PASS 8\n'; }

fio_setup_images() { t "fio_setup_images"; printf 'fio-images: PASS 4\n'; }
fio_map_all() { t "fio_map_all"; printf 'fio-map: PASS 4\n'; }
client_tuning_apply() { t "client_tuning_apply"; printf 'client-tuning: PASS 4\n'; }
client_tuning_verify() { t "client_tuning_verify"; printf 'client-tuning-verify: PASS 4\n'; }
fio_precondition() { t "fio_precondition"; printf 'fio-precondition: PASS 24.1\n'; }
fio_smoke_real() { t "fio_smoke_real $1"; printf 'fio-smoke-real: PASS 60\n'; }
fio_calibrate() { t "fio_calibrate $1"; printf 'fio-calibrate: PASS %s 40000\n' "$1"; }
bg_collect_start() { t "bg_collect_start"; printf 'bg-collect: STARTED 16\n'; }

# --- fake ssh 腳本：只有 calibrate 自己實作的步驟會用到真 transport -------------
expect_ssh() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$FAKE_SSH_SCRIPT"; }
reset_ssh() { : > "$FAKE_SSH_SCRIPT"; : > "$FAKE_SSH_LOG"; rm -rf "$FAKE_SSH_STATE"; }

BOOT_OLD="11111111-2222-3333-4444-555555555555"
BOOT_NEW="99999999-8888-7777-6666-555555555555"
printf '%s\n' "$BOOT_OLD" > "$tmp/boot-old.out"
printf '%s\n' "$BOOT_NEW" > "$tmp/boot-new.out"
printf '4242\n' > "$tmp/bgpid.out"
python3 - "$tmp/iperf.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w") as fh:
    json.dump({"end": {"sum_received": {"bits_per_second": 12400000000.0}}}, fh)
PY

script_happy_path() { # canary + net baseline 的期望 ssh 序列
  local n
  reset_ssh
  # canary：node ↔ osd 對應 → pre boot id → reboot → 等新 boot id
  expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
  expect_ssh 'boot_id' 0 0 "$tmp/boot-old.out"
  expect_ssh 'sudo reboot' 0 0 ""
  expect_ssh 'boot_id' 0 0 "$tmp/boot-new.out"
  # ceph_verify_no_rebench（真的）：新 boot id + unit-scoped journal + effective config
  expect_ssh 'boot_id' 0 0 "$tmp/boot-new.out"
  expect_ssh '@osd.0.service' 0 0 "$fx/journal-boot-nobench.txt"
  expect_ssh 'tell osd.0 config show' 0 0 "$fx/config-show-balanced.json"
  # net baseline：先清殘留 iperf3 server → 起 server → 逐台量 → 收 server
  expect_ssh 'remote_bg_stop' 0 0 ""
  expect_ssh 'remote_bg_start' 0 0 "$tmp/bgpid.out"
  n=0
  while [ "$n" -lt 11 ]; do
    expect_ssh 'iperf3 -c' 0 0 "$tmp/iperf.json"
    n=$((n + 1))
  done
  expect_ssh 'remote_bg_stop' 0 0 ""
}

reset_state() {
  rm -rf "$RESULTS_DIR"
  mkdir -p "$RESULTS_DIR"
  : > "$TRACE"
  inject_cache_reset
  _CLEANUP_STACK=()
}

OUTF="$tmp/stdout.txt"
ERRF="$tmp/stderr.txt"
JOURNAL="$RESULTS_DIR/calibrate/journal.log"
done_seq() { awk '$2 == "DONE" {printf "%s ", $3}' "$JOURNAL"; }
stack_has() { # <子字串>
  local e
  for e in "${_CLEANUP_STACK[@]+"${_CLEANUP_STACK[@]}"}"; do
    case "$e" in *"$1"*) return 0 ;; esac
  done
  return 1
}

# =============================================================== 1) happy path ==
# 在**當前 shell**跑（不用 subshell），才能檢查 cleanup stack 的交棒行為。
reset_state
script_happy_path
calibrate_main --yes-really-inject > "$OUTF" 2> "$ERRF" || fail "happy path 應成功（見 $ERRF）"
ok
eq "$(cat "$OUTF")" "calibrate: PASS" "stdout 只有機器行 calibrate: PASS"

# 1a) 固定順序：journal 的 DONE 序列即規格
eq "$(done_seq)" \
  "verify-provision env-provision raw-nvme-baseline deploy campaign-flags env-cluster capacity reboot-canary net-baseline client-setup fio-smoke-real calibrate-4k calibrate-seq manifest bg-collect " \
  "calibrate 步驟順序"

# 1b) raw NVMe 基線必須在 bootstrap（與任何 OSD 建立）之前
before "fio_raw_nvme_baseline mclock-osd-1" "ceph_bootstrap" "raw 基線在 bootstrap 前"
before "fio_raw_nvme_baseline mclock-osd-8" "ceph_apply_osds" "raw 基線在 OSD 建立前"
eq "$(grep -c 'fio_raw_nvme_baseline' "$TRACE" | tr -d ' ')" "8" "8 台 OSD node 都量 raw 基線"

# 1c) 部署鏈順序（Task 5 序列）
before "ceph_gen_campaign_key" "ceph_bootstrap" "keypair 先於 bootstrap"
before "ceph_add_hosts" "ceph_apply_mons" "host 納管先於 mon"
before "ceph_apply_mons" "ceph_apply_osds" "mon 先於 OSD"
before "ceph_apply_osds" "ceph_verify_versions" "versions gate 在 OSD 之後"
before "ceph_verify_versions" "ceph_setup_crush" "CRUSH 在 versions gate 之後"
before "ceph_setup_crush" "ceph_create_pool" "pool 在 CRUSH 之後"
before "ceph_create_pool" "ceph_setup_client_auth" "client auth+smoke 在 pool 之後"
before "ceph_setup_client_auth" "ceph_campaign_flags" "campaign flags 最後"
before "ceph_campaign_flags" "env_snapshot_cluster" "env-cluster 在 flags 之後"

# 1d) capacity → canary → client → smoke → calibrate → manifest → bg-collect
before "ceph_capacity_provenance" "ceph_lock_capacity" "provenance 先於 lock"
before "fio_map_all" "client_tuning_apply" "tuning 需要已 map 的 rbd 裝置"
before "client_tuning_apply" "env_snapshot_map" "env-map 要收到 tuning 後的值"
before "fio_smoke_real" "fio_calibrate 4k" "smoke-real（parser 校正）在 calibrate 之前"
before "fio_calibrate 4k" "fio_calibrate seq" "兩形態都要校準"
before "fio_calibrate seq" "bg_collect_start" "bg-collector 在校準之後"
# bg_collect_start 是最後一個動作 → 它必定在 `calibrate: PASS` 之前
eq "$(tail -1 "$TRACE")" "bg_collect_start" "bg_collect_start 是收尾（先於 calibrate: PASS）"
has "$RESULTS_DIR/calibrate/manifest.done" "manifest: 63 cells 147 executions" "manifest --assert 已跑"
[ -s "$RESULTS_DIR/manifest.json" ] || fail "manifest.json 未產生"
ok

# 1e) reboot canary：current-boot 合取證據，且**不得**有 pre-reboot cursor / 裸 -b
has "$FAKE_SSH_LOG" "journalctl -b -u ceph-${CEPH_FSID}@osd.0.service" "unit-scoped + current boot"
hasnt "$FAKE_SSH_LOG" "--cursor" "不得使用 pre-reboot cursor"
hasnt "$FAKE_SSH_LOG" "--since" "不得用時間游標取代 current-boot 證據"
eq "$(grep -c 'journalctl -b' "$FAKE_SSH_LOG" | tr -d ' ')" \
   "$(grep -c 'journalctl -b -u ceph-' "$FAKE_SSH_LOG" | tr -d ' ')" \
   "每一次 journalctl -b 都是 unit-scoped（無裸 journalctl -b）"
has "$FAKE_SSH_LOG" "cat /proc/sys/kernel/random/boot_id" "boot ID 取自 /proc（reboot 前後各一）"
has "$FAKE_SSH_LOG" "sudo reboot" "canary 真的重開機"
eq "$(jget "$RESULTS_DIR/no-rebench-osd0.json" boot_id_changed)" "True" "證據：boot ID 已變更"
eq "$(jget "$RESULTS_DIR/no-rebench-osd0.json" positive_control)" "True" "證據：positive control（H-013）"

# 1f) capacity 五狀態決策表（真 ceph_capacity_decide 的輸出）
lock="$RESULTS_DIR/capacity-lock.json"
eq "$(jget "$lock" osds.0.decision)" "accepted-consistent" "狀態 1：bench 採用且比值合理"
eq "$(jget "$lock" osds.0.locked_value)" "45000" "狀態 1 鎖 bench 值"
eq "$(jget "$lock" osds.1.decision)" "accepted-inconsistent" "狀態 2：比值出界"
eq "$(jget "$lock" osds.1.locked_source)" "fio-derived" "狀態 2 改用 raw fio"
eq "$(jget "$lock" osds.2.decision)" "rejected-out-of-range" "狀態 3：被 Ceph 丟棄"
eq "$(jget "$lock" osds.2.locked_source)" "fio-derived" "狀態 3 改用 raw fio"
eq "$(jget "$lock" osds.3.decision)" "skipped-existing-nondefault" "狀態 4：沿用既有值"
eq "$(jget "$lock" osds.3.locked_source)" "stored" "狀態 4 鎖 stored"

# 1g) 網路基線落檔
[ -s "$RESULTS_DIR/env/net-baseline.json" ] || fail "net-baseline.json 未產生"
ok
eq "$(jget "$RESULTS_DIR/env/net-baseline.json" server)" "mclock-osd-1" "iperf3 server 記錄"
eq "$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(len(d["nodes"]))' "$RESULTS_DIR/env/net-baseline.json")" "11" "11 台對 server 量測"

# 1h) campaign flags 交棒：成功收尾不得在 exit 時 unset（campaign 還要用）
stack_has "campaign-unflag" && fail "成功收尾不該留下 campaign flags 的 unset（要交棒給 campaign）"
ok
# 1i) 模擬正常離開的 EXIT trap：flags 不回退、marker 保留
cleanup_run
hasnt "$TRACE" "campaign-unflag" "成功離開時不得 unset campaign flags"
[ -f "$RESULTS_DIR/calibrate/campaign-flags.done" ] \
  || fail "成功離開不得清掉 campaign-flags marker"
ok

# ==================================================== 2) 冪等重入（斷點續跑）==
# 同一個 results/ 再跑一次：所有步驟都該跳過（連 ssh 都不該打）
: > "$TRACE"
reset_ssh
inject_cache_reset
calibrate_main --yes-really-inject > "$OUTF" 2> "$ERRF" || fail "重入應成功"
ok
eq "$(cat "$OUTF")" "calibrate: PASS" "重入仍印 calibrate: PASS"
eq "$(wc -l < "$TRACE" | tr -d ' ')" "0" "重入不重跑任何步驟"
eq "$(wc -l < "$FAKE_SSH_LOG" | tr -d ' ')" "0" "重入不打任何 ssh"
eq "$(awk '$2 == "SKIP" {n++} END {print n + 0}' "$JOURNAL")" "15" "15 個步驟都記為 SKIP"

# ================================ 3) raw 基線的順序不變條件（deploy 後不得重跑）==
# 已經有 OSD 了還想重打 raw device = 毀 BlueStore；即使人工 --redo 也要擋。
: > "$TRACE"
( calibrate_main --yes-really-inject --redo raw-nvme-baseline ) > "$OUTF" 2> "$ERRF" \
  && fail "deploy 已完成時 --redo raw-nvme-baseline 應 die"
ok
hasnt "$TRACE" "fio_raw_nvme_baseline" "被擋下就不得真的去打 raw device"
has "$ERRF" "raw" "die 訊息要指出 raw 基線的順序不變條件"

# ============================================== 4) 失敗即停 + 之後從斷點續跑 ==
reset_state
reset_ssh
FAKE_APPLY_OSDS_RC=1
( calibrate_main --yes-really-inject ) > "$OUTF" 2> "$ERRF" && fail "部署失敗應非 0 離開"
ok
hasnt "$OUTF" "calibrate: PASS" "失敗不得印 PASS"
has "$TRACE" "ceph_apply_osds" "失敗發生在 OSD 步驟"
hasnt "$TRACE" "ceph_verify_versions" "失敗後不得往前走"
hasnt "$TRACE" "ceph_capacity_provenance" "失敗後不得往前走（capacity）"
[ -f "$RESULTS_DIR/calibrate/deploy.done" ] && fail "失敗的步驟不得留下 done marker"
ok
[ -f "$RESULTS_DIR/calibrate/raw-nvme-baseline.done" ] || fail "先前成功的步驟要留 marker"
ok

# 修好之後續跑：不重跑 raw 基線，但重跑整條部署鏈（每步自己冪等）
FAKE_APPLY_OSDS_RC=0
: > "$TRACE"
script_happy_path
inject_cache_reset
_CLEANUP_STACK=()
calibrate_main --yes-really-inject > "$OUTF" 2> "$ERRF" || fail "續跑應成功（見 $ERRF）"
ok
eq "$(cat "$OUTF")" "calibrate: PASS" "續跑印 calibrate: PASS"
hasnt "$TRACE" "fio_raw_nvme_baseline" "續跑不重打 raw device"
has "$TRACE" "ceph_bootstrap" "未完成的 deploy 步驟整段重跑（lib 各自冪等）"
eq "$(awk '$2 == "DONE" && $3 == "raw-nvme-baseline" {n++} END {print n + 0}' "$JOURNAL")" \
  "1" "raw 基線只做過一次"

# ================================================ 5) capacity failed → 停在原地 ==
reset_state
reset_ssh
FAKE_PROV_MODE=failed
( calibrate_main --yes-really-inject ) > "$OUTF" 2> "$ERRF" && fail "capacity failed 應 die"
ok
has "$ERRF" "capacity-decide: HUMAN-NEEDED" "五狀態決策表：failed/no-result 必須 HUMAN-NEEDED"
hasnt "$TRACE" "ceph_lock_capacity" "決策未過不得 lock"
hasnt "$JOURNAL" "DONE capacity" "capacity 步驟不得標 DONE"
hasnt "$FAKE_SSH_LOG" "sudo reboot" "決策未過不得進 reboot canary"

# 5b) no-result 與 failed 同一個出口：不得自動選值
reset_state
reset_ssh
FAKE_PROV_MODE=no-result
( calibrate_main --yes-really-inject ) > "$OUTF" 2> "$ERRF" && fail "capacity no-result 應 die"
ok
has "$ERRF" "capacity-decide: HUMAN-NEEDED" "五狀態決策表：no-result 也是 HUMAN-NEEDED"
hasnt "$TRACE" "ceph_lock_capacity" "no-result 不得 lock"
FAKE_PROV_MODE=mixed

# ======================================== 6) 跨 8 顆 CoV gate（異質 NVMe 防線）==
reset_state
reset_ssh
FAKE_RAW_OUTLIER_NODE="mclock-osd-8"
( calibrate_main --yes-really-inject ) > "$OUTF" 2> "$ERRF" && fail "CoV 超標應 die"
ok
has "$ERRF" "capacity-dispersion-high" "CoV > 20% 要指名 capacity-dispersion-high"
hasnt "$TRACE" "ceph_lock_capacity" "dispersion 超標不得 lock"
[ -f "$RESULTS_DIR/capacity-lock.json" ] && fail "dispersion 超標不得寫出 lock 檔"
ok
hasnt "$FAKE_SSH_LOG" "sudo reboot" "dispersion 超標不得進 reboot canary"
FAKE_RAW_OUTLIER_NODE=""

# ======================================================= 7) 注入 gate 與 flags ==
reset_state
reset_ssh
( calibrate_main ) > "$OUTF" 2> "$ERRF" && fail "缺 --yes-really-inject 應 die"
ok
has "$ERRF" "--yes-really-inject" "die 訊息要指名旗標"
eq "$(wc -l < "$TRACE" | tr -d ' ')" "0" "沒過 gate 就不得有任何動作"

# 8) 未知旗標要擋（避免打錯字被靜默忽略）
( calibrate_main --yes-really-inject --bogus ) > "$OUTF" 2> "$ERRF" \
  && fail "未知旗標應 die"
ok

# =========================== 9) campaign flags 回退時 marker 要對稱清除（續跑正確性）==
# 失敗/中斷路徑的 EXIT trap 會 unset flags；若 marker 還在，續跑就會跳過這一步，
# 整個 campaign 會在沒有 noscrub / balancer off 的情況下跑。
reset_state
_CLEANUP_STACK=()
calib_campaign_flags > /dev/null || fail "calib_campaign_flags 應成功"
ok
mkdir -p "$RESULTS_DIR/calibrate"
: > "$RESULTS_DIR/calibrate/campaign-flags.done"   # 模擬 calib_step 寫下的 marker
[ -f "$RESULTS_DIR/calibrate/campaign-flags.done" ] || fail "marker 應建立成功"
ok
stack_has "campaign-unflag" || fail "flags 的對稱 unset 應在 cleanup stack 上"
ok
cleanup_run                                        # 模擬失敗/中斷路徑的 exit
[ -f "$RESULTS_DIR/calibrate/campaign-flags.done" ] \
  && fail "回退 campaign flags 時要一併清掉 marker（否則續跑會誤判已設定）"
ok

rm -rf "$tmp"
printf 'test-calibrate: %d asserts passed\n' "$asserts"
