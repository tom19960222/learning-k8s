# Ceph 生產 cluster — 時鐘同步監控（採集 script + alert 規則）總結報告

> 研究主題：驗證並重建「NTP 時間同步的採集 script 與 Prometheus alert 規則」，
> 使極高敏感（掉 2 個 ping 都要叫）的生產 Ceph cluster 能在第一時間偵測時鐘異常。
> 2026-07-23 完成（規劃與離線判決先行，實機一日執行）。
> 規劃 13 個實驗（E-00~E-11 + E-05a）：10 獨立執行（E-00/E-01/E-02/E-05a/E-05/
> E-06/E-07/E-08/E-09/E-10）+ 2 併入其他實驗（E-03/E-04）+ 1 裁定不做（E-11）；
> 另有 2 個計畫外追加（首小時檢核、H-033 純形式測試 — 對抗 review 與假說 backlog 衍生）。
> 原始證據：`EVIDENCE-LOG.md`（實機時間軸）、`HYPOTHESES.md`（39 條假說，21 條 confirmed）、
> `tests/`（69 個可重跑的機器判決）。
> 版本錨點：systemd v249.11（實機）/v260.1（source 對照）、Ceph 19.2.5（實機 cephadm）
> /v19.2.3（source 對照）、node_exporter v1.7.0（實機）/v1.11.1（source 對照）、
> Prometheus 2.51（實機 cephadm 版）、promtool 3.12。

## 0. 這份報告怎麼讀

- §1 前提與環境；§2 全部實驗的規劃/結果總覽表；§3–§6 逐實驗詳情（固定五欄）；
- **趕時間：看 §2 總覽表 + §7 參數建議總表 + §8 總結**。
- 術語 primer（讀者可能缺的三組概念）：
  - **textfile collector**：node_exporter 讀一個目錄下的 `.prom` 檔、把內容當 metrics
    輸出。我們的採集 script 定期把 `timedatectl` 的資訊寫成 `.prom` 檔。關鍵特性：
    **檔案不更新時，metrics 不會消失** — node_exporter 每次被抓取都重讀舊檔，值凍結但
    時間戳永遠新鮮。
  - **timesyncd 的 offset 快照**：`timedatectl timesync-status` 顯示的 Offset 是
    「上一次 NTP 對時當下量到的偏差」，兩次對時之間凍結不動；生產設定
    `PollIntervalMaxSec=256` 下最多過時 4.3 分鐘。它不是「現在時鐘差多少」。
  - **kernel timex**：Linux kernel 內部的時鐘紀律狀態（`adjtimex` 系統呼叫可讀），
    含 `offset`（PLL 尚未修完的量，不是絕對誤差）、`maxerror`（誤差上界，失聯時每秒
    +500µs）、`STA_UNSYNC` 旗標。`timedatectl` 的 `NTPSynchronized` 其實就是
    「maxerror < 16 秒」。
- 本報告的分層與代號約定：
  - **L1 / L2 / 實機**：L1 = 本機離線判決（fake timedatectl、promtool 合成
    series）；L2 = 單機真實環境段（如 E-01 的真機格式對照）；其餘皆 Azure lab 實機。
  - **車道（lane）**：一組共用同一訊號來源的規則。v2 共 8 條：A 跨 node spread、
    B 單 node 絕對 offset、C kernel 修正快車道（timex）、D 上游失聯（age + 同步旗）、
    E kernel 誤差上界（maxerror）、F daemon 掙扎（poll 縮短）、G 跨信任域 Drift、
    H 觀測鏈自保（heartbeat / 壞檔 / 缺席 / exporter down）。共 17 條規則。
- 時間皆 UTC；效果量一律「前值→後值（倍率或差值）」。

## 1. 前提

**要回答的問題**（依優先序）：
1. 現行 script + 3 條 alert 規則，能不能在時鐘異常時第一時間叫？盲區在哪？
2. false positive 在哪？（極高敏感環境，誤報等同狼來了）
3. 重建後的方案，偵測延遲的確定性上界是多少？哪些故障型態各由哪條規則負責？

**判定標準**（實驗前定案）：
- 每個實驗 prediction 先寫死、機器或時間軸比對，被推翻的 prediction 是最高價值輸出；
- 門檻對齊 Ceph 常數：`mon_clock_drift_allowed=0.05s`（mon 間 50ms 即 HEALTH_WARN）、
  `mon_timecheck_interval=300s`（Ceph 自身偵測週期）；
- 零 FP 基線：生產參數健康態下新規則必須全綠（promtool 斷言 + 實機 soak）。

