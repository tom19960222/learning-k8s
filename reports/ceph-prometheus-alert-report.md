# Ceph 儲存叢集告警系統：設計、驗證與真機故障演練報告

- **日期**：2026-07-07
- **狀態**：全部驗證完成（27 條 alert rule、22 個真機故障場景 22/22 通過）
- **對象讀者**：技術與非技術主管、全體同事（前半部不需要儲存或監控背景即可閱讀；技術細節集中在後半與附錄）
- **驗證聲明**：本報告所有數字與宣稱已逐一對照原始實驗數據複核（`experiments/*/results/` 原始 JSON、orchestrator 進度記錄、promtool / amtool 輸出）；無法由現有數據支撐的項目統一標記於附錄 E「待補實驗」

---

## 1. 執行摘要

我們為 Ceph 儲存叢集重新設計了一套 Prometheus 告警（alert）系統，解決「例行維護會半夜誤叫值班人員、真正的故障卻可能靜默」這個長期痛點。這套系統不是紙上設計：每一條規則都先在開發環境用工具逐條驗證邏輯，再到真實叢集上**製造 22 種真實故障**（磁碟變慢、節點斷線、資料損毀、容量寫爆、時鐘偏移……），親眼確認告警真的響、而且送到正確的人手上。

| 成果指標 | 數字 |
|---|---|
| 自訂 alert rule | **27 條**（6 條穩定性 + 3 條可精準靜音 + 18 條生產覆蓋） |
| 真機故障注入場景 | **22 個，22/22 全數通過** |
| 開發階段測試抓到的設計 bug | **1 個**（且是「最壞情況反而不叫」的致命型，上線前即修復） |
| 只有真機演練才現形的問題 | **16 個**（工具測試全綠、真實環境才暴露，全部已修正並回歸驗證） |
| 實驗後叢集狀態 | 完全復原至 `HEALTH_OK`，無任何殘留變更 |

**一句話總結**：這套告警現在做得到——例行維護時不吵人、真故障時一定叫人、連「監控系統自己壞掉」都會被發現；同時我們也誠實列出了它做不到的事（見第 8 節）。

---

## 2. 給非技術讀者的 60 秒背景

讀這份報告只需要知道六個名詞：

| 名詞 | 白話說明 |
|---|---|
| **Ceph** | 我們的共用儲存底座。許多虛擬機與服務的資料都放在它上面，它出問題等於上層全部受影響。 |
| **Prometheus** | 持續收集系統量測數據（metrics）的工具，例如「這顆硬碟延遲多少」「還剩多少容量」。 |
| **Alert rule** | 寫在 Prometheus 裡的判斷式，例如「延遲連續 5 分鐘超標就發告警」。本報告的核心產出就是 27 條這種規則。 |
| **Alertmanager** | 收到告警後決定「通知誰、用什麼管道」的元件。 |
| **Pager vs Slack** | 兩種通知等級。**Pager = 半夜也會把值班人員叫醒**；Slack = 上班時間看到再處理。把訊號分對等級，是這個專案的靈魂。 |
| **Silence（靜音）** | 計畫性維護時暫時關掉特定告警。本專案的關鍵改進之一：讓靜音可以**精準到只蓋住維護中的那一台機器**，而不是整類告警全關。 |

---

## 3. 前言：我們為什麼要做這件事

Ceph 官方其實已附帶一套預設告警規則（ceph-mixin）。拿來「看叢集健不健康」夠用，但拿來**當值班人員的 pager 訊號**，在實務上有三個痛點：

### 痛點一：例行維護的噪音，無法精準靜音

換一顆硬碟、重開一台機器，是儲存叢集的日常。但預設告警是「叢集級」的：維護任何一台機器，`CephOSDHostDown`、`CephMonDown` 這類告警就會響，而且——這是根本原因——**Ceph 匯出的健康狀態指標（`ceph_health_detail`）只有事件名稱，沒有「是哪一台機器」的標籤（label）**。Alertmanager 的靜音只能依 label 比對，所以你**無法只靜音維護中的那一台**。結果只剩兩個壞選項：忍受維護噪音，或粗暴地把整類告警全部靜音——後者等於維護那兩小時裡，其他機器真的壞了也沒人知道。

### 痛點二：告警疲勞——狼來了

一次換硬碟會連鎖觸發一整串告警（副本暫時少一份、保護旗標升起……）。當值班人員習慣了「告警響 = 大概又是維護」，真正的故障就會被淹沒。告警系統最貴的成本不是漏報，是**訓練出忽視告警的團隊**。

### 痛點三：最壞的情況，反而可能靜默

這是最反直覺、也最危險的一類問題。舉兩個本專案實際抓到的例子：

- 監控叢集共識（MON quorum）的規則，一種常見寫法在「所有 MON 全部掛掉」——最嚴重的情況——**反而算不出結果、不會觸發**（詳見第 6.1 節，這是我們在開發階段用測試抓到的真 bug）。
- 如果監控資料的匯出端（exporter）自己壞了，所有告警規則都沒有資料可算，整個告警系統會**無聲失明**——沒有任何一條規則會告訴你「我瞎了」。

**所以這個專案要做的事**：在保留官方預設規則（當作背景參考資訊）的前提下，加上一層維護友善、經過完整驗證的告警，並且把「監控系統自身的失效」也納入監控。

---

## 4. 我們設計了什麼

### 4.1 設計原則：不重寫，加一層；每條告警先分好「角色」

我們沒有丟掉官方預設規則，而是在它之上加一層。每一條告警在設計時就先回答：它屬於哪種角色？

| 角色 | 意思 | 例行維護時可以靜音嗎 |
|---|---|---|
| **Pager 主訊號** | 使用者的讀寫已被擋住、叢集共識失守、監控失明、明確的機器/服務下線 | 只有「帶機器標籤」的可以按目標精準靜音；其餘**不可**靜音 |
| **Slack / 工單參考** | 官方預設的叢集級告警、低優先提示 | 可短時間靜音降噪 |
| **維護可精準靜音** | 帶 `hostname` / `ceph_daemon` label 的機器級告警 | 維護時**只靜音目標那一台** |

### 4.2 三組規則 + 一張路由表

**第一組 `ceph-stability-first`（6 條）——使用者風險，多數不可靜音。** 核心是 `CephClientBlocked`：只要使用者的讀寫實際被擋（PG 不可用、操作嚴重變慢、容量寫死），1 分鐘內 page。搭配一條 catch-all `CephClientRisk` 接住「還沒被專屬規則接手、但會危及使用者」的其他健康檢查，以及 MON quorum 生命線、監控失明偵測、低優先提示。

**第二組 `ceph-scoped-availability`（3 條 + 2 條 recording rule）——解決「無法精準靜音」的那一組。** 技術關鍵：Ceph 的 metadata 指標（`ceph_osd_metadata` / `ceph_mon_metadata`）其實帶有 `hostname`，我們用 PromQL join 把「機器/服務下線」狀態接上機器名稱，讓告警 label 裡有 `hostname` / `ceph_daemon`——維護時就能只靜音那一台。同時用 `unless` 去重：整台機器掛掉時只發一條「host down」，不會該機器上每顆硬碟服務各叫一次。

**第三組 `ceph-production-coverage`（18 條）——生產環境覆蓋面。** 依六大故障模式分類補齊：**監控自身失明**（`CephMetricsAbsent`、永遠心跳的 `Watchdog` 接 dead-man switch）、**硬體**（延遲離群、容量三級警戒、3 天容量趨勢預測）、**網路**（心跳變慢、服務反覆上下線、時鐘偏移）、**軟體**（daemon crash、mgr 無備援）、**資料完整性**（資料損毀、物件遺失）、**PG 健康狀態**。

