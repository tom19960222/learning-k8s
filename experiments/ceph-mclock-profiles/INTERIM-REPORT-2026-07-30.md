# Ceph mClock profile 對照實驗 — 階段性報告（INTERIM）

> **這不是最終報告。** campaign 仍在真機上執行中（本報告快照時間 **2026-07-30T02:45Z**，
> 最後一筆 journal 活動 2026-07-30T02:19Z）。矩陣 152 個 execution 中已定案 83、
> 待跑 65、等人工裁示 4。凡標 ⏳ 的區塊**沒有結論**，讀者不得把「已定案」段落的
> 數字外推到未完成的區塊。
>
> 資料來源：`experiments/ceph-mclock-profiles/results/`（每個數字都能指回具體檔案，
> 各節內文附路徑）。方法論：`skills/researching-system-behavior/SKILL.md` +
> `skills/writing-experiment-reports/SKILL.md`。
> 上位文件：spec `docs/superpowers/specs/2026-07-24-ceph-mclock-profiles-azure-design.md`（rev 9）、
> campaign plan `docs/superpowers/plans/2026-07-25-ceph-mclock-profiles-campaign.md`、
> 假說帳本 `experiments/ceph-mclock-profiles/HYPOTHESES.md`。

---

## 0. 讀者需知（名詞 primer）

看這份報告需要的最少背景，每個 2–3 行：

- **mClock / profile**：Ceph OSD 的 IO scheduler。三個內建 profile（`balanced` /
  `high_client_ops` / `high_recovery_ops`）用 (reservation, weight, limit) 三元組
  分配「client IO」與「recovery（資料修復）IO」的比重。本實驗就是量這三個 profile 的實際差異。
- **PG（placement group）**：Ceph 把物件分桶的單位。`up` set = CRUSH 演算法說這個 PG
  應該放在哪幾顆 OSD；`acting` set = 目前實際服務它的 OSD。兩者不一致通常是暫態，
  持續不一致就是異常（本報告的頭牌發現就是這種）。
- **degraded**：物件副本數不足的比例。**censored（右設限）**：量測在恢復完成前撞到
  時間上限（cap），只知道「恢復時間 > cap」，是有效觀測不是失敗。
- **p99 劣化比（p99 degradation ratio）**：故障期間的 p99 latency ÷ 同一次量測注入前
  60 秒健康窗的 p99。**只能在同壓力等級內比較**（原因見 §7 陷阱一）。
- **stall / brownout**：stall = fio 逐秒 log 中「該秒完成 IO 數 = 0」的連續秒數；
  brownout = 吞吐嚴重低於目標的秒數。
- **taint / needs-human**：taint = 該次量測的觀測完整性不合格、作廢重試；同一
  replicate 連續 3 次 taint 轉 **needs-human**（跳過、等人工裁示）。
- **replicate / cell / execution / bundle**：cell = 一個參數組合（故障型 × 壓力 ×
  profile）；每個 cell 跑 n 個 replicate；一次 replicate = 一個 execution；
  bundle = 一次 execution 落地的證據目錄（fio log、叢集快照、判定產物）。
- **immediate class / best_effort class**：mClock 只仲裁「client」與
  「background_recovery」兩類的相對比重；**peering（PG 故障後重新協商）與 replica
  寫入走 `immediate` class，完全繞過 mClock**——所以故障瞬間的凍結不受 profile
  控制。`background_best_effort`（例：非 degraded 的回歸 backfill）則只有 limit
  上限、沒有保障。
- **laggy（laggy_probability）**：mon 對「常 flap 的 OSD」累積的歷史印象值，
  影響 down→auto-out 的等待；48 小時內不自然歸零，是 flapping cells 之間的已知殘留。

---

## 1. 前提（premises）

### 1.1 受測系統（SUT）

| 項目 | 值 | 證據 |
|---|---|---|
| Ceph | **v19.2.2**（cephadm 容器部署） | `results/env/env-cluster.json` |
| 叢集 | Azure japanwest，15 VM：8× L8s_v3 OSD node（8 vCPU / 64 GiB / 1.92 TB local NVMe，各 1 OSD）+ 3 mon + 4 fio client（D4s_v5） | spec §3.1、`results/env/env-provision.json` |
| OS / kernel | Ubuntu 22.04.5 (jammy) / **6.8.0-136-generic**（HWE，對映生產 krbd datapath） | `results/env/env-provision.json` |
| 資料路徑 | 4 台 client 以 **krbd** map RBD image 打 fio | spec §3.1 |
| 拓撲 | replica 3、failure domain = **rack**（4 synthetic CRUSH racks × 2 nodes） | spec §3.1 |
| 控制變因 | 全程 `noscrub`/`nodeep-scrub`；`mon_osd_adjust_heartbeat_grace=false` **且** `mon_osd_adjust_down_out_interval=false`；recovery 併發鎖定（`osd_max_backfills=1`、`osd_recovery_max_active_ssd=10`，mClock 模式預設） | `results/env/env-cluster.json` |

### 1.2 capacity 校準（cost model 的分母）

mClock 的 res/lim 是比例，乘上每顆 OSD 鎖定的名義 capacity 才變成實際額度。

