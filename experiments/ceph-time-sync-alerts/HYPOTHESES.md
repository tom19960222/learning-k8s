# ceph-time-sync-alerts — Hypothesis Backlog

## Charter

**研究問題**：現行的 NTP 採集 script（`collect_ntp_offset.sh`，textfile collector 模式）加上 3 條
ceph-ntp alert（`CephNTPClockAbnormal` / `CephNTPNetworkDegraded` / `CephNTPServiceMisconfigured`），
是否足以在「極高敏感、掉 2 個 ping 都會叫」的生產 Ceph cluster 上**第一時間**偵測時鐘異常？
盲區在哪、false positive 在哪、偵測延遲多長？

**Source of truth（pinned）**：
- systemd submodule v260.1（`src/timedate/timedatectl.c`、`src/basic/time-util.c`；目標機實際版本待 E-00 校正）
- ceph submodule v19.2.3（`src/common/options/mon.yaml.in`、`monitoring/ceph-mixin/prometheus_alerts.yml`）
- node_exporter submodule v1.11.1（`collector/timex.go`、`collector/textfile.go`）
- 使用者提供的實機環境（規格見 README.md §2）

**既有可重用資產**：`experiments/timesyncd/`（fake NTP server、`clock_inject.py`、校準、
iptables/tc 注入與 cleanup trap）；`experiments/ceph-alert-rules/`（既有 27 條 rule 含
`CephMonClockSkew`）；先前 SP 實證的 accumulated failure classes（`skills/enumerating-adversarial-boundaries/references/axes.md`）。

**關鍵背景常數（T1 已證）**：
- `mon_clock_drift_allowed = 0.05s`（mon.yaml.in:609-613）→ mon 間 skew 50ms 即 HEALTH_WARN
- `mon_timecheck_interval = 5min`（mon.yaml.in:628-634）→ Ceph 自身偵測週期 5 分鐘（leader 執行）
- 官方 mixin `CephMonClockSkew`：`ceph_health_detail{name="MON_CLOCK_SKEW"} == 1`，for: 1m（prometheus_alerts.yml:74-83）
- systemd-timesyncd poll interval：成功即倍增，預設最大 `PollIntervalMaxSec=2048s`（≈34 min）
- **生產 ops 參數（使用者 2026-07-23 確認）**：`PollIntervalMaxSec` 將調整為 **256s**
  （= timesyncd lab exp4 的建議值）→ 涉及 poll 的預測以 256 為主線、2048 為預設組對照
- node_exporter timex collector 預設啟用：`node_timex_offset_seconds` / `node_timex_sync_status` / `node_timex_maxerror_seconds`（timex.go:75,85,155,191）

---

## A 組 — 採集 script 的行為邊界

### H-001: offset ≥ 1 分鐘時，parser 把 `+1min 2s` 誤讀成 1.0 秒 — skew 越大、匯報值錯得越離譜
- Status: confirmed
- Evidence: tests/parser/run-parser-tests.sh 11/11 PASS（2026-07-23，baseline script 原封
  awk 邏輯 + fake timedatectl）：`+1min 2.337s`→1.000000000、`+1h 2min 3s`→1.0、
  `+1d`→1.0、`n/a`→0.000000000（lying）、Offset 行缺失→unavailable 分支；
  60s 以下（us/ms/s）全對。真機 timedatectl 輸出格式的端到端覆核留 E-01 L2 段
- Tier: T1（source 已證）→ L1 已實證，T3 端到端覆核
- Origin: negative-space（offset 字串格式全空間枚舉）
- Prediction: fake timedatectl 回 `Offset: +1min 2.337s` 時，`node_ntp_offset_seconds` 輸出 `1.000000000`；
  回 `+1h 2min` 時輸出 `1.000000000`。60 秒以下（dot notation 單 token）則正確。
  另外（codex 修正）：若輸出為 `n/a` 之類非數字 token，awk 強制轉型成 `0.000000000` —
  不是走 unavailable 分支，而是**匯報完美同步**（lying）；首次 sync 前正常情況是整行
  Offset 缺失（timedatectl.c:439 附近，packet count 為 0 時不印）。
