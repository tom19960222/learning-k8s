# Task 3 報告：alert rules v2（stability-first 修訂 + ceph-production-coverage + tierA + routing v2）

## 重要背景：本次執行中偵測到並行修改

執行途中發現 repo 有另一個並行程序（很可能是主導 session 直接在跑，範圍涵蓋 Task 4～23，包含真機故障注入證據 `experiments/ceph-alert-real-lab/EVIDENCE-SUMMARY-2026-07-04.md` 與新頁面 `prometheus-alert-real-lab-findings.mdx`）持續在同一份 working tree 上寫檔案，harness 也明確提示「這是預期中的變更，採納即可，不用跟使用者提」。因此本報告除了記錄我自己做的部分，也記錄了「發現、驗證、修正」那些共用檔案的過程——最終 commit 範圍比原始 task-3-brief 的檔案清單略寬（見下方「commit 範圍與理由」）。

## Step 0：真叢集 metric 形狀驗證

```
ssh -i .ssh/id_ed25519 ... ikaros@192.168.18.166 'curl -s http://192.168.18.166:9283/metrics | grep -E "..."'
```

結果：
- `ceph_daemon_health_metrics{type,ceph_daemon}` 存在，label 形狀符合計畫假設。
- `ceph_pool_metadata{pool_id,name,type,description,compression_mode}` 有 `name` 與 `pool_id`。
- `ceph_pg_down/incomplete/unknown/stale/peered{pool_id}` join key 是 `pool_id`。
- `ceph_pool_quota_bytes{pool_id}`、`ceph_pool_bytes_used{pool_id}` 皆存在。
- `ceph_cluster_total_bytes`、`ceph_cluster_total_used_bytes` 無 label（單一 cluster-wide 值，`max()` 包裝合理）。
- `ceph_mgr_status{ceph_daemon}`、`ceph_osd_metadata{ceph_daemon,hostname,...}`、`ceph_osd_commit_latency_ms{ceph_daemon}`、`ceph_osd_up{ceph_daemon}` 皆符合。

**結論：不需要調整任何 expr。** 計畫檔的兩段 YAML 逐字照抄即可。

## TDD 證據

### RED（第一次跑 tierA，rules 尚未寫）

```
### guard：rules 與頁面一致
FAIL  page=1 rules=0 :: ceph_health_detail{name=~"PG_AVAILABILITY|SLOW_OPS"} == 1
FAIL  page=1 rules=0 :: PG_AVAILABILITY|SLOW_OPS|OSD_DOWN|OSD_HOST_DOWN|MON_DOWN|...
...
FORFAIL CephExporterDown: page=5m rules=None
```
（guard 失敗即 `exit 1`，promtool 測試沒機會跑——18 個新 `coverage-*.test.yml` 與 4 個修訂測試檔在這個時點全部處於「規則不存在」的紅燈狀態。）

### GREEN（rules 寫完、checker 同步、修正兩個真 bug 之後）

```
### guard：rules 與頁面一致
... 全部 ok / forok
rules match page (exprs + for: durations consistent both sides)

### promtool check rules（lint）
SUCCESS: 6 rules found（ceph-stability-first）
SUCCESS: 5 rules found（ceph-scoped-availability）
SUCCESS: 18 rules found（ceph-production-coverage）
SUCCESS: 2 rules found（_default-mixin）
SUCCESS: 1 rules found（ceph-mon-quorum-dynamic）

### promtool test rules（單元測試）
... 全部 SUCCESS
TIER A PASS
```

## 過程中發現並修正的 2 個真 bug

1. **`CephDataDamage` 的 em-dash 掉字**：計畫檔逐字要求
   `"Ceph data damage detected: {{ $labels.name }} — identify bad replica before repair"`
   （em-dash `—`），但當時 rules 檔、`coverage-data-damage.test.yml`、以及新頁面
   `prometheus-alert-real-lab-findings.mdx` 的同一段 YAML 都被打成了一般連字號 `-`。
   三處全部改回 em-dash，恢復「與計畫檔逐字一致」的不變量。用 `diff` 對照從 plan 檔抽出的
   verbatim block 與實際 rules 檔逐字比對，確認除了頭部註解與未變動的 `CephMonQuorumLost`
   （計畫檔片段本就不含它）之外，**兩個 rules 檔現在與計畫檔完全 byte-for-byte 一致**。

