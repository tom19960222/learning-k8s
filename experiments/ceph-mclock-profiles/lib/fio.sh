#!/usr/bin/env bash
# ceph-mclock-profiles — fio datapath（Task 7）。bash 3.2 相容；
# stdout 只放機器要抓的那行，log/progress 一律 stderr。
#
# 對外介面：
#   fio_setup_images                     4 顆 fio-c1..c4（各 300 GiB，--id mclock-fio）
#   fio_map_all [out] / fio_unmap_all    krbd map/unmap；記 /dev/rbdX 對應與 map options
#   fio_device <client>                  由 rbd-map.json 查該 client 的 /dev/rbdX
#   client_tuning_apply|verify|restore   scheduler=none + readahead 固定（原值留存供回退）
#   fio_precondition                     4 client 平行全量寫 → ceph df 驗 usable 20–30%
#   fio_render_job <shape> <mode> <rate> 完整 time-series 契約的 job 檔（stdout）
#   fio_start_bg <bundle> <mode> <shape> <rate>   per-client run-id，走 remote_bg_start
#   fio_readiness_barrier <bundle> [secs]         ramp 完成 + 60s 穩定窗（= 注入前基線）
#   fio_assert_alive <bundle>            每 client heartbeat 新鮮度
#   fio_wait_segments <bundle> <stop-fn> <deadline-epoch>   0 | 124(cap) | 2(fio 失聯)
#   fio_stop <bundle>                    exit code + heartbeat = exit proof，並回收三 log
#   fio_run_steady <bundle> <shape> <rate>            單段 300s
#   fio_run_baseline <bundle> <shape> <pressure> <rate>  60s 復測 → baseline.json
#   fio_calibrate <shape>                balanced + final_clean 下的 rate sweep
#   fio_raw_nvme_baseline <name>         **只准在 OSD 建立前**：OSD node 本機 raw 4K 基線
#   fio_smoke_real <bundle>              60s 真 fio → golden log + parser 校正 gate
#
# 契約（跨 lib）：
#   results/raw-nvme-baseline.json  {"<node>": {"iops": <float>, "bw_bytes": <float>}}
#                                   → lib/ceph.sh ceph_capacity_provenance 消費
#   results/calibration.json        shapes.<shape>.{ceiling_iops, rates, per_job_rates,
#                                   reference_p99_ns} → lib/verdict.py baseline-check 消費
#   <bundle>/fio/<client>/<seg>_{iops,lat,clat_hist}.<job>.log
#   <bundle>/fio-summary.json、<bundle>/baseline.json、<bundle>/fio-exit-proof.json
#                                   → lib/verdict.py aggregate / baseline-check 消費
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR

[ -n "${MCLOCK_FIO_LOADED:-}" ] && return 0
MCLOCK_FIO_LOADED=1

# shellcheck source=./ceph.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ceph.sh"

# --- 常數（plan Global Constraints「fio 常數」+ spec §4）----------------------
FIO_IMAGE_PREFIX="${FIO_IMAGE_PREFIX:-fio-c}"
FIO_IMAGE_SIZE_MIB="${FIO_IMAGE_SIZE_MIB:-307200}"          # 300 GiB
FIO_IMAGE_SIZE_BYTES="${FIO_IMAGE_SIZE_BYTES:-322122547200}"
FIO_RANDSEED="${FIO_RANDSEED:-4242}"
FIO_NUMJOBS_4K="${FIO_NUMJOBS_4K:-4}"
FIO_IODEPTH_4K="${FIO_IODEPTH_4K:-16}"
FIO_NUMJOBS_SEQ="${FIO_NUMJOBS_SEQ:-2}"
FIO_IODEPTH_SEQ="${FIO_IODEPTH_SEQ:-8}"
FIO_RWMIXREAD="${FIO_RWMIXREAD:-70}"
FIO_STEADY_SECS="${FIO_STEADY_SECS:-300}"
FIO_RAMP_SECS="${FIO_RAMP_SECS:-30}"
FIO_BASELINE_SECS="${FIO_BASELINE_SECS:-60}"
FIO_BASELINE_RAMP_SECS="${FIO_BASELINE_RAMP_SECS:-10}"
FIO_CALIB_SECS="${FIO_CALIB_SECS:-120}"
FIO_SMOKE_SECS="${FIO_SMOKE_SECS:-60}"
FIO_SMOKE_RAMP_SECS="${FIO_SMOKE_RAMP_SECS:-5}"
# 注入前健康基線窗（= p99 degradation ratio 的分母，pipeline SoT 與此一致）
FIO_STABLE_WINDOW_SECS="${FIO_STABLE_WINDOW_SECS:-60}"
FIO_STABLE_COV="${FIO_STABLE_COV:-0.10}"
FIO_READINESS_SECS="${FIO_READINESS_SECS:-900}"
FIO_HEARTBEAT_MAX_AGE="${FIO_HEARTBEAT_MAX_AGE:-30}"
FIO_WORKDIR_BASE="${FIO_WORKDIR_BASE:-/var/tmp/mclock-fio}"
FIO_STOP_WAIT_SECS="${FIO_STOP_WAIT_SECS:-120}"
FIO_RUN_SLACK_SECS="${FIO_RUN_SLACK_SECS:-300}"
FIO_PRECOND_SECS="${FIO_PRECOND_SECS:-21600}"
FIO_PRECOND_MIN_PCT="${FIO_PRECOND_MIN_PCT:-20}"
FIO_PRECOND_MAX_PCT="${FIO_PRECOND_MAX_PCT:-30}"
FIO_READAHEAD_KB="${FIO_READAHEAD_KB:-128}"
FIO_SCHEDULER="${FIO_SCHEDULER:-none}"
FIO_MAP_OPTS="${FIO_MAP_OPTS:-}"
FIO_RAW_SECS="${FIO_RAW_SECS:-60}"
FIO_CALIB_ROUNDS="${FIO_CALIB_ROUNDS:-3}"
FIO_CALIB_CLEAN_SECS="${FIO_CALIB_CLEAN_SECS:-600}"
FIO_SMOKE_SHAPE="${FIO_SMOKE_SHAPE:-4k}"
FIO_SMOKE_MIN_SECONDS="${FIO_SMOKE_MIN_SECONDS:-30}"

# results/ 下的契約檔一律「呼叫當下」才解析路徑（入口腳本常在 source 後才定 RESULTS_DIR）
rbd_map_path() { printf '%s\n' "${RBD_MAP_JSON:-$RESULTS_DIR/rbd-map.json}"; }
client_tuning_path() { printf '%s\n' "${CLIENT_TUNING_JSON:-$RESULTS_DIR/client-tuning.json}"; }
calibration_path() { printf '%s\n' "${CALIBRATION_JSON:-$RESULTS_DIR/calibration.json}"; }
fio_golden_dir() { printf '%s\n' "${FIO_GOLDEN_DIR:-$RESULTS_DIR/golden/fio-smoke}"; }

_FIO_PY_SRC="$(cat <<'PY'
"""lib/fio.sh 的 JSON / 數值判讀（Task 7）。

家規：bash 保持薄，JSON 判斷集中在 python；**stdout 只放機器行**，log 一律 stderr。
本檔只被 lib/fio.sh 以 `python3 lib/fio-py.py <subcmd> ...` 呼叫。
"""

import json
import os
import statistics
import sys


def emit(line):
    sys.stdout.write("%s\n" % line)


def log(msg):
    sys.stderr.write("[fio] %s\n" % msg)


def die(msg, code=1):
    sys.stderr.write("[fio] FATAL: %s\n" % msg)
    raise SystemExit(code)


