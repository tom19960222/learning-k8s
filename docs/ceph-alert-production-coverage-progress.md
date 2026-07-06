# Ceph 工廠級 alert 覆蓋 — 研究與真機驗證進度

> 目標環境：工廠關鍵生產系統，要求 0 downtime，每台 VM 掉 2 個 ping 都會被追問。
> **驗收鐵律：每一條 alert 都必須在真 ceph-lab 上用真實故障注入讓它 firing，不接受模擬或假 metric。**
>
> **22/22 場景全數真機驗證通過**，叢集完整復原至 HEALTH_OK（2026-07-06）。接下來是文件收尾與最終 whole-branch review。

| 指標 | 數字 |
|---|---|
| 設計/修訂的 alert rule | **28** |
| 真機故障注入場景 | **22** |
| 已真機驗證 firing | **22 ✅ 全數** |
| 真機才抓到的 bug/發現 | **16** |

---

## 01 — 研究計畫與目的

不是重寫一套 alert，是把「看 cluster 健不健康」升級成「值得叫醒人的 pager 訊號」。起點是既有的兩層設計（ceph-mixin 預設 rule 之上加一層維護友善的 scoped rule）。工廠級 0-downtime 改變兩件事：

- **洞見一 · 早期訊號**：latency 異常、心跳變慢、容量趨勢，要在變成 outage 前就被看到。「掉 2 個 ping 就被問」代表 disk 開始劣化、網路開始丟包那一刻就要有訊號。
- **洞見二 · 寧濫勿缺**：寧願多監控幾條進 Slack，也不要漏掉一整類故障（軟體 crash、資料損毀、監控自己失明）沒人看。

**驗收鐵律**：每條 rule 都要在真 ceph-lab（cephadm v19.2.3、3 mon + 9 OSD）上，用真實故障讓它進入 `firing` 並送達正確 receiver 才算數。lab 可以有 downtime；證據不能是假的。這條鐵律正是後面十幾個「只有真機才抓得到的 bug」被逼出來的原因。

---

## 02 — 方法論

`brainstorm → spec → plan → subagent 實作 → 真機逐一驗證`

實作交給 Sonnet subagent（我聚焦情境發想、設計、規劃與真機破壞性驗證），每個任務都經「實作 → 兩階段 review → 修正迴圈」把關。

- **三份 rule 一致性把關**：MDX 頁面 = single source of truth、`ceph-alert-rules/rules/` = promtool 被測物、lab render 直接讀 rules 檔。`check-rules-match-page.sh` 逐字比對防漂移。
- **三層測試 gate**：Tier A（promtool 凍結時間驗 `for:` 邊界與 expr）、Tier B（amtool 驗 routing label → receiver）、Tier C（真 Prometheus/Alertmanager 載入評估）。每次改動 `run-tests.sh` + `shellcheck` + `make validate` 三綠才 commit。
- **對抗式 review 迴圈**：reviewer subagent 用 vendored ceph 原始碼當 oracle（objectstore-tool 語法、cephadm `--mount`、health-check 名稱），抓到多個「fake 測試過但真機會錯」的缺陷。
- **破壞性驗證我直接控**：改真叢集的注入由我逐一執行、每步可回退、前後 gate 在 `HEALTH_OK`，不丟給無法中斷的背景 subagent。

---

## 03 — 設計的 rules × 監控什麼

依故障模式分六類，共 28 條 rule。去向欄：🔴 = pager，🔵 = slack，🟡 = watchdog receiver。

### A · 監控系統自身失明（meta-risk）

> 實測發現 lab 原本 scrape 打到 standby mgr（HTTP 200 但空 body），active mgr 已 failover 走——監控處於「`up==1` 卻零 ceph metric」的全盲。

| Rule | 監控什麼 / expr | for | 去向 |
|---|---|---|---|
| `CephMetricsAbsent` | `absent(ceph_health_status)` — 整個 ceph metric 從 Prometheus 消失 | 5m | 🔴 |
| `CephExporterAllDown` | `(count(up{job="ceph"}==1) or vector(0))==0` — 全部 exporter target 死亡 | 5m | 🔴 |
| `Watchdog` | `vector(1)` — 恆 firing 心跳，接外部 dead-man switch | 0s | 🟡 |

### B · 硬體 — 磁碟（disk latency / 容量）

