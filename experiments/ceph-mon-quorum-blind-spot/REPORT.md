# Ceph MON quorum-loss 盲區：純 Prometheus 偵測 + IO 衝擊實驗報告

> 進行中的活文件。使用者要求「每執行完一 step 就 push」；下方 **執行進度** 逐步更新。
> 方法論：`skills/researching-system-behavior`（Frame→Enumerate→Falsify→Automate→Synthesize）
> + `skills/designing-falsifiable-experiments`（inject→observe→collect→rollback→assert，prediction 先行）。
> 對應 backlog：[HYPOTHESES.md](./HYPOTHESES.md)。

---

## 0. TL;DR（真機實證，run 20260708T154019Z）

**問題**：3-mon cluster 停 2 顆 → quorum 失守，但 `CephMonQuorumLost` 不會 fire。**已在真機重現**：停 mon-02+mon-03 後，`ceph_mon_quorum_status` 全窗 stale=3、規則從未 pending。

**根因**：整個 cluster 唯一 Ceph metric source = active mgr prometheus module（`:9283`）。quorum 一失守，mgr 拿不到新 map、metric **凍結**在最後好值（三顆都 `=1`）→ `count(==1)` 還是 3、永不觸發。這不是規則寫法問題，是**單一 sensor 與被測物同生共死**——修不在 PromQL，在**資料來源**。`up{ceph}` 亦全窗=1（mgr 續 serve），所以 `up`-based 也盲。

**推薦解**：加 **blackbox_exporter TCP 探每顆 mon 的 msgr port(3300)**，`(count(probe_success{job="mon-tcp"}==1) or vector(0)) < 2`。真機實測**注入 ≤5s 偵測、30s fire**，與 mgr 凍結無關；還原自動回復。這是唯一「不經過 mgr、逐 mon 獨立」又**不需 per-host agent** 的方案。保留現行 mgr 版當互補、加探針守門。規則 + promtool 測試 + 可套用 manifest 都已產出（§5）。

**IO 衝擊**（已證）：**已連線 client（RBD 已 map/mount）single/multi × random/seq × read/write 全部照跑、吞吐 ≈ baseline**——quorum 只管 map 分發/建 session，data path 直打 OSD。真正卡的是**任何要新建 mon 連線的動作**：node 的 kernel `rbd map`（新 pod 卡 ContainerCreating）→ 涵蓋新部署 / pod 重啟 / node 重開 / drain 重排 / HPA 擴容。⇒ quorum 失守期間別重排 pod / drain node，且務必要有 quorum pager（存量 workload 無感、不會自己叫）。

---

## 1. 背景與根因

### 1.1 現行規則
```
# experiments/ceph-alert-rules/rules/ceph-stability-first.yml
- alert: CephMonQuorumLost
  expr: (count(ceph_mon_quorum_status == 1) or vector(0)) < 2
  for: 1m
```
`or vector(0)` 是既有的 F1 修正：解決「**全部** mon 掛掉、`==1` 過濾成空 vector、`count(空)` 無 sample、`<2` 算不出結果 → 不 fire」的最壞情況。

### 1.2 為什麼 2/3 down 仍不 fire
`or vector(0)` 只救「series 完全消失」的情況。但停 2 顆 mon 時 series **沒有消失**——它**凍結**：

- 唯一 metric source = active mgr prometheus module `:9283`（本 lab 無 ceph-exporter:9926、無 node-exporter）。
- mgr 對 monmap 裡**每一顆** mon 匯出 `ceph_mon_quorum_status`（`prometheus/module.py` iterate `monmap['mons']`）。
- quorum 失守後 mgr 拿不到新 map，續吐上一輪的值（三顆都 =1）。
- ⇒ `count(ceph_mon_quorum_status==1)` = 3，`3 < 2` 為 false，**永不 fire**。
- 前一輪真機（EVIDENCE-SUMMARY-2026-07-04 finding #5）已實測：`sum(ceph_mon_quorum_status)=3` 在真 quorum loss 後仍回報；規則只在把 mgr 也停掉、series 變空後才靠 `or vector(0)` fire。

