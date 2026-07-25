#!/usr/bin/env bash
# Task 2 — lib/inventory.sh：解析、驗證、getter、ADMIN_* export。
# 每個 assertion 失敗即 exit 1；最後一行印通過數（stdout 機器行）。
# shellcheck source-path=SCRIPTDIR
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fixture="$here/fixtures/inventory.json"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/mclock-inv.XXXXXX")"

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { asserts=$((asserts + 1)); }
eq() { # eq <got> <want> <desc>
  [ "$1" = "$2" ] || fail "$3（got=[$1] want=[$2]）"
  ok
}

# shellcheck source=../lib/inventory.sh
. "$root/lib/inventory.sh"
cleanup_push "rm -rf '$tmp'"

# mk_variant <out> <python-mutation>：以 fixture 為底做結構破壞
mk_variant() {
  python3 - "$fixture" "$1" "$2" <<'PY'
import json, sys
src, out, code = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))
exec(code)
json.dump(d, open(out, 'w'))
PY
}

# 期望 inventory_load 失敗，且 stderr 含關鍵字
expect_die() { # expect_die <file> <keyword> <desc>
  local msg rc
  msg="$( ( inventory_load "$1" ) 2>&1 1>/dev/null )" && rc=0 || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "$3：inventory_load 應該失敗但成功了"
  case "$msg" in
    *"$2"*) ok ;;
    *) fail "$3：錯誤訊息未提及 [$2]（got=[$msg]）" ;;
  esac
}

# --- 1. 正常載入 -------------------------------------------------------------
# 先在 subshell 驗 stdout 純淨（command substitution 會吃掉 export，所以之後再載入一次）
out="$(inventory_load "$fixture")"
eq "$out" "" "inventory_load 不得污染 stdout"
inventory_load "$fixture"

eq "$ADMIN_PUBLIC_IP" "20.63.11.5" "ADMIN_PUBLIC_IP"
eq "$ADMIN_PRIVATE_IP" "10.60.1.10" "ADMIN_PRIVATE_IP（v4.2/O-F3：不可為空）"
eq "$ADMIN_NAME" "mclock-admin" "ADMIN_NAME"

# export 檢查：子行程要看得到（隔離規則 -s/-d 依賴它）
child="$(bash -c 'printf %s "${ADMIN_PRIVATE_IP:-UNSET}"')"
eq "$child" "10.60.1.10" "ADMIN_PRIVATE_IP 必須 export"
child="$(bash -c 'printf %s "${ADMIN_PUBLIC_IP:-UNSET}"')"
eq "$child" "20.63.11.5" "ADMIN_PUBLIC_IP 必須 export"

# --- 2. inv_names ------------------------------------------------------------
eq "$(inv_names | wc -l | tr -d ' ')" "15" "inv_names 全部 15 台"
eq "$(inv_names osd | wc -l | tr -d ' ')" "8" "inv_names osd = 8"
eq "$(inv_names mon | wc -l | tr -d ' ')" "2" "inv_names mon = 2"
eq "$(inv_names client | wc -l | tr -d ' ')" "4" "inv_names client = 4"
eq "$(inv_names osd | head -1)" "mclock-osd-1" "inv_names 保序"

# --- 3. getters --------------------------------------------------------------
eq "$(inv_ip mclock-osd-3)" "10.60.1.23" "inv_ip"
eq "$(inv_ip mclock-client-4)" "10.60.1.34" "inv_ip client"
eq "$(inv_rack mclock-osd-3)" "rack2" "inv_rack"
eq "$(inv_rack mclock-osd-8)" "rack4" "inv_rack rack4"
eq "$(inv_nvme mclock-osd-8)" "/dev/disk/by-id/nvme-MSFT_NVMe_osd-8" "inv_nvme"

# 未知 node → die（非靜默空字串）
if ( inv_ip mclock-nope ) 2>/dev/null; then fail "inv_ip 未知 node 應失敗"; fi
ok
# 非 osd node 無 rack → die
if ( inv_rack mclock-mon-1 ) 2>/dev/null; then fail "inv_rack 對 mon 應失敗"; fi
ok
if ( inv_nvme mclock-admin ) 2>/dev/null; then fail "inv_nvme 對 admin 應失敗"; fi
ok

# --- 4. 結構不符一律 die ------------------------------------------------------
mk_variant "$tmp/osd7.json" 'd["nodes"]=[n for n in d["nodes"] if n["name"]!="mclock-osd-8"]'
expect_die "$tmp/osd7.json" "osd" "OSD 數量 ≠ 8"

mk_variant "$tmp/rack3.json" '
for n in d["nodes"]:
    if n.get("rack")=="rack4": n["rack"]="rack1"
'
expect_die "$tmp/rack3.json" "rack" "rack 數量 ≠ 4"

mk_variant "$tmp/rackskew.json" '
names={"mclock-osd-1":"rack2"}
for n in d["nodes"]:
    if n["name"] in names: n["rack"]=names[n["name"]]
'
expect_die "$tmp/rackskew.json" "rack" "每 rack 必須恰 2 顆 OSD"

mk_variant "$tmp/nonvme.json" '
for n in d["nodes"]:
    if n["name"]=="mclock-osd-5": n.pop("nvme_device")
'
expect_die "$tmp/nonvme.json" "nvme_device" "缺 nvme_device"

mk_variant "$tmp/noadminip.json" '
for n in d["nodes"]:
    if n["role"]=="admin": n["private_ip"]=""
'
expect_die "$tmp/noadminip.json" "private_ip" "admin 缺 private_ip"

mk_variant "$tmp/nopub.json" 'd.pop("admin_public_ip")'
expect_die "$tmp/nopub.json" "admin_public_ip" "缺 admin_public_ip"

mk_variant "$tmp/dupip.json" '
for n in d["nodes"]:
    if n["name"]=="mclock-osd-2": n["private_ip"]="10.60.1.21"
'
expect_die "$tmp/dupip.json" "private_ip" "private_ip 重複"

printf 'not json' > "$tmp/broken.json"
expect_die "$tmp/broken.json" "JSON" "非 JSON"

expect_die "$tmp/does-not-exist.json" "inventory" "檔案不存在"

# --- 5. 重新載入會清掉舊狀態 ---------------------------------------------------
mk_variant "$tmp/renamed.json" '
for n in d["nodes"]:
    if n["name"]=="mclock-osd-8": n["name"]="mclock-osd-8b"
'
inventory_load "$tmp/renamed.json"
eq "$(inv_ip mclock-osd-8b)" "10.60.1.28" "重新載入後看得到新 node"
if ( inv_ip mclock-osd-8 ) 2>/dev/null; then fail "重新載入後舊 node 應消失"; fi
ok
inventory_load "$fixture"

printf 'test-inventory.sh: %d assertions passed\n' "$asserts"
