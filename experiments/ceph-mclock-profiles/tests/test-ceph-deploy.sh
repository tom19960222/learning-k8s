#!/usr/bin/env bash
# Task 5 — lib/ceph.sh 部署鏈（campaign key → bootstrap → hosts → mon → OSD →
# versions gate → CRUSH → pool → client auth + smoke → campaign flags）。
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
fx="$here/fixtures/ceph"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-ceph-deploy.XXXXXX")"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"; ok; }
has() { grep -qF -- "$2" "$1" || fail "$3：log 未含 [$2]"; ok; }
hasnt() { grep -qF -- "$2" "$1" && fail "$3：log 不該含 [$2]"; ok; }
count_of() { grep -cF -- "$2" "$1" | tr -d ' '; }
line_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
last_line_of() { grep -nF -- "$2" "$1" | tail -1 | cut -d: -f1; }

export PATH="$here/fakes:$PATH"
export FAKE_SSH_SCRIPT="$tmp/ssh.script"
export FAKE_SSH_LOG="$tmp/ssh.log"
export FAKE_SSH_STATE="$tmp/ssh.state"
export RESULTS_DIR="$tmp/results"
export CAMPAIGN_KEY="$tmp/keys/mclock_campaign"
# 測試不要真的等：輪詢間隔壓到最小
export POLL_INTERVAL=0.05

reset_ssh() { : > "$FAKE_SSH_SCRIPT"; : > "$FAKE_SSH_LOG"; rm -rf "$FAKE_SSH_STATE"; }
expect_ssh() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "$FAKE_SSH_SCRIPT"; }

# shellcheck source=../lib/ceph.sh
. "$root/lib/ceph.sh"
inventory_load "$fixture"
cleanup_push "rm -rf '$tmp'"

# 這些常數在測試裡固定，避免真的去查叢集
export CEPH_FSID="3f2b1c8e-7a41-4c9d-9b0e-2d5a6f7c8b90"
export CEPH_OSD_IDS="0 1 2 3 4 5 6 7"

# ================================================================ ceph_hosts ==
# 1) Ceph host = admin + mon×2 + osd×8 = 11 台（client 不納管）
hosts="$(ceph_hosts)"
eq "$(printf '%s\n' "$hosts" | wc -l | tr -d ' ')" "11" "ceph_hosts 共 11 台"
printf '%s\n' "$hosts" | grep -qx 'mclock-admin' || fail "ceph_hosts 缺 admin"
ok
printf '%s\n' "$hosts" | grep -qx 'mclock-osd-8' || fail "ceph_hosts 缺 osd-8"
ok
printf '%s\n' "$hosts" | grep -q 'client' && fail "ceph_hosts 不該含 fio client"
ok

# ====================================================== ceph_gen_campaign_key ==
# 2) 本機 keygen 冪等（不碰 ssh）
reset_ssh
rm -rf "$tmp/keys"
ceph_keygen_local || fail "ceph_keygen_local 應成功"
ok
[ -s "$CAMPAIGN_KEY" ] || fail "私鑰未產生"
ok
[ -s "${CAMPAIGN_KEY}.pub" ] || fail "公鑰未產生"
ok
eq "$(cat "$FAKE_SSH_STATE/count" 2>/dev/null || printf '0')" "0" \
  "keygen 階段不該有 ssh 呼叫"
sha_before="$(shasum -a 256 "$CAMPAIGN_KEY" | awk '{print $1}')"
ceph_keygen_local || fail "第二次 keygen 應成功（冪等）"
ok
eq "$(shasum -a 256 "$CAMPAIGN_KEY" | awk '{print $1}')" "$sha_before" \
  "keygen 冪等：既有 keypair 不得被覆蓋"

