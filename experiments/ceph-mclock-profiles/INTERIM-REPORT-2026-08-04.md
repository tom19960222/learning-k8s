# Ceph mClock profiles 中期實驗報告

> 快照時間：2026-08-04 08:36:04 +08:00
>
> 報告性質：campaign 進行中的中期判讀，不是 final report，也不是生產變更核准書。
>
> System under test：Ceph v19.2.2；不要與 repository submodule 的 v19.2.3 混用。

## 兩分鐘摘要

本輪研究比較 `balanced`、`high_client_ops`、`high_recovery_ops` 三個 mClock profile。
目前最穩健的結論，是在本 Ceph v19.2.2、Azure single-NIC、固定 capacity 環境的 steady 狀態下，沒有觀察到三個 profile 對 4K 或 sequential workload 造成超過事前實務門檻與實測 noise 的差異。
steady 4K 的 36/36 個規劃 executions 均已完成，依壓力層彙整後的 IOPS profile 最大差距只有 0.03%–0.48%。
同一批 steady 4K 的 profile mean p99 gap 只有 0.011–0.699 ms。
steady sequential 有 35/36 個規劃 executions 可用，依壓力層彙整後的 throughput 差距為 0.30%–1.58%。
steady sequential 的 profile mean p99 gap 為 0.841–2.447 ms，而單一 cell 的 replicate 全距可到 8.913 ms。
因此，steady 資料沒有支持任何 profile 的穩健排名；這是 operationally indistinguishable，不是正式統計 equivalence proof。
排除一筆明確離群資料後，usable finalized datasets 為 136。
在 16 個完整可比較 group（8 個 steady controls、8 個 fault groups）中，只有 4 個 pair comparisons 跨過事前 margin，而且全落在 2 個 fault groups。
這 4 個比較全部只有 n=2，而且 replicate 範圍重疊。
它們只能標為 provisional、underpowered，不能升格成 profile 勝負。
沒有任何 TTR pair comparison 跨過事前 margin。
目前已 finalized 且納入分析的 fault attempts，其 aggregate stall 約為 20–28 秒，對營運仍然重要；chaos 與未完成 replicates 不在這個分母內。
這個 stall 訊號支持 timeout 與告警容量規劃，卻還不能支持 profile 排名。
目前在本實驗涵蓋的 workload 與拓撲內，一般情境應維持 `balanced` 作為預設。
不要依中期 fault 資料做全域 profile 切換。
若精確重現 OSD down、4K extreme，且研究目標是 post-clean throughput，`high_client_ops` 可列為後續驗證假說，不是 production 切換候選。
這個假說仍須等待 r3、final audit、dataset seal 與事前註冊的 follow-up。
27 個 pending 中包含 `chaos` 與 21 個追加 replicates；另有 4 個 needs-human，均尚未收斂。
handoff 粗估約 179.9 小時、US$1,439；模型是自 `.campaign-start` 起的 wall-clock × 全 fleet 固定 US$8/小時，這不是 Azure 實際帳單。

## 判讀標籤

- **Supported**：資料足以支持目前範圍內的敘述，但仍受外部效度限制。
- **Provisional**：已有方向性訊號，replicate 或 validity 證據仍不足。
- **Underpowered**：觀察到的差距無法與 run-to-run noise 清楚分離。
- **Descriptive only**：只描述資料，不是 preregistered primary endpoint 的推論。
- **Open**：尚未完成、尚待人工裁定，或需要 final audit 才能回答。
- **Censored**：量測窗結束時事件仍未完成，不能把上限當成真正完成時間。

## 術語 primer

| 術語 | 本報告中的意思 |
|---|---|
| B | `balanced` profile |
| C | `high_client_ops` profile |
| R | `high_recovery_ops` profile |
| cell | 一組固定 shape、pressure、scenario 與 profile 的實驗條件 |
| group | 同一 scenario、shape、pressure 下三個 profile 的可比較集合 |
| replicate | 相同 cell 的一次獨立 execution |
| steady | 沒有主動 fault injection 的量測 |
| fault | 有明確 fault injection 與 recovery 觀察窗的量測 |
| p99 latency | 同一次 execution 的 fault window p99 latency，以 ms 呈現；profile 比較只在同 shape、同 pressure、同 scenario 的 group 內進行 |
| stall | client I/O 沒有前進的連續時間 |
| TTR | time to recovery；依本 campaign 的 recovery completion 定義計算 |
| finalized | verdict 已完成且進入目前分析帳的 dataset |
| usable | finalized 扣除明確離群排除後，能進入主要判讀的 dataset |
| needs-human | 自動化無法安全裁定，必須人工查看 evidence |
| pending | 已排程但尚未完成或尚未 finalized |
| decision-open | optional scenario 尚未裁定是否排入；不是 execution 的 pending，也不是 descoped |
| post-clean | 事件清理完成後的 final-clean 複測，不是 injection 前 baseline |
| merged measurement | 在同一次 execution 內取得的額外觀測，不另計 execution |
| operationally indistinguishable | 差距低於本 campaign 事前實務門檻，且未大於實測 run-to-run noise；不代表已做 confidence interval 或正式 equivalence test |
| res / wgt / lim | mClock class 的 reservation（保底）、weight（超額分配權重）與 limit（上限） |
| OSD / PG | OSD 是儲存 daemon；PG 是 Ceph 用來映射與追蹤物件副本狀態的 placement group |
| CRUSH rack | 本實驗用 CRUSH hierarchy 模擬的 fault domain；不等同實體機櫃或 Azure availability zone |
| shape | workload 形態；本報告主要是 4K randrw 70/30 與 1 MiB sequential write |
| binding | 某個 reservation／limit 真的成為 throughput 上限；不 binding 表示瓶頸在別處 |
| large-I/O cost model | mClock 依 I/O 大小換算排程成本的模型；1 MiB I/O 的名義成本遠高於 4K I/O |
| r3 | 同一 cell 的第三個 replicate，不是第三種 profile |
| effective gate | 切換 profile 後逐一確認 8 個 OSD 的實際 effective config，不能只看 central config 已寫入 |
| dataset seal | audit 通過後把納入範圍、hash 與 exclusion 固定，之後不得靜默修改資料集 |
| fake-taint | harness 寫下疑似污染 annotation，但回看 fault timing 與 verdict 後確認不代表 finalized dataset 無效 |
| D-state | Linux 不可中斷睡眠，常見於 kernel I/O 等待；本報告的 client hang 指 fio/krbd 卡在此狀態 |
| `fault_t0` / down epoch | `fault_t0` 是 harness 開始注入的時間；down epoch 是 Ceph OSDMap 真正觀察到 OSD down 的版本點 |
| H-033 | 本 campaign 的 incident id：flapping 後 PG 卡在 recovering 並造成 client D-state/hang；不是 rack sampler heartbeat 事件 |

## 一、研究問題與決策邊界

本研究要回答的第一個問題，是 profile 是否改變 steady client performance。
第二個問題，是 profile 是否改變 fault 期間的 p99、stall、recovery throughput 或 TTR。
第三個問題，是任何差距能否大於事前 margin，且大於 replicate noise。
第四個問題，是觀察到的訊號是否足以改變一般預設 profile。
本報告不回答所有 Ceph cluster、硬體或網路拓撲下的通用最佳 profile。
本報告不把 post-clean throughput 當成 preregistered primary endpoint。
本報告不把 n=1 或 n=2 的平均值順序直接解讀為排名。
本報告不把 fault severity 本身誤寫成 profile effect。
本報告不把尚待裁定的 scenario 誤寫成 descoped。

## 二、premises 與 System under test

### 2.1 軟體與雲端環境

- 實際 System under test 是 Ceph v19.2.2。
- repository submodule 的 Ceph v19.2.3 不是本輪量測版本。
- 環境位於 Azure `japanwest`。
- 總規模為 15 台 VM、88 vCPU。
- OSD layer 有 8 台 `L8s_v3` node。
- 每台 OSD node 為 8 vCPU、64 GiB RAM、1.92 TB local NVMe。
- 每台 OSD node 只配置 1 個 OSD。
- control plane 包含 3 個 mon 與 2 個 mgr。
- client 端使用 4 台 fio client。
- 所有 node 使用單一 NIC，且位於同一 subnet。
- 因此 synthetic rack 結果不能直接外推成實體多 AZ 網路故障結果。

### 2.2 CRUSH 與資料配置

- 8 個 OSD 被配置成 4 個 synthetic racks，每個 rack 2 個 OSD。
- pool replica size 為 3。
- `min_size` 為 2。
- PG 數固定為 128。
- autoscaler 關閉。
- 固定 PG 與 autoscaler 狀態可降低 campaign 期間的配置漂移。
- 這些設定也是本報告外部效度的硬邊界。

### 2.3 OSD capacity 與 benchmark 前提

- 8 個 OSD 的 capacity 範圍為 6,057–6,646 IOPS。
- OSD capacity 的 CoV 為 3.188%。
- `skip_benchmark=true`。
- 不應把 capacity 改回舊的 21,500 IOPS。
- 21,500 與本環境量得的 6,057–6,646 不一致。
- 保持 `skip_benchmark=true` 是 campaign 可比較性的前提之一。

### 2.4 workload calibration

- 4K calibration ceiling 為 63,634 IOPS。
- 4K low target 為 15,908 IOPS。
- 4K mid target 為 31,817 IOPS。
- 4K high target 為 50,907 IOPS。
- fault 結果中的 `extreme` 代表本 campaign 的最高 4K pressure 層。
- sequential calibration ceiling 在 manifest/harness 以四台合計 `rate_iops=2374` 表示；因每筆 I/O 是 1 MiB，payload 數值約等於 2,374 MiB/s。
- sequential low target 為 aggregate `rate_iops=594`，payload 約 594 MiB/s。
- sequential mid target 為 aggregate `rate_iops=1187`，payload 約 1,187 MiB/s。
- sequential high target 為 aggregate `rate_iops=1899`，payload 約 1,899 MiB/s。
- 這些 target 是本環境的校準點，不是其他 cluster 的建議常數。