**受測物與環境**：
- 生產設定：systemd-timesyncd、`PollIntervalMaxSec` 將調 256s（皆使用者確認）。
- 實機：Azure lab 9 台（3 K8s + 3 Ceph mon + 3 OSD；Ubuntu 22.04 / systemd 249.11 /
  kernel 6.8.0-1062-azure；cephadm Ceph 19.2.5，9 OSD / 3 mon quorum）。
- 受測舊方案：採集 script 輸出 3 個 metric（offset/synchronized/packet_count）+
  3 條 alert 規則（內含 7 個條件、引用 9 個 metric 名）— 規格落差即第一個線索。
- 監控鏈（lab 原本沒有，E-00 後以 `ceph orch` 自佈）：node-exporter×6 +
  Prometheus/Alertmanager（scrape/eval 10s）。
- **信任域切分**（共模偵測的前提架構）：5 台受測節點 + 1 台 L2 節點走
  timesyncd→lab 內 NTP server（k8s-0）；Prometheus host（osd-2）與 NTP server 本身
  保持 chrony→Azure PHC — Drift 規則的兩端屬不同時鐘來源。
- 注入工具：`clock_inject.py`（adjtimex 注入 + capture/restore）、可控 skew 的
  fake NTP server、iptables（只動 OUTPUT udp/123）。

**結論可信度防線**：
- 離線判決先行：PromQL 語意用 promtool 合成 series 窮舉（25 組）、parser 用
  fake timedatectl 判決（39 + 5 個 case），實機只驗證離線推不出的部分；
- 雜訊帶先量再定門檻：Drift 訊號實測雜訊 +2.5~5.0ms → 門檻取 10 倍裕度；
- 每次注入走 inject→observe→collect→rollback→assert，回退後驗證 `HEALTH_OK`；
- 兩輪跨模型對抗 review（36 條 findings 全數處理，載重項逐條對 pinned source 抽查）。

**移植性標記**：〔機制〕= 跟版本/環境無關的行為；〔數值〕= 本環境量出的數字，
換環境要重量（例：雜訊帶、Ceph timecheck 相位）。

## 2. 實驗規劃總覽（規劃 13 個）

### 2.1 離線判決（不需機器）

| 編號 | 調整的參數/注入 | 為什麼 | 預期 | 結果 |
|---|---|---|---|---|
| E-05a | promtool 合成 series：舊規則 7 條件 × 11 情境 | PromQL 語意決定性，不必燒機器 | 死分支 6/7、對稱 skew 盲、poll 反向永久 FP、or-on() 身分互踩 | ✅ 11/11 全中 |
| E-01(L1) | fake timedatectl：offset 字串 11 種格式 | parser 是否在災難時刻說謊 | `+1min 2s`→1.0s、`n/a`→0.0 | ✅ 11/11 全中 |

### 2.2 實機：採集面

| 編號 | 調整的參數/注入 | 為什麼 | 預期 | 結果 |
|---|---|---|---|---|
| E-00 | 無（9 台唯讀盤點）| 校正全部前提 | timesyncd + timex 可用 | ❌ **推翻**：全 lab chrony→PHC 共模；cephadm 無監控堆疊；timex collector 被 cephadm 停用且救不回（詳 §3.1）|
| 首小時（計畫外追加）| v2 collector 部署 + timer 停擺演練 + 雜訊量測 | L1 綠燈驗不到的真實世界 | 逐項見 §3.2 | ✅ 全中（timer 死亡僅 heartbeat 洩底的機制獲實機首證）|
| E-02 | 獨立壞 `.prom`（無值行）| 拒收 granularity 決定歸因設計 | 整檔滅、target 級 scrape_error | ✅ per-file 語意實錘 |

### 2.3 實機：故障注入與規則判決

