# ceph-time-sync-alerts — 實機證據日誌（Azure lab, 2026-07-23 起）

主機一律用 hostname（public IP 見 azure-iac-lab/ACCESS.md，不進版控）。
UTC 時間戳。詳細 bundle 在 results/（gitignored）；本檔是可追溯的摘要索引。

## 環境（E-00, 05:1x UTC）
- 9 台全同質：systemd 249.11 / kernel 6.8.0-1062-azure / chrony→PHC0(hyperv) 共模
- cephadm 19.2.5 無監控堆疊 → 已佈：node-exporter×6（textfile ✓、timex 不可啟用=H-037）、
  Prometheus+Alertmanager @ osd-2（scrape/eval 10s、job=node、external cluster label）
- 信任域切分：mon×3 + osd-0/1 + k8s-1 → timesyncd→k8s-0(10.0.1.5)、poll 256；
  osd-2 + k8s-0 + k8s-2 保持 chrony→PHC

## 首小時檢核（05:3x–05:4x UTC）
- v2 collector 端到端：systemd 249 真實輸出全欄位正確（含 `2min 8s` 多單位、`Jitter: 0` 裸零）
- H-037 判決：`--collector.timex` → kingpin `cannot be repeated` → 6 台 node-exporter 全滅
  → 修 spec 只留 textfile；EMIT_TIMEX adjtimex fallback 上線，6 台 timex 齊
- H-002/H-007 live confirmed（osd-2 fail-loud；k8s-1 never-synced 無 Offset 行）
- Timer 停擺演練（osd-1, 05:40:59Z–05:47Z）：series 全程存活、值凍結、heartbeat 洩底；
  恢復 1 個 timer 週期內 — H-030 修正版機制 confirmed
- Drift 雜訊水位：6 台 +2.5~+5.0ms（scrape max 0.156s）→ 1s 門檻 200x 裕度

## E-05(a) 健康態 baseline 規則行為（05:40 起持續觀測）
- 載入後 60s 內健康 5 台全 pending `CephNTPNetworkDegraded`（poll=256≥128 反向條件）
- **活體新現象**：pending 集合震盪（5 台 ↔ 1 台）— rate==0 分支偶發非空時 `or on()`
  把 poll 分支整個丟棄 → 其他節點 for 重置 → 健康叢集上 warning 永遠 pending/偶發 firing、
  行為不確定（H-012×H-013×H-014 交互，比 promtool 合成情境更嚴重）

## E-05(d) 上游失聯注入（osd-0）
- inject: `iptables -A OUTPUT -p udp --dport 123 -j DROP`（時刻見下）
- prediction: age 線性爬升；rate[5m]==0 於 ~5min 後對 osd-0 恆真；baseline Degraded
  可能因 or-on() 壓制其他節點；daemon offset 凍結；NTPSynchronized 維持 yes（H-023）
- rollback: `iptables -D OUTPUT -p udp --dport 123 -j DROP` + 確認 packet count 恢復增長
- inject 05:47:13Z / rollback 06:15:23Z（iptables 確認乾淨；packet 恢復待下個 poll ≤256s）
- 實測曲線（obs1–13，每 2min）：
  - age 線性 90→1535s（v2 Stalled 768s 會在 +12min 落點、Critical 1800s 在 +30min）
  - rate[5m]==0 自 +5min 起恆真（baseline Degraded 對 osd-0 firing）
  - `NTPSynchronized` 全程 =1 — **25 分鐘失聯完全不可見**（H-023 live）
  - daemon offset 凍結在 +26µs 全程不動（H-005 live）
  - `node_timex_maxerror` 線性 0.0465→0.769（斜率 496µs/s ≈ kernel 理論 500µs/s，H-022 live）
- **or-on() 災難實錄（H-012/H-013 追加證據）**：05:50 健康 4 台（mon×3+osd-1）達 firing
  （poll≥128 永久 FP 完全體）；05:52 osd-0 的 rate==0 分支非空 → `or on()` 丟棄 poll 分支
  → **4 個 firing alert 瞬間 auto-resolve**，僅剩 osd-0 — 生產上 = 4 個 page + 4 個假 resolve，
  而那些節點狀態零變化。alert 身分/條件互踩在真 Prometheus 的破壞力比 promtool 合成情境更大

## E-02(a) 壞檔 per-file 語意（mon-2, 06:21:32Z）
- inject: 獨立壞檔 junk.prom（無值行 + 壞 label）
- 判決：`node_textfile_scrape_error=1`（target 級）；**time_sync.prom metrics 完好** →
  拒收 granularity = per-file；壞檔自己的 mtime series 不存在（parse 失敗不產生）
