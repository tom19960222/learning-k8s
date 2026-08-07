---
status: accepted
---

# 持續保存實驗證據並產出可讀報告

每個 campaign 使用獨立 `run-ledger.ndjson`，在事件發生時即 append prediction freeze、設定與驗證結果、preflight gate、`fault_t0`、fault／recovery／rollback 狀態轉換、partial／aborted 原因及最後可信時間戳。Ledger 不等待 execution 或 campaign 結束才一次產生；既有事件不得覆寫或刪除，更正以新的 amendment event 表達。

2026-08-07 17:30（Asia/Taipei）與每次 campaign 進入 `paused` 時，產生帶時間戳且不可覆寫的 checkpoint 報告。若 checkpoint 當下仍有 execution active，不為了報告中斷它；報告須把該 attempt 標成 active，列出目前階段、已落地資料、尚未落地的當下 fio segment，以及最後可信時間戳。

Campaign 達 planned completion、`completed-with-gaps` 或被人工終止後產生 `FINAL-REPORT.md`。正文以未參與實驗者能直接理解的語言說明：原問題、capacity A/B 的證據邊界、common 與 extreme 結果、capacity effect、限制及建議。主要表格直接呈現 client IOPS、retention 百分點、recovery 秒數與 p99 毫秒；不得要求讀者自行從 ratio 換算 latency。統計細節、執行順序、partial／invalid／not-started 清單、缺件與最後可信時間戳放入附錄，但不能因移入附錄而隱藏會改變結論的限制。

Raw data、fio JSON、Ceph samples、attempt bundles 與 machine-readable verdict 保留在本輪獨立且被 git ignore 的 campaign results namespace，不放入 Markdown 正文，也不 commit。報告只引用其相對路徑、摘要值與 integrity manifest，讓本機仍可追溯原始證據。
