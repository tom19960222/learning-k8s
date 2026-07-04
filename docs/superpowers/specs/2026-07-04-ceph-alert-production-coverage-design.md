# Ceph alert 工廠級 production 覆蓋 — design spec

日期：2026-07-04
狀態：使用者離線，依「都用你推薦的做」偏好由 AI 決定細節並全程執行。
前置：`prometheus-alert-design.mdx` 的兩層設計（`ceph-stability-first` + `ceph-scoped-availability`）與 `experiments/ceph-alert-real-lab` 真機 harness 已存在；已真機驗證的只有 `CephClientBlocked`（SLOW_OPS、PG_AVAILABILITY 兩路）與 `CephMonQuorumLost`。

## 情境設定

工廠生產關鍵系統：要求 0 downtime，每台 VM 掉 2 個 ping 都會被質詢。這改變兩件事：

1. **早期訊號跟出事訊號一樣重要**——latency 異常、網路 heartbeat 變慢、容量趨勢，都要在變成 outage 前被看到。
2. **寧願多監控，不要漏監控**——多幾條 Slack 級訊號可以接受；漏一類故障不可接受。

驗收標準（使用者明訂）：**每一條 alert rule 都必須在 ceph-lab 真叢集上，用真實故障注入讓它 firing 並送達正確 receiver 才算數**。不接受模擬或假 metric。lab 可以有 downtime。

## 偵察結果（2026-07-04 實測）

- 叢集 HEALTH_OK：3 mon（.166/.167/.164）、2 mgr（active=mon-01 .166、standby=mon-02 .167）、9 OSD × 100 GiB，使用率 ~0.04%。
- **重大發現：standby mgr 的 `:9283` 回 HTTP 200 + 空 body。** lab Prometheus 只 scrape `.167`，而 active mgr 已 failover 到 `.166` —— 現在的 lab 監控是「`up==1` 但零 ceph metric」的全盲狀態，任何 alert 都不會叫。這正是本設計要補的第一個洞。
- mgr exporter 有：per-OSD `ceph_osd_commit_latency_ms`/`apply_latency_ms`、`ceph_mgr_status`（1=active/0=standby）、`ceph_cluster_total_bytes`/`used`、per-pool `ceph_pg_*` 狀態 gauge（含 `inconsistent`/`down`/`stale`/`unknown`/`incomplete`/`peered`）、`ceph_num_objects_unfound`、`ceph_pool_quota_bytes`、`ceph_daemon_health_metrics`、`ceph_osd_flag_*`。
- mgr exporter **沒有**：mon election 計數、per-daemon perf counter、任何 node 層 metric。
- node-exporter（:9100）與 ceph-exporter（:9926）都未部署。
- mon host 根磁碟 free ≈ 82%（`mon_data_avail_warn` 測試可行）。
- 本機有 promtool；`experiments/ceph-alert-rules` 已有 Tier A（promtool）/ Tier B（routing）測試架構與 `_default-mixin.yml`。

## 故障模式分類 → 現況 → 缺口

### A. 監控系統自身失明（meta-risk，實測正在發生）

| 故障 | 現況 | 缺口/決定 |
|---|---|---|
| scrape 對到 standby mgr（200+空 body，`up==1`） | 無任何訊號 | scrape **所有** mgr host；新增 `CephMetricsAbsent`（`absent(ceph_health_status)`）當生命線 page |
| 所有 exporter 端點死亡 | `CephExporterDown`（單 target `up==0`）語意在多 target 下錯 | 拆成 `CephExporterAllDown`（全滅，page）+ `CephExporterTargetDown`（單點，Slack） |
| Prometheus / Alertmanager 自己掛 | 無 | `Watchdog`（`vector(1)` 恆 firing）→ 專用 receiver，文件註明接外部 dead-man switch；lab 驗證恆 firing 送達 |

### B. 硬體 — 磁碟

