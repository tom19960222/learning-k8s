# ceph slow ops 快速偵測（SSD firmware 暫態卡頓）— Hypothesis Backlog

## Charter

- **Goal**：只靠 Prometheus metrics，(a) 對「SSD firmware 造成的 BlueStore 暫態卡頓」（5~8 顆 OSD 在同一秒回報 op 卡 5~8 秒）做出可主動偵測的規則，(b) 對「真的會卡住 client 的一般 slow ops」把偵測延遲壓到事發後 30~60 秒內——且兩者都要在真機上量出實際偵測延遲。
- **Scope**：
  - in：ceph 內建可匯出的 metrics（mgr prometheus module、ceph-exporter）、node_exporter、Prometheus recording/alerting rules、偵測延遲量測、firmware 事件的「同秒多 OSD」指紋。
  - out：log-based 偵測（Loki 等）、SMART/RAID 卡帶外工具（storcli 等）、修 firmware 本身、client 端量測。
- **使用者事件描述**（framing 輸入）：生產環境 OSD node 為 10x SAS SSD 全掛在同一張 RAID 卡（無軟體 RAID）；發生過數次 5~8 顆 OSD 同一秒回報 BlueStore op 卡住 5~8 秒（「slow ops in bluestore」），疑似 SSD firmware 造成。
- **Version anchors**：ceph v19.2.3（repo submodule `ceph/` @ c92aebb）；lab = cephadm v19.2.3，3 mon（.166/.167/.164）+ 9 OSD（.169/.171/.174 各 3）；lab Prometheus **v2.51.0**、scrape interval **10s**（cephadm 部署預設）。
- **Tiers available**：
  - T1：`ceph/` submodule 原始碼（pinned v19.2.3）。
  - T2：官方文件 / tracker / GitHub 版本比對。
  - T3：真機 lab（monitoring stack 已於 2026-07-09 以 `ceph orch apply` 部署：prometheus@mon-01:9095、ceph-exporter×6:9926、node-exporter×6:9100；實驗結束後 `ceph orch rm` 回退）。破壞性操作依 repo 規則：pre-check → 注入 → 收集 → 立即回退 → HEALTH_OK。
- **注入機制（T3）**：
  - 暫態卡頓（firmware pause 模擬）：`dmsetup suspend /dev/dm-N` + sleep + `resume`——device 層 IO 全排隊、OSD process/heartbeat/admin socket 全部正常，最貼近 firmware 卡頓的語意。
  - 持續慢盤（client 卡住）：OSD service cgroup（cgroup v2）對 data device 設 `io.max` r/wiops 極低值；OSD 活著、op 排隊變老。
  - process 凍結（observer 測試用）：`kill -STOP` 真正的 ceph-osd PID（不是 conmon/podman-init）。

### Gate 決策紀錄（使用者離線，依授權自主通過）

- Gate 1（backlog triage）：使用者已在任務描述中明確指定兩個目標並委託探索 unknown-unknowns；triage 結果——全部 T3 實驗聚焦 H-001~H-008、H-011、H-013、H-016、H-017、H-020、H-021、H-022；H-012 降級為 T1 推理（時序競態 demo 價值低）；H-009、H-015、H-019 以 T1/T2 + 部分 T3 資料回答。
- Gate 2（破壞性操作）：lab cluster 為既有授權的驗證用叢集（先前 alert-coverage SP 已做過 22 條真機注入）；一律遵守可回退紀律，且不碰生產環境。
- Gate 3（findings triage）：報告全數呈現，由使用者事後裁決哪些進 alert rules / 專題頁。

## Preliminary research 摘要（T1 已錨定的事實）