- Evidence(T1): systemd `format_timespan` 單位表 time-util.c:525-534（y/month/w/d/h/min/s/ms/us 多單位、
  空格分隔）；dot notation 僅在 `t < USEC_PER_MINUTE`（time-util.c:571-590）；Offset 印出
  `%s%s`（sign + FORMAT_TIMESPAN）timedatectl.c:509-516。awk 對 `+1min` 數值強制轉型 → 1.0。

### H-002: 若改跑 chrony（cephadm 官方建議之一），`timedatectl timesync-status` 失敗 → 所有 metrics 靜默消失
- Status: confirmed
- Evidence: Azure lab 實機（2026-07-23）：osd-2 保持 chrony 時，v2 collector 走 fail-loud
  路徑（heartbeat + collector_error=1 + timex×3，daemon metrics 全缺席）— chrony 下
  timesync-status 確實失敗；baseline script 在同條件下只會剩 comment 檔（L1 已證 T-tdctl-fail）。
  v2 的 fail-loud 設計即本假設的對策，實機行為與設計完全一致
- Tier: T3
- Origin: matrix「NTP daemon × partial × observer」
- Note: 使用者已確認（2026-07-23）生產環境用 systemd-timesyncd → 本假設降為 robustness
  情境（防未來有人裝 chrony 接管時監控靜默死亡），非主線風險。
- Prediction: chrony 環境下 script 走 `# timedatectl unavailable` 分支，`.prom` 只剩 comment；
  series 在**下一次成功 scrape 就被打 stale marker**（node_exporter 本身仍可 scrape，
  series 從回應中消失 → 立即 stale，不是等 5 分鐘 lookback — codex 修正）；
  現行 3 條 alert 全部不 fire。

### H-003: 三次獨立指令呼叫任一回空值時，`.prom` 出現無值行，node_exporter 拒收**整份檔案**
- Status: confirmed
- Note: 檔案面已 L1 實證（tests/parser T-empty-packet）；node_exporter 側 E-02(a) 實機
  判決（2026-07-23 06:21Z mon-2）：**拒收 granularity = per-file** — 壞檔自己全滅
  （含 mtime series 不產生）、其他 .prom 完好、scrape_error=1 為 target 級無從歸因
- Tier: T3
- Origin: pre-mortem（script 靜默失效的路徑回推）
- Prediction: `packet_count` 為空時寫出 `node_ntp_packet_count_total `（無值）→
  `node_textfile_scrape_error=1` 且該檔**所有** metrics（含正常的 offset）一起消失；
  現行 alert 無一盯 `node_textfile_scrape_error` → 靜默。

### H-004: metric absent 時，`count(node_ntp_synchronized == 0) > 0` 不會 fire — 「採集死亡」與「一切正常」在 alert 眼中同義
- Status: confirmed
- Evidence: T9 — stale 後 alert 靜默 auto-resolve 亦證實；textfile→stale 的實機時序留 E-10；promtool 3.12.0, `bash tests/run-tests.sh` → PASS（2026-07-23）, tests/promtool/current-rules.test.yml
- Tier: T2（PromQL 語意）→ T3 實測
- Origin: axes.md accumulated class「Observer lying / stale telemetry」
- Prediction: 停掉 cron 或刪 `.prom` 後，3 條 alert 持續綠燈；`node_textfile_mtime_seconds`
  持續變舊但無 alert 引用它。

### H-005: `node_ntp_offset_seconds` 是「上次 poll 時刻」的快照，兩次 poll 之間凍結 — 預設 2048s 時最多過時 34 分鐘；生產參數 256s 時凍結窗 ≤ 4.3 分鐘
- Status: confirmed
- Evidence: E-05(d) Azure lab（2026-07-23 05:47–06:15Z）：osd-0 斷 NTP 25 分鐘，
  daemon offset 凍結在 +26µs 全程不動（EVIDENCE-LOG.md E-05(d) 段）
- Tier: T3
- Origin: matrix「script × stale × observer」
- Prediction: 斷 NTP（iptables drop udp/123）+ 注入 100ppm drift 後，`node_ntp_offset_seconds`
  維持斷線前的值不動，真實 offset 每分鐘 +6ms 發散；`node_timex_maxerror_seconds` 持續上升
  （kernel 每秒累加）— timex 層看得到、script 層看不到。

