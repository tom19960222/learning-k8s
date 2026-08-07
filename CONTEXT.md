# learning-k8s 實驗語彙

這份 glossary 固定系統行為實驗裡容易混淆的領域語言，避免把不同量測層級的數字都簡稱為「IOPS」。

## Ceph mClock

**宣告容量（declared capacity）**：
mClock 以 `osd_mclock_max_capacity_iops_ssd` 表示的單顆 OSD 名義容量，用來換算 scheduler 的 reservation、weight 與 limit；它不是裸裝置 IOPS，也不是整個 cluster 的 client 吞吐。
_Avoid_: 實際 IOPS、磁碟 IOPS

**宣告容量落差（declared-capacity gap）**：
宣告容量與另一個明確標示量測層級的 capacity reference 之間的差距；描述時必須指出 reference 是 raw NVMe、per-OSD BlueStore 或 cluster client ceiling。
_Avoid_: capacity 錯估、真實 IOPS 落差

**OSD startup bench**：
OSD 啟動時由 Ceph 經 BlueStore 執行的短時間 4 KiB 寫入量測，結果可成為宣告容量的來源。
_Avoid_: raw NVMe benchmark、client ceiling

**raw NVMe throughput**：
建立 OSD 前直接對裸 NVMe 裝置量到的吞吐，只代表裝置層能力，不含 BlueStore、replication 與 client datapath 成本。
_Avoid_: OSD capacity、Ceph IOPS

**client ceiling**：
cluster 健康時，以不限速 client workload 經完整 RBD datapath 量到的 aggregate 吞吐上限。
_Avoid_: per-OSD capacity、raw device ceiling

**容量敏感度情境（capacity-sensitivity scenario）**：
固定故障、workload 與環境，只刻意改變宣告容量，判斷 profile 分離程度是否依賴 capacity calibration。
_Avoid_: 重新校準、重跑 benchmark

**重現容量（reproduction capacity）**：
重現舊 campaign 當時由 Ceph 接受並鎖定的 per-OSD startup bench 值，約 6,057–6,646 IOPS；它代表舊設定，不預設為真實容量。
_Avoid_: 正確容量、raw capacity

**敏感度容量（sensitivity capacity）**：
把重現容量的 per-OSD 相對比例等比放大，使中位數落在 Ceph SSD 預設的 21,500 IOPS；它是測試 capacity scale 影響的 treatment，不是校準真值。
_Avoid_: 修正容量、真實容量、NVMe capacity

**常見情境（common scenario）**：
單顆 OSD 下線並進行 recovery，同時承受 fresh client ceiling 中位數 50% 的 4K 70/30 混合讀寫，代表一般 VM／RBD workload 遇到磁碟故障或更換 OSD；舊 ceiling 推估約 31.8k aggregate IOPS，但不是本輪固定 target。
_Avoid_: 一般負載、正常情況

**極限分離情境（maximum-separation scenario）**：
單顆 OSD 下線並進行 recovery，同時承受不限速的 4K 70/30 混合讀寫，用來提高觀察 mClock profile 取捨的機會。
_Avoid_: 壓力測試、最壞情況

**雙重校準稽核（dual-calibration audit）**：
在 profile screening 前，同時重驗 OSD startup bench 與 client ceiling，避免把不同層級的量測偏差帶進後續 workload 與宣告容量。
_Avoid_: calibration、preflight

**裁決指標（verdict endpoint）**：
用來判定 profile screening 是否觀察到 trade-off 的指標；本輪以 client IOPS 保留率與 recovery 完成時間／吞吐為主。
_Avoid_: 所有量測值、重要指標

**Profile gap**：
同一 workload 情境與同一宣告容量下，`high_client_ops` 與 `high_recovery_ops` 在單一 verdict endpoint 上的差值。
_Avoid_: profile ratio、capacity effect

**Capacity effect**：
敏感度容量的 profile gap 減去重現容量的 profile gap；本輪用這個 difference-in-differences 判斷 profile 分離是否依賴 capacity scale。
_Avoid_: 高容量結果、profile gap

**Mixed capacity sensitivity**：
Client 與 recovery 的 signed capacity effect 分別朝不同方向，或只有一個 endpoint 跨門檻的結果；只能逐 endpoint 報告，不給整體支持或反駁原假設的結論。
_Avoid_: 部分成功、整體有差、trade-off signal

**Censored-indeterminate**：
Recovery cell 只有 `>30m` 的右設限，且可得上下界不足以證明 signed capacity effect 是否跨過預註冊門檻的 verdict；保留界線，不把 30 分鐘當成完成時間。
_Avoid_: recovery 1800 秒、未跨門檻、無效 execution

**Trade-off signal**：
`high_client_ops` 較能保留 client IOPS，且 `high_recovery_ops` recovery 較快的同向組合；單一 endpoint 跨門檻只能稱為該 endpoint 的 screening signal。
_Avoid_: profile 勝者、實驗成功

**Pre-fault capacity-bound**：
fault 注入前已取得 60 秒穩定窗，但實際 client IOPS 低於 offered-load target 的 85%；它是 capacity treatment 的有效觀測，不是 harness failure。
_Avoid_: workload 無效、readiness failure