### 2.5 fio workload 與時間窗

| shape | fio 定義 | 並行度 | rate 語意 |
|---|---|---|---|
| 4K | `rw=randrw`、`bs=4k`、70% read / 30% write | 每台 `numjobs=4`、每 job `iodepth=16`；4 台共 16 jobs | manifest rate 是 4 台合計值，再按 jobs 與 70/30 拆分 |
| sequential | `rw=write`、`bs=1M`，沒有 read mix | 每台 `numjobs=2`、每 job `iodepth=8`；4 台共 8 jobs | manifest rate 是 4 台合計 IOPS，再除以 8 jobs；因每筆 I/O 為 1 MiB，payload 數值約等於 MiB/s |

四台 fio client 各使用獨立 300 GiB RBD image，`randseed=4242`。`rate=0` 代表不限速的 closed-loop extreme。steady 與 fault/chaos 都以 300 秒 fio segment、30 秒 ramp 執行；fault/chaos 若需更久會 back-to-back 跑相同 segment，每個新 segment 都重新 ramp 30 秒，STOP 只在完整 segment 邊界生效。

注入前先等 60 秒穩定窗：四台裝置層 IOPS 每秒都要有資料、aggregate IOPS > 0、CoV ≤ 0.10，最長等 900 秒。這個 readiness gate 不是 primary p99 evidence；正式 pre-window p99 來自同一次 fio histogram 的注入前 60 秒。回退並達 `final_clean` 後另跑 60 秒、10 秒 ramp 的 post-clean baseline，寫入 `fio-baseline/`；它不進 fault-window p99 比較。

### 2.6 fault knobs、持有時間與 heal

| scenario | 注入方式 | fault 持有與 cap | heal 語意 |
|---|---|---|---|
| flapping | 同一 OSD 做 10 輪 stop → 等 down → start → 等 up → 等相關 PG active；沒有固定秒數 cadence，由 state gate 推進 | 全程 `noout`；down grace 60 秒，必要時顯式標 down再等 60 秒；up/PG gate 各最多 300 秒；base cap 2700 秒，部分 rescue 5400 秒 | 每輪已 start，結束應為 up+in，pipeline 無額外 manual in |
| OSD down | `ceph orch daemon stop`，最多等 down 120 秒，再立即 manual out | target 保持 down+out，直到 recovery completion 或 2700 秒 cap | 量測後才 start、最多等 up 300 秒，再 manual in |
| node isolation | 單一 OSD node 安裝自動 flush guard，再以 `MCLOCK-ISO` iptables chain 保留 bastion SSH、丟棄 cluster subnet 流量；驗 endpoint 不通、SSH 可通、OSD 最多 180 秒內 down | down 後立即 manual out，保持到 recovery completion 或 2700 秒 cap | 停 guard、flush chain、30 秒內 endpoint reopen、300 秒內 OSD up，再 manual in |
| rack isolation | 同一 synthetic rack 兩台 node 都先 guard/prepare，兩邊 barrier 成功才 commit；兩台 prepare skew 必須 ≤5 秒，超過即 taint；不得降級為單 node fault | 兩顆 OSD 都 down 後同一次 manual out；保持到 completion 或 2700 秒 cap | 兩台 flush、都 up 後同一次 manual in |
| sequential contention | fault 機制與 OSD down 相同，但 workload 是 1 MiB sequential write，只測 mid/extreme | down 後立即 out；現行 cap 3150 秒 | 與 OSD down 相同，start + in |
| chaos | fixed seed 4242，1800 秒；事件是 `osd-stop` 或 `node-isolate`，間隔 20–90 秒、hold 30–180 秒、換 rack 至少空 60 秒、尾端保留 60 秒；最多同 rack 2 個並行 fault，禁止跨 rack | 不 manual out；guard 2400 秒 | 每個事件有配對 start/heal，結束 `inject_rollback_all` |

已完成 execution 的 cap 以該 attempt bundle 為權威，不能拿後來 amendment 回寫舊資料。隔離 guard 是 bastion 失聯安全網；若 guard 先於正常 heal 觸發，attempt 必須 taint。

### 2.7 execution order 與 interleaving

排程是 deterministic，不是隨機：group 依序為 steady 4K 四壓力、steady sequential 四壓力、flapping、OSD down、rack isolation、node isolation、sequential contention、chaos；group 內先 replicate，再以 Latin rotation 排三個 profiles。相同 `(shape, pressure, fault, replicate)` 的三個 profiles 連續執行，起始 profile 隨 group/replicate 輪替；同一 group 的 target 固定。rescue/extra amendments 不插回 Latin base schedule，而是按 amendment sequence 接在 base 後，runner 每次取 merged view 的第一個 pending execution。這降低固定 profile-first bias，但不能消除長期 Azure time trend。

### 2.8 primary endpoints 與 denominator

- 稽核註記：harness 原始 primary field 是 `p99_degradation_ratio = aggregate.endpoints.p99_ns / aggregate.windows.baseline.p99_ns`；本文以這兩個 raw ns 欄位呈現 pre-window 與 fault-window 的 ms，但 formal verdict 仍沿用原始 normalized estimand，且不把其 margin 偽裝成 ms threshold。
- measurement end 取實際觀測尾端、`recovery_complete_t`、measurement deadline，以及存在時的 `heal_t0−1` 四者最早者。
- `time_to_recovery_complete_s = recovery_complete_t − fault_t0`。`fault_t0` 在注入動作前記錄，所以包含注入、down detection、manual out 與 backfill；不是從 down epoch、heal 或 `final_clean` 起算。
- `recovery_complete` 的 predicate 是所有 PG state set 恰為 `active+clean`；managed-out target 此時可以仍 down+out。之後把 OSD heal 成 up+in 的 `final_clean` 是另一個 gate。
- 超過 cap 時，TTR 記 `deadline−fault_t0` 作 right-censored lower bound，不代表 recovery 已完成。
- `max_stall_seconds` 先加總所有 client/job/direction 的每秒 IOPS；aggregate IOPS ≤0，或該秒不是 coverage gap、工具 heartbeat 仍存活卻沒有 fio 樣本，皆算 stall。coverage gap 與不完整 segment 尾秒不算；endpoint 取 measurement window 內最長連續區段。
- recovery throughput 的 25% pair margin，以該 pair 兩個 profile mean 的平均為 reference；p99 formal verdict 沿用 preregistered normalized rule，raw ms 只作 human-readable descriptive evidence，不另外創造 ms margin。TTR 同理用 pair mean 平均計 20%，再與 300 秒取較大。

chaos 尚有一項 code-as-written evidence debt：pipeline 寫 `chaos_t0`，aggregate 目前只辨識 `fault_t0`，因此可能錯走 steady denominator 分支。因 chaos 仍是 0 finalized，本報告不產生 chaos endpoint；執行前必須先修正或以 bundle 證明時間窗正確。

## 三、三個 profile 的實際參數

| profile | client res/wgt/lim | recovery res/wgt/lim | best_effort res/wgt/lim |
|---|---:|---:|---:|
| `balanced` | 50% / 1 / max | 50% / 1 / max | 0% / 1 / 90% |
| `high_client_ops` | 60% / 2 / max | 40% / 1 / max | 0% / 1 / 70% |
| `high_recovery_ops` | 30% / 1 / max | 70% / 2 / max | 0% / 1 / max |

`balanced` 是本報告的 default 與一般預設比較基準。
profile 可以 runtime 切換，但「設定已送出」不等於「8 個 OSD 全部生效」。
任何實際切換流程都必須有 8 OSD effective gate。
若任一 OSD 尚未套用，該次比較不能宣稱 profile 一致生效。

## 四、完整 planning 帳

### 4.1 base matrix

| 類別 | cells | 每 cell replicate | base executions |
|---|---:|---:|---:|
| steady | 24 | 3 | 72 |
| flapping | 9 | 2 | 18 |
| OSD down | 9 | 2 | 18 |
| rack isolation | 9 | 2 | 18 |
| node isolation | 3 | 2 | 6 |
| sequential contention | 6 | 2 | 12 |
| chaos | 3 | 1 | 3 |
| **base 合計** |  |  | **147** |

### 4.2 排程與狀態對帳

- base matrix：147 executions。
- rescue：9 executions。
- extra：12 executions。
- scheduled 合計：147 + 9 + 12 = 168。
- finalized：137。
- finalized 內含 steady 71、fault 66、chaos 0。
- needs-human：4。
- pending：27。
- descoped：0。
- 對帳：137 + 4 + 27 = 168。
- 一筆明確離群資料排除後，usable finalized 為 136。
- `auto-out`、`gray`、`adaptive-grace` 尚待裁定。
- 這三項不是已 descoped。
- 四個 fault pilots 各自就是 base matrix 中該 fault 類別的第一個 execution，已併入 147，不是額外 execution。
- return-backfill 才是在 fault execution 內取得的 merged measurement，不另加 execution。
- 不得因 pilot 標籤或 merged measurement 重複增加 planning 分母。

排程層級的帳如下。4 個 `cap-update` 只改 observation cap，不增加 execution，因此不另列成排程層。

| 排程層 | scheduled | finalized | needs-human | pending | descoped |
|---|---:|---:|---:|---:|---:|
| base matrix | 147 | 137 | 4 | 6 | 0 |
| rescue amendments | 9 | 0 | 0 | 9 | 0 |
| extra amendments | 12 | 0 | 0 | 12 | 0 |
| **expanded total** | **168** | **137** | **4** | **27** | **0** |

27 個 execution-pending 依 scenario 分為：flapping 9、OSD down 3、rack isolation 5、node isolation 3、sequential contention 4、chaos 3，合計 27。這裡的 21 個 amendments 就是 9 rescue + 12 extra；不能再與 27 相加。

4 個 needs-human keys 是：

