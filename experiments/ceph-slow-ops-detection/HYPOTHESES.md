# ceph slow ops 快速偵測（SSD firmware 暫態卡頓）— Hypothesis Backlog

## Charter

- **Goal**：只靠 Prometheus metrics，(a) 對「SSD firmware 造成的 BlueStore 暫態卡頓」（5~8 顆 OSD 在同一秒回報 op 卡 5~8 秒）做出可主動偵測的規則，(b) 對「真的會卡住 client 的一般 slow ops」把偵測延遲壓到事發後 30~60 秒內——且兩者都要在真機上量出實際偵測延遲。
- **Scope**：
  - in：ceph 內建可匯出的 metrics（mgr prometheus module、ceph-exporter）、node_exporter、Prometheus recording/alerting rules、偵測延遲量測、firmware 事件的「同秒多 OSD」指紋。
  - out：log-based 偵測（Loki 等）、SMART/RAID 卡帶外工具（storcli 等）、修 firmware 本身、client 端量測。
- **使用者事件描述**（framing 輸入）：生產環境 OSD node 為 10x SAS SSD 全掛在同一張 RAID 卡（無軟體 RAID）；發生過數次 5~8 顆 OSD 同一秒回報 BlueStore op 卡住 5~8 秒（「slow ops in bluestore」），疑似 SSD firmware 造成。
- **Version anchors**：ceph v19.2.3（repo submodule `ceph/` @ c92aebb）；lab = cephadm v19.2.3，3 mon（.166/.167/.164）+ 9 OSD（.169/.171/.174 各 3）。
- **Tiers available**：
  - T1：`ceph/` submodule 原始碼（pinned v19.2.3）。
  - T2：官方文件 / tracker / mailing list。
  - T3：真機 lab（可注入、可回退；monitoring stack **尚未部署**，需先 `ceph orch apply` prometheus + ceph-exporter + node-exporter，實驗後可 `ceph orch rm` 回退）。破壞性操作依 repo 規則：ok-to-stop → 注入 → 收集 → 立即回退 → HEALTH_OK。

### Gate 決策紀錄（使用者離線，依授權自主通過）

- Gate 1（backlog triage）：使用者已在任務描述中明確指定兩個目標並委託探索 unknown-unknowns，triage 由我依「與兩個目標的直接相關性」排序；全部決策記錄在各 hypothesis 的 Notes。
- Gate 2（破壞性操作）：lab cluster 為既有授權的驗證用叢集（先前 alert-coverage SP 已做過 22 條真機注入）；一律遵守可回退紀律，且不碰生產環境。
- Gate 3（findings triage）：報告全數呈現，由使用者事後裁決哪些進 alert rules / 專題頁。

## Preliminary research 摘要（T1 已錨定的事實）

| 事實 | 錨點 |
|---|---|
| BlueStore op 超過 `bluestore_log_op_age`（預設 **5s**）→ log「slow operation observed」+ `_add_slow_op_event()` + **inc 專用 perf counter** | `BlueStore.cc:18476-18484`（log_latency）、`18494-18506`（log_latency_fn） |
| 4 個專用 slow counter：`slow_aio_wait_count`、`slow_committed_kv_count`、`slow_read_onode_meta_count`、`slow_read_wait_aio_count`，全部 `PRIO_USEFUL`(5) | `BlueStore.cc:6456-6476`、`BlueStore.h:223-226` |
| txc 從 start 到 committed 超過 5s → `slow_committed_kv_count`++ | `BlueStore.cc:14471-14479` |
| `BLUESTORE_SLOW_OP_ALERT` health 警告：queue 內事件數 ≥ `bluestore_slow_ops_warn_threshold`（預設 1），事件保留 `bluestore_slow_ops_warn_lifetime`（預設 **86400s = 24h**，latch） | `BlueStore.cc:18444-18453`、`18899-18907`、`global.yaml.in:5447-5463` |
| SLOW_OPS health：op 齡 > `osd_op_complaint_time`（預設 **30s**）才計入；OSD 每 tick（~1s）算一次 → `mgrc.update_daemon_health()` | `OSD.cc:7825-7832`、`OSD.cc:6460`、`OSD.cc:2406` |
| ceph-exporter：每 `exporter_stats_period`（預設 **5s**）撈 admin socket，`exporter_prio_limit` 預設 **5**（`priority < 5` 才略過 → PRIO_USEFUL 會匯出），port 9926 | `ceph-exporter.yaml.in`、`DaemonMetricCollector.cc:116,164` |
| mgr prometheus module：`exclude_perf_counters` 預設 **True**（perf counters 交給 ceph-exporter）；模組自身 cache `scrape_interval` 預設 **15s** | `pybind/mgr/prometheus/module.py:589-596,607-609` |
| OSD `op_latency` prio 9、`op_r_latency`/`op_w_latency` 落在 `set_prio_default(PRIO_USEFUL)` 區段 → 都會被 ceph-exporter 匯出；line 131 之後的 counter 是 PRIO_DEBUGONLY → 不匯出 | `osd_perf_counters.cc:31,49-99,131` |
| BlueStore `txc_commit_lat`＝PRIO_CRITICAL → 匯出 | `BlueStore.cc:6217-6219` |

**核心推論（待 T3 驗證）**：`increase(ceph_bluestore_slow_committed_kv_count[...])` 這類表達式可以在「單次 5~8s 卡頓」發生後一個 scrape 週期內看到，不受 30s complaint 門檻限制——同時解決「firmware 暫態偵測」與「<30-60s 快速偵測」。

## 現有 alert 資產（避免重工）