| 編號 | 調整的參數/注入 | 為什麼 | 預期 | 結果 |
|---|---|---|---|---|
| E-05 | 健康態 24h 級觀測 + 斷 NTP 25min（osd-0）| 舊規則的 FP 與失聯曲線 | 健康態 FP；age 線性、sync 旗不動 | ✅ 全中 + or-on() 四重誤報/假 resolve 實錄（超出預期的嚴重度）|
| E-06 | 全 fleet（含 3 mon）共模 +300s | 共模是否只有跨信任域訊號看得見 | 只有 Drift 車道 fire；Ceph 無感 | ✅ firing 級證明；HEALTH_OK 全程零 election |
| E-07 | 斷 NTP + step +100ms（持續）；回退量自癒 | 偵測接力時序 + snapshot/timex 語意 | Unsync 8.9h 盲、失聯 age 13min 是唯一快訊號 | ❌ **推翻**：Unsync 3min 就翻（kernel ntp_clear）→ 實測接力 3/6/13min（詳 §5.2）|
| E-09(a) | 單 mon 錯誤 upstream +100ms（現行門檻）| 與 MON_CLOCK_SKEW 賽跑 | v2 全盲、Ceph 贏 | ✅ 如預測輸掉 — 門檻下修的決定性證據 |
| E-09(b) | 同注入、Drift 門檻 0.05/2m | 重賽 | v2 ~3min 確定性偵測 | ✅ T+2.9min；Ceph 暖 round 57s（冷 4.6min）→ 互補結論 |
| H-033（計畫外追加）| NTP 連線下 step +100ms | transient 自癒速度 | 秒級自癒 | ✅ 12.7s |
| E-10 | 停 timer / 壞檔 / 停 node-exporter | 觀測鏈自保三情境 | heartbeat 凍結為唯一訊號；up==0 無人接 | ✅（timer/壞檔）；node-exporter 停用觀測見 §6.3 |
| E-08 | 新舊規則 A/B 同場 + soak | 修正項全數翻正、零 FP | v2 接住全部舊盲區 | ✅ A/B 貫穿 E-06~E-09；soak 07:39Z 起累積中 |

### 2.4 併入與裁定不做

| 編號 | 原計畫 | 處置 |
|---|---|---|
| E-03 | poll 32/256/2048 三 cell 凍結曲線 | **併入** E-05(d)/E-07：生產參數 256 的凍結、age、maxerror 曲線已完整取得；32/2048 非生產值，邊際價值不值機時 |
| E-01 的 L2 段 | 真機三區間 offset 格式對照 | **E-01 的 L1 段獨立執行**；L2 段**併入**首小時 + E-06/E-07：實機輸出（`2min 8s`、裸 `0`、never-synced 缺行、`-100.244ms`）已覆蓋全部格式類，與 L1 fixture 一致 |
| E-04 | chrony 環境下採集行為 | **併入**首小時觀測（§3.4）：osd-2 保持 chrony 即天然對照組，fail-loud 路徑全程實測 |
| E-11 | 停 2/3 mon 驗證 mgr 凍結時 node 層存活 | **不做**：mgr 凍結已由先前 mon-quorum SP 實證；本 SP 的 node 層路徑（textfile→node_exporter→Prometheus）架構上不經過 mon/mgr，E-06 中 Ceph 全盲而 node 層正常運作已是等效證據 |

## 3. 逐實驗：環境與採集面

### 3.1 E-00 環境盤點 —— 三個前提被推翻，全部當場處置

- **調整的參數**：無（9 台唯讀盤點：daemon 狀態、有效設定、node-exporter argv、
  Prometheus config、Hyper-V 時鐘面）。
- **為什麼測**：所有原始碼層級推出的前提要對實機校正。
- **預期**：timesyncd 在跑、cephadm 有監控堆疊、timex collector 可用。
- **結果**：三項全數推翻 —
  1. 9 台全部 **chrony、唯一 source = PHC0（Hyper-V PTP 裝置）**：整個 lab 天生共模跟著
     Azure host 時鐘 →〔機制〕重建了信任域切分（§1）才能測共模偵測；
  2. cephadm 19.2.5 **完全沒部署監控堆疊** → 用 `ceph orch` 自佈；
  3. cephadm 對 node-exporter 硬帶 `--no-collector.timex`，用 `extra_entrypoint_args`
     加 `--collector.timex` → **6 台 node-exporter 全滅**（kingpin：
     `flag 'collector.timex' cannot be repeated`）→〔機制〕timex collector 在 cephadm
     下救不回來。
- **建議**：生產部署前必跑同款盤點（`run/e00-inventory.sh`）；timex 車道一律走
  collector 的 `EMIT_TIMEX=1` fallback（script 自己以 glibc `adjtimex()` 補發同名
  metrics，單位換算對齊 node_exporter timex.go），**不要**嘗試 extra args 重開。

### 3.2 首小時檢核 —— v2 collector 一次通過；「timer 死了 series 不會消失」實錘

- **調整的參數**：部署 v2 collector（systemd timer 30s）到 6 台；停 timer 6 分鐘再恢復；
  連續量測 Drift 訊號雜訊。
- **為什麼測**：L1 的綠燈全部來自 fake timedatectl + 合成 series，真實世界的部署面
  （argv、權限、真格式、timer 生命週期）只有上機能證。
