#!/usr/bin/env bash
# azure/verify-provision.sh — provisioning 驗收（PROVISIONING-REQUIREMENTS.md §9 全覆蓋）。
#
#   用法：azure/verify-provision.sh [--inventory <path>] [--attestation <path>]
#
# 設計：每台 node 只開一次 ssh，跑一支「自述式 probe」（輸出 key=value），bastion 端再
# 逐條判定。這樣 15 台 × 十幾條檢查只花 15 次連線，且失敗時能指名是哪台哪個值。
#
# 輸出紀律：逐條 `PASS/FAIL <id> <desc>` 走 stderr；stdout 只有機器行
#   verify-provision: PASS|FAIL <n>/<total>
# 任一條 FAIL → exit 1（不 skip、不降級——R §9 明文「任一不過退回」）。
#
# attestation 驗「值」不驗「存在」：boolean 必須為期望值、費率 > 0、generated_at < 24h、
# subscription_id 與 bastion `az account show` 相符。此步同時是 campaign 前的 az preflight
# （plan Task 3 / watchdog 2b：`az vm restart` 的登入態 + subscription + RG 權限），
# 也是 campaign 期間唯二 az 依賴的其中一個——這裡全部是唯讀呼叫。
#
# ssh 驗不到的 Azure 控制面事實（accelerated networking / tags / auto-shutdown /
# Spot vs Regular / 費率）沒有 guest 內的可信來源，一律靠 attestation 驗值補強。
# shellcheck source-path=SCRIPTDIR
set -u

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(cd "$_HERE/.." && pwd)"
# shellcheck source=../lib/inventory.sh
. "$_ROOT/lib/inventory.sh"

ATTESTATION_JSON="${ATTESTATION_JSON:-$_ROOT/azure/attestation.json}"
AZ_BIN="${AZ_BIN:-az}"
AZ_RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-ceph-mclock-profiles}"
CEPH_VERSION_EXPECT="${CEPH_VERSION_EXPECT:-19.2.2}"
# R §4/§5：生產是 Ubuntu 22.04 (jammy) + kernel 6.8 (HWE)。實驗用 krbd 打 client IO，
# krbd 行為隨 kernel 版本改變 → lab 與生產 kernel 不一致，結論就無法外推。故這兩條是
# 硬 gate，不是「有就好」。kernel 只比 major.minor 前綴（`6.8.*`）——ABI/patch 號會隨
# 安全更新滾動，要求完整版號一致只會製造假失敗。
OS_VERSION_EXPECT="${OS_VERSION_EXPECT:-22.04}"
KERNEL_VERSION_EXPECT="${KERNEL_VERSION_EXPECT:-6.8}"
# R §5：chrony offset < 100ms
CHRONY_MAX_OFFSET_SEC="${CHRONY_MAX_OFFSET_SEC:-0.1}"
# R §9：同 subnet「< 1ms 量級」——取一個數量級內的上界，避免把正常抖動判成失敗
PING_MAX_MS="${PING_MAX_MS:-2.0}"
# L8s_v3 的 1.92TB NVMe（1.75TiB）；resource disk /dev/sdb 約 80GB，必須被這個區間排除
NVME_MIN_BYTES="${NVME_MIN_BYTES:-1700000000000}"
NVME_MAX_BYTES="${NVME_MAX_BYTES:-2200000000000}"
ATTESTATION_MAX_AGE_H="${ATTESTATION_MAX_AGE_H:-24}"
# probe 內每個外部指令的遠端逾時（夜間卡死無人救，一律有界）
PROBE_CMD_TIMEOUT="${PROBE_CMD_TIMEOUT:-15}"

usage() {
  cat >&2 <<'USAGE'
用法：azure/verify-provision.sh [--inventory <path>] [--attestation <path>]

逐條驗 PROVISIONING-REQUIREMENTS.md §9 的 acceptance checklist；
明細走 stderr，stdout 只有 `verify-provision: PASS|FAIL <n>/<total>`。
任一條 FAIL → exit 1。
USAGE
}

