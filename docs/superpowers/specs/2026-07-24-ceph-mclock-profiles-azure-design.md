# Ceph mClock profile 對照實驗（Azure 真機）— 設計（spec）

> 日期：2026-07-24
> 方法論：`skills/researching-system-behavior/SKILL.md`（Frame → Enumerate → Falsify → Automate → Synthesize）
> 目標版本：**Ceph v19.2.2**（實機部署與原始碼引用皆以 v19.2.2 為準；repo submodule pin 維持 v19.2.3 不動，讀碼用 `git show v19.2.2:<path>`）
> 產出：`experiments/ceph-mclock-profiles/` 完整實驗報告（`skills/writing-experiment-reports` 五欄格式 + 參數建議總表）
> 環境：Azure japanwest（SKU 可用性掃描後唯一可行 region；使用者已調升 cores quota 至 95）

## 1. 研究問題

比較 mClock 三個內建 profile（`balanced` / `high_client_ops` / `high_recovery_ops`），回答：

1. **參數面**：每個 profile 具體設定了哪些參數？這些參數在 scheduler 機制上各自控制什麼？
2. **行為面**：在低／中／高／極端四級 IO 壓力下，profile 對 client IO（IOPS、latency 百分位）與 recovery/backfill（速度、time-to-clean）的取捨曲線長什麼樣？
3. **故障面**：OSD flapping、OSD down、node down、rack down 各情境下，profile 差異如何呈現？
4. **極限面**：極端壓力 + 連續隨機故障（chaos）下，各 profile 的退化與恢復力差異。

使用者原始關注 = balanced vs high_client_ops；high_recovery_ops 全矩陣同跑，作為光譜另一端錨點。

## 2. 原始碼基礎（v19.2.2，已驗證的起點事實）

`src/osd/scheduler/mClockScheduler.cc:337-373`（`set_config_defaults_from_profile()`）定義三個 profile，每個 profile = 3 個 client class × (reservation, weight, limit)：

| profile | client (res/wgt/lim) | background_recovery | background_best_effort |
|---|---|---|---|
| `balanced`（預設） | 50% / 1 / max | 50% / 1 / max | 0 / 1 / 90% |
| `high_client_ops` | **60% / 2 / max** | **40% / 1 / max** | 0 / 1 / **70%** |
| `high_recovery_ops` | 30% / 1 / max | 70% / 2 / max | 0 / 1 / max |

- res/lim 是 **OSD IOPS capacity（per shard）的百分比**；capacity 來自 OSD 啟動時的 osd bench 自動量測（`osd_mclock_max_capacity_iops_ssd`），寫入 mon config store。
- 九個底層參數：`osd_mclock_scheduler_{client,background_recovery,background_best_effort}_{res,wgt,lim}`（`mClockScheduler.cc:400-422` 逐一 `set_val_default`）。
- `osd_mclock_profile` 可 runtime 切換（`ceph config set osd` 即生效，不需重啟）。

**Frame 階段要補完的機制題**（進 HYPOTHESES.md）：
- dmclock 演算法中 res/wgt/lim 三段式的實際排序邏輯（reservation phase → weight phase，limit 上限）——引 `src/dmclock/` 對應實作。
- 大 IO 的成本換算：`osd_mclock_max_sequential_bandwidth_ssd` 與 `calc_scaled_cost()`（`mClockScheduler.cc:427-436`）如何把 1M 寫換算成 IOPS 成本 → 1M seq 形態下 profile 差異的預測基礎。
- mClock 模式下 `osd_max_backfills` / `osd_recovery_max_active` 被鎖定的機制與預設值（`osd_mclock_override_recovery_settings`，`osd.yaml.in`）——recovery 併發度是 profile 之外的另一個自由度，實驗全程保持鎖定預設，只動 profile。
- capacity 量測失真防線：`osd_mclock_iops_capacity_threshold_ssd`（量出離譜值時 fallback 行為）。
- SnapTrim / scrub 落在 best_effort class 的證據（best_effort lim 90% vs 70% 差異何時可觀測——本實驗不主測，標註為已知邊界）。

