# Ceph `CephClientBlocked` 對 `SLOW_OPS` 的實際告警回響報告

> 報告日期：2026-07-21<br>
> 受測版本：Ceph v19.2.3（Squid）、Prometheus v2.51.0<br>
> 證據來源：`ceph-slow-ops-detection` 真機實驗，以及同一座 lab 的 Prometheus → Alertmanager → pager sink 端到端紀錄

## 結論先講

**會響。** 真機對 OSD backing device 限速並持續施加寫入負載後，Ceph 確實升起 `SLOW_OPS`，目前的 `CephClientBlocked{name="SLOW_OPS"}` 也確實從 pending 進入 firing，最後由 Alertmanager 的 pager receiver 送到測試 sink。

這次端到端實測從「開始限速並啟動負載」算起：

| 階段 | UTC 時刻 | 相對注入開始 | 證據強度 |
|---|---:|---:|---|
| 開始限制 OSD I/O，啟動 `rados bench` | 10:11:43 | 0 秒 | 指令紀錄 |
| Ceph `health detail` 已看到 `SLOW_OPS` | 10:12:34–10:12:35 | +51～52 秒 | 直接觀測 |
| Prometheus 首次把 `CephClientBlocked` 條件判為 true，進入 pending | 10:12:42.762 | +59.8 秒 | `activeAt` 直接觀測 |
| `for: 1m` 滿足，可在下一次 evaluation 進入 firing | 約 10:13:42.762 | 約 +119.8 秒 | 由 `activeAt`、`for: 1m` 與 5 秒 evaluation interval 推導 |
| Prometheus 已觀測為 firing，pager sink 也已收到 | 不晚於 10:13:47 | 不晚於 +124 秒 | 直接觀測 |

因此，這套 lab 設定下可以把答案定為：

- **alert 推定約在 +120 秒轉為 firing；直接證據確認它不晚於 +124 秒已是 firing。**
- **pager 端實際收到：不晚於 124 秒。** sink log 沒有逐筆時間戳，所以不能把送達時間再宣稱得更精確。
- 依 `ceph-slow-ops-detection` 的另一輪持續慢盤實驗，`SLOW_OPS` 在 +45 秒可見；加上 scrape／evaluation 抖動與目前的 `for: 1m`，可將**約 105～120 秒**當成本 lab 的規劃區間。這不是延遲分布，也不能直接外推為所有環境的常態。

但這個結論有一個必要條件：**`SLOW_OPS` 必須持續夠久，讓 `ceph_health_detail{name="SLOW_OPS"} == 1` 連續成立滿 1 分鐘。** 只出現一兩個 scrape 的短脈衝，或每個 op 都在 30 秒內完成的慢化，不保證會觸發目前的 `CephClientBlocked`。

## 1. 這份報告回答什麼

本報告只回答三個問題：

1. 現行 `CephClientBlocked` 在真實 `SLOW_OPS` 升起時，是否真的會 firing？
2. Alertmanager 的 pager routing 是否真的收到，不只是 Prometheus 畫面變紅？
3. 從 client I/O 開始被拖慢，到 alert firing 與 pager 收到，各要多久？

這裡的「`SLOW_OPS` 升起」是指 Ceph op tracker 發現仍在 in-flight、且年齡超過 `osd_op_complaint_time` 的 op。此 lab 使用 Ceph 預設值 30 秒。它和 BlueStore 的 5 秒 slow counter、`BLUESTORE_SLOW_OP_ALERT` 是不同訊號，不能混為同一個觸發時刻。

本報告用到的術語：

- **backing device**：OSD 實際承載資料的底層 block device。
- **pager sink**：lab 內的測試 webhook；它只記錄 Alertmanager 的 pager receiver 收到什麼，不是真的電話或簡訊服務。
- **duty cycle**：反覆 suspend／resume device，模擬持續但間歇恢復的慢盤。
- **兩路 `SLOW_OPS`**：cluster 級 `ceph_health_detail` 與 per-daemon `ceph_daemon_health_metrics`。
- **query replay**：用已儲存的 Prometheus 時序資料事後重算 expression；能量出「何時可判真」，但不等於當時真的載入 alert rule 並送出通知。
- **`keep_firing_for`**：expression 回到 false 後，仍讓 alert 保持 firing 一段指定時間，避免短脈衝來不及被值班人員看見。