- 含意：baseline 的無值行會殺光 baseline 自己檔內全部 metrics（與 L1 一致）；
  scrape_error 無法指認哪個檔壞 → v2 歸因設計（scrape_error 降級 warning + heartbeat
  absent 定位）正確。TextfileScrapeError 預期 06:36Z 後 firing（for:15m）
- rollback: 觀測到 firing 後刪 junk.prom

## E-07(i) 持續性 +100ms step（osd-1, NTP 先斷）
- capture: /tmp/timex-pre-e07.json（tick 10000 / freq +14.68ppm / STA_PLL|STA_NANO）
- inject 06:19:16Z: iptables DROP udp/123 → clock_inject set-offset --ms 100
- prediction: Drift 值 ≈ +105ms（低於 1s warning → **記錄為 sub-1s 靜默 step 的偵測空窗**）；
  timex offset ≈ 0（ADJ_SETOFFSET 不經 PLL）；daemon offset 凍結 → spread 盲；
  age 爬升 → Stalled warning ~06:32 firing；baseline 只有 rate==0 (~06:24)
- rollback: 解封 → clock watcher 立即 resync 修正（量恢復時間；CorrectionInProgress
  應在修正瞬間 fire 並 keep_firing 10m）→ 對照 captured timex 狀態

## E-06 全 fleet 共模 +5min（prediction 先行，執行前寫死）
- 舞台：fake NTP server @ k8s-2 (10.0.1.6) `--skew-ms 300000`（06:47Z 起 active，
  k8s-1 probe 實測 +299998ms）；Prometheus host osd-2 與真上游 k8s-0 不受影響
- inject: 5 台（mon×3 + osd-0/1）`99-lab.conf` NTP= 改 10.0.1.6 → 同時 restart
  systemd-timesyncd（restart 會立即對時 — timesyncd lab exp3 已證）
- PREDICTION（機器比對點）:
  1. 5 台在 restart 後數秒內各自 step +300s；+300s > 0.4s 門檻 → clock_settime step
  2. 過渡窗（首台 step 至末台 step，預期 <30s）：spread 瞬間 ~300s → SpreadCritical/
     OffsetHigh 可能短暫 pending（for 5m 擋 firing）；Drift 車道立刻讀 +300s
  3. 收斂後（全部 stepped）：**daemon/spread/offset 層全綠**（各自 offset≈0、spread≈0）；
     kernel 層：step → ntp_clear（E-07 新發現）→ Unsynchronized/KernelErrorBound 短暫
     fire、待 timesyncd 下次 adjtimex 重設 maxerror 後 resolve（觀測重設節奏）
  4. 穩態：**唯一持續 firing = Drift 兩車道（+300s >> 10s critical）** — H-015 共模
     唯一可見路徑的正面證明；baseline 三條全綠（共模全盲，H-015 對舊規則的判決）
  5. Ceph：過渡窗可能 MON_CLOCK_SKEW / election（mon 間瞬時 skew 分鐘級）→ 記錄
     實際反應與恢復；穩態（全 mon 同步偏 5min）Ceph 自身無感（timecheck 相對量）
- rollback: NTP= 改回 10.0.1.5 → 同時 restart → 5 台 step -300s 回正 →
  確認 HEALTH_OK + 全 alert resolve + maxerror 恢復正常斜率
- 風險備忘：過渡窗 mon quorum 可能短暫抖動（disposable lab；全程盯 ceph -s）

## E-07(i) 結果（osd-1，06:19:16Z–06:47Z 含回退）
- 注入段（obs1–14，90s 間隔）：
  - **Drift 車道穩定讀 +105ms**（±5ms 雜訊）— 跨信任域量測在 100ms 尺度可靠 →
    門檻可由 1s 大幅下修（候選 100ms warning）
  - **prediction violation（重大發現）**：`Unsynchronized` +3min firing、
    `KernelErrorBound` +6min firing — 因為 **kernel 對任何 CLOCK_REALTIME step 執行
    ntp_clear() → maxerror 瞬間 16s + STA_UNSYNC**。`NTPSynchronized` 雙面語意：
    安靜失聯 8.9h 盲（E-05d）／本地 step 瞬間翻旗（E-07i）。silent step 並非偵測
    空窗；真空窗 = 上游緩慢帶偏（無 step、Drift 車道專屬）
  - timex offset 全程 0（ADJ_SETOFFSET 不經 PLL）；daemon offset 凍結 → spread 盲 ✓
  - v2 偵測接力實測：Unsync 3min → KernelErrorBound 6min → Stalled 13min ✓
  - baseline 僅 rate==0 Degraded（+3min，與 collector 死亡同訊號、無法區分）
  - TextfileScrapeError（E-02a 的 mon-2 爛檔）06:37Z 準時 firing（for:15m ✓）
