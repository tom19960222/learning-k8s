# Tier D 真機觀測（ceph v19.2.3, commit c92aebb, cephadm, 3 mon + 9 OSD/3 host）

叢集：fsid 0c9bf37e；mon-01/02/03（.166/.167/.164），osd-01(osd.0-2)/osd-02(osd.3-5)/osd-03(osd.6-8)。
mgr active 在 mon-02，prometheus module 啟用於 :9283。觀測：Mac 跑 Prometheus 載真規則 scrape .167:9283 → Alertmanager → sink（for: 5m→30s 縮短版）。

## Baseline（HEALTH_OK）— 每條 label 假設都成立
- `ceph_mon_quorum_status{ceph_daemon="mon.ceph-lab-mon-01"} 1.0`（三台皆 1，只帶 ceph_daemon）✓
- `ceph_mon_metadata{ceph_daemon=...,hostname=...,public_addr=...,rank=...,ceph_version=...}`（帶 hostname）✓
- `ceph_osd_up{ceph_daemon="osd.0"} 1.0` —— **只帶 ceph_daemon**（真機證實 devil #5：join 後 `{ceph_daemon,hostname}` 無洩漏）✓
- `ceph_osd_metadata{...,ceph_daemon="osd.0",...,hostname="ceph-lab-osd-01",...}`（帶 hostname；額外 label 在 metadata 上、不在 osd_up）✓
- `ceph_health_status 0.0`、無 `ceph_health_detail` series（health OK 時不匯出）
- 透過我的 Prometheus：up{job=ceph}=1、count(quorum==1)=3、count(osd_up==1)=9、**無任何 alert**（乾淨）
- raw snapshot：`baseline-metrics.txt`

## 情境觀測

### S1 — 單顆 OSD down（停 osd.8）
- `ceph osd ok-to-stop osd.8` → `{"ok_to_stop":true,"num_ok_pgs":0}`（osd.8 不持有那唯一 .mgr PG → 不升 PG_DEGRADED）
- 停止後 `ceph_osd_up{ceph_daemon="osd.8"}=0`（<5s）；ceph 升 `OSD_DOWN`（HEALTH_WARN）
- prometheus module 匯出 `ceph_health_detail{name="OSD_DOWN", severity="HEALTH_WARN"} 1`（證實 name/severity label 格式與測試 fixture 一致）
- **CephOSDDaemonDownScoped 在 35s firing**，label `{ceph_daemon="osd.8", hostname="ceph-lab-osd-03"}` —— recording-rule 的 `group_left(hostname)` join 在真 ceph 上正確接上 hostname；silence 用 `ceph_daemon=osd.8` 可精準鎖定
- **CephOSDHostDownScoped 不 fire**（只 1/3 down，scoped host 判定正確）
- 還原：`ceph orch daemon start osd.8` → osd.8 up（35s）→ alert 清除（40s）。乾淨恢復。

### S2 — 整台 OSD node 維護（ceph-lab-osd-03 進 maintenance）🔴 抓到設計 bug
- `ceph orch host maintenance enter ceph-lab-osd-03`：停 osd.6/7/8、自動對 host subtree 設 `noout`
- ceph 實際升的 health check（`ceph health detail` 確認 raw 名稱）：
  `HOST_IN_MAINTENANCE`、`OSD_DOWN`、**`OSD_FLAGS`**（"host ceph-lab-osd-03 has flags noout"）、`OSD_HOST_DOWN`、`PG_DEGRADED`
- ✅ **CephOSDHostDownScoped{hostname="ceph-lab-osd-03"} firing**（30s）——scoped 訊號保留
- ✅ **CephOSDDaemonDownScoped 不 fire**——整台 down 被 `unless on(hostname)` 壓掉，不會每顆各叫
- ✅ CephLowPriorityNotice fire（HOST_IN_MAINTENANCE、PG_DEGRADED）——slack-only 正確
- ✅ **silence 真機有效**：`amtool silence add alertname=CephOSDHostDownScoped hostname=ceph-lab-osd-03` → `state=suppressed`
- 🔴 **設計 bug（只有真機抓得到）**：`CephClientRisk{name="OSD_FLAGS"} firing`！設計頁的排除清單寫 `OSDMAP_FLAGS`，但 **`maintenance enter` 對 subtree 設 noout 升的是 `OSD_FLAGS`（per-subtree flag），不是 `OSDMAP_FLAGS`（cluster-wide `ceph osd set` 才升）**。名字對不上 → catch-all 接走 → **例行維護照樣 page oncall**，正是設計要防的失敗。頁面 callout 正確抓到「noout 要排除」的意圖，卻用錯 check 名。修法：排除清單 + LowPriorityNotice 都改用 `OSD_FLAGS`（保險起見含 `OSD_FLAGS|OSDMAP_FLAGS` 兩者，因 cluster-wide noout 才升 OSDMAP_FLAGS）。
- 還原：`maintenance exit` → 9 OSD up、noout 移除、PG 回 active+clean、HEALTH_OK（30s）