sha_priv="$sha_before"
sha_pub="$(shasum -a 256 "${CAMPAIGN_KEY}.pub" | awk '{print $1}')"
mk_verify_out() { # <owner> <priv-mode> <pub-mode> <sha-priv> <sha-pub> <outfile>
  {
    printf '/home/ikaros/.ssh/mclock_campaign %s %s\n' "$1" "$2"
    printf '/home/ikaros/.ssh/mclock_campaign.pub %s %s\n' "$1" "$3"
    printf '%s  /home/ikaros/.ssh/mclock_campaign\n' "$4"
    printf '%s  /home/ikaros/.ssh/mclock_campaign.pub\n' "$5"
  } > "$6"
}

script_push_ok() { # 11 台 fanout + 寫兩個 key 檔 + 驗證
  local n
  for n in $(seq 1 11); do expect_ssh 'authorized_keys' 0 0 ""; done
  expect_ssh 'mclock_campaign.pub' 0 0 ""
  expect_ssh 'sha256sum' 0 0 "$tmp/verify.out"
}

# 3) fanout 覆蓋 11 台全部 Ceph host（client 一台都不能碰）
reset_ssh
mk_verify_out ikaros 600 644 "$sha_priv" "$sha_pub" "$tmp/verify.out"
script_push_ok
ceph_push_campaign_key || fail "ceph_push_campaign_key 應成功"
ok
eq "$(count_of "$FAKE_SSH_LOG" 'authorized_keys')" "11" "pubkey fanout 覆蓋 11 台"
# admin 走 public IP（node_ssh 的直連路徑），其餘 10 台走 private IP
grep -F 'authorized_keys' "$FAKE_SSH_LOG" | grep -qF "ikaros@20.63.11.5 " \
  || fail "fanout 未覆蓋 admin"
ok
for ip in 10.60.1.11 10.60.1.12 10.60.1.21 10.60.1.22 10.60.1.23 \
          10.60.1.24 10.60.1.25 10.60.1.26 10.60.1.27 10.60.1.28; do
  grep -F 'authorized_keys' "$FAKE_SSH_LOG" | grep -qF "ikaros@${ip}" \
    || fail "fanout 未覆蓋 ${ip}"
done
ok
for ip in 10.60.1.31 10.60.1.32 10.60.1.33 10.60.1.34; do
  grep -F 'authorized_keys' "$FAKE_SSH_LOG" | grep -qF "ikaros@${ip}" \
    && fail "fanout 不該碰 fio client（${ip}）"
done
ok
has "$FAKE_SSH_LOG" "/home/ikaros/.ssh/mclock_campaign.pub" "公鑰檔送到 admin"
has "$FAKE_SSH_LOG" "0600" "私鑰 mode 0600"
has "$FAKE_SSH_LOG" "0644" "公鑰 mode 0644"

# 4) owner / mode / 內容任一不符即 die
reset_ssh
mk_verify_out root 600 644 "$sha_priv" "$sha_pub" "$tmp/verify.out"
script_push_ok
( ceph_push_campaign_key ) >/dev/null 2>&1 && fail "owner 不符應 die"
ok
reset_ssh
mk_verify_out ikaros 644 644 "$sha_priv" "$sha_pub" "$tmp/verify.out"
script_push_ok
( ceph_push_campaign_key ) >/dev/null 2>&1 && fail "私鑰 mode 不符應 die"
ok
reset_ssh
mk_verify_out ikaros 600 644 "0000000000000000000000000000000000000000000000000000000000000000" "$sha_pub" "$tmp/verify.out"
script_push_ok
( ceph_push_campaign_key ) >/dev/null 2>&1 && fail "私鑰內容不一致應 die"
ok
reset_ssh
mk_verify_out ikaros 600 644 "$sha_priv" "1111111111111111111111111111111111111111111111111111111111111111" "$tmp/verify.out"
script_push_ok
( ceph_push_campaign_key ) >/dev/null 2>&1 && fail "公鑰內容不一致應 die"
ok