- **per-OSD osd bench（4K randwrite）**：8 顆 6,057–6,646 IOPS，
  平均 **6,439**，跨顆 **CoV 3.19%**（gate 上限 20%，遠低於 → 裝置同質性成立）。
  全部 `accepted`、鎖定來源 = bench。（`results/capacity-lock.json`、`capacity-provenance.json`）
  > **2026-08-07 更正**：原文寫「走完整 OSD stack」與下一項的「BlueStore + replication
  > stack 的通過量」皆為誤述。`OSD::run_osd_bench_test` 直接 `queue_transaction` 到
  > `coll_t::meta()`，**不經 messenger / PG / replication / op scheduler**；計時段是
  > 3,000 個 4 KiB op、約 0.47 秒。此值系統性低估，以收官報告 §2.2 為準。
- **raw NVMe 4K randwrite（不經 Ceph）**：276,735–304,158 IOPS——osd bench 量的是
  BlueStore 單一 sequencer 的單執行緒通過量，兩者差 ~45× 不代表 osd bench 量錯，
  但也不代表它等於這顆 OSD 的服務能力（見上方更正）。
- **叢集 4K randrw 70/30 ceiling**：**63,634 IOPS**（3 輪 63,232–64,942）；
  **1M seq write ceiling：2,374 MiB/s**（3 輪幾乎重合）。（`results/calibration.json`）

### 1.3 負載矩陣（planned = 63 cells / 147 base executions）

| 區塊 | 內容 | n | executions |
|---|---|---|---|
| A 穩態 | 3 profile × 4 壓力（低/中/高/極端）× 2 形態（4K randrw 70/30、1M seq write） | 3 | 72 |
| B 故障主軸 | 3 profile × 3 壓力 × 3 故障型（osd-down / flapping / rack-isolation），4K | 2 | 54 |
| C node loss 變體 | 3 profile × 中壓 × network-isolation | 2 | 6 |
| D large-IO contention | 3 profile × {中,極端} × osd-down × 1M seq | 2 | 12 |
| E chaos | 3 profile × 極端壓 × 固定 seed | 1 | 3 |

壓力等級的固定速率（校準產物）：4K 低 15,908 / 中 31,817 / 高 50,907 IOPS、
極端 = closed-loop（打滿）；seq 低 594 / 中 1,187 / 高 1,899 MiB/s。
校準參考 p99（4K）：低 2.77 ms / 中 3.26 ms / 高 5.73 ms / 極端 46.4 ms。

### 1.4 判準（預註冊，開跑前寫死）

| endpoint | profile 間「有感差異」門檻 | 絕對嚴重度 |
|---|---|---|
| p99 劣化比 | Δratio ≥ 1.0 或相對差 ≥ 50%（取較大） | ≥ 3× = 生產顯著；≥ 10× = 事故級 |
| 最長 IO stall | Δ ≥ 2 s | ≥ 5 s = 事故級；≥ 30 s = guest IO error 風險 |
| recovery bytes/s | 相對差 ≥ 25% | — |
| time-to-recovery | 相對差 ≥ 20% 且絕對差 ≥ 300 s | 超過 cap = censored |

「量不出差異」必須二分為 **equivalent**（噪音 < 門檻，真的等效）或
**underpowered**（噪音 ≥ 門檻，靈敏度不足、禁止寫成「沒差」）。
（`HYPOTHESES.md` §預註冊生產門檻、`results/margins.json`）

### 1.5 可信度防線

- **穩態噪音底線**（71 個穩態 bundle 的同 cell 內離散度）：p99 劣化比 ±0.066
  （相對 **±3.3%**）、最長 stall ±0.24 s。（`results/margins.json`）
- **prediction freeze**：每個 execution 開跑前把 cell 參數凍進 bundle
  （sha256 不可變）；方向性預測母版在 `HYPOTHESES.md` §Cell 預測骨架。
- **negative control**：穩態區塊本身就是「profile 不應有差」的對照組（§4.1）。
- 故障 cell 的量測完整性由 coverage supervisor 把關，不合格即 taint 作廢。

---

## 2. 進度快照與對帳（2026-07-30T02:45Z）

**帳目**（`lib/manifest.py view`，含 amendments merge 視圖）：

```
base 147 + rescue-replicate 5 = 152 total
= done 83 + pending 65 + needs-human 4 ✓
```

| 區塊 | 已定案 | 待跑 / 等裁示 | 狀態 |
|---|---|---|---|
| A 穩態 4K（36） | 36 | 0 | ✅ 完成 |
| A 穩態 seq（36） | 35 | 1 needs-human（`none-seq-high+high_recovery_ops/r1`） | ✅ 實質完成（71/72） |
| B osd-down（18） | 1（pilot） | 17 | ⏳ |
| B flapping（18+5 rescue = 23） | 8 | 12 pending + 3 needs-human | ⏳ 進行中（現在正在跑的就是它） |
| B rack-isolation（18） | 1（pilot） | 17 | ⏳ |
| C node-isolation（6） | 1（pilot） | 5 | ⏳ |
| D seq-contention（12） | 1（pilot） | 11 | ⏳ |
| E chaos（3） | 0 | 3 | ⏳ 未開始 |

- 5 筆 rescue-replicate（追加的替補 replicate，`results/schedule-amendments.json`）
  全部在 flapping：3 筆是 needs-human 後根因修復的替補、2 筆是
  `verdict.py need-more-n` 判定證據不足追加的 r3（cap 升 5400 s，想看 flapping 的
  恢復到底會不會結束——目前全部 censored 在 2700 s）。
