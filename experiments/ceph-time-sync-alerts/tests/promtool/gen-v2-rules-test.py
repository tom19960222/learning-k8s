#!/usr/bin/env python3
"""產生 v2-rules.test.yml — 從 v2 規則檔抽出 annotations 原文（promtool 對
exp_annotations 做全比對，手抄必炸），依既定情境矩陣組出 promtool 測試。
改情境改這支，再執行重新產生；不要手改 v2-rules.test.yml。"""
import re
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RULES = os.path.join(HERE, "..", "..", "v2", "ceph-time-sync-alerts.yml")
OUT = os.path.join(HERE, "v2-rules.test.yml")

# 抽 annotations 原文（保留原始引號字串，貼回測試檔語意相同）
ann = {}
cur = None
for line in open(RULES):
    m = re.match(r'\s+- alert: (\w+)', line)
    if m:
        cur = m.group(1)
        ann[cur] = {}
    m = re.match(r'\s+(summary|description): (".*")\s*$', line)
    if m and cur:
        ann[cur][m.group(1)] = m.group(2)

ALL_ALERTS = list(ann)
assert len(ALL_ALERTS) == 15, f"預期 15 條 rule，抽到 {len(ALL_ALERTS)}"


def series(name, labels, values):
    lab = ", ".join(f'{k}="{v}"' for k, v in labels.items())
    return f"      - series: '{name}{{{lab}}}'\n        values: '{values}'\n"


def exp(alertname, labels):
    out = "          - exp_labels:\n"
    for k, v in labels.items():
        out += f"              {k}: {v}\n"
    out += "            exp_annotations:\n"
    for k, v in ann[alertname].items():
        out += f"              {k}: {v}\n"
    return out


def block(comment, inputs, asserts):
    out = f"  # ── {comment} ──\n  - interval: 1m\n    input_series:\n"
    out += "".join(inputs)
    out += "    alert_rule_test:\n"
    for t, name, expected in asserts:
        out += f"      - eval_time: {t}\n        alertname: {name}\n"
        out += ("        exp_alerts:\n" + expected) if expected else "        exp_alerts: []\n"
    return out + "\n"


CN = {"job": "ceph-node"}


def n(inst):
    return {"instance": inst, **CN}


tests = []

# U1 — H-011 修正驗證：對稱 ±40ms（實差 80ms）→ SpreadHigh 會 fire
tests.append(block(
    "U1: 對稱 skew ±40ms → v2 spread 接住（舊規則 T1 證實漏掉）",
    [series("node_ntp_offset_seconds", n("mon1"), "0.04x30"),
     series("node_ntp_offset_seconds", n("mon2"), "-0.04x30"),
     series("node_ntp_offset_seconds", n("mon3"), "0x30")],
    [("4m", "CephNodeTimeSpreadHigh", exp("CephNodeTimeSpreadHigh", {"severity": "warning"})),
     ("4m", "CephNodeTimeSpreadCritical", None)]))

# U2 — H-016 修正驗證：單 node +250ms、無 jitter 條件 → 雙車道 offset alert
tests.append(block(
    "U2: 單 node +250ms（舊規則 T3 證實沉默）→ OffsetHigh/Warning 都接住",
    [series("node_ntp_offset_seconds", n("mon1"), "0.25x30")],
    [("3m", "CephNodeTimeOffsetHigh",
      exp("CephNodeTimeOffsetHigh", {"severity": "critical", "instance": "mon1", "job": "ceph-node"})),
     ("4m", "CephNodeTimeOffsetWarning",
      exp("CephNodeTimeOffsetWarning", {"severity": "warning", "instance": "mon1", "job": "ceph-node"}))]))

