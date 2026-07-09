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

### H-011: op 若永遠不完成（真正 hang 死），4 個 slow counter 全程不動——counter 只在 op「完成且量到 >5s」時記帳，永久卡死只有 op-tracker SLOW_OPS 看得到
- Status: proposed
- Tier: T1 + T3
- Origin: matrix "bluestore × crash(hang) × counter path"
- Prediction:
- Evidence:
- Artifacts:
- Notes: 若成立 → 新規則是「補盲」不是「取代」，SLOW_OPS 規則必須保留。T1 錨點：log_latency 在 op 完成路徑上被呼叫。

### H-012: slow 事件發生後 ~20s 內 OSD 就 crash 的話，counter 增量來不及被 scrape（exporter 5s + scrape 15s 的競態）→ 事件本身丟失，只剩 OSD down alert
- Status: proposed
- Tier: T3
- Origin: matrix "osd × crash × 訊號晚到"
- Prediction:
- Evidence:
- Artifacts:
- Notes: firmware 卡頓惡化成 suicide timeout 的真實情境。驗證輔以 signal co-occurrence（axes.md 既有 failure class）。

### H-013: OSD 嚴重卡死時 admin socket 的 perf dump 也可能卡住 → ceph-exporter 對該 OSD 回舊值或缺值，但 exporter 的 up 仍 =1（observer lying）
- Status: proposed
- Tier: T3
- Origin: matrix "ceph-exporter × lying"；axes.md「Observer lying / stale telemetry」
- Prediction:
- Evidence:
- Artifacts:
- Notes: T3 用 SIGSTOP 凍結 OSD，觀察 exporter 對該 daemon 輸出什麼（缺 series？舊值？整個 /metrics 卡住?）。這決定要不要加 absent()/staleness 防護規則。

### H-014: BlueStore 內有 log_latency 呼叫點沒帶 idx2（不 inc 任何 slow counter）→ 存在「會打 log + 觸發 BLUESTORE_SLOW_OP_ALERT、但 4 個 counter 都不動」的 slow 類別
- Status: proposed
- Tier: T1
- Origin: negative-space（4 個 counter vs 全部 log_latency 呼叫點）
- Prediction:
- Evidence:
- Artifacts:
- Notes: T1 窮舉全部呼叫點與其 idx2；評估未覆蓋路徑是否會被 txc_commit_lat 這種「跨全程」的量測傳遞性覆蓋。

### H-015: 純負載（recovery/backfill/compaction/HDD 過載）也能把單段 op 推過 5s → slow counter 增加＝false positive；「單一 node vs 多 node 同時」+ recovery 指標可作區分器
- Status: proposed
- Tier: T3（注入負載對照）+ T2
- Origin: pre-mortem（alert 上線後狼來了 → 被靜音 → 真事件漏掉）
- Prediction:
- Evidence:
- Artifacts:
- Notes: 對應 persona=SRE 的 pager fatigue 視角；severity 分級要靠事件規模與持續性。

### H-016: `bluestore_log_op_age` 是 runtime 可調選項——調低（如 2s）可提高對 <5s 卡頓的靈敏度、不用重啟 OSD；代價是 log 量與 FP 上升
- Status: proposed
- Tier: T1 + T3
- Origin: negative-space（5s 門檻以下的事件全不可見）
- Prediction:
- Evidence:
- Artifacts:
- Notes: T1 錨點 `global.yaml.in`（with_legacy: true、無 runtime flag？需確認是否 runtime 生效）；T3 用 `ceph config set osd bluestore_log_op_age 2` + 注入 3s 卡頓驗證。

### H-017: 卡住的 device 上若當下沒有任何 IO 經過（idle OSD），4 個 counter 與 op-tracker 都不會有訊號——「無 IO 即無偵測」是 counter-based 方法的結構性盲區
- Status: proposed
- Tier: T1（推理）+ T3（描述性驗證）
- Origin: matrix "SSD/firmware × slow × 無觀測流量"
- Prediction:
- Evidence:
- Artifacts:
- Notes: heartbeat 不落盤所以幫不上。報告需明示此限制；緩解（如週期性 synthetic IO）超出 Prometheus-only scope，僅列為建議。

### H-018: 事件當下 active mgr 若正好 failover，`ceph_health_detail`/`ceph_daemon_health_metrics` 會有空窗，但 ceph-exporter 路徑（per-host）不受影響——兩條管線互相獨立
- Status: proposed
- Tier: T3
- Origin: matrix "mgr × crash × 訊號不到"
- Prediction:
- Evidence:
- Artifacts:
- Notes: 若成立，counter-based 規則同時是 health-based 規則的 mgr-failover 備援。

### H-019: 4 個 slow counter 是 Squid 才加入的——使用者生產環境若是 Reef 或更早，這些 metric 不存在，fallback 只能用 op 均值 + node_disk
- Status: proposed
- Tier: T2（查 PR / release notes / backport 狀態）
- Origin: pre-mortem（報告照抄到生產卻沒這個 metric）
- Prediction:
- Evidence:
- Artifacts:
- Notes: 使用者未提生產版本；報告必須標明版本依賴與 fallback 方案。

### H-020: counter-based 規則的機制細節在 lab 的 Prometheus 版本上成立：OSD 重啟造成的 counter reset 不會讓 `increase()` 假陽性；`keep_firing_for` 可用來把單發事件的 alert 撐住觀察窗
- Status: proposed
- Tier: T3
- Origin: persona "Prometheus 專家"（規則正確性 lens）
- Prediction:
- Evidence:
- Artifacts:
- Notes: cephadm 部署的 Prometheus 版本待確認（keep_firing_for 需 v2.42+）。

### H-021: `ceph_disk_occupation`（mgr module）可把 OSD join 到 node_exporter 的 device series → alert 可直接標注「哪台 node 哪顆 device」，且 device 層 `node_disk_io_time_weighted_seconds_total` 在卡頓窗內同步異常
- Status: proposed
- Tier: T3
- Origin: matrix "觀測路徑 × 跨層對齊"
- Prediction:
- Evidence:
- Artifacts:
- Notes: 生產情境（10 VD 一張卡）多 VD 同時異常 → 指向控制器；單 VD → 單碟。lab 無 RAID 卡，只驗 join 與 device 層反映機制。

### H-022: 以 1m 窗的聚合就足以區分「單一 node 多 OSD 同時卡」（firmware/控制器指紋）與「跨 node 大範圍變慢」（網路/負載）——不需要秒級對齊
- Status: proposed
- Tier: T3
- Origin: matrix "time × partial"（scrape 相位使秒級對齊不可得）
- Prediction:
- Evidence:
- Artifacts:
- Notes: Prometheus 各 target scrape 相位不同，「同一秒」在 metrics 層本來就不可觀測；驗證 1m 窗聚合的區分力。