- **預期**：collector 全欄位正確；timer 死亡只有 heartbeat 洩底；雜訊帶 « 1s。
- **結果**：
  - systemd 249 真實輸出全欄位正確（含 `2min 8s (min: 32s; max 4min 16s)` 多單位、
    `Jitter: 0` 裸零、never-synced 時整行 Offset 缺失）；
  - timer 停 6 分鐘：node_exporter 照常輸出**全部** series（值凍結、抓取時間戳新鮮）—
    absent/staleness 類偵測對「timer 死亡」全部失效〔機制〕；唯一訊號 = 檔內 heartbeat
    時戳凍結；恢復後 1 個 timer 週期（≤30s）復活；
  - Drift 雜訊：6 台 +2.5~+5.0ms（scrape 最長 0.156s）〔數值〕。
- **建議**：heartbeat（`node_time_sync_last_run_timestamp_seconds`）是採集層自保的
  第一訊號，對應規則 `CephNodeTimeSyncDataStale`（>120s / for 3m）。

### 3.3 E-02 壞檔語意 —— 拒收是 per-file；scrape_error 無法歸因

- **調整的參數**：對 mon-2 寫入獨立壞檔 `junk.prom`（無值行 + 壞 label）。
- **為什麼測**：baseline script 會寫出無值行；node_exporter 的拒收範圍決定
  meta-alert 的歸因設計。
- **預期**：壞檔整檔滅、`node_textfile_scrape_error=1`（target 級）、他檔不受影響。
- **結果**：全中 —— 壞檔自己的 metrics 與 mtime series 全滅，`time_sync.prom` 完好，
  scrape_error=1 且無 file label〔機制〕。`CephNodeTextfileScrapeError`（for:15m）於
  15.5 分鐘後準時 firing。
- **建議**：scrape_error 只做降級 warning；「哪個檔壞了」靠 heartbeat absent 定位
  （壞的是 time_sync.prom 時 `CephNodeTimeMetricsMissing` 會同時 fire）。

### 3.4 E-04 chrony 環境（併入首小時）—— fail-loud 路徑實測

- **調整的參數**：無需注入 — Prometheus host（osd-2）依信任域設計保持 chrony，
  對 timesyncd 專用的採集鏈就是天然的「錯誤 backend」對照組。
- **為什麼測**：生產確認用 timesyncd，但若未來有人裝 chrony 接管，監控不能靜默死亡。
- **預期**：`timedatectl timesync-status` 失敗 → collector 走 fail-loud：
  `collector_error=1` + heartbeat 照常，daemon 相關 metrics 全部缺席（不說謊）。
- **結果**：全中 — osd-2 上實測輸出僅 heartbeat + error=1 + timex×3；
  `CephNodeTimeCollectorError`（for:10m）如設計 pending。附帶：舊 script 在同條件下
  只會留下一個註解檔（L1 已證），全部 metrics 靜默消失。
- **建議**：chrony 接管屬設定事故，靠 CollectorError 車道 fail-loud 抓；若生產
  未來改用 chrony，採集要換 `chronyc` backend（本次未實作）。

## 4. 逐實驗：舊規則（baseline）判決

### 4.1 E-05a + E-01(L1) 離線判決 —— 7 個條件中 6 個是死的，活著的都有毛病

- **調整的參數**：promtool 合成 series 11 情境；fake timedatectl 11 種 offset 格式。
- **為什麼測**：舊 script 只輸出 3 個 metric，舊規則卻引用 9 個。
- **預期**：11+11 個情境的 prediction 逐一寫死於測試檔內（每個 case 的註解即
  prediction 原文），此處不重列。
- **結果**（全部 ✅ 與 prediction 一致，各情境一句話）：
  - 6 個被引用的 metric 不存在 → `CephNTPServiceMisconfigured` 整條死規則、另兩條
    各死 1–2 個分支（Prometheus 對 absent metric 不報錯 — 靜默腐敗）；
  - spread 用 `max(abs)-min(abs)`：**+40ms/-40ms（實差 80ms）算出 0，不叫**；
    而 Ceph timecheck 是 peer-對-leader 減 latency，對稱 skew 同樣可能不叫 —
    雙方共同盲區；
  - 單 node +250ms 且網路乾淨：`and jitter` 條件擋掉，**全部沉默**；
  - `poll≥128s 判為網路不穩`方向相反：poll 拉長是 timesyncd 對穩定的獎勵 —
    生產參數 256 下**每台健康機器 100% 命中**；
  - parser：`+1min 2.337s`→**1.000000000**（62 秒匯報成 1 秒）、`+1h`→1.0、
    `n/a`→**0.0（匯報完美同步）** — 錯得越大、匯報越正常。
- **建議**：舊規則不可修補（結構性問題），整組替換。

