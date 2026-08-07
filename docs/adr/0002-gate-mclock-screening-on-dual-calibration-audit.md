---
status: accepted
---

# Profile screening 前保留三十分鐘做雙重校準稽核

六小時實驗先保留最多三十分鐘，逐顆執行三次與 startup 完全同參數的 manual OSD bench：每次先 `ceph tell osd.N cache drop`，再執行 4 KiB bench；不得為此重啟 OSD。接著在暖機後重跑三次 client ceiling。任一中位數相對舊值偏移超過 15% 時，停止既定 profile 矩陣並重算宣告容量或 workload；未超過才繼續，以避免節省前置時間卻讓整輪實驗建立在錯誤天花板上。

三十分鐘是 audit hard cap，不是可挪用的 execution 時槽。到期前必須取得八顆 OSD 各三筆 bench 與三筆 client ceiling；缺任一筆就停止，不以 partial calibration 啟動矩陣，也不占用第一個 execution 時槽補測。

OSD bench 逐顆判斷：每顆三次中位數相對該顆舊值偏移超過 15%，或三次內 CoV 超過 10%，audit 即失敗。Client ceiling 三次中位數相對舊值偏移超過 15%，或三輪 CoV 超過 10%，同樣失敗。Cluster median 與跨 OSD CoV 保留為描述性證據，不得用平均結果蓋掉單顆失敗；任一 gate 失敗就不啟動 profile matrix。

Audit 與 client ceiling 的共同參考條件固定為 `balanced + capacity A`。Audit 通過後，common offered-load target 取三次 fresh client ceiling 的中位數乘以 50%，四捨五入為整數 IOPS；同一 target 用於全部 capacity A/B 與兩個極端 profile，不隨 treatment 改變。Extreme workload 維持不限速 closed-loop。

校準與 screening 只能在獨佔實驗窗口開始：不得讀取或採用其他 agent 的 active 實驗結果，也不得與其共用執行時段。開始前以唯讀 preflight 確認沒有 active runner／fio、cluster 已達 `final_clean`，且 profile 與宣告容量已恢復至已知狀態；未通過只等待，不終止、不修改另一個 agent 的工作。

本輪雙重校準只判斷舊 startup bench 與 client ceiling 是否可重現，六小時 screening 只回答 profile 分離是否對 capacity scale 敏感；它不裁定該 cluster 唯一正確的 mClock capacity。raw NVMe throughput 只保留為裝置層上限，Ceph SSD 預設 21,500 IOPS 只作敏感度 treatment；若要主張正確 capacity，另立 sustained OSD-path calibration，不與本輪結果混用。