| 故障 | 現況 | 缺口/決定 |
|---|---|---|
| 磁碟整顆死（OSD down） | scoped rules 已設計，**未進 lab、未測** | 部署進 lab；S4/S5 真機測（單顆 vs 整台、`unless` 去重斷言） |
| 磁碟變慢（degrading；工廠最想早知道） | 只有 SLOW_OPS（出事後訊號） | 新增 `CephOSDLatencyOutlier`（commit latency vs 叢集中位數，Slack 早期訊號）+ `CephDaemonSlowOps`（`ceph_daemon_health_metrics{type="SLOW_OPS"}>0`，帶 `ceph_daemon` label） |
| SMART / DEVICE_HEALTH_* | catch-all 蓋到 | VM lab 無 SMART，不可真機測 → 不開專屬 rule，文件記載由 catch-all 蓋、catch-all 機制本身有真機測 |
| OSD nearfull/backfillfull/full | catch-all 5m page（分級錯誤） | 專屬三級：`CephOSDNearFull`（Slack）/`CephOSDBackfillFull`（page）/ OSD_FULL 併入 `CephClientBlocked`（寫入真的被擋） |
| 容量趨勢（幾天內填滿） | 無 | 新增 `CephCapacityForecast`（`predict_linear` 72h 投影 > 85%，Slack） |
| pool quota 滿 | catch-all | `CephPoolNearQuota`（metric 比例，Slack）；POOL_FULL 併入 `CephClientBlocked` |
| mon store 磁碟低水位 | catch-all | `CephMonDiskLow`（Slack）/`CephMonDiskCritical`（page；mon 磁碟滿 = quorum 死亡前兆） |
| BlueStore spillover / fragmentation | catch-all 蓋到 | lab 無獨立 DB device，不可真機測 → 文件記載，不開專屬 rule |

### C. 網路

| 故障 | 現況 | 缺口/決定 |
|---|---|---|
| host 完全斷網 | 與 daemon down 同訊號（scoped rules） | S4/S5/S6 涵蓋偵測面 |
| 高 latency / 丟包（「掉 2 個 ping」場景） | catch-all 5m（太慢、無專屬 runbook） | 新增 `CephOSDSlowHeartbeat`（`OSD_SLOW_PING_TIME_BACK/FRONT`，2m page）；真機用 `tc netem` 注入 |
| 間歇斷線（NIC 抖動）→ OSD flapping | 無（up/down 震盪各自不滿 `for:`） | 新增 `CephOSDFlapping`（`changes(ceph_osd_up[15m])>=4`，join metadata 帶 hostname，page） |
| NTP 失聯 / clock step | catch-all | 新增 `CephMonClockSkew`（MON_CLOCK_SKEW，2m page；skew 會壞 quorum 與 cephx） |
| mon 間 election 風暴 | 無 metric（mgr exporter 不匯出） | **取捨**：不做 rule；文件記載需 ceph-exporter per-daemon perf counter 才可觀測，quorum 面由 `CephMonDownScoped`(30s) + `CephMonQuorumLost` 蓋 |

### D. 軟體 / daemon

| 故障 | 現況 | 缺口/決定 |
|---|---|---|
| daemon crash（segfault/OOM/assert） | catch-all 5m page（但 RECENT_CRASH 一掛 2 週，page 會訓練 oncall 無視 pager） | 重分類：`CephDaemonRecentCrash`（Slack + ticket）；反覆 crash 由 flapping/down rules page |
| mgr standby 全滅（失去 failover 能力） | 無 | 新增 `CephMgrNoStandby`（`count(ceph_mgr_status)<2`，Slack） |
| mgr failover 後監控連續性 | **壞的**（單 target） | multi-target scrape 修掉；S8 真機驗證 failover 中 metrics 不中斷 |
| catch-all（`CephClientRisk`）機制本身 | 從未真機測過 | S9 用 `mon_osd_down_out_interval=0` → `OSD_NO_DOWN_OUT_INTERVAL` 真機驗證 |
| `CephLowPriorityNotice` | 從未真機測過 | S10 用 `noout` → OSDMAP_FLAGS，等滿 30m 斷言只進 Slack |
| 版本不一致 / cephadm daemon 失敗 | catch-all 蓋到 | 不可安全注入（需舊版 binary）→ 文件記載 |

### E. 資料完整性（工廠關鍵）

