# Ceph Prometheus alert 重新設計 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `next-site/content/ceph/features/prometheus-alert-design.mdx` 從 4 層 alert 設計原地改寫成「穩定性第一、6 條 rule」設計，保留原始碼背景、移除 PromQL 維護 gate、補上逐 alert 成因證據與手動 silence SOP。

**Architecture:** 這是**單一 MDX 內容頁的原地改寫**，不是程式碼。因此不走 TDD red/green；「測試」= (1) 每個寫進頁面的 check name / 行號都對 pinned ceph v19.2.3 source 核對過（zero-fabrication），(2) `make validate` exit 0（含 Next.js build）。因為單一 MDX 在改寫途中的中間狀態無法通過 build，**所有內容編輯先完成、最後才一次 `make validate` + 一次 commit + push**，不在改寫途中分段 commit。

**Tech Stack:** Next.js 14.2.5 static MDX（next-mdx-remote）、Python `scripts/validate.py`（`make validate` 觸發）、ceph v19.2.3 pinned submodule、Prometheus / Alertmanager（`amtool`）、promtool（頁面內示範，不實跑）。

---

## Reference: 已核對的 source 證據（ceph v19.2.3，`git describe` 確認 `v19.2.3`）

寫進 MDX 的行號**只能用下表**；下表以外的行號要先 grep 核對再寫。

**`src/osd/OSDMap.cc`**
| check | severity | line |
|---|---|---|
| `OSD_DOWN` | WARN | 7342 |
| `OSD_FULL` | ERR | 7441 |
| `OSD_BACKFILLFULL` | WARN | 7451 |
| `OSD_NEARFULL` | WARN | 7462 |
| `OSDMAP_FLAGS` | WARN | 7493 |
| `OSD_FLAGS` | WARN | 7540 |
| `OSD_UNREACHABLE` | ERR | 7745 |

**`src/mon/PGMap.cc`**
| check | severity | line |
|---|---|---|
| `PG_AVAILABILITY` | WARN | 2573 (sev 2574) |
| `PG_DEGRADED` | WARN | 2578 (sev 2580) |
| `PG_BACKFILL_FULL` | WARN | 2583 |
| `PG_DAMAGED` | ERR | 2588 |
| `PG_RECOVERY_FULL` | ERR | 2593 |
| `OSD_SCRUB_ERRORS` | ERR | 2646 |
| `LARGE_OMAP_OBJECTS` | WARN | 2674 |
| `OSD_TOO_MANY_REPAIRS` | WARN | 2849 |
| `POOL_FULL` | ERR | 3041 |
| `POOL_NEAR_FULL` | WARN | 3047 |
| `OBJECT_MISPLACED` | WARN | 3064 |
| `OBJECT_UNFOUND` | WARN | 3078 |
| `PG_SLOW_SNAP_TRIMMING` | WARN | 3412 |

**其他**
| check / symbol | severity | file:line |
|---|---|---|
| `SLOW_OPS` | WARN | `src/mgr/DaemonHealthMetricCollector.cc:18` |
| `MGR_DOWN` | 動態 level | `src/mon/MgrMonitor.cc:398` |
| `MON_DISK_CRIT` | ERR | `src/mon/HealthMonitor.cc:603` |
| `MON_DISK_LOW` | WARN | `src/mon/HealthMonitor.cc:610` |
| `MON_DOWN` | WARN | `src/mon/HealthMonitor.cc:820` |
| `MON_CLOCK_SKEW` | WARN | `src/mon/HealthMonitor.cc:862` |
| `RECENT_CRASH` | WARN | `src/pybind/mgr/crash/module.py:137` |
| `RECENT_MGR_MODULE_CRASH` | WARN | `src/pybind/mgr/crash/module.py:145` |
| `DEVICE_HEALTH` | WARN | `src/pybind/mgr/devicehealth/module.py:17` |
| `DEVICE_HEALTH_TOOMANY` | WARN | `src/pybind/mgr/devicehealth/module.py:19` |
| `BLUESTORE_SLOW_OP_ALERT` | WARN | `src/os/bluestore/BlueStore.cc:18906` |
| `BLUEFS_SPILLOVER` | WARN | `src/os/bluestore/BlueStore.cc:18930` |
| `BLUESTORE_FREE_FRAGMENTATION` | WARN | `src/os/bluestore/BlueStore.cc:18965` |
| `HOST_IN_MAINTENANCE` | WARN | `src/pybind/mgr/cephadm/module.py:2126` |