def read_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def write_json(path, doc):
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(doc, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.rename(tmp, path)


def read_tsv(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            rows.append(line.split("\t"))
    return rows


# ------------------------------------------------------------------ rbd image --

def cmd_image_size(argv):
    """stdin = `rbd info --format json`；驗證 image 大小恰為預期位元組數。"""
    want = int(argv[0])
    doc = json.load(sys.stdin)
    got = int(doc.get("size") or 0)
    if got != want:
        die("image 大小 %d bytes，期望 %d（300 GiB 是 20–30%% 填充率的前提）"
            % (got, want))
    emit(str(got))
    return 0


def cmd_devlist_device(argv):
    """stdin = `rbd device list --format json`；印出該 image 的 /dev/rbdX（沒有就印空）。"""
    image = argv[0]
    try:
        doc = json.load(sys.stdin)
    except ValueError:
        doc = []
    if isinstance(doc, dict):
        doc = doc.get("devices") or []
    for row in doc or []:
        if not isinstance(row, dict):
            continue
        if row.get("name") == image or row.get("image") == image:
            dev = row.get("device") or ""
            if dev:
                emit(dev)
                return 0
    return 0


def cmd_map_record(argv):
    """tsv：client / image / device / map_options / devlist-json 路徑。"""
    tsv, out = argv[0], argv[1]
    clients = {}
    for row in read_tsv(tsv):
        name, image, device, opts, devlist = (row + ["", "", "", "", ""])[:5]
        clients[name] = {
            "image": image,
            "device": device,
            "map_options": opts,
            "device_list": read_json(devlist, []),
        }
    write_json(out, {"schema_version": 1, "pool": os.environ.get("CEPH_POOL", ""),
                     "clients": clients})
    emit(str(len(clients)))
    return 0


# --------------------------------------------------------------- client tuning --

def cmd_tuning_record(argv):
    """tsv：client / device / 原 scheduler / 原 read_ahead_kb。"""
    tsv, out = argv[0], argv[1]
    applied_sched = argv[2]
    applied_ra = argv[3]
    clients = {}
    for row in read_tsv(tsv):
        name, device, sched, ra = (row + ["", "", "", ""])[:4]
        clients[name] = {
            "device": device,
            "original_scheduler": sched,
            "original_read_ahead_kb": ra,
            "applied_scheduler": applied_sched,
            "applied_read_ahead_kb": applied_ra,
        }
    write_json(out, {"schema_version": 1, "clients": clients})
    emit(str(len(clients)))
    return 0


def cmd_tuning_values(argv):
    doc = read_json(argv[0])
    if not doc:
        die("client-tuning.json 讀不到：%s" % argv[0])
    for name in sorted((doc.get("clients") or {})):
        row = doc["clients"][name]
        sys.stdout.write("%s\t%s\t%s\t%s\n" % (
            name, row.get("device", ""), row.get("original_scheduler", ""),
            row.get("original_read_ahead_kb", "")))
    return 0


# -------------------------------------------------------------------- readiness --

def _iops_by_sec(path):
    secs = {}
    try:
        fh = open(path)
    except OSError:
        return secs
    with fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 3:
                continue
            try:
                sec = int(float(parts[0])) // 1000
                val = float(parts[1])
            except ValueError:
                continue
            secs[sec] = secs.get(sec, 0.0) + val
    return secs


def cmd_readiness(argv):
    """ramp 完成 + <window>s 吞吐穩定窗；此窗即注入前健康基線（p99 ratio 的分母）。"""
    window = int(argv[0])
    cov_limit = float(argv[1])
    out = argv[2]
    per_client = {}
    for spec in argv[3:]:
        name, _, path = spec.partition("=")
        per_client[name] = _iops_by_sec(path)
    if not per_client:
        die("readiness：沒有指定任何 client 的 iops log")

    common = None
    for secs in per_client.values():
        keys = set(secs)
        common = keys if common is None else (common & keys)
    if not common:
        log("readiness PENDING：還沒有所有 client 都涵蓋的秒（ramp 未完成？）")
        return 1

    # 捨棄最後一秒：仍在跑的 fio 可能只寫了半行／半個窗，計入會虛增 CoV
    end = max(common) - 1
    start = end - window + 1
    if start < min(common):
        log("readiness PENDING：穩定窗樣本不足（要 %ds，實得 %ds）"
            % (window, len(common) - 1))
        return 1
    agg = []
    for sec in range(start, end + 1):
        if sec not in common:
            log("readiness PENDING：穩定窗內第 %d 秒不是全 client 覆蓋" % sec)
            return 1
        agg.append(sum(secs[sec] for secs in per_client.values()))

    mean = statistics.mean(agg)
    if mean <= 0:
        log("readiness PENDING：穩定窗平均吞吐為 0")
        return 1
    cov = (statistics.pstdev(agg) / mean) if len(agg) > 1 else 0.0
    if cov > cov_limit:
        log("readiness PENDING：吞吐未穩定（CoV %.3f > %.3f）" % (cov, cov_limit))
        return 1

    doc = {
        "schema_version": 1,
        "window": {"start": start, "end": end},
        "stable_seconds": window,
        "cov": cov,
        "cov_limit": cov_limit,
        "mean_iops": mean,
        "clients": dict(
            (name, {"mean_iops": statistics.mean(
                [secs[s] for s in range(start, end + 1)]),
                "samples": len(secs)})
            for name, secs in per_client.items()),
    }
    write_json(out, doc)
    emit("fio-readiness: PASS %d %d %.4f" % (start, end, cov))
    return 0


# ---------------------------------------------------------------------- summary --

def _percentile_ns(direction):
    clat = direction.get("clat_ns")
    if isinstance(clat, dict):
        pct = clat.get("percentile") or {}
        scale = 1.0
    else:
        clat = direction.get("clat") or {}
        pct = clat.get("percentile") or {}
        scale = 1000.0
    out = {}
    for key, want in (("50.000000", "p50_ns"), ("99.000000", "p99_ns"),
                      ("99.900000", "p999_ns")):
        if key in pct:
            out[want] = float(pct[key]) * scale
    return out


def cmd_summary(argv):
    out, shape, mode, rate = argv[0], argv[1], argv[2], argv[3]
    files = argv[4:]
    if not files:
        die("summary：沒有任何 fio JSON（fio 可能根本沒跑起來）")
    clients = {}
    read_iops = write_iops = bw = 0.0
    p99 = p50 = p999 = None
    duration = 0
    for path in files:
        doc = read_json(path)
        if doc is None:
            die("summary：fio JSON 無法解析：%s" % path)
        client = os.path.basename(os.path.dirname(path))
        slot = clients.setdefault(client, {"read_iops": 0.0, "write_iops": 0.0,
                                           "bw_bytes_per_sec": 0.0, "segments": 0})
        slot["segments"] += 1
        for job in doc.get("jobs") or []:
            duration = max(duration, int(job.get("job_runtime") or 0))
            for name in ("read", "write"):
                d = job.get(name) or {}
                iops = float(d.get("iops") or 0.0)
                if iops <= 0:
                    continue
                slot["%s_iops" % name] += iops
                slot["bw_bytes_per_sec"] += float(d.get("bw_bytes") or 0.0)
                if name == "read":
                    read_iops += iops
                else:
                    write_iops += iops
                bw += float(d.get("bw_bytes") or 0.0)
                pcts = _percentile_ns(d)
                if "p99_ns" in pcts:
                    p99 = pcts["p99_ns"] if p99 is None else max(p99, pcts["p99_ns"])
                if "p50_ns" in pcts:
                    p50 = pcts["p50_ns"] if p50 is None else max(p50, pcts["p50_ns"])
                if "p999_ns" in pcts:
                    p999 = pcts["p999_ns"] if p999 is None else max(p999, pcts["p999_ns"])

    doc = {
        "schema_version": 1,
        "shape": shape,
        "mode": mode,
        "target_iops": (None if int(rate) == 0 else int(rate)),
        "closed_loop": int(rate) == 0,
        "achieved_iops": read_iops + write_iops,
        "read_iops": read_iops,
        "write_iops": write_iops,
        "bw_bytes_per_sec": bw,
        "p50_ns": p50,
        "p99_ns": p99,
        "p999_ns": p999,
        "duration_s": duration / 1000.0 if duration else None,
        "segments": sum(c["segments"] for c in clients.values()),
        "clients": clients,
    }
    write_json(out, doc)
    emit("%s" % (read_iops + write_iops))
    return 0


def cmd_summary_get(argv):
    doc = read_json(argv[0])
    if doc is None:
        die("讀不到 summary：%s" % argv[0])
    emit("%s" % doc.get(argv[1]))
    return 0


def cmd_baseline_record(argv):
    out, shape, pressure, rate, summary = argv[:5]
    doc = read_json(summary)
    if doc is None:
        die("baseline-record：讀不到 summary：%s" % summary)
    write_json(out, {
        "schema_version": 1,
        "shape": shape,
        "pressure": pressure,
        "target_iops": (None if int(rate) == 0 else int(rate)),
        "achieved_iops": doc.get("achieved_iops"),
        "p99_ns": doc.get("p99_ns"),
        "p50_ns": doc.get("p50_ns"),
        "duration_s": doc.get("duration_s"),
    })
    emit("%s" % doc.get("achieved_iops"))
    return 0


# -------------------------------------------------------------------- calibrate --

PRESSURE_FRACTION = (("low", 0.25), ("mid", 0.50), ("high", 0.80))


def cmd_calib_rates(argv):
    """三輪不限速 achieved → 中位為 ceiling；反推 25/50/80% 的 aggregate 速率。"""
    values = [float(v) for v in argv[0].split(",") if v.strip() != ""]
    if len(values) < 3:
        die("calib-rates：需要 3 輪 ceiling 觀測（實得 %d）" % len(values))
    ceiling = int(round(statistics.median(values)))
    rates = [str(int(round(ceiling * frac))) for _, frac in PRESSURE_FRACTION]
    emit("%d %s" % (ceiling, " ".join(rates)))
    return 0


def cmd_calib_record(argv):
    out, shape, divisor, ceiling = argv[0], argv[1], int(argv[2]), int(argv[3])
    low, mid, high = int(argv[4]), int(argv[5]), int(argv[6])
    refs = {}
    for item in argv[7].split(","):
        if not item.strip():
            continue
        key, _, val = item.partition("=")
        try:
            refs[key] = float(val)
        except ValueError:
            refs[key] = None
    doc = read_json(out) or {}
    doc.setdefault("schema_version", 1)
    shapes = doc.setdefault("shapes", {})
    rates = {"low": low, "mid": mid, "high": high}
    for name, value in rates.items():
        if value == ceiling:
            die("calib-record：%s 壓的固定速率等於 ceiling（baseline-check 會恆超標）"
                % name)
    shapes[shape] = {
        "ceiling_iops": ceiling,
        "ceiling_rounds": [float(v) for v in argv[8].split(",") if v.strip() != ""],
        "rates": rates,
        "per_job_rates": dict(
            (name, max(1, int(value // divisor))) for name, value in rates.items()),
        "reference_p99_ns": refs,
        "divisor": divisor,
    }
    write_json(out, doc)
    emit("%d" % ceiling)
    return 0


# ------------------------------------------------------------------ ceph df 驗算 --

def cmd_df_check(argv):
    pool, lo, hi = argv[0], float(argv[1]), float(argv[2])
    doc = json.load(sys.stdin)
    entry = None
    for row in doc.get("pools") or []:
        if row.get("name") == pool:
            entry = row
            break
    if entry is None:
        die("ceph df 找不到 pool %s" % pool)
    stats = entry.get("stats") or {}
    stored = float(stats.get("stored") or 0.0)
    avail = float(stats.get("max_avail") or 0.0)
    usable = stored + avail
    if usable <= 0:
        die("ceph df：usable 容量為 0（stored=%s max_avail=%s）" % (stored, avail))
    pct = 100.0 * stored / usable
    if pct < lo or pct > hi:
        die("填充率 %.2f%% 不在 %.0f–%.0f%% 之間（backfill footprint 會改變）"
            % (pct, lo, hi))
    emit("%.2f" % pct)
    return 0


# ------------------------------------------------------------- raw NVMe 基線 --

def cmd_raw_record(argv):
    """契約（lib/ceph.sh ceph_capacity_provenance 消費）：{"<node>": {"iops": float}}。"""
    out, node, path = argv[0], argv[1], argv[2]
    doc = read_json(path)
    if doc is None:
        die("raw-record：fio JSON 無法解析：%s" % path)
    iops = 0.0
    bw = 0.0
    for job in doc.get("jobs") or []:
        d = job.get("write") or {}
        iops += float(d.get("iops") or 0.0)
        bw += float(d.get("bw_bytes") or 0.0)
    if iops <= 0:
        die("raw-record：%s 的 4K randwrite IOPS 為 0（fio 沒真的跑）" % node)
    acc = read_json(out) or {}
    acc[node] = {"iops": iops, "bw_bytes": bw}
    write_json(out, acc)
    emit("%s" % iops)
    return 0


# -------------------------------------------------------------------- exit proof --

def cmd_exit_proof(argv):
    """tsv：client / exit-code / heartbeat epoch / now epoch / segment 數。"""
    tsv, out, mode = argv[0], argv[1], argv[2]
    clients = {}
    failed = []
    for row in read_tsv(tsv):
        name, code, hb, now, segs = (row + ["", "", "", "", ""])[:5]
        try:
            age = int(now) - int(hb)
        except ValueError:
            age = None
        try:
            rc = int(code)
        except ValueError:
            rc = None
        clients[name] = {
            "exit_code": rc,
            "exit_raw": code,
            "heartbeat_epoch": int(hb) if hb.isdigit() else None,
            "heartbeat_age_s": age,
            "segments": int(segs) if segs.isdigit() else None,
        }
        if rc != 0:
            failed.append(name)
    write_json(out, {"schema_version": 1, "mode": mode, "clients": clients,
                     "failed": failed, "all_ok": not failed})
    emit("%d" % len(failed))
    return 0


COMMANDS = {
    "image-size": cmd_image_size,
    "devlist-device": cmd_devlist_device,
    "map-record": cmd_map_record,
    "tuning-record": cmd_tuning_record,
    "tuning-values": cmd_tuning_values,
    "readiness": cmd_readiness,
    "summary": cmd_summary,
    "summary-get": cmd_summary_get,
    "baseline-record": cmd_baseline_record,
    "calib-rates": cmd_calib_rates,
    "calib-record": cmd_calib_record,
    "df-check": cmd_df_check,
    "raw-record": cmd_raw_record,
    "exit-proof": cmd_exit_proof,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        die("未知的子命令：%s（可用：%s）"
            % (argv[0] if argv else "", ", ".join(sorted(COMMANDS))), code=2)
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
)"
_fio_py() { python3 -c "$_FIO_PY_SRC" "$@"; }

# --- 遠端執行 helper ----------------------------------------------------------

# _fio_run_script <node> <secs> <tag> <script>
#   腳本以 base64 過線（免多層引號地獄），遠端包 coreutils timeout。
#   `: mclock-<tag>-<node>;` 是給人/測試看的指令指紋——每支遠端呼叫都能被唯一辨識。
_fio_run_script() {
  [ $# -eq 4 ] || die "用法：_fio_run_script <node> <secs> <tag> <script>"
  local node="$1" secs="$2" tag="$3" b64
  case "$secs" in ''|*[!0-9]*) die "_fio_run_script：secs 必須是整數秒（got=${secs}）" ;; esac
  b64="$(printf '%s' "$4" | base64 | tr -d '\n')"
  node_ssh "$node" \
    ": mclock-${tag}-${node}; printf %s '${b64}' | base64 --decode | timeout ${secs} sudo bash"
}

_fio_clients() { inv_names client; }

_fio_nclients() { _fio_clients | wc -l | tr -d ' '; }

_fio_rbd() { printf 'rbd -p %s --id %s' "$CEPH_POOL" "$CEPH_CLIENT_ID"; }

_fio_scratch() { _ceph_scratch; }

# _fio_image_for <client-index>
_fio_image_for() { printf '%s%s\n' "$FIO_IMAGE_PREFIX" "$1"; }

# --- 1) RBD image ------------------------------------------------------------

fio_setup_images() {
  local idx=1 c img rbd_c out n=0
  rbd_c="$(_fio_rbd)"
  for c in $(_fio_clients); do
    img="$(_fio_image_for "$idx")"
    out="$(_fio_run_script "$c" 120 imgcheck "${rbd_c} ls")" \
      || die "rbd ls 失敗：${c}"
    if printf '%s\n' "$out" | grep -qx -- "$img"; then
      log "image ${img} 已存在（${c}），跳過建立"
    else
      _fio_run_script "$c" 900 imgcreate \
        "${rbd_c} create ${img} --size ${FIO_IMAGE_SIZE_MIB}" >&2 \
        || die "image 建立失敗：${img}（${c}）"
    fi
    _fio_run_script "$c" 120 imginfo "${rbd_c} info ${img} --format json" \
      | _fio_py image-size "$FIO_IMAGE_SIZE_BYTES" >/dev/null \
      || die "image ${img} 大小驗證失敗（${c}）"
    idx=$((idx + 1))
    n=$((n + 1))
  done
  printf 'fio-images: PASS %s\n' "$n"
}

# --- 2) krbd map / unmap -----------------------------------------------------

fio_map_all() { # [outfile]
  local out="${1:-$(rbd_map_path)}" idx=1 c img rbd_c dev dl tsv n=0 mapcmd
  rbd_c="$(_fio_rbd)"
  tsv="$(_fio_scratch)/map.tsv"
  : > "$tsv"
  for c in $(_fio_clients); do
    img="$(_fio_image_for "$idx")"
    dl="$(_fio_scratch)/devlist.${c}.json"
    _fio_run_script "$c" 120 maplist "${rbd_c} device list --format json" > "$dl" \
      || die "rbd device list 失敗：${c}"
    dev="$(_fio_py devlist-device "$img" < "$dl")"
    if [ -z "$dev" ]; then
      mapcmd="${rbd_c} map ${img}"
      [ -n "$FIO_MAP_OPTS" ] && mapcmd="${mapcmd} -o ${FIO_MAP_OPTS}"
      dev="$(_fio_run_script "$c" 300 map "$mapcmd" | tr -d ' \r' | tail -1)" \
        || die "rbd map 失敗：${img}（${c}）"
      [ -n "$dev" ] || die "rbd map 沒有回傳裝置路徑：${c}"
      _fio_run_script "$c" 120 maplist2 "${rbd_c} device list --format json" > "$dl" \
        || die "map 後 rbd device list 失敗：${c}"
      [ "$(_fio_py devlist-device "$img" < "$dl")" = "$dev" ] \
        || die "map 後 device list 與 map 回傳的裝置不一致：${c}"
    else
      log "image ${img} 已 map 在 ${dev}（${c}），跳過"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$c" "$img" "$dev" "$FIO_MAP_OPTS" "$dl" >> "$tsv"
    idx=$((idx + 1))
    n=$((n + 1))
  done
  CEPH_POOL="$CEPH_POOL" _fio_py map-record "$tsv" "$out" >/dev/null \
    || die "rbd-map.json 寫入失敗"
  cut -f1-3 "$tsv" > "$(_rbd_map_tsv)" || die "rbd map 查表寫入失敗"
  printf 'fio-map: PASS %s\n' "$n"
}

fio_unmap_all() {
  local idx=1 c img rbd_c dev dl n=0
  rbd_c="$(_fio_rbd)"
  for c in $(_fio_clients); do
    img="$(_fio_image_for "$idx")"
    dl="$(_fio_scratch)/devlist-unmap.${c}.json"
    _fio_run_script "$c" 120 maplist "${rbd_c} device list --format json" > "$dl" \
      || die "rbd device list 失敗：${c}"
    dev="$(_fio_py devlist-device "$img" < "$dl")"
    if [ -n "$dev" ]; then
      _fio_run_script "$c" 300 unmap "${rbd_c} device unmap ${img}" >&2 \
        || die "rbd unmap 失敗：${img}（${c}）"
      n=$((n + 1))
    fi
    idx=$((idx + 1))
  done
  printf 'fio-unmap: PASS %s\n' "$n"
}

# rbd-map.json 是證據檔（進 env snapshot）；同名 .tsv 是 bash 端的快取查表——
# 每次查裝置都起一顆 python3 會讓 campaign 期間的 ssh 迴圈變得非常慢。
_rbd_map_tsv() { local p; p="$(rbd_map_path)"; printf '%s\n' "${p%.json}.tsv"; }

fio_device() { # <client>
  [ $# -eq 1 ] || die "用法：fio_device <client>"
  local f dev
  f="$(_rbd_map_tsv)"
  [ -s "$f" ] || die "rbd map 記錄不存在（先跑 fio_map_all）：${f}"
  dev="$(awk -F'\t' -v c="$1" '$1 == c {print $3}' "$f")"
  [ -n "$dev" ] || die "rbd map 記錄查不到 ${1} 的裝置"
  printf '%s\n' "$dev"
}

_fio_blk() { # <client> → rbd0
  basename "$(fio_device "$1")"
}

# --- 3) client tuning（round2/F20）--------------------------------------------

client_tuning_apply() {
  local c blk out sched ra tsv n=0
  tsv="$(_fio_scratch)/tuning.tsv"
  : > "$tsv"
  for c in $(_fio_clients); do
    blk="$(_fio_blk "$c")"
    out="$(_fio_run_script "$c" 60 tune "$(cat <<EOF
set -u
cat /sys/block/${blk}/queue/scheduler
cat /sys/block/${blk}/queue/read_ahead_kb
echo ${FIO_SCHEDULER} > /sys/block/${blk}/queue/scheduler
echo ${FIO_READAHEAD_KB} > /sys/block/${blk}/queue/read_ahead_kb
echo tuned
EOF
)")" || die "client tuning 套用失敗：${c}"
    printf '%s\n' "$out" | tail -1 | grep -qx tuned || die "client tuning 未回報成功：${c}"
    sched="$(printf '%s\n' "$out" | sed -n '1s/.*\[\([^]]*\)\].*/\1/p')"
    ra="$(printf '%s\n' "$out" | sed -n '2p' | tr -d ' \r')"
    [ -n "$sched" ] || die "讀不到 ${c} 的原 scheduler"
    [ -n "$ra" ] || die "讀不到 ${c} 的原 read_ahead_kb"
    printf '%s\t%s\t%s\t%s\n' "$c" "/dev/${blk}" "$sched" "$ra" >> "$tsv"
    n=$((n + 1))
  done
  _fio_py tuning-record "$tsv" "$(client_tuning_path)" \
    "$FIO_SCHEDULER" "$FIO_READAHEAD_KB" >/dev/null \
    || die "client-tuning.json 寫入失敗"
  printf 'client-tuning: PASS %s\n' "$n"
}

client_tuning_verify() {
  local c blk out sched ra n=0
  for c in $(_fio_clients); do
    blk="$(_fio_blk "$c")"
    out="$(_fio_run_script "$c" 60 tuneverify "$(cat <<EOF
set -u
cat /sys/block/${blk}/queue/scheduler
cat /sys/block/${blk}/queue/read_ahead_kb
EOF
)")" || die "client tuning 回讀失敗：${c}"
    sched="$(printf '%s\n' "$out" | sed -n '1s/.*\[\([^]]*\)\].*/\1/p')"
    ra="$(printf '%s\n' "$out" | sed -n '2p' | tr -d ' \r')"
    [ "$sched" = "$FIO_SCHEDULER" ] \
      || die "${c} 的 scheduler 是 ${sched}，期望 ${FIO_SCHEDULER}"
    [ "$ra" = "$FIO_READAHEAD_KB" ] \
      || die "${c} 的 read_ahead_kb 是 ${ra}，期望 ${FIO_READAHEAD_KB}"
    n=$((n + 1))
  done
  printf 'client-tuning-verify: PASS %s\n' "$n"
}

client_tuning_restore() {
  local f rows c dev sched ra blk n=0
  f="$(client_tuning_path)"
  [ -s "$f" ] || { log "client-tuning.json 不存在，無法還原：${f}"; return 1; }
  rows="$(_fio_py tuning-values "$f")" || die "讀不到 client-tuning.json"
  while IFS=$'\t' read -r c dev sched ra; do
    [ -n "$c" ] || continue
    blk="$(basename "$dev")"
    _fio_run_script "$c" 60 tunerestore "$(cat <<EOF
set -u
echo ${sched} > /sys/block/${blk}/queue/scheduler
echo ${ra} > /sys/block/${blk}/queue/read_ahead_kb
echo restored
EOF
)" >&2 || log "client tuning 還原失敗（續行）：${c}"
    n=$((n + 1))
  done <<< "$rows"
  printf 'client-tuning-restore: PASS %s\n' "$n"
}

# --- 4) job 檔 ---------------------------------------------------------------

# fio_render_job <shape> <mode> <rate>
#   <rate> = **aggregate** 目標 IOPS（0 = 不限速的閉迴路極端壓）；
#   per-job rate 由 aggregate / (numjobs × client 數) 反推，randrw 再依 70/30 拆分。
#   __DEVICE__ / __SEGPREFIX__ 由遠端 runner 逐 segment 代換。
fio_render_job() {
  [ $# -eq 3 ] || die "用法：fio_render_job <shape> <mode> <rate>"
  local shape="$1" mode="$2" rate="$3"
  local rw bs iodepth numjobs runtime ramp jobname perjob rd wr nclients
  case "$rate" in ''|*[!0-9]*) die "fio_render_job：rate 必須是整數 IOPS（got=${rate}）" ;; esac
  case "$shape" in
    4k)  rw=randrw; bs=4k; iodepth="$FIO_IODEPTH_4K"; numjobs="$FIO_NUMJOBS_4K"
         jobname=mclock-4k ;;
    seq) rw="write"; bs=1M; iodepth="$FIO_IODEPTH_SEQ"; numjobs="$FIO_NUMJOBS_SEQ"
         jobname=mclock-seq ;;
    *) die "未知 shape：${shape}（可用 4k / seq）" ;;
  esac

  if [ "$mode" = "precondition" ]; then
    # 全量寫（一次寫滿整顆 image），之後只 overwrite；不需要逐秒 log
    cat <<EOF
# mclock fio job — precondition（一次寫滿整顆 image，不是計時型）
[global]
ioengine=libaio
direct=1
randseed=${FIO_RANDSEED}
group_reporting=1

[mclock-precondition]
filename=__DEVICE__
rw=write
bs=4M
iodepth=32
numjobs=1
loops=1
EOF
    return 0
  fi

  case "$mode" in
    steady|segment) runtime="$FIO_STEADY_SECS"; ramp="$FIO_RAMP_SECS" ;;
    baseline)       runtime="$FIO_BASELINE_SECS"; ramp="$FIO_BASELINE_RAMP_SECS" ;;
    calib)          runtime="$FIO_CALIB_SECS"; ramp="$FIO_RAMP_SECS" ;;
    smoke)          runtime="$FIO_SMOKE_SECS"; ramp="$FIO_SMOKE_RAMP_SECS" ;;
    *) die "未知 mode：${mode}（可用 steady/segment/baseline/calib/smoke/precondition）" ;;
  esac

  nclients="$(_fio_nclients)"
  [ "$nclients" -gt 0 ] || die "inventory 沒有 client node"
  cat <<EOF
