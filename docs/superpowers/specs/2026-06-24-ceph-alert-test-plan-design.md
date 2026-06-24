# Ceph Prometheus Alert 測試計劃 — 設計（spec）

> 日期：2026-06-24
> 被測對象來源（single source of truth）：`next-site/content/ceph/features/prometheus-alert-design.mdx`
> 子計畫定位：SP-6（ceph）下的驗證子題；產出 `experiments/ceph-alert-rules/` 測試 harness + 一頁讀者向 MDX 專題頁。
> 自主決策聲明：使用者離線授權「遇到選擇採用推薦方案」，本 spec 內所有「決策」欄位即代為核准的選項，附理由。

## 1. 目標

`prometheus-alert-design` 那頁設計了一整套「在 ceph-mixin 預設 rule 之上加一層維護友善 alert」的方案。本計劃要在**開發環境**把這套設計**逐條規則**驗證過，證明：

1. 每條 alert 的 PromQL expr、`for:` 時長、輸出 label 都如設計所述。
2. catch-all 規則 `CephClientRisk` 的排除清單真的把維護噪音（`PG_DEGRADED` / `OSDMAP_FLAGS` / `MON_DOWN` / `OSD_DOWN`…）擋在 pager 外。
3. 兩條 recording rule 的 join 與「整台 host down vs 單顆 OSD down」去重邏輯正確。
4. Alertmanager routing 把每條 alert 對映到正確 receiver——尤其**預設 aggregate rule（`CephMonDownQuorumAtRisk` / `CephOSDDownHigh` / `CephHealthWarning`）不得進 pager**。
5. 維護用的 scoped silence 只 silence 目標 `hostname` / `ceph_daemon`，不波及其他台。

每條測試都要明確記載：**測哪一條規則 / 哪個情境 / step-by-step 怎麼測 / 預期結果（PASS 判準）**。先涵蓋正常常見 case，再涵蓋 edge case。整套設計成可由 **AI agent 無人值守執行**：純 CLI、靠 exit code 與結構化輸出判 PASS/FAIL，無 GUI、無互動。

## 2. 被測系統（被測規則清單）

全部逐字取自 `prometheus-alert-design.mdx`（頁面是 rule 的唯一真實來源；抽出來放 `experiments/ceph-alert-rules/rules/` 時不得改寫，改寫會讓測試失去意義）。

**`ceph-stability-first`（client 風險，多數不可 silence）**
| Alert | expr 摘要 | for | severity |
|---|---|---|---|
| `CephClientBlocked` | `ceph_health_detail{name=~"PG_AVAILABILITY\|SLOW_OPS"} == 1` | 1m | critical |
| `CephClientRisk` | `ceph_health_detail{name!~"<10 個排除>"} == 1` | 5m | critical |
| `CephMonQuorumLost` | `count(ceph_mon_quorum_status == 1) < 2` | 1m | critical |
| `CephExporterDown` | `up{job="ceph"} == 0` | 5m | critical |
| `CephLowPriorityNotice` | `ceph_health_detail{name=~"<5 個低優先>"} == 1` | 30m | info |

`CephClientRisk` 排除清單（10 個）：`PG_AVAILABILITY` `SLOW_OPS` `OSD_DOWN` `OSD_HOST_DOWN` `MON_DOWN` `HOST_IN_MAINTENANCE` `OBJECT_MISPLACED` `PG_SLOW_SNAP_TRIMMING` `PG_DEGRADED` `OSDMAP_FLAGS`。
`CephLowPriorityNotice` 清單（5 個）：`HOST_IN_MAINTENANCE` `OBJECT_MISPLACED` `PG_SLOW_SNAP_TRIMMING` `PG_DEGRADED` `OSDMAP_FLAGS`。

**`ceph-scoped-availability`（帶 label，維護可精準 silence）**
| 物件 | expr 摘要 |
|---|---|
| record `ceph:osd_up:with_hostname` | `ceph_osd_up * on (ceph_daemon) group_left(hostname) ceph_osd_metadata` |
| record `ceph:osd_host_down:scoped` | `count by (hostname)(…==0) == count by (hostname)(…)` |
| `CephOSDHostDownScoped` | `ceph:osd_host_down:scoped`，for 5m |
| `CephOSDDaemonDownScoped` | `(…==0) unless on (hostname) ceph:osd_host_down:scoped`，for 5m |
| `CephMonDownScoped` | `((1 - ceph_mon_quorum_status) * on (ceph_daemon) group_left(hostname) ceph_mon_metadata) == 1`，for 30s |