**Metric model keepers（`src/pybind/mgr/prometheus/module.py`）**
| symbol | line |
|---|---|
| `health_status_to_number` (0/1/2) | 47 |
| `OSD_FLAGS` tuple（9 個，**無 pause***） | 69 |
| `HEALTHCHECK_DETAIL = ('name','severity')` | 113 |
| `mon_quorum_status` Metric | 641；set 在 1031 |
| `health_detail` Metric | 742；逐 check set=1 在 932 |
| `get_metadata_and_osd_status` | 1121 |

**cephadm 維護連帶動作（背景段用）**：`enter_host_maintenance`（`module.py:2131`）→ `_set_maintenance_healthcheck`（2118，丟 `HOST_IN_MAINTENANCE`）+ `osd set-group noout`（2183）；`exit` 走 `osd unset-group`（2235）。

**舊頁要修的 bug**：舊頁 line 502-509 的 `CephClusterPaused` 用 `ceph_osd_flag_pauserd` / `ceph_osd_flag_pausewr` —— v19.2.3 的 `OSD_FLAGS` tuple（module.py:69）只有 `noup/nodown/noout/noin/nobackfill/norebalance/norecover/noscrub/nodeep-scrub`，**沒有 pause***，故 `ceph_osd_flag_pauserd` 這個 metric 不存在。整段移除。

---

## Task 1: 改寫 frontmatter + 場景 + 原始碼背景（保留段，修行號）

**Files:**
- Modify: `next-site/content/ceph/features/prometheus-alert-design.mdx`（lines 1-216 區段）

- [ ] **Step 1: 改 frontmatter（lines 1-5）**

把 `title` / `description` 的「四層設計」字樣換成穩定性第一版。新內容：

```mdx
---
layout: doc
title: Ceph — Prometheus alert 重新設計：穩定性第一、新手好維護的 6 條 rule
description: 從 ceph 原始碼（OSDMap.cc / PGMap.cc / HealthMonitor.cc / mgr 各 module）核對每個 health check 的觸發路徑與 severity，設計成「health_detail 預設全 page、3 個 cosmetic 白名單例外、維護期用 amtool 手動 silence」的 6 條 alert rule，並附逐 alert 成因證據與維護 silence SOP。
---
```

- [ ] **Step 2: 微調 `## 場景` 結尾（lines 7-35）**

保留凌晨換碟、警報風暴的敘事與那段 `[FIRING]` 範例（lines 9-28）。把 lines 30-35 的「這頁從原始碼層拆 1~4」導言改成導向新設計：原始碼背景 → 6 條 rule → 維護手動 silence（不再提「用 unless 子句 gate」「promtool dry-run 推演」）。改寫 lines 30-35 為：

```mdx
這頁從原始碼層拆三件事：

1. ceph mgr/prometheus 模組丟了哪些 metric、`ceph_health_detail` 的資料模型長怎樣。
2. 一個正當的維護動作（`ceph orch host maintenance enter`）在原始碼裡實際點亮哪些 health check。
3. 重新設計成 6 條 rule：預設把所有會危及 client 的訊號 page，只留一張很短的 cosmetic 白名單；維護期不靠 PromQL 猜測，改用人工 `amtool silence`。
```

- [ ] **Step 3: 修 `## 從原始碼追` 段的兩個行號（lines 37-216）**

