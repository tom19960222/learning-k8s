#!/usr/bin/env python3
"""lib/manifest.py — 實驗矩陣（63 cells / 147 executions）的產生器與排程消費者（Task 4）。

子命令：
  generate  依 inventory 產生 `results/manifest.json`（63 cells；`--assert` 驗 63/147）
  schedule  印出完整 execution 排程（JSONL，含 amendments 展開）
  next      印出下一個待執行 execution（單行 JSON）；佇列耗盡 exit 3
  amend     append-only 寫入 `results/schedule-amendments.json`（四型，tmp+mv 原子）
  view      印出 merge 視圖（`next` 與 audit 共用同一語意）
  pilots    印出每故障型的 pilot execution（預期最慢組合的 r1）

設計要點（plan Task 4 / §Replicate Pipeline / §Cap policy）：
- group = 排除 profile 的 treatment 組合（shape × pressure × fault）；cell_id = <group_id>+<profile>。
- targets 綁 group：同一 group 內全部 executions 用同一 target，輪替只發生在 group 之間，
  避免 profile 對照被 target 異質性污染（v4.2/F5-6）。
- Latin square：`LATIN[(group_index + replicate_n) % 3]` 決定該 group-replicate 的起始 profile，
  position p 的 profile = `LATIN[(group_index + replicate_n + p) % 3]`。
- cap policy：cap-update 只影響尚未執行者；已執行者的 cap 以 bundle 為準（本模組回報
  `measurement_cap_source="bundle"`，不追溯改寫）；rescue-replicate 攜帶自己的 cap。
- 完成判定用 replicate 級 DONE（`results/<cell>/<rN>/DONE`，由 common.sh 的 bundle_finalize 寫入），
  不遞迴 attempts/。

家規：標準庫 only；stdout 只放機器要抓的行，log/警告一律 stderr。
"""

import argparse
import copy
import hashlib
import json
import os
import sys
import tempfile
import time

SCHEMA_VERSION = 1
AMEND_SCHEMA_VERSION = 1

# profile 順序即 Latin square 的 base order（不可任意更動，會改變全 campaign 排程）
PROFILES = ("balanced", "high_client_ops", "high_recovery_ops")
LATIN = PROFILES

# 壓力等級（spec §4）：低/中/高 = ceiling 的 25/50/80% 固定速率；極端 = 不限速閉迴路
PRESSURES_STEADY = ("low", "mid", "high", "extreme")
PRESSURES_FAULT = ("low", "mid", "extreme")
PRESSURE_RANK = {"low": 0, "mid": 1, "high": 2, "extreme": 3}

SHAPE_4K = "4k"      # 4K randrw 70/30
SHAPE_SEQ = "seq"    # 1M seq write

# §Cap policy：pilot 前的預設 measurement cap；guard 必須至少晚 600s
DEFAULT_MEASUREMENT_CAP = 2700
GUARD_MARGIN_SECS = 600
CHAOS_SEED = 4242
CHAOS_DURATION_SECS = 1800

# pilot / cap-update 適用的故障型（chaos 無 cap，不在此列）
FAULT_TYPES = ("flapping", "osd-down", "node-isolation", "rack-isolation", "seq-contention")
AMEND_TYPES = ("extra-replicates", "cap-update", "rescue-replicate", "needs-human")

AMENDMENTS_BASENAME = "schedule-amendments.json"
MANIFEST_BASENAME = "manifest.json"

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
_ROOT_DIR = os.path.dirname(_LIB_DIR)


def log(msg):
    sys.stderr.write("[manifest] %s\n" % msg)


def fail(msg, code=1):
    sys.stderr.write("[manifest] FATAL: %s\n" % msg)
    sys.exit(code)


def default_results_dir():
    return os.environ.get("RESULTS_DIR") or os.path.join(_ROOT_DIR, "results")


def default_inventory():
    return os.environ.get("INVENTORY_JSON") or os.path.join(_ROOT_DIR, "azure", "inventory.json")


# --- inventory ---------------------------------------------------------------


