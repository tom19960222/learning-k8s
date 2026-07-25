#!/usr/bin/env bash
# ceph-mclock-profiles — inventory 解析（Task 2）。bash 3.2 相容，解析用 python3（不依賴 jq）。
#
# 對外介面：
#   inventory_load [path]  載入並驗證；export ADMIN_PUBLIC_IP / ADMIN_PRIVATE_IP / ADMIN_NAME
#   inv_names [role]       列出 node 名稱（可依 role 過濾），保持 inventory 原順序
#   inv_ip <name> / inv_rack <name> / inv_nvme <name>
#
# ADMIN_PRIVATE_IP 是硬需求（plan v4.2/O-F3）：Task 5 bootstrap 的 --mon-ip 與 Task 8
# 隔離規則的 -s/-d 都靠它；若為空字串，iptables 規則會 match 全部流量。
# 因此結構不符（OSD ≠ 8／rack ≠ 4／缺 nvme_device／缺 admin private_ip）一律 die。
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR

[ -n "${MCLOCK_INVENTORY_LOADED:-}" ] && return 0
MCLOCK_INVENTORY_LOADED=1

# shellcheck source=./common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# _INV_TABLE：每行 `name<TAB>role<TAB>private_ip<TAB>rack<TAB>nvme_device`（缺值為 `-`）
_INV_TABLE=""

inventory_load() { # [path]
  local path raw head
  path="${1:-$INVENTORY_JSON}"
  [ -f "$path" ] || die "inventory 不存在：${path}"

  raw="$(python3 - "$path" <<'PY'
import collections
import json
import sys


def fail(msg):
    sys.stderr.write("inventory 驗證失敗：%s\n" % msg)
    sys.exit(1)


path = sys.argv[1]
try:
    with open(path) as fh:
        doc = json.load(fh)
except ValueError as exc:
    fail("JSON 無法解析（%s）" % exc)
except OSError as exc:
    fail("無法讀取 inventory（%s）" % exc)

if not isinstance(doc, dict):
    fail("頂層必須是 JSON object")

pub = doc.get("admin_public_ip")
if not isinstance(pub, str) or not pub.strip():
    fail("缺 admin_public_ip（或不是非空字串）")
pub = pub.strip()

nodes = doc.get("nodes")
if not isinstance(nodes, list) or not nodes:
    fail("缺 nodes 陣列")

EXPECT_ROLES = {"admin": 1, "mon": 2, "osd": 8, "client": 4}
rows = []
seen_names = set()
seen_ips = set()
role_count = collections.Counter()
rack_count = collections.Counter()

for idx, node in enumerate(nodes):
    if not isinstance(node, dict):
        fail("nodes[%d] 不是 object" % idx)
    name = (node.get("name") or "").strip()
    role = (node.get("role") or "").strip()
    ip = (node.get("private_ip") or "").strip()
    if not name:
        fail("nodes[%d] 缺 name" % idx)
    if not role:
        fail("node %s 缺 role" % name)
    if not ip:
        fail("node %s 缺 private_ip" % name)
    if name in seen_names:
        fail("node name 重複：%s" % name)
    if ip in seen_ips:
        fail("private_ip 重複：%s（%s）" % (ip, name))
    seen_names.add(name)
    seen_ips.add(ip)
    role_count[role] += 1
    rack = (node.get("rack") or "").strip()
    nvme = (node.get("nvme_device") or "").strip()
    if role == "osd":
        if not rack:
            fail("OSD %s 缺 rack 標籤" % name)
        if not nvme:
            fail("OSD %s 缺 nvme_device" % name)
        rack_count[rack] += 1
    for field in ("\t", "\n"):
        if any(field in value for value in (name, role, ip, rack, nvme)):
            fail("node %s 的欄位含控制字元" % name)
    rows.append((name, role, ip, rack or "-", nvme or "-"))

for role in sorted(EXPECT_ROLES):
    want = EXPECT_ROLES[role]
    got = role_count[role]
    if got != want:
        fail("role %s 的 node 數量 %d，期望 %d" % (role, got, want))

if len(rack_count) != 4:
    fail("rack 數量 %d，期望 4（CRUSH 拓撲是 4 rack × 2 OSD）" % len(rack_count))
for rack in sorted(rack_count):
    if rack_count[rack] != 2:
        fail("rack %s 有 %d 顆 OSD，期望 2" % (rack, rack_count[rack]))

admin = [r for r in rows if r[1] == "admin"][0]
out = ["#ADMIN\t%s\t%s\t%s" % (admin[0], admin[2], pub)]
out.extend("\t".join(r) for r in rows)
sys.stdout.write("\n".join(out) + "\n")
PY
  )" || die "inventory 結構不符：${path}"

  head="$(printf '%s\n' "$raw" | head -1)"
  _INV_TABLE="$(printf '%s\n' "$raw" | tail -n +2)"

  local tag aname aip apub
  IFS=$'\t' read -r tag aname aip apub <<< "$head"
  [ "$tag" = "#ADMIN" ] || die "inventory 解析輸出格式異常（${path}）"
  [ -n "$aip" ] || die "admin private_ip 為空（${path}）"
  [ -n "$apub" ] || die "admin_public_ip 為空（${path}）"

  ADMIN_NAME="$aname"
  ADMIN_PRIVATE_IP="$aip"
  ADMIN_PUBLIC_IP="$apub"
  export ADMIN_NAME ADMIN_PRIVATE_IP ADMIN_PUBLIC_IP
  log "inventory 載入：${path}（admin=${ADMIN_NAME} ${ADMIN_PRIVATE_IP} / public ${ADMIN_PUBLIC_IP}）"
}

_inv_require() {
  [ -n "$_INV_TABLE" ] || die "inventory 未載入：請先呼叫 inventory_load"
}

# _inv_lookup <name> <role|ip|rack|nvme>
#   0 = 找到；1 = 無此 node；2 = 該 node 無此欄位
_inv_lookup() {
  local want="$1" field="$2" n r i k v
  while IFS=$'\t' read -r n r i k v; do
    [ "$n" = "$want" ] || continue
    case "$field" in
      role) printf '%s\n' "$r" ;;
      ip)   printf '%s\n' "$i" ;;
      rack) [ "$k" = "-" ] && return 2; printf '%s\n' "$k" ;;
      nvme) [ "$v" = "-" ] && return 2; printf '%s\n' "$v" ;;
      *)    return 3 ;;
    esac
    return 0
  done <<< "$_INV_TABLE"
  return 1
}

# 取值失敗一律 die（不回空字串——空字串進 iptables/ssh 會變成災難）。
_inv_get() { # <name> <field> <欄位中文名>
  local out rc
  out="$(_inv_lookup "$1" "$2")"
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$out"; return 0 ;;
    2) die "node ${1} 沒有 ${3}（inventory 只有 OSD 帶 rack/nvme_device）" ;;
    *) die "inventory 查無此 node：${1}" ;;
  esac
}

inv_names() { # [role]
  _inv_require
  local role="${1:-}" n r i k v
  while IFS=$'\t' read -r n r i k v; do
    [ -n "$n" ] || continue
    if [ -z "$role" ] || [ "$r" = "$role" ]; then
      printf '%s\n' "$n"
    fi
  done <<< "$_INV_TABLE"
}

inv_ip()   { _inv_require; _inv_get "$1" ip   "private_ip"; }
inv_rack() { _inv_require; _inv_get "$1" rack "rack 標籤"; }
inv_nvme() { _inv_require; _inv_get "$1" nvme "nvme_device"; }
inv_role() { _inv_require; _inv_get "$1" role "role"; }