_inv_path="$INVENTORY_JSON"
while [ $# -gt 0 ]; do
  case "$1" in
    --inventory)
      [ $# -ge 2 ] || die "--inventory 需要路徑參數"
      _inv_path="$2"; shift 2 ;;
    --attestation)
      [ $# -ge 2 ] || die "--attestation 需要路徑參數"
      ATTESTATION_JSON="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知參數：$1" ;;
  esac
done

inventory_load "$_inv_path"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mclock-verify-probe.XXXXXX")" || die "無法建立暫存目錄"
cleanup_push "rm -rf '$WORK'"

NODES_ALL="$(inv_names)"
NODES_OSD="$(inv_names osd)"
NODES_MON="$(inv_names mon)"
NODES_CLIENT="$(inv_names client)"

# =============================================================== probe 產生 ==

# `name:ip` 對照（全部 15 台）——probe 用它逐一 getent 驗 /etc/hosts。
# 15 台共用同一份，只算一次（每台重算 = 225 次 inv_ip 子行程）。
HOSTS_PAIRS=""
_build_hosts_pairs() {
  local n out=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    out="${out} ${n}:$(inv_ip "$n")"
  done <<< "$NODES_ALL"
  HOSTS_PAIRS="${out# }"
}

# 非 admin 節點才查 IMDS：admin 本來就該有 public IP。
_probe_public_ip_block() {
  cat <<'BLOCK'
_md="$(t curl -s -m 5 -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface?api-version=2021-02-01" 2>/dev/null)"
if [ -n "$_md" ]; then kv imds ok; else kv imds fail; fi
kv public_ip_count "$(printf '%s' "$_md" | grep -o '"publicIpAddress":"[0-9][^"]*"' | wc -l | tr -d '[:space:]')"
BLOCK
}

# _probe_script <name> <role> <nvme|-> <peer-ip|->
# 首行是自述標記（測試以它比對；真機上只是註解式賦值）。
_probe_script() {
  local name="$1" role="$2" nvme="$3" peer="$4" pairs="$HOSTS_PAIRS"
  cat <<EOF
MCLOCK_PROBE_NODE=${name}
set -u
t() { timeout ${PROBE_CMD_TIMEOUT} "\$@"; }
kv() { printf '%s=%s\n' "\$1" "\$2"; }
have() { if command -v "\$1" >/dev/null 2>&1; then echo ok; else echo missing; fi; }
kv node "${name}"
kv role "${role}"
kv hostname "\$(hostname -s 2>/dev/null || true)"
kv os_version_id "\$(grep -m1 '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d '[:space:]')"
kv kernel_release "\$(uname -r 2>/dev/null | tr -d '[:space:]')"
if t sudo -n true >/dev/null 2>&1; then kv sudo ok; else kv sudo fail; fi
_bad=""
for _e in ${pairs}; do
  _n="\${_e%%:*}"
  _want="\${_e#*:}"
  _got="\$(t getent hosts "\$_n" 2>/dev/null | awk '{print \$1; exit}')"
  [ "\$_got" = "\$_want" ] || _bad="\$_bad \$_n(\${_got:--})"
done
kv hosts_bad "\${_bad# }"
kv timer_apt_daily "\$(systemctl is-enabled apt-daily.timer 2>&1 | tr -d '[:space:]')"
kv timer_apt_daily_upgrade "\$(systemctl is-enabled apt-daily-upgrade.timer 2>&1 | tr -d '[:space:]')"
kv chrony_active "\$(systemctl is-active chrony 2>&1 | tr -d '[:space:]')"
kv chrony_offset "\$(t chronyc tracking 2>/dev/null | awk '/^Last offset/ {print \$4}')"
kv swap_lines "\$(t swapon --show 2>/dev/null | wc -l | tr -d '[:space:]')"
for _c in iostat iperf3 nc fping; do kv "tool_\${_c}" "\$(have "\$_c")"; done
if t sudo -n iptables -L -n >/dev/null 2>&1; then kv tool_iptables ok; else kv tool_iptables missing; fi
kv accel_vf "\$(ls /sys/class/net 2>/dev/null | grep -c '^enP')"
EOF

  case "$role" in
    admin)
      cat <<'BLOCK'
kv cephadm_version "$(t cephadm version 2>/dev/null | head -1)"
kv ceph_version "$(t ceph --version 2>/dev/null | head -1)"
kv podman_version "$(t podman --version 2>/dev/null | head -1)"
BLOCK
      ;;
    mon)
      cat <<'BLOCK'
kv podman_version "$(t podman --version 2>/dev/null | head -1)"
BLOCK
      ;;
    osd)
      cat <<'BLOCK'