2. **`for:` 邊界 off-by-one（我自己寫的兩個測試）**：
   - `CephExporterTargetDown`（`for: 15m`）：原本斷言「15m 不 fire、16m fire」，但
     promtool 實測顯示邊界其實在 `for:` duration 本身（14m 不 fire、15m fire）——與
     `CephExporterAllDown`／`CephMonQuorumLost` 等既有慣例一致，是我自己的計算失誤。
     另外「flap reset」向量原本樣本長度不夠（`values` 只到 t=19m），`eval_time: 26m`
     時 promtool 因為超過最後樣本的 staleness 視窗而回傳空結果——延長樣本序列後才穩定通過。
   - `CephCapacityForecast`（`for: 30m`）：用 promtool 直接二分探測（暫存
     `/tmp/probe-forecast*.test.yml`，已清除）確認 `predict_linear` 在 t=1m（第一次有 2 個
     樣本可算斜率）就已超過門檻，所以「30m 不 fire、31m fire」才是實測邊界，不是憑空假設
     的「29m/30m」或我原本猜的「40m」。

   這兩個都是先看到 promtool `FAILED: exp:[...] got:[...]` 的具體輸出才定位、修正，全程
   沒有靠猜測改數字。

## 各檔案變更摘要

- `experiments/ceph-alert-rules/rules/ceph-stability-first.yml`：`CephClientBlocked` regex 加
  `OSD_FULL|POOL_FULL`；`CephClientRisk` 排除清單擴到 24 個；`CephExporterDown` 拆成
  `CephExporterAllDown`（`(count(up{job="ceph"}==1) or vector(0))==0`，5m critical）與
  `CephExporterTargetDown`（`up{job="ceph"}==0`，15m warning）；`CephLowPriorityNotice` 加
  `POOL_APP_NOT_ENABLED|POOL_NEARFULL`。`CephMonQuorumLost` 未動。
- `experiments/ceph-alert-rules/rules/ceph-production-coverage.yml`（新檔）：18 條 rule，逐字照抄
  計畫檔，補了 header 註解與 em-dash 修正。
- `experiments/ceph-alert-rules/rules/alertmanager-route.yml`：routing v2，label 導向
  （`severity="critical"` AND `source=~"ceph_stability|ceph_scoped|ceph_coverage"`），新增
  `watchdog-ceph` receiver（沿用本檔既有的「receiver 只留 name，無 webhook_configs」風格）。
- `experiments/ceph-alert-rules/lib/check-rules-match-page.sh`：invariants 陣列更新（新 regex、
  AllDown expr、移除舊 pager alertname regex 改用 `source=~...`）；`for:` 對照表把
  `CephExporterDown` 換成 `CephExporterAllDown`/`CephExporterTargetDown`；同時（由並行程序）擴充
  成同時比對 design page 與新的 findings page，並補齊 18 條 coverage rule 的 invariant。這超出
  本任務 brief 字面要求，但邏輯上是防漂移 guard 為涵蓋新增規則的自然延伸，我逐條驗證過內容
  正確（`grep -qF` 兩邊都對得上）才接受。
- `experiments/ceph-alert-rules/lib/prometheus-load-check.sh`、`run/tierA.sh`：非 brief 明列，但
  是讓新規則檔真正被 lint／真 Prometheus 載入驗證所必需的配套修改（`rule_files` 清單、`expected`
  陣列加新 alert 名）。
- `tests/tierA-promtool/`：4 個既有檔案修訂（client-blocked 加 OSD_FULL/POOL_FULL 向量；
  client-risk 全面重寫成 24 排除項 + `OSD_NO_DOWN_OUT_INTERVAL` 正向 + `RECENT_CRASH` 不再觸發的
  負向；exporter-down 改測 AllDown/TargetDown 雙軌；low-priority-notice 加兩個新向量）+ 18 個新
  `coverage-*.test.yml`（每條新 rule 一檔，含 firing/not-firing 邊界）。
- `tests/tierB-routing/routes-test.sh`：改成 label 導向斷言（`severity=critical` 才 pager，
  warning/info 進 slack，`Watchdog` 走獨立 receiver）。
- `tests/tierC-live/{alertmanager-live.yml,run.sh,run-e2e.sh}`：live AM 設定同步 routing v2；
  另外兩個 run script 的改動（SC2015/SC2329 shellcheck 修法）是並行程序做的專案級 shellcheck-0
  清理，與本任務邏輯無關但驗證過不影響行為（tierC 三段仍全線 PASS）。
