#!/usr/bin/env bash
# Task 3 — azure/verify-provision.sh：PROVISIONING-REQUIREMENTS.md §9 acceptance checklist
# 全覆蓋 + attestation 驗值（非驗存在）+ az preflight。
#
# 測試手法：fake ssh 回放「每台 node 一支 probe」的 key=value 輸出（fixture 檔可即時改寫，
# 因為 fake ssh 是呼叫當下才 cat），fake az 回放 `account show` / `group show`。
# 每個失敗情境只動一個變因，斷言「該條 FAIL、總數少一」——避免整片紅看不出成因。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
script="$root/azure/verify-provision.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-verify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"; ok; }

export PATH="$here/fakes:$PATH"
export FAKE_SSH_SCRIPT="$tmp/ssh.script"
export FAKE_SSH_LOG="$tmp/ssh.log"
export FAKE_SSH_STATE="$tmp/ssh.state"
export FAKE_AZ_SCRIPT="$tmp/az.script"
export FAKE_AZ_LOG="$tmp/az.log"
export FAKE_AZ_STATE="$tmp/az.state"
export INVENTORY_JSON="$fixture"
export ATTESTATION_JSON="$tmp/attestation.json"
export RESULTS_DIR="$tmp/results"
export POLL_INTERVAL=0.1

TOTAL_CHECKS=27
SUB_ID="11111111-2222-3333-4444-555555555555"
NVME_SIZE=1920383410176

node_list() {
  local i
  printf '%s\n' mclock-admin mclock-mon-1 mclock-mon-2
  for i in 1 2 3 4 5 6 7 8; do printf 'mclock-osd-%s\n' "$i"; done
  for i in 1 2 3 4; do printf 'mclock-client-%s\n' "$i"; done
}

# --- probe fixture 產生 -------------------------------------------------------

probe_base() { # <name>
  local n="$1"
  {
    printf 'node=%s\n' "$n"
    printf 'hostname=%s\n' "$n"
    printf 'sudo=ok\n'
    printf 'hosts_bad=\n'
    # 生產對映：Ubuntu 22.04 (jammy) + kernel 6.8 HWE
    printf 'os_version_id=22.04\n'
    printf 'kernel_release=6.8.0-52-generic\n'
    printf 'timer_apt_daily=masked\n'
    printf 'timer_apt_daily_upgrade=masked\n'
    printf 'chrony_active=active\n'
    printf 'chrony_offset=+0.000123456\n'
    printf 'swap_lines=0\n'
    printf 'tool_iostat=ok\n'
    printf 'tool_iperf3=ok\n'
    printf 'tool_nc=ok\n'
    printf 'tool_fping=ok\n'
    printf 'tool_iptables=ok\n'
    printf 'accel_vf=1\n'
  } > "$tmp/probe/$n.txt"
}

probe_no_public_ip() { # <name>
  {
    printf 'imds=ok\n'
    printf 'public_ip_count=0\n'
  } >> "$tmp/probe/$1.txt"
}