## 2. 目前被測的 alert

Repo 目前的規則是：

```yaml
- alert: CephClientBlocked
  expr: ceph_health_detail{name=~"PG_AVAILABILITY|SLOW_OPS|OSD_FULL|POOL_FULL"} == 1
  for: 1m
  labels:
    severity: critical
    source: ceph_stability
```

`SLOW_OPS` 不是一出現就 firing。Prometheus 第一次看到 expression 為 true 時先進入 pending；同一組 label 必須連續維持 1 分鐘，才進入 firing。任何一次 evaluation 回到 false，都會重算這 1 分鐘。

端到端 lab 的 Prometheus 設定為：

- `scrape_interval: 5s`
- `evaluation_interval: 5s`
- Alertmanager `group_wait: 0s`
- `severity="critical"` 且 `source="ceph_stability"` 路由到 pager receiver

所以這次量到的主要延遲不是 Alertmanager 刻意等待，而是：

1. Ceph 要先等 op 年齡超過 30 秒；
2. health 狀態要傳到 exporter，再被 Prometheus scrape／evaluate；
3. `CephClientBlocked` 還要再連續 pending 1 分鐘。

## 3. 實驗規劃與結果總覽

| 編號 | 注入或觀察條件 | 事前要驗證的事情 | 結果 |
|---|---|---|---|
| A | 對 `osd.6` backing device 設 cgroup v2 `io.max=262144 B/s`，同時以 16 threads、4 MiB object 跑 `rados bench` | 真實 `SLOW_OPS` 是否讓目前規則 firing，並送到 pager | ✅ firing，pager sink 收到；端到端不晚於 +124 秒 |
| B | 對 `osd.0` 做名目 142.8 秒、實測窗口 153 秒的 `dmsetup suspend 8s / resume 0.4s` duty cycle，32 threads 持續寫入 | 持續 client-blocking 慢盤多久才讓 `SLOW_OPS` 首次可見 | ✅ cluster 與 daemon 兩路首次非零皆在 +45 秒 |
| C1 | 對單 OSD suspend 8 秒，512 KiB、4 threads 寫入 | 本次 8 秒 device pause 是否會產生 `SLOW_OPS` | ❌ 本次注入兩路 `SLOW_OPS` 全程為 0 |
| C2 | 無故障注入，16 threads、4 MiB 高壓寫入；意外觀測到 max latency 44.7 秒 | 無事前 prediction；用來檢查短命 `SLOW_OPS` 的採樣邊界 | ⚠️ cluster 路徑只有 2 個非零樣本；daemon 路徑漏採 |
| D | 對 `osd.0` 的 `/dev/dm-3` 設 `io.max wiops=8` 共 150 秒；512 KiB、8 threads 寫入 | 持續節流是否必然升起 `SLOW_OPS` | ❌ 完成 op 的 max latency 15.403 秒、兩路 `SLOW_OPS` 全程為 0 |

帳目：A、B、C1、D 是 4 個已執行的受控實驗；C2 是 E-00 未完成 run 中的意外觀測，不冒充事前規劃的實驗。沒有已規劃但未執行的項目。

## 4. 實驗 A：`CephClientBlocked` 確實 firing，pager 確實收到

- **調整的參數**：對 `192.168.18.174` 上 `osd.6` 的 `/dev/sdb` 套用 cgroup v2 `io.max`，讀寫頻寬皆限為 262,144 B/s；同時啟動上限 180 秒的 `rados bench` 寫入，16 threads、每個 object 4 MiB。驗證在 +124 秒完成後停止 workload，實際沒有跑滿 180 秒。
- **為什麼測**：單看 PromQL 或 promtool 只能證明規則邏輯；本實驗要證明真 Ceph health、真 Prometheus rule state、真 Alertmanager routing 三段都有接通。
- **預期**：持續限速會讓 in-flight op 超過 30 秒，升起 `SLOW_OPS`；該 health detail 連續維持 1 分鐘後，`CephClientBlocked{name="SLOW_OPS"}` 進入 firing，並送往 pager。
- **結果**：預期成立。Ceph health、Prometheus firing state 與 pager sink 三層都有獨立證據。
- **建議**：可以把目前規則視為「持續 client blocking 的最後一道 critical page」，但值班手冊應寫明「本 lab 推定約 2 分鐘轉 firing；直接確認不晚於 124 秒」，而不是「1 分鐘內」。