這整段保留。但 `File:` 標註的行號要更新成已核對值：
- line 41 `OSDMap.cc (line 7471)` → `OSDMap.cc (line 7493)`（OSDMAP_FLAGS）。同步檢查 code 區塊 lines 43-70 與 v19.2.3 一致（warn_flags 清單）。
- line 80 `OSDMap.cc (line 7498)` → `OSDMap.cc (line 7540)`（OSD_FLAGS）。
- line 107 `cephadm/module.py (line 2118)` 保留（`_set_maintenance_healthcheck` 確在 2118）。
- line 125 `cephadm/module.py (line 2180)` → `cephadm/module.py (line 2183)`（`osd set-group` prefix）。
- lines 147-202 的 mgr/prometheus 段保留，但把 line 161/163 的 `health_detail`(742) 旁補一句 label tuple 出處：`HEALTHCHECK_DETAIL = ('name','severity')` 在 `module.py:113`。
- lines 204-216 的「維護期會拿到這些 gauge」清單保留（它仍正確且為後面 silence 鋪陳）。**但刪掉 line 213 `ceph_osd_flag_noout == 0` 那行的「要用 health_detail 不能只看 ceph_osd_flag_noout」結論裡，任何暗示後面會用 PromQL gate 的措辭**；改成中性陳述「所以判斷維護狀態看 `ceph_health_detail{name=~"HOST_IN_MAINTENANCE|OSD_FLAGS|OSDMAP_FLAGS"}` 最準」（這句仍對，後面 silence SOP 會用到這些 name）。

- [ ] **Step 4: 核對本 task 改動的 code 區塊未捏造**

Run:
```bash
nl -ba ceph/src/osd/OSDMap.cc | sed -n '7488,7545p'
```
Expected: 看到 `checks->add("OSDMAP_FLAGS", HEALTH_WARN, ...)` 約在 7493、`checks->add("OSD_FLAGS", HEALTH_WARN, ...)` 約在 7540，與寫進頁面的行號一致。

---

## Task 2: 用 6 條 rule 取代「四層 alert 設計」整節

**Files:**
- Modify: `next-site/content/ceph/features/prometheus-alert-design.mdx`（刪除舊 lines 218-496「為什麼 stock 會吵」+「四層 alert 設計」+ 各 Tier；新增「設計理念」+「6 條 rule」）

- [ ] **Step 1: 刪除舊段**

刪掉舊頁 `## 為什麼 stock ceph-mixin 規則會吵`（lines 218-252）、`## 四層 alert 設計`（lines 254-496，含 Tier 0~3 的 ASCII 圖與所有 group YAML、`ceph:maintenance_active` recording rule、`unless on()` gate）。

> 保留決策：`## 為什麼 stock 會吵` 的核心觀察（stock 規則不看「我有沒有預期」）很有價值 → 不整段刪，濃縮成新「設計理念」段的兩句引子。

- [ ] **Step 2: 新增 `## 設計理念`**

```mdx
## 設計理念

stock `ceph-mixin/prometheus_alerts.yml` 的哲學是「全部丟出來、oncall 自己判斷」，
正式環境就是 alert fatigue 的元兇——它不看「我有沒有預期現在是 WARN」。

舊版我曾用一條 `ceph:maintenance_active` recording rule + 每條規則掛 `unless on()` 去自動
gate 維護期。問題是：規則在「猜」維護狀態，猜錯就漏 page，看不懂也不敢改。

新設計把「現在是不是維護」這件事從 PromQL 移回人身上，只留一句心法：

> **`ceph_health_detail` 噴出來的，預設全部 page；只有一張很短（3 個）的 cosmetic 白名單例外。
> 維護前人工下一條 `amtool silence`，到期自動解除。**

規則永遠只回答「cluster 有沒有壞」，不回答「這個壞是不是我預期的」——後者交給維護 SOP。

**為什麼 catch-all 比逐條列名更完整**：`ceph_health_detail` 是「每個 active 的 health check
各自 set 一條 =1」（`module.py:932`，label 只有 `('name','severity')` 見 `module.py:113`）。
所以 `name!~"<白名單>"` 的排除法會自動接住沒列到的冷門 check、以及**未來 ceph 版本新增的 check**。
舊的 4 層列了約 20 個固定名字，新 check 會被靜默漏接——對「穩定性第一」是反指標。
```

- [ ] **Step 3: 新增 `## 6 條 rule`（YAML 與 spec 一致）**

貼上 spec 裡的完整 6 條 rule YAML（`groups: - name: ceph-stability-first`，含 `CephHealthError` /
`CephClientBlocked` / `CephClientRisk` / `CephMonQuorumLost` / `CephExporterDown` / `CephCosmeticNag`），
逐字採用 spec `docs/superpowers/specs/2026-05-29-ceph-prometheus-alert-redesign-design.md` 的「設計：6 條 rule」區塊。YAML 後補一句：