# mclock fio job — shape=${shape} mode=${mode} aggregate_rate=${rate}
[global]
ioengine=libaio
direct=1
randseed=${FIO_RANDSEED}
group_reporting=1
time_based=1
runtime=${runtime}
ramp_time=${ramp}
log_avg_msec=1000
log_hist_msec=1000
log_hist_coarseness=0
log_unix_epoch=1
per_job_logs=1
write_iops_log=__SEGPREFIX__
write_lat_log=__SEGPREFIX__
write_hist_log=__SEGPREFIX__
filename=__DEVICE__

[${jobname}]
rw=${rw}
bs=${bs}
iodepth=${iodepth}
numjobs=${numjobs}
EOF
  [ "$shape" = "4k" ] && printf 'rwmixread=%s\n' "$FIO_RWMIXREAD"
  if [ "$rate" -gt 0 ]; then
    perjob=$((rate / (numjobs * nclients)))
    [ "$perjob" -ge 1 ] || perjob=1
    if [ "$shape" = "4k" ]; then
      rd=$((perjob * FIO_RWMIXREAD / 100))
      [ "$rd" -ge 1 ] || rd=1
      wr=$((perjob - rd))
      [ "$wr" -ge 1 ] || wr=1
      printf 'rate_iops=%s,%s\n' "$rd" "$wr"
    else
      printf 'rate_iops=%s\n' "$perjob"
    fi
  else
    printf '# aggregate_rate=0 → 極端壓走閉迴路（過飽和），刻意不限速\n'
  fi
  return 0
}