### 4.2 E-05 實機 —— or-on() 的破壞力比合成情境更大

- **調整的參數**：兩段 — (a) 健康態長時觀測；(b) **斷線段**：osd-0 斷 NTP 25 分鐘（iptables）。§7 引用的「E-05 斷線段」即 (b)。
- **為什麼測**：離線判決推不出 alert 身分在真 Prometheus 的動態。
- **預期**：健康態 poll 條件永久為真；斷線後 age 線性、sync 旗不動、offset 凍結。
- **結果**：
  - 健康 5 台在規則載入 **60 秒內全部 pending** `CephNTPNetworkDegraded`；pending 集合
    持續震盪（rate==0 分支偶發非空時，`or on()` 把 poll 分支整批丟棄 → 其他節點 for
    重置）→ 健康叢集上這條 warning 的行為**不確定**；
  - +10min 四台健康機到達 firing；**05:52 osd-0 的 rate==0 變真 → 其他 4 台的 firing
    瞬間全部 auto-resolve** — 生產上等於 4 個 page + 4 個假 resolve，節點狀態零變化；
  - 第一個「真」firing 是誤診：timer 演練凍結的 counter 被判為「NTP 網路劣化」—
    baseline 無法區分採集死亡與上游失聯；
  - 斷線曲線全中：age 90→1535s 線性；`NTPSynchronized` **25 分鐘全程 =1**；daemon
    offset 凍在 +26µs；maxerror 斜率實測 496µs/s（kernel 理論 500µs/s）；
  - 附帶：**每次 timesyncd restart → poll 從 32s 重新倍增 → ~8 分鐘後保證一發
    poll≥128 的 FP page**（E-06/E-09 期間三度重現）。
- **建議**：多條件 or-on() 合併規則在生產 alert 是反模式 — 一條 alert 一個條件。

## 5. 逐實驗：故障注入與 v2 判決

### 5.1 E-06 全 fleet 共模 +300s —— 只有跨信任域的 Drift 車道看得見

- **調整的參數**：5 台（含全部 3 mon）NTP 切到 +300s 的 fake upstream，同時 restart。
- **為什麼測**：共模（全 cluster 跟錯 upstream）是理論上最危險的盲區 — 所有相對量測
  都正常。
- **預期**：過渡窗被 for 吸收；穩態只有 Drift 車道 fire；Ceph 無感。
- **結果**：全中 ——
  - 過渡窗 ~1 秒（timesyncd restart 立即對時），daemon spread 短暫 300s 的單筆快照被
    for:5m 完整吸收，零誤 firing；
  - 穩態：**唯一 firing = Drift warning×5 + critical×5**；daemon spread ≤3ms、sync=1、
    timex 全綠（timesyncd 自己 step 後立即 re-discipline，與 §5.2 的外部 step 成對照）；
  - baseline 三條**全程綠** — 共模全盲 firing 級證明；
  - **Ceph HEALTH_OK 全程、quorum age 6h 零 election**：3 mon 一起偏 5 分鐘，相對
    量測完全無感〔機制〕— node 層獨立絕對時間參考存在的決定性理由；
  - 回退 -300s 同樣乾淨（0.6 秒窗、20 秒內 drift 收斂到 29ms）。
- **建議**：Drift 車道（`node_time_seconds - timestamp(...)`）必須存在且 Prometheus
  host 的時鐘來源必須與被測 fleet 異質；Prometheus host 自身時鐘要另行監控。

### 5.2 E-07 持續性 step +100ms —— 三層接力全中；兩個推翻

- **調整的參數**：osd-1 先 iptables 斷 NTP、再 `clock_inject` step +100ms（持續、
  不自癒）；回退後量自癒。
- **為什麼測**：量 v2 各車道對「靜默本地 step」的偵測時序。
- **預期**：Unsync 8.9h 盲 → 空窗只剩 Stalled(13min)；timex offset 不動；Drift 讀
  +105ms 但低於 1s 門檻。
