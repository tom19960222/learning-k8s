# ceph-mclock-profiles — Hypothesis Backlog（Phase 1 Frame 產出）

> 方法論：`skills/researching-system-behavior/SKILL.md`（Frame → Enumerate → Falsify → Automate → Synthesize）
> spec：`docs/superpowers/specs/2026-07-24-ceph-mclock-profiles-azure-design.md`（rev 7）
> plan：`docs/superpowers/plans/2026-07-24-ceph-mclock-profiles-harness.md`（v4.2.1）
> 本檔狀態：**Task 1 Step 1–7 完成，等 Step 8 使用者 gate**。

## Charter

- **Goal**：在 Azure 15 台 VM 的 Ceph v19.2.2 叢集上，量出 mClock 三個內建 profile（`balanced` / `high_client_ops` / `high_recovery_ops`）在穩態、四類故障、chaos 下對 client IO 與 recovery 的取捨曲線；所有機制主張錨定 pinned source，所有行為主張錨定 evidence bundle，量不出可信差異的一律標記為「等效」或「靈敏度不足」（兩者必須可區分，見 §預註冊生產門檻）。
- **Scope**
  - **in**：mClock scheduler 的 profile 切換與其九個衍生參數、cost model（`osd_mclock_max_capacity_iops_ssd` / `osd_mclock_max_sequential_bandwidth_ssd`）、mClock 仲裁涵蓋邊界（immediate / high-priority 旁路）、四類故障注入（OSD flapping、OSD down、node loss = network-isolation、synthetic CRUSH-rack loss）、固定 seed chaos、harness 自動化與 evidence bundle。
  - **out**：**任何 profile 以外的 QoS 調參**（九參數手改、`osd_mclock_override_recovery_settings=true`、custom profile）、mon 的故障**注入**（repair 不在此限）、Azure 層調校、cross-environment 絕對數字外推、EC pool、HDD/hybrid、crimson OSD。
  - **明確不主測（標為已知邊界）**：scrub / deep-scrub（campaign 全程 noscrub）、snap trim（無 snapshot）、per-client QoS（v19.2.2 classic OSD 未實作，見 H-022）。
- **Version anchors**
  - Ceph **v19.2.2**（`git -C ceph show v19.2.2:<path>`；repo submodule pin 為 v19.2.3，兩者的 dmclock vendor 內容不同，**嚴禁混用**）。
  - dmclock **`dmclock@e4ccdcfa`**（= `git ls-tree v19.2.2 src/dmclock` 的 gitlink `e4ccdcfa828c84b8ea775a928118f2b8012d0f42`，已比對確認）。
  - 錨點格式：Ceph = `path:line`；dmclock = `dmclock@e4ccdcfa:src/dmclock_server.h:line`。
- **Tiers**
  - **T1**：pinned source（ceph v19.2.2、dmclock@e4ccdcfa）。
  - **T2**：官方文件（docs.ceph.com mClock config reference、Azure SKU/網路文件）。
  - **T3**：Azure japanwest 15-VM campaign（8× L8s_v3 OSD node、1 admin + 2 mon、4 fio client；krbd datapath；replica 3、failure domain = rack）。**全程 ssh-native、可回退**；破壞性動作限本 campaign 專用 RG。
- **本檔的三個用途**（缺一不可）
  1. 六個機制題的 source-anchored 敘述（M-1 … M-6），供報告的「機制」章節直接引用。
  2. 可證偽假說 backlog（H-001 … H-023），每條含 prediction 與證偽條件。
  3. **prediction freeze 的母版**：63 cells 的方向性預測骨架（§Cell 預測骨架）——pipeline 在每個 replicate 開跑前把對應 cell 的預測凍進 bundle。

---

## 預註冊生產門檻（production margin，Task 1 Step 7）

`indistinguishable` 這個 verdict 在 Azure 這種噪音環境裡最危險：它同時可能是「三個 profile 真的等效」或「我們的靈敏度根本不夠」。因此**在看到任何資料之前**先把「生產有感」的絕對門檻寫死；分析時 `verdict.py margins` 同時報 noise margin（觀測 CoV 導出）與下表的 production margin：

| primary endpoint | 定義 | **profile 間 production margin（有感差異）** | **絕對嚴重度門檻** |
|---|---|---|---|
| client p99 degradation ratio | 故障窗 p99 ÷ 同 replicate 注入前 60s 健康窗 p99 | Δratio ≥ **1.0**（例：2.0× vs 3.0×）或相對差 ≥ **50%**，取較大者 | ratio ≥ **3×** = 生產顯著劣化；≥ **10×** = 事故級 |
| max IO stall duration | fio 逐秒 log 中「該秒完成數 = 0」的最長連續秒數 | Δ ≥ **2 s** | ≥ **5 s** = 事故級（使用者標準：關鍵生產系統 IO delay 數秒即事故）；≥ **30 s** = guest 層 IO error 風險 |
| recovery bytes/s | `ceph pg dump` 差分的 recovery+backfill bytes/s（量測窗中位數） | 相對差 ≥ **25%** | — |
| time-to-recovery-complete | `fault_t0` → 當下 up set 下 PG 100% active+clean 的秒數（right-censored 有效） | 相對差 ≥ **20%** **且** 絕對差 ≥ **300 s** | 超過 `measurement_cap` = censored |

**`indistinguishable` 的兩型判別規則（寫死，不得事後改）**：

- **等效（equivalent）**：`|觀測差異| < production margin` **且** `noise margin < production margin`。→ 可以寫「在本環境下三 profile 對此 endpoint 沒有生產意義上的差別」。
- **靈敏度不足（underpowered）**：`noise margin ≥ production margin`。→ **禁止**寫成「profile 沒差」，只能寫「本環境的噪音大於生產門檻，無法回答」，並列入 S3 補跑或 n 升級清單。

補充規則：

- 極端壓（closed-loop）cells 的 p99 不可與固定速率 cells 直接比較（spec §4）；極端壓的 profile 比較只在「同為極端壓」的組內做。
- `recovery bytes/s` 與 `time-to-recovery-complete` 在 censored replicate 上只採後者的下界，前者仍有效。
- 三態 verdict = `confirmed / violated / indistinguishable(equivalent|underpowered)`。

---

## M-1 dmclock 的三段式排程與 `AtLimit::Wait`（Step 1）

**機制**（全部 T1）：

- 每個 dmclock client 由 `ClientInfo{reservation, weight, limit}` 描述，內部同時保存三個倒數 `*_inv`；**任一項為 0 → 對應的 `*_inv` = 0**（`dmclock@e4ccdcfa:src/dmclock_server.h:97-134`，`update()` 在 :113-120）。
- 每個 request 進佇列時算三個 tag（`dmclock@e4ccdcfa:src/dmclock_server.h:137-185`）：`reservation`、`proportion`（weight 用）、`limit`。tag 的遞增量 = `inv × (dist_req_val + cost)`，並對「現在時刻」取 max（`:248-261`）。**關鍵分支：`increment == 0` 時，res/prop 回傳 `max_tag`（+∞）、limit 回傳 `min_tag`（−∞）**（`:254-255`，由 `extreme_is_high` 決定）。
- 出隊決策 `do_next_request`（`dmclock@e4ccdcfa:src/dmclock_server.h:1124-1195`）嚴格三段：
  1. **reservation 階段**：`resv_heap` 頂端的 request 若 `tag.reservation <= now` → 直接出隊（`:1133-1137`）。
  2. **limit → ready 提升**：把 `limit_heap` 裡 `tag.limit <= now` 的 client 提升進 `ready_heap`（`:1144-1153`）。
  3. **weight（proportion）階段**：`ready_heap` 頂端出隊（`:1155-1160`）。
  4. 都不行 → 回傳「未來時間」，等 limit/reservation tag 成熟（`:1179-1194`）。
- Classic OSD 用 **`AtLimit::Wait`**（`src/osd/scheduler/mClockScheduler.cc:137`）→ `:1166-1174` 的「破 limit」分支**不會執行**，超過 limit 的 request 只能等。`anticipation_timeout` 取自 `osd_mclock_scheduler_anticipation_timeout`（`mClockScheduler.cc:138`），預設 **0**（`src/common/options/osd.yaml.in:1090-1095`）→ 無 anticipation 行為。
- **ratio → bytes/s 的轉換**在 `ClientRegistry::update_from_config`（`mClockScheduler.cc:166-224`）：`res=0` → `default_min`、`lim=0` → `default_max`，而 `default_min = 0.0`、`default_max = ∞`（`src/osd/scheduler/mClockScheduler.h:45-47`）。合起來看：
  - **client 三個 profile 的 `lim` 都是 0 → ∞ → `limit_inv = 0` → limit tag = −∞ → 永遠 ready，client class 沒有上限。**
  - **`background_best_effort` 三個 profile 的 `res` 都是 0 → 0.0 → `reservation_inv = 0` → reservation tag = +∞ → best_effort 永遠不會從 reservation 階段出隊**（只能靠第 3 段的 weight 階段）。
- idle client 重新活躍時，其 proportion tag 會被拉到「目前最低的 active proportion tag」（`dmclock@e4ccdcfa:src/dmclock_server.h:946-994`）→ **閒置不累積 credit、也不累積 debt**。

### H-001: 三個 profile 的 reservation 總和都剛好 = 100% 名義 capacity，因此只要實際裝置吞吐低於鎖定的 capacity 值，dmclock 就長期停在 reservation 階段，weight（client wgt 2 vs 1）完全不參與排序 — profile 差異退化成純 res 比值
- Status: proposed
- Priority: P0
- Tier: T1 → T3
- Origin: 讀碼（`do_next_request` 三段式 + profile 表相加 = 1.0）
- Prediction: 在 recovery 與 client 併發、且 client 需求已達 res 門檻的 cells（極端壓）中，client:background_recovery 的實際服務比 ≈ **res 比**（balanced 0.5:0.5、high_client_ops 0.6:0.4、high_recovery_ops 0.3:0.7），而**不是** weight 暗示的 2:1。具體：`high_client_ops` 的 client 吞吐相對 `balanced` 的提升落在 **1.1–1.3×**（0.6/0.5 = 1.2 附近）。
- 證偽條件: 極端壓 osd-down cells 量到 `high_client_ops` client 吞吐 ≥ 1.5 × `balanced` → weight 有參與排序 → violated（代表 reservation 常態被滿足，系統處在 weight regime）。
- Evidence（機制）: dmclock_server.h:1133-1137（reservation 分支優先）、:1155-1160（weight 分支）；mClockScheduler.cc:337-373（三 profile 的 res 相加皆 = 1.0）。
- Artifacts: 每個 replicate 收 `ceph tell osd.N perf dump` 的 `mclock-shard-queue-*` 佇列長度組成（`mClockScheduler.cc:93-114`）作為 regime 判定 covariate。
- Notes: 這條決定整個實驗的解讀框架 — 若成立，「weight」在報告裡必須降級為「幾乎不可觀測的參數」。

### H-002: `background_best_effort` 的 `res=0` 使它永遠進不了 reservation 階段，因此只要 client + background_recovery 的 reservation 已吃滿裝置，best_effort 近乎完全餓死，三 profile 的 best_effort `lim`（90% / 70% / max）差異在中高壓下不可觀測
- Status: proposed
- Priority: P1
- Tier: T1 → T3
- Origin: 讀碼（`default_min = 0.0` → `reservation_inv = 0` → tag = +∞）
- Prediction: 中壓以上的故障 cells 中，best_effort class 的服務量三 profile 皆 ≈ 0（差異 < noise margin）；只有低壓（25%）cells 才可能出現 90/70/max 的分層。
- 證偽條件: 中壓或極端壓 cells 量到三 profile 的 best_effort 吞吐分層符合 90:70:100 → violated。
- Evidence: mClockScheduler.h:45（`default_min = 0.0`）；mClockScheduler.cc:171-177（`get_res`）；dmclock_server.h:117（`reservation_inv = 0`）、:254-255（`increment == 0` → `max_tag`）、:1133-1137。
- Notes: best_effort 在本 campaign 的主要來源 = **非 degraded 的 backfill**（見 H-008），不是 scrub/snap trim（皆已關閉/不存在）。