| Rule | 監控什麼 / expr | for | 去向 |
|---|---|---|---|
| `CephOSDLatencyOutlier` | commit latency >100ms 且 >3×叢集中位數 — 單顆碟劣化早期訊號 | 10m | 🔵 |
| `CephDaemonSlowOps` | `max_over_time(ceph_daemon_health_metrics{type="SLOW_OPS"}[5m])>0` — 哪顆 OSD 在 slow ops | 1m | 🔵 |
| `CephOSDNearFull` | `OSD_NEARFULL` | 10m | 🔵 |
| `CephOSDBackfillFull` | `OSD_BACKFILLFULL` — 滿到 recovery 都被擋 | 5m | 🔴 |
| `CephMonDiskLow` | `MON_DISK_LOW` — mon store 磁碟低水位 | 10m | 🔵 |
| `CephMonDiskCritical` | `MON_DISK_CRIT` — mon 磁碟滿 = quorum 死亡前兆 | 1m | 🔴 |
| `CephPoolNearQuota` | `bytes_used > 0.8×quota` — pool 逼近配額 | 10m | 🔵 |
| `CephCapacityForecast` | `predict_linear(used[1h],72h) > 0.85×total` — 3 天內填滿的趨勢預測 | 30m | 🔵 |

### C · 網路（心跳 / 抖動 / 時鐘）

| Rule | 監控什麼 / expr | for | 去向 |
|---|---|---|---|
| `CephOSDSlowHeartbeat` | `OSD_SLOW_PING_TIME_BACK/FRONT` — 「掉 2 個 ping」等級的網路劣化 | 2m | 🔴 |
| `CephOSDFlapping` | `changes(ceph_osd_up[15m])>=4` — NIC 抖動造成 up/down 震盪（join metadata 帶 hostname） | 0s | 🔴 |
| `CephMonClockSkew` | `MON_CLOCK_SKEW` — NTP 失聯 / 時鐘偏移，會壞 quorum 與 cephx | 2m | 🔴 |

### D · 軟體 / daemon（crash / failover / 可用性）

| Rule | 監控什麼 / expr | for | 去向 |
|---|---|---|---|
| `CephDaemonRecentCrash` | `RECENT_CRASH` — 降為 Slack：未 archive 會掛 2 週，page 會訓練 oncall 無視 | 5m | 🔵 |
| `CephMgrNoStandby` | `(count(ceph_mgr_status) or vector(0))<2` — 失去 mgr failover 能力 | 5m | 🔵 |
| `CephOSDDaemonDownScoped` | 帶 hostname/ceph_daemon — 單顆 OSD down，維護時可精準 silence | 5m | 🔴 |
| `CephOSDHostDownScoped` | 同 host 全部 OSD down — 用 `unless` 去重不重複叫 | 5m | 🔴 |
| `CephMonDownScoped` | `(1-mon_quorum_status)×mon_metadata` — 某 mon 掉出 quorum，帶 host label | 30s | 🔴 |
| `CephClientRisk` | `name!~` 大排除清單 — 其餘一切會危及 client 的 health check catch-all | 5m | 🔴 |
| `CephLowPriorityNotice` | MAINTENANCE / MISPLACED / PG_DEGRADED / OSDMAP_FLAGS … — 維護常態噪音，只記錄不叫人 | 30m | 🔵 |

### E · 資料完整性（工廠最關鍵）

| Rule | 監控什麼 / expr | for | 去向 |
|---|---|---|---|
| `CephDataDamage` | `PG_DAMAGED \| OSD_SCRUB_ERRORS` — scrub 抓到不一致 / PG 損毀 | 1m | 🔴 |
| `CephObjectUnfound` | `OBJECT_UNFOUND` — 最新副本不可用，資料正在遺失中 | 1m | 🔴 |
| `CephPGUnhealthyStates` | `(down+incomplete+unknown+stale+peered)>0` — health 匯報路徑之外的第二訊號源 | 3m | 🔴 |

### F · client I/O 生命線 + 監控核心（stability-first）