**預設 ceph-mixin（保留當 context）**：`CephHealthError`（`ceph_health_status == 2`，for 5m，`type=ceph_default`，要 page）、`CephHealthWarning`（`ceph_health_status == 1`，Slack-only）、以及 aggregate rule `CephMonDownQuorumAtRisk` / `CephOSDDownHigh` 等（保留但 routing 只進 Slack）。

**Alertmanager routing**（頁面「把角色映射到 receiver」一節）：4 條 route，第 1 條 `type=ceph_default ∧ alertname=CephHealthError → pager`；第 2 條 7 個自訂 alertname regex → pager；第 3 條 `CephLowPriorityNotice → slack`；第 4 條 `type=ceph_default → slack`（兜底）。

## 3. 測試方法論（決策：四層分層）

**決策：採用 promtool / amtool / live / real-ceph 四層**，理由：能用 deterministic 的工具精準測 PromQL 與 routing（A/B），用真服務測端到端 wiring 與 silence（C），把只有真 ceph 能回答的「ceph 到底匯出什麼 metric / 升什麼 health check」留給能驗的環境（D）並以原始碼當 oracle。對齊本專案既有 L3/L4 慣例與「AI agent 可無人執行」要求。本機已具備 `promtool 3.12.0` / `prometheus` / `docker` / `go` / `python3`，僅需補 `amtool`+`alertmanager`（`brew install alertmanager`，一次給兩個 binary；fallback：`go install` amtool + 下載 release，或 docker `prom/alertmanager`）。

| Tier | 工具 | 測什麼 | 本機可跑？ | 性質 |
|---|---|---|---|---|
| **A — 規則邏輯** | `promtool test rules` | 每條 alert + recording rule 的 expr / `for:` / label / 排除清單 | ✅ 完全可跑、deterministic | **核心，必過** |
| **B — Routing** | `amtool config routes test` | 每個 label set → 哪個 receiver；預設 aggregate 不進 pager | ✅ deterministic | **核心，必過** |
| **C — Live 整合 smoke** | 真 `prometheus` + 真 `alertmanager` + python webhook sink | 規則真載入、alert 真傳到 AM 並 route、silence 真的壓掉目標 | ✅（裝 alertmanager 後） | 整合層，較易 flaky，獨立於 A/B |
| **D — 真 ceph** | Proxmox 3-node + ceph v19.2.3 | 每情境 ceph 實際升的 health check、stopped mon 的 metric 是否仍在 | ❌ 需真環境 | 以原始碼 oracle 驗 + 「在你環境跑後對照」標註 |

**Tier 間分工原則**：
- `for:` 精確語意（1m/5m/30m/30s 邊界、flap reset）**只在 Tier A 測**（promtool 可凍結時間，精準）。
- Tier C 為了不要跑 30 分鐘，用**腳本產生 `for:` 縮短版** rule 副本（如全部改 10s）只測 wiring/routing/silence；真 `for:` 值由 Tier A 保證。此分工要在文件與腳本註解寫清楚，避免誤會 Tier C 在測時長。
- ceph 行為宣稱（stopped mon 仍在 monmap 故 `mon_quorum_status{ceph_daemon=...}=0` 與 metadata 仍在、maintenance enter 自動設 `noout`→`OSDMAP_FLAGS`、掉副本→`PG_DEGRADED`）**不在 dev 重新推導**；Tier A 測的是「**若**這些 series 以這些 label 存在，alert **就**會帶 `hostname`/`ceph_daemon` 而可被 silence」，而「series 是否真的存在」由 Tier D / 原始碼負責。這個邊界要在每條相關測試的註解標明。

## 4. 逐條測試矩陣（Tier A 為主，標 →B/→C/→D 表示該情境另在哪層覆蓋）

每列 = 一個測試情境。「預期」即 PASS 判準。

### 4.1 `CephHealthError`（預設，page 總開關）
- **正常-觸發**：`ceph_health_status=2` 持續 5m → 5m fire，label `severity=critical,type=ceph_default`。
- **正常-不觸發**：`=1` / `=0` → 永不 fire。
- **edge-for 邊界**：4m 時不 fire，5m 才 fire。
- **edge-for reset（flap）**：2→0→2 在 5m 內跳動 → `for` 重置，不 fire。
- →B：`{alertname=CephHealthError,type=ceph_default}` → **pager**。

### 4.2 `CephHealthWarning`（預設，Slack-only）
- **正常**：`ceph_health_status=1` → fire（Tier A 只驗 fire 與否）。
- →B：`{alertname=CephHealthWarning,type=ceph_default}` → **slack**（不可進 pager）。