- 4 筆 needs-human 明細在附錄 A。
- **剩餘時程粗估**：故障 execution 單筆 ≈ 注入 + 量測（cap 2,700–5,400 s）+
  回歸 backfill + 900 s 固定 overhead ≈ 1.3–2 h；65 筆序列執行 ≈ **85–130 h
  wall-clock（約 4–6 天）**。這是手算粗估（`schedule-estimate.json` 的
  `estimated_remaining_hours` 目前為 null），僅供排程參考，不是承諾。
- **本報告只對 ✅ 區塊與 4 個故障 pilot 下「已定案」敘述；⏳ 區塊只報既有 replicate
  的描述性數字，不做三 profile verdict**（正式 verdict 要等 cell 的全部 replicate 齊）。

---

## 3. 規劃總覽表（每個規劃中的實驗一列）

標記：✅ 預測命中｜❌ 預測被推翻｜➖ 等效/量不出｜⏳ pending。
「調的參數」都是 `osd_mclock_profile` ∈ {balanced, high_client_ops, high_recovery_ops}，
變的是它作用的情境。

| # | 情境（形態×壓力×故障） | 為何測 | 事前預測（凍結於 HYPOTHESES.md §Cell 預測骨架） | 結果 |
|---|---|---|---|---|
| A-1 | 4K × 4 壓力 × 無故障 | negative control：無 recovery 競爭時 profile 不應有差（client limit 三者皆 max） | 三 profile indistinguishable(equivalent) | ✅ **命中**（§4.1：IOPS 差 0.03–0.48%、p99 差 0.34–1.45%） |
| A-2 | 1M seq × 4 壓力 × 無故障 | 同上，大 IO 形態 | 同上 | ✅ 命中（§4.2；p99 離散較大但遠低於門檻） |
| B-1 | osd-down × 低/中/極端 | reservation 是否 binding 隨壓力分層（H-005） | 低壓等效；中壓 high_recovery_ops 劣化；極端完整分離 ≈ res 比 | ⏳ 只有 pilot 1 筆（§4.3） |
| B-2 | flapping × 低/中/極端 | peering 走 immediate class，stall 應與 profile 無關（H-007） | max stall 三者 indistinguishable；p99 分離度 < 同壓力 osd-down | ⏳ 8/22 筆；**初步觀測與預測方向相左，見 §4.4（未定案）** |
| B-3 | rack-isolation × 低/中/極端 | 最大 backfill footprint，profile 分離應最大（H-023） | 極端壓分離最大、最可能 censored | ⏳ 只有 pilot 1 筆 |
| C | node-isolation × 中壓 | 與 osd-down 同 footprint、只差故障路徑（H-020） | 以 down-epoch 對齊後與 osd-down 中壓等效；判 down 延遲 20–30 s vs <5 s | ⏳ 只有 pilot 1 筆 |
| D | 1M seq × osd-down × 中/極端 | client res 換算成頻寬遠高於實際可達 → 不 binding（H-004/H-006/H-014） | 六 cells 全部 indistinguishable | ⏳ 只有 pilot 1 筆 |
| E | chaos × 極端 × 3 profile 同 seed | showcase，n=1 不做嚴格 verdict | 累積 stall：high_client_ops < balanced < high_recovery_ops | ⏳ 未開始 |
| （附帶） | 回歸 backfill 時長（每個故障 replicate 免費附帶，H-008） | 全實驗唯一 best_effort limit 會 binding 的場景 | high_recovery_ops < balanced < high_client_ops ≈ 1 : 1.11 : 1.43 | ⏳ 初步 flapping 資料**看不出分層**（§4.4 末），未定案 |

對帳：planned 147 + rescue 5 = 152 = done 83 + pending 65 + needs-human 4。
目前**沒有** descope（`counts.descoped = 0`）、沒有被砍的實驗。

---

## 4. 已定案結果（逐實驗五欄）

### 4.1 穩態 4K —— negative control（36/36 定案）

- **調的參數**：`osd_mclock_profile` 三值 × 4 壓力等級（固定速率 15,908 / 31,817 /
  50,907 IOPS + closed-loop 極端壓），4K randrw 70/30，n=3。
- **為什麼測**：讀碼結論（H-001/H-002）說三 profile 的 client limit 都是 max、
  無 recovery 競爭時 reservation 只是下限——所以穩態「不應該」有差。任何超過門檻的
  差異都代表有未受控變因，故障區塊的結論就不可信。這是整場 campaign 的地基。
- **事前預測**：三 profile indistinguishable(equivalent)。
- **結果（✅ 命中）**：36 bundle 全數 finalize、0 taint、0 censored。三 profile 的
  cell 平均（各 n=3，來源 = 各 bundle `aggregate.json`）：

  | 壓力 | IOPS（bal / h_cli / h_rec） | 最大差 | p99 ms（bal / h_cli / h_rec） | 最大差 |
  |---|---|---|---|---|
  | 低 | 15,427 / 15,368 / 15,410 | 0.38% | 2.31 / 2.31 / 2.29 | 0.95% |
  | 中 | 30,701 / 30,848 / 30,780 | 0.48% | 3.23 / 3.24 / 3.23 | 0.34% |
  | 高 | 49,249 / 49,400 / 49,331 | 0.31% | 6.11 / 6.04 / 6.02 | 1.45% |
  | 極端 | 60,421 / 60,415 / 60,402 | **0.03%** | 52.9 / 53.4 / 53.6 | 1.32% |

  所有差異都在噪音底線（p99 ±3.3%）內、遠低於 production margin（Δratio ≥ 1.0）。
  極端壓三 profile 都打到 ~60.4k IOPS（= ceiling 的 95%）。
