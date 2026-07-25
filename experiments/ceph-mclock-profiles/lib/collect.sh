#!/usr/bin/env bash
# ceph-mclock-profiles — 量測資料收集（Task 9）。bash 3.2 相容；
# stdout 只放機器要抓的那行，log/progress 一律 stderr。
#
# 對外介面
# --------
# replicate 級 sampler（跑在 admin，5s 粒度）：
#   sampler_start <bundle>          lock → remote_bg_start → run marker（stdout: pid）
#   sampler_assert_alive <bundle>   heartbeat 新鮮度（rc 1 = 不新鮮，不 die：交由 supervisor 標 taint）
#   sampler_stop <bundle>           冪等（沒 marker 就 no-op、不打 ssh）
# campaign 級 collector（15 台 ping mesh + NIC 差分、admin 的 SLOW_OPS/health 事件）：
#   bg_collect_start / bg_collect_assert_alive / bg_collect_ensure / bg_collect_stop
#   （bg_collect_ensure = reconcile／resume 的重啟路徑，只動死掉的那幾個）
# coverage supervisor（headline endpoint 的必要證據）：
#   coverage_check <bundle> [epoch]           固定 cadence 呼叫；rc 1 = 有 source 退化
#   coverage_finalize <bundle> [start] [end]  → coverage-proof.json；rc 1 = tainted
# 回歸 backfill（H-008，全實驗唯一 lim binding 的場景）：
#   collect_return_backfill <bundle> <osd-in-done-epoch> <final-clean-epoch>
# 量測窗收尾：
#   collect_cell <bundle> <kind> [win-start] [win-end]
# env snapshot 三段：
#   env_snapshot_provision / env_snapshot_cluster / env_snapshot_map
#
# 設計要點（stall vs gap，plan §Replicate Pipeline）
# ------------------------------------------------
# 「client 真的黑掉」與「量測工具中斷」在 fio log 裡長得一模一樣（都是沒有樣本）。
# 唯一的分辨依據是 coverage supervisor 的 heartbeat 證據，因此本檔的規則是：
#   - evidence[]：collector 壞掉的**證據區間**（sampler 沒樣本 / fio heartbeat 過期 /
#     supervisor 自己失聯）。taint 判定看它——單一區間 ≥ COVERAGE_GAP_TOLERANCE_SECS
#     或總量 > COVERAGE_MAX_TOTAL_GAP_SECS 就標 tainted。
#   - gaps[]：evidence 區間 ∩「該秒沒有任何 client 的 fio 樣本」。這是 verdict.py 用來
#     遮蔽的集合——**有資料的秒永遠不遮**（遮了會把真 stall 抹掉），沒資料又有壞掉證據的
#     秒才遮（不遮會把工具中斷誤判成 client 黑掉）。
#
# 與其他 lib 的契約
# ----------------
#   - fio（Task 7 lib/fio.sh）：heartbeat 與輸出位置以 `<bundle>/fio/run.tsv`
#     （client<TAB>run-id<TAB>workdir）為準——coverage supervisor 讀 `<workdir>/heartbeat`，
#     collect_cell 從同一個 workdir 回收（`fio_stop` 已收回來的就不重拉）。
#     沒有 run.tsv 時退回 registry 慣例 `<registry>/<collect_fio_run_id>.hb`。
#   - 產出物檔名對齊 `verdict.py schemas <kind>`（sampler-summary.json / coverage-proof.json /
#     return-backfill.json / fio-summary.json）。
#   - 以 $( ) 取機器行時 cleanup_push 會落在 subshell（不生效）；呼叫端（pipeline）必須
#     自行把 `sampler_stop <bundle>` 推進自己的 cleanup stack。
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR

[ -n "${MCLOCK_COLLECT_LOADED:-}" ] && return 0
MCLOCK_COLLECT_LOADED=1

# shellcheck source=./ceph.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ceph.sh"

# --- 常數 ---------------------------------------------------------------------
COLLECT_REMOTE_ROOT="${COLLECT_REMOTE_ROOT:-/var/tmp/mclock}"
FIO_REMOTE_ROOT="${FIO_REMOTE_ROOT:-${COLLECT_REMOTE_ROOT}/fio}"
SAMPLER_REMOTE_ROOT="${SAMPLER_REMOTE_ROOT:-${COLLECT_REMOTE_ROOT}/sampler}"
BGC_REMOTE_ROOT="${BGC_REMOTE_ROOT:-${COLLECT_REMOTE_ROOT}/bgcollect}"
SAMPLER_INTERVAL_SECS="${SAMPLER_INTERVAL_SECS:-5}"
# heartbeat 新鮮度上限：sampler 每輪要跑三個 ceph 指令，recovery 中偶爾會慢
SAMPLER_HB_MAX_AGE_SECS="${SAMPLER_HB_MAX_AGE_SECS:-30}"
BGC_INTERVAL_SECS="${BGC_INTERVAL_SECS:-10}"
BGC_HB_MAX_AGE_SECS="${BGC_HB_MAX_AGE_SECS:-60}"
FIO_HB_MAX_AGE_SECS="${FIO_HB_MAX_AGE_SECS:-30}"
# coverage supervisor：固定 cadence（獨立於 segment 邊界）與缺口容忍度
COVERAGE_CADENCE_SECS="${COVERAGE_CADENCE_SECS:-30}"
COVERAGE_GAP_TOLERANCE_SECS="${COVERAGE_GAP_TOLERANCE_SECS:-10}"
COVERAGE_MAX_TOTAL_GAP_SECS="${COVERAGE_MAX_TOTAL_GAP_SECS:-30}"
# sampler 樣本間隔超過這個值才算「中斷」（5s 粒度偶爾抖動不該 taint）
COLLECT_SAMPLER_MAX_DELTA_SECS="${COLLECT_SAMPLER_MAX_DELTA_SECS:-15}"
# 注入前健康基線窗（pipeline 的 60s 穩定窗）——推導量測窗時要涵蓋它
COLLECT_BASELINE_PAD_SECS="${COLLECT_BASELINE_PAD_SECS:-60}"
PING_PERIOD_MS="${PING_PERIOD_MS:-1000}"
SAR_INTERVAL_SECS="${SAR_INTERVAL_SECS:-10}"
COLLECT_TAR_TIMEOUT="${COLLECT_TAR_TIMEOUT:-300}"
COLLECT_CMD_TIMEOUT="${COLLECT_CMD_TIMEOUT:-120}"
# cephadm 內建 prometheus（admin 本機）
COLLECT_PROM_URL="${COLLECT_PROM_URL:-http://localhost:9095}"
COLLECT_PROM_STEP="${COLLECT_PROM_STEP:-5}"
# 預設查詢集合（metric 名取自 v19.2.2 mgr prometheus module 與 node-exporter；
# 查無資料不算失敗，index.json 會如實記錄每個 query 的 series 數）。
COLLECT_PROM_QUERIES="${COLLECT_PROM_QUERIES:-health_status=ceph_health_status
health_detail=ceph_health_detail
pg_degraded=ceph_pg_degraded
pg_clean=ceph_pg_clean
pool_recovering_bytes=ceph_pool_recovering_bytes_per_sec
pool_recovering_objects=ceph_pool_recovering_objects_per_sec
osd_op_w_latency_sum=ceph_osd_op_w_latency_sum
osd_op_r_latency_sum=ceph_osd_op_r_latency_sum
nic_rx_bytes=node_network_receive_bytes_total
nic_tx_bytes=node_network_transmit_bytes_total}"
# provision snapshot 要記版本的套件（PROVISIONING-REQUIREMENTS §6）
COLLECT_PKGS="${COLLECT_PKGS:-chrony curl jq python3 lvm2 sysstat iperf3 nvme-cli netcat-openbsd fping fio ceph-common cephadm}"

collect_env_dir() { printf '%s\n' "${COLLECT_ENV_DIR:-$RESULTS_DIR/env}"; }
bg_collect_state_path() { printf '%s\n' "${BG_COLLECT_STATE:-$RESULTS_DIR/bg-collect.json}"; }
bg_collect_data_dir() { printf '%s\n' "${BG_COLLECT_DATA_DIR:-$RESULTS_DIR/bg-collect}"; }

# --- 命名契約 -----------------------------------------------------------------