setup_probes() {
  local n idx
  rm -rf "$tmp/probe"
  mkdir -p "$tmp/probe"
  while IFS= read -r n; do
    probe_base "$n"
    case "$n" in
      mclock-admin)
        {
          printf 'cephadm_version=cephadm version 19.2.2 (0eceb0d) squid (stable)\n'
          printf 'ceph_version=ceph version 19.2.2 (0eceb0d) squid (stable)\n'
          printf 'podman_version=podman version 4.9.3\n'
        } >> "$tmp/probe/$n.txt"
        ;;
      mclock-mon-*)
        printf 'podman_version=podman version 4.9.3\n' >> "$tmp/probe/$n.txt"
        # 負的 offset 一樣是合格的（chronyc 會帶正負號）——別讓它落進字串比較
        printf 'chrony_offset=-0.000091\n' >> "$tmp/probe/$n.txt"
        probe_no_public_ip "$n"
        ;;
      mclock-osd-*)
        idx="${n##*-}"
        {
          printf 'podman_version=podman version 4.9.3\n'
          printf 'fio_version=fio-3.36\n'
          printf 'nvme_dev=/dev/disk/by-id/nvme-MSFT_NVMe_osd-%s\n' "$idx"
          printf 'nvme_path=ok\n'
          printf 'nvme_real=/dev/nvme0n1\n'
          printf 'nvme_size=%s\n' "$NVME_SIZE"
          printf 'nvme_parts=0\n'
          printf 'nvme_fstype=\n'
          printf 'nvme_mount=\n'
          printf 'ping_peer=10.60.1.31\n'
          printf 'ping_avg_ms=0.421\n'
        } >> "$tmp/probe/$n.txt"
        probe_no_public_ip "$n"
        ;;
      mclock-client-*)
        {
          printf 'ceph_version=ceph version 19.2.2 (0eceb0d) squid (stable)\n'
          printf 'fio_version=fio-3.36\n'
          printf 'modprobe_rbd=ok\n'
          printf 'ping_peer=10.60.1.21\n'
          printf 'ping_avg_ms=0.388\n'
        } >> "$tmp/probe/$n.txt"
        probe_no_public_ip "$n"
        ;;
    esac
  done <<< "$(node_list)"
}

wire_ssh() { # 每台一筆期望，pattern = probe 的自述標記
  local n
  : > "$FAKE_SSH_SCRIPT"
  : > "$FAKE_SSH_LOG"
  rm -rf "$FAKE_SSH_STATE"
  while IFS= read -r n; do
    printf 'MCLOCK_PROBE_NODE=%s|0|0|%s\n' "$n" "$tmp/probe/$n.txt" >> "$FAKE_SSH_SCRIPT"
  done <<< "$(node_list)"
}

set_key() { # <node> <key> <value>
  local f="$tmp/probe/$1.txt"
  grep -v "^$2=" "$f" > "$f.new"
  printf '%s=%s\n' "$2" "$3" >> "$f.new"
  mv "$f.new" "$f"
}

del_key() { # <node> <key>
  local f="$tmp/probe/$1.txt"
  grep -v "^$2=" "$f" > "$f.new"
  mv "$f.new" "$f"
}

# --- attestation / az fixture -------------------------------------------------

write_attestation() { # [generated_at]
  local gen="${1:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
  cat > "$ATTESTATION_JSON" <<JSON
{
  "accelerated_networking_all": true,
  "vm_priority_all": "Regular",
  "auto_shutdown_none": true,
  "tags_applied": true,
  "public_ip_only_admin": true,
  "hourly_rate_usd": {"L8s_v3": 0.832, "D4s_v5": 0.229, "D2s_v5": 0.114},
  "generated_at": "${gen}",
  "subscription_id": "${SUB_ID}"
}
JSON
}

att_patch() { # <python-expr 對 doc 做修改>
  python3 - "$ATTESTATION_JSON" "$1" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path) as fh:
    doc = json.load(fh)
exec(sys.argv[2])  # noqa: S102 — 測試 fixture 專用
with open(path, "w") as fh:
    json.dump(doc, fh)
PY
}

wire_az() { # <account-rc> <group-rc> [account-sub-id]
  local arc="$1" grc="$2" sub="${3:-$SUB_ID}"
  : > "$FAKE_AZ_SCRIPT"
  : > "$FAKE_AZ_LOG"
  rm -rf "$FAKE_AZ_STATE"
  printf '{"id":"%s","name":"mclock-sub","state":"Enabled"}\n' "$sub" > "$tmp/az-account.json"
  printf '{"name":"ceph-mclock-profiles","location":"japanwest"}\n' > "$tmp/az-group.json"
  if [ "$arc" -eq 0 ]; then
    printf 'account show|0|%s\n' "$tmp/az-account.json" >> "$FAKE_AZ_SCRIPT"
  else
    printf 'account show|%s|\n' "$arc" >> "$FAKE_AZ_SCRIPT"
  fi
  if [ "$grc" -eq 0 ]; then
    printf 'group show|0|%s\n' "$tmp/az-group.json" >> "$FAKE_AZ_SCRIPT"
  else
    printf 'group show|%s|\n' "$grc" >> "$FAKE_AZ_SCRIPT"
  fi
}

