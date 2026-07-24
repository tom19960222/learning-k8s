# Ceph mClock profile 對照實驗（Azure 真機）— 設計（spec）

> 日期：2026-07-24（rev 2：套用 codex gpt-5.6-sol high review 21 條 findings；rev 3：krbd datapath、單 NIC 網路設計、node 故障改 ssh-native 網路隔離、stall/brownout 判準、完全自主執行；rev 4：provisioning 改由 IaC agent 依 PROVISIONING-REQUIREMENTS.md 實作；rev 5：套用 plan review 波及 spec 的修正——clean 判準、capacity 順序+skip_benchmark、fio segment 續跑、adaptive grace 裁決、生效驗證強化、node loss 命名統一；rev 6：兩層 clean 判準（recovery-complete vs final-clean）、故障 replicate 改 workload 先行、fault_t0 絕對時間軸、殘留 HEALTH_OK/power-off 清除；rev 7：degradation ratio 分母改 within-replicate 注入前健康窗、雙軌 margin（noise + production 預註冊門檻）、mon repair vs injection 釐清）
> 方法論：`skills/researching-system-behavior/SKILL.md`（Frame → Enumerate → Falsify → Automate → Synthesize）
> 目標版本：**Ceph v19.2.2**（實機部署與原始碼引用皆以 v19.2.2 為準；repo submodule pin 維持 v19.2.3 不動，讀碼用 `git show v19.2.2:<path>`）
> 產出：`experiments/ceph-mclock-profiles/` 完整實驗報告（`skills/writing-experiment-reports` 五欄格式 + 參數建議總表）
> 環境：Azure japanwest（SKU 可用性掃描後唯一可行 region；使用者已調升 cores quota 至 95）

## 1. 研究問題

比較 mClock 三個內建 profile（`balanced` / `high_client_ops` / `high_recovery_ops`），回答：

1. **參數面**：每個 profile 具體設定了哪些參數？這些參數在 scheduler 機制上各自控制什麼？
2. **行為面**：在低／中／高／極端四級 IO 壓力下，profile 對 client IO（IOPS、latency 百分位）與 recovery/backfill（速度、time-to-clean）的取捨曲線長什麼樣？
3. **故障面**：OSD flapping、OSD down、node loss（network-isolation）、synthetic CRUSH-rack loss 各情境下，profile 差異如何呈現？
4. **極限面**：極端壓力 + 連續隨機故障（chaos）下，各 profile 的退化與恢復力差異。

使用者原始關注 = balanced vs high_client_ops；high_recovery_ops 全矩陣同跑，作為光譜另一端錨點。

## 2. 原始碼基礎（v19.2.2，已驗證的起點事實）

`src/osd/scheduler/mClockScheduler.cc:337-373`（`set_config_defaults_from_profile()`）定義三個 profile，每個 profile = 3 個 client class × (reservation, weight, limit)：

| profile | client (res/wgt/lim) | background_recovery | background_best_effort |
|---|---|---|---|
| `balanced`（預設） | 50% / 1 / max | 50% / 1 / max | 0 / 1 / 90% |
| `high_client_ops` | **60% / 2 / max** | **40% / 1 / max** | 0 / 1 / **70%** |
| `high_recovery_ops` | 30% / 1 / max | 70% / 2 / max | 0 / 1 / max |

**機制定位（rev 2 修正）**：res/lim 是**無因次 scheduler ratio**，不是「實體 IOPS × 百分比」的硬配額。Classic OSD 把 ratio 乘上 `osd_mclock_max_sequential_bandwidth_* / num_shards` 換算成 per-shard 的 cost/s（`mClockScheduler.cc:152-185,250-275`）；`osd_mclock_max_capacity_iops_*` 則透過 `sequential_bandwidth / IOPS` 決定每筆 op 的最低成本（`calc_scaled_cost()`，`mClockScheduler.cc:427-436`）。語意：**reservation = 最低保障、weight = 剩餘 capacity 的比例分配、limit = 上限**（lim=0 表示不設限；classic OSD 用 `AtLimit::Wait`）。三個 profile 的 client lim 都是 max —— 無競爭時 client 理論上可借滿全部 capacity。

