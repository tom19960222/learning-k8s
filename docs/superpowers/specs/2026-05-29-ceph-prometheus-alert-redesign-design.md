# Ceph Prometheus alert 重新設計 design（新手好維護版）

## Goal

把既有的 `next-site/content/ceph/features/prometheus-alert-design.mdx`（目前是 4 層
observe/ignorable/better-not-ignore/immediate 設計）**原地改寫**成一套以「穩定性第一、新手好維護」
為目標的 **6 條 alert rule** 設計。核心心法只有一句：

> **`ceph_health_detail` 噴出來的，預設全部 page；只有一張很短（3 個）的 cosmetic 白名單例外。維護期不靠 PromQL gate，改用 `amtool silence` 手動壓。**

改寫後保留原頁「從原始碼追 HEALTH_WARN 怎麼被丟出來」的背景段落（它是這頁的價值），
但移除所有把維護狀態 gate 進 PromQL 的複雜機制，並補上「逐 alert 成因 + 原始碼證明」一節。

## 為什麼要改

使用者反映舊的 4 層設計太複雜：`ceph:maintenance_active` recording rule + 每條 Tier 1 都掛
`unless on() (ceph:maintenance_active == 1)` + `PG_AVAILABILITY` 的 `- on() group_left()` 減法
+ quorum 的 `bool` 數學 + 6 步實驗計畫。維護一台 node 要靠一串 PromQL 自動 gate，看不懂、
也不敢改。穩定性要求高的環境裡，這種「自動猜測維護狀態」反而是風險（猜錯就漏 page）。

新設計把「判斷現在是不是維護」這件事從 PromQL 移到人身上：維護前人工下一條 `amtool silence`，
維護完到期自動解除。規則本身永遠只回答「現在 cluster 有沒有壞」，不回答「這個壞是不是我預期的」。

## Non-goals

- 不改 `ceph-mixin` 上游、不發 PR 回 ceph；這頁只記錄「我自己環境怎麼配」。
- 不畫新的 PNG diagram（沿用 ASCII / 既有圖即可）。
- 不動其他 ceph feature page，不改 `feature-map.json` 的 node（這頁 slug 不變）。
- 不寫完整 6 步實驗計畫；只留一支精簡 promtool unit test 驗 PromQL 邏輯。
- 不為 client-IO-blocked 以外的 check 做 per-check `for:` 微調（catch-all 共用 `for: 5m`）。

## 設計：6 條 rule

三組 name 集合（rule 2 / 3 / 6）互斥且涵蓋整個 `ceph_health_detail`，所以每個 check 只落到
其中一條，不雙噴也不漏接。rule 1 / 4 / 5 是與 health_detail 正交的 cluster 級 / 抓取面 backstop。

```yaml
groups:
  - name: ceph-stability-first
    rules:
      # 1) cluster 進 HEALTH_ERR —— 任何 ERR 級 check 的總開關（永不 silence）
      - alert: CephHealthError
        expr: ceph_health_status == 2
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "Ceph HEALTH_ERR"
          runbook: "ceph health detail; ceph -s"

      # 2) client IO 已被擋 —— 最痛訊號，1 分鐘內叫（永不 silence）
      - alert: CephClientBlocked
        expr: ceph_health_detail{name=~"PG_AVAILABILITY|SLOW_OPS"} == 1
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "Ceph client IO blocked: {{ $labels.name }}"

      # 3) 主規則：其餘所有會危及 client 的 WARN+ check，逐 name page
      - alert: CephClientRisk
        expr: |
          ceph_health_detail{
            name!~"PG_AVAILABILITY|SLOW_OPS|HOST_IN_MAINTENANCE|OBJECT_MISPLACED|PG_SLOW_SNAP_TRIMMING"
          } == 1
        for: 5m
        labels: { severity: critical }
        annotations:
          summary: "Ceph client-risk check active: {{ $labels.name }}"

      # 4) quorum 失守 —— 補 MON_DOWN 0/1 看不出「掛幾台」的盲點（永不 silence）
      - alert: CephMonQuorumLost
        expr: count(ceph_mon_quorum_status == 1) < 2   # 3-mon 多數 = 2
        for: 1m
        labels: { severity: critical }

      # 5) 抓不到 ceph metrics 本身就是盲區（永不 silence）
      - alert: CephExporterDown
        expr: up{job="ceph"} == 0
        for: 5m
        labels: { severity: critical }

      # 6) 純雜訊 / 自己設的狀態 —— 只進 Slack，不 page
      - alert: CephCosmeticNag
        expr: |
          ceph_health_detail{
            name=~"HOST_IN_MAINTENANCE|OBJECT_MISPLACED|PG_SLOW_SNAP_TRIMMING"
          } == 1
        for: 30m
        labels: { severity: info }
```