**路由（routing）**：label 導向而非逐條列名——自訂規則中 `severity=critical` 的進 pager；warning/info 進 Slack；官方預設規則一律只進 Slack（唯一例外：`CephHealthError` 保留當 pager 總開關）；`Watchdog` 走獨立管道給外部的 dead-man switch 監視「告警系統本身還活著」。新增規則時只要 label 標對，路由自動正確。

### 4.3 完整的 27 條 alert rule 總覽

圖例：🔴 = pager（叫醒值班）、🔵 = Slack、⚪ = watchdog 專用管道。「驗證場景」對應第 6 節的真機故障注入編號。

| # | Alert | 白話意義 | 等級 / 去向 | 持續門檻 | 驗證場景 |
|---|---|---|---|---|---|
| 1 | `CephClientBlocked` | 使用者讀寫已被擋（PG 不可用 / 操作過慢 / 容量寫死） | critical 🔴 | 1m | S1·S2·S16·S17 |
| 2 | `CephClientRisk` | 其餘會危及使用者的健康檢查（catch-all） | critical 🔴 | 5m | S9 |
| 3 | `CephMonQuorumLost` | 叢集共識（quorum）失守的生命線 | critical 🔴 | 1m | S3 |
| 4 | `CephExporterAllDown` | 監控資料來源全部失聯（告警失明） | critical 🔴 | 5m | S7 |
| 5 | `CephExporterTargetDown` | 單一監控來源失聯 | warning 🔵 | 15m | ⚠️ 無專屬場景（附錄 E） |
| 6 | `CephLowPriorityNotice` | 低優先提示（維護旗標、資料搬移中…） | info 🔵 | 30m | S10 |
| 7 | `CephOSDHostDownScoped` | 整台儲存機器下線（帶 hostname，可精準靜音） | critical 🔴 | 5m | S5 |
| 8 | `CephOSDDaemonDownScoped` | 單顆儲存服務（OSD）下線（帶 daemon 名） | critical 🔴 | 5m | S4 |
| 9 | `CephMonDownScoped` | 單台共識節點（MON）下線（帶 hostname） | critical 🔴 | 30s | S6 |
| 10 | `CephMetricsAbsent` | Ceph 指標從監控中消失（盲飛偵測） | critical 🔴 | 5m | S7 |
| 11 | `Watchdog` | 永遠觸發的心跳，供外部 dead-man switch 反向監視告警系統 | none ⚪ | — | S22 |
| 12 | `CephOSDSlowHeartbeat` | 儲存節點間網路心跳變慢 | critical 🔴 | 2m | S12 |
| 13 | `CephOSDFlapping` | OSD 反覆上下線（15 分鐘內 ≥4 次） | critical 🔴 | — | S15 |
| 14 | `CephMonClockSkew` | 節點時鐘偏移 | critical 🔴 | 2m | S13 |
| 15 | `CephOSDLatencyOutlier` | 單顆 OSD 延遲明顯高於群體（壞碟前兆） | warning 🔵 | 10m | S11 |
| 16 | `CephDaemonSlowOps` | 個別 daemon 有慢操作（5 分鐘窗化） | warning 🔵 | 1m | S1 |
| 17 | `CephDaemonRecentCrash` | daemon 近兩週內曾 crash | warning 🔵 | 5m | S14 |
| 18 | `CephMgrNoStandby` | 管理服務（mgr）失去備援 | warning 🔵 | 5m | S8 |
| 19 | `CephOSDNearFull` | OSD 接近容量警戒線 | warning 🔵 | 10m | S16 |
| 20 | `CephOSDBackfillFull` | OSD 已滿到無法進行資料修復 | critical 🔴 | 5m | S16 |
| 21 | `CephMonDiskLow` | MON 資料磁碟空間偏低 | warning 🔵 | 10m | S21 |
| 22 | `CephMonDiskCritical` | MON 資料磁碟空間危急 | critical 🔴 | 1m | S21 |
| 23 | `CephPoolNearQuota` | 儲存池用量超過配額 80% | warning 🔵 | 10m | S17 |
| 24 | `CephCapacityForecast` | 依趨勢預測 3 天內容量將超過 85% | warning 🔵 | 30m | S18 |
| 25 | `CephDataDamage` | 偵測到資料損毀（scrub 錯誤，5 分鐘窗化） | critical 🔴 | 1m | S19 |
| 26 | `CephObjectUnfound` | 有物件的最新版本找不到任何副本 | critical 🔴 | 1m | S20 |
| 27 | `CephPGUnhealthyStates` | 資料分片（PG）處於不健康狀態 | critical 🔴 | 3m | S2 |

另保留官方 ceph-mixin 預設規則做為 Slack 參考資訊，其中 `CephHealthError`（叢集進入 `HEALTH_ERR`）保留為 pager 總開關。

<details>
<summary><strong>📄 完整 Prometheus rules set（點開展開，5 個檔案、逐字與版本庫一致）</strong></summary>

#### `ceph-stability-first.yml` — 使用者風險（6 條）

```yaml
# 逐字取自 next-site/content/ceph/features/prometheus-alert-design.mdx
# §「ceph-stability-first：client 風險，多數不可 silence」
# 被測物 — 不得改寫。lib/check-rules-match-page.sh 會比對。
groups:
  - name: ceph-stability-first
    rules:
      - alert: CephClientBlocked
        expr: ceph_health_detail{name=~"PG_AVAILABILITY|SLOW_OPS|OSD_FULL|POOL_FULL"} == 1
        for: 1m
        labels:
          severity: critical
          source: ceph_stability
        annotations:
          summary: "Ceph client I/O blocked: {{ $labels.name }}"

      - alert: CephClientRisk
        expr: |
          ceph_health_detail{
            name!~"PG_AVAILABILITY|SLOW_OPS|OSD_FULL|POOL_FULL|OSD_DOWN|OSD_HOST_DOWN|MON_DOWN|HOST_IN_MAINTENANCE|OBJECT_MISPLACED|PG_SLOW_SNAP_TRIMMING|PG_DEGRADED|OSDMAP_FLAGS|POOL_APP_NOT_ENABLED|POOL_NEARFULL|OSD_SLOW_PING_TIME_BACK|OSD_SLOW_PING_TIME_FRONT|MON_CLOCK_SKEW|RECENT_CRASH|OSD_NEARFULL|OSD_BACKFILLFULL|MON_DISK_LOW|MON_DISK_CRIT|PG_DAMAGED|OSD_SCRUB_ERRORS|OBJECT_UNFOUND"
          } == 1
        for: 5m
        labels:
          severity: critical
          source: ceph_stability
        annotations:
          summary: "Ceph client-risk check active: {{ $labels.name }}"

      - alert: CephMonQuorumLost
        # FIX (F1)：原 `count(ceph_mon_quorum_status == 1) < 2` 在全部 mon 掛掉時，
        # 內層 ==1 過濾為空，count(空) 無 sample，< 2 算不出結果 → 不 fire（最壞情況靜默）。
        # `or vector(0)` 讓空 count 退回 0，quorum 全失守照樣 page。promtool 實證見測試。
        expr: (count(ceph_mon_quorum_status == 1) or vector(0)) < 2
        for: 1m
        labels:
          severity: critical
          source: ceph_stability
        annotations:
          summary: "Ceph MON quorum lost or below 3-mon majority"

      - alert: CephExporterAllDown
        expr: (count(up{job="ceph"} == 1) or vector(0)) == 0
        for: 5m
        labels:
          severity: critical
          source: ceph_stability
        annotations:
          summary: "All Ceph Prometheus exporter targets are down"

      - alert: CephExporterTargetDown
        expr: up{job="ceph"} == 0
        for: 15m
        labels:
          severity: warning
          source: ceph_stability
        annotations:
          summary: "Ceph exporter target {{ $labels.instance }} is down"

      - alert: CephLowPriorityNotice
        expr: |
          ceph_health_detail{
            name=~"HOST_IN_MAINTENANCE|OBJECT_MISPLACED|PG_SLOW_SNAP_TRIMMING|PG_DEGRADED|OSDMAP_FLAGS|POOL_APP_NOT_ENABLED|POOL_NEARFULL"
          } == 1
        for: 30m
        labels:
          severity: info
          source: ceph_stability
        annotations:
          summary: "Ceph low-priority notice: {{ $labels.name }}"
```