# --- 5) 背景 fio -------------------------------------------------------------

# _fio_runid <bundle> <mode> <client>
#   replicate bundle（results/<cell>/<rN>/attempts/<ts>）→ `fio-<cell>-<rN>-<ts>-<client>`，
#   與 lib/collect.sh 的 `collect_fio_run_id` 逐字一致：coverage supervisor 靠這個
#   run-id 找 heartbeat，且 registry 條目在 replicate 之間不會互撞（reconcile 才分得清）。
#   校準／precondition 這類非 replicate 的 scratch bundle 退回 `fio-<mode>-<client>`。
_fio_runid() {
  local dir="${1%/}" mode="$2" client="$3" ts rep cell
  case "$dir" in
    */attempts/*)
      ts="$(basename "$dir")"
      rep="$(basename "$(dirname "$(dirname "$dir")")")"
      cell="$(basename "$(dirname "$(dirname "$(dirname "$dir")")")")"
      printf 'fio-%s-%s-%s-%s\n' "$cell" "$rep" "$ts" "$client"
      ;;
    *) printf 'fio-%s-%s\n' "$mode" "$client" ;;
  esac
}
_fio_workdir() { printf '%s/%s\n' "$FIO_WORKDIR_BASE" "$(_fio_runid "$1" "$2" "$3")"; }

# 遠端 runner：背景跑 segment（mode=segment 時 back-to-back 直到 STOP），
# 逐秒 heartbeat 落檔（= exit proof 與 coverage supervisor 的依據）。
_fio_runner_script() { # <workdir> <job-b64> <device> <loop 0|1>
  cat <<EOF
set -u
D=$1
mkdir -p "\$D"
rm -f "\$D"/STOP "\$D"/exit-code "\$D"/heartbeat
printf %s '$2' | base64 --decode > "\$D/job.tmpl"
( while :; do date +%s > "\$D/heartbeat.tmp" && mv "\$D/heartbeat.tmp" "\$D/heartbeat"; sleep 5; done ) &
HB=\$!
trap 'kill \$HB 2>/dev/null' EXIT
date +%s > "\$D/heartbeat"
i=1
rc=0
while :; do
  seg=\$(printf 'seg%02d' "\$i")
  sed -e "s|__SEGPREFIX__|\$D/\$seg|g" -e "s|__DEVICE__|$3|g" "\$D/job.tmpl" > "\$D/\$seg.fio"
  fio --output-format=json --output="\$D/\$seg.json" "\$D/\$seg.fio"
  rc=\$?
  echo "\$rc" > "\$D/exit-code.\$seg"
  [ "\$rc" -eq 0 ] || break
  [ "$4" = "1" ] || break
  [ -e "\$D/STOP" ] && break
  i=\$((i + 1))
done
echo "\$rc" > "\$D/exit-code.tmp" && mv "\$D/exit-code.tmp" "\$D/exit-code"
kill \$HB 2>/dev/null || true
EOF
}

fio_start_bg() { # <bundle> <mode> <shape> <rate>
  [ $# -eq 4 ] || die "用法：fio_start_bg <bundle> <mode> <shape> <rate>"
  local bundle="$1" mode="$2" shape="$3" rate="$4"
  local job jb64 loop c runid wd dev tsv n=0
  [ -d "$bundle" ] || die "bundle 不存在：${bundle}"
  job="$(fio_render_job "$shape" "$mode" "$rate")" || die "job render 失敗"
  jb64="$(printf '%s\n' "$job" | base64 | tr -d '\n')"
  loop=0
  [ "$mode" = "segment" ] && loop=1
  mkdir -p "$bundle/fio"
  tsv="$(_fio_scratch)/run.tsv"
  : > "$tsv"
  for c in $(_fio_clients); do
    runid="$(_fio_runid "$bundle" "$mode" "$c")"
    wd="$(_fio_workdir "$bundle" "$mode" "$c")"
    dev="$(fio_device "$c")"
    remote_bg_start "$c" "$runid" \
      "$(_fio_runner_script "$wd" "$jb64" "$dev" "$loop")" >/dev/null \
      || die "fio 背景啟動失敗：${c}"
    printf '%s\t%s\t%s\n' "$c" "$runid" "$wd" >> "$tsv"
    n=$((n + 1))
  done
  # run.json = 證據檔；run.tsv / run.meta = bash 端查表（避免每次查欄位都起 python3）
  cp "$tsv" "$bundle/fio/run.tsv" || die "run.tsv 寫入失敗"
  printf 'mode=%s\nshape=%s\nrate=%s\n' "$mode" "$shape" "$rate" > "$bundle/fio/run.meta"
  python3 -c 'import json,os,sys,time
tsv, out, mode, shape, rate = sys.argv[1:6]
runids, wds = {}, {}
for line in open(tsv):
    line = line.rstrip("\n")
    if not line:
        continue
    client, runid, wd = line.split("\t")
    runids[client] = runid
    wds[client] = wd
doc = {"schema_version": 1, "mode": mode, "shape": shape,
       "target_iops": (None if int(rate) == 0 else int(rate)),
       "runids": runids, "workdirs": wds, "started_at": int(time.time())}
tmp = out + ".tmp"
with open(tmp, "w") as fh:
    json.dump(doc, fh, indent=1, sort_keys=True)
    fh.write("\n")
os.rename(tmp, out)' "$tsv" "$bundle/fio/run.json" "$mode" "$shape" "$rate" \
    || die "run.json 寫入失敗"
  printf 'fio-start: PASS %s\n' "$n"
}

_fio_workdir_of() { # <bundle> <client>
  awk -F'\t' -v c="$2" '$1 == c {print $3}' "$1/fio/run.tsv"
}

_fio_runid_of() { # <bundle> <client>
  awk -F'\t' -v c="$2" '$1 == c {print $2}' "$1/fio/run.tsv"
}

_fio_mode_of() { # <bundle>
  sed -n 's/^mode=//p' "$1/fio/run.meta"
}

_fio_require_run() { # <bundle>
  [ -s "$1/fio/run.json" ] || die "找不到 ${1}/fio/run.json（fio 還沒啟動？）"
  [ -s "$1/fio/run.tsv" ] || die "找不到 ${1}/fio/run.tsv（fio 還沒啟動？）"
}

# --- 6) readiness barrier ----------------------------------------------------

_fio_readiness_once() {
  local bundle="$_FIO_RB_BUNDLE" c wd f args
  args=""
  for c in $(_fio_clients); do
    wd="$(_fio_workdir_of "$bundle" "$c")"
    [ -n "$wd" ] || return 1
    f="$(_fio_scratch)/readlog.${c}.log"
    _fio_run_script "$c" 60 readlogs "cat ${wd}/*_iops.*.log 2>/dev/null" > "$f" \
      || return 1
    args="${args} ${c}=${f}"
  done
  # shellcheck disable=SC2086
  # args 是刻意要做 word splitting 的 `client=path` 清單（bash 3.2 沒有 nameref）
  _fio_py readiness "$FIO_STABLE_WINDOW_SECS" "$FIO_STABLE_COV" \
    "$bundle/readiness.json" $args
}

# fio_readiness_barrier <bundle> [secs]
#   ramp 完成 + 60s throughput 穩定窗；此窗即 within-replicate 的注入前健康基線
#   （primary endpoint「p99 degradation ratio」的分母）。
fio_readiness_barrier() {
  [ $# -ge 1 ] || die "用法：fio_readiness_barrier <bundle> [secs]"
  local bundle="$1" secs="${2:-$FIO_READINESS_SECS}" rc=0
  _fio_require_run "$bundle"
  _FIO_RB_BUNDLE="$bundle"
  with_deadline "$secs" _fio_readiness_once || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "readiness barrier 未在 ${secs}s 內達成（ramp / 穩定窗）"
    return 1
  fi
  return 0
}

# --- 7) heartbeat / segment 等待 ---------------------------------------------

fio_assert_alive() { # <bundle>
  [ $# -eq 1 ] || die "用法：fio_assert_alive <bundle>"
  local bundle="$1" c wd out hb now age n=0
  _fio_require_run "$bundle"
  for c in $(_fio_clients); do
    wd="$(_fio_workdir_of "$bundle" "$c")"
    out="$(_fio_run_script "$c" 30 hb "$(cat <<EOF
set -u
if [ -s ${wd}/heartbeat ]; then echo "HB \$(cat ${wd}/heartbeat)"; else echo "HB -"; fi
echo "NOW \$(date +%s)"
EOF
)")" || { log "heartbeat 讀取失敗：${c}"; return 1; }
    hb="$(printf '%s\n' "$out" | awk '$1 == "HB" {print $2}')"
    now="$(printf '%s\n' "$out" | awk '$1 == "NOW" {print $2}')"
    case "${hb}${now}" in *[!0-9]*|'') log "heartbeat 缺值：${c}"; return 1 ;; esac
    age=$((now - hb))
    if [ "$age" -gt "$FIO_HEARTBEAT_MAX_AGE" ]; then
      log "fio heartbeat 過期：${c}（${age}s > ${FIO_HEARTBEAT_MAX_AGE}s）"
      return 1
    fi
    n=$((n + 1))
  done
  printf 'fio-alive: PASS %s\n' "$n"
}

# fio_wait_segments <bundle> <stop-fn> <deadline-epoch>
#   0 = stop-condition 成立（recovery_complete）；124 = 撞 measurement deadline；
#   2 = fio 失聯（該 attempt 要標 taint，不得當成正常量測）。
fio_wait_segments() {
  [ $# -eq 3 ] || die "用法：fio_wait_segments <bundle> <stop-fn> <deadline-epoch>"
  local bundle="$1" stopfn="$2" deadline="$3" now
  case "$deadline" in ''|*[!0-9]*) die "deadline 必須是絕對 epoch 秒（got=${deadline}）" ;; esac
  while :; do
    if "$stopfn"; then return 0; fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      log "fio_wait_segments：撞 measurement deadline ${deadline}（right-censored）"
      return 124
    fi
    if ! fio_assert_alive "$bundle" >/dev/null; then
      log "fio_wait_segments：fio client 失聯"
      return 2
    fi
    sleep "$POLL_INTERVAL"
  done
}

# --- 8) 停止 + exit proof + 回收 ---------------------------------------------

# baseline 復測與量測窗跑在**同一個 replicate bundle**：資料若都落 <bundle>/fio，
# verdict.py aggregate（walk 整個 fio/）會把 60s 復測的秒數也算進量測窗。
# 因此 baseline 的產出另立 <bundle>/fio-baseline/，只有主 workload 用 <bundle>/fio/。
_fio_data_root() { # <bundle> <mode>
  case "$2" in
    baseline) printf '%s/fio-baseline\n' "$1" ;;
    *)        printf '%s/fio\n' "$1" ;;
  esac
}

_fio_fetch() { # <bundle> <mode> <client> <workdir>
  local bundle="$1" mode="$2" c="$3" wd="$4" dest tarf
  dest="$(_fio_data_root "$bundle" "$mode")/$c"
  mkdir -p "$dest"
  tarf="$(_fio_scratch)/fetch.${c}.tar"
  _fio_run_script "$c" 900 fetch "cd ${wd} && tar cf - ." > "$tarf" \
    || die "fio 輸出回收失敗：${c}"
  [ -s "$tarf" ] || die "fio 輸出回收到空的 tar：${c}"
  tar -C "$dest" -xf "$tarf" || die "fio 輸出解開失敗：${c}"
}

fio_stop() { # <bundle>
  [ $# -eq 1 ] || die "用法：fio_stop <bundle>"
  local bundle="$1" mode c runid wd out tsv nfail
  _fio_require_run "$bundle"
  mode="$(_fio_mode_of "$bundle")"
  tsv="$(_fio_scratch)/exit.tsv"
  : > "$tsv"
  for c in $(_fio_clients); do
    runid="$(_fio_runid_of "$bundle" "$c")"
    wd="$(_fio_workdir_of "$bundle" "$c")"
    out="$(_fio_run_script "$c" $((FIO_STOP_WAIT_SECS + 60)) stop "$(cat <<EOF
set -u
D=${wd}
touch "\$D/STOP"
i=0
while [ \$i -lt ${FIO_STOP_WAIT_SECS} ] && [ ! -s "\$D/exit-code" ]; do sleep 1; i=\$((i + 1)); done
if [ -s "\$D/exit-code" ]; then echo "EXIT \$(cat "\$D/exit-code")"; else echo "EXIT TIMEOUT"; fi
if [ -s "\$D/heartbeat" ]; then echo "HB \$(cat "\$D/heartbeat")"; else echo "HB -"; fi
echo "SEG \$(ls "\$D"/exit-code.seg* 2>/dev/null | wc -l | tr -d ' ')"
echo "NOW \$(date +%s)"
EOF
)")" || die "fio 停止指令失敗：${c}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$c" \
      "$(printf '%s\n' "$out" | awk '$1 == "EXIT" {print $2}')" \
      "$(printf '%s\n' "$out" | awk '$1 == "HB" {print $2}')" \
      "$(printf '%s\n' "$out" | awk '$1 == "NOW" {print $2}')" \
      "$(printf '%s\n' "$out" | awk '$1 == "SEG" {print $2}')" >> "$tsv"
    remote_bg_stop "$c" "$runid" >/dev/null || log "remote_bg_stop 失敗（續行）：${c}"
    _fio_fetch "$bundle" "$mode" "$c" "$wd"
  done
  nfail="$(_fio_py exit-proof "$tsv" "$bundle/fio-exit-proof.json" "$mode")" \
    || die "exit proof 產生失敗"
  if [ "$nfail" != "0" ]; then
    printf 'fio-stop: FAIL %s\n' "$nfail"
    return 1
  fi
  printf 'fio-stop: PASS %s\n' "$(_fio_nclients)"
}

_fio_all_done() {
  local bundle="$_FIO_WD_BUNDLE" c wd out
  for c in $(_fio_clients); do
    wd="$(_fio_workdir_of "$bundle" "$c")"
    out="$(_fio_run_script "$c" 60 wait "$(cat <<EOF
set -u
if [ -s ${wd}/exit-code ]; then echo "DONE \$(cat ${wd}/exit-code)"; else echo PENDING; fi
EOF
)")" || return 1
    case "$out" in DONE*) : ;; *) return 1 ;; esac
  done
  return 0
}

_fio_wait_done() { # <bundle> <secs>
  local bundle="$1" secs="$2" rc=0
  _FIO_WD_BUNDLE="$bundle"
  with_deadline "$secs" _fio_all_done || rc=$?
  [ "$rc" -eq 0 ] || die "fio 未在 ${secs}s 內結束（segment 卡住？）"
}

_fio_summarize() { # <bundle> <shape> <mode> <rate> <out>
  local bundle="$1" shape="$2" mode="$3" rate="$4" out="$5" files root
  root="$(_fio_data_root "$bundle" "$mode")"
  files="$(find "$root" -type f -name 'seg*.json' | sort)"
  [ -n "$files" ] || die "找不到 fio segment JSON：${root}"
  # shellcheck disable=SC2086
  # files 是刻意要做 word splitting 的路徑清單（路徑由 bundle key 產生，無空白）
  _fio_py summary "$out" "$shape" "$mode" "$rate" $files
}

# --- 9) 穩態 / baseline ------------------------------------------------------

fio_run_steady() { # <bundle> <shape> <rate>
  [ $# -eq 3 ] || die "用法：fio_run_steady <bundle> <shape> <rate>"
  local bundle="$1" shape="$2" rate="$3" achieved
  fio_start_bg "$bundle" steady "$shape" "$rate" >/dev/null
  fio_readiness_barrier "$bundle" >/dev/null \
    || die "穩態量測前的 readiness barrier 未通過"
  _fio_wait_done "$bundle" $((FIO_STEADY_SECS + FIO_RAMP_SECS + FIO_RUN_SLACK_SECS))
  fio_stop "$bundle" >/dev/null || die "穩態 fio 非正常結束（exit proof 見 bundle）"
  achieved="$(_fio_summarize "$bundle" "$shape" steady "$rate" "$bundle/fio-summary.json")"
  printf 'fio-steady: PASS %s\n' "$achieved"
}

_fio_run_short() { # <bundle> <mode> <shape> <rate> <summary-out>
  local bundle="$1" mode="$2" shape="$3" rate="$4" out="$5" secs
  case "$mode" in
    baseline) secs=$((FIO_BASELINE_SECS + FIO_BASELINE_RAMP_SECS)) ;;
    calib)    secs=$((FIO_CALIB_SECS + FIO_RAMP_SECS)) ;;
    smoke)    secs=$((FIO_SMOKE_SECS + FIO_SMOKE_RAMP_SECS)) ;;
    precondition) secs="$FIO_PRECOND_SECS" ;;
    *) die "_fio_run_short 不支援 mode=${mode}" ;;
  esac
  fio_start_bg "$bundle" "$mode" "$shape" "$rate" >/dev/null
  _fio_wait_done "$bundle" $((secs + FIO_RUN_SLACK_SECS))
  fio_stop "$bundle" >/dev/null || die "${mode} fio 非正常結束（exit proof 見 bundle）"
  [ -n "$out" ] || return 0
  _fio_summarize "$bundle" "$shape" "$mode" "$rate" "$out" >/dev/null
}

fio_run_baseline() { # <bundle> <shape> <pressure> <rate>
  [ $# -eq 4 ] || die "用法：fio_run_baseline <bundle> <shape> <pressure> <rate>"
  local bundle="$1" shape="$2" pressure="$3" rate="$4" summary achieved
  summary="$bundle/fio-baseline-summary.json"
  _fio_run_short "$bundle" baseline "$shape" "$rate" "$summary"
  achieved="$(_fio_py baseline-record "$bundle/baseline.json" "$shape" "$pressure" \
              "$rate" "$summary")" || die "baseline.json 寫入失敗"
  printf 'fio-baseline: PASS %s\n' "$achieved"
}

# --- 10) 校準 ----------------------------------------------------------------

# fio_calibrate <shape>：balanced + final_clean 下的 rate sweep。
#   無限速 3 輪取中位為 ceiling → 反推 25/50/80% → 各壓力再跑 60s 記參考 p99。
fio_calibrate() {
  [ $# -eq 1 ] || die "用法：fio_calibrate <shape>"
  local shape="$1" profile base b r ceilings="" achieved
  local ceiling low mid high rates refs="" pressure rate p99
  local _praw
  # 取值與 trim 分兩步：`$(cmd | tr)` 的 rc 來自 tr（恆 0），`|| die` 會失效。
  _praw="$(ceph_adm "ceph config get osd osd_mclock_profile")" \
    || die "取不到目前的 mclock profile"
  profile="$(printf '%s' "$_praw" | tr -d ' \r\n')"
  [ -n "$profile" ] || die "取到的 mclock profile 是空的"
  [ "$profile" = "balanced" ] \
    || die "校準必須在 balanced profile 下做（目前 ${profile}）——treatment 不得污染 dose"
  ceph_wait_final_clean "$FIO_CALIB_CLEAN_SECS" >/dev/null \
    || die "校準必須在 final_clean 下做"

  base="$RESULTS_DIR/calibration/$shape"
  r=1
  while [ "$r" -le "$FIO_CALIB_ROUNDS" ]; do
    b="$base/ceiling-$r"
    mkdir -p "$b"
    _fio_run_short "$b" calib "$shape" 0 "$b/fio-summary.json"
    achieved="$(_fio_py summary-get "$b/fio-summary.json" achieved_iops)"
    ceilings="${ceilings},${achieved}"
    r=$((r + 1))
  done
  ceilings="${ceilings#,}"
  rates="$(_fio_py calib-rates "$ceilings")" || die "ceiling 推導失敗"
  ceiling="$(printf '%s\n' "$rates" | awk '{print $1}')"
  low="$(printf '%s\n' "$rates" | awk '{print $2}')"
  mid="$(printf '%s\n' "$rates" | awk '{print $3}')"
  high="$(printf '%s\n' "$rates" | awk '{print $4}')"

  for pressure in low mid high extreme; do
    case "$pressure" in
      low) rate="$low" ;; mid) rate="$mid" ;; high) rate="$high" ;; *) rate=0 ;;
    esac
    b="$base/ref-$pressure"
    mkdir -p "$b"
    _fio_run_short "$b" baseline "$shape" "$rate" "$b/fio-summary.json"
    p99="$(_fio_py summary-get "$b/fio-summary.json" p99_ns)"
    refs="${refs}${pressure}=${p99},"
  done

  _fio_py calib-record "$(calibration_path)" "$shape" \
    "$(_fio_shape_divisor "$shape")" "$ceiling" "$low" "$mid" "$high" \
    "${refs%,}" "$ceilings" >/dev/null || die "calibration.json 寫入失敗"
  printf 'fio-calibrate: PASS %s %s\n' "$shape" "$ceiling"
}

_fio_shape_divisor() { # <shape> → numjobs × client 數
  local numjobs
  case "$1" in
    4k) numjobs="$FIO_NUMJOBS_4K" ;;
    seq) numjobs="$FIO_NUMJOBS_SEQ" ;;
    *) die "未知 shape：${1}" ;;
  esac
  printf '%s\n' $((numjobs * $(_fio_nclients)))
}

# --- 11) precondition --------------------------------------------------------

fio_precondition() {
  local b pct
  b="$RESULTS_DIR/precondition"
  mkdir -p "$b"
  _fio_run_short "$b" precondition seq 0 ""
  pct="$(ceph_adm "ceph df --format json" \
         | _fio_py df-check "$CEPH_POOL" "$FIO_PRECOND_MIN_PCT" "$FIO_PRECOND_MAX_PCT")" \
    || die "填充率驗證未過（見上方訊息）"
  printf 'fio-precondition: PASS %s\n' "$pct"
}

# --- 12) raw NVMe 基線（**只准在 OSD 建立前**）--------------------------------

_fio_raw_guard_script() { # <device>
  cat <<EOF
set -u
DEV=$1
if [ ! -b "\$DEV" ]; then echo "RAWGUARD DIRTY not-a-block-device"; exit 0; fi
if ls -d /var/lib/ceph/*/osd.* >/dev/null 2>&1; then
  echo "RAWGUARD DIRTY osd-dir-exists"; exit 0
fi
if command -v blkid >/dev/null 2>&1; then
  if blkid -p -o export "\$DEV" 2>/dev/null | grep -qE '^(TYPE|PTTYPE|USAGE)='; then
    echo "RAWGUARD DIRTY blkid-signature"; exit 0
  fi
fi
if lsblk -nro NAME "\$DEV" 2>/dev/null | tail -n +2 | grep -q .; then
  echo "RAWGUARD DIRTY has-partitions"; exit 0
fi
if command -v ceph-volume >/dev/null 2>&1; then
  if ! ceph-volume inventory "\$DEV" --format json 2>/dev/null \
       | grep -q '"available": *true'; then
    echo "RAWGUARD DIRTY ceph-volume-unavailable"; exit 0
  fi
fi
echo RAWGUARD OK
EOF
}