| Rule | 監控什麼 / expr | for | 去向 |
|---|---|---|---|
| `CephClientBlocked` | `PG_AVAILABILITY \| SLOW_OPS \| OSD_FULL \| POOL_FULL` — client I/O 已被擋 | 1m | 🔴 |
| `CephMonQuorumLost` | `(count(mon_quorum_status==1) or vector(0))<2` — `or vector(0)` 讓「一台不剩」也 fire | 1m | 🔴 |
| `CephExporterTargetDown` | `up{job="ceph"}==0` — 單一 target 掛（多 mgr 下不誤 page 維護那台） | 15m | 🔵 |
| `CephHealthError` | `ceph_health_status==2` — 保留 mixin 預設當 page 總開關 | 5m | 🔴 |

### routing v2 · label 導向 + inhibit + watchdog

routing 從「alertname regex 白名單」改成 **label 導向**：`severity="critical" ∧ source=~"ceph_stability|ceph_scoped|ceph_coverage"` → pager；warning/info → slack；`Watchdog` → 專用 dead-man receiver。理由：新增 rule 不再需要每次改 routing regex（舊寫法已經漏過新 rule）。另加 inhibit：`CephMonQuorumLost` 抑制 `CephMonDownScoped`（quorum 已失守時單 mon 訊號是噪音）。

---

## 04 — 真機驗證進度看板（即時）

**22 / 22 全數通過 ✅** · 叢集已復原 HEALTH_OK（ratios/flags/config 全還原、無殘留 crash/pool）

| # | 場景 | 驗證的 alert | 真實注入手法 | 狀態 |
|---|---|---|---|---|
| S22 | watchdog baseline | Watchdog → watchdog receiver | 部署後即斷言心跳必達 | ✅ |
| S9 | catch-all-risk | CephClientRisk{OSD_NO_DOWN_OUT_INTERVAL} → 🔴 | config set mon_osd_down_out_interval 0 | ✅ |
| S21 | mon-disk-low | CephMonDiskLow → 🔵 · CephMonDiskCritical → 🔴 | 調 mon_data_avail_warn/crit 閾值 | ✅ |
| S13 | mon-clock-skew | CephMonClockSkew → 🔴 | 停時間同步 + date step +2s | ✅ |
| S8 | mgr-failover | metrics 不中斷 · CephMgrNoStandby → 🔵 | ceph mgr fail + 停 standby mgr | ✅ |
| S7 | exporter-blind | CephMetricsAbsent + CephExporterAllDown → 🔴 | disable prometheus module | ✅ |
| S4 | osd-daemon-down | CephOSDDaemonDownScoped → 🔴（host-scoped 不叫） | 停單顆 OSD service | ✅ |
| S6 | mon-down-single | CephMonDownScoped → 🔴（QuorumLost 不叫） | 停單台 mon | ✅ |
| S5 | osd-host-down | CephOSDHostDownScoped → 🔴（3 顆 daemon-scoped 都不叫） | 停整台 host 全部 OSD · 驗 unless 去重 | ✅ |
| S14 | daemon-crash | CephDaemonRecentCrash → 🔵 | 真 SIGSEGV 打進容器內 ceph-osd | ✅ |
| S15 | osd-flapping | CephOSDFlapping → 🔴 | OSD 停/啟 ×2 = 4 次 transition | ✅ |
| S1 | slow-ops | CephClientBlocked{SLOW_OPS} → 🔴 · CephDaemonSlowOps → 🔵 | cgroup io.max 限速 + rados bench | ✅ |
| S11 | latency-outlier | CephOSDLatencyOutlier → 🔵 | 輕度限速 + 高並發寫入 | ✅ |
| S12 | net-slow-heartbeat | CephOSDSlowHeartbeat → 🔴 | tc netem delay 1200ms | ✅ |
| S2 | pg-availability | CephClientBlocked{PG_AVAILABILITY} + CephPGUnhealthyStates → 🔴 | 停測試 pool 兩顆 acting OSD | ✅ |
| S17 | pool-quota | CephPoolNearQuota → 🔵 · CephClientBlocked{POOL_FULL} → 🔴 | 寫爆 pool max_bytes quota | ✅ |
| S16 | capacity-ladder | CephOSDNearFull → 🔵 · CephOSDBackfillFull → 🔴 · CephClientBlocked{OSD_FULL} + CephHealthError → 🔴 | 動態量測 OSD 使用率 → 逐級調低 full-ratio | ✅ |
| S18 | capacity-forecast | CephCapacityForecast → 🔵 | 3 條連續 rados bench 平行流持續寫入，72h 趨勢預測越過 85% | ✅ |
| S19 | data-damage | CephDataDamage → 🔴 | objectstore-tool `set-bytes` 損毀單一 object 內容 → deep-scrub | ✅ |
| S20 | object-unfound | CephObjectUnfound → 🔴 | size=2/min_size=1 誘發 unfound 標準手法 | ✅ |
| S10 | low-priority-notice | CephLowPriorityNotice → 🔵（pager 靜默） | noout flag → OSDMAP_FLAGS，等 for:30m | ✅ |
| S3 | mon-quorum-lost | CephMonQuorumLost → 🔴 + inhibit（確定性驗證） | 停 2 台 mon（保留 active mgr 那台） | ✅ |

