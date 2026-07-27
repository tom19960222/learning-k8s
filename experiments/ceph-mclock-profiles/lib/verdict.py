#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""lib/verdict.py — ceph-mclock-profiles 的量測 / 判準工具（plan Task 10）。

家規：只用 python3 標準庫；**stdout 只放機器行**，log/progress 一律 stderr。

子命令
------
  aggregate <bundle> [--validate-schema]
  margins <steady-bundle>... [--fault <fault-bundle>...] [-o <out>]
  freeze <bundle> --prediction <file>
  verdict <bundle> --prediction <file> [--margins <f>]
  verdict --cell <cell-id> [--results <dir>]
  verdict --group <group-id> [--results <dir>] [--margins <f>]
  need-more-n <cell> [--results <dir>] [--margins <f>]
  baseline-check <bundle> [--results <dir>]
  schemas <kind> [--json] [--verify <bundle>]
  schedule-estimate <pilot-bundle>... [--results <dir>]
  audit <results-dir> [--manifest <f>] [--out-dir <d>]

Bundle 內的檔案契約（與 Task 7/9/11 的介面；`schemas` 是唯一 SoT）
------------------------------------------------------------------
  fio/<client>/<seg>_iops.<job>.log        fio 1s IOPS log（log_unix_epoch=1）
  fio/<client>/<seg>_lat.<job>.log         fio 1s latency log
  fio/<client>/<seg>_clat_hist.<job>.log   fio 1s histogram log（log_hist_msec=1000）
  fault-timeline.json  {fault_t0, down_epoch_t, heal_t0, final_clean_t,
                        recovery_complete_t, measurement_deadline, measurement_cap}
  coverage-proof.json  {window:{start,end}, gaps:[{start,end,source}], tainted:bool}
  censor-status.json   {censored:bool, time_to_recovery_complete_s, measurement_cap}
  sampler-summary.json {recovery_bytes_per_sec_median, ...}
  return-backfill.json {heal_t0, final_clean_t, duration_s, recovery_bytes_per_sec}
  baseline.json        {shape, pressure, target_iops, achieved_iops, p99_ns, duration_s}
  prediction.json      {cell_id, group_id, profile, shape, pressure, manifest_hash,
                        expectations:{<endpoint>:{relation, order}}}