_fio_raw_job_script() { # <device>
  cat <<EOF
set -u
fio --name=raw-nvme --filename=$1 --ioengine=libaio --direct=1 \\
    --rw=randwrite --bs=4k --iodepth=32 --numjobs=1 --randseed=${FIO_RANDSEED} \\
    --time_based=1 --runtime=${FIO_RAW_SECS} --ramp_time=5 --group_reporting=1 \\
    --output-format=json
EOF
}

# fio_raw_nvme_baseline <name>：OSD node 本機 fio 4K randwrite 直打 inv_nvme。
#   內建 guard：偵測到既有 BlueStore/分割/OSD 目錄即 die（OSD 建立後再打 raw device 會毀資料）。
fio_raw_nvme_baseline() {
  [ $# -eq 1 ] || die "用法：fio_raw_nvme_baseline <node>"
  local node="$1" dev guard out jsonf iops
  dev="$(inv_nvme "$node")"
  guard="$(_fio_run_script "$node" 120 rawguard "$(_fio_raw_guard_script "$dev")")" \
    || die "raw guard 執行失敗：${node}"
  case "$guard" in
    "RAWGUARD OK"*) : ;;
    *) die "raw NVMe guard 擋下：${node} ${dev}（${guard}）——只准在 OSD 建立前跑" ;;
  esac
  jsonf="$(_fio_scratch)/rawfio.${node}.json"
  _fio_run_script "$node" $((FIO_RAW_SECS + 180)) rawfio \
    "$(_fio_raw_job_script "$dev")" > "$jsonf" || die "raw fio 執行失敗：${node}"
  [ -s "$jsonf" ] || die "raw fio 沒有輸出：${node}"
  iops="$(_fio_py raw-record "$(raw_nvme_baseline_path)" "$node" "$jsonf")" \
    || die "raw 基線寫入失敗：${node}"
  out="$iops"
  printf 'raw-nvme-baseline: PASS %s %s\n' "$node" "$out"
}