### 為什麼 catch-all 比逐條列名更完整

`ceph_health_detail` 在原始碼裡是「每個 active 的 health check 各自 set 一條 =1」
（`module.py:932`，label 只有 `('name','severity')` 見 `module.py:742`）。所以
`name!~"<白名單>"` 的排除法會自動接住：我沒列到的冷門 check、以及**未來 ceph 版本新增的
check**。舊的 4 層列了 ~20 個固定名字，新 check 會被靜默漏接 —— 對穩定性第一是反指標。

### Cosmetic 白名單（唯一「不 page」清單，3 個）

| name | 為什麼不 page | 源頭 |
|---|---|---|
| `HOST_IN_MAINTENANCE` | 自己 `ceph orch host maintenance enter` 設的，預期內 | `cephadm/module.py` |
| `OBJECT_MISPLACED` | 副本數**足夠**、只是位置待搬，rebalance 必經、不危及 client | `PGMap.cc` (WARN) |
| `PG_SLOW_SNAP_TRIMMING` | snap trim 背景積壓，housekeeping，極少直接卡 client | `PGMap.cc` (WARN) |

> 這兩個 judgment call（`OBJECT_MISPLACED` / `PG_SLOW_SNAP_TRIMMING`）基於「副本充足 / 純背景」
> 判為不 page。要更保守就把任一個從白名單拿掉、它即回到 `CephClientRisk` 改成 page。
> 其餘所有 check 一律 page（含 `RECENT_CRASH`、`DEVICE_HEALTH`、`LARGE_OMAP_OBJECTS`、
> `BLUESTORE_*`、`MON_DISK_*`、`MON_CLOCK_SKEW` 等）。

## 每個 alert 的成因與來源（zero-fabrication 證據表）

頁面要新增「逐 alert 成因（按來源檔分組）」一節，逐一證明 check name 真實存在於 v19.2.3。
**所有行號在實作（寫 MDX）時必須對 pinned v19.2.3 重新 `nl -ba | sed -n` 核對一次**，
這裡先記檔案與 severity；不確定的行號不寫進 MDX。

| check name | severity | 落到哪條 rule | 源頭檔 |
|---|---|---|---|
| （任何 ERR） | ERR | `CephHealthError` | `prometheus/module.py:47` health_status_to_number |
| `PG_AVAILABILITY` | WARN | `CephClientBlocked` | `mon/PGMap.cc` |
| `SLOW_OPS` | WARN | `CephClientBlocked` | `mgr/DaemonHealthMetricCollector.cc:18` |
| `OSD_DOWN` | WARN | `CephClientRisk` | `osd/OSDMap.cc` |
| `OSD_NEARFULL` | WARN | `CephClientRisk` | `osd/OSDMap.cc` |
| `OSD_BACKFILLFULL` | WARN | `CephClientRisk` | `osd/OSDMap.cc` |
| `OSD_FULL` | ERR | `CephHealthError`(+`CephClientRisk`) | `osd/OSDMap.cc` |
| `OSD_UNREACHABLE` | ERR | `CephHealthError`(+`CephClientRisk`) | `osd/OSDMap.cc` |
| `OSDMAP_FLAGS` | WARN | `CephClientRisk`（維護時 silence） | `osd/OSDMap.cc` |
| `OSD_FLAGS` | WARN | `CephClientRisk`（維護時 silence） | `osd/OSDMap.cc` |
| `PG_DEGRADED` | WARN | `CephClientRisk`（維護時 silence） | `mon/PGMap.cc` |
| `PG_BACKFILL_FULL` | WARN | `CephClientRisk` | `mon/PGMap.cc` |
| `PG_DAMAGED` | ERR | `CephHealthError`(+`CephClientRisk`) | `mon/PGMap.cc` |
| `PG_RECOVERY_FULL` | ERR | `CephHealthError`(+`CephClientRisk`) | `mon/PGMap.cc` |
| `OSD_SCRUB_ERRORS` | ERR | `CephHealthError`(+`CephClientRisk`) | `mon/PGMap.cc` |
| `OBJECT_UNFOUND` | WARN | `CephClientRisk` | `mon/PGMap.cc` |
| `LARGE_OMAP_OBJECTS` | WARN | `CephClientRisk` | `mon/PGMap.cc` |
| `OSD_TOO_MANY_REPAIRS` | WARN | `CephClientRisk` | `mon/PGMap.cc` |
| `POOL_NEAR_FULL` | WARN | `CephClientRisk` | `mon/PGMap.cc` |
| `POOL_FULL` | ERR | `CephHealthError`(+`CephClientRisk`) | `mon/PGMap.cc` |
| `MON_DOWN` | WARN | `CephClientRisk`（mon 維護時 silence） | `mon/HealthMonitor.cc` |
| `MON_DISK_LOW` | WARN | `CephClientRisk` | `mon/HealthMonitor.cc` |
| `MON_DISK_CRIT` | ERR | `CephHealthError`(+`CephClientRisk`) | `mon/HealthMonitor.cc` |
| `MON_CLOCK_SKEW` | WARN | `CephClientRisk` | `mon/HealthMonitor.cc` |
| `MGR_DOWN` | 動態 | `CephClientRisk`（mgr 維護時 silence） | `mon/MgrMonitor.cc` |
| `RECENT_CRASH` | WARN | `CephClientRisk` | `crash/module.py` |
| `RECENT_MGR_MODULE_CRASH` | WARN | `CephClientRisk` | `crash/module.py` |
| `DEVICE_HEALTH` | WARN | `CephClientRisk` | `devicehealth/module.py` |
| `DEVICE_HEALTH_TOOMANY` | WARN | `CephClientRisk` | `devicehealth/module.py` |
| `BLUESTORE_SLOW_OP_ALERT` | WARN | `CephClientRisk` | `os/bluestore/BlueStore.cc` |
| `BLUEFS_SPILLOVER` | WARN | `CephClientRisk` | `os/bluestore/BlueStore.cc` |
| `BLUESTORE_FREE_FRAGMENTATION` | WARN | `CephClientRisk` | `os/bluestore/BlueStore.cc` |
| `HOST_IN_MAINTENANCE` | WARN | `CephCosmeticNag` | `cephadm/module.py` |
| `OBJECT_MISPLACED` | WARN | `CephCosmeticNag` | `mon/PGMap.cc` |
| `PG_SLOW_SNAP_TRIMMING` | WARN | `CephCosmeticNag` | `mon/PGMap.cc` |

