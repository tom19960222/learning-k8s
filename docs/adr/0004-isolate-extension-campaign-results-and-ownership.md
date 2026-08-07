---
status: accepted
---

# 隔離延伸實驗的結果與執行 ownership

延伸實驗必須使用唯一且起始為空的 `RESULTS_DIR`，格式為 `experiments/ceph-mclock-profiles/results/profile-capacity-extension-20260807/<campaign-id>/`。Runner 必須顯式傳入這個路徑，不得退回共用的預設 `results/`，也不得把舊 campaign 的 marker、capacity lock、replicate 或 verdict 當成本輪可續跑狀態。

舊 campaign 結果與另一個 agent 的工作產物一律只讀，不搬移、不改名、不補寫、不清除。若指定的 `<campaign-id>` 已存在，runner 必須拒絕啟動，而不是覆寫或接續；需要重試時建立新的 campaign ID，並在 ledger 記錄前一個 ID 與中止原因。

只有 exclusive experiment window 已經由唯讀 preflight 證明成立後，才能建立本輪 local 與 remote owner lock。Lock 必須記錄 campaign ID、runner ID、建立時間與 owner；發現其他 owner、active runner 或 fio 時只可等待並回報，不得搶鎖、刪鎖、停止程序或修改 cluster。取得 ownership 後若 exclusive window 消失，立刻停止啟動新 execution，完成安全回退並把當下 attempt 封存為 partial 或 aborted。

下列任一條件會把 campaign 轉為 `paused`，停止啟動新 execution、盡力安全回退，且不得自動恢復：exclusive window 消失；出現無法由本次 `osd.5` fault 解釋的 cluster 健康異常；OSD 回復後無法驗證 `final_clean`；無法驗證八顆 OSD 已回到 `balanced + capacity A`；使用者要求停止或明確 hard deadline 到達。恢復前必須重新通過完整 exclusive-window preflight 並取得 ownership。

一般 execution preflight 或 `ceph osd ok-to-stop osd.5` 未通過時不得修改 cluster，只維持唯讀等待並重新檢查；這不建立 `fault_t0`、不消耗 fault injection budget，也不單獨把 campaign 判成失敗。