| 事實 | 錨點 |
|---|---|
| BlueStore op 超過 `bluestore_log_op_age`（預設 **5s**）→ log「slow operation observed」+ `_add_slow_op_event()` + **inc 專用 perf counter（idx2，僅部分呼叫點有帶）** | `BlueStore.cc:18476-18484`（log_latency）、`18494-18506`（log_latency_fn） |
| 4 個專用 slow counter：`slow_aio_wait_count`、`slow_committed_kv_count`、`slow_read_onode_meta_count`、`slow_read_wait_aio_count`，全部 `PRIO_USEFUL`(5) | `BlueStore.cc:6456-6476`、`BlueStore.h:223-226` |
| txc 從 start 到 committed 超過 5s → `slow_committed_kv_count`++ | `BlueStore.cc:14471-14479` |
| `BLUESTORE_SLOW_OP_ALERT` health 警告：queue 內事件數 ≥ `bluestore_slow_ops_warn_threshold`（預設 1），事件保留 `bluestore_slow_ops_warn_lifetime`（預設 **86400s = 24h**，latch） | `BlueStore.cc:18444-18453`、`18899-18907`、`global.yaml.in:5447-5463` |
| SLOW_OPS health：op 齡 > `osd_op_complaint_time`（預設 **30s**）才計入；OSD 每 tick（~1s）算一次 → `mgrc.update_daemon_health()` | `OSD.cc:7825-7832`、`OSD.cc:6460`、`OSD.cc:2406` |
| ceph-exporter：每 `exporter_stats_period`（預設 **5s**）撈 admin socket，`exporter_prio_limit` 預設 **5**（`priority < 5` 才略過 → PRIO_USEFUL 會匯出），port 9926 | `ceph-exporter.yaml.in`、`DaemonMetricCollector.cc:116,164` |
| mgr prometheus module：`exclude_perf_counters` 預設 **True**（perf counters 交給 ceph-exporter）；模組自身 cache `scrape_interval` 預設 **15s** | `pybind/mgr/prometheus/module.py:589-596,607-609` |
| OSD `op_latency` prio 9、`op_r_latency`/`op_w_latency` 落在 `set_prio_default(PRIO_USEFUL)` 區段 → 都會被 ceph-exporter 匯出；line 131 之後的 counter 是 PRIO_DEBUGONLY → 不匯出 | `osd_perf_counters.cc:31,49-99,131` |
| BlueStore `txc_commit_lat`＝PRIO_CRITICAL → 匯出 | `BlueStore.cc:6217-6219` |
| `ceph_osd_commit_latency_ms`/`apply_latency_ms` 來自 mgr module 的 `OSD_STATS`（pg dump 的 osd_stat），非 perf counter 路徑 | `module.py:94` |

**T3 已確認的匯出面（2026-07-09）**：`ceph_bluestore_slow_{aio_wait,committed_kv,read_onode_meta,read_wait_aio}_count{ceph_daemon="osd.N"}` 全部存在於 ceph-exporter :9926；`ceph_bluestore_txc_commit_lat_{sum,count}`、`ceph_osd_op_w_latency_{sum,count}` 亦在。Prometheus v2.51.0（支援 `keep_firing_for`）、scrape 10s。

## 現有 alert 資產（避免重工）

`experiments/ceph-alert-rules/rules/`：`CephClientIOBlocked`（`ceph_health_detail{name="SLOW_OPS"}`, for:1m）、`CephDaemonSlowOps`（`max_over_time(ceph_daemon_health_metrics{type="SLOW_OPS"}[5m]) > 0`, for:1m）——兩者都吃 30s complaint 門檻 + health 傳播延遲，對 5~8s 暫態全盲。

## 候選規則（實驗的 prediction 標的）

```promql
# R1 CephOSDTransientStall（warning）：任一 OSD 一分鐘內出現 ≥1 次 >5s 的 BlueStore slow op
sum by (ceph_daemon, instance) (
    increase(ceph_bluestore_slow_aio_wait_count[1m])
  + increase(ceph_bluestore_slow_committed_kv_count[1m])
  + increase(ceph_bluestore_slow_read_onode_meta_count[1m])
  + increase(ceph_bluestore_slow_read_wait_aio_count[1m])
) > 0
# for: 0s, keep_firing_for: 10m

# R2 CephNodeMultiOSDStall（critical，firmware/RAID 卡指紋）：同一 node ≥3 顆 OSD 在同一 2m 窗內出現 slow op
count by (instance) (
  sum by (ceph_daemon, instance) (
      increase(ceph_bluestore_slow_aio_wait_count[2m])
    + increase(ceph_bluestore_slow_committed_kv_count[2m])
    + increase(ceph_bluestore_slow_read_onode_meta_count[2m])
    + increase(ceph_bluestore_slow_read_wait_aio_count[2m])
  ) > 0
) >= 3
# for: 0s, keep_firing_for: 15m

# R3 CephDaemonSlowOpsFast（critical，client 卡住、加速版）：SLOW_OPS 一出現就 fire（不等 for:1m）
max_over_time(ceph_daemon_health_metrics{type="SLOW_OPS"}[1m]) > 0
# for: 0s, keep_firing_for: 10m
```

