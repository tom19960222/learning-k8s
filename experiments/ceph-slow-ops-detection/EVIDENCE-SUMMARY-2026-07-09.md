# Evidence Summary — 2026-07-09（ceph-slow-ops-detection）

每列一個 run：scenario、注入方式、bundle 目錄（results/，gitignored——保留在本機）、結果。
`violated` = prediction 被推翻 = 有發現，不是執行失敗。

| Run | Scenario | 注入 | Bundle | Verdict | 備註 |
|---|---|---|---|---|---|
| 0 | e00（第一次，4MB 物件） | 無（純 16×4MB bench） | 20260709-083626-e00 | （中止：pgrep 自匹配） | 意外觀測窗：9/9 OSD counter 全增、max lat 44.7s → H-015 violated；SLOW_OPS 兩路一漏採一 blip → H-023 confirmed |
| 1 | e00-negative-control（1M） | 無（純 16×1M bench） | 20260709-085001-e00 | violated | 1M 全速仍 +52 → H-015 蓋棺；同時抓到 R1 regex 形式的重複 labelset 錯誤（規則改顯式相加） |
| 2 | e01-single-osd-transient | dm suspend 8s ×2（寫段+讀段），512K/t4 校準負載 | 20260709-090010-e01 | violated（2 子項） | 核心全過：counter +6、R1 **+14s** 判真、SLOW_OPS 全程 0、完成才記帳；違：op_w 均值僅 0.67s（H-007 稀釋更重）、讀段 0 增量（cache，→e01b） |
| 3 | e01b-cold-read-stall | fill→restart osd.0（清 cache）→冷讀 + suspend 8s | 20260709-090635-e01b | confirmed | slow_read_* +3 → H-010 |
| 4 | e02（第一次） | 同 node 3 dm 同秒 suspend 8s | 20260709-091031-e02 | violated | R2 訊號成立但 first-true 被 e01b fill 殘留污染 → 加 wait_quiet gate + alert 層斷言 |
| 5 | e02-multi-osd-same-node | 同上（quiet gate 後） | 20260709-091446-e02 | confirmed | R2 count=3 於注入 **+20s** 判真、達標 instance 恰 1 台 → H-004/H-022 |
| 6 | e03-idle-blindspot | dm suspend 15s、無負載 | 20260709-092028-e03 | confirmed | 全訊號靜默 → H-017 |
| 7 | e04 v2 | cgroup io.max wiops=8、150s | 20260709-092856-e04 | violated | op_w 均值 15.2s 而 SLOW_OPS 全程 0 → **H-024**（sub-30s 持續劣化盲區）；io.max 回退語法踩雷 |
| 8 | e04 v3 | （io.max EINVAL，空跑作廢） | 20260709-093716-e04-VOID | void | kernel 6.8 io.max 數值寫入 EINVAL（成因未解，踩雷記錄） |
| 9 | e04-sustained-throttle v4 | dm duty-cycle suspend8s/resume0.4s ×17（~143s）、t32 | 20260709-094532-e04 | violated（預測錯 daemon） | 三路 SLOW_OPS 首非零 **t_inj+45s**（R3/R4 可 fire +45~60s vs 舊規則 +120s）→ H-005；SLOW_OPS 亮的是**別台的 primary**（osd.4/6/7/8）而非被卡的 osd.0 → **H-025**；node_disk 對合成注入不可見 → H-009 violated（保真度邊界） |
| 10 | e05-exporter-freeze | SIGSTOP osd.0 15s、輕負載 | 20260709-095531-e05 | violated | 預測 stale、實際「短暫整體 stale → per-daemon 掉 series」；HTTP 200、up=1 全程 → H-013 修正 |
| 11 | e06-threshold-tuning | dm suspend 3s ×2（a=預設 5s；b=log_op_age=2） | 20260709-095824-e06 | confirmed | a：+0（5s 門檻對 3s 盲）；b：runtime 調 2s → **+6** → H-016（線上可調靈敏度） |
| 12 | seq-finale | restart osd.0/1/2 + 善後 | 20260709-100210-seq-finale | confirmed | latch restart 即清（H-008）、counter reset 無 R1 FP（H-020）、pool 刪除、最終 **HEALTH_OK 無豁免**。附加：restart 引發的 peering IO 會讓其他 OSD 重新 latch（osd.6），需沉降後再清 |

最終盤點：**19 confirmed / 4 violated / 2 proposed（H-012、H-018＝Gate 1 triage 為 T1 推理，不跑 T3）**。叢集回基線（HEALTH_OK、bench pool 已刪、monitoring stack 保留供後續 SP）。

harness 執行紀錄（供重跑）：負載校準 512K/t4＝0 slow op；wait_quiet gate 必開（[2m] lookback 會吃前場景殘留）；io.max 在此 lab 不可用（改 dm duty-cycle）。