### H-006: timedatectl D-Bus 呼叫有 25s 內建 timeout（`BUS_DEFAULT_TIMEOUT`，bus-internal.h:314）→ 阻塞有界（兩次呼叫 ≈50s）但仍超過採集週期 → 短間隔 timer 下 instance 疊加
- Status: predicted
- Tier: T1（timeout 常數已證）→ T3（實測疊加行為）
- Origin: matrix「script × slow」（codex 修正：非無界阻塞）
- Prediction: `SIGSTOP systemd-timesyncd` 後單次 script 執行耗時上界 ≈ 2×25s，非無限；
  15–60s 的 timer 間隔下仍會出現 instance 並存與共用 `.tmp` 檔互踩（見 H-035）→
  新 script 仍需外層 timeout + flock。

### H-007: timesyncd 啟動後、首次成功對時前，`timesync-status` 無 Offset 值（或 n/a）— script 在最需要回報的窗口反而沒輸出
- Status: confirmed
- Evidence: Azure lab 實機（2026-07-23）：k8s-1 剛轉 timesyncd、Packet count=0 時，
  timesync-status 只印 Server/Poll interval/Packet count 三行 — Offset 整行缺失，
  與預測一致。baseline → unavailable 分支（全滅）；v2 → collector_error=1 + 部分欄位，
  首次 poll 成功後自動恢復
- Tier: T3
- Origin: negative-space（daemon 生命週期狀態枚舉）
- Prediction: restart timesyncd 且 udp/123 被擋時，`Offset:` 行缺失或值非數字 → 進 unavailable 分支或寫壞檔。

### H-008: `Packet count` 在 timesyncd restart 時歸零；`increase()` / `rate()` 在窗口 < 2×poll interval 時恆為 0
- Status: proposed
- Tier: T3
- Origin: matrix「counter 語意 × stale」
- Prediction: poll=2048s 的健康節點，`rate(node_ntp_packet_count_total[5m])` 大部分時間 = 0。

## B 組 — Alert 規則邏輯缺陷

### H-010: 6 個被引用的 metric（jitter/delay/poll_interval/active/local_rtc/timezone_info）script 從未輸出 → 3 條 alert 的 7 個條件中 6 個永遠是 empty vector
- Status: confirmed
- Evidence: T3 — Misconfigured 在 6 metric 缺席下 15m 全程沉默；promtool 3.12.0, `bash tests/run-tests.sh` → PASS（2026-07-23）, tests/promtool/current-rules.test.yml
- Tier: T2（比對 script 輸出與 rule 引用）→ T3 實測
- Origin: negative-space（rule 引用 vs script 輸出交集）
- Prediction: `CephNTPServiceMisconfigured` 整條在任何注入下都不可能 fire；
  `CephNTPClockAbnormal` 條件(3)、`CephNTPNetworkDegraded` 條件(1)(3) 同樣是死的。
  Prometheus 對 absent metric 不報錯 — 這是靜默的規則腐敗。

### H-011: spread 用 `max(abs(o)) - min(abs(o))` — 對稱 skew（+40ms / -40ms，實際相差 80ms）算出 spread=0，不 fire
- Status: confirmed
- Evidence: T1+T2 — 對稱 ±40ms 沉默；非對稱 70ms 陽性對照有 fire；promtool 3.12.0, `bash tests/run-tests.sh` → PASS（2026-07-23）, tests/promtool/current-rules.test.yml
- Tier: T2 → T3
- Origin: pre-mortem（mon 已 MON_CLOCK_SKEW 但我們的 alert 沒叫，回推原因）
- Prediction: 兩 node 各注入 +40ms / -40ms，真實 inter-node skew 80ms，
  `CephNTPClockAbnormal` 條件(1) 恆為 0，不 fire。
  （codex 修正）Ceph 這時**也可能不叫**：timecheck 是每個 peer 對 leader 算
  `skew_bound = |delta| - latency`（Monitor.cc:5163-5170，還要減掉 latency），
  leader 在 0、兩 peer ±40ms 時各自 skew_bound < 50ms → 不 WARN。
  也就是：對稱 skew 是 Ceph 自身偵測的天然弱區 — 我們的 spread 規則必須接住
  Ceph 接不住的這一塊，這是 node 層 spread 條件存在的獨立理由。

