# Task 3 報告：`slow-ops-detection-mechanisms`（mechanism 頁）

> 注意：本檔覆蓋了上一輪 SP（alert rules v2）留下的同名舊報告；舊內容在 git history 內仍可查。

## 產出

- 新檔：`next-site/content/ceph/features/slow-ops-detection-mechanisms.mdx`
- 改檔：`next-site/lib/projects.ts`（ceph `features` 陣列尾端 append `'slow-ops-detection-mechanisms'`，只動這個陣列，group 留 Task 15）

## 文章結構與每節來源

| 節 | 內容 | 主要來源 |
|---|---|---|
| 本頁定位 | 文章類型/版本錨點(c92aebb)/可獨立閱讀/T1+T3/取代宣告(含 archive) | 開頭契約 |
| 場景 | log_latency slow op 但 SLOW_OPS 不亮 + 三路徑總綱表 | 舊頁場景改寫 + 報告總綱 |
| 路徑一：兩個 SLOW_OPS metric 來源鏈 | OpTracker→DaemonHealthMetric→mgr 累加→prometheus 解析 summary/per-daemon dump | 舊頁上半（查證正確，改寫沿用）+ T1 逐錨點 |
| 路徑二＆三：BLUESTORE_SLOW_OP_ALERT 與 4 counter | log_latency 一條路做三件事（log/_add_slow_op_event/idx2 counter）；latch 型 alert；device-local counter | 舊頁機制段 + REPORT §緣起(三件事) + T1 counter 定義 |
| 三層盲區 | 暫態(H-001/E-01)、持續 sub-30s(H-024/E-04v2)、採樣漏失(H-023/44.7s) | REPORT「三層盲區」+ HYPOTHESES H-001/023/024（T3） |
| 定位陷阱 | H-025 SLOW_OPS 怪錯人（卡 osd.0 亮 osd.4/6/7/8）；counter=元兇 vs SLOW_OPS=受害者 | HYPOTHESES H-025（T3） |
| 訊號邊界表 | H-011 完成才記帳、H-014 omap/scrub 盲區、H-017 idle 盲區、H-019 Squid vs Reef 版本；+H-015 FP 預期 | HYPOTHESES H-011/014/017/019/015 |
| 一句話關於規則 | 指向 ./slow-ops-fast-detection-lab（含真機延遲 +14/+20/+45~60 vs ~120） | REPORT 偵測延遲表 |
| 相關閱讀 | slow-ops-fast-detection-lab / pg-health-states / bluestore-deep-dive | brief 指定 |

**刻意不沿用舊頁下半**：三層 alert 架構、`CephBluestoreSlowOps`/`CephDaemonSlowOpsScoped`/`CephOSDOpLatencyHigh` 規則、`osd_op_complaint_time` 調法——皆被 findings_slowops.json 標「已推翻」，規則屬 Task 4。本頁只留「一句話」指過去。

## log_latency 重數結果（Step 2）

- 口徑：`grep -cE 'log_latency(_fn)?\(' BlueStore.cc` = **33**
- 扣除 2 個函式定義本身（line 18465 `void BlueStore::log_latency(`、18487 `void BlueStore::log_latency_fn(`）= **31 個呼叫點**
- 拆分：`log_latency(` 24 + `log_latency_fn(` 9 = 33（含定義）
- 帶 idx2（會 inc slow counter）的呼叫點 = **5**（12368/12708/13080=read_onode_meta、12751/13113=read_wait_aio、14471=committed_kv）+ **1 個直接 inc**（14175=aio_wait，不經 log_latency）
- 其餘 **26** 個呼叫點只打 log + `_add_slow_op_event()`、不 inc counter
- **與既有數字差異**：舊頁「22 處」（低估）、研究 H-014「29 個呼叫點」（也低估）；文章以我親數的 31 為準並寫明口徑。

## 驗過的 file:line 清單（全部對 c92aebb / v19.2.3 主 checkout 開檔驗證）

SLOW_OPS 路徑：
- `OSD.cc:2406` set_complaint_and_threshold(osd_op_complaint_time, ...)
- `OSD.cc:7825` get_health_metrics()；`7831-7832` too_old -= osd_op_complaint_time；`7844` count_slow_ops lambda；`7906` emplace SLOW_OPS,slow,oldest；`7909` else 0,0
- `OSD.cc:6460` mgrc.update_daemon_health(get_health_metrics())
- `OSD.cc:1024-1025` osd_stat.os_alerts clear/swap
- `Monitor.cc:5985` MON 端 emplace SLOW_OPS
- `TrackedOp.cc:342-344` visit loop skip continuous/warn_interval_multiplier==0；`364` oldest_secs<complaint_time return false
- `global.yaml.in:3130` osd_op_complaint_time default 30
- `mon.yaml.in:1139` mon_op_complaint_time default 30
- `DaemonServer.cc:2741` accumulated map loop osd+mon
- `DaemonHealthMetricCollector.cc:20` _update(n1+=,n2=max)；`37` 「format used in mgr/prometheus」註解；`50` summary fmt::format
- `module.py:885` _get_value；`908`+`913-916` SLOW_OPS parse；`918-924` err→del；`929` inactive→0；`1630`+`1635-1636` get_all_daemon_health_metrics
- `ActivePyModules.cc:1473`+`1475` dump_int value=n1（只 n1、無 n2）