# U3 — H-032 修正驗證：無關主機不再汙染
tests.append(block(
    "U3: job=other 的主機 +200ms → scope 隔離，Ceph alert 不 fire（舊規則 T8 證實誤發）",
    [series("node_ntp_offset_seconds", n("mon1"), "0x30"),
     series("node_ntp_offset_seconds", n("mon2"), "0x30"),
     series("node_ntp_offset_seconds", {"instance": "app-42", "job": "other"}, "0.2x30")],
    [("5m", "CephNodeTimeSpreadHigh", None),
     ("5m", "CephNodeTimeOffsetHigh", None)]))

# U4 — 零 FP 基線：生產參數（poll=256）健康態，15 條全綠
healthy = [
    series("node_ntp_offset_seconds", n("mon1"), "0.001x30"),
    series("node_ntp_offset_seconds", n("mon2"), "-0.002x30"),
    series("node_ntp_offset_seconds", n("mon3"), "0.0005x30"),
    series("node_ntp_synchronized", n("mon1"), "1x30"),
    series("node_ntp_synchronized", n("mon2"), "1x30"),
    series("node_ntp_synchronized", n("mon3"), "1x30"),
    series("node_ntp_seconds_since_last_packet", n("mon1"), "120x30"),
    series("node_ntp_seconds_since_last_packet", n("mon2"), "200x30"),
    series("node_ntp_seconds_since_last_packet", n("mon3"), "60x30"),
    series("node_ntp_poll_interval_seconds", n("mon1"), "256x30"),
    series("node_ntp_poll_interval_seconds", n("mon2"), "256x30"),
    series("node_ntp_poll_interval_seconds", n("mon3"), "256x30"),
    series("node_time_sync_collector_error", n("mon1"), "0x30"),
    series("node_time_sync_collector_error", n("mon2"), "0x30"),
    series("node_time_sync_collector_error", n("mon3"), "0x30"),
    series("up", n("mon1"), "1x30"),
    series("up", n("mon2"), "1x30"),
    series("up", n("mon3"), "1x30"),
    series("node_timex_offset_seconds", n("mon1"), "0.0001x30"),
    series("node_timex_maxerror_seconds", n("mon1"), "0.05x30"),
    series("node_time_seconds", n("mon1"), "0+60x30"),
    series("node_textfile_scrape_error", n("mon1"), "0x30"),
]
tests.append(block(
    "U4: 生產參數健康基線（poll=256）→ 15 條 rule 全程零 alert（零 FP 斷言）",
    healthy,
    [("20m", a, None) for a in ALL_ALERTS]))

# U5 — H-004/H-030 修正驗證：採集死亡 → per-node missing-series 會叫
tests.append(block(
    "U5: node 活著但採集死亡（error series 轉 stale）→ MetricsMissing 準時 fire（舊規則 T9 證實靜默）",
    [series("up", n("mon1"), "1x30"),
     series("node_time_sync_collector_error", n("mon1"), "0x10 stale")],
    [("23m", "CephNodeTimeMetricsMissing",
      exp("CephNodeTimeMetricsMissing", {"severity": "warning", "instance": "mon1", "job": "ceph-node"}))]))

# U6 — H-023 對策驗證：last-packet-age 是快速失聯訊號（雙車道）
tests.append(block(
    "U6: 上游失聯 age 線性爬升 → Stalled(768s)/StalledCritical(1800s) 依序 fire",
    [series("node_ntp_seconds_since_last_packet", n("mon1"), "0+120x29")],
    [("10m", "CephNodeTimeSyncStalled",
      exp("CephNodeTimeSyncStalled", {"severity": "warning", "instance": "mon1", "job": "ceph-node"})),
     ("18m", "CephNodeTimeSyncStalledCritical",
      exp("CephNodeTimeSyncStalledCritical", {"severity": "critical", "instance": "mon1", "job": "ceph-node"}))]))

# U7 — 最終後衛：NTPSynchronized=no
tests.append(block(
    "U7: NTPSynchronized=no → Unsynchronized critical（語意=失聯已 ~9h 的最終後衛）",
    [series("node_ntp_synchronized", n("mon1"), "0x30")],
    [("5m", "CephNodeTimeUnsynchronized",
      exp("CephNodeTimeUnsynchronized", {"severity": "critical", "instance": "mon1", "job": "ceph-node"}))]))