#### `ceph-scoped-availability.yml` — 可精準靜音的機器級告警（3 條 alert + 2 條 recording rule）

```yaml
# 逐字取自 next-site/content/ceph/features/prometheus-alert-design.mdx
# §「ceph-scoped-availability：帶 label，維護可精準 silence」
# 被測物 — 不得改寫。lib/check-rules-match-page.sh 會比對。
groups:
  - name: ceph-scoped-availability
    rules:
      - record: ceph:osd_up:with_hostname
        expr: |
          ceph_osd_up
            * on (ceph_daemon) group_left(hostname) ceph_osd_metadata

      - record: ceph:osd_host_down:scoped
        expr: |
          count by (hostname) (ceph:osd_up:with_hostname == 0)
          ==
          count by (hostname) (ceph:osd_up:with_hostname)

      - alert: CephOSDHostDownScoped
        expr: ceph:osd_host_down:scoped
        for: 5m
        labels:
          severity: critical
          source: ceph_scoped
        annotations:
          summary: "Ceph OSD host down: {{ $labels.hostname }}"
          runbook: "ceph osd tree; ceph health detail; check host power/network/systemd"

      - alert: CephOSDDaemonDownScoped
        expr: |
          (ceph:osd_up:with_hostname == 0)
          unless on (hostname) ceph:osd_host_down:scoped
        for: 5m
        labels:
          severity: critical
          source: ceph_scoped
        annotations:
          summary: "Ceph OSD down: {{ $labels.ceph_daemon }} on {{ $labels.hostname }}"
          runbook: "ceph osd tree; ceph osd ok-to-stop {{ $labels.ceph_daemon }}; inspect daemon log"

      - alert: CephMonDownScoped
        expr: |
          (
            (1 - ceph_mon_quorum_status)
              * on (ceph_daemon) group_left(hostname) ceph_mon_metadata
          ) == 1
        for: 30s
        labels:
          severity: critical
          source: ceph_scoped
        annotations:
          summary: "Ceph MON down or out of quorum: {{ $labels.ceph_daemon }} on {{ $labels.hostname }}"
          runbook: "ceph quorum_status; ceph health detail; inspect mon log and host network"
```

#### `ceph-production-coverage.yml` — 生產覆蓋（18 條）

```yaml
# 逐字取自 docs/superpowers/plans/2026-07-04-ceph-alert-production-coverage.md 的 Task 3 段落。
# 完整說明留給後續新頁面（Ceph - 真機故障注入後的 alert 韌性修訂）；被測物 — 不得改寫。
# lib/check-rules-match-page.sh 會比對本檔與設計頁的 load-bearing invariants。
groups:
  - name: ceph-production-coverage
    rules:
      - alert: CephMetricsAbsent
        expr: absent(ceph_health_status)
        for: 5m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph metrics absent from Prometheus (blind monitoring)"

      - alert: Watchdog
        expr: vector(1)
        labels:
          severity: none
          source: ceph_coverage
        annotations:
          summary: "Always-firing heartbeat; wire to external dead-man switch"

      - alert: CephOSDSlowHeartbeat
        expr: ceph_health_detail{name=~"OSD_SLOW_PING_TIME_BACK|OSD_SLOW_PING_TIME_FRONT"} == 1
        for: 2m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph OSD heartbeat pings are slow: {{ $labels.name }}"

      - alert: CephOSDFlapping
        expr: |
          (changes(ceph_osd_up[15m]) * on (ceph_daemon) group_left(hostname) ceph_osd_metadata) >= 4
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph OSD flapping: {{ $labels.ceph_daemon }} on {{ $labels.hostname }}"

      - alert: CephMonClockSkew
        expr: ceph_health_detail{name="MON_CLOCK_SKEW"} == 1
        for: 2m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph MON clock skew detected"

      - alert: CephOSDLatencyOutlier
        expr: |
          (
            ceph_osd_commit_latency_ms > 100
            and
            ceph_osd_commit_latency_ms > 3 * scalar(quantile(0.5, ceph_osd_commit_latency_ms))
          ) * on (ceph_daemon) group_left(hostname) ceph_osd_metadata
        for: 10m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph OSD commit latency outlier: {{ $labels.ceph_daemon }} on {{ $labels.hostname }}"

      - alert: CephDaemonSlowOps
        expr: max_over_time(ceph_daemon_health_metrics{type="SLOW_OPS"}[5m]) > 0
        for: 1m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph daemon has slow ops: {{ $labels.ceph_daemon }}"

      - alert: CephDaemonRecentCrash
        expr: ceph_health_detail{name="RECENT_CRASH"} == 1
        for: 5m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph daemon crash reported in the last two weeks"

      - alert: CephMgrNoStandby
        expr: (count(ceph_mgr_status) or vector(0)) < 2
        for: 5m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph mgr has no standby (failover capacity lost)"

      - alert: CephOSDNearFull
        expr: ceph_health_detail{name="OSD_NEARFULL"} == 1
        for: 10m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph OSD(s) near full"

      - alert: CephOSDBackfillFull
        expr: ceph_health_detail{name="OSD_BACKFILLFULL"} == 1
        for: 5m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph OSD(s) backfill-full: recovery is blocked"

      - alert: CephMonDiskLow
        expr: ceph_health_detail{name="MON_DISK_LOW"} == 1
        for: 10m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph MON data disk space low"

      - alert: CephMonDiskCritical
        expr: ceph_health_detail{name="MON_DISK_CRIT"} == 1
        for: 1m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph MON data disk space critically low"

      - alert: CephPoolNearQuota
        expr: |
          (
            ceph_pool_bytes_used > 0.8 * ceph_pool_quota_bytes
            and
            ceph_pool_quota_bytes > 0
          ) * on (pool_id) group_left(name) ceph_pool_metadata
        for: 10m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph pool {{ $labels.name }} above 80% of quota"

      - alert: CephCapacityForecast
        expr: |
          max(predict_linear(ceph_cluster_total_used_bytes[1h], 259200))
          > 0.85 * max(ceph_cluster_total_bytes)
        for: 30m
        labels:
          severity: warning
          source: ceph_coverage
        annotations:
          summary: "Ceph raw capacity projected to exceed 85% within 3 days"

      # fix round 1（real-lab, S19 資料損壞情境）：mgr 的 health_detail 匯出對 scrub/damage
      # 類 check 是 transient 的——objectstore-tool 破壞副本、deep-scrub 偵測到後，CLI
      # `ceph health detail` 持續顯示 OSD_SCRUB_ERRORS 約 6 分鐘，但同一段時間 Prometheus
      # 裡 ceph_health_detail{name="OSD_SCRUB_ERRORS"} 採了 97 個樣本、avg=0.031——值 1 只
      # 出現在約 3 次零星 scrape，其餘全是 0。舊版 `== 1` + `for: 1m` 永遠無法連續 1 分鐘為
      # 1，真故障期間規則永遠停在 pending、不會 fire（跟已修正的 CephDaemonSlowOps 同一種
      # spiky snapshot gauge 問題）。改成 max_over_time(...[5m]) > 0 撐住這段 flicker，
      # for:1m 只當單次 scrape 抖動的 debounce；一旦偵測到損壞，alert 會撐住約 5 分鐘（即使
      # repair 已經讓 health check 清除），方便 oncall 觀察，這對 pager alert 是好事。
      - alert: CephDataDamage
        expr: max_over_time(ceph_health_detail{name=~"PG_DAMAGED|OSD_SCRUB_ERRORS"}[5m]) > 0
        for: 1m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph data damage detected: {{ $labels.name }} — identify bad replica before repair"

      # fix round 1（preemptive）：OBJECT_UNFOUND 跟上面的 PG_DAMAGED / OSD_SCRUB_ERRORS
      # 同屬 mgr health_detail 匯出的資料完整性類 check，S20（object-unfound 情境）幾乎必定
      # 重現同樣的 transient-export flicker，所以先套用同一套視窗化修正，理由與
      # CephDataDamage 相同。
      - alert: CephObjectUnfound
        expr: max_over_time(ceph_health_detail{name="OBJECT_UNFOUND"}[5m]) > 0
        for: 1m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph objects unfound: latest replica unavailable"

      - alert: CephPGUnhealthyStates
        expr: |
          (
            (ceph_pg_down + ceph_pg_incomplete + ceph_pg_unknown + ceph_pg_stale + ceph_pg_peered)
            * on (pool_id) group_left(name) ceph_pool_metadata
          ) > 0
        for: 3m
        labels:
          severity: critical
          source: ceph_coverage
        annotations:
          summary: "Ceph pool {{ $labels.name }} has PGs in unhealthy states"
```