- 回退段（06:42:05Z 解封）：
  - 修復發生在下一個 poll（+180s，≤256s 如預測；clock watcher 不會為「解封」觸發 —
    它只看 clock 變化）：量到 -100.58ms → 修正 → sync 回 1、maxerror 由 timesyncd 重設
  - **freq 汙染**：step 誤導頻率估計 +14.7ppm → -275.9ppm，offset ±25ms 震盪再收斂 —
    單次 step 的傷害持續多個 poll 週期（timesyncd lab exp1 行為的生產再現）
  - **CorrectionInProgress 未 fire**：100ms slew 的 timex 殘餘峰值僅 -23ms < 50ms 門檻
    → 快車道對 100ms 級修正不敏感（tuning 輸入：門檻 vs 靈敏度取捨待 E-08 soak 定）
  - assert：clock_inject restore 還原捕捉狀態（tick/freq/status/maxerror）→ 手動覆核 OK

## E-06 結果（06:47:46Z inject / 07:05:01Z rollback）
- 過渡窗 ~1s（4 台的 date 已印 +5min 時間）；HEALTH_OK 全程、quorum age 6h 零 election
- 穩態（obs8–20）：**唯一 firing = Drift warning×5 + critical×5**；daemon spread ≤0.003s、
  sync=1、timex 全綠 — H-015/H-034 firing 級證明；baseline 三條全程綠 = 共模全盲
- 過渡 transient（spread 300s 單筆快照）被 for:5m 完整吸收，零誤 firing ✓
- timesyncd 自己 step → 立即 re-discipline → Unsynchronized 未 fire（vs E-07 外部 step
  即翻 — H-038 語意細化：差別在 daemon 是否立刻善後）
- **新 FP 機制**：daemon restart → poll 32s 重新倍增 → ~06:55（+8min）baseline
  Degraded 重新 firing×5 — 每次 restart 保證一發延遲 page
- 回退：5 台 0.6s 窗內 -300s；max|drift| 20s 後已收到 0.029s；HEALTH_OK

## E-09(a) 單 mon 錯誤 upstream +100ms（prediction 先行）
- inject: fake server 改 --skew-ms 100；僅 mon-1 NTP=10.0.1.6 → daemon 維持的
  持續 +100ms（不會自癒 — daemon 認為自己同步）
- PREDICTION:
  1. mon-1 daemon offset ≈0（同步到錯源）→ Offset/Spread 車道**盲**
  2. mon-1 Drift ≈ +105ms < 1s → Drift 車道**盲**（現行門檻）
  3. timex/sync 全綠（daemon 正常 discipline）→ **v2 全車道沉默**
  4. Ceph timecheck（≤300s 週期 + mixin for:1m）：inter-mon skew 100ms > 50ms →
     `MON_CLOCK_SKEW` HEALTH_WARN + `CephMonClockSkew` firing ≤ ~7min —
     **Ceph 贏得這一局**（誠實記錄 v2 的敗仗）
  5. 若成立 → 決定性 tuning 證據：Drift warning 門檻 1s → 0.05s（10× 雜訊水位）
     後重賽（E-09b），v2 應以 ~1-2min 反超
- rollback: mon-1 NTP=10.0.1.5 restart → HEALTH_OK + MON_CLOCK_SKEW resolve

## E-09(a) 結果（inject 07:06:28Z / rollback 07:23:23Z）— Ceph 贏第一局（如預測）
- `MON_CLOCK_SKEW` HEALTH_WARN **T+4.6min**（07:11，一個 timecheck 週期內、正確指認
  mon-1）；`CephMonClockSkew` alert firing **T+6.6min**（07:13）
- **v2 全程沉默（現行門檻）**：mon-1 daemon offset 震盪 -30~-57ms（同步到錯源 →
  自認健康；freq 汙染使其繞 +130ms 真實偏差擺動）；Drift 讀值 +112~154ms 穩定
  可見但 < 1s 門檻；tsstat（leader 視角）121-149ms 與 Drift 讀值相互印證
- 附帶觀察：baseline `ClockAbnormal` 因 daemon offset 在 50ms 邊緣進出而 flapping；
  `Degraded` 因 E-06 rollback 的 restart 再次全 fleet firing（restart→FP 機制三度重現）
- 判決：**單 node 錯誤 upstream（100ms 級）= v2 現行門檻的真實敗仗**；Drift 數據
  （穩定 +130ms、雜訊 ±5ms）構成門檻下修的決定性證據 → E-09(b) 以
  warning 0.05/for:2m、critical 0.5/for:1m 重賽