### 4.1 精確時間線

注入起點採 `throttle.txt` 與 `rados-bench.txt` 共同記錄的 `2026-07-04T10:11:43Z`，不用 result 目錄建立時間代替。

1. **+0 秒：開始注入。** `io.max` 寫入成功，`rados bench` 同秒開始。
2. **+32.4 秒：第一筆寫入才完成。** Bench 顯示首筆完成 latency 32.4026 秒，證明 workload 中至少有一筆完成 op 存活超過 30 秒；是否已形成 Ceph health warning 要看下一步的 health 證據，不能只由 bench latency 判定。
3. **+51～52 秒：Ceph health 已升起。** `health detail` 顯示 `SLOW_OPS`，最老 op 已卡 37 秒；同時有 `BLUESTORE_SLOW_OP_ALERT`，但本報告不拿後者冒充 `CephClientBlocked` 的觸發來源。
4. **+59.8 秒：Prometheus 進入 pending。** Alert API 的 `activeAt` 是 `2026-07-04T10:12:42.762155964Z`，label 明確是 `alertname="CephClientBlocked"`、`name="SLOW_OPS"`。
5. **約 +119.8 秒：滿足 `for: 1m`。** 這是 `activeAt + 60s`。由於 evaluation interval 為 5 秒，alert 會在該邊界或緊接的 evaluation 轉為 firing。
6. **不晚於 +124 秒：端到端成功。** 10:13:47 的證據擷取已看到 Prometheus `state="firing"`；同次擷取的 `sink-since-checkpoint.log` 也有 pager receiver 收到同一組 `CephClientBlocked{name="SLOW_OPS"}`。

### 4.2 這個結果能證明到哪裡

能直接證明：

- 真 Ceph `SLOW_OPS` 可以驅動目前的 `CephClientBlocked`。
- `severity="critical"`、`source="ceph_stability"` 的路由確實到 pager。
- 在本次持續、重度慢盤下，從注入到 pager 可見不超過 124 秒。

不能直接證明：

- 每一種 `SLOW_OPS` 都會 page；訊號若抖回 0，`for: 1m` 會重算。
- 所有環境都會是 124 秒；不同 scrape／evaluation interval、mgr cache、Alertmanager `group_wait` 與通知媒介會改變後半段延遲。
- 任意 5～8 秒 BlueStore 卡頓都不會觸發；實驗 C1 只證明本次 8 秒注入在當時負載與 queue 深度下沒有觸發。若解除 pause 後 queue 仍壅塞，個別 op 仍可能繼續老化並跨過 30 秒。

## 5. 實驗 B：本 lab 為什麼量到約 2 分鐘

- **調整的參數**：在 pool `slowops-bench` 執行 300 秒 `rados bench write`，object size 512 KiB、32 threads；負載開始 30 秒後，對 `192.168.18.169` 的 `osd.0` backing device 進行 `suspend 8s / resume 0.4s` 共 17 次。名目 duty cycle 是 142.8 秒，遠端時間戳量到的注入窗口是 153 秒。Prometheus scrape interval 10 秒；注入後的 cluster／daemon `SLOW_OPS` query 從 `t_inj` 觀察到 300 秒 bench 排空、cleanup 與再沉降 90 秒之後，query step 為 5 秒。
- **為什麼測**：把「Ceph 本身多久才產生 `SLOW_OPS`」和 alert rule 的 `for: 1m` 分開量，才能解釋端到端時間，而不是只報一個黑盒數字。
- **預期**：`SLOW_OPS` 在注入後 35～120 秒間首次非零；較快的 BlueStore counter 規則會先看到。
- **結果**：cluster 級 `ceph_health_detail{name="SLOW_OPS"}` 與 daemon 級 metric 都在 `t_inj + 45s` 首次非零。受害 device 是 `osd.0`，但非零 daemon label 出現在其他 primary OSD，另證明 `SLOW_OPS` label 指的是被拖累的 primary，不一定是元兇 device。
- **建議**：時間估算要拆成「本輪 +45 秒讓 `SLOW_OPS` 可見，另留 scrape／evaluation 餘裕」再加「1 分鐘 `for:`」。因此約 105～120 秒可作為本 lab 的容量規劃區間，而不是只看 YAML 裡的 `for: 1m` 就宣稱 60 秒；它不是跨環境的延遲保證。