def load_osd_nodes(path):
    """回傳 [{"node":..., "rack":...}]（inventory 原順序）；結構不符即 die。

    只取 target 指派需要的欄位；完整驗證仍由 lib/inventory.sh 負責，這裡重驗
    8 OSD / 4 rack × 2 是為了「targets 綁 group」的輪替不會靜默失衡。
    """
    if not os.path.isfile(path):
        fail("inventory 不存在：%s" % path)
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except ValueError as exc:
        fail("inventory JSON 無法解析：%s" % exc)
    nodes = doc.get("nodes") if isinstance(doc, dict) else None
    if not isinstance(nodes, list):
        fail("inventory 缺 nodes 陣列：%s" % path)

    osds = []
    racks = {}
    for node in nodes:
        if not isinstance(node, dict) or node.get("role") != "osd":
            continue
        name = (node.get("name") or "").strip()
        rack = (node.get("rack") or "").strip()
        if not name or not rack:
            fail("OSD node 缺 name 或 rack：%r" % (node,))
        osds.append({"node": name, "rack": rack})
        racks.setdefault(rack, []).append(name)

    if len(osds) != 8:
        fail("OSD node 數量 %d，期望 8" % len(osds))
    if len(racks) != 4:
        fail("rack 數量 %d，期望 4" % len(racks))
    for rack in sorted(racks):
        if len(racks[rack]) != 2:
            fail("rack %s 有 %d 台 OSD node，期望 2" % (rack, len(racks[rack])))
    return osds


# --- 矩陣定義（spec §5）------------------------------------------------------


def group_specs():
    """21 個 group（= 63 cells / 3 profiles）；順序即 group_index，決定排程與 target 輪替。"""
    specs = []
    # 穩態（negative control）：3 profiles × 4 壓力 × 2 形態 = 24 cells，n=3
    for shape in (SHAPE_4K, SHAPE_SEQ):
        for pressure in PRESSURES_STEADY:
            specs.append({"kind": "steady", "fault": "none", "shape": shape,
                          "pressure": pressure, "base_n": 3, "target_kind": None})
    # 故障主軸（4K randrw）：3 profiles × 3 壓力 × 3 故障 = 27 cells，n=2
    for fault in ("flapping", "osd-down", "rack-isolation"):
        for pressure in PRESSURES_FAULT:
            specs.append({"kind": "fault", "fault": fault, "shape": SHAPE_4K,
                          "pressure": pressure, "base_n": 2,
                          "target_kind": "rack" if fault == "rack-isolation" else "node"})
    # node loss 變體：3 profiles × 中壓 × network-isolation = 3 cells，n=2
    specs.append({"kind": "fault", "fault": "node-isolation", "shape": SHAPE_4K,
                  "pressure": "mid", "base_n": 2, "target_kind": "node"})
    # large-IO contention：3 profiles × {中, 極端} × OSD down × 1M seq = 6 cells，n=2
    for pressure in ("mid", "extreme"):
        specs.append({"kind": "fault", "fault": "seq-contention", "shape": SHAPE_SEQ,
                      "pressure": pressure, "base_n": 2, "target_kind": "node"})
    # chaos 終局：3 profiles × 極端壓 × 固定 seed = 3 cells，n=1
    specs.append({"kind": "chaos", "fault": "chaos", "shape": SHAPE_4K,
                  "pressure": "extreme", "base_n": 1, "target_kind": None})
    return specs


def fault_params(fault):
    """每個故障型的完整參數（plan Task 4）；cap/guard 一併持久化。"""
    if fault == "none":
        return {}
    if fault == "chaos":
        return {"seed": CHAOS_SEED,
                "duration": CHAOS_DURATION_SECS,
                # chaos 無 measurement_cap → guard 直接錨在 duration（v4.2/F5-9）
                "guard_deadline_secs": CHAOS_DURATION_SECS + GUARD_MARGIN_SECS}
    base = {"measurement_cap": DEFAULT_MEASUREMENT_CAP, "guard_margin_secs": GUARD_MARGIN_SECS}
    if fault == "flapping":
        base.update({"cycles": 10, "no_out": True, "per_cycle_gate": "pgs_active_for_osd"})
    elif fault == "osd-down":
        base.update({"manual_out": True})
    elif fault == "node-isolation":
        base.update({"nodes": 1, "manual_out": True})
    elif fault == "rack-isolation":
        base.update({"nodes": 2, "manual_out": True})
    elif fault == "seq-contention":
        base.update({"fault": "osd-down", "shape": SHAPE_SEQ, "manual_out": True})
    else:
        fail("未知 fault type：%s" % fault)
    return base