### H-012: `or on()` 串接讓 alert series 身分在「aggregate 條件 ↔ per-instance 條件」轉換時變動 → `for: 3m` 計時器重置；且 fire 時無法辨識條件與 node
- Status: confirmed
- Evidence: T6+T7 — 修正版語意證實：(1)↔(2) 不重置準時 3m fire；(1)→(3) 重置、5m 沉默 7m 才 fire；promtool 3.12.0, `bash tests/run-tests.sh` → PASS（2026-07-23）, tests/promtool/current-rules.test.yml
- Tier: T2（PromQL `or on()` 語意：LHS 非空時 RHS 同 signature 全丟）→ T3 實測
- Origin: matrix「alert rule × partial」
- Prediction:（codex 修正原始版本）條件(1)↔(2) 之間轉換**不會**重置 for — 兩者輸出
  都是空 label set、alert 身分相同。重置只發生在空 label set ↔ per-instance 的轉換：
  例如條件(1) spread 先真 2 分鐘後解除、改由條件(3)（帶 instance label）為真 →
  身分改變 → for 重新計時 → firing 比單一條件持續觸發晚。
  「fire 時分不清哪個條件、哪個 node」的部分維持原判。promtool 單元測試可完整驗證（E-05a）。

### H-013: 「poll interval ≥ 128s 判為網路不穩」方向完全相反 — NTP client 穩定時才會拉長 poll → 健康 cluster 開機十幾分鐘後此條件永久為真
- Status: confirmed
- Evidence: T5 — 健康節點（rate>0）僅因 poll=2048 即永久 warning；promtool 3.12.0（2026-07-23）。
  Live 追加：Azure lab 健康 4 台於規則載入 ~10min 後達 firing（poll=256≥128）—
  且 05:52 被 osd-0 的 rate==0 分支透過 or-on() 全數瞬間 auto-resolve（EVIDENCE-LOG.md）
- Tier: T1（timesyncd poll 倍增邏輯；先前 exp4 實測）→ T3
- Origin: persona（SRE 視角：這條上線第一天就 alert fatigue）
- Prediction: 若補上 `node_ntp_poll_interval_seconds` metric，健康節點在 sync 穩定後
  poll 倍增至 max，條件(3) 在穩定同步一段時間後永久為真 → 永久 warning。
  生產參數 256 下更糟：256 ≥ 128 恆真 → 每一台健康機器 100% 命中（T5b 證實）。
  （codex 細化）倍增條件是 `|offset| < 0.25×NTP_ACCURACY_SEC`；`> 0.75×` 或 spike 減半、
  `> 1×` 直接跌回最小值（timesyncd-manager.c:364-390）— 所以 poll 拉長恰恰是
  「offset 持續很小」的證明，方向反轉的結論不變且更強。

### H-014: `rate(packet_count[5m]) == 0` 的 FP 與否取決於 poll interval 對 5m 窗的比值 — 預設 2048s 下永久性間歇 FP；生產參數 256s 下健康態 FP 消失、翻轉為「掉 ~3 個 poll 才 fire」的粗粒度失聯偵測
- Status: confirmed
- Evidence: T4 — poll=2048 型 counter（34 分鐘 +1）10m 即誤發；T4b — 生產參數 256 型
  counter（4 分鐘 +1）任何 5m 窗必含遞增 → 10m/20m 全程無 alert，短暫零窗撐不過
  for:5m；promtool 3.12.0, `bash tests/run-tests.sh` → PASS（2026-07-23）
- Tier: T3
- Origin: negative-space（poll interval 值域 vs 窗口 5m）
- Prediction: 預設 2048 下健康節點反覆誤發（T4 證實）。生產參數 256 下：counter 最大
  間隔 4.27m < 5m 窗 → 健康態恆 rate>0（T4b 證實）；失聯時條件為真的時長 ≈ gap−300s，
  要撐過 for:5m 需 gap ≥ ~600s ≈ 連掉 3 個 poll → 偵測延遲 ~10 分鐘等級（L2/E-03
  實測 timesyncd 失聯時的實際重試節奏後精算）。設計含意：rate 窗與 for 必須
  跟 PollIntervalMaxSec 綁定設計，且此路徑只能當粗粒度後備、快速失聯偵測靠 last-sync-age。