本輪 Prometheus scrape interval 是 10 秒，mgr Prometheus module 自身另有 15 秒 cache；query replay 量到訊號在 +45 秒已可判真。這和實驗 A 在 +59.8 秒進入 pending、推定約 +120 秒轉 firing，且不晚於 +124 秒直接確認的結果方向一致，但兩者不是同一筆量測。

## 6. 實驗 C、D：已確認的漏接邊界

### 6.1 C1：本次 8 秒暫態卡頓沒有響

- **調整的參數**：對 `osd.0` 的 device suspend 8 秒，使用 512 KiB object、4 threads 持續寫入；Prometheus scrape interval 10 秒。
- **為什麼測**：這是原始 SSD firmware 事件的形態。
- **預期**：這次校準負載下，8 秒 pause 不會讓任何 in-flight op 活到 30 秒，兩路 `SLOW_OPS` 都應維持 0。
- **結果**：預期成立。兩路全程 0；本次 `CephClientBlocked` 沒有進入 pending。BlueStore slow counter 增加 6，證明 device pause 確實影響了 I/O，不是注入未生效。
- **建議**：用 `CephOSDTransientStall` 的 BlueStore slow counter 路徑補足這種短暫事件。本次真機量到 expression 在卡頓開始 +14 秒可判真，實際 firing 再加一個 rule evaluation interval。這是單次負載形狀的結果；更深 queue 可能在 8 秒 pause 結束後仍讓 op 老化超過 30 秒，不能外推成「所有 5～8 秒事件必不觸發」。

### 6.2 D：持續節流 150 秒仍沒有響

- **調整的參數**：對 `192.168.18.169` 的 `osd.0`／`/dev/dm-3`（major:minor `252:3`）設定 cgroup v2 `io.max wiops=8` 共 150 秒；總負載為 300 秒、512 KiB object、8 threads 寫入，節流從負載 +30 秒開始；Prometheus scrape interval 10 秒。
- **為什麼測**：確認「長時間效能劣化」是否等同於「有單一 op 超過 30 秒」。
- **預期**：原先預期持續節流會升起 `SLOW_OPS`。
- **結果**：**預期被推翻。** 150 秒節流期間，bench 已完成 op 的 cumulative max latency 為 15.403 秒，Prometheus `op_w` 平均 latency 峰值為 15.158 秒，而兩路 `SLOW_OPS` 全程為 0，因此 `CephClientBlocked` 無從觸發。這些數字證明「完成 op 的最大值未越過 30 秒」與「當時未觀測到 `SLOW_OPS`」；不拿平均值單獨證明所有 in-flight op 的年齡。
- **建議**：不能用 `CephClientBlocked{SLOW_OPS}` 當所有持續 latency 劣化的涵蓋證明；必須保留 BlueStore slow counter 或 latency 類規則。

### 6.3 C2：`SLOW_OPS` 只短暫被 scrape 到，不足以證明會響

這不是事前規劃的實驗，而是第一輪 E-00 在 harness 因 `pgrep` 自匹配而中止前留下的意外觀測。條件為無故障注入、16 threads、4 MiB object 的高壓寫入，原定寫入 90 秒；lab Prometheus scrape interval 10 秒。該 run 記錄到完成 op max latency 44.7 秒，cluster health metric 只有 2 個非零樣本，daemon metric 整段漏採。因 harness 中止，實際有效負載時長與完整觀測窗沒有保留下來，原始 bundle 也不完整；本報告只把它當採樣邊界，不拿來估計發生率或當成可重現的主要實驗。

當時沒有載入目前 rule 做端到端通知；query replay 顯示非零樣本無法讓 expression 連續成立滿 1 分鐘。因此能下的結論是「這組樣本不滿足目前 `for: 1m`」，不是「實際 alert 曾 firing 或未 firing」。

所以「Ceph health 曾出現 `SLOW_OPS`」和「`CephClientBlocked` 一定會 page」不是同一句話。正確條件是：**Prometheus 必須持續觀測到同一組 `SLOW_OPS` label 為 1，連續滿 1 分鐘。**

## 7. 時間預算與建議總表