kv podman_version "$(t podman --version 2>/dev/null | head -1)"
kv fio_version "$(t fio --version 2>/dev/null | head -1)"
BLOCK
      cat <<EOF
_dev="${nvme}"
kv nvme_dev "\$_dev"
if [ -e "\$_dev" ]; then kv nvme_path ok; else kv nvme_path missing; fi
_real="\$(readlink -f "\$_dev" 2>/dev/null)"
kv nvme_real "\$_real"
kv nvme_size "\$(t lsblk -bndo SIZE "\$_real" 2>/dev/null | tr -d '[:space:]')"
kv nvme_parts "\$(t lsblk -nlo NAME "\$_real" 2>/dev/null | tail -n +2 | wc -l | tr -d '[:space:]')"
kv nvme_fstype "\$(t lsblk -nlo FSTYPE "\$_real" 2>/dev/null | tr -d '[:space:]')"
kv nvme_mount "\$(t lsblk -nlo MOUNTPOINTS "\$_real" 2>/dev/null | tr -d '[:space:]')"
EOF
      ;;
    client)
      cat <<'BLOCK'
kv ceph_version "$(t ceph --version 2>/dev/null | head -1)"
kv fio_version "$(t fio --version 2>/dev/null | head -1)"
if t sudo -n modprobe rbd >/dev/null 2>&1; then kv modprobe_rbd ok; else kv modprobe_rbd fail; fi
BLOCK
      ;;
  esac

  [ "$role" = "admin" ] || _probe_public_ip_block

  if [ "$peer" != "-" ]; then
    cat <<EOF
kv ping_peer "${peer}"
# 量「背靠背」而非「每秒一發」——實測（2026-07-26 真機）兩者差 2–3 倍，且與 CPU C-state
# 無關（兩端各自壓滿 CPU 都不會改善），是收端每封包的中斷聚合／排程喚醒成本，pipeline
# 化之後被攤平。實驗跑的是高 queue depth 連續流量＝pipeline 情境，所以 gate 要量這個；
# 間距版另存 covariate 進 environment snapshot，不當 gate。
kv ping_avg_ms "\$(t sudo -n ping -f -c 100 -W 2 -q ${peer} 2>/dev/null | awk -F/ '/rtt|round-trip/ {print \$5}')"
kv ping_spaced_ms "\$(t ping -c 3 -W 2 -q ${peer} 2>/dev/null | awk -F/ '/rtt|round-trip/ {print \$5}')"
EOF
  fi
}

# osd ↔ client 互 ping（R §9：client/osd 任兩台間 < 1ms 量級）
_peer_ip() { # <role>
  local first
  case "$1" in
    osd)    first="$(printf '%s\n' "$NODES_CLIENT" | head -1)" ;;
    client) first="$(printf '%s\n' "$NODES_OSD" | head -1)" ;;
    *)      printf '%s\n' "-"; return 0 ;;
  esac
  inv_ip "$first"
}

collect_probes() {
  local n role nvme peer rc
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    role="$(inv_role "$n")"
    nvme="-"
    if [ "$role" = "osd" ]; then nvme="$(inv_nvme "$n")"; fi
    peer="$(_peer_ip "$role")"
    rc=0
    # `< /dev/null` 不可省：ssh 未帶 -n 會讀乾 stdin，把下面 `done <<< "$NODES_ALL"`
    # 的 herestring 整個吸走 → 迴圈只跑第一圈，15 台只 probe 到 admin 一台，
    # 其餘 14 台無資料而連帶 18 條檢查假性失敗（真機交付時實際踩到）。
    node_ssh "$n" "$(_probe_script "$n" "$role" "$nvme" "$peer")" \
      > "$WORK/$n.out" 2> "$WORK/$n.err" < /dev/null || rc=$?
    # 自產的 _rc 放最後一行：同名 key 後者覆蓋前者，遠端輸出偽造不了它
    printf '_rc=%s\n' "$rc" >> "$WORK/$n.out"
    _load_kv "_P_${n//[^A-Za-z0-9]/_}__" "$WORK/$n.out"
    if [ "$rc" -ne 0 ]; then
      log "probe 失敗：${n}（rc=${rc}）$(head -1 "$WORK/$n.err" 2>/dev/null)"
    fi
  done <<< "$NODES_ALL"
}