### S3 — 單台 mon 維護（ceph-lab-mon-03，非 mgr 節點）✅ 證實 monmap 宣稱
- `maintenance enter ceph-lab-mon-03`：停 mon.ceph-lab-mon-03（mgr 只在 mon-01/02，scrape 不受影響）
- live health：`1/3 mons down, quorum ceph-lab-mon-01,ceph-lab-mon-02`；ceph 升 `MON_DOWN`、`HOST_IN_MAINTENANCE`
- ✅ **CephMonDownScoped{ceph_daemon="mon.ceph-lab-mon-03"} firing**（40s）
- ✅ **stopped mon 仍匯出 `ceph_mon_quorum_status{mon-03}=0` 與 `ceph_mon_metadata{mon-03, hostname=ceph-lab-mon-03}`**——證實頁面「停掉的 mon 仍在 monmap、metric 與 metadata 都在」的宣稱，所以 scoped silence（用 ceph_daemon/hostname）接得到
- ✅ count(quorum==1)=2 → **CephMonQuorumLost 不 fire**（維護 1 台生命線正確靜默）
- ✅ **MON_DOWN 被正確排除**：CephClientRisk 不 fire（MON_DOWN 名稱與頁面排除清單相符）
- ✅ 真實 health-check 名稱對照頁面：`MON_DOWN`✓ `HOST_IN_MAINTENANCE`✓ `OSD_DOWN`✓ `OSD_HOST_DOWN`✓ `PG_DEGRADED`✓，唯 `OSD_FLAGS`✗（頁面寫 OSDMAP_FLAGS）
- 還原：`maintenance exit` → mon-03 rejoin、quorum=3、HEALTH_OK（25s）

### S4 — 真 quorum loss（systemctl 停 mon-03 + mon-01，保留 mon-02/mgr）🔴🔴 最深層發現
- trap 保證一定重啟兩台 mon；不停全部 3 台（total outage，Tier A 已證 count=0 行為）
- **觀測結果：quorum 真失守的 90 秒內，mgr metric 完全凍結**：`count(quorum==1)` 一直 =3、`ceph_mon_quorum_status` 三台都還報 1、`up{job=ceph}` 一直 =1。**CephMonQuorumLost 沒 fire、CephExporterDown 也沒 fire。**
- 機制：mgr 要有 mon quorum 才能更新 cluster 視圖。quorum 一沒，mgr 凍結在最後已知狀態，但 prometheus HTTP endpoint 仍持續吐這份 stale 資料（所以 scrape 還成功、up=1）。
- **結論（架構級限制）**：`CephMonQuorumLost` / `CephMonDownScoped` 讀的是 **mgr 匯出**的 `ceph_mon_quorum_status`，而 mgr 本身依賴 quorum。所以這條「生命線」對 graceful 的單台下線（S3，quorum 還在、mgr 能更新）有效，但對**真正的 quorum 失守是盲的**——metric 說一切正常、沒有任何 alert。要偵測真 quorum loss 必須走**叢集外的 out-of-band 手段**（blackbox 探每台 mon 的 port、外部 quorum 檢查、或對 metric 凍結/staleness 告警）。
- 對照 F1（Tier A 的 empty-vector bug）：兩者都讓「quorum 全失守」這個最壞情況靜默，但成因不同——F1 是 PromQL `count(空)` 語意（規則層，可用 `or vector(0)` 修），S4 是 metric 來源凍結（架構層，規則層修不了）。**F1 修好後也救不了 S4**：就算 `or vector(0)` 正確，mgr 凍結時 count 仍是 stale 的 3，不會觸發。
- 還原：trap `systemctl start` mon-01+mon-03 → 38s 內 3-mon quorum + HEALTH_OK。

## 真機 vs 頁面假設總結
| 頁面假設 | 真 ceph v19.2.3 | 結果 |
|---|---|---|
| metric label（ceph_daemon/hostname/name/severity） | 完全相符；ceph_osd_up 只帶 ceph_daemon | ✅ 規則設計成立 |
| stopped mon 仍匯出 quorum_status=0 + metadata | graceful 下線時成立（S3） | ✅ scoped silence 接得到 |
| 維護升 `OSDMAP_FLAGS`（noout） | 實際升 **`OSD_FLAGS`**（subtree noout） | 🔴 排除清單名字錯 → 維護照樣 page |
| CephMonQuorumLost 是 quorum 失守生命線 | 真失守時 mgr metric 凍結、不 fire | 🔴 架構級盲區，需 out-of-band |
| scoped 去重 / silence 粒度 | osd/host/mon 都如設計 | ✅ |
