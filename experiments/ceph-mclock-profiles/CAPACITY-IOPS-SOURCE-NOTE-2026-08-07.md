# Ceph mClock capacity IOPS：低估時會發生什麼事

日期：2026-08-07
版本：Ceph v19.2.2（`0eceb0defba60152a8182f7bd87d164b639885b8`）為原 campaign 對照；v19.2.3（`c92aebb279828e9c3c1f5d24613efca272649e62`）做差異檢查。

## 結論先講

`osd_mclock_max_capacity_iops_ssd` 是 **per-OSD、經 ObjectStore/BlueStore 的 4 KiB random-write capacity 模型輸入**，不是 raw NVMe 規格，也不是 cluster client IOPS。若同一層級的 OSD 能力真是 70K、卻宣告成 6–7K，mClock 不會把 client 與 `background_recovery` 的總吞吐硬鎖在 6–7K；built-in profile 對這兩個 class 的 limit 都是無上限。實際效果是每筆小 IO 的 QoS cost floor 被放大約十倍，reservation 換算成 IOPS 後提早用完，接下來可能進入 weight 競爭。

所以對「之前 profile 實驗不出差異」這個問題，source 推導出的方向是：

- **低估 capacity 不等於硬性總吞吐 cap。** source 能證明的直接效果是 small-op cost floor 上升、等效 reservation IOPS 降低；無限 limit 的 class 仍可由 weight 繼續分配。
- **profile gap 對 capacity 並非 source 保證的單調函數。** 高低 capacity 都可能產生 reservation/weight 差異；是否看得到，還取決於兩個 class 是否在同一個 OSD shard 持續 backlog，以及 offered load 是否真的超過當下可服務量。
- 若只有 client workload、沒有同時 backlog 的 `background_recovery`，三個 built-in profile 的 client limit 都是無上限，本來就不該期待穩態吞吐明顯分開。
- generic recovery 不能一律當成 `background_recovery`。低優先度 request 可能被分到 `background_best_effort`；它的 limit 在 `high_client_ops` 是 `0.7C`、`balanced` 是 `0.9C`、`high_recovery_ops` 才是無上限。

## 這個數字怎麼量出來

OSD 啟動時，`OSD::maybe_override_max_osd_capacity_for_qos()` 在 mClock 啟用且沒有設定 `osd_mclock_skip_benchmark` 時判斷是否執行 bench。一般情況只會在目前仍是編譯預設值時執行；`osd_mclock_force_run_benchmark_on_init=true` 可以強制重測。SSD 的結果寫回 `osd_mclock_max_capacity_iops_ssd`。

以下 line anchor 取自 v19.2.3；v19.2.2 的 capacity → cost → profile → dmclock 因果鏈語意相同。兩版之間另有 scheduler constructor 搬移、dmclock 從 gitlink 改為 vendored source，以及 cleaner guard 變更，但沒有改動本研究依賴的 capacity/tag/dequeue 語意。

source 路徑：

1. `src/osd/OSD.cc:10064-10118` 選 SSD/HDD config，固定建立 100 個 4 MiB object，再執行總量 12,288,000 bytes、block size 4 KiB 的 bench。
2. `src/osd/OSD.cc:3400-3542` 顯示 IO 經 `ObjectStore::Transaction`、OSD 的 `meta_ch` 與 `flush_commit()`；計時區段是對既有 object 做 3,000 次隨機 4 KiB overwrite。這不是繞過 Ceph 的 raw-device fio。
3. `src/osd/OSD.cc:10127-10167` 以 `count / elapsed / bsize` 算 IOPS；SSD 結果必須落在 1,000–80,000 的接受範圍，否則保留原值並警告。
4. `src/common/options/osd.yaml.in:1202-1214` 也把它定義成「per OSD 的 4 KiB random write IOPS capacity」。

因此，「SSD raw fio 70K、OSD startup bench 6K」本身不能證明 Ceph 測錯；兩者量的是不同 datapath。

## capacity 如何進入 mClock

`src/osd/scheduler/mClockScheduler.cc:215-248,392-400,441-463` 的核心換算是：

```text
cost_floor = sequential_bandwidth / declared_iops_capacity
capacity_per_shard = sequential_bandwidth / num_osd_shards
qos_cost = max(request_cost, cost_floor)
```

對小 IO，可近似推得某 class 的 aggregate reservation：

```text
reservation_iops ~= reservation_ratio * declared_iops_capacity
```

下表使用本次 QoS gate 讀到的 **mClock model input**：sequential bandwidth 1,200 MiB/s、8 OSD op shards；它不是對 Azure 實體 sequential bandwidth 的獨立量測。再用 6,500 IOPS 示意，而且只適用於 request 原始 cost 小於 `B/C`、因而由 cost floor 主導的情況：

| 項目 | 宣告 6.5K | 宣告 70K |
|---|---:|---:|
| 小 IO 的 cost floor | 約 193,583 B/op | 約 17,975 B/op |
| `high_client_ops` client reservation | 3,900 IOPS | 42,000 IOPS |
| `high_client_ops` recovery reservation | 2,600 IOPS | 28,000 IOPS |
| `high_recovery_ops` client reservation | 1,950 IOPS | 21,000 IOPS |
| `high_recovery_ops` recovery reservation | 4,550 IOPS | 49,000 IOPS |

