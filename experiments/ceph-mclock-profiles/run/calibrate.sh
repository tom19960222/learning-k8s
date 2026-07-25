#!/usr/bin/env bash
# ceph-mclock-profiles — campaign 前置校準（Task 12）。
# bash 3.2 相容；stdout 只放機器要抓的那行（`calibrate: PASS`），log/progress 一律 stderr。
#
#   用法：run/calibrate.sh --yes-really-inject [--inventory <path>] [--redo <step>]
#
# 這支腳本是 campaign 的**唯一前置**：跑完之後 steady/faults/chaos 才有
# calibration.json（壓力等級與參考 p99）、capacity-lock.json（鎖定的 mClock capacity）、
# manifest.json（63 cells / 147 executions）與活著的 campaign 級 collector。
#
# 固定順序（plan Task 12；順序本身就是規格，tests/test-calibrate.sh 逐項斷言）
# ---------------------------------------------------------------------------
#   verify-provision（含 az preflight）
#   → env_snapshot_provision
#   → **raw NVMe fio ×8（必須在 bootstrap 之前）**——OSD 建好後再直打 raw device 會毀
#     掉 BlueStore；除了本檔的順序不變條件，fio_raw_nvme_baseline 自己還有 RAWGUARD
#   → 部署鏈（keypair → bootstrap → host add/check → mon quorum=3 → OSD ×8 →
#     versions gate → CRUSH → pool → client auth + smoke）
#   → campaign flags → env_snapshot_cluster
#   → capacity provenance + decide（五狀態決策表 + 跨 8 顆 CoV gate）+ lock
#   → **reboot canary**（ceph_verify_no_rebench 的 current-boot 合取證據）
#   → network baseline（iperf3）
#   → images + map + client tuning + env_snapshot_map + precondition
#   → **fio_smoke_real（parser 對真輸出的一次性校正）**
#   → fio_calibrate ×2 形態 → manifest generate --assert
#   → **bg_collect_start**（campaign 級收集；所有 execution preflight 的
#     `bg-collector alive` 由此保證，all.sh 收尾對稱 stop、reconcile 負責 resume 重啟）
#   → 機器行 `calibrate: PASS`
#
# 冪等 / 斷點續跑
# --------------
#   每個步驟成功後寫 `results/calibrate/<step>.done`（內容 = 該步驟的機器行），
#   重入時直接跳過；任一步失敗即 die，**停在原地不前進**，修好後重跑會從斷點續跑
#   （未完成的步驟整段重跑——各 lib 函式自己都是冪等的）。
#   `--redo <step>` 可人工清掉單一步驟的 marker；但 raw NVMe 基線在 deploy 完成後
#   一律拒絕重跑（毀 BlueStore 的不可逆操作）。
#
# 例外：campaign flags 的交棒
# -------------------------
#   `ceph_campaign_flags` 在設定當下即註冊對稱 unset（失敗/中斷路徑會回退）。但
#   calibrate **成功**收尾代表把 campaign 級狀態交棒給 run 佇列，此時那幾筆 unset
#   必須從 cleanup stack 移除，否則 calibrate 一離開 noscrub/balancer 就被還原了。
# shellcheck source-path=SCRIPTDIR
set -u

_CALIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CALIB_ROOT="$(cd "$_CALIB_HERE/.." && pwd)"
# inject.sh 只借用 node ↔ osd 對應（reboot canary 要指名 OSD）；fio/collect 是主要依賴。
# shellcheck source=../lib/inject.sh
. "$_CALIB_ROOT/lib/inject.sh"
# shellcheck source=../lib/fio.sh
. "$_CALIB_ROOT/lib/fio.sh"
# shellcheck source=../lib/collect.sh
. "$_CALIB_ROOT/lib/collect.sh"

