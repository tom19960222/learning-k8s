---
status: accepted
---

# 六小時篩選優先比較兩個極端 mClock profile

容量敏感度情境先比較 `high_client_ops` 與 `high_recovery_ops`，因為兩者提供最大的理論 contrast；`balanced` 排在最後，只有剩餘時間與 cluster 狀態允許才補跑。這項取捨用完整三 profile 的矩陣換取異常重跑與安全回歸的時間，常見情境仍保留 `balanced` 作為預設值參照。

2026-08-07 17:30（Asia/Taipei）是 report checkpoint，不是 campaign stop。到點封存 completed、partial、active 與 not-started 狀態及 cluster／treatment 快照；在沒有明確 hard stop、exclusive window 仍成立且安全 gate 正常時，campaign 繼續完成後續 execution。若外部中斷發生，安全回退優先於時間點。

基本 screening 不自動重複每個 cell；同一組 profile／情境最多允許三次實際 fault injection，不延續前一輪最多五次的設計。計數邊界是已寫入 `fault_t0`：在此之前被 preflight 擋下不計，之後不論 complete、partial 或 invalid 都占用一次；第三次後仍缺有效資料就停止該 cell，保留不完整結論，不再為湊足三個有效樣本增加 fault。六小時窗口優先保留 capacity A/B 與兩種 workload 情境的覆蓋，重複只使用彈性時槽或 soft deadline 後明確取得的額外時間。延長階段不得看單次結果挑選有利 cell，而以完整 paired round 增加樣本：先把 common capacity A/B × 兩個極端 profile 的 2×2 全部補到 n=2，再把所選 capacity 的 extreme profile pair 補到 n=2；之後以相同順序分別補到 n=3。所有缺漏、partial 或無效 cell 的成對修復優先於增加下一輪樣本，但不得突破每個 cell 三次 fault injection 上限；核心 cell 全部達 n=3 後，最後只補 common scenario 的 `balanced` capacity A、B 各一次，不執行 extreme + `balanced`。兩個 `balanced` reference 完成後即達 planned completion，安全回退並產出最終報告，不再追加 replicate。

若 cell 用完三次 fault injection 仍未取得所需完整樣本，標成 `attempt-budget-exhausted`，其他仍有獨立比較價值且未用完 budget 的既定 cell 繼續執行。若 common 2×2 尚不足以依預註冊 routing score 選 capacity，就不啟動 adaptive extreme；若核心矩陣仍有缺口，就不補 `balanced`。所有仍具資格的 cell 完成或用完 budget 後，以 `completed-with-gaps` 安全收官並產出最終報告，不把 planned completion 當成無限重試條件。

單次 execution 的 recovery measurement cap 為 OSD 下線後三十分鐘；到期仍未完成時記為有效的右設限結果 `>30m`，而非無效 execution。排程則為每次保留四十五分鐘 wall-clock，包含最多十五分鐘的前置、回退與 cluster 健康確認。扣除三十分鐘雙重校準稽核後，17:30 soft deadline 前的基本容量最多為七個完整 execution 時槽。

Planned completion 共包含 common 2×2 的三輪 12 次、所選 capacity extreme pair 的三輪 6 次，以及最後 common `balanced` capacity A/B 2 次，合計 20 次 execution；加上雙重校準，依每次 45 分鐘保守估算約 15.5 小時，尚不含等待 exclusive window 或安全異常。原六小時只承諾優先完成 basic screening，不承諾 n=3 收官。Common round 視為 3 小時 paired block，extreme pair 與 `balanced` A/B 各視為 1.5 小時 paired block；只有已知剩餘時間足以完成整個 block 時才啟動。沒有已知 hard deadline 時可繼續；一旦 deadline 明確，不開啟註定只能留下單邊的新 block。

證據採持續 checkpoint：prediction freeze、profile／capacity gate、pre-fault readiness、fault timeline 的每個狀態轉換即時寫入 append-only run ledger；Ceph sampler 維持 5 秒粒度、coverage supervisor 維持 30 秒 cadence，fio 每個完整 segment 落地後即保留。`DONE` 只在完整 schema 驗證後原子寫入；中斷中的 attempt 保留原始檔並明確標記 partial 或 aborted，不覆寫、不假裝成未執行。Report checkpoint 與最終報告都必須列出缺件及最後可信時間戳。