| 故障 | 現況 | 缺口/決定 |
|---|---|---|
| scrub 不一致 / PG damaged | catch-all 5m + HealthError 5m（太慢、無 runbook） | 新增 `CephDataDamage`（`PG_DAMAGED\|OSD_SCRUB_ERRORS`，1m page，runbook 強調先找壞副本再 repair）；真機用 `ceph-objectstore-tool` 弄壞 test pool 單一 object 副本 |
| unfound objects（資料遺失中） | catch-all | 新增 `CephObjectUnfound`（1m page）；真機用 size=2/min_size=1 test pool 的「寫入→停 A→改寫→停 B→啟 A」標準手法誘發 |
| PG 結構異常（health 匯報路徑之外的第二訊號源） | 無 | 新增 `CephPGUnhealthyStates`（`down+incomplete+unknown+stale+peered > 0` per-pool，3m page）；在 S2 pg-availability 場景一併斷言 |

### F. 不進本輪 scope（文件記載於頁面「邊界」）

- node 層（NIC error、conntrack、CPU steal、memory pressure）：node-exporter 未部署；建議生產環境必加，本 SP 不做。
- RGW / MDS / RBD-mirror：lab 未部署對應 daemon，mixin 預設 rules 蓋，無法真機測。
- SMART、BlueStore spillover、DAEMON_OLD_VERSION、CEPHADM_*：不可安全/如實注入，由 catch-all 蓋並文件記載（catch-all 機制本身有真機證據）。
- per-daemon perf counter（含 mon election、op latency 分位數）：需部署 ceph-exporter(:9926)，記為 future work。

## Rule 設計總表

### 修改（`ceph-stability-first`）

| Rule | 變更 |
|---|---|
| `CephClientBlocked` | regex 擴為 `PG_AVAILABILITY\|SLOW_OPS\|OSD_FULL\|POOL_FULL`（後兩者寫入真的被擋，1m page） |
| `CephClientRisk` | 排除清單加入所有新開專屬 rule 的 name（OSD_SLOW_PING_TIME_BACK/FRONT、MON_CLOCK_SKEW、RECENT_CRASH、OSD_NEARFULL、OSD_BACKFILLFULL、OSD_FULL、POOL_FULL、POOL_NEARFULL、MON_DISK_LOW、MON_DISK_CRIT、PG_DAMAGED、OSD_SCRUB_ERRORS、OBJECT_UNFOUND、POOL_APP_NOT_ENABLED） |
| `CephLowPriorityNotice` | regex 加入 `POOL_APP_NOT_ENABLED`（config 衛生，不是 client 風險） |
| `CephExporterDown` | 拆為 `CephExporterAllDown`（`(count(up{job="ceph"} == 1) or vector(0)) == 0`，5m page）與 `CephExporterTargetDown`（單 instance `up==0`，15m Slack）。多 mgr target 下舊語意（單 target up==0 就 page）會在 standby host 維護時誤 page |

### 新 group：`ceph-production-coverage`（`source: ceph_coverage`）