- `none-seq-high+high_recovery_ops/r1`
- `flapping-4k-extreme+high_client_ops/r1`
- `flapping-4k-low+balanced/r1`
- `flapping-4k-low+high_client_ops/r1`

`auto-out`、`gray`、`adaptive-grace` 位於 schedule 之外，狀態是 decision-open；在做出裁定並 amendment 入帳以前，它們既不是上述 27 個 pending executions，也不是 descoped。

### 4.3 規劃目的、預測與目前結果

| 區塊 | 調整的情境 | 為何規劃 | 凍結的事前預測 | 快照結果 |
|---|---|---|---|---|
| A-1 | steady 4K，4 壓力 × 3 profiles | 作為 negative control，先量 profile 自身是否製造差異 | 三者 equivalent | ✅ 未觀察到超過實務門檻/noise 的差異，36/36 完成 |
| A-2 | steady sequential，4 壓力 × 3 profiles | 驗證 large-I/O cost model 下的 negative control | 三者 equivalent | ✅ 未觀察到超過實務門檻/noise 的差異，35/36 可用 |
| B-1 | OSD down，4K low/mid/extreme | 找 reservation 由不 binding 轉為 binding 的壓力點 | low 等效；mid R 傷 client；extreme C < B < R，TTR 反向 | ❌ 已完成組未出現預測的穩健分離 |
| B-2 | flapping，4K low/mid/extreme | 分離 peering stall 與 profile effect | stall equivalent；p99 分離小於 OSD down | ⏳ mid p99 latency 方向相反、stall 有 provisional mean hits；low/extreme 未齊 |
| B-3 | rack isolation，4K low/mid/extreme | 放大 backfill footprint 與 fault domain loss | extreme 分離最大；C client 最佳但 TTR 最長 | ❌ mid/extreme 不支持；low 含一筆排除點 |
| C | node isolation，4K mid | 與 OSD down 同 footprint、只改故障路徑 | 對齊 down epoch 後與 OSD down mid equivalent | ⏳ profile 無分離；對齊與 timestamps debt 未結案 |
| D | sequential contention，mid/extreme | 測試 large-I/O 與 recovery 競爭 | 六 cells equivalent | ⏳ mid recovery throughput 有 provisional mean hits |
| E | chaos，extreme、固定 seed | descriptive showcase 與跨區塊一致性檢查 | 累積 stall C < B < R，不做嚴格 verdict | ⏳ 0 finalized |
| merged | fault pilots、return-backfill | 不增加 execution 地取得早期與 heal-tail 證據 | pilots 沿用 cell prediction；return-backfill R : B : C ≈ 1 : 1.11 : 1.43 | ⏳ pilots 已併入；node timestamps 不可信 |
| optional | auto-out、gray、adaptive-grace | 補 production fault semantics 與灰色失效 | 尚待凍結 | ⏳ decision-open，不是 execution pending，也不是 descoped |

## 五、事前 effect margin 與推論規則

### 5.1 preregistered margin

| endpoint | 跨 margin 的最低條件 |
|---|---|
| p99 latency | formal verdict 沿用原 preregistered normalized rule；本文不列 normalized 數值，也不換造成 ms threshold |
| stall | Δ ≥ 2 秒 |
| recovery throughput | Δ ≥ 25% |
| TTR | Δ ≥ `max(300 秒, 20%)` |

stall 達 5 秒以上就視為 incident-relevant。
stall 達 30 秒以上代表 guest I/O risk 進一步升高。
目前已 finalized 且納入分析的 fault attempts，其 stall 約 20–28 秒，已明顯超過 5 秒營運門檻；chaos 與未完成 replicates 不在這個分母內。
但 stall 的絕對嚴重性與 profile 差異是兩個不同問題。

### 5.2 等效與 underpowered 的規則

本 campaign 原規則只有在觀察 noise 小於事前 margin 時才標 equivalent；本報告為避免把 operational verdict 誤讀成統計證明，結果一律改稱 operationally indistinguishable。
steady client IOPS／bandwidth 沒有另外註冊 formal equivalence bound 或 confidence interval；其百分比只作 negative-control effect size，不能宣稱統計等效。
若 mean gap 跨 margin，但 replicate 範圍重疊，不能宣稱穩健勝負。
若 replicate 只有 n=2，任何單一方向都必須標示 underpowered。
若 endpoint 沒有 preregistered threshold，就只能做 descriptive analysis。
若 baseline 語意不是 injection 前 baseline，就不能拿來回答 injection effect。
若 shape 或 pressure 不同，就不能混在同一 baseline 分布。
若量測被 censored，就不能把 censor time 當成實際 TTR。

## 六、結果總覽

### 6.1 steady 結論

steady 4K 的 36/36 個規劃 executions 均完成；依四個壓力層彙整，IOPS profile 最大差距為 0.03%–0.48%。
steady 4K 的 profile mean p99 gap 為 0.011–0.699 ms。
這些 gap 都小於同 pressure 的 within-profile replicate range；IOPS 與 p99 都沒有 formal equivalence bound。
steady sequential 有 35/36 個規劃 executions 可用。
其 throughput 差距為 0.30%–1.58%。
sequential 的 profile mean p99 gap 為 0.841–2.447 ms。
但 individual cell 的 replicate 全距可到 8.913 ms。
因此 steady 的結論是：在本環境與 workload 下，沒有觀察到超過事前實務門檻與 cell noise 的 profile 差異；這不是 formal equivalence analysis。

完整 steady control 如下。4K throughput 單位是 IOPS；sequential throughput 單位是 MiB/s（2^20 B/s），不是 IOPS。每格格式為 `mean [min,max]；n`；最後一欄將 throughput effect size 留在百分比、p99 effect size 直接寫成 ms，不是 formal equivalence test。

| steady group | throughput B | throughput C | throughput R | p99 B ms | p99 C ms | p99 R ms | 最大 mean gap（throughput / p99） |
|---|---:|---:|---:|---:|---:|---:|---:|
| 4K low | 15426.617 [15363.176,15518.259]；3 | 15368.334 [15263.810,15435.249]；3 | 15409.753 [15379.335,15450.569]；3 | 2.310144 [2.244608,2.375680]；3 | 2.310144 [2.277376,2.342912]；3 | 2.288299 [2.277376,2.310144]；3 | 0.38% / 0.022 ms |
| 4K mid | 30700.754 [30618.850,30799.653]；3 | 30848.242 [30809.781,30919.916]；3 | 30779.565 [30554.314,30954.365]；3 | 3.227648 [3.227648,3.227648]；3 | 3.238571 [3.227648,3.260416]；3 | 3.227648 [3.194880,3.260416]；3 | 0.48% / 0.011 ms |
| 4K high | 49248.702 [49116.477,49368.130]；3 | 49399.900 [49342.066,49451.077]；3 | 49330.909 [49261.606,49412.990]；3 | 6.105771 [6.062080,6.193152]；3 | 6.040235 [5.996544,6.127616]；3 | 6.018389 [5.865472,6.193152]；3 | 0.31% / 0.087 ms |
| 4K extreme | 60420.594 [60286.155,60567.747]；3 | 60414.531 [60365.309,60479.065]；3 | 60401.731 [60056.633,60587.365]；3 | 52.865707 [52.166656,53.739520]；3 | 53.389995 [53.215232,53.739520]；3 | 53.564757 [53.215232,53.739520]；3 | 0.03% / 0.699 ms |
| seq low | 567.299 [566.285,568.817]；3 | 567.021 [564.835,569.942]；3 | 568.736 [568.581,568.929]；3 | 9.895936 [8.847360,10.682368]；3 | 9.229653 [8.290304,10.158080]；3 | 10.070699 [9.764864,10.551296]；3 | 0.30% / 0.841 ms |
| seq mid | 1122.803 [1107.267,1141.096]；3 | 1130.952 [1119.110,1137.912]；3 | 1124.461 [1114.287,1138.378]；3 | 21.452117 [18.743296,25.296896]；3 | 22.675456 [18.481152,27.394048]；3 | 20.316160 [18.219008,23.724032]；3 | 0.72% / 2.359 ms |
| seq high | 1789.969 [1782.609,1803.577]；3 | 1797.007 [1787.596,1808.155]；3 | 1793.214 [1788.202,1798.225]；2 | 76.021760 [71.827456,79.167488]；3 | 75.672235 [73.924608,78.118912]；3 | 78.118912 [76.021760,80.216064]；2 | 0.39% / 2.447 ms |
| seq extreme | 2215.360 [2174.221,2244.088]；3 | 2201.596 [2179.602,2222.262]；3 | 2236.303 [2231.050,2244.109]；3 | 104.333312 [103.284736,105.381888]；3 | 103.284736 [101.187584,107.479040]；3 | 102.585685 [101.187584,103.284736]；3 | 1.58% / 1.748 ms |

steady controls 沒有 fault injection，因此 recovery throughput 是結構性 0，TTR 為 null／不適用；不能把 recovery 的 `0 ≥ 0` 當 threshold hit。seq high 的 R 只有 n=2，因另一個 execution 是 needs-human。

### 6.2 fault 結論

排除離群後，共有 16 個完整 group 可做三 profile 比較：8 個 steady controls 與 8 個 fault groups。
只有 4 個 pair comparisons 跨過各自 endpoint 的事前 margin。
flapping-mid stall 的 B-R mean gap 為 2 秒，門檻為 2 秒。
flapping-mid stall 的 C-R mean gap 為 2.5 秒，門檻為 2 秒。
sequential-mid recovery 的 B-C mean gap 為 106.356 MB/s，25% 門檻為 97.137 MB/s。
sequential-mid recovery 的 B-R mean gap 為 126.144 MB/s，25% 門檻為 99.610 MB/s。
這 4 個比較全部只有 n=2。
這 4 個比較的 replicate 範圍全部重疊。
所以它們只能標為 Provisional / Underpowered。
沒有任何 TTR pair comparison 跨過 TTR margin。
fault-window p99 latency 沒有形成 robust profile ranking。