- **建議**：**無故障的叢集上，切這三個 profile 對 client IO 沒有可量測的影響**
  （適用條件：4K randrw、無 scrub/snap trim、v19.2.2 classic OSD）。
  可以放心在生產離峰先切 profile、等故障場景的結論再決定值。

### 4.2 穩態 1M seq（35/36 定案；`none-seq-high+high_recovery_ops` n=2）

- **調的參數**：同上，形態改 1M seq write（594 / 1,187 / 1,899 MiB/s + closed-loop）。
- **為什麼測**：cost model 對大 IO 的計價不同（1M = 4K 的 17.9 倍成本），要確認
  negative control 在大 IO 世界也成立。
- **事前預測**：同 A-1，indistinguishable(equivalent)。
- **結果（✅ 命中，附噪音註記）**：IOPS 最大差 0.30–1.58%。p99 的組間差較大
  （低壓 9.1%、中壓 11.6%），但同 cell 內 replicate 的 p99 離散本來就到 ~16%
  （例：seq-mid balanced 三個 replicate p99 = 18.7 / 20.3 / 25.3 ms），
  組間差 < 組內噪音 → 仍判 equivalent（且遠低於 production margin）。
  極端壓三 profile 都到 ~2.2k MiB/s（ceiling 2,374 的 ~93%）。
- **建議**：同 4.1。附帶：seq 形態的 p99 天生比 4K 抖，後續故障區塊 D 的判讀
  要用這裡的噪音當底線，不能拿 4K 的 ±3.3% 去套。
- **勘誤（H-024，已結案）**：穩態期間 seq/high 的 taint 曾集中在
  `high_recovery_ops`（8 次 vs 0/1 次），一度懷疑是 profile 行為。**查證結果是
  harness 的量測窗尾端競態 + 重試回饋迴圈放大，與 mClock 無關**——詳見 §7 陷阱二。

### 4.3 四個故障 pilot（各 1 筆定案；全部 `high_client_ops`）

pilot 的目的是推導各故障型的量測時間上限（cap），**不是** profile 對照——四筆都是
同一個 profile，**互相之間也不可比 p99 劣化比（壓力等級不同，見 §7 陷阱一）**。

| 故障型 × 壓力 | p99 劣化比（前→後） | 最長 stall | 恢復耗時 | recovery 速率 | bundle |
|---|---|---|---|---|---|
| osd-down × 4K 極端 | **1.093**（50.6→55.3 ms） | 20 s（總 59 s） | 953 s | 400.6 MB/s | `results/osd-down-4k-extreme+high_client_ops/r1/attempts/20260728T051910Z` |
| node-isolation × 4K 中 | **8.618**（3.39→29.2 ms；down-epoch 對齊 8.386） | 25 s（總 72 s） | 645 s | 531.6 MB/s | `results/node-isolation-4k-mid+high_client_ops/r1/attempts/20260728T124651Z` |
| rack-isolation × 4K 極端 | **1.568**（48.5→76.0 ms） | 23 s（總 86 s）；單筆 IO 最長 17.1 s | 1,139 s | 892.3 MB/s | `results/rack-isolation-4k-extreme+high_client_ops/r1/attempts/20260728T075920Z` |
| seq-contention × seq 極端 | **1.012**（90.7→91.8 ms） | 20 s（總 79 s） | 1,575 s | 231.4 MB/s | `results/seq-contention-seq-extreme+high_client_ops/r1/attempts/20260728T142932Z` |

- **五欄**：調的參數 = 故障型（profile 固定 high_client_ops）；為何測 = 推 cap；
  預測 = H-023「rack 極端是最慢組合」；結果 = **恢復耗時最長的是 seq-contention
  （1,575 s）而非 rack（1,139 s）**，cap 因此只對 seq-contention 上調
  （2,700 → 3,150 s，`results/schedule-amendments.json` seq 7），其餘維持 2,700 s。
  H-023 的「rack 最慢」預測**在 pilot 層面沒有成立**（❌ 方向初步存疑，
  但 n=1、且 H-023 講的是 time-to-recovery 全矩陣比較，要等全佇列定案）。
- **已定案的絕對嚴重度（限這四筆 pilot 本身）**：最長 stall 全部 20–25 s，
  **全部超過事故級門檻（≥ 5 s）**、逼近 guest IO error 風險（≥ 30 s）。
  機制上（H-007）這段凍結來自 peering / 判 down 的窗口，走 immediate class、
  繞過 mClock，**預期與 profile 無關——但這是機制預測，profile 無關性要等 B 區塊
  三 profile 對照定案才算驗證**。旁證：flapping 已有的 8 筆（三個 profile 都有）
  最長 stall 同樣落在 20–26 s。適用條件：4K/seq 高壓與極端壓、krbd datapath；
  低壓 cells 還沒跑。

### 4.4 flapping 初步資料（⏳ 未定案——8/23 筆，判讀凍結至 cell 補齊）

**這一節是描述性快照，不是 verdict。**（6 個 cell 有資料、其中 4 個 cell 只有單筆）

- **調的參數**：`osd_mclock_profile` × {低,中} 壓（極端壓 r1 needs-human）×
  10 輪 stop/start 同一顆 OSD（`no_out`，每輪等 PG active gate）。