## Hypotheses

### H-001: 5~8 秒的 BlueStore 卡頓永遠不會產生 SLOW_OPS health 警告（op 齡 < osd_op_complaint_time=30s），現有兩條 slow-ops alert 對此類事件 0 覆蓋
- Status: predicted
- Tier: T1（已錨定）+ T3（實證）
- Origin: framing-dialog（使用者「該如何更主動偵測」的直接成因）
- Prediction: E-01（8s 暫態注入）觀察窗（注入起 −60s ~ +180s）內，`ceph_health_detail{name="SLOW_OPS"}` 與 `ceph_daemon_health_metrics{type="SLOW_OPS",ceph_daemon="osd.0"}` 全程 == 0。
- Evidence: T1 = `OSD.cc:7832`（`too_old -= osd_op_complaint_time`，預設 30s）
- Artifacts:
- Notes: T3 bundle 待 E-01。

### H-002: `ceph_bluestore_slow_committed_kv_count` 等 4 個 counter 會被 lab 的 ceph-exporter 以預設設定匯出，且單次 >5s 卡頓會讓 counter 增加
- Status: predicted
- Tier: T3
- Origin: framing-dialog + preliminary research
- Prediction: (a) 已確認 4 個 metric 存在（見上）；(b) E-01 注入後 120s 內，`sum(increase(ceph_bluestore_slow_*_count{ceph_daemon="osd.0"}[2m]))` ≥ 1（4 counter 合計）。
- Evidence: (a) = 2026-07-09 curl .169:9926/metrics（全 0 baseline）
- Artifacts:
- Notes: 地基假設。

### H-003: 以 slow counter 的 increase 做 alert（R1），從「卡頓結束（op 完成）」到規則第一次可判真的延遲 ≤ 30s；從「卡頓開始」算 ≤ 40s——滿足 <30-60s 目標
- Status: predicted
- Tier: T3
- Origin: framing-dialog（<30-60s 目標）
- Prediction: E-01：R1 表達式（query_range step 5s 重放）第一個為真的 timestamp − SIGSUSPEND 結束時刻 ≤ 30s（機制上限=exporter 5s + scrape 10s + eval 15s）。
- Evidence:
- Artifacts:
- Notes: lab 未載入規則，以 query_range 事後重放 + 分析式加上 eval interval 上限；方法記錄於報告。

### H-004: 「同一 node ≥3 顆 OSD 在同一個 2m 窗內 slow counter 同時增加」（R2）可作為 firmware/RAID-卡層級事件的指紋，且單一 OSD 事件（E-01）不會觸發 R2
- Status: predicted
- Tier: T3
- Origin: framing-dialog（使用者事件形態：5~8 顆同一秒）
- Prediction: E-02（同 node 3 OSD 同秒 suspend 8s）：R2 在注入後 ≤ 130s 內為真且 `count == 3`、label instance="ceph-lab-osd-01"；E-01 全程 R2 不為真。
- Evidence:
- Artifacts:
- Notes:

### H-005: 現有 SLOW_OPS 鏈路的端到端偵測延遲 ≥ 2 分鐘（op 開始卡住 → CephDaemonSlowOps(for:1m) 可 fire），即使 op 持續卡住
- Status: predicted
- Tier: T3
- Origin: framing-dialog（baseline 量測）
- Prediction: E-04（持續 io.max 節流）：`ceph_daemon_health_metrics{type="SLOW_OPS",ceph_daemon="osd.0"} > 0` 第一次出現 ≥ 注入起 +35s；加上 for:1m 與 eval，`CephDaemonSlowOps` 可 fire 時刻 ≥ 注入起 +95s。對照 R3（for:0）可 fire 時刻 ≈ SLOW_OPS 出現 +15s 內。
- Evidence:
- Artifacts:
- Notes: R1 在同一事件的可判真時刻也一併量（預測 op 首批 >5s 完成後 ≤30s）。