## 3. 環境設計（Azure japanwest）

### 3.1 拓撲

| 角色 | SKU | 數量 | vCPU 小計 | 備註 |
|---|---|---|---|---|
| OSD node | Standard_L8s_v3（8 vCPU / 64G / 1.92TB local NVMe） | 8 | 64 | 1 OSD/node（不切分 NVMe）；CRUSH：**4 racks × 2 nodes** |
| mon/admin | Standard_D4s_v5 | 1 | 4 | mon.a + mgr + prometheus（cephadm 內建 monitoring stack）+ 指揮所 |
| mon | Standard_D2s_v5 | 2 | 4 | 3-mon quorum；故障實驗不碰 mon |
| fio client | Standard_D8s_v5 | 2 | 16 | librbd fio；跟 OSD 分離避免 CPU 互搶 |
| **合計** | | 13 | **88** | quota 上限 95（cores）；**前提：使用者先刪 `CYSHIH-KUBEVIRT-CEPH-LAB`（釋出 60）** |

- SKU 可用性（2026-07-24 實掃）：L8s_v3 僅 japanwest 對本 subscription 開放（eastasia / southeastasia / japaneast 皆 NotAvailableForSubscription，koreacentral 無此 SKU）。
- replica 3、failure domain = **rack**。4 racks 的理由：rack down 後仍有 3 個 rack 可容納第三副本 → 觸發真 backfill；3 racks 拓撲下 rack down 只會卡 degraded（無 backfill 目標），測不到「rack 級 backfill vs client IO」。
- 資料填充 ~25–30%（讓單 OSD backfill 在 15–30 分鐘量級收斂：有意義又不拖垮時窗；實際填充量 Phase 0 校準時定案）。
- on-demand 計價，不用 Spot（Spot 驅逐 = 不受控的故障注入，污染實驗）。
- ceph 部署：**cephadm**，指定 image 版本 v19.2.2（與家中 lab 操作慣例一致）。

### 3.2 成本框架

- 全叢集 ≈ US$6.5–7.5/hr（L8s_v3 ×8 為主）。
- **整個 campaign 連續開機不落地**（使用者裁示：24–72 小時的連續運轉在預算內，省掉重建/重校準比省閒置錢重要）；估 48–72 小時 wall-clock → **約 US$350–550**；天花板 US$1000。
- 唯一落地時機 = watchdog 停損（見 §7）；**Lsv3 local NVMe 在 deallocate 後資料消失** → provision/deploy script 仍要冪等可重入（停損後重建 ~40 分鐘含重灌資料）。

## 4. 壓力等級定義（校準先行）

Phase 0 在 HEALTH_OK、目標 profile 下量出兩種形態的飽和點（peak）：

| 等級 | 定義 | fio 實作 |
|---|---|---|
| 低 | 25% × peak | `--rate_iops` 固定速率 |
| 中 | 50% × peak | 固定速率 |
| 高 | 80% × peak（接近膝點） | 固定速率 |
| 極端 | 不限速，高 iodepth × 多 job 過飽和 | throughput-seeking |

- 低／中／高固定供給速率 → latency 是乾淨因變數；極端反轉為看 mClock 在過飽和下的配額行為。
- 兩種形態：**4K randrw**（latency 敏感、IOPS 型）與 **1M seq write**（頻寬型、走 cost 換算路徑）。
- 校準同時驗證 mclock 量到的 `osd_mclock_max_capacity_iops_ssd` 合理（對照 fio 裸盤數據；離譜即先處理再開跑——這本身是一條 hypothesis）。

## 5. 實驗矩陣（63 組）

| 區塊 | 維度 | 組數 |
|---|---|---|
| 穩態 | 3 profiles × 4 壓力 × 2 形態（randrw / seq） | 24 |
| 故障 | 3 profiles × 3 壓力（低/中/極端） × 4 故障 | 36 |
| chaos 終局 | 3 profiles × 極端壓 × 固定 seed 隨機故障序列 | 3 |

故障四型（皆以 4K randrw 為量測負載）：