下表直接呈現 fault 前後的 p99 latency。範圍合併同一 group 內三個 profile 的已納入 replicates；最後一欄用每個 profile 的 raw mean 寫成 `pre-window → fault-window（Δms）`，不要求讀者心算。

| fault group | pre-window p99 ms | fault-window p99 ms | profile mean pre → fault（Δms），B / C / R |
|---|---:|---:|---:|
| flapping 4K mid | 2.97–3.19 | 304–472 | B 2.998→427.819（+424.821）/ C 3.113→335.544（+332.431）/ R 3.031→417.333（+414.302） |
| OSD down 4K low | 2.34–2.47 | 8.45–9.63 | B 2.408→8.978（+6.570）/ C 2.408→8.651（+6.242）/ R 2.425→9.241（+6.816） |
| OSD down 4K mid | 3.23–3.42 | 10.68–13.04 | B 3.310→10.879（+7.569）/ C 3.293→12.780（+9.486）/ R 3.342→11.469（+8.126） |
| OSD down 4K extreme | 47.45–53.74 | 55.31–60.56 | B 47.972→59.245（+11.272）/ C 49.807→57.410（+7.602）/ R 52.167→60.031（+7.864） |
| rack isolation 4K mid | 3.06–3.52 | 19.79–28.44 | B 3.064→22.544（+19.481）/ C 3.473→20.447（+16.974）/ R 3.424→24.773（+21.348） |
| rack isolation 4K extreme | 48.50–55.31 | 70.78–78.12 | B 51.380→74.449（+23.069）/ C 48.759→73.400（+24.642）/ R 54.002→74.973（+20.972） |
| node isolation 4K mid | 3.26–3.49 | 25.30–32.64 | B 3.424→27.787（+24.363）/ C 3.326→27.263（+23.937）/ R 3.408→29.884（+26.477） |
| sequential contention mid | 22.94–33.16 | 46.40–62.65 | B 25.821→55.837（+30.015）/ C 30.933→50.070（+19.137）/ R 28.443→51.380（+22.938） |

### 6.3 完整 fault endpoint 矩陣

以下是 8 個三 profile 都至少 n=2 的 fault groups。每格格式為 `mean [min,max]；n`；recovery 使用十進位 MB/s（10^6 B/s）。明確離群 attempt `20260802T000016Z` 已排除。

| fault group | endpoint | B | C | R |
|---|---|---:|---:|---:|
| flapping 4K mid | p99 ms：pre→fault（Δ）；fault range | 2.998→427.819（+424.821）；[383.779,471.859]；2 | 3.113→335.544（+332.431）；[304.087,367.002]；2 | 3.031→417.333（+414.302）；[408.945,425.722]；2 |
|  | stall s | 23.000 [21,25]；2 | 23.500 [22,25]；2 | 21.000 [20,22]；2 |
|  | recovery MB/s | 0 [0,0]；2 | 0 [0,0]；2 | 0 [0,0]；2 |
|  | TTR s | 2700 [2700,2700]；2 censored | 2700 [2700,2700]；2 censored | 2700 [2700,2700]；2 censored |
| OSD down 4K low | p99 ms：pre→fault（Δ）；fault range | 2.408→8.978（+6.570）；[8.454,9.503]；2 | 2.408→8.651（+6.242）；[8.585,8.716]；2 | 2.425→9.241（+6.816）；[8.847,9.634]；2 |
|  | stall s | 21.500 [21,22]；2 | 20.500 [20,21]；2 | 21.500 [21,22]；2 |
|  | recovery MB/s | 641.414 [554.697,728.131]；2 | 597.758 [587.552,607.964]；2 | 565.882 [565.532,566.231]；2 |
|  | TTR s | 824.000 [759,889]；2 | 815.500 [796,835]；2 | 769.000 [751,787]；2 |
| OSD down 4K mid | p99 ms：pre→fault（Δ）；fault range | 3.310→10.879（+7.569）；[10.682,11.076]；2 | 3.293→12.780（+9.486）；[12.517,13.042]；2 | 3.342→11.469（+8.126）；[11.207,11.731]；2 |
|  | stall s | 21.000 [21,21]；2 | 20.000 [20,20]；2 | 20.500 [20,21]；2 |
|  | recovery MB/s | 483.394 [471.859,494.928]；2 | 534.774 [510.307,559.241]；2 | 509.783 [480.248,539.318]；2 |
|  | TTR s | 883.500 [871,896]；2 | 767.000 [734,800]；2 | 814.500 [764,865]；2 |
| OSD down 4K extreme | p99 ms：pre→fault（Δ）；fault range | 47.972→59.245（+11.272）；[57.934,60.555]；2 | 49.807→57.410（+7.602）；[55.312,59.507]；2 | 52.167→60.031（+7.864）；[59.507,60.555]；2 |
|  | stall s | 20.500 [20,21]；2 | 20.500 [20,21]；2 | 20.500 [20,21]；2 |
|  | recovery MB/s | 407.547 [394.265,420.829]；2 | 411.217 [400.556,421.877]；2 | 412.265 [408.246,416.285]；2 |
|  | TTR s | 971.500 [956,987]；2 | 953.500 [953,954]；2 | 963.000 [898,1028]；2 |
| rack isolation 4K mid | p99 ms：pre→fault（Δ）；fault range | 3.064→22.544（+19.481）；[22.413,22.675]；2 | 3.473→20.447（+16.974）；[19.792,21.103]；2 | 3.424→24.773（+21.348）；[21.103,28.443]；2 |
|  | stall s | 23.000 [23,23]；2 | 22.500 [22,23]；2 | 24.000 [22,26]；2 |
|  | recovery MB/s | 805.936 [788.040,823.831]；2 | 847.983 [806.774,889.192]；2 | 921.873 [871.716,972.030]；2 |
|  | TTR s | 1258.500 [1253,1264]；2 | 1178.500 [1174,1183]；2 | 1115.000 [1090,1140]；2 |
| rack isolation 4K extreme | p99 ms：pre→fault（Δ）；fault range | 51.380→74.449（+23.069）；[72.876,76.022]；2 | 48.759→73.400（+24.642）；[70.779,76.022]；2 | 54.002→74.973（+20.972）；[71.827,78.119]；2 |
|  | stall s | 23.500 [23,24]；2 | 23.000 [23,23]；2 | 23.000 [23,23]；2 |
|  | recovery MB/s | 803.734 [802.161,805.306]；2 | 814.918 [737.498,892.338]；2 | 804.922 [801.811,808.033]；2 |
|  | TTR s | 1325.500 [1294,1357]；2 | 1269.000 [1139,1399]；2 | 1283.000 [1274,1292]；2 |
| node isolation 4K mid | p99 ms：pre→fault（Δ）；fault range | 3.424→27.787（+24.363）；[25.559,30.015]；2 | 3.326→27.263（+23.937）；[25.297,29.229]；2 | 3.408→29.884（+26.477）；[27.132,32.637]；2 |
|  | stall s | 22.500 [22,23]；2 | 24.000 [23,25]；2 | 24.000 [24,24]；2 |
|  | recovery MB/s | 432.443 [425.183,439.703]；2 | 431.839 [332.049,531.628]；2 | 414.537 [323.660,505.414]；2 |
|  | TTR s | 720.000 [702,738]；2 | 708.000 [645,771]；2 | 719.000 [707,731]；2 |
| sequential contention mid | p99 ms：pre→fault（Δ）；fault range | 25.821→55.837（+30.015）；[49.021,62.652]；2 | 30.933→50.070（+19.137）；[46.399,53.740]；2 | 28.443→51.380（+22.938）；[48.497,54.264]；2 |
|  | stall s | 20.500 [20,21]；2 | 20.500 [20,21]；2 | 20.500 [20,21]；2 |
|  | recovery MB/s | 335.370 [196.433,474.306]；2 | 441.725 [360.910,522.540]；2 | 461.513 [343.164,579.863]；2 |
|  | TTR s | 925.000 [855,995]；2 | 766.500 [733,800]；2 | 772.500 [713,832]；2 |

### 6.4 每個 fault group × endpoint 的 margin audit

每列取該 endpoint 三組 pair 中 mean gap 最大者；若另一組 pair 也 hit，會在 verdict 明列。p99 列只顯示 raw fault-window latency gap，formal verdict 仍沿用原 preregistered normalized rule，不把它換算成 ms margin；stall=`2 s`、recovery=`pair mean × 25%`、TTR=`max(300 s, pair mean × 20%)`。