setup_all() {
  setup_probes
  wire_ssh
  write_attestation
  wire_az 0 0
}

# --- 執行 ---------------------------------------------------------------------

V_OUT=""
V_RC=0
run_v() {
  V_OUT="$(bash "$script" 2>"$tmp/err")"
  V_RC=$?
}

want_line() { # <PASS|FAIL> <passed>
  eq "$V_OUT" "verify-provision: $1 $2/$TOTAL_CHECKS" "機器行（stderr 見 $tmp/err）"
  eq "$(printf '%s\n' "$V_OUT" | wc -l | tr -d ' ')" "1" "stdout 只有一行機器行"
}

want_fail_id() { # <check-id>
  grep -qE "^FAIL[[:space:]]+$1[[:space:]]" "$tmp/err" \
    || fail "stderr 應有 FAIL $1（實際：$(grep -c '^FAIL' "$tmp/err") 條 FAIL）"
  ok
}

want_pass_id() { # <check-id>
  grep -qE "^PASS[[:space:]]+$1[[:space:]]" "$tmp/err" || fail "stderr 應有 PASS $1"
  ok
}

# 每跑一次 verify-provision 就要 15 次 fake ssh + 3 次 python3，成本不低；
# 因此同一批只放「彼此不互相干擾、且對應到不同 check id」的變因，
# 再斷言「恰好這幾條 FAIL、總數少這幾條」——覆蓋度不減，回合數大減。
expect_fails() { # <desc> <check-id...>
  local desc="$1"
  shift
  eq "$V_RC" "1" "${desc}：任一條 FAIL 應 exit 1"
  want_line FAIL "$((TOTAL_CHECKS - $#))"
  local id
  for id in "$@"; do want_fail_id "$id"; done
}

# ============================================================ 1. 全綠基準線 ==
setup_all
run_v
eq "$V_RC" "0" "全綠時 exit 0（stderr 見 $tmp/err）"
want_line PASS "$TOTAL_CHECKS"

# R §9 每一條都要有對應 check id（缺一不可）
for id in ssh-reachable passwordless-sudo hostname etc-hosts os-version kernel-version \
          apt-timers-masked \
          chrony-offset swap-empty base-tools nvme-raw nvme-device-match osd-fio \
          admin-ceph-version podman client-ceph-version client-fio \
          client-modprobe-rbd intra-subnet-ping no-public-ip \
          attestation-fields attestation-booleans attestation-rates \
          attestation-freshness az-login az-subscription-match az-rg-access; do
  want_pass_id "$id"
done

# 15 台各開一次 ssh（一台一支 probe，不做 N×M 次呼叫）
eq "$(cat "$FAKE_SSH_STATE/count")" "15" "每台 node 恰一次 ssh"
grep -qF 'ProxyJump=ikaros@20.63.11.5' "$FAKE_SSH_LOG" || fail "非 admin 應經 admin 跳板"
ok
# probe 必須有界（遠端 timeout 包裝），否則夜間卡死無人救
grep -qF 'timeout ' "$FAKE_SSH_LOG" || fail "probe 內的遠端指令必須包 timeout"
ok
# az 只做唯讀呼叫（campaign 前唯一 az 依賴）
grep -qF 'account show' "$FAKE_AZ_LOG" || fail "az preflight 應查登入態"
ok
grep -qF 'group show' "$FAKE_AZ_LOG" || fail "az preflight 應查 RG 權限"
ok
if grep -qE 'vm (restart|delete)|group delete' "$FAKE_AZ_LOG"; then
  fail "verify-provision 不得做任何 mutating az 呼叫"
