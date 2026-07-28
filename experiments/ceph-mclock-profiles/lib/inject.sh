#!/usr/bin/env bash
# ceph-mclock-profiles — 故障注入狀態機（Task 8）。bash 3.2 相容；
# stdout 只放機器要抓的那行，log/progress 一律 stderr。
#
# 對外介面
# --------
#   inject_confirm "$@"                     入口腳本呼叫一次（吃 --yes-really-inject）
#   fault_flapping <osd-id> <bundle>        10 輪 stop/start；noout 對稱設解；不 out
#   fault_osd_down <osd-id> <bundle>        stop → 等 down → 立即 osd out
#   fault_osd_down_recover <osd-id> <bundle>
#   fault_node_isolate <node> <bundle>      guard → chain → 三段驗證 → osd out
#   fault_node_heal <node> <bundle>         kill guard → flush → 驗恢復 → 等 up → osd in
#   fault_rack_isolate <rack> <bundle>      prepare → verify barrier → commit（一次 out 兩顆）
#   fault_rack_heal <rack> <bundle>
#   chaos_generate <seed> <duration> <out>  固定 seed 的事件序列（min_size 不變條件內建驗證）
#   chaos_prepare_seq / inject_chaos_verify / chaos_run <seed> <duration> <bundle>
#   inject_rollback_all <bundle>            依 active registry 回退（冪等）
#   inject_cleanup_proof <bundle>           全 OSD node 無殘留規則/guard + OSD 全 up+in
#   inject_iso_rules <node>                 純函式：規則檔內容（測試逐行斷言）
#   inject_guard_secs [cap] [deadline|-]    guard deadline 與不變條件檢查
#   inject_event / inject_timeline_set / inject_taint / inject_is_tainted
#
# 設計要點
# --------
# 1. **每型故障一個顯式狀態機**（plan Task 8）：flapping / osd-down / node-isolate /
#    rack-isolate 的驗證條件與回退路徑本質不同，刻意不共用 generic 機。
# 2. **down 偵測延遲差異（H-020）**：`orch daemon stop` 有 MOSDMarkMeDown（<5s 判 down），
#    network isolation 只能等 heartbeat 逾時（≈20s）。所以每次判 down 都同時記錄
#    `down_epoch_t`（絕對時間）與 `down_map_epoch`（OSDMap `down_at`），
#    跨故障型比較一律用後者對齊；fault_t0 只能當作注入動作的時戳。
# 3. **guard 先於 chain**（plan v4）：先 `remote_bg_start` 一支 `sleep N && flush` 的自動回退
#    guard，才套隔離規則——避免「chain 套了、guard 沒起來」的窗口。guard 觸發 = attempt taint
#    （guard 是 bastion 失聯時的安全網，不是正常 heal 路徑）。
# 4. **ESTABLISHED 只開給 admin 的 tcp/22**：下 general ESTABLISHED accept 會讓既有 Ceph
#    messenger 連線續存 → 隔離無效（round2 blocker 9）。
# 5. **chaos 的 min_size 安全不變條件**：任一時刻的併發故障只能落在同一個 rack
#    （pool size=3 / failure domain=rack / min_size=2）——跨 rack 併發會讓 PG inactive，
#    krbd client IO 卡 kernel D-state，fio kill 不掉、unmap 必敗、watchdog 救不回。
# 6. 所有注入在動手**之前**先寫 active registry（`<bundle>/inject-active.tsv`），
#    crash/abort 後 `inject_rollback_all` 才有得回退。
#
# 給 Task 11（pipeline）的契約
# ---------------------------
#   - `MEASUREMENT_CAP` / `MEASUREMENT_DEADLINE` 必須由 pipeline export，
#     `inject_guard_secs` 才驗得了 `guard_deadline >= measurement_deadline + 600`。
#   - `fault_t0` / `measurement_deadline` / `measurement_cap` 由 pipeline 寫進
#     `fault-timeline.json`；本檔只寫 `down_epoch_t` / `down_map_epoch` /
#     `heal_t` / `rack` / `prepare_skew_s` 等注入端事實（同一個檔，合併寫入）。
#   - **不要用 `x="$(fault_... )"` 取機器行**：command substitution 是 subshell，
#     裡面的 `cleanup_push` 出了 subshell 就沒了。pipeline 應在建立 bundle 之後
#     自己 `cleanup_push "inject_rollback_all '<bundle>' || true"`（registry 落檔，
#     所以即使 crash 在新 process 也回退得了）。
#   - rc 慣例：0 = 成功；4 = taint（叢集安全，attempt 作廢）；1 = 失敗（已就地回退）。
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR

[ -n "${MCLOCK_INJECT_LOADED:-}" ] && return 0
MCLOCK_INJECT_LOADED=1

# shellcheck source=./ceph.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ceph.sh"

# --- 常數 ---------------------------------------------------------------------
INJECT_CHAIN="${INJECT_CHAIN:-MCLOCK-ISO}"
GUARD_GRACE_SECS="${GUARD_GRACE_SECS:-600}"
MEASUREMENT_CAP="${MEASUREMENT_CAP:-2700}"
INJECT_CMD_SECS="${INJECT_CMD_SECS:-60}"
INJECT_PROBE_SECS="${INJECT_PROBE_SECS:-15}"
# flapping（plan Task 8：10 輪）
FLAP_CYCLES="${FLAP_CYCLES:-10}"
FLAP_DOWN_GRACE_SECS="${FLAP_DOWN_GRACE_SECS:-60}"
FLAP_FORCE_DOWN_SECS="${FLAP_FORCE_DOWN_SECS:-60}"
FLAP_UP_SECS="${FLAP_UP_SECS:-300}"
FLAP_PG_SECS="${FLAP_PG_SECS:-300}"
# osd-down（MOSDMarkMeDown → 通常 <5s）
OSD_DOWN_SECS="${OSD_DOWN_SECS:-120}"
OSD_UP_SECS="${OSD_UP_SECS:-300}"
# isolation（heartbeat 逾時 ≈20s + mon tick）
ISO_OPEN_SECS="${ISO_OPEN_SECS:-30}"
ISO_CLOSED_SECS="${ISO_CLOSED_SECS:-60}"
ISO_DOWN_SECS="${ISO_DOWN_SECS:-180}"
ISO_UP_SECS="${ISO_UP_SECS:-300}"
RACK_PREPARE_MAX_SKEW_SECS="${RACK_PREPARE_MAX_SKEW_SECS:-5}"
# chaos 事件產生器
CHAOS_SEED="${CHAOS_SEED:-4242}"
CHAOS_GAP_MIN="${CHAOS_GAP_MIN:-20}"
CHAOS_GAP_MAX="${CHAOS_GAP_MAX:-90}"
CHAOS_HOLD_MIN="${CHAOS_HOLD_MIN:-30}"
CHAOS_HOLD_MAX="${CHAOS_HOLD_MAX:-180}"
CHAOS_RACK_SWITCH_GAP="${CHAOS_RACK_SWITCH_GAP:-60}"
CHAOS_TAIL_MARGIN="${CHAOS_TAIL_MARGIN:-60}"

# --- python 解析器（JSON / PRNG 判讀集中在這裡）--------------------------------
_INJECT_PY_SRC="$(cat <<'PY'
import json
import os
import random
import re
import sys
import time

SCHEMA_VERSION = 1
ADDR_RE = re.compile(r"(?:(v\d):)?(\d{1,3}(?:\.\d{1,3}){3}):(\d+)")