`experiments/ceph-alert-rules/rules/`：`CephClientIOBlocked`（`ceph_health_detail{name="SLOW_OPS"}`, for:1m）、`CephDaemonSlowOps`（`max_over_time(ceph_daemon_health_metrics{type="SLOW_OPS"}[5m]) > 0`, for:1m）——兩者都吃 30s complaint 門檻 + health 傳播延遲，對 5~8s 暫態全盲。

## Hypotheses

### H-001: 5~8 秒的 BlueStore 卡頓永遠不會產生 SLOW_OPS health 警告（op 齡 < osd_op_complaint_time=30s），現有兩條 slow-ops alert 對此類事件 0 覆蓋
- Status: proposed
- Tier: T1（已有錨點）+ T3（實證）
- Origin: framing-dialog（使用者「該如何更主動偵測」的直接成因）
- Prediction:
- Evidence:
- Artifacts:
- Notes: T1 錨點 `OSD.cc:7832`（`too_old -= osd_op_complaint_time`）。T3 注入 5~8s 卡頓後 `ceph_health_detail{name="SLOW_OPS"}` 應全程為 0。

### H-002: `ceph_bluestore_slow_committed_kv_count` 等 4 個 counter 會被 lab 的 ceph-exporter 以預設設定匯出，且單次 >5s 卡頓會讓 counter +1
- Status: proposed
- Tier: T3
- Origin: framing-dialog + preliminary research
- Prediction:
- Evidence:
- Artifacts:
- Notes: 若成立，這是整個研究的地基。

### H-003: 以 slow counter 的 increase 做 alert，從「卡頓發生」到 Prometheus alert firing 的延遲 < 60s（op 完成 + exporter 5s + scrape 15s + rule eval）
- Status: proposed
- Tier: T3
- Origin: framing-dialog（<30-60s 目標）
- Prediction:
- Evidence:
- Artifacts:
- Notes: 需在 lab 實際量：注入時刻 → ALERTS{alertstate="firing"} 出現時刻。

### H-004: 「同一 node ≥3 顆 OSD 在同一個 scrape 窗內 slow counter 同時增加」可作為 firmware/RAID-卡層級事件的指紋，可與單一 OSD 事件區分
- Status: proposed
- Tier: T3
- Origin: framing-dialog（使用者事件形態：5~8 顆同一秒）
- Prediction:
- Evidence:
- Artifacts:
- Notes: lab 每 node 3 OSD，注入「同 node 全部 OSD 同時卡」vs「單一 OSD 卡」做對照。

### H-005: 現有 SLOW_OPS 鏈路（30s complaint + OSD→mgr→mon 傳播 + mgr 15s cache + scrape + for:1m）的端到端偵測延遲 ≥ 2 分鐘，即使 op 持續卡住
- Status: proposed
- Tier: T3
- Origin: framing-dialog（「發生當下更快偵測」的 baseline 量測）
- Prediction:
- Evidence:
- Artifacts:
- Notes: 用長時間卡頓（>60s）注入量測 baseline，對照新規則。

### H-006: `ceph_osd_commit_latency_ms`/`ceph_osd_apply_latency_ms`（mgr module 匯出的 gauge）對 5~8s 暫態卡頓不可靠（更新週期粗、事件窗短，scrape 高機率錯過）
- Status: proposed
- Tier: T1 + T3
- Origin: preliminary research（負面對照：排除看似可用其實不行的訊號）
- Prediction:
- Evidence:
- Artifacts:
- Notes:

### H-007: `rate(op_w_latency_sum)/rate(op_w_latency_count)` 這類區間均值在低負載時對單次卡頓極敏感（一個 6s op 拉爆均值），但在高 IOPS 時被稀釋——靈敏度依賴 op 混合，不適合做主要偵測，適合做輔助分級
- Status: proposed
- Tier: T3
- Origin: preliminary research
- Prediction:
- Evidence:
- Artifacts:
- Notes: BlueStore slow counter 是「事件計數」不會被稀釋，理論上優於均值；驗證此對比。

### H-008: `BLUESTORE_SLOW_OP_ALERT`（threshold=1、lifetime=24h latch）會在事件後掛 24 小時，適合「曾經發生」的盤後追查、不適合快速 pager；且它會出現在 `ceph_health_detail`
- Status: proposed
- Tier: T3
- Origin: preliminary research + 先前 SP 的「BlueStore 24h latch」踩雷記憶
- Prediction:
- Evidence:
- Artifacts:
- Notes: 若成立，規則設計要避免拿它當快訊號，但可當 low-priority 佐證。

### H-009: node_exporter 的 per-device 指標（`node_disk_io_time_weighted_seconds_total` 等）在 VD（RAID 卡邏輯碟）層看得到同秒卡頓，可做跨層佐證：多 VD 同時卡 → 指向控制器/firmware 而非單一碟
- Status: proposed
- Tier: T3
- Origin: framing-dialog（環境：10 SSD 一張 RAID 卡）
- Prediction:
- Evidence:
- Artifacts:
- Notes: lab 沒有真 RAID 卡，只能驗「注入的 device 層卡頓會反映在 node_disk_*」的機制，控制器歸因邏輯以 T1/T2 論證。

### H-010: 讀路徑卡頓由 `slow_read_wait_aio_count`/`slow_read_onode_meta_count` 覆蓋，寫路徑由 `slow_committed_kv_count`/`slow_aio_wait_count` 覆蓋——單一規則需同時看 4 個 counter 才不漏
- Status: proposed
- Tier: T1 + T3
- Origin: preliminary research
- Prediction:
- Evidence:
- Artifacts:
- Notes: T1 錨點：讀路徑 `BlueStore.cc:12751-12756,13113-13118`；aio wait `14175`。