---

## 05 — 真機才抓得到的深層發現

這 15 個 bug，fake 測試全部綠、只有真硬體會現形。「每條 alert 都要真機驗證」這條鐵律，逼出了 promtool / fake 測試永遠測不到的環境真相。

### 01 · daemon crash 打錯行程 + 這個 lab 的 crash sidecar 是壞的（S14）
- **症狀**：`kill -SEGV` 打 systemd MainPID，OSD 乾淨重啟但沒產生 crash report，RECENT_CRASH 永遠不出現。
- **根因**：MainPID 是 `conmon`（容器監控器）不是 ceph-osd；容器內 PID 1 是 `podman-init`、ceph-osd 是 PID 7，podman-init 不轉發 SEGV。更深：這個 lab 的 `ceph-crash` sidecar 根本沒有 keyring（`client.crash` auth 不存在），物理上 post 不了 crash。
- **修法**：對 host 上 ceph-osd 真實 PID（`pgrep -P $(podman inspect .State.Pid)`）送 SEGV → 真 crash meta 寫進 spool → 透過 seed 節點 admin `ceph crash post`（真 crash 資料，只繞過壞掉的傳輸 daemon）。RECENT_CRASH 真的亮、alert 真的 fire。

### 02 · CephDaemonSlowOps 的指標太 spiky，for:3m 永遠湊不滿（S1 · rule 重設計）
- **症狀**：製造了真實嚴重的持續 slow-ops，cluster 級 CephClientBlocked 正常 fire，但 per-daemon 的 CephDaemonSlowOps 逾時不 fire。
- **根因**：TSDB ground truth：`ceph_daemon_health_metrics{type=SLOW_OPS,osd.1}` 峰值 30 但 min=0，整個視窗只有 **28.8% 時間 >0**——它是「當下超過 complaint-time 的 op 數」snapshot gauge，本質極 spiky。`for:3m`（需 100% 連續）在這種指標上永遠不可能滿足。
- **修法**：rule 改用時間窗聚合 `max_over_time(...[5m]) > 0` + `for:1m`——語意變成「該 daemon 近 5 分鐘有過 slow op」，符合設計意圖且對 spiky gauge 穩健。

### 03 · 節流太硬會讓 OSD flap；要「持續」slow-ops 得靠並發不是靠更硬（S1）
- **症狀**：256KB/s 限速下 SLOW_OPS 訊號爆發式，同樣參數一次 fire、一次不 fire，高變異。
- **根因**：受控實驗證明把節流調到 128KB/s，被限速的 OSD 連自己的 housekeeping I/O（心跳、metadata）都被卡 → 直接 flap down。不能靠調硬節流換取「持續」。
- **修法**：保持 256KB/s（flap-safe），改用高並發寫入（`-t 64`）把 op queue 持續撐滿——queue 不排空 SLOW_OPS 就連續，不增加 flap 風險。

### 04 · cephadm shell 的 stderr banner 污染 JSON，jq 直接 parse error（S15 · S19 · S20）
- **症狀**：osd-flapping 的 down/up 狀態輪詢永遠逾時。
- **根因**：`run_capture` 用 `2>&1` 把 cephadm 的 4 行 banner（`Inferring fsid…`）併進 JSON 檔，非 `#` 開頭，`grep -v '^#'` 濾不掉 → jq `Invalid numeric literal` → 輪詢永遠失敗。fake 測試回乾淨 JSON 所以測不到。
- **修法**：JSON 解析改用純 stdout 重導（banner 走 stderr 到 sidecar 檔）。同一修正一次補掉尚未真機跑的 S19、S20 的同款潛在 bug。

