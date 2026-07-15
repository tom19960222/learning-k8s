# OSD latency 變高時，如何更快偵測、也更準確找到原因

> 從 SSD 暫態卡頓、IO 過載、BlueStore slow operation，到 client 已受影響的 slow ops
>
> 報告日期：2026-07-15
> 版本錨點：Ceph v19.2.3、Prometheus v2.51.0（快速 slow-ops 研究）／v3.2.1（production alert 真機驗證）
> 證據來源：Ceph 原始碼、兩批真機故障注入、既有 alert rules、PVE SMART 觀察與保留下來的 evidence ledger

## 0. 給主管的兩分鐘版本

我們現在面對的不是「有沒有 slow ops alert」而已，而是兩個不同問題：

1. **能不能在 5～8 秒事件結束後數十秒內留下可行動訊號，而不是等到 30 秒級 `SLOW_OPS`？**
2. **看到 latency 變壞後，能不能分辨是單顆 SSD／device path、同 node 共用硬體、全 cluster IO 過載，還是 BlueStore 內部卡頓？**

既有的 Ceph `SLOW_OPS` 只會計算「仍在飛、而且已超過 `osd_op_complaint_time`」的 op；預設門檻是 30 秒。生產曾出現疑似 SSD／firmware 的 5～8 秒暫態卡頓，事件結束得太快，**在機制上不可能進入這條告警路徑**。真機注入 8 秒卡頓時，兩路 `SLOW_OPS` metric 全程都是 0。

Ceph Squid 新增的四個 BlueStore slow counter 能補上這個洞。實測結果：

| 情境 | 建議訊號 | 真機資料多久看得出來 | Prometheus 最晚多久進入告警 | 通知是否真的送達 |
|---|---|---|---|---|
| 單顆 OSD 卡 8 秒 | `CephOSDTransientStall` | 事件開始後 **14 秒**看見 | 推估不晚於 **29 秒** | **尚未實測** |
| 同 node 三顆 OSD 同窗卡 8 秒 | `CephNodeMultiOSDStall` | 事件開始後 **20 秒**看見 | 推估不晚於 **35 秒** | **尚未實測** |
| request 真正卡超過 30 秒 | `CephDaemonSlowOpsFast`＋`CephClusterSlowOpsFast` | 約 **45 秒**看見 | 推估約 **45～60 秒** | **尚未實測** |
| OSD 持續離群 | `CephOSDLatencyOutlier` | 持續 10 分鐘後進入告警 | 已在真機驗證 | Slack 送達已驗 |

但**更快不等於更準**。無故障的重負載也曾讓 9/9 OSD 的 BlueStore counter 增加；因此任何單一 counter 只能說「這裡發生過超過 latency 預算的操作」，不能直接說「SSD 壞了」。正確做法是：

> **先偵測症狀，再用 client、OSD、node、device 的跨層證據歸因；任何單一 alert 都不能證明 SSD 已損壞。**

建議分三個階段落地：

1. **先補整合缺口，再上快訊號**：四條規則已有自動測試與真機資料，但還沒證明通知能正確送達。上線前要先修正通知路徑、避免把全 cluster 過載誤判成單 node 硬體故障，並補上「某顆 OSD metric 消失」的告警；完成後先只記錄、不通知值班人員。
2. **補準確歸因**：把 client p99、per-OSD commit/apply latency、同 node 受影響 OSD 數量、recovery/backfill 與 device 指標放進同一個事件視圖。
3. **補硬體證據**：incident bundle 目前已有 Prometheus dump 與 `iostat`，但還缺 SMART 與 RAID/HBA event；這是要把「同 node 聚集指紋」升級成「可交給硬體團隊處理的證據」的最後一哩。

閱讀方式：主管先看 §0、§9、§11～§14；負責 Prometheus 與 Ceph 的同事再看 §5～§8 與 §15。本文的數字分成 expression 首真、alert firing、receiver 送達三層；沒有 receiver 證據時不會把它寫成 pager SLA。

---

## 1. 先把四個容易混淆的名詞分開

### 1.1 OSD latency

泛指一顆 OSD 處理 IO 的延遲。`ceph_osd_commit_latency_ms` 與 `ceph_osd_apply_latency_ms` 是 mgr 匯出的 per-OSD 統計，適合找持續離群的 OSD；它們不是每筆 IO 的完整 latency 分布，也會稀釋短暫尖峰。

### 1.2 BlueStore slow operation

BlueStore 內部某個階段超過 `bluestore_log_op_age` 就會被視為 slow operation；Ceph v19.2.3 預設是 **5 秒**。這是一個 storage engine 層的事件，不等於 client request 已卡滿 30 秒。

### 1.3 `SLOW_OPS`

OSD op tracker 檢查「仍在飛、而且已超過 `osd_op_complaint_time`」的 request；預設是 **30 秒**。它回答的是「現在是否已有 request 卡得很嚴重」，不是「剛才是否發生過 5 秒 SSD 暫停」。

### 1.4 client p99

第 99 百分位的端到端 IO latency。這最接近 workload 的實際體感，但只告訴我們「使用者正在痛」，不會直接告訴我們是哪顆 OSD、哪個 node 或哪個 device 造成。

這四者是互補關係：client p99 負責確認影響，BlueStore counter 負責留下 per-OSD storage-path 症狀，OSD commit/apply latency 負責看持續離群，`SLOW_OPS` 負責抓永久或超過 30 秒的嚴重 request。

### 1.5 本文會用到的短詞彙

| 詞彙 | 本文中的意思 |
|---|---|
| scrape／evaluation／receiver | Prometheus 抓 metric／計算 alert rule／Alertmanager 實際送通知；三者時間不能混為一談 |
| replica／acting set | 同一份資料的副本／目前負責某個 PG 的 OSD 集合 |
| size／min_size | pool 的副本數／仍允許 IO 的最少副本數 |
| PLP | power-loss protection；掉電時保護尚未落盤資料的 SSD 能力 |
| HBA | host bus adapter；連接主機與磁碟／背板的儲存介面卡 |
| CoV | coefficient of variation；用來看多輪量測的相對波動 |
| 原始碼證據／真機證據 | 前者說明機制如何運作，後者證明實際環境觀察到相同行為 |
| shadow | 載入規則並記錄結果，但先不送 pager |
| SLO | 團隊對 workload 可接受 latency／availability 的服務目標 |

後文的 cgroup、PromQL 與 label-set 細節只影響實作者，集中放到 §15，不作主管判斷前提。