BlueStore／counter 路徑：
- `BlueStore.cc:18465` log_latency def；`18473` tinc；`18476` dout slow op；`18480` _add_slow_op_event；`18481-18483` idx2 inc；`18487` log_latency_fn def
- `BlueStore.cc:18455` _add_slow_op_event def；`18456` threshold==0 disables；`18444` _trim_slow_op_event_queue(lifetime/threshold)
- `BlueStore.cc:18901-18907` _log_alerts BLUESTORE_SLOW_OP_ALERT
- `global.yaml.in:5447` bluestore_slow_ops_warn_lifetime default 86400 +「not the same as osd_op_complaint_time」；`5456` threshold default 1
- `BlueStore.cc:6456-6475` 4 slow counter def（全 PRIO_USEFUL）
- `BlueStore.cc:14471` committed_kv idx2；`12751`/`13113` read_wait_aio idx2；`12368`/`12708`/`13080`(idx2@12372/12712/13084) read_onode_meta；`14175` slow_aio_wait_count 直接 inc
- `BlueStore.cc:6217` txc_commit_lat(PRIO_CRITICAL)；`6252` kv_sync_lat
- `PGMap.cc:3237-3238` BLUESTORE_SLOW_OP_ALERT summary；`3239-3244` stalled read alerts；`3247-3249` checks->add + detail
- `exporter/util.cc:54` promethize
- `osd_perf_counters.cc:48-51` op_latency(l_osd_op_lat, prio 9)

版本錨點：`git -C ceph rev-parse --short HEAD` = `c92aebb`、`git describe --tags` = `v19.2.3`。

## Self-review findings

- **frontmatter 契約**：layout: doc / title: Ceph — … / description / category: mechanism 全備；title/description 無冒號（gray-matter 安全）。
- **開頭契約**：本頁定位含全部 5 元素（類型/版本錨點 c92aebb/可獨立閱讀/T1+T3 原則/取代宣告含 archive）。
- **相關閱讀**：只在文末，連 3 個指定 slug。in-body 唯一外連是「一句話關於規則」指向實驗頁——符合 brief「規則建議留一句話指向實驗頁」。
- **MDX 安全**：prose 角括號全 `&lt;`/`&gt;` escape；掃描後只剩 3 組 `<Callout>` JSX tag（合法、全域註冊、未 import）。無 Mermaid、無元件 import、無 MDX 內測驗題。
- **語言**：mainland-term 掃描 0 命中；never-translate（node/cluster/alert/daemon/counter/gauge/latch/Pod/OSD…）保留英文；程式碼註解維持英文（源碼原文）。
- **T1/T3 標示**：機制結論標 T1，盲區/定位/邊界結論標 T3（H-019 標 T2）。
- **證據誠實度**：counter「ceph-exporter 預設匯出」以 T3（lab :9926 實見）陳述、PRIO_USEFUL 以 T1 陳述——未捏造未開檔的 exporter config 行號。

## Concerns

1. **前向連結 `./slow-ops-fast-detection-lab` 目前不存在**（Task 4 才建，同批會補）。`make validate` 的 slug↔MDX 檢查針對 `projects.ts` features 陣列（該 lab slug 尚未加入，Task 4 負責），不解析 MDX 內部連結目標存在性，故本頁不會被 validate 因這條連結擋下。
2. **呼叫點數字 31 vs 研究 29 vs 舊頁 22**：我實數 31（口徑寫明）。研究的 29 未含全部 `c->store->log_latency` 呼叫，屬低估；文章以實數為準。若 reviewer 要求對齊研究數字，應以本頁實數為準。
3. 未跑 `make validate`（依指示由 orchestrator 統一跑）；未跑 review gate（Step 5 由 orchestrator dispatch）。

## Fix round 1（reviewer Important：idx2 呼叫點計數 5→6）

**Finding**：文章表格本身列了 6 個帶 idx2 的 log_latency 呼叫點（14471；12751/13113；12368/12708/13080），但兩句 prose 寫「5 個帶 idx2」「其餘 26 個」——內部不自洽。對 source 重驗：6 個 idx2 呼叫點全部傳合法 `l_bluestore_slow_*_count`（idx2 實參位置 12372/12712/13084/12756/13118/14479），31 − 6 = 25 log-only。錯誤源頭是研究文件 H-014（列 6 個行號卻寫「僅 5 處」），我照抄時未重數 idx2 子集。

**修正**：
1. `slow-ops-detection-mechanisms.mdx` 兩處：「5 個帶 idx2」→「6 個帶 idx2」（line 399）；「5+1 個呼叫點…僅 5 個，其餘 26 個」→「6+1…僅 6 個，其餘 25 個」（line 464 邊界表）。grep 全文確認無殘留（`5 個帶|5\+1|其餘 26|僅 5` 零命中）。
2. **Back-port** `experiments/ceph-slow-ops-detection/HYPOTHESES.md` H-014：Evidence 原句（日期化）不改，其下加 blockquote 更正註記——總數 31（此前 29 低估）、idx2 6 處（此前誤記 5）、log-only 25 處、direct-inc 1 處不變、結論不受影響。
3. grep `REPORT-2026-07-09.md` 與 `rules/` 的「5+1／僅 5／5 處」：**零命中**，無需加註。

**修正後口徑（最終版）**：31 個 log_latency/log_latency_fn 呼叫點（grep 33 − 2 函式定義）＝ 6 帶 idx2 + 25 log-only；另有 1 個 direct inc（14175，不經 log_latency 計數）。文章、H-014 註記、本報告三處一致。

Minor 兩項（前向連結、cosmetic 措辭）依 coordinator 指示不動。