| Rule | expr 概要 | for | 級別/receiver | 真機場景 |
|---|---|---|---|---|
| `CephMetricsAbsent` | `absent(ceph_health_status)` | 5m | critical/pager | S7 disable prometheus module |
| `Watchdog` | `vector(1)` | 0 | none/watchdog receiver | S22 baseline 斷言恆送達 |
| `CephOSDSlowHeartbeat` | `ceph_health_detail{name=~"OSD_SLOW_PING_TIME_(BACK\|FRONT)"} == 1` | 2m | critical/pager | S12 `tc netem delay` |
| `CephOSDFlapping` | `changes(ceph_osd_up[15m]) >= 4`，join `ceph_osd_metadata` 帶 hostname | 0 | critical/pager | S15 連續重啟 OSD ×2 |
| `CephMonClockSkew` | `ceph_health_detail{name="MON_CLOCK_SKEW"} == 1` | 2m | critical/pager | S13 停時間同步 + `date` step |
| `CephOSDLatencyOutlier` | commit latency > max(3×叢集中位數, 100ms) | 10m | warning/slack | S11 輕度 cgroup 限速 + bench |
| `CephDaemonSlowOps` | `ceph_daemon_health_metrics{type="SLOW_OPS"} > 0` | 3m | warning/slack | S1 既有 slow-ops 場景加斷言 |
| `CephDaemonRecentCrash` | `ceph_health_detail{name="RECENT_CRASH"} == 1` | 5m | warning/slack | S14 `kill -SEGV` OSD |
| `CephMgrNoStandby` | `(count(ceph_mgr_status) or vector(0)) < 2` | 5m | warning/slack | S8 停 standby mgr |
| `CephOSDNearFull` | `ceph_health_detail{name="OSD_NEARFULL"} == 1` | 10m | warning/slack | S16 容量階梯 |
| `CephOSDBackfillFull` | `ceph_health_detail{name="OSD_BACKFILLFULL"} == 1` | 5m | critical/pager | S16 |
| `CephMonDiskLow` | `ceph_health_detail{name="MON_DISK_LOW"} == 1` | 10m | warning/slack | S21 調 `mon_data_avail_warn` |
| `CephMonDiskCritical` | `ceph_health_detail{name="MON_DISK_CRIT"} == 1` | 1m | critical/pager | S21 |
| `CephPoolNearQuota` | `ceph_pool_bytes_used > 0.8 * ceph_pool_quota_bytes and ceph_pool_quota_bytes > 0`（join pool name） | 10m | warning/slack | S17 quota pool |
| `CephCapacityForecast` | `predict_linear(ceph_cluster_total_used_bytes[1h], 259200) > 0.85 * ceph_cluster_total_bytes` | 30m | warning/slack | S18 持續 bench 寫入 |
| `CephDataDamage` | `ceph_health_detail{name=~"PG_DAMAGED\|OSD_SCRUB_ERRORS"} == 1` | 1m | critical/pager | S19 objectstore-tool 壞副本 |
| `CephObjectUnfound` | `ceph_health_detail{name="OBJECT_UNFOUND"} == 1` | 1m | critical/pager | S20 unfound 標準手法 |
| `CephPGUnhealthyStates` | per-pool `(down+incomplete+unknown+stale+peered) > 0` | 3m | critical/pager | S2 既有場景加斷言 |

備註：health-check 名稱類 rule 沿用 `ceph_health_detail` 的設計語言（與 v1 一致）；有更好 label 來源時（flapping/latency/pool quota）改用 metric 直接算，帶 `hostname`/`ceph_daemon`/pool label 以支援精準 silence。

### `ceph-scoped-availability`（既有設計，本輪納入 lab 真機驗證）

`CephOSDHostDownScoped` / `CephOSDDaemonDownScoped` / `CephMonDownScoped` — S4/S5/S6，含 `unless` 去重的「不該叫的沒叫」斷言。

### Routing v2 + inhibit

- routing 從 alertname regex 改成 **label 導向**：`severity="critical"` ∧ `source=~"ceph_stability|ceph_scoped|ceph_coverage"` → pager；`severity=~"warning|info"` → slack；`alertname="Watchdog"` → watchdog receiver；mixin 預設維持 `CephHealthError` → pager、其餘 → slack。新增 rule 不再需要改 routing（v1 的 regex 已經漏掉過新 rule 的風險）。
- inhibit：`CephMonQuorumLost` 抑制 `CephMonDownScoped`（quorum 已失守時單 mon 訊號是噪音）；在 S3 既有場景加斷言。
- lab 的 Prometheus rule_files 加載 mixin `_default-mixin.yml`（與頁面「已套用預設 rules」前提對齊）；`CephHealthError` 在 S16/S19 的 HEALTH_ERR 期間取得真機證據。

## 真機場景總表（每條 rule ≥ 1 真實 firing 證據）

既有擴充：S1 slow-ops（+`CephDaemonSlowOps`）、S2 pg-availability（+`CephPGUnhealthyStates`）、S3 mon-quorum-lost（+inhibit 斷言）。