VERIFY_PROVISION_SH="${VERIFY_PROVISION_SH:-$_CALIB_ROOT/azure/verify-provision.sh}"
MANIFEST_PY="${MANIFEST_PY:-$MCLOCK_LIB/manifest.py}"
# reboot canary：預設拿第一台 OSD node（一 host 一顆 OSD）
CALIB_CANARY_NODE="${CALIB_CANARY_NODE:-}"
CALIB_REBOOT_SECS="${CALIB_REBOOT_SECS:-900}"
# network baseline（iperf3）：server 固定一台，其餘 node 逐台對打，避免互相干擾
CALIB_IPERF_SERVER="${CALIB_IPERF_SERVER:-}"
CALIB_IPERF_PORT="${CALIB_IPERF_PORT:-5201}"
CALIB_IPERF_SECS="${CALIB_IPERF_SECS:-10}"
CALIB_IPERF_RUNID="${CALIB_IPERF_RUNID:-calib-iperf3}"
# 明顯壞掉的 NIC 才擋（Accelerated Networking 沒開通常掉到 1Gbps 量級以下）；
# 正常 L8s_v3 應有 ~12 Gbps，低於這個門檻但高於地板值只警告並記成 covariate。
CALIB_NET_MIN_GBPS="${CALIB_NET_MIN_GBPS:-1.0}"
CALIB_NET_WARN_GBPS="${CALIB_NET_WARN_GBPS:-5.0}"

# 步驟清單（順序 = 規格）
CALIB_STEPS="verify-provision env-provision raw-nvme-baseline deploy campaign-flags
env-cluster capacity reboot-canary net-baseline client-setup fio-smoke-real
calibrate-4k calibrate-seq manifest bg-collect"

# --- marker / journal ---------------------------------------------------------
# RESULTS_DIR 常在 source 之後才被入口決定，路徑一律呼叫當下才解析。
calib_state_dir() { printf '%s\n' "${CALIBRATE_STATE_DIR:-$RESULTS_DIR/calibrate}"; }
_calib_marker() { printf '%s/%s.done\n' "$(calib_state_dir)" "$1"; }
_calib_journal_path() { printf '%s/journal.log\n' "$(calib_state_dir)"; }

_calib_journal() { # <step> <START|DONE|SKIP|FAIL>
  mkdir -p "$(calib_state_dir)"
  printf '%s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$2" "$1" \
    >> "$(_calib_journal_path)"
}

_calib_valid_step() { # <step>
  local s
  for s in $CALIB_STEPS; do
    [ "$s" = "$1" ] && return 0
  done
  return 1
}

# --- 各步驟 -------------------------------------------------------------------

# verify-provision.sh 內含 campaign 前的 az preflight（watchdog 2b 的救援憑證）。
calib_verify_provision() {
  [ -f "$VERIFY_PROVISION_SH" ] || die "找不到 verify-provision.sh：${VERIFY_PROVISION_SH}"
  bash "$VERIFY_PROVISION_SH" --inventory "$INVENTORY_JSON"
}

calib_env_provision() { env_snapshot_provision; }

# raw NVMe 基線：**只准在 OSD 建立前**（OSD 建好後直打 raw device = 毀 BlueStore）。
# 這裡是順序不變條件（deploy 完成就拒絕），fio_raw_nvme_baseline 內另有 RAWGUARD
# 對裝置本身做 blkid / OSD 目錄偵測——兩道防線都要有，results/ 被清掉時仍擋得住。
calib_raw_nvme_baseline() {
  local node n=0
  if [ -f "$(_calib_marker deploy)" ]; then
    die "拒絕重跑 raw NVMe 基線：deploy 已完成，OSD 建立後直打 raw device 會毀掉 BlueStore"
  fi
  for node in $(inv_names osd); do
    fio_raw_nvme_baseline "$node" || return 1
    n=$((n + 1))
  done
  printf 'raw-nvme-baseline: PASS %s nodes\n' "$n"
}

calib_deploy() {
  ceph_gen_campaign_key || return 1
  ceph_bootstrap || return 1
  ceph_add_hosts || return 1
  ceph_apply_mons || return 1
  ceph_apply_osds || return 1
  ceph_verify_versions || return 1
  ceph_setup_crush || return 1
  ceph_create_pool || return 1
  ceph_setup_client_auth || return 1
  printf 'deploy: PASS\n'
}

# campaign flags：記下 cleanup stack 的區間，成功收尾時交棒（見檔頭說明）。
calib_campaign_flags() {
  local lo
  lo="${#_CLEANUP_STACK[@]}"
  # 失敗/中斷路徑會把 flags 回退掉，marker 必須對稱清除——否則續跑會跳過這一步，
  # 整個 campaign 就在沒有 noscrub / balancer off 的情況下跑（污染所有 cells）。
  cleanup_push "rm -f '$(_calib_marker campaign-flags)'"
  ceph_campaign_flags || return 1
  _CALIB_FLAG_CLEANUP_LO="$lo"
  _CALIB_FLAG_CLEANUP_HI="${#_CLEANUP_STACK[@]}"
}