---

## 2. 這份報告用了哪些環境，可信到哪裡

### 2.1 Ceph slow-ops 真機 lab：告警時間的主要證據

- Ceph v19.2.3 Squid、cephadm。
- 3 MON、9 OSD，三個 OSD node 各三顆。
- Prometheus v2.51.0，scrape interval 10 秒、rule evaluation interval 15 秒。
- 以 `dmsetup suspend` 模擬 device 暫停，以 duty cycle 模擬持續慢盤。
- 研究 backlog 共 25 條 hypothesis：19 confirmed、4 violated、2 條只有原始碼推理，尚未完成真機驗證。
- `EVIDENCE-SUMMARY-2026-07-09.md` 保留 13 筆 run 記錄：11 筆完成且可判讀、1 筆中止但留下有效意外觀測、1 筆因注入未生效而明確標為 void。

這組環境最適合回答「哪個 metric 先動、expression 何時首真、規則會不會漏採」，不代表生產 RAID 卡或 SSD firmware 已被重現。

### 2.2 Production alert 真機 lab：firing、routing 與 receiver 的主要證據

- 與快速 slow-ops 研究相同的 Ceph v19.2.3 cluster：3 MON、9 OSD，三個 OSD node 各三顆。
- 監控 stack 使用 Prometheus v3.2.1、Alertmanager v0.28.1，以及分別代表 pager、Slack、watchdog 的 webhook sink。
- 22 場 production alert scenario 中，本文只納入 slow-ops 與 `CephOSDLatencyOutlier`；其他 quorum、容量、crash、data damage 場景不拿來支持 disk latency 結論。
- 每場都保留 Prometheus firing、receiver 到達、negative assertion、rollback 與健康恢復證據。

這組環境適合回答「規則是否真的 firing、通知是否走到正確 receiver」。但四條新快速偵測規則尚未放進這套端到端流程，因此 +14／+20 秒只能算真機 series 的離線重放結果，不能當 pager SLA。

### 2.3 homelab PVE：只作低信心 SSD 觀察，不拿來定門檻

PVE 環境有明顯干擾：SSD pool 只有兩顆 OSD、size=min_size=2、public network 是 1G、同 pool 有其他 workload、基線已存在 osd.0 BlueStore warning，部分實驗 CoV 很高。本文**不使用它的效能數字制定 alert threshold，也不拿它證明因果**。

只保留 read-only SMART／inventory 觀察：

- osd.0：Crucial MX300 275GB，消費級、無 PLP。
- wear 90%、average block erase count 1360／約 1500。
- power-on 29,154 小時、7 個 reallocated sector。
- osd.8：OCZ ARC100，同樣是消費級、無 PLP。

這些資料足以支持「硬體狀態值得優先檢查」。改用有 PLP 的資料中心級 SSD 是基於 Ceph durability／flush workload 的 engineering recommendation，不是這組觀察單獨證明的實驗結論；更不能寫成「某次 BlueStore slow operation 已證明由 SSD 老化造成」。

### 2.4 證據分級

| 結論 | 證據等級 | 可否直接採用 |
|---|---|---|
| 5～8 秒事件不會進 30 秒 `SLOW_OPS` | 原始碼＋真機 | 機制級，可採用 |
| BlueStore counter expression 14～20 秒首真 | 真機資料離線重放 | 可作 expression 時序證據；未驗 receiver |
| 同 node 多 OSD 是共用元件指紋 | 真機合成注入＋拓樸推理 | 可用於升級調查，不能直接定罪 firmware |
| `CephOSDLatencyOutlier` 能完成 firing 與 Slack routing | 真機 alert scenario | 可作既有持續離群告警的端到端證據 |
| PVE SSD 老化就是 slow-op 根因 | 觀察性資料 | 不可當已證因果，只能當風險案例 |

### 2.5 實驗帳目如何對上本文

這是一份跨研究整合報告，不是新開一批實驗；以下對帳可避免只挑漂亮數字：

| 原研究 | 原始帳目 | 本文納入 | 其餘項目如何處理 |
|---|---|---|---|
| `ceph-slow-ops-detection` | 25 hypotheses；13 筆 run 記錄 | 無故障高負載、單 OSD 暫停、同 node 多 OSD 暫停、idle、持續慢盤與 observer freeze（E-00～E-06） | 所有 hypothesis 都留在 backlog；與本題無直接關係的版本史與清理細節只列 §15 索引 |
| `ceph-alert-real-lab` | 22 個 production alert scenario | slow-ops 與 latency-outlier 實驗（S1、S11） | 其餘 20 場是 quorum、容量、crash、data damage 等 coverage，與 OSD latency 歸因無直接關係 |
| homelab PVE | 多組 RBD IO 實驗＋read-only SSD 調查 | 只納入 SMART／inventory | 效能結果受 1G 網路、兩 OSD、共用 workload 與高 CoV 影響，不進門檻或效果量結論 |

slow-ops 的 25 條 hypothesis 不是 25 個獨立 scenario；多條 hypothesis 由同一次注入共同驗證。13 筆 run 中，11 筆完成並有 verdict、1 筆中止但留下有效意外觀測、1 筆因注入未生效標為 void。這些失敗與重試沒有從帳上刪除。

---

## 3. 一筆 IO 在哪裡可能變慢

```text
workload / VM
  -> client（krbd / librbd）
  -> primary OSD
  -> replica OSD
  -> BlueStore
  -> block device
  -> SSD / RAID / HBA
```

寫入 size=3 的 pool 時，primary 通常要等 replica 完成必要階段才能回覆 client。這會造成一個很重要的定位陷阱：

- 被卡住的 SSD 可能位於 osd.0。
- 等待 osd.0 replica ack 的 primary 可能是 osd.4。
- `SLOW_OPS` 記在 primary 的 op tracker，因此告警顯示 osd.4。
- BlueStore slow counter 是 per-OSD storage-path 計數，較可能指向真正卡住的 osd.0，但仍未直接定位到實體 SSD。

在持續慢盤實驗裡，被限速的是 osd.0，但 daemon `SLOW_OPS` 出現在 osd.4/6/7/8。若 on-call 只看 `SLOW_OPS` label，就可能查錯磁碟。

所以定位順序應該是：

1. 用 client p99 確認影響。
2. 用 BlueStore counter 與 commit/apply latency 找 per-OSD storage-path 異常。
3. 用 `SLOW_OPS` 判斷 request 是否已嚴重卡住，但不單靠它定根因。
4. 用 node/device 訊號確認 SSD、RAID/HBA 或 IO 爭用。