# key=value 檔 → 以 <prefix><key> 命名的 shell 變數（bash 3.2 沒有 associative array）。
# 一台 node 十幾個欄位、15 台 × 十幾條檢查——若每次查值都 fork 一次 grep，整支要跑好幾秒。
_load_kv() { # <prefix> <file>
  local line key
  [ -f "$2" ] || return 0
  while IFS= read -r line; do
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    # 只收合法識別字，避免遠端輸出污染其他變數
    case "$key" in
      ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;;
    esac
    eval "${1}${key}=\"\${line#*=}\""
  done < "$2"
}

# pv <node> <key>：結果放全域 _PV（查無 = 空字串）。零 fork。
_PV=""
pv() {
  local pfx="_P_${1//[^A-Za-z0-9]/_}__"
  eval "_PV=\"\${${pfx}${2}-}\""
}

# ============================================================== 檢查框架 ====

CHECK_TOTAL=0
CHECK_PASSED=0

emit() { # <id> <desc> <bad-list>
  CHECK_TOTAL=$((CHECK_TOTAL + 1))
  if [ -z "$3" ]; then
    CHECK_PASSED=$((CHECK_PASSED + 1))
    printf 'PASS %-22s %s\n' "$1" "$2" >&2
  else
    printf 'FAIL %-22s %s — %s\n' "$1" "$2" "$3" >&2
  fi
}

# 數值比較（bash 3.2 沒有浮點）——空字串一律不通過，不得當成 0。
_lt() { # <value> <limit>
  [ -n "$1" ] || return 1
  awk -v v="$1" -v l="$2" 'BEGIN { exit !(v + 0 < l + 0) }'
}
_abs_lt() {
  [ -n "$1" ] || return 1
  # 先 +0 強制轉數值：chronyc 的 offset 帶正負號（`+0.000012`），別讓它落進字串比較
  awk -v v="$1" -v l="$2" 'BEGIN { v = v + 0; if (v < 0) v = -v; exit !(v < l + 0) }'
}
_in_range() {
  [ -n "$1" ] || return 1
  awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v + 0 >= lo + 0 && v + 0 <= hi + 0) }'
}

# =============================================================== 逐條檢查 ====

check_ssh_and_sudo() {
  local n bad_ssh="" bad_sudo=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" _rc
    [ "$_PV" = "0" ] || bad_ssh="${bad_ssh} ${n}(rc=${_PV:-?})"
    pv "$n" sudo
    [ "$_PV" = "ok" ] || bad_sudo="${bad_sudo} ${n}"
  done <<< "$NODES_ALL"
  emit ssh-reachable "15 台 ssh 可達（14 台經 admin ProxyJump）" "${bad_ssh# }"
  emit passwordless-sudo "sudo -n true 全部成功" "${bad_sudo# }"
}

check_hostname_and_hosts() {
  local n bad_h="" bad_r="" rc
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" hostname
    [ "$_PV" = "$n" ] || bad_h="${bad_h} ${n}(hostname=${_PV:--})"
    pv "$n" _rc; rc="$_PV"
    pv "$n" hosts_bad
    if [ "$rc" != "0" ]; then
      bad_r="${bad_r} ${n}(probe 失敗)"
    elif [ -n "$_PV" ]; then
      bad_r="${bad_r} ${n}[${_PV}]"
    fi
  done <<< "$NODES_ALL"
  emit hostname "主機名與 inventory 相符" "${bad_h# }"
  emit etc-hosts "/etc/hosts 可解出全部 15 台的 private IP" "${bad_r# }"
}

# R §9：OS = Ubuntu 22.04、kernel = 6.8.*（HWE）。兩條都是生產對映的硬需求——jammy 的
# 預設 GA kernel 是 5.15，IaC 若漏裝 `linux-generic-hwe-22.04` 就會拿到它，而 krbd 的
# 行為（sysfs 介面、blk-mq 路徑、congestion 處理）在 5.15 與 6.8 之間有差，量到的數字
# 外推不到生產。不放行、不降級。
check_os_and_kernel() {
  local n bad_os="" bad_kern=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" os_version_id
    [ "$_PV" = "$OS_VERSION_EXPECT" ] || bad_os="${bad_os} ${n}(VERSION_ID=${_PV:--})"
    pv "$n" kernel_release
    # 只比 major.minor 前綴：ABI/patch 號隨安全更新滾動，要求完整一致只會製造假失敗。
    # 前綴後面那個 `.` 是刻意的——沒有它，`6.80.1` 會被誤判成合格。
    case "$_PV" in
      "$KERNEL_VERSION_EXPECT"|"$KERNEL_VERSION_EXPECT".*) ;;
      *) bad_kern="${bad_kern} ${n}(uname -r=${_PV:--})" ;;
    esac
  done <<< "$NODES_ALL"
  emit os-version "15 台 OS = Ubuntu ${OS_VERSION_EXPECT}" "${bad_os# }"
  emit kernel-version \
    "15 台 kernel = ${KERNEL_VERSION_EXPECT}.*（HWE；生產 krbd 對映）" "${bad_kern# }"
}