def die(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def dump_atomic(path, doc):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(doc, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.rename(tmp, path)


def load_or(path, default):
    if not os.path.exists(path):
        return default
    try:
        with open(path) as fh:
            return json.load(fh)
    except ValueError:
        return default


def coerce(text):
    if re.match(r"^-?\d+$", text):
        return int(text)
    try:
        return float(text)
    except ValueError:
        pass
    if text in ("true", "false"):
        return text == "true"
    return text


def kvs(args):
    out = {}
    for item in args:
        if "=" not in item:
            die("k=v 格式錯誤：%s" % item)
        key, _, val = item.partition("=")
        out[key] = coerce(val)
    return out


# --- endpoint ----------------------------------------------------------------


def parse_addr(raw):
    """`[v2:ip:port/nonce,v1:ip:port/nonce]` 或舊格式 `ip:port/nonce` 都吃。"""
    cands = [(m.group(1) or "v1", m.group(2), m.group(3))
             for m in ADDR_RE.finditer(str(raw))]
    for want in ("v2", "v1"):
        for ver, ip, port in cands:
            if ver == want:
                return ip, port
    return None


def cmd_endpoint():
    doc = json.load(sys.stdin)
    for key in ("front_addr", "public_addr", "back_addr"):
        found = parse_addr(doc.get(key) or "")
        if found:
            print("%s %s" % found)
            return
    die("osd metadata 內找不到可用的 addr（front_addr/public_addr/back_addr 皆無）")


def cmd_subnets():
    """全 node private IP → 去重的 /24（隔離規則的 DROP 範圍）。"""
    nets = []
    for line in sys.stdin.read().split():
        parts = line.strip().split(".")
        if len(parts) != 4:
            die("不是 IPv4 位址：%s" % line)
        net = "%s.%s.%s.0/24" % (parts[0], parts[1], parts[2])
        if net not in nets:
            nets.append(net)
    if not nets:
        die("inventory 沒有任何 private IP —— 隔離規則會沒有 DROP 範圍")
    for net in sorted(nets):
        print(net)


# --- bundle 產出物 ------------------------------------------------------------


def cmd_event(path, name, *args):
    row = {"t": int(time.time()), "event": name}
    row.update(kvs(args))
    with open(path, "a") as fh:
        fh.write(json.dumps(row, sort_keys=True) + "\n")


def cmd_timeline(path, *args):
    doc = load_or(path, {})
    doc.setdefault("schema_version", SCHEMA_VERSION)
    doc.update(kvs(args))
    dump_atomic(path, doc)


def cmd_taint(path, reason):
    doc = load_or(path, {"schema_version": SCHEMA_VERSION, "reasons": []})
    doc["tainted"] = True
    doc.setdefault("reasons", []).append({"t": int(time.time()), "reason": reason})
    dump_atomic(path, doc)


def cmd_proof(path, osd_line, *nodes):
    total, up, inn = [int(x) for x in osd_line.split()]
    rows = []
    clean = True
    for spec in nodes:
        name, iso, guards = spec.split(":")
        iso, guards = int(iso), int(guards)
        rows.append({"node": name, "iso_rules": iso, "guards": guards})
        if iso or guards:
            clean = False
    osds_ok = (total > 0 and up == total and inn == total)
    doc = {"schema_version": SCHEMA_VERSION,
           "verified": bool(clean and osds_ok),
           "nodes": rows,
           "osds": {"total": total, "up": up, "in": inn},
           "checked_at": int(time.time())}
    dump_atomic(path, doc)
    print("ok" if doc["verified"] else "dirty")


# --- chaos -------------------------------------------------------------------

FAULT_ACTIONS = ("osd-stop", "node-isolate")
HEAL_OF = {"osd-stop": "osd-start", "node-isolate": "node-heal"}


def verify_events(events, min_size=2):
    """展開後的完整事件序列必須守 min_size 安全不變條件。

    pool size=3、failure domain=rack、min_size=2 ⇒ 任一時刻的併發故障只要跨兩個
    rack，就會有 PG 只剩 1 份副本 → inactive → krbd client 卡 kernel D-state。
    """
    active = {}
    problems = []
    last_t = None
    for ev in events:
        t = ev["t"]
        if last_t is not None and t < last_t:
            problems.append("事件未按時間排序（t=%s）" % t)
        last_t = t
        if ev["action"] in FAULT_ACTIONS:
            active[ev["node"]] = ev["rack"]
        elif ev["action"] in HEAL_OF.values():
            active.pop(ev["node"], None)
        else:
            problems.append("未知 action：%s" % ev["action"])
        racks = set(active.values())
        if len(racks) > 1:
            problems.append("t=%s 併發故障跨 %d 個 rack（PG 會低於 min_size=%d）"
                            % (t, len(racks), min_size))
        if len(active) > 2:
            problems.append("t=%s 併發故障 %d 顆 OSD" % (t, len(active)))
    if active:
        problems.append("序列結束仍有未回退的故障：%s" % sorted(active))
    return problems


def cmd_chaos_gen(seed, duration, out, params_json):
    seed, duration = int(seed), int(duration)
    par = json.loads(params_json)
    topo = json.load(sys.stdin)
    if not topo:
        die("chaos topology 是空的")
    rnd = random.Random(seed)
    by_rack = {}
    for row in topo:
        by_rack.setdefault(row["rack"], []).append(row)

    events = []
    active = []          # [{node, rack, osd, action, heal_t}]
    last_clear_t = 0     # active 最後一次清空的時間（rack 切換的冷卻起點）
    last_rack = None
    t = rnd.randint(par["gap_min"], par["gap_max"])
    horizon = duration - par["tail_margin"]
    while t <= horizon:
        for row in [a for a in active if a["heal_t"] <= t]:
            active.remove(row)
            if not active:
                last_clear_t = row["heal_t"]
        if active:
            rack = active[0]["rack"]
            busy = set(a["node"] for a in active)
            cands = [r for r in by_rack[rack] if r["node"] not in busy]
        elif last_rack is not None and (t - last_clear_t) < par["rack_switch_gap"]:
            # 換 rack 前先讓上一輪的 peering/recovery 落地，避免緊接著再打第二個 rack
            cands = [r for r in by_rack[last_rack]]
        else:
            cands = list(topo)
        if cands:
            row = dict(rnd.choice(sorted(cands, key=lambda r: r["osd"])))
            action = FAULT_ACTIONS[rnd.randint(0, len(FAULT_ACTIONS) - 1)]
            hold = rnd.randint(par["hold_min"], par["hold_max"])
            heal_t = min(t + hold, duration - 1)
            if heal_t <= t:
                heal_t = t + 1
            events.append({"t": t, "action": action, "node": row["node"],
                           "osd": row["osd"], "rack": row["rack"]})
            events.append({"t": heal_t, "action": HEAL_OF[action],
                           "node": row["node"], "osd": row["osd"],
                           "rack": row["rack"]})
            active.append({"node": row["node"], "rack": row["rack"],
                           "osd": row["osd"], "action": action, "heal_t": heal_t})
            last_rack = row["rack"]
        t += rnd.randint(par["gap_min"], par["gap_max"])

    # 同一秒：heal 一律排在 fault 之前（否則展開序列會出現假的跨 rack 併發）
    events.sort(key=lambda e: (e["t"], 0 if e["action"] in HEAL_OF.values() else 1))
    problems = verify_events(events)
    if problems:
        die("chaos 產生器違反 min_size 不變條件（這是 bug，不得放行）：\n  %s"
            % "\n  ".join(problems))
    doc = {"schema_version": SCHEMA_VERSION, "seed": seed, "duration_s": duration,
           "params": par, "events": events,
           "invariant": {"min_size": 2, "max_concurrent_faults": 2,
                         "max_concurrent_racks": 1, "verified": True}}
    dump_atomic(out, doc)
    print(len(events))


def cmd_chaos_verify(path):
    doc = load_or(path, None)
    if not doc or "events" not in doc:
        die("讀不到 chaos 事件序列：%s" % path)
    problems = verify_events(doc["events"])
    if problems:
        die("chaos 事件序列違反 min_size 不變條件：\n  %s" % "\n  ".join(problems))
    print(len(doc["events"]))


def cmd_chaos_events(path):
    doc = load_or(path, None)
    if not doc:
        die("讀不到 chaos 事件序列：%s" % path)
    for ev in doc["events"]:
        print("%d\t%s\t%s\t%d\t%s" % (int(ev["t"]), ev["action"], ev["node"],
                                      int(ev["osd"]), ev["rack"]))


def cmd_chaos_meta(path, seed, duration):
    doc = load_or(path, None)
    if not doc:
        print("missing")
        return
    same = (int(doc.get("seed", -1)) == int(seed)
            and int(doc.get("duration_s", -1)) == int(duration))
    print("match" if same else "stale")


DISPATCH = {
    "endpoint": cmd_endpoint,
    "subnets": cmd_subnets,
    "event": cmd_event,
    "timeline": cmd_timeline,
    "taint": cmd_taint,
    "proof": cmd_proof,
    "chaos-gen": cmd_chaos_gen,
    "chaos-verify": cmd_chaos_verify,
    "chaos-events": cmd_chaos_events,
    "chaos-meta": cmd_chaos_meta,
}

if len(sys.argv) < 2 or sys.argv[1] not in DISPATCH:
    die("未知子指令：%s" % (sys.argv[1] if len(sys.argv) > 1 else ""))
DISPATCH[sys.argv[1]](*sys.argv[2:])
PY
)"

_inject_py() { python3 -c "$_INJECT_PY_SRC" "$@"; }

# --- confirm gate -------------------------------------------------------------

inject_confirm() {
  require_inject_flag "$@"
  INJECT_CONFIRMED=1
  export INJECT_CONFIRMED
}

_inject_require_confirm() {
  [ "${INJECT_CONFIRMED:-}" = "1" ] \
    || die "注入未確認：入口腳本必須先呼叫 inject_confirm \"\$@\"（--yes-really-inject）"
}

# --- bundle 產出物 ------------------------------------------------------------

inject_event() { # <bundle> <event-name> [k=v...]
  [ $# -ge 2 ] || die "用法：inject_event <bundle> <name> [k=v...]"
  local b="$1" name="$2"; shift 2
  mkdir -p "$b"
  _inject_py event "$b/inject-events.jsonl" "$name" "$@" \
    || die "事件時間軸寫入失敗：${b}"
}

inject_timeline_set() { # <bundle> k=v...
  [ $# -ge 2 ] || die "用法：inject_timeline_set <bundle> k=v..."
  local b="$1"; shift
  mkdir -p "$b"
  _inject_py timeline "$b/fault-timeline.json" "$@" \
    || die "fault-timeline 寫入失敗：${b}"
}

inject_taint() { # <bundle> <reason>
  [ $# -eq 2 ] || die "用法：inject_taint <bundle> <reason>"
  mkdir -p "$1"
  _inject_py taint "$1/inject-taint.json" "$2" || die "taint 標記寫入失敗：${1}"
  log "attempt 標為 taint：${2}"
}

inject_is_tainted() { # <bundle>
  [ $# -eq 1 ] || die "用法：inject_is_tainted <bundle>"
  [ -s "$1/inject-taint.json" ]
}

# --- active registry（回退的唯一 SoT）-----------------------------------------
# 每行：`kind<TAB>target<TAB>osd-ids(逗號)<TAB>rack`

_inject_registry() { printf '%s/inject-active.tsv\n' "${1%/}"; }

_inject_active_add() { # <bundle> <kind> <target> <osd-ids> [rack]
  local reg
  reg="$(_inject_registry "$1")"
  mkdir -p "$1"
  [ -f "$reg" ] || : > "$reg"
  _inject_active_del "$1" "$2" "$3"
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "${5:-}" >> "$reg"
}

_inject_active_del() { # <bundle> <kind> <target>
  local reg tmpf k t rest
  reg="$(_inject_registry "$1")"
  [ -f "$reg" ] || return 0
  tmpf="${reg}.tmp.$$"
  : > "$tmpf"
  while IFS=$'\t' read -r k t rest; do
    [ -n "$k" ] || continue
    if [ "$k" = "$2" ] && [ "$t" = "$3" ]; then continue; fi
    printf '%s\t%s\t%s\n' "$k" "$t" "$rest" >> "$tmpf"
  done < "$reg"
  mv -f "$tmpf" "$reg"
}

_inject_push_rollback() { # <bundle>：唯一的 abort 出口（cleanup stack，LIFO）
  cleanup_push "inject_rollback_all '$1' >/dev/null 2>&1 || true"
}

# inject_rollback_all <bundle>：依 registry 把所有殘留故障回退；冪等（空 registry 不打 ssh）。
inject_rollback_all() {
  [ $# -eq 1 ] || die "用法：inject_rollback_all <bundle>"
  local b="$1" reg kind target osds rack racks=""
  reg="$(_inject_registry "$b")"
  [ -s "$reg" ] || { printf 'inject-rollback: CLEAN\n'; return 0; }
  while IFS=$'\t' read -r kind target osds rack; do
    [ -n "$kind" ] || continue
    log "inject_rollback_all：回退 ${kind} target=${target} osds=${osds:-?}"
    case "$kind" in
      osd-down)      fault_osd_down_recover "$target" "$b" >/dev/null || true ;;
      chaos-osd-stop) _inject_osd_start_only "$target" "$b" >/dev/null || true ;;
      flapping)      _inject_osd_start_only "$target" "$b" >/dev/null || true ;;
      node-isolate)  fault_node_heal "$target" "$b" >/dev/null || true ;;
      chaos-isolate) _inject_node_rollback "$target" "$b" || true ;;
      rack-isolate)
        case " ${racks} " in *" ${rack} "*) : ;; *) racks="${racks} ${rack}" ;; esac
        ;;
      *) log "inject_rollback_all：未知的 registry 類型 ${kind}（跳過）" ;;
    esac
  done < "$reg"
  for rack in ${racks}; do
    fault_rack_heal "$rack" "$b" >/dev/null || true
  done
  printf 'inject-rollback: DONE\n'
}