### 4.3 `CephClientBlocked`
- **正常-PG_AVAILABILITY**：`name=PG_AVAILABILITY,value=1` → 1m fire，summary 含 `PG_AVAILABILITY`，label `severity=critical`（注意 metric 的 `severity` label 被 rule label 蓋掉）。
- **正常-SLOW_OPS**：同上換 name。
- **edge-雙 name 同時**：`PG_AVAILABILITY` + `SLOW_OPS` 同時 active → **兩個 alert 實例**（每 name 一個）。
- **負向-不該接的 name**：`name=PG_DEGRADED,value=1` → 此規則**不** fire（交給別條）。
- **edge-inactive**：`value=0` → 不 fire。
- **edge-for**：active 59s 後清掉 → 不 fire（for 1m）。

### 4.4 `CephClientRisk`（catch-all，最關鍵）
- **正常-觸發**：任一不在排除清單的 check，如 `name=POOL_NEAR_FULL,value=1` → 5m fire，summary 含該 name。
- **負向-逐一排除（10 條，每條一個測試）**：`PG_AVAILABILITY` / `SLOW_OPS` / `OSD_DOWN` / `OSD_HOST_DOWN` / `MON_DOWN` / `HOST_IN_MAINTENANCE` / `OBJECT_MISPLACED` / `PG_SLOW_SNAP_TRIMMING` / `PG_DEGRADED` / `OSDMAP_FLAGS` 各自 `value=1` → `CephClientRisk` **不** fire。
- **edge-維護綜合情境（本計劃的核心宣稱）**：`PG_DEGRADED` + `OSDMAP_FLAGS` + `OSD_HOST_DOWN` + `MON_DOWN` 同時 active 滿 5m → `CephClientRisk` **完全不** fire（證明維護不會經由 catch-all 繞回來 page）。
- **edge-混合**：一個排除 name + 一個非排除 name 同時 active → 只為非排除 name fire 一個實例。

### 4.5 `CephMonQuorumLost`（3-mon 寫死）
- **正常-健康**：3 mon `quorum_status` 皆 1，count=3，不 `<2` → 不 fire。
- **正常-維護 1 台（生命線靜默）**：1 台=0、2 台=1，count=2，不 `<2` → 不 fire。
- **觸發-掉 2 台**：count=1 `<2` → 1m fire。
- **觸發-全掉**：count=0 → fire。
- **edge-`==1` filter**：3 series 值 `1,1,0` → count=2 不 fire；`1,0,0` → count=1 fire（值非 1 不算數）。

### 4.6 `CephExporterDown`
- **正常**：`up{job="ceph"}=1` → 不 fire。
- **觸發**：`=0` 持續 5m → fire。
- **edge-label 選擇**：`up{job="node"}=0` → 此規則不 fire（只認 `job="ceph"`）。
- **edge-for flap**：5m 內 0→1→0 → 不 fire。

### 4.7 `CephLowPriorityNotice`
- **正常-逐一觸發（5 條）**：`HOST_IN_MAINTENANCE` / `OBJECT_MISPLACED` / `PG_SLOW_SNAP_TRIMMING` / `PG_DEGRADED` / `OSDMAP_FLAGS` 各 `value=1` → 30m fire，`severity=info`。
- **負向**：`name=PG_AVAILABILITY` → 不 fire。
- **edge-for**：29m 不 fire、30m fire。
- **跨規則一致性（關鍵）**：載入整組 stability-first，餵 `PG_DEGRADED=1`（與 `OSDMAP_FLAGS=1`）→ 斷言 `CephLowPriorityNotice` fire（info/slack）**且** `CephClientRisk` 不 fire（critical/page）。這是頁面設計最乾淨的證明。

### 4.8 recording rule `ceph:osd_up:with_hostname`
- **join 正常**：`ceph_osd_up{ceph_daemon=osd.0}=1` + `ceph_osd_metadata{ceph_daemon=osd.0,hostname=osd-host-a}=1` → 產出值 1、帶 `hostname=osd-host-a`。
- **edge-缺 metadata**：某 OSD 有 `ceph_osd_up` 但無對應 metadata → join 後該 series 消失（scoped 規則對它盲）；標註此為頁面「metadata 一定存在」假設的依賴點。

### 4.9 recording rule `ceph:osd_host_down:scoped`
- **整台 down**：host-a 3 顆 OSD 全 0 → 產出 `hostname=osd-host-a`（值 3）。
- **部分 down**：host-a 1/3 down → 不產出（1≠3）。
- **全 up**：不產出。
- **多 host**：host-a 全 down、host-b 全 up → 只產出 host-a。