def assign_targets(specs, osd_nodes):
    """targets 綁 group：同 group 一個 target，輪替只發生在 group 之間（v4.2/F5-6）。

    node 級故障共用一個 node 輪替計數器（依 group_index 遞增），rack 級另用 rack 計數器。
    """
    racks = []
    for node in osd_nodes:
        if node["rack"] not in racks:
            racks.append(node["rack"])
    node_i = 0
    rack_i = 0
    for spec in specs:
        kind = spec["target_kind"]
        if kind is None:
            spec["targets"] = []
        elif kind == "node":
            spec["targets"] = [copy.deepcopy(osd_nodes[node_i % len(osd_nodes)])]
            node_i += 1
        elif kind == "rack":
            rack = racks[rack_i % len(racks)]
            rack_i += 1
            spec["targets"] = [copy.deepcopy(n) for n in osd_nodes if n["rack"] == rack]
        else:
            fail("未知 target_kind：%s" % kind)
    return specs


def build_cells(osd_nodes):
    specs = assign_targets(group_specs(), osd_nodes)
    cells = []
    seen_groups = set()
    for gi, spec in enumerate(specs):
        group_id = "%s-%s-%s" % (spec["fault"], spec["shape"], spec["pressure"])
        if group_id in seen_groups:
            fail("group_id 重複：%s（矩陣定義有誤）" % group_id)
        seen_groups.add(group_id)
        for profile in PROFILES:
            cells.append({
                "cell_id": "%s+%s" % (group_id, profile),
                "group_id": group_id,
                "group_index": gi,
                "kind": spec["kind"],
                "profile": profile,
                "shape": spec["shape"],
                "pressure": spec["pressure"],
                "fault": spec["fault"],
                "fault_params": fault_params(spec["fault"]),
                "base_n": spec["base_n"],
                "targets": copy.deepcopy(spec["targets"]),
            })
    return cells