```mdx
三組 name 集合（rule 2 / 3 / 6）互斥且涵蓋整個 `ceph_health_detail`：rule 2 ∪ rule 6 剛好是
rule 3 排除的那 5 個 name，所以每個 check 只落到一條，不雙噴也不漏接。rule 1 / 4 / 5 是與
health_detail 正交的 cluster 級 / 抓取面 backstop。
```

- [ ] **Step 4: 新增 cosmetic 白名單表**

```mdx
### Cosmetic 白名單（唯一「不 page」清單，3 個）

| name | 為什麼不 page | 源頭 |
|---|---|---|
| `HOST_IN_MAINTENANCE` | 自己 `ceph orch host maintenance enter` 設的，預期內 | `cephadm/module.py:2126` |
| `OBJECT_MISPLACED` | 副本數足夠、只是位置待搬，rebalance 必經、不危及 client | `PGMap.cc:3064` (WARN) |
| `PG_SLOW_SNAP_TRIMMING` | snap trim 背景積壓，housekeeping，極少直接卡 client | `PGMap.cc:3412` (WARN) |

`OBJECT_MISPLACED` / `PG_SLOW_SNAP_TRIMMING` 是 judgment call（副本充足 / 純背景）。要更保守就把
任一個從白名單拿掉、它即回到 `CephClientRisk` 改成 page。其餘所有 check 一律 page。
```

---

## Task 3: 新增「每個 alert 的成因」證據表（按來源檔分組）

**Files:**
- Modify: `next-site/content/ceph/features/prometheus-alert-design.mdx`（在 6 rule 段之後新增）

- [ ] **Step 1: 新增 `## 每個 alert 的成因（原始碼證據）`**

用 Reference ledger 的行號，按來源檔分組成小節。每組開頭一句說明，再列 `check → severity → 落到哪條 rule`。至少涵蓋下列分組（行號用 ledger）：

```mdx
## 每個 alert 的成因（原始碼證據）

下表每個 check name 都在 ceph v19.2.3 source 核對過。ERR 級 check 會同時被 `CephHealthError`
（`ceph_health_status == 2`）和 `CephClientRisk`（逐 name）打中，形成刻意的雙重 backstop。

### OSD / OSDMap（`src/osd/OSDMap.cc`）

| check | severity | line | rule |
|---|---|---|---|
| `OSD_DOWN` | WARN | 7342 | CephClientRisk（維護時 silence） |
| `OSD_NEARFULL` | WARN | 7462 | CephClientRisk |
| `OSD_BACKFILLFULL` | WARN | 7451 | CephClientRisk |
| `OSD_FULL` | ERR | 7441 | CephHealthError (+CephClientRisk) |
| `OSD_UNREACHABLE` | ERR | 7745 | CephHealthError (+CephClientRisk) |
| `OSDMAP_FLAGS` | WARN | 7493 | CephClientRisk（維護時 silence） |
| `OSD_FLAGS` | WARN | 7540 | CephClientRisk（維護時 silence） |

### PG / 資料放置（`src/mon/PGMap.cc`）

| check | severity | line | rule |
|---|---|---|---|
| `PG_AVAILABILITY` | WARN | 2573 | **CephClientBlocked**（client IO 卡住） |
| `PG_DEGRADED` | WARN | 2578 | CephClientRisk（維護時 silence） |
| `PG_BACKFILL_FULL` | WARN | 2583 | CephClientRisk |
| `PG_DAMAGED` | ERR | 2588 | CephHealthError (+CephClientRisk) |
| `PG_RECOVERY_FULL` | ERR | 2593 | CephHealthError (+CephClientRisk) |
| `OSD_SCRUB_ERRORS` | ERR | 2646 | CephHealthError (+CephClientRisk) |
| `LARGE_OMAP_OBJECTS` | WARN | 2674 | CephClientRisk |
| `OSD_TOO_MANY_REPAIRS` | WARN | 2849 | CephClientRisk |
| `POOL_NEAR_FULL` | WARN | 3047 | CephClientRisk |
| `POOL_FULL` | ERR | 3041 | CephHealthError (+CephClientRisk) |
| `OBJECT_UNFOUND` | WARN | 3078 | CephClientRisk |
| `OBJECT_MISPLACED` | WARN | 3064 | CephCosmeticNag |
| `PG_SLOW_SNAP_TRIMMING` | WARN | 3412 | CephCosmeticNag |

### 客戶請求被擋（`src/mgr/DaemonHealthMetricCollector.cc`）

`SLOW_OPS`（WARN，line 18）由 OSD 與 Monitor 共用發出，語意是「請求被 block」。這是 client
此刻已被影響，落到 `CephClientBlocked`（`for: 1m`），不在任何 silence list。

### MON / MGR（`src/mon/HealthMonitor.cc`、`src/mon/MgrMonitor.cc`）

| check | severity | file:line | rule |
|---|---|---|---|
| `MON_DOWN` | WARN | HealthMonitor.cc:820 | CephClientRisk（mon 維護時 silence）+ CephMonQuorumLost backstop |
| `MON_DISK_LOW` | WARN | HealthMonitor.cc:610 | CephClientRisk |
| `MON_DISK_CRIT` | ERR | HealthMonitor.cc:603 | CephHealthError (+CephClientRisk) |
| `MON_CLOCK_SKEW` | WARN | HealthMonitor.cc:862 | CephClientRisk |
| `MGR_DOWN` | 動態 | MgrMonitor.cc:398 | CephClientRisk（mgr 維護時先 `ceph mgr fail` 切走） |

### crash / device / bluestore

| check | severity | file:line | rule |
|---|---|---|---|
| `RECENT_CRASH` | WARN | crash/module.py:137 | CephClientRisk（人工處理完 `ceph crash archive`） |
| `RECENT_MGR_MODULE_CRASH` | WARN | crash/module.py:145 | CephClientRisk |
| `DEVICE_HEALTH` | WARN | devicehealth/module.py:17 | CephClientRisk |
| `DEVICE_HEALTH_TOOMANY` | WARN | devicehealth/module.py:19 | CephClientRisk |
| `BLUESTORE_SLOW_OP_ALERT` | WARN | BlueStore.cc:18906 | CephClientRisk |
| `BLUEFS_SPILLOVER` | WARN | BlueStore.cc:18930 | CephClientRisk |
| `BLUESTORE_FREE_FRAGMENTATION` | WARN | BlueStore.cc:18965 | CephClientRisk |
```