# ============================================================= ceph_bootstrap ==
# 5) 已 bootstrap → 冪等跳過
reset_ssh
expect_ssh 'ceph.client.admin.keyring' 0 0 ""
ceph_bootstrap || fail "已 bootstrap 應直接成功"
ok
hasnt "$FAKE_SSH_LOG" "cephadm --image" "已 bootstrap 不該再跑一次"

# 6) 未 bootstrap → 完整 argv，--image 必須在 bootstrap 之前
reset_ssh
expect_ssh 'ceph.client.admin.keyring' 1 0 ""
expect_ssh 'cephadm --image' 0 0 ""
ceph_bootstrap || fail "ceph_bootstrap 應成功"
ok
bootline="$(grep -F 'cephadm --image' "$FAKE_SSH_LOG" | head -1)"
case "$bootline" in
  *"cephadm --image quay.io/ceph/ceph:v19.2.2 bootstrap "*) ok ;;
  *) fail "--image 必須在 bootstrap 之前：${bootline}" ;;
esac
for arg in "--mon-ip 10.60.1.10" "--ssh-user ikaros" \
           "--ssh-private-key /home/ikaros/.ssh/mclock_campaign" \
           "--ssh-public-key /home/ikaros/.ssh/mclock_campaign.pub" \
           "--skip-dashboard"; do
  case "$bootline" in
    *"$arg"*) ok ;;
    *) fail "bootstrap argv 缺 ${arg}" ;;
  esac
done

# ============================================================= ceph_add_hosts ==
# 7) 先全部 orch host add，再逐台 cephadm check-host
reset_ssh
expect_ssh 'orch apply mon --unmanaged=true' 0 0 ""
expect_ssh 'orch host ls' 0 0 "$fx/orch-host-ls-empty.json"
for n in mon-1 mon-2 osd-1 osd-2 osd-3 osd-4 osd-5 osd-6 osd-7 osd-8; do
  expect_ssh "orch host add mclock-${n}" 0 0 ""
done
for n in mon-1 mon-2 osd-1 osd-2 osd-3 osd-4 osd-5 osd-6 osd-7 osd-8; do
  expect_ssh "cephadm check-host mclock-${n}" 0 0 ""
done
ceph_add_hosts || fail "ceph_add_hosts 應成功"
ok
eq "$(count_of "$FAKE_SSH_LOG" 'orch host add')" "10" "10 台非 admin host 都要 add"
eq "$(count_of "$FAKE_SSH_LOG" 'cephadm check-host')" "10" "10 台都要 check-host"
has "$FAKE_SSH_LOG" "orch host add mclock-osd-3 10.60.1.23" "host add 帶 private IP"
last_add="$(last_line_of "$FAKE_SSH_LOG" 'orch host add')"
first_check="$(line_of "$FAKE_SSH_LOG" 'cephadm check-host')"
[ "$last_add" -lt "$first_check" ] \
  || fail "順序錯：check-host 必須在全部 host add 之後（add=${last_add} check=${first_check}）"
ok
# 真機踩到：cephadm 在 host add 後會自動鋪 mon（預設 count:5），placement 收斂時留下
# CEPHADM_STRAY_DAEMON，而 final_clean 只允許 noscrub/nodeep-scrub → safety gate 卡死。
first_unmanaged="$(line_of "$FAKE_SSH_LOG" 'orch apply mon --unmanaged=true')"
first_add="$(line_of "$FAKE_SSH_LOG" 'orch host add')"
[ "$first_unmanaged" -lt "$first_add" ] \
  || fail "順序錯：mon 必須先轉 unmanaged 才能 add host（unmanaged=${first_unmanaged} add=${first_add}）"
ok

# 8) 已納管 → 不重複 add，但仍 check-host
reset_ssh
expect_ssh 'orch apply mon --unmanaged=true' 0 0 ""
expect_ssh 'orch host ls' 0 0 "$fx/orch-host-ls-full.json"
for n in mon-1 mon-2 osd-1 osd-2 osd-3 osd-4 osd-5 osd-6 osd-7 osd-8; do
  expect_ssh "cephadm check-host mclock-${n}" 0 0 ""