- capacity 量測：OSD 啟動時 osd bench **只量 4KiB random write IOPS**（`OSD.cc:10039-10122`），寫入 mon config store；**sequential bandwidth 不量測**，固定用預設 `osd_mclock_max_sequential_bandwidth_ssd=1200 MiB/s`。已有非預設 IOPS 值時啟動即跳過 benchmark；量出值超出 1,000–80,000 IOPS 區間則不採用（`osd.yaml.in:1258-1291`）；`osd_mclock_force_run_benchmark_on_init` 只保證重跑、不保證接受，且需重啟。
- 九個底層參數：`osd_mclock_scheduler_{client,background_recovery,background_best_effort}_{res,wgt,lim}`。**注意：profile 衍生值是 OSD process 內 `set_val_default()` 套用，不寫入 mon config store，`ceph config dump` 看不到**（`mClockScheduler.cc:396-424`）——生效驗證必須逐 OSD 查 effective config（§6）。
- `osd_mclock_profile` 可 runtime 切換（`ceph config set osd` 即生效，不需重啟）。

**Frame 階段要補完的機制題**（進 HYPOTHESES.md）：
- dmclock 演算法 res/wgt/lim 三段式的排序邏輯（reservation clock → weight clock、`AtLimit::Wait`）——引 `src/dmclock/` 對應實作。
- **mClock 仲裁的涵蓋邊界**：peering 與部分 replica traffic 走 immediate/high-priority queue，繞過 mClock（`mClockScheduler.cc:476-499`、`OpSchedulerItem.h:243-278`）——flapping 的 latency spike 不必然服從 profile 比例；量測要把 peering 區間與 recovery 區間分開。
- mClock 模式下 `osd_max_backfills`（=1）/ `osd_recovery_max_active_ssd`（=10）被鎖定的機制（`osd_mclock_override_recovery_settings`）——實驗全程保持鎖定預設，只動 profile。
- `mon_osd_adjust_heartbeat_grace` / `laggy_probability` 累積機制（`OSDMonitor.cc:3195-3239`）——flapping 場景的設計前提。
- `mon_osd_down_out_subtree_limit=rack` 預設值 → **整個 rack down 時不會 auto-out**（`OSDMonitor.cc:5160-5187`）——rack 場景的核心生產語意。
- SnapTrim / scrub 落在 best_effort class 的證據（best_effort lim 90% vs 70% 何時可觀測——本實驗不主測，標註為已知邊界）。

## 3. 環境設計（Azure japanwest）

### 3.1 拓撲

| 角色 | SKU | 數量 | vCPU 小計 | 備註 |
|---|---|---|---|---|
| OSD node | Standard_L8s_v3（8 vCPU / 64G / 1.92TB local NVMe） | 8 | 64 | 1 OSD/node（不切分 NVMe）；CRUSH：**4 synthetic racks × 2 nodes** |
| mon/admin | Standard_D4s_v5 | 1 | 4 | mon.a + mgr + prometheus（cephadm 內建 monitoring stack）+ 指揮所 |
| mon | Standard_D2s_v5 | 2 | 4 | 3-mon quorum；故障實驗不碰 mon |
| fio client | Standard_D4s_v5 | 4 | 16 | **krbd** map + fio（對映生產 KubeVirt/ceph-csi 的 krbd datapath，rev 3）；**4 小台取代 2× D8s_v5**：compute 價格相同、aggregate NIC ceiling 較高（rev 2/F19） |
| **合計** | | 15 | **88** | |

**Quota 三層 gate（rev 2/F17）**：Azure 同時檢查 Total Regional vCPU 與 per-family quota。需求：Regional 88 / **LSv3 family 64（上限 65，僅餘 1 的緊配）** / DSv5 family 24（上限 65）。前提 = 使用者先刪 `CYSHIH-KUBEVIRT-CEPH-LAB`（釋出 LSv3 24 + DSv5 36 + regional 60）。provision gate 必須：(a) 保存 `az vm list-usage -l japanwest` 證據確認三層 free quota；(b) **原子化建立全部 8 台 L8s_v3**——quota 夠不代表當下有 allocation capacity，任何一台拿不到就整批清理停止。