- **為什麼測**：flapping 是 log-based recovery 的代表場景；H-007 預測 stall 與
  profile 無關、p99 分離度小於 osd-down。
- **事前預測**：max stall 三 profile Δ < 2 s；p99 劣化比分離 < 同壓 osd-down。
- **目前觀測**（各 bundle `aggregate.json`；**全部 censored**——2,700 s 內
  recovery 沒有一次自己完成）：

  | cell | p99 劣化比 | 最長 stall | 最長單段 brownout（`max_brownout_seconds`） |
  |---|---|---|---|
  | 低壓 balanced（r2） | 649.4 | 23 s | 308 s |
  | 低壓 high_client_ops（r2） | 497.7 | 24 s | 393 s |
  | 低壓 high_recovery_ops（r1, r2） | 328.6 / 519.4 | 26 / 22 s | 444 / 448 s |
  | 中壓 balanced（r1） | 159.1 | 25 s | 319 s |
  | 中壓 high_client_ops（r1） | 95.2 | 22 s | 322 s |
  | 中壓 high_recovery_ops（r1, r2） | 136.4 / 139.0 | 20 / 22 s | 460 / 313 s |

  三件事已經可以說（因為與 profile 對照無關）：
  1. **flapping 的傷害量級與其他故障型完全不同**（對照組目前只有 n=1 的 pilot，
     量級差距大到不受此限，但精確倍數要等定案）：劣化比跨壓力不可比，改看絕對值——
     flapping 的故障窗 p99 在 0.3–1.6 **秒**量級，osd-down 極端壓 pilot 是 55 ms；
     最長單段 brownout 300–460 秒（brownout 總量 1,479–2,107 秒，含注入期，
     各 bundle `total_brownout_seconds`）vs osd-down 的 0 秒（單段與總量皆 0）。
  2. **8 筆全部 censored**：flapping 之後 recovery 在 45 分鐘內從未自行完成
     （成因見 §5 頭牌發現——PG 卡死，不是「恢復慢」）。追加的 r3（cap 5,400 s）
     正在驗證上界。
  3. 低壓的 `high_recovery_ops` 兩個 replicate 劣化比差 1.6 倍（328.6 vs 519.4）
     ——同 cell 內離散極大，**這正是不能拿單筆做 profile 結論的理由**。
- **對 H-007 的初步壓力**：stall 部分（20–26 s，Δ ≤ 6 s）尚無法判定；但「flapping
  的 p99 分離度小於 osd-down」這個預測目前**方向堪憂**——不過真正的比較要等
  osd-down 同壓力 cells 跑完才有對照組。**不在本報告定案。**
- **回歸 backfill（H-008 附帶量測）**：flapping 的 return-backfill 時長
  balanced 899/1,036 s、high_client_ops 878/936 s、high_recovery_ops 879–950 s
  ——預測的 1 : 1.11 : 1.43 分層**初步看不到**（❌ 方向存疑，等更多故障型回填；
  若最終不成立，代表回歸 backfill 的瓶頸不是 best_effort limit 而是
  `osd_max_backfills=1` 或裝置，H-008 的證偽條件本來就涵蓋此分支）。

---

## 5. 頭牌發現（已定案）：flapping 後 PG 可能卡死在 recovering（已重現兩次），client IO 無限期 hang，而且監控幾乎全盲

**這是本 campaign 目前最有生產價值的發現，且已重現兩次**（H-029 於
2026-07-28、H-033 於 2026-07-29；證據 `results/evidence/H033-*.json` 與
`HYPOTHESES.md` H-029/H-033 全文）。與 mClock profile 無關——它是 flapping
這個故障型本身的 Ceph 行為。此外 evidence 目錄還有兩筆後續 PG query 快照顯示
**相同指紋再度出現**（`H033-3rd-pg-2.1d-*`：2026-07-29T17:41，`up=[3,6,0]` /
`acting=[3,6]`；`H033-4th-pg-2.6d-*`：2026-07-29T19:40，`up=[7,4,0]` /
`acting=[7,4]`，皆 `active+recovering+undersized+degraded+remapped`）——帳本
未對這兩筆展開完整分析，故本節保守口徑為「完整分析重現 2 次、相同指紋另擷取 2 次」。

**現象結構**（兩次完全相同）：

1. 10 輪 stop/start 同一顆 OSD 之後，某個 PG 停在
   `active+recovering+undersized+degraded+remapped`：被 flap 的 OSD **進得了 up set、
   永遠進不了 acting set**（第一次 `up=[4,1,2]` / `acting=[4,1]`，
   第二次 `up=[7,4,0]` / `acting=[7,4]`）。primary 的 recovering 清單卡住 2–3 個
   物件，永不完成（卡了 115 分鐘直到人工介入）。
2. 打到那些物件的 **client read 無限期阻塞**：`dump_blocked_ops` 顯示
   `flag_point: "waiting for rw locks"`，第一次 age 5,413 s、第二次 23 個 op 阻塞
   2,796 s（帳本記錄值；evidence 快照 `H033-osd7-blocked-ops-*.json` 收檔時最舊
   age 已達 2,890 s，仍在增長中）。第二次更嚴重：一台 fio client 整個 hang 死
   28 分鐘（krbd IO 落在卡住的物件上，kernel D-state），**且 46 個 PG 排在
   recovery_wait 全部被這一個 PG 堵住**。