done
ceph_add_hosts || fail "ceph_add_hosts 冪等呼叫應成功"
ok
eq "$(count_of "$FAKE_SSH_LOG" 'orch host add')" "0" "已納管的 host 不得重複 add"

# ============================================================= ceph_apply_mgrs ==
# 真機踩到：cephadm 預設自己挑兩台鋪 mgr，實測落到 OSD node 上。故障注入要網路隔離
# OSD node，隔到 active mgr 那台就會打掉 mgr → `ceph -s` 輪詢與 sampler 中斷。
reset_ssh
expect_ssh 'orch apply mgr --placement=mclock-admin,mclock-mon-1' 0 0 ""
expect_ssh 'orch ps --daemon-type=mgr' 0 0 "$fx/orch-ps-mgr-ok.json"
ceph_apply_mgrs || fail "ceph_apply_mgrs 應成功"
ok
has "$FAKE_SSH_LOG" "orch apply mgr --placement=mclock-admin,mclock-mon-1" \
  "mgr placement 必須明列非 OSD node"

# mgr 仍落在 OSD node → 必須不收斂（die）
reset_ssh
_saved_mqs="$MON_QUORUM_SECS"
MON_QUORUM_SECS=1
expect_ssh 'orch apply mgr' 0 0 ""
expect_ssh 'orch ps --daemon-type=mgr' 0 0 "$fx/orch-ps-mgr-on-osd.json"
expect_ssh 'orch ps --daemon-type=mgr' 0 0 "$fx/orch-ps-mgr-on-osd.json"
if ( ceph_apply_mgrs ) >/dev/null 2>&1; then fail "mgr 落在 OSD node 上不該通過"; fi
ok
MON_QUORUM_SECS="$_saved_mqs"

# ============================================================= ceph_apply_mons ==
# 9) placement 明列三台 + quorum 恰為那三名
reset_ssh
expect_ssh 'orch apply mon' 0 0 ""
expect_ssh 'quorum_status' 0 0 "$fx/quorum-status.json"
ceph_apply_mons || fail "ceph_apply_mons 應成功"
ok
has "$FAKE_SSH_LOG" "orch apply mon --placement=mclock-admin,mclock-mon-1,mclock-mon-2" \
  "mon placement 明列三台"

# 10) quorum 只有兩名 → 失敗
reset_ssh
expect_ssh 'orch apply mon' 0 0 ""
expect_ssh 'quorum_status' 0 0 "$fx/quorum-status-2.json"
( MON_QUORUM_SECS=0 ceph_apply_mons ) >/dev/null 2>&1 && fail "quorum 不足應失敗"
ok

# ============================================================= ceph_apply_osds ==
# 11) 逐台 daemon add osd <host>:<device>，禁 all-available-devices
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-partial.json"
for n in 5 6 7 8; do
  expect_ssh "orch daemon add osd mclock-osd-${n}:" 0 0 ""
done
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-8up.json"
ceph_apply_osds || fail "ceph_apply_osds 應成功"
ok
eq "$(count_of "$FAKE_SSH_LOG" 'orch daemon add osd')" "4" "已有 OSD 的 host 不重複建立"
has "$FAKE_SSH_LOG" \
  "orch daemon add osd mclock-osd-5:/dev/disk/by-id/nvme-MSFT_NVMe_osd-5" \
  "daemon add 指定 inventory 的 nvme device"
hasnt "$FAKE_SSH_LOG" "all-available-devices" "禁用 all-available-devices"

# 12) 8 顆沒到齊 → 失敗（不得放行）
reset_ssh
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-8up.json"
expect_ssh 'osd tree' 0 0 "$fx/osd-tree-partial.json"
expect_ssh 'osd dump' 0 0 "$fx/osd-dump-8up.json"
( OSD_READY_SECS=0 ceph_apply_osds ) >/dev/null 2>&1 && fail "OSD 未到齊應失敗"
ok