- **網路設計（rev 3）**：Azure 的頻寬上限是 **per-VM**，加第二張 NIC 不會增加頻寬 → 每台 VM 單 NIC + Accelerated Networking，全部掛同一 VNet/subnet；Ceph `public_network` = `cluster_network` = 該 subnet（在 Azure 上做 public/cluster 分離只是設定形式、無實體隔離效果，報告如實註明與實體機差異）。只有 admin node 掛 public IP（NSG 鎖使用者來源 IP），其餘 VM 純 private、經 admin 跳板。
- SKU 可用性（2026-07-24 實掃）：L8s_v3 僅 japanwest 對本 subscription 開放（eastasia / southeastasia / japaneast 皆 NotAvailableForSubscription，koreacentral 無此 SKU）。**不用更大台（如 L16s_v3 2×NVMe = 2 OSD/node）**：8 台超出 LSv3 quota（128>65）；4 台則 rack 塌縮成 node（rack 場景消失）且 2 顆 OSD 共享同一條 12.5 Gbps NIC，網路面劣化。
- replica 3、failure domain = **rack**。4 racks 的理由：失去一個 rack 後仍有未用 rack 可承接第三副本 → 觸發真 backfill；3 racks 拓撲只會卡 degraded。**命名注意（rev 2/F21）**：rack 是人為 CRUSH logical label，場景正名為 **synthetic CRUSH-rack loss**，不可外推為 Azure 實體 rack correlated failure。
- 資料填充 ~25–30%（讓單 OSD backfill 在 15–30 分鐘量級收斂；實際填充量由 pilot 定案）。
- on-demand 計價，不用 Spot（Spot 驅逐 = 不受控的故障注入）。
- ceph 部署：**cephadm**，指定 image 版本 v19.2.2。

### 3.2 成本框架（rev 2/F20 依 retail price 重算）

| SKU | 單價（japanwest Linux on-demand，2026-07-24） | 數量 | 小計/hr |
|---|---|---|---|
| L8s_v3 | $0.818 | 8 | $6.544 |
| D4s_v5 | $0.248 | 5（1 admin + 4 client） | $1.240 |
| D2s_v5 | $0.124 | 2 | $0.248 |
| **compute 合計** | | | **$8.03/hr** |

- 另計 OS managed disks / public IP / egress（估 +5–10%）。
- 時程目標 72h（§7）→ compute **$578–771**，含雜項估 **$620–850**；天花板 US$1000。**跨過 96h 時通知使用者一聲，但不停機器、繼續跑到完**（使用者裁示）。
- provision 前以實際 subscription rate 重算一次。

## 4. 壓力等級定義（共同基準校準，rev 2/F8）

**校準只做一次、在共同參考條件下**：`balanced` profile + final-clean（§5 判準），rate sweep 找出兩種形態的 aggregate throughput ceiling 與 latency knee。**三個 profile 共用同一組絕對速率**（treatment 不得污染 dose）；own-peak-normalized 曲線只作次要分析。

| 等級 | 定義（相對 balanced-healthy ceiling） | fio 實作 |
|---|---|---|
| 低 | 25% | `--rate_iops` 固定速率（開迴路供給） |
| 中 | 50% | 固定速率 |
| 高 | 80% | 固定速率 |
| 極端 | 不限速，高 iodepth 過飽和 | throughput-seeking（閉迴路） |