新增：
- S4 單顆 OSD down（DaemonScoped fire、HostScoped 不 fire）
- S5 整台 OSD host down（HostScoped fire、DaemonScoped 不 fire）
- S6 單 mon down（MonDownScoped 30s fire、QuorumLost 不 fire）
- S7 exporter 全盲（disable prometheus module → MetricsAbsent + ExporterAllDown）
- S8 mgr failover 連續性 + 停 standby（MgrNoStandby）
- S9 catch-all（`mon_osd_down_out_interval=0` → OSD_NO_DOWN_OUT_INTERVAL → CephClientRisk）
- S10 low-priority（`noout` 30m → 只進 Slack、pager 靜默斷言）
- S11 latency outlier（輕度 io.max 限速 + rados bench）
- S12 slow heartbeat（`tc netem delay 1200ms`，**預先武裝 timed 自動回退**再注入）
- S13 clock skew（mon-03 停時間同步 + step +1.5s，timecheck 週期內出現）
- S14 daemon crash（SIGSEGV → RECENT_CRASH → `ceph crash archive-all` 回退）
- S15 OSD flapping（重啟 ×2 = 4 transitions）
- S16 容量階梯（bench 寫 ~2% → nearfull 0.01 → backfillfull 0.012 → full 0.015 → 逐級斷言 → 反序還原 → 刪 pool；full 期間同時取得 `CephClientBlocked{OSD_FULL}` 與 mixin `CephHealthError` 證據）
- S17 pool quota（近 quota → NearQuota；超 quota → POOL_FULL → ClientBlocked）
- S18 容量趨勢（持續寫 ~40m → Forecast fire → 清理）
- S19 資料損毀（objectstore-tool 對 test pool 單 object 壞副本 → deep-scrub → DataDamage → `pg repair` → clean）
- S20 unfound object（size=2/min_size=1 test pool 標準手法 → ObjectUnfound → 復原找回）
- S21 mon 磁碟（`mon_data_avail_warn` 85 → Low；`mon_data_avail_crit` 84 → Critical → 還原預設 30/5）
- S22 watchdog（baseline 斷言持續送達 watchdog receiver）

安全規範（全場景一致）：只動 test pool 與指定 daemon；注入前 `assert_lab_ready`、結束 `assert_lab_recovered`（HEALTH_OK gate）；trap 保證 rollback；網路/磁碟注入前預武裝 timed 自動回退；full-ratio 類先寫入小量資料再調閾值、還原順序 full→backfillfull→nearfull。

「調低閾值觸發」的正當性：S16/S21 改的是 Ceph 的 policy 閾值，讓 mon 對**真實磁碟/用量狀態**做出真實判定，整條 mon→health→mgr exporter→Prometheus→Alertmanager→receiver 管線都是真的；被禁止的是餵假 metric 或繞過管線，這裡沒有。

## 執行方式

- 依 `subagent-driven-development`：實作（rules YAML、render 函式、場景腳本、fake 測試、promtool Tier A/B 擴充、MDX）交給 Sonnet subagent，TDD + shellcheck + `run-tests.sh` 全綠。
- 真機注入由 orchestrator session 直接控制逐場景執行（CLAUDE.md：破壞性驗證不交給無法中斷的背景 subagent），每場景之間 HEALTH_OK gate。
- 文件：新增 feature 頁 `prometheus-alert-production-coverage.mdx`（分類表、新 group YAML、真機證據摘要），`prometheus-alert-design.mdx` 只做修訂差異（ClientBlocked regex、排除清單、Exporter 拆分、routing v2）+ 互鏈。
- 最終 gate：`run-tests.sh` + `shellcheck` + `make validate` 三綠才 commit/push。

## 明確的取捨記錄

1. `RECENT_CRASH` 從（實質上的）page 降為 Slack：RECENT_CRASH 未 archive 會掛 2 週，page 級會訓練 oncall 無視 pager；反覆 crash 的 page 面由 flapping/down/quorum rules 承擔。
2. mon election 風暴：mgr exporter 無此 metric，不硬做；記為 ceph-exporter future work。
3. DEVICE_HEALTH / spillover / OLD_VERSION：無法如實注入 → 不開專屬 rule（開了也違反「每條都要真機測過」），由 catch-all 蓋並在頁面記載。
4. `CephPGUnhealthyStates` 含 `peered`：讓 S2 能對它取證，且 peered 持續 >3m 本來就代表 I/O 停擺；短暫 peering 由 `for: 3m` 吸收。
5. 單機 Alertmanager、無外部 dead-man endpoint：lab 限制；頁面記載生產環境要 HA AM + 外部 watchdog 消費者。