check_apt_timers() {
  local n bad=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" timer_apt_daily
    case "$_PV" in masked|disabled) ;; *) bad="${bad} ${n}(apt-daily=${_PV:--})" ;; esac
    pv "$n" timer_apt_daily_upgrade
    case "$_PV" in masked|disabled) ;; *) bad="${bad} ${n}(apt-daily-upgrade=${_PV:--})" ;; esac
  done <<< "$NODES_ALL"
  emit apt-timers-masked "apt-daily/-upgrade timer 皆 masked 或 disabled" "${bad# }"
}

check_chrony() {
  local n bad="" act
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" chrony_active; act="$_PV"
    pv "$n" chrony_offset
    if [ "$act" != "active" ]; then
      bad="${bad} ${n}(chronyd=${act:--})"
    elif ! _abs_lt "$_PV" "$CHRONY_MAX_OFFSET_SEC"; then
      bad="${bad} ${n}(offset=${_PV:--}s)"
    fi
  done <<< "$NODES_ALL"
  emit chrony-offset "chronyc tracking 正常且 offset < ${CHRONY_MAX_OFFSET_SEC}s" "${bad# }"
}

check_swap() {
  local n bad=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" swap_lines
    [ "$_PV" = "0" ] || bad="${bad} ${n}(swapon 輸出 ${_PV:--} 行)"
  done <<< "$NODES_ALL"
  emit swap-empty "swapon --show 輸出為空" "${bad# }"
}

check_base_tools() {
  local n c bad=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    for c in iostat iperf3 nc fping iptables; do
      pv "$n" "tool_${c}"
      [ "$_PV" = "ok" ] || bad="${bad} ${n}/${c}"
    done
  done <<< "$NODES_ALL"
  emit base-tools "sysstat/iperf3/netcat/fping/iptables 15 台皆可用" "${bad# }"
}

check_nvme() {
  local n bad_raw="" bad_dev="" size
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" nvme_size; size="$_PV"
    _in_range "$size" "$NVME_MIN_BYTES" "$NVME_MAX_BYTES" \
      || bad_raw="${bad_raw} ${n}(size=${size:--})"
    pv "$n" nvme_parts
    [ "$_PV" = "0" ] || bad_raw="${bad_raw} ${n}(分割數=${_PV:--})"
    pv "$n" nvme_fstype
    [ -z "$_PV" ] || bad_raw="${bad_raw} ${n}(fstype=${_PV})"
    pv "$n" nvme_mount
    [ -z "$_PV" ] || bad_raw="${bad_raw} ${n}(掛載於 ${_PV})"
    # inventory 的 nvme_device 必須存在，且 probe 用的就是 inventory 那條路徑
    pv "$n" nvme_path
    [ "$_PV" = "ok" ] || bad_dev="${bad_dev} ${n}(路徑不存在)"
    pv "$n" nvme_dev
    [ "$_PV" = "$(inv_nvme "$n")" ] || bad_dev="${bad_dev} ${n}(probe 路徑與 inventory 不符)"
    [ -n "$size" ] || bad_dev="${bad_dev} ${n}(lsblk 對不上)"
  done <<< "$NODES_OSD"
  emit nvme-raw "osd NVMe ~1.92TB、無分割/無 fs/未掛載" "${bad_raw# }"
  emit nvme-device-match "inventory nvme_device 存在且與 lsblk 相符" "${bad_dev# }"
}