| 故障 | 注入 | 回復觸發 | 觀測重點 |
|---|---|---|---|
| OSD flapping | 單 OSD daemon stop/start 循環（down 30s / up 60s × 10 輪） | **不 out**（保留預設 `mon_osd_down_out_interval=600s`；flapping 本就不應觸發 out） | 反覆 peering + log-based recovery 對 client latency 的衝擊 |
| OSD down | stop 單 OSD daemon | down 後**立即手動 `ceph osd out`** → backfill 起點對齊 | backfill 速度 vs client IO 分配 |
| node down | OS 層 poweroff 單一 OSD node（**不可 deallocate**——NVMe 會被清空，性質變成永久換機） | 手動 out ×1 node 的 OSD | 2 OSD 同時 backfill |
| rack down | poweroff 同 rack 2 台 node | 手動 out ×2 nodes | 最大規模 backfill（~1/4 資料遷移）下的 QoS 行為 |

- 每組故障實驗結束：OSD/node 回歸 → `ceph osd in` → 等回填收斂 → `HEALTH_OK` + baseline latency 復測通過 → 才進下一組（回復期為嚴謹性成本，計入時間預算）。
- chaos：固定 seed 的隨機故障序列（隨機挑 OSD kill/restart、隨機 node reboot、隨機間隔，20–30 分鐘），三個 profile 重播**同一序列**保可比性；定位為 showcase，不做嚴格歸因。
- 報告須註明：手動 out 的組別在生產環境要外加 600s 的 mark-out 等待期。

## 6. 量測與判準

- **client 面**：fio JSON——IOPS/BW、lat p50/p99/p99.9/max、逐秒 time series（`--log_avg_msec`）。
- **recovery 面**：`ceph pg dump` / `ceph -s` 差分——recovering objects/s、bytes/s、degraded% 曲線、time-to-clean。
- **叢集面**：cephadm 內建 prometheus（OSD op latency 分佈、SLOW_OPS、mclock 相關 perf counters）；每組附 `ceph config dump` 生效驗證（九個 mclock 參數 = 該 profile 預期值，違者作廢該組）。
- **判準**：prediction 先行（每組先寫預測再跑）；n≥2（穩態組 n≥3）；三態 verdict `confirmed / violated / indistinguishable`（沿用 rbd-io-perf 的 verdict 機器比對慣例）。

## 7. 執行模式（單一連續 campaign）

使用者裁示：**開機後一路跑到完、不落地**（24–72h 連續運轉在預算內）；只在「實驗失敗卡住」時停損避免浪費。三個 stage 只是邏輯分段，不是關機邊界：

| Stage | 內容 | 累計 wall-clock |
|---|---|---|
| S1 | provision → cephadm 部署 → burn-in → Phase 0 校準 → 穩態 24 組 | ~10–12h |
| S2 | 故障 36 組（緊接 S1，沿用同一次校準） | ~38–44h |
| S3 | chaos 3 組 → 補跑異常組 → 資料齊收 → **刪除整個 RG** | ~48–60h |

- 全自動 run queue：組間零人工等待；每組 hard timeout，逾時收集現場 → 標 skip → 續行。
- **watchdog 停損（唯一落地時機）**：佇列停滯 >60 分鐘且自動修復無效 → 自動 deallocate 全部 OSD node 止血；修復後重建（~40 分鐘）從斷點續跑（bundle 存在即跳過，沿用 rbd-io-perf 慣例）。
- 每種實驗類型的第一組跑完先過人工檢查（分佈合理才放行整批）——防系統性錯誤污染整夜。
- 夜間 Azure API 操作（node down 的 stop/start）內建 retry。
- 分工：az CLI provisioning script 我寫我跑；實驗我從 bastion ssh 執行；**quota 調升與舊 lab 刪除由使用者親手**，我不碰 `CYSHIH-KUBEVIRT-CEPH-LAB`。

## 8. Harness 架構