### H-006: `ceph_osd_commit_latency_ms`/`ceph_osd_apply_latency_ms` 對 5~8s 暫態卡頓不可靠（更新粗、事件窗短，scrape 高機率錯過），對持續事件才有反應
- Status: predicted
- Tier: T1 + T3
- Origin: preliminary research（負面對照）
- Prediction: E-01 觀察窗內 `ceph_osd_commit_latency_ms{ceph_daemon="osd.0"}` max < 5000（抓不到 8s 事件的量級）；E-04 期間其 max ≥ 1000（持續事件看得到）。
- Evidence: T1 = `module.py:94`（OSD_STATS 路徑，來源是 pg dump osd_stat，OSD 報告週期粗）
- Artifacts:
- Notes: 「看似可用其實不行」的負面清單成員。

### H-007: `rate(op_w_latency_sum)/rate(count)` 區間均值在低負載時對單次卡頓敏感、高 IOPS 時被稀釋——不適合當主要偵測，適合當嚴重度分級輔助
- Status: predicted
- Tier: T3（事後以 E-01/E-04 資料計算，不另注入）
- Origin: preliminary research
- Prediction: E-01：`rate(ceph_osd_op_w_latency_sum{ceph_daemon="osd.0"}[1m])/rate(..._count[1m])` 峰值 ≥ 1s（16 併發、低 IOPS 下一批 8s op 拉高均值）；同窗其他 OSD 峰值 < 0.2s。E-04：均值持續 > 1s。
- Evidence:
- Artifacts:
- Notes: 稀釋論證走 T1 數學（單 op 貢獻 = stall/ops_per_window），報告呈現。

### H-008: `BLUESTORE_SLOW_OP_ALERT`（threshold=1、lifetime=24h latch）會在事件後持續掛著（不自動清除），出現在 `ceph_health_detail`；適合盤後追查、不適合快速 pager
- Status: predicted
- Tier: T3
- Origin: preliminary research + 先前 SP「BlueStore 24h latch」踩雷記憶
- Prediction: E-01 之後 `ceph_health_detail{name="BLUESTORE_SLOW_OP_ALERT"} == 1` 出現並持續到實驗序列結束（>30min）不清除；restart osd.0 後 5 分鐘內轉 0。
- Evidence: T1 = `BlueStore.cc:18444-18453`（lifetime 86400s）
- Artifacts:
- Notes: 出現延遲不量化預測（health 傳播 + mgr cache 15s + scrape，估 <60s）。

### H-009: node_exporter 的 per-device 指標在 device 層看得到卡頓，可跨層佐證：多 VD 同時卡 → 指向控制器/firmware 而非單一碟
- Status: predicted
- Tier: T3（機制驗證）+ T2（歸因邏輯）
- Origin: framing-dialog（環境：10 SSD 一張 RAID 卡）
- Prediction: E-04 期間 `rate(node_disk_io_time_weighted_seconds_total{instance="ceph-lab-osd-01",device="dm-3"}[1m])` 明顯高於 baseline（≥5×）；E-01 的 8s suspend 在 [1m] rate 上也可見（io_time_weighted 累積 in-flight 時間）。
- Evidence:
- Artifacts:
- Notes: lab 無 RAID 卡；生產歸因邏輯（多 VD 同秒 vs 單 VD）以報告論證。

### H-010: 讀路徑卡頓由 `slow_read_wait_aio_count`/`slow_read_onode_meta_count` 覆蓋，寫路徑由 `slow_committed_kv_count`/`slow_aio_wait_count` 覆蓋——規則需同時看 4 個 counter
- Status: predicted
- Tier: T1（已錨定）+ T3
- Origin: preliminary research
- Prediction: E-01 寫負載 → 增量主要落在 `slow_committed_kv_count`（或 aio_wait）；讀負載段（rados bench seq read + suspend）→ 增量落在 `slow_read_*`。
- Evidence: T1 = 讀路徑 `BlueStore.cc:12751-12756,13113-13118`；寫 `14471-14479`；aio wait `14175`
- Artifacts:
- Notes: E-01 附一段讀負載注入（同一 fault 機制、負載型態為變因）。