# U8 — fail-loud 路徑
tests.append(block(
    "U8: collector_error=1 持續 → CollectorError（chrony 接管/格式變更的 fail-loud）",
    [series("node_time_sync_collector_error", n("mon1"), "1x30")],
    [("12m", "CephNodeTimeCollectorError",
      exp("CephNodeTimeCollectorError", {"severity": "warning", "instance": "mon1", "job": "ceph-node"}))]))

# U9 — H-015/H-034 對策驗證：共模漂移由跨信任域訊號接住
tests.append(block(
    "U9: node 時鐘比 Prometheus 快 300s（共模情境的可觀測面）→ Drift 雙車道",
    [series("node_time_seconds", n("mon1"), "300+60x30")],
    [("3m", "CephNodeClockVsPrometheusDriftCritical",
      exp("CephNodeClockVsPrometheusDriftCritical", {"severity": "critical", "instance": "mon1", "job": "ceph-node"})),
     ("6m", "CephNodeClockVsPrometheusDrift",
      exp("CephNodeClockVsPrometheusDrift", {"severity": "warning", "instance": "mon1", "job": "ceph-node"}))]))

# U10 — H-033 對策驗證：transient step 自癒後 keep_firing_for 仍讓人看見
tests.append(block(
    "U10: timex 短暫 0.2s 修正（2 分鐘就自癒）→ CorrectionInProgress 以 keep_firing_for 保留 10m",
    [series("node_timex_offset_seconds", n("mon1"), "0.2x1 0x28")],
    [("8m", "CephNodeClockCorrectionInProgress",
      exp("CephNodeClockCorrectionInProgress", {"severity": "warning", "instance": "mon1", "job": "ceph-node"})),
     ("13m", "CephNodeClockCorrectionInProgress", None)]))

# U11 — kernel 誤差上界獨立訊號
tests.append(block(
    "U11: maxerror 2s → KernelClockErrorBoundHigh（script 全滅時仍活著的訊號）",
    [series("node_timex_maxerror_seconds", n("mon1"), "2x30")],
    [("6m", "CephNodeKernelClockErrorBoundHigh",
      exp("CephNodeKernelClockErrorBoundHigh", {"severity": "warning", "instance": "mon1", "job": "ceph-node"}))]))

# U12 — H-013 修正驗證：方向反轉後的 poll 規則
tests.append(block(
    "U12: poll 卡在 32s（daemon 掙扎）→ Struggling；健康 256 不會 fire（U4 已證）",
    [series("node_ntp_poll_interval_seconds", n("mon1"), "32x30")],
    [("16m", "CephNodeTimeSyncStruggling",
      exp("CephNodeTimeSyncStruggling", {"severity": "warning", "instance": "mon1", "job": "ceph-node"}))]))

# U13 — H-031 對策驗證
tests.append(block(
    "U13: node_textfile_scrape_error=1 → TextfileScrapeError（歸因注意事項在 annotation）",
    [series("node_textfile_scrape_error", n("mon1"), "1x30")],
    [("16m", "CephNodeTextfileScrapeError",
      exp("CephNodeTextfileScrapeError", {"severity": "warning", "instance": "mon1", "job": "ceph-node"}))]))

header = """# v2 規則的 promtool 判決 — 由 gen-v2-rules-test.py 產生，不要手改。
# 對照組：current-rules.test.yml（舊規則的盲區證明）；本檔斷言 v2 把每個盲區接住
# 且健康基線（生產參數 poll=256）零 FP。
rule_files:
  - ../../v2/ceph-time-sync-alerts.yml

evaluation_interval: 1m

tests:
"""
with open(OUT, "w") as f:
    f.write(header + "".join(tests))
print(f"generated {OUT}: {len(tests)} test groups, {len(ALL_ALERTS)} rules covered")