#### `alertmanager-route.yml` — Alertmanager 路由

```yaml
# Alertmanager routing（被測物）。route 區塊逐字取自 prometheus-alert-design.mdx
# §「Alertmanager routing：把角色映射到 receiver」。receivers 補成 amtool 可吃的最小定義。
# 效果：pager 收 severity=critical 的自訂 Ceph rules + CephHealthError；
#       warning/info 自訂 rules 與預設 aggregate（type=ceph_default，除 CephHealthError）進 slack；
#       Watchdog 走獨立 receiver，方便接外部 dead-man switch。
route:
  receiver: slack-ceph
  group_by: ['alertname', 'name', 'hostname', 'ceph_daemon']
  routes:
    - receiver: watchdog-ceph
      matchers:
        - alertname="Watchdog"

    - receiver: pager-ceph
      matchers:
        - severity="critical"
        - source=~"ceph_stability|ceph_scoped|ceph_coverage"

    - receiver: pager-ceph
      matchers:
        - type="ceph_default"
        - alertname="CephHealthError"

    - receiver: slack-ceph
      matchers:
        - source=~"ceph_stability|ceph_scoped|ceph_coverage"

    - receiver: slack-ceph
      matchers:
        - type="ceph_default"

receivers:
  - name: slack-ceph
  - name: pager-ceph
  - name: watchdog-ceph
```

#### `ceph-mon-quorum-dynamic.yml` — 非 3-MON 叢集用的動態多數決版本（替代選項）

```yaml
# 頁面「邊界 / 3-mon hard-code」提供的動態 majority 版本（已套 F1 的 or vector(0) 修正）。
# 來源：next-site/content/ceph/features/prometheus-alert-design.mdx §邊界。
groups:
  - name: ceph-mon-quorum-dynamic
    rules:
      - alert: CephMonQuorumLostDynamic
        expr: (count(ceph_mon_quorum_status == 1) or vector(0)) < (floor(count(ceph_mon_metadata) / 2) + 1)
        for: 1m
        labels:
          severity: critical
          source: ceph_stability
        annotations:
          summary: "Ceph MON quorum lost or below dynamic majority"
```

</details>

---

## 5. 我們怎麼驗證：四層測試

告警規則最危險的地方是「看起來對」。一條寫錯的規則平常展示都正常，偏偏在最壞情況那一刻靜默——你不會在上線時發現，你會在**該被叫醒卻沒被叫醒的那個凌晨**發現。所以我們把驗證拆成四層，每層回答一個不同的問題：

| 層級 | 工具 / 環境 | 回答的問題 | 性質 |
|---|---|---|---|
| **A — 規則邏輯** | `promtool test rules`（官方單元測試工具，可凍結時間） | 每條規則的判斷式、持續時間門檻、輸出 label 是否精確正確？ | 自動化、每次改動必跑 |
| **B — 路由** | `amtool config routes test` | 每種告警到底會送到 pager 還是 Slack？官方預設告警是否確定進不了 pager？ | 自動化、每次改動必跑 |
| **C — 整合** | 真的 Prometheus + Alertmanager + 接收端模擬 | 規則真的載得進去嗎？告警真的送得到嗎？靜音真的壓得住嗎？ | 自動化 |
| **D — 真機故障注入** | 真實 cephadm v19.2.3 叢集（3 MON + 9 OSD） | Ceph 在真實故障時**到底會不會**產生規則所假設的那些訊號？ | 22 個場景逐場注入、腳本自動斷言、逐一簽收 |

這四層有一條重要的分工線：**A/B/C 證明的是「如果 Ceph 在故障時匯出了這些訊號，規則的行為就正確」；而「Ceph 到底會不會匯出那些訊號」只有 D 層的真機能回答。** 第 6 節會看到，這條線正是 16 個「工具測試全綠、真機才現形」問題的來源——兩者驗的是完全不同的東西，缺一不可。

---

## 6. 做了哪些實驗、結果如何

### 6.1 開發階段就抓到一個致命 bug：quorum 生命線在最壞情況反而靜默

`CephMonQuorumLost` 的早期版本寫的是直覺式的 `count(ceph_mon_quorum_status == 1) < 2`——「在共識中的 MON 少於 2 台就叫」。看起來完全合理，日常情境也都正確。

但 PromQL 的 `count()` 是對「存在的資料」計數：當**所有** MON 全部掛掉、沒有任何一台回報「我在 quorum 中」時，過濾後一筆資料都不剩，`count(空)` 回傳的不是 0，而是「無資料」——整條判斷式**算不出結果，告警不會觸發**。也就是說，這條生命線在它最該叫的最壞情況（一台不剩）反而靜默，只有「還剩一台」時才叫。

這個 bug 是 A 層測試餵入「3 台全掛」的合成資料時抓到的。撰寫本報告時我們又用 promtool 重現了一次修正前的紅燈作為存證：對舊寫法餵入「3 台 MON 全部為 0」的合成資料，promtool 回報預期 1 筆告警、實得 `got:[]`（零告警）——工具輸出的空結果就是證據。修法是標準寫法 `(count(...) or vector(0)) < 2`：資料為空時退回 0，`0 < 2` 成立照樣觸發。修正後三種情境（健康不叫、掉 2 台叫、**掉 3 台也叫**）全數通過；目前版本庫內最近一次完整執行結果為 Tier A promtool `SUCCESS`（31 個測試斷言）、Tier B routing **22 passed / 0 failed**（`experiments/ceph-alert-rules/results/`）。

我們也誠實記錄了修正的副作用：修正版在「quorum 指標完全不存在」（例如 mgr 剛重啟）時也會觸發——它分不出「MON 全掛」與「指標缺席」。多數情況這可接受（連 quorum 指標都沒有，本來就等於對 quorum 失明，值得叫），若要避免，rules set 中另附一個以 metadata 為錨的動態多數決版本，天生免疫這個誤觸，且自動適應 5-MON 等不同規模的叢集。

另外，A 層對 `CephClientRisk` 的 25 項排除清單做了「完整性測試」：一次餵入全部排除項 + 2 個非排除項，斷言只有非排除項觸發——之後任何人不小心改動排除清單，測試都會擋下來。B 層則把「官方預設的 critical 告警也只能進 Slack、不得進 pager」這條最容易寫錯的路由規則釘死。

### 6.2 真機故障注入：22 個場景，22/22 通過

在真實的 cephadm v19.2.3 實驗叢集（3 MON + 9 OSD）上，我們對每一條告警**製造對應的真實故障**，驗收鐵律是：**必須用真故障讓告警實際觸發並送達正確接收端，不接受模擬或假資料。** 注入手法包括：