---

## 4. 五種常見的 OSD latency 事件

### 4.1 單顆 SSD 或單一路徑暫態異常

典型形狀是單一 OSD 的 BlueStore counter 增加，同 node 其他 OSD 沒有同窗事件。可能原因包含 SSD firmware GC、media retry、單一 virtual disk、纜線或 device path 暫停。

單顆事件只能先列為「per-OSD storage-path 症狀」；下一步要查 SMART、kernel log、`iostat -xz`、RAID/HBA event 與同 node 對照，不能直接換碟。

### 4.2 同 node 多顆 OSD 在同一時間窗卡頓

若同一台 node 有三顆以上 OSD 在同一兩分鐘窗內出現 BlueStore slow counter，**而其他 node 沒有同樣聚集**，單顆 SSD 獨立故障已不容易解釋這個形狀。優先懷疑：

- 共用 RAID/HBA。
- 背板或共用 bus。
- 同型號／同批次 SSD firmware 行為。
- node memory pressure 或整台 node 的 IO 路徑。

這是一個**同 node 聚集指紋**，不是 firmware 的證明。`CephNodeMultiOSDStall` 目前只計算每個 node 在兩分鐘窗內有幾顆 OSD 出現 counter 增量；它沒有檢查其他 node 是否也成立，也不能證明三顆是在同一秒卡住。無故障高負載實驗（E-00）的全 cluster 過載會讓每個 node 都符合條件，因此這條規則在補上 cluster-wide correlation／抑制前不應直接 page。要完成歸因，仍需 controller log、SMART、kernel 與 workload 時間線。

### 4.3 IO 過重、backfill、recovery 或 scrub

無注入的 16×4MiB `rados bench` 曾讓 9/9 OSD counter 全部增加，max latency 44.7 秒。這推翻了「正常負載絕不會產生 >5 秒 BlueStore op」的預測。

判讀重點不是把它叫 false positive，而是看分布：

- 單顆 OSD：偏向單一路徑問題。
- 同 node 多顆、其他 node 正常：偏向共用 node/device 元件。
- 多個 node、大量 OSD 同時出現，且伴隨高 client throughput、backfill、recovery 或深佇列：偏向 cluster-wide IO 壓力。

因此告警不能只看絕對 latency，還要帶上 recovery、backfill、scrub、client throughput 與受影響範圍。多個 node 同時出現 counter 增量時，應先判為 cluster-wide pressure，而不是同時宣告多顆 SSD 故障。

### 4.4 BlueStore 內部 slow operation

Ceph v19.2.3 的 `bluestore_log_op_age` 預設 5 秒。四個可由 ceph-exporter 匯出的 counter 是：

- `ceph_bluestore_slow_aio_wait_count`
- `ceph_bluestore_slow_committed_kv_count`
- `ceph_bluestore_slow_read_onode_meta_count`
- `ceph_bluestore_slow_read_wait_aio_count`

它們涵蓋幾個關鍵 read、等待底層 IO 完成與 commit 路徑，但不是每一行 `slow operation observed` log 都有專用 counter。既有研究比對到多個只有 log／health event、沒有上述四個 counter 的呼叫點，因此「四個 counter 都沒動」不能排除所有 BlueStore slow operation。

`BLUESTORE_SLOW_OP_ALERT` 走另一條 health 路徑，預設 lifetime 是 86,400 秒（24 小時）、threshold 是 1。它適合回答「昨晚是否發生過」，不適合即時 pager：事件早已結束，health warning 仍可能留一整天。

### 4.5 永久卡死、process freeze 或 telemetry 失明

BlueStore slow counter 通常要等對應階段完成才記帳；它是事件結束後快速留下痕跡，不保證能在受影響的那筆 client IO 完成前預警。op 永久卡住時，它可能一直不增加。OSD process 被 freeze 時，ceph-exporter 也可能先短暫回舊值，接著只讓該 daemon series 消失；HTTP 仍是 200、Prometheus `up` 仍是 1。

因此快速 counter 不能取代：

- daemon／cluster `SLOW_OPS`。
- OSD down、flapping、recent crash。
- per-daemon series absent／freshness。
- client timeout／stall。

---

## 5. 為什麼既有監控會晚、會漏、甚至會指錯人

### 5.1 30 秒門檻看不到 5～8 秒事件

Ceph 原始碼把 `osd_op_complaint_time` 預設設為 30 秒；OSD health metric 從目前仍在飛的 op 中找超齡 request。5～8 秒事件完成後就離開 tracker，不會留下 `SLOW_OPS` 訊號。

### 5.2 snapshot gauge 可能落在採樣縫隙

真機曾出現 max latency 44.7 秒的 slow op：mon 端 health detail 抓到兩個樣本，但 per-daemon metric 整段漏掉。原因是 daemon gauge 在 op 完成後歸零，可見窗只有「實際 op 齡減 30 秒」；再穿過 mgr cache 與 10 秒 scrape，很容易沒有任何樣本。

這就是為什麼嚴重 slow-request 告警要同時保留 daemon 與 mon 兩路，並用 `max_over_time()` 留住短暫訊號。它證明 OSD tracked request 已超齡；workload 是否已違反 SLO，仍要回到 client p99 確認。

### 5.3 平均值會把暫態卡頓稀釋掉

單 OSD 8 秒暫停實驗中：

- `ceph_osd_commit_latency_ms` 只顯示約 754ms。
- `rate(op_w_latency_sum)/rate(count)` 峰值只約 0.67 秒。

這兩者並非沒用，而是不適合當暫態事件的唯一快訊號。它們更適合持續劣化的嚴重度與離群比較。

### 5.4 `ceph health` 不負責保證 latency

Ceph health 主要描述 quorum、daemon、PG、容量與已知 health check；它不是 workload latency SLO。單 OSD 暫停 8 秒的真機實驗中，兩路 `SLOW_OPS` metric 都是 0，正好說明短於 30 秒的 disk stall 可以完全落在既有 slow-ops health path 之外。

### 5.5 既有 latency-outlier 規則是慢而穩，不是快訊號

目前 `CephOSDLatencyOutlier` 的條件是：

- commit latency >100ms。
- 同時高於全體 OSD 中位數 3 倍。
- 持續 10 分鐘。