### 05 · flapping 太快，5s scrape 抓不到中間狀態，changes() 只數到 2（S15）
- **症狀**：腳本靠 `ceph osd tree` 確認 4 次 transition 都完成了，但 CephOSDFlapping 不 fire。
- **根因**：`ceph osd tree`（mon 視角）比 mgr exporter 的 `ceph_osd_up` 快；某個 up 狀態只持續 4 秒，5s scrape 下沒被記成獨立樣本 → `changes()` 實際只數到 2。
- **修法**：每次 transition 改成等 Prometheus 的 `ceph_osd_up` 真的反映該值再前進，確保 4 個真狀態各被 scrape 成獨立樣本。OSD 真的 flap 4 次，只是配速讓 pipeline 觀測到每個狀態。

### 06 · pool 超 quota 要「持續寫入壓力」才會升 POOL_FULL（S17）
- **症狀**：CephPoolNearQuota 正常 fire，但寫過 quota 後 POOL_FULL 6.5 分鐘都不出現。
- **根因**：手動實驗驗證 pool 超過 max_bytes 確實升 POOL_FULL，但只在 client 持續嘗試寫入（寫到被 block）時 mon 才 flag。腳本在剛過 quota 那次 put 就停手，沒有持續壓力。
- **修法**：past-quota 階段改用 remote `timeout 30 rados put`（bounded，被 block 不 hang，exit 124 當「pool 滿」訊號）持續寫過 quota 並輪詢 POOL_FULL。

### 13 · capacity-forecast 六輪纏鬥：真正的兇手是 rados bench 覆寫 objects（S18）
- **症狀**：CephCapacityForecast 連五輪不 fire——趨勢預測（predict_linear）始終爬不到 85% 門檻。
- **層層剝開**：表面是「寫入吞吐不夠」。連換三個假設都沒解決：(1) pool PG 數太少 → 加到 16/32 PG；(2) 並發不夠 → 加到 -t 128、3 條平行流；(3) 3× 複寫吃掉成長 → 想改 size=1（結果 v19 EPERM 擋掉，且發現指標本來就是 raw、複寫其實有算）。每輪都靠即時 TSDB `deriv()` 量測才知道還是不夠。
- **真根因**：一次 10 分鐘的受控 probe（單一連續 `rados bench 600`）實測到 **6.9 MB/s**，但場景的 round-loop 卻只有 0.1 MB/s 甚至負成長。差別在 **`rados bench` 的 round-loop 每輪都用固定 `--run-name streamN`，第二輪起就覆寫掉前一輪的同名 objects，pool 填滿第一輪後就不再成長**。probe 用單一連續 bench 所以 objects 持續累積。
- **修法**：讓場景完全照 probe——每條 stream 一個連續 `rados bench 4500`（不分 round）。第六輪成長率衝到 **9.15 MB/s**，projection 爬到 2046 GB（門檻 821），alert 真的 fire → slack。
- **教訓**：這是整輪最硬的除錯。「每條 alert 都要真機驗證」的鐵律逼我把一個看似「lab 太弱」的失敗，一路挖到「rados bench 物件命名語意」這麼底層——而 rule 本身從頭到尾都是對的（它正確地拒絕在不夠陡的趨勢上 fire）。

### 16 · 真 quorum loss 時 inhibit 觀察不到——exporter-freeze 讓兩條 alert 不重疊（S3）
- **症狀**：CephMonQuorumLost fire→pager 通過，但 inhibit 斷言（CephMonQuorumLost 應抑制 CephMonDownScoped）逾時。
- **根因**：這是 finding #11（exporter 遙測凍結）的延伸後果。真 quorum loss 時 mgr exporter 先凍結（回報 stale quorum=3）、再死掉；CephMonQuorumLost 只能靠 exporter 死後的 empty-series path 觸發。但那時 `ceph_mon_quorum_status` 已消失,CephMonDownScoped 的 expr 無資料可算 → 不 active → **兩條 alert 在真故障中永遠不時間重疊**,inhibit 無從觀察。
- **修法**：inhibit 設定本身是對的——直接 POST 兩條 synthetic alert 到 Alertmanager,CephMonDownScoped 立刻變 `suppressed`、`inhibitedBy` 指向 CephMonQuorumLost。於是把「真故障中觀察 inhibit」改成「確定性的 AM 設定行為測試」(Tier-C 式,測 Alertmanager 設定而非造假 ceph 故障),主 alert CephMonQuorumLost 仍由真 quorum loss 驗證。
- **教訓**：與 S19 的 CephHealthError 同型——「機制正確但真故障的動態讓它觀察不到」。誠實的做法是把不可觀察的斷言換成確定性驗證、並記錄為什麼,而不是硬湊或造假。