### H-015: 全 cluster 同步漂移（所有 node 跟同一個錯誤 upstream 對時）→ spread=0、sync=1、jitter 低 → 三條 alert 全盲
- Status: predicted
- Tier: T3
- Origin: matrix「NTP upstream × lying」
- Prediction: fake upstream 統一撥快 5 分鐘，全部 node 跟上後：現行三條 alert 無一 fire；
  但 RGW S3 signature（AWS SigV4 容忍 ±15min）、cephx ticket、外部系統對時全部處於風險中。

### H-016: 單 node 大 offset 但網路穩定（jitter 低）→ 條件(3) 的 `and jitter > 0.05` 擋掉 alert
- Status: confirmed
- Evidence: T3 — +250ms 絕對偏差全程無任何 alert；promtool 3.12.0, `bash tests/run-tests.sh` → PASS（2026-07-23）, tests/promtool/current-rules.test.yml
- Tier: T2 → T3
- Origin: negative-space（offset × jitter 四象限，「大 offset + 低 jitter」象限 UNCOVERED）
- Prediction: 單 node step +200ms 且網路乾淨時，條件(3) 不成立；只剩條件(1) spread 能救
  （又被 H-011 的 abs bug 弄殘：若另有 node offset 為負，可能也不 fire）。

### H-017: RTC / timezone 檢查用 `count_values()` 對 gauge 值 — timezone 字串無法用 gauge 值表達，即使補了 metric 語意也是錯的
- Status: proposed
- Tier: T2
- Origin: negative-space（metric 型別 vs 表達需求）
- Prediction: 需 info-pattern（字串放 label、值恆 1）重寫，否則無法偵測「Asia/Taipei vs UTC 混用」。

## C 組 — 分層防禦與 Ceph 端行為

### H-020: node-level alert 應穩定領先 `MON_CLOCK_SKEW` — Ceph 端偵測延遲上界 ≈ mon_timecheck_interval(5min) + mixin for(1m) + scrape
- Status: predicted
- Tier: T1（常數已證）→ T3（量測實際先後與差距）
- Origin: matrix「ceph mon × slow(偵測路徑)」
- Prediction: mon node 持續性 skew（注意 H-033：一次性 step 會被 timesyncd 自癒，
  必須用「斷 NTP + drift」或 upstream skew 注入），設計良好的 node alert 應在
  ≤ 2 分鐘 firing；`ceph_health_detail{name="MON_CLOCK_SKEW"}` **常態情況**
  ~6 分鐘後才變 1。（codex 修正）6 分鐘是常態估計、非硬上界：timecheck round
  未完成可延至 3×mon_timecheck_interval 才取消（Monitor.cc:4826-4875），
  election 又會立即觸發新 round → 實測記錄實際分布而非驗證單一上界。

### H-021: mon quorum 掉時 mgr prometheus metrics 凍結（先前 SP 已實證）→ 「靠 ceph_health_detail 偵測時鐘」在時鐘壞到影響 quorum 時正好失效
- Status: predicted
- Tier: T2（引用 experiments/ceph-mon-quorum-blind-spot 既有證據）
- Origin: axes.md accumulated class「Observer lying / stale telemetry」
- Prediction: node-level（textfile + timex）觀測路徑不經過 mon/mgr，時鐘災難時仍活著 —
  這是三層防禦中 node 層存在的核心理由，L4 驗證一次即可。

### H-022: 斷 NTP 後 `node_timex_maxerror_seconds` 穩定累加（500µs/s，linux kernel/time/ntp.c:457）→ 約 8.9 小時觸頂 16s — kernel 層是唯一「持續反映失聯時長」的免費訊號，但它是誤差上界、不是實際 offset
- Status: confirmed
- Evidence: E-05(d)：maxerror 0.0465→0.769 / 1456s → 實測斜率 496µs/s（理論 500µs/s）；
  外插 16s 觸頂 ≈ 8.95h 與 T1 推算一致（EVIDENCE-LOG.md）
- Tier: T1（kernel source 已證）→ T3（實測累加曲線與 sync_status 翻轉）
- Origin: negative-space（三層觀測路徑各自的更新頻率枚舉）
- Prediction: 斷線後 maxerror 以 500µs/s 累加，~8.9 小時觸頂 16s；
  （codex 補充）`node_timex_offset_seconds` 是 kernel PLL 的**剩餘修正量**
  （timesyncd 經 ADJ_OFFSET 寫入，timex.go:163-193）— 被馴服收斂後趨近 0，
  即使全 cluster 跟著錯誤 upstream 也趨近 0（見 H-034）。
  設計上 maxerror 適合當「失聯持續」訊號、offset 適合當「修正中/未收斂」訊號，
  兩者都**不是**絕對時間誤差的真值。