真機 latency-outlier 實驗（S11）先把 osd.7 限到 4MiB/s，仍不足以撐過 `for:`；收緊到 1MiB/s 後才 firing，且已驗證 Slack receiver 收到、pager 沒收到。它適合抓「持續離群的 OSD」，不應拿來承擔 5～8 秒暫態卡頓。

### 5.6 三種時間證據不能混用

- **expression 首真**：PromQL 對已收集的 series 第一次算出 true。`CephOSDTransientStall` 的 +14s 與 `CephNodeMultiOSDStall` 的 +20s 屬於這一層，而且是 `query_range` 離線重放。
- **alert firing**：Prometheus 定期 evaluation 後把 rule 轉成 firing。若 evaluation interval 為 15 秒、`for: 0`，`CephOSDTransientStall` 推估不晚於 +29s，`CephNodeMultiOSDStall` 不晚於 +35s；這兩個上限尚未在 live rule evaluator 驗證。
- **receiver 送達**：Alertmanager 完成 routing 後，Slack／pager 真正收到。四條快速偵測規則尚無這層證據；只有 `CephOSDLatencyOutlier` 完成了 receiver 驗證。

因此本文把四條快速偵測規則定位為「promtool 已過、真機 series 時序已驗、production integration 未完成」，不能把 +14／+20 秒當成 pager SLA。

---

## 6. 實驗總覽：測了什麼、預期什麼、結果如何

`violated` 代表事前 prediction 被推翻，不代表實驗失敗。被推翻的項目反而是這次規則設計最有價值的部分。

### 6.1 負載、時間與重複方式

| 實驗群 | workload／注入矩陣 | 時間與重複 |
|---|---|---|
| 無故障高負載（E-00） | 先 16×4MiB、再以 16×1MiB `rados bench` 作 negative control | 兩筆獨立 run；第一筆中止但保留意外觀測 |
| 單 OSD 暫停與同 node 多 OSD 暫停（E-01、E-01b、E-02） | 校準負載 512KiB、4 threads；單 OSD suspend 8s（寫、讀各一段）；fill＋restart 後做冷讀；同 node 三顆 OSD suspend 8s | 每個 scenario 一筆 final run；另保留被前場景污染的同 node 重試史 |
| idle OSD 暫停（E-03） | idle、無 client IO，單 OSD suspend 15s | 一筆 run |
| 持續但未滿 30 秒的慢 IO（E-04 v2） | cgroup `io.max wiops=8` 持續 150s，觀察到每筆 op 約 15.2s | 一筆有效 run；後續一筆因 kernel 拒絕設定標 void |
| 超過 30 秒的持續卡頓（E-04 v4） | 32 threads；suspend 8s／resume 0.4s ×17，總注入約 143s | 一筆 final run |
| observer freeze 與 2～5 秒靈敏度（E-05、E-06） | 輕負載下 SIGSTOP osd.0 15s；另以 suspend 3s ×2 比較 age=5s／2s | 各一筆 final run |
| 持續 latency outlier（S11） | `rados bench` 1120s、16 threads；先 4MiB/s，再於同 run 收緊至 1MiB/s | 一筆長時 run，涵蓋完整 10m `for:` |
| PVE | 本文不使用效能 run，只用 read-only SMART／inventory | 不參與 alert threshold 統計 |

這些 fault scenario 是可回退的固定長窗，可回答機制與事件內時序，不能被當成大量獨立 incident 的統計分布。

### 6.2 逐實驗結果

| 情境 | 為什麼測 | 注入／調整 | 事前預期 | 實測結果 | 對監控的影響 |
|---|---|---|---|---|---|
| 無故障高負載（E-00） | 驗 false positive | 無注入高負載 | counter 應保持 0 | ❌ 9/9 OSD 增加，max 44.7s | counter 定位為症狀，不直接定罪硬體 |
| 單 OSD 暫停 8 秒（E-01） | 重現 5～8s 暫態 | 單 OSD suspend 8s | counter 快、SLOW_OPS 不動 | ✅ expression 離線重放首真 +14s；SLOW_OPS=0 | `CephOSDTransientStall` 可補暫態盲區，但未驗 receiver |
| 冷讀暫停（E-01b） | 避免 read cache 掩護 | 冷 cache read＋suspend | read counter 應增加 | ✅ `slow_read_*` +3 | 冷讀路徑可被看見 |
| 同 node 三顆 OSD 暫停（E-02） | 驗同 node 聚集 | 三 OSD 同窗 suspend 8s | 只有該 node 聚集 | ✅ count=3，expression 首真 +20s | `CephNodeMultiOSDStall` 有聚集能力，但須補全 cluster 過載排除 |
| idle OSD 暫停（E-03） | 找 idle 盲區 | idle OSD suspend 15s | 可能仍有背景訊號 | ❌ 全部靜默 | idle 是結構性盲區 |
| 持續但未滿 30 秒的慢 IO（E-04 v2） | 驗持續 sub-30s 劣化 | `wiops=8`、150s | 應出現 SLOW_OPS | ❌ op 約15.2s、SLOW_OPS=0 | 發現持續劣化盲區 |
| 超過 30 秒的持續卡頓（E-04 v4） | 驗 >30s severe path | suspend/resume duty cycle | 30～60s 內出現嚴重訊號 | ✅ expression 首真約 +45s；推估 firing +45～60s | 兩條 severe slow-request 規則可省掉舊規則額外 1m，未驗 receiver |
| observer freeze（E-05） | 驗 observer freeze | SIGSTOP osd.0 15s | exporter 會回 stale | ❌ 後續是 per-daemon series 消失 | 必須另做 absent/freshness rule |
| 2～5 秒門檻比較（E-06） | 驗 2～5s 靈敏度 | 3s stall；age 5s vs 2s | 5s 看不到、2s 看得到 | ✅ +0 -> +6 | 2s 可試點，但要承擔噪音 |
| 持續 latency outlier（S11） | 驗持續離群與 routing | osd.7 長時間限速 | latency outlier 應 firing | ✅ 1MiB/s 段走滿 10m；Slack 到、pager 無 | 適合持續 warning，不適合快報 |
| PVE SMART | 補實體盤觀察 | read-only 盤點 | 老舊消費 SSD 可能是風險 | 觀察到 90% wear、無 PLP | 只作風險案例，不作因果證明 |

### 6.3 被推翻的預測如何改變設計