_calib_handoff_flags() {
  local i n rest
  [ -n "${_CALIB_FLAG_CLEANUP_HI:-}" ] || return 0
  rest=()
  n="${#_CLEANUP_STACK[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$i" -lt "$_CALIB_FLAG_CLEANUP_LO" ] || [ "$i" -ge "$_CALIB_FLAG_CLEANUP_HI" ]; then
      rest[${#rest[@]}]="${_CLEANUP_STACK[$i]}"
    fi
    i=$((i + 1))
  done
  _CLEANUP_STACK=("${rest[@]+"${rest[@]}"}")
  log "campaign flags 交棒給 run 佇列（calibrate 離開時不再 unset）"
}

calib_env_cluster() { env_snapshot_cluster; }

calib_capacity() {
  ceph_capacity_provenance || return 1
  # 五狀態決策表 + 跨 8 顆 CoV gate；failed/no-result 或 dispersion 超標一律 die
  ceph_capacity_decide || return 1
  ceph_lock_capacity || return 1
}

_calib_boot_id() { # <node>
  _node_run "$1" 30 "cat /proc/sys/kernel/random/boot_id" | tr -d ' \r\n'
}

_calib_rebooted() { # <node> <pre-boot-id>：ssh 回來且 boot ID 已變
  local b
  b="$(_calib_boot_id "$1" 2>/dev/null)"
  [ -n "$b" ] || return 1
  [ "$b" != "$2" ]
}

# reboot canary：證明鎖定的 capacity 在重開機後不會被重新 bench 掉。
# 判定一律走 ceph_verify_no_rebench 的 current-boot 合取證據（boot ID 變更 +
# unit-scoped `journalctl -b -u ceph-<fsid>@osd.N` 無 bench log + effective skip +
# 值未變 + positive control）——**不得**用 pre-reboot cursor 或裸 `journalctl -b`。
calib_reboot_canary() {
  local node id pre
  node="${CALIB_CANARY_NODE:-$(inv_names osd | head -1)}"
  [ -n "$node" ] || die "inventory 沒有 OSD node，無法做 reboot canary"
  _inject_tree_load
  id="$(_inject_osd_for_node "$node")"
  pre="$(_calib_boot_id "$node")"
  [ -n "$pre" ] || die "取不到 ${node} 的 pre-reboot boot ID"
  log "reboot canary：${node}（osd.${id}），pre-boot=${pre}"
  _node_run "$node" 30 "sudo reboot" >&2 \
    || log "ssh reboot 未正常回傳（連線被切斷屬預期）——改以 boot ID 判定"
  with_deadline "$CALIB_REBOOT_SECS" _calib_rebooted "$node" "$pre" \
    || die "canary node ${node} 未在 ${CALIB_REBOOT_SECS}s 內以新的 boot ID 回來"
  ceph_wait_final_clean \
    || die "canary node ${node} 回來後 cluster 未回到 final_clean——停在原地（人工確認）"
  ceph_verify_no_rebench "$id" "$node" "$pre" || return 1
}

_calib_net_clients() { # <server>：對 server 打流量的 node（OSD 複寫路徑 + client IO 路徑）
  local n
  { inv_names osd; inv_names client; } | while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$n" = "$1" ] && continue
    printf '%s\n' "$n"
  done
}

_calib_net_record() { # <raw-dir> <outfile> <server>
  python3 - "$1" "$2" "$3" <<'PY'
import json
import os
import sys

raw_dir, out, server = sys.argv[1], sys.argv[2], sys.argv[3]
nodes = {}
worst = None
for name in sorted(os.listdir(raw_dir)):
    if not name.endswith(".json"):
        continue
    node = name[: -len(".json")]
    with open(os.path.join(raw_dir, name)) as fh:
        doc = json.load(fh)
    end = doc.get("end", {})
    sums = end.get("sum_received") or end.get("sum_sent") or {}
    bps = sums.get("bits_per_second")
    if bps is None:
        sys.stderr.write("net-baseline: %s 的 iperf3 輸出沒有 bits_per_second\n" % node)
        raise SystemExit(1)
    gbps = round(float(bps) / 1e9, 3)
    nodes[node] = {"gbps": gbps, "bits_per_second": float(bps)}
    worst = gbps if worst is None else min(worst, gbps)
if worst is None:
    sys.stderr.write("net-baseline: 沒有任何 iperf3 結果\n")
    raise SystemExit(1)
parent = os.path.dirname(out)
if parent and not os.path.isdir(parent):
    os.makedirs(parent)
with open(out, "w") as fh:
    json.dump({"schema_version": 1, "server": server, "port_seconds": None,
               "min_gbps": worst, "nodes": nodes}, fh, indent=1, sort_keys=True)
    fh.write("\n")
sys.stdout.write("%s\n" % worst)
PY
}

calib_net_baseline() {
  local server ip dir node worst
  server="${CALIB_IPERF_SERVER:-$(inv_names osd | head -1)}"
  [ -n "$server" ] || die "inventory 沒有 OSD node，無法做 network baseline"
  ip="$(inv_ip "$server")"
  dir="$(collect_env_dir)/net"
  rm -rf "$dir"
  mkdir -p "$dir"

  # 冪等：registry 是遠端背景 process 的 SoT，先清殘留再起新的 server
  remote_bg_stop "$server" "$CALIB_IPERF_RUNID" >&2 \
    || log "清理殘留 iperf3 server 未回報成功（續行）"
  remote_bg_start "$server" "$CALIB_IPERF_RUNID" \
    "iperf3 -s -p ${CALIB_IPERF_PORT}" >&2 \
    || die "iperf3 server 啟動失敗：${server}"
  cleanup_push "remote_bg_stop ${server} ${CALIB_IPERF_RUNID} >&2 || true"

  while IFS= read -r node; do
    [ -n "$node" ] || continue
    _node_run "$node" "$((CALIB_IPERF_SECS + 60))" \
      "iperf3 -c ${ip} -p ${CALIB_IPERF_PORT} -t ${CALIB_IPERF_SECS} -J" \
      > "${dir}/${node}.json" \
      || die "iperf3 量測失敗：${node} → ${server}"
  done <<< "$(_calib_net_clients "$server")"

  remote_bg_stop "$server" "$CALIB_IPERF_RUNID" >&2 \
    || log "iperf3 server 停止未回報成功（reconcile 會按 registry 收拾）"

  worst="$(_calib_net_record "$dir" "$(collect_env_dir)/net-baseline.json" "$server")" \
    || die "net-baseline 產生失敗"
  awk -v v="$worst" -v f="$CALIB_NET_MIN_GBPS" 'BEGIN { exit !(v + 0 >= f + 0) }' \
    || die "網路基線過低：最慢 ${worst} Gbps < ${CALIB_NET_MIN_GBPS} Gbps（NIC 有問題，不得開跑）"
  awk -v v="$worst" -v w="$CALIB_NET_WARN_GBPS" 'BEGIN { exit !(v + 0 >= w + 0) }' \
    || log "警告：最慢 ${worst} Gbps 低於預期的 ${CALIB_NET_WARN_GBPS} Gbps（Accelerated Networking？）——已記成 covariate"
  printf 'net-baseline: PASS %s %s\n' "$server" "$worst"
}

# images → map → tuning：client_tuning_apply 讀 fio_device()（rbd map 記錄），
# 所以 tuning 必須在 map 之後；env_snapshot_map 則要收 tuning 後的生效值。
calib_client_setup() {
  fio_setup_images || return 1
  fio_map_all || return 1
  client_tuning_apply || return 1
  client_tuning_verify || return 1
  env_snapshot_map || return 1
  fio_precondition || return 1
}

calib_fio_smoke_real() {
  local bundle
  bundle="$RESULTS_DIR/smoke"
  mkdir -p "$bundle"
  fio_smoke_real "$bundle"
}

calib_calibrate_4k() { fio_calibrate 4k; }
calib_calibrate_seq() { fio_calibrate seq; }

calib_manifest() {
  python3 "$MANIFEST_PY" generate \
    --inventory "$INVENTORY_JSON" --results "$RESULTS_DIR" --assert
}

# campaign 級收集在此啟動：之後每個 execution 的 preflight 都要 `bg-collector alive`。
calib_bg_collect() { bg_collect_start; }

_calib_dispatch() { # <step>
  case "$1" in
    verify-provision) calib_verify_provision ;;
    env-provision) calib_env_provision ;;
    raw-nvme-baseline) calib_raw_nvme_baseline ;;
    deploy) calib_deploy ;;
    campaign-flags) calib_campaign_flags ;;
    env-cluster) calib_env_cluster ;;
    capacity) calib_capacity ;;
    reboot-canary) calib_reboot_canary ;;
    net-baseline) calib_net_baseline ;;
    client-setup) calib_client_setup ;;
    fio-smoke-real) calib_fio_smoke_real ;;
    calibrate-4k) calib_calibrate_4k ;;
    calibrate-seq) calib_calibrate_seq ;;
    manifest) calib_manifest ;;
    bg-collect) calib_bg_collect ;;
    *) die "未知步驟：${1}" ;;
  esac
}