- **開迴路 vs 閉迴路（rev 2/F10）**：極端組是 closed-loop——latency 惡化時發送率自動下降，其 tail latency **不可**與固定速率組直接比較；極端組主要報 achieved throughput + 該供給下的 latency，跨 profile 比較以「同為極端組」為限。
- 兩種形態：**4K randrw 70/30**（latency 敏感）與 **1M seq write**（頻寬型、走 cost 換算路徑）。1M seq 的 peak 可能先撞 NIC ceiling（L8s_v3 / D4s_v5 皆 12.5 Gbps，replica 3 放大 cluster traffic）——burn-in 含 network baseline，每組收 NIC tx/rx/drop/retransmit，若 seq 受限於網路則如實標註「NIC-bound 環境下的結果」（rev 2/F19）。
- **fio job spec 固定化（rev 2/F10 + rev 3 改 krbd）**：client 用 **krbd**（`rbd map` → fio `ioengine=libaio` 打 `/dev/rbdX`），對映生產 KubeVirt/ceph-csi 的 kernel RBD datapath；direct=1（繞過 page cache）、randseed 固定、**穩態組** runtime 300s + ramp_time 30s；**故障/chaos 組改為連續 segment 續跑**（back-to-back 300s segment 直到 clean 或 measurement cap——300s 蓋不住 15–30 分鐘 backfill，後段 recovery 若無 client 競爭即失去研究對象，rev 5/F8）；逐秒 time series 契約 = 1s IOPS log + 1s latency log + 1s histogram log（`log_avg_msec=1000` + `write_iops_log`/`write_lat_log`/`write_hist_log`，stall/brownout 由此重建，rev 5/F12）；4 client 各用獨立 RBD image（大小固定、預先全量寫過 precondition、之後只 overwrite）；randrw iodepth/numjobs 與速率分配在 plan 定死並進 evidence bundle。client kernel 版本（Ubuntu 24.04 LTS）與 krbd map options 記入 environment snapshot；client 端 IO scheduler=none、readahead 固定。
- **capacity 校準（rev 2/F2 + rev 5 順序修正）**：順序不可逆——(1) **OSD 建立前**逐台跑 raw NVMe fio 4K randwrite 基線（OSD 建立後再碰 raw device 會毀 BlueStore）；(2) cephadm 建 OSD、收 startup bench 結果與 provenance（accepted / rejected-out-of-range / default）；(3) 對照 (1) 的 fio 基線 + 離散 gate（CoV>20% 先處理）；(4) 顯式 `ceph config set osd.N` 鎖定 + **`osd_mclock_skip_benchmark=true`**（v19.2.2 只比對「值是否 ≠ compiled default」決定重跑 bench，不看 config 來源——鎖同值仍會重跑，必須用 skip 旗標，`OSD.cc:10039-10063`）；(5) reboot canary 後重驗值未變。`osd_mclock_max_sequential_bandwidth_ssd` 維持預設 1200 MiB/s 並如實記錄——所有結論標註為「Ceph 預設 cost model 下的結果」。

## 5. 實驗矩陣（63 cells / ~147 executions，rev 2/F9+F12 重構）

**術語（rev 2/F12）**：cell = 一個參數組合；replicate = 該 cell 的一次完整執行（故障 cell 的 replicate = 完整「注入 → 量測 → 回復到 clean」cycle，同 cycle 內多個觀測窗不算多個 replicate）；每個 replicate 一個 evidence sub-bundle（原子化 completion marker）。

| 區塊 | 維度 | cells | n | executions |
|---|---|---|---|---|
| 穩態（**null/control 定位**） | 3 profiles × 4 壓力 × 2 形態 | 24 | 3 | 72 |
| 故障主軸（4K randrw） | 3 profiles × 3 壓力（低/中/極端） × {flapping, OSD down, rack loss} | 27 | 2 | 54 |
| 故障：node loss 變體 | 3 profiles × 中壓 × network-isolation（整機） | 3 | 2 | 6 |
| 故障：large-IO contention（rev 2/F9） | 3 profiles × {中, 極端} × OSD down × **1M seq** | 6 | 2 | 12 |
| chaos 終局 | 3 profiles × 極端壓 × 固定 seed 故障序列 | 3 | 1 | 3 |
| **合計** | | **63** | | **147** |

- **穩態組定位修正（rev 2/F9）**：三 profile 的 client lim 都是 max，無 recovery 競爭時 client 可借滿 capacity → 穩態組是 **negative control**（預測：profile 間 indistinguishable）；真正的 tradeoff 主戰場在故障區塊。`calc_scaled_cost()` 的 large-IO 路徑由 seq-contention 6 cells 在競爭下驗證。
- **node loss 修正（rev 2/F7）**：1 OSD/node ⇒ node loss 只失去 1 顆 OSD，backfill footprint 與 OSD down 幾乎相同；其獨立價值只在故障路徑（整機網路消失 vs 單 daemon stop），故降為中壓單點變體。「2 OSD 同時 backfill」由 rack loss（2 nodes）承擔。
- **profile 順序 counterbalance（rev 2/F15）**：同一 cell 群組內三個 profile 的執行順序按 Latin square 輪換，避免 Azure 鄰居效應、NVMe GC/溫度、BlueStore compaction 與 profile 共線。狀態鎖定：pg_num 固定 + autoscaler off、balancer off、實驗中 noscrub/nodeep-scrub、RBD image 固定只 overwrite；每個故障 replicate 記錄 target 初始 bytes 與實際 recovery backlog。