1. **高負載也會增加 counter**：`CephOSDTransientStall` 只代表「暫態卡頓症狀」，硬體歸因交給同 node 聚集規則與跨層證據。
2. **平均 latency 對暫態不敏感**：不再拿平均值當 5～8 秒事件主訊號。
3. **daemon SLOW_OPS 可能整段漏採**：增加 mon 端 `CephClusterSlowOpsFast` 備援。
4. **SLOW_OPS 可能指向等待 replica 的 primary**：定位優先看 BlueStore counter。
5. **device suspend 不會讓 node disk busy 必然上升**：bio 可能被擋在 device 之上；`node_disk_*` 只當佐證，不設未驗證的固定倍率。
6. **注入是否生效是一等證據**：cgroup 限速曾套到空殼 unit；沒有行為級生效證據的陰性結果一律作廢，技術細節見 §15。

---

## 7. 建議的五層偵測架構

### 先確認監控本身活著

目的：避免「沒有告警」其實只是 metric 消失。目前只有 observer freeze 實驗（E-05）的證據，**repo 尚無可直接部署的 per-daemon absent/freshness rule**，必須優先實作。

- exporter `up`。
- 每顆 OSD 應有的 series 是否 absent。
- sample timestamp／freshness。
- mgr failover 前後的 metrics continuity。

### 確認 workload 是否真的受影響

目的：把 storage 內部事件與使用者痛感接起來。

- workload／VM block latency p99、p99.9。
- timeout、stall、queue depth。
- 建議以各 workload 自身 7 日同時段 baseline 做倍數比較。

本文的故障注入沒有驗證通用的 client p99 門檻。production 應依 workload SLO 與 shadow baseline 設定；client 訊號在這裡只負責確認 disk 事件是否真的影響 workload，不拿來取代 per-OSD 定位。

### 快速找出 per-OSD storage-path 症狀

目的：在 5～8 秒事件結束後，仍能知道哪顆 OSD 剛才卡過。

- 四個 `ceph_bluestore_slow_*_count` 的 `increase()`。
- `ceph_osd_commit_latency_ms`／`apply_latency_ms` 相對全體中位數。
- `ceph_osd_metadata` 將 OSD 對應到 hostname。

### 確認是否已有嚴重超齡 request

目的：對已超過 30 秒的 OSD tracked request 立即調查，不再多等一分鐘。這類訊號本身不證明 workload SLO 已破；是否 page 應結合 client impact，或由團隊明確接受「severe request 先 page、再查 client」的政策。

- daemon：`max_over_time(ceph_daemon_health_metrics{type="SLOW_OPS"}[1m]) > 0`。
- mon 備援：`max_over_time(ceph_health_detail{name="SLOW_OPS"}[1m]) > 0`。
- 兩者都搭配 `keep_firing_for`，保留短暫訊號供 on-call 看見。

### 用受影響範圍與硬體訊號做歸因

目的：分辨「單碟、單 node、全 cluster」。

- 同 node 在兩分鐘窗內受影響的 OSD 數量。
- `node_disk_io_time_weighted_seconds_total`、`iostat -xz`。
- SMART wear、media error、reallocated sector。
- RAID/HBA event、virtual disk／physical disk 狀態。
- recovery、backfill、scrub、client throughput。

---

## 8. 告警組合與時間預算

研究版規則位於 [`../ceph-slow-ops-detection/rules/ceph-slow-ops-fast.yml`](../ceph-slow-ops-detection/rules/ceph-slow-ops-fast.yml)，持續離群規則位於 [`../ceph-alert-rules/rules/ceph-production-coverage.yml`](../ceph-alert-rules/rules/ceph-production-coverage.yml)。四條快速偵測規則不是可直接複製到 production 就完成的 bundle；下列整合缺口要先修。

| 規則 | 用途 | 現行門檻 | 路由建議 | 重要限制 |
|---|---|---|---|---|
| `CephOSDTransientStall` | 單 OSD 剛發生 >5s BlueStore op | 1m increase >0；keep 10m | warning／事件記錄 | 過載也會觸發 |
| `CephNodeMultiOSDStall` | 同 node 聚集候選 | 2m 內 ≥3 OSD；keep 15m | 先 shadow；補過載排除後才考慮 critical | 全 cluster 過載時每個 node 都會成立；2m 同窗不等於同秒 |
| `CephDaemonSlowOpsFast` | daemon 端 >30s request | 1m max >0；keep 10m | 先驗 routing；是否 pager 由 SLO 政策決定 | 可能指向等待 replica 的 primary；不證明 client SLO 已破 |
| `CephClusterSlowOpsFast` | mon 端漏採備援 | 1m max >0；keep 10m | 與 `CephDaemonSlowOpsFast` 建共同 incident key | 沒有 per-OSD label；不證明 client SLO 已破 |
| `CephOSDLatencyOutlier` | 持續 commit latency 離群 | >100ms 且 >median×3，for 10m | warning／Slack | 太慢，不抓暫態 |
| client p99 | 確認 workload impact | 依 workload SLO；先以生產 shadow 建 baseline | 依 workload SLO | 本研究未驗證通用門檻 |

### 8.1 上線前五個硬性 blocker

1. **routing allowlist 不認得新 source**：四條快速偵測規則的 `source=ceph_slow_ops_fast` 不在現行 `alertmanager-route.yml` 的 matcher；critical 會落到預設 Slack receiver，不會進 pager。
2. **現行 grouping 無法合併 slow-request 通知**：`group_by` 含 `alertname`，`CephDaemonSlowOpsFast`、`CephClusterSlowOpsFast` 與既有 `CephClientBlocked{name="SLOW_OPS"}` 都會成為不同通知。需要共同 `incident_class`、inhibition 或自訂 route，不能只在報告裡說「視為同一事件」。
3. **既有 catch-all 會繞過新分級**：`CephClientRisk` 沒排除 `BLUESTORE_SLOW_OP_ALERT`，health latch 維持 24 小時時，會在 5 分鐘後以 critical page。若 `CephOSDTransientStall` 要當 warning、latch 只作盤後證據，就必須先修 catch-all 並補測試。
4. **`CephNodeMultiOSDStall` 沒排除全 cluster 過載**：無故障高負載實驗（E-00）的 9/9 OSD 增量會讓每個 node 都符合條件。production 版要加入「多 node 同時成立時改判 cluster-wide pressure」的 correlation／抑制，或至少在 routing 前加 recording rule 分類。
5. **per-daemon telemetry 缺少可部署的存活規則**：observer freeze 實驗（E-05）所需的 absent/freshness rule 目前沒有實作；不能只靠 exporter `up`。

