# 使用 blackbox-exporter 偵測 Ceph MON 多數失聯：方案設計與真機驗證報告

> 報告日期：2026-07-14｜真機實驗日期：2026-07-08
>
> 適用範圍：固定 3-MON Ceph cluster；目標是偵測「從監控位置只能連到 0 或 1 顆 MON」
>
> 版本錨點：Ceph v19.2.3（commit `c92aebb`）、Prometheus v2.53.0、blackbox-exporter v0.25.0
>
> 原始證據：[`results/mon-quorum-2down-20260708T154019Z/`](./results/mon-quorum-2down-20260708T154019Z/)
>
> 現有 artifact：[`manifests/monitoring.yaml`](./manifests/monitoring.yaml)、[`rules/ceph-mon-quorum-blackbox.yml`](./rules/ceph-mon-quorum-blackbox.yml)、[`tests/mon-quorum-blackbox.test.yml`](./tests/mon-quorum-blackbox.test.yml)

---

## 閱讀前先認識十個詞

| 詞彙 | 白話意思 |
|---|---|
| MON | Ceph monitor daemon，負責維護 cluster map、認證與一致性狀態；3 顆至少要 2 顆互相同意 |
| mgr | Ceph manager daemon；Prometheus 平常從它取得 Ceph metrics |
| endpoint | 這裡指一顆 MON 對外提供的 TCP 位址與 port |
| blackbox-exporter | 從 Ceph mgr 路徑之外主動連線指定 endpoint，將成功或失敗轉成 Prometheus metric 的標準元件 |
| probe location | blackbox-exporter 發起連線時所在的網路位置；不同位置可能看到不同結果 |
| stale telemetry | 監控 HTTP 還有回應，但內容停在故障前的舊值 |
| shadow mode | 先收集告警結果但不通知值班人員，用來找誤報、漏報與門檻問題 |
| pager | 會立即通知值班人員、要求處理的 critical 告警通道 |
| target coverage | 預期監控的三顆 MON 是否每一顆都有被設定並產生 scrape 結果 |
| dynamic majority | 依目前觀察到的 metric series 數自動計算多數門檻；target 遺漏時可能把錯誤設定當成 MON 縮容 |

## 0. 先講結論

### 給主管的一句話

**建議核准 blackbox-exporter 的兩階段工作：先完成監控語意與部署硬化，再進行 14 天只觀察、不通知值班人員的 shadow mode。一次受控真機實驗支持它能補上「2/3 MON daemon 停止、mgr metrics 卻仍顯示健康」的盲區，足以進入 shadow 驗證；目前 artifact 仍是實驗原型，不能直接升級為 pager。**

### 這份報告回答什麼

我們原本用 Ceph mgr 匯出的 `ceph_mon_quorum_status` 判斷 quorum。真機停止 3 顆 MON 中的 2 顆後，quorum 已不可能成立，但 active mgr 的 Prometheus endpoint 仍可被 scrape。從注入起始標記到 +156 秒的每一份保存快照，都仍回報三顆 MON 在 quorum，也都沒有看到既有告警 pending 或 firing。這些是離散快照；注入標記又早於兩次遠端 stop，因此 156 秒不能解讀成完整 2-down 狀態的精確持續時間。

同一時間，從 Ceph mgr 之外部署的 blackbox-exporter 對三顆 MON 的 msgr2 TCP port（3300）逐一探測，正確看到只有 1 顆可達。注入起始後 6 秒保存的第一份快照已顯示告警 pending；注入起始後 47 秒保存的快照已顯示 firing。

這證明兩件事：

1. 現有 mgr-based rule（以 mgr metric 判斷的告警）存在真實盲區；單靠重排現有 quorum metric 與 `up` 的 PromQL 無法修正。若要沿 mgr 路徑偵測資料新鮮度，仍需另找並驗證可靠訊號。
2. blackbox-exporter 能提供不同於 mgr 的獨立觀測路徑，補上「多數 MON endpoint 已不可達」這一類故障。

但要先把語意說準：**TCP connect 成功只代表從某個 probe location 能連到 MON port，不等於該 MON 已加入 quorum。** 因此正式告警應命名為 `CephMonEndpointMajorityUnreachable`，而不是宣稱已確認 `QuorumLost`。

### 建議決策

| 決策項目 | 建議 | 理由 |
|---|---|---|
| 是否採用 blackbox-exporter | **採用，先進 shadow mode** | 單次受控真機實驗支持它能補 mgr stale telemetry 盲區 |
| 是否直接套用目前 manifest | **否** | 目前是單 replica、靜態 IP、無 Alertmanager、無 cluster 分組的 lab harness |
| 是否取代 mgr-based rule | **否** | TCP 可達性與 quorum membership 是不同訊號，兩者互補 |
| 是否採用 dynamic majority | **暫不採用** | 以「目前看得到的 series 數」當分母，設定漏 target 時會縮小 majority 並漏報 |
| 何時接 pager | 補齊 §10 的四個 gate 後 | 避免 exporter failure 冒充 Ceph quorum failure，並證明通知真的送達 |

### 這次請主管核准的工作包

以下是規劃估算，不是實驗量測值：

| 項目 | 建議 |
|---|---|
| 範圍 | 先在現有 Ceph lab 完成規則硬化與演練，再選 1 個固定 3-MON production cluster 進 shadow mode；本次不核准直接接 pager |
| Owner | Observability／SRE 1 人主責規則、部署與 Alertmanager；Ceph owner 1 人 review inventory、runbook 與受控演練 |
| 粗估投入 | 合計 3～5 engineer-days，分散在約 2 個日曆週；不含組織本身的 change approval 等待時間 |
| 時程 | D0 核准；D+3 完成硬化與 lab gate；D+4～D+17 shadow；D+18 提交 go／no-go 報告 |
| Shadow 期限 | 固定 14 天，且至少涵蓋一次正常 MON 維護；若期間沒有維護，需補 lab 演練，不能只等時間到 |
| 未通過時 | 不接 pager；修正原因後重新累積至少連續 7 天 shadow evidence，再提下一次 go／no-go |