check_versions() {
  local n bad_fio="" bad_podman="" bad_cfio="" bad_cceph="" bad_rbd="" bad_admin=""

  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" fio_version
    [ -n "$_PV" ] || bad_fio="${bad_fio} ${n}"
  done <<< "$NODES_OSD"
  emit osd-fio "osd-1..8 有 fio（raw NVMe 基線量測要用）" "${bad_fio# }"

  # admin 的 cephadm / ceph 版本必須 pin 在 19.2.2
  pv "$ADMIN_NAME" cephadm_version
  case "$_PV" in *"$CEPH_VERSION_EXPECT"*) ;; *) bad_admin="${bad_admin} cephadm=${_PV:--}" ;; esac
  pv "$ADMIN_NAME" ceph_version
  case "$_PV" in *"$CEPH_VERSION_EXPECT"*) ;; *) bad_admin="${bad_admin} ceph=${_PV:--}" ;; esac
  emit admin-ceph-version "admin 的 cephadm/ceph = ${CEPH_VERSION_EXPECT}" "${bad_admin# }"

  # podman：admin + mon ×2 + osd ×8（cephadm 的 container runtime）
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" podman_version
    [ -n "$_PV" ] || bad_podman="${bad_podman} ${n}"
  done <<< "$(printf '%s\n%s\n%s\n' "$ADMIN_NAME" "$NODES_MON" "$NODES_OSD")"
  emit podman "admin/mon/osd 的 podman 可用" "${bad_podman# }"

  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" ceph_version
    case "$_PV" in *"$CEPH_VERSION_EXPECT"*) ;; *) bad_cceph="${bad_cceph} ${n}(${_PV:--})" ;; esac
    pv "$n" fio_version
    [ -n "$_PV" ] || bad_cfio="${bad_cfio} ${n}"
    pv "$n" modprobe_rbd
    [ "$_PV" = "ok" ] || bad_rbd="${bad_rbd} ${n}"
  done <<< "$NODES_CLIENT"
  emit client-ceph-version "client-1..4 的 ceph = ${CEPH_VERSION_EXPECT}" "${bad_cceph# }"
  emit client-fio "client-1..4 有 fio" "${bad_cfio# }"
  emit client-modprobe-rbd "client-1..4 可 modprobe rbd（krbd 路徑）" "${bad_rbd# }"
}

check_network() {
  local n bad_ping="" bad_pub="" rtt spaced spaced_note=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pv "$n" ping_avg_ms; rtt="$_PV"
    pv "$n" ping_spaced_ms; spaced="$_PV"
    [ -n "$spaced" ] && spaced_note="${spaced_note} ${n}:${spaced}"
    if ! _lt "$rtt" "$PING_MAX_MS"; then
      pv "$n" ping_peer
      bad_ping="${bad_ping} ${n}->${_PV:-?}(${rtt:-無回應})"
    fi
  done <<< "$(printf '%s\n%s\n' "$NODES_OSD" "$NODES_CLIENT")"
  # covariate（非 gate）：每秒一發的 RTT，供 environment snapshot 與報告引用
  log "ping covariate（間距 1s，非 gate）：${spaced_note# }"
  emit intra-subnet-ping "osd/client 互 ping < ${PING_MAX_MS}ms" "${bad_ping# }"

  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$n" = "$ADMIN_NAME" ] && continue
    pv "$n" imds
    if [ "$_PV" != "ok" ]; then
      bad_pub="${bad_pub} ${n}(IMDS 查不到，無法證明)"
    else
      pv "$n" public_ip_count
      [ "$_PV" = "0" ] || bad_pub="${bad_pub} ${n}(有 public IP)"
    fi
  done <<< "$NODES_ALL"
  emit no-public-ip "admin 以外的 VM 無 public IP" "${bad_pub# }"
}

# ========================================================= attestation + az ==