### H-011: op 若永遠不完成（真正 hang 死），4 個 slow counter 全程不動——counter 只在 op「完成且量到 >5s」時記帳；硬卡死只有 op-tracker SLOW_OPS 看得到
- Status: predicted
- Tier: T1 + T3
- Origin: matrix "bluestore × crash(hang) × counter path"
- Prediction: E-04 硬節流段（wiops=1 的前 60s，op 幾乎不完成）：`increase(slow_*_count[1m])` ≈ 0（≤1 次零星），同時 SLOW_OPS > 0；解除節流後 60s 內 counter 爆量（排隊 op 完成）。
- Evidence: T1 = log_latency 全部呼叫點都在完成路徑（`BlueStore.cc` 枚舉見 H-014）
- Artifacts:
- Notes: 證明 R1 與 R3 互補、缺一不可。E-04 分兩段：wiops=1（硬卡）→ wiops=8（trickle）。

### H-012: slow 事件發生後 ~15s 內 OSD 就 crash 的話，counter 增量來不及被 scrape（exporter 5s + scrape 10s 競態）→ 事件丟失，只剩 OSD down alert
- Status: proposed
- Tier: T1（推理即可）
- Origin: matrix "osd × crash × 訊號晚到"
- Prediction:
- Evidence:
- Artifacts:
- Notes: Gate 1 triage：不做 T3（時序競態 demo 價值低）；報告以管線時間常數推理，結論=此情境靠既有 OSD down alert 覆蓋。

### H-013: OSD process 凍結時 ceph-exporter 對該 OSD 回舊值（stale）而非缺值，exporter 的 up 仍 =1（observer lying/stale）
- Status: predicted
- Tier: T3
- Origin: matrix "ceph-exporter × lying"；axes.md「Observer lying / stale telemetry」
- Prediction: E-05（SIGSTOP osd.0 15s，無負載）：凍結期間 .169:9926/metrics 仍 200、osd.0 series 仍在且值不變（與凍結前相同）；`up{job=~".*ceph-exporter.*"}` 全程 1；SIGCONT 後 10s 內恢復更新。
- Evidence:
- Artifacts:
- Notes: 結果決定是否需要 staleness 防護規則（如 exporter 自身 metrics 或 absent()）。

### H-014: BlueStore 內多數 log_latency 呼叫點沒帶 idx2 → 存在「打 log + 觸發 BLUESTORE_SLOW_OP_ALERT、但 4 個 counter 都不動」的 slow 類別；寫路徑靠 txc 全程量測傳遞性覆蓋
- Status: confirmed
- Tier: T1
- Origin: negative-space（4 counter vs 全部 log_latency 呼叫點）
- Prediction: （T1 枚舉即為驗證）
- Evidence: 2026-07-09 枚舉 `BlueStore.cc` 全部 29 個 log_latency/log_latency_fn 呼叫點：帶 idx2 的僅 5 處（12368/12708/13080=read_onode_meta、12751/13113=read_wait_aio、14471=committed_kv）+ 直接 inc 1 處（14175=aio_wait）；其餘 23 處（omap iterator ×8、read_lat ×2、csum、decompress、clist、kv_flush/kv_commit/kv_sync/kv_final、submit/throttle_transact、compress、allocator、get_onode@readv=13002）只 log + `_add_slow_op_event()`。`_add_slow_op_event()` 在 log_latency 內無條件呼叫（18480）→ health alert 涵蓋全部類別。
- Artifacts: 報告「訊號地圖」一節
- Notes: 實務影響：kv_sync 慢（裝置 fsync 卡）不直接進 counter，但只要有 write txc 在飛，txc commit 全程量測（start→committed）會把同一事件記進 `slow_committed_kv_count`；純 omap/scrub 類 slow 事件是 counter 盲區、僅 health alert 可見。