### H-003: idle client 的 proportion tag 重置機制使「注入前 client 獨占 → 注入後 recovery 湧入」不會產生補償性 credit，因此 `fault_t0` 之後頭幾秒的 client latency spike 不是 mClock 造成的
- Status: proposed
- Priority: P2
- Tier: T1 → T3
- Origin: 讀碼（`do_add_request` 的 `client.idle` 分支）
- Prediction: `fault_t0` 後首 5 秒的 client p99 三 profile 差異 < production margin（Δratio < 1.0）；該區間的劣化由 peering / OSDMap 更新主導（見 H-007）。
- 證偽條件: 首 5 秒即出現符合 res 比的 profile 分層 → violated（代表 mClock 在故障瞬間就 binding）。
- Evidence: dmclock_server.h:946-994（`prop_delta = lowest_prop_tag - time`）。

### H-022: v19.2.2 的 classic OSD 對所有外部 client 共用同一個 dmclock client record（`get_scheduler_id` 永遠回傳預設的 `client_profile_id_t()`），因此 mClock 只有 class 級 QoS、沒有 per-client 公平性 — 單一 fio client 可以吃光整個 client class 的保障
- Status: proposed
- Priority: P2
- Tier: T1 → T3
- Origin: 讀碼（`external_client_infos` 在 v19.2.2 實際上是 dead map）
- Prediction: 4 台 fio client 的 IOPS 分佈在同一 cell 內的 CoV 不受 profile 影響（三 profile 的「client 間不均勻度」差異 < noise margin）；且不存在任何 profile 能改善 client 之間的公平性。
- 證偽條件: 某 profile 明顯壓低 client 間 CoV → violated。
- Evidence: mClockScheduler.h:206-211（`get_scheduler_id` 用預設 `client_profile_id_t()`）、:165-170（`default_external_client_info` + 空的 `external_client_infos`）；mClockScheduler.cc:226-234（`get_external_client` 永遠 miss → 回預設）。
- Notes: 報告的「何時選哪個 profile」裁決樹必須明講：mClock 不解決 noisy-neighbour tenant 問題。

---

## M-2 cost model：ratio 如何變成 bytes/s，以及 1M IO 的實際成本（Step 2）

**機制**（全部 T1）：

- 兩個衍生量在 `set_osd_capacity_params_from_config()`（`mClockScheduler.cc:250-283`）算出：
  - `osd_bandwidth_cost_per_io = 名義 sequential bandwidth ÷ 名義 IOPS capacity`（`:272-273`），單位 bytes/io。
  - `osd_bandwidth_capacity_per_shard = 名義 sequential bandwidth ÷ num_shards`（`:274-275`），單位 bytes/s。
- 每筆 op 的排程成本：`calc_scaled_cost(item_cost) = max(max(1, item_cost), (uint32)cost_per_io)`（`mClockScheduler.cc:427-436`）——**只有 floor，沒有其他換算**。`item_cost` 來自 `Message::get_cost()`，其定義是 `data.length()`（`src/msg/Message.h:478-480`），由 `OSD::enqueue_op` 取出（`src/osd/OSD.cc:9674-9675`）。
- res/lim 的 ratio 乘上 `capacity_per_shard` 變成 bytes/s（`mClockScheduler.cc:171-185`）。
- `num_shards` = `osd_op_num_shards_ssd` = **8**（非 rotational；`OSD.cc:3627-3635`、`osd.yaml.in:900-904`），由 `OSDShard` 建構時傳入（`OSD.cc:10830-10847`、`src/osd/scheduler/OpScheduler.cc:24-45`）。
- 名義值預設：`osd_mclock_max_sequential_bandwidth_ssd = 1200 MiB/s`（`osd.yaml.in:1110-1121`）、`osd_mclock_max_capacity_iops_ssd = 21500`（`osd.yaml.in:1137-1147`）。

**1M IO cost 算例**（用 compiled default 21500 IOPS，campaign 實際會鎖成校準值，屆時重算並寫進 bundle）：

| 量 | 算式 | 值 |
|---|---|---|
| 名義 seq bandwidth | `1200 × 1024 × 1024` | 1,258,291,200 bytes/s |
| `capacity_per_shard` | `÷ 8 shards` | 157,286,400 bytes/s |
| `cost_per_io` | `1,258,291,200 ÷ 21500` | 58,525 bytes/io |
| 4K random **write** 的 scaled cost | `max(4096, 58525)` | **58,525** |
| 4K random **read** 的 scaled cost | `max(max(1, 0), 58525)`（read 請求 `data.length() = 0`） | **58,525**（與寫相同） |
| 1M seq write 的 scaled cost | `max(1048576, 58525)` | **1,048,576** = 4K op 的 **17.92×** |
| balanced client res 的 bytes/s（per shard） | `0.5 × 157,286,400` | 78,643,200 |
| 換算成 4K ops/s（整顆 OSD） | `78,643,200 ÷ 58,525 × 8` | **10,750** = `0.5 × 21500` ✓ |
| 換算成 1M ops/s（整顆 OSD） | `78,643,200 ÷ 1,048,576 × 8` | **600 ops/s = 600 MiB/s** = `0.5 × 1200 MiB/s` ✓ |

→ 語意結論：**同一個 res ratio，在小 IO 世界代表「ratio × 名義 IOPS」，在大 IO 世界代表「ratio × 名義 sequential bandwidth」**，兩者的交叉點正好在 `cost_per_io`（預設 ≈ 57 KiB）。1M 相對 4K 只貴 17.9 倍，而非 bytes 比的 256 倍。

### H-004: 因為 `calc_scaled_cost` 只是 `max(item_cost, cost_per_io)`，4K 讀與 4K 寫的排程成本完全相同，randrw 的讀寫比不影響 mClock 的帳；而 1M op 只被計為 4K op 的 ~17.9 倍
- Status: proposed
- Priority: P1
- Tier: T1
- Origin: 讀碼（`Message::get_cost()` = `data.length()`，read 請求無 data）
- Prediction: 同壓力等級下，把 4K randrw 從 70/30 改成 50/50 不會改變三 profile 的相對分離度（S3 選配確認組；主 campaign 只做 70/30）。且 1M seq cells 的 client 保障換算成頻寬 = `res × 1200 MiB/s`（balanced 600 / high_client_ops 720 / high_recovery_ops 360 MiB/s per OSD）。
- 證偽條件: rw mix 改變後 profile 分離度顯著改變 → violated（代表 cost 另有 read/write 不對稱來源，例如 BlueStore 層而非 scheduler 層）。
- Evidence: mClockScheduler.cc:427-436；Message.h:478-480；OSD.cc:9674-9675。
- Artifacts: 報告的參數建議總表必須附「cost_per_io 交叉點」欄位（鎖定 capacity 後的實際 bytes 值）。

### H-005: 壓力等級（相對 balanced-healthy ceiling）與 mClock 的 res 門檻分母不同，必須用校準後的 ρ 換算；只有當「per-OSD client-class 需求比 > 該 profile 的 client res」時 profile 才會分離
- Status: proposed
- Priority: **P0**（決定全部 63 cells 的方向性預測）
- Tier: T1 → T3
- Origin: 讀碼 + 矩陣推導（ceiling 的分母是實測 aggregate、res 的分母是鎖定的名義 per-OSD capacity）
- 換算式（**在 calibrate 完成後填值，並凍進每個 cell 的 prediction**）：
  - `C` = 鎖定的 per-OSD `osd_mclock_max_capacity_iops_ssd`（4K）。
  - `ceiling` = balanced + final-clean 下實測的 aggregate 4K randrw ceiling（IOPS）。
  - **`ρ = ceiling ÷ (8 × C)`**；某壓力等級 `L ∈ {0.25, 0.5, 0.8, ~1.0}` 對應的 per-OSD client-class 需求比 = **`ρ × L`**。
  - 推導依據：read 只由 primary 服務、write 的兩份 replica op 走 immediate class 不計入 client class（H-006），故 client-class ops 總數 = client IOPS 本身，均分到 8 顆 OSD。
- Prediction（以 ρ 參數化；`res_client` = 0.5 / 0.6 / 0.3）：
  - `ρ × L < 0.3` → 三 profile **全部** indistinguishable（client 需求低於最小的 client res，reservation 對誰都不 binding）。
  - `0.3 ≤ ρ × L < 0.5` → 只有 `high_recovery_ops` 劣化；`balanced` 與 `high_client_ops` indistinguishable。
  - `0.5 ≤ ρ × L < 0.6` → `high_recovery_ops` < `balanced` < `high_client_ops`（client 面），但 balanced/high_client_ops 的差可能落在 margin 內。
  - `ρ × L ≥ 0.6` → 三 profile 完整分離，服務比 ≈ res 比（接上 H-001）。
- 證偽條件: 出現「ρ×L 明顯低於 0.3 卻量到超過 production margin 的 profile 分離」或「ρ×L ≥ 0.6 卻三者等效」→ violated，代表換算式漏了項（第一嫌疑：immediate class 的 off-book 佔用，見 H-006）。
- Artifacts: `run/calibrate.sh` 的 `results/calibration.json` 必須輸出 ρ；`manifest.py generate` 把每個 cell 的 `ρ×L` 與預期分支寫進 `prediction`。

---

## M-3 mClock 的仲裁涵蓋邊界：什麼繞過 scheduler（Step 3）

**機制**（全部 T1）：

- `mClockScheduler::enqueue`（`mClockScheduler.cc:476-513`）三分支：
  1. `class_id == immediate` → 丟進 `high_priority`，優先權 = `immediate_class_priority` = `numeric_limits<unsigned>::max()`（`mClockScheduler.h:204`）。
  2. `item priority >= cutoff_priority` → 也丟 `high_priority`（`:484-485`）。
  3. 其餘才進 dmclock（`:487-499`）。
  `dequeue` 永遠先清空 `high_priority`（`mClockScheduler.cc:548-568`），而 `high_priority` 是 `std::map<priority_t, ..., std::greater<>>`（`mClockScheduler.h:193-195` 定義、`:203` 成員）→ immediate 排在最前。
- `cutoff_priority` 來自 `osd_op_queue_cut_off`，預設 `high` → `CEPH_MSG_PRIO_HIGH = 196`（`OSD.cc:2436-2448`、`osd.yaml.in:947-969`、`src/include/msgr.h:223-226`）。
- **class 的判定表**（`src/osd/scheduler/OpSchedulerItem.h`）：

  | queueable | class | 錨點 |
  |---|---|---|
  | `PGOpItem`（訊息型 op） | 只有 `CEPH_MSG_OSD_OP` / `CEPH_MSG_OSD_BACKOFF` → `client`；**其餘一律 `immediate`** | :243-251 |
  | `PGPeeringItem` | 恆 `immediate` | :276-278 |
  | `PGRecovery` / `PGRecoveryContext` | `priority_to_scheduler_class(priority)` | :522-524、:550-551 |
  | `PGRecoveryMsg`（push/pull/backfill/scan） | `priority_to_scheduler_class(訊息 priority)` | :613-615、:587-598 |
  | `PGSnapTrim` / `PGScrub` / `PGScrubItem` 系 / `PGDelete` | 恆 `background_best_effort` | :299-301、:322-324、:362-364、:574-576 |

- `priority_to_scheduler_class`（`OpSchedulerItem.h:204-212`）：`>= 196` → immediate；`>= DEGRADED(10)` → background_recovery；否則 → background_best_effort。
- recovery 的 priority 值在 mClock 下是特製的小整數（`src/osd/PeeringState.h:1580-1585`）：`FORCED=20 / UNDERSIZED=15 / DEGRADED=10 / BEST_EFFORT=5`，由 `get_recovery_op_priority()` 依 PG 狀態選出（`PeeringState.h:1588-1601`）。→ **PG 只是 misplaced（不 degraded、不 undersized）時，其 recovery/backfill 落在 `background_best_effort`**。
- 路由：`OSD::enqueue_op` 先判 `PGRecoveryMsg::is_recovery_msg(op)`，是則包成 `PGRecoveryMsg`，否則包成 `PGOpItem`（`OSD.cc:9698-9711`）。本地發起的 recovery 走 `_queue_for_recovery`，item priority 用 `osd_recovery_priority`、cost 用 `cost_per_object × reserved_pushes`（`OSD.cc:2060-2087`）。