- `next-site/content/ceph/features/prometheus-alert-design.mdx`：`ceph-stability-first` YAML 區塊
  同步；routing YAML 區塊改 v2；相關直述文字（ClientBlocked/ClientRisk 分工、Exporter 拆分、
  `CephExporterAllDown`/`TargetDown` 個別處理段落、邊界段落提到 `CephMetricsAbsent`）同步；新增
  一句指向 `./prometheus-alert-real-lab-findings` 的相對連結（該頁確實存在，非空連結）。
- `next-site/content/ceph/features/prometheus-alert-real-lab-findings.mdx`（新頁）、
  `prometheus-alert-testing.mdx`、`slow-ops-and-bluestore-alerts.mdx`、`feature-map.json`、
  `lib/projects.ts`：非本任務 brief 字面範圍（屬計畫 Task 23），但 `check-rules-match-page.sh`
  已經把 findings 頁納入 invariant 比對的必要輸入（`FATAL: page not found` 若缺）——排除它會讓
  checker 在單獨這個 commit 上不可執行，所以一併收進本 commit 才能保持「這個 commit 自己是可跑、
  可驗證」的狀態。內容我逐頁讀過，證據表格、「驗證狀態」表誠實標注 coverage rule「promtool 已驗
  規則邏輯；真機逐條注入尚待執行」，未過度宣稱；找到並修正了它 YAML 區塊裡同樣的 em-dash 掉字。

## Tier B / Tier C / make validate 結果

- **tierB**：22 passed, 0 failed（pager: critical+source 全數 9 條 custom rule 含 4 條 coverage
  代表樣本；slack: warning/info custom + 全部預設 aggregate；watchdog-ceph；兜底 slack）。
- **tierC**：C1 全 29 條 rule/recording-rule `health=ok`；C2 live routing + silence 8 passed；
  C3 全鏈路 e2e 2 passed。TIER C PASS。
- **make validate**：全 8 項檢查通過（含 Next.js build）。第一次跑時 build 因為另一並行程序同時
  在跑 `npm run build` 造成 `.next` 目錄競態（`ENOENT ... _ssgManifest.js`），重跑後正常，非本次
  變更造成的程式碼問題。
- **shellcheck**：`lib/*.sh run/*.sh tests/tierB-routing/*.sh tests/tierC-live/*.sh` 全數 0 findings
  （含 info 級）。`lib/prometheus-load-check.sh` 有一個 pre-existing 的 SC2329（`cleanup` 只被
  EXIT trap 呼叫，shellcheck 靜態分析看不到）——用 `git show HEAD:...` 確認這個 finding 在我方
  改動之前就存在，不在本次改動的診斷範圍內，予以保留不動。

## Commit 範圍與理由

`git log` 顯示這次工作前沒有任何相關 commit（`987ce00` 是更早的 scenario-framework 工作）。
working tree 除了 Task 3 的檔案外，還混有明顯屬於 Task 4（`experiments/ceph-alert-real-lab/`）、
Task 6（`EVIDENCE-SUMMARY-2026-07-04.md`）、以及另一輪 SP 用同檔名重寫的 Task 1/2 報告檔的
並行修改。這些**沒有**被我 `git add`、commit：

- `experiments/ceph-alert-real-lab/{lib/common.sh,lib/evidence.sh,lib/monitoring.sh,tests/test-monitoring-render.sh}`
- `experiments/ceph-alert-real-lab/EVIDENCE-SUMMARY-2026-07-04.md`（untracked）
- `.superpowers/sdd/task-1-report.md`、`task-2-report.md`
- `linux`（無關的 submodule pointer 髒狀態）

commit `cb7b036 Extend alert rules to production coverage v2` 只包含 Task 3 本體 + 上述「必要配套」
（design 頁三個姊妹頁 + feature-map/projects.ts，因為 checker 對 findings 頁有硬依賴）。

## 自我 review / concerns

1. **DONE_WITH_CONCERNS 的理由**：commit 範圍比 brief 字面清單寬（多了 findings 頁、
   testing/slow-ops 兩頁的同步編輯、feature-map.json、projects.ts）。這是因為
   `check-rules-match-page.sh` 已被（並行程序）擴充成同時要求 findings 頁存在，若不一併收進
   commit，這個 commit 單獨 checkout 出來會直接 FATAL。已逐頁讀過內容確認正確、無捏造。
   如果主導 session 原本打算自己對這些檔案做完整的 Task 23 commit，這裡可能造成語意重複
   （同一批檔案被兩次提交描述成兩種目的）——但因為 `git log` 顯示尚未有任何相關 commit，
   目前不存在重複 commit 的風險，只是未來如果主導 session 也想提交這些檔案，需要注意它們已經
   進了 `cb7b036`。