- **結果**：
  - ❌ **推翻#1**：`CephNodeTimeUnsynchronized` **T+3min firing** — kernel 對任何
    CLOCK_REALTIME step 執行 `ntp_clear()` → maxerror 瞬間 16s + STA_UNSYNC〔機制〕。
    `NTPSynchronized` 是雙面訊號：安靜失聯 8.9h 盲（E-05 斷線段）／本地 step 秒級翻旗。
    v2 偵測接力實測：**Unsync 3min → KernelErrorBound 6min → Stalled 13min**；
  - Drift 穩定 +105ms（±5ms）— 大幅高於雜訊、低於當時 1s 門檻（→ E-09 定案下修）；
  - timex offset 全程 0（ADJ_SETOFFSET 不經 PLL）→ `CorrectionInProgress` 正確沉默；
  - 回退：修復發生在解封後**下一個 poll**（+180s）；
  - ❌ **推翻#2**：step 汙染 freq 估計 **+14.7ppm → -275.9ppm**、offset ±25ms 震盪
    數十分鐘 —「修好了」不等於「沒事了」，`keep_firing_for` 的存在價值；
  - `CorrectionInProgress` 對 100ms 級 slew 不 fire（timex 殘餘峰值 -23ms < 50ms 門檻）
    — 快車道靈敏度下限〔數值〕，soak 累積後再議是否下修。
- **建議**：對「本地被 step」不需要新規則 — kernel 已是天然 tripwire；
  監控回應 playbook 要知道 step 後 30–60 分鐘的 offset 震盪是 freq 汙染餘波。

### 5.3 E-09 單 mon 錯誤 upstream +100ms —— 輸一局、調參、再賽

- **調整的參數**：(a) mon-1 跟 +100ms fake upstream（現行門檻）；(b) 同注入、
  Drift warning 1s→0.05s、for 5m→2m。
- **為什麼測**：這是「daemon 自認健康、實際錯 100ms」的正宗場景 — 對 mon 是
  MON_CLOCK_SKEW 的領域，對 v2 是最難的題目。
- **預期**：(a) v2 全盲、Ceph 贏；(b) v2 ~3min 確定性 firing。
- **結果**：
  - (a) 全中：mon-1 daemon offset 震盪 -30~-57ms（自認同步）、spread 盲、Drift 讀
    +112~154ms 穩定可見**但低於 1s** → v2 全程沉默；Ceph `MON_CLOCK_SKEW` **T+4.6min**
    HEALTH_WARN（正確指認）、mixin alert T+6.6min firing — **誠實的敗仗**；
  - (b) `CephNodeClockVsPrometheusDrift`（0.05/2m）**T+2.9min firing**、正確指認 mon-1
    ✅；Ceph 這局 T+57s — 剛經歷 skew 的 timecheck 是暖的〔數值〕→ 結論修正：
    Ceph 偵測延遲隨 round 相位變化 — 兩局實測 57s（暖）與 4.6min（冷、alert 6.6min），
    樣本 n=2、僅界定觀測範圍；v2 tuned 的 ~3min 上界由時序分解推得
    （for 2m + 採集 30s + scrape/eval 各 10s ≈ 2m50s，與實測 2.9min 相符，綁本環境
    節奏）且不依賴 mon/mgr pipeline — 互補而非零和。
- **建議**：Drift warning **0.05s / for 2m**、critical **0.5s / for 1m**（定案，已
  回寫規則與 promtool 測試）；保留 `CephMonClockSkew`（權威確認 + 有時更快）。

### 5.4 H-033 純 transient —— 12.7 秒自癒

- **調整的參數**：k8s-1 在 NTP 連線下 step +100ms。
- **為什麼測**：transient step 的自癒速度決定「事後可見性」需求。
- **預期**：clock-change watcher 立即 resync，秒級修正。
- **結果**：真實 offset 回到 <20ms 耗時 **12.7s**；timesync-status 事後仍顯示
  -100.244ms（快照滯後語意三度實證）。
- **建議**：transient 快於任何 scrape+for 鏈 — 事後可見性靠 kernel tripwire
  （§5.2）與 `keep_firing_for`。

### 5.5 E-08 新舊規則 A/B 同場對照 —— 每個舊盲區都有對應的 v2 接手者

- **調整的參數**：規則集版本（舊 3 條 vs v2 17 條**同時載入**同一個 Prometheus，
  對每場注入做同場 A/B）；另起零 FP soak（07:39Z 起，尚在累積）。
- **為什麼測**：「v2 接住全部舊盲區」必須逐場對照，不能靠敘述。
- **預期**：每場注入中，舊規則沉默或誤報之處，v2 有明確的負責車道 firing。
- **結果**（四場同場對照）：