# calib_step <step>：冪等執行單一步驟。已完成 → 跳過；失敗 → die（停在原地）。
# 步驟的 stdout（各 lib 的機器行）不外流，收進 marker 檔並轉印到 stderr。
calib_step() {
  local name="$1" marker out rc=0 line
  marker="$(_calib_marker "$name")"
  if [ -f "$marker" ]; then
    _calib_journal "$name" SKIP
    log "calibrate: 跳過已完成的步驟 ${name}"
    return 0
  fi
  _calib_journal "$name" START
  log "calibrate: 步驟 ${name} 開始"
  mkdir -p "$(calib_state_dir)"
  out="$(calib_state_dir)/.${name}.out"
  : > "$out"
  # 這裡只做重導向、不用 $( )：subshell 會吃掉步驟內的 cleanup_push（campaign flags）
  _calib_dispatch "$name" > "$out" || rc=$?
  if [ "$rc" -ne 0 ]; then
    _calib_journal "$name" FAIL
    die "calibrate 步驟失敗：${name}（rc=${rc}）——停在原地，修好後重跑會從此步續跑"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && log "  ${name}: ${line}"
  done < "$out"
  { printf '# %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$name"; cat "$out"; } > "$marker"
  rm -f "$out"
  _calib_journal "$name" DONE
}

calib_usage() {
  cat >&2 <<'USAGE'
用法：run/calibrate.sh --yes-really-inject [--inventory <path>] [--redo <step>]

campaign 前置校準（順序固定，見檔頭）。每步冪等、斷點續跑；任一步失敗即停在原地。
  --yes-really-inject   必填：本腳本會部署 cluster 並重開機一台 node
  --inventory <path>    改用指定的 inventory.json
  --redo <step>         清掉單一步驟的 done marker 後重跑（raw-nvme-baseline 在
                        deploy 完成後一律拒絕——直打 raw device 會毀掉 BlueStore）
stdout 只有機器行 `calibrate: PASS`。
USAGE
}

calibrate_main() {
  local inv="" redo="" s a
  # --help 不做任何事，先於 inject gate 處理（問用法不該被要求帶危險旗標）
  for a in "$@"; do
    case "$a" in -h|--help) calib_usage; return 0 ;; esac
  done
  require_inject_flag "$@"
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes-really-inject) shift ;;
      --inventory)
        [ $# -ge 2 ] || die "--inventory 需要路徑參數"
        inv="$2"; shift 2 ;;
      --redo)
        [ $# -ge 2 ] || die "--redo 需要步驟名稱"
        redo="${redo} $2"; shift 2 ;;
      *) die "未知參數：${1}（用 --help 看用法）" ;;
    esac
  done
  [ -n "$inv" ] && INVENTORY_JSON="$inv"
  inventory_load "$INVENTORY_JSON"
  mkdir -p "$(calib_state_dir)"

  for s in $redo; do
    _calib_valid_step "$s" || die "--redo 的步驟名稱無效：${s}"
    rm -f "$(_calib_marker "$s")"
    log "calibrate: 已清除 ${s} 的 done marker（將重跑）"
  done

  for s in $CALIB_STEPS; do
    calib_step "$s"
  done

  _calib_handoff_flags
  printf 'calibrate: PASS\n'
}

# 被 source（測試）時不自動執行。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  calibrate_main "$@"
fi