ERR 級的 check 會同時被 `CephHealthError`（health_status==2）和 `CephClientRisk`（逐 name）打中，
形成雙重 page。這是刻意的 backstop：就算我漏分類某個 ERR check，`CephHealthError` 也兜得住。

## 維護時的手動 silence SOP

topology 前提（使用者環境）：**mon node 只跑 mon+mgr；osd node 只跑 osd**，兩者不重疊。
因此各場景的 silence 名單互不交叉。silence 一律掛在 `CephClientRisk` 上，用 `name=~` 限定。

```bash
# A. 維護 mon/mgr node（整台）—— 只會噴 MON_DOWN
amtool silence add alertname="CephClientRisk" 'name="MON_DOWN"' \
  --duration=2h -c "maint mon node X"
#   若維護的是 active mgr，先 `ceph mgr fail <active-mgr>` 切走 → 不噴 MGR_DOWN。
#   CephExporterDown / CephMonQuorumLost 絕不 silence。

# B. 維護 osd node（整台）
amtool silence add alertname="CephClientRisk" \
  'name=~"OSD_DOWN|PG_DEGRADED|OSDMAP_FLAGS|OSD_FLAGS"' \
  --duration=2h -c "maint osd host Y"

# C. 維護單顆 osd（換硬碟）
amtool silence add alertname="CephClientRisk" \
  'name=~"OSD_DOWN|PG_DEGRADED|OSD_FLAGS"' \
  --duration=1h -c "replace osd.N"
```

**安全性質（要在頁面講清楚）**：silence 壓的全是「冗餘下降」訊號；真正「client 被擋」的
`PG_AVAILABILITY` / `SLOW_OPS`（→ `CephClientBlocked`）、任何 ERR 升級（→ `CephHealthError`）、
quorum 失守（→ `CephMonQuorumLost`）、抓取面盲區（→ `CephExporterDown`）都**不在 silence list**，
維護窗內若真的出事照樣 page。`OBJECT_MISPLACED` 因已是 cosmetic，維護時不必再 silence。

**為何不做 per-node silence**：`ceph_health_detail` 只有 `('name','severity')` 兩個 label
（`module.py:742`），無法只靜音某台的 `OSD_DOWN`。雖可另建 `ceph_osd_up == 0 * on(ceph_daemon)
group_left(hostname) ceph_osd_metadata` 的 per-osd 規則達成精準 silence，但下游 check
（`PG_DEGRADED` 等）在 ceph metric 裡本就只有 cluster 級、無 per-node label，做不到完整 node-scoped；
且會讓規則與 silence 流程變複雜。穩定性第一 + 上述 backstop 已足夠，故採 cluster-wide by name。
（此取捨要在頁面「邊界與除錯」記一段，含 per-osd 變體的程式碼供日後參考。）

## 精簡 promtool unit test