3. **監控幾乎全盲**：第一次事故（H-029）的終態 degraded 比例 **0.000%**
   （2/921,651 物件）——任何以 degraded 百分比為門檻的告警都不響；health 只有
   一行看似無害的 `PG_DEGRADED`。第二次事故的快照（`H033-status-*.json`）因
   46 個 PG 還堵在 recovery_wait，degraded 反而顯示 **12.037%**——但那看起來就是
   「recovery 正常進行中」，一樣不會指向卡死的 PG。兩次共通點：唯一大聲的
   `SLOW_OPS` 點名的都是 **PG primary（受害者）**，不是被 flap 的肇因 OSD。
4. **解法一行**：`ceph pg repeer <pgid>` —— 瞬間恢復（acting 補齊、slow ops 全消），
   不需重啟任何 daemon。重啟 OSD / 重開機在本案**無效**（第一次事故中 watchdog
   重開了一台無關節點，見附錄 B）。

**營運建議（可直接執行）**：

1. 告警加一條「**PG 非 active+clean 持續 N 分鐘**」（建議 N=15，涵蓋正常 backfill
   的暫態；規則放在既有 Prometheus rules 的 PG 健康群組旁）。第一次事故在
   degraded% 門檻下完全靜默；第二次雖有 degraded 12% 但外觀與正常 recovery 無異
   ——這條是唯一能精準抓到「卡死本身」的訊號。
2. `SLOW_OPS` 的排查 runbook 要加一句：**被點名的 OSD 可能是受害者**。先查卡住 PG 的
   `up` vs `acting` 差異回推肇因，不要直接動被點名那顆。
3. recovery 停滯的第一個處置改成 `ceph pg repeer <pgid>`（便宜、精準、不動 daemon），
   **但只對 `recovering`/`peering`/`activating`/`stale`/`incomplete`/`down`/`unknown`
   狀態的 PG 下手；`backfill_wait`/`backfilling` 的 PG 絕對不要 repeer**——那會把
   已完成的 backfill 進度打掉重來（本 campaign 的 watchdog 在真機資料上驗證過這條
   allowlist 的必要性）。

---

## 6. 其他營運發現

- **（已定案）systemd 會在 OSD flapping 第 5 次後放棄重啟（H-025）**：cephadm 產生的
  OSD unit 帶 `StartLimitInterval=30min` / `StartLimitBurst=5`。生產上 OSD 反覆
  flap 時，第 5 次之後 systemd 直接拒啟（`start-limit-hit`），OSD 保持 down 直到
  人工 `systemctl reset-failed`。監控只會看到「OSD down」，根因卻是速率限制——
  排查方向完全不同。診斷特徵：`systemctl status` 的 Exec 步驟全部 `0/SUCCESS`。
- **（⏳ pilot 初步，方向一致）判 down 延遲依故障型不同（H-020）**：daemon stop 有
  `MOSDMarkMeDown`（OSD 關閉前主動通報 mon 的訊息）幾乎立即判 down；網路隔離要等
  heartbeat grace（~20 s）。node-isolation pilot 的劣化比以「mon 實際判 down 的
  OSDMap 版本（down-epoch）」對齊後從 8.618 修正為 8.386——跨故障型比較一律要用
  down-epoch 對齊的欄位。

---

## 7. 兩個解讀陷阱（讀本報告任何數字前必讀）

### 陷阱一：p99 劣化比只能在同壓力等級內比較

劣化比的分母是「注入前健康窗的 p99」。**低壓 cell 被限速，健康 p99 極小**
（低壓 ~2.3 ms、中壓 ~3.3 ms），極端壓 closed-loop 的健康 p99 本來就是 ~50 ms。
同樣一段絕對劣化，在低壓 cell 會被放大成巨大的比值。實例（皆本 campaign 定案資料）：

- node-isolation（**中壓**）劣化比 8.6，故障窗 p99 = **29 ms**；
- osd-down（**極端壓**）劣化比 1.09，故障窗 p99 = **55 ms**。

只看比值會得出「node-isolation 傷害大 8 倍」，看絕對值卻是 osd-down 的故障窗
p99 比較高——**跨壓力比劣化比會得到相反結論**。flapping 的 649（低壓）vs 159（中壓）
同理：不代表低壓下 flapping 更傷。本報告所有 profile 對照都只在同壓力組內做；
跨壓力請看絕對 p99 與 stall 秒數。

### 陷阱二：H-024 的 taint 集中「不是」profile 差異（已結案勘誤）

穩態 seq/high 曾出現 taint 高度集中在 `high_recovery_ops`（8 次 vs 0/1 次），
表面看像 profile 行為。查證結果：taint 的判準與「coverage supervisor 最後一次檢查
落在 fio 結束之前或之後」一刀兩斷完全對齊——是**量測窗尾端的競態**（fio 結束後
心跳自然停止被誤記成缺口），與 mClock 無關。而它看起來集中在一格，是因為
**taint 觸發 retry、retry 又是一次擲骰子**——先中的那格會被回饋迴圈放大，
統計「哪格 taint 最多」時分母不是固定的。（`HYPOTHESES.md` H-024 結案記錄）

**規則**：後續任何「某 profile 的 taint / 異常比較多」的觀察，都必須先排除
重試回饋迴圈與分母不固定，才准寫進結論。

---

## 8. 參數與營運建議總表（interim）