- 用 cgroup v2 `io.max` 對 OSD 底層磁碟限速，重現「硬碟變慢」（S1、S11）
- 真的停掉 OSD / MON / mgr 服務（S3–S6、S8）
- 用 `tc netem` 注入 1200ms 網路延遲、手動撥快時鐘（S12、S13）
- 對 ceph-osd 行程送真的 `SIGSEGV` 製造 crash（S14）
- 用 `objectstore-tool` 真的損毀單一物件的副本內容，再觸發 deep-scrub（S19）
- 持續寫入直到容量三級警戒與儲存池配額全數觸發（S16–S18）

**結果：22 個場景全數通過**——每個場景預期的告警都真的觸發、送到正確的接收端（pager / Slack / watchdog）；每輪注入後叢集都復原到 `HEALTH_OK`，沒有殘留任何設定變更或測試資料。完整場景表見附錄 A。

精確地說：27 條自訂規則中有 **26 條**在這 22 個場景裡完成了真機 firing 驗證。唯一的例外是 `CephExporterTargetDown`（單一監控來源失聯 15 分鐘的 warning）——它通過了路由層驗證（確認會進 Slack、不進 pager），但沒有專屬的真機注入場景，已標記為待補實驗（附錄 E）。

其中最重要的單一發現來自 S3（quorum 失守）：真實停掉兩台 MON 後，`ceph quorum_status` 指令已經無法完成，但 Prometheus 從單一 mgr exporter 查到的 quorum 數**仍然是 3**——**監控資料來源在叢集共識崩潰時會凍結在舊世界、回報過期資料**。這不是規則寫錯（PromQL 完全正確），而是資料來源在說謊。最終告警是在 exporter 也停掉、資料變空後，靠 6.1 節那個 `or vector(0)` 修正觸發的。這個發現直接推導出第 8 節的限制與第 9 節的補強建議（multi-mgr scrape + 獨立觀測面）。

### 6.3 十六個「工具測試全綠、只有真機才現形」的問題

真機驗證過程中共發現 16 個問題——**沒有任何一個是 PromQL 寫錯**（promtool 全綠）。它們全部出在規則之外的真實世界：指標的統計特性、容器執行環境、工具的隱藏語意、故障當下的時序動態。依類型歸納：

| 類型 | 代表發現 | 教訓 |
|---|---|---|
| **指標的統計特性** | 多個健康指標本質是「瞬間快照」型，真故障期間只有零星時間點為 1——資料損毀場景中 CLI 持續顯示錯誤的同一時段，TSDB 的 97 個取樣只有約 3 個為 1（平均值 0.031）；slow-ops 指標在持續故障下也只有約 28.8% 的時間 >0。「持續 N 分鐘為真」的門檻永遠湊不滿，告警永遠不觸發（發現 02、14） | 對這類 spiky 指標一律改用時間窗聚合 `max_over_time(...[5m])`；一次抓到後預先套用到同類規則，S20 因此一次通過（發現 15） |
| **容器 / 執行環境** | 對 systemd `MainPID` 送 SIGSEGV 打到的是容器監控器而不是 ceph-osd；且 lab 的 crash 回報 sidecar 本身缺 keyring，物理上回報不了 crash（發現 01） | 「訊號鏈的每一環」都要真機驗過，包括你以為理所當然的部分 |
| **工具的隱藏語意** | `rados bench` 分輪執行時每輪覆寫同名物件，容量根本沒有累積成長——趨勢預測告警連續五輪不觸發，追了六輪才找到真兇（發現 13） | 規則從頭到尾是對的，它正確地拒絕在不夠陡的趨勢上觸發；錯的是實驗假設 |
| **故障當下的時序動態** | 真 quorum 崩潰時 exporter 先凍結再死亡，兩條告警在時間上永遠不重疊，設計好的抑制（inhibit）關係在真故障中「觀察不到」（發現 11、16） | 機制正確但不可觀察時，改用確定性方法驗證機制本身，並誠實記錄原因 |
| **自動化細節** | cephadm shell 的提示文字污染 JSON 解析、rollback 指令自斷 SSH 連線、mgr failover 後備援需數十秒才重新註冊……（發現 04、09、10 等） | 故障演練的自動化腳本本身也需要與生產同等的工程品質 |

全部 16 個發現的完整記錄（症狀 → 根因 → 修法）見附錄 B。

---

## 7. 結果與預想的落差

| 我們原本以為 | 實際發生的事 |
|---|---|
| promtool 單元測試全綠 ≈ 可以上線 | 全綠之後真機仍暴露 16 個問題。工具測的是「規則邏輯對不對」，真機測的是「規則接到的資料在真故障當下長什麼樣」——是兩個不同的驗證面 |
| mgr exporter 會即時反映 quorum 狀態 | 真 quorum 崩潰時 exporter 凍結、回報舊資料；告警最終靠「資料變空」的路徑觸發。單一 exporter 不可當唯一的 quorum 偵測器 |
| 健康指標是穩定的 0/1 狀態 | 多個指標是 spiky 快照：CLI 持續顯示錯誤的同一時段，Prometheus 只在 3% 的取樣點看到 1 |
| 把磁碟限速調得更狠，slow-ops 訊號會更持續 | 限速太狠 OSD 連心跳都發不出去、直接掉線；「持續」要靠高並發把佇列撐滿，不是靠更硬的限速 |
| 設計好的 inhibit 關係可在真故障中觀察到 | exporter 凍結使兩條告警永遠不同時存在；改以合成告警確定性驗證 Alertmanager 設定本身 |

**共同的模式**：預想的落差幾乎都不在「規則寫錯」，而在**真實系統在故障當下的行為與教科書假設不同**。這正是「每條告警都要真機驗證」這條鐵律的價值——它逼出的不是更多綠燈，而是這些只有真實世界才會給的答案。

---

## 8. 最終我們能解決什麼、不能解決什麼

### ✅ 能解決

1. **例行維護不再吵醒值班人員**：維護單台機器時，只精準靜音該台的告警（附 SOP 指令）；維護必然引起的連鎖訊號（副本暫少、保護旗標）已預先分流到 Slack，不進 pager。（噪音分流與帶 label 的 scoped 告警均已真機驗證；silence 壓制已在真 Alertmanager 整合測試驗證；完整維護 SOP 的真機演練列入附錄 E 待補。）
2. **維護期間的保護不打折**：靜音只蓋目標機器——維護 A 台時 B 台壞掉照樣 page；「維護第一台 MON 時第二台也掉」的 quorum 生命線永遠不被靜音。
3. **真故障可靠送達**：22 種故障模式（含磁碟慢、斷線、資料損毀、容量、網路、時鐘）逐一真機簽收過「故障 → 告警觸發 → 送達正確接收端」的完整鏈路。
4. **監控系統自身的失效會被發現**：exporter 全滅、指標消失有專屬 critical 告警；`Watchdog` 心跳讓外部系統能偵測「告警系統本身死掉」。
5. **容量問題從「事後救火」變「事前預警」**：接近配額、接近警戒線、3 天趨勢預測三個梯度，在寫死之前給出行動時間。

### ❌ 不能解決（與對應緩解）

1. **單一 mgr exporter 視角的「凍結說謊」**：真 quorum 崩潰時 exporter 會回報過期資料，quorum 告警要等資料完全消失才觸發（有延遲）。緩解：Prometheus 應 scrape 所有 mgr；根治需要 Ceph 之外的獨立觀測面（如 node-exporter 的 systemd 視角），屬後續工作。
2. **「指標從未存在」的盲區只補了關鍵處**：規則只在對應指標存在時才可能觸發；scrape 設定打錯這類「從未有資料」的失效，目前由 `CephMetricsAbsent`（鎖 `ceph_health_status`）與 `CephExporterAllDown` 涵蓋核心，並非每一個指標都有 absent 保護。
3. **門檻值不是普世常數**：延遲 100ms、配額 80%、預測 85% 等門檻來自本實驗叢集的合理值，導入不同規模的生產環境需依基線重新校準。
4. **quorum 生命線的固定門檻假設 3-MON 叢集**：其他規模需改用附帶的動態多數決版本（rules set 內已附）。
5. **告警只負責「叫對人」，不負責修復**：每條 pager 告警附有第一步 runbook 指令，但診斷與修復仍需值班人員執行。