### 故障注入定義

| 故障 | 注入 | 回復觸發 | 觀測重點 |
|---|---|---|---|
| OSD flapping | 單 OSD daemon stop/start，**以 OSDMap epoch 為邊界**（確認 down epoch → up epoch → active 才算一輪；目標 10 輪） | 不 out（保留預設） | 反覆 peering（mClock bypass 路徑）+ log-based recovery 對 client latency 的衝擊 |
| OSD down | stop 單 OSD daemon | down 後立即手動 `ceph osd out`（= **managed-out backfill**） | backfill 速度 vs client IO 分配 |
| node loss（變體） | **網路隔離**（iptables drop 該 node 全部 Ceph 流量、保留 bastion ssh）——ssh-native、可維持任意 down 時長、免 Azure API（rev 3） | 手動 out ×1 OSD | 同 OSD down 但故障路徑不同（heartbeat 逾時 + 整機消失視角） |
| synthetic CRUSH-rack loss | 同上 ×2 台（同 rack） | 手動 out ×2 OSD | 最大規模 backfill（~1/4 資料）下的 QoS 行為 |

- **flapping 的 adaptive grace（rev 2/F5 + rev 5/F17 裁決）**：Squid 預設 `mon_osd_adjust_heartbeat_grace=true`，重複 down/up 累積 `laggy_probability`；且 **daemon restart 並非可靠的 laggy reset**（`OSDMonitor.cc:3692-3714` 只是更新/衰減，非歸零）→ 跨 cell 污染無法靠 restart 清除。裁決：**campaign 全程設 `mon_osd_adjust_heartbeat_grace=false`**（控制變因，主比較在關閉 adaptive grace 下進行，報告如實標註）；逐輪仍以 OSDMap 事件驗證 down/up，未達 down 即 `ceph osd down` 顯式標記；S3 選配一組 production-default（adaptive grace on）特性化 run。
- **managed-out 語意（rev 2/F6）**：手動 out ≠「生產再加 600s」——(a) auto-out 是「至少」600s 再疊 adaptive grace；(b) **rack down 預設 `mon_osd_down_out_subtree_limit=rack` 會一直不 auto-out**，生產上需 operator 手動介入；(c) 立即 out 消除了 down-but-in 期間的 write debt（repo 既有 E-39 已觀察到差異）。報告以「managed-out backfill」定位所有故障 cell，生產語意差異獨立成節。S3 時間允許時加 2 組 auto-out 確認組（OSD down × 中壓 × balanced/high_client_ops，等真 600s+grace）。
- **node 級故障改用網路隔離的理由（rev 3，取代 rev 2/F18 的 az stop 方案）**：(a) 從叢集視角語意等價（heartbeat 全滅 → node 判 down），而 mClock QoS 行為正是本實驗的觀測對象；(b) ssh-native → 免 Azure API、夜間全自主、down 時長任意可控；(c) 完全避開「stop 是否保留 local NVMe」的文件不一致風險。與真實斷電的差異（OSD process 仍存活、恢復時無 journal replay）在報告如實註明。**reboot canary（Phase 0）**：對 1 台 OSD node `sudo reboot`（planned reboot 不換 host、NVMe 保留），驗證 BlueStore 可讀 + OSD rejoin——這是 watchdog 第二層自救的前提驗證。
- **選配（S3，時間允許）**：gray network failure——`tc netem` 對單一 OSD node 注入 1–5% packet loss/延遲抖動（對應生產「ping 掉兩個封包」的灰色故障情境），觀察 heartbeat 未斷但效能劣化下三 profile 的 client latency 差異；進 HYPOTHESES.md backlog。
- **clean 判準（rev 5/F7 + rev 6 兩層定義）**——全文件唯一定義，不可用字面 `HEALTH_OK`（campaign 掛著 noscrub flags 會永久 timeout）：
  - **recovery-complete（under-fault）**：以**當下 up set** 為準，PG 100% `active+clean`（degraded/misplaced 歸零）——managed-out 的故障中，backfill 完成時 target 仍 down+out，這就是量測終點；fio segment 的 stop-condition 用這層。
  - **final-clean**：OSD 全部 up+in + PG 100% `active+clean` + health 除 harness 自設 `noscrub`/`nodeep-scrub` 外無其他 warning/error——replicate 收尾、baseline 復測前、watchdog 成功判準用這層。campaign 收尾必須 unset flags（abort path 也要，cleanup stack 對稱註冊）。