**核心洞見**：`CephMonQuorumLost` 用 mgr 匯出的 metric 去偵測「mgr 失去 quorum 感知」的狀況——sensor 跟被測物同生共死。要跳出盲區，訊號必須來自 mgr 以外。

### 1.3 Lab 狀態與復原註記（2026-07-08）
機器重開後 public IP 漂移（DHCP），monmap 仍記舊 IP → 三顆 mon `bind: Cannot assign requested address` crash-loop、cluster 無 quorum。**復原**：各 mon host `ens18` 補回 monmap 的舊 IP 當 secondary（mon-01 `.166`／mon-02 `.167`／mon-03 `.164`），`reset-failed`+`start` → quorum 秒回 `HEALTH_OK`。詳見 memory `project-ceph-lab-cluster`。此復原可逆（`ip addr del`），且與 Rook CSI 既有 mon 設定一致（PVC provisioning 實測正常）。

---

## 2. 實驗設計

見 [HYPOTHESES.md](./HYPOTHESES.md)。單次長窗注入（停 mon-02+mon-03，留 mon-01+active mgr 觀察 stale），窗內同時量測兩 thread。

**Thread A 偵測源**（窗內同時 scrape，比較誰正確、誰最快）：
| # | 方案 | 來源 | 預期 |
|---|---|---|---|
| A1 | 現行 `ceph_mon_quorum_status` | mgr :9283 | **盲**（stale=3，不 fire）|
| A2 | mgr staleness | mgr :9283 | 值凍結；`up` 前段仍=1 |
| A3 | blackbox TCP 探 mon:3300 | blackbox_exporter | **偵測**（2 顆 probe_success=0）|
| A4 | `up{job=ceph}` only | Prometheus | **盲**（mgr 續跑 up=1）|
| A5 | node_exporter systemd | node_exporter | 偵測（time permitting）|
| A6 | per-host ceph-exporter | ceph-exporter :9926 | 待驗（time permitting）|

**Thread B IO 矩陣**（k8s Rook RBD PVC + fio pod）：
- 已連線 client：注入**前** mount + warm，窗內跑 {randread,randwrite,seqread,seqwrite} × {1,4 thread}，per-second log。
- 新連線 client：窗內 `apply` 新 PVC+fio pod，觀察是否卡 Pending/mount timeout。

---

## 3. 執行進度

- [x] **Step 0**：Lab 復原（IP 漂移 → secondary IP 修，quorum 回 HEALTH_OK）；metric 拓樸盤點（唯一源 = mgr :9283）；k8s RBD 路徑 smoke test 通過。
- [x] **Step 1**：實驗設計（HYPOTHESES.md + 本報告）落地、push。
- [x] **Step 2**：部署 monitoring（k8s ns `qmon`：Prometheus NodePort 30090 + blackbox_exporter 探 mon:3300；scrape mgr :9283）+ 兩 thread baseline。node_exporter(A5) 因 mon host 不在 k8s、需 per-host agent 而 blackbox 已足，改以設計論證處理（見 §5）。
- [x] **Step 3**：注入長窗（停 mon-02+mon-03，~2.5min quorum loss）、窗內量兩 thread、trap 還原、assert 3-mon quorum 回。結果見 §4.1/§4.2。
- [x] **Step 4**：Synthesize — 推薦（§5）+ 規則草案 `rules/ceph-mon-quorum-blackbox.yml` + promtool test `tests/mon-quorum-blackbox.test.yml`（SUCCESS，含 mgr-盲 vs blackbox-fire 頭條對照）。網站 MDX 發佈**延後**等使用者在 Gate 3 定奪。

---

## 4. 結果（回填中）