### H-006: replica 寫（`MSG_OSD_REPOP` 等非 `CEPH_MSG_OSD_OP` 訊息）在 replica OSD 上被判為 `immediate`，完全繞過 mClock；replica 3 下每顆 OSD 有可觀比例的裝置工作是「不計入任何 class」的表外負載，這會系統性壓縮 mClock 能分配的實際容量
- Status: proposed
- Priority: **P0**（頭牌機制發現）
- Tier: T1 → T3
- Origin: 讀碼（`PGOpItem::get_scheduler_class` 的白名單只有兩個訊息型別）
- Prediction:
  1. 4K randrw 70/30 下，每 100 個 client IO 在叢集內產生 100 個 client-class op + 60 個 immediate REPOP → **immediate 佔 scheduler 入列量的 ≈ 37.5%**；1M seq write（100% 寫）下 ≈ **66.7%**。以 `mclock-shard-queue-*` 的 `mclock_immediate_queue_len` vs `mclock_client_queue_len` 佇列長度組成驗證量級。
  2. 因為表外負載在寫比重高時更大，**profile 對 client 的保護效果在寫重負載下更弱**：1M seq cells（100% 寫）的 profile 分離度 < 4K randrw cells（30% 寫）。
- 證偽條件: 量到 immediate 佇列長期為 0，或 1M seq cells 的 profile 分離度 ≥ 4K cells → violated。
- Evidence: OpSchedulerItem.h:243-251；mClockScheduler.cc:476-486、:548-568；mClockScheduler.h:204；OSD.cc:9698-9711。
- Artifacts: `collect.sh` 必須收 per-OSD per-shard 的四個 mclock 佇列長度（counter 名稱見 `mClockScheduler.cc:96-105`）；報告需獨立一節說明「mClock 的帳只涵蓋 primary client op」。

### H-007: peering 恆走 immediate（且 peering 訊息本身 priority ≥ 196 也會落進 high_priority queue），因此 flapping 場景的 IO stall 主要由 peering 期間的 PG 不可用造成，與 profile 無關
- Status: proposed
- Priority: P0
- Tier: T1 → T3
- Origin: 讀碼 + spec §2「量測要把 peering 區間與 recovery 區間分開」
- Prediction: flapping 的 9 個 cells 中，**max IO stall duration 三 profile indistinguishable**（Δ < 2 s）；profile 差異只在每輪 OSD up 之後的 log-based recovery 區段（`background_recovery` class）可見，因此 flapping 的 p99 degradation ratio 分離度 < 同壓力的 osd-down cells。
- 證偽條件: 某 profile 的 max stall 顯著較長（Δ ≥ 2 s 且跨 replicate 一致）→ violated，代表 stall 有 mClock 成因。
- Evidence: OpSchedulerItem.h:276-278（`PGPeeringItem` → immediate）；mClockScheduler.cc:482-486；msgr.h:223-226；OSD.cc:2436-2448。
- Artifacts: sampler 必須能切出 peering 區間（PG state 含 `peering`/`activating` 的時窗）供分段統計。

### H-008: 回歸階段（heal → `osd in`）的 backfill 因為 PG 只是 misplaced 而非 degraded，落在 `background_best_effort` class — 那是三個 profile 的 `lim`（90% / 70% / max）**唯一**會 binding 的地方，而現行 pipeline 把這段當成純安全 gate、沒有量測
- Status: proposed
- Priority: **P0**（同時是對 plan 的具體修改建議）
- Tier: T1 → T3
- Origin: 讀碼（`get_recovery_op_priority()` 的 `BEST_EFFORT=5` 分支 → `priority_to_scheduler_class` 落在 best_effort）
- Prediction: 在 heal 之後、無 client 負載的「回歸 backfill」區段，`time(heal_t0 → final_clean)` 呈 `high_recovery_ops` < `balanced` < `high_client_ops`，比值約 **1 : 1.11 : 1.43**（= 1 : 1/0.9 : 1/0.7）。
- 證偽條件: 三者 indistinguishable → violated，代表回歸 backfill 的瓶頸不是 mClock 的 lim，而是 `osd_max_backfills=1` / PG 數 / 裝置本身（此時應在報告標註 lim 在本拓撲不可觀測）。
- Evidence: PeeringState.h:1588-1601（非 degraded/undersized → `BEST_EFFORT=5`）；OpSchedulerItem.h:204-212、:613-615；mClockScheduler.cc:369-373 / :337-341 / :353-357（三 profile 的 best_effort lim = .9 / .7 / 0=max）；H-002 說明為何這段必須「無 client 負載」才觀測得到。
- **Artifacts（plan 修改建議）**：
  - `lib/pipeline.sh` 的 safety gate 需記錄 `heal_t0`、`final_clean_t` 兩個絕對時戳，並讓 sampler 在該區段維持取樣（現行流程是「停 fio → 回歸 → 等 final_clean → sampler_stop」，時序上 sampler 仍活著，只需把時戳與區段標記寫進 bundle）。
  - `verdict.py` 新增 secondary endpoint `return-backfill-duration`；`schemas` 的 fault kind 加入 `return-backfill.json`。
  - 成本 = 0 額外 cluster 時間（這段本來就要等）。

---

## M-4 mClock 模式下被鎖定的 recovery 參數（Step 4）

**機制**（全部 T1）：

- `OSD::maybe_override_options_for_qos()`（`OSD.cc:10126-10222`）只在 `osd_op_queue == mclock_scheduler` 時作用（`:10130`），鎖定表為（`:10131-10136`）：

  | key | mClock 下的值 |
  |---|---|
  | `osd_recovery_max_active` | 0 |
  | `osd_recovery_max_active_hdd` | 3 |
  | **`osd_recovery_max_active_ssd`** | **10** |
  | **`osd_max_backfills`** | **1** |

- **boot 路徑**（`changed == nullptr`，`:10199-10222`）用 **`set_val_default`**（`:10208`）——原始碼註解自己說明：`set_val_default` 不會覆蓋更高層級（mon config store / ceph.conf）的既有設定。
- **runtime 變更路徑**（`:10139-10195`）：若 `osd_mclock_override_recovery_settings == false`（預設，`osd.yaml.in:1203-1223`），OSD 會**主動向 mon 送 `config rm` 把你設的值刪掉**（`:10166-10188`）並發 cluster warning `"Change to <key> on osd.N did not take effect. Enable osd_mclock_override_recovery_settings before setting this option."`（`:10190-10194`）。
- 另有 `OSD::maybe_override_sleep_options_for_qos()`（`OSD.cc:10227-10254`）：mClock 下把 `osd_recovery_sleep{,_hdd,_ssd,_hybrid}`、`osd_delete_sleep*`、`osd_snap_trim_sleep*`、`osd_scrub_sleep` 全部 **`set_val`（非 default）為 0** — 這是**無條件覆蓋** operator 設定。
- 三個 override 函式都在 OSD boot 的同一處依序呼叫（`OSD.cc:4097-4099`：sleep → options → capacity）；`osd_max_backfills` 的 runtime hook 在 `OSD.cc:9888-9897`。

### H-009: boot 路徑用 `set_val_default`，所以 mon config store 或 ceph.conf 裡任何既有的 `osd_max_backfills` / `osd_recovery_max_active_*` override 都會存活下來 — 「recovery 併發度全 campaign 固定」這個前提必須由 qos gate 驗值**且**驗來源，不能只信 mClock 會鎖
- Status: proposed
- Priority: **P0**（harness gate 設計依據）
- Tier: T1 → T3
- Origin: 讀碼（`set_val_default` 的註解 `:10201-10206`）
- Prediction: 乾淨的 cephadm v19.2.2 部署下，八顆 OSD 的 effective `osd_max_backfills = 1`、`osd_recovery_max_active_ssd = 10`，且 `ceph config dump` 不含這兩個 key；任一顆不符 → 必為外部 override。
- 證偽條件: 乾淨部署即出現非預設值 → violated（則必須在報告標註 cephadm/IaC 有預設注入）。
- Evidence: OSD.cc:10199-10222（尤其 :10201-10208 的註解與 `set_val_default`）。
- Artifacts: `ceph_qos_gate` 除了比對 effective 值，另跑 `ceph config dump` 交叉核對「這些 key 不應出現在 mon store」；不符即 die。

### H-010: 在 `osd_mclock_override_recovery_settings=false` 下，任何對這四個 key 的 `ceph config set` 會被 OSD 反向刪除並產生 cluster warning — 症狀是「設了、值消失、health 出現 warning」
- Status: proposed
- Priority: P1
- Tier: T1
- Origin: 讀碼
- Prediction: harness 不做此操作；若 campaign 期間出現 cluster log `did not take effect. Enable osd_mclock_override_recovery_settings` → 判定為外部污染事件，該時窗所有 replicate 標 taint。
- 證偽條件: 手動 `ceph config set osd osd_max_backfills 3` 後值持續存在且無 warning → violated（v19.2.2 行為與讀碼不符，必須重查）。此驗證可在 calibrate 階段以 1 分鐘成本做一次 positive control，做完立即 `config rm` 還原。
- Evidence: OSD.cc:10145-10194。
- Artifacts: `bg_collect` 的 health/事件 log 加這條字串的偵測規則。

### H-011: mClock 模式下所有 sleep 節流（recovery / delete / snap trim / scrub）被無條件設為 0，因此 recovery 節流 100% 由 scheduler 承擔、沒有 sleep 後備 — 這排除了一整類混淆變因
- Status: proposed
- Priority: P1
- Tier: T1 → T3
- Origin: 讀碼
- Prediction: 八顆 OSD 的 effective `osd_recovery_sleep_ssd` / `osd_delete_sleep_ssd` / `osd_snap_trim_sleep_ssd` / `osd_scrub_sleep` 全部恆為 0（含 profile 切換後）。
- 證偽條件: 任一顆非 0 → violated（代表有更高優先級的設定管道，需重新評估 recovery 節流歸因）。
- Evidence: OSD.cc:10227-10254（`set_val` 非 `set_val_default`）。
- Artifacts: 併入 `ceph_qos_gate` 的驗證集合（成本近乎 0，但把「recovery 慢是因為 sleep」這個替代解釋一次排除）。

---

## M-5 capacity 全路徑與它的三個陷阱（Step 5）

**機制**（全部 T1，`OSD::maybe_override_max_osd_capacity_for_qos()`，`OSD.cc:10019-10123`）：

1. **前提閘門**（`:10024-10026`）：三個條件同時成立才會跑 bench —— `osd_op_queue == mclock_scheduler` **且** `osd_mclock_skip_benchmark == false` **且** objectstore != `memstore`。任一不成立 → 整個函式什麼都不做、**不留任何 log**。
2. **skip 判定**（`:10039-10062`）：非 force 模式下，取 `cur_iops`（目前 effective 值）與 `get_val_default()`（compiled default）比對，**只要 `default_iops != cur_iops` 就 return**（`:10056-10061`），**完全不看值的來源**。此分支**有**正向 log：`dout(1) ... "Skip OSD benchmark test."`。
3. **bench 內容**（`:10064-10069`）：寫 100 個 4 MiB 物件、block size **4 KiB**、總計 12,288,000 bytes ——**只量 4K random write IOPS，從不量 sequential bandwidth**。
4. **採納判定**（`:10091-10121`）：量出的 iops 若落在 `[osd_mclock_iops_capacity_low_threshold_ssd, osd_mclock_iops_capacity_threshold_ssd]` = **[1000, 80000]**（`osd.yaml.in:1258-1291`）之外 → 只發 cluster warning、**保留現值**（`:10108-10117`）；落在範圍內才 `mon_cmd_set_config` 寫進 mon store（`:10121`）。
5. `osd_mclock_force_run_benchmark_on_init` 是 **startup** flag（`osd.yaml.in:1150-1165`），`osd_mclock_skip_benchmark` 是 **runtime** flag（`osd.yaml.in:1166-1178`），但後者只在 boot 路徑上有意義。
6. capacity 與 profile 都在 `get_tracked_conf_keys()` 內（`mClockScheduler.cc:593-613`），runtime 改值會重跑 `set_osd_capacity_params_from_config()` + `update_from_config()`（`mClockScheduler.cc:619-635`），而前者會印一行 `dout(1)` 帶 `osd_bandwidth_cost_per_io` 與 `osd_bandwidth_capacity_per_shard`（`mClockScheduler.cc:277-282`）。

### H-012: 若鎖定的 capacity 值剛好等於 compiled default（v19.2.2 的 `osd_mclock_max_capacity_iops_ssd = 21500`），skip 判定不成立，OSD 每次重啟都會重跑 bench 並可能覆寫 — 決策表必須禁止 `locked_value == 21500`
- Status: proposed
- Priority: **P0**（harness 不變條件）
- Tier: T1 → T3
- Origin: 讀碼（`:10056` 的 `default_iops != cur_iops`）
- Prediction: 鎖成 21500 的 OSD 在 reboot canary 後其 log 出現 `osd bench result`；鎖成 21499 的則出現 `Skip OSD benchmark test.`。（可在單顆 OSD 上做，成本 < 5 分鐘。）
- 證偽條件: 鎖 21500 後 reboot 未重跑 bench → violated（代表另有 skip 條件）。
- Evidence: OSD.cc:10039-10062；osd.yaml.in:1137-1147（default 21500）。
- Artifacts: `ceph_capacity_decide` 加不變條件 `locked_value != 21500`（命中則 ±1 並記錄 provenance）；此不變條件要有測試。