| fault group | endpoint | 最大 gap pair | gap / margin | ranges overlap | verdict |
|---|---|---|---:|---|---|
| flapping mid | p99 latency | B–C | raw gap 92.275 ms；margin 不換算 | raw ms：否 | 原 preregistered normalized rule：No hit |
|  | stall | C–R | 2.500 / 2.000 s | 是 | Hit / Underpowered；B–R 2.000/2.000 也 hit |
|  | recovery | 全部 | 0 / 0 MB/s | 是 | N/A；`0 ≥ 0` 是退化 artifact |
|  | TTR | 全部 | 0 / 540 s | 是 | Censored / No hit |
| OSD down low | p99 latency | C–R | raw gap 0.590 ms；margin 不換算 | raw ms：否 | 原 preregistered normalized rule：No hit |
|  | stall | B–C、C–R | 1.000 / 2.000 s | 是 | No hit |
|  | recovery | B–R | 75.532 / 150.912 MB/s | 是 | No hit |
|  | TTR | B–R | 55.000 / 300 s | 是 | No hit |
| OSD down mid | p99 latency | B–C | raw gap 1.901 ms；margin 不換算 | raw ms：否 | 原 preregistered normalized rule：No hit |
|  | stall | B–C | 1.000 / 2.000 s | 否 | No hit |
|  | recovery | B–C | 51.380 / 127.271 MB/s | 否 | No hit |
|  | TTR | B–C | 116.500 / 300 s | 否 | No hit |
| OSD down extreme | p99 latency | C–R | raw gap 2.621 ms；margin 不換算 | raw ms：是 | 原 preregistered normalized rule：No hit |
|  | stall | 全部 | 0 / 2.000 s | 是 | No hit |
|  | recovery | B–R | 4.719 / 102.476 MB/s | 是 | No hit |
|  | TTR | B–C | 18.000 / 300 s | 否 | No hit |
| rack isolation mid | p99 latency | C–R | raw gap 4.325 ms；margin 不換算 | raw ms：是 | 原 preregistered normalized rule：No hit |
|  | stall | C–R | 1.500 / 2.000 s | 是 | No hit |
|  | recovery | B–R | 115.938 / 215.976 MB/s | 否 | No hit |
|  | TTR | B–R | 143.500 / 300 s | 否 | No hit |
| rack isolation extreme | p99 latency | C–R | raw gap 1.573 ms；margin 不換算 | raw ms：是 | 原 preregistered normalized rule：No hit |
|  | stall | B–C、B–R | 0.500 / 2.000 s | 是 | No hit |
|  | recovery | B–C | 11.185 / 202.331 MB/s | 是 | No hit |
|  | TTR | B–C | 56.500 / 300 s | 是 | No hit |
| node isolation mid | p99 latency | C–R | raw gap 2.621 ms；margin 不換算 | raw ms：是 | 原 preregistered normalized rule：No hit |
|  | stall | B–C、B–R | 1.500 / 2.000 s | B–C 是；B–R 否 | No hit |
|  | recovery | B–R | 17.906 / 105.872 MB/s | 是 | No hit |
|  | TTR | B–C | 12.000 / 300 s | 是 | No hit |
| sequential contention mid | p99 latency | B–C | raw gap 5.767 ms；margin 不換算 | raw ms：是 | 原 preregistered normalized rule：No hit |
|  | stall | 全部 | 0 / 2.000 s | 是 | No hit |
|  | recovery | B–R | 126.144 / 99.610 MB/s | 是 | Hit / Underpowered；B–C 106.356/97.137 也 hit |
|  | TTR | B–C | 158.500 / 300 s | 否 | No hit |

即使 replicate ranges 不重疊，只要 mean gap 未跨 production margin，仍是 No hit，不能形成 profile ranking。全矩陣只有上述 4 個非退化 hits，且四者都是 n=2、ranges overlap；沒有任何 TTR hit。

## 七、逐類五欄詳情

### 7.1 steady 4K

1. **調整參數**：固定 Ceph、PG 與 OSD capacity，依 4K low、mid、high、extreme 四個 pressure 切換 B、C、R。
2. **為何測**：先確認 profile 是否在沒有 fault 時犧牲 client IOPS 或 p99。
3. **事前預測**：三個 profile 應 indistinguishable（equivalent）；沒有 recovery 流量時 client 是唯一 active class，reservation 是下限而不是上限。
4. **結果**：36/36 IOPS 最大差距僅 0.03%–0.48%，profile mean p99 gap 僅 0.011–0.699 ms。
5. **建議**：判為 operationally indistinguishable；steady 4K 不構成離開 `balanced` 的理由，但不宣稱正式統計等效。

### 7.2 steady sequential

1. **調整參數**：使用 sequential low、mid、high、extreme 四個 pressure，比較 B、C、R。
2. **為何測**：確認 sequential bandwidth 與 latency 是否對 profile 更敏感。
3. **事前預測**：同 steady 4K，三個 profile 應 indistinguishable（equivalent）。
4. **結果**：35/36 sequential throughput 差距為 0.30%–1.58%；profile mean p99 gap 為 0.841–2.447 ms，cell 內 replicate 全距可到 8.913 ms。
5. **建議**：判為 operationally indistinguishable；不可用 group mean 順序製造 profile 排名，也不宣稱正式統計等效。

### 7.3 flapping-mid

1. **調整參數**：在 mid pressure 下重複 flapping fault，分別套用 B、C、R。
2. **為何測**：觀察反覆 membership/availability 擾動是否放大 client stall 與 recovery 不穩定。
3. **事前預測**：max stall 三者應 indistinguishable，因 peering 主導；p99 latency 的 profile 分離應小於同壓力 OSD down，recovery 差異可能落在 margin 內。
4. **結果**：p99 mean 由 B 2.998→427.819（+424.821）、C 3.113→335.544（+332.431）、R 3.031→417.333 ms（+414.302）；fault-window 最大 raw gap 為 92.275 ms，同壓力 OSD down 只有 1.901 ms，描述方向與預測相反。stall mean 為 23、23.5、21 秒，replicate 範圍依序為 `[21,25]`、`[22,25]`、`[20,22]` 秒。
5. **建議**：原 preregistered normalized p99 rule 為 No hit，raw 92.275 ms gap 只作 human-readable magnitude；B-R 與 C-R stall gap 剛跨 2 秒 margin，但 n=2 且 replicate 範圍重疊，只能 Provisional。low/extreme 尚待完成。

flapping-mid 的 TTR 三者都是 2,700 秒 censored。
不能把 2,700 秒解讀為三者真正相同的完成時間。
它只表示量測窗結束時三者都尚未完成既定 recovery 條件。
H-033 也使 flapping 的操作風險高於單純 profile 比較。

### 7.4 OSD down、4K low

1. **調整參數**：4K low pressure 下執行 OSD down，依序比較 B、C、R。
2. **為何測**：測試輕壓力時 client latency 與 recovery 是否能被 profile 明顯分離。
3. **事前預測**：client 面三者應 indistinguishable；recovery throughput 應為 R ≥ B ≈ C，因 recovery 可取用 client 未使用的資源。
4. **結果**：p99 mean 由 B 2.408→8.978（+6.570）、C 2.408→8.651（+6.242）、R 2.425→9.241 ms（+6.816）；recovery throughput mean 為 B 641.414、C 597.758、R 565.882 MB/s，與預測方向相反；TTR 為 824、815.5、769 秒。
5. **建議**：descriptive recovery 方向違反預測，但沒有 pair 跨過 preregistered margin；維持 Underpowered、無穩健排名。

### 7.5 OSD down、4K mid

1. **調整參數**：4K mid pressure 下執行 OSD down，比較 B、C、R。
2. **為何測**：檢查 pressure 上升後，client 與 recovery 資源競爭是否顯現。
3. **事前預測**：R 的 client 劣化應顯著，B ≈ C；recovery throughput 應為 R > B ≳ C。
4. **結果**：p99 mean 由 B 3.310→10.879（+7.569）、C 3.293→12.780（+9.486）、R 3.342→11.469 ms（+8.126）；TTR 為 883.5、767、814.5 秒。
5. **建議**：平均值方向與預測不一致，且未跨 margin；不要據此選 C 或 R。

### 7.6 OSD down、4K extreme

1. **調整參數**：在最高 4K pressure 層執行 OSD down，比較 B、C、R。
2. **為何測**：測試接近 calibration 上緣時 profile 是否產生可操作的差異。
3. **事前預測**：client 劣化應完整分離為 C < B < R，client throughput 約依 0.6 : 0.5 : 0.3；TTR 應為 R < B < C。
4. **結果**：p99 mean 由 B 47.972→59.245（+11.272）、C 49.807→57.410（+7.602）、R 52.167→60.031 ms（+7.864）。raw fault-window ms 的 C < B < R 只屬 post hoc descriptive ordering；原 preregistered normalized p99 direction 並未符合凍結預測。TTR 為 971.5、953.5、963 秒，順序 C < R < B，也與凍結方向相反。
5. **建議**：原 preregistered normalized p99 rule 與 TTR 都沒有 pair hit，raw absolute ordering 不得改寫 prediction fate；primary endpoints 只能判 Underpowered。post-clean achieve_ratio 另列 descriptive 訊號。

### 7.7 rack isolation、4K mid

1. **調整參數**：隔離一個 synthetic rack，在 4K mid pressure 下比較 B、C、R。
2. **為何測**：觀察同時失去兩個 OSD fault domain 時的 client impact 與 recovery。
3. **事前預測**：R 的 client 劣化應顯著；兩顆 OSD 同時失去後，backfill footprint 與絕對 recovery 成本應大於單一 OSD down。
4. **結果**：p99 mean 由 B 3.064→22.544（+19.481）、C 3.473→20.447（+16.974）、R 3.424→24.773 ms（+21.348）。raw fault-window ms 的 R 最高只屬 post hoc descriptive ordering；原 preregistered normalized p99 direction 未支持凍結預測。TTR 為 1,258.5、1,178.5、1,115 秒。
5. **建議**：原 preregistered normalized p99 rule 為 No hit，raw 最大 gap 4.325 ms 只描述絕對量級，不做 profile 排名。

### 7.8 rack isolation、4K extreme

1. **調整參數**：隔離一個 synthetic rack，在最高 4K pressure 層比較 B、C、R。
2. **為何測**：測試高 client pressure 與大 fault domain loss 的交互影響。
3. **事前預測**：這應是全矩陣 profile 分離最大的區塊；C 的 client 保護最好，但 TTR 最長且最可能 censored，R 應最快。
4. **結果**：p99 mean 由 B 51.380→74.449（+23.069）、C 48.759→73.400（+24.642）、R 54.002→74.973 ms（+20.972）。raw fault-window ms 的 C 最低只屬 post hoc descriptive ordering；原 preregistered normalized p99 direction 並未支持「C client 最佳」的凍結預測。TTR 為 1,325.5、1,269、1,283 秒，C 反而最短，也與凍結方向相反。
5. **建議**：原 preregistered normalized p99 rule 與 TTR 都沒有 pair hit，raw absolute ordering 不得改寫 prediction fate；primary endpoints 只能判 Underpowered。rack post-clean achieve_ratio 也未超過 C 的 within-profile range。

### 7.9 node isolation、4K mid

