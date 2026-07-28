#!/usr/bin/env bash
# ceph-mclock-profiles — Ceph 部署鏈（Task 5）與 QoS gate / capacity / 健康判準（Task 6）。
# bash 3.2 相容；stdout 只放機器要抓的那行，log/progress 一律 stderr。
#
# 對外介面（Task 5 部署鏈，每步冪等 + 驗證）：
#   ceph_hosts                     11 台 Ceph host（admin + mon×2 + osd×8；不含 fio client）
#   ceph_keygen_local              bastion 端產 campaign 專用 ed25519 keypair（冪等）
#   ceph_push_campaign_key         pubkey fanout 11 台 + 兩個 key 檔送 admin + owner/mode/內容驗證
#   ceph_gen_campaign_key          = keygen_local + push（calibrate 用的複合入口）
#   ceph_bootstrap                 cephadm bootstrap（--image 在 bootstrap 之前）
#   ceph_add_hosts                 先全部 orch host add，後逐台 cephadm check-host
#   ceph_apply_mons                mon placement 明列三台 → quorum 恰為那三名
#   ceph_apply_osds                逐台 orch daemon add osd <host>:<dev>（禁 all-available-devices）
#   ceph_verify_versions           ceph versions 全 19.2.2 + orch ps image 相符
#   ceph_setup_crush               4 rack × 2 host + rule mclock-rack（failure domain = rack）
#   ceph_create_pool               pool + size 3 + autoscaler off + rbd pool init
#   ceph_setup_client_auth         client auth/conf 分發 + 拋棄式 smoke image 的 map/讀寫/unmap gate
#   ceph_campaign_flags/unflags    campaign 固定設定（設定當下即註冊對稱 unset）
#
# 對外介面（Task 6）：
#   ceph_set_profile <profile>              切換 mclock profile（冪等；gate 之前呼叫）
#   ceph_qos_gate <profile> [bundle]        每 execution preflight 的驗證集合 + settle + 證據 JSON
#   ceph_capacity_provenance [out]          per-OSD bench 來源證據
#   ceph_capacity_decide [prov] [out]       五狀態決策表 + 跨 8 顆 CoV gate
#   ceph_lock_capacity [lock]               逐顆 set 值 + skip_benchmark=true + 回讀驗證
#   ceph_verify_no_rebench <id> <node> <pre-boot-id> [out]
#   ceph_wait_recovery_complete <deadline-epoch> / ceph_wait_final_clean [progress-secs]
#   ceph_osd_state / ceph_wait_osd_down / ceph_wait_osd_up / ceph_wait_pgs_active_for_osd
#   ceph_daemon_stop|start / ceph_osd_out|in / ceph_health_snapshot / ceph_check_laggy
#
# clean 判準（spec §5，全檔唯一定義，不可用字面 health 字串）：
#   recovery_complete = 當下 up set 下 PG 100% active+clean
#   final_clean       = OSD 全 up+in + PG 100% active+clean + health 只剩自設 noscrub/nodeep-scrub
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR

[ -n "${MCLOCK_CEPH_LOADED:-}" ] && return 0
MCLOCK_CEPH_LOADED=1

# shellcheck source=./inventory.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inventory.sh"

# --- 常數（plan Global Constraints）------------------------------------------
CEPH_IMAGE="${CEPH_IMAGE:-quay.io/ceph/ceph:v19.2.2}"
CEPH_EXPECT_VERSION="${CEPH_EXPECT_VERSION:-19.2.2}"
CEPH_POOL="${CEPH_POOL:-mclock}"
CEPH_CRUSH_RULE="${CEPH_CRUSH_RULE:-mclock-rack}"
CEPH_PG_NUM="${CEPH_PG_NUM:-128}"
CEPH_POOL_SIZE="${CEPH_POOL_SIZE:-3}"
CEPH_CLIENT_ID="${CEPH_CLIENT_ID:-mclock-fio}"
CAMPAIGN_KEY="${CAMPAIGN_KEY:-$MCLOCK_ROOT/.ssh/mclock_campaign}"
CAMPAIGN_KEY_REMOTE="${CAMPAIGN_KEY_REMOTE:-/home/ikaros/.ssh/mclock_campaign}"
CEPH_CMD_TIMEOUT="${CEPH_CMD_TIMEOUT:-120}"
CEPH_BOOTSTRAP_SECS="${CEPH_BOOTSTRAP_SECS:-1800}"
MON_QUORUM_SECS="${MON_QUORUM_SECS:-600}"
OSD_READY_SECS="${OSD_READY_SECS:-1800}"
QOS_CONVERGE_SECS="${QOS_CONVERGE_SECS:-300}"
QOS_SETTLE_SECS="${QOS_SETTLE_SECS:-30}"
# v19.2.2 編譯預設值：capacity 若剛好等於它，每次 boot 都會重跑 bench（H-012）
CEPH_CAPACITY_DEFAULT="${CEPH_CAPACITY_DEFAULT:-21500}"
CEPH_SEQ_BW_SSD="${CEPH_SEQ_BW_SSD:-1258291200}"
CEPH_FIO_DERIVED_CAP="${CEPH_FIO_DERIVED_CAP:-72000}"
CAPACITY_COV_LIMIT="${CAPACITY_COV_LIMIT:-0.20}"
# results/ 底下的三個契約檔一律「呼叫當下」才解析路徑——入口腳本常在 source 之後
# 才決定 RESULTS_DIR，寫死在載入期會拿到過期路徑。
capacity_lock_path() { printf '%s\n' "${CAPACITY_LOCK_JSON:-$RESULTS_DIR/capacity-lock.json}"; }
capacity_provenance_path() {
  printf '%s\n' "${CAPACITY_PROVENANCE_JSON:-$RESULTS_DIR/capacity-provenance.json}"
}
# Task 7 的 fio_raw_nvme_baseline 契約：{"<node-name>": {"iops": <float>}, ...}
raw_nvme_baseline_path() {
  printf '%s\n' "${RAW_NVME_BASELINE_JSON:-$RESULTS_DIR/raw-nvme-baseline.json}"
}
# H-013 positive control：本次 boot 一定看得到的 log（撈不到 = log 管道壞掉，不是「沒重跑」）
CEPH_BOOT_MARKERS="${CEPH_BOOT_MARKERS:-done with init, starting boot process|osd_max_backfills set to|osd_bandwidth_cost_per_io}"

# --- 遠端執行 helper ----------------------------------------------------------

# _node_run <node> <secs> <cmd>：單一指令（引號原樣交給遠端 shell），遠端包 timeout。
_node_run() {
  [ $# -eq 3 ] || die "用法：_node_run <node> <secs> <cmd>"
  case "$2" in ''|*[!0-9]*) die "_node_run：secs 必須是整數秒（got=${2}）" ;; esac
  # `< /dev/null` 在此結構性隔離 stdin：ceph_adm 這類包裝在 `while read` 迴圈裡被呼叫時，
  # 底下的 ssh 會把迴圈的 herestring 吃光、只跑第一圈。真機上就是這樣造成
  # `ceph_lock_capacity` 只鎖到 osd.0（其餘七顆的 skip_benchmark 沒設）。
  # 指令一律以參數傳入、從不從 stdin 讀，所以這裡隔離永遠安全。
  node_ssh "$1" "timeout $2 $3" < /dev/null
}

# _node_sh <node> <secs> <cmd>：多段指令（含 `;`／pipe）以 sh -c 整體包 timeout。
# 指令內不得含單引號（會破壞包裝）——需要傳資料一律走 base64。
_node_sh() {
  [ $# -eq 3 ] || die "用法：_node_sh <node> <secs> <cmd>"
  case "$2" in ''|*[!0-9]*) die "_node_sh：secs 必須是整數秒（got=${2}）" ;; esac
  case "$3" in *"'"*) die "_node_sh：遠端指令不得含單引號" ;; esac
  node_ssh "$1" "timeout $2 sh -c '$3'" < /dev/null  # 同 _node_run：結構性隔離 stdin
}