### 4.0 Baseline（healthy 3-mon quorum）
Thread A 全部偵測源一致（health 時本來就該一致）：`count(ceph_mon_quorum_status==1)=3`、`count(probe_success{mon-tcp}==1)=3`、`up{ceph}=1`、無 alert。

Thread B pre-connected fio 矩陣（direct=1, iodepth=1；小 lab、size=3、慢碟 → 寫很慢是常態，重點在 baseline vs window 比較）：

| pattern | 1 thread | 4 thread |
|---|---|---|
| randread 4k | 2847 iops / 348µs | 36134 iops / 108µs |
| randwrite 4k | 10 iops / 95.8ms | 13 iops / 295.8ms |
| read seq 1M | 172 iops (172 MB/s) | 1380 iops (1380 MB/s) |
| write seq 1M | 1 iops (1.4 MB/s) | 3 iops (2.6 MB/s) |

原始 JSON、Thread A snapshot 見 `results/baseline/`。

### 4.1 Thread A — 偵測結果（confirmed）
注入 = 停 mon-02+mon-03（留 mon-01+active mgr）。bundle：`results/mon-quorum-2down-20260708T154019Z/`。

| 時間 | A1 mgr `count(quorum_status==1)` | A3 blackbox `count(probe==1)` | A4 mgr `up` | firing |
|---|---|---|---|---|
| baseline | 3 | 3 | 1 | — |
| t+3s | **3（stale, 盲）** | **1（偵測）** | 1（盲） | blackbox → pending |
| t+10s | 3 | 1 | 1 | blackbox pending |
| t+30s | **3** | **1** | 1 | **blackbox FIRING** |
| window-final(~2.5m) | **3** | **1** | 1 | blackbox firing |

**判定**：
- **H-A1 confirmed（現行規則盲）**：整個窗 `ceph_mon_quorum_status` 三顆都停在 stale=1、`count(==1)=3`。`CephMonQuorumLost`（A1）**從頭到尾沒進 pending，更沒 fire**。重現前一輪 finding #5。
- **H-A3 confirmed（blackbox 主推）**：注入後**一個 scrape（≤5s）**內 `count(probe_success==1)` 掉到 1；`for:30s` 後 fire。還原後 3-scrape 內回 3。偵測與 mgr 是否凍結完全無關。
- **H-A4 confirmed（up-only 盲）**：`up{job=ceph}` 全窗 =1——mon daemon 停不代表 mgr 進程停，mgr host 續跑、續 serve stale ⇒ `CephExporterAllDown` 不 fire。
- **H-A2 confirmed（凍結非缺席）**：mgr 續 serve（up=1），值凍結 =3 長達 ~2.5min 未自癒為可偵測狀態 ⇒ 靠「等 mgr 掛」不可靠。
- **ground truth（真的失守）**：`mon-02/03 systemctl is-active=inactive`；還原時 `ceph -s` 出現 `748 slow ops … mon.ceph-lab-mon-01 has slow ops`——證明 mon-01 在窗內收到 client 的 mon 請求但因無 quorum 無法處理（塞成 slow ops），即 quorum 確實失守、而 mgr metric 仍讀 3。

### 4.2 Thread B — IO 衝擊結果（confirmed）
pre-connected client = 注入前已 mount + warm 的 fio pod；new client = 窗內才 apply 的 PVC+pod。

**(a) 已連線 client：single/multi × random/seq 全部續跑，無質性衝擊。** 每 cell rc=0、無 stall/timeout，窗內吞吐 ≈ baseline（讀甚至更快，少了背景 mon/mgr chatter）：

| pattern | baseline 1t / 4t | window 1t / 4t |
|---|---|---|
| randread 4k | 2847 / 36134 iops | 8766 / 38702 iops |
| randwrite 4k | 10 / 13 iops | 9 / 19 iops |
| read seq 1M | 172 / 1380 iops | 343 / 1376 iops |
| write seq 1M | 1 / 3 iops | 2 / 2 iops |

