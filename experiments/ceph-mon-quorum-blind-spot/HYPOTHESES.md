# HYPOTHESES — Ceph MON quorum-loss 盲區偵測 + IO 衝擊

## Charter

**Pinned source of truth**：真 cephadm Ceph **v19.2.3**（fsid `0c9bf37e…`，3 mon + 9 OSD）+ k0s v1.36 單節點 Rook external（`.155`）。commit c92aebb，對齊專案 pin。

**問題**：3-mon cluster 停 2 顆 mon（quorum 失守）時：
- **Thread A（偵測）**：現行 `CephMonQuorumLost = (count(ceph_mon_quorum_status==1) or vector(0)) < 2` 無法 fire，因為唯一 metric source（active mgr prometheus module `:9283`）在 quorum 失守後**凍結**、繼續吐 stale `ceph_mon_quorum_status=1`。要用**純 Prometheus metrics**（允許加標準 exporter，不寫 out-of-band script）把這個狀態偵測出來，設計多方案、實驗、推薦最佳。
- **Thread B（IO 衝擊）**：在 2-mon-down / out-of-quorum 狀態下，client IO 具體受什麼影響？涵蓋 single/multi thread × random/seq，且區分「已連線 client」vs「新連線 client」。

**注入手法（兩 thread 共用）**：`systemctl stop` mon-02 + mon-03 的 mon daemon（保留 mon-01：它跑 active mgr，用來觀察 stale telemetry）→ 觀察窗 → `systemctl start` 還原 → assert `HEALTH_OK`。可逆、idempotent、pre-check ok-to-stop/quorum。

## Backlog state machine
`proposed → predicted → confirmed | violated → synthesized`

---

## Thread A — 偵測方案

### H-A1 — 現行規則盲（重現 baseline）
- **Status**: predicted | **Tier**: T3(live) | **Origin**: prior finding #5（EVIDENCE-SUMMARY-2026-07-04）
- **Claim**: 停 2/3 mon 時，active mgr 續吐 stale `ceph_mon_quorum_status`（三顆都=1），`count(==1)` 維持 3，`CephMonQuorumLost` 停在 `none`。
- **Prediction**: 觀察窗內 `count(ceph_mon_quorum_status==1)` == 3（≥2），alert state == `none`（`for: 1m` + 15s scrape + margin ⇒ 窗 ≥ 3min）。

### H-A2 — mgr telemetry 凍結可被 staleness 偵測
- **Status**: predicted | **Tier**: T3 | **Origin**: enumerate（sensor-freeze 軸）
- **Claim**: quorum 失守後 mgr 續 serve（`up{mgr}`=1）但 metric 值凍結；某些正常會遞增/變動的 metric 停止變化。
- **Prediction**: (a) `up{job="ceph-mgr"}` 在窗內前段維持 1（stale-serve，非 absent）；(b) 至少一個平時每 scrape 會變的 mgr metric 在注入後 `changes(...[2m]) == 0`。量測「mgr scrape 何時（若有）真的失敗」的時間。

### H-A3 — blackbox_exporter TCP 探 mon port（**主推候選**）
- **Status**: predicted | **Tier**: T3 | **Origin**: enumerate（ceph-telemetry-independent 軸）
- **Claim**: blackbox_exporter `tcp_connect` 探每顆 mon 的 v2 port 3300，停掉的 2 顆 `probe_success=0`，與 mgr 是否凍結無關。
- **Prediction**: 注入後 1 個 scrape interval 內 `count(probe_success{job="mon-tcp"}==1) < 2` 成立、對應 alert fire（`for: 30s` ⇒ 窗內確定 firing）。還原後恢復 3。

### H-A4 — 純 `up{job="ceph"}` 偵測不到（負向對照）
- **Status**: predicted | **Tier**: T3 | **Origin**: enumerate
- **Claim**: 只停 mon daemon、host + mgr 續跑 ⇒ mgr scrape target `up` 不掉，`up`-only 偵測盲。
- **Prediction**: 窗內 `up{instance=mgr}` == 1 全程；`CephExporterAllDown`（`for: 5m`）在窗內**不** fire（除非 mgr 另外失敗，一併量測其時序）。

### H-A5 — node_exporter systemd collector 看 mon 進程
- **Status**: proposed | **Tier**: T3 | **Origin**: enumerate（per-host process 軸）
- **Claim**: node_exporter `--collector.systemd` 匯出 `node_systemd_unit_state{name="…mon…",state="active"}`，停掉的 2 顆 active-state → 0。
- **Prediction**: `count(node_systemd_unit_state{name=~".*mon.*",state="active"}==1) < 2`。（部署成本較高：systemd collector 需 dbus；時間夠才做。）

### H-A6 — per-host ceph-exporter 多源去 stale
- **Status**: proposed | **Tier**: T3 | **Origin**: enumerate（multi-source 軸）
- **Claim**: 若每台跑 ceph-exporter(:9926) 抓 local mon admin socket，停掉的 mon 其 series **absent**、存活 mon 回報自身 out-of-quorum(0)，多源匯總即反映真相。
- **Prediction**: 多源下 `count(ceph_mon_quorum_status==1) < 2`。**高不確定**：ceph-exporter 是否匯出 quorum_status、停掉 mon 的 local exporter 是 absent 還是 stale，需實測。orch 壞 ⇒ 要 standalone 跑，成本高，列後補。