load_attestation() {
  python3 - "$ATTESTATION_JSON" > "$WORK/attestation.kv" <<'PY'
import datetime
import json
import sys

out = {
    "load_error": "",
    "missing": "",
    "bool_bad": "",
    "rate_bad": "",
    "age_hours": "",
    "age_error": "",
    "subscription_id": "",
}

path = sys.argv[1]
doc = None
try:
    with open(path) as fh:
        doc = json.load(fh)
except OSError as exc:
    out["load_error"] = "無法讀取（%s）" % exc
except ValueError as exc:
    out["load_error"] = "JSON 無法解析（%s）" % exc

if doc is not None and not isinstance(doc, dict):
    out["load_error"] = "頂層不是 JSON object"
    doc = None

REQUIRED = [
    "accelerated_networking_all",
    "vm_priority_all",
    "auto_shutdown_none",
    "tags_applied",
    "public_ip_only_admin",
    "hourly_rate_usd",
    "generated_at",
    "subscription_id",
]
BOOL_TRUE = [
    "accelerated_networking_all",
    "auto_shutdown_none",
    "tags_applied",
    "public_ip_only_admin",
]
SKUS = ["L8s_v3", "D4s_v5", "D2s_v5"]

if doc is not None:
    out["missing"] = ",".join(k for k in REQUIRED if k not in doc)

    bad = []
    for key in BOOL_TRUE:
        if key not in doc:
            bad.append("%s=<缺>" % key)
        elif doc[key] is not True:
            bad.append("%s=%s" % (key, json.dumps(doc[key])))
    if "vm_priority_all" not in doc:
        bad.append("vm_priority_all=<缺>")
    elif doc["vm_priority_all"] != "Regular":
        bad.append("vm_priority_all=%s" % json.dumps(doc["vm_priority_all"]))
    out["bool_bad"] = ",".join(bad)

    rates = doc.get("hourly_rate_usd")
    rbad = []
    if "hourly_rate_usd" not in doc:
        rbad.append("hourly_rate_usd=<缺>")
    elif not isinstance(rates, dict):
        rbad.append("hourly_rate_usd 不是 object")
    else:
        for sku in SKUS:
            val = rates.get(sku)
            if isinstance(val, bool) or not isinstance(val, (int, float)):
                rbad.append("%s=%s" % (sku, json.dumps(val)))
            elif val <= 0:
                rbad.append("%s=%s" % (sku, json.dumps(val)))
    out["rate_bad"] = ",".join(rbad)

    stamp = doc.get("generated_at")
    if not isinstance(stamp, str) or not stamp.strip():
        out["age_error"] = "generated_at 缺漏或不是字串"
    else:
        text = stamp.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            when = datetime.datetime.fromisoformat(text)
        except ValueError:
            out["age_error"] = "generated_at 無法解析（%s）" % stamp
        else:
            if when.tzinfo is None:
                when = when.replace(tzinfo=datetime.timezone.utc)
            now = datetime.datetime.now(datetime.timezone.utc)
            age = (now - when).total_seconds() / 3600.0
            if age < -1:
                out["age_error"] = "generated_at 在未來（%.2fh）" % age
            else:
                out["age_hours"] = "%.2f" % age

    sub = doc.get("subscription_id")
    out["subscription_id"] = sub.strip() if isinstance(sub, str) else ""

for key in sorted(out):
    sys.stdout.write("%s=%s\n" % (key, out[key].replace("\n", " ")))
PY
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'load_error=python3 解析 attestation 失敗（rc=%s）\n' "$rc" > "$WORK/attestation.kv"
  fi
  _load_kv "_ATT__" "$WORK/attestation.kv"
}

_AV=""
av() { eval "_AV=\"\${_ATT__${1}-}\""; }

check_attestation() {
  local err missing bool_bad rate_bad age age_err
  av load_error; err="$_AV"
  av missing; missing="$_AV"
  av bool_bad; bool_bad="$_AV"
  av rate_bad; rate_bad="$_AV"
  av age_hours; age="$_AV"
  av age_error; age_err="$_AV"

  local bad=""
  if [ -n "$err" ]; then bad="$err"; elif [ -n "$missing" ]; then bad="缺欄位：${missing}"; fi
  emit attestation-fields "attestation JSON 存在且欄位齊全" "$bad"

  bad=""
  if [ -n "$err" ]; then bad="$err"; elif [ -n "$bool_bad" ]; then bad="$bool_bad"; fi
  emit attestation-booleans \
    "accelerated networking / 無 auto-shutdown / tags / public IP 僅 admin / 非 Spot" "$bad"

  bad=""
  if [ -n "$err" ]; then bad="$err"; elif [ -n "$rate_bad" ]; then bad="$rate_bad"; fi
  emit attestation-rates "hourly_rate_usd 三個 SKU 皆為正數" "$bad"

  bad=""
  if [ -n "$err" ]; then
    bad="$err"
  elif [ -n "$age_err" ]; then
    bad="$age_err"
  elif ! _lt "$age" "$ATTESTATION_MAX_AGE_H"; then
    bad="generated_at 距今 ${age:-?}h（上限 ${ATTESTATION_MAX_AGE_H}h）"
  fi
  emit attestation-freshness "generated_at 距驗收 < ${ATTESTATION_MAX_AGE_H}h" "$bad"
}