2. **未涉及的已知後續**：`ceph-production-coverage` 18 條新 rule 只在 promtool/live Prometheus
   層驗證過，尚未逐條真機故障注入（這本來就不在本任務 Step 0 的範圍——brief 只要求驗證 metric
   label 形狀，不要求破壞性注入）；findings 頁的「驗證狀態」表已誠實標注這點。
3. **`lib/prometheus-load-check.sh` 的 pre-existing SC2329**：未修，因為不在本次改動範圍內，
   且 CLAUDE.md 的 shellcheck-0 慣例是否回溯適用到「未觸及」的既有 pre-existing finding，
   判斷上屬於超出本任務授權的清理，未動。
4. **未 push**：依指示只 commit 到本機 master，未 push。
5. **`.superpowers/sdd/task-3-report.md` 檔名沿用了上一輪 SP 的舊報告路徑**（原內容是
   「Evidence Collection Helpers」的報告，已被本檔覆蓋）；舊內容仍完整保留在 git history
   （commit `72dec54` 等），本次只是覆寫 working tree 上的檔案，並未 rewrite history。

## Fix round 1

Code review 後的 3 個文件正確性 finding，修正對象是 commit `cb7b036`（`CephClientBlocked`
擴到四個 name、`CephClientRisk` 排除清單擴到 25 個）之後沒同步更新的 prose。

**驗證真實排除清單長度**：`experiments/ceph-alert-rules/rules/ceph-stability-first.yml` 的
`name!~"..."` 用 Python 對 `|` 切開實際數了一次，**確認是 25 個**（不是 commit message 或舊文件
講的 24 個）。`client-risk.test.yml` 的完整排除清單完整性測試本身也是餵 25 個排除 name + 2 個
非排除 name（第 33–82 行是 25 個排除 series，83–85 行是 2 個非排除），數字驗證與測試資料一致，
只有註解文字寫成舊的 24。

**改了什麼**：

1. `next-site/content/ceph/features/prometheus-alert-testing.mdx`：
   - `CephClientBlocked` 段落的 prose 從「只盯 `PG_AVAILABILITY` / `SLOW_OPS`」改成「盯
     `PG_AVAILABILITY` / `SLOW_OPS` / `OSD_FULL` / `POOL_FULL`」，並在條列下加一條說明測試也驗了
     `OSD_FULL`/`POOL_FULL` 這兩個 v2 新增向量（`client-blocked.test.yml` 裡本來就有這兩組測試，
     只是 prose 沒提到）。
   - 兩處「24 個排除」改成「25 個排除」。
2. `experiments/ceph-alert-rules/tests/tierA-promtool/client-risk.test.yml`：4 處註解裡的
   「24」改成「25」（`name!~ 24 個排除`、`全部 24 個排除 name`、`排除清單擴充到 24 個`、
   `完整排除清單完整性：24 排除`）。**只動註解文字，測試向量、`input_series`、`exp_alerts`
   完全沒碰。**
3. `next-site/content/ceph/features/prometheus-alert-design.mdx`：檢查 `CephClientBlocked` /
   `CephClientRisk` 附近的 prose，發現「分工」條列（原第 163 行附近）已經是四個 name、沒有舊
   「24」計數，這部分不用動。但下面「## 發出 alert 時怎麼處理 → ### CephClientBlocked」的 runbook
   段落還停在「client I/O 已被 `PG_AVAILABILITY` 或 `SLOW_OPS` 影響」，跟同頁上方 YAML（四個 name
   的 regex）矛盾，屬於同一類 finding，一併修：補上 `OSD_FULL` / `POOL_FULL`（容量硬擋），並在
   偵察指令加 `ceph df`、在調查指引加一句 `OSD_FULL`/`POOL_FULL` 的處理方向（擴容量/清資料，硬擋
   不會自己恢復）。

**Gate 結果**：

```
bash experiments/ceph-alert-rules/lib/check-rules-match-page.sh   # PASS，exit 0
make validate                                                      # PASS，exit 0
```

**Commit 範圍**：只加 `git add` 上述 3 個檔案 + 本報告的新增段落（用 `git add -p` 挑出
task-3-report.md 這次新增的 hunk，沒有連帶提交 working tree 上其餘不相干的並行修改，例如
`task-1-report.md`、`task-2-report.md`、`linux` submodule pointer）。未 push。

## Fix round 1（real-lab）：windowed slow-ops