---

## Thread B — IO 衝擊

### H-B1 — 已連線 client 續跑（cached osdmap）
- **Status**: predicted | **Tier**: T3 | **Origin**: framing（mon 職責：map 分發，非 data path）
- **Claim**: 注入前已 map/mount 並在 IO 的 client，持 cached osdmap 直打 OSD，quorum 失守後仍持續（至少到需要新 map 或 cephx ticket 過期）。
- **Prediction**: 注入前起跑的 fio，穿越整個 down 窗 per-second IOPS 維持非零、無 stall；還原後不變。

### H-B2 — 新連線 client 阻塞
- **Status**: predicted | **Tier**: T3 | **Origin**: framing（新 client 需向 mon 取 monmap/osdmap）
- **Claim**: 窗內新建 PVC/新 mount/新 rados client 需向 mon 取 map ⇒ 阻塞直到 quorum 回。
- **Prediction**: 窗內 `kubectl apply` 新 PVC + fio pod → 卡在 Pending/ContainerCreating（mount timeout），0 IOPS；quorum 回後才 Bound/Running。

### H-B3 — rand/seq × 單/多 thread 對「已連線續跑」無質性差異（null result）
- **Status**: predicted | **Tier**: T3 | **Origin**: framing（quorum 依賴在 map/session 層，非 data path）
- **Claim**: 對已連線 client，quorum 失守不因 IO pattern / 併發度而有質性差異。
- **Prediction**: 已連線 client 在窗內跑 {randread,randwrite,seqread,seqwrite} × {1,4 thread}，各 cell 皆完成，窗內吞吐/延遲 ≈ baseline（差異在雜訊帶內，非階梯式崩落）。

### H-B4 — 讀寫皆續（PG 不 re-peer）
- **Status**: predicted | **Tier**: T3 | **Origin**: framing（OSD 端 PG 維持 active、無 peering 變更）
- **Claim**: quorum 失守但 OSD 全 up ⇒ 既有 PG 維持 active，讀與寫都續（不像 OSD down 會 re-peer）。
- **Prediction**: 已連線 client 的 randwrite 與 randread 皆維持非零吞吐；`ceph_pg_active` 類（若可讀，注入前 snapshot）不減。

### H-B5 — 還原後有界恢復
- **Status**: predicted | **Tier**: T3 | **Origin**: framing
- **Claim**: quorum 回後，被卡的新 client 有界時間內恢復。
- **Prediction**: 窗內被卡的新 PVC/pod，在 `systemctl start` 兩顆 mon 後 ~數十秒內 Bound/Running；已連線 client 全程無感。

---

## 執行順序
1. 部署 monitoring（Prometheus + blackbox_exporter 探 mon:3300；mgr:9283；node_exporter 視情況）
2. Baseline（HEALTH_OK、quorum、全 metric、fio 矩陣基準）
3. 注入單次長窗（停 mon-02+mon-03）：窗內同時量 Thread A（各偵測源）與 Thread B（已連線 fio 矩陣 + 新 client 阻塞）
4. 還原、assert HEALTH_OK、收 bundle
5. Synthesize → 推薦 + 規則草案 + promtool test

---

## 結果狀態（run 20260708T154019Z）

| H | 判定 | 證據 |
|---|---|---|
| H-A1 現行規則盲 | **confirmed** | 全窗 `count(ceph_mon_quorum_status==1)=3`，CephMonQuorumLost 未 pending/fire |
| H-A2 mgr 凍結非缺席 | **confirmed** | up=1 全窗、值凍結=3 ~2.5min 未自癒 |
| H-A3 blackbox 探 mon port | **confirmed** | 注入 ≤5s `count(probe_success==1)=1`，30s fire；還原回 3 |
| H-A4 up-only 盲 | **confirmed** | up{ceph}=1 全窗，CephExporterAllDown 不 fire |
| H-A5 node_exporter systemd | 設計論證（未部署） | mon host 不在 k8s、需 per-host agent；blackbox 已 dominates |
| H-A6 per-host ceph-exporter | 設計論證（未部署） | 需 per-host agent + orch 壞；blackbox 較省 |
| H-B1 已連線續跑 | **confirmed** | 窗內 fio 矩陣全 rc=0、吞吐≈baseline |
| H-B2 新連線阻塞 | **confirmed（修正版）** | 新 pod 卡 ContainerCreating（krbd map）；但 PVC provision 經既有 provisioner 連線仍成功 |
| H-B3 rand/seq×thread 無質性差異 | **confirmed** | 8 cell 皆續、無階梯崩落 |
| H-B4 讀寫皆續 | **confirmed** | randwrite/write 窗內維持 baseline 級（慢是碟慢，非 quorum） |
| H-B5 還原後恢復 | 未直接觀察 | cleanup 提早刪 new pod；屬預期 |

**一句話**：偵測盲區的根因是「sensor（mgr metric）與被測物（quorum）同生共死」，唯一解是引入 mgr 以外、逐 mon 獨立的訊號（blackbox TCP 探 mon port 最省）；IO 衝擊則是「已連線者無感、新建 mon 連線者阻塞」。