# ========================================================= ceph_verify_versions ==
# 13) 全部 19.2.2 + image 相符 → PASS
reset_ssh
expect_ssh 'ceph versions' 0 0 "$fx/versions-ok.json"
expect_ssh 'orch ps' 0 0 "$fx/orch-ps.json"
ceph_verify_versions || fail "ceph_verify_versions 應成功"
ok

# 14) 混版 → die
reset_ssh
expect_ssh 'ceph versions' 0 0 "$fx/versions-mixed.json"
( ceph_verify_versions ) >/dev/null 2>&1 && fail "混版應 die"
ok

# 15) image 不符 → die
reset_ssh
expect_ssh 'ceph versions' 0 0 "$fx/versions-ok.json"
expect_ssh 'orch ps' 0 0 "$fx/orch-ps-badimage.json"
( ceph_verify_versions ) >/dev/null 2>&1 && fail "image 不符應 die"
ok

# ============================================================= ceph_setup_crush ==
# 16) rack 已存在 + rule 已存在 → 只做冪等 move 與驗證
printf '["replicated_rule","mclock-rack"]\n' > "$tmp/rule-ls.json"
printf '["replicated_rule"]\n' > "$tmp/rule-ls-norule.json"
reset_ssh
expect_ssh 'osd crush tree' 0 0 "$fx/crush-tree.json"
for r in rack1 rack2 rack3 rack4; do
  expect_ssh "osd crush move ${r} root=default" 0 0 ""
done
for n in 1 2 3 4 5 6 7 8; do
  expect_ssh "osd crush move mclock-osd-${n} rack=" 0 0 ""
done
expect_ssh 'osd crush rule ls' 0 0 "$tmp/rule-ls.json"
expect_ssh 'osd crush tree' 0 0 "$fx/crush-tree.json"
ceph_setup_crush || fail "ceph_setup_crush 應成功"
ok
hasnt "$FAKE_SSH_LOG" "add-bucket" "rack 已存在就不再 add-bucket"
hasnt "$FAKE_SSH_LOG" "rule create-replicated" "rule 已存在就不再建立"
has "$FAKE_SSH_LOG" "osd crush move mclock-osd-7 rack=rack4" "host 掛到 inventory 指定的 rack"

# 17) rule 不存在 → 建立 rule（failure domain = rack）
reset_ssh
expect_ssh 'osd crush tree' 0 0 "$fx/crush-tree.json"
for r in rack1 rack2 rack3 rack4; do
  expect_ssh "osd crush move ${r} root=default" 0 0 ""
done
for n in 1 2 3 4 5 6 7 8; do
  expect_ssh "osd crush move mclock-osd-${n} rack=" 0 0 ""
done
expect_ssh 'osd crush rule ls' 0 0 "$tmp/rule-ls-norule.json"
expect_ssh 'rule create-replicated' 0 0 ""
expect_ssh 'osd crush tree' 0 0 "$fx/crush-tree.json"
ceph_setup_crush || fail "ceph_setup_crush（建 rule）應成功"
ok
has "$FAKE_SSH_LOG" "osd crush rule create-replicated mclock-rack default rack" \
  "rule 的 failure domain 是 rack"

# ============================================================== ceph_create_pool ==
printf '["device_health_metrics"]\n' > "$tmp/pool-ls.json"
script_pool_verify() { # <size-fixture>
  expect_ssh 'osd pool get mclock size' 0 0 "$1"
  expect_ssh 'osd pool get mclock pg_num' 0 0 "$fx/pool-get-pgnum.json"
  expect_ssh 'osd pool get mclock crush_rule' 0 0 "$fx/pool-get-rule.json"
  expect_ssh 'osd pool get mclock pg_autoscale_mode' 0 0 "$fx/pool-get-autoscale.json"
}
# 18) 建 pool + size 3 + autoscaler off + rbd pool init
reset_ssh
expect_ssh 'osd pool ls' 0 0 "$tmp/pool-ls.json"
expect_ssh 'osd pool create mclock' 0 0 ""
expect_ssh 'osd pool set mclock size 3' 0 0 ""
expect_ssh 'osd pool set mclock pg_autoscale_mode off' 0 0 ""
expect_ssh 'osd pool application enable mclock rbd' 0 0 ""
expect_ssh 'rbd pool init mclock' 0 0 ""
script_pool_verify "$fx/pool-get-size.json"
ceph_create_pool || fail "ceph_create_pool 應成功"
ok
has "$FAKE_SSH_LOG" "osd pool create mclock 128 128 replicated mclock-rack" "pool 用 mclock-rack rule"
has "$FAKE_SSH_LOG" "rbd pool init mclock" "pool 要 rbd init"