### H-015: 純負載（recovery/backfill/compaction/過載）也能把單段 op 推過 5s → R1 false positive；「單 node vs 多 node」+ 持續性可作區分
- Status: predicted
- Tier: T3（負向對照）+ T2
- Origin: pre-mortem（pager fatigue → 靜音 → 真事件漏掉）
- Prediction: E-00（全速 rados bench 90s 無注入）：全叢集 `increase(slow_*_count[5m])` == 0（lab virtio 碟全速負載不產生 >5s 單段延遲）。
- Evidence:
- Artifacts:
- Notes: lab 結果只證「這個 lab 不 FP」；生產 FP 風險與 severity 分級寫進報告（T2）。

### H-016: `bluestore_log_op_age` 可 runtime 調低（如 2s）提高對 <5s 卡頓的靈敏度、不需重啟 OSD；預設 5s 下 3s 卡頓完全不可見
- Status: predicted
- Tier: T1 + T3
- Origin: negative-space（5s 門檻以下的事件全不可見）
- Prediction: E-06a（預設 5s、suspend 3s、有負載）：counter 零增量。E-06b（`ceph config set osd.0 bluestore_log_op_age 2` 後同樣注入）：counter 增量 ≥1。config rm 後恢復。
- Evidence: T1 = `log_latency` 每次呼叫都讀 `cct->_conf->bluestore_log_op_age`（legacy conf 值，config observer 更新後即生效）
- Artifacts:
- Notes: 若成立 → 生產可把門檻調到貼近 SSD 預期延遲（例如 1~2s）做更早偵測；代價（log 量、FP）寫報告。

### H-017: 卡住的 device 上若當下沒有 IO 經過（idle OSD），counter 與 op-tracker 都無訊號——「無 IO 即無偵測」是結構性盲區
- Status: predicted
- Tier: T1（推理）+ T3（描述性）
- Origin: matrix "SSD/firmware × slow × 無觀測流量"
- Prediction: E-03（suspend osd.0 15s、叢集無 client 負載）：觀察窗內 4 counter 增量 == 0 且 SLOW_OPS == 0（BlueStore 內部背景 IO 可能造成零星例外；若出現，記錄來源）。
- Evidence:
- Artifacts:
- Notes: 緩解（週期性 synthetic IO，如低頻 rados bench cron）超出 Prometheus-only scope，報告列建議。

### H-018: 事件當下 active mgr failover 會讓 `ceph_health_detail`/`ceph_daemon_health_metrics` 空窗，但 ceph-exporter 路徑（per-host）不受影響——兩管線互相獨立
- Status: proposed
- Tier: T1（架構推理）
- Origin: matrix "mgr × crash × 訊號不到"
- Prediction:
- Evidence:
- Artifacts:
- Notes: Gate 1 triage：不做 T3（mgr failover 對 lab 序列干擾大、架構層面已可論證：ceph-exporter 直讀各 host admin socket，與 mgr 無關）。報告帶一句「counter 規則同時是 health 規則的 mgr-failover 備援」。

### H-019: 4 個 slow counter 是 Squid（19.2.0+）才有；`BLUESTORE_SLOW_OP_ALERT` 是 19.2.1+/Reef 18.2.6+ 才有——生產環境版本決定可用訊號
- Status: confirmed
- Tier: T2
- Origin: pre-mortem（報告照抄到生產卻沒這個 metric）
- Prediction: （版本比對即驗證）
- Evidence: 2026-07-09 GitHub raw 比對：`l_bluestore_slow_aio_wait_count` 在 v19.2.0/v19.2.1 存在、v18.2.7 不存在；`BLUESTORE_SLOW_OP_ALERT` 在 v19.2.1/v18.2.6/v18.2.7 存在、v19.2.0/v18.2.5/v18.2.4 不存在。
- Artifacts: 報告「版本依賴」一節
- Notes: Reef 使用者 fallback：op 均值 + node_disk + SLOW_OPS 加速版（R3）。

### H-020: OSD 重啟造成的 counter reset 不會讓 `increase()` 假陽性；`keep_firing_for` 可把單發事件 alert 撐住觀察窗（lab Prometheus v2.51.0 支援）
- Status: predicted
- Tier: T3
- Origin: persona "Prometheus 專家"
- Prediction: 實驗序列末端 restart osd.0：counter 從 >0 歸 0，重啟後 5 分鐘窗內 R1 表達式不為真（increase 對 reset 的處理不產生正增量假訊號）。
- Evidence: Prometheus v2.51.0 ≥ 2.42（keep_firing_for OK，T3 已確認版本）
- Artifacts:
- Notes: promtool unit test 另行覆蓋 reset 情境。