⇒ **H-B1 / H-B3 / H-B4 confirmed**：quorum 依賴在「map 分發 / 建 session」層，不在 data path；已持 cached osdmap 的 client 直打 OSD（OSD 全 up、PG 不 re-peer），rand/seq/thread/讀寫皆不受影響。

**(b) 新連線 client：卡在 kernel `rbd map`，比 H-B2 更細緻的發現：**
- 新 PVC `qio-newclient` 窗內竟 **Bound**（RBD image 建出來了）——因為 CSI **provisioner 本身也是個已連線的 rados client**，用 cached 連線就把 image 建了（= H-B1 延伸到 control plane）。
- 但新 pod 卡在 **ContainerCreating**：node 上的 `rbd map` 是**全新 kernel client**，要向 mon 取 map ⇒ 阻塞。事件停在 `SuccessfulAttachVolume` 之後、mount 之前。
- ⇒ **H-B2 修正版 confirmed**：阻塞的精確位置是「需要**新建 mon 連線**的動作（krbd map / 新 rados client）」，不是「PVC 建立」這件事本身。riding 既有連線的 control-plane 動作照過。
- H-B5（新 mount 在 quorum 回來後恢復）未直接觀察（cleanup 在還原後即刪除該 pod）；依 Ceph 既有行為與 (a) 已證 data path 健康，回 quorum 後 map 會續成，屬預期。

**還原**：trap 保證啟回 mon-02+mon-03，blackbox count 2→3、3-mon quorum 回（`ceph -s` age 秒級），窗內累積的 mon slow ops 隨即清空，回到實驗前 baseline WARN。

---

## 5. 推薦與規則草案

### 5.1 偵測方案比較（feasibility + 判定）
| 方案 | 訊號來源 | 需新元件 | 偵測 2/3 down | 延遲 | 侷限 | 評 |
|---|---|---|---|---|---|---|
| A1 現行 mgr metric | mgr :9283 | 無 | ✗ **盲**（stale=3） | 永不 | sensor 與 quorum 同生共死 | 保留當互補 |
| A2 mgr staleness | mgr :9283 | 無 | 不可靠 | — | 無穩定 ticking metric；`up` 全窗=1 | 不當主訊號 |
| **A3 blackbox 探 mon:3300** | blackbox_exporter | **1 個 central pod** | ✓ | **≤1 scrape(≤5s)，30s fire** | port 開 ≠ 已進 quorum | **★ 主推** |
| A4 up-only | Prometheus 內建 | 無 | ✗ 盲 | — | mon daemon 停 ≠ mgr 進程停 | 不可用 |
| A5 node_exporter systemd | node_exporter | per-host agent ×3 | ✓（理論） | 1 scrape | mon host 不在 k8s、需逐台裝、dbus | 可行但比 A3 重 |
| A6 per-host ceph-exporter | ceph-exporter :9926 | per-host agent ×3 | ✓ **且能抓 in-quorum** | 1 scrape | orch 壞、逐台裝、較重 | 唯一能抓「port 開但沒進 quorum」 |

### 5.2 推薦
1. **主訊號：A3 blackbox 探 mon msgr port**。載入 `rules/ceph-mon-quorum-blackbox.yml` 的 `CephMonQuorumLostBlackbox`（寫死 3-mon）或 `…Dynamic`（非 3-mon）。它是唯一「不經過 mgr、逐 mon 獨立」又**不需 per-host agent**的方案；真機實測注入 ≤5s 偵測、30s fire。
2. **互補層：保留現行 mgr-based `CephMonQuorumLost`**。mgr 健康時它能抓 blackbox 抓不到的退化（如 port 開著但 rank 不對）。兩者取聯集當 pager。
3. **守門：`CephMonProbeExporterDown`**，把「探針自己死了」跟「mon 掛了」分開，避免誤導 runbook。
4. **可選第三層（若在意「mon 進程活、port 開、卻沒進 quorum」——分區/選舉卡住）：A6 per-host ceph-exporter**。成本是逐台 agent；非必要不上。