- **故障 replicate 的順序（rev 6 修正——workload 先行）**：qos gate → sampler 啟動 → **fio 先啟動並通過 readiness barrier**（ramp 完成、throughput 穩定）→ 記錄 `fault_t0` → **注入在 workload 進行中發生**（stall/brownout 才量得到故障瞬間）→ fio segment 續跑至 recovery-complete 或 measurement cap → 回歸（heal/start + `osd in`）→ 等 final-clean → baseline 復測 → 下一個。deadline 全部錨定 `fault_t0` 的絕對時間軸（不因 heal 重新起算）。
- **measurement cap 與 safety gate 分離（rev 5/F9）**：cap 到期記 `time-to-recovery-complete > cap`（right-censored 有效觀測，相對 recovery-complete 而非 final-clean），叢集仍必須等到 final-clean 才進下一 replicate；PG 持續無進展才進 watchdog。
- chaos：固定 seed 隨機故障序列（隨機 OSD kill/restart、隨機 node 隔離/解除、隨機間隔，20–30 分鐘），三 profile 重播同一序列；定位 showcase，不做嚴格歸因。

## 6. 量測與判準

- **client 面**：fio JSON——IOPS/BW、lat p50/p99/p99.9/max、逐秒 time series。
- **recovery 面**：`ceph pg dump` / `ceph -s` 差分——recovering objects/s、bytes/s、degraded% 曲線、time-to-clean；peering 區間與 recovery 區間分開統計（rev 2/F4）。
- **叢集面**：cephadm 內建 prometheus（OSD op latency、SLOW_OPS、mclock/queue perf counters、NIC 指標、per-shard queue）。
- **生效驗證（rev 2/F3 + rev 5/F14 強化）**：每個 replicate **開始前**輪詢八顆 OSD 的 effective config（`ceph tell osd.N config show`）**同時收斂**到預期集合——profile 名、九個衍生參數、鎖定的 IOPS capacity、`osd_mclock_max_sequential_bandwidth_ssd=1200MiB/s`、`osd_max_backfills=1`、recovery active 值、`osd_mclock_override_recovery_settings=false`——全數一致後再過 settle window 才開始量測；結構化驗證結果寫入該 replicate bundle。`ceph config dump` 不可作為依據（profile 衍生值不進 mon store）。違者作廢該 replicate。
- **stall/brownout 視角（rev 3，使用者標準：關鍵生產系統，IO delay 幾秒即事故）**：從 fio 逐秒 log 導出——**IO stall**（該秒完成數 = 0）與 **brownout**（該秒 p99 > 1s）的最長連續時長與總秒數，per replicate 報告；同步收 SLOW_OPS 事件時間軸對齊。故障實驗的頭號問題是「client 到底黑掉幾秒」，不只是平均劣化幅度。
- **網路觀測面（rev 3）**：全 node 間 1s 間隔 ping mesh 全程記錄（對齊故障注入時間軸，也用於辨識 Azure 自身的網路抖動輪）。
- **判準（rev 2/F11 + rev 7 修訂）**：prediction 先行。primary endpoints 預先指定：**client p99 degradation ratio（分母 = 同 replicate 的注入前 60s 健康窗；跨日穩態 cell 降為次要對照——防 72h 校準漂移污染）**、**max IO stall duration**、**recovery bytes/s**、**time-to-recovery-complete**；其餘指標為 secondary/exploratory。margin 採**雙軌**：noise margin（觀測 CoV 導出）+ **production margin（HYPOTHESES.md 預註冊的生產有感絕對門檻）**——`indistinguishable` 必須標明是「等效（差異 < 生產門檻）」或「靈敏度不足（噪音 > 生產門檻）」。故障 n=2 標 **exploratory**，噪音超標自動升 n（上限 5；含 censored 觀測的 cell 不走 CoV 升級，改走雙 censored 自救規則——plan §Cap policy）。三態 verdict `confirmed / violated / indistinguishable`。
- **timeout ≠ skip（rev 2/F14）**：recovery 逾時記為 **right-censored 有效資料**（`time-to-clean > cap`）納入 verdict——慢 profile 的最差結果正是研究對象；只有量測工具故障才作廢。bundle 完成以原子 marker 判定，不以目錄存在判定。