| 注入場景 | 舊規則實際表現 | v2 實際表現 |
|---|---|---|
| E-05 斷線段（osd-0 失聯 25min）| `Degraded` rate==0 分支 +5min fire — 但與「採集死亡」同訊號無法區分；且觸發 or-on() 讓其他 4 台健康機的 firing 假 resolve | `Stalled` age 768s 準時 warning（+13min）；失聯與採集死亡由不同車道分辨（age vs heartbeat）|
| E-06 共模 +300s（全 fleet）| **三條全程綠**（共模全盲）| `Drift` warning+critical ×5 firing（唯一看得見的車道）；其餘車道正確沉默 |
| E-07 本地 step +100ms（NTP 斷）| 僅 rate==0（+3min，語意模糊）| `Unsynchronized` 3min → `KernelErrorBound` 6min → `Stalled` 13min 三層接力，語意各自明確 |
| E-09 單 mon 錯誤 upstream +100ms | `ClockAbnormal` 在 50ms 邊緣 flapping（daemon offset 震盪誤觸）| (a) 現行門檻誠實全盲 →(b) 門檻定案後 `Drift` T+2.9min 正確指認 |

  - 健康態對照：舊規則載入 60s 全 pending、10min firing、每次 restart 再一發；
    v2 除兩個已知例外（osd-2 = 刻意不裝 collector 的參考機 `MetricsMissing`、
    soak 前的過渡）零誤發。
- **建議**：v2 上線後舊規則直接下架（同場對照已證無互補價值）；soak 收滿前
  接非 paging receiver。

## 6. 逐實驗：觀測鏈自保（E-10）

### 6.1 timer 停擺 → `CephNodeTimeSyncDataStale`（§3.2 已述）
### 6.2 壞檔 → `CephNodeTextfileScrapeError` 15.5min 準時 firing（§3.3 已述）
### 6.3 停 node-exporter（up==0）

- **調整的參數**：`ceph orch daemon stop node-exporter.cyshih-osd-0`，11 分 22 秒後恢復。
- **為什麼測**：整台 exporter 死掉時誰負責叫。
- **預期**：v2 `MetricsMissing` 正確不 fire（其設計前提 up==1）；**現場沒有任何
  target-down 規則接手** — 缺口。
- **結果**：全中 —— up=0 的 11 分 22 秒裡，**整個載入的規則集（v2 + baseline + cephadm
  mixin 全部）沒有任何 alert 提到 osd-0**；`MetricsMissing` 正確不 fire（其前提
  up==1 成立才有意義）。缺口實錘。
- **建議**：已補第 17 條 `CephNodeExporterDown`（`up==0 for 5m`，warning）+
  inhibition（它 fire 時壓掉該 node 其他時鐘 warning — exporter 死掉時其他車道的
  沉默是「未知」不是「健康」）；promtool U15 斷言 fire 與 MetricsMissing 的互斥語意。

## 7. 參數建議總表

| 層 | 參數/規則 | 建議值 | 依據 | 效果量/理由 | 可調性 |
|---|---|---|---|---|---|
| timesyncd | `PollIntervalMaxSec` | **256** | 先前 timesyncd 實驗系列的 soak 結論 + 本 SP 全程以此為生產參數 | 凍結窗 34min→4.3min；age 訊號解析度 | drop-in + restart |
| collector | timer 間隔 | **30s** | E-07/E-09 的偵測鏈時序分解 | 偵測延遲貢獻 ≤30s | timer unit |
| collector | `EMIT_TIMEX` | cephadm 環境 **=1** | E-00（timex 救不回）+ E-07（kernel tripwire 需要它）| Unsync 3min/KernelErrorBound 6min 兩車道的資料來源 | env（先確認 node_exporter 無 timex 再開，避免同名衝突）|
| 規則 | Drift warning | **>0.05s for 2m** | E-06 雜訊 + E-09b | 單 node 錯誤 upstream：全盲→T+2.9min | rule reload |
| 規則 | Drift critical | **>0.5s for 1m** | E-09 | 10× mon 容許值；絕對錯誤時間行動線 | rule reload |
| 規則 | Spread warning/critical | >0.05/0.15 **for 5m** | E-06 過渡吸收 + spike 樣本壽命分析（timesyncd 拒用的 spike 樣本仍停留在快照一個 poll 週期，§0 快照語意）| 零過渡誤發；真實 skew 持續必中 | rule reload |
| 規則 | Offset warning/critical | >0.05 for 10m / >0.1 for 5m | spike 樣本壽命分析 + E-09（freq 汙染震盪不誤發）| spike 樣本壽命 ≤ 一個 poll | rule reload |
| 規則 | Stalled warning/critical | age **>768s / >1800s** for 1m | E-05 斷線段（age 線性 ✓）| 失聯 13/30 分鐘兩級 | rule reload |
| 規則 | DataStale | heartbeat 距今 **>120s for 3m** | 首小時 timer 演練 | timer 死亡唯一訊號 | rule reload |
| 規則 | KernelErrorBound | maxerror **>1s for 5m** | E-05 斷線段實測斜率 496µs/s | 安靜失聯 ~33min 後備；step 時秒級觸發 | rule reload |
| 規則 | 新增 target-down | `up==0 for 5m` | E-10(§6.3) | per-node 車道的前提 | rule reload |
| Alertmanager | inhibition + group_by | `v2/alertmanager-inhibition.yml` | 對抗 review 發現（單一事故可同時滿足 4+ 條規則）+ E-09 實測多車道同時 fire | 單一事故 4+ page → 1 通知 | AM config |
| 部署 | node-exporter textfile 目錄 | `--collector.textfile.directory=/etc/node-exporter`（cephadm `extra_entrypoint_args`）| E-00 | 沒有它整條採集不存在 | orch spec |