---

## 9. 總結與上線建議

這個專案交付的不只是 27 條規則，而是三件可長期複用的資產：

1. **一套已完成閉環驗證的告警系統**——設計、邏輯測試、路由測試、整合測試、22 個真機故障場景，每一環都有可重跑的自動化證據。
2. **一套可重複執行的故障演練工具**——所有注入腳本可重跑、自動回滾、跑完自動驗證叢集復原，未來規則調整後可隨時回歸。
3. **一組方法論教訓**——最重要的一條：**工具測試與真機演練驗的是兩件不同的事，16 個真機發現沒有一個能被工具測試抓到**。這條經驗適用於任何監控告警系統，不限於 Ceph。

**建議的生產導入路徑**（依序）：

1. 全部規則先接到**非 paging 接收端**觀察 1–2 週，確認誤報率。
2. 配置 Prometheus scrape **所有 mgr** endpoint（緩解 exporter 凍結）。
3. 把 `Watchdog` 接上外部 dead-man switch（如 healthchecks.io 或既有值班系統）。
4. 依生產基線校準門檻值（延遲、容量、預測窗）。
5. 逐條開啟 pager 路由；有條件時在生產環境重放關鍵注入場景簽收。
6. 後續工作：以 node-exporter systemd collector 建立 MON 的獨立觀測面，交叉檢查 mgr exporter。

---

<details>
<summary><strong>附錄 A：22 個真機故障注入場景完整記錄（點開展開）</strong></summary>

故障模式六分類：**A** 監控系統自身失明、**B** 硬體（磁碟延遲／容量）、**C** 網路（心跳／抖動／時鐘）、**D** 軟體／daemon、**E** 資料完整性、**F** client I/O 生命線。圖例：🔴 pager、🔵 Slack。

| # | 場景 | 類別 | 驗證的 alert | 真實注入手法 | 結果 |
|---|---|---|---|---|---|
| S1 | slow-ops | F/B | `CephClientBlocked{SLOW_OPS}` 🔴 · `CephDaemonSlowOps` 🔵 | cgroup v2 `io.max` 限速 backing device + 高並發 `rados bench` 撐滿 op queue | ✅ |
| S2 | pg-availability | F/E | `CephClientBlocked{PG_AVAILABILITY}` 🔴 · `CephPGUnhealthyStates` 🔴 | 停測試 pool acting set 裡兩顆 OSD | ✅ |
| S3 | mon-quorum-lost | F | `CephMonQuorumLost` 🔴（含 inhibit 確定性驗證） | 停 2 台 MON（保留 active mgr 那台，再停 active mgr 測 empty-series path） | ✅ |
| S4 | osd-daemon-down | D | `CephOSDDaemonDownScoped` 🔴（host 級不誤叫） | 停單顆 OSD service | ✅ |
| S5 | osd-host-down | D | `CephOSDHostDownScoped` 🔴（3 顆 daemon 級都不誤叫，驗 `unless` 去重） | 停整台 host 全部 OSD | ✅ |
| S6 | mon-down-single | D | `CephMonDownScoped` 🔴（`CephMonQuorumLost` 不誤叫） | 停單台 MON | ✅ |
| S7 | exporter-blind | A | `CephMetricsAbsent` + `CephExporterAllDown` 🔴 | disable `prometheus` mgr module | ✅ |
| S8 | mgr-failover | D | metrics 不中斷 · `CephMgrNoStandby` 🔵 | `ceph mgr fail` + 停 standby mgr | ✅ |
| S9 | catch-all-risk | D | `CephClientRisk{OSD_NO_DOWN_OUT_INTERVAL}` 🔴 | `config set mon_osd_down_out_interval 0` | ✅ |
| S10 | low-priority-notice | D | `CephLowPriorityNotice` 🔵（pager 靜默） | 設 `noout` flag 升 `OSDMAP_FLAGS`，等滿 `for: 30m` | ✅ |
| S11 | latency-outlier | B | `CephOSDLatencyOutlier` 🔵 | 輕度限速 + 高並發寫入 | ✅ |
| S12 | net-slow-heartbeat | C | `CephOSDSlowHeartbeat` 🔴 | `tc netem delay 1200ms`（預先武裝 auto-revert 計時器） | ✅ |
| S13 | mon-clock-skew | C | `CephMonClockSkew` 🔴 | 停時間同步 + `date` 手動 step +2s | ✅ |
| S14 | daemon-crash | D | `CephDaemonRecentCrash` 🔵 | 真 `SIGSEGV` 打進容器內的 ceph-osd 行程 | ✅ |
| S15 | osd-flapping | C | `CephOSDFlapping` 🔴 | OSD 停/啟 ×2（4 次 transition，等 Prometheus 取樣到每個狀態） | ✅ |
| S16 | capacity-ladder | B/F | `CephOSDNearFull` 🔵 · `CephOSDBackfillFull` 🔴 · `CephClientBlocked{OSD_FULL}` + `CephHealthError` 🔴 | 動態量測最滿 OSD 使用率，逐級調低 full-ratio | ✅ |
| S17 | pool-quota | B/F | `CephPoolNearQuota` 🔵 · `CephClientBlocked{POOL_FULL}` 🔴 | 持續寫爆 pool `max_bytes` quota | ✅ |
| S18 | capacity-forecast | B | `CephCapacityForecast` 🔵 | 3 條連續 `rados bench` 平行 stream 持續寫入（約 27GiB），72h 趨勢預測越過 85% | ✅ |
| S19 | data-damage | E | `CephDataDamage` 🔴 | `objectstore-tool set-bytes` 損毀單一 object 內容 → deep-scrub | ✅ |
| S20 | object-unfound | E | `CephObjectUnfound` 🔴 | `size=2/min_size=1` 誘發 unfound 的標準手法 | ✅ |
| S21 | mon-disk-low | B | `CephMonDiskLow` 🔵 · `CephMonDiskCritical` 🔴 | 動態調低 `mon_data_avail_warn`／`mon_data_avail_crit` 閾值 | ✅ |
| S22 | watchdog baseline | A | `Watchdog` → watchdog receiver | 部署後即斷言心跳必達 | ✅ |

**中期關鍵場景的原始證據**（committed evidence index：`experiments/ceph-alert-real-lab/EVIDENCE-SUMMARY-2026-07-04.md`）：

| Alert | 真故障 | Ceph 端證據 | Prometheus / pager 證據 |
|---|---|---|---|
| `CephClientBlocked{name="SLOW_OPS"}` | `io.max` 限速 `osd.6`（`192.168.18.174` 的 `/dev/sdb`）+ `rados bench` | health check 出現 `SLOW_OPS` 與 `BLUESTORE_SLOW_OP_ALERT` | `state="firing"`，`activeAt=2026-07-04T10:12:42Z`，sink 收到 pager 通知 |
| `CephClientBlocked{name="PG_AVAILABILITY"}` | 停測試 pool acting set 的 `osd.5` / `osd.8` | `PG_AVAILABILITY` 升起、PG `2.10` inactive | `state="firing"`，`activeAt=2026-07-04T10:28:57Z`，sink 收到 pager 通知 |
| `CephMonQuorumLost` | 停 mon-01/mon-03，再停 mon-02 與 active mgr | `ceph quorum_status` exit 255；但 exporter 仍回報 quorum 數 = 3（凍結證據） | 停 active mgr 後 `state="firing"`，`activeAt=2026-07-04T10:34:37Z`，sink 收到 pager 通知 |

**最終輪次的補充原始數據**（撰寫本報告時直接從 `results/` 原始檔複核）：

