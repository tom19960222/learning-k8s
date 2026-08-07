---
status: accepted
---

# 以 profile gap 的 difference-in-differences 裁決 capacity sensitivity

本輪不以單一 profile 的絕對值裁決，而在每個 capacity 先計算 `high_client_ops` 與 `high_recovery_ops` 的 profile gap，再以 capacity B gap 減去 capacity A gap。Client IOPS retention 的 capacity effect 至少 10 個百分點才構成 screening signal；recovery time 沿用舊 production margin，須同時達相對 20% 與絕對 300 秒。只有 client 保護與 recovery 加速分別朝兩個極端 profile 的預期方向時才稱為 trade-off signal；未跨門檻只能寫「本輪未觀察到」，n=1 不得宣稱 equivalent。

Recovery capacity effect 的相對門檻分母固定為 common 2×2 四個 cell 各自 recovery time 中位數的總平均；materiality threshold 為 `max(300 秒, 該總平均 × 20%)`。比較 signed `recovery gap B − recovery gap A` 的絕對值是否跨過此門檻，再以正負號解讀方向。若任一 cell 只有右設限 `>30m`，使 available bounds 無法證明 capacity effect 已跨門檻或未跨門檻，verdict 必須標成 `censored-indeterminate`，不得把 30 分鐘代入為實際完成時間。

Capacity effect 必須保留正負號，不只搜尋支持原假設的結果。兩個 endpoint 的 `B gap − A gap` 都跨門檻且為正，才稱為支持「舊的低 declared capacity 可能遮住 profile 差異」；都跨門檻且為負，則反駁該方向，並顯示低 declared capacity 反而放大 profile 分離。Client 與 recovery 的方向不一致時標成 `mixed capacity sensitivity`，不得給整體支持或反駁結論；兩者都未跨門檻時只能寫「本輪未觀察到 capacity sensitivity」，不得宣稱 A/B equivalent。單一 endpoint 跨門檻時只報告該 endpoint 的方向性 signal。

Client p99 必須以毫秒完整記錄 baseline、fault、差值、rolling worst 與 elevated duration，但因沒有正式 SLO，不參與本輪 verdict。

Capacity A/B 必須使用相同 offered load，不得因某一 treatment 打不到 target 而臨時降載。取得連續 60 秒且吞吐 CoV 不超過 10% 的 pre-fault 穩定窗後，即可注入 fault；若實際 client IOPS 低於 target 的 85%，標記為 `pre-fault capacity-bound`，仍保留為有效觀測並同時報告絕對 IOPS 與相對 pre-fault baseline 的 retention。只有穩定窗無法建立、client 出錯或關鍵 telemetry 缺漏才算無效 execution。

Fault 期間沿用舊 coverage gate：單一 telemetry 缺口不得達 25 秒，全部缺口合計不得超過 30 秒，且四台 client 的 baseline 與 fault latency 資料都必須存在。若 p99 缺漏但 primary endpoint 完整，標記為 `partial execution`，保留有效 endpoint 並優先使用彈性時槽重跑；profile／capacity 套用證據、fault timeline 或 primary endpoint 缺漏才使整次 execution 無效。p99 完整性只決定 evidence completeness，不改變 profile verdict。

每次 execution 的 application latency observation 固定以毫秒產出：四台 client 合併的 overall p99 baseline／fault／差值、read 與 write p99、各 client p99 與 worst client、fault 期間最差 30 秒 rolling p99，以及 rolling p99 超過自身 baseline 2 倍的累積時間。`2× baseline` 只作描述性 elevated-duration trigger，不是 SLO，也不參與 verdict。

沿用既有 300 秒 fio segment，不為降低中斷資料損失而改短，以免同時改變 ramp 與 workload measurement 語意。若 execution 在 segment 完成前突然中斷，當下最多 5 分鐘的 p99 可能尚未落地；已完成 segment 與 5 秒 Ceph／recovery samples 必須保留。此情況依上述規則標記為 `partial execution`，明列 p99 缺口與最後可信時間戳，不把缺漏解讀為 latency 正常，也不以 p99 缺漏改寫 primary endpoint verdict。