def build_manifest(inventory_path):
    cells = build_cells(load_osd_nodes(inventory_path))
    digest = hashlib.sha256(
        json.dumps(cells, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "inventory": os.path.abspath(inventory_path),
        "latin_order": list(LATIN),
        "default_measurement_cap": DEFAULT_MEASUREMENT_CAP,
        "guard_margin_secs": GUARD_MARGIN_SECS,
        "counts": {"cells": len(cells), "executions": sum(c["base_n"] for c in cells)},
        "manifest_hash": digest,
        "cells": cells,
    }


def assert_counts(man):
    """--assert：恰 63 cells / 147 executions（24×3 + 36×2 + 3×1）。不符 exit 1。"""
    cells = man["cells"]
    execs = sum(c["base_n"] for c in cells)
    problems = []
    if len(cells) != 63:
        problems.append("cells=%d 期望 63" % len(cells))
    if execs != 147:
        problems.append("executions=%d 期望 147" % execs)
    for base_n, want in ((3, 24), (2, 36), (1, 3)):
        got = sum(1 for c in cells if c["base_n"] == base_n)
        if got != want:
            problems.append("base_n=%d 的 cells=%d 期望 %d" % (base_n, got, want))
    groups = set(c["group_id"] for c in cells)
    if len(groups) != 21:
        problems.append("groups=%d 期望 21" % len(groups))
    for group in sorted(groups):
        n_prof = len(set(c["profile"] for c in cells if c["group_id"] == group))
        if n_prof != 3:
            problems.append("group %s 只有 %d 個 profile" % (group, n_prof))
        tset = set(json.dumps(c["targets"], sort_keys=True)
                   for c in cells if c["group_id"] == group)
        if len(tset) != 1:
            problems.append("group %s 的 targets 未綁定（%d 種）" % (group, len(tset)))
    if problems:
        for p in problems:
            log("assert 失敗：%s" % p)
        fail("manifest --assert 未通過（%d 項）" % len(problems))


# --- 排程展開 ----------------------------------------------------------------


def latin_position(group_index, replicate_n, profile):
    """position p 滿足 LATIN[(group_index + replicate_n + p) % 3] == profile。"""
    return (LATIN.index(profile) - (group_index + replicate_n)) % 3


def make_execution(cell, replicate_n, origin, cap_override, manifest_hash):
    return {
        "cell_id": cell["cell_id"],
        "group_id": cell["group_id"],
        "group_index": cell["group_index"],
        "kind": cell["kind"],
        "profile": cell["profile"],
        "shape": cell["shape"],
        "pressure": cell["pressure"],
        "fault": cell["fault"],
        "fault_params": copy.deepcopy(cell["fault_params"]),
        "targets": copy.deepcopy(cell["targets"]),
        "base_n": cell["base_n"],
        "replicate_n": replicate_n,
        "replicate": "r%d" % replicate_n,
        "latin_position": latin_position(cell["group_index"], replicate_n, cell["profile"]),
        "origin": origin,
        "bundle_key": "%s/r%d" % (cell["cell_id"], replicate_n),
        "manifest_hash": manifest_hash,
        "_cap_override": cap_override,
    }


def load_manifest(path):
    if not os.path.isfile(path):
        fail("manifest 不存在：%s（請先跑 manifest.py generate）" % path)
    try:
        with open(path) as fh:
            man = json.load(fh)
    except ValueError as exc:
        fail("manifest JSON 無法解析：%s" % exc)
    if man.get("schema_version") != SCHEMA_VERSION:
        fail("manifest schema_version=%r，本工具只支援 %d"
             % (man.get("schema_version"), SCHEMA_VERSION))
    if not isinstance(man.get("cells"), list) or not man["cells"]:
        fail("manifest 缺 cells")
    return man


def load_amendments(results_dir):
    """讀 append-only JSONL journal；壞行一律 die（不得靜默略過——journal 是唯一持久 SoT）。"""
    path = os.path.join(results_dir, AMENDMENTS_BASENAME)
    if not os.path.isfile(path):
        return []
    records = []
    with open(path) as fh:
        for lineno, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except ValueError as exc:
                fail("%s 第 %d 行不是合法 JSON：%s" % (path, lineno, exc))
            if not isinstance(rec, dict):
                fail("%s 第 %d 行不是 object" % (path, lineno))
            for field in ("schema_version", "type", "key", "value", "seq"):
                if field not in rec:
                    fail("%s 第 %d 行缺欄位 %s" % (path, lineno, field))
            if rec["schema_version"] != AMEND_SCHEMA_VERSION:
                fail("%s 第 %d 行 schema_version=%r，本工具只支援 %d"
                     % (path, lineno, rec["schema_version"], AMEND_SCHEMA_VERSION))
            if rec["type"] not in AMEND_TYPES:
                fail("%s 第 %d 行 type=%r 不在四型之內" % (path, lineno, rec["type"]))
            records.append(rec)
    records.sort(key=lambda r: r["seq"])
    return records


def _needs_human_index(amendments):
    """回傳 (cell 級集合, 'cell/rN' 級集合, 呈報清單)。"""
    cells = set()
    reps = set()
    listed = []
    for rec in amendments:
        if rec["type"] != "needs-human":
            continue
        key = str(rec["key"])
        if "/" in key:
            reps.add(key)
        else:
            cells.add(key)
        listed.append({"key": key, "reason": rec["value"], "seq": rec["seq"],
                       "source": rec.get("source", "")})
    return cells, reps, listed


def expand_schedule(man, amendments):
    """base 排程（group_index → replicate → latin_position）＋ amendments 追加的 executions。"""
    cells = {c["cell_id"]: c for c in man["cells"]}
    mhash = man.get("manifest_hash", "")
    execs = []
    for cell in man["cells"]:
        for n in range(1, cell["base_n"] + 1):
            execs.append(make_execution(cell, n, "base", None, mhash))
    execs.sort(key=lambda e: (e["group_index"], e["replicate_n"], e["latin_position"]))

    # 加跑的 replicate 接在 base 之後（決策時點本來就晚於 base 排程）
    next_n = {}
    for rec in amendments:
        cell_id = str(rec["key"])
        if rec["type"] == "extra-replicates":
            cell = cells.get(cell_id)
            if cell is None:
                fail("extra-replicates 指向不存在的 cell：%s" % cell_id)
            start = next_n.get(cell_id, cell["base_n"] + 1)
            count = int(rec["value"])
            for i in range(count):
                execs.append(make_execution(cell, start + i,
                                            "extra-replicates:%d" % rec["seq"], None, mhash))
            next_n[cell_id] = start + count
        elif rec["type"] == "rescue-replicate":
            cell = cells.get(cell_id)
            if cell is None:
                fail("rescue-replicate 指向不存在的 cell：%s" % cell_id)
            cap = rec["value"]
            if isinstance(cap, dict):
                cap = cap.get("cap")
            if not isinstance(cap, int) or cap <= 0:
                fail("rescue-replicate 的 value 必須帶正整數 cap（got=%r）" % (rec["value"],))
            start = next_n.get(cell_id, cell["base_n"] + 1)
            execs.append(make_execution(cell, start,
                                        "rescue-replicate:%d" % rec["seq"], cap, mhash))
            next_n[cell_id] = start + 1
    return execs


def merged_view(man, results_dir):
    """`next` 與 audit 共用的 merge 視圖（四型都有定義的語意）。"""
    amendments = load_amendments(results_dir)
    execs = expand_schedule(man, amendments)

    # cap-update：只影響「尚未執行」者；已執行者的 cap 以 bundle 為準，不追溯改寫。
    cap_by_fault = {}
    for rec in amendments:
        if rec["type"] == "cap-update":
            cap_by_fault[str(rec["key"])] = (int(rec["value"]), rec["seq"])

    nh_cells, nh_reps, nh_list = _needs_human_index(amendments)

    done = 0
    pending = 0
    blocked = 0
    for ex in execs:
        cap_override = ex.pop("_cap_override")
        key = "%s/%s" % (ex["cell_id"], ex["replicate"])
        marker = os.path.join(results_dir, ex["cell_id"], ex["replicate"], "DONE")
        if os.path.isfile(marker):
            ex["status"] = "done"
        elif ex["cell_id"] in nh_cells or key in nh_reps:
            ex["status"] = "needs-human"
        else:
            ex["status"] = "pending"

        if ex["status"] == "done":
            # 完成的 execution 其 cap 只有 bundle 知道（verdict 以此拒絕合併不同 cap 的 replicates）
            ex["measurement_cap"] = None
            ex["measurement_cap_source"] = "bundle"
            done += 1
        else:
            if cap_override is not None:
                ex["measurement_cap"] = cap_override
                ex["measurement_cap_source"] = ex["origin"]
            elif ex["kind"] == "chaos":
                ex["measurement_cap"] = None
                ex["measurement_cap_source"] = "chaos-no-cap"
            elif ex["kind"] == "steady":
                ex["measurement_cap"] = None
                ex["measurement_cap_source"] = "steady-no-cap"
            elif ex["fault"] in cap_by_fault:
                value, seq = cap_by_fault[ex["fault"]]
                ex["measurement_cap"] = value
                ex["measurement_cap_source"] = "cap-update:%d" % seq
            else:
                ex["measurement_cap"] = ex["fault_params"].get("measurement_cap")
                ex["measurement_cap_source"] = "base"
            if ex["status"] == "pending":
                pending += 1
            else:
                blocked += 1
        # guard 不變條件（§Cap policy）：guard_deadline >= measurement_deadline + 600
        if ex["measurement_cap"] is not None:
            ex["guard_deadline_secs"] = ex["measurement_cap"] + GUARD_MARGIN_SECS
        else:
            ex["guard_deadline_secs"] = ex["fault_params"].get("guard_deadline_secs")

    return {
        "schema_version": SCHEMA_VERSION,
        "manifest_hash": man.get("manifest_hash", ""),
        "counts": {
            "cells": len(man["cells"]),
            "base_executions": sum(c["base_n"] for c in man["cells"]),
            "total_executions": len(execs),
            "done": done,
            "pending": pending,
            "needs_human": blocked,
        },
        "executions": execs,
        "amendments": amendments,
        "needs_human": nh_list,
    }


def pilot_executions(man):
    """每故障型的 pilot = 「預期最慢組合」（最高壓力 × high_client_ops）的 r1。

    node-isolation 只有中壓 cells → 其 pilot 自然退化為中壓 × high_client_ops（v4.2.1）。
    chaos 無 measurement_cap，不需要 pilot 推導。
    """
    mhash = man.get("manifest_hash", "")
    out = []
    for fault in FAULT_TYPES:
        cands = [c for c in man["cells"] if c["fault"] == fault]
        if not cands:
            fail("manifest 內找不到 fault type：%s" % fault)
        top = max(PRESSURE_RANK[c["pressure"]] for c in cands)
        picked = [c for c in cands
                  if PRESSURE_RANK[c["pressure"]] == top and c["profile"] == "high_client_ops"]
        if len(picked) != 1:
            fail("fault %s 的 pilot cell 不唯一（%d 個）" % (fault, len(picked)))
        ex = make_execution(picked[0], 1, "pilot", None, mhash)
        ex.pop("_cap_override")
        ex["measurement_cap"] = picked[0]["fault_params"].get("measurement_cap")
        ex["measurement_cap_source"] = "base"
        out.append(ex)
    return out


# --- amendments 寫入 ---------------------------------------------------------


def append_amendment(results_dir, record):
    """tmp + mv 原子 append（journal 是 crash-resume 的唯一持久 SoT）。"""
    path = os.path.join(results_dir, AMENDMENTS_BASENAME)
    lines = []
    if os.path.isfile(path):
        with open(path) as fh:
            lines = [x for x in fh.read().splitlines() if x.strip()]
    lines.append(json.dumps(record, sort_keys=True, ensure_ascii=False))
    fd, tmp = tempfile.mkstemp(dir=results_dir, prefix=".amend.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write("\n".join(lines) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return path


def parse_amend_value(atype, raw):
    if atype in ("extra-replicates", "cap-update"):
        try:
            value = int(raw)
        except (TypeError, ValueError):
            fail("%s 的 --value 必須是整數（got=%r）" % (atype, raw))
        if value <= 0:
            fail("%s 的 --value 必須 > 0（got=%d）" % (atype, value))
        return value
    if atype == "rescue-replicate":
        try:
            value = json.loads(raw)
        except ValueError:
            value = raw
        if isinstance(value, int):
            value = {"cap": value}
        if not isinstance(value, dict) or not isinstance(value.get("cap"), int) \
                or value["cap"] <= 0:
            fail("rescue-replicate 的 --value 必須是 {\"cap\": 秒數} 或正整數（got=%r）" % (raw,))
        return {"cap": value["cap"]}
    # needs-human
    if not str(raw).strip():
        fail("needs-human 的 --value（原因）不得為空")
    return str(raw)


def validate_amend_key(man, atype, key, existing):
    cell_ids = set(c["cell_id"] for c in man["cells"])
    if atype == "cap-update":
        if key not in FAULT_TYPES:
            fail("cap-update 的 --key 必須是故障型 %s（got=%s）" % (list(FAULT_TYPES), key))
        return
    cell_id = key.split("/", 1)[0] if atype == "needs-human" else key
    if cell_id not in cell_ids:
        fail("%s 的 --key 指向不存在的 cell：%s" % (atype, cell_id))
    if atype == "needs-human" and "/" in key:
        rep = key.split("/", 1)[1]
        if not rep.startswith("r") or not rep[1:].isdigit():
            fail("needs-human 的 replicate 格式必須是 <cell_id>/rN（got=%s）" % key)
    if atype == "rescue-replicate":
        # §Cap policy：雙 censored 自救「每 cell 以一次為限」——在寫入端擋掉重複
        for rec in existing:
            if rec["type"] == "rescue-replicate" and str(rec["key"]) == key:
                fail("cell %s 已有 rescue-replicate（seq=%d）；每 cell 以一次為限"
                     % (key, rec["seq"]))


# --- CLI ---------------------------------------------------------------------


def _add_common(parser):
    parser.add_argument("--results", default=None, help="results 目錄（預設 $RESULTS_DIR）")
    parser.add_argument("--manifest", default=None, help="manifest.json 路徑（預設 <results>/manifest.json）")


def _resolve(args):
    results = os.path.abspath(args.results or default_results_dir())
    manifest = os.path.abspath(args.manifest or os.path.join(results, MANIFEST_BASENAME))
    return results, manifest


def cmd_generate(args):
    results = os.path.abspath(args.results or default_results_dir())
    out = os.path.abspath(args.out or os.path.join(results, MANIFEST_BASENAME))
    man = build_manifest(args.inventory or default_inventory())
    if getattr(args, "assert_counts", False):
        assert_counts(man)
    parent = os.path.dirname(out)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    fd, tmp = tempfile.mkstemp(dir=parent or ".", prefix=".manifest.", suffix=".tmp")
    with os.fdopen(fd, "w") as fh:
        json.dump(man, fh, indent=2, sort_keys=True, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, out)
    log("manifest 已寫入 %s（hash=%s）" % (out, man["manifest_hash"][:12]))
    sys.stdout.write("manifest: %d cells %d executions\n"
                     % (man["counts"]["cells"], man["counts"]["executions"]))
    return 0


def cmd_schedule(args):
    results, manifest = _resolve(args)
    man = load_manifest(manifest)
    if getattr(args, "assert_counts", False):
        assert_counts(man)
    view = merged_view(man, results)
    for ex in view["executions"]:
        sys.stdout.write(json.dumps(ex, sort_keys=True, ensure_ascii=False) + "\n")
    return 0


def cmd_view(args):
    results, manifest = _resolve(args)
    man = load_manifest(manifest)
    if getattr(args, "assert_counts", False):
        assert_counts(man)
    sys.stdout.write(json.dumps(merged_view(man, results), sort_keys=True,
                                ensure_ascii=False) + "\n")
    return 0


def cmd_next(args):
    results, manifest = _resolve(args)
    man = load_manifest(manifest)
    view = merged_view(man, results)
    wanted = None
    if args.pilot:
        wanted = set("%s/r%d" % (p["cell_id"], p["replicate_n"]) for p in pilot_executions(man))
    for ex in view["executions"]:
        if ex["status"] != "pending":
            continue
        if args.kind and ex["kind"] != args.kind:
            continue
        if wanted is not None and "%s/%s" % (ex["cell_id"], ex["replicate"]) not in wanted:
            continue
        sys.stdout.write(json.dumps(ex, sort_keys=True, ensure_ascii=False) + "\n")
        return 0
    log("沒有待執行的 execution（kind=%s pilot=%s）" % (args.kind or "*", bool(args.pilot)))
    return 3


def cmd_pilots(args):
    _, manifest = _resolve(args)
    man = load_manifest(manifest)
    for ex in pilot_executions(man):
        sys.stdout.write(json.dumps(ex, sort_keys=True, ensure_ascii=False) + "\n")
    return 0


def cmd_amend(args):
    results, manifest = _resolve(args)
    man = load_manifest(manifest)
    if args.type not in AMEND_TYPES:
        fail("--type 必須是四型之一 %s（got=%s）" % (list(AMEND_TYPES), args.type))
    if not os.path.isdir(results):
        os.makedirs(results)
    existing = load_amendments(results)
    validate_amend_key(man, args.type, args.key, existing)
    value = parse_amend_value(args.type, args.value)
    seq = (max([r["seq"] for r in existing]) + 1) if existing else 1
    record = {
        "schema_version": AMEND_SCHEMA_VERSION,
        "type": args.type,
        "key": args.key,
        "value": value,
        "source": args.source,
        "seq": seq,
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    path = append_amendment(results, record)
    log("amendment 已寫入 %s" % path)
    sys.stdout.write("amend: %s %s seq=%d\n" % (args.type, args.key, seq))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="manifest.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd")

    p = sub.add_parser("generate", help="產生 results/manifest.json")
    p.add_argument("--inventory", default=None)
    p.add_argument("--results", default=None)
    p.add_argument("--out", default=None)
    p.add_argument("--assert", dest="assert_counts", action="store_true")
    p.set_defaults(func=cmd_generate)

    p = sub.add_parser("schedule", help="印出完整 execution 排程（JSONL）")
    _add_common(p)
    p.add_argument("--assert", dest="assert_counts", action="store_true")
    p.set_defaults(func=cmd_schedule)

    p = sub.add_parser("view", help="印出 merge 視圖（next 與 audit 共用語意）")
    _add_common(p)
    p.add_argument("--assert", dest="assert_counts", action="store_true")
    p.set_defaults(func=cmd_view)

    p = sub.add_parser("next", help="印出下一個待執行 execution；無則 exit 3")
    _add_common(p)
    p.add_argument("--kind", choices=("steady", "fault", "chaos"), default=None)
    p.add_argument("--pilot", action="store_true")
    p.set_defaults(func=cmd_next)

    p = sub.add_parser("pilots", help="印出每故障型的 pilot execution")
    _add_common(p)
    p.set_defaults(func=cmd_pilots)

    p = sub.add_parser("amend", help="append-only 寫入 schedule-amendments.json")
    _add_common(p)
    p.add_argument("--type", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--value", required=True)
    p.add_argument("--source", default="")
    p.set_defaults(func=cmd_amend)

    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help(sys.stderr)
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