### H-013: 現行 `ceph_verify_no_rebench` 的「無 `osd bench result` 行」是**必要非充分**證據，且缺少 positive control — 若 `journalctl -b -u ceph-<fsid>@osd.N` 因 unit 名稱或 fsid 取錯而回空集合，斷言會假通過
- Status: proposed
- Priority: **P0**（方法論缺口 + 對 plan 的修改建議）
- Tier: T1 → T3
- Origin: 讀碼與 plan Task 6 敘述比對（見 §與 plan/spec 的出入 #1）
- Prediction: 在 reboot canary 中，若刻意把某顆 OSD 設成 `skip_benchmark=false` 且 capacity 值 ≠ 21500，其 log **必定**出現 `Skip OSD benchmark test.`（`:10059-10060` 是 `dout(1)`，預設 log level 撈得到）。這行的出現即證明「log 管道確實抓得到該 OSD 的 boot log」。
- 證偽條件: 上述設定下仍撈不到該行 → 代表 log 管道有問題（正是本假說要偵測的失效），或 log level 不足 → 兩者都必須在 canary 階段解決才能開跑。
- Evidence: OSD.cc:10024-10026（skip flag 路徑無 log）、:10056-10061（值差異路徑**有** log）。
- Artifacts（plan 修改建議）: `run/calibrate.sh` 的 reboot canary 增加一步 **positive control**：對 canary node 的 OSD 暫時 `skip_benchmark=false`（值仍 ≠ default）→ reboot → 斷言看得到 `Skip OSD benchmark test.` → 還原 `skip_benchmark=true` → 再 reboot → 斷言看不到 `osd bench result` 且 capacity 值未變。沒有這個 positive control，現行合取證據無法區分「真的沒重跑」與「根本沒抓到 log」。

### H-014: osd bench 只量 4K random write，sequential bandwidth 從不量測（固定 1200 MiB/s）— cost model 的兩個端點只有一個被校準到本機，所有大 IO 結論都必須標註「Ceph 預設 cost model 下的結果」
- Status: proposed
- Priority: P1
- Tier: T1 → T3
- Origin: 讀碼 + spec §2
- Prediction: (a) 實測 raw NVMe 4K randwrite IOPS 與 osd bench IOPS 的比值落在 `[0.5, 2]`（決策表 `accepted-consistent` 分支）；(b) 實測 1M seq write 的 per-OSD 可達頻寬與名義 1200 MiB/s 的比值**顯著偏離 1**（L8s_v3 單 NIC 12.5 Gbps ≈ 1.45 GiB/s，replica 3 放大後 per-OSD 可用寫入頻寬預期遠低於 1200 MiB/s）。
- 證偽條件: 實測 seq 頻寬 ≈ 1200 MiB/s（±15%）→ 名義值恰好正確，H-004 / H-005 對 seq cells 的推論需重算。
- Evidence: OSD.cc:10064-10069（bench 參數）；mClockScheduler.cc:255-267（rotational 分支只取兩個 config，沒有任何量測）；osd.yaml.in:1110-1121。
- Artifacts: `env_snapshot_cluster` 記錄 `osd_bandwidth_cost_per_io` 的實際值（由 H-019 的 log 行取得）；報告的每個 seq 結論加註。

### H-019: capacity 與 profile 都是 runtime-changeable，且 `set_osd_capacity_params_from_config()` 會印出 `osd_bandwidth_cost_per_io` / `osd_bandwidth_capacity_per_shard` — 這提供比「讀 config show」更強的**生效**斷言
- Status: proposed
- Priority: P1
- Tier: T1 → T3
- Origin: 讀碼
- Prediction: `ceph config set osd.N osd_mclock_max_capacity_iops_ssd <X>` 之後，osd.N 的 log 立即出現一行含 `osd_bandwidth_cost_per_io: <1258291200/X>` 的訊息，且不需重啟 OSD。
- 證偽條件: 改值後無此 log 或值未變 → violated（則 capacity lock 必須改為 restart 才算生效，會顯著拉長 campaign）。
- Evidence: mClockScheduler.cc:593-613（tracked keys）、:619-630（handle_conf_change 重算）、:277-282（dout(1) 內容）。
- Artifacts: `ceph_lock_capacity` 與 `ceph_qos_gate` 把這行 log 納入生效證據（config show + log 雙證據）。

---

## M-6 mon 側：heartbeat grace、laggy 累積、down-out subtree limit（Step 6）

**機制**（全部 T1）：

- `OSDMonitor::get_grace_time()`（`src/mon/OSDMonitor.cc:3195-3239`）：起點是 `osd_heartbeat_grace`（預設 **20** 秒，`src/common/options/global.yaml.in:2833-2836`）；**`mon_osd_adjust_heartbeat_grace == false` 時直接回傳原值**（`:3200-3202`），不做任何 laggy 加成。預設為 true（`src/common/options/mon.yaml.in:885-897`）。
- **laggy 值仍會照常更新**：`OSDMonitor::prepare_boot()`（函式起點 `:3592`）在 OSD 開機時更新 `osd_xinfo_t`（`:3693-3714`）——`boot_epoch == 0` 走衰減分支 `× (1 - mon_osd_laggy_weight)`，否則 `laggy_probability = w + p × (1-w)`（w = `mon_osd_laggy_weight` 預設 **0.3**，`mon.yaml.in:859-867`）、`laggy_interval` 為 down 時長的 EWMA 並被 `mon_osd_laggy_max_interval`（預設 **5 分鐘**，`mon.yaml.in:873-881`）截斷。**關掉 adaptive grace ≠ 關掉 laggy 累積。**
- laggy 的**唯一自動歸零**路徑：OSD 被標 DOWN 時，若距上次 down 超過門檻才呼叫 `set_default_laggy_params()`（`:1961-1970` → `:3446-3456`）；門檻 = `48 × mon_osd_laggy_halflife` = **48 小時**（`:3425-3432`，halflife 預設 1 小時，`mon.yaml.in:850-855`）。
- **另一條 laggy 生效路徑沒被關掉**：auto-out 的 grace 由 `mon_osd_adjust_down_out_interval`（預設 **true**，`mon.yaml.in:905-910`）縮放（`OSDMonitor.cc:5164-5175`），與 `mon_osd_adjust_heartbeat_grace` 是**兩個獨立開關**。
- `mon_osd_down_out_subtree_limit` 預設 **`rack`**（`mon.yaml.in:966-975`）：tick 時若「包含該 OSD 的整個 rack subtree 都 down」→ **重置 `down_pending_out` 計時器並 `continue`**（`OSDMonitor.cc:5177-5188`）→ **永遠不會 auto-out**。
- `can_mark_out()`（`OSDMonitor.cc:3132-3160`）檢查 `noout` 與 `mon_osd_min_in_ratio`（預設 **0.75**，`mon.yaml.in:994-1000`），但它**只被 auto-out tick 呼叫**（`:5145`、`:5159`）；手動 `ceph osd out` 走 `prepare_command` 路徑（`:11991-12070`），**沒有 min_in_ratio 檢查**。
- OSD 正常關閉時會主動送 `MOSDMarkMeDown`（`OSD.cc:1338-1360`，由 shutdown 路徑呼叫 `:4562`/`:4569`）→ daemon stop 幾乎立即被標 down；網路隔離沒有這條路徑，只能等 heartbeat grace + failure report。

### H-015: `mon_osd_adjust_heartbeat_grace=false` 只關掉 heartbeat grace 的 laggy 加成，`mon_osd_adjust_down_out_interval` 仍是 true，且 laggy 值 48 小時內不會自然歸零 — flapping cells 之間存在無法靠 restart 清除的跨 cell 污染
- Status: proposed
- Priority: P1
- Tier: T1 → T3
- Origin: 讀碼（兩個獨立開關 + 48 × halflife 門檻）
- Prediction: 每個 flapping cell（10 輪）結束後，目標 OSD 的 `laggy_probability` 單調上升並逼近 1（每輪 `p ← 0.3 + 0.7p`：3 輪後 ≈ 0.66、10 輪後 ≈ 0.97），且在 72 小時 campaign 內**不會**回到 0；`laggy_interval` 被 300 秒截斷。
- 證偽條件: 觀測到 `laggy_probability` 在 cells 之間回到 0 → 存在其他重置路徑，需重查（讀碼結論錯誤）。
- Evidence: OSDMonitor.cc:3200-3202、:3693-3714、:3425-3444、:1961-1970、:3446-3456、:5164-5175；mon.yaml.in:850-910。
- Artifacts: 每個 replicate 收 `ceph osd dump --format json` 的 `osd_xinfo` 作 covariate（**只記錄不 gate**）；報告需說明「flapping 的 profile 比較在 laggy 已飽和的狀態下進行」。

### H-016: `mon_osd_down_out_subtree_limit=rack` 使整個 rack down 時 auto-out 計時器被反覆重置 — 生產上沒有 operator 介入就永遠不會觸發 backfill，這是 rack 場景最重要的生產語意
- Status: proposed
- Priority: P0
- Tier: T1 → T3
- Origin: 讀碼 + spec §2
- Prediction: rack cells 注入後（兩台隔離、OSD 判 down）在下手動 `osd out` 之前的觀察窗內，兩顆 OSD 維持 `down + in`、`degraded%` 不下降、`recovery bytes/s ≈ 0`；下 out 之後才起 backfill。此觀察可在 rack pilot 的注入後前 60 秒順帶完成，不需額外 cell。
- 證偽條件: 未手動 out 即自動起 backfill → violated（則 subtree limit 未生效，需檢查 CRUSH type 名稱是否真的是 `rack`）。
- Evidence: OSDMonitor.cc:5177-5188；mon.yaml.in:966-975。
- Artifacts: rack pilot 的 bundle 需含這 60 秒的 `ceph -s` 序列作為報告素材。

### H-017: 手動 `ceph osd out` 不受 `mon_osd_min_in_ratio` 限制，rack 場景一次 out 兩顆（in 比降到 6/8 = 0.75）不會被拒
- Status: proposed
- Priority: P1
- Tier: T1 → T3
- Origin: 讀碼（`can_mark_out` 的呼叫點只有 auto-out tick）
- Prediction: rack commit 步驟的兩顆 `ceph osd out` 恆成功；若失敗必為其他原因（mon 不可用、id 錯誤）。
- 證偽條件: 出現 `will not mark osd.N out` 之類拒絕 → violated。
- Evidence: OSDMonitor.cc:3132-3160（定義）、:5145/:5159（唯二呼叫點）、:11991-12070（手動路徑無此檢查）；mon.yaml.in:994-1000。

### H-020: 網路隔離的「注入 → 判 down」延遲 ≈ heartbeat grace（20 秒）+ mon tick，而 daemon stop 因為有 `MOSDMarkMeDown` 幾乎立即 down — 兩種故障的時間軸必須以 OSDMap down epoch 對齊，不能都用 `fault_t0`
- Status: proposed
- Priority: **P0**（分析正確性前提）
- Tier: T1 → T3
- Origin: 讀碼 + spec 對 node loss 的定位
- Prediction: `node-isolation` 的 `fault_t0 → OSDMap down epoch` 延遲 ≈ **20–30 秒**；`osd-down`（daemon stop）的同一延遲 **< 5 秒**。若以 `fault_t0` 為量測窗起點，node-isolation 的 degradation ratio 會被前段「什麼都沒發生」的 20 秒稀釋。
- 證偽條件: 兩者延遲差 < 5 秒 → violated（代表隔離規則也切斷了某條讓 OSD 自我回報的路徑，或 mon 用其他機制更快判定）。
- Evidence: OSD.cc:1338-1360（`MOSDMarkMeDown`）、:4562/:4569；OSDMonitor.cc:3195-3202（grace = 20s）；global.yaml.in:2833-2836。
- Artifacts: `verdict.py aggregate` 對 fault cells 同時輸出以 `fault_t0` 與以 `down_epoch_t` 為原點的兩組窗口統計；跨故障型比較一律用後者。

---

## 橫向假說