# ceph_adm <cmd...>：在 admin 上以 sudo 跑 ceph/rbd/cephadm 指令（有界）。
ceph_adm() {
  [ $# -ge 1 ] || die "用法：ceph_adm <cmd...>"
  _node_run "$ADMIN_NAME" "$CEPH_CMD_TIMEOUT" "sudo $*"
}

# ceph_adm_to <secs> <cmd...>：同上，指定較長的逾時（bootstrap / daemon add / pool init）。
ceph_adm_to() {
  [ $# -ge 2 ] || die "用法：ceph_adm_to <secs> <cmd...>"
  local secs="$1"; shift
  _node_run "$ADMIN_NAME" "$secs" "sudo $*"
}

_ceph_scratch() {
  if [ -z "${_CEPH_SCRATCH:-}" ]; then
    _CEPH_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/mclock-ceph.XXXXXX")" \
      || die "無法建立暫存目錄"
    cleanup_push "rm -rf '$_CEPH_SCRATCH'"
  fi
  printf '%s\n' "$_CEPH_SCRATCH"
}

_sha256() { # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

_b64() { base64 < "$1" | tr -d '\n'; }

# ceph_fsid：cephadm 部署後的 cluster fsid（OSD 的 systemd unit 名要用），快取。
ceph_fsid() {
  local _raw
  if [ -z "${CEPH_FSID:-}" ]; then
    # 取值與 trim 分兩步：`$(cmd | tr)` 的 rc 來自 tr（恆 0），`|| die` 會失效。
    _raw="$(ceph_adm "ceph fsid")" || die "取不到 ceph fsid"
    CEPH_FSID="$(printf '%s' "$_raw" | tr -d ' \r\n')"
    [ -n "$CEPH_FSID" ] || die "ceph fsid 是空的"
    export CEPH_FSID
  fi
  printf '%s\n' "$CEPH_FSID"
}

# ceph_osd_ids：八顆 OSD 的 id（空白分隔），快取。
ceph_osd_ids() {
  local _raw
  if [ -z "${CEPH_OSD_IDS:-}" ]; then
    _raw="$(ceph_adm "ceph osd ls")" || die "取不到 osd 清單"
    CEPH_OSD_IDS="$(printf '%s' "$_raw" | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')"
    [ -n "$CEPH_OSD_IDS" ] || die "ceph osd ls 是空的"
    export CEPH_OSD_IDS
  fi
  printf '%s\n' "$CEPH_OSD_IDS"
}

# --- python 解析器（所有 JSON 判讀集中在這裡）---------------------------------
_CEPH_PY_SRC="$(cat <<'PY'
import json
import os
import re
import sys

PROFILES = {
    "balanced": ((0.5, 1, 0.0), (0.5, 1, 0.0), (0.0, 1, 0.9)),
    "high_client_ops": ((0.6, 2, 0.0), (0.4, 1, 0.0), (0.0, 1, 0.7)),
    "high_recovery_ops": ((0.3, 1, 0.0), (0.7, 2, 0.0), (0.0, 1, 0.0)),
}
CLASSES = ("client", "background_recovery", "background_best_effort")
NINE_KEYS = ["osd_mclock_scheduler_%s_%s" % (c, f)
             for c in CLASSES for f in ("res", "wgt", "lim")]
# 這些 key 只要出現在 mon config store 就代表有外部 override（H-009 / H-018）
FORBIDDEN_IN_MON_STORE = NINE_KEYS + [
    "osd_max_backfills", "osd_recovery_max_active",
    "osd_recovery_max_active_ssd", "osd_recovery_max_active_hdd",
]
COVARIATE_KEYS = ["osd_recovery_sleep_ssd", "osd_delete_sleep_ssd",
                  "osd_snap_trim_sleep_ssd", "osd_scrub_sleep",
                  "osd_recovery_max_active", "osd_recovery_max_active_hdd"]


def die(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def load(path):
    with open(path) as fh:
        return json.load(fh)


def load_stdin():
    raw = sys.stdin.read()
    if not raw.strip():
        die("空的 JSON 輸入")
    try:
        return json.loads(raw)
    except ValueError as exc:
        die("JSON 無法解析：%s" % exc)


def dump(path, doc):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(doc, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.rename(tmp, path)


def as_float(v):
    return float(str(v).strip())


def as_bool(v):
    return str(v).strip().lower() in ("true", "1", "yes")


def pg_states(doc):
    pgmap = doc.get("pgmap", {})
    total = 0
    clean = 0
    for entry in pgmap.get("pgs_by_state", []):
        count = int(entry.get("count", 0))
        total += count
        parts = set(entry.get("state_name", "").split("+"))
        if parts == set(("active", "clean")):
            clean += count
    return total, clean


def osdmap(doc):
    om = doc.get("osdmap", {})
    if "osdmap" in om:
        om = om["osdmap"]
    return om


def health_ok_for_campaign(doc):
    """final_clean 的 health 條件：只允許 harness 自設的 noscrub / nodeep-scrub。"""
    allowed_flags = set(("noscrub", "nodeep-scrub"))
    checks = doc.get("health", {}).get("checks", {})
    extra = []
    for key, body in checks.items():
        if key != "OSDMAP_FLAGS":
            extra.append(key)
            continue
        msg = body.get("summary", {}).get("message", "")
        flags = msg.split(" flag(s) set")[0]
        for flag in flags.split(","):
            flag = flag.strip()
            if flag and flag not in allowed_flags:
                extra.append("OSDMAP_FLAGS:%s" % flag)
    return (len(extra) == 0), extra


def cmd_pgs_clean():
    doc = load_stdin()
    total, clean = pg_states(doc)
    pgmap = doc.get("pgmap", {})
    ok = 1 if (total > 0 and total == clean) else 0
    print("%d %d %d %d" % (ok, total - clean,
                           int(pgmap.get("degraded_objects", 0)),
                           int(pgmap.get("misplaced_objects", 0))))


def cmd_final_clean():
    doc = load_stdin()
    total, clean = pg_states(doc)
    om = osdmap(doc)
    num = int(om.get("num_osds", 0))
    up = int(om.get("num_up_osds", 0))
    inn = int(om.get("num_in_osds", 0))
    health_ok, extra = health_ok_for_campaign(doc)
    pgmap = doc.get("pgmap", {})
    ok = 1 if (total > 0 and total == clean and num > 0 and up == num
               and inn == num and health_ok) else 0
    print("%d %d %d %d %d %d %d" % (
        ok, total - clean, int(pgmap.get("degraded_objects", 0)),
        int(pgmap.get("misplaced_objects", 0)), num, up, inn))
    if extra:
        sys.stderr.write("final_clean 未達成的 health 項目：%s\n" % ",".join(extra))


def cmd_health_snapshot(out):
    doc = load_stdin()
    dump(out, {"schema_version": 1,
               "status": doc.get("health", {}).get("status"),
               "checks": doc.get("health", {}).get("checks", {}),
               "osdmap": osdmap(doc),
               "pgmap": doc.get("pgmap", {}),
               "quorum_names": doc.get("quorum_names", [])})


def cmd_quorum_names():
    doc = load_stdin()
    print(" ".join(sorted(doc.get("quorum_names", []))))


def cmd_osd_state(osd_id):
    doc = load_stdin()
    for osd in doc.get("osds", []):
        if int(osd.get("osd", -1)) == int(osd_id):
            print("osd.%d up=%d in=%d up_from=%d up_thru=%d down_at=%d" % (
                int(osd_id), int(osd.get("up", 0)), int(osd.get("in", 0)),
                int(osd.get("up_from", 0)), int(osd.get("up_thru", 0)),
                int(osd.get("down_at", 0))))
            return
    die("osd dump 內找不到 osd.%s" % osd_id)


def cmd_osds_in():
    doc = load_stdin()
    osds = doc.get("osds", [])
    up = sum(1 for o in osds if int(o.get("up", 0)) == 1)
    inn = sum(1 for o in osds if int(o.get("in", 0)) == 1)
    print("%d %d %d" % (len(osds), up, inn))


def cmd_laggy(out):
    doc = load_stdin()
    rows = [{"osd": int(x.get("osd", -1)),
             "laggy_probability": x.get("laggy_probability", 0.0),
             "laggy_interval": x.get("laggy_interval", 0),
             "down_stamp": x.get("down_stamp")}
            for x in doc.get("osd_xinfo", [])]
    dump(out, {"schema_version": 1, "note": "covariate only, never gates", "osds": rows})
    print(len(rows))


def cmd_pgs_active():
    doc = load_stdin()
    stats = doc if isinstance(doc, list) else doc.get("pg_stats", [])
    active = sum(1 for pg in stats if "active" in str(pg.get("state", "")).split("+"))
    print("%d %d" % (len(stats), active))


def _pgs_not_clean(doc):
    stats = doc if isinstance(doc, list) else doc.get("pg_stats", [])
    out = []
    for pg in stats:
        st = str(pg.get("state", "")).split("+")
        if "active" in st and "clean" in st:
            continue
        out.append(pg)
    return out


def cmd_pgs_not_clean():
    # stdout 只放 pgid，一行一個（watchdog 要逐個 repeer）。
    for pg in _pgs_not_clean(load_stdin()):
        pgid = pg.get("pgid")
        if pgid:
            print(pgid)


def cmd_pgs_not_clean_primary():
    # 卡住的 PG 的 primary OSD id；acting_primary 缺就退回 acting[0]。
    for pg in _pgs_not_clean(load_stdin()):
        pri = pg.get("acting_primary")
        if pri is None:
            acting = pg.get("acting") or []
            pri = acting[0] if acting else None
        if pri is not None:
            print(int(pri))


def cmd_versions_check(expect):
    doc = load_stdin()
    bad = []
    seen = set()
    for section, entries in doc.items():
        for ver, count in entries.items():
            if expect not in ver:
                bad.append("%s: %s (%s)" % (section, ver, count))
            if section != "overall":
                seen.add(ver)
    if bad:
        die("ceph versions 不是全部 %s：\n  %s" % (expect, "\n  ".join(bad)))
    # 版本字串含 git commit hash，多於一種 = 同版號但不同 build 混在一起。
    # 這是 image 一致性的權威判準（container image ref 因 tag/digest 混用不可靠）。
    if len(seen) > 1:
        die("ceph daemon 跑在同版號的不同 build 上：\n  %s" % "\n  ".join(sorted(seen)))
    print("ok")


def cmd_orch_image_check(image):
    """Ceph daemon 是否都跑同一份 ceph image。

    不比對字面 tag：cephadm 拉完會把 image 正規化成 digest
    （`quay.io/ceph/ceph@sha256:...`），而且 tag 是 multi-arch manifest list，
    其 digest 與 amd64 image 的 digest 本來就不同——比 tag 永遠不會成立。
    也不能把 monitoring stack（prometheus / grafana / alertmanager /
    node-exporter）算進來，它們本來就用別的 image。
    同一份 image 也可能同時被 tag 與 digest 引用（bootstrap 當下建的 daemon 記 tag、
    之後拉過的記 digest），所以連「ref 字串一致」都不能要求。
    **build 一致性由 `ceph versions` 把關**——它的版本字串含 git commit hash，
    全部 daemon 歸在同一個 key 就證明是同一份 build（見 cmd_versions_check）。
    這裡只確認 ceph daemon 都來自預期的 repo（抓「被指到別的 registry」）。
    """
    doc = load_stdin()
    repo = image.split("@")[0].rsplit(":", 1)[0]  # quay.io/ceph/ceph:v19.2.2 → quay.io/ceph/ceph
    ceph_types = ("mon", "mgr", "osd", "mds", "rgw", "crash", "ceph-exporter")
    bad = []
    for daemon in doc:
        if (daemon.get("daemon_type") or "") not in ceph_types:
            continue
        name = daemon.get("container_image_name") or ""
        if not name.startswith(repo + "@") and not name.startswith(repo + ":"):
            bad.append("%s@%s: %s" % (daemon.get("daemon_name"),
                                      daemon.get("hostname"), name))
    if bad:
        die("ceph daemon 的 image 不是來自 %s：\n  %s" % (repo, "\n  ".join(bad)))
    print("ok")


def cmd_host_names():
    doc = load_stdin()
    for host in doc:
        print(host.get("hostname", ""))


def cmd_daemon_hosts():
    """orch ps JSON → 每個 daemon 所在 host（一行一個，去重）。"""
    doc = load_stdin()
    seen = []
    for daemon in doc:
        h = daemon.get("hostname") or ""
        if h and h not in seen:
            seen.append(h)
    for h in seen:
        print(h)


def cmd_osd_tree_hosts():
    """印出 `<host> <osd-count>`，並在有 OSD 時附上 id 清單。"""
    doc = load_stdin()
    nodes = {n["id"]: n for n in doc.get("nodes", [])}
    for node in doc.get("nodes", []):
        if node.get("type") != "host":
            continue
        kids = [k for k in node.get("children", [])
                if nodes.get(k, {}).get("type") == "osd" or k >= 0]
        print("%s %d %s" % (node.get("name"), len(kids),
                            ",".join(str(k) for k in kids)))


def cmd_osd_tree_ready(expect):
    doc = load_stdin()
    expect = int(expect)
    nodes = doc.get("nodes", [])
    osds = [n for n in nodes if n.get("type") == "osd"]
    up = [n for n in osds if n.get("status") == "up"]
    hosts = [n for n in nodes if n.get("type") == "host"]
    one_each = [h for h in hosts if len(h.get("children", [])) == 1]
    print("%d %d %d %d" % (len(osds), len(up), len(hosts), len(one_each)))
    if len(osds) != expect or len(up) != expect or len(one_each) != expect:
        sys.exit(1)


def cmd_crush_racks():
    doc = load_stdin()
    for node in doc.get("nodes", []):
        if node.get("type") == "rack":
            print(node.get("name", ""))


def cmd_crush_check(racks, per_rack):
    doc = load_stdin()
    racks, per_rack = int(racks), int(per_rack)
    nodes = {n["id"]: n for n in doc.get("nodes", [])}
    rack_nodes = [n for n in doc.get("nodes", []) if n.get("type") == "rack"]
    good = 0
    detail = []
    for rack in rack_nodes:
        hosts = [k for k in rack.get("children", [])
                 if nodes.get(k, {}).get("type") == "host"]
        detail.append("%s=%d" % (rack.get("name"), len(hosts)))
        if len(hosts) == per_rack:
            good += 1
    print("%d %d %s" % (len(rack_nodes), good, ",".join(sorted(detail))))
    if len(rack_nodes) != racks or good != racks:
        die("CRUSH 拓撲不符：期望 %d rack × %d host，實得 %s"
            % (racks, per_rack, ",".join(sorted(detail))))


def cmd_json_get(key):
    doc = load_stdin()
    if key not in doc:
        die("JSON 缺 key：%s" % key)
    print(doc[key])


def cmd_qos_check(profile, lock_path, dump_path, show_dir, out_path):
    if profile not in PROFILES:
        die("未知 profile：%s" % profile)
    prof = PROFILES[profile]
    lock = load(lock_path)
    dumped = load(dump_path)
    mon_store = {}
    for entry in dumped:
        mon_store.setdefault(entry.get("name"), []).append(entry.get("section"))
    forbidden = [{"name": k, "sections": v}
                 for k, v in sorted(mon_store.items())
                 if k in FORBIDDEN_IN_MON_STORE]

    osds_out = []
    failures = []
    for row in lock.get("osds", []):
        osd = int(row["osd"])
        locked = float(row["locked_value"])
        path = os.path.join(show_dir, "show.%d.json" % osd)
        if not os.path.exists(path):
            failures.append("osd.%d 沒有 config show 輸出" % osd)
            osds_out.append({"osd": osd, "ok": False, "checks": [],
                             "error": "missing config show"})
            continue
        show = load(path)
        checks = []

        def check(key, expected, kind, tol=0.0):
            actual = show.get(key)
            if actual is None:
                res = False
            elif kind == "str":
                res = str(actual).strip() == str(expected)
            elif kind == "bool":
                res = as_bool(actual) == bool(expected)
            elif kind == "int":
                res = int(round(as_float(actual))) == int(expected)
            else:
                res = abs(as_float(actual) - float(expected)) <= tol
            checks.append({"key": key, "expected": expected,
                           "actual": actual, "ok": res})
            if not res:
                failures.append("osd.%d %s：期望 %s 實得 %s"
                                % (osd, key, expected, actual))

        # round2 blocker 2：mClock 的一切前提
        check("osd_op_queue", "mclock_scheduler", "str")
        check("osd_mclock_profile", profile, "str")
        for cls, vals in zip(CLASSES, prof):
            check("osd_mclock_scheduler_%s_res" % cls, vals[0], "float", 1e-4)
            check("osd_mclock_scheduler_%s_wgt" % cls, vals[1], "int")
            check("osd_mclock_scheduler_%s_lim" % cls, vals[2], "float", 1e-4)
        check("osd_mclock_max_capacity_iops_ssd", locked, "float", 0.5)
        check("osd_mclock_max_sequential_bandwidth_ssd",
              int(os.environ.get("CEPH_SEQ_BW_SSD", "1258291200")), "int")
        check("osd_max_backfills", 1, "int")
        check("osd_recovery_max_active_ssd", 10, "int")
        check("osd_mclock_override_recovery_settings", False, "bool")
        check("osd_mclock_skip_benchmark", True, "bool")

        # H-012 不變條件：鎖定值不得等於 compiled default
        default_iops = float(os.environ.get("CEPH_CAPACITY_DEFAULT", "21500"))
        cap_ok = abs(locked - default_iops) > 0.5
        checks.append({"key": "capacity_not_compiled_default",
                       "expected": "!= %g" % default_iops,
                       "actual": locked, "ok": cap_ok})
        if not cap_ok:
            failures.append("osd.%d 鎖定的 capacity 等於 compiled default %g"
                            " —— 每次 boot 都會重跑 bench（H-012）" % (osd, default_iops))

        covariates = dict((k, show.get(k)) for k in COVARIATE_KEYS)
        osd_ok = all(c["ok"] for c in checks)
        osds_out.append({"osd": osd, "ok": osd_ok, "checks": checks,
                         "covariates": covariates})

    if forbidden:
        for item in forbidden:
            failures.append("mon config store 出現 %s（section=%s）——"
                            " recovery/QoS 參數必須來自 mClock 的 set_val_default（H-009/H-018）"
                            % (item["name"], ",".join(str(s) for s in item["sections"])))

    verdict = "pass" if not failures else "fail"
    dump(out_path, {"schema_version": 1, "profile": profile,
                    "verdict": verdict,
                    "settle_secs": int(os.environ.get("QOS_SETTLE_SECS", "30")),
                    "provenance": {"forbidden_in_mon_store": forbidden,
                                   "ok": not forbidden},
                    "osds": osds_out, "failures": failures})
    if failures:
        sys.stderr.write("qos gate 未通過：\n  %s\n" % "\n  ".join(failures))
        sys.exit(1)
    print("ok")


BENCH_RE = re.compile(r"iops:\s*([0-9]+(?:\.[0-9]+)?)")


def _raw_iops(raw, host):
    entry = raw.get(host)
    if entry is None:
        return None
    if isinstance(entry, dict):
        return float(entry.get("iops")) if entry.get("iops") is not None else None
    return float(entry)


def cmd_capacity_provenance(tree_path, dump_path, clog_path, raw_path,
                            data_dir, out_path):
    tree = load(tree_path)
    dumped = load(dump_path)
    clog = open(clog_path).read() if os.path.exists(clog_path) else ""
    raw = load(raw_path) if os.path.exists(raw_path) else {}

    nodes = {n["id"]: n for n in tree.get("nodes", [])}
    host_of = {}
    for node in tree.get("nodes", []):
        if node.get("type") != "host":
            continue
        for kid in node.get("children", []):
            if kid >= 0 and nodes.get(kid, {}).get("type", "osd") == "osd":
                host_of[int(kid)] = node.get("name")

    stored = {}
    for entry in dumped:
        if entry.get("name") == "osd_mclock_max_capacity_iops_ssd":
            section = str(entry.get("section", ""))
            if section.startswith("osd."):
                stored[int(section.split(".", 1)[1])] = float(entry.get("value"))

    rows = []
    for name in sorted(os.listdir(data_dir)):
        if not name.startswith("journal.") or not name.endswith(".txt"):
            continue
        osd = int(name.split(".")[1])
        text = open(os.path.join(data_dir, name)).read()
        show_path = os.path.join(data_dir, "show.%d.json" % osd)
        effective = None
        if os.path.exists(show_path):
            show = load(show_path)
            if show.get("osd_mclock_max_capacity_iops_ssd") is not None:
                effective = as_float(show["osd_mclock_max_capacity_iops_ssd"])

        bench_iops = None
        lines = []
        for line in text.splitlines():
            if ("osd bench result" in line or "Skip OSD benchmark test." in line
                    or "osd bench err" in line
                    or "is not within the threshold" in line):
                lines.append(line.strip())
            if "osd bench result" in line:
                match = BENCH_RE.search(line)
                if match:
                    bench_iops = float(match.group(1))

        rejected_marker = "for osd.%d." % osd
        rejected = any("is not within the threshold" in ln and rejected_marker in ln
                       for ln in (clog.splitlines() + text.splitlines()))

        if "osd bench result" in text:
            status = "rejected-out-of-range" if rejected else "accepted"
        elif "Skip OSD benchmark test." in text:
            status = "skipped-existing-nondefault"
        elif "osd bench err" in text:
            status = "failed"
        else:
            status = "no-result"

        host = host_of.get(osd)
        rows.append({"osd": osd, "host": host, "bench_iops": bench_iops,
                     "bench_status": status, "effective_iops": effective,
                     "stored_value": stored.get(osd),
                     "raw_fio_iops": _raw_iops(raw, host) if host else None,
                     "log_lines": lines})

    rows.sort(key=lambda r: r["osd"])
    dump(out_path, {"schema_version": 1, "osds": rows})
    print(len(rows))


def cmd_capacity_decide(prov_path, raw_path, out_path, expect_n, cov_limit,
                        default_iops, fio_cap):
    prov = load(prov_path)
    raw = load(raw_path) if os.path.exists(raw_path) else {}
    expect_n, cov_limit = int(expect_n), float(cov_limit)
    default_iops, fio_cap = float(default_iops), float(fio_cap)
    rows = prov.get("osds", [])
    if len(rows) != expect_n:
        die("capacity-decide: HUMAN-NEEDED 決策表只有 %d 顆 OSD（期望 %d）"
            % (len(rows), expect_n))

    out_rows = []
    for row in rows:
        osd = int(row["osd"])
        host = row.get("host")
        status = row.get("bench_status")
        rawv = row.get("raw_fio_iops")
        if rawv is None and host:
            rawv = _raw_iops(raw, host)
        bench = row.get("bench_iops")
        storedv = row.get("stored_value")
        if storedv is None:
            storedv = row.get("effective_iops")

        def fio_derived():
            if rawv is None:
                die("capacity-decide: HUMAN-NEEDED osd.%d 需要 raw NVMe fio 基線"
                    " 才能決策（bench_status=%s）" % (osd, status))
            return min(float(rawv), fio_cap), "fio-derived"


        if status == "accepted":
            if bench is None:
                die("capacity-decide: HUMAN-NEEDED osd.%d 標為 accepted 卻沒有 bench 值" % osd)
            # 不拿 bench 與 raw fio 比值當判準：bench 是 **BlueStore 層** 的 4K randwrite
            # 能力，raw fio 是 **裸裝置** 能力，兩者本質相差一個數量級以上（BlueStore
            # 寫放大／WAL／metadata／checksum／fsync 語意）。真機實測 bench 6.4K vs
            # raw 287K（45×），而從叢集飽和點反推每顆 OSD 的實際寫入率是 ~7.0K——
            # bench 才是對的。用比值判準會把正確的 bench 誤判成 inconsistent 而改鎖
            # 一個過大的值，於是 reservation 永遠達不到、mClock 不介入仲裁、三個
            # profile 表現一致，整場實驗得出假的 null result。
            # raw fio 在此只剩一個把關角色：裝置健康下限。裸 NVMe 若連 BlueStore
            # 層的 bench 都跑不贏，表示碟被 throttle／壞掉／指到錯的裝置——
            # 那時 bench 值也不可信。（只在 bench 真的要被採用時才檢查；bench 被
            # Ceph 判為 out-of-range 時那個值本來就不可信，比較沒有意義。）
            if rawv is not None and float(rawv) < float(bench):
                die("capacity-decide: HUMAN-NEEDED osd.%d 的裸裝置 fio（%.0f）低於"
                    " BlueStore bench（%.0f）——裝置疑似被 throttle 或指到錯的碟"
                    % (osd, float(rawv), float(bench)))
            decision, (locked, source) = "accepted", (float(bench), "bench")
        elif status == "rejected-out-of-range":
            decision, (locked, source) = "rejected-out-of-range", fio_derived()
        elif status == "skipped-existing-nondefault":
            if storedv is None:
                die("capacity-decide: HUMAN-NEEDED osd.%d 標為 skipped 卻讀不到現值" % osd)
            # 同上：不與 raw fio 比值（量的是不同層）。現值直接採用，
            # 是否合理由 Ceph 自己的接受區間（1000–80000）與跨 OSD 的 CoV gate 把關。
            decision = "skipped-existing-nondefault"
            locked, source = float(storedv), "stored"
        else:
            die("capacity-decide: HUMAN-NEEDED osd.%d 的 bench_status=%s"
                "（bench 失敗或無證據時不得自動選值）" % (osd, status))

        locked = int(round(locked))
        offset = False
        if abs(locked - default_iops) < 0.5:
            locked = int(default_iops) - 1
            offset = True
        out_rows.append({"osd": osd, "host": host, "bench_iops": bench,
                         "bench_status": status, "raw_fio_iops": rawv,
                         "decision": decision, "locked_value": locked,
                         "locked_source": source, "offset_from_default": offset})

    values = [float(r["locked_value"]) for r in out_rows]
    mean = sum(values) / len(values)
    var = sum((v - mean) ** 2 for v in values) / (len(values) - 1)
    cov = (var ** 0.5) / mean if mean else 0.0
    if cov > cov_limit:
        die("capacity-dispersion-high：8 顆鎖定值的 CoV = %.3f > %.2f（%s）——"
            " 不得 lock、不得開跑；remediation 見 README（outlier OSD 以"
            " osd_mclock_force_run_benchmark_on_init + restart 重測，或 operator"
            " override 並記錄 provenance）"
            % (cov, cov_limit, ",".join(str(int(v)) for v in values)))

    dump(out_path, {"schema_version": 1, "cov": round(cov, 5),
                    "cov_limit": cov_limit, "osds": out_rows})
    print(len(out_rows))


def cmd_lock_values(lock_path):
    lock = load(lock_path)
    for row in lock.get("osds", []):
        value = float(row["locked_value"])
        text = "%d" % int(value) if float(value).is_integer() else "%g" % value
        print("%d %s" % (int(row["osd"]), text))


def cmd_check_capacity(show_path, expected):
    show = load(show_path)
    actual = show.get("osd_mclock_max_capacity_iops_ssd")
    skip = show.get("osd_mclock_skip_benchmark")
    if actual is None or abs(as_float(actual) - float(expected)) > 0.5:
        die("capacity 回讀不符：期望 %s 實得 %s" % (expected, actual))
    if not as_bool(skip):
        die("osd_mclock_skip_benchmark 未生效（實得 %s）" % skip)
    print("ok")


def cmd_norebench(osd_id, boot_old, boot_new, journal_path, show_path,
                  expected, markers, out_path):
    text = open(journal_path).read()
    show = load(show_path)
    marker_list = [m for m in markers.split("|") if m]
    hit = [m for m in marker_list if m in text]

    boot_changed = bool(boot_new) and boot_new != boot_old
    journal_nonempty = bool(text.strip())
    positive = bool(hit)
    no_bench = "osd bench result" not in text
    skip_effective = as_bool(show.get("osd_mclock_skip_benchmark"))
    actual_cap = show.get("osd_mclock_max_capacity_iops_ssd")
    cap_unchanged = (actual_cap is not None
                     and abs(as_float(actual_cap) - float(expected)) <= 0.5)

    doc = {"schema_version": 1, "osd": int(osd_id),
           "boot_id_before": boot_old, "boot_id_after": boot_new,
           "boot_id_changed": boot_changed,
           "journal_nonempty": journal_nonempty,
           "positive_control": positive, "positive_control_hits": hit,
           "no_bench_log": no_bench, "skip_benchmark_effective": skip_effective,
           "expected_capacity": float(expected), "actual_capacity": actual_cap,
           "capacity_unchanged": cap_unchanged}
    doc["verdict"] = ("pass" if all([boot_changed, journal_nonempty, positive,
                                     no_bench, skip_effective, cap_unchanged])
                      else "fail")
    dump(out_path, doc)

    reasons = []
    if not boot_changed:
        reasons.append("boot ID 未變更（%s → %s）——沒有真的重開機" % (boot_old, boot_new))
    if not journal_nonempty:
        reasons.append("unit-scoped journal 是空的——log 管道壞掉，不是「沒重跑」")
    if not positive:
        reasons.append("positive control 未命中（找不到本次 boot 必存在的 log：%s）"
                       "——「查無 bench log」無法與「根本沒抓到 log」區分（H-013）"
                       % markers)
    if not no_bench:
        reasons.append("本次 boot 出現 `osd bench result` —— capacity 被重跑覆寫")
    if not skip_effective:
        reasons.append("osd_mclock_skip_benchmark 不是 true")
    if not cap_unchanged:
        reasons.append("capacity 值已變（期望 %s 實得 %s）" % (expected, actual_cap))
    if reasons:
        die("no-rebench 未通過：\n  %s" % "\n  ".join(reasons))
    print("ok")


DISPATCH = {
    "pgs-clean": cmd_pgs_clean,
    "final-clean": cmd_final_clean,
    "health-snapshot": cmd_health_snapshot,
    "quorum-names": cmd_quorum_names,
    "osd-state": cmd_osd_state,
    "osds-in": cmd_osds_in,
    "laggy": cmd_laggy,
    "pgs-active": cmd_pgs_active,
    "pgs-not-clean": cmd_pgs_not_clean,
    "pgs-not-clean-primary": cmd_pgs_not_clean_primary,
    "versions-check": cmd_versions_check,
    "orch-image-check": cmd_orch_image_check,
    "host-names": cmd_host_names,
    "daemon-hosts": cmd_daemon_hosts,
    "osd-tree-hosts": cmd_osd_tree_hosts,
    "osd-tree-ready": cmd_osd_tree_ready,
    "crush-racks": cmd_crush_racks,
    "crush-check": cmd_crush_check,
    "json-get": cmd_json_get,
    "qos-check": cmd_qos_check,
    "capacity-provenance": cmd_capacity_provenance,
    "capacity-decide": cmd_capacity_decide,
    "lock-values": cmd_lock_values,
    "check-capacity": cmd_check_capacity,
    "norebench": cmd_norebench,
}

if len(sys.argv) < 2 or sys.argv[1] not in DISPATCH:
    die("未知子指令：%s" % (sys.argv[1] if len(sys.argv) > 1 else ""))
DISPATCH[sys.argv[1]](*sys.argv[2:])
PY
)"

_ceph_py() { python3 -c "$_CEPH_PY_SRC" "$@"; }

# =============================================================================
# Task 5 — 部署鏈
# =============================================================================

# ceph_hosts：cephadm 納管的 11 台（fio client 不納管）。
ceph_hosts() {
  inv_names admin
  inv_names mon
  inv_names osd
}

_ceph_managed_hosts() { # admin 以外的 10 台（orch host add 的對象）
  inv_names mon
  inv_names osd
}

# 1) campaign 專用 keypair -----------------------------------------------------

ceph_keygen_local() {
  local priv="$CAMPAIGN_KEY" pub="${CAMPAIGN_KEY}.pub" dir
  dir="$(dirname "$priv")"
  if [ -s "$priv" ] && [ -s "$pub" ]; then
    chmod 0600 "$priv"; chmod 0644 "$pub"
    log "campaign keypair 已存在，沿用：${priv}"
    return 0
  fi
  mkdir -p "$dir" || die "無法建立 ${dir}"
  chmod 0700 "$dir"
  rm -f "$priv" "$pub"
  ssh-keygen -t ed25519 -N '' -C 'mclock-campaign' -f "$priv" >/dev/null 2>&1 \
    || die "ssh-keygen 失敗：${priv}"
  chmod 0600 "$priv"; chmod 0644 "$pub"
  log "產生 campaign keypair：${priv}"
}

ceph_push_campaign_key() {
  local priv="$CAMPAIGN_KEY" pub="${CAMPAIGN_KEY}.pub" host cmd pubb64 privb64
  [ -s "$priv" ] && [ -s "$pub" ] || die "campaign keypair 不存在：${priv}"
  pubb64="$(_b64 "$pub")"
  privb64="$(_b64 "$priv")"

  # (a) pubkey 冪等 append 到 11 台全部 Ceph host（admin 也要——不依賴 cephadm 自行 authorize）
  for host in $(ceph_hosts); do
    cmd="umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys;"
    cmd="${cmd} chmod 600 ~/.ssh/authorized_keys;"
    cmd="${cmd} _k=\$(printf %s ${pubb64} | base64 --decode);"
    cmd="${cmd} grep -qF \"\$_k\" ~/.ssh/authorized_keys ||"
    cmd="${cmd} printf \"%s\\n\" \"\$_k\" >> ~/.ssh/authorized_keys;"
    cmd="${cmd} echo authorized-keys-ok"
    _node_sh "$host" 60 "$cmd" >/dev/null \
      || die "pubkey fanout 失敗：${host}"
  done
  log "campaign pubkey 已散布到 11 台 Ceph host"

  # (b) 兩個 key 檔都送 admin（cephadm 對 --ssh-private-key/--ssh-public-key 都直接開檔）
  cmd="umask 077; mkdir -p /home/ikaros/.ssh;"
  cmd="${cmd} printf %s ${privb64} | base64 --decode > ${CAMPAIGN_KEY_REMOTE};"
  cmd="${cmd} chmod 0600 ${CAMPAIGN_KEY_REMOTE};"
  cmd="${cmd} printf %s ${pubb64} | base64 --decode > ${CAMPAIGN_KEY_REMOTE}.pub;"
  cmd="${cmd} chmod 0644 ${CAMPAIGN_KEY_REMOTE}.pub;"
  cmd="${cmd} echo campaign-key-written"
  _node_sh "$ADMIN_NAME" 60 "$cmd" >/dev/null || die "campaign key 檔寫入 admin 失敗"

  # (c) owner / mode / 內容逐位元驗證
  cmd="stat -c \"%n %U %a\" ${CAMPAIGN_KEY_REMOTE} ${CAMPAIGN_KEY_REMOTE}.pub;"
  cmd="${cmd} sha256sum ${CAMPAIGN_KEY_REMOTE} ${CAMPAIGN_KEY_REMOTE}.pub"
  local out n u m want got line
  out="$(_node_sh "$ADMIN_NAME" 60 "$cmd")" || die "campaign key 驗證指令失敗"

  line="$(printf '%s\n' "$out" | sed -n '1p')"
  read -r n u m <<< "$line"
  [ "$n" = "$CAMPAIGN_KEY_REMOTE" ] || die "私鑰路徑不符：${line}"
  [ "$u" = "$SSH_USER" ] || die "私鑰 owner 應為 ${SSH_USER}（實得 ${u}）"
  [ "$m" = "600" ] || die "私鑰 mode 應為 600（實得 ${m}）"
  line="$(printf '%s\n' "$out" | sed -n '2p')"
  read -r n u m <<< "$line"
  [ "$n" = "${CAMPAIGN_KEY_REMOTE}.pub" ] || die "公鑰路徑不符：${line}"
  [ "$u" = "$SSH_USER" ] || die "公鑰 owner 應為 ${SSH_USER}（實得 ${u}）"
  [ "$m" = "644" ] || die "公鑰 mode 應為 644（實得 ${m}）"

  want="$(_sha256 "$priv")"
  got="$(printf '%s\n' "$out" | sed -n '3p' | awk '{print $1}')"
  [ "$want" = "$got" ] || die "admin 上的私鑰內容與 bastion 不一致"
  want="$(_sha256 "$pub")"
  got="$(printf '%s\n' "$out" | sed -n '4p' | awk '{print $1}')"
  [ "$want" = "$got" ] || die "admin 上的公鑰內容與 bastion 不一致"
  log "campaign key 驗證通過（owner/mode/內容）"
}

ceph_gen_campaign_key() {
  ceph_keygen_local
  ceph_push_campaign_key
}

# 2) bootstrap -----------------------------------------------------------------

ceph_bootstrap() {
  if _node_run "$ADMIN_NAME" 30 "sudo test -f /etc/ceph/ceph.client.admin.keyring" \
      >/dev/null 2>&1; then
    log "cluster 已 bootstrap（admin keyring 存在），跳過"
    return 0
  fi
  # --image 必須在 bootstrap 之前（cephadm 的 global option）
  ceph_adm_to "$CEPH_BOOTSTRAP_SECS" \
    "cephadm --image ${CEPH_IMAGE} bootstrap" \
    "--mon-ip ${ADMIN_PRIVATE_IP}" \
    "--ssh-user ${SSH_USER}" \
    "--ssh-private-key ${CAMPAIGN_KEY_REMOTE}" \
    "--ssh-public-key ${CAMPAIGN_KEY_REMOTE}.pub" \
    "--skip-dashboard" >&2 || die "cephadm bootstrap 失敗"
  log "cephadm bootstrap 完成"
}

# 3) host 納管（先 add 再 check-host）------------------------------------------

ceph_add_hosts() {
  local known host
  # 先把 mon service 轉為 unmanaged，再加 host。否則 cephadm 會在每台新 host 上
  # 自動鋪 mon（預設 placement count:5），等 ceph_apply_mons 把 placement 收斂到三台時，
  # 多出來的那些會變成 `CEPHADM_STRAY_DAEMON` 警告——而 final_clean 只允許
  # noscrub/nodeep-scrub，於是每個 replicate 的 safety gate 都會卡死。
  ceph_adm "ceph orch apply mon --unmanaged=true" >&2 \
    || die "無法把 mon service 轉為 unmanaged（避免 host add 觸發自動鋪 mon）"
  known="$(ceph_adm "ceph orch host ls --format json" | _ceph_py host-names)" \
    || die "取不到 orch host ls"
  for host in $(_ceph_managed_hosts); do
    if printf '%s\n' "$known" | grep -qx -- "$host"; then
      log "host 已納管：${host}"
      continue
    fi
    ceph_adm "ceph orch host add ${host} $(inv_ip "$host")" >&2 \
      || die "orch host add 失敗：${host}"
  done
  # round2/F2：check-host 對未納管 host 會回 Host not found，所以一定要在 add 之後
  for host in $(_ceph_managed_hosts); do
    ceph_adm_to 300 "ceph cephadm check-host ${host}" >&2 \
      || die "cephadm check-host 失敗：${host}"
  done
  log "10 台 host 納管完成並通過 check-host"
}

# 4) mon placement -------------------------------------------------------------

_ceph_mon_names() {
  local names
  names="$ADMIN_NAME"
  local m
  for m in $(inv_names mon); do names="${names},${m}"; done
  printf '%s\n' "$names"
}

_ceph_quorum_ok() {
  local want got
  want="$(_ceph_mon_names | tr ',' '\n' | sort | tr '\n' ' ')"
  got="$(ceph_adm "ceph quorum_status --format json" | _ceph_py quorum-names \
         | tr ' ' '\n' | sort | tr '\n' ' ')" || return 1
  [ "$want" = "$got" ]
}

ceph_apply_mons() {
  local placement
  placement="$(_ceph_mon_names)"
  ceph_adm "ceph orch apply mon --placement=${placement}" >&2 \
    || die "orch apply mon 失敗"
  with_deadline "$MON_QUORUM_SECS" _ceph_quorum_ok \
    || die "mon quorum 未收斂到指定三台（${placement}）"
  log "mon quorum = ${placement}"
}

# mgr 必須釘在非 OSD node（admin + mon-1）。cephadm 預設會自己挑兩台鋪 mgr，實測會落到
# OSD node 上——而故障注入要網路隔離 OSD node，隔到 active mgr 那台就會連帶打掉 mgr，
# 讓 `ceph -s` 輪詢與 sampler 中斷、量測窗出現假的 collector gap。
ceph_apply_mgrs() {
  local placement first_mon
  first_mon="$(inv_names mon | head -1)"
  placement="${ADMIN_NAME}${first_mon:+,${first_mon}}"
  ceph_adm "ceph orch apply mgr --placement=${placement}" >&2 \
    || die "orch apply mgr 失敗"
  with_deadline "$MON_QUORUM_SECS" _ceph_mgr_off_osd \
    || die "mgr 未收斂到非 OSD node（${placement}）"
  log "mgr placement = ${placement}（避開 OSD node）"
}

# 所有 mgr daemon 都不在 OSD node 上才算收斂
_ceph_mgr_off_osd() {
  local hosts osd_hosts h
  hosts="$(ceph_adm "ceph orch ps --daemon-type=mgr --format json" \
    | _ceph_py daemon-hosts)" || return 1
  osd_hosts="$(inv_names osd)"
  for h in $hosts; do
    printf '%s\n' "$osd_hosts" | grep -qx -- "$h" && return 1
  done
  [ -n "$hosts" ]
}

# 5) OSD（逐台指定裝置，禁 all-available-devices）------------------------------

_ceph_osds_ready() {
  local n
  n="$(inv_names osd | wc -l | tr -d ' ')"
  ceph_adm "ceph osd tree --format json" | _ceph_py osd-tree-ready "$n" >/dev/null \
    || return 1
  local counts total up inn
  counts="$(ceph_adm "ceph osd dump --format json" | _ceph_py osds-in)" || return 1
  read -r total up inn <<< "$counts"
  [ "$total" = "$n" ] && [ "$up" = "$n" ] && [ "$inn" = "$n" ]
}

ceph_apply_osds() {
  local tree host have
  tree="$(ceph_adm "ceph osd tree --format json" | _ceph_py osd-tree-hosts)" \
    || die "取不到 osd tree"
  for host in $(inv_names osd); do
    have="$(printf '%s\n' "$tree" | awk -v h="$host" '$1 == h {print $2}')"
    if [ -n "$have" ] && [ "$have" != "0" ]; then
      log "host 已有 OSD，跳過：${host}"
      continue
    fi
    ceph_adm_to 900 "ceph orch daemon add osd ${host}:$(inv_nvme "$host")" >&2 \
      || die "orch daemon add osd 失敗：${host}"
  done
  with_deadline "$OSD_READY_SECS" _ceph_osds_ready \
    || die "OSD 未全部 up+in（期望一 host 一顆、共 8 顆）"
  log "8 顆 OSD 全部 up+in"
}

# 6) versions gate -------------------------------------------------------------

ceph_verify_versions() {
  ceph_adm "ceph versions --format json" \
    | _ceph_py versions-check "$CEPH_EXPECT_VERSION" >/dev/null \
    || die "ceph versions 不是全部 ${CEPH_EXPECT_VERSION}"
  ceph_adm "ceph orch ps --format json" \
    | _ceph_py orch-image-check "$CEPH_IMAGE" >/dev/null \
    || die "orch ps 的 container image 與 ${CEPH_IMAGE} 不符"
  log "版本 gate 通過：${CEPH_EXPECT_VERSION} / ${CEPH_IMAGE}"
}

# 7) CRUSH：4 rack × 2 host + rule --------------------------------------------

_ceph_racks() {
  local host
  for host in $(inv_names osd); do inv_rack "$host"; done | sort -u
}

ceph_setup_crush() {
  local existing rack host rules
  existing="$(ceph_adm "ceph osd crush tree --format json" | _ceph_py crush-racks)" \
    || die "取不到 crush tree"
  for rack in $(_ceph_racks); do
    if ! printf '%s\n' "$existing" | grep -qx -- "$rack"; then
      ceph_adm "ceph osd crush add-bucket ${rack} rack" >&2 \
        || die "add-bucket 失敗：${rack}"
    fi
    ceph_adm "ceph osd crush move ${rack} root=default" >&2 \
      || die "rack move 失敗：${rack}"
  done
  for host in $(inv_names osd); do
    ceph_adm "ceph osd crush move ${host} rack=$(inv_rack "$host")" >&2 \
      || die "host move 失敗：${host}"
  done
  rules="$(ceph_adm "ceph osd crush rule ls --format json")" || die "取不到 crush rule ls"
  if ! printf '%s' "$rules" | grep -qF "\"${CEPH_CRUSH_RULE}\""; then
    ceph_adm "ceph osd crush rule create-replicated ${CEPH_CRUSH_RULE} default rack" >&2 \
      || die "建立 crush rule 失敗：${CEPH_CRUSH_RULE}"
  fi
  ceph_adm "ceph osd crush tree --format json" | _ceph_py crush-check 4 2 >/dev/null \
    || die "CRUSH 拓撲驗證失敗（期望 4 rack × 2 host）"
  log "CRUSH 拓撲就緒：4 rack × 2 host + rule ${CEPH_CRUSH_RULE}"
}

# 8) pool ----------------------------------------------------------------------

_ceph_pool_get() { # <key>
  ceph_adm "ceph osd pool get ${CEPH_POOL} $1 --format json" | _ceph_py json-get "$1"
}

ceph_create_pool() {
  local pools got
  pools="$(ceph_adm "ceph osd pool ls --format json")" || die "取不到 pool ls"
  if ! printf '%s' "$pools" | grep -qF "\"${CEPH_POOL}\""; then
    ceph_adm "ceph osd pool create ${CEPH_POOL} ${CEPH_PG_NUM} ${CEPH_PG_NUM} replicated ${CEPH_CRUSH_RULE}" >&2 \
      || die "建立 pool 失敗：${CEPH_POOL}"
  fi
  ceph_adm "ceph osd pool set ${CEPH_POOL} size ${CEPH_POOL_SIZE}" >&2 \
    || die "pool size 設定失敗"
  ceph_adm "ceph osd pool set ${CEPH_POOL} pg_autoscale_mode off" >&2 \
    || die "autoscaler 關閉失敗"
  ceph_adm "ceph osd pool application enable ${CEPH_POOL} rbd" >&2 \
    || die "pool application enable 失敗"
  ceph_adm_to 300 "rbd pool init ${CEPH_POOL}" >&2 || die "rbd pool init 失敗"

  got="$(_ceph_pool_get size)" || die "讀不到 pool size"
  [ "$got" = "$CEPH_POOL_SIZE" ] || die "pool size 應為 ${CEPH_POOL_SIZE}（實得 ${got}）"
  got="$(_ceph_pool_get pg_num)" || die "讀不到 pg_num"
  [ "$got" = "$CEPH_PG_NUM" ] || die "pg_num 應為 ${CEPH_PG_NUM}（實得 ${got}）"
  got="$(_ceph_pool_get crush_rule)" || die "讀不到 crush_rule"
  [ "$got" = "$CEPH_CRUSH_RULE" ] || die "crush_rule 應為 ${CEPH_CRUSH_RULE}（實得 ${got}）"
  got="$(_ceph_pool_get pg_autoscale_mode)" || die "讀不到 pg_autoscale_mode"
  [ "$got" = "off" ] || die "autoscaler 應為 off（實得 ${got}）"
  log "pool ${CEPH_POOL} 就緒（size=${CEPH_POOL_SIZE} pg_num=${CEPH_PG_NUM} rule=${CEPH_CRUSH_RULE}）"
}

# 9) client auth + 拋棄式 smoke image ------------------------------------------

_ceph_client_smoke() { # <client-node>
  local node="$1" img rbd_c dev rc=0
  img="smoke-${node}"
  rbd_c="rbd -p ${CEPH_POOL} --id ${CEPH_CLIENT_ID}"
  _node_run "$node" 120 "sudo ${rbd_c} create ${img} --size 1024" >&2 \
    || die "smoke image 建立失敗：${node}"
  _node_run "$node" 60 "sudo ${rbd_c} ls" | grep -qx -- "$img" \
    || die "smoke image 建立後 rbd ls 看不到：${img}"
  dev="$(_node_run "$node" 120 "sudo ${rbd_c} map ${img}" | tr -d ' \r' | tail -1)" \
    || die "smoke image map 失敗：${node}"
  [ -n "$dev" ] || die "rbd map 沒有回傳裝置路徑：${node}"

  _node_run "$node" 300 \
    "sudo dd if=/dev/zero of=${dev} bs=1M count=16 oflag=direct conv=fsync" >&2 || rc=1
  if [ "$rc" -eq 0 ]; then
    _node_run "$node" 300 \
      "sudo dd if=${dev} of=/dev/null bs=1M count=16 iflag=direct" >&2 || rc=1
  fi
  # 不論成敗都要回收（拋棄式 image 不得殘留 map）
  _node_run "$node" 120 "sudo ${rbd_c} unmap ${dev}" >&2 \
    || log "smoke unmap 失敗（續行）：${node} ${dev}"
  _node_run "$node" 120 "sudo ${rbd_c} rm ${img}" >&2 \
    || log "smoke rm 失敗（續行）：${node} ${img}"
  [ "$rc" -eq 0 ] || die "smoke 讀寫失敗：${node}"
  _node_run "$node" 60 "sudo ${rbd_c} ls" | grep -qx -- "$img" \
    && die "smoke image 未被刪除：${img}"
  log "client smoke gate 通過：${node}"
  return 0
}

ceph_setup_client_auth() {
  local keyring conf kb64 cb64 node cmd
  keyring="$(ceph_adm "ceph auth get-or-create client.${CEPH_CLIENT_ID}" \
    "mon 'profile rbd' osd 'profile rbd pool=${CEPH_POOL}'")" \
    || die "client auth 建立失敗"
  [ -n "$keyring" ] || die "client keyring 是空的"
  conf="$(ceph_adm "ceph config generate-minimal-conf")" || die "取不到 minimal conf"
  [ -n "$conf" ] || die "minimal conf 是空的"
  kb64="$(printf '%s\n' "$keyring" | base64 | tr -d '\n')"
  cb64="$(printf '%s\n' "$conf" | base64 | tr -d '\n')"

  for node in $(inv_names client); do
    cmd="sudo mkdir -p /etc/ceph;"
    cmd="${cmd} printf %s ${cb64} | base64 --decode | sudo tee /etc/ceph/ceph.conf > /dev/null;"
    cmd="${cmd} printf %s ${kb64} | base64 --decode |"
    cmd="${cmd} sudo tee /etc/ceph/ceph.client.${CEPH_CLIENT_ID}.keyring > /dev/null;"
    cmd="${cmd} sudo chmod 0600 /etc/ceph/ceph.client.${CEPH_CLIENT_ID}.keyring;"
    cmd="${cmd} echo client-conf-ok"
    _node_sh "$node" 60 "$cmd" >/dev/null || die "client conf/keyring 分發失敗：${node}"
    _ceph_client_smoke "$node"
  done
}

# 10) campaign flags（設定當下即註冊對稱 unset）--------------------------------

_ceph_unset_flag() { ceph_adm "ceph osd unset $1" >&2; }
_ceph_config_rm_mon() { ceph_adm "ceph config rm mon $1" >&2; }
_ceph_config_rm_osd() { ceph_adm "ceph config rm osd $1" >&2; }
_ceph_balancer_on() { ceph_adm "ceph balancer on" >&2; }

ceph_campaign_flags() {
  ceph_adm "ceph osd set noscrub" >&2 || die "設定 noscrub 失敗"
  cleanup_push "_ceph_unset_flag noscrub"
  ceph_adm "ceph osd set nodeep-scrub" >&2 || die "設定 nodeep-scrub 失敗"
  cleanup_push "_ceph_unset_flag nodeep-scrub"
  ceph_adm "ceph balancer off" >&2 || die "關閉 balancer 失敗"
  cleanup_push "_ceph_balancer_on"
  # H-015：只關 heartbeat grace 控制不完全，down-out interval 是獨立開關且預設 true
  ceph_adm "ceph config set mon mon_osd_adjust_heartbeat_grace false" >&2 \
    || die "關閉 adaptive heartbeat grace 失敗"
  cleanup_push "_ceph_config_rm_mon mon_osd_adjust_heartbeat_grace"
  ceph_adm "ceph config set mon mon_osd_adjust_down_out_interval false" >&2 \
    || die "關閉 adaptive down-out interval 失敗"
  cleanup_push "_ceph_config_rm_mon mon_osd_adjust_down_out_interval"
  log "campaign flags 已設定（noscrub / nodeep-scrub / balancer off / 兩個 adjust 開關）"
}

ceph_campaign_unflags() {
  local rc=0
  _ceph_unset_flag noscrub || rc=1
  _ceph_unset_flag nodeep-scrub || rc=1
  _ceph_balancer_on || rc=1
  _ceph_config_rm_mon mon_osd_adjust_heartbeat_grace || rc=1
  _ceph_config_rm_mon mon_osd_adjust_down_out_interval || rc=1
  # Task 0.1 Step 3 的裁決：profile 由每個 execution 的 preflight 設定（campaign 級的
  # 持續狀態，非單一 execution 的注入），因此對稱回退掛在 campaign 收尾——設什麼就
  # 回退什麼，teardown 前最後一次 `ceph config dump` 乾淨才證得了 cleanup stack 對稱。
  _ceph_config_rm_osd osd_mclock_profile || rc=1
  [ "$rc" -eq 0 ] || log "campaign unflags 有項目失敗（請人工確認）"
  return "$rc"
}

# ceph_set_profile <profile>：切換 mclock profile（runtime-changeable，不需重啟 OSD）。
#   - 只接受三個合法 profile：打錯字若放行，要等 qos gate 撞完 QOS_CONVERGE_SECS 才發現。
#   - 已經是目標 profile 就不重下指令（冪等）——resume 與同 profile 連跑的 cell 很常見。
#   - 本函式只負責「下指令」；**是否生效一律由 ceph_qos_gate 判定**（八顆同時收斂 +
#     settle window + 逐 OSD effective config），所以這裡不做任何等待或驗證。
#   - H-018：九個衍生參數是 set_val_default、不進 mon config store，
#     `FORBIDDEN_IN_MON_STORE` 也不含 osd_mclock_profile → 設 profile 不會踩到
#     qos gate 的「來源反向斷言」。
#   - 不註冊 per-execution 的對稱回退：profile 是 campaign 級持續狀態，
#     收尾由 `ceph_campaign_unflags` 一併 `ceph config rm osd osd_mclock_profile`。
ceph_set_profile() {
  [ $# -eq 1 ] || die "用法：ceph_set_profile <profile>"
  local profile="$1" current
  case "$profile" in
    balanced|high_client_ops|high_recovery_ops) : ;;
    *) die "未知的 mclock profile：${profile}（合法：balanced / high_client_ops / high_recovery_ops）" ;;
  esac
  # 先取當下值再決定要不要下指令；管線會吃掉 rc，所以取值與 trim 分兩步。
  current="$(ceph_adm "ceph config get osd osd_mclock_profile")" \
    || die "取不到當下的 osd_mclock_profile（不得盲設）"
  current="$(printf '%s' "$current" | tr -d ' \r\n')"
  [ -n "$current" ] || die "osd_mclock_profile 查詢結果是空的（不得盲設）"
  if [ "$current" = "$profile" ]; then
    log "mclock profile 已是 ${profile}（不重下指令）"
    printf 'set-profile: NOOP %s\n' "$profile"
    return 0
  fi
  ceph_adm "ceph config set osd osd_mclock_profile $profile" >&2 \
    || die "設定 osd_mclock_profile=${profile} 失敗"
  log "mclock profile：${current} → ${profile}（收斂與否交給 qos gate 判定）"
  printf 'set-profile: SET %s %s\n' "$current" "$profile"
}

# =============================================================================
# Task 6 — QoS gate、capacity 決策、no-rebench 證據、兩層 clean 判準
# =============================================================================

# ceph_qos_gate <profile> [bundle-dir]
#   驗證集合（spec §6 + round2 blocker 2 + H-009/H-012/H-018）：
#     osd_op_queue=mclock_scheduler、profile 名、九參數、鎖定 capacity（且 != compiled
#     default）、seq bw 1200MiB/s、osd_max_backfills=1、osd_recovery_max_active_ssd=10、
#     osd_mclock_override_recovery_settings=false、osd_mclock_skip_benchmark=true，
#     外加「這些 key 不得出現在 mon config store」的來源反向斷言。
#   八顆必須「同時」收斂 → settle window → 再驗一次 → 結構化 JSON 入 bundle。
_ceph_qos_pass() {
  local id
  for id in $(ceph_osd_ids); do
    ceph_adm "ceph tell osd.${id} config show" > "${_QOS_DIR}/show.${id}.json" \
      || return 1
    [ -s "${_QOS_DIR}/show.${id}.json" ] || return 1
  done
  ceph_adm "ceph config dump --format json" > "${_QOS_DIR}/config-dump.json" || return 1
  [ -s "${_QOS_DIR}/config-dump.json" ] || return 1
  CEPH_SEQ_BW_SSD="$CEPH_SEQ_BW_SSD" CEPH_CAPACITY_DEFAULT="$CEPH_CAPACITY_DEFAULT" \
  QOS_SETTLE_SECS="$QOS_SETTLE_SECS" \
    _ceph_py qos-check "$_QOS_PROFILE" "$(capacity_lock_path)" \
      "${_QOS_DIR}/config-dump.json" "$_QOS_DIR" "${_QOS_DIR}/qos.json" >/dev/null
}

ceph_qos_gate() {
  [ $# -ge 1 ] || die "用法：ceph_qos_gate <profile> [bundle-dir]"
  local profile="$1" bundle="${2:-}" scratch rc=0
  [ -s "$(capacity_lock_path)" ] \
    || die "qos gate 需要 capacity-lock.json（$(capacity_lock_path)）"
  scratch="$(_ceph_scratch)"
  _QOS_PROFILE="$profile"
  _QOS_DIR="${scratch}/qos.$$"
  rm -rf "$_QOS_DIR"; mkdir -p "$_QOS_DIR"

  _ceph_qos_save() { # 證據不論成敗都要留下
    [ -n "$bundle" ] || return 0
    [ -s "${_QOS_DIR}/qos.json" ] || return 0
    mkdir -p "$bundle"
    cp "${_QOS_DIR}/qos.json" "${bundle}/qos.json"
  }

  if ! with_deadline "$QOS_CONVERGE_SECS" _ceph_qos_pass; then
    _ceph_qos_save
    die "qos gate：八顆 OSD 未在 ${QOS_CONVERGE_SECS}s 內同時收斂到 ${profile}"
  fi
  log "qos gate：八顆已收斂，settle ${QOS_SETTLE_SECS}s 後複驗"
  sleep "$QOS_SETTLE_SECS"
  if ! _ceph_qos_pass; then
    _ceph_qos_save
    die "qos gate：settle window 後複驗失敗（${profile}）"
  fi
  _ceph_qos_save
  printf 'qos-gate: PASS %s\n' "$profile"
  return "$rc"
}

# ceph_capacity_provenance [outfile]：per-OSD 的 bench 來源證據（決策表的輸入）。
ceph_capacity_provenance() {
  local out="${1:-$(capacity_provenance_path)}" scratch dir id host fsid hostmap n
  scratch="$(_ceph_scratch)"
  dir="${scratch}/prov.$$"
  rm -rf "$dir"; mkdir -p "$dir"
  mkdir -p "$(dirname "$out")"
  fsid="$(ceph_fsid)"

  ceph_adm "ceph osd tree --format json" > "${dir}/tree.json" || die "取不到 osd tree"
  ceph_adm "ceph config dump --format json" > "${dir}/dump.json" || die "取不到 config dump"
  ceph_adm "ceph log last 10000 warn cluster" > "${dir}/clog.txt" \
    || log "取不到 cluster log（rejected-out-of-range 只能靠 OSD 自身 log 判定）"
  hostmap="$(_ceph_py osd-tree-hosts < "${dir}/tree.json")" || die "osd tree 解析失敗"
  for id in $(ceph_osd_ids); do
    host="$(printf '%s\n' "$hostmap" \
            | awk -v want="$id" '{n = split($3, ids, ","); for (i = 1; i <= n; i++)
                                    if (ids[i] == want) print $1}')"
    [ -n "$host" ] || die "osd tree 內找不到 osd.${id} 所在的 host"
    _node_run "$host" 120 \
      "sudo journalctl -u ceph-${fsid}@osd.${id}.service --no-pager -n 100000" \
      > "${dir}/journal.${id}.txt" \
      || log "取不到 osd.${id} 的 journal（將判為 no-result）"
    ceph_adm "ceph tell osd.${id} config show" > "${dir}/show.${id}.json" \
      || log "取不到 osd.${id} 的 effective config"
  done

  n="$(_ceph_py capacity-provenance "${dir}/tree.json" "${dir}/dump.json" \
       "${dir}/clog.txt" "$(raw_nvme_baseline_path)" "$dir" "$out")" \
    || die "capacity provenance 產生失敗"
  printf 'capacity-provenance: PASS %s\n' "$n"
}

# ceph_capacity_decide [provenance] [outfile]：五狀態決策表 + 跨 8 顆 CoV gate。
ceph_capacity_decide() {
  local prov="${1:-$(capacity_provenance_path)}" out="${2:-$(capacity_lock_path)}" n
  [ -s "$prov" ] || die "capacity provenance 不存在：${prov}"
  mkdir -p "$(dirname "$out")"
  n="$(inv_names osd | wc -l | tr -d ' ')"
  _ceph_py capacity-decide "$prov" "$(raw_nvme_baseline_path)" "$out" \
    "$n" "$CAPACITY_COV_LIMIT" "$CEPH_CAPACITY_DEFAULT" "$CEPH_FIO_DERIVED_CAP" \
    >/dev/null || die "capacity 決策未過（見上方訊息）"
  printf 'capacity-decide: PASS %s\n' "$n"
}

# ceph_lock_capacity [lockfile]：逐顆 set 值 + skip_benchmark=true，並回讀驗證。
ceph_lock_capacity() {
  local lock="${1:-$(capacity_lock_path)}" scratch dir pairs id value n=0
  [ -s "$lock" ] || die "capacity lock 檔不存在：${lock}"
  scratch="$(_ceph_scratch)"
  dir="${scratch}/lock.$$"
  rm -rf "$dir"; mkdir -p "$dir"
  pairs="$(_ceph_py lock-values "$lock")" || die "讀不到 lock 檔內容"

  while read -r id value; do
    [ -n "$id" ] || continue
    [ "$value" != "$CEPH_CAPACITY_DEFAULT" ] \
      || die "lock 檔的 osd.${id} 等於 compiled default ${CEPH_CAPACITY_DEFAULT}（H-012）"
    ceph_adm "ceph config set osd.${id} osd_mclock_max_capacity_iops_ssd ${value}" >&2 \
      || die "鎖定 capacity 失敗：osd.${id}"
    ceph_adm "ceph config set osd.${id} osd_mclock_skip_benchmark true" >&2 \
      || die "設定 skip_benchmark 失敗：osd.${id}"
  done <<< "$pairs"

  while read -r id value; do
    [ -n "$id" ] || continue
    ceph_adm "ceph tell osd.${id} config show" > "${dir}/show.${id}.json" \
      || die "回讀 osd.${id} config show 失敗"
    _ceph_py check-capacity "${dir}/show.${id}.json" "$value" >/dev/null \
      || die "osd.${id} 的 capacity/skip_benchmark 回讀驗證失敗"
    n=$((n + 1))
  done <<< "$pairs"
  printf 'capacity-lock: PASS %s\n' "$n"
}

# ceph_verify_no_rebench <osd-id> <node> <pre-boot-id> [outfile]
#   current-boot 合取證據：boot ID 變更 + unit-scoped journal（非裸 journalctl -b）
#   無 `osd bench result` + effective skip_benchmark + capacity 值未變；
#   外加 H-013 的 positive control（斷言必須包含至少一條本次 boot 已知存在的 log）。
ceph_verify_no_rebench() {
  [ $# -ge 3 ] || die "用法：ceph_verify_no_rebench <osd-id> <node> <pre-boot-id> [out]"
  local id="$1" node="$2" pre="$3" out="${4:-$RESULTS_DIR/no-rebench-osd${1}.json}"
  local scratch dir fsid boot expected
  [ -s "$(capacity_lock_path)" ] || die "no-rebench 需要 capacity-lock.json"
  expected="$(_ceph_py lock-values "$(capacity_lock_path)" \
              | awk -v want="$id" '$1 == want {print $2}')"
  [ -n "$expected" ] || die "lock 檔內找不到 osd.${id}"
  scratch="$(_ceph_scratch)"
  dir="${scratch}/norebench.$$"
  rm -rf "$dir"; mkdir -p "$dir"
  mkdir -p "$(dirname "$out")"
  fsid="$(ceph_fsid)"

  boot="$(_node_run "$node" 30 "cat /proc/sys/kernel/random/boot_id" | tr -d ' \r\n')" \
    || die "取不到 ${node} 的 boot ID"
  _node_run "$node" 120 \
    "sudo journalctl -b -u ceph-${fsid}@osd.${id}.service --no-pager -n 100000" \
    > "${dir}/journal.txt" \
    || log "journalctl 取用失敗（會由 positive control 判為證據不足）"
  ceph_adm "ceph tell osd.${id} config show" > "${dir}/show.json" \
    || die "取不到 osd.${id} 的 effective config"

  _ceph_py norebench "$id" "$pre" "$boot" "${dir}/journal.txt" "${dir}/show.json" \
    "$expected" "$CEPH_BOOT_MARKERS" "$out" >/dev/null \
    || die "no-rebench 證據不足（見上方訊息）"
  printf 'no-rebench: PASS osd.%s\n' "$id"
}

# --- 兩層 clean 判準 ----------------------------------------------------------

_ceph_status_json() { ceph_adm "ceph -s --format json"; }

# ceph_wait_recovery_complete <deadline-epoch>
#   recovery_complete = 當下 up set 下 PG 100% active+clean（target 仍 down+out 也算）。
#   撞 deadline 回 124 並印 censored——right-censored 是有效觀測，不是失敗。
ceph_wait_recovery_complete() {
  [ $# -eq 1 ] || die "用法：ceph_wait_recovery_complete <deadline-epoch>"
  local deadline="$1" out ok now
  case "$deadline" in ''|*[!0-9]*) die "deadline 必須是絕對 epoch 秒（got=${deadline}）" ;; esac
  while :; do
    out="$(_ceph_status_json | _ceph_py pgs-clean 2>/dev/null)" || out=""
    ok="$(printf '%s' "$out" | awk '{print $1}')"
    if [ "$ok" = "1" ]; then
      printf 'recovery-complete: reached %s\n' "$(date +%s)"
      return 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      printf 'recovery-complete: censored %s\n' "$deadline"
      return 124
    fi
    sleep "$POLL_INTERVAL"
  done
}

# ceph_wait_final_clean [progress-deadline-secs]
#   final_clean = OSD 全 up+in + PG 100% active+clean + health 僅剩自設 noscrub/nodeep-scrub。
#   PG 在 progress-deadline 內零進展 → exit 3 交 watchdog（無絕對上限，安全 gate 不censor）。
ceph_wait_final_clean() {
  local progress="${1:-600}" out ok key last="" mark
  case "$progress" in ''|*[!0-9]*) die "progress deadline 必須是整數秒（got=${progress}）" ;; esac
  mark=$SECONDS
  while :; do
    out="$(_ceph_status_json | _ceph_py final-clean 2>/dev/null)" || out=""
    ok="$(printf '%s' "$out" | awk '{print $1}')"
    if [ "$ok" = "1" ]; then
      printf 'final-clean: PASS\n'
      return 0
    fi
    key="$(printf '%s' "$out" | awk '{print $2":"$3":"$4":"$6":"$7}')"
    if [ "$key" != "$last" ] && [ -n "$out" ]; then
      last="$key"
      mark=$SECONDS
    elif [ $((SECONDS - mark)) -ge "$progress" ]; then
      printf 'final-clean: NO-PROGRESS %s\n' "$progress"
      return 3
    fi
    sleep "$POLL_INTERVAL"
  done
}

# --- OSD 狀態 / PG / daemon helper -------------------------------------------

ceph_osd_state() { # <osd-id> → `osd.N up=.. in=.. up_from=.. up_thru=.. down_at=..`
  [ $# -eq 1 ] || die "用法：ceph_osd_state <osd-id>"
  ceph_adm "ceph osd dump --format json" | _ceph_py osd-state "$1"
}

_ceph_state_field() { # <state-line> <field>
  printf '%s\n' "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k {print $2}'
}

_ceph_osd_is_down() {
  local now up down_at pre_up_from
  now="$(ceph_osd_state "$_OSD_WAIT_ID")" || return 1
  up="$(_ceph_state_field "$now" up)"
  down_at="$(_ceph_state_field "$now" down_at)"
  pre_up_from="$(_ceph_state_field "$_OSD_WAIT_PRE" up_from)"
  [ "$up" = "0" ] || return 1
  # 相對 pre-state 判定：陳舊的 down 事件（早於上一次 up_from）不算這次的故障
  [ "${down_at:-0}" -gt "${pre_up_from:-0}" ]
}

_ceph_osd_is_up() {
  local now up up_from pre_up_from
  now="$(ceph_osd_state "$_OSD_WAIT_ID")" || return 1
  up="$(_ceph_state_field "$now" up)"
  up_from="$(_ceph_state_field "$now" up_from)"
  pre_up_from="$(_ceph_state_field "$_OSD_WAIT_PRE" up_from)"
  [ "$up" = "1" ] || return 1
  [ "${up_from:-0}" -gt "${pre_up_from:-0}" ]
}

ceph_wait_osd_down() { # <osd-id> <pre-state-line> <secs>
  [ $# -eq 3 ] || die "用法：ceph_wait_osd_down <osd-id> <pre-state> <secs>"
  _OSD_WAIT_ID="$1"; _OSD_WAIT_PRE="$2"
  with_deadline "$3" _ceph_osd_is_down
}

ceph_wait_osd_up() { # <osd-id> <pre-state-line> <secs>
  [ $# -eq 3 ] || die "用法：ceph_wait_osd_up <osd-id> <pre-state> <secs>"
  _OSD_WAIT_ID="$1"; _OSD_WAIT_PRE="$2"
  with_deadline "$3" _ceph_osd_is_up
}

_ceph_pgs_active_ok() {
  local out total active
  out="$(ceph_adm "ceph pg ls-by-osd ${_PG_WAIT_ID} --format json" \
         | _ceph_py pgs-active 2>/dev/null)" || return 1
  read -r total active <<< "$out"
  [ -n "$total" ] || return 1
  [ "$total" = "$active" ]
}

# ceph_wait_pgs_active_for_osd <osd-id> [secs]：flapping 每輪的 gate（round2/F23）。
ceph_wait_pgs_active_for_osd() {
  [ $# -ge 1 ] || die "用法：ceph_wait_pgs_active_for_osd <osd-id> [secs]"
  _PG_WAIT_ID="$1"
  with_deadline "${2:-300}" _ceph_pgs_active_ok
}

# daemon 控制一律走 orchestrator（不猜 systemd unit 名）
# OSD daemon 的起停一律走 **目標 host 的 systemd**，不用 `ceph orch daemon`：
# 本 lab 的 OSD 是逐台 `orch daemon add osd` 建的，`ceph orch ls` 顯示該 service 是
# **unmanaged**，而 cephadm 的協調迴圈不碰 unmanaged service——`orch daemon start`
# 只會回「Scheduled to start」然後**永遠不執行**。真機 flapping 第一輪就卡在這：
# stop 生效、start 沒生效，osd.2 等了 300s 沒回來，attempt taint。
# unit 名不是猜的：cephadm 的固定命名 `ceph-<fsid>@osd.<id>.service`，fsid 取自
# `ceph_fsid`（部署時就驗過），且下指令前先以 `systemctl list-units` 確認該 unit 存在。
_ceph_osd_unit() { # <osd-id> → ceph-<fsid>@osd.<id>.service
  printf 'ceph-%s@osd.%s.service' "$(ceph_fsid)" "$1"
}

# 用既有的 osd tree（測試已有 fixture、部署鏈也已在用）反查 host，不另打 `osd find`。
# 設 `_CEPH_OSD_HOST` 而非印出：呼叫端若用 `$(...)` 取值，快取寫在子 shell 裡
# 一離開就消失（flapping 有 10 輪 stop/start，等於每輪都重查 osd tree）。
_ceph_osd_host_set() { # <osd-id> → 設 _CEPH_OSD_HOST
  local cached
  eval "cached=\"\${_CEPH_OSDHOST_$1:-}\""
  if [ -n "$cached" ]; then _CEPH_OSD_HOST="$cached"; return 0; fi
  _CEPH_OSD_HOST="$(ceph_adm "ceph osd tree --format json" | _ceph_py osd-tree-hosts \
    | awk -v id="$1" '{n=split($3,a,","); for(i=1;i<=n;i++) if(a[i]==id){print $1; exit}}')"
  [ -n "$_CEPH_OSD_HOST" ] || die "osd tree 裡找不到 osd.$1 的 host"
  eval "_CEPH_OSDHOST_$1=\"\$_CEPH_OSD_HOST\""
}

ceph_daemon_stop() { # <osd-id>
  [ $# -eq 1 ] || die "用法：ceph_daemon_stop <osd-id>"
  local unit
  _ceph_osd_host_set "$1"; unit="$(_ceph_osd_unit "$1")"
  _node_run "$_CEPH_OSD_HOST" 300 \
    "systemctl list-units --all --type=service --no-legend '${unit}' | grep -q ." \
    || die "osd.$1 的 systemd unit 不存在：${unit}（host=${_CEPH_OSD_HOST}）"
  _node_run "$_CEPH_OSD_HOST" 300 "sudo systemctl stop ${unit}" >&2
}

ceph_daemon_start() { # <osd-id>
  [ $# -eq 1 ] || die "用法：ceph_daemon_start <osd-id>"
  local unit
  _ceph_osd_host_set "$1"; unit="$(_ceph_osd_unit "$1")"
  # `reset-failed` 不可省：cephadm 的 unit 模板設 StartLimitBurst=5 /
  # StartLimitInterval=30min，而 flapping 要跑 10 輪——第 5 輪起 systemd 會以
  # `start-limit-hit` 拒絕啟動並把 unit 標成 failed（stop 本身是成功的，所有
  # Exec 步驟都回 0，只有速率限制擋下重啟）。reset-failed 清掉失敗狀態與計數器，
  # 是這個情境的標準解法，不需要改動系統設定。
  _node_run "$_CEPH_OSD_HOST" 300 "sudo systemctl reset-failed ${unit}" >&2 \
    || log "reset-failed 失敗（續行）：osd.$1"
  _node_run "$_CEPH_OSD_HOST" 300 "sudo systemctl start ${unit}" >&2
}

ceph_osd_out() { # <osd-id...>（rack 場景一次兩顆 → backfill 起點單一）
  [ $# -ge 1 ] || die "用法：ceph_osd_out <osd-id...>"
  ceph_adm "ceph osd out $*" >&2
}

ceph_osd_in() { # <osd-id...>
  [ $# -ge 1 ] || die "用法：ceph_osd_in <osd-id...>"
  ceph_adm "ceph osd in $*" >&2
}

ceph_health_snapshot() { # <outfile>
  [ $# -eq 1 ] || die "用法：ceph_health_snapshot <outfile>"
  mkdir -p "$(dirname "$1")"
  _ceph_status_json | _ceph_py health-snapshot "$1" >/dev/null \
    || die "health snapshot 失敗"
}

# ceph_check_laggy <outfile>：**只記錄 covariate，永不 gate**（round2 REGRESSED 修正）。
# 關掉 adaptive grace 不會停止 laggy 累積（H-015），所以只留證據、不擋流程。
ceph_check_laggy() {
  [ $# -eq 1 ] || die "用法：ceph_check_laggy <outfile>"
  local out="$1" dump
  mkdir -p "$(dirname "$out")"
  if ! dump="$(ceph_adm "ceph osd dump --format json" 2>/dev/null)"; then
    printf '{"schema_version": 1, "error": "osd dump 取用失敗", "osds": []}\n' > "$out"
    log "ceph_check_laggy：osd dump 取用失敗（covariate 缺一筆，不影響流程）"
    return 0
  fi
  printf '%s' "$dump" | _ceph_py laggy "$out" >/dev/null 2>&1 \
    || printf '{"schema_version": 1, "error": "解析失敗", "osds": []}\n' > "$out"
  return 0
}