前四個時槽在常見情境跑完整的 capacity A/B × `high_client_ops`／`high_recovery_ops` 2×2 screening；第五、六個時槽在前四次中 profile 分離較明顯的容量下，跑不限速極限情境的兩個 profile。第七個時槽先保留給缺漏、partial 或無效 execution 的成對修復；若前六次均完整，則直接開始 common 2×2 的 n=2 paired round，不提前插入 `balanced`。

固定起始順序為：常見 A／`high_client_ops` → 常見 A／`high_recovery_ops` → 常見 B／`high_recovery_ops` → 常見 B／`high_client_ops`。極限情境在第四次後才選容量，兩個 profile 的先後順序反轉該容量在常見情境中的順序，降低固定先後與時間漂移被誤認為 profile 差異的風險。這是自適應 screening；極限情境的結果須標示容量選擇使用了同一輪常見情境資料，不包裝成預先固定的 confirmatory test。

重複輪次採預先固定的 counterbalance。n=2 的整輪順序完全反轉 n=1；n=3 在讀取任何 endpoint 結果前，由 campaign ID 的 deterministic seed 產生 block 與 block 內 profile 的先後順序。排序仍以 capacity block 為單位，避免不必要的 capacity config churn。Extreme pair 使用同一原則：n=2 反轉 n=1，n=3 由同一 seed 規則決定。實際排程與 seed 必須在 round 開始前寫入 prediction freeze，之後不得依觀察結果改序。

Capacity A 是舊 campaign 實際鎖定的 per-OSD startup bench 向量（約 6,057–6,646 IOPS），用於重現舊設定；capacity B 保留同一向量的相對比例並等比放大，使中位數落在 Ceph v19.2.3 的 SSD 預設 21,500 IOPS。B 只提供 capacity scale 的敏感度 treatment；即使它產生較大 profile 差異，也不得宣稱 21,500 是該 cluster 的正確容量。raw NVMe throughput 與 client ceiling 保留為診斷證據，不直接寫入 `osd_mclock_max_capacity_iops_ssd`。

第四次 common screening 後，以預註冊的 routing score 選第五、六次 extreme 使用的 capacity：client profile gap 除以 10 個百分點，recovery profile gap 除以 `max(300 秒, pair mean 的 20%)`，且只保留預期方向的正值；每個 capacity 取兩個標準化 score 的較小者。較高者代表兩條 trade-off 腿中較弱的一腿仍較清楚，因此入選；同分時先比較 client score，仍同分則選 A。這只決定後續 screening 路由，不構成 confirmatory verdict，p99 不參與選擇。

Capacity routing 只能在 common 2×2 四個 execution 都完整後進行。任一 common execution 為 partial 或無效時，第五、第六時槽先用來補齊 common；不得以缺件資料選 capacity。若因此沒有足夠時間完成一對 extreme profile，就停止於完整 common 2×2，將 extreme 留為未執行，而不是留下不可比較的單邊結果。

本輪所有 execution 全部固定以 `mclock-osd-6`（rack3）作為單顆 OSD-down target。它的舊 startup bench 約 6,457 IOPS，接近八顆中位數約 6,482 IOPS，且是舊 extreme cells 的既有 target；固定同一 target 可避免裝置、PG mapping 與 CRUSH 位置差異混入 capacity/profile effect。新 common 與舊 mid cells 因 target 不同，跨輪比較只作描述性參考。

故障語意沿用舊 managed-out 路徑：`mclock-osd-6` 對應的 `osd.5` 在 pre-fault 穩定窗完成後，先通過 `ceph osd ok-to-stop osd.5`；未通過不修改 cluster，記為 preflight failure。通過後於 daemon stop 前記 `fault_t0`，等待 OSD 被判 down，立即 manual out；recovery endpoint 是 target 仍 down+out 時，其餘當下 up set 的 PG 全部 `active+clean`。量測結束後啟動 OSD、等待 up、標 in，並等完整 `final_clean`。`ok-to-stop` 是相較舊 harness 新增的安全 gate。

Treatment 以區塊為生命週期：slot 1–2 保持 capacity A、slot 3–4 保持 capacity B、slot 5–6 保持 routing 選出的 capacity，區塊內只切換必要的 profile，避免多餘 config churn。每次 execution 前仍須驗證八顆 OSD 的 capacity、profile、九項 QoS 與 `skip_benchmark`，fault 回復後必須先達 `final_clean`。任何錯誤、中斷、等待使用者或 campaign 結束都恢復 `balanced + A` 並驗證八顆生效；回退驗證未通過，不得宣稱安全停止。