| 參數 / 規則 | 建議值 | 依據 | 效果量 | 變更成本 |
|---|---|---|---|---|
| `osd_mclock_profile`（穩態叢集） | 三者皆可，切換無風險 | §4.1/4.2（71 bundle） | 差異 ≤ 0.5% IOPS / ≤ 1.5% p99（4K） | runtime（`ceph config set osd`，免重啟） |
| `osd_mclock_profile`（故障期間該選誰） | **尚無結論——等故障矩陣定案** | B/C/D 區塊 ⏳ | — | — |
| 告警：PG 非 active+clean 持續 N 分 | **新增**，N=15 分鐘起 | §5（H-029/H-033，兩次重現） | 第一次事故 degraded=0.000%、其他訊號全靜默時的唯一有效訊號；未加 = 115 分鐘全盲 | alert rule 一條 |
| SLOW_OPS runbook | 加「被點名者可能是受害者；先查 up/acting 差」 | §5 | 第一次事故中照舊 runbook 會去修錯的 OSD | 文件 |
| recovery 停滯處置 | 第一步 `ceph pg repeer`——**僅限 §5 的狀態 allowlist；`backfill_wait`/`backfilling` 的 PG 絕不可 repeer** | §5 | 卡 115 分 → 秒級恢復；對 backfill 中 PG 誤用會把已完成進度打掉重來 | 指令一行 |
| systemd OSD unit 的 start-limit | 監控加 `start-limit-hit` 偵測；排障記得 `reset-failed` | §6（H-025） | flap ≥ 5 次後 OSD 永久 down 直到人工介入 | 監控規則 |
| 故障期間 client IO 凍結預期 | 容量規劃按「單一故障 = 20 s 級 stall」設定上游 timeout（**pilot 初步值：n=1、單 profile、低壓未測；故障矩陣定案後更新**） | §4.3（四 pilot 全部 ≥ 20 s）+ §4.4 旁證 | 20–26 s > 事故級門檻 5 s | 架構層 |
| capacity 鎖定流程 | 鎖定值 ≠ 21500（compiled default）、`skip_benchmark=true` | H-012 讀碼 + calibrate 實行 | 防每次重啟 re-bench 漂移 | 部署腳本 |

---

## 9. 被推翻／方向存疑的預測（最高價值清單）

| 預測 | 狀態 | 說明 |
|---|---|---|
| H-023「rack 極端是全矩陣最慢恢復」 | ❌ pilot 層面未成立（n=1，未定案） | seq-contention 1,575 s > rack 1,139 s；cap 因此只上調 seq-contention |
| H-007「flapping p99 分離度 < osd-down」 | ⚠️ 初步方向堪憂（未定案） | flapping 劣化量級遠超 osd-down pilot；等同壓對照組 |
| H-008「回歸 backfill 呈 1 : 1.11 : 1.43 分層」 | ⚠️ 初步看不到分層（未定案） | flapping 的 return-backfill 三 profile 相近（878–1,036 s） |
| H-024「taint 集中 = profile 效應」 | ❌ **已結案推翻** | 是 harness 競態 + 重試放大（§7 陷阱二） |
| 「flapping 只是恢復變慢」（隱含假設） | ❌ 在已觀測的 8 筆中推翻（2,700 s 內 8/8 censored；兩次確認為 PG 卡死需人工 repeer，§5） | 是否為系統性「永不結束」待 r3（cap 5,400 s）定案，見 §12.1 |

---

## 10. 方法論可信度附錄：harness 缺陷帳（全部 confirmed + mutation 驗證 + 已修）

真機階段抓到的量測儀器缺陷全數記錄在 `HYPOTHESES.md`（H-026、H-027、H-028、
H-030、H-031、H-032、H-034、H-035、H-036），每筆都有「會紅的測試 → 修 → 綠」與
mutation 驗證（把缺陷放回去測試必須變紅）。對讀者的意義擇要：

- **H-031**：第一個故障 cell 的兩個主指標曾是 null（baseline 窗被夾成零寬 +
  recovery 時戳沒落盤）——pipeline 全綠但主指標是空的。已修，且所有已定案 bundle
  重新產出過。教訓：「跑完了」≠「量到了」。
- **H-034→H-035**：一次完整的「歸因錯誤」記錄——先修了真實但非決定性的因素
  （supervisor 抖動），現象沒消失，才找到真因（flapping 注入的 9 分鐘全程沒人打卡）。
  修正後 coverage gap 從 484–560 s 降到 0。
- **H-030**：watchdog 曾在「八顆 OSD 全 up」時盲選重開一台無關的健康節點——
  自動修復的目標選擇與修復動作同樣需要驗證。
- **H-027/H-032/H-036**：三次「修 A 壞 B」的共用機制迴歸，共同教訓 =
  改 chokepoint 時要問「誰還會走到它」與「它的生命週期到哪結束」。

穩態資料的可信度證據：negative control 全綠（§4.1）、margins 的敏感度判定
p99/stall 兩個 endpoint 皆 `adequate`（`results/margins.json` sensitivity 欄）。
其中 `recovery_bytes_per_sec` / `time_to_recovery` 的噪音底線要等故障 replicate
補齊才有（穩態沒有 recovery 流量，margins 的 `noise_fault` 目前是 null）。

**Incidents（誠實記錄）**：兩次 baseline-drift 誤報停佇列（2026-07-27，成因 =
參考基準條件不可比，已改判準後 unhalt 並歸零計數）；一次 watchdog 誤重開健康節點
（H-030）；margins 產出時穩態是 71/72（needs-human 1 筆排除在外，runner 因此
FATAL 過一次，margins 在 amendment 落帳後重跑產出）。全部留痕於
`results/watchdog-state.json` 的 `unhalt_log` 與 `results/schedule-amendments.json`。