### H-018: profile 的九個衍生參數是 OSD process 內的 `set_val_default`，不進 mon config store；而在非 `custom` profile 下對這九個 key 做 `ceph config set` 會被 OSD 反向 `config rm` — 生效驗證只能逐 OSD 讀 effective config
- Status: proposed
- Priority: **P0**（qos gate 設計依據）
- Tier: T1 → T3
- Origin: 讀碼 + spec §2
- Prediction: (a) 每次 profile 切換後 30 秒 settle window 內，八顆 OSD 的九個 effective 參數全部收斂到該 profile 的值；(b) `ceph config dump` 恆不含這九個 key；(c) 若誤下 `ceph config set osd osd_mclock_scheduler_client_res 0.9`，該 key 會在數秒內從 mon store 消失（且 profile 值不變）。
- 證偽條件: (a) 有 OSD 在 30 秒後仍未收斂 → settle window 需加長並記錄；(c) 值持續存在 → 讀碼結論錯誤。
- Evidence: mClockScheduler.cc:320-325（只有 shard 0 設 profile defaults）、:396-425（`set_val_default` + `apply_changes`）、:631-635（profile 變更 → 重算）、:658-695（非 custom profile 下的 QoS 參數變更 → 向 mon 送 `config rm` + `rm_val`）。
- Artifacts: `ceph_qos_gate` 的驗證集合（已在 plan Task 6）＝ profile 名 + 九參數 + capacity + seq bw + `osd_max_backfills` + `osd_recovery_max_active_ssd` + `override_recovery_settings=false` + `skip_benchmark=true` + `osd_op_queue=mclock_scheduler`；本假說補上「`ceph config dump` 不得含九個 key」的反向斷言。

### H-021: 灰色網路故障（1–5% packet loss / 延遲抖動）下 heartbeat 未斷但效能劣化，三 profile 的 client latency 差異可能與硬故障相反
- Status: proposed（**S3 選配，時間允許才做**）
- Priority: P2
- Tier: T3
- Origin: spec §5 選配 + repo 既有 gray-failure 研究線
- Prediction: `tc netem` 對單一 OSD node 注入 2% loss 時，OSD 不被標 down（無 backfill），client p99 劣化主要來自該 OSD 的重傳；三 profile indistinguishable（沒有 recovery 流量可分配）。
- 證偽條件: 出現符合 res 比的 profile 分層 → 代表灰色故障也會觸發可被 mClock 分配的背景流量。
- Notes: 若主 campaign 超時，此條直接留在 backlog、報告標為未驗證。

### H-023: `rack-loss × 極端壓 × high_client_ops` 是最可能撞 measurement cap 的 cell，其 `time-to-recovery-complete` 會是全矩陣最長、`recovery bytes/s` 最低
- Status: proposed
- Priority: P1
- Tier: T3
- Origin: 矩陣推導（最大 backfill footprint × 最高 client 壓 × 最不利 recovery 的 profile）
- Prediction: 該 cell 的 `time-to-recovery-complete` ≥ 其他 rack cells 的 1.4 倍；若 `measurement_cap = 2700s` 不足，它是第一個 censored 的 cell。plan 的 pilot 選擇規則（每故障型取「極端壓 × `high_client_ops`」）與本預測一致 → **pilot 的 cap 推導不會系統性低估**。
- 證偽條件: 其他組合先 censored → cap 推導的反偏誤假設不成立，需重新選 pilot 組合。
- Artifacts: 若 pilot 自己 censored，走 plan §Cap policy 的 `PILOT-CENSORED` 人工 gate。

---

## Cell 預測骨架（63 cells，Task 1 Step 7）

**共同規則**

- 每個 replicate 開跑前，pipeline 把對應 cell 的預測**凍進 bundle**（`prediction.json`），事後不可改。
- 方向性符號：`A < B` 表示「A 的 client 劣化小於 B」；recovery 面的方向相反時會明講。
- 所有「分離 / 等效」的判定都套 §預註冊生產門檻，且 `indistinguishable` 必須標 equivalent 或 underpowered。
- **ρ（H-005）在 calibrate 後填入**；下表的 `ρ×L` 分支決定該 cell 是「預測分離」還是「預測等效」。若 calibrate 得到的 ρ 使某 cell 落在不同分支，以 ρ 為準改寫該 cell 的預測（改寫發生在 freeze 之前，並記入 journal）。

### A. 穩態 24 cells（3 profiles × 4 壓力 × 2 形態，n=3）— negative control

| 壓力 | 形態 | 預測 |
|---|---|---|
| 低 / 中 / 高 / 極端 | 4K randrw 70/30 | **三 profile indistinguishable（equivalent）**：無 recovery 流量 → 只有一個 active class；client `lim` 三 profile 皆 max（`mClockScheduler.cc:337-373`）→ reservation 只是下限、不構成上限。 |
| 低 / 中 / 高 / 極端 | 1M seq write | 同上。 |

- **這 24 cells 的功能是偵測混淆變因**：任何超過 production margin 的 profile 差異都代表有未受控來源（best_effort 背景流量、Azure 鄰居效應、校準漂移），必須先解釋才能相信故障區塊的結論。
- 次要預測：極端壓的 achieved IOPS 即 `ceiling`（校準值）；三 profile 的 ceiling 差異 < noise margin。

### B. 故障主軸 27 cells（3 profiles × 3 壓力 × 3 故障型，4K randrw，n=2）

以 `ρ×L` 分支（H-005）給方向性預測；`res_client` = balanced 0.5 / high_client_ops 0.6 / high_recovery_ops 0.3。

| 故障型 | 壓力 L | client 面預測 | recovery 面預測 | 主要依據 |
|---|---|---|---|---|
| **OSD down** | 低 (0.25) | `ρ×L < 0.3` → 三者 **indistinguishable** | `high_recovery_ops` ≥ `balanced` ≈ `high_client_ops`（recovery 拿走 client 沒用完的全部） | H-005、H-001 |
| | 中 (0.5) | `0.3 ≤ ρ×L < 0.6` → `high_recovery_ops` 顯著劣化；`balanced` ≈ `high_client_ops` | recovery bytes/s：`high_recovery_ops` > `balanced` ≳ `high_client_ops` | H-005 |
| | 極端 (~1.0) | 完整分離：`high_client_ops` < `balanced` < `high_recovery_ops`，且 client 吞吐比 ≈ 0.6 : 0.5 : 0.3 | time-to-recovery：`high_recovery_ops` < `balanced` < `high_client_ops` | H-001、H-005 |
| **OSD flapping** | 低 / 中 / 極端 | **max IO stall duration 三者 indistinguishable**（peering 主導）；p99 degradation ratio 的分離度**小於**同壓力的 OSD down cells | 每輪 up 後的 log-based recovery 量小 → recovery 面差異可能落在 margin 內 | H-007、H-015 |
| **synthetic CRUSH-rack loss** | 低 | 三者 indistinguishable（同 OSD down 低壓） | backfill footprint ≈ 1/4 資料、2 顆 OSD 同時 → 絕對值最大 | H-005、H-016 |
| | 中 | `high_recovery_ops` 顯著劣化 | 同上 | |
| | 極端 | 分離最大（全矩陣中 profile 差異最明顯的 9 cells）；`high_client_ops` 的 client 保護最好但 time-to-recovery 最長，**最可能 censored** | time-to-recovery 全矩陣最長 | H-001、H-023 |

- 全 27 cells 共同預測：`fault_t0` 後首 5 秒的 p99 spike 與 profile 無關（H-003、H-007）。
- 全 27 cells 共同預測：heal 後的回歸 backfill 時間呈 `high_recovery_ops` < `balanced` < `high_client_ops`，比值 ≈ 1 : 1.11 : 1.43（H-008；需 plan 補時戳）。

### C. node loss 變體 3 cells（3 profiles × 中壓 × network-isolation，n=2）

- 主預測：**以 OSDMap down epoch 對齊後**，與「OSD down × 中壓」的三個 cells 在四個 primary endpoint 上皆 indistinguishable（backfill footprint 相同、只有故障路徑不同）。
- 次預測（H-020）：`fault_t0 → down epoch` 延遲 ≈ 20–30 秒，顯著大於 OSD down 的 < 5 秒；若誤用 `fault_t0` 對齊，node-isolation 的 degradation ratio 會被系統性低估。
- 差異來源（如實記錄，不做歸因）：隔離期間 OSD process 仍活著、恢復時無 journal replay。

### D. large-IO contention 6 cells（3 profiles × {中, 極端} × OSD down × 1M seq write，n=2）

- 主預測（H-004 + H-006 + H-014）：**六個 cells 全部 indistinguishable**。理由：(a) 1M 形態下 client 的 res 換算成 `res × 1200 MiB/s`（600 / 720 / 360 MiB/s per OSD），而實測 per-OSD 可達寫入頻寬預期遠低於 360 MiB/s（單 NIC 12.5 Gbps + replica 3）→ 三個 profile 的 client reservation 都不 binding；(b) 100% 寫使 immediate class 的表外佔比升到 ~2/3，進一步壓縮 mClock 的有效仲裁空間。
- **證偽點（本區塊的價值所在）**：任一對 profile 分離 > production margin → H-004/H-014 的名義值假設錯誤，須用實測 seq 頻寬重算 cost model。
- 必收 covariate：per-OSD achieved MiB/s、NIC tx/rx/drop/retransmit（判定是否 NIC-bound）、`osd_bandwidth_cost_per_io` 實際值。

### E. chaos 3 cells（3 profiles × 極端壓 × 固定 seed，n=1）

- 定位 showcase，**不做嚴格 verdict**（n=1，只報描述性統計 + 與 B 區塊的一致性檢查）。
- 方向性預測：累積 stall 秒數 `high_client_ops` < `balanced` < `high_recovery_ops`；三者重播同一事件序列，事件序列本身滿足 min_size ≥ 2 的安全不變條件（plan §Task 8）。
- 一致性檢查：若 chaos 的方向與 B 區塊極端壓 cells 相反 → 標為異常，列入報告的「未解釋觀測」。

### 齊備度

`24 + 27 + 3 + 6 + 3 = 63 cells`；executions `72 + 54 + 6 + 12 + 3 = 147`（與 spec §5 一致，`manifest.py generate --assert 63/147` 驗）。

---

## 讀碼結果與 plan / spec 敘述的出入（**高價值，須在 Step 8 gate 一併裁示**）

1. **plan Task 6 說「v19.2.2 的 skip 路徑（`OSD.cc:10024` early return）沒有正向『skipped』log 可斷言」——只對一半。**
   - `osd_mclock_skip_benchmark=true` 造成的 early return（`OSD.cc:10024-10026`）確實無 log ✔。
   - 但「值 ≠ compiled default」造成的 skip（`OSD.cc:10056-10061`）**有** `dout(1) ... "Skip OSD benchmark test."`。
   - 影響：harness 兩個條件都設，實際落在無 log 的那條，所以 plan 的結論在該設定下仍成立，但**理由陳述不精確**，且因此漏掉了一個免費的 positive control（H-013）。建議照 H-013 的 Artifacts 修改 `run/calibrate.sh`。

2. **spec §2 說「best_effort lim 90% vs 70% 何時可觀測——本實驗不主測，標註為已知邊界」——低估了。**
   - `PeeringState::get_recovery_op_priority()`（`PeeringState.h:1588-1601`）在 PG 非 degraded、非 undersized 時回傳 `BEST_EFFORT=5`，經 `priority_to_scheduler_class`（`OpSchedulerItem.h:204-212`）落在 `background_best_effort`。
   - 也就是說 best_effort 的內容**不只是 scrub / snap trim**（本 campaign 都關掉了），還包含**每個 fault replicate heal 之後的回歸 backfill**——而那正是 lim 唯一 binding 的場景，且 harness 本來就要等它完成（safety gate）。
   - 影響：只要補兩個時戳就能免費拿到一個乾淨的 lim 對照（H-008），否則整份報告對「best_effort lim」只能寫「未觀測」。**建議 in-scope**。

3. **spec §5 說「campaign 全程設 `mon_osd_adjust_heartbeat_grace=false`（控制變因）」——控制不完全。**
   - `mon_osd_adjust_down_out_interval` 是**另一個獨立開關**且預設 true（`mon.yaml.in:905-910`、`OSDMonitor.cc:5164-5175`），laggy 仍會影響 down→auto-out 的等待時間。
   - 影響：本 campaign 以手動 out + flapping 期間 `noout` 迴避，實務上不受影響；但報告若寫「已關閉 adaptive grace」需限定為「heartbeat grace 面」。另 laggy 值本身 48 小時內不歸零（H-015），跨 cell 污染的存在必須誠實寫進 limitations。