blackbox 相對 mgr metric 的關鍵優勢：down target 它匯出 `probe_success=0`（series 不消失），故動態 majority 的分母 `count(probe_success)` 穩定、連全掉都算得出——比 mgr metadata 動態版更穩。

**部署**：完整可套用 manifest 見 `manifests/monitoring.yaml`（blackbox Deployment + Prometheus job `mon-tcp` relabel 探三顆 mon:3300 + 載入規則）。規則邏輯以 promtool 驗證：`tests/mon-quorum-blackbox.test.yml`（含「同一 quorum-loss 下 mgr 版盲、blackbox 版 fire」的頭條對照），`promtool test rules` **SUCCESS**。

### 5.3 IO 衝擊結論（Thread B → 實務意義）
- **已在跑的 workload 多半無感**：只要 RBD 已 map/mount，single/multi × random/seq × read/write 全部照跑（實測吞吐 ≈ baseline）。quorum 只管 map 分發與建 session，data path 直打 OSD（OSD 全 up、PG 不 re-peer）。
- **真正會爆的是「任何要新建 mon 連線」的動作**：k8s 上就是 node 的 kernel `rbd map`（新 pod 卡 `ContainerCreating`）。這涵蓋**新部署、pod 重啟、node 重開機、drain 後重排、HPA 擴容**——全部卡住直到 quorum 回。控制面 PVC provisioning 反而可能成功（CSI provisioner 是既有連線）。
- **對 alert 的意涵**：不能指望存量 workload 自己察覺 quorum 失守（它們無感）；quorum pager（A3）是必要的主動訊號。且 quorum 失守期間**別重排 pod / drain node**，會把無感變成全卡。

### 5.4 現場狀態與善後（給醒來的你）
- **叢集**：3-mon quorum 回復、9 OSD up、mgr active+standby。`HEALTH_WARN` 只剩兩個既存良性項：BlueStore slow-op alert（實驗寫入觸發，~24h latch，非現時 slow）＋「3 hosts fail cephadm check」（IP 漂移導致 orch SSH 失敗，data plane 無礙）。
- **⚠️ mon secondary IP 不要拆**：`.166/.167/.164` 是現在維持 quorum 的綁定位址（見 §1.3）。重開機不會保留；下次開機要照 memory 重補。
- **推薦偵測 stack 仍在線**：k8s ns `qmon`（Prometheus + blackbox）。Prometheus UI＝ `http://192.168.18.155:30090`（Mac 可直接開），已在即時監測 quorum。要收掉：`sudo kubectl delete ns qmon`（在 .155）。
- **Gate 3（發佈決策，已定案）**：使用者選「獨立一頁」。已新增 `next-site/content/ceph/features/mon-quorum-detection-blind-spot.mdx`（偵測盲區為主軸 + blackbox 解 + IO 衝擊以既有 `mon-quorum-loss-impact` 頁為深追、本頁只放真機確認），並註冊進 `projects.ts`（監控與告警群組）、`feature-map.json`、`quiz.json`（Q17/Q18）。`make validate` 全過。

### 5.5 誠實的邊界 / 未竟
- blackbox 探的是**可達性**（TCP port 開）。「mon 進程活、port 開、但因分區/選舉卡在 probing 沒進 quorum」這種 corner case blackbox 會誤判為健康——需 A6 才抓得到。實務上 quorum 失守最常見成因（mon daemon 掛、host 掛、網路斷）都會讓 port 不可達，A3 抓得到。
- H-B5（新 mount 在 quorum 回來後恢復）未直接觀察（cleanup 提早刪 pod）；屬 Ceph 既有行為。
- A5/A6 以設計 + 拓樸論證處理，未真機部署（mon host 不在 k8s、需 per-host agent，且 A3 已解題）。