| 項目 | 建議或預期值 | 量到的效果 | 依據 | 可調性 |
|---|---|---|---|---|
| 現行 `CephClientBlocked{SLOW_OPS}` firing 時間 | 本 lab 的持續重度事件以約 2 分鐘規劃 | +59.8 秒 pending；推定約 +119.8 秒轉 firing；直接確認不晚於 +124 秒 | 實驗 A、B | `for:` 可 runtime reload 規則；Ceph complaint 門檻可 runtime 調整，但不建議只為縮短 pager 時間直接下修 |
| Pager 送達時間 | 本次不晚於 +124 秒；生產另加實際 `group_wait`、網路與通知媒介延遲 | 推定 firing 後不超過約 4.2 秒已在 sink 可見；sink 無逐筆時間戳，故只是上界 | 實驗 A | Alertmanager routing/runtime reload |
| `for: 1m` | 保留可防單次 scrape 抖動，但要接受短脈衝漏接 | expression 要連續為 true 60 秒；C2 只有 2 個非零樣本，不足以滿足 | 實驗 A、C2 | Prometheus rule reload |
| `osd_op_complaint_time` | 維持預設 30 秒，除非另做誤報率與 cluster 成本驗證 | C1 的 8 秒注入兩路為 0；B 的持續深 queue 在 +45 秒可見 | 實驗 B、C1 | Ceph runtime config |
| 需要 60 秒內 page | 現行規則不符合；fast rules 只能作為待驗收方案，設定見下節 | 本 lab 的 query replay 顯示 +45 秒可判真，尚無 fast rules 的 pager 送達時間 | 實驗 B | Prometheus／Alertmanager runtime reload |
| 需要涵蓋短暫 firmware 卡頓 | 使用 BlueStore slow counter 路徑；同 node 多顆 OSD 同窗發生時再升級 | C1 的 slow counter +6、expression 在 +14 秒可判真；同輪兩路 `SLOW_OPS` 仍為 0 | 實驗 C1 與 `ceph-slow-ops-detection` E-02 | Prometheus rule reload；Squid v19.2.0+ 才有必要的 slow counters |

### 7.1 Fast rules 若要拿來 page，還缺哪些部署條件

Repo 內的 fast rules 已通過 promtool 與真機 query replay，但**目前沒有端到端 pager 時間證據**。其中與「client 已卡超過 30 秒」直接相關的兩條是：

| Rule | Expression | `for`／保持時間 | Severity | 本 lab 證據 |
|---|---|---|---|---|
| `CephDaemonSlowOpsFast` | `max_over_time(ceph_daemon_health_metrics{type="SLOW_OPS"}[1m]) > 0` | 無 `for`；`keep_firing_for: 10m` | critical | daemon 路徑在 B 的 +45 秒可判真，但 C2 曾整段漏採 |
| `CephClusterSlowOpsFast` | `max_over_time(ceph_health_detail{name="SLOW_OPS"}[1m]) > 0` | 無 `for`；`keep_firing_for: 10m` | critical | cluster 路徑在 B 的 +45 秒可判真，作為 daemon 漏採時的備援 |

不能直接把檔案套上就宣稱 60 秒內 page，原因有兩個：

1. Fast rules 的 `source="ceph_slow_ops_fast"` 不在目前 pager route 的 `source=~"ceph_stability|ceph_scoped|ceph_coverage"` matcher 內；必須先新增明確 route，否則 critical label 也不保證進 pager。
2. Alertmanager 現在以 `alertname` 分組；`CephDaemonSlowOpsFast`、`CephClusterSlowOpsFast` 與約 1 分鐘後的 `CephClientBlocked{name="SLOW_OPS"}` 是三個不同 alertname。若三條都直接加到 pager route，單一事件預期會產生 **3 組 pager 通知**，不會自然去重。建議的驗收目標是每個事件 **1 組首次 pager 通知**：只讓 `CephClusterSlowOpsFast` 進 pager、`CephDaemonSlowOpsFast` 留作 Slack／定位訊號，並在 cluster fast alert 活躍時 inhibit 後續的 `CephClientBlocked{name="SLOW_OPS"}`。若團隊要保留第二次確認通知，也必須明寫預期是 2 組，不能把它當成意外噪音。

若要核准上線，驗收條件應是：