- **S3 最終 run**（`mon-quorum-lost-20260706T121047Z`）：`CephMonQuorumLost` `state="firing"`、`activeAt=2026-07-06T12:12:07Z`、sink 收到 `receiver=pager`；規則運算式的 TSDB 即時值為 `0`（empty-series path 生效）；inhibit 以合成 alert 對真 Alertmanager 驗證——`CephMonDownScoped` 回報 `state: suppressed`、`inhibitedBy` 指向 `CephMonQuorumLost` 的 fingerprint；postcheck `HEALTH_OK`。
- **S18 通過數據**：3 條連續 stream 量測到 **9.15MB/s** 的成長率（分輪版趨近 0.1MB/s），實際寫入 **27.6GB**，`predict_linear` 的 72 小時預測值達 **2046GB**、越過門檻 **821GB**（= 85% 總容量）→ firing 進 Slack、pager 確認 absent。
- **S19 spiky 指標數據**：注入後 CLI 持續顯示 `OSD_SCRUB_ERRORS` 的同一時段，TSDB 97 個取樣平均值僅 **0.031**（約 3 個取樣為 1）——窗化修法的直接依據。

驗證全數結束後，叢集復原至 `HEALTH_OK`：ratio、config、flag 全部還原，無殘留 crash report 或測試 pool。

</details>

<details>
<summary><strong>附錄 B：16 個「只有真機才現形」的發現完整記錄（點開展開）</strong></summary>

以下每一項在 promtool / unit test 層全部綠燈，只有接上真硬體、真 mgr、真 cephadm shell 才暴露。編號後括號為對應場景。

1. **daemon crash 打錯行程，且 lab 的 crash sidecar 本身是壞的（S14）**——`kill -SEGV` 打 systemd `MainPID` 其實打到容器監控器 `conmon`，容器內 PID 1 的 `podman-init` 不轉發訊號；更深一層 `ceph-crash` sidecar 缺 `client.crash` keyring，物理上回報不了 crash。修法：對 host 上 ceph-osd 真實 PID 送 `SIGSEGV`，crash meta 落 spool 後由 admin 節點 `ceph crash post`。
2. **`CephDaemonSlowOps` 指標太 spiky，`for:` 永遠湊不滿（S1）**——`ceph_daemon_health_metrics{type="SLOW_OPS"}` 是瞬間快照 gauge，觀察窗內只有約 28.8% 時間 >0。修法：改 `max_over_time(...[5m]) > 0` + 短 `for:`。
3. **節流太硬 OSD 直接 flap（S1）**——太狠的限速連 OSD 自身心跳 I/O 都卡住，直接掉線。「持續的 slow-ops」要靠高並發把 op queue 撐滿，不是更硬的限速。
4. **cephadm shell 的 stderr banner 污染 JSON（S15/S19/S20）**——`2>&1` 把 `Inferring fsid…` 等提示行併進 `jq` 要解析的 JSON，parse error 導致輪詢永遠逾時。修法：JSON 只取 stdout，banner 走 stderr 旁路 log。
5. **flapping 太快，5 秒 scrape 抓不到中間狀態（S15）**——某個 up 狀態只維持 4 秒，`changes()` 只數到 2。修法：每次 transition 等 Prometheus 真的取樣到該值再前進。
6. **pool 超過 quota 要「持續寫入壓力」才升 `POOL_FULL`（S17）**——mon 只在 client 持續嘗試寫入（寫到被 block）時才 flag。修法：過 quota 後用 `timeout 30 rados put` 持續施壓並輪詢。
7. **寫滿容量太慢；改用動態 ratio 貼合真實使用率（S16）**——叢集近乎全空時固定閾值不可能 trip。修法：量測最滿 OSD 的實際使用率，把三級 ratio 設為它的 0.6/0.7/0.8 倍，動態推導。
8. **BlueStore slow-op 警告是 24 小時 latch，restart 清除會弄壞 cephadm inventory（S1/S11/S16）**——修法：暫調 `bluestore_slow_ops_warn_lifetime` 讓警告約 20 秒內老化清除，不 restart 任何 OSD；抽成共用 helper（其後在 S16、S18 的真機 run 中實際使用並通過）。
9. **移除網路延遲時自斷 SSH（S12）**——rollback 指令走的正是被延遲 1200ms 的介面，delete 當下連線異常斷開、回傳非零。修法：改用全新 SSH 連線事後輪詢「延遲確實消失」。（告警本身已由真機 firing 驗證；此回滾判斷修正以自動化測試回歸，未重跑完整場景。）
10. **mgr failover 後 standby 要數十秒才重新註冊（S8）**——單次查詢判失敗是誤判。修法：有時間預算的輪詢。順帶真機驗證了 multi-mgr scrape：failover 過程 metrics 不中斷。
11. **真 quorum loss 時 mgr exporter 遙測凍結在舊世界（S3）**——`ceph quorum_status` 已失敗，exporter 仍回報 quorum 數 = 3。這是「不能只靠單一 exporter 視角」與新增 `CephMetricsAbsent` 的直接理由。
12. **只改 configmap，Prometheus 不會自動重載 rule（harness gap）**——rule 變更後必須重啟 Prometheus deployment；已列入部署腳本硬化待辦。
13. **capacity-forecast 六輪纏鬥：真兇是 `rados bench` 覆寫同名 object（S18）**——分輪執行時每輪用固定 run 名稱，第二輪起覆寫前一輪物件，容量成長趨近零（量測值約 0.1MB/s、甚至為負）；受控對照的連續寫入則量到 6.9MB/s（門檻推算需 ≥3.2MB/s）。規則正確地拒絕在不夠陡的趨勢上觸發。修法：改為連續 stream 寫入，成長率達 9.15MB/s、第 6 輪通過。整輪最耗工的除錯（前 5 輪失敗）。
14. **data-damage 三層疊（S19）**——(a) `ceph_health_detail` 對 scrub 類 check 是 spiky 匯出（97 個樣本 avg=0.031）→ 窗化；(b) 用 `remove` 刪副本會被 recovery 自動補回、與 deep-scrub 形成競態 → 改 `set-bytes` 損毀內容（recovery 治不好，確定性觸發）；(c) `HEALTH_ERR` 本身也閃爍 → 移除該場景中重複且不穩定的 `CephHealthError` 斷言（它已由 S16 穩定驗證）。
15. **`CephObjectUnfound` 預先套用窗化修正（S20）**——認出它與發現 14 同類後在同一修正中一併窗化，該場景一次通過。「把發現抽象成一類問題再預先套用」的價值。
16. **真 quorum loss 當下 inhibit 觀察不到（S3）**——exporter 先凍結再死亡，`CephMonQuorumLost` 與 `CephMonDownScoped` 在時間上永遠不重疊。修法：以合成 alert 確定性驗證 Alertmanager 的 inhibit 設定本身（確認 `CephMonDownScoped` 被標記 suppressed 且指向正確來源），主 alert 仍由真故障驗證。

</details>

<details>
<summary><strong>附錄 C：測試 harness 與重跑方式（點開展開）</strong></summary>

#### 開發環境四層測試（`experiments/ceph-alert-rules/`）

```bash
bash experiments/ceph-alert-rules/run/all.sh    # Tier A→B→C 依序，任一非 0 即整體 FAIL
bash experiments/ceph-alert-rules/run/tierA.sh  # 防漂移 guard + promtool lint + 單元測試
bash experiments/ceph-alert-rules/run/tierB.sh  # amtool routing 斷言
bash experiments/ceph-alert-rules/run/tierC.sh  # 起真 Prometheus / Alertmanager 的整合測試
```