1. **調整參數**：隔離完整 OSD node，在 4K mid pressure 下比較 B、C、R。
2. **為何測**：確認 node-level fault 是否與單一 OSD down 呈現不同 profile 敏感度。
3. **事前預測**：以 OSDMap down epoch 對齊後，四個 primary endpoints 應與 OSD down 4K mid indistinguishable；`fault_t0` 到 down epoch 約 20–30 秒，而直接 OSD down 應小於 5 秒。
4. **結果**：p99 mean 由 B 3.424→27.787（+24.363）、C 3.326→27.263（+23.937）、R 3.408→29.884 ms（+26.477）；TTR 為 720、708、719 秒。
5. **建議**：差距不跨 margin；node return-backfill timestamps 不可信，不能補強排名。

### 7.10 sequential contention、mid

1. **調整參數**：在 sequential mid pressure 與 recovery contention 下比較 B、C、R。
2. **為何測**：測試 bandwidth-heavy client 與 recovery 是否比 4K workload 更容易被 mClock 分離。
3. **事前預測**：六個 sequential contention cells 應全部 indistinguishable；任一 profile pair 跨 margin，便會對名義 cost model 的假設構成證偽壓力。
4. **結果**：p99 mean 由 B 25.821→55.837（+30.015）、C 30.933→50.070（+19.137）、R 28.443→51.380 ms（+22.938）；TTR 為 925、766.5、772.5 秒。
5. **建議**：recovery 有兩個跨 margin 的 pair，但 replicate 範圍重疊且 n=2，先補 replicate。

sequential-mid recovery throughput 如下。

| profile | mean MB/s | replicate range MB/s |
|---|---:|---:|
| B | 335.370 | 196.433–474.306 |
| C | 441.725 | 360.910–522.540 |
| R | 461.513 | 343.164–579.863 |

B-C mean gap 為 106.356 MB/s，對應 25% margin 為 97.137 MB/s。
B-R mean gap 為 126.144 MB/s，對應 25% margin 為 99.610 MB/s。
C 與 R 的 range 都與 B overlap。
TTR 的最大 mean gap 也沒有跨過 `max(300 秒, 20%)`。
這是補做 r3 的理由，不是立即切換 profile 的理由。

### 7.11 fault pilots 與 return-backfill

1. **調整參數**：四個 pilot 沿用各自 base cell 的 profile 與 fault；return-backfill 則在既有 fault execution 中附帶量測。
2. **為何測**：以不增加 execution 的方式觀察 fault 回復尾端行為。
3. **事前預測**：pilot 沿用所屬 cell 的凍結預測；return-backfill 時間應約為 R : B : C = 1 : 1.11 : 1.43。
4. **結果**：pilot 已併入 base execution 帳，return-backfill 是 merged measurement；node return-backfill timestamps 目前不可信，不能檢驗該比例。
5. **建議**：不增加 planning 分母，也不以不可信 timestamps 支持 TTR 結論。

### 7.12 chaos 與待裁定 scenario

1. **調整參數**：base matrix 規劃 3 個 chaos cells，各 n=1；另有 auto-out、gray、adaptive-grace 待裁定。
2. **為何測**：探索組合 fault 與灰色失效是否出現既有 scenario 沒覆蓋的行為。
3. **事前預測**：chaos 僅作 n=1 descriptive showcase，但累積 stall 的方向預測為 C < B < R；待裁定的三個 scenario 尚無凍結結果可檢驗。
4. **結果**：截至快照 chaos finalized 為 0；三個待裁定項目也未形成結果。
5. **建議**：全部保持 Open；不可寫成 descoped，也不可納入 profile 排名。

## 八、post-event achieve_ratio：只能描述，不能升格

### 8.1 語意與計算方式

`achieve_ratio` 是 final-clean `baseline.json.achieved_iops / 63634`。
它不是 primary endpoint。
它不是 injection 前 baseline。
它沒有 preregistered threshold。
它也沒有 preregistered statistical test。
所以本節只能做 strong preliminary descriptive separation 或不成立的描述。

### 8.2 OSD down、4K extreme

| profile | mean achieve_ratio | range |
|---|---:|---:|
| C | 1.024839 | 1.024679–1.024999 |
| B | 0.905303 | 0.904156–0.906450 |
| R | 0.883061 | 0.882166–0.883956 |

C、B、R 的 mean 與 ranges 呈現明顯分離。
mean 差相對該 pair 兩組中較大的 within-profile range，分別是 B–R 9.70×、C–B 52.12×、C–R 79.21×。
這可稱為 strong preliminary descriptive separation。
它不能被改寫成 preregistered causal conclusion。
它也不能推翻 primary p99、stall、recovery throughput 與 TTR 的結論。

### 8.3 rack isolation、4K extreme

| profile | mean achieve_ratio | range |
|---|---:|---:|
| C | 0.905214 | 0.783270–1.027159 |
| B | 0.784881 | 0.775814–0.793947 |
| R | 0.972251 | 0.955797–0.988706 |

最大 mean span 為 0.187371。
C 的 within-profile range 為 0.243890。
mean span 小於 C 自己的 within-profile range。
因此目前無法宣稱 rack extreme 有 robust three-profile descriptive separation。

### 8.4 跨 pressure 只描述 latency，不推論 profile effect

排除明確離群後，rack low 的 fault-window p99 為 13.828–16.450 ms，rack mid 為 19.792–28.443 ms，rack extreme 為 70.779–78.119 ms。
這些 raw latency 直接呈現 workload pressure 上升時 client 面承受的絕對延遲。
但 low、mid、extreme 的 workload 與 pre-window latency 不同，因此跨 pressure 的絕對值不能用來推論 profile effect；profile 比較仍須留在同 pressure group 的 formal verdict audit，並以 raw ms 呈現人類可讀的 magnitude。

## 九、明確離群資料與 baseline 語意

唯一明確排除的資料位於：

`results/rack-isolation-4k-low+balanced/r2/attempts/20260802T000016Z/aggregate.json`

該次 injection-window baseline p99 為 28.966912 ms。
同 shape、同 pressure 的 4K/low baseline median 為 2.375680 ms。
MAD 為 0.065536 ms。
該次 baseline 比同組 median 高 26.591232 ms。
verdict 已 recorded，且 `tainted=false`。
這表示 harness 當時沒有攔到它。
分析層必須明確排除，才能得到 usable=136。
不要改用 post-clean `baseline.json` 的 14.221312 ms 當 injection-window baseline。
14.221312 ms 與 28.966912 ms 的語意和時間窗不同。

## 十、資料品質與研究事故

### 10.1 drift gate 設計失配

drift gate 在 8 天內停止 campaign 6 次。
6 次沒有任何一次是 true positive。
原 gate 量到的是 post-event 善後複測。
該階段受 backfill heavy-tail 影響。
例如 4K/low/backfill 的 post-clean p99 從 2.899968 升到 14.221312 ms，raw gap 為 11.321344 ms；4K/mid/backfill 從 4.227072 升到 38.010880 ms，raw gap 為 33.783808 ms，並出現 10.3、12.4、30.8、38.0 ms 的重尾值。
它不是 cluster 的 injection 前 pre-window 基準。
因此原 gate 的資料語意與名稱不一致。
目前已改成 warn-only。
threshold、streak、detection 邏輯沒有修改。
所有 validity gate 也沒有修改。
截至固定快照，`DRIFT-ALERT=0`。
final report 前必須手動清零 `results/baseline-drift-state.json`。
清零後必須重新執行 audit。
相較之下，injection pre-window 必須依 8 個 `(shape, pressure)` 組合分開保留 raw p99 ms 分布，不能用跨組百分比壓成同一尺度。原 proposed heuristic 是同組 median 偏離超過 50%；下表已把規則展開成可直接操作的 ms 界線，讀者不需心算。

| shape / pressure | clean n | median p99 ms | lower bound ms | upper bound ms | 狀態 |
|---|---:|---:|---:|---:|---|
| 4K low | 24 | 2.359296 | 1.179648 | 3.538944 | Provisional；已排除明確離群 attempt |
| 4K mid | 33 | 3.194880 | 1.597440 | 4.792320 | Provisional |
| 4K high | 9 | 5.931008 | 2.965504 | 8.896512 | Provisional；樣本僅 9 |
| 4K extreme | 26 | 52.690944 | 26.345472 | 79.036416 | Provisional |
| sequential low | 9 | 10.027008 | 5.013504 | 15.040512 | Provisional；樣本僅 9 |
| sequential mid | 15 | 24.248320 | 12.124160 | 36.372480 | Provisional |
| sequential high | 8 | 76.546048 | 38.273024 | 114.819072 | Provisional；另有一筆 needs-human 未納入 |
| sequential extreme | 12 | 103.809024 | 51.904512 | 155.713536 | Provisional |

表內 clean set 固定在本報告快照，且不含 `20260802T000016Z`；因此 4K/low 的 2.359296 ms clean median，會與第九節用完整候選集合偵測該離群點時的 2.375680 ms reference median 不同。後續遇到 pre-window p99 低於 lower bound 或高於 upper bound 時，先標記、排除並查 evidence；這些界線必須以歷史 clean samples 回測 false-positive/false-negative，在完成前維持 warn-only，只有多筆新越界同時出現才升級為 cluster 環境劣化訊號。

### 10.2 rack fake-taint annotation

重算出的 rack raw fake-taint annotations 為 23。
這 23 是 18 個 DONE attempts 加 5 個 ABORTED attempts。
它不是 23 個 invalid datasets。
全部 18 個 finalized rack verdict 都是 `tainted=false`。
另有 3 次 sampler heartbeat loss。
這 3 次 heartbeat loss 與 H-033 無關。
final report 必須把 attempt annotation、dataset validity 與 incident 分開記帳。

### 10.3 H-033

H-033 是 flapping 後 PG 卡在 `recovering`。
同時 client 出現 D-state/hang。
完整重現 2 次。
另有 2 次相似指紋。
這是一個操作與回復安全問題，不只是統計 noise。
`ceph pg repeer` 必須使用嚴格 allowlist，只允許 `recovering`、`peering`、`activating`、`stale`、`incomplete`、`down`、`unknown`。
它不可用於 `backfill_wait` 或 `backfilling`。
cephadm systemd unit 在 30 分鐘內第 5 次啟動可觸發 start-limit。
告警與 runbook 必須同時覆蓋 PG state、client hang 與 systemd start-limit。