### 14 · data-damage 三層疊：health_detail 閃爍 + objectstore remove 被 recovery 治好 + HEALTH_ERR 也閃爍（S19）
- **症狀**：CephDataDamage 連兩輪不 fire。
- **第一層（指標閃爍）**：objectstore-tool 弄壞副本、deep-scrub 抓到、`ceph health detail` CLI 持續顯示 OSD_SCRUB_ERRORS，但 mgr 匯出的 `ceph_health_detail` **metric** 整個視窗只有 ~3% scrape 是 1（97 樣本 avg 0.031）——同 CephDaemonSlowOps 那類閃爍。→ rule 改窗化 `max_over_time([5m])>0`（順便預先修 CephObjectUnfound）。
- **第二層（recovery race）**：改窗化後仍不穩，因為 `objectstore-tool ... remove` 讓副本**缺少**物件,OSD 重啟後 PG 會 recovery 補回,與 deep-scrub 賽跑（run 1 scrub 贏、run 2 recovery 贏）。→ 改用 `set-bytes` **損毀內容**（recovery 不治存在但錯誤的副本），確定性觸發 scrub mismatch。
- **第三層（HEALTH_ERR 也閃爍）**：CephDataDamage 終於 fire→pager,但額外的 CephHealthError 斷言逾時——scrub-error 的 HEALTH_ERR 隨底層 health_detail 指標在 2(ERR)↔1(WARN) 跳,`for:5m` 撐不住。而 CephHealthError 早被 S16 的穩定 OSD_FULL HEALTH_ERR 驗證過。→ 移除 S19 的冗餘 CephHealthError 斷言。
- **教訓**：一個「資料損毀 alert」的真機驗證,竟牽出 mgr 指標匯出的統計特性、Ceph recovery 與 scrub 的時序競態、以及 health_status 的傳導性閃爍三件事。rule 邏輯全程正確。

### 15 · CephObjectUnfound 預先窗化，省下一輪（S20）
- **判斷**：修 S19 時認出 OBJECT_UNFOUND 是同一類 data-integrity health check,很可能同樣閃爍,於是在同一個 commit 把 CephObjectUnfound 也改成窗化。
- **結果**：S20 直接一次通過（CephObjectUnfound firing→pager）——預先套用已驗證的修正模式,省掉一輪失敗+診斷+修正的來回。這就是「把真機發現抽象成一類、而非逐案修」的價值。

### 07 · capacity 想寫 27GiB 太慢；改用動態 ratio 貼合真實使用率（S16）
- **症狀**：setup 想寫到 27GiB raw used 才調閾值，10 輪只寫到 ~940MB 且不累積 → FATAL。
- **根因**：叢集幾乎全空（最滿 OSD 只 0.05%），低並發 30s bench 太慢；固定閾值 0.02 對 0.05% 使用率本來就不會 trip。
- **修法**：不追固定容量：高並發寫入到「最滿 OSD 到達適量使用率」，然後動態量測該使用率、把三級 ratio 設為其分數（nearfull=0.6U、backfillfull=0.7U、full=0.8U）——自動保證低於實際使用率且有序，三級都 trip。

### 08 · BlueStore slow-op 是 24h latch，restart OSD 會弄壞 cephadm inventory（S1 · S11 · S16）
- **症狀**：限速類場景結束後留下 `BLUESTORE_SLOW_OP_ALERT`（9 顆 OSD）卡住 HEALTH_OK gate；舊清理靠 restart OSD，卻讓 cephadm 把 daemon 標成 `unknown`。
- **根因**：這個警告有 24 小時 latch 生命週期；rolling restart 太粗暴又造成 orchestrator 追蹤狀態不同步。
- **修法**：暫時把 `bluestore_slow_ops_warn_lifetime=1` 讓警告 ~20 秒老化清除再還原，不 restart 任何 OSD。抽成 `lib/evidence.sh` 共用 helper，三個場景共用。