- 規則檔逐字抽自設計文件，`lib/check-rules-match-page.sh` 自動比對防止漂移。
- PASS 判準：各 tier 印 `TIER X PASS`、`all.sh` 印 `ALL PASS` 且 exit 0。
- Tier C 分三段：C1 規則載入檢查、C2 真 Alertmanager 的 routing + silence、C3 合成 metric → 真 Prometheus → 真 Alertmanager → webhook sink 全鏈路。
- 已知邊界：Tier C 不驗 `for:` 時長（C2 直接 POST 已成形 alert、C3 用縮短 `for:` 的副本）；`for:` 精確語意只由 Tier A 保證。

#### 真機故障注入 harness（`experiments/ceph-alert-real-lab/`）

```bash
# 全鏈執行（內建 cleanup）
bash experiments/ceph-alert-real-lab/run/all.sh --yes-really-inject

# 本機測試 gate
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh run/*.sh tests/*.sh
```

安全界線：每個注入腳本都要求 `--yes-really-inject`；每個場景完成後確認 `HEALTH_OK` 才進下一個；`run/cleanup.sh` best-effort、可重複執行；破壞性場景（quorum loss）排最後。長時場景注意：`low-priority-notice` 與 `capacity-forecast` 因 `for: 30m` 分別需 30+ 與 55–75 分鐘 wall-clock，後者會寫入約 27GiB 測試資料。

#### 實驗環境

- 真機叢集：cephadm Ceph v19.2.3（Squid LTS），3 MON + 9 OSD（3 台 OSD host × 3）
- 監控面：lab k8s 內臨時部署的 Prometheus + Alertmanager + webhook sink（`experiments/ceph-alert-real-lab/rendered/monitoring.yaml`）
- 原始 result 目錄不進版本庫（含機敏路徑與大量原始 JSON）；committed 證據索引為 `EVIDENCE-SUMMARY-2026-07-04.md`

</details>

<details>
<summary><strong>附錄 D：參考資料與連結（點開展開）</strong></summary>

#### 本專案文件（GitHub：<https://github.com/tom19960222/learning-k8s>）

| 文件 | 路徑 | 內容 |
|---|---|---|
| 設計篇 | `next-site/content/ceph/features/prometheus-alert-design.mdx` | 完整設計理由、每條規則的 PromQL 解讀、維護 silence SOP、發警時的第一步 runbook |
| 開發驗證篇 | `next-site/content/ceph/features/prometheus-alert-testing.mdx` | 四層測試方法論、F1 bug 完整案例、逐條測試內容 |
| 真機驗證篇 | `next-site/content/ceph/features/prometheus-alert-real-lab-findings.mdx` | 22 場景全記錄、16 個真機發現、v2 規則修訂理由 |
| Rules set（單一事實來源） | `experiments/ceph-alert-rules/rules/*.yml` | 本報告附錄之 5 個規則檔 |
| 開發測試 harness | `experiments/ceph-alert-rules/` | Tier A/B/C 自動化測試 |
| 真機注入 harness | `experiments/ceph-alert-real-lab/` | 22 個場景的注入 / 驗證 / 回滾腳本 |
| 真機證據索引 | `experiments/ceph-alert-real-lab/EVIDENCE-SUMMARY-2026-07-04.md` | 中期關鍵場景的 committed 證據 |

#### 相關深入閱讀（同站 Ceph 專題頁）

- `osd-ok-to-stop`：維護前的安全檢查在原始碼層做了什麼
- `mon-quorum-loss-impact`：3-MON / 5-MON quorum 失守對 client I/O 的影響
- `pg-health-states`：為什麼 `PG_AVAILABILITY` 要 page 而 `PG_DEGRADED` 只進 Slack
- `slow-ops-and-bluestore-alerts`：slow ops 與 BlueStore 告警的 metric 來源
- `osd-flapping`：OSD 為什麼會被反覆標記 down/up

#### 上游 / 外部參考

- Ceph v19.2.3（Squid）原始碼，特別是 `src/pybind/mgr/prometheus/module.py`（metric 匯出定義）與 `monitoring/ceph-mixin/prometheus_alerts.yml`（官方預設 rules）：<https://github.com/ceph/ceph/tree/v19.2.3>
- Ceph health checks 官方文件：<https://docs.ceph.com/en/squid/rados/operations/health-checks/>
- Prometheus 告警規則與單元測試（promtool）：<https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>、<https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/>
- Alertmanager（routing / silence / inhibition）：<https://prometheus.io/docs/alerting/latest/alertmanager/>
- cgroup v2 `io.max`（磁碟限速注入手法）：<https://docs.kernel.org/admin-guide/cgroup-v2.html#io>
- `tc netem`（網路延遲注入手法）：<https://man7.org/linux/man-pages/man8/tc-netem.8.html>

</details>

<details>
<summary><strong>附錄 E：驗證狀態總表與待補實驗（點開展開）</strong></summary>

本報告完稿前，所有宣稱已逐一對照原始數據複核。複核方式與結果：

| 驗證項目 | 依據的原始數據 | 狀態 |
|---|---|---|
| 27 條 rule 數量與內容（6+3+18、排除清單 25 項、各 `for:` 門檻） | 直接統計 `experiments/ceph-alert-rules/rules/*.yml` | ✅ 相符 |
| Tier A 規則邏輯測試 | `results/tierA.txt`：promtool `SUCCESS`（31 個測試斷言） | ✅ 相符 |
| Tier B routing（含「預設 critical aggregate 只進 Slack」） | `results/tierB.txt`：22 passed / 0 failed，含 `CephMonDownQuorumAtRisk` / `CephOSDDownHigh` → slack 斷言 | ✅ 相符 |
| F1 bug（舊寫法最壞情況靜默） | 撰寫本報告時以 promtool 重現：舊 expr 餵 3 台全 0 → `got:[]`；修正版測試檔含「3 台全掉必須 fire」案例 | ✅ 已重現存證 |
| 22 個場景 22/22、`HEALTH_OK` 復原 | orchestrator 進度記錄逐場景 PASS 記錄 + 抽查原始 run 目錄（S1/S2/S3 的 firing JSON、sink log、postcheck） | ✅ 相符 |
| S3 exporter 凍結 / empty-series / inhibit | 原始 JSON：`ceph quorum_status` exit 255 同時 TSDB 查得 `3`；最終 run firing `2026-07-06T12:12:07Z` → pager；`CephMonDownScoped` `suppressed` + `inhibitedBy` fingerprint | ✅ 相符 |
| S18 / S19 關鍵數字（9.15MB/s、2046GB vs 821GB、27.6GB、97 取樣 avg 0.031、28.8%） | orchestrator 進度記錄（含即時 TSDB 查詢結果） | ✅ 相符 |

**待補實驗（現有數據無法支撐、或尚未執行）：**

1. ⚠️ **`CephExporterTargetDown` 的真機 firing 驗證**——22 個場景的注入腳本中沒有任何一個斷言這條 alert（僅 Tier B routing 驗證過它進 Slack）。待補做法：保留另一個 mgr target 存活的前提下，讓單一 exporter target 失聯超過 `for: 15m`，斷言 warning 送達 Slack 且 pager absent。
2. ⚠️ **「maintenance enter + 精準 silence」端到端 SOP 真機演練**——組成元件都各自驗過（scoped label 真機驗證於 S4/S5/S6；silence 壓制驗證於 Tier C 真 Alertmanager；維護噪音分流驗證於 S10），但「`ceph orch host maintenance enter` + `amtool silence hostname=X` → 只有目標機靜音、其他機器故障照常 page」這條完整 SOP 尚未在真機串成一輪演練。
3. ⚠️ **附錄 C 的各場景 wall-clock 時間**——為依 `for:` 條款與輪詢次數推算的設計估算值，僅 S10（30+ 分鐘）與 S18（55–75 分鐘）由實際執行大致印證，其餘未逐一計時。
4. ℹ️ **F1 當時的原始紅燈輸出未歸檔**——開發當下的 promtool 失敗輸出沒有留檔（僅文件敘述）；本次撰寫報告時已重現並記錄於本附錄，可視為已補。

</details>