本報告的 20–28 秒 `max_stall_seconds` 是 finalized attempt 在排定 fault observation window 內、把四台 client 全部 IOPS 加總後的 endpoint。H-033 的 28 分鐘則是 incident wall-clock：單一 `mclock-client-3` fio process 在第 3 segment 後卡於 krbd/kernel D-state，其餘三台仍持續完成 segments；原始 H-033 attempts 是 ABORTED，也沒有 `aggregate.json`。兩者不是同一個分母、時間窗或終止條件：前者用來比較已完成 attempts，後者證明單一 client 可能越過量測窗持續惡化。因此不能用 20–28 秒否定 28 分鐘事故，也不能把 28 分鐘冒充正式 aggregate stall endpoint。

### 10.4 分析與 history 事故

曾把 post-event baseline 誤當成 pre-injection baseline。
曾因 analysis 漏掉 shape，將 sequential 資料混入 4K baseline。
錯誤混用後產生假的 10.527 ms，甚至進入程式註解。
正確值是 3.523 ms，後續已修正。
曾在 n=1 時看見 profile 排名，但增加到 n=2 後排名消失。
曾過度宣稱 rack achieve_ratio，後續因 within-profile range 較大而撤回。
這些事故共同說明：資料語意、shape key、replicate 與 noise gate 必須先於敘事。

## 十一、事前預測與中途解讀的命運

下表只把 `HYPOTHESES.md` 在執行前寫下的方向稱為「事前預測」；n=1 排名、rack `achieve_ratio` 與 drift gate 的說法是 campaign 中途解讀，分開記錄，避免事後改寫 prediction。

| 區塊 | 凍結的事前預測 | 目前判讀 |
|---|---|---|
| steady 4K / sequential | 三 profile equivalent | ✅ operationally indistinguishable；差距未超過 noise 或 production margin，但未做 formal equivalence test |
| OSD down low | client equivalent；recovery R ≥ B ≈ C | ❌ recovery mean 實為 B > C > R，descriptive direction 相反；但未跨 margin，仍是 Underpowered |
| OSD down mid | R 的 client 劣化顯著、B ≈ C；recovery R > B ≳ C | ❌ 目前平均值方向不符，且沒有 pair 通過完整判定 |
| OSD down extreme | client 劣化 C < B < R；TTR R < B < C | ❌ 原 preregistered normalized p99 direction 不符合預測；raw fault-window p99 的 C 57.410 < B 59.245 < R 60.031 ms 只作 post hoc 描述，不改寫 verdict；TTR 為 C < R < B，方向相反 |
| flapping | stall equivalent；p99 分離小於同壓力 OSD down | ⏳ 原 preregistered normalized p99 direction 與預測相反；raw fault-window gap 為 92.275 ms，OSD-down-mid 為 1.901 ms；stall 有兩個 mean hit，但均 n=2、範圍重疊；low/extreme 未齊 |
| rack isolation | extreme 分離最大；C client 最佳但 TTR 最長 | ❌ 原 preregistered normalized p99 direction 不支持 C client 最佳；raw rack-extreme C 73.400 ms 最低只作 post hoc 描述，不改寫 verdict；C 的 TTR 反而最短，low 又有一筆明確排除點 |
| node isolation | 對齊 down epoch 後與 OSD down mid equivalent | ⏳ 尚須完成對齊分析；return-backfill timestamps 不能使用 |
| sequential contention | 六 cells 全部 equivalent | ⏳ recovery throughput 出現兩個 provisional mean hits，對 cost model 形成證偽壓力，但範圍仍重疊 |
| chaos | n=1 descriptive；累積 stall C < B < R | ⏳ 0 finalized |
| return-backfill | 時間約 R : B : C = 1 : 1.11 : 1.43 | ⏳ node timestamps 不可信，現在不能判定 |

三個高價值的中途解讀也已被撤回：n=1 看見的 profile 排名沒有在 n=2 保留；rack-extreme post-clean `achieve_ratio` 的組間差小於 C 自己的 within-profile range；drift gate 被當成 pre-window 環境監看器，卻在 8 天內造成 6 次 false stop、0 true positive。這些不是凍結的 cell prediction，但同樣必須留在研究事故帳。

## 十二、營運建議表

| 決策 | 目前值／動作 | 依據與效果量 | 證據強度 | 可調性／成本 | 升級條件 |
|---|---|---|---|---|---|
| 一般預設 profile | 維持 `balanced` | A-1/A-2：steady 4K IOPS 差 0.03%–0.48%；4K p99 gap 0.011–0.699 ms、sequential p99 gap 0.841–2.447 ms，均小於同 cell replicate 全距 | Operationally indistinguishable | runtime、無須重啟；仍須 8 OSD effective gate | final audit 不推翻 negative-control 判讀 |
| 全域切換 profile | 不要切換 | B/C/D：只有 4 個 mean hit，均 n=2 且範圍重疊；TTR 0 hit | 中期決策 | 不變更 | 多 scenario、足夠 replicate 的一致勝出 |
| OSD down + 4K extreme + post-clean throughput | 僅把 C 列為 follow-up 假說，不作 production 切換依據 | B-1 descriptive：C/B/R achieve_ratio 1.024839/0.905303/0.883061 | Descriptive only | 研究排程；若未來要切仍是 runtime + 8 OSD gate | 先事前註冊 follow-up，再完成 r3、audit、dataset seal |
| recovery 導向預設 | 不採用 R 作全域預設 | D mid recovery 有 provisional hits，但所有 TTR pair 0 hit | Underpowered | 不變更 | recovery/TTR 同時跨 margin 且 replicate 範圍不重疊 |
| PG non-clean/no-progress | 同一 PG 非 active+clean 且 15 分鐘無進度先 warning；合併 client stall、blocked ops 或 `up`/`acting` 不一致才 page | H-033：2 次完整重現、2 次相似指紋；15 分鐘約是最短 28 分鐘 hang 的一半，旨在保留人工反應時間 | Proposed incident heuristic | alert rule runtime 更新 | 先量正常 recovery dwell 與誤報率，再決定 production page 門檻 |
| slow ops | runbook 查 `up`/`acting` 與 PG state | H-033：SLOW_OPS 指向受害 primary，不直接等於肇因 OSD | Incident-backed | runbook 變更，無 cluster restart | runbook 演練完成 |
| `ceph pg repeer` | 不自動化；只限 allowlist state、一次一個 PG，排除 `backfill_wait`/`backfilling` | H-033：卡住 PG 在實驗中可由 repeer 恢復 | Incident-backed | 高風險且沒有真正 rollback，須 SRE 人工核准 | 獨立安全 review 與 staging 演練完成 |
| systemd | 監控 start-limit | 30 分鐘內第 5 次啟動可觸發 | Incident-backed | alert rule/runtime runbook | 告警能在門檻前後正確辨識 |
| 上游 timeout/retry | 先盤點並標記 `<30 秒` 的元件；在 staging 比較 30 秒與 60 秒，不直接指定 production 通用值 | 已納入 fault attempts 的 stall 約 20–28 秒；H-033 另有 28 分鐘 hang | Proposed validation plan | 依元件可能 runtime 或 rolling update；須觀察 retry amplification | 補齊 guest path、retry storm 與剩餘 fault 驗證後逐元件定值 |
| profile runtime 切換 | 每次都要求 8 OSD effective gate | 所有納入資料均以 effective state 作 validity gate | Required guardrail | runtime、無須重啟；需等待收斂 | 全體 OSD 都確認生效 |
| OSD capacity | 保持 6,057–6,646 IOPS 與 `skip_benchmark=true` | calibration CoV 3.188%；舊值 21,500 不符合本環境 | Environment-backed | runtime config，但重校準會破壞 campaign 可比性 | 新的完整 capacity calibration |

### 12.1 立即可採取但仍需標示 provisional 的事項

15 分鐘是 H-033 導出的 proposed warning 起點，不是從 production baseline 算出的 page threshold；只有「同一 PG 無進度」再合併 client/blocked-op/`up`-`acting` 訊號才升級，並須先量正常 backfill/recovery 的誤報率。
slow ops 調查應同時查看 PG 的 `up` 與 `acting` 集合。
systemd start-limit 應有獨立監控，不應只看 Ceph health summary。
對 `ceph pg repeer`，操作者必須先保存 `ceph pg query` 與 cluster health、確認 PG 落在 allowlist、取得 SRE 人工核准、一次只處理一個 PG並立即 postcheck；若沒有改善或 health 惡化，停止重試、保存 evidence 並升級事件。此操作沒有可保證的 rollback，所以不得包成自動 remediation。
上游 timeout/retry 的立即動作是標記 `<30 秒` 的現值並在 staging 跑 30/60 秒兩組測試，同時觀察 retry rate、queue depth 與 guest error；在這些資料完成前不提供跨元件的 production 通用值。
這些措施針對 fault severity，不代表已找出最佳 profile。

### 12.2 暫時不要做的事項

不要以單一 fault-window p99 mean 最低者作全域 profile。
不要以 post-clean achieve_ratio 取代 primary endpoints。
不要把 2,700 秒 censored TTR 當成精確完成時間。
不要跨 pressure 用絕對 p99 latency 推論 profile effect。
不要把 23 個 fake-taint annotations 寫成 23 個 invalid datasets。
不要把 auto-out、gray、adaptive-grace 寫成 descoped。
不要把 capacity 改回 21,500。
不要關閉 `skip_benchmark=true` 破壞 campaign 可比較性。

## 十三、限制與 open work