fi
ok
# accelerated networking 的 guest 佐證（covariate，不是 gate）
grep -qF '15/15 台看得到 SR-IOV VF' "$tmp/err" || fail "應回報 accelerated networking 佐證"
ok

# --- 遠端 probe 本身的健全性 ---------------------------------------------------
# fake ssh 只比對字串、不會真的執行 probe；probe 若有語法錯誤，要等上真機才會炸。
# 因此直接把送出去的 probe 抽出來做 bash -n + 內容斷言。
probe_of() { # <node>：從 fake ssh 保真的 argv 記錄還原 probe 內容
  local f
  for f in "$FAKE_SSH_STATE"/call.*.args; do
    [ -e "$f" ] || continue
    if grep -qF "MCLOCK_PROBE_NODE=$1" "$f"; then
      sed -n '/MCLOCK_PROBE_NODE=/,$p' "$f" | sed '1s/.*MCLOCK_PROBE_NODE=/MCLOCK_PROBE_NODE=/'
      return 0
    fi
  done
  return 1
}

for probe_node in mclock-admin mclock-mon-1 mclock-osd-3 mclock-client-2; do
  probe="$(probe_of "$probe_node")" || fail "抓不到 ${probe_node} 的 probe"
  printf '%s\n' "$probe" > "$tmp/probe-render.sh"
  bash -n "$tmp/probe-render.sh" || fail "${probe_node} 的 probe 有語法錯誤"
  ok
  grep -qF 'timeout 15 "$@"' "$tmp/probe-render.sh" || fail "${probe_node}：probe 未包 timeout"
  ok
  grep -qF 'mclock-osd-8:10.60.1.28' "$tmp/probe-render.sh" \
    || fail "${probe_node}：probe 應帶全部 15 台的 name:ip 對照"
  ok
  # OS / kernel 是生產對映的硬需求（krbd 行為隨 kernel 變）——15 台都要問，不是抽查
  grep -qF '/etc/os-release' "$tmp/probe-render.sh" \
    || fail "${probe_node}：probe 應讀 /etc/os-release 取 VERSION_ID"
  ok
  grep -qF 'uname -r' "$tmp/probe-render.sh" || fail "${probe_node}：probe 應取 uname -r"
  ok
done

probe_of mclock-osd-3 > "$tmp/probe-osd.sh"
grep -qF '/dev/disk/by-id/nvme-MSFT_NVMe_osd-3' "$tmp/probe-osd.sh" \
  || fail "osd probe 應直接用 inventory 的 nvme_device 路徑"
ok
grep -qF '169.254.169.254' "$tmp/probe-osd.sh" || fail "非 admin 應查 IMDS 確認無 public IP"
ok
probe_of mclock-admin > "$tmp/probe-admin.sh"
if grep -qF '169.254.169.254' "$tmp/probe-admin.sh"; then
  fail "admin 本來就該有 public IP，不必查 IMDS"
fi
ok
grep -qF 'cephadm version' "$tmp/probe-admin.sh" || fail "admin probe 應查 cephadm 版本"
ok
probe_of mclock-client-2 > "$tmp/probe-client.sh"
grep -qF 'modprobe rbd' "$tmp/probe-client.sh" || fail "client probe 應驗 modprobe rbd"
ok

# ================================================== 2. ssh / 主機層失敗路徑 ==
# ssh 不可達：該台的所有依賴資料一併缺 → 多條 FAIL（不得靜默當成 PASS）
setup_all
: > "$FAKE_SSH_SCRIPT"
while IFS= read -r n; do
  if [ "$n" = "mclock-osd-3" ]; then
    printf 'MCLOCK_PROBE_NODE=%s|255|0|\n' "$n" >> "$FAKE_SSH_SCRIPT"
  else
    printf 'MCLOCK_PROBE_NODE=%s|0|0|%s\n' "$n" "$tmp/probe/$n.txt" >> "$FAKE_SSH_SCRIPT"
  fi