```
experiments/ceph-mclock-profiles/
├── HYPOTHESES.md            # charter + 假說 backlog（Frame 產出）
├── README.md
├── azure/
│   ├── provision.sh         # az CLI：RG/VNet/VM/NSG；冪等可重入；tag 標記成本歸屬
│   ├── teardown.sh          # 整 RG 刪除（S3 收尾）與 deallocate（watchdog 停損用）
│   └── inventory.sh         # 產出 IP/host 清單給 lib/ 使用
├── lib/
│   ├── common.sh            # ssh 向量、log→stderr、die、bundle helper（沿用家規）
│   ├── ceph.sh              # cephadm bootstrap/add-host/OSD、profile 切換+生效驗證、osd out/in
│   ├── inject.sh            # 四型故障注入 + chaos 序列（固定 seed）+ 回退
│   ├── fio.sh               # 校準、四級壓力 render、n 輪執行
│   ├── collect.sh           # fio JSON、pg dump 差分、prometheus 快照、config dump
│   └── verdict.py           # 三態比對（bastion python3）
├── run/
│   ├── calibrate.sh         # Phase 0
│   ├── steady.sh            # 穩態 24 組佇列
│   ├── faults.sh            # 故障 36 組佇列（含回復 gate、watchdog）
│   ├── chaos.sh
│   └── all.sh
├── tests/                   # fake az/ssh/ceph + fixtures；run-tests.sh
└── results/                 # git-ignored evidence bundles；EVIDENCE-SUMMARY 進 git
```

家規全數適用：bash 3.2、TDD、shellcheck 0、stdout 只放機器行、mutating script 要 `--yes-really-inject`。

## 9. 階段與 gates

| Phase | 內容 | Gate |
|---|---|---|
| 1 Frame | v19.2.2 讀碼補完 §2 機制題 → HYPOTHESES.md（每條附預測） | 假說 backlog 過使用者一眼 |
| 2 Automate | harness + tests 全綠（純本機，fake 外部指令） | tests + shellcheck + `make validate` 全綠 |
| 3 S1 | **Gate：使用者確認舊 lab 已刪、quota 就緒、說 go** → provision → 校準 → 穩態 24 組 | 校準結果 + 首組人工檢查通過 |
| 4 S2/S3 | 故障 36 組 → chaos → 收資料 → 刪 RG | 每型首組人工檢查；watchdog 全程 |
| 5 Synthesize | 完整報告（五欄 + 參數建議總表 + 主管 persona review）；HYPOTHESES.md 收斂 | 報告過 `writing-experiment-reports` gate |

## 10. 風險與邊界

- **成本失控**：watchdog 停損 + S3 結束整 RG 刪除；連續 campaign 期間每 12 小時回報一次累計花費與進度。
- **雲端噪音**：Azure 共享基礎設施的鄰居效應——穩態組 n≥3 + 逐秒 time series 可辨識異常輪；異常組進 S3 補跑清單。
- **capacity 量測失真**：Phase 0 對照 fio 裸盤數據把關；必要時 `osd_mclock_force_run_benchmark_on_init` 重測（這條本身就是發現）。
- **絕對數字不可外推**：結論以「同環境內 profile 相對差異」為準；絕對 IOPS/latency 標註僅適用此拓撲。
- **mon 單薄**：3 mon 但 2 顆是 D2s_v5 小機——故障實驗不碰 mon node；若 mon 異常即暫停佇列（watchdog 條件之一）。
- **版本**：實機 v19.2.2 = 引用基準 v19.2.2，無漂移；與 submodule pin（v19.2.3）差異在報告註記一次。

## 11. 驗收標準

1. `bash experiments/ceph-mclock-profiles/tests/run-tests.sh` 全綠；`shellcheck` 0；`make validate` exit 0。
2. 63 組（±補跑）evidence bundle 齊備，`EVIDENCE-SUMMARY-<date>.md` 索引進 git；每組含 prediction、config dump 生效驗證、verdict。
3. 完整報告落地：三 profile 參數對照（source 錨點）、四級壓力取捨曲線、四型故障 + chaos 對照、參數建議總表（含「何時選哪個 profile」的裁決樹）。
4. Azure RG 已刪除、費用總結回報（≤ US$1000）。
5. HYPOTHESES.md 所有 P0/P1 條目離開 proposed。