4. **spec §2 對 `calc_scaled_cost()` 的敘述（「`osd_mclock_max_capacity_iops_*` 透過 `sequential_bandwidth / IOPS` 決定每筆 op 的最低成本」）正確，但缺了一個推論**：因為 `Message::get_cost()` = `data.length()`（`Message.h:478-480`），**read 請求的 item_cost 是 0**，所以 4K 讀與 4K 寫的 scaled cost 完全相同（都等於 floor）。randrw 的讀寫比在 mClock 的帳上不存在（H-004）。

5. **spec §2 對 profile 表的「res 是無因次 ratio」正確，但沒有指出三個 profile 的 client + background_recovery reservation 相加**都**等於 1.0**（0.5+0.5 / 0.6+0.4 / 0.3+0.7）。這使得「weight 是否可觀測」成為整個實驗的解讀分水嶺（H-001），建議在報告的機制章節明列。

---

## Triage（等使用者 Step 8 裁示）

| 優先 | 條目 | 為何現在就要決定 |
|---|---|---|
| **P0** | H-001、H-005、H-006、H-007、H-008、H-009、H-012、H-013、H-016、H-018、H-020 | 前四條決定全部 cells 的預測與報告框架；後六條是 harness 的 gate / 不變條件 / 時間軸對齊，**Phase 2 收尾前必須決定是否採納**（H-008 與 H-013 需要改 plan Task 6/9/10/11/12）。 |
| **P1** | H-002、H-004、H-010、H-011、H-014、H-015、H-017、H-023 | campaign 期間的斷言與 covariate，改動集中在 `collect.sh` / `ceph_qos_gate`，成本低。 |
| **P2** | H-003、H-019、H-021、H-022 | 研究線與加強型證據；H-021 明確為 S3 選配，時間不足即留 backlog。 |

**驗收（spec §11.5）**：所有 P0/P1 條目在 Phase 5 收官時必須離開 `proposed`（confirmed / violated / indistinguishable(equivalent|underpowered) / killed 四選一）。

### H-024：seq/high 的 taint 高度集中在 client reservation 最低的 profile

**狀態**：proposed（穩態階段實測觀察，待故障階段交叉驗證）

**觀察**（2026-07-27 穩態，`seq` 形態 × `high` 壓力，每 cell 3 replicate）：

| cell | coverage taint 次數 |
|---|---|
| `seq-high+high_client_ops`（client res 60%） | 0（三個 replicate 一次過） |
| `seq-high+balanced`（client res 50%） | 1 |
| `seq-high+high_recovery_ops`（client res 30%） | **8**（r1 三次全 taint → needs-human） |

taint 的成因是 fio 逐秒 log 與 heartbeat 同時出現 50–86 秒缺口；查證 r1 最後一次 attempt，
宣稱缺口的 86 秒內 fio 只有 36 秒有資料——**workload 真的中斷，不是純粹的觀測失效**。

**為什麼這與預期相反**：穩態沒有 recovery 競爭，而三個 profile 的 client limit 都是 max
（H-001），照理 client 可借滿全部 capacity、profile 不該有差別。穩態原本被定位為
negative control。

**可能機制**（待驗）：capacity 鎖在 4K randwrite 導出的 ~6,439，而 1M IO 的 mClock cost
是 4K 的 **17.9 倍**（H-004）。seq/high 目標約 1,900 MiB/s，換算成 cost 需求遠高於
capacity；此時 reservation 是否 binding 就取決於是否有其他 class 在動（BlueStore 內部、
pg stats、snap trim 等）。若成立，代表 **profile 在「大 IO + 高壓」下即使沒有 recovery
也會產生實質差異**，穩態不再是乾淨的 negative control。

**證偽方式**：故障階段的 seq-contention cells（1M × OSD down × 中/極端壓）已在矩陣內；
若該處三 profile 的 client 表現差異與此處的 taint 分佈同向，則本假說獲得支持。
另可在報告中以 `results/none-seq-high+*/` 的 coverage-proof 佐證。

**注意**：`n=3` 且 taint 具時間相關性的可能（8 次 taint 集中在同一時段）尚未排除，
不足以單獨支撐結論——列為待查，不寫進主結論。


### H-025：cephadm 的 systemd unit 有啟動速率限制，OSD flapping 實驗必然撞上

**狀態**：confirmed（真機實測，2026-07-27）

cephadm 產生的 OSD unit 模板（`/etc/systemd/system/ceph-<fsid>@.service`）帶有：

```
StartLimitInterval=30min
StartLimitBurst=5
```

**後果**：任何在 30 分鐘內重啟同一顆 OSD 超過 5 次的實驗，第 5 次之後 systemd 會直接拒絕
啟動並把 unit 標成 `failed (Result: start-limit-hit)`。本實驗的 flapping 場景設計為 10 輪
stop/start，必然觸發。

**診斷特徵**（容易誤判成 OSD 本身壞掉）：`systemctl status` 顯示所有 `Exec*` 步驟都是
`code=exited, status=0/SUCCESS`——**stop 是成功的**，只有重新啟動被速率限制擋下。
若只看「OSD 起不來」會往 BlueStore／裝置方向查，方向完全錯誤。

**處置**：每次 `systemctl start` 之前先 `systemctl reset-failed <unit>`，清掉失敗狀態與
計數器。這是 systemd 為此情境提供的標準機制，不需要改動 unit 設定（改設定會讓 lab 與
生產環境產生未記錄的差異）。

**對生產的意涵**：真實環境若遇到 OSD 反覆 flapping，**systemd 會在第 5 次後停止嘗試重啟**，
OSD 就此保持 down 直到人工介入。這是一個容易被忽略的失效放大路徑——監控只看到「OSD down」，
但根因是速率限制而非 OSD 本身。值得寫進報告的營運建議。

**另一個前提陷阱**（同時發現）：以 `ceph orch daemon add osd` 逐台建立的 OSD，其 service
在 `ceph orch ls` 中是 **unmanaged**，而 cephadm 不協調 unmanaged service——
`ceph orch daemon start` 只會回 `Scheduled to start` 然後**永不執行**。本實驗因此改走
目標 host 的 systemd（unit 名由 cephadm 固定命名 + 已驗證的 fsid 組出，動手前先確認存在）。

### H-026：STOP 的粒度是 segment，不是秒——收尾設計必須以「一整段」為單位

**狀態**：confirmed（真機實測，2026-07-28 flapping pilot）

故障模式的 fio 是 back-to-back segment 迴圈，runner 只在**每段結束後**才檢查 STOP
（fio 跑到一半被中斷就保不住 JSON 輸出）。原本的收尾有兩個獨立缺陷，疊在一起讓
整個 cell 報廢：

1. **等待時間短於一整段**：`FIO_STOP_WAIT_SECS=120` vs segment 全長 330s
   （`FIO_STEADY_SECS=300` + `FIO_RAMP_SECS=30`）。STOP 能不能在等待內生效，
   完全取決於它剛好落在段內哪個位置——**是擲骰子，不是設計**。
2. **STOP 是逐台依序送的**：首台停下來後，末台還要等好幾分鐘才收到 STOP。
   實測首台跑 6 段、末台跑 8 段，期間末台仍在全速打 IO。

**連鎖後果**：等待逾時 → `remote_bg_stop` 把 fio 殺在寫 JSON 的半路 → 尾段 JSON
截斷 → summary parser 直接 FATAL → 連帶 post-fault baseline 也寫不出來 → cell 失敗。
4 台裡有 3 台中招（`fio-stop: FAIL 3`）。

**修法（三處，缺一不可）**：
- 等待時間**由 segment 長度推導**（`FIO_STEADY_SECS + FIO_RAMP_SECS + 60`），
  不寫死常數；否則日後調 segment 長度會忘了跟著調。
- STOP **先廣播給全部 client，再回頭逐台等待**。因為各 client 同時起跑、段長相同，
  廣播後它們會在幾乎同一時刻抵達段邊界，總等待是「共用的一段餘量」而非 4 倍。
- summary parser 對**沒跑完的尾段**寬容：runner 是在 fio 回來後才寫
  `exit-code.<seg>`，那個檔就是「這段有正常結束」的憑證。沒憑證又解不開 = 本來就
  不是資料，跳過並把段名記進 `incomplete_segments`（**絕不靜靜丟掉**）；
  有憑證卻解不開 = 真損毀，照舊 die。全部段落都不完整時不可產出空殼 summary。

**可複用的原則**：對「以區塊為單位產出資料」的量測工具下停止訊號時，逾時上限必須
≥ 一個區塊，而且訊號要先廣播再收割。否則逾時殺掉的不是「多餘的尾巴」，而是
**正在落地的那份資料**。

### H-027：為真機事故寫的防護，本身從未生效（簽章不吃參數）

**狀態**：confirmed（真機實測，2026-07-28）

`fault_flapping` 在解除 `noout` 之前有一段防護，註解明白寫著它是為了擋掉先前真機上
「OSD 還 down 就解 noout → 600s 後 mon auto-out → 非計畫 backfill」的事故：

```bash
if ! _inject_osd_is_up_now "$id"; then ... 先拉起再解 noout ... fi
```

但 `_inject_osd_is_up_now` **的簽章根本不吃參數**——它讀全域 `_INJECT_UP_ID`，
而該全域只有 `_inject_wait_up_now` 會設。所以這行傳進去的 `$id` 被靜靜丟掉，
實際查的是「上一次殘留在全域裡的那顆 OSD」。防護寫了、看起來合理、也有註解說明
它擋的是什麼事故，**卻從第一天起就沒擋過任何東西**。

真機重現：pilot 被中斷在第 7 輪的 down 相位，osd.2 留在 down，`noout` 照樣解除。

**兩個獨立缺陷疊加才造成後果**：
1. 上述 up-check 失效（查錯 OSD）。
2. `fault_flapping` **從未把自己登記進 active registry**（其他故障型都有
   `_inject_active_add` + `_inject_push_rollback`），所以中斷時
   `inject_rollback_all` 看到空 registry → 回報 `CLEAN` → 什麼都沒做，
   而 cleanup stack 裡的 `unset noout` 照跑。**回報 CLEAN 的同時叢集其實是壞的。**

**修法**：`_inject_osd_is_up_now [<osd-id>]` 收參數（省略時才沿用全域，供
`with_deadline` 反覆呼叫）；`fault_flapping` 登記進 registry，且因為 cleanup stack
是 LIFO，登記要排在 `unset noout` 的 push **之後**（→ 先拉起 OSD、再解 noout）；
只有確認 OSD 真的回到 up 才撤掉 registry 條目，否則留著讓 rollback／reconcile 補救。

**可複用的原則**：bash 沒有 arity 檢查，多傳的參數會被靜靜吃掉。**「呼叫端看起來
有傳參數」不等於「被呼叫端有用到」**——helper 若靠全域傳值，任何帶參數的呼叫都是
騙人的。這類缺陷對 review 幾乎隱形（程式碼讀起來完全正確），只有 mutation 測試
或真機事故會揭露。

### H-028：同一個 attempt 的量測與 baseline 共用遠端 workdir

**狀態**：confirmed（真機實測，2026-07-28）

`_fio_runid` 對 replicate bundle（`*/attempts/*`）的命名**完全不含 mode**，所以
故障量測與其後的 post-fault baseline 落在同一個遠端 workdir。runner 啟動時只清
`STOP`/`exit-code`/`heartbeat`，不清 `seg*.json`——於是 baseline 的 fetch 會把量測期
的 6–7 段一起撈回來，再被 summary 的 `seg*.json` glob 摺進 baseline。
**而 baseline 正是劣化比的分母。**

`devstat.log` 是 `>>` 累加、從不截斷，同樣跨輪殘留。

**穩態為何逃過一劫**：穩態每輪只產一段，baseline 的 `seg01.json` 直接覆蓋掉舊的，
而量測資料在 baseline 開跑前就已經 fetch 走了。78 個穩態 baseline 實測全乾淨——
**是巧合，不是設計**。故障模式一輪產 6–7 段，必中。

**修法**：runner 啟動時清掉上一輪的全部產物（`seg*`、`exit-code.seg*`、
`fio-exited-at`、`devstat.log`）。runner 比 devstat 取樣器早啟動，所以在 runner 裡
清 `devstat.log` 是安全的。這同時也涵蓋「同一個 attempt 重試」的情境——改 runid
命名則不會。

### H-024（結案）：seq/high 的 taint 集中在 high_recovery_ops，是 harness 競態不是 profile 行為