done <<< "$(node_list)"
rm -rf "$FAKE_SSH_STATE"
run_v
eq "$V_RC" "1" "ssh 不可達應 exit 1"
want_fail_id "ssh-reachable"
want_fail_id "nvme-raw"
grep -qF 'mclock-osd-3' "$tmp/err" || fail "FAIL 明細應指名出問題的 node"
ok

# 批次 A：R §9 的 OS/套件/網路面，一次一個 node 各壞一項（18 條互不重疊的 check）
setup_all
set_key mclock-osd-5 hostname mclock-osd-6
set_key mclock-mon-2 sudo fail
set_key mclock-client-1 hosts_bad "mclock-osd-8(-)"
set_key mclock-osd-1 timer_apt_daily enabled
set_key mclock-mon-1 chrony_offset "+0.512000"
set_key mclock-client-4 swap_lines 2
set_key mclock-osd-2 tool_fping missing
set_key mclock-osd-4 nvme_parts 1
set_key mclock-osd-7 nvme_path missing
set_key mclock-osd-8 fio_version ""
set_key mclock-admin ceph_version "ceph version 19.2.3 (x) squid (stable)"
set_key mclock-mon-1 podman_version ""
set_key mclock-client-3 ceph_version "ceph version 19.2.3 (x) squid (stable)"
set_key mclock-client-3 fio_version ""
set_key mclock-client-2 modprobe_rbd fail
set_key mclock-osd-1 ping_avg_ms 8.4
set_key mclock-osd-2 public_ip_count 1
att_patch 'doc["accelerated_networking_all"] = False'
run_v
expect_fails "批次 A（每台各壞一項）" \
  hostname passwordless-sudo etc-hosts apt-timers-masked chrony-offset swap-empty \
  base-tools nvme-raw nvme-device-match osd-fio admin-ceph-version podman \
  client-ceph-version client-fio client-modprobe-rbd intra-subnet-ping no-public-ip \
  attestation-booleans

# 批次 B：同幾條 check 的另一種壞法（第一批沒踩到的分支）
setup_all
set_key mclock-osd-3 timer_apt_daily_upgrade enabled
set_key mclock-mon-2 chrony_active inactive
set_key mclock-client-2 tool_nc missing
set_key mclock-osd-6 nvme_size 75161927680
set_key mclock-osd-7 nvme_dev /dev/disk/by-id/nvme-WRONG
set_key mclock-osd-5 imds fail
set_key mclock-client-1 ping_avg_ms ""
set_key mclock-admin cephadm_version "cephadm version 18.2.4 reef (stable)"
att_patch 'doc["hourly_rate_usd"]["L8s_v3"] = 0.0'
run_v
expect_fails "批次 B（另一種壞法）" \
  apt-timers-masked chrony-offset base-tools nvme-raw nvme-device-match \
  no-public-ip intra-subnet-ping admin-ceph-version attestation-rates

# 批次 C：缺值不得被當成合格（空字串 → 0 / 空 fstype 之類的陷阱）
setup_all
set_key mclock-mon-1 chrony_offset ""
set_key mclock-admin tool_iptables missing
set_key mclock-osd-4 nvme_fstype ext4
att_patch 'doc["vm_priority_all"] = "Spot"'
att_patch 'doc["generated_at"] = "2020-01-01T00:00:00Z"'
run_v
expect_fails "批次 C（缺值/過期）" \
  chrony-offset base-tools nvme-raw attestation-booleans attestation-freshness

# 批次 D：掛載中的 NVMe、負向大 offset、auto-shutdown、未來時戳、字串費率
setup_all
set_key mclock-osd-4 nvme_mount /mnt/data
set_key mclock-client-2 chrony_offset "-0.400000"
att_patch 'doc["auto_shutdown_none"] = False'
att_patch 'doc["generated_at"] = "2099-01-01T00:00:00Z"'
att_patch 'doc["hourly_rate_usd"]["D2s_v5"] = "0.114"'
run_v
expect_fails "批次 D（掛載/負向 offset/未來時戳/字串費率）" \
  nvme-raw chrony-offset attestation-booleans attestation-freshness attestation-rates