### H-021: `ceph_disk_occupation` 可把 OSD join 到 node_exporter 的 device series → alert 可標注「哪台 node 哪顆 device」；device 層指標在卡頓窗內同步異常
- Status: predicted
- Tier: T3
- Origin: matrix "觀測路徑 × 跨層對齊"
- Prediction: (a) `ceph_disk_occupation{ceph_daemon="osd.0"}` 存在且 device/instance label 對得上 dm-3/ceph-lab-osd-01（或其 sdX parent）；(b) E-04 期間 join 表達式可算出該 device 的 io_time rate 異常。
- Evidence:
- Artifacts:
- Notes: 生產（10 VD 一張卡）：多 device 同窗異常 → 控制器嫌疑；單 device → 單碟嫌疑。

### H-022: 1m~2m 窗的聚合就足以區分「單 node 多 OSD 同時卡」（firmware/控制器指紋）與「跨 node 大範圍變慢」——不需秒級對齊
- Status: predicted
- Tier: T3
- Origin: matrix "time × partial"（scrape 相位使秒級對齊不可觀測）
- Prediction: E-02 的 R2 `count by (instance)` == 3 且僅 osd-01 一個 instance 出現；E-01 時 R2 無 series。跨 node 情境以 T1 論證（R2 的 count by instance 天然把跨 node 事件拆成多個 <3 的 group，除非每台都 ≥3 顆同時卡——那已是叢集級事件，另有 SLOW_OPS/health 規則）。
- Evidence:
- Artifacts:
- Notes:

## 實驗總覽（Automate 階段）

| ID | 目的（假設） | 注入（單一 fault） | 變因/參數 | 負載 | 預期核心訊號 |
|---|---|---|---|---|---|
| E-00 | H-015 負向對照 | 無 | — | rados bench 全速 write 90s + seq read 60s | 全部 slow counter 零增量 |
| E-01 | H-001/002/003/006/007/008/010 | `dmsetup suspend dm-3(osd.0)` 8s ×2（write 段 + read 段） | 單 OSD、暫態 | bench write 16 併發；讀段 seq read | `slow_committed_kv/slow_read_*` +N；SLOW_OPS 全程 0；R1 ≤30s 可判真 |
| E-02 | H-004/022 | 同秒 suspend dm-1/2/3（osd.0/1/2）8s | 同 node 3 OSD | bench write | R2 count==3, instance=osd-01 |
| E-03 | H-017 | suspend dm-3 15s | 無負載 | 無 | 所有訊號靜默（結構性盲區實證） |
| E-04 | H-005/006/007/009/011/021 | cgroup io.max osd.0：段1 wiops=1 60s（硬卡）→ 段2 wiops=8 120s（trickle） | 持續慢盤、兩段強度 | bench write | 段1: SLOW_OPS>0 且 counter≈0；段2: counter 連續增；R3 vs 舊規則延遲差 |
| E-05 | H-013 | SIGSTOP ceph-osd(osd.0) 15s | process 凍結 | 無 | exporter 回 stale 值、up==1 |
| E-06 | H-016 | suspend dm-3 3s（a: 預設 5s；b: log_op_age=2） | 偵測門檻 | bench write | a: 零增量；b: ≥1 增量 |

共同紀律：pre-check（HEALTH_OK、9 up、無 recovery、對象 OSD ok-to-stop）→ baseline 快照 → 注入 → 觀察 → collect（bundle 先於 cleanup）→ rollback（以觀測狀態驗證：dmsetup info=ACTIVE / io.max=max / SIGCONT 後 state=S）→ assert（HEALTH_OK + bench 恢復）。E-01 之後 `BLUESTORE_SLOW_OP_ALERT` 預期 latch（H-008），不阻擋後續（記錄在 assert 豁免清單），序列末端 restart osd.0 清除 + 驗 H-020。