# 19) size 驗不過 → die
reset_ssh
expect_ssh 'osd pool ls' 0 0 "$tmp/pool-ls.json"
expect_ssh 'osd pool create mclock' 0 0 ""
expect_ssh 'osd pool set mclock size 3' 0 0 ""
expect_ssh 'osd pool set mclock pg_autoscale_mode off' 0 0 ""
expect_ssh 'osd pool application enable mclock rbd' 0 0 ""
expect_ssh 'rbd pool init mclock' 0 0 ""
script_pool_verify "$fx/pool-get-size-2.json"
( ceph_create_pool ) >/dev/null 2>&1 && fail "pool size 不符應 die"
ok

# ========================================================= ceph_setup_client_auth ==
printf '[client.mclock-fio]\n\tkey = AQBxxxxxxxxxxxxxxxxxxxxxxxxxxxxx==\n' > "$tmp/keyring.out"
printf '# minimal ceph.conf\n[global]\n\tfsid = %s\n\tmon_host = [v2:10.60.1.10:3300/0]\n' \
  "$CEPH_FSID" > "$tmp/minconf.out"
script_client_ok() {
  local c
  expect_ssh 'auth get-or-create client.mclock-fio' 0 0 "$tmp/keyring.out"
  expect_ssh 'config generate-minimal-conf' 0 0 "$tmp/minconf.out"
  for c in 1 2 3 4; do
    expect_ssh "ceph.client.mclock-fio.keyring" 0 0 ""
    expect_ssh "rbd -p mclock --id mclock-fio create smoke-mclock-client-${c}" 0 0 ""
    printf 'smoke-mclock-client-%s\n' "$c" > "$tmp/ls-${c}.out"
    expect_ssh "rbd -p mclock --id mclock-fio ls" 0 0 "$tmp/ls-${c}.out"
    printf '/dev/rbd%s\n' "$c" > "$tmp/map-${c}.out"
    expect_ssh "rbd -p mclock --id mclock-fio map smoke-mclock-client-${c}" 0 0 "$tmp/map-${c}.out"
    expect_ssh "of=/dev/rbd${c}" 0 0 ""
    expect_ssh "if=/dev/rbd${c}" 0 0 ""
    expect_ssh "rbd -p mclock --id mclock-fio unmap /dev/rbd${c}" 0 0 ""
    expect_ssh "rbd -p mclock --id mclock-fio rm smoke-mclock-client-${c}" 0 0 ""
    : > "$tmp/ls-after-${c}.out"
    expect_ssh "rbd -p mclock --id mclock-fio ls" 0 0 "$tmp/ls-after-${c}.out"
  done
}
# 20) auth + conf 分發 + 拋棄式 smoke image 的 map/讀寫/unmap/rm
reset_ssh
script_client_ok
ceph_setup_client_auth || fail "ceph_setup_client_auth 應成功"
ok
eq "$(count_of "$FAKE_SSH_LOG" 'create smoke-')" "4" "每個 client 一顆拋棄式 smoke image"
eq "$(count_of "$FAKE_SSH_LOG" 'rm smoke-')" "4" "smoke image 用完必須刪除"
eq "$(count_of "$FAKE_SSH_LOG" 'unmap')" "4" "smoke image 用完必須 unmap"
has "$FAKE_SSH_LOG" "oflag=direct" "smoke 寫入走 direct IO"
has "$FAKE_SSH_LOG" "iflag=direct" "smoke 讀取走 direct IO"
hasnt "$FAKE_SSH_LOG" "fio-c1" "正式 fio image 不在部署鏈建立（Task 7 負責）"