### H-023: 斷 NTP 後 `NTPSynchronized` 約 8.9 小時內維持 yes — script 的 sync flag 對「上游失聯」在頭幾小時完全不敏感
- Status: confirmed
- Evidence: E-05(d)：25 分鐘完全失聯，flag 全程 =1（8.9h 全程翻轉點由 maxerror 實測斜率
  外插；不值得吊 8.9h 機器等它翻）（EVIDENCE-LOG.md）
- Tier: T1（source 已證）→ T3（實測翻轉時刻）
- Origin: matrix「timesyncd × stale × observer」
- Prediction: `NTPSynchronized` 實作是 `adjtimex().maxerror < 16s`，且**刻意忽略
  STA_UNSYNC**（timedated.c:570-579）→ 斷線後跟著 maxerror 累加走，~8.9 小時才翻 no。
  `node_ntp_synchronized` 與 `node_timex_sync_status` 對「失聯 30 分鐘」都是瞎的；
  快速失聯偵測必須靠 last-sync-age / packet count 停滯 + 窗口設計。

## D 組 — 觀測鏈自身失效（observer 也是被測系統）

### H-030: textfile 過期無人盯 — timer 死亡後 series **不會消失**（node_exporter 每次 scrape 重讀舊檔、時間戳永遠新鮮），absent/staleness 類偵測全部失效
- Status: predicted
- Tier: T2 → T3
- Origin: pre-mortem；機制由 codex r2 finding 2 修正（textfile collector 於 scrape 時讀檔）
- Prediction: timer 停用後，所有 `node_ntp_*` 凍結在最後值但 series 持續存在且「新鮮」；
  `up unless collector_error` 類規則不會 fire（U5 的 stale-series 情境是合成的，真實
  機制走不到）。唯一可靠訊號 = 檔內 heartbeat 時戳凍結（v2 已加
  `node_time_sync_last_run_timestamp_seconds` + `CephNodeTimeSyncDataStale`）或
  `node_textfile_mtime_seconds` 變舊。E-10 實機驗證兩者。

### H-031: `node_textfile_scrape_error == 1`（壞檔）無人盯 — 與 H-003 合併成「採集層需要自己的 meta-alert」
- Status: predicted
- Tier: T3
- Origin: matrix「node-exporter × lying」
- Prediction: 寫入壞格式 `.prom` 後 `node_textfile_scrape_error` 變 1，現行規則無反應。
  （codex 補充歸因限制）`scrape_error` 是 target 級單一 gauge、**無 file label**
  （textfile.go:35-42）；`node_textfile_mtime_seconds{file=...}` 只在 parse 成功時存在
  （textfile.go:269-281）→ 壞檔時 mtime series 也一起消失。meta-alert 設計必須用
  「scrape_error + 我方 heartbeat metric absent」組合歸因，且 scrape_error 單獨告警
  降級（可能是別的 `.prom` 壞掉，別讓時鐘監控背鍋）。

### H-032: 規則的 selector 全域無 scope — 任何非 Ceph 主機的 `node_ntp_*` 都會混進 spread / count 計算
- Status: confirmed
- Evidence: T8 — app-42 主機 +200ms 令 Ceph alert 誤 fire；promtool 3.12.0, `bash tests/run-tests.sh` → PASS（2026-07-23）, tests/promtool/current-rules.test.yml
- Tier: T2 → T3
- Origin: codex cross-review finding 10（persona: 共用 Prometheus 的 fleet 視角）
- Prediction: 同一個 Prometheus 上若有第二組主機輸出同名 metrics，非 Ceph 主機的
  時鐘異常會對 Ceph cluster 誤發 page；反之 Ceph node 的 series 缺席可被他組
  相同值遮蔽。修正版規則必須帶 cluster/job label scope + 期望節點清單 join
  （每 node 一條 missing-series alert，而非全域 absent()）。