**狀態**：refuted as a profile effect（分析日 2026-07-28）

原始觀察：穩態 7 個 taint 裡有 5 個落在 `none-seq-high+high_recovery_ops`
（balanced 1、high_client_ops 0），與「穩態是 negative control」的預期相反。

**判準**：把每個 attempt 的「coverage supervisor 最後一次檢查時刻 − fio 自報結束時刻」
（以下稱 lag）與 taint 對照，結果是乾淨的一刀兩斷：

| lag | 結果 |
|---|---|
| 正（最後一次檢查落在 fio 結束**之後**） | 全部 taint（14, 7, 1, 16, 2, 14, 8） |
| 負（落在結束**之前**） | 全部乾淨 |

成因：fio 結束後 runner 的心跳自然停止，若 supervisor 的 30s cadence 又多打了一次
檢查，那段「結束後到窗尾」就被記成 heartbeat gap → 超過容忍 → taint。
**這是量測窗尾端的競態，與 mClock 的排程行為無關。**

**為什麼看起來集中在一格**：taint 會觸發 retry，retry 又是一次擲骰子——
`high_recovery_ops` 因此累積了 7 個 attempt（其他兩個 profile 各 3–4 個），
**先中的那一格會被回饋迴圈放大**。這是「重試會放大偏差」的典型陷阱：
統計「哪一格 taint 最多」時，分母不是固定的。

**次要觀察（僅記錄，不作結論）**：`none-seq-high+high_recovery_ops` 的 lag 分布
確實偏正（−40 ~ +16），而同壓力的 `high_client_ops` 緊緊落在 −12 ~ −16。
可能與該 profile 下背景類別保留較多、收尾偵測的 ssh 往返變慢有關，但與 retry
回饋迴圈完全混淆，**證據不足以支持任何因果宣稱**，報告中不得寫成 profile 差異。

**待辦**：coverage supervisor 應比照 aggregate 的做法，用 `fio-exited-at` 把窗尾
夾掉，別把「fio 結束之後」算成心跳缺口——這個假 taint 每次都要多燒一輪重試。

### H-029：OSD flapping 會讓 PG 的物件永久卡在 recovering，client IO 無限期阻塞

**狀態**：confirmed（真機實測，2026-07-28）

10 輪 flapping（osd.2）跑完、`flapping: OK` 之後，叢集看起來幾乎是健康的：

```
Degraded data redundancy: 2/921651 objects degraded (0.000%), 1 pg degraded
24 slow ops, oldest one blocked for 6489 sec, osd.4 has slow ops
```

實際狀態：PG 2.1a `active+recovering+undersized+degraded+remapped`，**卡了 115 分鐘**。
`ceph pg 2.1a query` 顯示關鍵矛盾：

- `up: [4, 1, 2]` 但 `acting: [4, 1]` ——**被 flap 的 osd.2 進得了 up，卻始終進不了 acting**
- primary 的 `recovery_progress.recovering` 清單裡固定卡著兩個物件，永不完成
- `might_have_unfound` 兩個 peer 都是 `already probed`（不是 unfound）

而 `ceph tell osd.4 dump_blocked_ops` 顯示阻塞的是 **client read**，
`flag_point: "waiting for rw locks"`，age 5413 秒，目標物件正是 recovering 清單裡那顆
（`rbd_data.5f8cfe291ffd.000000000000b755:head`）。也就是說：
**recovery 卡住 → 該物件的 rw lock 永遠不放 → 打到那顆物件的 client IO 無限期 hang。**

**為什麼監控幾乎看不到**：
- degraded 比例 **0.000%**（2 / 921,651），任何以「degraded 百分比」為門檻的告警都不會響。
- `HEALTH_WARN` 只有一行 `PG_DEGRADED`，看起來像即將自癒的小事。
- 唯一大聲的訊號是 `SLOW_OPS`，而它點名的是 **osd.4（PG 的 primary）**，
  不是 osd.2（真正 flap、真正肇因的那顆）。與先前 slow-ops SP 的 H-025「SLOW_OPS
  怪錯人」是同一個機制的不同案例。

**處置**：`ceph pg repeer <pgid>` —— 瞬間解決（state 立刻回 `active+clean`、
acting 補回 osd.2、slow ops 全消）。不需要重啟任何 daemon，不需要重開機。

**營運建議（報告用）**：
1. 告警不能只看 degraded 百分比；要有「PG 非 active+clean 持續 N 分鐘」這條，
   否則本案完全靜默。
2. `SLOW_OPS` 點名的 OSD 是**受害者（PG primary）**，排查要從卡住的 PG 的
   `up`/`acting` 差異回推肇因，而不是直接去修被點名的那顆。
3. 遇到 recovery 停滯，**先試 `ceph pg repeer`**——它便宜、精準、不破壞；
   重啟 OSD 或重開機都是更重的手段，而且在本案完全無效（問題不在任何一台機器上）。

### H-030：watchdog 在沒有 OSD down 時會盲選節點，重開了無關的健康機器

**狀態**：confirmed（真機實測，2026-07-28）

`_pipeline_stuck_node` 的邏輯是「找第一顆不是 up+in 的 OSD，回傳它的 node」。
H-029 的情境裡**八顆全部 up+in**（卡的是 PG recovery，不是任何一台機器），
於是迴圈找不到目標，直接掉到 fallback `inv_names osd | head -1` ——
**回傳 inventory 的第一台**。watchdog 因此 `sudo reboot` 了 `mclock-osd-1`，
一台跟問題毫無關係的健康節點。重開當然無效，再失敗一次就把 cell 標成 needs-human。

**兩個修正**：
1. `pg-no-progress` 的升級階梯**第一段改成 `pg-repeer`**（原本第一段就是 restart
   OSD）。repeer 便宜、精準、不動 daemon，而且在 H-029 裡是唯一有效的手段。
   階梯變成 repeer → osd restart → node reboot → az restart → human。
2. fallback 不可盲猜：先問「卡住的 PG 的 primary 是誰」（`acting_primary`），
   由它反查 node；真的問不出來才退回第一台，**並在 log 明講這是猜測**。

**修 H-030 的過程中差點自己種下更糟的缺陷**：第一版的 repeer 對「所有非 active+clean
的 PG」下手。拿真機資料一驗才發現，一次 osd-down 期間有 **46 個 PG 處於
`backfill_wait`/`backfilling`**——那是合法的大量資料搬移，對它們 repeer 會把已完成的
backfill 進度打掉重來，**比不修還糟**，而且正好會發生在這個實驗要跑的每一個故障型上。
合成 fixture 完全測不出來（我的 fixture 裡只有 recovering）。改成 allowlist：
只挑 `recovering`/`peering`/`activating`/`stale`/`incomplete`/`down`/`unknown`，
其餘一律不碰，並把略過的數量寫進 stderr（靜靜跳過與「沒有這些 PG」在輸出上無法區分）。

**可複用的原則**：自動修復的**目標選擇**和修復動作本身一樣需要被檢驗。
「找不到目標就拿第一個」在測試裡永遠看不出問題（測試都會先安排一顆壞掉的 OSD），
但在真機上它會去動一台完全無辜的機器——**破壞性動作配上猜測的目標，是最糟的組合**。

### H-031：故障 cell 的主指標本來會全部是 null（baseline 窗被 coverage 窗夾成零寬）

**狀態**：confirmed（真機第一個完成的故障 cell，2026-07-28）

`osd-down-4k-extreme+high_client_ops` 是第一個完整走完的故障 cell。verdict 產出後，
兩個關鍵 endpoint 是 `null`：

- `p99_degradation_ratio` ——**跨 profile 比較的主指標**
- `time_to_recovery_complete_s` ——恢復速度，故障階段的另一根支柱

**成因一（主指標）**：aggregate 用 coverage-proof 的窗當 `win_start`，而 pipeline 把
coverage 窗的起點設成 `fault_t0`（supervisor 從注入那刻才開始打卡，對覆蓋證明是對的）。
故障前 baseline 窗算的是 `max(win_start, fault_t0 - 60) .. fault_t0 - 1`，
於是變成 `start > end` 的**零寬窗**——而 fio 序列裡明明有 54 秒的故障前資料
（readiness barrier 期間就在跑）。coverage 窗證明的是「量測窗無缺口」，
**不該拿來界定參考基線**。改用實際觀測序列的起點 `obs_start` 為下界後，
baseline 窗補回 54 秒，主指標算出 **1.093**（故障期間 p99 惡化 9.3%）。

**成因二（恢復時間）**：`ceph_wait_recovery_complete` 會印
`recovery-complete: reached <epoch>`，但呼叫端只把它 `>&2` 丟掉、**只用回傳碼**，
時間戳從未寫進 `fault-timeline.json`。於是 `recovery_complete_t` 永遠不存在，
即使 `censor-status.json` 已判定 `censored=false`（恢復確實完成了）。
修法：呼叫端捕捉 stdout，`reached` 時把時間戳寫進 timeline；另加一條 fallback——
未被 censor 的 cell 用 `observed_end - fault_t0` 推導（量測迴圈就是等到 recovery
完成才跳出、跳出後立刻記 win_end，差在秒級輪詢），既有 bundle 因此也算得出來。

**為什麼值得記**：這兩個都不會讓任何東西報錯。pipeline 全綠、`verdict: RECORDED`、
`censored=0`，一切看起來成功——只是**主指標是空的**。若沒在第一個 cell 就逐欄看
endpoints，72 個故障 cell 跑完才會發現整個故障階段沒有可比較的數據。
**「跑完了」和「量到了」是兩件事，要分開驗。**

**附帶**：這輪又抓到一個空過的測試——`jget` 對 `None` 印的是 `"null"` 而不是
`"None"`，我的斷言寫成 `!= "None"` 於是永遠成立。mutation 一跑就現形。

### H-032：安全網 guard 的「已觸發」標記會誤判，成因是我自己先前的修正

**狀態**：confirmed（真機 rack-isolation pilot，2026-07-28）

隔離型故障（node / rack）在套規則之前會先在目標節點武裝一支 guard：
`sleep N; iptables -F; date +%s > <guard>.fired`。`.fired` 存在 = 安全網先於正常
heal 動作 = attempt 作廢（taint）。

真機上 rack-isolation 在 heal 當下被判 `guard-fired`——**距真正的 guard 期限還有
1582 秒**。若不修，每個 node-isolation 與 rack-isolation cell 都會被誤 taint，
也就是 72 個故障 cell 裡的 36 個。

**成因（是我自己種下的迴歸）**：正常 heal 會先 `remote_bg_stop` 殺掉 guard。而我先前
為了修「`kill -TERM -<pgid>` 會連帶殺掉自己的 ssh session」而改寫的 `remote_bg_stop`，
順序是**先 `pkill -P`（殺子代）再 `kill`（殺父）**。對 guard 這種
「前景 sleep + 後續動作」的腳本，殺掉前景的 `sleep` 等於**放行**——父 shell 立刻
執行下一行，flush 並寫下 `.fired`。於是 heal 把自己 kill guard 的動作，
誤讀成安全網先觸發。

**兩處修正**：
1. `.fired` 只在 **sleep 真的睡滿**時才寫：`if sleep N; then ... fi`。
   sleep 被殺 → 非 0 回傳 → 不留標記。這條才是真正的不變條件，與誰先被殺無關。
2. `remote_bg_stop` 改成**先父後子**。非互動 bash 收到 TERM 時會在前景子程序結束後
   才處理，因而直接終止、不會再往下走一行。

**可複用的原則**：修一個 bug 時改動的是**共用的 chokepoint**，就要把所有依賴它的
語意重新過一遍。`remote_bg_stop` 原本的 pgid 殺法對 fio 是錯的、對 guard 是對的；
我只驗了 fio。**「這個修正在我測的那條路徑上是對的」不等於「它在所有路徑上都是對的」。**

**附帶（第二個空過的測試）**：我為此寫的行為測試同時殺了 sleep 與父 shell，
而本機上父 shell 幾乎總是先死，marker 自然不出現——測試永遠會過。
改成**只殺 sleep**、讓父 shell 活著跑完，才真的驗到那條不變條件。
mutation 一跑就現形：修正前後差別在此。

### H-033：H-029 可重現，且嚴重到會拖垮 client 工作負載本身

**狀態**：confirmed（真機故障佇列第一個 flapping cell，2026-07-29）

H-029（flapping 讓 PG 的物件永久卡在 recovering）**不是一次性巧合**。完整故障佇列
跑的第一個 flapping cell（`flapping-4k-low+balanced/r1`）重現了完全相同的結構，
而且後果更嚴重。證據存於 `results/evidence/H033-*`：