## 7. 執行模式（單一連續 campaign，rev 2/F13 時程重算）

使用者裁示：開機後一路跑到完、不落地、**不設硬性時間上限**（跨 96h 通知一聲即可，繼續跑到完）。時程估算以 72h 為目標（147 executions：穩態 ~9h、故障 cycles ~48h、chaos+校準+provision+gates ~12h、buffer ~8h）。

| Stage | 內容 | 累計 wall-clock |
|---|---|---|
| S0 | provision（原子化 8× L8s_v3）→ cephadm 部署 → burn-in（含 network baseline、reboot canary）→ Phase 0 校準 | ~6–8h |
| S1 | 穩態 72 executions（control） | ~15–17h |
| S2 | **每型故障先跑 n=1 pilot（4 組）→ 以實測 P50/P95 recovery 時間重算 S2 排程** → 故障 72 cycles | ~63–70h |
| S3 | chaos 3 → auto-out 確認組（選配）→ 補跑 → 資料齊收 → **刪除整個 RG** | ~72–80h |

- **descope 階梯**：時間無硬上限（使用者裁示跑到完），predefined descope（① 故障低壓降 n=1 ② 砍 auto-out 確認組 ③ seq-contention 只留極端壓）只在成本逼近 $1000 天花板或病態緩慢（單 cycle 超估算 3 倍以上反覆發生）時啟用，啟用前通知使用者。
- 全自動 run queue：組間零人工等待；pilot 通過後整批放行（每型首組人工檢查）。
- **watchdog 分層自救（rev 2/F16 + 使用者裁示：無解先重開機、真的解不了才叫人）**：
  1. 第一層：停止 fio 與故障注入、暫停佇列，嘗試自動修復（daemon restart、`ceph osd in/out` 校正、重跑該 replicate）。
  2. 第二層：**reboot 相關 VM**（首選 ssh `sudo reboot`；ssh 完全失聯才用最後手段 `az vm restart`——兩者皆不換 host、local NVMe 資料保留；az 路徑需 campaign 開跑前 preflight `az account show`/subscription/權限）→ 等 OSD rejoin + **final-clean** → 從斷點續跑；該 replicate 標記 tainted 重跑。
  3. 第三層（唯一叫使用者的時機）：前兩層循環仍無法恢復（例如 BlueStore 損毀、Azure allocation 層問題）→ 通知使用者裁示。**全程 VM 保持 allocated，嚴禁自動 deallocate**——8 台 OSD 的 NVMe 同時消失 = data plane 報廢，deallocate 只能是使用者親自下的放棄決定。
- 連續 campaign 期間每 12 小時回報累計花費與進度。
- **完全自主執行（rev 3，使用者裁示）**：campaign 內的一切——校準、穩態、故障注入（daemon stop / iptables 隔離）、chaos、自救（daemon restart / `sudo reboot`）、收數據——全部 ssh-native，由 AI 自主執行，不依賴 Azure API。Azure 層操作降到最少且集中在 campaign 邊界：provision（開跑前）、teardown（收官）、以及 watchdog 第三層的最後手段（VM ssh 完全失聯時的 `az vm restart`）。
- **Provisioning 分工（rev 4，使用者裁示）**：由**另一個 IaC agent** 依 `experiments/ceph-mclock-profiles/PROVISIONING-REQUIREMENTS.md` 實作（完整需求：規格數量、套件、OS desired state、inventory handoff 契約、acceptance checklist 都在該文件）；harness 開跑前跑 acceptance 驗收，任一不過退回 IaC。teardown 用同一套 IaC 刪整個 RG。使用者手動負責：quota、舊 lab 刪除（我不碰 `CYSHIH-KUBEVIRT-CEPH-LAB`）。

## 8. Harness 架構