### 4.10 `CephOSDHostDownScoped`
- **整台 down**：→ 5m fire，label `hostname=osd-host-a`，summary 含該 hostname。
- **部分 down**：→ 不 fire。
- →C：silence `hostname=osd-host-a` 壓掉本 alert；注入 host-b 全 down → host-b 的 alert 不被壓。

### 4.11 `CephOSDDaemonDownScoped`（`unless` 去重）
- **單顆 down**：osd.5 down、同 host 其他 OSD up → fire `{ceph_daemon=osd.5,hostname=osd-host-a}`，且 `CephOSDHostDownScoped` 不 fire。
- **整台 down（去重關鍵）**：host-a 全 down → `CephOSDHostDownScoped` fire，`CephOSDDaemonDownScoped` 對該 host 任何 OSD **皆不** fire（被 `unless` 壓掉；證明整台掛不會每顆各叫一次）。
- **edge-混合**：host-a 全 down + host-b 的 osd.9 單顆 down → host-a 只出 host alert、osd.9 出 daemon alert。
- **edge-值為 0 仍 fire**：`==0` 回傳值 0 的 series，alert 仍 fire（驗證 alerting rule 靠 series 存在而非真值）。

### 4.12 `CephMonDownScoped`
- **觸發**：mon.a `quorum_status=0` + metadata 存在 → 30s fire，`{ceph_daemon=mon.a,hostname=mon-host-a}`。
- **正常**：全 in-quorum（=1）→ `1-1=0`，`==1` false → 不 fire。
- **edge-缺 metadata**：mon `=0` 但無 metadata → join 無結果 → 不 fire（呼應頁面 monmap 宣稱：metadata 在才接得到）。→D：「stopped mon 是否仍有 metadata/quorum_status series」由真 ceph 驗。
- **edge-短 for**：30s 即 fire（mon down 設計上比 OSD 急）。

### 4.13 Routing（Tier B 全量）
對每個 label set 跑 `amtool config routes test`，斷言 receiver：
- → **pager**：`CephHealthError(type=ceph_default)`、`CephClientBlocked`、`CephClientRisk`、`CephMonQuorumLost`、`CephExporterDown`、`CephOSDHostDownScoped`、`CephOSDDaemonDownScoped`、`CephMonDownScoped`。
- → **slack**：`CephLowPriorityNotice`、`CephHealthWarning(type=ceph_default)`、**`CephMonDownQuorumAtRisk(type=ceph_default)`**、**`CephOSDDownHigh(type=ceph_default)`**、無 match 的兜底。
- **核心斷言**：帶 `type=ceph_default` 的預設 aggregate（除 `CephHealthError`）一律 slack，不得 pager。

### 4.14 Silence（Tier C）
- **host 粒度**：silence `alertname=CephOSDHostDownScoped, hostname=osd-host-a` → 該 alert suppressed；另注入 `hostname=osd-host-b` 的同 alert → **不** suppressed。
- **daemon 粒度**：silence `alertname=CephOSDDaemonDownScoped, ceph_daemon=osd.5` → 只壓 osd.5。
- **mon 粒度**：silence `alertname=CephMonDownScoped, hostname=mon-host-a, ceph_daemon=mon.a` → 只壓 mon.a。
- **生命線不被誤壓**：上述 silence 存在時，注入 `CephMonQuorumLost` / `CephClientBlocked` → 仍送達 pager receiver（證明維護 silence 不會蓋掉真故障）。

### 4.15 邊界：3-mon hard-code vs 動態 majority（Tier A）
- 對 `count(ceph_mon_quorum_status == 1) < (floor(count(ceph_mon_metadata)/2)+1)` 動態式另寫一組測試：
  - 3-mon：動態門檻=2，與寫死 `<2` 在掉 1/掉 2 台時行為一致。
  - 5-mon：門檻=3，掉 2 台（count=3）不 fire、掉 3 台（count=2）fire。
- 證明頁面提供的動態改法在 n=3 時等價於寫死版。

## 5. Harness 架構（決策：鏡像 timesyncd 慣例）