### H-033: 外部注入的一次性 clock step 會觸發 timesyncd 的 clock-change watcher 立即 resync — 注入在被偵測前自癒
- Status: predicted
- Tier: T1（timesyncd-manager.c:206-223：`manager_clock_watch` 對非自身 jump 立即
  `poll_resync=true` + `manager_send_request()`）→ T3
- Origin: codex cross-review finding 16（實驗設計 confound）
- Prediction: NTP 連線正常時對 mon node step +100ms，timesyncd 在秒級內發起 resync
  並修正 → Ceph 的 5 分鐘 timecheck 與我們的分鐘級 alert 都可能根本看不到。
  實驗上「持續 skew」必須用（a）斷 NTP + drift 或（b）upstream 回錯時間製造；
  一次性 step 只適合測「transient 偵測」這個獨立問題（見 E-07 重設計）。

### H-034: 共模錯誤時間下，kernel timex 三訊號（offset/maxerror/sync_status）全部顯示健康 — timex 層對 H-015 無防禦力
- Status: predicted
- Tier: T2 → T3（E-06 同步採樣驗證）
- Origin: codex cross-review finding 8（timex 語意修正的推論）
- Prediction: 全 cluster 跟錯誤 upstream 收斂後，node_timex_offset ≈ 0、maxerror 正常
  重置、sync_status=1 — 三層（timex/daemon/ceph health）觀測的都是同一個信任域，
  共模防禦必須來自獨立第四路（Prometheus 端時間比對 + 異質外部參考，且
  Prometheus 自身時鐘也要被監控）。

### H-035: 並發 script 執行共用同一個可預測的 `.tmp` 路徑 → 互踩截斷或 rename 失敗
- Status: proposed
- Tier: T3
- Origin: codex cross-review finding 11（部署 robustness）
- Prediction: 兩個 script instance 同時跑（H-006 的疊加情境）時，後者覆寫前者的
  `.tmp`，可能出現半寫入內容被 rename 或 rename 目標消失；新 script 需
  mktemp 唯一暫存檔（同檔案系統）+ flock + trap cleanup。

### H-036: 被 timesyncd 判為 spike 而拒用的 NTP 樣本，仍會停留在 `timesync-status` 顯示直到下一個 poll — snapshot 車道單一樣本可存活 ≤256s
- Status: predicted
- Tier: T1（timesyncd-manager.c:565-575：`if (!spike)` 才 adjust，樣本本身照存）→ T3（E-03/E-05 實測）
- Origin: codex r2 finding 4
- Prediction: 對 upstream 注入單發大 offset 回應（fake server 可控），節點時鐘不動、
  `node_ntp_offset_seconds` 卻顯示 spike 值長達一個 poll 週期（poll 因 spike 減半 →
  ~128s）。v2 對策：snapshot 車道 `for:` ≥ 5m > spike 樣本壽命；快偵測交給
  timex/drift 車道。E-05 驗證 for 設計確實擋住單發 spike。

### H-037: pinned cephadm（v19.2.3）預設以 `--no-collector.timex` 啟動 node-exporter 且不設定 textfile 目錄 — timex 車道與 textfile 採集都需要顯式設定
- Status: confirmed
- Tier: T1（cephadmlib/daemons/monitoring.py:73-77 args 僅 `--no-collector.timex`；
  NodeExporterService 無 textfile flag）→ T3（E-00 對 lab 與生產各驗一次）
- Origin: codex r2 finding 1
- Prediction: lab 的 node-exporter argv 無 textfile 目錄與 timex（除非部署有
  extra_entrypoint_args）；生產環境現有 `node_textfile_mtime_seconds` 輸出證明生產
  有設定 textfile — E-00 抓兩邊實際 argv 對照，v2 部署文件補「啟用兩個 collector」
  步驟（`--collector.timex` 能否蓋掉 `--no-collector.timex` 由 kingpin 語意決定，實測）。
- Evidence（判決，2026-07-23 Azure lab）：**confirmed** —
  (1) E-00 證實 lab 的 cephadm 19.2.5 預設完全不佈監控堆疊；
  (2) `extra_entrypoint_args` 加 `--collector.timex` → 6 台 node-exporter 全掛，
  container 直接吐 `node_exporter: error: flag 'collector.timex' cannot be repeated`
  （kingpin 拒絕重複 bool flag）→ **timex collector 在 cephadm 下無法重新啟用**；
  (3) 對策已實作：v2 script 的 `EMIT_TIMEX=1` 以 glibc adjtimex() 補發同名
  node_timex_* metrics（textfile fallback），6 台實機驗證輸出正常。