# --- 拓撲 helper（node ↔ osd）-------------------------------------------------

_INJECT_TREE_CACHE=""

inject_cache_reset() { _INJECT_TREE_CACHE=""; }

# _inject_tree_load：把 node ↔ osd 對應載進 cache。
# **必須在非 subshell 的位置呼叫**——`x="$(...)"` 內的賦值出了 subshell 就沒了，
# 沒有這道分界的話每次查詢都會多打一次 `ceph osd tree`。
_inject_tree_load() {
  [ -n "$_INJECT_TREE_CACHE" ] && return 0
  _INJECT_TREE_CACHE="$(ceph_adm "ceph osd tree --format json" | _ceph_py osd-tree-hosts)" \
    || die "取不到 osd tree（node ↔ osd 對應）"
  [ -n "$_INJECT_TREE_CACHE" ] || die "osd tree 沒有任何 host"
}

_inject_osd_for_node() { # <node> → osd id（呼叫前須先 _inject_tree_load）
  local ids
  [ -n "$_INJECT_TREE_CACHE" ] \
    || die "內部錯誤：_inject_osd_for_node 之前必須先呼叫 _inject_tree_load"
  ids="$(printf '%s\n' "$_INJECT_TREE_CACHE" | awk -v h="$1" '$1 == h {print $3}')"
  [ -n "$ids" ] || die "osd tree 內找不到 host ${1}"
  case "$ids" in
    *,*) die "node ${1} 掛了多顆 OSD（${ids}）——本實驗拓撲假設 1 OSD/node" ;;
  esac
  printf '%s\n' "$ids"
}

_inject_nodes_in_rack() { # <rack> → node 名稱（inventory 順序）
  local n r found=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    r="$(inv_rack "$n")"
    if [ "$r" = "$1" ]; then
      printf '%s\n' "$n"
      found=$((found + 1))
    fi
  done <<< "$(inv_names osd)"
  [ "$found" -gt 0 ] || die "inventory 內沒有 rack ${1} 的 node"
}

_inject_osd_endpoint() { # <osd-id> → `ip port`（實際 addr:port，不是猜的）
  local out
  case "${1:-}" in ''|*[!0-9]*) die "_inject_osd_endpoint：osd id 必須是數字（got=[${1:-}]）" ;; esac
  out="$(ceph_adm "ceph osd metadata $1 --format json" | _inject_py endpoint)" \
    || die "取不到 osd.${1} 的 endpoint（ceph osd metadata）"
  [ -n "$out" ] || die "osd.${1} 的 endpoint 是空的"
  printf '%s\n' "$out"
}

# 供測試直接餵 metadata JSON 驗 parser
inject_parse_endpoint() { _inject_py endpoint; }

# --- 隔離規則（純函式，可逐行斷言）--------------------------------------------

_inject_assert_ip() { # <value> <欄位名>
  [ -n "$1" ] || die "${2} 是空字串——iptables 規則會 match 全部流量，拒絕套用"
  printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
    || die "${2} 不是 IPv4 位址：${1}"
}