profile 比例來自 `mClockScheduler.cc:285-338`：

- `high_client_ops`：client `res=.6,wgt=2,lim=max`；recovery `.4,1,max`。
- `balanced`：client `.5,1,max`；recovery `.5,1,max`。
- `high_recovery_ops`：client `.3,1,max`；recovery `.7,2,max`。

`mClockScheduler.cc:441-463` 也顯示 `immediate` 與高於 cutoff 的 request 走 `high_priority` queue，不進 dmclock tag 計算；`src/osd/scheduler/OpSchedulerItem.h:204-211` 則把部分低優先度 recovery 分到 `background_best_effort`。只看 aggregate client IOPS/p99，無法判斷真正經 mClock 的 class、各 class 是否同時有足夠 backlog，或有多少工作走旁路。

## 套回 Azure campaign 的數字

這組 lab 有三種不能直接互換的 capacity reference：

| 量測層級 | 結果 | 能回答的問題 |
|---|---:|---|
| raw NVMe 4K randwrite | 276,735–304,158 IOPS/device | 裸裝置上限，不含 BlueStore |
| OSD startup bench | 6,057–6,646 IOPS/OSD，平均 6,439 | mClock capacity 最接近的同層級輸入 |
| RBD 4K 70/30 cluster ceiling | 63,634 aggregate IOPS | 完整 client datapath 的 cluster 上限 |

把 cluster ceiling 的 30% write、replica 3、8 OSD 粗略回推：

```text
63,634 * 0.30 * 3 / 8 ~= 7,159 writes/s/OSD
```

它與 OSD bench 平均 6,439 只差約 11%，但這只是粗略 consistency check：沒有計入 read cost、primary/replica 工作差異、PG skew、cache、network/client ceiling 與 per-shard backlog，而且 startup bench 走 `meta_ch`，不是一般 RBD PG datapath。因此它只能說明「raw NVMe 280K 不能直接證明 6K 低估十倍」，不能證明 6–7K 就是正確 capacity，也不能單靠這個回推排除 capacity 假說。

既有正式 campaign 也確實在逐顆鎖定 6,057–6,646 後執行：steady 4K 共 36 次，profile mean IOPS 最大差距 0.03%–0.48%，p99 gap 0.011–0.699 ms；fault campaign 的正式判讀仍是 No hit。不過三個 profile 都使用同一組 capacity，這份資料無法識別 capacity 的因果效果。它同時相容於「沒有持續的 per-shard 雙 class 競爭」、「recovery class 與假設不同」或「bottleneck 在 recovery producer/concurrency/network 等 scheduler 外部」等解釋。

## 2026-08-07 live sanity check 的證據邊界

為了故意放大「低估」效果，八顆 OSD 的宣告值暫降為原值十分之一（約 606–665），執行 `osd-down-4k-low + high_client_ops`：

- QoS gate 確認八顆 OSD 都讀到目標 capacity/profile。
- 四台 fio client readiness 與結束狀態都通過。
- osd.3 down/out 的主要 fault window 為 727 秒，期間同時有約 15K client IOPS 與 recovery traffic；但現有 bundle 沒有證明該 recovery traffic 的 scheduler class，也沒有證明每個 shard 的兩個 class 都持續 backlog。
- osd.3 回到 `up/in` 後，runner 的 cleanup gate 把「固定 600 秒 deadline」錯當成「600 秒沒有進度」，錯誤觸發 osd.0 restart。osd.0 隨後恢復，沒有 degraded object，但 return-backfill 被延長。

這次 attempt 只有 `high_client_ops`，沒有配對的 `high_recovery_ops`，而且 cleanup runner 有缺陷。因此它只能證明「10 倍低宣告值可被 OSD 正確套用，且 fault window 內同時觀察到 client 與 recovery traffic」，**不能證明 per-shard backlog、不能用來排名 profile，也不能確認或推翻 capacity 假說**。bundle 保留在原 campaign worktree 的：

`results/capacity-ab-under10x-osd-down-4k-low+high_client_ops/r1/attempts/20260807T032330Z/`

## 下一個真正有裁決力的實驗

先修正 final-clean gate，使 deadline 與 progress-reset 分離，再做配對 A/B：

1. capacity：逐顆 OSD bench 值（約 6.4K）與十分之一值（約 640）。
2. profile：`high_client_ops` 與 `high_recovery_ops`。
3. workload/fault：同一個 `osd-down-4k-low`，固定 fault window、client target 與 recovery producer。
4. 必要 gate：每個 OSD shard 的 client 與 `background_recovery` queue 同時 backlog；同步收 `mclock_recovery_queue_len`、`mclock_best_effort_queue_len` 與 `mclock_immediate_queue_len`，確認實際 class。
5. 主要 endpoint：fault-window client p99 與 recovery complete time，prediction 必須在 run 前凍結。

預測只凍結 source 能支援的方向：640 會讓 small-op `qos_cost` 約為 6.4K 時的十倍、等效 reservation IOPS 約為十分之一；若 client 與 `background_recovery` 在每個 shard 都持續 backlog，兩個 profile 仍應保有 client/recovery ordering，但不預先宣稱 gap 必須比 6.4K 更大。若兩組仍無差異，下一步應轉查 queue class coverage 與 scheduler 外瓶頸，而不是直接拿 raw NVMe IOPS 覆寫 OSD capacity。