- PG 2.6d `active+recovering+undersized+degraded+remapped`，
  **`up=[7,4,0]` 但 `acting=[7,4]`**——被 flap 的 osd.0 進得了 up、進不了 acting
- primary（osd.7）的 `recovering` 清單卡著 3 個物件，`backfill_targets` 空、
  `might_have_unfound` 兩個 peer 都 `already probed`（不是 unfound）
- osd.7 有 **23 個 client op 阻塞 2796 秒**，`flag_point: waiting for rw locks`，
  目標物件正是 `recovering` 清單裡的第一個
- 另有 46 個 PG 排在 `recovery_wait`——**全部被那一個卡住的 PG 擋住**

**比 H-029 更嚴重的兩點**：

1. **client 工作負載本身被拖垮**：`mclock-client-3` 的 fio 在第 3 段之後就再也沒完成
   任何一段（其餘三台完成 9 段），卡了 28 分鐘，STOP 因此收不到、exit-code 寫不出來
   → `fio-stop: FAIL 1`。fio 不是「變慢」，是**整個 hang 在半路**（krbd 的 IO 落在
   那顆卡住的物件上，D-state 無限期等待）。
2. **recovery 從頭到尾沒完成過**：整個量測窗都是 `recovery-complete: censored`，
   最後撞上 measurement cap。也就是說在這個 cell 裡，**flapping 造成的不是「恢復變慢」，
   而是「恢復永遠不會結束」**——除非人工 `ceph pg repeer`。

**對報告的意涵**：這已經不是 mClock profile 的比較問題，而是**flapping 這個故障型
本身的一個 Ceph 行為**：反覆 stop/start 同一顆 OSD 有機率讓某個 PG 進入
「up 有它、acting 沒有它、recovering 清單卡死」的狀態，此後
（a）打到那些物件的 client IO 無限期 hang，
（b）該 PG 後面的 recovery 佇列全部停擺，
（c）叢集層面只顯示極小的 degraded 百分比 + 一行 SLOW_OPS，而 SLOW_OPS 點名的是
     PG primary（受害者），不是被 flap 的那顆。

**與 campaign 的關係**：harness 的 watchdog 已在 `pg-no-progress` 的第一段加了
`pg-repeer`（H-030），且 allowlist 只挑 `recovering` 一類、**不碰 `recovery_wait`**——
本案正好只需 repeer 那 1 個真正卡住的 PG，其餘 46 個會自己跟上。這條修正的正確性
在這裡得到獨立驗證。

### H-034：coverage supervisor 在故障期間系統性遲到，10s 容忍值本來就達不到

**狀態**：confirmed（真機故障佇列，2026-07-29）

故障佇列的前兩個 flapping cell 連續被判 `coverage-proof 標記 tainted`。追下去發現
taint 的**不是** client 卡住（那是 H-033，只寫 log 不 taint），而是
**單一一個 14 秒的 supervisor 缺口**超過 `COVERAGE_GAP_TOLERANCE_SECS=10`。

**先量再修**（不是直接放寬門檻）：

| | supervisor 缺口 |
|---|---|
| 穩態（79 個 attempt） | 只出現過 1 次、13s |
| 故障 | n=19，中位數 1s、**p90 17s**、最大 19s，**15.8% 超過 10s** |

再看檢查間隔本身：故障 attempt 的**實際平均檢查間隔是 40.0s**（範圍 32.7–43.6），
而 cadence 設定是 30s——**系統性慢了三分之一**。也就是說 10s 的容忍值在故障模式下
本來就達不到，這是量測儀器自己的抖動，不是被測系統的行為。

**成因（結構性）**：量測迴圈每個 tick 依序做 coverage 檢查 → sampler 檢查 →
`ceph_wait_recovery_complete <slice>`，而該函式
（a）**先查詢、後檢查期限**，
（b）超時前還會**睡滿一整輪 `POLL_INTERVAL`**，醒來再多打一次 `ceph -s` 才發現超時。
呼叫端把等待切成 5s 的 slice 正是為了讓 coverage 跑得到，結果每個 slice 多花
「一次 ssh 往返 + 一輪睡眠」——故障期間 `ceph -s` 變慢，檢查就遲到十幾秒。

**修法（修因不調門檻）**：睡眠夾到 deadline（`min(POLL_INTERVAL, 剩餘)`，因為測試
環境的 `POLL_INTERVAL` 是小數 0.05，取 min 要用 `awk` 不能用 `[ -gt ]`），
且超時後**不再多打一次查詢**。這移除了每個 tick 多出的一整次 ceph 查詢。

**若殘餘仍超過容忍值**：那就代表 30s cadence 在故障模式下確實達不到，
屆時應**依實測抖動**重新指定故障模式的容忍值並在報告中說明，
而不是假裝 10s 是可達的。門檻要反映儀器的真實能力，這與「為了讓測試過而放寬」不同。

**方法論**：這條的價值在診斷順序——最顯眼的症狀（`fio-stop: FAIL`）不是肇因。
先確認「誰真的讓 cell 失效」（taint reason），再量那個量的分布，最後才動手。

### H-035（修正 H-034 的診斷）：flapping coverage taint 的真因是「注入期間沒人打卡」

**狀態**：confirmed（真機故障佇列，2026-07-29）

H-034 把 flapping 的 coverage taint 歸因於 supervisor 抖動（實際檢查間隔 38-40s
vs cadence 30s）。**那個歸因是錯的**——它是真實現象，但不是這些 cell 被作廢的原因。

修掉抖動的一部分之後（40.0s → 38.2s）cell 仍然 taint，才看到真正的理由：

```
taint_reasons = ['supervisor 中斷 560s（>= 容忍值 25s）',
                 '量測工具中斷總量 560s > 30s']
evidence = [{'duration_s': 560, 'reason': 'no-check', 'source': 'supervisor',
             'start': <窗起點>, 'end': <窗起點+559>}]
```

**coverage 窗從 `fault_t0` 起算，但 supervisor 的第一次打卡在 560 秒之後。**
那 560 秒正是 flapping 注入本身的時間（10 輪 stop/start + 每輪 PG gate ≈ 9 分鐘）：
注入是同步執行的，量測迴圈要等它回來才開始 tick，**所以注入全程沒有任何人在打卡**。
osd-down / node-isolation 的注入只要幾秒到幾十秒，所以從沒暴露；flapping 必然中招。

**修法**：在 `with_deadline`（全 harness 共用的輪詢等待點）加一個預設 no-op 的覆寫點
`progress_tick`，pipeline 在量測窗一開始就把它覆寫成「打 coverage + sampler 卡」。
於是注入期間的每一次輪詢等待都會讓 supervisor 繼續打卡。

**配套（各自獨立驗證）**：
1. **devstat 逐秒紀錄算進「有量測證據的秒」**。它與 fio 獨立、IO 為零也照記，
   證明的是「那一秒儀器活著在量」而非「那一秒有 IO」，所以只消除假盲區、
   不會遮蔽 stall（stall 仍由 fio 逐秒資料判定）。真機那 12 秒「盲區」裡，
   四台 client 的 devstat 各有 12/12 筆樣本——證據一直都在，只是判定沒用它。
2. 故障模式的 `COVERAGE_GAP_TOLERANCE_SECS` 由實測解析度定為 25s（穩態維持 10s）。
   一個監督週期的成本是「coverage + sampler + 一次 ceph -s」全走 ssh，受壓叢集上
   實測 13-19s，10s 從來就達不到。**只放寬故障模式、只放寬 supervisor 的量級**；
   sampler / fio 心跳的判定完全不動。

**中途差點犯的錯（值得記）**：我一度把 taint 判定從原始 `evidence` 改成精煉的
`gaps`（中斷 ∩ 該秒無資料）。跑測試才發現 test 20 與 test 23 明確斷言
「sampler 中斷 40s 但 fio 還在寫 → 仍要 taint」「supervisor 稀疏 → 證據不足」——
**那是刻意的 gate，我差點為了讓 cell 過關而把它弱化**。已退回，改成只修真因。
測試在這裡發揮了它該有的作用：擋住作者本人的便宜行事。

**方法論**：H-034 → H-035 是一次「歸因錯誤」的完整記錄。第一次診斷找到的是
**真實但非決定性**的因素（supervisor 確實會抖），修了它、現象沒消失，才逼出真因。
教訓：**修完要回頭確認現象真的消失**；沒消失就代表歸因還沒到位，不能只因為
「我修的東西確實是個問題」就收工。

### H-036：函式覆寫是全域的，跨 execution 殘留會在下一輪的錯誤時機觸發

**狀態**：confirmed（真機故障佇列，2026-07-29）

H-035 的修法是在量測窗開始時把 `progress_tick`（common.sh 的預設 no-op 覆寫點）
換成「打 coverage + sampler 卡」。**bash 的函式覆寫是全域且永久的**——不還原的話，
下一個 execution 的早期階段也會觸發它，而那時 sampler 還沒啟動：

```
[21:01:47] execution 開始：flapping-4k-low+high_client_ops/r2 ...
[21:01:48] set-profile: SET high_recovery_ops high_client_ops
[21:01:48] FATAL: coverage_check：sampler 尚未啟動（缺 .../sampler/run.json）
```

第一個 execution 完全正常、第二個一開始就 FATAL——整個 runner 死掉。

**修法**：`_pipeline_reset_runtime_state` 與每個 execution 起頭都把 `progress_tick`
還原成 no-op。

**H-035 修正本身確認有效**（重啟後的 coverage-proof，用時間戳過濾確保是修正後的產物）：

| | 修正前 | 修正後 |
|---|---|---|
| 第一次打卡距窗起點 | 560s / 484s | **6s** |
| gaps | 7–9 | **0** |
| evidence_seconds | 484–560 | **10** |
| tainted | True | **False** |

**這是第四次「修正本身造成迴歸」**（前三次：H-032 殺 process 順序、H-034 錯誤歸因、
progress_tick 放在判定之後）。共同結構都是**改動共用的東西時只驗證了自己在意的那條
路徑**：
- H-032：`remote_bg_stop` 的殺法對 fio 是對的，對 guard 是錯的
- H-036：`progress_tick` 在量測窗內是對的，在 execution 早期是錯的

**可複用的原則**：共用機制的改動要問兩個問題——「**誰還會走到它**」以及
「**它的生命週期到哪裡結束**」。前者是 H-032，後者是 H-036。只問「我要的那條路徑
對不對」永遠會漏掉另一半。

### H-037：被故障卡住的 client 讓收尾 tar 回 rc 1，被誤當致命錯誤

**狀態**：confirmed（真機故障佇列，2026-07-30）

一個 flapping cell 在量測結束、撞上 measurement cap 之後，收尾階段直接 FATAL：

```
[14:54:17] 撞 measurement cap（right-censored——是有效觀測，不是失敗）
tar: .: file changed as we read it
[15:01:15] FATAL: fio 輸出回收失敗：mclock-client-1
```

**成因**：`_fio_fetch` 用 `tar cf - .` 打包遠端 workdir，而被 H-033 卡住的 fio
**停不下來、會持續寫 log**，於是 tar 讀到變動中的檔案回 **rc 1**。
tar 的 rc 1 語意是「archive 已建立，但有檔案在讀取期間被改動」——**archive 仍然完整**；
rc >= 2 才是真正的錯誤。原本的 `|| die` 不分青紅皂白，等於
**「因為量到了要量的現象，所以把該次量測整個丟掉」**。

**修法**：遠端只在 `rc >= 2` 時才回非 0；rc 1 照常收下（stderr 的警告仍會進 log，
不靜靜接受）。

**這是 H-033 第三次打破 harness 的假設**，前兩次分別是：
1. `fio-stop: FAIL`（STOP 送不到卡住的 client）→ 已區分「TIMEOUT + 心跳仍活 = 被卡住
   （有效觀測）」與「非 0 exit code = 崩潰（作廢）」
2. coverage 盲區（卡住的 client 不產 fio log）→ 已用 devstat 的逐秒紀錄補上證據

**可複用的原則**：當被測系統的**故障現象**會反過來干擾量測工具本身時，工具的每一個
「異常即失敗」判斷都要重新檢視一次——因為那個異常很可能正是實驗要捕捉的東西。
這類地方的正確做法是**分辨嚴重度**（tar rc1 vs rc2、TIMEOUT vs 非 0 exit），
而不是一律作廢，也不是一律容忍。