- [ ] **Step 2: 核對表中三個高風險引用**

Run:
```bash
grep -n '"SLOW_OPS"' ceph/src/mgr/DaemonHealthMetricCollector.cc
grep -n '"MGR_DOWN"' ceph/src/mon/MgrMonitor.cc
grep -n 'BLUESTORE_SLOW_OP_ALERT\|BLUEFS_SPILLOVER\|BLUESTORE_FREE_FRAGMENTATION' ceph/src/os/bluestore/BlueStore.cc
```
Expected: 分別命中 18 / 398 / 18906,18930,18965，與表格一致。

---

## Task 4: 新增維護 silence SOP + per-node 取捨

**Files:**
- Modify: `next-site/content/ceph/features/prometheus-alert-design.mdx`

- [ ] **Step 1: 新增 `## 維護時怎麼 silence`**

採用 spec 「維護時的手動 silence SOP」整段：topology 前提（mon node 只跑 mon+mgr、osd node 只跑 osd）
+ 三個 `amtool silence add` 指令（mon/mgr 整台、osd 整台、單顆 osd）+ 安全性質段。逐字貼 spec 的三個
bash 區塊。安全性質段要點：silence 壓的全是「冗餘下降」訊號；`PG_AVAILABILITY`/`SLOW_OPS`（→
CephClientBlocked）、ERR 升級（→ CephHealthError）、quorum 失守（→ CephMonQuorumLost）、抓取面
盲區（→ CephExporterDown）都不在 silence list，維護窗內出事照樣 page。

- [ ] **Step 2: 新增 per-node 取捨小節**