主管現在核准的是「投入上述人力，把 prototype 推進到可判斷是否接 pager 的狀態」，不是核准目前 manifest 直接上 production。

趕時間時，讀完本節，再看 §6「真機結果」、§8「正式環境設計」與 §10「導入計畫」即可。

---

## 1. 必要背景：MON、quorum 與為什麼 workload 沒報錯仍然危險

### 1.1 3-MON cluster 的 majority

Ceph MON 維護 cluster map、認證與一致性狀態。先看 Ceph 的真實狀態：3 顆 MON 要至少 2 顆實際參與並互相同意，才能形成 majority quorum。

| 實際參與 quorum 的 MON | Ceph 真實狀態 |
|---:|---|
| 3/3 | 正常 |
| 2/3 | 還有 quorum，但失去容錯餘裕 |
| 1/3 或 0/3 | 無法形成 majority |

blackbox 看到的是另一件事：某個特定網路位置能不能連到 MON endpoint。它不能直接推出上表的真實 quorum 狀態。

| 單一 probe location 所見可達數 | blackbox 告警可以宣稱的內容 |
|---:|---|
| 3/3 | 從此位置三顆 endpoint 都可達；不代表三顆都在 quorum |
| 2/3 | 從此位置有一顆 endpoint 不可達；不宣稱 quorum lost |
| 1/3 或 0/3 | 從此位置無法接觸 majority，疑似 quorum loss，需立刻用權威狀態確認 |

因此本文要解決的精確問題是：固定 3-MON topology 中，如何監控「從必要 probe location 只能連到 1 顆或 0 顆 MON」，並把它當成真實 quorum loss 的高風險 proxy，而不是直接當成 quorum truth。

### 1.2 quorum loss 不一定讓既有 I/O 立即停止

Ceph client 取得 map 並建立 session 後，資料面可直接與 OSD 溝通。只要 OSD 與既有 map 沒有改變，已建立 RBD mapping 的 workload 可能仍能讀寫，讓值班人員誤以為 cluster 正常。

本次故障窗內，已完成 mount 的 fio Pod 仍完成 8 組讀寫：隨機讀、隨機寫、循序讀、循序寫，各跑 1 與 4 thread，全部 `rc=0`。這只證明「既有 mapping 在本次故障窗內仍可用」，**不是效能等價性測試**，也不能外推成所有既有 workload 都永遠不受影響。

相對地，故障窗內新建的 PVC 已 `Bound`，但新 Pod 維持 `ContainerCreating` 105 秒，最後保存的 event 是 `SuccessfulAttachVolume`。結果與 attach 後的 map／mount 階段無法完成一致，但本次沒有保存足以把阻塞精確定位到單一 kernel `rbd map` 呼叫的 CSI 或 kubelet log。

對維運的含意很直接：

- 不可用「目前應用程式還有 I/O」推論 MON quorum 健康。
- quorum 疑似失守期間，不要主動 drain node、重排 Pod、擴容或重新部署；這些動作可能把仍能工作的既有 mapping 轉成需要新連線的 mapping。
- 必須有一條不依賴 workload 自己報錯的主動監控路徑。

---

## 2. 原有監控為什麼失明

### 2.1 原有規則

既有規則以 mgr 匯出的 `ceph_mon_quorum_status` 計算仍在 quorum 的 MON 數：

```promql
(count(ceph_mon_quorum_status == 1) or vector(0)) < 2
```

`or vector(0)` 解決的是「series 全部消失」：沒有 sample 時讓計算退回 0，避免最壞情況反而算不出結果。它無法處理「series 仍存在，但內容停在最後一次健康值」。

### 2.2 metric 的資料來源