---

## 11. Limitations（本階段）

1. **故障面的 profile 對照全部未定案**——這是本實驗的主要研究問題，目前只有
   pilot（全部 high_client_ops）與部分 flapping。任何「該選哪個 profile」的問題
   現在都答不了，§8 表裡那格是空的不是漏寫。
2. **絕對數字不可跨環境外推**：Azure 單 NIC 12.5 Gbps、雲端 NVMe、synthetic CRUSH
   rack——機制結論（§5、§6、§7）可外推，IOPS/延遲絕對值不行。
3. **flapping 的 profile 比較在 laggy 已飽和的狀態下進行**（H-015：laggy_probability
   48 小時內不歸零，跨 cell 殘留），這是記錄在案的已知混淆，covariate 有收
   （`laggy.json`）但未分析。
4. 穩態 seq 的 p99 噪音（同 cell CoV ~16%）明顯高於 4K，D 區塊判讀時 margin 要用
   seq 自己的底線。
5. `mon_osd_adjust_down_out_interval` 已一併關閉（優於 spec 初版只關 heartbeat
   grace），但 laggy 值本身仍累積——見 3。
6. 校準只做一次（2026-07-26）；72h campaign 的漂移由每 replicate 的 60 s baseline
   復測把關（連續 3 次超標停佇列），至今 drift_streak = 0。

## 12. Open questions 與資料缺口

1. **flapping 追加的 r3（cap 5,400 s）會不會仍 censored？** 若會，「flapping 後
   recovery 永不自行完成」就從個案升級為系統性行為。
2. **node-isolation pilot 的 `return_backfill_duration_s = 1 s`** 可疑（osd-down
   是 6,114 s）——回歸 backfill 的時戳在 isolation 路徑上可能沒接對，收官前要查。
3. **兩個 pilot 的單筆最長 IO 完全相同（17,112,760,320 ns）**——這是 fio latency
   histogram 的 bin 上緣值，代表 `max_ns` 在大延遲區間是量化值，只能當量級讀。
4. ρ（H-005 的壓力換算比）沒有寫進 `calibration.json`（Artifacts 要求有此欄）。
   由鎖定值手算 ρ = 63,634 ÷ (8 × 6,439) ≈ **1.24**，即中壓 ρ×L ≈ 0.62 已落在
   「三 profile 完整分離」的預測分支——故障矩陣跑完就能直接檢驗 H-005。
5. `prediction.json` 的 `expectations` 欄位是空物件——per-bundle 凍結的是 cell
   參數與 manifest hash，方向性預測的凍結載體實際上是 git 裡的 `HYPOTHESES.md`
   §Cell 預測骨架。收官報告引用預測時一律引該節。
6. 一筆已知的 bundle 內部不一致：`none-4k-low+high_client_ops/r1` 的 `verdict.json`
   （18:54 產）殘留修正前的 stall=9 s，其 `aggregate.json`（18:59 重跑）為 0 s；
   margins 與本報告皆以 aggregate 為準。收官 audit 時應重產該 verdict。
7. needs-human 4 筆的裁示（附錄 A）——3 筆已有 rescue replicate 頂上，
   `none-seq-high+high_recovery_ops/r1` 維持 n=2 是否可接受，收官時要具名裁決。

---

## 附錄 A：needs-human 與 rescue 對帳（`results/schedule-amendments.json`）

| execution | 時間 | 原因 | 後續 |
|---|---|---|---|
| `none-seq-high+high_recovery_ops/r1` | 07-27 | 連續 3 次 coverage taint（= H-024 的競態，成因已修） | 該 cell 以 n=2 續行，收官裁決 |
| `flapping-4k-extreme+high_client_ops/r1` | 07-28 | 連續 3 次 preflight-final-clean 失敗（= H-029 PG 卡死事故現場） | rescue replicate 已排入 |
| `flapping-4k-low+balanced/r1` | 07-29 | 連續 3 次 coverage taint（H-034 supervisor 遲到誤 taint） | 成因修復 + rescue replicate（其 r2 已定案） |
| `flapping-4k-low+high_client_ops/r1` | 07-29 | 同上（H-035 注入期間無人打卡） | 成因修復 + rescue replicate（其 r2 已定案） |

另有 2 筆 `need-more-n` rescue（`flapping-4k-low+high_recovery_ops` /
`flapping-4k-mid+high_recovery_ops` 各加 r3，cap 5,400 s）。

## 附錄 B：本報告引用的證據檔案索引

- 帳本 / 帳目：`HYPOTHESES.md`、`results/schedule-amendments.json`、
  `results/watchdog-state.json`、`lib/manifest.py view`
- 校準：`results/calibration.json`、`results/capacity-lock.json`、
  `results/capacity-provenance.json`、`results/margins.json`
- 穩態：`results/none-*/r*/attempts/*/aggregate.json`（71 筆 finalized）
- 故障 pilot：§4.3 表內各 bundle 路徑；cap 推導 `results/schedule-estimate.json`
- flapping：`results/flapping-*/r*/attempts/*/aggregate.json`（8 筆 finalized）
- 頭牌發現：`results/evidence/H033-*.json`（5 檔）+ `HYPOTHESES.md` H-029/H-033
- 環境：`results/env/env-cluster.json`、`results/env/env-provision.json`