# 21) smoke image 刪不掉（ls 仍看得到）→ die
reset_ssh
expect_ssh 'auth get-or-create client.mclock-fio' 0 0 "$tmp/keyring.out"
expect_ssh 'config generate-minimal-conf' 0 0 "$tmp/minconf.out"
expect_ssh "ceph.client.mclock-fio.keyring" 0 0 ""
expect_ssh "rbd -p mclock --id mclock-fio create smoke-mclock-client-1" 0 0 ""
printf 'smoke-mclock-client-1\n' > "$tmp/ls-1.out"
expect_ssh "rbd -p mclock --id mclock-fio ls" 0 0 "$tmp/ls-1.out"
printf '/dev/rbd1\n' > "$tmp/map-1.out"
expect_ssh "rbd -p mclock --id mclock-fio map smoke-mclock-client-1" 0 0 "$tmp/map-1.out"
expect_ssh "of=/dev/rbd1" 0 0 ""
expect_ssh "if=/dev/rbd1" 0 0 ""
expect_ssh "unmap /dev/rbd1" 0 0 ""
expect_ssh "rm smoke-mclock-client-1" 0 0 ""
expect_ssh "rbd -p mclock --id mclock-fio ls" 0 0 "$tmp/ls-1.out"
( ceph_setup_client_auth ) >/dev/null 2>&1 && fail "smoke image 殘留應 die"
ok

# 22) dd 失敗仍必須 unmap + rm（不得留下殘留 map）
reset_ssh
expect_ssh 'auth get-or-create client.mclock-fio' 0 0 "$tmp/keyring.out"
expect_ssh 'config generate-minimal-conf' 0 0 "$tmp/minconf.out"
expect_ssh "ceph.client.mclock-fio.keyring" 0 0 ""
expect_ssh "create smoke-mclock-client-1" 0 0 ""
expect_ssh "rbd -p mclock --id mclock-fio ls" 0 0 "$tmp/ls-1.out"
expect_ssh "map smoke-mclock-client-1" 0 0 "$tmp/map-1.out"
expect_ssh "of=/dev/rbd1" 1 0 ""
expect_ssh "unmap /dev/rbd1" 0 0 ""
expect_ssh "rm smoke-mclock-client-1" 0 0 ""
( ceph_setup_client_auth ) >/dev/null 2>&1 && fail "smoke 寫入失敗應 die"
ok
has "$FAKE_SSH_LOG" "unmap /dev/rbd1" "smoke 失敗路徑仍要 unmap"
has "$FAKE_SSH_LOG" "rm smoke-mclock-client-1" "smoke 失敗路徑仍要刪 image"