# 批次 E：tags 未套用 + 時戳無法解析
setup_all
att_patch 'doc["tags_applied"] = False'
att_patch 'doc["generated_at"] = "上週三"'
run_v
expect_fails "批次 E（tags/時戳格式）" attestation-booleans attestation-freshness

# 批次 F：OS/kernel 對不上生產（krbd 行為隨 kernel 變 → 結論無法外推，硬 FAIL）
# 5.15 是 jammy 預設 GA kernel，也就是「IaC 忘了裝 HWE」時最可能拿到的東西。
setup_all
set_key mclock-osd-2 os_version_id 24.04
set_key mclock-client-3 kernel_release 5.15.0-91-generic
run_v
expect_fails "批次 F（24.04 / 5.15 GA kernel）" os-version kernel-version
grep -qE '^FAIL[[:space:]]+os-version.*mclock-osd-2' "$tmp/err" \
  || fail "os-version FAIL 明細應指名 mclock-osd-2"
ok
grep -qE '^FAIL[[:space:]]+kernel-version.*mclock-client-3' "$tmp/err" \
  || fail "kernel-version FAIL 明細應指名 mclock-client-3"
ok

# 批次 G：probe 拿不到值（缺 VERSION_ID / uname -r 失敗）不得被當成合格
setup_all
del_key mclock-mon-1 os_version_id
del_key mclock-osd-5 kernel_release
run_v
expect_fails "批次 G（OS/kernel 缺值）" os-version kernel-version
grep -qE '^FAIL[[:space:]]+os-version.*mclock-mon-1' "$tmp/err" \
  || fail "缺 VERSION_ID 應指名 mclock-mon-1"
ok
grep -qE '^FAIL[[:space:]]+kernel-version.*mclock-osd-5' "$tmp/err" \
  || fail "缺 uname -r 應指名 mclock-osd-5"
ok

# 6.8 的完整版號不必一致（只比 major.minor 前綴），但 6.80 這種相近字串不得誤判為通過
setup_all
set_key mclock-osd-1 kernel_release 6.8.0-79-generic
set_key mclock-osd-2 kernel_release 6.80.1-1-generic
run_v
expect_fails "kernel 前綴比對（6.8.0-79 過、6.80.1 不過）" kernel-version
grep -qE '^FAIL[[:space:]]+kernel-version.*mclock-osd-2' "$tmp/err" \
  || fail "6.80.1 應被判為不符 6.8.*"
ok
if grep -qE '^FAIL[[:space:]]+kernel-version.*mclock-osd-1' "$tmp/err"; then
  fail "6.8.0-79-generic 是合格 kernel，不該被列為失敗"
fi
ok

# OS_VERSION_EXPECT / KERNEL_VERSION_EXPECT 可覆蓋（預設 22.04 / 6.8）
setup_all
n=""
while IFS= read -r n; do
  set_key "$n" os_version_id 24.04
  set_key "$n" kernel_release 6.11.0-9-generic
done <<< "$(node_list)"
V_OUT="$(OS_VERSION_EXPECT=24.04 KERNEL_VERSION_EXPECT=6.11 bash "$script" 2>"$tmp/err")"
V_RC=$?
eq "$V_RC" "0" "覆蓋期望值後應全綠（stderr 見 $tmp/err）"
want_line PASS "$TOTAL_CHECKS"

# accelerated networking：attestation 說全開、guest 一台 VF 都看不到 → 出警告但不 gate
# （VF 可能在 servicing 期間短暫 revoke，誤擋一整晚 campaign 的代價太高）
setup_all
n=""
while IFS= read -r n; do set_key "$n" accel_vf 0; done <<< "$(node_list)"
run_v
eq "$V_RC" "0" "VF 佐證對不上不得擋住整個驗收"
want_line PASS "$TOTAL_CHECKS"
grep -qF '沒有任何一台看得到 VF 介面' "$tmp/err" || fail "兩邊說法對不上時應出警告"
ok