以上五項沒有完成前，四條快速偵測規則只能 shadow，不應開 pager。

### 8.2 事件合併原則

同一事件可能同時出現單 OSD 暫態、同 node 多 OSD 聚集、兩路 severe slow-request、latency-outlier 與 client p99 訊號。production 設計應先產生共同事件分類，再 routing：

- `CephNodeMultiOSDStall` 成立時，把該 node 的多個 `CephOSDTransientStall` 當細節；若多個 node 同時成立，改標 cluster-wide pressure，不發多張「硬體」page。
- `CephDaemonSlowOpsFast` 與 `CephClusterSlowOpsFast` 代表同一 severe slow-request 類別的兩個 sensor，但要用共同 label 或 Alertmanager inhibition 合併。
- latency-outlier 維持 warning；是否升 pager 取決於 client SLO breach、severe slow request 或經驗證的單 node 聚集。
- sensor absent 要獨立呈現，不能被 storage alert 抑制。
- `increase()[1m]` 通常會跨數次 evaluation 為正；`for: 0` 的理由是不要再壓縮有限事件窗、爭取最低延遲，不是「只會剩一個 evaluation」。
- `keep_firing_for` 讓通知在訊號消失後仍保留 10～15 分鐘，代表「事件近期發生過」，不代表 storage 仍持續慢；annotation／dashboard 要同時顯示最後一次 counter 增量與目前 client p99。

PromQL regex／label-set 的實作踩雷移到 §15，避免阻斷管理決策主線。

---

## 9. 收到訊號後，怎麼判斷是哪一類問題

| 觀測組合 | 較可能原因 | 不能直接下的結論 | 第一個動作 |
|---|---|---|---|
| 單一 OSD 出現 `CephOSDTransientStall`，其他 OSD 正常 | 單一 SSD／device path 暫態 | SSD 已壞 | 查該 device SMART、kernel、iostat |
| 同 node 至少三顆 OSD 出現 `CephOSDTransientStall`，其他 node 正常 | RAID/HBA、背板、firmware、node 資源 | firmware 已確診 | 查共用硬體與 controller event |
| 多個 node、大量 OSD 出現 `CephOSDTransientStall`，同時 throughput 高 | workload、recovery、backfill、深佇列 | 多顆 SSD 同時壞 | 查 cluster-wide IO 與背景工作 |
| `CephDaemonSlowOpsFast` 指向 A、`CephOSDTransientStall` 指向 B | A 可能在等待 B 的 replica ack，也可能是兩個獨立問題 | 只靠時間共現就已完成歸因 | 查 A 的 historic ops、PG acting set，再驗證是否真的包含 B |
| severe slow-request 有訊號、`CephOSDTransientStall` 無訊號 | 永久卡死、未覆蓋的 BlueStore 路徑或採樣時序 | 沒有 device 問題 | 查 historic ops、daemon log、absent |
| commit latency 長期離群、`CephOSDTransientStall` 反覆出現 | 持續 device 劣化或長期過載 | 必然是 media failure | 用 SMART／RAID／負載完成歸因 |
| daemon series 消失、HTTP `up=1` | OSD freeze 或 exporter 讀不到 daemon | 問題已恢復 | 查 OSD process、down、crash 與 freshness |

判讀原則只有兩條：

1. **先看範圍**：單 OSD、單 node、還是全 cluster。
2. **再看共同時間線**：client p99、BlueStore counter、OSD latency、device 與 recovery 是否同時變化。

---

## 10. On-call 的前 15 分鐘

### 0～2 分鐘：確認影響與 sensor

1. 看 client p99／timeout，確認是否已有 workload impact。
2. 看 Prometheus targets、exporter `up` 與 per-daemon series，排除 sensor 失明。
3. 記錄告警開始時間，不要只看目前 `ceph -s`。

### 2～5 分鐘：縮小到 OSD、node 或 cluster

1. 列出最近兩分鐘有 BlueStore counter 增量的 OSD。
2. 對應 hostname，判斷是否集中同 node。
3. 比對 commit/apply latency、device busy、recovery/backfill 狀態。
4. 若只有 `SLOW_OPS`，確認它是否只是等待 replica 的 primary。

### 5～10 分鐘：啟動證據收集

先執行 read-only 收集，不要急著 restart OSD。現有工具：

```bash
bash experiments/ceph-incident-bundle/run/collect.sh \
  --inventory <inventory.env> \
  --ssh-key .ssh/id_ed25519 \
  --since 2h \
  --prom-url <prometheus-url>
```

bundle 已包含 cluster 狀態、Prometheus 時序、node 資源、`iostat`、kernel／systemd／Ceph log。**這個階段的目標是五分鐘內啟動，不是保證五分鐘內收完**：工具逐台序列收集，Prometheus dump 與單 node 預設 timeout 都可能超過五分鐘。事故期間可先釘 `--mode cephadm --seed ...` 減少 auto probe，再讓完整收集繼續跑；不要為了等 bundle 阻塞止血判斷。現況缺口是 SMART 與 RAID/HBA event，現場仍要另外收集並與 bundle 使用相同時間戳。

### 10～15 分鐘：依證據選處置

- **cluster-wide IO 壓力**：先確認 backfill/recovery/scrub 與 client 競爭，再評估降載或調整恢復速度。
- **單 device 持續離群＋SMART／controller 證據**：準備隔離與換碟計畫。
- **同 node 多 OSD＋controller event**：升級為 host／RAID/HBA 事件，不要逐顆 OSD 各自處理。
- **永久卡死**：同時看 `ok-to-stop`、quorum、PG 與 redundancy，再做任何 restart／stop。

一條 alert 不足以授權破壞性動作。停止 OSD 前仍要遵守 `ceph osd ok-to-stop`、確認 quorum、預先寫好 rollback，並在處理後確認 `HEALTH_OK` 或明確列出既存 health baseline。

---

## 11. 落地順序

### 第一步：先補 production integration

- `CephOSDTransientStall` 與 `CephNodeMultiOSDStall` 需要 Squid v19.2.0+ 的四個 counter。
- 確認 `/metrics` 能看到四個 `ceph_bluestore_slow_*_count`。
- 確認 `ceph_daemon` 與 `instance`／hostname 的對應；`CephNodeMultiOSDStall` 的 `count by (instance)` 必須真的是 per-node。
- 確認 Prometheus 支援 `keep_firing_for`（v2.42+）。
- 實作 per-daemon absent/freshness rule，補 observer freeze 實驗（E-05）對應測試。
- 修 Alertmanager source allowlist 與共同 incident grouping，讓 `CephDaemonSlowOpsFast` 與 `CephClusterSlowOpsFast` 能去重並送到預期 receiver。
- 從 `CephClientRisk` catch-all 排除 `BLUESTORE_SLOW_OP_ALERT`，改由明確的 warning／盤後規則負責。
- 為 `CephNodeMultiOSDStall` 增加 cluster-wide overload 分類或抑制；在此之前維持 warning。