只驗 PromQL 邏輯，不碰真 ceph。放頁面「驗證」一節，列檔案內容 + 跑法 + 預期輸出。

驗證點（精簡，2 個情境即可）：

- 情境 1：`PG_AVAILABILITY=1` → `CephClientBlocked` 在 1m fire；`OBJECT_MISPLACED=1` →
  `CephClientRisk` 不 fire（在白名單內）、`CephCosmeticNag` 在 30m fire。
- 情境 2：osd 維護期 silence 後（模擬：只送 `OSD_DOWN=1` 但 alert_rule_test 對 `CephClientRisk`
  斷言 fire，silence 屬 alertmanager 層、promtool 不模擬）→ 改為驗「`OSD_DOWN=1` 時 `CephClientRisk`
  會 fire」（證明沒被 PromQL gate 掉），並驗 `PG_AVAILABILITY` 同時觸發 `CephClientBlocked`。

> promtool 不模擬 alertmanager silence，所以測試只證明「規則該 fire 時有 fire」；silence 行為靠
> SOP 文字 + `amtool` 範例說明，不進 unit test。

## 頁面改寫範圍（in-place）

**保留**（這頁的核心價值）：

- `## 場景`（凌晨換碟、維護期警報風暴）—— 微調結尾導向「手動 silence」而非「PromQL gate」。
- `## 從原始碼追：HEALTH_WARN 是怎麼被丟出來的` 整節：`OSDMAP_FLAGS` / `OSD_FLAGS` /
  `HOST_IN_MAINTENANCE` 的觸發路徑、mgr/prometheus 的 `health_status_to_number` /
  `health_detail` / `OSD_FLAGS` metric 模型。
- 「維護一個動作會同時點亮五~六條 health check」這個關鍵觀察。

**移除**：

- `## 四層 alert 設計` 整節（Tier 0~3 ASCII 圖、四個 group 的規則）。
- `ceph:maintenance_active` recording rule 與所有 `unless on() (... == 1)` gate。
- `PG_AVAILABILITY` 的 `- on() group_left()` 減法、`CephPGActiveCountLow` 等補洞規則。
- `CephMonQuorumAtRisk` 的 `bool (floor(count(...) / 2) + 1)` 數學 → 換成 rule 4 的
  `count(...) < 2`。
- `## Dry-run 推演` 三情境時間線 + `## 實驗計畫` Step 1~6（Rook in kind / Vagrant / chaos test）。
- **bug**：`ceph_osd_flag_pauserd` / `ceph_osd_flag_pausewr`（v19.2.3 的 `OSD_FLAGS` tuple
  只有 noup/nodown/noout/noin/nobackfill/norebalance/norecover/noscrub/nodeep-scrub，
  見 `module.py:69`，**沒有 pause***）—— 整段 `CephClusterPaused` 移除，不留任何引用。

**新增**：

- `## 設計理念`：一句心法 + 為何 catch-all 比列舉完整。
- `## 6 條 rule`：上面的 YAML + cosmetic 白名單表。
- `## 每個 alert 的成因`：按來源檔分組的證據表（行號實作時核對）。
- `## 維護時怎麼 silence`：3 場景 `amtool` SOP + 安全性質說明 + per-node 取捨。
- `## 驗證`：精簡 promtool test。
- `## 邊界與除錯`：精簡保留（exporter 掛掉時的行為、忘記 unset flag 的兜底改由 `CephClientRisk`
  的 `OSDMAP_FLAGS`/`OSD_FLAGS` 持續 page 處理 —— 不再需要 12h timeout 的特製規則）。

frontmatter `title` / `description` 改寫，移除「四層設計」字樣，改述「穩定性第一、手動 silence」。

## 驗證

- `make validate` 必須 exit 0（frontmatter、圖片、quiz、projects.ts slug、Next.js build）。
- 頁面 slug `prometheus-alert-design` 不變 → `projects.ts` / `feature-map.json` 無需改動。
- 所有寫進 MDX 的 check name 與行號，實作時對 pinned v19.2.3 source 逐一核對；無法核對的不寫。

## 風險與緩解

- **風險**：catch-all `CephClientRisk` 把某個其實無害的 WARN 也 page，造成噪音。
  **緩解**：把該 name 加進 cosmetic 白名單即可（一行 regex），且這是有意識的「明確列出不 page 的」
  審計清單，比反向維護「要 page 的」清單更安全。
- **風險**：維護時忘記下 silence → 被自己的維護動作 page。
  **緩解**：SOP 寫成可直接複製的 `amtool` 指令；silence 有 `--duration` 自動到期，不會永久壓住。
- **風險**：行號隨 patch 版本漂移導致 MDX 引用失準。
  **緩解**：實作時對 pinned tag 重新核對；引用以 symbol 名為主、行號為輔。