Ceph v19.2.3 的 mgr Prometheus module 在 [`module.py:1018-1033`](../../ceph/src/pybind/mgr/prometheus/module.py#L1018) 從 `self.get('mon_status')` 取得 MON 狀態，再依每顆 MON 的 rank 是否位於 `mon_status['quorum']` 設定 `ceph_mon_quorum_status`：

```python
def get_quorum_status(self) -> None:
    mon_status = json.loads(self.get('mon_status')['json'])
    for mon in mon_status['monmap']['mons']:
        rank = mon['rank']
        id_ = mon['name']
        in_quorum = int(rank in mon_status['quorum'])
        self.metrics['mon_quorum_status'].set(in_quorum, (
            'mon.{}'.format(id_),
        ))
```

原始碼能證明 metric 是從 mgr 所見的 `mon_status` 產生；真機實驗則顯示，從注入標記到 +156 秒的每一份保存快照，mgr 所匯出的這份 view 都沒有反映兩顆 MON 已停止。把現象與機制分開來說：

- **實測事實**：上述每份保存快照都能 scrape active mgr endpoint，`ceph_mon_quorum_status` 三條 series 也都維持 1；這些是離散快照，不是完整 range evidence。
- **機制解釋**：mgr 在失去有效 quorum view 後仍提供最後已知狀態，因此 Prometheus 讀到 stale telemetry。

### 2.3 這不是單次偶發

2026-07-04 的前一輪 real-lab 也觀察到相同行為：停掉兩顆 MON 後，`sum(ceph_mon_quorum_status)` 仍為 3；只有進一步停止 active mgr、讓 exporter series 變空，既有規則才靠 `or vector(0)` firing。證據索引在：

- [`../ceph-alert-real-lab/EVIDENCE-SUMMARY-2026-07-04.md`](../ceph-alert-real-lab/EVIDENCE-SUMMARY-2026-07-04.md)
- [`../ceph-alert-real-lab/EVIDENCE-INDEX-2026-07.md`](../ceph-alert-real-lab/EVIDENCE-INDEX-2026-07.md)

### 2.4 問題不是公式，而是共同故障域

```text
Prometheus ──scrape──> active mgr ──cluster view──> MON quorum
                           │
                           └─ quorum view 失去更新後，仍可回傳最後狀態
```

我們正用「需要 MON quorum 才能持續更新 cluster view 的元件」監控 MON quorum 本身。當 sensor 與被監控對象共用相同故障域時，再精巧的 PromQL 也無法辨識一份內容錯誤、HTTP 卻持續成功的資料。

眼前可驗證的修正方向不是繼續重排同兩個 mgr 訊號，而是新增一條不經 mgr 的觀測路徑；mgr freshness detection 仍可作為後續互補研究。

---

## 3. blackbox-exporter 在這個方案中扮演什麼角色

blackbox-exporter 使用 `tcp_connect` module，從監控所在位置對每顆 MON 的 msgr2 TCP port 執行連線測試。實驗使用 port 3300；正式環境應從實際 monmap 或受控 inventory 取得位址與 port，不應盲目假設所有 cluster 都相同。

```text
                         ┌──────────────> MON 1 :3300
Prometheus ──HTTP────> blackbox-exporter ─────────> MON 2 :3300
                         └──────────────> MON 3 :3300

Prometheus ──HTTP────> Ceph active mgr :9283
```

兩條觀測路徑回答不同問題：

| 訊號 | 回答的問題 | 優勢 | 看不到的情境 |
|---|---|---|---|
| mgr `ceph_mon_quorum_status` | mgr 最近所見的 MON 是否在 quorum | 有 quorum membership 語意 | mgr view 凍結時會說舊狀態 |
| blackbox `probe_success` | 從指定 probe location 能否 TCP connect 到 MON endpoint | 不依賴 mgr，逐顆獨立 | port 開著但 MON 沒進 quorum；MON 彼此 partition；probe location 自己的網路問題 |

所以 blackbox-exporter 是 **MON majority reachability proxy**，不是 quorum truth。正式告警摘要應寫：

> 從 `<probe_location>` 無法連到 3 顆中的至少 2 顆 MON endpoint，疑似 quorum loss，請立即確認 probe 取得鏈路、網路與實際 quorum 狀態。

不應寫成：

> Ceph quorum 已確認失守。

---

## 4. 實驗前提與可信度防線

### 4.1 受測環境

| 項目 | 本次設定 |
|---|---|
| Ceph | v19.2.3，commit `c92aebb`，cephadm |
| Ceph topology | 3 MON、9 OSD、2 pool、33 PG |
| Kubernetes | k0s v1.36 單節點，Rook external，RBD CSI |
| Prometheus | v2.53.0，單 replica，scrape 5 秒，rule evaluation 5 秒 |
| blackbox-exporter | v0.25.0，單 replica，TCP timeout 3 秒 |
| probe targets | `192.168.18.166:3300`、`.167:3300`、`.164:3300` |
| 故障注入 | 依序停止 mon-02、mon-03 的 systemd unit，留下 mon-01 與 active mgr |
| 主要觀察窗 | 2026-07-08 15:40:22Z 至 15:42:58Z，約 156 秒 |

實驗前的 cluster 不是 `HEALTH_OK`，而是已有 BlueStore slow-op 與 cephadm host check 的 `HEALTH_WARN`；但當時 3 顆 MON 都在 quorum、9/9 OSD up/in、33 PG `active+clean`。rollback 後腳本會執行 postcheck；符合 3-MON quorum 且非 `HEALTH_ERR` 時印出 OK，否則要求人工檢查，但目前不會以非零 exit code 強制 gate。本次保存的 postcheck 已人工確認 3-MON quorum、9 OSD up/in 與 33 PG `active+clean`。

### 4.2 事前寫定的預測

| 候選 | 事前預測 |
|---|---|
| mgr quorum metric | 會維持最後健康值 3，既有告警不會 pending/firing |
| mgr `up` | active mgr 仍可 scrape，`up=1` |
| blackbox TCP probe | 兩顆停止的 MON 回 `probe_success=0`，成功數由 3 降到 1 |
| node_exporter systemd | 理論上可看見兩顆 unit inactive，但需要逐台部署 agent |
| per-host ceph-exporter | 需要額外驗證其能否提供可靠 quorum 語意，不先假設可行 |

### 4.3 安全與證據保存

- 故障腳本採 `inject → observe → collect → rollback → postcheck`。
- 腳本對正常 `EXIT`、`INT`、`TERM` 註冊 rollback handler；本次正式 run 的 `EXIT` rollback 成功。這不是不可失敗的安全保證：`SIGKILL`、主機故障無法觸發 trap，且 signal handler 後續應硬化為 rollback 完即明確 exit。
- 預檢要求三顆 MON 都在 quorum，blackbox 成功數為 3，且 cluster 不是 `HEALTH_ERR`。
- 注入後保存每個 Prometheus snapshot、兩顆 MON 的 systemd state、fio 結果、新 Pod 狀態與 rollback 後 `ceph -s`。
- 第一次嘗試在注入前中止，沒有留下正式故障 evidence；本報告的所有結論只採用 `T154019Z` run。

### 4.4 證據等級

| 情境 | 證據等級 |
|---|---|
| 停止 2/3 MON daemon | **真機執行** |
| mgr stale、blackbox 只剩 1/3 可達 | **真機觀察** |
| Prometheus alert pending → firing | **真機觀察** |
| 3/3 MON endpoint 不可達 | promtool synthetic test |
| probe scrape pipeline unavailable | promtool synthetic test；輸入為三條 `up=0`，未做真實 process failure |
| Alertmanager routing 與 receiver 送達 | **未驗證**；本次 manifest 沒有 Alertmanager |
| MON 間 network partition、port 開但不在 quorum | **未驗證** |

---

## 5. 候選方案總覽：規劃 6 個，在同一真機故障窗比較 4 種訊號，2 個裁定不部署

✅＝預測命中；❌＝預測被推翻；➖＝未取得足夠證據。

本節是主管快速對帳表；§6.3 保留固定五欄的稽核細節，技術同事需要追問 prediction 與 recommendation 時再讀。

| 候選方案 | 調整或觀察的訊號 | 為什麼測 | 事前預期 | 結果 |
|---|---|---|---|---|
| mgr quorum metric | `ceph_mon_quorum_status` | 現行主告警，必須先重現盲區 | 故障後仍回 3 | ✅ 注入標記至 +156 秒的每份保存快照都為 3；未看到告警 pending |
| mgr staleness／存活 | mgr `up` 與 quorum metric 是否變化 | 判斷能否不加 exporter、只抓凍結 | `up=1`、quorum metric 不變 | ✅ 觀察到這組合；➖ 沒找到並驗證可靠 ticking metric |
| blackbox TCP probe | 三個 MON `:3300` 的 `probe_success` | 建立不經 mgr 的逐 MON 訊號 | 成功數 3→1，告警 firing | ✅ 第一份故障快照已 1 且 pending；47 秒快照已 firing |
| Prometheus `up` only | `up{job="ceph"}` | 驗證 exporter-alive 能否代理 quorum | active mgr 還活著，因此會漏報 | ✅ 每份保存快照都 `up=1`，不可作 quorum 訊號 |
| node_exporter systemd | 每台 MON host 的 unit state | process-level 外部訊號 | 理論上可辨識停止的 daemon | 未部署：需每台 agent、DBus 權限與額外維護 |
| per-host ceph-exporter | 每台 host 的 local Ceph 訊號 | 評估更接近 daemon 的觀測 | 高不確定，需先驗證匯出內容 | 未部署：目前沒有證據證明它能提供 `ceph_mon_quorum_status` |

記帳：6 個候選 = 4 個在真機故障窗內觀察 + 2 個基於部署成本與證據缺口未部署。沒有把未執行的候選包裝成已驗證方案。

---

## 6. 真機結果

### 6.1 Ground truth

正式 run 的注入時間記錄為 `2026-07-08T15:40:22Z`。mon-02 與 mon-03 停止後，保存的 systemd state 都是 `inactive`。在固定 3-MON topology 裡只剩 mon-01，無法形成 majority；這是本次主要 ground truth。

故障窗內有界執行 `ceph -s` 沒有產生保存輸出；這與 CLI 等待 quorum 的預期一致，但因沒有保存 exit code，不能單獨證明原因。rollback 後的 `ceph -s` 出現 `748 slow ops ... mon.ceph-lab-mon-01 has slow ops`，可作為剩餘 MON 無法處理請求的間接佐證，但不是主要 ground truth。

### 6.2 實際時序

腳本檔名使用 `t+03s`、`t+10s`、`t+30s` 作為觀察點名稱；這些不是精確 wall-clock，因為兩次遠端 stop、Prometheus query 與一次有界 `ceph -s` 都會耗時。下表改用檔案內保存的 UTC 時戳與注入時間計算：

| 保存點 | UTC | 相對注入起始 | mgr quorum count | blackbox 成功數 | mgr `up` | blackbox scrape `up` 總數 | blackbox alert |
|---|---:|---:|---:|---:|---:|---:|---|
| baseline | 15:40:20 | 注入前 | 3 | 3 | 1 | 3 | 無 |
| 第一份故障快照 | 15:40:28 | +6 秒 | **3，stale** | **1** | 1 | 3 | pending |
| 第二份故障快照 | 15:40:37 | +15 秒 | **3，stale** | **1** | 1 | 3 | pending |
| 第一份保存的 firing 快照 | 15:41:09 | +47 秒 | **3，stale** | **1** | 1 | 3 | firing |
| fio 後 | 15:42:55 | +153 秒 | **3，stale** | **1** | 1 | 3 | firing |
| window final | 15:42:58 | +156 秒 | **3，stale** | **1** | 1 | 3 | firing |

可以安全承諾的是：

- 注入後第一份保存快照（+6 秒）已看到 1/3 endpoint 可達，且告警已 pending。
- 設定 `for: 30s`；第一份保存的 firing 快照在注入起始後 47 秒。
- 每份故障快照的三個 blackbox synthetic scrape 都是 `up=1`，可區分「blackbox 成功執行 probe、兩顆 MON connect 失敗」與「blackbox scrape 本身失敗」。
- 從注入標記至 +156 秒的每份保存快照，都沒有看到既有 mgr-based rule pending；這不是連續 range evidence。
- 本實驗沒有 Alertmanager，不能把 Prometheus firing 時間說成 pager 送達時間。

### 6.3 各方案五欄判定（稽核細節；主管可直接跳至 §6.4）

#### mgr quorum metric —— 盲區重現

- **調整／注入**：停止 2/3 MON，持續 scrape active mgr 的 `ceph_mon_quorum_status`。
- **為什麼測**：這是現行 `CephMonQuorumLost` 的資料來源。
- **事前預期**：mgr view 維持最後健康值 3，告警不會進入 pending。
- **結果**：baseline 3→各故障快照仍為 3（×1.0，完全沒有反映兩顆 unit 已 inactive）；注入標記至 +156 秒的每份保存快照都沒有看到告警 pending 或 firing。
- **建議**：保留作 quorum membership 的互補訊號，但不可單獨承擔真實 quorum-loss pager。

#### mgr staleness／`up` —— 只能證明 HTTP 還活著

- **調整／注入**：觀察 `up{job="ceph"}` 與 quorum metric 是否變化。
- **為什麼測**：希望在不加新 exporter 的情況下找出 sensor freeze。
- **事前預期**：mgr endpoint 仍可 scrape，`up=1`；quorum metric 不變。
- **結果**：每份保存快照都是 `up=1`、quorum count=3。原假說還要求找出可靠的 ticking metric 並以 `changes()` 驗證，本次沒有完成這部分。
- **建議**：`up` 只能監控 exporter HTTP availability；不要用它代理 MON 或 quorum。mgr staleness detection 留在後續研究，不列為已否定或已完成的方案。

#### blackbox TCP probe —— 本次唯一部署並真機命中的外部 Prometheus 候選訊號

- **調整／注入**：從 k0s node 上的 blackbox-exporter 對三顆 MON `:3300` 執行 TCP connect。
- **為什麼測**：建立不依賴 mgr、又不需要每台 MON host 安裝 agent 的觀測路徑。
- **事前預期**：兩顆停止的 MON 回 0，成功數由 3 降到 1；固定 3-MON threshold `<2` 成立。
- **結果**：成功數 3→1（−67%）；+6 秒保存快照 pending，+47 秒保存快照 firing；mgr 同時仍回 3。
- **建議**：採用為「MON endpoint majority unreachable」主訊號；與 mgr rule 互補，先 shadow，再接 pager。

#### Prometheus `up` only —— 負向對照

- **調整／注入**：只看 mgr scrape 的 `up`。
- **為什麼測**：確認 exporter availability 是否能間接反映 quorum。
- **事前預期**：MON daemon 停止不會讓 active mgr process 立即停止，`up` 會維持 1。
- **結果**：所有保存快照都是 1→1（×1.0），完全漏報。
- **建議**：只用於「mgr exporter 是否可被 scrape」，不可推論 cluster control-plane 健康。

#### node_exporter systemd —— 可行但未部署

- **調整／注入**：原計畫讀取各 MON host 的 systemd unit state。
- **為什麼測**：直接觀察 daemon process，避開 mgr view。
- **事前預期**：兩顆停止的 MON 會顯示 inactive。
- **結果**：實驗以 SSH 直接保存 systemd state 證明 ground truth，但沒有部署 node_exporter systemd collector，也沒有量測 Prometheus rule。
- **建議**：若組織本來就有完整 node_exporter systemd coverage，可作 process-level 補強；不要把它列為本次已驗證的 Prometheus 方案。

#### per-host ceph-exporter —— 尚無足夠證據

- **調整／注入**：原計畫在每台 MON host 建立 local Ceph metric source。
- **為什麼測**：希望取得比 TCP port 更接近 MON daemon 狀態的訊號。
- **事前預期**：屬高不確定假說，需確認實際匯出的 metric 與 failure semantics。
- **結果**：未部署；現有 evidence 無法證明 per-host ceph-exporter 會提供可靠的 `ceph_mon_quorum_status`。
- **建議**：保留為研究 backlog，不應在主管報告中宣稱它能補上「port 開但未進 quorum」。

### 6.4 rollback 結果

scenario 的 `trap` 重新啟動 mon-02 與 mon-03。保存的 postcheck 顯示：

- 3 顆 MON 已恢復 quorum，quorum age 3 秒。
- 9 OSD up/in。
- 33 PG `active+clean`。
- 整體仍是 `HEALTH_WARN`，且該份 postcheck 仍包含 `748` 個 MON slow ops；不是 `HEALTH_OK`，也沒有後續 evidence 證明 slow ops 已清除。

rollback 最多每 3 秒查詢一次 blackbox 成功數，共 40 次；看到 3 會提早結束，但即使輪詢用完也會繼續 postcheck。console poll 沒有保存進 evidence bundle，最終恢復以 postcheck 的 3-MON quorum 為準，本報告不宣稱「幾個 scrape 內恢復」。

---

## 7. 證據邊界：這個方案能證明什麼、機制上不能證明什麼

### 單次受控真機實驗支持的結論

1. 固定 3-MON lab 停止 2 顆 MON daemon 時，active mgr endpoint 仍可 scrape；從注入標記至 +156 秒的每一份保存快照，mgr-based quorum metric 都仍回報最後健康值。
2. 從 Ceph mgr 之外對每顆 MON 執行 TCP probe，能在同一故障窗看見 1/3 可達，補上 stale mgr view 的盲區。
3. 固定 threshold `<2` 的 blackbox rule 可由 pending 進入 firing，且 promtool 可重現「mgr 版盲、blackbox 版 firing」的對照。
4. 已建立 RBD mapping 的 Pod 在故障窗內仍完成所有測試讀寫，因此不能依賴既有 workload 自己暴露 MON 故障。

### 本方案在機制上不能單獨證明

1. TCP 可達等於 MON 在 quorum。
2. 多個 MON 都接受 TCP 時，MON 彼此一定能形成 quorum。
3. 單一 probe location 的結果代表所有 client 網路位置。

這三項不是「多做幾次相同實驗」就能變成真；它們需要 mgr、MON log、admin socket 或另一個獨立網路位置補足語意。

### 尚待驗證

1. probe scrape pipeline unavailable 時，正式規則能正確分類且不冒充 MON failure。
2. 多 cluster、多 probe location 的 PromQL 分組正確。
3. Alertmanager routing、grouping、inhibition 與 receiver 已送達。
4. 3/3 MON down 的真機行為；目前只有 promtool synthetic test。
5. 新 Pod 的阻塞已精確定位到某一個 kernel call；現有 evidence 只到 `SuccessfulAttachVolume` 後持續 `ContainerCreating`。

因此目前方案的成熟度是：**單次受控真機實驗支持核心方向，足以進 shadow 驗證；不能把 lab manifest 原封不動稱為 production-ready。**

---

## 8. 正式環境建議設計

### 8.1 告警語意分成三層

#### 第一層：單顆 endpoint 不可達

建議名稱：`CephMonEndpointUnreachable`

用途：告知某一顆 MON 從特定 probe location 不可達，但 3-MON cluster 仍可能維持 2/3 quorum。保留 `cluster`、`mon`、`probe_location` label，方便定位與 silence。

#### 第二層：多數 endpoint 不可達

建議名稱：`CephMonEndpointMajorityUnreachable`

用途：同一 `cluster`、同一 `probe_location` 下，固定 3 個預期 target 中少於 2 個成功。severity 為 critical，但 annotation 必須寫「quorum loss suspected」，不可宣稱已確認 quorum lost。

#### 第三層：probe 取得鏈路失明

建議名稱：`CephMonProbeAcquisitionBlind`

用途：blackbox-exporter、Prometheus 到 exporter 的 scrape 或 expected target coverage 不完整。這不是 Ceph 故障，卻代表最重要的外部觀測已失效，應獨立告警。

這條規則無法監控「執行它的 Prometheus 自己全滅」或「Alertmanager／receiver 沒送達」。整條通知鏈還需要 Prometheus／Alertmanager HA、監控系統外的 Watchdog／dead-man 通知，以及 receiver delivery freshness 檢查。

### 8.2 監控語意正確性的三個 blocker

#### 語意 blocker 1：依 cluster 與 probe location 分組

現行 expression 是全域 `count(...)`，target 只有 `mon_addr`。如果同一個 Prometheus 監控兩個 Ceph cluster，健康 cluster 的成功 probe 會替故障 cluster「灌票」，造成漏報。

正式 target 至少要帶：

```yaml
labels:
  cluster: ceph-prod-a
  mon: mon-01
  probe_location: monitoring-zone-a
```

所有計數都必須依 `cluster, probe_location` 分組；不同 probe location 的成功數不能直接相加。

#### 語意 blocker 2：probe acquisition failure 不可冒充 Ceph failure

現行固定版使用 `or vector(0)`。只要 blackbox process、Service、DNS、routing 或 Prometheus 到 exporter 的 scrape path 使 `probe_success` 全 absent，主要規則就會在 30 秒後發出 critical；現有 guard 卻要 2 分鐘才 warning。這會先告訴值班人員「Ceph quorum lost」，真正原因甚至可能從未達到 guard 的 hold time。

正式規則必須：

- 只有 expected target coverage 完整、blackbox scrape healthy 時，才評估 MON endpoint majority。
- exporter、scrape 或 target coverage 不完整時，只發 `CephMonProbeAcquisitionBlind`。
- 為兩種情境加入互斥的 promtool case，證明 probe acquisition unavailable 不會同時冒充 MON majority unreachable。

#### 語意 blocker 3：不用 observed series 自動推導 MON 總數

prototype 的 dynamic rule 使用 `count(probe_success)` 當 MON 總數。這只在所有 target 都正確存在時成立；若設定誤刪兩顆 target，分母會縮成 1，唯一成功的 target 反而被判為健康。

本次固定 3-MON cluster 應使用受控 inventory 的 expected count=3。若未來需要支援 5 或 7 顆 MON，應從版本化 inventory 或經驗證的 monmap 同步流程取得預期集合，不能從「目前恰好看得到的 series」反推。

### 8.3 部署與維運成熟度的 blocker

實驗 manifest 的 blackbox-exporter 與 Prometheus 都是單 replica，沒有 readiness／liveness probe、resource requests／limits、PDB、anti-affinity，也沒有 Alertmanager；Prometheus 透過 NodePort 暴露，MON IP 靜態寫死。這些選擇適合 lab，不適合直接搬到正式環境。

正式環境建議：

- 整合既有 Prometheus 與 Alertmanager，不另外建立孤立的單機 Prometheus。
- Prometheus／Alertmanager 採 HA，另由監控系統外的 Watchdog 驗證通知鏈仍活著。
- 每一個 logical `probe_location` 內可放多個 blackbox-exporter replica 做 component HA；Prometheus 對該 location 的固定 Service／endpoint 每顆 MON 只建立一條 probe series，避免 replica 被重複計數。
- 同一 `probe_location` 的 replica 必須具有等價且可預期的網路出口。若網路觀點不同，就不能藏在同一個隨機負載平衡 Service 後面再共用同一 label。
- 不同網路觀點使用可識別的獨立 Service／endpoint、獨立 scrape job 與不同 `probe_location` label，各自計算，不混加成功數。多 replica HA 不等於多個網路觀測點。
- 透過 kube-state-metrics 或等價方式監控 Deployment 可用 replica；所有 replica 或 Service endpoint 不可用時，MON majority expression 必須被當下 acquisition health 直接 gate，改發 acquisition blind。
- 使用受控 inventory 產生 target；設定變更要有 code review、reload success 與 target coverage 檢查。
- 限制 `/probe` 可探測的目標與網路存取，避免它成為任意內網掃描入口。
- 允許監控網路到每顆 MON 的實際 msgr2 port。
- 若 client 分布跨網段，至少選一個能代表關鍵 control-plane client 路徑的 probe location；高要求環境再加第二個獨立位置。

### 8.4 建議起始參數

| 參數 | 起始建議 | 依據與條件 |
|---|---|---|
| 固定 inventory | 3 個 MON target | 本研究只驗證固定 3-MON topology |
| majority threshold | 成功數 `<2` | 3-MON 的 majority 為 2 |
| probe module | `tcp_connect` | 單次真機實驗支持 daemon stop 時會反映 endpoint 不可達 |
| TCP timeout | 3 秒 | lab 設定；shadow 期間依正常 RTT 與 timeout rate 調整 |
| scrape interval | 5 秒 | lab 已驗證；三個 target 的成本低，quorum 風險需要快速訊號 |
| critical hold | 30 秒 | lab 設定；+47 秒保存快照已確認 firing |
| target coverage gate | 當下必須完整 | majority expression 直接以 acquisition health 與 expected coverage gate；`for:` 只負責節流，不能建立互斥語意 |
| mgr-based rule | 保留 | 補 TCP 可達但 mgr view 顯示不在 quorum 的情境 |

這些是 shadow rollout 的起始值，不是跨環境保證。正式 pager 門檻需經至少一個正常維護週期與受控演練確認。

---

## 9. 值班 runbook

### 9.1 收到告警後的前五分鐘

1. **先看 probe 取得鏈路是否健康。** 若 `CephMonProbeAcquisitionBlind` 同時 firing，不得由它判定 Ceph 故障或健康；一邊恢復 exporter、scrape 或 target coverage，一邊透過 host、MON log、其他 probe location 或有界 Ceph CLI 獨立確認 cluster。probe 失明與真 MON 故障可能同時發生。
2. **列出失敗的 target 與 probe location。** 確認是同一 cluster 的哪幾顆 MON 回 `probe_success=0`。
3. **比較第二個觀測來源。** 查看 mgr-based `ceph_mon_quorum_status`、其他 probe location、host reachability 與 MON process 狀態；注意 mgr metric 可能 stale，不能因它顯示 3 就結案。
4. **所有 Ceph CLI 都加有界 timeout。** quorum 疑似失守時 `ceph -s` 可能長時間等待，不要讓值班流程卡死。
5. **停止擴大變更。** 暫停 drain、Pod 重排、HPA 擴容、新部署與同時重啟多顆 MON。

### 9.2 區分三類故障

| 觀察 | 較可能的原因 | 下一步 |
|---|---|---|
| 只有一顆 MON 從所有位置不可達 | daemon／host 故障 | 檢查該 host 與 systemd／cephadm 狀態；quorum 通常仍在 |
| 兩顆 MON 從所有必要位置不可達 | 多 daemon／host failure，疑似 quorum loss | 先用 host／daemon ground truth 與權威狀態確認；若確認實際只剩一顆，再依 §9.3 恢復一顆 |
| 只有某個 probe location 看不到多顆 MON | probe 所在網段、防火牆或 routing 問題 | 比對另一位置，不要直接重啟 MON |
| TCP 全可達，但 mgr 顯示 MON 不在 quorum 或 CLI 無法取得 quorum | election／MON 間 partition／daemon 卡住 | TCP probe 不足，轉查 MON log、admin socket 與網路 |

### 9.3 恢復原則

- 只有在 host／daemon ground truth 與權威檢查確認實際只剩一顆 MON 後，才進入 MON 恢復流程；不能從 blackbox 可達數直接推導真實 1/3。
- 排除原故障原因後，優先重新啟動一顆先前正常停止、MON store 無已知損壞的 MON；不要重啟唯一仍工作的 MON。若 store 完整性有疑慮，不要自行重建，升級給 Ceph owner。
- 先排除時間、磁碟、網路與位址設定問題，再啟動 daemon。
- quorum 回來後再處理其他 daemon 或 workload 問題。

### 9.4 resolved 的條件

不能只看 blackbox alert 消失。結案前要同時確認：

- 至少 2 顆 endpoint 從必要 probe location 可達。
- `ceph quorum_status` 或等價的權威狀態確認 majority 已恢復。
- probe acquisition expected target coverage 完整。
- OSD、PG 與 cluster health 回到故障前基線。
- Alertmanager incident 已 resolved，沒有被錯誤 inhibition 或 silence。

---

## 10. 導入計畫與完成 gate

### Phase 1：規則與設定硬化

先完成：

- 加入 `cluster`、`mon`、`probe_location` label 與分組。
- 拆開 endpoint majority 與 probe acquisition blind。
- 固定 expected MON inventory=3，移除或停用 dynamic majority。
- 補 resource、health probe、HA、security 與設定 reload 檢查。

必須新增的測試：

- probe scrape pipeline unavailable：只發 acquisition blind，不發 MON majority unreachable。
- target 設定少一顆與少兩顆。
- 多 cluster，不得互相灌票。
- 多 probe location，不得混算。
- 單一 probe path partition。
- TCP 可達但 mgr 顯示未進 quorum。

### Phase 2：shadow mode

至少涵蓋一個正常 MON 維護週期，記錄：

- 每顆 MON 的 probe failure rate 與持續時間。
- 正常 probe duration 分布與 timeout。
- target coverage 與設定漂移。
- mgr-based 與 blackbox-based 訊號是否出現矛盾。

shadow 階段固定 14 天，不送 pager，只進 dashboard 或非緊急 channel。

### Shadow 與演練的量化 exit criteria

以下是建議的 go／no-go 門檻；它們是 rollout SLO，不是假裝成既有實驗結果：

| 項目 | Go 條件 |
|---|---|
| 觀察時間 | 連續 14 天，且涵蓋一次正常 MON 維護；否則補 lab 演練 |
| Target coverage | 三顆預期 MON 在每個必要 probe location 都是 100%；任何缺口都由 acquisition blind 指出 |
| Shadow 誤報 | 0 次錯誤的 majority critical；若發生，修正後重新累積至少連續 7 天 |
| 單顆維護 | 單顆 endpoint alert 可出現，但 majority critical 必須為 0 |
| 受控 2/3 daemon stop | 第一個失敗 metric 在 2 個 scrape interval 內出現（5 秒設定下 ≤10 秒）；Prometheus 在故障起始後 ≤60 秒 firing |
| Acquisition failure | 只發 acquisition blind；majority alert 必須 absent，不可兩條同時冒充 Ceph failure |
| 通知送達 | Prometheus firing 後 ≤30 秒到達 Alertmanager receiver；從故障起始到 receiver ≤90 秒 |
| Resolved | rollback 後 probe、權威 quorum、Alertmanager 與 receiver 都有 resolved evidence |
| Runbook | SRE 與 Ceph owner 各完成一次桌上推演並簽核 |

任何一項不通過就是 no-go：不接 pager、保留 shadow，修正後重新計時。D+18 的回報要逐項附證據，而不是只寫「測試成功」。

### Phase 3：受控演練

在 lab 或專用演練環境驗證：

1. 停一顆 MON：單顆告警應出現，majority critical 不應出現。
2. 再停第二顆：majority critical 應出現。
3. 停 blackbox-exporter：只能出現 acquisition blind。
4. 阻擋單一 probe location：告警必須指出 location，不得宣稱 cluster quorum 已失守。
5. 同時注入真 MON failure 與 probe acquisition blind，確認 runbook 不會因監控失明就假設 Ceph 健康。
6. 完整驗證 Alertmanager routing、grouping、inhibition 與 receiver 送達時間。
7. rollback 後確認 probe、quorum、OSD、PG 與通知都 resolved。

### Phase 4：升級 pager

四個必要 gate：

| Gate | 通過條件 |
|---|---|
| 語意正確 | 告警只宣稱 endpoint reachability；acquisition failure 不冒充 Ceph failure |
| 測試完整 | 單元、整合、故障演練涵蓋上述情境 |
| 通知閉環 | Alertmanager 到 receiver 的送達與 resolved 都有證據 |
| 操作就緒 | runbook、owner、dashboard、silence policy 與演練紀錄完成 |

全部通過後，才將 `CephMonEndpointMajorityUnreachable` 接 critical pager。

---

## 11. 本次實驗侷限與開放問題

機制上永遠存在的 TCP reachability 邊界已集中在 §7；這裡只列本次研究方法本身的限制：

- 只做一次 2/3 MON daemon stop 的正式 run，沒有重複輪次。
- 只驗證 3-MON topology。
- Prometheus 與 blackbox-exporter 都是單 replica。
- 沒有真實注入 blackbox-exporter failure。
- 沒有 Alertmanager。
- 沒有保存 recovery 的 Prometheus snapshot。
- `window-ceph-s-groundtruth.txt` 為空；主要 ground truth 是 3-MON topology 加兩顆 unit `inactive`。
- fio 只證明故障窗內能完成 I/O，不構成效能等價性結論。

### 開放問題

1. 如何取得可信、可版本化的 MON expected inventory，避免手動 target 漂移？
2. 是否需要兩個 probe location，分別代表監控平面與主要 client 網段？
3. TCP 可達但 election 卡住時，哪個外部訊號最可靠、部署成本可接受？
4. 是否能找到 mgr-independent、具有 quorum membership 語意的標準 exporter？目前沒有實驗證據支持 per-host ceph-exporter 能做到。
5. Alertmanager 應如何 grouping／inhibit endpoint、majority 與 acquisition 三層告警，避免告警風暴又不隱藏根因？

---

## 12. 最終建議

核准 §0 的 3～5 engineer-days 工作包：先修正監控語意與 acquisition guard，再完成 14 天 shadow、受控演練與 Alertmanager 閉環。固定 3-MON cluster 的判定維持：**同一 cluster、同一 probe location、固定 3 個預期 target 中，可達數少於 2。**

本次不核准目前 lab manifest 直接上 production，也不核准把 TCP reachability 命名為已確認 quorum loss。D+18 只有在 §10 所有量化 gate 都有 evidence 時才 go；否則維持 shadow、修正後重新累積至少 7 天。

這個決策的價值不是宣稱 blackbox-exporter 能說出 Ceph quorum 的全部真相，而是替已在真機重現的 mgr 觀測盲區建立第二個獨立觀點，讓值班人員在既有 workload 尚未報錯前就有機會介入。

---

## 附錄 A：目前實驗設定

### blackbox module

```yaml
modules:
  tcp_connect:
    prober: tcp
    timeout: 3s
    tcp:
      preferred_ip_protocol: ip4
```

### Prometheus probe job

```yaml
- job_name: mon-tcp
  scrape_interval: 5s
  metrics_path: /probe
  params:
    module: [tcp_connect]
  static_configs:
    - targets:
        - MON1:3300
        - MON2:3300
        - MON3:3300
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - source_labels: [__param_target]
      target_label: mon_addr
    - target_label: __address__
      replacement: blackbox:9115
```

以上片段只呈現實驗原理。正式版本必須加入 `cluster`、`mon`、`probe_location`、expected target coverage 與 §8 的 acquisition guard。

---

## 附錄 B：現有規則與 production 差距

實驗規則：

```promql
(count(probe_success{job="mon-tcp"} == 1) or vector(0)) < 2
```

它已在單 cluster、單 probe location、固定三個 target 的 lab 證明核心方向，但還有三個 production blocker：

1. 沒有 `by (cluster, probe_location)`。
2. `probe_success` absent 時會把 exporter failure 當成 MON failure。
3. 沒有外部 expected inventory coverage。

因此本報告不提供一段未經測試的「production-ready PromQL」讓讀者直接複製；應先在現有 rule 與 promtool harness 上完成 §10 Phase 1，再把通過測試的版本納入正式規則庫。

---

## 附錄 C：證據索引

| 證據 | 路徑 | 能支持的主張 |
|---|---|---|
| 實驗 charter 與預測 | [`HYPOTHESES.md`](./HYPOTHESES.md) | 候選方案、事前 prediction、執行／未執行記帳 |
| 故障注入腳本 | [`scenarios/mon-quorum-2down.sh`](./scenarios/mon-quorum-2down.sh) | inject、snapshot、rollback、postcheck 流程與安全邊界 |
| 注入時間 | [`inject-time.txt`](./results/mon-quorum-2down-20260708T154019Z/inject-time.txt) | 15:40:22Z |
| MON process ground truth | [`mon-isactive.txt`](./results/mon-quorum-2down-20260708T154019Z/mon-isactive.txt) | mon-02、mon-03 inactive |
| baseline | [`prom-baseline.txt`](./results/mon-quorum-2down-20260708T154019Z/prom-baseline.txt) | mgr=3、blackbox=3、up=1、無 alert |
| 第一份故障快照 | [`prom-t+03s.txt`](./results/mon-quorum-2down-20260708T154019Z/prom-t+03s.txt) | 實際 +6 秒；mgr=3、blackbox=1、pending |
| firing 快照 | [`prom-t+30s.txt`](./results/mon-quorum-2down-20260708T154019Z/prom-t+30s.txt) | 實際 +47 秒；mgr=3、blackbox=1、firing |
| window final | [`prom-window-final.txt`](./results/mon-quorum-2down-20260708T154019Z/prom-window-final.txt) | +156 秒仍維持相同對照 |
| rollback postcheck | [`postcheck-ceph-s.txt`](./results/mon-quorum-2down-20260708T154019Z/postcheck-ceph-s.txt) | 3-MON quorum、9 OSD up/in、33 PG active+clean、仍 HEALTH_WARN |
| 新 Pod 狀態 | [`newclient-status.txt`](./results/mon-quorum-2down-20260708T154019Z/newclient-status.txt) | PVC Bound、Pod 105 秒 ContainerCreating、已 SuccessfulAttachVolume |
| fio baseline | [`fio-matrix-baseline.txt`](./results/baseline/fio-matrix-baseline.txt) | 健康時 8 組讀寫 |
| fio 故障窗 | [`fio-window.txt`](./results/mon-quorum-2down-20260708T154019Z/fio-window.txt) | 故障窗內 8 組讀寫皆 rc=0 |
| PromQL 單元測試 | [`mon-quorum-blackbox.test.yml`](./tests/mon-quorum-blackbox.test.yml) | healthy、1/3 reachable、0/3 reachable、probe scrape pipeline unavailable synthetic case |
| Ceph source | [`module.py:1018-1033`](../../ceph/src/pybind/mgr/prometheus/module.py#L1018) | mgr metric 從 `self.get('mon_status')` 產生 |

### promtool 現況

```bash
promtool test rules experiments/ceph-mon-quorum-blind-spot/tests/mon-quorum-blackbox.test.yml
```

現有測試結果為 `SUCCESS`，但仍缺多 cluster、target drift、實際 exporter process failure、probe partition 與 Alertmanager 的測試，不能以單元測試成功替代 production gate。