```mdx
### 為什麼不做 per-node silence

`ceph_health_detail` 只有 `('name','severity')` 兩個 label（`module.py:113`），無法只靜音某台的
`OSD_DOWN`——`amtool silence ... name="OSD_DOWN"` 是整 cluster 靜音。

要精準到單台，得另建一條帶 per-osd label 的規則：

`ceph_osd_up == 0`（`module.py` 的 OSD_STATUS，每顆一條，帶 `ceph_daemon`）join 上 hostname：

​```promql
(ceph_osd_up == 0) * on(ceph_daemon) group_left(hostname) ceph_osd_metadata
​```

之後 `amtool silence add alertname=CephOsdDown ceph_daemon="osd.5"`（單顆）或 `hostname="osd-3"`
（整台）就能精準靜音。**但這只解決一半**：下游 check（`PG_DEGRADED`、`OBJECT_MISPLACED` 等）在
ceph metric 裡本就只有 cluster 級、沒有 per-node label，做不到完整 node-scoped；且要多一條規則、
維護從一行 silence 變兩行、還得分清 `ceph_daemon` vs `name` 兩種寫法。

以「穩定性第一 + mon/osd 分離 topology + 上述 backstop」評估，cluster-wide by name 已足夠安全，
故採用之；per-osd 變體留作日後若真有需求再加。
```

> 注意 promql 區塊內的反引號要用全形或跳脫，避免破壞 MDX；實作時用三個反引號 code fence 包住，
> 上面範例用了 `​```promql` 佔位，實際寫入時改成正常 fence。

---

## Task 5: 用「驗證(promtool)」取代 dry-run/實驗計畫，精簡邊界與除錯

**Files:**
- Modify: `next-site/content/ceph/features/prometheus-alert-design.mdx`（刪除舊 lines 573-903 的 Dry-run 推演 + 實驗計畫；改寫 lines 905-953 的邊界與除錯 + 接下來）

- [ ] **Step 1: 刪除 `## Dry-run 推演` + `## 實驗計畫`（舊 lines 573-903）**

整段移除（三情境時間線、promtool tests.yml 大區塊、Step 1~6 的 kind/Rook/Vagrant/chaos test）。

- [ ] **Step 2: 新增精簡 `## 驗證（promtool）`**

只驗 PromQL 邏輯、不碰真 ceph。給一支小 `tests.yml` + 跑法 + 預期輸出。內容：

```mdx
## 驗證（promtool）

規則邏輯用 Prometheus 內建 `promtool test rules` 驗，不需要真 ceph。promtool **不模擬
alertmanager silence**，所以這裡只證明「該 fire 時有 fire」；silence 行為靠上面的 `amtool` SOP。

​```yaml
# tests.yml
rule_files: [ ./ceph-alerts.yml ]
evaluation_interval: 30s
tests:
  - interval: 30s
    name: "client IO blocked 與 cosmetic 分流"
    input_series:
      - series: 'ceph_health_detail{name="PG_AVAILABILITY"}'
        values: '1x10'
      - series: 'ceph_health_detail{name="OBJECT_MISPLACED"}'
        values: '1x70'
    alert_rule_test:
      - eval_time: 2m            # PG_AVAILABILITY for:1m 應已 fire
        alertname: CephClientBlocked
        exp_alerts:
          - exp_labels: { severity: critical, name: "PG_AVAILABILITY" }
      - eval_time: 2m            # OBJECT_MISPLACED 在白名單 → CephClientRisk 不該 fire
        alertname: CephClientRisk
        exp_alerts: []
      - eval_time: 31m           # OBJECT_MISPLACED for:30m → CephCosmeticNag fire
        alertname: CephCosmeticNag
        exp_alerts:
          - exp_labels: { severity: info, name: "OBJECT_MISPLACED" }
​```

​```bash
promtool check rules ceph-alerts.yml   # lint
promtool test rules tests.yml          # 預期 SUCCESS
​```
```

> 反引號 fence 同 Task 4 注意事項，實作時用正常三反引號。

- [ ] **Step 3: 改寫 `## 邊界與除錯`**

保留並改寫，要點：
- **exporter 掛掉時**：`up{job="ceph"} == 0` → `CephExporterDown` 永不 silence，mgr/prometheus 掛掉時照樣叫醒（取代舊頁那段 `unless` 在 vector 不存在時的 semantics 討論）。
- **忘記 unset noout/flag**：不再需要舊頁的 12h 特製 `CephOSDFlagsSet` 規則。維護的 silence 有
  `--duration` 會自動到期；到期後若 flag 還在，`OSDMAP_FLAGS` / `OSD_FLAGS` 會讓 `CephClientRisk`
  在 5m 後重新 page。比舊的 12h 更早提醒。