AZ_SUB_ID=""
check_az() {
  local rc=0 state bad=""
  "$AZ_BIN" account show -o json > "$WORK/az-account.json" 2> "$WORK/az-account.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad="az account show rc=${rc}（未登入或 az 不可用）"
  else
    state="$(_json_field "$WORK/az-account.json" state)"
    AZ_SUB_ID="$(_json_field "$WORK/az-account.json" id)"
    [ "$state" = "Enabled" ] || bad="subscription state=${state:--}"
    [ -n "$AZ_SUB_ID" ] || bad="${bad} account show 沒有 subscription id"
  fi
  emit az-login "az 登入態正常（watchdog 2b 的 az vm restart 前提）" "${bad# }"

  local att_sub="$1"
  bad=""
  if [ -z "$att_sub" ]; then
    bad="attestation 沒有 subscription_id"
  elif [ -z "$AZ_SUB_ID" ]; then
    bad="az 取不到 subscription id，無法比對"
  elif [ "$att_sub" != "$AZ_SUB_ID" ]; then
    bad="attestation=${att_sub} vs az=${AZ_SUB_ID}"
  fi
  emit az-subscription-match "attestation 的 subscription_id 與 az account show 相符" "$bad"

  rc=0
  bad=""
  "$AZ_BIN" group show --name "$AZ_RESOURCE_GROUP" -o json \
    > "$WORK/az-group.json" 2> "$WORK/az-group.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad="az group show rc=${rc}（RG ${AZ_RESOURCE_GROUP} 不存在或無權限）"
  elif [ "$(_json_field "$WORK/az-group.json" name)" != "$AZ_RESOURCE_GROUP" ]; then
    bad="回傳的 RG 名稱不符"
  fi
  emit az-rg-access "可讀取 RG ${AZ_RESOURCE_GROUP}（救援指令的權限前提）" "$bad"
}

# accelerated networking 只有 attestation 說了算（guest 內沒有權威來源），但 Azure 開了
# AccelNet 之後 guest 會多一張 SR-IOV VF 介面（`enP*`）——拿它當佐證：attestation 說有、
# guest 全數看不到 = 兩邊說法對不上，值得在 campaign 前查清楚。刻意不當 gate：
# VF 可能在 servicing 期間短暫 revoke，誤擋一整晚的 campaign 代價太高。
report_accel_covariate() {
  local n seen=0 total=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    total=$((total + 1))
    pv "$n" accel_vf
    case "$_PV" in ''|0) ;; *) seen=$((seen + 1)) ;; esac
  done <<< "$NODES_ALL"
  log "accelerated networking（guest 佐證，非 gate）：${seen}/${total} 台看得到 SR-IOV VF 介面"
  av bool_bad
  if [ "$seen" -eq 0 ] && [ -z "$_AV" ]; then
    log "警告：attestation 聲明 accelerated networking 全開，但沒有任何一台看得到 VF 介面"
  fi
}

_json_field() { # <file> <top-level-key>
  python3 - "$1" "$2" <<'PY'
import json
import sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(doc, dict):
    sys.exit(0)
val = doc.get(sys.argv[2], "")
sys.stdout.write(val if isinstance(val, str) else json.dumps(val))
sys.stdout.write("\n")
PY
}

# ==================================================================== main ====

log "verify-provision：開始收集 15 台 probe（每台一次 ssh）"
_build_hosts_pairs
collect_probes
load_attestation

check_ssh_and_sudo
check_hostname_and_hosts
check_os_and_kernel
check_apt_timers
check_chrony
check_swap
check_base_tools
check_nvme
check_versions
check_network
check_attestation
av subscription_id
check_az "$_AV"

report_accel_covariate
log "ssh 驗不到的 Azure 控制面事實（accelerated networking / tags / auto-shutdown /"
log "Spot vs Regular / 費率）只能靠 attestation 驗值——上面三條 attestation-* 即是。"

if [ "$CHECK_PASSED" -eq "$CHECK_TOTAL" ]; then
  printf 'verify-provision: PASS %d/%d\n' "$CHECK_PASSED" "$CHECK_TOTAL"
  exit 0
fi
printf 'verify-provision: FAIL %d/%d\n' "$CHECK_PASSED" "$CHECK_TOTAL"
exit 1