責任分工建議：Ceph／SRE owner 負責 rules、routing 與 runbook；platform／workload owner 負責 client p99 與 SLO；hardware owner 負責 SMART、RAID/HBA inventory 與 event collector。三方都沒有 owner 時，不進 pager。

### 第二步：shadow 至少 14 天

- 載入現成規則，但先不 page。
- 每次觸發保留 workload、recovery、受影響 OSD 與 node 數量。
- 觀察窗至少涵蓋一次 recovery/backfill 或 scrub，以及一次 planned maintenance；14 天內沒遇到就延長到 30 天或安排可回退演練。
- 對照 live evaluator 的 firing 時間與離線 +14／+20 秒重放結果，不能只看 expression。
- 目標是量出正常尖峰、planned maintenance 與真正 incident 的分布，不是趕第二週開 pager。

### 第三步：通過上線驗收才開分級通知

- `CephOSDTransientStall`：warning／事件記錄。
- `CephNodeMultiOSDStall`：先區分單 node 聚集與多 node 過載；只有前者才是 critical 候選。
- `CephDaemonSlowOpsFast` 與 `CephClusterSlowOpsFast`：severe slow-request 事件；是否直接 pager，或只在 client SLO 同時 breach 時 pager，由團隊政策決定。
- `CephOSDLatencyOutlier`：保留為持續 warning。
- client p99 breach：依 workload SLO 決定 pager，不與 storage 內部訊號混成單一門檻。

以下是**建議的上線驗收值，不是既有實驗結果**：

| 驗收項目 | 通過條件 | 未通過時 |
|---|---|---|
| evaluator 時序 | 單 OSD 暫態、同 node 聚集與兩路 severe slow-request 規則各三次受控測試都在預算內 firing | 保持 shadow，查 scrape/evaluation |
| receiver routing | 三次 synthetic／受控 alert 都送達正確 receiver，且錯誤 receiver 為 0 | 回退 route，規則只留 shadow |
| 同 node 聚集歸因 | 已知 cluster-wide 壓力不產生單 node 硬體 page | `CephNodeMultiOSDStall` 維持 warning，補 correlation |
| critical 噪音 | shadow 14 天內，同 node 聚集與 severe slow-request 規則的誤 critical 合計不超過每 cluster 每週 1 次 | 延長至 30 天並調整條件 |
| telemetry absent | 三次 daemon freeze／series absent 都被存活規則看見，exporter `up=1` 不會掩護 | 不開任何「無事件即健康」的自動判斷 |
| runbook | 值班者只看告警與本文，15 分鐘內正確分類 OSD／node／cluster | 修 dashboard／runbook 後重演 |

這裡的「誤 critical」是事後確認既沒有違反既定 paging policy、也沒有需要立即處置的 storage 事件；正常 recovery 造成可解釋的 warning 不算誤 critical。每週 1 次是建議的初始營運門檻，須由 on-call owner 明確接受。

若任一驗收項目未通過，回退方式是移除／停用 notification route，保留 recording、dashboard 與資料；不要為了壓 alert 直接刪除原始 metric。

### 同步工作：補齊歸因資料

- Grafana 同頁放 client p99、單 OSD 暫態、同 node 聚集、commit/apply latency、recovery 與 device busy。
- incident bundle 加入 SMART 與 RAID/HBA event collector；在完成前，runbook 明列手動補收步驟。
- 建立 OSD -> hostname -> block device -> physical SSD／virtual disk 的 inventory。

### 有 baseline 後：在單一 node 試點 `bluestore_log_op_age=2`

2～5 秒門檻比較實驗（E-06）證明，3 秒 stall 在預設 5 秒時 +0，改 2 秒後 +6，而且 runtime 生效。但降低門檻會增加 log 與 warning 噪音：

1. 只選一台 node，逐一指定該 node 的 `osd.N`；不要先改全域 `osd` scope。
2. 先記錄至少一週 5 秒門檻 baseline。
3. 變更前保存每顆 OSD 的 config source/value；改 2 秒後比較事件率、log 量與 workload。
4. 若無法把正常高負載與異常分開，依保存的 source/value 還原，不推全 cluster；還原後確認 warning rate 回 baseline。

### 持續工作：演練與驗收

每季至少演練一次單 OSD 暫態、同 node 多 OSD 聚集與 telemetry absent。驗收不是「alert 有 firing」而已，而是：

- live evaluator 是否讓 `CephOSDTransientStall` 在 30 秒內、`CephNodeMultiOSDStall` 在 35 秒內留下可見訊號。
- >30 秒 severe request 是否在 60 秒左右 firing，並依 routing 政策送到正確 receiver。
- on-call 是否能在 15 分鐘內縮小到 OSD、node 或 cluster。
- critical false positive 是否符合上線驗收的每 cluster 每週門檻。
- sensor 失明是否另有獨立告警。

---

## 12. 給主管的投入建議

| 優先序 | 項目 | 解決的風險 | 現有證據 | 成本判斷 |
|---|---|---|---|---|
| 立即 | 修 routing、catch-all、同 node 過載誤歸因與 telemetry absent 後 shadow | 5～8s 暫態、採樣漏失與錯誤 paging | promtool＋真機 series 重放；尚缺 receiver | 中；rules 已有但整合未完成 |
| 立即 | client p99 dashboard／alert | 確認 disk alert 是否真的影響 workload | 必要交叉訊號；門檻待生產 shadow | 中；需 workload metrics |
| 立即 | OSD-node-device inventory | 告警無法對到實體硬體 | 多 OSD 共用元件判讀需求 | 低至中 |
| 近期 | 同頁呈現 client p99／recovery／device | SSD 與過載誤歸因 | 無故障高負載 9/9 OSD 的反例（E-00） | 中 |
| 近期 | incident bundle 補 SMART／RAID | 只能看到指紋，沒有硬體證據 | PVE SMART 案例＋現有缺口 | 中；依 vendor 工具而定 |
| 近期 | `CephNodeMultiOSDStall` correlation＋分級 routing | 單 node 硬體候選與全 cluster 過載混淆 | 同 node +20s；無故障高負載 9/9 OSD 的反例（E-00） | 中；不是單改 severity |
| 後續評估 | `bluestore_log_op_age=2` 試點 | 2～5s 早期徵兆 | 門檻比較實驗（E-06）+0 -> +6 | 低，但有噪音風險 |
| 後續評估 | 低頻 synthetic IO 評估 | idle OSD 完全無訊號 | idle OSD 暫停實驗（E-03）全靜默 | 中；需評估額外 IO 與誤判 |