# collect_bundle_key <bundle>：results/<cell>/<rN>/attempts/<ts> → `<cell>-<rN>-<ts>`
collect_bundle_key() {
  [ $# -eq 1 ] || die "用法：collect_bundle_key <bundle>"
  local dir ts rep cell
  dir="${1%/}"
  ts="$(basename "$dir")"
  case "$dir" in
    */attempts/*)
      rep="$(basename "$(dirname "$(dirname "$dir")")")"
      cell="$(basename "$(dirname "$(dirname "$(dirname "$dir")")")")"
      ;;
    *) die "bundle 路徑不符 results/<cell>/<rN>/attempts/<ts>：${1}" ;;
  esac
  printf '%s-%s-%s\n' "$cell" "$rep" "$ts"
}

collect_sampler_run_id() { printf 'sampler-%s\n' "$(collect_bundle_key "$1")"; }

# collect_fio_run_id <bundle> <client>：Task 7 的 fio 背景 process 必須用這個 run-id，
# coverage supervisor 才找得到它的 heartbeat。
collect_fio_run_id() {
  [ $# -eq 2 ] || die "用法：collect_fio_run_id <bundle> <client>"
  printf 'fio-%s-%s\n' "$(collect_bundle_key "$1")" "$2"
}

collect_hb_path() { printf '%s/%s.hb\n' "$BG_REGISTRY_DIR" "$1"; }
_collect_pid_path() { printf '%s/%s.pid\n' "$BG_REGISTRY_DIR" "$1"; }
_collect_lock_path() { printf '%s/%s.lock\n' "$BG_REGISTRY_DIR" "$1"; }

# --- lock / heartbeat ---------------------------------------------------------

# _collect_lock <node> <run-id>：原子 mkdir 取 lock；registry 的 pid 死了就接管。
_collect_lock() {
  local node="$1" id="$2" cmd out
  cmd="sudo mkdir -p ${BG_REGISTRY_DIR}; sudo chown ${SSH_USER}: ${BG_REGISTRY_DIR};"
  cmd="${cmd} if mkdir $(_collect_lock_path "$id") 2>/dev/null; then echo mclock-lock: acquired; exit 0; fi;"
  cmd="${cmd} if [ -s $(_collect_pid_path "$id") ] && sudo kill -0 \$(cat $(_collect_pid_path "$id")) 2>/dev/null;"
  cmd="${cmd} then echo mclock-lock: busy; exit 2; fi;"
  cmd="${cmd} echo mclock-lock: stale-takeover"
  # 判定一律看離開碼（0 = 取得或接管 stale、2 = 有活著的 owner）；
  # stdout 只是給人看的，不能拿來當條件。
  out="$(_node_sh "$node" 60 "$cmd")" || return 1
  log "lock：${id} @ ${node}（${out:-acquired}）"
  return 0
}

_collect_unlock() {
  local node="$1" id="$2"
  _node_sh "$node" 60 "sudo rm -rf $(_collect_lock_path "$id"); echo mclock-lock: released" \
    >/dev/null || log "unlock 失敗（續行）：${id} @ ${node}"
}

# _collect_hb_status <node> <run-id>：stdout = `<age-secs> <alive|dead>`；age -1 = 沒 heartbeat。
# 年齡在**遠端**計算——bastion 是 macOS，跟 Ubuntu 之間的時鐘偏移不能混進判定。
_collect_hb_status() {
  local node="$1" id="$2" cmd
  cmd="_p=$(_collect_pid_path "$id"); _s=dead;"
  cmd="${cmd} if [ -s \$_p ] && sudo kill -0 \$(cat \$_p) 2>/dev/null; then _s=alive; fi;"
  cmd="${cmd} _h=$(collect_hb_path "$id");"
  cmd="${cmd} if [ -s \$_h ]; then echo \$(( \$(date +%s) - \$(cat \$_h) )) \$_s; else echo -1 \$_s; fi"
  _node_sh "$node" 60 "$cmd"
}

# _collect_hb_age <node> <run-id>：只要年齡（取不到回 -1）。
_collect_hb_age() {
  local out
  out="$(_collect_hb_status "$1" "$2")" || { printf '%s\n' "-1"; return 0; }
  printf '%s\n' "${out%% *}"
}

# --- python 解析器（所有 JSON/時間軸判讀集中在這裡）---------------------------
_COLLECT_PY_SRC="$(cat <<'PY'
import datetime
import glob
import json
import os
import statistics
import sys

PG_FLAGS = ("active", "clean", "peering", "degraded", "recovering",
            "backfilling", "undersized", "remapped")


def die(msg, code=1):
    sys.stderr.write("[collect] %s\n" % msg)
    sys.exit(code)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        die("讀不到／無法解析 JSON：%s（%s）" % (path, exc))


def load_opt(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def dump(path, doc):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1, sort_keys=True)
        fh.write("\n")
    os.rename(tmp, path)


def read_jsonl(path):
    rows = []
    try:
        fh = open(path)
    except OSError:
        return rows
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
    return rows


def as_int(val, default=None):
    try:
        return int(float(val))
    except (TypeError, ValueError):
        return default


def opt_int(val):
    """`-` 或空字串 = 未指定。"""
    if val is None or val in ("-", ""):
        return None
    return as_int(val)


def merge_intervals(pairs):
    out = []
    for start, end in sorted(pairs):
        if out and start <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], end)
        else:
            out.append([start, end])
    return [(a, b) for a, b in out]


def runs_from_secs(secs):
    """把秒的集合壓成連續區間。"""
    out = []
    for sec in sorted(secs):
        if out and sec == out[-1][1] + 1:
            out[-1][1] = sec
        else:
            out.append([sec, sec])
    return [(a, b) for a, b in out]


# ------------------------------------------------------------------ tick ----

def cmd_tick(t, pgdump_path, status_path, osddump_path):
    t = as_int(t)
    if t is None:
        die("tick：時戳不是整數")
    pg = load(pgdump_path)
    if isinstance(pg, dict) and "pg_map" in pg:
        pg = pg["pg_map"]
    if not isinstance(pg, dict):
        die("tick：pg dump 結構不符")
    stats = pg.get("pg_stats") or []
    if not stats and "pg_stats_sum" not in pg:
        die("tick：pg dump 既沒有 pg_stats 也沒有 pg_stats_sum")
    states = {}
    counts = dict((k, 0) for k in PG_FLAGS)
    counts["inactive"] = 0
    for entry in stats:
        name = entry.get("state") or ""
        states[name] = states.get(name, 0) + 1
        toks = set(name.split("+"))
        for flag in PG_FLAGS:
            if flag in toks:
                counts[flag] += 1
        if "active" not in toks:
            counts["inactive"] += 1

    summ = (pg.get("pg_stats_sum") or {}).get("stat_sum") or {}
    rec_bytes = as_int(summ.get("num_bytes_recovered"))
    rec_objs = as_int(summ.get("num_objects_recovered"))
    if rec_bytes is None:
        rec_bytes = sum(as_int((e.get("stat_sum") or {}).get("num_bytes_recovered"), 0)
                        for e in stats)
    if rec_objs is None:
        rec_objs = sum(as_int((e.get("stat_sum") or {}).get("num_objects_recovered"), 0)
                       for e in stats)

    status = load(status_path)
    pgmap = status.get("pgmap") or {}
    osdmap = status.get("osdmap") or {}
    health = ((status.get("health") or {}).get("status")) or ""

    osddump = load(osddump_path)
    osds_down = []
    osds_out = []
    for osd in osddump.get("osds") or []:
        oid = as_int(osd.get("osd"))
        if oid is None:
            continue
        if as_int(osd.get("up"), 1) == 0:
            osds_down.append(oid)
        if as_int(osd.get("in"), 1) == 0:
            osds_out.append(oid)
    flags = osddump.get("flags")
    if flags is None:
        flags = ",".join(osddump.get("flags_set") or [])

    rec = {
        "t": t,
        # OSDMap epoch 以 osd dump 為權威（pg dump 的 last_osdmap_epoch 會落後）
        "osdmap_epoch": as_int(osddump.get("epoch"), as_int(pg.get("last_osdmap_epoch"))),
        "pg_total": as_int(pgmap.get("num_pgs"), len(stats)),
        "pg_states": states,
        "pg_counts": counts,
        "recovered_bytes_cum": rec_bytes,
        "recovered_objects_cum": rec_objs,
        "recovering_bytes_per_sec": as_int(pgmap.get("recovering_bytes_per_sec"), 0),
        "recovering_objects_per_sec": as_int(pgmap.get("recovering_objects_per_sec"), 0),
        "degraded_objects": as_int(pgmap.get("degraded_objects"), 0),
        "misplaced_objects": as_int(pgmap.get("misplaced_objects"), 0),
        "num_objects": as_int(pgmap.get("num_objects"), 0),
        "num_up_osds": as_int(osdmap.get("num_up_osds")),
        "num_in_osds": as_int(osdmap.get("num_in_osds")),
        "health": health,
        "osds_down": osds_down,
        "osds_out": osds_out,
        "flags": flags,
    }
    sys.stdout.write(json.dumps(rec, sort_keys=True) + "\n")
    return 0


# -------------------------------------------------------- sampler summary ----

def _rate_series(rows, max_delta):
    """相鄰樣本的 recovery bytes/s 差分（counter 倒退或間隔過長就跳過）。"""
    rates = []
    holes = []
    total = 0
    prev = None
    for row in rows:
        t = as_int(row.get("t"))
        cum = as_int(row.get("recovered_bytes_cum"))
        if t is None or cum is None:
            continue
        if prev is not None:
            dt = t - prev[0]
            dv = cum - prev[1]
            if dt <= 0:
                pass
            elif dt > max_delta:
                holes.append((prev[0], t))
            elif dv >= 0:
                rates.append(dv / float(dt))
                total += dv
        prev = (t, cum)
    return rates, total, holes


def cmd_sampler_summary(samples_path, trunc_path, out_path, start, end, max_delta):
    max_delta = as_int(max_delta, 15)
    start = opt_int(start)
    end = opt_int(end)
    rows = read_jsonl(samples_path)
    if not rows:
        die("sampler-summary：%s 沒有可用樣本" % samples_path)
    rows.sort(key=lambda r: as_int(r.get("t"), 0))
    win = [r for r in rows
           if (start is None or as_int(r.get("t"), 0) >= start)
           and (end is None or as_int(r.get("t"), 0) <= end)]
    if not win:
        die("sampler-summary：量測窗內沒有樣本（start=%s end=%s）" % (start, end))
    with open(trunc_path, "w") as fh:
        for row in win:
            fh.write(json.dumps(row, sort_keys=True) + "\n")

    rates, total_bytes, holes = _rate_series(win, max_delta)
    obj_prev = None
    total_objs = 0
    peering = 0
    recovering = 0
    inactive = 0
    degraded_peak = 0
    clean_first = None
    epochs = []
    state_changes = []
    prev_state = None
    prev_t = None
    for row in win:
        t = as_int(row.get("t"))
        counts = row.get("pg_counts") or {}
        dt = 0 if prev_t is None else max(0, t - prev_t)
        if as_int(counts.get("peering"), 0) > 0:
            peering += dt
        if as_int(counts.get("recovering"), 0) > 0 or \
                as_int(counts.get("backfilling"), 0) > 0:
            recovering += dt
        if as_int(counts.get("inactive"), 0) > 0:
            inactive += dt
        degraded_peak = max(degraded_peak, as_int(row.get("degraded_objects"), 0))
        total = as_int(row.get("pg_total"), 0)
        if clean_first is None and total and as_int(counts.get("clean"), 0) >= total:
            clean_first = t
        epoch = as_int(row.get("osdmap_epoch"))
        if not epochs or epochs[-1][1] != epoch:
            epochs.append((t, epoch))
        state = (tuple(row.get("osds_down") or []), tuple(row.get("osds_out") or []))
        if state != prev_state:
            state_changes.append({"t": t, "osdmap_epoch": epoch,
                                  "osds_down": list(state[0]),
                                  "osds_out": list(state[1])})
            prev_state = state
        cum_o = as_int(row.get("recovered_objects_cum"))
        if cum_o is not None:
            if obj_prev is not None and cum_o >= obj_prev:
                total_objs += cum_o - obj_prev
            obj_prev = cum_o
        prev_t = t

    mgr_rates = [as_int(r.get("recovering_bytes_per_sec"), 0) for r in win]
    doc = {
        "schema_version": 1,
        "generated_at": utc_now(),
        "window": {"start": as_int(win[0].get("t")), "end": as_int(win[-1].get("t"))},
        "samples": len(win),
        "sample_interval_s": max_delta,
        "recovery_bytes_per_sec_median": statistics.median(rates) if rates else 0.0,
        "recovery_bytes_per_sec_mean": (sum(rates) / len(rates)) if rates else 0.0,
        "recovery_bytes_per_sec_max": max(rates) if rates else 0.0,
        "recovery_bytes_total": total_bytes,
        "recovery_objects_total": total_objs,
        "mgr_recovering_bytes_per_sec_median":
            statistics.median(mgr_rates) if mgr_rates else 0.0,
        # spec §6：peering 區間與 recovery 區間分開統計
        "peering_seconds": peering,
        "recovering_seconds": recovering,
        "inactive_seconds": inactive,
        "degraded_peak_objects": degraded_peak,
        "pg_all_clean_first_t": clean_first,
        "osdmap_epoch_first": epochs[0][1] if epochs else None,
        "osdmap_epoch_last": epochs[-1][1] if epochs else None,
        "osdmap_epoch_changes": [{"t": t, "epoch": e} for t, e in epochs],
        # H-020：down 偵測延遲差異要靠 OSDMap epoch 對齊，不能用注入時刻
        "osd_state_changes": state_changes,
        "sample_holes": [{"start": a, "end": b} for a, b in holes],
    }
    dump(out_path, doc)
    sys.stdout.write("%s\n" % doc["recovery_bytes_per_sec_median"])
    return 0


# -------------------------------------------------------- return backfill ----

def cmd_return_backfill(samples_path, t_in, t_clean, out_path, max_delta):
    t_in = as_int(t_in)
    t_clean = as_int(t_clean)
    max_delta = as_int(max_delta, 15)
    if t_in is None or t_clean is None or t_clean <= t_in:
        die("return-backfill：時戳不合法（osd_in=%s final_clean=%s）" % (t_in, t_clean))
    rows = [r for r in read_jsonl(samples_path)
            if t_in <= as_int(r.get("t"), -1) <= t_clean]
    rows.sort(key=lambda r: as_int(r.get("t"), 0))
    rates, total_bytes, holes = _rate_series(rows, max_delta)
    duration = t_clean - t_in
    doc = {
        "schema_version": 1,
        "generated_at": utc_now(),
        # verdict.py 的欄位契約：heal_t0 / final_clean_t / duration_s / recovery_bytes_per_sec
        "heal_t0": t_in,
        "osd_in_done_t": t_in,
        "final_clean_t": t_clean,
        "duration_s": duration,
        "recovery_bytes_per_sec": total_bytes / float(duration),
        "recovery_bytes_per_sec_median": statistics.median(rates) if rates else 0.0,
        "recovery_bytes_total": total_bytes,
        "samples": len(rows),
        "sample_holes": [{"start": a, "end": b} for a, b in holes],
        # 非 degraded 的回歸 backfill 落 best_effort class（H-008）——
        # 全實驗唯一 lim（90/70/max）會 binding 的場景。
        "qos_class": "background_best_effort",
        "lim_binding": True,
    }
    dump(out_path, doc)
    sys.stdout.write("%d %s\n" % (duration, doc["recovery_bytes_per_sec"]))
    return 0


# -------------------------------------------------------- coverage check ----

def cmd_coverage_check(checks_path, epoch, max_age, *pairs):
    epoch = as_int(epoch)
    max_age = as_int(max_age, 30)
    sources = {}
    bad = 0
    for pair in pairs:
        name, _, raw = pair.rpartition("=")
        age = as_int(raw, -1)
        healthy = 0 <= age <= max_age
        if not healthy:
            bad += 1
        sources[name] = {"age_s": age, "ok": healthy}
    rec = {"t": epoch, "max_age_s": max_age, "sources": sources, "ok": bad == 0}
    d = os.path.dirname(checks_path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(checks_path, "a") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")
    sys.stdout.write("%d %d\n" % (len(sources), bad))
    return 1 if bad else 0


# ----------------------------------------------------- coverage finalize ----

def _fio_seconds(fio_dir):
    """每個 client 的 fio 逐秒樣本落在哪些秒（log_unix_epoch=1 → 第一欄是 ms）。"""
    per_client = {}
    if not os.path.isdir(fio_dir):
        return per_client
    for client in sorted(os.listdir(fio_dir)):
        cdir = os.path.join(fio_dir, client)
        if not os.path.isdir(cdir):
            continue
        secs = set()
        for path in sorted(glob.glob(os.path.join(cdir, "*_iops*.log")) +
                           glob.glob(os.path.join(cdir, "*", "*_iops*.log"))):
            try:
                fh = open(path)
            except OSError:
                continue
            with fh:
                for line in fh:
                    head = line.split(",", 1)[0].strip()
                    val = as_int(head)
                    if val is None:
                        continue
                    secs.add(val // 1000 if val > 10 ** 12 else val)
        per_client[client] = secs
    return per_client


def _broken_runs_from_checks(checks, source, win_start, win_end):
    """由 supervisor 的 heartbeat 證據推該 source 的壞掉區間。

    壞掉區間的起點用 heartbeat 年齡回推（年齡就是「上次活著」的距離），
    終點用下一次健康檢查的年齡回推（那時候已經活著了）。
    """
    runs = []
    cur = None
    prev_t = win_start - 1
    for rec in checks:
        t = as_int(rec.get("t"))
        if t is None:
            continue
        info = (rec.get("sources") or {}).get(source)
        if info is None:
            prev_t = t
            continue
        age = as_int(info.get("age_s"), -1)
        if not info.get("ok", False):
            start = t - age if age > 0 else prev_t + 1
            start = max(start, prev_t + 1)
            if cur is None:
                cur = [start, t]
            else:
                cur[1] = t
        elif cur is not None:
            back = t - age if age >= 0 else t
            cur[1] = max(cur[1], back)
            runs.append((cur[0], cur[1]))
            cur = None
        prev_t = t
    if cur is not None:
        runs.append((cur[0], max(cur[1], win_end)))
    return runs


def _blind_runs(checks, win_start, win_end, cadence):
    """supervisor 自己失聯的區間（沒有按 cadence 回報）。"""
    runs = []
    limit = 2 * cadence
    times = sorted(as_int(r.get("t")) for r in checks if as_int(r.get("t")) is not None)
    if not times:
        return [(win_start, win_end)]
    if times[0] - win_start > limit:
        runs.append((win_start, times[0] - 1))
    for prev, cur in zip(times, times[1:]):
        if cur - prev > limit:
            runs.append((prev + 1, cur - 1))
    if win_end - times[-1] > limit:
        runs.append((times[-1] + 1, win_end))
    return runs


def _sampler_runs(samples, win_start, win_end, max_delta):
    times = sorted(as_int(r.get("t")) for r in samples if as_int(r.get("t")) is not None)
    if not times:
        return [(win_start, win_end)]
    runs = []
    if times[0] - win_start > max_delta:
        runs.append((win_start, times[0] - 1))
    for prev, cur in zip(times, times[1:]):
        if cur - prev > max_delta:
            runs.append((prev + 1, cur - 1))
    if win_end - times[-1] > max_delta:
        runs.append((times[-1] + 1, win_end))
    return runs


def _clip(runs, win_start, win_end):
    out = []
    for a, b in runs:
        a = max(a, win_start)
        b = min(b, win_end)
        if b >= a:
            out.append((a, b))
    return out


def _derive_window(bundle, checks, samples):
    timeline = load_opt(os.path.join(bundle, "fault-timeline.json"), {}) or {}
    fault_t0 = as_int(timeline.get("fault_t0"))
    if fault_t0 is not None:
        pad = as_int(os.environ.get("COLLECT_BASELINE_PAD_SECS"), 60)
        end = None
        for key in ("recovery_complete_t", "measurement_deadline"):
            cand = as_int(timeline.get(key))
            if cand is not None:
                end = cand if end is None else min(end, cand)
        if end is not None:
            return fault_t0 - pad, end
    times = [as_int(r.get("t")) for r in checks if as_int(r.get("t")) is not None]
    times += [as_int(r.get("t")) for r in samples if as_int(r.get("t")) is not None]
    if not times:
        return None, None
    return min(times), max(times)


def cmd_coverage_finalize(bundle, out_path, cadence, tolerance, max_total,
                          sampler_max_delta, start, end):
    cadence = as_int(cadence, 30)
    tolerance = as_int(tolerance, 10)
    max_total = as_int(max_total, 30)
    sampler_max_delta = as_int(sampler_max_delta, 15)
    checks = read_jsonl(os.path.join(bundle, "coverage", "checks.jsonl"))
    checks.sort(key=lambda r: as_int(r.get("t"), 0))
    samples_path = os.path.join(bundle, "sampler", "samples.jsonl")
    if not os.path.exists(samples_path):
        samples_path = os.path.join(bundle, "sampler", "samples.window.jsonl")
    samples = read_jsonl(samples_path)
    win_start = opt_int(start)
    win_end = opt_int(end)
    if win_start is None or win_end is None:
        win_start, win_end = _derive_window(bundle, checks, samples)
    if win_start is None or win_end is None or win_end < win_start:
        die("coverage-finalize：推導不出量測窗（缺 fault-timeline / checks / samples）")

    per_client = _fio_seconds(os.path.join(bundle, "fio"))
    data_secs = set()
    for secs in per_client.values():
        data_secs |= secs

    evidence = []
    for run in _clip(_sampler_runs(samples, win_start, win_end, sampler_max_delta),
                     win_start, win_end):
        evidence.append({"start": run[0], "end": run[1], "source": "sampler",
                         "reason": "no-samples"})
    for run in _clip(_blind_runs(checks, win_start, win_end, cadence),
                     win_start, win_end):
        evidence.append({"start": run[0], "end": run[1], "source": "supervisor",
                         "reason": "no-check"})
    seen_sources = set()
    for rec in checks:
        seen_sources |= set((rec.get("sources") or {}).keys())
    for source in sorted(seen_sources):
        for run in _clip(_broken_runs_from_checks(checks, source, win_start, win_end),
                         win_start, win_end):
            evidence.append({"start": run[0], "end": run[1], "source": source,
                             "reason": "heartbeat"})
    for item in evidence:
        item["duration_s"] = item["end"] - item["start"] + 1

    # gaps = 壞掉證據 ∩ 沒有任何 fio 樣本的秒（有資料的秒永遠不遮）
    gaps = []
    for item in evidence:
        missing = set(range(item["start"], item["end"] + 1)) - data_secs
        for a, b in runs_from_secs(missing):
            gaps.append({"start": a, "end": b, "source": item["source"],
                         "duration_s": b - a + 1,
                         "tolerated": (b - a + 1) < tolerance})
    gaps.sort(key=lambda g: (g["start"], g["source"]))
    gap_secs = set()
    for gap in gaps:
        gap_secs |= set(range(gap["start"], gap["end"] + 1))

    reasons = []
    for item in evidence:
        if item["duration_s"] >= tolerance:
            reasons.append("%s 中斷 %ds（>= 容忍值 %ds）"
                           % (item["source"], item["duration_s"], tolerance))
    total_evidence = 0
    for a, b in merge_intervals([(i["start"], i["end"]) for i in evidence]):
        total_evidence += b - a + 1
    if total_evidence > max_total:
        reasons.append("量測工具中斷總量 %ds > %ds" % (total_evidence, max_total))

    window_secs = win_end - win_start + 1
    covered = len(set(range(win_start, win_end + 1)) & data_secs)
    sources_doc = {}
    sampler_secs = set(as_int(r.get("t")) for r in samples
                       if as_int(r.get("t")) is not None)
    sources_doc["sampler"] = {
        "samples": len(sampler_secs & set(range(win_start, win_end + 1))),
        "expected": window_secs // max(1, sampler_max_delta // 3),
    }
    for client, secs in sorted(per_client.items()):
        sources_doc["fio:%s" % client] = {
            "covered_seconds": len(secs & set(range(win_start, win_end + 1))),
            "window_seconds": window_secs,
        }

    doc = {
        "schema_version": 1,
        "generated_at": utc_now(),
        "bundle": bundle,
        "window": {"start": win_start, "end": win_end, "seconds": window_secs},
        "cadence_s": cadence,
        "gap_tolerance_s": tolerance,
        "max_total_gap_s": max_total,
        "checks": {"count": len(checks),
                   "first": as_int(checks[0].get("t")) if checks else None,
                   "last": as_int(checks[-1].get("t")) if checks else None},
        "sources": sources_doc,
        "evidence": evidence,
        "evidence_seconds": total_evidence,
        "gaps": gaps,
        "gap_seconds": len(gap_secs),
        "covered_seconds": covered,
        "tainted": bool(reasons),
        "taint_reasons": reasons,
    }
    dump(out_path, doc)
    sys.stdout.write("gaps=%d gap_seconds=%d tainted=%s\n"
                     % (len(gaps), len(gap_secs),
                        "true" if reasons else "false"))
    return 1 if reasons else 0


# ------------------------------------------------------------ fio summary ---

def cmd_fio_summary(fio_dir, out_path):
    clients = {}
    nonzero = 0
    errors = []
    if os.path.isdir(fio_dir):
        for client in sorted(os.listdir(fio_dir)):
            cdir = os.path.join(fio_dir, client)
            if not os.path.isdir(cdir):
                continue
            exits = {}
            for path in sorted(glob.glob(os.path.join(cdir, "*.exit"))):
                try:
                    with open(path) as fh:
                        code = as_int(fh.read().strip(), -1)
                except OSError as exc:
                    errors.append("%s: %s" % (path, exc))
                    continue
                exits[os.path.basename(path)[:-5]] = code
                if code != 0:
                    nonzero += 1
            jobs = []
            for path in sorted(glob.glob(os.path.join(cdir, "*.json"))):
                doc = load_opt(path)
                if not isinstance(doc, dict) or "jobs" not in doc:
                    continue
                for job in doc.get("jobs") or []:
                    entry = {"jobname": job.get("jobname"),
                             "error": job.get("error"),
                             "source": os.path.basename(path)}
                    for direction in ("read", "write"):
                        blob = job.get(direction) or {}
                        pct = ((blob.get("clat_ns") or {}).get("percentile") or {})
                        entry[direction] = {
                            "iops": blob.get("iops"),
                            "bw_bytes": blob.get("bw_bytes"),
                            "clat_ns_p99": pct.get("99.000000"),
                        }
                    jobs.append(entry)
            logs = len(glob.glob(os.path.join(cdir, "*.log")))
            if not exits:
                errors.append("%s 沒有 exit proof（Task 7 契約：<run-id>.exit）" % client)
            clients[client] = {"exit_codes": exits, "jobs": jobs, "log_files": logs}
    doc = {
        "schema_version": 1,
        "generated_at": utc_now(),
        "clients": clients,
        "clients_n": len(clients),
        "nonzero_exits": nonzero,
        "errors": errors,
    }
    dump(out_path, doc)
    sys.stdout.write("%d %d\n" % (len(clients), nonzero))
    return 0


# ---------------------------------------------------------------- window ----

def cmd_window(bundle, start, end):
    checks = read_jsonl(os.path.join(bundle, "coverage", "checks.jsonl"))
    samples = read_jsonl(os.path.join(bundle, "sampler", "samples.jsonl"))
    win_start = opt_int(start)
    win_end = opt_int(end)
    if win_start is None or win_end is None:
        derived = _derive_window(bundle, checks, samples)
        win_start = win_start if win_start is not None else derived[0]
        win_end = win_end if win_end is not None else derived[1]
    if win_start is None or win_end is None:
        die("window：推導不出量測窗")
    timeline = load_opt(os.path.join(bundle, "fault-timeline.json"), {}) or {}
    final_clean = as_int(timeline.get("final_clean_t"))
    prom_end = max(win_end, final_clean) if final_clean is not None else win_end
    sys.stdout.write("%d %d %d\n" % (win_start, win_end, prom_end))
    return 0


# ------------------------------------------------------------- prom index ---

def cmd_prom_index(prom_dir, out_path, win_start, win_end, step):
    series = {}
    for path in sorted(glob.glob(os.path.join(prom_dir, "*.json"))):
        name = os.path.basename(path)[:-5]
        if name == "index":
            continue
        doc = load_opt(path)
        if not isinstance(doc, dict):
            series[name] = {"status": "unparseable", "series": 0}
            continue
        result = ((doc.get("data") or {}).get("result")) or []
        series[name] = {"status": doc.get("status"), "series": len(result)}
    doc = {
        "schema_version": 1,
        "generated_at": utc_now(),
        "url": os.environ.get("COLLECT_PROM_URL", ""),
        "window": {"start": as_int(win_start), "end": as_int(win_end)},
        "step_s": as_int(step),
        "queries": series,
        "queries_n": len(series),
    }
    dump(out_path, doc)
    sys.stdout.write("%d\n" % len(series))
    return 0


# ------------------------------------------------------------- bg state -----

def cmd_bg_state_write(out_path, *entries):
    rows = []
    for entry in entries:
        node, run_id, data_dir = entry.split("|", 2)
        rows.append({"node": node, "run_id": run_id, "data_dir": data_dir,
                     "hb": os.environ.get("BG_REGISTRY_DIR", "/run/mclock")
                           + "/" + run_id + ".hb"})
    dump(out_path, {"schema_version": 1, "started_at": utc_now(), "entries": rows})
    sys.stdout.write("%d\n" % len(rows))
    return 0


def cmd_bg_state_list(path):
    doc = load_opt(path, {}) or {}
    for entry in doc.get("entries") or []:
        sys.stdout.write("%s %s %s\n" % (entry.get("node"), entry.get("run_id"),
                                         entry.get("data_dir")))
    return 0


# ---------------------------------------------------------------- field -----

def cmd_field(path, dotted):
    doc = load(path)
    cur = doc
    for key in dotted.split("."):
        if isinstance(cur, list):
            cur = cur[int(key)]
        else:
            cur = cur[key]
    sys.stdout.write("%s\n" % cur)
    return 0


def cmd_json_write(path, *pairs):
    """把 `key=value` 寫成 JSON（value 是數字就存數字）。"""
    doc = {}
    for pair in pairs:
        key, _, val = pair.partition("=")
        try:
            num = int(val)
            doc[key] = num
            continue
        except ValueError:
            pass
        doc[key] = val
    dump(path, doc)
    return 0


# ------------------------------------------------------------ env snapshot --

def _parse_sections(text):
    sections = {}
    name = None
    buf = []
    for line in text.splitlines():
        if line.startswith("##"):
            if name is not None:
                sections[name] = buf
            name = line[2:].strip()
            buf = []
        elif name is not None:
            buf.append(line)
    if name is not None:
        sections[name] = buf
    return sections


def cmd_env_provision(scratch, out_path):
    nodes = {}
    for path in sorted(glob.glob(os.path.join(scratch, "*.txt"))):
        node = os.path.basename(path)[:-4]
        with open(path) as fh:
            sections = _parse_sections(fh.read())
        if "end" not in sections:
            die("env-provision：%s 的輸出不完整（缺 ##end）" % node)
        osrel = {}
        for line in sections.get("osrelease", []):
            key, _, val = line.partition("=")
            if key:
                osrel[key.strip()] = val.strip().strip('"')
        packages = {}
        for line in sections.get("packages", []):
            parts = line.split()
            if len(parts) >= 2:
                packages[parts[0]] = parts[1]
        mem_kb = None
        for line in sections.get("meminfo", []):
            parts = line.split()
            if len(parts) >= 2:
                mem_kb = as_int(parts[1])
        uptime = None
        for line in sections.get("uptime", []):
            parts = line.split()
            if parts:
                try:
                    uptime = float(parts[0])
                except ValueError:
                    uptime = None
        fio_lines = [x for x in sections.get("fio", []) if x.strip()]
        nodes[node] = {
            "kernel": (sections.get("kernel") or [""])[0].strip(),
            "os": osrel,
            "packages": packages,
            "fio_version": fio_lines[0].strip() if fio_lines else None,
            "nproc": as_int((sections.get("nproc") or [""])[0].strip()),
            "mem_total_kb": mem_kb,
            "boot_id": (sections.get("bootid") or [""])[0].strip(),
            "uptime_s": uptime,
            "ntp_synchronized": (sections.get("timesync") or [""])[0].strip(),
        }
    if not nodes:
        die("env-provision：沒有任何 node 輸出")
    dump(out_path, {"schema_version": 1, "generated_at": utc_now(),
                    "stage": "provision", "nodes": nodes, "nodes_n": len(nodes)})
    sys.stdout.write("%d\n" % len(nodes))
    return 0


def cmd_env_cluster(scratch, out_path):
    status = load(os.path.join(scratch, "status.json"))
    osdmap_s = status.get("osdmap") or {}
    if as_int(osdmap_s.get("num_osds"), 0) <= 0:
        die("env-cluster：cluster 尚未部署完成（num_osds=0），前置狀態不成立")
    osddump = load_opt(os.path.join(scratch, "osd-dump.json"), {}) or {}
    flags = osddump.get("flags")
    if flags is None:
        flags = ",".join(osddump.get("flags_set") or [])
    doc = {
        "schema_version": 1,
        "generated_at": utc_now(),
        "stage": "cluster",
        "fsid": status.get("fsid"),
        "health": (status.get("health") or {}).get("status"),
        "versions": load_opt(os.path.join(scratch, "versions.json"), {}),
        "crush_tree": load_opt(os.path.join(scratch, "crush-tree.json"), {}),
        "pools": load_opt(os.path.join(scratch, "pool-ls-detail.json"), {}),
        "config_dump": load_opt(os.path.join(scratch, "config-dump.json"), []),
        "osdmap": {
            "epoch": as_int(osddump.get("epoch")),
            "flags": flags,
            "num_osds": as_int(osdmap_s.get("num_osds")),
            "num_up_osds": as_int(osdmap_s.get("num_up_osds")),
            "num_in_osds": as_int(osdmap_s.get("num_in_osds")),
        },
    }
    dump(out_path, doc)
    sys.stdout.write("ok\n")
    return 0


def cmd_env_map(scratch, out_path):
    nodes = {}
    for path in sorted(glob.glob(os.path.join(scratch, "*.txt"))):
        node = os.path.basename(path)[:-4]
        with open(path) as fh:
            sections = _parse_sections(fh.read())
        raw = "\n".join(sections.get("showmapped", [])).strip()
        try:
            mapped = json.loads(raw) if raw else []
        except ValueError:
            mapped = []
        if isinstance(mapped, dict):
            mapped = list(mapped.values())
        if not mapped:
            die("env-map：%s 沒有任何 mapped RBD image（前置狀態不成立）" % node)
        devices = {}
        cur = None
        fields = ["scheduler", "read_ahead_kb", "nr_requests", "rotational"]
        idx = 0
        for line in sections.get("devices", []):
            if line.startswith("#dev "):
                cur = line[5:].strip()
                devices[cur] = {}
                idx = 0
                continue
            if cur is None or idx >= len(fields):
                continue
            key = fields[idx]
            val = line.strip()
            devices[cur][key] = as_int(val) if key != "scheduler" else val
            idx += 1
        nodes[node] = {"mapped": mapped, "devices": devices}
    if not nodes:
        die("env-map：沒有任何 client 輸出")
    dump(out_path, {"schema_version": 1, "generated_at": utc_now(),
                    "stage": "map", "nodes": nodes, "nodes_n": len(nodes)})
    sys.stdout.write("%d\n" % len(nodes))
    return 0


DISPATCH = {
    "tick": cmd_tick,
    "sampler-summary": cmd_sampler_summary,
    "return-backfill": cmd_return_backfill,
    "coverage-check": cmd_coverage_check,
    "coverage-finalize": cmd_coverage_finalize,
    "fio-summary": cmd_fio_summary,
    "window": cmd_window,
    "prom-index": cmd_prom_index,
    "bg-state-write": cmd_bg_state_write,
    "bg-state-list": cmd_bg_state_list,
    "field": cmd_field,
    "json-write": cmd_json_write,
    "env-provision": cmd_env_provision,
    "env-cluster": cmd_env_cluster,
    "env-map": cmd_env_map,
}

if len(sys.argv) < 2 or sys.argv[1] not in DISPATCH:
    die("未知子指令：%s" % (sys.argv[1] if len(sys.argv) > 1 else ""))
sys.exit(DISPATCH[sys.argv[1]](*sys.argv[2:]) or 0)
PY
)"

_collect_py() { python3 -c "$_COLLECT_PY_SRC" "$@"; }
_collect_py_b64() { printf '%s' "$_COLLECT_PY_SRC" | base64 | tr -d '\n'; }

# collect_py_tick：sampler 每輪用的樣本產生器（測試以真實格式 fixture 鎖住欄位）。
collect_py_tick() { _collect_py tick "$@"; }

# =============================================================================
# replicate 級 sampler
# =============================================================================

_sampler_marker() { printf '%s/sampler/run.json\n' "${1%/}"; }
_sampler_stopped_marker() { printf '%s/sampler/stopped.json\n' "${1%/}"; }

# sampler_start <bundle>：lock → 遠端 5s 迴圈（pg dump 差分 / ceph -s / OSDMap epoch）
# → PID registry + heartbeat → bundle 內留 run marker。stdout = 機器行。
sampler_start() {
  [ $# -eq 1 ] || die "用法：sampler_start <bundle>"
  local bundle="${1%/}" id data hb script pid
  id="$(collect_sampler_run_id "$bundle")"
  data="${SAMPLER_REMOTE_ROOT}/${id}"
  hb="$(collect_hb_path "$id")"
  [ -d "$bundle" ] || die "bundle 不存在：${bundle}"

  _collect_lock "$ADMIN_NAME" "$id" \
    || die "sampler lock 取不到（${id}）——可能已有另一個 sampler 在跑"

  script="$(cat <<REMOTE
set -u
D=${data}
HB=${hb}
mkdir -p \$D
printf %s '$(_collect_py_b64)' | base64 --decode > \$D/collect.py
while :; do
  T=\$(date +%s)
  sudo ceph pg dump --format json > \$D/.pg.json 2>/dev/null
  sudo ceph -s --format json > \$D/.status.json 2>/dev/null
  sudo ceph osd dump --format json > \$D/.osd.json 2>/dev/null
  if python3 \$D/collect.py tick \$T \$D/.pg.json \$D/.status.json \$D/.osd.json \
       >> \$D/samples.jsonl 2>/dev/null; then
    [ -s \$D/pgdump-first.json ] || cp \$D/.pg.json \$D/pgdump-first.json
    cp \$D/.pg.json \$D/pgdump-last.json
    date +%s > \$HB
  fi
  sleep ${SAMPLER_INTERVAL_SECS}
done
REMOTE
)"
  pid="$(remote_bg_start "$ADMIN_NAME" "$id" "$script")" || {
    _collect_unlock "$ADMIN_NAME" "$id"
    die "sampler 啟動失敗：${id}"
  }
  pid="$(printf '%s' "$pid" | tr -d ' \r\n')"
  mkdir -p "$bundle/sampler"
  rm -f "$(_sampler_stopped_marker "$bundle")"
  _collect_py json-write "$(_sampler_marker "$bundle")" \
    "run_id=${id}" "node=${ADMIN_NAME}" "data_dir=${data}" "hb=${hb}" \
    "pid=${pid}" "interval_s=${SAMPLER_INTERVAL_SECS}" \
    "started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    || die "sampler run marker 寫入失敗"
  cleanup_push "sampler_stop '${bundle}' >/dev/null 2>&1 || true"
  printf 'sampler: STARTED %s %s\n' "$id" "$pid"
}

# sampler_assert_alive <bundle>：heartbeat 新鮮度（rc 1 = 不新鮮）。
# pipeline 於 start 之後、以及固定 30s cadence 呼叫。
sampler_assert_alive() {
  [ $# -eq 1 ] || die "用法：sampler_assert_alive <bundle>"
  local bundle="${1%/}" marker id node status age state
  marker="$(_sampler_marker "$bundle")"
  [ -s "$marker" ] || die "sampler 尚未啟動（缺 ${marker}）"
  id="$(_collect_py field "$marker" run_id)"
  node="$(_collect_py field "$marker" node)"
  status="$(_collect_hb_status "$node" "$id")" || {
    log "sampler_assert_alive：取不到 ${id} 的 heartbeat"
    return 1
  }
  age="${status%% *}"
  state="${status##* }"
  case "$age" in ''|*[!0-9-]*) age=-1 ;; esac
  if [ "$age" -lt 0 ] || [ "$age" -gt "$SAMPLER_HB_MAX_AGE_SECS" ]; then
    log "sampler_assert_alive：${id} heartbeat 年齡 ${age}s（上限 ${SAMPLER_HB_MAX_AGE_SECS}s，pid=${state}）"
    return 1
  fi
  printf 'sampler-alive: OK %s\n' "$age"
}

# sampler_stop <bundle>：冪等——沒 marker 或已停就完全不打 ssh。
sampler_stop() {
  [ $# -eq 1 ] || die "用法：sampler_stop <bundle>"
  local bundle="${1%/}" marker id node
  marker="$(_sampler_marker "$bundle")"
  if [ ! -s "$marker" ]; then
    printf 'sampler: STOPPED -\n'
    return 0
  fi
  id="$(_collect_py field "$marker" run_id)"
  node="$(_collect_py field "$marker" node)"
  if [ -s "$(_sampler_stopped_marker "$bundle")" ]; then
    printf 'sampler: STOPPED %s\n' "$id"
    return 0
  fi
  remote_bg_stop "$node" "$id" >/dev/null || log "sampler 停止指令失敗（續行）：${id}"
  _collect_unlock "$node" "$id"
  _collect_py json-write "$(_sampler_stopped_marker "$bundle")" \
    "run_id=${id}" "node=${node}" "stopped_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    || die "sampler stopped marker 寫入失敗"
  printf 'sampler: STOPPED %s\n' "$id"
}

# =============================================================================
# campaign 級 collector（ping mesh / NIC 差分 / SLOW_OPS + health 事件）
# =============================================================================

_bgc_net_run_id() { printf 'bgc-net-%s\n' "$1"; }
_bgc_events_run_id() { printf 'bgc-events\n'; }

_bgc_all_ips() { # 全 node private IP（ping mesh 目標）
  local n out=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    out="${out} $(inv_ip "$n")"
  done <<< "$(inv_names)"
  printf '%s\n' "${out# }"
}

_bgc_net_script() { # <data-dir> <hb> <ping 目標 IP...>
  local data="$1" hb="$2" ips="$3"
  cat <<REMOTE
set -u
D=${data}
HB=${hb}
mkdir -p \$D
fping -p ${PING_PERIOD_MS} -l -D -e ${ips} >> \$D/ping.log 2>&1 &
sar -n DEV ${SAR_INTERVAL_SECS} >> \$D/nic.log 2>&1 &
while :; do
  date +%s > \$HB
  sleep ${BGC_INTERVAL_SECS}
done
REMOTE
}

_bgc_events_script() { # <data-dir> <hb>
  local data="$1" hb="$2"
  cat <<REMOTE
set -u
D=${data}
HB=${hb}
mkdir -p \$D
sudo ceph -W cluster --format json >> \$D/cluster-events.jsonl 2>&1 &
while :; do
  sudo ceph health detail --format json >> \$D/health-detail.jsonl 2>/dev/null
  date +%s > \$HB
  sleep ${BGC_INTERVAL_SECS}
done
REMOTE
}

# _bgc_script_for <node> <run-id> <data-dir>：由 run-id 決定該 collector 的腳本，
# start 與 reconcile 的 restart 走同一份（不得有第二份定義）。
_bgc_script_for() { # <run-id> <data-dir>
  local id="$1" data="$2" hb
  hb="$(collect_hb_path "$id")"
  case "$id" in
    bgc-events) _bgc_events_script "$data" "$hb" ;;
    *) _bgc_net_script "$data" "$hb" "$(_bgc_all_ips)" ;;
  esac
}

_bgc_start_one() { # <node> <run-id> <data-dir>
  local node="$1" id="$2" data="$3" script
  script="$(_bgc_script_for "$id" "$data")"
  _collect_lock "$node" "$id" || die "bg collector lock 取不到：${id} @ ${node}"
  remote_bg_start "$node" "$id" "$script" >/dev/null || {
    _collect_unlock "$node" "$id"
    die "bg collector 啟動失敗：${id} @ ${node}"
  }
}

bg_collect_start() {
  local node id data entries n=0
  entries=()
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    id="$(_bgc_net_run_id "$node")"
    data="${BGC_REMOTE_ROOT}/${node}"
    _bgc_start_one "$node" "$id" "$data"
    entries[${#entries[@]}]="${node}|${id}|${data}"
    n=$((n + 1))
  done <<< "$(inv_names)"

  id="$(_bgc_events_run_id)"
  data="${BGC_REMOTE_ROOT}/events"
  _bgc_start_one "$ADMIN_NAME" "$id" "$data"
  entries[${#entries[@]}]="${ADMIN_NAME}|${id}|${data}"
  n=$((n + 1))

  mkdir -p "$(dirname "$(bg_collect_state_path)")"
  BG_REGISTRY_DIR="$BG_REGISTRY_DIR" _collect_py bg-state-write \
    "$(bg_collect_state_path)" "${entries[@]+"${entries[@]}"}" >/dev/null \
    || die "bg-collect state 檔寫入失敗"
  printf 'bg-collect: STARTED %s\n' "$n"
}

# bg_collect_assert_alive：每個 collector 的 heartbeat；死掉的要指名
#（watchdog 的 sampler/bg-collector trigger 只重啟 collector，不碰 OSD）。
bg_collect_assert_alive() {
  local state node id data age dead="" n=0
  state="$(bg_collect_state_path)"
  if [ ! -s "$state" ]; then
    printf 'bg-collect: MISSING-STATE\n'
    return 1
  fi
  while read -r node id data; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    age="$(_collect_hb_age "$node" "$id")"
    case "$age" in ''|*[!0-9-]*) age=-1 ;; esac
    if [ "$age" -lt 0 ] || [ "$age" -gt "$BGC_HB_MAX_AGE_SECS" ]; then
      log "bg-collect：${id} @ ${node} heartbeat 年齡 ${age}s（上限 ${BGC_HB_MAX_AGE_SECS}s）"
      if [ -z "$dead" ]; then dead="$id"; else dead="${dead},${id}"; fi
    fi
  done <<< "$(_collect_py bg-state-list "$state")"
  if [ -n "$dead" ]; then
    printf 'bg-collect: DEAD %s %s\n' "$(printf '%s' "$dead" | awk -F, '{print NF}')" "$dead"
    return 1
  fi
  printf 'bg-collect: ALIVE %s\n' "$n"
}

# bg_collect_ensure：reconcile / resume 用——沒 state 檔就整組啟動；有的話只重啟
# heartbeat 死掉的那幾個（watchdog 的 collector trigger **不得**碰 OSD／cluster）。
bg_collect_ensure() {
  local state node id data age n=0
  state="$(bg_collect_state_path)"
  if [ ! -s "$state" ]; then
    bg_collect_start
    return 0
  fi
  while read -r node id data; do
    [ -n "$id" ] || continue
    age="$(_collect_hb_age "$node" "$id")"
    case "$age" in ''|*[!0-9-]*) age=-1 ;; esac
    [ "$age" -ge 0 ] && [ "$age" -le "$BGC_HB_MAX_AGE_SECS" ] && continue
    log "bg-collect：${id} @ ${node} 已死（age=${age}s），重啟"
    remote_bg_stop "$node" "$id" >/dev/null || log "殘留 process 清理失敗（續行）：${id}"
    _collect_unlock "$node" "$id"
    _bgc_start_one "$node" "$id" "$data"
    n=$((n + 1))
  done <<< "$(_collect_py bg-state-list "$state")"
  printf 'bg-collect: RESTARTED %s\n' "$n"
}

# bg_collect_stop [outdir]：停 → 放 lock → 回收資料；state 檔轉為 stopped（冪等）。
bg_collect_stop() {
  local out="${1:-$(bg_collect_data_dir)}" state node id data n=0
  state="$(bg_collect_state_path)"
  if [ ! -s "$state" ]; then
    printf 'bg-collect: STOPPED 0\n'
    return 0
  fi
  while read -r node id data; do
    [ -n "$id" ] || continue
    remote_bg_stop "$node" "$id" >/dev/null || log "bg collector 停止失敗（續行）：${id}"
    _collect_unlock "$node" "$id"
    if [ "${BG_COLLECT_FETCH:-1}" = "1" ]; then
      _collect_fetch_dir "$node" "$data" "${out}/${node}" \
        || log "bg collector 資料回收失敗（續行）：${id}"
    fi
    n=$((n + 1))
  done <<< "$(_collect_py bg-state-list "$state")"
  mv -f "$state" "${state%.json}.stopped.json" || die "bg-collect state 檔轉存失敗"
  printf 'bg-collect: STOPPED %s\n' "$n"
}

# =============================================================================
# coverage supervisor
# =============================================================================

# _collect_fio_hb_age <bundle> <client>：fio 那邊的 heartbeat 年齡（取不到回 -1）。
# Task 7 的 fio.sh 把 heartbeat 寫在 `<workdir>/heartbeat`，workdir 記在
# `<bundle>/fio/run.tsv`（client<TAB>run-id<TAB>workdir）——有 run.tsv 就以它為準；
# 沒有（fio 還沒起、或用 registry 慣例的實作）才退回 `<registry>/<run-id>.hb`。
_collect_fio_hb_age() {
  local bundle="${1%/}" client="$2" tsv wd cmd out
  tsv="${bundle}/fio/run.tsv"
  if [ -s "$tsv" ]; then
    wd="$(awk -F'\t' -v c="$client" '$1 == c {print $3}' "$tsv")"
    if [ -n "$wd" ]; then
      cmd="if [ -s ${wd}/heartbeat ];"
      cmd="${cmd} then echo \$(( \$(date +%s) - \$(cat ${wd}/heartbeat) ));"
      cmd="${cmd} else echo -1; fi"
      out="$(_node_sh "$client" 60 "$cmd")" || { printf '%s\n' "-1"; return 0; }
      printf '%s\n' "${out%% *}"
      return 0
    fi
  fi
  _collect_hb_age "$client" "$(collect_fio_run_id "$bundle" "$client")"
}

# coverage_check <bundle> [epoch]：sampler + 各 client fio 的 heartbeat 新鮮度。
# rc 1 = 有 source 退化（pipeline 據此累計 gap；持續 gap → 該 attempt taint）。
coverage_check() {
  [ $# -ge 1 ] || die "用法：coverage_check <bundle> [epoch]"
  local bundle="${1%/}" epoch="${2:-}" marker id node age pairs client rc out
  marker="$(_sampler_marker "$bundle")"
  [ -s "$marker" ] || die "coverage_check：sampler 尚未啟動（缺 ${marker}）"
  [ -n "$epoch" ] || epoch="$(date -u '+%s')"
  id="$(_collect_py field "$marker" run_id)"
  node="$(_collect_py field "$marker" node)"
  pairs=()
  age="$(_collect_hb_age "$node" "$id")"
  pairs[${#pairs[@]}]="sampler=${age}"
  while IFS= read -r client; do
    [ -n "$client" ] || continue
    age="$(_collect_fio_hb_age "$bundle" "$client")"
    pairs[${#pairs[@]}]="fio:${client}=${age}"
  done <<< "$(inv_names client)"

  out="$(_collect_py coverage-check "${bundle}/coverage/checks.jsonl" "$epoch" \
        "$FIO_HB_MAX_AGE_SECS" "${pairs[@]+"${pairs[@]}"}")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'coverage-check: OK %s\n' "${out%% *}"
    return 0
  fi
  printf 'coverage-check: DEGRADED %s\n' "${out##* }"
  return 1
}

# coverage_finalize <bundle> [start] [end] → coverage-proof.json（rc 1 = tainted）。
# 必須在 collect_cell 之後呼叫（要有本地的 sampler samples 與 fio 逐秒 log）。
coverage_finalize() {
  [ $# -ge 1 ] || die "用法：coverage_finalize <bundle> [win-start] [win-end]"
  local bundle="${1%/}" start="${2:--}" end="${3:--}" out rc
  [ -d "$bundle" ] || die "bundle 不存在：${bundle}"
  out="$(COLLECT_BASELINE_PAD_SECS="$COLLECT_BASELINE_PAD_SECS" \
    _collect_py coverage-finalize "$bundle" "${bundle}/coverage-proof.json" \
      "$COVERAGE_CADENCE_SECS" "$COVERAGE_GAP_TOLERANCE_SECS" \
      "$COVERAGE_MAX_TOTAL_GAP_SECS" "$COLLECT_SAMPLER_MAX_DELTA_SECS" \
      "$start" "$end")"
  rc=$?
  case "$out" in
    *"tainted=true"*)
      printf 'coverage-proof: TAINTED %s\n' "$out"
      return 1
      ;;
    '')
      die "coverage_finalize 未產出結果（${bundle}）"
      ;;
  esac
  [ "$rc" -eq 0 ] || return "$rc"
  printf 'coverage-proof: OK %s\n' "$out"
}

# =============================================================================
# return-backfill（H-008）
# =============================================================================

# collect_return_backfill <bundle> <osd-in-done-epoch> <final-clean-epoch>
#   safety gate 期間呼叫（sampler 還在跑，資料是 append-only，可安全複製）。
collect_return_backfill() {
  [ $# -eq 3 ] || die "用法：collect_return_backfill <bundle> <osd-in-done-epoch> <final-clean-epoch>"
  local bundle="${1%/}" t_in="$2" t_clean="$3" out
  _collect_fetch_sampler "$bundle" || die "return-backfill：sampler 資料取不到"
  out="$(_collect_py return-backfill "${bundle}/sampler/samples.jsonl" \
        "$t_in" "$t_clean" "${bundle}/return-backfill.json" \
        "$COLLECT_SAMPLER_MAX_DELTA_SECS")" \
    || die "return-backfill 產生失敗"
  printf 'return-backfill: OK %s\n' "$out"
}

# =============================================================================
# collect_cell
# =============================================================================

# _collect_fetch_dir <node> <remote-dir> <local-dir>：tar over ssh（唯讀、有界）。
_collect_fetch_dir() {
  local node="$1" remote="$2" local_dir="$3" rc
  mkdir -p "$local_dir" || die "建立目錄失敗：${local_dir}"
  node_ssh "$node" "timeout ${COLLECT_TAR_TIMEOUT} tar -C ${remote} -cf - ." \
    | tar -C "$local_dir" -xf - 2>/dev/null
  rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || return 1
  return 0
}

# _collect_fetch_sampler <bundle>：把 admin 上的 sampler 資料夾整包拉回 bundle。
_collect_fetch_sampler() {
  local bundle="${1%/}" marker node data
  marker="$(_sampler_marker "$bundle")"
  [ -s "$marker" ] || { log "sampler run marker 不存在，略過回收：${bundle}"; return 1; }
  node="$(_collect_py field "$marker" node)"
  data="$(_collect_py field "$marker" data_dir)"
  _collect_fetch_dir "$node" "$data" "${bundle}/sampler"
}

# _collect_fetch_fio <bundle>：四台 client 的 fio 輸出（三 log + JSON + exit proof）。
# 遠端來源優先取 `<bundle>/fio/run.tsv` 記的 workdir（Task 7 fio.sh 的契約）；
# `fio_stop` 成功時已經把同一份資料收回 `<bundle>/fio/<client>/`，此時**不再重拉**
#（一個 45min replicate 的逐秒 log 不小，重拉只是浪費頻寬與時間）。
_collect_fetch_fio() {
  local bundle="${1%/}" key client tsv wd remote dest
  key="$(collect_bundle_key "$bundle")"
  tsv="${bundle}/fio/run.tsv"
  while IFS= read -r client; do
    [ -n "$client" ] || continue
    dest="${bundle}/fio/${client}"
    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
      log "fio 輸出已在 bundle 內，略過回收：${client}"
      continue
    fi
    wd=""
    [ -s "$tsv" ] && wd="$(awk -F'\t' -v c="$client" '$1 == c {print $3}' "$tsv")"
    remote="${wd:-${FIO_REMOTE_ROOT}/${key}/${client}}"
    _collect_fetch_dir "$client" "$remote" "$dest" \
      || log "fio 輸出回收失敗（續行）：${client}"
  done <<< "$(inv_names client)"
}

# _collect_prometheus <bundle> <start> <end>：cephadm 內建 prometheus 的時窗 export。
# 失敗不致命（不在 required-files schema 內），但每個 query 的結果都會記進 index.json。
_collect_prometheus() {
  local bundle="${1%/}" start="$2" end="$3" line name query dir
  dir="${bundle}/prometheus"
  mkdir -p "$dir"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%=*}"
    query="${line#*=}"
    # query 直接進遠端指令列，含空白會把指令切斷（且 curl 的 --data-urlencode 只吃一個
    # token）——寧可當場死，也不要靜默送出被截斷的查詢。
    case "$query" in
      *[[:space:]]*) die "prometheus query 不得含空白：${name}=${query}" ;;
    esac
    node_ssh "$ADMIN_NAME" \
      "timeout ${COLLECT_CMD_TIMEOUT} curl -sS -G ${COLLECT_PROM_URL}/api/v1/query_range --data-urlencode query=${query} --data-urlencode start=${start} --data-urlencode end=${end} --data-urlencode step=${COLLECT_PROM_STEP}" \
      > "${dir}/${name}.json" 2>/dev/null \
      || log "prometheus query 失敗（續行）：${name}"
  done <<< "$COLLECT_PROM_QUERIES"
  COLLECT_PROM_URL="$COLLECT_PROM_URL" _collect_py prom-index "$dir" \
    "${dir}/index.json" "$start" "$end" "$COLLECT_PROM_STEP" >/dev/null \
    || log "prometheus index 產生失敗（續行）"
}

# collect_cell <bundle> <kind> [win-start] [win-end]
collect_cell() {
  [ $# -ge 2 ] || die "用法：collect_cell <bundle> <kind> [win-start] [win-end]"
  local bundle="${1%/}" kind="$2" start="${3:--}" end="${4:--}"
  local win win_start win_end prom_end id req f missing=0
  [ -d "$bundle" ] || die "bundle 不存在：${bundle}"

  _collect_fetch_fio "$bundle"
  _collect_fetch_sampler "$bundle" || log "sampler 資料未回收（續行）：${bundle}"

  win="$(_collect_py window "$bundle" "$start" "$end")" \
    || die "collect_cell：推導不出量測窗（${bundle}）"
  win_start="$(printf '%s' "$win" | awk '{print $1}')"
  win_end="$(printf '%s' "$win" | awk '{print $2}')"
  prom_end="$(printf '%s' "$win" | awk '{print $3}')"

  if [ -s "${bundle}/sampler/samples.jsonl" ]; then
    _collect_py sampler-summary "${bundle}/sampler/samples.jsonl" \
      "${bundle}/sampler/samples.window.jsonl" "${bundle}/sampler-summary.json" \
      "$win_start" "$win_end" "$COLLECT_SAMPLER_MAX_DELTA_SECS" >/dev/null \
      || die "sampler-summary 產生失敗（${bundle}）"
  else
    log "collect_cell：沒有 sampler 樣本，跳過 sampler-summary"
  fi

  _collect_py fio-summary "${bundle}/fio" "${bundle}/fio-summary.json" >/dev/null \
    || die "fio-summary 產生失敗（${bundle}）"

  mkdir -p "${bundle}/config-show"
  for id in $(ceph_osd_ids); do
    ceph_adm "ceph tell osd.${id} config show" > "${bundle}/config-show/osd.${id}.json" \
      || log "osd.${id} config show 快照失敗（續行）"
  done
  ceph_adm "ceph df --format json" > "${bundle}/ceph-df.json" \
    || log "ceph df 快照失敗（續行）"

  _collect_prometheus "$bundle" "$win_start" "$prom_end"

  req="$(python3 "$VERDICT_PY" schemas "$kind")" \
    || die "取不到 ${kind} 的 required-files schema"
  while IFS= read -r f; do
    case "$f" in ''|'#'*) continue ;; esac
    [ -s "${bundle}/${f}" ] || missing=$((missing + 1))
  done <<< "$req"
  printf 'collect-cell: PASS %s missing=%s\n' "$bundle" "$missing"
}

# =============================================================================
# env snapshot 三段
# =============================================================================

_collect_scratch() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/mclock-collect.XXXXXX")" || die "無法建立暫存目錄"
  cleanup_push "rm -rf '$dir'"
  printf '%s\n' "$dir"
}

# env_snapshot_provision [outdir]：版本／套件／kernel／fio 版本（部署前收）。
env_snapshot_provision() {
  local out="${1:-$(collect_env_dir)}" scratch node cmd n
  [ -n "${ADMIN_NAME:-}" ] || die "env_snapshot_provision：inventory 未載入"
  scratch="$(_collect_scratch)"
  cmd="echo \"##kernel\"; uname -r;"
  cmd="${cmd} echo \"##osrelease\"; cat /etc/os-release;"
  cmd="${cmd} echo \"##packages\"; dpkg-query -W ${COLLECT_PKGS} 2>/dev/null;"
  cmd="${cmd} echo \"##fio\"; fio --version 2>/dev/null;"
  cmd="${cmd} echo \"##nproc\"; nproc;"
  cmd="${cmd} echo \"##meminfo\"; grep MemTotal /proc/meminfo;"
  cmd="${cmd} echo \"##bootid\"; cat /proc/sys/kernel/random/boot_id;"
  cmd="${cmd} echo \"##uptime\"; cat /proc/uptime;"
  cmd="${cmd} echo \"##timesync\"; timedatectl show -p NTPSynchronized --value;"
  cmd="${cmd} echo \"##end\""
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    _node_sh "$node" "$COLLECT_CMD_TIMEOUT" "$cmd" > "${scratch}/${node}.txt" \
      || die "env_snapshot_provision：${node} 取不到環境資訊（前置狀態不成立）"
  done <<< "$(inv_names)"
  mkdir -p "$out"
  n="$(_collect_py env-provision "$scratch" "${out}/env-provision.json")" \
    || die "env-provision snapshot 產生失敗"
  printf 'env-snapshot: PASS provision %s\n' "$n"
}

# env_snapshot_cluster [outdir]：ceph versions / crush tree / pool / flags（部署後收）。
env_snapshot_cluster() {
  local out="${1:-$(collect_env_dir)}" scratch
  scratch="$(_collect_scratch)"
  ceph_adm "ceph -s --format json" > "${scratch}/status.json" \
    || die "env_snapshot_cluster：cluster 尚未就緒（ceph -s 失敗），前置狀態不成立"
  ceph_adm "ceph versions --format json" > "${scratch}/versions.json" \
    || die "取不到 ceph versions"
  ceph_adm "ceph osd crush tree --format json" > "${scratch}/crush-tree.json" \
    || die "取不到 crush tree"
  ceph_adm "ceph osd pool ls detail --format json" > "${scratch}/pool-ls-detail.json" \
    || die "取不到 pool ls detail"
  ceph_adm "ceph osd dump --format json" > "${scratch}/osd-dump.json" \
    || die "取不到 osd dump"
  ceph_adm "ceph config dump --format json" > "${scratch}/config-dump.json" \
    || die "取不到 config dump"
  mkdir -p "$out"
  _collect_py env-cluster "$scratch" "${out}/env-cluster.json" >/dev/null \
    || die "env-cluster snapshot 產生失敗"
  printf 'env-snapshot: PASS cluster\n'
}

# env_snapshot_map [outdir]：krbd map options / rbdX 對應 / client scheduler + readahead。
env_snapshot_map() {
  local out="${1:-$(collect_env_dir)}" scratch client cmd n
  scratch="$(_collect_scratch)"
  cmd="echo \"##showmapped\"; sudo rbd showmapped --format json;"
  cmd="${cmd} echo \"##devices\";"
  cmd="${cmd} for d in /sys/block/rbd*; do [ -e \$d ] || continue;"
  cmd="${cmd} echo \"#dev \$(basename \$d)\";"
  cmd="${cmd} cat \$d/queue/scheduler; cat \$d/queue/read_ahead_kb;"
  cmd="${cmd} cat \$d/queue/nr_requests; cat \$d/queue/rotational; done;"
  cmd="${cmd} echo \"##end\""
  while IFS= read -r client; do
    [ -n "$client" ] || continue
    _node_sh "$client" "$COLLECT_CMD_TIMEOUT" "$cmd" > "${scratch}/${client}.txt" \
      || die "env_snapshot_map：${client} 取不到 rbd 對應（前置狀態不成立）"
  done <<< "$(inv_names client)"
  mkdir -p "$out"
  n="$(_collect_py env-map "$scratch" "${out}/env-map.json")" \
    || die "env-map snapshot 產生失敗（image 尚未 map？）"
  printf 'env-snapshot: PASS map %s\n' "$n"
}