```
experiments/ceph-alert-rules/
  README.md              # 給 AI agent / 使用者照跑的執行計畫（zh-TW 敘述、指令英文），含各 Tier 前置與 PASS 判準
  env.example.sh         # 可調：PROM/AM 版本、port、結果目錄
  rules/                 # 逐字取自頁面的「被測物」
    ceph-stability-first.yml
    ceph-scoped-availability.yml
    alertmanager-route.yml
  tests/
    tierA-promtool/      # 每條規則一個 *.test.yml（promtool test rules 格式）
    tierB-routing/       # routes 測試的 input/expected（amtool）
    tierC-live/          # docker-compose 或本機 binary 編排、python fake webhook sink、scenario 注入
    tierD-realceph/      # 各情境的「ceph 預期 health check」對照表（原始碼 oracle）+ 在你環境跑後對照欄
  lib/                   # 共用：產 for:-縮短版 rule、POST alert 到 AM、輪詢 AM API 的 helper
  run/
    all.sh tierA.sh tierB.sh tierC.sh   # 一鍵；各自獨立 exit code
  results/.gitkeep       # 跑完的 promtool/amtool/live 輸出落這
```

**AI agent 執行入口**：`run/all.sh` 依序跑 A→B→C，任何 tier 非 0 即整體 FAIL 並印出哪個情境掛了。A/B 無外部相依（promtool/amtool）；C 需 alertmanager binary（README 寫安裝）。

## 6. 真實來源與 oracle 處理（source-first）

- `rules/*.yml` 必須與頁面 YAML **逐字一致**；建一個 `lib/check-rules-match-page.sh`（或測試）比對抽出的 YAML 與頁面內容，避免漂移。
- 若測試揭露**頁面規則本身**的 bug（非測試寫錯）：記為 finding，於最終總結報告；只有在修正明確正確時才同步改頁面並註明，judgment call 留給使用者醒來定奪（autonomy 邊界）。
- Tier D 的「預期 health check」逐一附 ceph 原始碼行號 oracle（頁面已給多數：`OSDMap.cc:7316/7342/7493`、`PGMap.cc:2578`、`cephadm/module.py:2126/2131`、`prometheus/module.py:1021` 等），新測試沿用同來源。

## 7. 交付物

1. `experiments/ceph-alert-rules/` 完整 harness（上述），A/B/C 在本機實跑過、結果存 `results/`。
2. 讀者向 MDX 專題頁 `next-site/content/ceph/features/prometheus-alert-testing.mdx`：以「緣起→方法論（四層為何這樣分）→逐條測什麼/怎麼測/預期→怎麼跑→邊界與限制」敘事，source-first 對照被測規則與 ceph 原始碼。整合 `projects.ts`（features[] + 「監控與告警」群組）、`feature-map.json`（node + edge：`prometheus-alert-design → prometheus-alert-testing 「驗證」`）、`quiz.json`（2–3 題）。
3. `make validate` exit 0；commit（no-gpg）+ push（`.ssh/` key）。

## 8. 驗證等級（依專案規範）

- Tier A/B/C 指令：可在本機跑 → **必須實跑過、記錄回傳值**（promtool/amtool exit 0、live 斷言通過）。
- Tier D 指令：需真 Proxmox+ceph → 原始碼+官方文件交叉驗證，MDX 標「在你環境跑後對照」。
- 破壞性操作：Tier D 的 `maintenance enter` / `osd ok-to-stop` 已在被測頁有警告與回退；本計劃 dev 端不碰真叢集，無新破壞性操作。

## 9. 不做（YAGNI）

- 不建 ceph 叢集模擬器；不重新推導 ceph 內部行為（用原始碼 oracle）。
- 不在 Tier C 測 `for:` 真時長（縮短版）；時長交給 Tier A。
- 不重寫頁面的 alert 設計；本計劃是「驗證既有設計」，非「重新設計」。
- 不加 Mermaid；若要圖一律靜態 PNG（本頁預設不需要圖）。

## 10. 代為核准的決策彙整

| # | 決策 | 理由 |
|---|---|---|
| D1 | 四層方法論（promtool/amtool/live/real-ceph） | 精準測 expr+routing、端到端驗 wiring+silence、真 ceph 宣稱留給能驗的環境 |
| D2 | 交付 = experiments harness + 一頁 MDX 專題頁 | 對齊 timesyncd 先例；MDX 頁正是 `/reviewing-source-first-pages` 能 review 的對象 |
| D3 | rules 逐字抽頁面、不改寫 | 頁面是 single source of truth；測的就是它 |
| D4 | 今晚 `brew install alertmanager` 補 amtool/alertmanager | 讓 B/C 真能跑；fallback go install / docker |
| D5 | Tier C 用 for:-縮短版 rule | 避免 30m 等待與 flaky；時長由 A 保證 |
| D6 | 揭露頁面 rule bug → 先記 finding，明確者才同步改頁並註明 | autonomy 邊界：不擅自重寫設計判斷 |
| D7 | MDX slug = `prometheus-alert-testing` | 與被測頁 `prometheus-alert-design` 配對，語意清楚 |