_inject_subnets() {
  local n
  { while IFS= read -r n; do
      [ -n "$n" ] || continue
      inv_ip "$n"
    done <<< "$(inv_names)"
  } | _inject_py subnets
}

# inject_iso_rules <node>：iptables-restore 用的規則檔內容。
# ESTABLISHED,RELATED **只**開給 ADMIN_PRIVATE_IP 的 tcp/22——下 general ESTABLISHED
# accept 會讓既有 Ceph messenger 連線續存，隔離等於沒做（round2 blocker 9）。
inject_iso_rules() {
  [ $# -eq 1 ] || die "用法：inject_iso_rules <node>"
  local admin net role
  role="$(inv_role "$1")"
  [ "$role" = "osd" ] || die "只允許隔離 OSD node（${1} 的 role=${role}）"
  admin="${ADMIN_PRIVATE_IP:-}"
  _inject_assert_ip "$admin" "ADMIN_PRIVATE_IP"
  printf '*filter\n'
  printf -- '-A %s -s %s/32 -p tcp --dport 22 -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT\n' \
    "$INJECT_CHAIN" "$admin"
  printf -- '-A %s -d %s/32 -p tcp --sport 22 -m state --state ESTABLISHED,RELATED -j ACCEPT\n' \
    "$INJECT_CHAIN" "$admin"
  while IFS= read -r net; do
    [ -n "$net" ] || continue
    printf -- '-A %s -s %s -j DROP\n' "$INJECT_CHAIN" "$net"
    printf -- '-A %s -d %s -j DROP\n' "$INJECT_CHAIN" "$net"
  done <<< "$(_inject_subnets)"
  printf 'COMMIT\n'
}

# --- guard（bastion 失聯時的自動回退安全網）-----------------------------------

_inject_guard_id() { printf 'guard-%s\n' "$1"; }

# inject_guard_secs [cap] [deadline|-]
#   guard_deadline = cap + 600，且不變條件 guard_deadline >= measurement_deadline + 600。
#   chaos 沒有 measurement cap → 以 duration 當 cap、deadline 傳 `-`（plan v4.2/F5-9）。
inject_guard_secs() {
  local cap="${1:-$MEASUREMENT_CAP}" dl="${2:-${MEASUREMENT_DEADLINE:-}}" secs now
  case "$cap" in ''|*[!0-9]*) die "guard cap 必須是整數秒（got=${cap}）" ;; esac
  secs=$((cap + GUARD_GRACE_SECS))
  if [ -n "$dl" ] && [ "$dl" != "-" ]; then
    case "$dl" in ''|*[!0-9]*) die "measurement deadline 必須是絕對 epoch（got=${dl}）" ;; esac
    now="$(date +%s)"
    [ $((now + secs)) -ge $((dl + GUARD_GRACE_SECS)) ] \
      || die "guard deadline 不變條件違反：guard=$((now + secs)) < measurement_deadline+600=$((dl + GUARD_GRACE_SECS))（guard 絕不可先於正常 heal 觸發）"
  fi
  printf '%s\n' "$secs"
}

# inject_guard_script <run-id> <secs>：遠端背景 guard 的指令（純函式）。
inject_guard_script() {
  [ $# -eq 2 ] || die "用法：inject_guard_script <run-id> <secs>"
  # `.fired` 的語意必須是「我真的睡滿了才自動 flush」，而不是「我的 sleep 以某種
  # 方式結束了」。正常 heal 會先 kill 掉這支 guard——若 sleep 被殺掉後仍往下寫標記，
  # heal 就會把自己的動作誤讀成安全網先觸發，把好好的 attempt 標成 taint。
  # 真機實測：rack-isolation 在 heal 當下被誤判 guard-fired（距真正期限還有 1582s）。
  cat <<EOF
if sleep ${2}; then
  iptables -F ${INJECT_CHAIN} 2>/dev/null || true
  date +%s > ${BG_REGISTRY_DIR}/${1}.fired
fi
EOF
}

_inject_arm_guard() { # <node> <secs>
  local guard
  guard="$(_inject_guard_id "$1")"
  remote_bg_start "$1" "$guard" "$(inject_guard_script "$guard" "$2")" >/dev/null \
    || die "guard 武裝失敗（${1}）——未武裝 guard 前不得套隔離規則"
  log "guard 已武裝：${1}（${2}s 後自動 flush ${INJECT_CHAIN}）"
}

# --- chain 套用 / flush -------------------------------------------------------

_inject_arm_chain() { # <node>
  local node="$1" rules script
  rules="$(inject_iso_rules "$node")"
  script="$(cat <<EOF
sudo iptables -N ${INJECT_CHAIN} 2>/dev/null || true
sudo iptables -C INPUT -j ${INJECT_CHAIN} 2>/dev/null || sudo iptables -I INPUT 1 -j ${INJECT_CHAIN}
sudo iptables -C OUTPUT -j ${INJECT_CHAIN} 2>/dev/null || sudo iptables -I OUTPUT 1 -j ${INJECT_CHAIN}
sudo iptables -F ${INJECT_CHAIN}
sudo iptables-restore --noflush <<RULES
${rules}
RULES
echo mclock-iso: armed
EOF
)"
  _node_sh "$node" "$INJECT_CMD_SECS" "$script" >&2 \
    || die "隔離規則套用失敗（${node}）"
}

# _inject_flush_chain <node> <guard-id>：印出 `fired=0|1`（guard 是否曾觸發）。
_inject_flush_chain() {
  local node="$1" guard="$2" script out
  script="$(cat <<EOF
if [ -f ${BG_REGISTRY_DIR}/${guard}.fired ]; then echo mclock-iso: fired=1; else echo mclock-iso: fired=0; fi
sudo iptables -F ${INJECT_CHAIN} 2>/dev/null || true
sudo rm -f ${BG_REGISTRY_DIR}/${guard}.fired
echo mclock-iso: flushed
EOF
)"
  out="$(_node_sh "$node" "$INJECT_CMD_SECS" "$script")" \
    || { log "flush ${INJECT_CHAIN} 失敗（${node}）"; return 1; }
  case "$out" in
    *fired=1*) printf 'fired=1\n' ;;
    *)         printf 'fired=0\n' ;;
  esac
}

# --- 三段驗證的探針 -----------------------------------------------------------

_inject_probe_node() {
  if [ -z "${INJECT_PROBE_NODE:-}" ]; then
    INJECT_PROBE_NODE="$(inv_names client | head -1)"
    [ -n "$INJECT_PROBE_NODE" ] \
      || die "inventory 沒有 client node（endpoint 驗證需要一台不會被隔離的觀測點）"
  fi
  printf '%s\n' "$INJECT_PROBE_NODE"
}

_inject_probe_open() { # <ip> <port>：rc 0 = 通
  _node_run "$(_inject_probe_node)" "$INJECT_PROBE_SECS" "nc -z -w 3 $1 $2" \
    >/dev/null 2>&1
}

_inject_probe_closed() { _inject_probe_open "$_ISO_IP" "$_ISO_PORT" && return 1; return 0; }
_inject_probe_reopen() { _inject_probe_open "$_ISO_IP" "$_ISO_PORT"; }

_inject_ssh_alive() { # <node>
  _node_run "$1" "$INJECT_PROBE_SECS" "echo inject-alive" >/dev/null 2>&1
}

# --- OSD 狀態小工具 -----------------------------------------------------------