- **alertmanager inhibit（選配）**：可保留一段「若想雙保險，可在 alertmanager 對 `CephCosmeticNag`
  的 `HOST_IN_MAINTENANCE` 設 inhibit」，但標為選配，不是主路徑。

- [ ] **Step 4: 保留 `## 接下來 / 相關頁面`（舊 lines 947-953）**

四條相對連結（osd-flapping / pg-health-states / osd-ok-to-stop / mon-clock-skew-detection）保留。
把舊文案「Tier 2 的 CephMonClockSkew 訊號從哪來」改成「`MON_CLOCK_SKEW` 訊號從哪來（落到 CephClientRisk）」。

- [ ] **Step 5: 全頁掃描確認 bug 與舊措辭已清除**

Run:
```bash
grep -n 'pauserd\|pausewr\|maintenance_active\|unless on()\|四層\|Tier [0-3]\|dry-run\|CephClusterPaused\|group_left() (ceph_health' next-site/content/ceph/features/prometheus-alert-design.mdx
```
Expected: **無輸出**（所有舊機制與 bug 措辭都已移除）。若有輸出，回去清掉。

---

## Task 6: 驗證、commit、push

**Files:** 無新增；驗證整頁。

- [ ] **Step 1: 大陸用語 / never-translate 自查**

Run:
```bash
grep -n '软件\|软体\|网络\|文件\|程序\|默认\|数据\|用户\|视频\|分辨率\|鼠标' next-site/content/ceph/features/prometheus-alert-design.mdx
```
Expected: 無輸出。

- [ ] **Step 2: `make validate`**

Run:
```bash
make validate
```
Expected: `All checks passed!`、exit 0（含 Next.js build 通過）。若 build 失敗，多半是 MDX fence/角括號問題，修正後重跑。

- [ ] **Step 3: commit（no gpg sign）**

```bash
git add next-site/content/ceph/features/prometheus-alert-design.mdx
git commit --no-gpg-sign -m "$(cat <<'EOF'
Rewrite ceph prometheus-alert-design: 穩定性第一的 6 條 rule

把 4 層 alert 設計改寫成 health_detail 預設全 page + 3 個 cosmetic 白名單
+ 維護期 amtool 手動 silence。新增逐 alert 成因的 v19.2.3 原始碼證據表、
維護 silence SOP、per-node 取捨；移除 PromQL 維護 gate、dry-run、6 步實驗
與不存在的 ceph_osd_flag_pauserd。

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: push**

```bash
GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push
```
Expected: `master -> master` 更新成功。

---

## Self-Review

**Spec coverage：**
- 設計理念 + catch-all 完整性 → Task 2 Step 2。
- 6 條 rule YAML → Task 2 Step 3。
- Cosmetic 白名單（3 個）→ Task 2 Step 4。
- 逐 alert 成因證據表 → Task 3。
- 維護 silence SOP（3 場景）→ Task 4 Step 1。
- per-node 取捨 → Task 4 Step 2。
- 精簡 promtool → Task 5 Step 2。
- 保留原始碼背景、移除 4 層/recording rule/減法/bool/dry-run/實驗/pauserd bug → Task 1 + Task 2 Step 1 + Task 5 Step 1 + Task 5 Step 5。
- frontmatter 改寫 → Task 1 Step 1。
- `make validate` → Task 6。slug 不變、不動 projects.ts / feature-map.json → 計畫未觸碰，符合 spec non-goals。

**Placeholder scan：** 無 TBD/TODO；行號全部用 Reference ledger 的已核對值；YAML/表格大區塊明確指向 spec 對應段並逐字採用。

**Type/名稱一致性：** alert 名稱（CephHealthError / CephClientBlocked / CephClientRisk / CephMonQuorumLost / CephExporterDown / CephCosmeticNag）跨 Task 一致；白名單 3 名（HOST_IN_MAINTENANCE / OBJECT_MISPLACED / PG_SLOW_SNAP_TRIMMING）跨 Task 2/3/4 一致；rule 3 排除 5 名 = rule 2(2) ∪ rule 6(3)，分流一致。