campaign 仍在進行中。
27 個 pending 包含尚無 finalized dataset 的 chaos 與尚未全部完成的 21 個追加 replicates。
4 個 needs-human 尚待人工裁定。
final audit 尚未完成。
dataset seal 尚未完成。
evidence summary 尚未完成。
Azure 實際帳單尚未取得。
環境 teardown 尚未完成。
`HYPOTHESES.md` 尚未回填完成。
node return-backfill timestamps 目前不可信。
expectations 欄位目前為空。
expectations 為空會削弱自動化 verdict 的可稽核性。
outlier harness 未在執行時攔截已知極端 baseline。
drift state 必須清零後重跑 audit。
OSD-down extreme achieve_ratio 尚缺 r3 與 preregistered follow-up。
目前每個關鍵 fault group 主要只有 n=2。
steady IOPS／bandwidth 沒有 formal equivalence bound、confidence interval 或 equivalence test；本報告只做 operational threshold/noise 判讀。
base schedule 是 deterministic Latin rotation，不是完全隨機；rescue/extra 又接在 base 之後，仍可能混入長期 Azure time trend。
chaos 的 `chaos_t0` 與 aggregate 只辨識 `fault_t0` 存在 code-as-written 時間窗風險，0 finalized 前不得忽略。
H-033 的 28 分鐘是 ABORTED attempt 的 incident-level single-client hang，沒有 machine-readable aggregate endpoint。
synthetic racks 共享單一 subnet。
Azure VM、local NVMe 與單 NIC 結果不可直接外推到其他環境。
Ceph v19.2.2 結果不可不經驗證外推到 v19.2.3。
handoff 粗估為約 179.9 小時、US$1,439。
估算公式是 `elapsed_h × FAULTS_HOURLY_USD`，預設費率為全 fleet US$8/小時並四捨五入到整數美元；較早一筆持久化 runner report 為 170.67 小時、US$1,365，與公式一致。
這個模型不含雜項，也不是 Azure Cost Management 的實際 bill。

## 十四、final report 前的完成條件

先按以下順序執行；owner 是角色，不是假定的人名。

| 優先序 | 時點 | owner | 工作與完成定義 |
|---|---|---|---|
| P0 | campaign 仍在跑時，每 2 小時 | campaign operator | 檢查 supervisor/runner、pre-window 是否超出 §10.1 同 shape/pressure 的 direct-ms lower／upper bound、`DRIFT-ALERT`、Azure 登入與 rollback health；不平行啟動第二個 gate |
| P0 | `pending=0` 後第一個工作區段 | campaign operator + evidence analyst | 凍結新 execution、逐筆裁定 4 個 needs-human、確認 optional decisions，不把 decision-open 混入 execution ledger |
| P0 | needs-human 裁定後、寫 final report 前 | evidence analyst | 手動清零 drift state、重跑 audit、套用明確 exclusion、產生完整矩陣與 dataset seal；任一 validity failure 都阻擋 final report |
| P1 | 同一個 final review cycle | SRE reviewer | 審核 H-033 告警、`repeer` allowlist／核准／失敗流程、systemd start-limit 與 30/60 秒 timeout staging plan |
| P1 | final report 發布前 | project owner | 回填 `HYPOTHESES.md`、記錄 optional scenario 裁定、取得實際 Azure bill，並把 estimated/actual 分欄 |
| P1 | evidence 保存與 teardown 核准後 | cloud owner | 關閉 Azure 資源並保存 teardown evidence；不得在資料未 seal 前拆除唯一證據來源 |

handoff 在本快照估計尚需 18–24 小時；這只是排程估算，若 needs-human、r3 或 audit 失敗，以上時點順延，不以日期硬壓過 validity gate。

1. 完成 21 個追加 replicates，或逐一記錄無法完成的原因。
2. 完成 4 個 needs-human 的人工 evidence review。
3. 裁定 auto-out、gray、adaptive-grace，且不得默認 descoped。
4. 完成 chaos 或清楚保留為未完成範圍。
5. 手動清零 `results/baseline-drift-state.json`。
6. 重新執行完整 audit，確認 `DRIFT-ALERT` 與 validity gate 狀態。
7. 對所有 finalized dataset 執行 dataset seal。
8. 產出可追溯到 attempt 的 evidence summary。
9. 修補或明確隔離 node return-backfill timestamp 問題。
10. 在 audit 中記錄既有 `prediction.json.expectations` 為空的 evidence debt；不得事後回填舊 bundle，後續新 execution 才強制非空。
11. 對 H-033 的 allowlist、start-limit 與回復流程做獨立 review。
12. 取得 Azure 實際帳單，與約 179.9 小時/US$1,439 估算分開呈現。
13. 完成環境 teardown 並保存必要 evidence。
14. 回填 `HYPOTHESES.md`，標明 supported、falsified、open。
15. 再次確認 System under test 版本寫成 v19.2.2。

## 十五、evidence index

### E-01：planning ledger

路徑：`results/manifest.json`、`results/schedule-amendments.json`。

用途：對帳 147 base、9 rescue、12 extra 與 168 scheduled。
目前狀態：快照已固定；final report 仍須納入 sealed evidence summary。

### E-02：steady aggregates

路徑：`results/none-*/r*/attempts/*/aggregate.json`，只納入同 attempt 有 `DONE` 的資料。

用途：支持 4K 36/36 與 sequential 35/36 的 negative-control／operationally-indistinguishable 判讀；不是 formal equivalence proof。
目前狀態：中期判讀可用；final report 須保留 cell-level noise 與缺少的一個 execution。

### E-03：fault group aggregates

路徑：`results/{flapping,osd-down,rack-isolation,node-isolation,seq-contention}-*/r*/attempts/*/aggregate.json`，並以同 attempt 的 `prediction.json` 取得 group/profile。

用途：支持 16 個完整可比較 group（8 steady、8 fault）、4 個跨 margin pair comparisons 與無 TTR ranking。
目前狀態：跨 margin 的 4 個比較都是 n=2，必須保留 replicate 範圍重疊與 Underpowered 標籤。

### E-04：明確離群 attempt

路徑：`results/rack-isolation-4k-low+balanced/r2/attempts/20260802T000016Z/aggregate.json`。
用途：記錄 injection-window baseline p99 28.966912 ms 與排除理由。
注意：不可用 post-clean 14.221312 ms 取代該時間窗。

### E-05：final-clean baseline

路徑：各已納入 attempt 的 `baseline.json`；分母取 `results/calibration.json` 的 4K ceiling 63,634 IOPS。

用途：計算 `baseline.json.achieved_iops / 63634` 的 post-event achieve_ratio。
目前狀態：Descriptive only；沒有 preregistered threshold/test。

### E-06：drift state

路徑：`results/baseline-drift-state.json`。
用途：保存 drift streak/state。
注意：final report 前須人工清零並重跑 audit，不能沿用舊 state。

### E-07：rack annotation 重算

路徑：`results/faults.log` 與 rack attempt verdict/DONE markers。

用途：區分 18 DONE、5 ABORTED attempts 與 finalized dataset validity。
目前狀態：23 raw annotations 不等於 23 invalid datasets；18 finalized verdict 均 `tainted=false`。

### E-08：H-033 incident evidence

路徑：`results/evidence/H033-*` 與 `HYPOTHESES.md` 的 H-029/H-033。

用途：串連 PG `recovering`、client D-state/hang、reproduction 與回復限制。
目前狀態：2 次完整重現、2 次相似指紋；與 3 次 sampler heartbeat loss 分開。

### E-09：profile effective state

路徑：各 attempt 的 `qos.json`（例如 `results/none-4k-mid+balanced/r1/attempts/20260726T205433Z/qos.json`）。

用途：證明每次 runtime 切換後 8 個 OSD 都套用預期 profile。
目前狀態：屬必要 validity gate；final evidence summary 須逐 run 可追溯。

### E-10：成本與 teardown

路徑：`results/faults.log`、`results/.campaign-start`、`README.md` 的 cost observability 說明。

用途：區分約 179.9 小時/US$1,439 handoff 估算、實際 Azure bill 與資源關閉證據。
目前狀態：實際 bill 與 teardown 尚未完成。

### E-11：方法與時間窗實作

路徑：`lib/fio.sh`（workload/segment/readiness）、`lib/inject.sh`（fault/heal）、`lib/manifest.py`（schedule/order）、`lib/verdict.py`（window/endpoints）、`lib/ceph.sh`（recovery predicate/effective config）。

用途：讓 §2.5–2.8 的 workload、fault knob、TTR、stall 與 denominator 可從 code-as-run 重現，而不是只依敘事。
目前狀態：chaos timestamp key 不一致仍是執行前 blocker。

## 十六、結論

截至 2026-08-04 08:36:04 +08:00，最可靠的答案仍是：「在本 Ceph v19.2.2、Azure single-NIC、固定 capacity 環境的 steady workload 下，沒有觀察到超過事前實務門檻與實測 noise 的 profile 差異；這不是 formal equivalence proof。」
目前已 finalized 且納入分析的 fault attempts 確實出現營運上重要的 20–28 秒 stall，以及少數跨 margin 的 mean gaps；chaos 與未完成 replicates 不在這個分母內。
但 4 個跨 margin comparisons 都是 n=2、replicate 範圍重疊，無法形成 robust profile ranking。
TTR 也沒有任何 pair 跨過事前 margin。
因此目前維持 `balanced` 作為一般預設，是證據最一致、變更風險最低的決策。
`high_client_ops` 在 OSD down + 4K extreme 的 post-clean throughput 可保留為明確的 follow-up 假說，但不是 production 切換候選。
該訊號仍須事前註冊 follow-up，再以 r3、audit 與 dataset seal 檢查，才可能升級。
最先應進行的是 PG no-progress、slow ops、systemd start-limit 與 20 秒級 stall 的告警／staging 驗證；production 門檻仍須依 §12 的升級條件核准。
這些防護處理已觀察到的 fault severity，不應被包裝成 profile 已定案。
final report 的責任，是完成剩餘 replicate、人工裁定、audit、evidence sealing、實際成本與 teardown。