```
experiments/ceph-mclock-profiles/
├── HYPOTHESES.md            # charter + 假說 backlog（Frame 產出）
├── README.md
├── PROVISIONING-REQUIREMENTS.md  # 給 IaC agent 的完整 provisioning 需求（rev 4）
├── azure/
│   ├── verify-provision.sh  # acceptance checklist 自動驗收（IaC 交付 gate）
│   └── inventory.sh         # 讀 IaC 交付的 inventory JSON → 供 lib/ 使用
├── lib/
│   ├── common.sh            # ssh 向量、log→stderr、die、bundle helper + 原子 completion marker
│   ├── ceph.sh              # cephadm bootstrap/add-host/OSD、profile 切換 + 逐 OSD effective config 驗證、osd out/in、laggy 檢查
│   ├── inject.sh            # 故障注入（OSDMap epoch 邊界）：daemon stop/start、iptables 隔離/解除、chaos 序列（固定 seed）+ 回退；全 ssh-native
│   ├── fio.sh               # 校準 sweep、固定 job spec render、Latin square 排序、n 輪執行
│   ├── collect.sh           # fio JSON、pg dump 差分、prometheus 快照、effective config、NIC 指標
│   └── verdict.py           # 三態比對 + equivalence margin + right-censored 處理（bastion python3）
├── run/
│   ├── calibrate.sh         # Phase 0（含 capacity 驗證、reboot canary、network baseline）
│   ├── steady.sh            # 穩態佇列
│   ├── faults.sh            # pilot → 故障佇列（回復 gate、watchdog、descope 階梯）
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
| 3 S0/S1 | **Gate：使用者確認舊 lab 已刪、三層 quota 證據齊、說 go** → provision → canary/校準 → 穩態 | 校準 + canary + 首組人工檢查通過 |
| 4 S2/S3 | 故障 pilots → 重算排程 → 故障全佇列 → chaos → 收資料 → 刪 RG | 每型 pilot 人工檢查；watchdog 全程；96h 通知（不停機） |
| 5 Synthesize | 完整報告（五欄 + 參數建議總表 + 主管 persona review）；HYPOTHESES.md 收斂 | 報告過 `writing-experiment-reports` gate |

## 10. 風險與邊界

- **成本失控**：watchdog 分層自救 + 每 12h 花費回報 + 96h 通知 + 成本逼近天花板才啟用 descope + S3 整 RG 刪除。
- **雲端噪音**：Azure 鄰居效應——counterbalance + n≥3（穩態）+ 逐秒 time series + equivalence margin；異常 replicate 進 S3 補跑清單。
- **capacity 量測失真**：Phase 0 逐 OSD 把關 + 顯式鎖定；seq bandwidth 固定 1200 MiB/s 是 Ceph 預設 cost model 的一部分，如實標註。
- **LSv3 quota 僅餘 1 vCPU 餘裕**：provision gate 原子化 + 失敗即清理；拿不到 8 台就停，不硬跑殘缺拓撲。
- **絕對數字不可外推**：結論以「同環境內 profile 相對差異」為準；synthetic CRUSH-rack loss 不可外推為實體 rack 故障；NIC-bound 的 seq 結果如實標註。
- **mon 單薄**：故障**注入**不碰 mon node；mon 異常即暫停佇列，watchdog 允許的 mon **修復**動作（daemon restart，上限 1 次 → HUMAN-NEEDED）不在此限——repair ≠ fault injection。
- **版本**：實機 v19.2.2 = 引用基準 v19.2.2，無漂移；與 submodule pin（v19.2.3）差異在報告註記一次。

## 11. 驗收標準

1. `bash experiments/ceph-mclock-profiles/tests/run-tests.sh` 全綠；`shellcheck` 0；`make validate` exit 0。
2. **63 cells / ~147 replicate sub-bundles**（±descope 記錄）齊備，`EVIDENCE-SUMMARY-<date>.md` 索引進 git；每個 replicate 含 prediction、逐 OSD effective config 驗證、原子 completion marker、verdict（含 right-censored）。
3. 完整報告落地：三 profile 參數對照 + cost model 機制（source 錨點）、共同基準下的壓力取捨曲線、故障 + chaos 對照（managed-out 語意與生產差異獨立成節）、參數建議總表（含「何時選哪個 profile」裁決樹）。
4. Azure RG 已刪除、費用總結回報（≤ US$1000）。
5. HYPOTHESES.md 所有 P0/P1 條目離開 proposed。