真機故障注入證據（cgroup v2 `io.max` 限速 backing device 製造持續嚴重 slow-ops）發現
`CephDaemonSlowOps` 設計有致命 bug：`ceph_daemon_health_metrics{type="SLOW_OPS"}` 是
snapshot gauge（正在超過 30s complaint-time 的 op 數），TSDB ground truth 顯示單一
daemon（`osd.1`）上 max=30、min=0，**只有 28.8% 的時間 >0**——op 過門檻→被算到→完成→
歸零，slow ops 也會在多顆 daemon 間跳動。舊版 `expr: ceph_daemon_health_metrics{type="SLOW_OPS"} > 0`
+ `for: 3m` 要求同一 daemon 連續 3 分鐘 >0，這種 spiky gauge 幾乎不可能在單一 daemon 上
滿足，所以真故障期間這條規則永遠不會 fire（跟 cluster 級的 `CephClientBlocked{SLOW_OPS}`
不同——那條會正常 fire，只有這條 per-daemon 規則設計有誤）。

**改法**：`expr` 換成 `max_over_time(ceph_daemon_health_metrics{type="SLOW_OPS"}[5m]) > 0`，
`for:` 從 `3m` 降到 `1m`（視窗已經吸收「持續」的語意，`for:1m` 只是防單次 scrape 抖動的
debounce）。`[5m]` 視窗也讓 alert 在最後一次 slow op 之後停留約 5 分鐘，方便 oncall 觀察，
是刻意保留的副作用。

**TDD**：先照新 expr 改寫 `tests/tierA-promtool/coverage-daemon-slow-ops.test.yml`
（新增 spiky firing 向量 `0 0 5 0 3 0 8 0 2 0 0 0 0 0 0 0`，涵蓋 pending 不算 firing、
確切首次 firing 時刻、視窗內即使當下讀數是 0 仍持續 firing、視窗過期後 resolve 四個
斷言點；non-firing 向量恆 0），對「舊 rule」跑 `promtool test rules` 先觀察 RED
（`FAILED` at `time: 3m` 與 `time: 12m`，跟預期一致——舊 rule 對 spiky 資料永遠不會
firing），再改 `rules/ceph-production-coverage.yml` 的 `CephDaemonSlowOps`，重跑轉 GREEN
（`SUCCESS`）。

**驗證過的確切 firing eval_time**：故障於 `t=2m` 開始出現第一個 spike，`t=2m` 仍是
pending（`for:1m` 尚未跨滿），**`t=3m` 正式轉為 firing**（`exp_alerts` 命中）；即使
`t=12m` 當下讀數是 0，仍因 `t=8m` 的 spike 還在 `[5m]` 視窗內而持續 firing；`t=13m`
（`t=8m` + 5 分鐘）視窗過期才 resolve。

**同步更新的另外兩處**（三方一致性）：
1. `lib/check-rules-match-page.sh` 的 invariants 陣列裡，`'ceph_daemon_health_metrics{type="SLOW_OPS"} > 0'`
   改成 `'max_over_time(ceph_daemon_health_metrics{type="SLOW_OPS"}[5m]) > 0'`（`for:` 對照表本來就有
   `CephDaemonSlowOps`，只是數值從 `3m` 變 `1m`，跟著頁面同步即可）。
2. `next-site/content/ceph/features/prometheus-alert-real-lab-findings.mdx` 第 221–223 行的
   `ceph-production-coverage` YAML 區塊（該頁把整組 coverage rule 逐字嵌入當 evidence table 的
   佐證）同步改成新 expr/for，否則會跟 checker 抓到的 invariant 對不上。確認過
   `prometheus-alert-design.mdx` 沒有引用 `CephDaemonSlowOps`（該頁只涵蓋 stability-first +
   scoped，未來的 coverage 專頁才會記錄這條規則的最終形態），不需要改。
   `slow-ops-and-bluestore-alerts.mdx` 裡只有 `CephDaemonSlowOpsScoped`（不同名字、不同 rule），
   不在本次修改範圍。

**Gate 結果**：`tierA.sh` PASS（guard + lint + 全部 promtool 單元測試 SUCCESS）、
`check-rules-match-page.sh` PASS（exit 0）、`tierB.sh` PASS（22 passed, 0 failed，routing
不受影響）、`make validate` PASS（exit 0，8 項檢查含 Next.js build 全過）。

**Commit 範圍**：只 `git add` 這 3 個檔案（rule、tierA 測試、guard script）+
`prometheus-alert-real-lab-findings.mdx` 的同步編輯 + 本報告新增段落，無其他不相干檔案。未 push。
</content>