"""

import argparse
import datetime
import hashlib
import json
import math
import os
import re
import glob
import statistics
import sys

SCHEMA_VERSION = 1

LIB_DIR = os.path.dirname(os.path.abspath(__file__))
EXP_ROOT = os.path.dirname(LIB_DIR)
DEFAULT_RESULTS = os.environ.get("RESULTS_DIR", os.path.join(EXP_ROOT, "results"))
DEFAULT_HYPOTHESES = os.path.join(EXP_ROOT, "HYPOTHESES.md")

# --- 輸出 --------------------------------------------------------------------


def emit(line):
    """機器行 → stdout。"""
    sys.stdout.write("%s\n" % line)


def log(msg):
    sys.stderr.write("[verdict] %s\n" % msg)


def die(msg, code=1):
    sys.stderr.write("[verdict] FATAL: %s\n" % msg)
    raise SystemExit(code)


# =============================================================== required-files ==
# per-kind versioned required-files schema（plan Task 10 / round2 F21）。
# `bundle_finalize`（lib/common.sh）以「一行一個相對路徑」消費本清單；`#` 開頭為註解行。

_STEADY_FILES = [
    "prediction.json",
    "qos.json",
    "fio-summary.json",
    "aggregate.json",
    "verdict.json",
]

# fault 另加：故障時間軸、sampler、censor、兩層 clean 證明、cleanup、coverage、
# 以及 H-008 的 best_effort 回歸時戳（return-backfill.json）。
_FAULT_EXTRA = [
    "fault-timeline.json",
    "sampler-summary.json",
    "censor-status.json",
    "final-clean-proof.json",
    "cleanup-proof.json",
    "coverage-proof.json",
    "return-backfill.json",
]

# chaos：event-seq + prediction/verdict/coverage-proof（plan Task 10）；
# chaos 也會注入故障，故一併要求 cleanup-proof（回退證明）。
_CHAOS_EXTRA = [
    "event-seq.json",
    "coverage-proof.json",
    "cleanup-proof.json",
]

SCHEMAS = {
    "steady": {"version": 1, "files": list(_STEADY_FILES)},
    "fault": {"version": 1, "files": _STEADY_FILES + _FAULT_EXTRA},
    "chaos": {"version": 1, "files": _STEADY_FILES + _CHAOS_EXTRA},
}


# ============================================================ production margin ==
# HYPOTHESES.md §預註冊生產門檻（Task 1 Step 7）的機器可讀複本。
# 這裡是「程式端 SoT」；`_check_hypotheses_drift()` 會回頭驗 HYPOTHESES.md
# 仍寫著同一組數字，避免兩邊悄悄漂移。
#
# combine 語意：
#   "max"  → 門檻 = max(diff_abs, diff_rel × ref)（「取較大者」與「且」數學上同值）
#   "abs"  → 門檻 = diff_abs
#   "rel"  → 門檻 = diff_rel × ref
PRODUCTION_MARGINS = {
    "p99_degradation_ratio": {
        "diff_abs": 1.0,
        "diff_rel": 0.50,
        "combine": "max",
        "unit": "ratio",
        "severity": {"significant": 3.0, "incident": 10.0},
        "hypotheses_tokens": ["1.0", "50%", "3×", "10×"],
    },
    "max_stall_seconds": {
        "diff_abs": 2.0,
        "combine": "abs",
        "unit": "s",
        "severity": {"incident": 5.0, "guest_io_error_risk": 30.0},
        "hypotheses_tokens": ["2 s", "5 s", "30 s"],
    },
    "recovery_bytes_per_sec": {
        "diff_rel": 0.25,
        "combine": "rel",
        "unit": "B/s",
        "severity": {},
        "hypotheses_tokens": ["25%"],
    },
    "time_to_recovery_complete_s": {
        "diff_abs": 300.0,
        "diff_rel": 0.20,
        "combine": "max",
        "unit": "s",
        "severity": {},
        "hypotheses_tokens": ["20%", "300 s"],
    },
}

PRIMARY_ENDPOINTS = tuple(PRODUCTION_MARGINS.keys())


def production_threshold(endpoint, ref):
    """回傳該 endpoint 在參考值 ref 下的「生產有感」絕對門檻。"""
    spec = PRODUCTION_MARGINS[endpoint]
    ref = abs(float(ref)) if ref is not None else 0.0
    abs_t = float(spec.get("diff_abs", 0.0))
    rel_t = float(spec.get("diff_rel", 0.0)) * ref
    mode = spec.get("combine", "max")
    if mode == "abs":
        return abs_t
    if mode == "rel":
        return rel_t
    return max(abs_t, rel_t)


def severity_of(endpoint, value):
    """把單一觀測值對照絕對嚴重度門檻（HYPOTHESES.md 右欄）。"""
    spec = PRODUCTION_MARGINS.get(endpoint, {})
    sev = spec.get("severity") or {}
    if value is None or not sev:
        return None
    hit = None
    for name, threshold in sorted(sev.items(), key=lambda kv: kv[1]):
        if float(value) >= float(threshold):
            hit = name
    return hit


def _check_hypotheses_drift(path):
    """驗 HYPOTHESES.md 的預註冊門檻仍與 PRODUCTION_MARGINS 一致。

    回傳漂移的 endpoint 清單（空 list = 沒漂移）；檔案不存在則回 None（略過）。
    """
    if not path or not os.path.isfile(path):
        return None
    with open(path, "r") as fh:
        text = fh.read()
    start = text.find("預註冊生產門檻")
    if start < 0:
        return list(PRODUCTION_MARGINS.keys())
    section = text[start:start + 4000]
    drifted = []
    for endpoint, spec in PRODUCTION_MARGINS.items():
        for token in spec.get("hypotheses_tokens", []):
            if token not in section:
                drifted.append(endpoint)
                break
    return drifted


# ==================================================================== 小工具 ====


def read_json(path, default=None):
    if not path or not os.path.isfile(path):
        return default
    try:
        with open(path, "r") as fh:
            return json.load(fh)
    except ValueError as exc:
        die("JSON 解析失敗：%s（%s）" % (path, exc))
    except (IOError, OSError) as exc:
        die("讀檔失敗：%s（%s）" % (path, exc))


def write_json(path, obj):
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    os.rename(tmp, path)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def mean(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    return float(sum(vals)) / len(vals)


def median(vals):
    vals = sorted(v for v in vals if v is not None)
    if not vals:
        return None
    return float(statistics.median(vals))


def stdev(vals):
    vals = [v for v in vals if v is not None]
    if len(vals) < 2:
        return None
    return float(statistics.stdev(vals))


def cov(vals):
    """within-cell CoV；mean == 0 時 CoV 無定義，回 None（呼叫端改用絕對 margin）。"""
    m = mean(vals)
    s = stdev(vals)
    if m is None or s is None or abs(m) < 1e-12:
        return None
    return s / abs(m)


def longest_run(sorted_secs, break_set):
    """在已排序的秒清單上找最長連續 run；break_set 內的秒視為斷點（不橋接）。"""
    best = 0
    cur = 0
    prev = None
    for sec in sorted_secs:
        if prev is not None and (sec != prev + 1 or prev in break_set or sec in break_set):
            cur = 0
        cur += 1
        if cur > best:
            best = cur
        prev = sec
    return best


# ============================================================== fio log parser ==
#
# fio histogram：FIO_IO_U_PLAT_BITS=6 → 每組 64 bin。
#   nsec 版（fio >= 3.0）：29 組 → 1856 bin，bin 值單位 ns
#   usec 版（fio < 3.0） ：19 組 → 1216 bin，bin 值單位 us
# 由 bin 數自動判定單位——這是本 parser 對真機 log 的一次性自校正依據
# （`fio_smoke_real` 走 `aggregate --validate-schema`）。

FIO_IO_U_PLAT_BITS = 6
FIO_IO_U_PLAT_VAL = 1 << FIO_IO_U_PLAT_BITS
HIST_BINS_NS = 29 * FIO_IO_U_PLAT_VAL   # 1856
HIST_BINS_US = 19 * FIO_IO_U_PLAT_VAL   # 1216
HIST_UNIT_NS = {HIST_BINS_NS: 1.0, HIST_BINS_US: 1000.0}

_LOG_RE = re.compile(
    r"^(?P<seg>.+)_(?P<kind>clat_hist|clat|slat|lat|iops|bw)"
    r"(?:\.(?P<job>\d+))?\.log$"
)

_PLAT_CACHE = {}


def plat_idx_to_val(idx):
    """fio `plat_idx_to_val()`（stat.c）的 python 複刻。"""
    if idx in _PLAT_CACHE:
        return _PLAT_CACHE[idx]
    if idx < (FIO_IO_U_PLAT_VAL << 1):
        val = float(idx)
    else:
        error_bits = (idx >> FIO_IO_U_PLAT_BITS) - 1
        base = 1 << (error_bits + FIO_IO_U_PLAT_BITS)
        k = idx % FIO_IO_U_PLAT_VAL
        val = float(base + ((k + 0.5) * (1 << error_bits)))
    _PLAT_CACHE[idx] = val
    return val


def hist_percentile(bins, pct, unit_ns):
    """從一組 histogram bin 算 percentile（回傳 ns）。bins 為 delta counts。"""
    total = sum(bins)
    if total <= 0:
        return None
    want = total * (pct / 100.0)
    acc = 0
    for idx, cnt in enumerate(bins):
        if cnt <= 0:
            continue
        acc += cnt
        if acc >= want:
            return plat_idx_to_val(idx) * unit_ns
    return None


def hist_max(bins, unit_ns):
    for idx in range(len(bins) - 1, -1, -1):
        if bins[idx] > 0:
            return plat_idx_to_val(idx) * unit_ns
    return None


def _iter_log_files(fio_dir):
    """走訪 <bundle>/fio 下的所有 fio log；回 (path, client, seg, kind, job)。"""
    for dirpath, _dirnames, filenames in os.walk(fio_dir):
        for name in sorted(filenames):
            m = _LOG_RE.match(name)
            if not m:
                continue
            rel = os.path.relpath(dirpath, fio_dir)
            client = "default" if rel in (".", "") else rel.split(os.sep)[0]
            yield (
                os.path.join(dirpath, name),
                client,
                m.group("seg"),
                m.group("kind"),
                m.group("job") or "0",
            )


def _parse_numeric_log(path):
    """解析 iops/lat/bw log；回 [(time_ms, value, direction, bs)]。"""
    rows = []
    with open(path, "r") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 3:
                raise ValueError("%s:%d 欄位不足（fio log 至少 3 欄）" % (path, lineno))
            try:
                t_ms = int(float(parts[0]))
                val = float(parts[1])
                direction = int(float(parts[2]))
                bs = int(float(parts[3])) if len(parts) > 3 and parts[3] != "" else 0
            except ValueError:
                raise ValueError("%s:%d 非數值欄位：%s" % (path, lineno, line))
            rows.append((t_ms, val, direction, bs))
    return rows


def _parse_hist_log(path):
    """解析 clat_hist log；回 (bin_count, [(time_ms, direction, bins)])。"""
    rows = []
    bin_count = None
    with open(path, "r") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 4:
                raise ValueError("%s:%d hist log 欄位不足" % (path, lineno))
            try:
                t_ms = int(float(parts[0]))
                direction = int(float(parts[1]))
                bins = [int(float(p)) for p in parts[3:] if p != ""]
            except ValueError:
                raise ValueError("%s:%d hist log 非數值欄位" % (path, lineno))
            if bin_count is None:
                bin_count = len(bins)
            elif len(bins) != bin_count:
                raise ValueError(
                    "%s:%d hist bin 數不一致（%d vs %d）"
                    % (path, lineno, len(bins), bin_count)
                )
            rows.append((t_ms, direction, bins))
    return bin_count, rows


class FioSeries(object):
    """跨 segment / client / job 合併後的逐秒序列。

    正規化規則（plan Task 10「windowed log 的重複 timestamp / 不完整尾窗要正規化」）：
      1. 同一 stream（client, seg, kind, job, direction）內同一秒重複出現 → 保留第一筆，
         其餘計入 `duplicate_rows_dropped`。
      2. 每個 segment 每個 stream 的**最後一秒**是不完整尾窗：
         若別的 segment 也覆蓋該秒 → 直接丟棄尾窗那筆；
         若沒有別的來源 → 保留但標成 `partial_tail`，**不參與 stall 判定**
         （半個窗的低計數不是 stall）。
    """

    def __init__(self):
        self.iops_by_sec = {}          # sec -> 累計 IOPS（跨 client/job/direction）
        self.bytes_by_sec = {}         # sec -> 累計 bytes/s
        self.hist_by_sec = {}          # sec -> list[int] bins（delta counts）
        self.partial_tail_secs = set()
        self.duplicate_rows_dropped = 0
        self.clients = set()
        self.segments = set()
        self.files = 0
        self.hist_bins = None
        self.hist_unit_ns = None
        self.epoch_ms = None
        self.directions = set()
        self.errors = []

    # -- 累加 ------------------------------------------------------------
    def _add_numeric(self, sec, value, bs, partial):
        self.iops_by_sec[sec] = self.iops_by_sec.get(sec, 0.0) + value
        # 不從 iops × bs 換算頻寬：真機的 iops log block-size 欄位是 0，
        # 換算恆為 0。頻寬一律取自 fio 的 bw log（kind == "bw"）。
        _ = bs
        if partial:
            self.partial_tail_secs.add(sec)

    def _add_hist(self, sec, bins):
        cur = self.hist_by_sec.get(sec)
        if cur is None:
            self.hist_by_sec[sec] = list(bins)
        else:
            for i, c in enumerate(bins):
                if c:
                    cur[i] += c

    # -- 秒集合 ----------------------------------------------------------
    def observed_seconds(self):
        return set(self.iops_by_sec.keys())

    def span(self):
        secs = self.observed_seconds() | set(self.hist_by_sec.keys())
        if not secs:
            return (None, None)
        return (min(secs), max(secs))


def load_fio_series(fio_dir, strict=False):
    """掃描 <bundle>/fio 建立 FioSeries。strict=True 時把解析錯誤變成例外。"""
    series = FioSeries()
    numeric_raw = {}   # (client, seg, job, direction) -> dict[sec] = (value, bs)
    numeric_tail = {}  # (client, seg, job, direction) -> tail sec
    bw_raw = {}        # (client, seg, job, direction) -> dict[sec] = bytes/s
    bw_tail = {}       # (client, seg, job, direction) -> tail sec
    hist_raw = {}      # (client, seg, job, direction) -> dict[sec] = bins
    hist_tail = {}

    if not os.path.isdir(fio_dir):
        series.errors.append("找不到 fio log 目錄：%s" % fio_dir)
        return series

    for path, client, seg, kind, job in _iter_log_files(fio_dir):
        if kind in ("slat", "clat"):
            continue  # percentile 一律走 clat_hist
        series.files += 1
        series.clients.add(client)
        series.segments.add(seg)
        try:
            if kind == "clat_hist":
                bin_count, rows = _parse_hist_log(path)
                if bin_count is not None:
                    if series.hist_bins is None:
                        series.hist_bins = bin_count
                    elif series.hist_bins != bin_count:
                        raise ValueError(
                            "hist bin 數跨檔不一致（%d vs %d）：%s"
                            % (bin_count, series.hist_bins, path)
                        )
                for t_ms, direction, bins in rows:
                    series.directions.add(direction)
                    if series.epoch_ms is None:
                        series.epoch_ms = t_ms > 10 ** 12
                    sec = t_ms // 1000
                    key = (client, seg, job, direction)
                    slot = hist_raw.setdefault(key, {})
                    if sec in slot:
                        series.duplicate_rows_dropped += 1
                        continue
                    slot[sec] = bins
                    hist_tail[key] = sec
            elif kind == "bw":
                # fio 的 bw log 直接給 KiB/s；不能從 iops log 換算——它的
                # block-size 欄位真機上是 0（`1785082328606, 695, 0, 0, 0`），
                # 換算結果會恆為 0，頻寬在報告裡就永遠是空的。
                rows = _parse_numeric_log(path)
                for t_ms, val, direction, _bs in rows:
                    if series.epoch_ms is None:
                        series.epoch_ms = t_ms > 10 ** 12
                    sec = t_ms // 1000
                    key = (client, seg, job, direction)
                    slot = bw_raw.setdefault(key, {})
                    if sec in slot:
                        series.duplicate_rows_dropped += 1
                        continue
                    slot[sec] = val * 1024.0      # KiB/s → bytes/s
                    bw_tail[key] = sec
            elif kind == "iops":
                rows = _parse_numeric_log(path)
                for t_ms, val, direction, bs in rows:
                    series.directions.add(direction)
                    if series.epoch_ms is None:
                        series.epoch_ms = t_ms > 10 ** 12
                    sec = t_ms // 1000
                    key = (client, seg, job, direction)
                    slot = numeric_raw.setdefault(key, {})
                    if sec in slot:
                        series.duplicate_rows_dropped += 1
                        continue
                    slot[sec] = (val, bs)
                    numeric_tail[key] = sec
            # kind == "lat" 目前僅作為 schema 驗證素材（percentile 一律走 hist）
        except ValueError as exc:
            if strict:
                raise
            series.errors.append(str(exc))

    # 尾窗判定：某 stream 的最後一秒，若同 (client, job, direction) 的其他 segment
    # 也有該秒的資料 → 丟棄尾窗；否則保留並標 partial。
    def _coverage_by_stream(raw):
        cover = {}
        for (client, seg, job, direction), slot in raw.items():
            key = (client, job, direction)
            for sec in slot:
                cover.setdefault(key, {}).setdefault(sec, set()).add(seg)
        return cover

    num_cover = _coverage_by_stream(numeric_raw)
    for (client, seg, job, direction), slot in sorted(numeric_raw.items()):
        tail = numeric_tail.get((client, seg, job, direction))
        for sec in sorted(slot):
            val, bs = slot[sec]
            is_tail = sec == tail
            if is_tail and len(num_cover[(client, job, direction)][sec]) > 1:
                series.duplicate_rows_dropped += 1
                continue
            series._add_numeric(sec, val, bs, is_tail)

    bw_cover = _coverage_by_stream(bw_raw)
    for (client, seg, job, direction), slot in sorted(bw_raw.items()):
        tail = bw_tail.get((client, seg, job, direction))
        for sec in sorted(slot):
            if sec == tail and len(bw_cover[(client, job, direction)][sec]) > 1:
                series.duplicate_rows_dropped += 1
                continue
            series.bytes_by_sec[sec] = series.bytes_by_sec.get(sec, 0.0) + slot[sec]

    hist_cover = _coverage_by_stream(hist_raw)
    for (client, seg, job, direction), slot in sorted(hist_raw.items()):
        tail = hist_tail.get((client, seg, job, direction))
        for sec in sorted(slot):
            if sec == tail and len(hist_cover[(client, job, direction)][sec]) > 1:
                continue
            series._add_hist(sec, slot[sec])

    if series.hist_bins:
        series.hist_unit_ns = HIST_UNIT_NS.get(series.hist_bins)
    return series


# ================================================================ 窗口統計 ====


def load_gap_seconds(bundle):
    """coverage-proof.json 是 gap 的唯一權威來源（plan §Replicate Pipeline）。

    「工具中斷」與「client 真的黑掉」在 fio log 上長得一樣（都是沒有樣本），
    唯一能區分的是 coverage supervisor 的 heartbeat 證據。因此：
      - 落在 coverage-proof gap 區間的秒 → gap，不算 stall、也不算覆蓋。
      - 不在 gap 區間、卻沒有樣本的秒 → **stall**（supervisor 說工具活著）。
    """
    proof = read_json(os.path.join(bundle, "coverage-proof.json"), {}) or {}
    gaps = []
    for g in proof.get("gaps") or []:
        try:
            start = int(g["start"])
            end = int(g["end"])
        except (KeyError, TypeError, ValueError):
            continue
        gaps.append((start, end))
    gap_secs = set()
    for start, end in gaps:
        for sec in range(start, end + 1):
            gap_secs.add(sec)
    window = proof.get("window") or {}
    return gap_secs, gaps, window, proof


def window_stats(series, gap_secs, start, end, brownout_ns):
    """對 [start, end]（含端點，epoch 秒）算窗口統計。"""
    out = {
        "start": start,
        "end": end,
        "window_seconds": None,
        "covered_seconds": 0,
        "gap_seconds": 0,
        "partial_tail_seconds": 0,
        "iops_mean": None,
        "iops_median": None,
        "bw_bytes_per_sec_mean": None,
        "p50_ns": None,
        "p99_ns": None,
        "p999_ns": None,
        "max_ns": None,
        "max_stall_seconds": 0,
        "total_stall_seconds": 0,
        "stall_intervals": [],
        "max_brownout_seconds": 0,
        "total_brownout_seconds": 0,
    }
    if start is None or end is None or end < start:
        return out
    out["window_seconds"] = end - start + 1

    iops_vals = []
    bw_vals = []
    stall_secs = []
    brownout_secs = []
    covered = 0
    gaps_in_window = 0
    partial = 0
    merged_bins = None

    for sec in range(start, end + 1):
        if sec in gap_secs:
            gaps_in_window += 1
            continue
        present = sec in series.iops_by_sec
        if present:
            covered += 1
            val = series.iops_by_sec[sec]
            iops_vals.append(val)
            bw_vals.append(series.bytes_by_sec.get(sec, 0.0))
        if sec in series.partial_tail_secs:
            # 不完整尾窗：計數偏低是量測假象，不得判為 stall
            partial += 1
        elif (not present) or series.iops_by_sec.get(sec, 0.0) <= 0.0:
            # 有樣本但完成數 = 0，或 supervisor 保證活著卻沒有樣本 → stall
            stall_secs.append(sec)

        bins = series.hist_by_sec.get(sec)
        if bins:
            if merged_bins is None:
                merged_bins = list(bins)
            else:
                for i, c in enumerate(bins):
                    if c:
                        merged_bins[i] += c
            if series.hist_unit_ns:
                p99 = hist_percentile(bins, 99.0, series.hist_unit_ns)
                if p99 is not None and p99 > brownout_ns:
                    brownout_secs.append(sec)

    out["covered_seconds"] = covered
    out["gap_seconds"] = gaps_in_window
    out["partial_tail_seconds"] = partial
    out["iops_mean"] = mean(iops_vals)
    out["iops_median"] = median(iops_vals)
    out["bw_bytes_per_sec_mean"] = mean(bw_vals)

    if merged_bins and series.hist_unit_ns:
        out["p50_ns"] = hist_percentile(merged_bins, 50.0, series.hist_unit_ns)
        out["p99_ns"] = hist_percentile(merged_bins, 99.0, series.hist_unit_ns)
        out["p999_ns"] = hist_percentile(merged_bins, 99.9, series.hist_unit_ns)
        out["max_ns"] = hist_max(merged_bins, series.hist_unit_ns)

    out["total_stall_seconds"] = len(stall_secs)
    out["max_stall_seconds"] = longest_run(sorted(stall_secs), gap_secs)
    out["stall_intervals"] = _to_intervals(sorted(stall_secs), gap_secs)
    out["total_brownout_seconds"] = len(brownout_secs)
    out["max_brownout_seconds"] = longest_run(sorted(brownout_secs), gap_secs)
    return out


def _to_intervals(secs, break_set):
    intervals = []
    start = None
    prev = None
    for sec in secs:
        if prev is None or sec != prev + 1 or prev in break_set or sec in break_set:
            if start is not None:
                intervals.append([start, prev])
            start = sec
        prev = sec
    if start is not None:
        intervals.append([start, prev])
    return intervals


# =================================================================== aggregate ==


def cmd_aggregate(args):
    bundle = os.path.abspath(args.bundle)
    if not os.path.isdir(bundle):
        die("bundle 不存在：%s" % bundle)
    fio_dir = os.path.join(bundle, "fio")

    if args.validate_schema:
        return _validate_log_schema(fio_dir, args)

    series = load_fio_series(fio_dir)
    for err in series.errors:
        log("aggregate 解析警告：%s" % err)
    if series.hist_bins and not series.hist_unit_ns:
        die("無法判定 hist 單位（bin 數 = %d，預期 %d 或 %d）"
            % (series.hist_bins, HIST_BINS_NS, HIST_BINS_US))

    gap_secs, gap_intervals, cov_window, _proof = load_gap_seconds(bundle)
    pred = read_json(os.path.join(bundle, "prediction.json"), {}) or {}
    timeline = read_json(os.path.join(bundle, "fault-timeline.json"), {}) or {}
    censor = read_json(os.path.join(bundle, "censor-status.json"), {}) or {}
    sampler = read_json(os.path.join(bundle, "sampler-summary.json"), {}) or {}
    backfill = read_json(os.path.join(bundle, "return-backfill.json"), {}) or {}

    obs_start, obs_end = series.span()
    win_start = _as_int(cov_window.get("start"), obs_start)
    win_end = _as_int(cov_window.get("end"), obs_end)

    # fio 若是自己跑完（穩態跑滿 runtime 就結束），窗尾要夾到它結束的時刻：
    # pipeline 記的 win_end 是「偵測到 fio 結束」的時間，比實際晚一個輪詢週期
    # （真機實測 34s），那段沒有 workload、自然沒有 IO，不夾就會被算成 stall。
    # **只夾 fio 自行結束的情形**——被我們 STOP 中止時，尾端沒有 IO 是真的 stall
    # （client 全黑到最後正是故障實驗要抓的東西），夾掉就等於把它抹掉。
    exit_proof = read_json(os.path.join(bundle, "fio-exit-proof.json"), {}) or {}
    exited = [c.get("fio_exited_at") for c in (exit_proof.get("clients") or {}).values()]
    exited = [e for e in exited if isinstance(e, int)]
    if exited and win_end is not None and obs_end is not None:
        # 夾到**最後一筆實際樣本**，不是 fio_exited_at：後者是「fio 連 log 都寫完
        # 才返回」的時刻，比最後一筆量測晚數秒（真機 9s），那幾秒同樣沒有 workload。
        # fio_exited_at 在此只當「fio 是自行結束的」這個事實的證據——被我們 STOP
        # 中止時它不存在，就不夾窗，尾端無 IO 才會如實記成 stall。
        if obs_end < win_end:
            log("aggregate：窗尾自 %d 夾到最後一筆樣本 %d（差 %ds 為 fio 收尾與偵測延遲）"
                % (win_end, obs_end, win_end - obs_end))
            win_end = obs_end
    if win_start is None or win_end is None:
        die("aggregate：找不到任何 fio 逐秒樣本，也沒有 coverage-proof 的窗口定義")

    brownout_ns = float(args.brownout_threshold) * 1e9
    fault_t0 = _as_int(timeline.get("fault_t0"), None)
    down_epoch_t = _as_int(timeline.get("down_epoch_t"), None)
    heal_t0 = _as_int(timeline.get("heal_t0"), None)
    recovery_complete_t = _as_int(timeline.get("recovery_complete_t"), None)
    deadline = _as_int(timeline.get("measurement_deadline"), None)

    # 量測窗終點：recovery_complete 或 measurement_deadline（先到者），封頂在觀測末端
    meas_end = win_end
    for cand in (recovery_complete_t, deadline):
        if cand is not None:
            meas_end = min(meas_end, cand)
    if heal_t0 is not None:
        meas_end = min(meas_end, heal_t0 - 1)

    windows = {}
    windows["full"] = window_stats(series, gap_secs, win_start, win_end, brownout_ns)

    if fault_t0 is not None:
        base_start = max(win_start, fault_t0 - 60)
        windows["baseline"] = window_stats(
            series, gap_secs, base_start, fault_t0 - 1, brownout_ns)
        windows["measurement_t0"] = window_stats(
            series, gap_secs, fault_t0, meas_end, brownout_ns)
        if down_epoch_t is not None:
            windows["measurement_down_epoch"] = window_stats(
                series, gap_secs, down_epoch_t, meas_end, brownout_ns)
    else:
        # 穩態（negative control）：前 60s 當基線，其餘當量測窗，
        # 讓 p99_degradation_ratio 這個 endpoint 在穩態上也有噪音底。
        base_end = min(win_end, win_start + 59)
        windows["baseline"] = window_stats(
            series, gap_secs, win_start, base_end, brownout_ns)
        windows["measurement_t0"] = window_stats(
            series, gap_secs, min(base_end + 1, win_end), win_end, brownout_ns)

    meas = windows["measurement_t0"]
    base = windows["baseline"]
    endpoints = {
        "p99_degradation_ratio": _ratio(meas.get("p99_ns"), base.get("p99_ns")),
        "max_stall_seconds": meas.get("max_stall_seconds"),
        "total_stall_seconds": meas.get("total_stall_seconds"),
        "max_brownout_seconds": meas.get("max_brownout_seconds"),
        "total_brownout_seconds": meas.get("total_brownout_seconds"),
        "recovery_bytes_per_sec": sampler.get("recovery_bytes_per_sec_median"),
        "time_to_recovery_complete_s": None,
        "return_backfill_duration_s": backfill.get("duration_s"),
        "iops_mean": meas.get("iops_mean"),
        "bw_bytes_per_sec_mean": meas.get("bw_bytes_per_sec_mean"),
        "p50_ns": meas.get("p50_ns"),
        "p99_ns": meas.get("p99_ns"),
        "p999_ns": meas.get("p999_ns"),
        "max_ns": meas.get("max_ns"),
    }
    if "measurement_down_epoch" in windows:
        endpoints["p99_degradation_ratio_down_epoch"] = _ratio(
            windows["measurement_down_epoch"].get("p99_ns"), base.get("p99_ns"))

    # censor 相對 recovery_complete（不是 final_clean）
    censored = bool(censor.get("censored", False))
    ttr = censor.get("time_to_recovery_complete_s")
    if ttr is None and fault_t0 is not None and recovery_complete_t is not None:
        ttr = recovery_complete_t - fault_t0
    if ttr is None and censored and fault_t0 is not None and deadline is not None:
        ttr = deadline - fault_t0
    endpoints["time_to_recovery_complete_s"] = ttr

    cap = censor.get("measurement_cap", timeline.get("measurement_cap"))

    out = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "bundle": bundle,
        "cell_id": pred.get("cell_id"),
        "group_id": pred.get("group_id"),
        "profile": pred.get("profile"),
        "shape": pred.get("shape"),
        "pressure": pred.get("pressure"),
        "manifest_hash": pred.get("manifest_hash"),
        "windows": windows,
        "endpoints": endpoints,
        "censored": censored,
        "censor_basis": "recovery_complete",
        "measurement_cap": cap,
        "normalization": {
            "duplicate_rows_dropped": series.duplicate_rows_dropped,
            "partial_tail_seconds": sorted(series.partial_tail_secs),
            "segments": sorted(series.segments),
        },
        "coverage": {
            "window": {"start": win_start, "end": win_end},
            "gap_intervals": [list(g) for g in gap_intervals],
            "gap_seconds": len(gap_secs),
            "covered_seconds": windows["full"]["covered_seconds"],
        },
        "log_schema": {
            "files": series.files,
            "clients": sorted(series.clients),
            "hist_bins": series.hist_bins,
            "hist_unit": _unit_name(series.hist_unit_ns),
            "epoch_ms": series.epoch_ms,
            "directions": sorted(series.directions),
            "brownout_threshold_ns": brownout_ns,
        },
        "parse_warnings": series.errors,
    }
    write_json(os.path.join(bundle, "aggregate.json"), out)
    emit("aggregate: OK max_stall=%s total_stall=%s max_brownout=%s p99_ns=%s" % (
        endpoints["max_stall_seconds"], endpoints["total_stall_seconds"],
        endpoints["max_brownout_seconds"], _fmt(endpoints["p99_ns"])))
    return 0


def _validate_log_schema(fio_dir, args):
    """`fio_smoke_real` 的 parser 校正模式：對真機 raw log 驗結構契約。"""
    problems = []
    try:
        series = load_fio_series(fio_dir, strict=True)
    except ValueError as exc:
        emit("aggregate: SCHEMA-FAIL %s" % str(exc).replace("\n", " "))
        return 1
    if series.errors:
        problems.extend(series.errors)
    if series.files == 0:
        problems.append("找不到任何 fio log（預期 <bundle>/fio/<client>/<seg>_{iops,lat,clat_hist}.<job>.log）")
    if not series.iops_by_sec:
        problems.append("iops log 沒有任何樣本")
    if series.hist_bins is None:
        problems.append("缺 clat_hist log（brownout 判定需要逐秒 histogram）")
    elif series.hist_unit_ns is None:
        problems.append("hist bin 數 %d 不在已知集合 {%d(ns), %d(us)}"
                        % (series.hist_bins, HIST_BINS_NS, HIST_BINS_US))
    if series.epoch_ms is False:
        problems.append("timestamp 不是 unix epoch ms（fio 需 log_unix_epoch=1）")
    for d in series.directions:
        if d not in (0, 1, 2):
            problems.append("未知的 data direction 代碼：%s" % d)
    covered = len(series.iops_by_sec)
    if covered < args.min_seconds:
        problems.append("逐秒樣本只有 %d 秒（要求 >= %d）" % (covered, args.min_seconds))

    if problems:
        for p in problems:
            log("schema 問題：%s" % p)
        emit("aggregate: SCHEMA-FAIL %s" % problems[0].replace("\n", " "))
        return 1
    emit("aggregate: SCHEMA-OK files=%d seconds=%d hist_bins=%d unit=%s clients=%d" % (
        series.files, covered, series.hist_bins,
        _unit_name(series.hist_unit_ns), len(series.clients)))
    return 0


def _unit_name(unit_ns):
    if unit_ns is None:
        return None
    return "ns" if abs(unit_ns - 1.0) < 1e-9 else "us"


def _as_int(val, default):
    if val is None:
        return default
    try:
        return int(val)
    except (TypeError, ValueError):
        return default


def _ratio(num, den):
    if num is None or den is None or den == 0:
        return None
    return float(num) / float(den)


def _fmt(val):
    if val is None:
        return "null"
    if isinstance(val, float):
        return "%.6g" % val
    return str(val)


# ================================================================ bundle 掃描 ====


def iter_done_bundles(results_dir):
    """走訪 results/<cell>/<rN>/attempts/<ts>，只回已 finalize（有 DONE）的 attempt。"""
    if not os.path.isdir(results_dir):
        return
    for cell in sorted(os.listdir(results_dir)):
        cell_dir = os.path.join(results_dir, cell)
        if not os.path.isdir(cell_dir):
            continue
        for rep in sorted(os.listdir(cell_dir)):
            rep_dir = os.path.join(cell_dir, rep)
            attempts = os.path.join(rep_dir, "attempts")
            if not os.path.isdir(attempts):
                continue
            for ts in sorted(os.listdir(attempts)):
                att = os.path.join(attempts, ts)
                if os.path.isfile(os.path.join(att, "DONE")):
                    yield (cell, rep, att)


def bundle_record(path):
    """把一個 attempt 目錄整理成分析用的扁平記錄。"""
    agg = read_json(os.path.join(path, "aggregate.json"), {}) or {}
    pred = read_json(os.path.join(path, "prediction.json"), {}) or {}
    censor = read_json(os.path.join(path, "censor-status.json"), {}) or {}
    timeline = read_json(os.path.join(path, "fault-timeline.json"), {}) or {}
    proof = read_json(os.path.join(path, "coverage-proof.json"), {}) or {}
    cap = censor.get("measurement_cap")
    if cap is None:
        cap = timeline.get("measurement_cap")
    if cap is None:
        cap = agg.get("measurement_cap")
    return {
        "bundle": path,
        "cell_id": pred.get("cell_id") or agg.get("cell_id"),
        "group_id": pred.get("group_id") or agg.get("group_id"),
        "profile": pred.get("profile") or agg.get("profile"),
        "shape": pred.get("shape") or agg.get("shape"),
        "pressure": pred.get("pressure") or agg.get("pressure"),
        "fault": pred.get("fault"),
        "manifest_hash": pred.get("manifest_hash"),
        "expectations": pred.get("expectations") or {},
        "endpoints": agg.get("endpoints") or {},
        "censored": bool(censor.get("censored", agg.get("censored", False))),
        "measurement_cap": cap,
        "tainted": bool(proof.get("tainted", False)),
    }


def load_records(paths):
    return [bundle_record(os.path.abspath(p)) for p in paths]


def records_by_cell(records):
    out = {}
    for rec in records:
        if rec["cell_id"]:
            out.setdefault(rec["cell_id"], []).append(rec)
    return out


# ====================================================================== margins ==


def _noise_from_records(records):
    """雙軌 margin 的 noise 軌：以「同 cell 內 replicate 離散度」導出。

    noise margin 一律以**絕對值**表示（2 × pooled stdev），這樣 stall 這種
    均值趨近 0 的 endpoint 也有定義；同時附 relative（2 × median CoV）供報告用。
    """
    by_cell = records_by_cell(records)
    noise = {}
    for endpoint in PRIMARY_ENDPOINTS:
        variances = []
        covs = []
        cells = 0
        all_vals = []
        for _cell, recs in sorted(by_cell.items()):
            vals = [r["endpoints"].get(endpoint) for r in recs]
            vals = [float(v) for v in vals if v is not None]
            all_vals.extend(vals)
            if len(vals) < 2:
                continue
            cells += 1
            sd = stdev(vals)
            if sd is not None:
                variances.append(sd * sd)
            c = cov(vals)
            if c is not None:
                covs.append(c)
        if cells == 0:
            noise[endpoint] = {
                "cells": 0, "pooled_stdev": None, "cov_median": None,
                "cov_max": None, "absolute": None, "relative": None,
                "grand_mean": mean(all_vals), "basis": "insufficient-replicates",
            }
            continue
        pooled_sd = math.sqrt(sum(variances) / len(variances)) if variances else 0.0
        noise[endpoint] = {
            "cells": cells,
            "pooled_stdev": pooled_sd,
            "cov_median": median(covs),
            "cov_max": max(covs) if covs else None,
            "absolute": 2.0 * pooled_sd,
            "relative": (2.0 * median(covs)) if covs else None,
            "grand_mean": mean(all_vals),
            "basis": "within-cell-replicates",
        }
    return noise


def cmd_margins(args):
    results_dir = os.path.abspath(args.results or DEFAULT_RESULTS)
    steady = load_records(args.bundles)
    if not steady:
        die("margins 需要至少一個穩態 bundle")
    fault = load_records(args.fault or [])

    drift = _check_hypotheses_drift(args.hypotheses)
    if drift:
        for ep in drift:
            log("production margin 與 HYPOTHESES.md 不一致：%s" % ep)
        emit("margins: HYPOTHESES-DRIFT %s" % ",".join(sorted(set(drift))))
        return 1
    if drift is None:
        log("找不到 HYPOTHESES.md（%s），略過預註冊門檻漂移檢查" % args.hypotheses)

    noise_steady = _noise_from_records(steady)
    noise_fault = _noise_from_records(fault) if fault else None

    sensitivity = {}
    adequate = 0
    for endpoint in PRIMARY_ENDPOINTS:
        # 故障 cells 的噪音不可直接沿用穩態（plan Task 10）：有 fault 資料就優先取。
        src = "fault"
        n = (noise_fault or {}).get(endpoint) or {}
        if n.get("absolute") is None:
            n = noise_steady.get(endpoint) or {}
            src = "steady"
        ref = n.get("grand_mean")
        prod = production_threshold(endpoint, ref)
        noise_abs = n.get("absolute")
        if noise_abs is None:
            verdict_s = "unknown"
        elif noise_abs >= prod:
            verdict_s = "underpowered"
        else:
            verdict_s = "adequate"
            adequate += 1
        sensitivity[endpoint] = {
            "noise_basis": src,
            "noise_absolute": noise_abs,
            "production_threshold": prod,
            "reference_value": ref,
            "status": verdict_s,
        }

    out = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "production": PRODUCTION_MARGINS,
        "noise_steady": noise_steady,
        "noise_fault": noise_fault,
        "sensitivity": sensitivity,
        "sources": {
            "steady": [r["bundle"] for r in steady],
            "fault": [r["bundle"] for r in fault],
            "hypotheses": args.hypotheses,
        },
    }
    out_path = args.output or os.path.join(results_dir, "margins.json")
    write_json(out_path, out)
    for endpoint in PRIMARY_ENDPOINTS:
        if sensitivity[endpoint]["status"] == "underpowered":
            emit("margins: UNDERPOWERED %s noise=%s production=%s" % (
                endpoint, _fmt(sensitivity[endpoint]["noise_absolute"]),
                _fmt(sensitivity[endpoint]["production_threshold"])))
    emit("margins: OK %d/%d %s" % (adequate, len(PRIMARY_ENDPOINTS), out_path))
    return 0


# ============================================================ prediction freeze ==


def _freeze_path(bundle):
    return os.path.join(bundle, "prediction-freeze.json")


def freeze_prediction(bundle, prediction_file):
    """prediction freeze：寫入後不可變。回 (sha256, created)。"""
    dst = os.path.join(bundle, "prediction.json")
    src_sha = sha256_file(prediction_file)
    frz = read_json(_freeze_path(bundle))
    if os.path.isfile(dst):
        dst_sha = sha256_file(dst)
        if frz and frz.get("sha256") != dst_sha:
            die("prediction 已被竄改：bundle 內容 sha=%s，freeze 記錄 sha=%s"
                % (dst_sha, frz.get("sha256")), code=3)
        if dst_sha != src_sha:
            die("prediction freeze 衝突：bundle 已凍結 sha=%s，來源 sha=%s（不可覆寫）"
                % (dst_sha, src_sha), code=3)
        return (dst_sha, False)
    data = read_json(prediction_file)
    if data is None:
        die("讀不到 prediction 檔：%s" % prediction_file)
    with open(prediction_file, "rb") as fh:
        blob = fh.read()
    with open(dst, "wb") as fh:
        fh.write(blob)
    write_json(_freeze_path(bundle), {
        "schema_version": SCHEMA_VERSION,
        "sha256": src_sha,
        "source": os.path.abspath(prediction_file),
        "frozen_at": utc_now(),
    })
    return (src_sha, True)


def cmd_freeze(args):
    bundle = os.path.abspath(args.bundle)
    if not os.path.isdir(bundle):
        die("bundle 不存在：%s" % bundle)
    sha, created = freeze_prediction(bundle, args.prediction)
    emit("freeze: %s %s" % ("FROZEN" if created else "ALREADY-FROZEN", sha[:16]))
    return 0


# ====================================================================== verdict ==


def cmd_verdict(args):
    if args.cell:
        return _verdict_cell(args)
    if args.group:
        return _verdict_group(args)
    if not args.bundle:
        die("verdict 需要 <bundle>、--cell 或 --group 其中之一")
    return _verdict_replicate(args)


def _verdict_replicate(args):
    bundle = os.path.abspath(args.bundle)
    if not os.path.isdir(bundle):
        die("bundle 不存在：%s" % bundle)
    if args.prediction:
        sha, created = freeze_prediction(bundle, args.prediction)
        if created:
            log("prediction 於 verdict 階段才凍結（pipeline 應在注入前 freeze）")
    else:
        pred_path = os.path.join(bundle, "prediction.json")
        if not os.path.isfile(pred_path):
            die("bundle 內沒有 prediction.json，且未提供 --prediction")
        frz = read_json(_freeze_path(bundle))
        sha = sha256_file(pred_path)
        if frz and frz.get("sha256") != sha:
            die("prediction 已被竄改（freeze sha=%s，實際 sha=%s）"
                % (frz.get("sha256"), sha), code=3)

    rec = bundle_record(bundle)
    if not rec["endpoints"]:
        die("verdict：bundle 缺 aggregate.json（請先跑 aggregate）")

    severity = {}
    for endpoint in PRIMARY_ENDPOINTS:
        s = severity_of(endpoint, rec["endpoints"].get(endpoint))
        if s:
            severity[endpoint] = s

    out = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "scope": "replicate",
        "bundle": bundle,
        "cell_id": rec["cell_id"],
        "group_id": rec["group_id"],
        "profile": rec["profile"],
        "prediction_sha256": sha,
        "endpoints": rec["endpoints"],
        "censored": rec["censored"],
        "censor_basis": "recovery_complete",
        "measurement_cap": rec["measurement_cap"],
        "tainted": rec["tainted"],
        "severity": severity,
        "status": "recorded",
        "note": "三態 verdict 需跨 profile 比較，見 verdict --group",
    }
    write_json(os.path.join(bundle, "verdict.json"), out)
    emit("verdict: RECORDED %s censored=%d cap=%s" % (
        rec["cell_id"] or os.path.basename(bundle),
        1 if rec["censored"] else 0, _fmt(rec["measurement_cap"])))
    return 0


def pool_cell(records):
    """把同 cell 的 replicates 合成 cell 級估計。

    plan §Cap policy：**拒絕合併不同 cap 的 replicates**（標記 → 觸發 extra-n）。
    """
    usable = [r for r in records if not r["tainted"]]
    caps = sorted({r["measurement_cap"] for r in usable if r["measurement_cap"] is not None})
    out = {
        "cell_id": usable[0]["cell_id"] if usable else None,
        "group_id": usable[0]["group_id"] if usable else None,
        "profile": usable[0]["profile"] if usable else None,
        "n": len(usable),
        "n_tainted": len(records) - len(usable),
        "caps": caps,
        "censored_n": sum(1 for r in usable if r["censored"]),
        "bundles": [r["bundle"] for r in usable],
        "pooling": {"status": "pooled", "reason": None},
        "endpoints": {},
        "extra_n_required": False,
    }
    if len(caps) > 1:
        out["pooling"] = {"status": "rejected-cap-mismatch", "reason": "caps=%s" % caps}
        out["extra_n_required"] = True
        return out
    for endpoint in PRIMARY_ENDPOINTS:
        vals = [r["endpoints"].get(endpoint) for r in usable]
        vals = [float(v) for v in vals if v is not None]
        if not vals:
            out["endpoints"][endpoint] = {
                "n": 0, "mean": None, "median": None, "stdev": None,
                "cov": None, "censored": out["censored_n"] > 0,
            }
            continue
        out["endpoints"][endpoint] = {
            "n": len(vals),
            "mean": mean(vals),
            "median": median(vals),
            "stdev": stdev(vals),
            "cov": cov(vals),
            # censored 觀測對 time-to-recovery 只是下界（HYPOTHESES §門檻補充規則）
            "censored": out["censored_n"] > 0 and endpoint == "time_to_recovery_complete_s",
            "lower_bound_only": out["censored_n"] > 0 and endpoint == "time_to_recovery_complete_s",
        }
    return out


def _collect_cell(results_dir, cell_id):
    recs = []
    for cell, _rep, att in iter_done_bundles(results_dir):
        if cell != cell_id:
            continue
        recs.append(bundle_record(att))
    return recs


def _verdict_cell(args):
    results_dir = os.path.abspath(args.results or DEFAULT_RESULTS)
    recs = _collect_cell(results_dir, args.cell)
    if not recs:
        die("找不到 cell %s 的任何 DONE bundle（results=%s）" % (args.cell, results_dir))
    pooled = pool_cell(recs)
    pooled["schema_version"] = SCHEMA_VERSION
    pooled["generated_at"] = utc_now()
    pooled["scope"] = "cell"
    out_path = os.path.join(results_dir, args.cell, "cell-verdict.json")
    write_json(out_path, pooled)
    if pooled["pooling"]["status"] == "rejected-cap-mismatch":
        emit("verdict: CAP-MISMATCH %s %s" % (
            args.cell, ",".join(str(c) for c in pooled["caps"])))
        return 0
    emit("verdict: POOLED %s n=%d censored=%d" % (
        args.cell, pooled["n"], pooled["censored_n"]))
    return 0


def _three_state(endpoint, values, expectation, noise_abs):
    """三態判定 + `indistinguishable` 的 equivalent / underpowered 兩型判別。"""
    profiles = [p for p in sorted(values) if values[p] is not None]
    result = {
        "values": {p: values[p] for p in profiles},
        "pairs": [],
        "verdict": "indistinguishable",
        "indistinguishable_type": None,
        "expectation": expectation,
        "noise_absolute": noise_abs,
    }
    if len(profiles) < 2:
        result["verdict"] = "indistinguishable"
        result["indistinguishable_type"] = "underpowered"
        result["reason"] = "少於兩個 profile 有觀測值"
        return result

    significant = []
    max_threshold = 0.0
    for i in range(len(profiles)):
        for j in range(i + 1, len(profiles)):
            a, b = profiles[i], profiles[j]
            va, vb = float(values[a]), float(values[b])
            ref = (abs(va) + abs(vb)) / 2.0
            threshold = production_threshold(endpoint, ref)
            max_threshold = max(max_threshold, threshold)
            diff = vb - va
            pair = {
                "a": a, "b": b, "value_a": va, "value_b": vb,
                "diff": diff, "abs_diff": abs(diff),
                "relative_diff": (abs(diff) / ref) if ref else None,
                "production_threshold": threshold,
                "significant": abs(diff) >= threshold,
            }
            result["pairs"].append(pair)
            if pair["significant"]:
                significant.append(pair)

    relation = (expectation or {}).get("relation", "indistinguishable")
    order = (expectation or {}).get("order") or []

    if not significant:
        # 差異小於生產門檻 → 是「等效」還是「靈敏度不足」由 noise margin 決定
        if noise_abs is None:
            result["indistinguishable_type"] = "underpowered"
            result["reason"] = "noise margin 未知（margins.json 缺該 endpoint）"
        elif noise_abs >= max_threshold:
            result["indistinguishable_type"] = "underpowered"
            result["reason"] = "noise margin %.6g >= production margin %.6g" % (
                noise_abs, max_threshold)
        else:
            result["indistinguishable_type"] = "equivalent"
            result["reason"] = "觀測差異 < production margin 且 noise margin < production margin"
        result["verdict"] = "confirmed" if relation == "indistinguishable" else "indistinguishable"
        return result

    if relation == "indistinguishable":
        result["verdict"] = "violated"
        result["reason"] = "預測等效，但觀測到超過生產門檻的差異"
        return result

    # relation == "separated"：檢查顯著配對的方向是否與預測 order 一致
    rank = {p: idx for idx, p in enumerate(order)}
    mismatched = []
    for pair in significant:
        ra, rb = rank.get(pair["a"]), rank.get(pair["b"])
        if ra is None or rb is None:
            mismatched.append(pair)
            continue
        expected_sign = 1 if rb > ra else -1
        actual_sign = 1 if pair["diff"] > 0 else -1
        if expected_sign != actual_sign:
            mismatched.append(pair)
    if mismatched:
        result["verdict"] = "violated"
        result["reason"] = "顯著配對方向與預測 order 不符：%s" % [
            "%s<->%s" % (p["a"], p["b"]) for p in mismatched]
    else:
        result["verdict"] = "confirmed"
        result["reason"] = "顯著配對方向全部與預測 order 一致"
    return result


def _verdict_group(args):
    results_dir = os.path.abspath(args.results or DEFAULT_RESULTS)
    margins = read_json(args.margins or os.path.join(results_dir, "margins.json"), {}) or {}
    sensitivity = margins.get("sensitivity") or {}

    by_cell = {}
    expectations = {}
    for cell, _rep, att in iter_done_bundles(results_dir):
        rec = bundle_record(att)
        if rec["group_id"] != args.group:
            continue
        by_cell.setdefault(cell, []).append(rec)
        if rec["expectations"]:
            expectations = rec["expectations"]
    if not by_cell:
        die("找不到 group %s 的任何 DONE bundle" % args.group)

    cells = {}
    profile_values = {}
    rejected = []
    for cell, recs in sorted(by_cell.items()):
        pooled = pool_cell(recs)
        cells[cell] = pooled
        if pooled["pooling"]["status"] != "pooled":
            rejected.append(cell)
            continue
        prof = pooled["profile"]
        for endpoint in PRIMARY_ENDPOINTS:
            val = (pooled["endpoints"].get(endpoint) or {}).get("mean")
            profile_values.setdefault(endpoint, {})[prof] = val

    endpoints = {}
    for endpoint in PRIMARY_ENDPOINTS:
        noise_abs = (sensitivity.get(endpoint) or {}).get("noise_absolute")
        endpoints[endpoint] = _three_state(
            endpoint, profile_values.get(endpoint, {}),
            expectations.get(endpoint), noise_abs)

    out = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "scope": "group",
        "group_id": args.group,
        "cells": cells,
        "endpoints": endpoints,
        "rejected_cells": rejected,
        "margins_source": args.margins or os.path.join(results_dir, "margins.json"),
    }
    out_path = os.path.join(results_dir, "group-verdicts", "%s.json" % args.group)
    write_json(out_path, out)
    for cell in rejected:
        emit("verdict: CAP-MISMATCH %s %s" % (
            cell, ",".join(str(c) for c in cells[cell]["caps"])))
    for endpoint in PRIMARY_ENDPOINTS:
        e = endpoints[endpoint]
        tag = e["verdict"]
        if e["indistinguishable_type"]:
            tag = "%s(%s)" % (tag, e["indistinguishable_type"])
        emit("verdict: %s %s %s" % (args.group, endpoint, tag))
    return 0


# ================================================================= need-more-n ==

MAX_N = 5


def read_amendments(results_dir):
    """讀 Task 4 的 append-only journal（JSONL）。

    介面契約（plan Task 4）：每筆 `{schema_version, type, key, value, source, seq}`，
    type ∈ {extra-replicates, cap-update, rescue-replicate, needs-human}。
    本檔只**讀**這個視圖，寫入一律交給 `manifest.py amend`。
    """
    path = os.path.join(results_dir, "schedule-amendments.json")
    entries = []
    if not os.path.isfile(path):
        return entries
    with open(path, "r") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except ValueError:
                # 與 manifest.py::load_amendments 一致：journal 是唯一持久 SoT，
                # 靜默略過會讓 audit 報出「看起來完整」的殘缺視圖。
                die("amendments journal 第 %d 行不是合法 JSON（%s）" % (lineno, path))
    return entries


def _amend_line(atype, key, value, source):
    return json.dumps({
        "schema_version": SCHEMA_VERSION,
        "type": atype,
        "key": key,
        "value": value,
        "source": source,
    }, ensure_ascii=False, sort_keys=True)


def cmd_need_more_n(args):
    results_dir = os.path.abspath(args.results or DEFAULT_RESULTS)
    recs = _collect_cell(results_dir, args.cell)
    if not recs:
        die("找不到 cell %s 的任何 DONE bundle" % args.cell)
    usable = [r for r in recs if not r["tainted"]]
    n_now = len(usable)
    journal = read_amendments(results_dir)
    extra_already = sum(
        int(e.get("value") or 0) for e in journal
        if e.get("type") == "extra-replicates" and e.get("key") == args.cell)
    rescued = any(e.get("type") == "rescue-replicate" and e.get("key") == args.cell
                  for e in journal)
    censored_n = sum(1 for r in usable if r["censored"])
    caps = sorted({r["measurement_cap"] for r in usable if r["measurement_cap"] is not None})

    decision = {
        "schema_version": SCHEMA_VERSION,
        "cell_id": args.cell,
        "n_now": n_now,
        "extra_already": extra_already,
        "censored_n": censored_n,
        "caps": caps,
        "max_n": MAX_N,
        "path": None,
        "extra": 0,
        "amendments": [],
    }

    # 1) 含 censored 觀測 → CoV 無定義，**不走 CoV 升級**（plan Task 10 明文）
    if censored_n > 0:
        decision["path"] = "censored-no-cov-upgrade"
        emit("need-more-n: CENSORED-NO-COV-UPGRADE %s censored=%d" % (args.cell, censored_n))
        # 雙 censored 自救：同 cell 兩 replicate 皆 censored → 一次 cap×2 加跑（每 cell 限一次）
        if censored_n >= 2 and not rescued:
            base_cap = max(caps) if caps else None
            if base_cap is None:
                emit("need-more-n: RESCUE-BLOCKED %s 無 measurement_cap 記錄" % args.cell)
            else:
                new_cap = int(base_cap) * 2
                decision["path"] = "double-censored-rescue"
                decision["rescue_cap"] = new_cap
                decision["amendments"].append(
                    _amend_line("rescue-replicate", args.cell, {"cap": new_cap},
                                "verdict.py need-more-n"))
                emit("need-more-n: RESCUE-CAP %s %d" % (args.cell, new_cap))
        elif censored_n >= 2 and rescued:
            emit("need-more-n: RESCUE-ALREADY-ISSUED %s" % args.cell)
        _finish_need_more_n(results_dir, args, decision)
        return 0

    # 2) 不同 cap 的 replicates 不可合併 → 補一個同 cap 樣本
    if len(caps) > 1:
        decision["path"] = "cap-mismatch"
        extra = 1 if (n_now + extra_already) < MAX_N else 0
        decision["extra"] = extra
        if extra:
            decision["amendments"].append(
                _amend_line("extra-replicates", args.cell, extra, "verdict.py cap-mismatch"))
            emit("need-more-n: CAP-MISMATCH %s %s extra=%d" % (
                args.cell, ",".join(str(c) for c in caps), extra))
        else:
            emit("need-more-n: CAP-MISMATCH %s %s extra=0 已達 n=%d 上限" % (
                args.cell, ",".join(str(c) for c in caps), MAX_N))
        _finish_need_more_n(results_dir, args, decision)
        return 0

    # 3) CoV 升級：與 margins.json 的 noise margin（relative）比較
    margins = read_json(args.margins or os.path.join(results_dir, "margins.json"), {}) or {}
    noise = margins.get("noise_steady") or {}
    over = []
    for endpoint in PRIMARY_ENDPOINTS:
        vals = [r["endpoints"].get(endpoint) for r in usable]
        vals = [float(v) for v in vals if v is not None]
        c = cov(vals)
        limit = (noise.get(endpoint) or {}).get("relative")
        if c is None or limit is None:
            continue
        if c > limit:
            over.append({"endpoint": endpoint, "cov": c, "noise_relative": limit})
    decision["over_margin"] = over
    if not over:
        decision["path"] = "within-margin"
        emit("need-more-n: OK %s n=%d" % (args.cell, n_now))
        _finish_need_more_n(results_dir, args, decision)
        return 0

    decision["path"] = "cov-upgrade"
    room = MAX_N - (n_now + extra_already)
    extra = 1 if room > 0 else 0
    decision["extra"] = extra
    if extra:
        decision["amendments"].append(
            _amend_line("extra-replicates", args.cell, extra, "verdict.py cov-upgrade"))
        emit("need-more-n: EXTRA %s %d cov_over=%s" % (
            args.cell, extra, ",".join(o["endpoint"] for o in over)))
    else:
        emit("need-more-n: CAPPED %s n=%d 已達上限 %d" % (args.cell, n_now + extra_already, MAX_N))
    _finish_need_more_n(results_dir, args, decision)
    return 0


def _finish_need_more_n(results_dir, args, decision):
    write_json(os.path.join(results_dir, args.cell, "need-more-n.json"), decision)
    if args.emit_amend:
        for line in decision["amendments"]:
            emit(line)


# ============================================================== baseline-check ==

BASELINE_ACHIEVE_MIN = 0.85
BASELINE_P99_TOLERANCE = 0.15
FIXED_RATE_PRESSURES = ("low", "mid", "high")


def _calibration_target(cal, shape, pressure):
    """取該 (shape, pressure) 的目標速率。

    **嚴禁**拿固定速率 cell 的 achieved 去比 ceiling（plan Task 10 / v4.2.1 N2）：
    低/中/高壓本來就只跑 25/50/80% ceiling，比 ceiling 會恆超標、把 campaign 卡死。
    """
    shapes = cal.get("shapes") or {}
    entry = shapes.get(shape) or {}
    if pressure in FIXED_RATE_PRESSURES:
        rates = entry.get("rates") or {}
        target = rates.get(pressure)
        if target is None:
            return (None, "calibration.json 缺 %s/%s 的固定速率" % (shape, pressure))
        ceiling = entry.get("ceiling_iops")
        if ceiling is not None and abs(float(target) - float(ceiling)) < 1e-9:
            return (None, "固定速率 cell 的 target 等於 ceiling（禁止的比較基準）")
        return (float(target), None)
    # 極端壓 = closed-loop，目標就是 ceiling 本身
    ceiling = entry.get("ceiling_iops")
    if ceiling is None:
        return (None, "calibration.json 缺 %s 的 ceiling_iops" % shape)
    return (float(ceiling), None)


def _reference_p99(cal, shape, pressure):
    entry = (cal.get("shapes") or {}).get(shape) or {}
    refs = entry.get("reference_p99_ns") or entry.get("ref_p99_ns") or {}
    val = refs.get(pressure)
    return float(val) if val is not None else None


BASELINE_REF_MIN_SAMPLES = 3


def _prior_baselines(results_dir, shape, pressure, exclude=None):
    """同 (shape, pressure) 先前所有 replicate 的 baseline p99（升冪）。"""
    out = []
    pat = os.path.join(results_dir, "*", "r*", "attempts", "*", "baseline.json")
    for path in sorted(glob.glob(pat)):
        if exclude and os.path.dirname(path) == exclude.rstrip("/"):
            continue
        doc = read_json(path, {}) or {}
        if doc.get("shape") != shape or doc.get("pressure") != pressure:
            continue
        v = doc.get("p99_ns")
        if isinstance(v, (int, float)) and v > 0:
            out.append(float(v))
    return sorted(out)


def cmd_baseline_check(args):
    bundle = os.path.abspath(args.bundle)
    results_dir = os.path.abspath(args.results or DEFAULT_RESULTS)
    baseline = read_json(os.path.join(bundle, "baseline.json"))
    if baseline is None:
        die("baseline-check：bundle 缺 baseline.json（60s 復測）")
    cal_path = args.calibration or os.path.join(results_dir, "calibration.json")
    cal = read_json(cal_path)
    if cal is None:
        die("baseline-check：找不到 calibration.json（%s）" % cal_path)

    pred = read_json(os.path.join(bundle, "prediction.json"), {}) or {}
    shape = baseline.get("shape") or pred.get("shape")
    pressure = baseline.get("pressure") or pred.get("pressure")
    cell_id = pred.get("cell_id")
    if not shape or not pressure:
        die("baseline-check：無法判定 shape/pressure")

    target = baseline.get("target_iops")
    if target is None:
        target, err = _calibration_target(cal, shape, pressure)
        if target is None:
            emit("baseline-check: BAD-TARGET %s" % err)
            return 2
    else:
        # 即使 bundle 自帶 target，也要擋掉「固定速率 cell 的 target = ceiling」
        _t, err = _calibration_target(cal, shape, pressure)
        if err and pressure in FIXED_RATE_PRESSURES:
            emit("baseline-check: BAD-TARGET %s" % err)
            return 2
        target = float(target)

    achieved = baseline.get("achieved_iops")
    p99 = baseline.get("p99_ns")
    # 參考 p99 優先取 **campaign 自己先前同 (shape, pressure) 的 baseline 中位數**，
    # 不是校準值。真機實測：所有 baseline 對校準值都是正偏移（+5.6%～+17.1%，均值
    # 約 13%），呈系統性而非隨機——校準跑在 precondition 剛結束、且當時沒有 sampler／
    # collector 在跑，條件與 campaign 期間不同。拿條件不同的兩者比，會把固定落差誤判
    # 成漂移（實際就觸發了 3 連續超標而停佇列，但同期吞吐是校準天花板的 109–111%，
    # 叢集根本沒有變慢）。同條件比較才問得出「叢集有沒有隨時間漂移」。
    prior = _prior_baselines(results_dir, shape, pressure, exclude=bundle)
    if len(prior) >= BASELINE_REF_MIN_SAMPLES:
        ref_p99 = statistics.median(prior)
        ref_source = "campaign-median(n=%d)" % len(prior)
    else:
        ref_p99 = _reference_p99(cal, shape, pressure)
        ref_source = "calibration"

    signals = []
    achieve_ratio = None
    if achieved is not None and target:
        achieve_ratio = float(achieved) / float(target)
        if achieve_ratio < BASELINE_ACHIEVE_MIN:
            signals.append(("achieve-ratio", (achieve_ratio - 1.0) * 100.0))
    p99_shift = None
    if p99 is not None and ref_p99:
        p99_shift = (float(p99) - ref_p99) / ref_p99
        if abs(p99_shift) > BASELINE_P99_TOLERANCE:
            signals.append(("baseline-p99", p99_shift * 100.0))

    state_path = os.path.join(results_dir, "baseline-drift-state.json")
    state = read_json(state_path, {"consecutive": 0, "recent": []}) or {
        "consecutive": 0, "recent": []}
    if signals:
        state["consecutive"] = int(state.get("consecutive", 0)) + 1
        state["recent"] = (state.get("recent") or [])[-4:] + [bundle]
    else:
        state["consecutive"] = 0
        state["recent"] = []
    state["updated_at"] = utc_now()
    write_json(state_path, state)

    out = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "bundle": bundle,
        "cell_id": cell_id,
        "shape": shape,
        "pressure": pressure,
        "target_iops": target,
        "achieved_iops": achieved,
        "achieve_ratio": achieve_ratio,
        "achieve_ratio_min": BASELINE_ACHIEVE_MIN,
        "baseline_p99_ns": p99,
        "reference_p99_ns": ref_p99,
        "reference_source": ref_source,
        "p99_shift": p99_shift,
        "p99_tolerance": BASELINE_P99_TOLERANCE,
        "drift_signals": [s[0] for s in signals],
        "consecutive_drift": state["consecutive"],
        "covariate": True,
        "calibration": cal_path,
    }
    write_json(os.path.join(bundle, "baseline-check.json"), out)

    for metric, pct in signals:
        emit("baseline-drift %s %.2f" % (metric, pct))
    if state["consecutive"] >= 3:
        emit("baseline-check: HUMAN-NEEDED recalibrate %d" % state["consecutive"])
        return 4
    if signals:
        emit("baseline-check: DRIFT %d covariate" % len(signals))
        return 0
    emit("baseline-check: OK")
    return 0


# ====================================================================== schemas ==


def cmd_schemas(args):
    kind = args.kind
    if kind not in SCHEMAS:
        die("未知的 bundle kind：%s（可用：%s）" % (kind, ", ".join(sorted(SCHEMAS))), code=2)
    spec = SCHEMAS[kind]
    if args.verify:
        return _verify_bundle(args.verify, kind, args)
    if args.json:
        emit(json.dumps({"kind": kind, "schema_version": spec["version"],
                         "files": spec["files"]}, ensure_ascii=False, sort_keys=True))
        return 0
    emit("# schema_version=%d kind=%s" % (spec["version"], kind))
    for f in spec["files"]:
        emit(f)
    return 0


def _verify_bundle(bundle, kind, args):
    """schema 的交叉核對模式：cell/profile/manifest-hash/時間窗一致性。"""
    bundle = os.path.abspath(bundle)
    spec = SCHEMAS[kind]
    problems = []
    for f in spec["files"]:
        p = os.path.join(bundle, f)
        if not os.path.isfile(p) or os.path.getsize(p) == 0:
            problems.append("缺件或空檔：%s" % f)
    if problems:
        emit("schemas: MISMATCH %s %s" % (kind, problems[0]))
        return 1

    pred = read_json(os.path.join(bundle, "prediction.json"), {}) or {}
    agg = read_json(os.path.join(bundle, "aggregate.json"), {}) or {}
    vrd = read_json(os.path.join(bundle, "verdict.json"), {}) or {}

    for field in ("cell_id", "profile"):
        if not pred.get(field):
            problems.append("prediction.json 缺 %s" % field)
            continue
        if agg.get(field) and agg.get(field) != pred.get(field):
            problems.append("%s 不一致：prediction=%s aggregate=%s"
                            % (field, pred.get(field), agg.get(field)))
        if vrd.get(field) and vrd.get(field) != pred.get(field):
            problems.append("%s 不一致：prediction=%s verdict=%s"
                            % (field, pred.get(field), vrd.get(field)))

    frz = read_json(_freeze_path(bundle))
    actual_sha = sha256_file(os.path.join(bundle, "prediction.json"))
    if frz and frz.get("sha256") != actual_sha:
        problems.append("prediction freeze sha 不符（已被竄改）")
    if vrd.get("prediction_sha256") and vrd["prediction_sha256"] != actual_sha:
        problems.append("verdict.json 記錄的 prediction sha 與實際不符")

    expected_hash = args.manifest_hash
    if expected_hash and pred.get("manifest_hash") != expected_hash:
        problems.append("manifest_hash 不符：bundle=%s 期望=%s"
                        % (pred.get("manifest_hash"), expected_hash))

    if kind != "steady":
        proof = read_json(os.path.join(bundle, "coverage-proof.json"), {}) or {}
        win = proof.get("window") or {}
        agg_win = (agg.get("coverage") or {}).get("window") or {}
        if win.get("start") is not None and agg_win.get("start") is not None:
            if int(agg_win["start"]) < int(win["start"]) or \
                    int(agg_win["end"]) > int(win["end"]):
                problems.append("aggregate 時間窗超出 coverage-proof 宣告的量測窗")
        if proof.get("tainted"):
            problems.append("coverage-proof 標記 tainted，不得 finalize 為有效 replicate")

    if problems:
        for p in problems:
            log("schema 交叉核對：%s" % p)
        emit("schemas: MISMATCH %s %s" % (kind, problems[0]))
        return 1
    emit("schemas: OK %s %s" % (kind, bundle))
    return 0


# ============================================================ schedule-estimate ==

DEFAULT_CAP = 2700
# 每個 execution 的固定管銷（preflight + fio ramp + final_clean + baseline 復測）
PER_EXECUTION_OVERHEAD_S = 900


def _percentile(vals, pct):
    vals = sorted(float(v) for v in vals if v is not None)
    if not vals:
        return None
    if len(vals) == 1:
        return vals[0]
    idx = (len(vals) - 1) * (pct / 100.0)
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return vals[lo]
    return vals[lo] + (vals[hi] - vals[lo]) * (idx - lo)


def cmd_schedule_estimate(args):
    results_dir = os.path.abspath(args.results or DEFAULT_RESULTS)
    recs = load_records(args.bundles)
    if not recs:
        die("schedule-estimate 需要至少一個 pilot bundle")

    by_fault = {}
    for rec in recs:
        fault = rec["fault"] or "unknown"
        by_fault.setdefault(fault, []).append(rec)

    faults = {}
    exit_code = 0
    for fault, group in sorted(by_fault.items()):
        censored = [r for r in group if r["censored"]]
        caps = sorted({r["measurement_cap"] for r in group
                       if r["measurement_cap"] is not None})
        entry = {
            "n_pilots": len(group),
            "caps": caps,
            "censored_n": len(censored),
            "p50_recovery_s": None,
            "p95_recovery_s": None,
            "recommended_cap": None,
            "status": None,
            "bundles": [r["bundle"] for r in group],
        }
        if censored:
            # censored pilot 的 recovery 值只是下界 → **禁止**餵進 2× 公式
            cap = caps[-1] if caps else DEFAULT_CAP
            entry["status"] = "pilot-censored"
            entry["recommended_cap"] = None
            entry["human_gate"] = "以 cap×2 重跑 pilot，或人工指定 cap（決策記入 journal）"
            entry["cap_x2_suggestion"] = int(cap) * 2
            faults[fault] = entry
            emit("schedule-estimate: PILOT-CENSORED %s %s" % (fault, cap))
            exit_code = 5
            continue
        vals = [r["endpoints"].get("time_to_recovery_complete_s") for r in group]
        vals = [v for v in vals if v is not None]
        if not vals:
            entry["status"] = "no-recovery-observation"
            faults[fault] = entry
            emit("schedule-estimate: NO-DATA %s" % fault)
            exit_code = max(exit_code, 6)
            continue
        p50 = _percentile(vals, 50.0)
        p95 = _percentile(vals, 95.0)
        entry["p50_recovery_s"] = p50
        entry["p95_recovery_s"] = p95
        entry["recommended_cap"] = int(max(DEFAULT_CAP, round(2.0 * max(vals))))
        entry["status"] = "ok"
        faults[fault] = entry
        emit("schedule-estimate: cap-update %s %d" % (fault, entry["recommended_cap"]))
        emit(_amend_line("cap-update", fault, entry["recommended_cap"],
                         "verdict.py schedule-estimate"))

    remaining = args.remaining_executions
    total_s = None
    if remaining:
        usable = [e["p50_recovery_s"] for e in faults.values()
                  if e.get("p50_recovery_s") is not None]
        if usable:
            total_s = (mean(usable) + PER_EXECUTION_OVERHEAD_S) * remaining

    out = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "default_cap": DEFAULT_CAP,
        "per_execution_overhead_s": PER_EXECUTION_OVERHEAD_S,
        "faults": faults,
        "remaining_executions": remaining,
        "estimated_remaining_hours": (total_s / 3600.0) if total_s else None,
    }
    write_json(os.path.join(results_dir, "schedule-estimate.json"), out)
    if total_s:
        emit("schedule-estimate: OK %.1fh" % (total_s / 3600.0))
    elif exit_code == 0:
        emit("schedule-estimate: OK")
    return exit_code


# ======================================================================== audit ==


def load_manifest(path):
    """Task 4 `manifest.py generate` 的產物。

    介面契約（plan Task 4）：cells 為 `{cell_id, group_id, profile, shape, pressure,
    fault, fault_params, base_n, targets}`；容忍 `{"cells":[...]}` 與裸 list 兩種外框。
    """
    data = read_json(path)
    if data is None:
        return None, None
    if isinstance(data, list):
        return data, None
    cells = data.get("cells")
    if cells is None:
        return None, None
    return cells, data


def cmd_audit(args):
    results_dir = os.path.abspath(args.results_dir)
    if not os.path.isdir(results_dir):
        die("results 目錄不存在：%s" % results_dir)
    manifest_path = args.manifest or os.path.join(results_dir, "manifest.json")
    cells, manifest_doc = load_manifest(manifest_path)
    if cells is None:
        die("讀不到 manifest（%s）——audit 需要它才能算齊備度" % manifest_path)
    # manifest.py 自己發布的 manifest_hash 是「cells 內容」的 hash，跨重新產生穩定；
    # 檔案級 sha256 會因 generated_at 變動而失效，只在 manifest 未發布時當 fallback。
    manifest_hash = (manifest_doc or {}).get("manifest_hash") or sha256_file(manifest_path)

    journal = read_amendments(results_dir)
    extra_by_cell = {}
    rescue_by_cell = {}
    cap_updates = {}
    needs_human = []
    for e in journal:
        etype, key, value = e.get("type"), e.get("key"), e.get("value")
        if etype == "extra-replicates":
            extra_by_cell[key] = extra_by_cell.get(key, 0) + int(value or 0)
        elif etype == "rescue-replicate":
            rescue_by_cell[key] = rescue_by_cell.get(key, 0) + 1
        elif etype == "cap-update":
            cap_updates[key] = value
        elif etype == "needs-human":
            needs_human.append({"key": key, "reason": value})

    descope = read_json(os.path.join(results_dir, "descope.json"), {}) or {}
    descoped = {d.get("cell_id"): d.get("reason") for d in (descope.get("cells") or [])}

    expected = {}
    base_total = 0
    for c in cells:
        cid = c.get("cell_id")
        base_n = int(c.get("base_n") or 0)
        base_total += base_n
        expected[cid] = {
            "base_n": base_n,
            "extra": extra_by_cell.get(cid, 0) + rescue_by_cell.get(cid, 0),
            "group_id": c.get("group_id"),
            "profile": c.get("profile"),
            "fault": c.get("fault"),
        }
    expected_total = sum(v["base_n"] + v["extra"] for v in expected.values())

    done = {}
    duplicates = []
    censored_list = []
    tainted_list = []
    unknown_cells = []
    for cell, rep, att in iter_done_bundles(results_dir):
        done.setdefault(cell, {}).setdefault(rep, []).append(att)
        rec = bundle_record(att)
        if rec["censored"]:
            censored_list.append({"cell_id": cell, "replicate": rep, "bundle": att})
        if rec["tainted"]:
            tainted_list.append({"cell_id": cell, "replicate": rep, "bundle": att})
        if cell not in expected:
            unknown_cells.append({"cell_id": cell, "replicate": rep, "bundle": att})
        if rec["manifest_hash"] and rec["manifest_hash"] != manifest_hash:
            tainted_list.append({"cell_id": cell, "replicate": rep, "bundle": att,
                                 "reason": "manifest_hash 不符"})

    done_total = 0
    missing = []
    for cid, exp in sorted(expected.items()):
        reps = done.get(cid, {})
        n_done = len(reps)
        done_total += n_done
        for rep, atts in sorted(reps.items()):
            if len(atts) > 1:
                duplicates.append({"cell_id": cid, "replicate": rep,
                                   "attempts": atts})
        want = exp["base_n"] + exp["extra"]
        if n_done < want:
            missing.append({"cell_id": cid, "have": n_done, "want": want,
                            "descoped": cid in descoped})

    summary = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "results_dir": results_dir,
        "manifest": manifest_path,
        "manifest_hash": manifest_hash,
        "cells_expected": len(expected),
        "executions_base": base_total,
        "executions_expected": expected_total,
        "executions_done": done_total,
        "missing": missing,
        "duplicates": duplicates,
        "censored": censored_list,
        "tainted": tainted_list,
        "needs_human": needs_human,
        "descoped": descoped,
        "unknown_cells": unknown_cells,
        "cap_updates": cap_updates,
    }
    write_json(os.path.join(results_dir, "audit.json"), summary)

    out_dir = os.path.abspath(args.out_dir or EXP_ROOT)
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    md_path = os.path.join(out_dir, "EVIDENCE-SUMMARY-%s.md" % date)
    _write_evidence_summary(md_path, summary, manifest_doc)

    complete = (not missing) and (not duplicates) and (not unknown_cells)
    emit("audit: %d/%d cells=%d missing=%d duplicate=%d censored=%d tainted=%d "
         "needs-human=%d descope=%d" % (
             done_total, expected_total, len(expected), len(missing), len(duplicates),
             len(censored_list), len(tainted_list), len(needs_human), len(descoped)))
    emit("audit: %s %s" % ("OK" if complete else "INCOMPLETE", md_path))
    return 0 if complete else 1


def _md_rows(rows):
    return "\n".join(rows) if rows else "_（無）_"


def _write_evidence_summary(path, s, manifest_doc):
    lines = []
    lines.append("---")
    lines.append("layout: doc")
    lines.append("title: ceph-mclock-profiles evidence summary %s" % s["generated_at"][:10])
    lines.append("---")
    lines.append("")
    lines.append("# Evidence Summary — ceph-mclock-profiles")
    lines.append("")
    lines.append("> 由 `lib/verdict.py audit` 自動產生（唯讀）；資料集封閉後執行。")
    lines.append("")
    lines.append("| 項目 | 值 |")
    lines.append("|---|---|")
    lines.append("| 產生時間（UTC） | %s |" % s["generated_at"])
    lines.append("| results 目錄 | `%s` |" % s["results_dir"])
    lines.append("| manifest | `%s` |" % s["manifest"])
    lines.append("| manifest sha256 | `%s` |" % s["manifest_hash"][:16])
    lines.append("| cells（manifest） | %d |" % s["cells_expected"])
    lines.append("| executions（base） | %d |" % s["executions_base"])
    lines.append("| executions（base + amendments） | %d |" % s["executions_expected"])
    lines.append("| executions（DONE） | %d |" % s["executions_done"])
    lines.append("")

    lines.append("## 缺件（未達預期 replicate 數）")
    lines.append("")
    if s["missing"]:
        lines.append("| cell | 已完成 | 應完成 | 已 descope |")
        lines.append("|---|---|---|---|")
        for m in s["missing"]:
            lines.append("| `%s` | %d | %d | %s |" % (
                m["cell_id"], m["have"], m["want"], "是" if m["descoped"] else "否"))
    else:
        lines.append("_（無）_")
    lines.append("")

    lines.append("## duplicate finalization（同一 replicate 多個 DONE attempt）")
    lines.append("")
    lines.append(_md_rows(["- `%s` / `%s`：%d 個 attempt" % (
        d["cell_id"], d["replicate"], len(d["attempts"])) for d in s["duplicates"]]))
    lines.append("")

    lines.append("## right-censored 觀測（`time-to-recovery-complete > cap`，有效資料）")
    lines.append("")
    lines.append(_md_rows(["- `%s` / `%s`" % (c["cell_id"], c["replicate"])
                           for c in s["censored"]]))
    lines.append("")

    lines.append("## tainted（不得作為有效 replicate）")
    lines.append("")
    lines.append(_md_rows(["- `%s` / `%s`%s" % (
        t["cell_id"], t["replicate"],
        "（%s）" % t["reason"] if t.get("reason") else "") for t in s["tainted"]]))
    lines.append("")

    lines.append("## needs-human（taint 重試預算耗盡，佇列已跳過）")
    lines.append("")
    lines.append(_md_rows(["- `%s`：%s" % (n["key"], n["reason"]) for n in s["needs_human"]]))
    lines.append("")

    lines.append("## descope")
    lines.append("")
    lines.append(_md_rows(["- `%s`：%s" % (k, v) for k, v in sorted(s["descoped"].items())]))
    lines.append("")

    if s["unknown_cells"]:
        lines.append("## manifest 沒有的 cell（孤兒 bundle）")
        lines.append("")
        lines.append(_md_rows(["- `%s` / `%s`" % (u["cell_id"], u["replicate"])
                               for u in s["unknown_cells"]]))
        lines.append("")

    if s["cap_updates"]:
        lines.append("## measurement_cap 修訂（journal `cap-update`）")
        lines.append("")
        lines.append("| fault | cap（秒） |")
        lines.append("|---|---|")
        for k, v in sorted(s["cap_updates"].items()):
            lines.append("| `%s` | %s |" % (k, v))
        lines.append("")

    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.rename(tmp, path)


# ========================================================================= main ==


def build_parser():
    p = argparse.ArgumentParser(prog="verdict.py", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd")

    a = sub.add_parser("aggregate")
    a.add_argument("bundle")
    a.add_argument("--validate-schema", action="store_true")
    a.add_argument("--brownout-threshold", type=float, default=1.0,
                   help="brownout 判定的秒數門檻（該秒 hist p99 > 此值）")
    a.add_argument("--min-seconds", type=int, default=30,
                   help="--validate-schema 時要求的最少逐秒樣本數")
    a.set_defaults(func=cmd_aggregate)

    m = sub.add_parser("margins")
    m.add_argument("bundles", nargs="+")
    m.add_argument("--fault", nargs="*", default=[])
    m.add_argument("-o", "--output")
    m.add_argument("--results")
    m.add_argument("--hypotheses", default=DEFAULT_HYPOTHESES)
    m.set_defaults(func=cmd_margins)

    f = sub.add_parser("freeze")
    f.add_argument("bundle")
    f.add_argument("--prediction", required=True)
    f.set_defaults(func=cmd_freeze)

    v = sub.add_parser("verdict")
    v.add_argument("bundle", nargs="?")
    v.add_argument("--prediction")
    v.add_argument("--cell")
    v.add_argument("--group")
    v.add_argument("--results")
    v.add_argument("--margins")
    v.set_defaults(func=cmd_verdict)

    n = sub.add_parser("need-more-n")
    n.add_argument("cell")
    n.add_argument("--results")
    n.add_argument("--margins")
    n.add_argument("--emit-amend", action="store_true",
                   help="把要送給 manifest.py amend 的 journal 行印到 stdout")
    n.set_defaults(func=cmd_need_more_n)

    b = sub.add_parser("baseline-check")
    b.add_argument("bundle")
    b.add_argument("--results")
    b.add_argument("--calibration")
    b.set_defaults(func=cmd_baseline_check)

    s = sub.add_parser("schemas")
    s.add_argument("kind")
    s.add_argument("--json", action="store_true")
    s.add_argument("--verify")
    s.add_argument("--manifest-hash")
    s.set_defaults(func=cmd_schemas)

    e = sub.add_parser("schedule-estimate")
    e.add_argument("bundles", nargs="+")
    e.add_argument("--results")
    e.add_argument("--remaining-executions", type=int)
    e.set_defaults(func=cmd_schedule_estimate)

    au = sub.add_parser("audit")
    au.add_argument("results_dir")
    au.add_argument("--manifest")
    au.add_argument("--out-dir")
    au.set_defaults(func=cmd_audit)
    return p


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "cmd", None):
        parser.print_help(sys.stderr)
        return 2
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