最值得先做的是修完 §8.1 的整合 blocker，再把四條快速偵測規則放進 shadow；client p99 與 OSD-node-device inventory 同步進行。直接採購硬體或把所有 `CephOSDTransientStall` 當 pager，都比這個順序更容易造成誤判與疲勞。

---

## 13. 不能誇大的地方

1. **lab 沒有生產使用的真 RAID 卡**：`CephNodeMultiOSDStall` 證明的是同 node 多 OSD 聚集可被偵測，不是 firmware 已在 lab 重現。
2. **PVE 是觀察性案例**：硬體老化、無 PLP、既存 warning 與低寫入能力同時存在，但沒有隔離變因的換碟 A/B，不能宣稱因果已證。
3. **四個 counter 只涵蓋部分 BlueStore 路徑**：log 有 slow operation，不保證四個 counter 一定增加。
4. **counter 要等階段完成**：永久卡死仍要靠 `SLOW_OPS`、down、absent 與 client stall。
5. **idle OSD 沒有 IO 就沒有 latency**：若一定要在 idle 時抓 firmware 暫停，需額外 synthetic IO 或帶外硬體 telemetry。
6. **絕對門檻不可直接移植**：100ms、20ms、2ms 或倍數都受 SSD 類型、replica、scrape interval 與 workload 影響；先 shadow 建 baseline。
7. **合成注入有保真度邊界**：`dmsetup suspend` 會把 IO 擋在特定層，`node_disk_*` 不一定重現真 firmware 在 device 內排隊的形狀。
8. **alert 成功不等於 recovery 證據完美**：latency-outlier 實驗（S11）的正向 firing 與 routing 斷言通過，但 BlueStore 24h latch 讓同一 run 內沒有 `HEALTH_OK`；健康恢復證據來自下一場 run 的 ready gate。

---

## 14. 一句話結論

**更快**：用 Squid BlueStore slow counter 在 5～8 秒事件結束後數十秒內留下痕跡；用 daemon＋mon 雙路讓 severe request expression 約 +45 秒首真。實際 pager 時間要等 routing blocker 修完後重新驗證。

**更準**：不要讓任何單一 metric 定罪 SSD；用「client 是否受影響、哪顆 OSD、是否同 node 聚集、device／recovery 是否同時異常」完成歸因。

**真正要避免的失敗**：disk 只卡 5～8 秒、OSD 沒有 down，事件卻短到既有 30 秒 `SLOW_OPS` 完全看不見；或 disk 永久卡住時，BlueStore counter 因操作尚未完成而沒有增加。前者要靠快速 counter 留痕，後者要靠 severe slow-request、OSD down、telemetry absent 與 client stall 補位。

---

## 15. 證據與實作索引

### 快速 slow-ops 研究

- [完整研究報告](../ceph-slow-ops-detection/REPORT-2026-07-09.md)
- [逐 run evidence summary](../ceph-slow-ops-detection/EVIDENCE-SUMMARY-2026-07-09.md)
- [Hypothesis backlog](../ceph-slow-ops-detection/HYPOTHESES.md)
- [快速 slow-ops 偵測規則](../ceph-slow-ops-detection/rules/ceph-slow-ops-fast.yml)

### Production alert 真機驗證

- [22 場 evidence index](../ceph-alert-real-lab/EVIDENCE-INDEX-2026-07.md)
- [`CephOSDLatencyOutlier` 與既有 coverage rules](../ceph-alert-rules/rules/ceph-production-coverage.yml)
- [現行 Alertmanager route](../ceph-alert-rules/rules/alertmanager-route.yml)
- [`CephClientRisk` catch-all](../ceph-alert-rules/rules/ceph-stability-first.yml)
- [slow-ops scenario](../ceph-alert-real-lab/run/scenario-slow-ops.sh)
- [latency-outlier scenario](../ceph-alert-real-lab/run/scenario-latency-outlier.sh)

### homelab PVE 與 incident bundle

- [PVE preflight／SMART snapshot](../rbd-io-perf/preflight-snapshot-2026-07-07.md)
- [PVE evidence summary](../rbd-io-perf/EVIDENCE-SUMMARY-2026-07-07.md)
- [Incident bundle 使用說明](../ceph-incident-bundle/README.md)
- [Prometheus dump 真機驗證](../ceph-incident-bundle/PROM-VALIDATION-2026-07.md)

### Ceph v19.2.3 原始碼錨點

- `ceph/src/common/options/global.yaml.in`：`osd_op_complaint_time`、`bluestore_log_op_age`、slow-op lifetime／threshold 預設值。
- `ceph/src/os/bluestore/BlueStore.cc`：四個 slow counter、`_add_slow_op_event()`、`BLUESTORE_SLOW_OP_ALERT`。
- `ceph/src/os/bluestore/BlueStore.h`：counter enum。
- `ceph/src/osd/OSD.cc`：`get_health_metrics()` 的 30 秒 slow-op 判定。
- `ceph/src/pybind/mgr/prometheus/module.py`：OSD apply／commit latency 匯出。

### 實作者注意事項

- `increase()[1m]` 的單發增量通常會跨數次 evaluation 保持為正；`for: 0` 是為了不再增加等待確認時間、取得最低 latency，不是因為它必然只真一次。
- 四個 counter 不能以 metric name regex 一次選完後直接 `increase()`：`__name__` 被移除時，同 OSD 可能形成重複 label set。研究版規則使用四個 `increase()` 顯式相加。
- cephadm／podman 的 OSD process 可能在 systemd unit 下的子 cgroup；故障注入必須用實際 throughput／latency 與 cgroup path 證明生效，否則陰性 run 作廢。
- latency-outlier 實驗（S11）的 `HEALTH_OK` 不在同一 run 內：BlueStore latch 使 recovery gate 當時仍是 WARN，下一場 ready gate 才提供健康恢復證據。