# boolean 欄位缺漏：既是缺欄位、也不得讓 boolean 檢查假通過
setup_all
att_patch 'doc.pop("public_ip_only_admin")'
run_v
eq "$V_RC" "1" "缺 boolean 欄位應 exit 1"
want_line FAIL "$((TOTAL_CHECKS - 2))"
want_fail_id "attestation-fields"
want_fail_id "attestation-booleans"

# 缺費率欄位：fields + rates 同時 FAIL
setup_all
att_patch 'doc.pop("hourly_rate_usd")'
run_v
want_line FAIL "$((TOTAL_CHECKS - 2))"
want_fail_id "attestation-fields"
want_fail_id "attestation-rates"

# attestation 檔完全不存在 → 五條 attestation/subscription 相關全 FAIL（不得 skip）
setup_all
rm -f "$ATTESTATION_JSON"
run_v
eq "$V_RC" "1" "attestation 缺檔應 exit 1"
want_line FAIL "$((TOTAL_CHECKS - 5))"
want_fail_id "attestation-fields"
want_fail_id "attestation-booleans"
want_fail_id "attestation-rates"
want_fail_id "attestation-freshness"
want_fail_id "az-subscription-match"

# attestation 不是合法 JSON
setup_all
printf 'not json at all\n' > "$ATTESTATION_JSON"
run_v
eq "$V_RC" "1" "attestation JSON 壞掉應 exit 1"
want_fail_id "attestation-fields"

# ======================================================== 6. az preflight ==
# 未登入：登入態 FAIL + subscription 比對 FAIL（watchdog 2b 的救援憑證等於沒有）
setup_all
wire_az 1 0
run_v
eq "$V_RC" "1" "az 未登入應 exit 1"
want_fail_id "az-login"
want_fail_id "az-subscription-match"

# subscription 不一致：attestation 出具的是另一個 subscription
setup_all
wire_az 0 0 "99999999-8888-7777-6666-555555555555"
run_v
eq "$V_RC" "1" "subscription 不一致應 exit 1"
want_line FAIL "$((TOTAL_CHECKS - 1))"
want_fail_id "az-subscription-match"
want_pass_id "az-login"

# RG 權限不足（watchdog 2b 的 az vm restart 會失敗）
setup_all
wire_az 0 3
run_v
eq "$V_RC" "1" "RG 無權限應 exit 1"
want_line FAIL "$((TOTAL_CHECKS - 1))"
want_fail_id "az-rg-access"

# az 指令根本不存在
setup_all
export AZ_BIN=/nonexistent/az
run_v
unset AZ_BIN
eq "$V_RC" "1" "az 不存在應 exit 1"
want_fail_id "az-login"

# ============================================================ 7. 介面契約 ==
# inventory 壞掉 → die（不得回 PASS）
setup_all
printf '{"admin_public_ip":"1.2.3.4","nodes":[]}\n' > "$tmp/bad-inventory.json"
V_OUT="$(INVENTORY_JSON="$tmp/bad-inventory.json" bash "$script" 2>/dev/null)" && \
  fail "inventory 結構不符應 die"
ok
eq "$V_OUT" "" "die 路徑不得吐機器行"

# --attestation / --inventory 旗標可覆蓋
setup_all
V_OUT="$(bash "$script" --inventory "$fixture" --attestation "$ATTESTATION_JSON" 2>/dev/null)"
V_RC=$?
eq "$V_RC" "0" "旗標形式應等價"
want_line PASS "$TOTAL_CHECKS"

# 未知旗標 → die
setup_all
if bash "$script" --nope >/dev/null 2>&1; then fail "未知旗標應 die"; fi
ok

printf 'test-verify-provision.sh: %d assertions passed\n' "$asserts"