**Application latency observation**：
完整記錄並以毫秒呈現的 client p99 latency；本輪沒有正式 SLO，因此用 baseline、fault、差值與持續時間描述 application 代價，但不單獨決定實驗成功或失敗。
_Avoid_: 次要指標、p99 verdict

**Partial execution**：
Primary endpoint 仍有有效證據，但必要的 application p99 telemetry 不完整的 execution；保留可用 endpoint，卻不算完成基本矩陣，並優先使用彈性時槽重跑。
_Avoid_: 無效 execution、完整 execution

**P99 interruption exposure**：
沿用 300 秒 fio segment 時，突然中斷可能使當下尚未落地的 p99 最多缺少 5 分鐘；已完成 segment 與 Ceph／recovery samples 仍保留，該次依證據完整度標記為 partial，而不是把缺漏視為 latency 正常。
_Avoid_: p99 容許中斷、五分鐘 latency SLO

**Report checkpoint**：
在指定時間封存當下的 completed、partial、active 與 not-started 狀態及 cluster／treatment 快照，供中途閱讀與最終報告追溯；它不是 campaign stop。
_Avoid_: deadline、final report、campaign completion

**Azure lab 存在（Azure lab present）**：
以目標 subscription 與精確 resource group 內的 VM inventory、power state 和 provisioning state 證明實驗機器仍可用；未指定 resource group 的空白 VM 清單不構成刪機證據。
_Avoid_: resource group 存在、agent 程序存在、空白 VM 查詢

**獨佔實驗窗口（exclusive experiment window）**：
其他 agent 與 campaign 已停止寫入，且經唯讀 preflight 證明沒有 active runner／fio、cluster 已達 `final_clean`、profile 與宣告容量回到已知狀態的期間；新的校準與 execution 只能在此窗口開始。
_Avoid_: agent 看起來閒置、程序已結束、VM 還在

**Campaign 結果命名空間（campaign results namespace）**：
本輪延伸實驗專用、唯一且起始為空的 `RESULTS_DIR`；舊 campaign 與另一個 agent 的結果維持只讀，不得把其 marker 或 replicate 當成本輪續跑狀態。
_Avoid_: 共用 results、覆寫 campaign、沿用舊 marker

**Campaign ownership**：
Exclusive experiment window 成立後才可取得的 local 與 remote owner lock；遇到其他 owner 或 active workload 時只能等待，不能搶鎖、清鎖或停止對方程序。
_Avoid_: cluster ownership、VM ownership、強制接管

**Planned completion**：
Common 2×2 與所選 capacity 的 extreme profile pair 均達 n=3，且最後的 common `balanced` capacity A、B reference 各完成一次；到此安全回退並收官，不再無限增加 replicate。
_Avoid_: hard deadline、跑到被中斷、所有 profile 全矩陣

**Fault injection budget**：
每個 cell 自 `fault_t0` 起最多三次實際 fault injection；complete、partial 與 fault 後 invalid 都計入，preflight 在 `fault_t0` 前拒絕則不計。用完仍缺資料就保留不完整結論，不再追加 fault。
_Avoid_: 三個有效樣本、無限重跑、三次 preflight

**Campaign paused**：
Exclusive window、cluster 健康或安全回退證據失效後，停止啟動新 execution 且不得自動恢復的狀態；必須重新通過完整 exclusive-window preflight 才能繼續。
_Avoid_: campaign failed、等待下一個 slot、自動 retry

**Counterbalanced round**：
在讀取 endpoint 結果前固定的重複輪次順序；n=2 反轉 n=1，n=3 由 campaign ID 的 deterministic seed 排定，同時維持 capacity block 以限制 config churn。
_Avoid_: 隨結果調序、完全隨機 execution、固定 profile 永遠先跑

**Live evidence ledger**：
事件發生時即 append 的 `run-ledger.ndjson`，持續保存 prediction、gate、設定、fault timeline、回退與 partial／aborted 狀態；更正以 amendment event 追加，不覆寫歷史。
_Avoid_: 最後才補紀錄、可修改日誌、console output

**Checkpoint report**：
17:30 與每次 campaign paused 時產生的時間戳唯讀快照；不為報告中斷 active execution，並明列最後可信時間戳與尚未落地的資料。
_Avoid_: final report、campaign stop、覆寫最新報告

**Attempt budget exhausted**：
某個 cell 已完成第三次 `fault_t0` 後仍缺所需完整樣本的終止狀態；該 cell 不再重跑，但不自動取消其他仍有比較價值的 cell。
_Avoid_: 三次有效樣本、campaign failed、再試一次

**Completed with gaps**：
所有仍具資格的 cell 已完成或用完 fault injection budget，但核心矩陣仍有缺口時的正式 campaign 終態；安全回退並依現有證據寫報告。
_Avoid_: planned completion、failed、永遠等待補件

**Paired-block admission**：
只有已知剩餘時間足以完成整個 paired block 才啟動下一區塊；common round 預留 3 小時，extreme pair 與 `balanced` A/B 各預留 1.5 小時，避免 hard deadline 留下單邊結果。
_Avoid_: 單次有空就跑、六小時完成承諾、跨 deadline 啟動