- 在隔離 lab 重跑持續慢盤，直接看到 fast alert firing、pager sink 收到，並量到注入後不超過 60 秒；不能只用 query replay。
- 驗證 `CephDaemonSlowOpsFast` 與 `CephClusterSlowOpsFast` 同時成立時，依上面的建議設計只產生 1 組 pager 通知；`CephDaemonSlowOpsFast` 只到 Slack，後續 `CephClientBlocked{name="SLOW_OPS"}` 被 inhibition 壓住，不產生第二組 page。
- 驗證 rule 與 Alertmanager reload 成功、Watchdog 仍持續送達、基線沒有新增 firing alert。
- 回退方式是移除 fast rule group 與它的專屬 route／inhibition 後 reload；回退後再次確認 Watchdog 與原 `CephClientBlocked` 路徑正常。

## 8. 最終判定

### `CephClientBlocked` 在 `SLOW_OPS` 觸發時真的會響嗎？

**會，但要把「觸發」定義為 Prometheus 連續看見 `SLOW_OPS=1` 滿 1 分鐘。** 真機端到端證據已同時看到 Ceph health、Prometheus firing、Alertmanager pager sink 三段成功。

### 需要多久？

**這次由 `activeAt + for: 1m` 推定約 120 秒轉為 firing；直接觀測確認 Prometheus 與 pager sink 都不晚於 124 秒成功。** 在相同 lab 設定與持續重度慢盤下，可用約 2 分鐘規劃；其他環境要重測。其組成約為：

```text
op 開始被卡
  → 約 30 秒：跨過 Ceph complaint 門檻
  → 約 45～60 秒：SLOW_OPS 被 Prometheus 看見、alert 進 pending
  → 再 60 秒：for: 1m 滿足，alert firing
  → 再加 Alertmanager 與通知媒介延遲
```

### 下一步

1. 值班手冊把目前 `CephClientBlocked{SLOW_OPS}` 的 lab 基準寫成「持續事件推定約 2 分鐘轉 firing；直接確認不晚於 124 秒」，不要寫成「1 分鐘內」。
2. 若要求 60 秒內得知 client 已卡住，依 §7.1 讓 fast rules 通過 routing、去重、端到端時間與回退驗收後再部署；目前只有 +45 秒可判真的 query replay 證據。
3. 若要求穩定涵蓋 5～8 秒 firmware 暫停，不能只依賴目前的 `CephClientBlocked`；應以 BlueStore slow counter 路徑補足，並以目標負載與 queue 深度重跑驗收。
4. 生產上線前，以生產的 scrape、evaluation、Alertmanager `group_wait` 與實際通知管道再跑一次端到端計時，並讓 sink／receiver 自帶時間戳，才能得到精確送達時間。

## 9. 證據索引與侷限

### 直接證據

- 現行規則：`experiments/ceph-alert-rules/rules/ceph-stability-first.yml`
- 注入開始：`experiments/ceph-alert-real-lab/results/slow-ops-20260704T101128Z.jVmRwg/throttle.txt`
- 寫入負載與 latency：同一 bundle 的 `rados-bench.txt`
- Ceph health：同一 bundle 的 `health-check-SLOW_OPS.txt`
- Prometheus firing 與 `activeAt`：同一 bundle 的 `prometheus-alerts-CephClientBlocked-name.json`
- Pager sink：同一 bundle 的 `sink-since-checkpoint.log`
- 已 commit 的端到端證據摘要：`experiments/ceph-alert-real-lab/EVIDENCE-SUMMARY-2026-07-04.md`
- `SLOW_OPS` +45 秒與負向邊界：`experiments/ceph-slow-ops-detection/EVIDENCE-SUMMARY-2026-07-09.md`、`REPORT-2026-07-09.md`

### 侷限

- 端到端成功案例只有這一個可精確還原的成功 run，足以證明鏈路可用，不足以宣稱延遲分布或 p95／p99。
- Pager sink 記錄沒有事件時間戳；本報告只能證明「不晚於擷取時間收到」。
- 端到端 run 使用 5 秒 scrape／evaluation；`ceph-slow-ops-detection` E-04 使用 10 秒 scrape 並以 query replay 分析。兩者用途不同，本報告沒有把它們混成同一筆量測。
- `SLOW_OPS` 是快照型訊號，會因 op 完成而下降；同樣強度的負載仍可能因 queue 形態不同而抖動，導致 `for: 1m` 重算。
- 實驗在隔離 lab 執行，不代表生產的 Alertmanager grouping、網路與外部 pager 服務也只增加 4 秒。