# --- 13) smoke-real（parser 對真輸出的一次性校正）-----------------------------

fio_smoke_real() { # <bundle>
  [ $# -eq 1 ] || die "用法：fio_smoke_real <bundle>"
  local bundle="$1" golden c out
  [ -d "$bundle" ] || die "bundle 不存在：${bundle}"
  _fio_run_short "$bundle" smoke "$FIO_SMOKE_SHAPE" 0 "$bundle/fio-summary.json"

  golden="$(fio_golden_dir)"
  rm -rf "$golden"
  mkdir -p "$golden"
  for c in $(_fio_clients); do
    [ -d "$bundle/fio/$c" ] || continue
    mkdir -p "$golden/$c"
    cp -R "$bundle/fio/$c/." "$golden/$c/" || die "golden log 存檔失敗：${c}"
  done

  out="$(python3 "$VERDICT_PY" aggregate "$bundle" --validate-schema \
         --min-seconds "$FIO_SMOKE_MIN_SECONDS")" \
    || die "parser 校正未過：${out:-（無輸出）}"
  case "$out" in
    "aggregate: SCHEMA-OK"*) : ;;
    *) die "parser 校正未過：${out}" ;;
  esac
  printf 'fio-smoke-real: PASS %s\n' "${out#aggregate: SCHEMA-OK }"
}