# ========================================================== ceph_campaign_flags ==
script_flags() {
  expect_ssh 'osd set noscrub' 0 0 ""
  expect_ssh 'osd set nodeep-scrub' 0 0 ""
  expect_ssh 'balancer off' 0 0 ""
  expect_ssh 'config set mon mon_osd_adjust_heartbeat_grace false' 0 0 ""
  expect_ssh 'config set mon mon_osd_adjust_down_out_interval false' 0 0 ""
}
script_unflags() {
  expect_ssh 'osd unset noscrub' 0 0 ""
  expect_ssh 'osd unset nodeep-scrub' 0 0 ""
  expect_ssh 'balancer on' 0 0 ""
  expect_ssh 'config rm mon mon_osd_adjust_heartbeat_grace' 0 0 ""
  expect_ssh 'config rm mon mon_osd_adjust_down_out_interval' 0 0 ""
  expect_ssh 'config rm osd osd_mclock_profile' 0 0 ""
}
# 23) 兩個 adjust 開關都要關（H-015：只關 heartbeat grace 控制不完全）
reset_ssh
script_flags
script_unflags
ceph_campaign_flags || fail "ceph_campaign_flags 應成功"
ok
has "$FAKE_SSH_LOG" "config set mon mon_osd_adjust_heartbeat_grace false" "關 adaptive heartbeat grace"
has "$FAKE_SSH_LOG" "config set mon mon_osd_adjust_down_out_interval false" "關 adaptive down-out interval"
has "$FAKE_SSH_LOG" "osd set noscrub" "campaign 期間 noscrub"
has "$FAKE_SSH_LOG" "osd set nodeep-scrub" "campaign 期間 nodeep-scrub"
has "$FAKE_SSH_LOG" "balancer off" "campaign 期間 balancer off"
ceph_campaign_unflags || fail "ceph_campaign_unflags 應成功"
ok
has "$FAKE_SSH_LOG" "config rm mon mon_osd_adjust_down_out_interval" "unflags 對稱移除"
# Task 0.1 Step 3 的裁決：profile 由 execution preflight 設定（campaign 級的持續狀態），
# 收尾一併移除——設什麼就回退什麼，teardown 前最後一次 config dump 才乾淨。
has "$FAKE_SSH_LOG" "config rm osd osd_mclock_profile" "unflags 一併移除 osd_mclock_profile"
# 但 flags 階段**不得**先設 profile（校準必須在 balanced 下完成，profile 由 preflight 設）
hasnt "$FAKE_SSH_LOG" "config set osd osd_mclock_profile" "campaign flags 不得自己設 profile"

# 24) 設定當下就註冊對稱 unset：腳本結束時 cleanup stack 一定跑到
reset_ssh
cat > "$tmp/flags-exit.sh" <<EOF
set -u
export CEPH_FSID='${CEPH_FSID}'
export CEPH_OSD_IDS='${CEPH_OSD_IDS}'
. "$root/lib/ceph.sh"
inventory_load "$fixture"
ceph_campaign_flags
exit 0
EOF
script_flags
script_unflags
bash "$tmp/flags-exit.sh" >/dev/null 2>&1 || fail "flags 腳本應正常結束"
ok
has "$FAKE_SSH_LOG" "osd unset noscrub" "cleanup stack 對稱 unset noscrub"
has "$FAKE_SSH_LOG" "osd unset nodeep-scrub" "cleanup stack 對稱 unset nodeep-scrub"
has "$FAKE_SSH_LOG" "config rm mon mon_osd_adjust_heartbeat_grace" "cleanup stack 對稱移除 mon 設定"
has "$FAKE_SSH_LOG" "config rm mon mon_osd_adjust_down_out_interval" "cleanup stack 對稱移除第二個 mon 設定"
has "$FAKE_SSH_LOG" "balancer on" "cleanup stack 還原 balancer"

# 25) 中途 die 也要走 cleanup（abort path 不得留 flags）
reset_ssh
cat > "$tmp/flags-die.sh" <<EOF
set -u
export CEPH_FSID='${CEPH_FSID}'
export CEPH_OSD_IDS='${CEPH_OSD_IDS}'
. "$root/lib/ceph.sh"
inventory_load "$fixture"
ceph_campaign_flags
die "模擬 campaign 中途失敗"
EOF
script_flags
script_unflags
bash "$tmp/flags-die.sh" >/dev/null 2>&1 && fail "die 應回非 0"
ok
has "$FAKE_SSH_LOG" "osd unset noscrub" "abort path 也要 unset flags"

# 收尾：測試 23 在本 shell 的 cleanup stack 留了 5 筆對稱 unset，離場時會執行——
# 先把對應的 ssh 期望排好，避免離場時噴 UNEXPECTED（那不是失敗，但會蓋掉真訊息）。
reset_ssh
script_unflags

printf 'test-ceph-deploy.sh: %d assertions passed\n' "$asserts"