## 8. 完整總結

**問題 1（現行方案夠不夠）**：不夠，且不可修補。7 個 alert 條件 6 個永遠不評估
（引用不存在的 metric）；活著的條件裡，spread 公式漏掉對稱 skew（Ceph 也漏 — 共同
盲區）、poll 條件方向相反（生產參數下每台健康機器永久誤報）、or-on() 讓 alert 身分
不穩定（實測出現 4 個 firing 同時假 resolve）。parser 在 offset ≥ 1 分鐘時把災難
匯報成正常（62s→1s、n/a→0）。

**問題 2（FP）**：舊規則健康態必然誤報（載入 60 秒全 pending、10 分鐘 firing、每次
daemon restart 再送一發）；v2 在全部注入（±300s step、100ms skew、freq 汙染震盪）
中零過渡誤發 — for 時長按「spike 樣本壽命 ≤ 一個 poll」設計是關鍵。
**注意：零 FP 的實機 soak 閘門尚未關閉**（soak 自 07:39Z 起累積，需收滿多日再複核 —
§1 判定標準的第三條目前只過了 promtool 半座門）。

**問題 3（重建後的偵測面）**：8 車道 17 條規則，每種故障型態有明確負責人與實測時序 —
本地 step：kernel tripwire 3min；上游失聯：age 13/30min 兩級；單 node 錯誤
upstream：Drift 2.9min（Ceph 兩局實測 57s~4.6min 相位依賴，互補）；全 cluster 共模：
Drift 車道獨家（Ceph 的 timecheck 只量 mon 相對差 — 在此架構下對共模結構性不可見）；採集鏈死亡：heartbeat 2min + per-file 歸因。

**一句話**：舊方案在最需要它的每一種場景都沉默或說謊；新方案的每條規則、每個門檻
都掛著一個實驗編號。

**接下來（按優先序）**：
1. E-08 soak 收滿多日（已於 07:39Z 起跑）→ 零 FP 斷言 + `CorrectionInProgress`
   門檻複核（E-07 顯示 50ms 對 100ms 級 slew 不敏感）；
2. 生產部署走 §7 表 + `run/e00-inventory.sh` 盤點 + README §4.6 首小時檢核；
   Alertmanager receiver 級遞送與 inhibition 驗證（本 lab 未接真 receiver）；
3. 生產 Prometheus 的時鐘來源確認與監控（Drift 車道的架構前提）；
4. 遺留觀察項見 §9。

## 9. 侷限與事故記錄

- **數值級 vs 機制級**：偵測時序（3/6/13min、2.9min、12.7s）綁本環境的 scrape 10s /
  timer 30s / poll 256 節奏，生產不同節奏要按 §5 的分解式重算；雜訊帶 ±5ms 是
  Azure 單 AZ 內量測，跨機房會變大（Drift 門檻要重新取裕度）。kernel ntp_clear、
  per-file 拒收、or-on() 語意、快照凍結為機制級，跨環境成立。
- **未覆蓋**：真 paging receiver 的遞送與 inhibition（lab 無 receiver）；8.9h 的
  NTPSynchronized 自然翻轉（以實測斜率外插，未吊機等待）；chrony 為主 backend 的
  生產（本生產確認 timesyncd）；Prometheus 自身時鐘被帶偏的情境（單 Prometheus，
  建議生產以第二參考互監）。
- **事故誠實記錄**：
  1. `--collector.timex` extra arg 令 6 台 node-exporter crash-loop ~5 分鐘（實驗環境，
     修 spec 即復原）— 但這正是「timex collector 在 cephadm 下救不回」的判決現場（§3.1）；
  2. 一次 commit 因 cwd 錯誤未先跑 `make validate`（變更僅實驗紀錄檔；事後補驗全綠）；
  3. timer 演練的凍結 counter 意外觸發 baseline 首個 firing — 事故變成「baseline
     無法區分採集死亡與上游失聯」的最佳證據。