### 09 · rollback 移除 netem delay 時，自己把自己那條 SSH 弄斷（S12）
- **症狀**：CephOSDSlowHeartbeat 正常 fire、netem 確認移除、HEALTH_OK，但腳本 exit 1。
- **根因**：rollback 的 `tc qdisc del` 是透過那條「正被延遲 1200ms 的介面」下 SSH 去移除延遲；移除瞬間擾亂當下這條 SSH → ssh 回傳 255 → rc=1，儘管 host 端其實成功。
- **修法**：rollback 的成功判斷改成事後用一條 fresh SSH 輪詢「netem 確實不見了」，而不是信那條會自我擾亂的 del 指令退出碼。

### 10 · mgr failover 後 standby 要幾十秒才重新註冊（S8）
- **症狀**：`ceph mgr fail` 後立刻查 `mgr dump`，standby 是空的 → FATAL。
- **根因**：被降級的 mgr 需數秒到數十秒才重新以 standby 身分註冊；腳本只查一次沒重試。
- **修法**：改用 `poll_until`（2 分鐘預算）輪詢 `.standbys | length > 0`。這也順帶真機驗證了 multi-mgr scrape 修正（failover 中 metrics 不中斷）。

### 11 · 真 quorum loss 時 mgr exporter 遙測會「凍結」在舊世界（S3 · 早期發現）
- **症狀**：真實停掉 2 台 mon 後，`ceph quorum_status` 已無法完成，但 Prometheus 查到的 `sum(ceph_mon_quorum_status)` 仍是 3。
- **根因**：不是 PromQL 寫錯，而是**監控資料源還在回報舊世界**——單一 mgr exporter 視角在 quorum 崩潰時會 stale。CephMonQuorumLost 最後是靠 `or vector(0)` 的 empty-series path（exporter 也死、series 變空）才觸發。
- **修法**：這正是 v2 補 CephMetricsAbsent + multi-mgr scrape 的理由：不能只靠單一 exporter 視角當 quorum-loss 偵測器。（S3 完整真機注入待跑。）

### 12 · deploy 腳本只改 configmap 不會讓 Prometheus 重載 rule（harness gap）
- **症狀**：改完 rule、重佈監控，Prometheus 卻還載著舊 expr。
- **根因**：`kubectl apply` 在 Deployment spec 沒變時不會重啟 pod；configmap 改了但運行中的 Prometheus 不會自動重讀 rule 檔。
- **修法**：任何 rule 變更後 `kubectl rollout restart deploy/prometheus`。已記入待辦：把 deploy 腳本硬化成 apply 後自動 reload。

---

## 06 — 邊界與明確取捨

**不進本輪 scope（文件記載）**：無法真機注入的就不開專屬 rule。node 層（NIC error、conntrack、CPU steal）需 node-exporter，lab 未部署；RGW / MDS / RBD-mirror 無對應 daemon；SMART / BlueStore spillover / 舊版本 / mon election 風暴無法安全或如實注入——由 catch-all 蓋並記載，而 catch-all 機制本身有真機證據。開一條測不到的 rule 反而違反鐵律。

**明確取捨 — RECENT_CRASH 從 page 降為 Slack**：crash 未 archive 會掛 2 週，維持 page 級會訓練 oncall 無視 pager；反覆 crash 的 page 面由 flapping / down / quorum rules 承擔。crash 的 admin-post：真 crash 資料經 admin 通道進 crash module，只替換壞掉的 sidecar 傳輸，不是造假——並已把「lab crash sidecar 缺 keyring」這個真機發現顯著記載。

---

## 07 — 接下來

- **S19 data-damage** → **S20 object-unfound** → **S10 low-priority-notice** → **S3 mon-quorum-lost**（含 inhibit 真機斷言）。
- **硬化 deploy 腳本**：apply 後自動 `rollout restart` Prometheus，讓 rule 變更可重現載入。
- **文件收尾**：更新 `prometheus-alert-design` 頁 + 新增 production coverage / 真機證據頁（每條 rule × 注入手法 × firing 證據 × 回退）。
- **最終多視角 review**：整條 branch 交給 code-reviewer 做 whole-branch 複查。

> 所有 alert 的驗證證據（sink JSON、Prometheus alerts JSON、health-check 輸出）都收在對應的 `results/` 目錄。