# 回歸判準用「現在是 up」（up=1 且最後一個事件是 up），而不是嚴格的 epoch 前進——
# barrier 失敗回退時目標可能根本沒 down 過，嚴格判準會空等到逾時。
# 參數可省略：with_deadline 會反覆無參呼叫它，所以目標 id 存在 _INJECT_UP_ID。
# 但直接呼叫時**一定要帶 id**——原本的簽章完全吃不到參數，`_inject_osd_is_up_now "$id"`
# 會靜靜地去查上一次殘留在全域裡的那顆 OSD。fault_flapping 解除 noout 前的「確認
# 已 up」防護就是這樣失效的：它本來就是為了擋 auto-out 而寫，卻從沒真的擋過
# （真機實測 osd.2 被留在 down，noout 照解，600s 後被 auto-out）。
_inject_osd_is_up_now() { # [<osd-id>]
  local now up up_from down_at
  [ $# -eq 0 ] || _INJECT_UP_ID="$1"
  [ -n "${_INJECT_UP_ID:-}" ] || die "_inject_osd_is_up_now：沒有目標 osd id"
  now="$(ceph_osd_state "$_INJECT_UP_ID")" || return 1
  up="$(_ceph_state_field "$now" up)"
  up_from="$(_ceph_state_field "$now" up_from)"
  down_at="$(_ceph_state_field "$now" down_at)"
  [ "$up" = "1" ] || return 1
  [ "${down_at:-0}" -le "${up_from:-0}" ]
}

_inject_wait_up_now() { # <osd-id> <secs>
  _INJECT_UP_ID="$1"
  with_deadline "$2" _inject_osd_is_up_now
}

# _inject_record_down <bundle> <osd-id> <event> [k=v...]
#   H-020：down_epoch_t（絕對時間）與 down_map_epoch（OSDMap down_at）都要留，
#   跨故障型對齊一律用後者。stdout = down_at。
_inject_record_down() {
  local b="$1" id="$2" ev="$3"; shift 3
  local st down_at t
  st="$(ceph_osd_state "$id")" || die "取不到 osd.${id} 狀態"
  down_at="$(_ceph_state_field "$st" down_at)"
  t="$(date +%s)"
  inject_event "$b" "$ev" osd="$id" map_epoch="${down_at:-0}" down_epoch_t="$t" "$@"
  inject_timeline_set "$b" down_epoch_t="$t" down_map_epoch="${down_at:-0}"
  printf '%s\n' "${down_at:-0}"
}

# =============================================================================
# 狀態機 1：flapping（不 out；noout 對稱設解；逐輪 PG gate + 未被 out 斷言）
# =============================================================================

_inject_unset_noout() { ceph_adm "ceph osd unset noout" >&2; }

fault_flapping() {
  _inject_require_confirm
  [ $# -eq 2 ] || die "用法：fault_flapping <osd-id> <bundle>"
  local id="$1" b="$2" i=1 rc=0 reason="" pre st st2 down_at up_from
  mkdir -p "$b"
  # noout：某輪 start 卡住超過 mon_osd_down_out_interval 會觸發 auto-out，
  # 非計畫 backfill 讓整個 attempt 變質（plan v4.2/F5-8）。
  ceph_adm "ceph osd set noout" >&2 || die "設定 noout 失敗"
  cleanup_push "ceph_adm 'ceph osd unset noout' >/dev/null 2>&1 || true"
  # flapping 也必須進 active registry：中斷在某輪的 down 相位時，registry 是空的話
  # inject_rollback_all 會直接回報 CLEAN，而 cleanup stack 照樣解除 noout——OSD 就這樣
  # 被留在無保護的 down，600s 後 mon auto-out 觸發非計畫 backfill（真機實測）。
  # cleanup stack 是 LIFO：這個 push 排在 unset noout 之後，所以「先拉起 OSD、再解 noout」。
  _inject_active_add "$b" flapping "$id" "$id"
  _inject_push_rollback "$b"
  while [ "$i" -le "$FLAP_CYCLES" ]; do
    pre="$(ceph_osd_state "$id")" || die "取不到 osd.${id} 狀態"
    ceph_daemon_stop "$id"
    if ! ceph_wait_osd_down "$id" "$pre" "$FLAP_DOWN_GRACE_SECS"; then
      log "flapping：osd.${id} 超過 grace 仍未判 down，顯式 ceph osd down"
      ceph_adm "ceph osd down $id" >&2 || log "顯式 ceph osd down 失敗（續行判定）"
      if ! ceph_wait_osd_down "$id" "$pre" "$FLAP_FORCE_DOWN_SECS"; then
        reason="cycle-${i}-down-timeout"; rc=4; break
      fi
    fi
    st="$(ceph_osd_state "$id")" || die "取不到 osd.${id} 狀態"
    down_at="$(_ceph_state_field "$st" down_at)"
    ceph_daemon_start "$id"
    if ! ceph_wait_osd_up "$id" "$st" "$FLAP_UP_SECS"; then
      reason="cycle-${i}-up-timeout"; rc=4; break
    fi
    st2="$(ceph_osd_state "$id")" || die "取不到 osd.${id} 狀態"
    up_from="$(_ceph_state_field "$st2" up_from)"
    if ! ceph_wait_pgs_active_for_osd "$id" "$FLAP_PG_SECS"; then
      reason="cycle-${i}-pg-not-active"; rc=4; break
    fi
    # noout 之下仍被 out = 前提失效（非計畫 backfill 已經開始）→ attempt 作廢
    if [ "$(_ceph_state_field "$st2" in)" != "1" ]; then
      reason="cycle-${i}-osd-marked-out"; rc=4; break
    fi
    ceph_check_laggy "$b/laggy/cycle-${i}.json"
    inject_event "$b" flap-cycle osd="$id" cycle="$i" \
      down_map_epoch="${down_at:-0}" up_map_epoch="${up_from:-0}"
    i=$((i + 1))
  done
  # 解除 noout 之前必須確認 OSD 已回到 up：失敗路徑（某輪 start 逾時）下 OSD 還是
  # down，一解除 noout，mon 就會在 mon_osd_down_out_interval（600s）後把它 auto-out
  # 並啟動非計畫 backfill——真機第一次跑 flapping 就是這樣，osd.2 taint 之後被 out。
  local up_ok=1
  if ! _inject_osd_is_up_now "$id"; then
    log "osd.${id} 仍為 down：先嘗試拉起再解除 noout（避免 auto-out 觸發非計畫 backfill）"
    ceph_daemon_start "$id" >&2 || log "拉起 osd.${id} 失敗（noout 仍會解除，改由 reconcile 收拾）"
    if ! with_deadline "$FLAP_UP_SECS" _inject_osd_is_up_now "$id"; then
      up_ok=0
      log "osd.${id} 未在期限內回到 up——解除 noout 後可能被 auto-out，reconcile 會處理"
    fi
  fi
  # 只有確認 OSD 真的回到 up 才撤掉 registry 條目。還是 down 就留著，讓 cleanup
  # stack 的 inject_rollback_all（和之後的 reconcile）還有一次補救機會。
  if [ "$up_ok" -eq 1 ]; then
    _inject_active_del "$b" flapping "$id"
  else
    log "osd.${id} 仍為 down：保留 registry 條目讓 rollback／reconcile 續行補救"
  fi
  _inject_unset_noout || log "unset noout 失敗（cleanup stack 會再試一次）"
  if [ "$rc" -ne 0 ]; then
    inject_taint "$b" "flapping ${reason}"
    printf 'flapping: TAINT osd.%s %s\n' "$id" "$reason"
    return 4
  fi
  inject_timeline_set "$b" flapping_cycles="$FLAP_CYCLES"
  printf 'flapping: OK osd.%s cycles=%s\n' "$id" "$FLAP_CYCLES"
}

# =============================================================================
# 狀態機 2：osd-down（managed-out：down 之後立即手動 out）
# =============================================================================

fault_osd_down() {
  _inject_require_confirm
  [ $# -eq 2 ] || die "用法：fault_osd_down <osd-id> <bundle>"
  local id="$1" b="$2" pre down_at
  mkdir -p "$b"
  pre="$(ceph_osd_state "$id")" || die "取不到 osd.${id} 狀態"
  _inject_active_add "$b" osd-down "$id" "$id"
  _inject_push_rollback "$b"
  ceph_daemon_stop "$id"
  if ! ceph_wait_osd_down "$id" "$pre" "$OSD_DOWN_SECS"; then
    log "osd.${id} 在 ${OSD_DOWN_SECS}s 內未判 down"
    return 1
  fi
  down_at="$(_inject_record_down "$b" "$id" osd-down)"
  ceph_osd_out "$id"
  printf 'osd-down: OK osd.%s down_map_epoch=%s\n' "$id" "$down_at"
}

_inject_osd_start_only() { # <osd-id> <bundle>：只把 daemon 拉回來（chaos 用，不 in）
  local id="$1" b="$2" st up_from
  ceph_daemon_start "$id"
  if ! _inject_wait_up_now "$id" "$OSD_UP_SECS"; then
    log "osd.${id} 在 ${OSD_UP_SECS}s 內未回 up"
    return 1
  fi
  st="$(ceph_osd_state "$id")" || die "取不到 osd.${id} 狀態"
  up_from="$(_ceph_state_field "$st" up_from)"
  _inject_active_del "$b" chaos-osd-stop "$id"
  _inject_active_del "$b" osd-down "$id"
  printf '%s\n' "${up_from:-0}"
}

fault_osd_down_recover() {
  _inject_require_confirm
  [ $# -eq 2 ] || die "用法：fault_osd_down_recover <osd-id> <bundle>"
  local id="$1" b="$2" up_from
  up_from="$(_inject_osd_start_only "$id" "$b")" || return 1
  ceph_osd_in "$id"
  inject_event "$b" osd-down-recover osd="$id" map_epoch="${up_from:-0}"
  printf 'osd-down-recover: OK osd.%s up_map_epoch=%s\n' "$id" "${up_from:-0}"
}

# =============================================================================
# 狀態機 3：node network isolation
# =============================================================================

# _inject_node_isolate_core <node> <bundle> <guard-secs> <registry-kind> [rack]
#   順序固定：解析 endpoint → pre-state → 前置探測（必須通）→ **guard 武裝** →
#   套 chain → 三段驗證（endpoint 不通 + node_ssh 仍通 + OSD 判 down）。
#   rc 0 = 注入且驗證通過；rc 1 = 驗證未過（已就地回退）。
_inject_node_isolate_core() {
  local node="$1" b="$2" gsecs="$3" kind="$4" rack="${5:-}" id ep
  _inject_tree_load
  id="$(_inject_osd_for_node "$node")"
  ep="$(_inject_osd_endpoint "$id")"
  _ISO_IP="${ep%% *}"; _ISO_PORT="${ep##* }"
  _ISO_ID="$id"
  _ISO_PRE="$(ceph_osd_state "$id")" || die "取不到 osd.${id} 狀態"
  if ! _inject_probe_open "$_ISO_IP" "$_ISO_PORT"; then
    die "注入前 ${node} 的 endpoint ${_ISO_IP}:${_ISO_PORT} 就不通——注入後的「不通」無從解讀"
  fi
  _inject_active_add "$b" "$kind" "$node" "$id" "$rack"
  _inject_push_rollback "$b"
  _inject_arm_guard "$node" "$gsecs"     # guard 必須先於 chain
  _inject_arm_chain "$node"
  inject_event "$b" "${kind}-applied" node="$node" osd="$id" \
    endpoint="${_ISO_IP}:${_ISO_PORT}" guard_secs="$gsecs"
  if ! with_deadline "$ISO_CLOSED_SECS" _inject_probe_closed; then
    log "隔離驗證失敗：${node} 的 ${_ISO_IP}:${_ISO_PORT} 仍然通"
    return 1
  fi
  if ! _inject_ssh_alive "$node"; then
    log "隔離驗證失敗：${node} 的 node_ssh 也斷了（規則把 bastion 一起關在外面）"
    return 1
  fi
  if ! ceph_wait_osd_down "$_ISO_ID" "$_ISO_PRE" "$ISO_DOWN_SECS"; then
    log "隔離驗證失敗：osd.${_ISO_ID} 在 ${ISO_DOWN_SECS}s 內未判 down"
    return 1
  fi
  return 0
}

# _inject_node_flush <node> <bundle> <kind>：kill guard → flush → 驗恢復。
#   rc 0 = 恢復；rc 4 = guard 曾觸發（安全網啟動 = attempt taint）；rc 1 = 未恢復。
_inject_node_flush() {
  local node="$1" b="$2" kind="$3" guard fired rc=0
  guard="$(_inject_guard_id "$node")"
  remote_bg_stop "$node" "$guard" >/dev/null 2>&1 || log "guard 停止失敗（${node}）"
  fired="$(_inject_flush_chain "$node" "$guard")" || rc=1
  _inject_active_del "$b" "$kind" "$node"
  if ! with_deadline "$ISO_OPEN_SECS" _inject_probe_reopen; then
    log "heal 後 ${node} 的 ${_ISO_IP}:${_ISO_PORT} 仍不通"
    rc=1
  fi
  if [ "$rc" -eq 0 ] && [ "$fired" = "fired=1" ]; then
    inject_taint "$b" "isolation guard 觸發（${node}）——安全網先於正常 heal 動作"
    rc=4
  fi
  return "$rc"
}

# _inject_node_prepare_heal <node> <bundle> <kind>：flush 前先把 endpoint 查回來
#   （heal 可能在新的 process 裡跑，_ISO_* 不一定還在）。
_inject_node_prepare_heal() {
  local node="$1" id ep
  _inject_tree_load
  id="$(_inject_osd_for_node "$node")"
  # 先比對「舊的」_ISO_ID 再覆寫——反過來寫的話 cache 永遠命中，heal 會拿上一台的
  # endpoint 去探測，探通了還以為自己恢復了（假陽性）。
  ep="$(_inject_endpoint_cached "$id")"
  _ISO_ID="$id"
  _ISO_IP="${ep%% *}"; _ISO_PORT="${ep##* }"
  [ -n "$_ISO_IP" ] && [ -n "$_ISO_PORT" ] || die "heal 前取不到 osd.${id} 的 endpoint"
}

# heal 期間不能再打 `ceph osd metadata`（OSD 可能還 down），改用 inventory 的 private IP
# + 注入時記下的 port；沒有記錄時退回 metadata。
_inject_endpoint_cached() { # <osd-id>
  if [ -n "${_ISO_IP:-}" ] && [ -n "${_ISO_PORT:-}" ] && [ "${_ISO_ID:-}" = "$1" ]; then
    printf '%s %s\n' "$_ISO_IP" "$_ISO_PORT"
    return 0
  fi
  _inject_osd_endpoint "$1"
}

fault_node_isolate() {
  _inject_require_confirm
  [ $# -eq 2 ] || die "用法：fault_node_isolate <node> <bundle>"
  local node="$1" b="$2" gsecs down_at
  mkdir -p "$b"
  gsecs="$(inject_guard_secs)"
  if ! _inject_node_isolate_core "$node" "$b" "$gsecs" node-isolate; then
    _inject_node_rollback "$node" "$b"
    inject_taint "$b" "node-isolate 驗證未過（${node}），已回退"
    printf 'node-isolate: TAINT %s\n' "$node"
    return 1
  fi
  down_at="$(_inject_record_down "$b" "$_ISO_ID" node-isolate node="$node")"
  ceph_osd_out "$_ISO_ID"          # commit：managed-out
  printf 'node-isolate: OK %s osd.%s down_map_epoch=%s\n' "$node" "$_ISO_ID" "$down_at"
}

# _inject_node_rollback <node> <bundle>：注入失敗/chaos 用的回退（不 osd in）。
_inject_node_rollback() {
  local node="$1" b="$2" rc=0
  _inject_node_prepare_heal "$node" "$b"
  _inject_node_flush "$node" "$b" node-isolate || rc=$?
  _inject_active_del "$b" chaos-isolate "$node"
  _inject_active_del "$b" rack-isolate "$node"
  _inject_wait_up_now "$_ISO_ID" "$ISO_UP_SECS" \
    || log "回退後 osd.${_ISO_ID} 尚未回 up（交由 safety gate/watchdog）"
  return "$rc"
}

fault_node_heal() {
  _inject_require_confirm
  [ $# -eq 2 ] || die "用法：fault_node_heal <node> <bundle>"
  local node="$1" b="$2" rc=0 st up_from
  mkdir -p "$b"
  _inject_node_prepare_heal "$node" "$b"
  _inject_node_flush "$node" "$b" node-isolate || rc=$?
  [ "$rc" -eq 1 ] && { printf 'node-heal: FAIL %s\n' "$node"; return 1; }
  if ! _inject_wait_up_now "$_ISO_ID" "$ISO_UP_SECS"; then
    log "heal 後 osd.${_ISO_ID} 在 ${ISO_UP_SECS}s 內未回 up"
    printf 'node-heal: FAIL %s\n' "$node"
    return 1
  fi
  st="$(ceph_osd_state "$_ISO_ID")" || die "取不到 osd.${_ISO_ID} 狀態"
  up_from="$(_ceph_state_field "$st" up_from)"
  ceph_osd_in "$_ISO_ID"
  inject_event "$b" node-heal node="$node" osd="$_ISO_ID" map_epoch="${up_from:-0}" \
    heal_t="$(date +%s)"
  inject_timeline_set "$b" heal_t="$(date +%s)"
  if [ "$rc" -eq 4 ]; then
    printf 'node-heal: TAINT %s guard-fired\n' "$node"
    return 4
  fi
  printf 'node-heal: OK %s\n' "$node"
}

# =============================================================================
# 狀態機 4：rack isolation（prepare → verify barrier → commit）
# =============================================================================

fault_rack_isolate() {
  _inject_require_confirm
  [ $# -eq 2 ] || die "用法：fault_rack_isolate <rack> <bundle>"
  local rack="$1" b="$2" gsecs n i n1 n2 id1 id2 ip1 port1 ip2 port2 pre1 pre2
  local t_first t_last skew ok1 ok2 down1 down2
  mkdir -p "$b"
  gsecs="$(inject_guard_secs)"
  i=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    i=$((i + 1))
    [ "$i" -eq 1 ] && n1="$n"
    [ "$i" -eq 2 ] && n2="$n"
  done <<< "$(_inject_nodes_in_rack "$rack")"
  [ "$i" -eq 2 ] || die "rack ${rack} 有 ${i} 台 node（期望 2）"

  # 解析（都在 prepare 之前——隔離之後就查不到 metadata 了）
  local ep
  _inject_tree_load
  id1="$(_inject_osd_for_node "$n1")"
  ep="$(_inject_osd_endpoint "$id1")"; ip1="${ep%% *}"; port1="${ep##* }"
  pre1="$(ceph_osd_state "$id1")" || die "取不到 osd.${id1} 狀態"
  id2="$(_inject_osd_for_node "$n2")"
  ep="$(_inject_osd_endpoint "$id2")"; ip2="${ep%% *}"; port2="${ep##* }"
  pre2="$(ceph_osd_state "$id2")" || die "取不到 osd.${id2} 狀態"
  _inject_probe_open "$ip1" "$port1" \
    || die "注入前 ${n1} 的 endpoint 就不通——注入後的「不通」無從解讀"
  _inject_probe_open "$ip2" "$port2" \
    || die "注入前 ${n2} 的 endpoint 就不通——注入後的「不通」無從解讀"

  # --- prepare：兩台各自 guard → chain（間隔要 <5s）---------------------------
  _inject_active_add "$b" rack-isolate "$n1" "$id1" "$rack"
  _inject_active_add "$b" rack-isolate "$n2" "$id2" "$rack"
  _inject_push_rollback "$b"
  t_first="$(date +%s)"
  _inject_arm_guard "$n1" "$gsecs"
  _inject_arm_chain "$n1"
  _inject_arm_guard "$n2" "$gsecs"
  _inject_arm_chain "$n2"
  t_last="$(date +%s)"
  skew=$((t_last - t_first))
  inject_timeline_set "$b" rack="$rack" prepare_skew_s="$skew" \
    rack_osds="${id1},${id2}"
  inject_event "$b" rack-isolate-prepared rack="$rack" nodes="${n1},${n2}" \
    osds="${id1},${id2}" prepare_skew_s="$skew"

  # --- verify barrier：兩台都過才算成功 ---------------------------------------
  ok1=0; ok2=0
  _ISO_IP="$ip1"; _ISO_PORT="$port1"
  if with_deadline "$ISO_CLOSED_SECS" _inject_probe_closed \
     && _inject_ssh_alive "$n1" \
     && ceph_wait_osd_down "$id1" "$pre1" "$ISO_DOWN_SECS"; then
    ok1=1
    down1="$(_ceph_state_field "$(ceph_osd_state "$id1")" down_at)"
  fi
  _ISO_IP="$ip2"; _ISO_PORT="$port2"
  if with_deadline "$ISO_CLOSED_SECS" _inject_probe_closed \
     && _inject_ssh_alive "$n2" \
     && ceph_wait_osd_down "$id2" "$pre2" "$ISO_DOWN_SECS"; then
    ok2=1
    down2="$(_ceph_state_field "$(ceph_osd_state "$id2")" down_at)"
  fi
  if [ "$ok1" -ne 1 ] || [ "$ok2" -ne 1 ]; then
    log "rack barrier 失敗（${n1}=${ok1} ${n2}=${ok2}）——立即回退兩台，不得降級成單 node fault"
    _ISO_ID=""; _ISO_IP="$ip1"; _ISO_PORT="$port1"; _ISO_ID="$id1"
    _inject_node_rollback "$n1" "$b" || true
    _ISO_IP="$ip2"; _ISO_PORT="$port2"; _ISO_ID="$id2"
    _inject_node_rollback "$n2" "$b" || true
    inject_taint "$b" "rack-isolate barrier 失敗（${n1}=${ok1} ${n2}=${ok2}）"
    printf 'rack-isolate: TAINT %s barrier\n' "$rack"
    return 4
  fi
  if [ "$skew" -gt "$RACK_PREPARE_MAX_SKEW_SECS" ]; then
    inject_taint "$b" "rack prepare 間隔 ${skew}s > ${RACK_PREPARE_MAX_SKEW_SECS}s（兩台不算同時失效）"
  fi

  # --- commit：一次 out 兩顆（backfill 起點單一）-------------------------------
  local t
  t="$(date +%s)"
  inject_event "$b" rack-isolate rack="$rack" osds="${id1},${id2}" \
    down_map_epoch_1="${down1:-0}" down_map_epoch_2="${down2:-0}" down_epoch_t="$t"
  inject_timeline_set "$b" down_epoch_t="$t" down_map_epoch="${down1:-0}" \
    down_map_epoch_2="${down2:-0}"
  ceph_osd_out "$id1" "$id2"
  printf 'rack-isolate: OK %s osds=%s,%s down_map_epoch=%s\n' \
    "$rack" "$id1" "$id2" "${down1:-0}"
}

fault_rack_heal() {
  _inject_require_confirm
  [ $# -eq 2 ] || die "用法：fault_rack_heal <rack> <bundle>"
  local rack="$1" b="$2" n i n1 n2 id1 id2 rc=0 sub
  mkdir -p "$b"
  i=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    i=$((i + 1))
    [ "$i" -eq 1 ] && n1="$n"
    [ "$i" -eq 2 ] && n2="$n"
  done <<< "$(_inject_nodes_in_rack "$rack")"
  [ "$i" -eq 2 ] || die "rack ${rack} 有 ${i} 台 node（期望 2）"
  _inject_tree_load
  id1="$(_inject_osd_for_node "$n1")"
  id2="$(_inject_osd_for_node "$n2")"

  for sub in "$n1" "$n2"; do
    _inject_node_prepare_heal "$sub" "$b"
    _inject_node_flush "$sub" "$b" rack-isolate || rc=$?
  done
  _inject_wait_up_now "$id1" "$ISO_UP_SECS" || rc=1
  _inject_wait_up_now "$id2" "$ISO_UP_SECS" || rc=1
  if [ "$rc" -eq 1 ]; then
    printf 'rack-heal: FAIL %s\n' "$rack"
    return 1
  fi
  ceph_osd_in "$id1" "$id2"        # 一次 in 兩顆
  inject_event "$b" rack-heal rack="$rack" osds="${id1},${id2}" heal_t="$(date +%s)"
  inject_timeline_set "$b" heal_t="$(date +%s)"
  if [ "$rc" -eq 4 ]; then
    printf 'rack-heal: TAINT %s guard-fired\n' "$rack"
    return 4
  fi
  printf 'rack-heal: OK %s\n' "$rack"
}

# =============================================================================
# chaos：固定 seed 事件序列（min_size 安全不變條件）
# =============================================================================

_inject_chaos_params() {
  printf '{"gap_min": %s, "gap_max": %s, "hold_min": %s, "hold_max": %s, "rack_switch_gap": %s, "tail_margin": %s}\n' \
    "$CHAOS_GAP_MIN" "$CHAOS_GAP_MAX" "$CHAOS_HOLD_MIN" "$CHAOS_HOLD_MAX" \
    "$CHAOS_RACK_SWITCH_GAP" "$CHAOS_TAIL_MARGIN"
}

# _inject_topology：`[{node, rack, osd}]`；測試可用 INJECT_TOPOLOGY_JSON 注入。
_inject_topology() {
  if [ -n "${INJECT_TOPOLOGY_JSON:-}" ]; then
    cat "$INJECT_TOPOLOGY_JSON"
    return 0
  fi
  local n rack id first=1
  _inject_tree_load
  printf '['
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    rack="$(inv_rack "$n")"
    id="$(printf '%s\n' "$_INJECT_TREE_CACHE" | awk -v h="$n" '$1 == h {print $3}')"
    [ -n "$id" ] || die "osd tree 內找不到 host ${n}"
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"node": "%s", "rack": "%s", "osd": %s}' "$n" "$rack" "$id"
  done <<< "$(inv_names osd)"
  printf ']\n'
}

chaos_generate() { # <seed> <duration> <outfile>
  [ $# -eq 3 ] || die "用法：chaos_generate <seed> <duration> <outfile>"
  local n
  mkdir -p "$(dirname "$3")"
  n="$(_inject_topology | _inject_py chaos-gen "$1" "$2" "$3" "$(_inject_chaos_params)")" \
    || die "chaos 事件序列產生失敗（seed=${1} duration=${2}）"
  log "chaos 事件序列：seed=${1} duration=${2} events=${n} → ${3}"
  printf '%s\n' "$n"
}

inject_chaos_verify() { # <event-seq.json>
  [ $# -eq 1 ] || die "用法：inject_chaos_verify <event-seq.json>"
  _inject_py chaos-verify "$1"
}

# chaos_prepare_seq <seed> <duration> <bundle>：既有序列（同 seed/duration）沿用，
# 否則重新產生——序列是 resume 的唯一 SoT。stdout = 序列檔路徑。
chaos_prepare_seq() {
  [ $# -eq 3 ] || die "用法：chaos_prepare_seq <seed> <duration> <bundle>"
  local seed="$1" dur="$2" b="$3" f state
  mkdir -p "$b"
  f="$b/event-seq.json"
  state="$(_inject_py chaos-meta "$f" "$seed" "$dur")" || state="missing"
  if [ "$state" = "match" ] && inject_chaos_verify "$f" >/dev/null 2>&1; then
    log "沿用既有 chaos 事件序列（resume）：${f}"
  else
    chaos_generate "$seed" "$dur" "$f" >/dev/null
  fi
  printf '%s\n' "$f"
}

_chaos_wait_until() { # <start-epoch> <offset>
  [ "${CHAOS_NO_SLEEP:-}" = "1" ] && return 0
  local target now
  target=$(( $1 + $2 ))
  while :; do
    now="$(date +%s)"
    [ "$now" -ge "$target" ] && return 0
    sleep 1
  done
}

chaos_run() { # <seed> <duration> <bundle>
  _inject_require_confirm
  [ $# -eq 3 ] || die "用法：chaos_run <seed> <duration> <bundle>"
  local seed="$1" dur="$2" b="$3" f start gsecs n=0
  local t action node osd rack pre down_at up_from
  mkdir -p "$b"
  f="$(chaos_prepare_seq "$seed" "$dur" "$b")"
  # chaos 沒有 measurement cap：guard deadline = duration + 600（plan v4.2/F5-9）
  gsecs="$(inject_guard_secs "$dur" -)"
  _inject_push_rollback "$b"
  start="$(date +%s)"
  inject_timeline_set "$b" chaos_seed="$seed" chaos_duration_s="$dur" chaos_t0="$start"
  while IFS=$'\t' read -r t action node osd rack; do
    [ -n "$action" ] || continue
    _chaos_wait_until "$start" "$t"
    case "$action" in
      osd-stop)
        pre="$(ceph_osd_state "$osd")" || die "取不到 osd.${osd} 狀態"
        _inject_active_add "$b" chaos-osd-stop "$osd" "$osd" "$rack"
        ceph_daemon_stop "$osd"
        ceph_wait_osd_down "$osd" "$pre" "$OSD_DOWN_SECS" \
          || log "chaos：osd.${osd} 未在期限內判 down（續跑序列）"
        down_at="$(_ceph_state_field "$(ceph_osd_state "$osd")" down_at)"
        inject_event "$b" chaos-event action="$action" node="$node" osd="$osd" \
          rack="$rack" seq_t="$t" map_epoch="${down_at:-0}"
        ;;
      osd-start)
        up_from="$(_inject_osd_start_only "$osd" "$b")" || up_from=0
        inject_event "$b" chaos-event action="$action" node="$node" osd="$osd" \
          rack="$rack" seq_t="$t" map_epoch="${up_from:-0}"
        ;;
      node-isolate)
        if _inject_node_isolate_core "$node" "$b" "$gsecs" chaos-isolate "$rack"; then
          down_at="$(_ceph_state_field "$(ceph_osd_state "$_ISO_ID")" down_at)"
        else
          log "chaos：${node} 隔離驗證未過，就地回退（續跑序列）"
          _inject_node_rollback "$node" "$b" || true
          down_at=0
        fi
        inject_event "$b" chaos-event action="$action" node="$node" osd="$osd" \
          rack="$rack" seq_t="$t" map_epoch="${down_at:-0}"
        ;;
      node-heal)
        _inject_node_rollback "$node" "$b" || true
        up_from="$(_ceph_state_field "$(ceph_osd_state "$_ISO_ID")" up_from)"
        inject_event "$b" chaos-event action="$action" node="$node" osd="$osd" \
          rack="$rack" seq_t="$t" map_epoch="${up_from:-0}"
        ;;
      *) die "chaos：未知 action ${action}" ;;
    esac
    n=$((n + 1))
  done < <(_inject_py chaos-events "$f")
  inject_rollback_all "$b" >/dev/null      # 結束全回退
  inject_timeline_set "$b" chaos_events="$n" chaos_end_t="$(date +%s)"
  printf 'chaos: OK seed=%s events=%s\n' "$seed" "$n"
}

# =============================================================================
# cleanup proof（fault/chaos schema 的必備檔）
# =============================================================================

# 遠端探針：殘留規則數 + 還活著的 guard 數。`\$f`/`\$(cat ...)` 刻意留給遠端 shell 展開。
_inject_probe_script() {
  cat <<EOF
printf iso-rules=
sudo iptables -S ${INJECT_CHAIN} 2>/dev/null | grep -c -- "-A ${INJECT_CHAIN}" || true
printf guards=
for f in ${BG_REGISTRY_DIR}/guard-*.pid; do [ -e "\$f" ] || continue; sudo kill -0 "\$(cat "\$f")" 2>/dev/null && echo x; done | wc -l | tr -d " "
echo mclock-iso: probe-done
EOF
}

inject_cleanup_proof() { # <bundle>
  [ $# -eq 1 ] || die "用法：inject_cleanup_proof <bundle>"
  local b="$1" n out iso guards specs=() line
  mkdir -p "$b"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if ! out="$(_node_sh "$n" "$INJECT_CMD_SECS" "$(_inject_probe_script)")"; then
      log "cleanup proof：${n} 查詢失敗，視為髒"
      out="iso-rules=99
guards=99"
    fi
    iso="$(printf '%s\n' "$out" | sed -n 's/^iso-rules=//p' | head -1)"
    guards="$(printf '%s\n' "$out" | sed -n 's/^guards=//p' | head -1)"
    specs[${#specs[@]}]="${n}:${iso:-99}:${guards:-99}"
  done <<< "$(inv_names osd)"
  line="$(ceph_adm "ceph osd dump --format json" | _ceph_py osds-in)" \
    || die "cleanup proof：取不到 osd dump"
  out="$(_inject_py proof "$b/cleanup-proof.json" "$line" "${specs[@]+"${specs[@]}"}")" \
    || die "cleanup-proof.json 寫入失敗"
  if [ "$out" = "ok" ]; then
    printf 'inject-cleanup: PASS\n'
    return 0
  fi
  printf 'inject-cleanup: FAIL\n'
  return 1
}