### H-038: kernel 對任何 CLOCK_REALTIME step（ADJ_SETOFFSET / settimeofday）執行 ntp_clear() → maxerror 瞬間 16s + STA_UNSYNC — NTPSynchronized 對「本地 step」是即時偵測器
- Status: confirmed
- Tier: T3（E-07i 實測）；T1 佐證 = linux kernel timekeeping ntp_clear() 路徑
- Origin: E-07(i) prediction violation（預測 8.9h 盲 → 實測 3min firing）
- Evidence: EVIDENCE-LOG.md E-07(i)：step +100ms 後 maxerror 直跳 16、sync_status=0，
  `CephNodeTimeUnsynchronized` +3min firing。設計含意：Unsynchronized 車道實為
  「本地 step 即時偵測 + 安靜失聯 8.9h 後衛」雙用途；真正的慢速盲區只剩
  「上游緩慢帶偏」（Drift 車道專屬領域）

### H-039: 單次 step 會汙染 timesyncd 的頻率估計（誤判為 freq 誤差）→ 修復後 offset 震盪、錯誤 freq 持續多個 poll 週期
- Status: confirmed
- Tier: T3（E-07i 回退段實測）
- Origin: E-07(i) 回退觀測（timesyncd lab exp1 已知行為的生產參數再現）
- Evidence: freq +14.7ppm → -275.9ppm、offset ±25ms 震盪（EVIDENCE-LOG.md）。
  設計含意：一次 transient step 的可觀測餘波長達數十分鐘 — keep_firing_for 的
  存在價值再添一筆；監控端「修好了」不等於「沒事了」

---

## Matrix 完備性檢核（enumerating-adversarial-boundaries）

| Failure mode | 覆蓋的 hypothesis |
|---|---|
| crash | H-002（daemon 不存在）、H-030（cron 死）|
| slow  | H-006（D-Bus 25s timeout 疊加）、H-020（Ceph 端偵測慢）|
| partial | H-003（部分欄位空）、H-012（部分條件真）、H-032（scope 混入/遮蔽）、H-035（並發互踩）|
| stale | H-005（offset 凍結）、H-004/H-030（textfile 過期）、H-021（mgr 凍結）|
| lying | H-001（parser 把 1min 讀成 1s、n/a 讀成 0）、H-013（把健康訊號讀成故障）、H-015/H-034（upstream 統一說謊、timex 跟著說謊）、H-023（sync=yes 但失聯 8.9h）、H-033（注入自癒 → 實驗自己騙自己）|

**Cross-review 紀錄**：
- Round 2（2026-07-23，機器前交付物）：codex 17 條 findings、NO-GO verdict，全數採納。
  載重項抽查證實：cephadm `--no-collector.timex`（H-037）、textfile series 永不消失
  （H-030 機制修正）、spike 樣本存留（H-036）。修正落地：script heartbeat/chmod 順序/
  age 防倒退/零值 parse、rules 16 條（+DataStale、by(cluster)、alertgroup、snapshot
  車道 for≥5m）、E-00 硬化重寫、alertmanager-inhibition.yml 草稿、results/ 入 .gitignore。
- Round 1（2026-07-23，計畫）：codex 19 條 findings，全數採納；載重反駁（Monitor.cc leader-相對 timecheck、timesyncd
clock-change watcher、BUS_DEFAULT_TIMEOUT、`NTPSynchronized = maxerror < 16s`）已由本
session 對 pinned source 抽查證實。原始輸出見 session 記錄；修正已回寫至各 H 條目
（標「codex 修正/補充」）與 README.md（E-05a、E-07/E-09 注入重設計、L4 回退安全）。

觀測路徑三問（訊號會到嗎／會遲到嗎／會說謊嗎）：textfile 鏈 = H-003/004/030/031；
poll 快照 = H-005/008；kernel timex = H-022；ceph health 鏈 = H-020/021。

Pre-mortem 與 negative-space 各至少一輪：已完成（Origin 欄可查）。
