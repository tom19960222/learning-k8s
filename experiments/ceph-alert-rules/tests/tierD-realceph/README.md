# Tier D — 真 ceph 對照（在你環境跑後對照）

Tier A/B/C 證明的是「**若** metric / health check 以頁面假設的 label 與值存在，規則就會如設計行為」。但「ceph 在某個維護/故障情境下**真的**會升哪些 health check、stopped 的 daemon 是否仍匯出 metric」只有真 ceph 能回答。本表把這層用 **ceph 原始碼當 oracle**（行號取自 ceph v19.2.3，與被測頁一致），給你在 Proxmox + 3-node + ceph 叢集跑完後逐欄對照。

> 破壞性操作（`maintenance enter`、停 OSD、停 mon）請先讀被測頁 [Prometheus alert 設計](../../../next-site/content/ceph/features/prometheus-alert-design.mdx) 的維護 silence 與回退步驟。本表只列「預期」，不替你決定要不要動手。

## 對照表

| 情境（觸發動作） | ceph 預期升起的 health check（原始碼 oracle） | 預期 pager 行為（本頁設計） | 在你環境實際看到（待填） |
|---|---|---|---|
| **維護單台 mon**：`ceph orch host maintenance enter mon-host-a` | `MON_DOWN`（`HealthMonitor.cc:820`，HEALTH_WARN）、`HOST_IN_MAINTENANCE`（`cephadm/module.py:2126`，HEALTH_WARN） | `CephMonDownScoped{ceph_daemon=mon.a,hostname=mon-host-a}` page（用 hostname/ceph_daemon silence）；`CephClientRisk{name=MON_DOWN}` **不** page（MON_DOWN 在排除清單）；`HOST_IN_MAINTENANCE` 只進 Slack（`CephLowPriorityNotice`） | ☐ |
| **維護整台 OSD node**：`ceph orch host maintenance enter osd-host-a` | 停該 host 全部 OSD → `OSD_HOST_DOWN`/`OSD_DOWN`（`OSDMap.cc:7316`/`7342`，HEALTH_WARN）；自動對 subtree 設 `noout`（`cephadm/module.py:2131`）→ `OSDMAP_FLAGS`（`OSDMap.cc:7493`）；副本掉一份 → `PG_DEGRADED`（`PGMap.cc:2578`，HEALTH_WARN） | 唯一 pager 訊號 `CephOSDHostDownScoped{hostname=osd-host-a}`（用 hostname silence）；`OSDMAP_FLAGS`/`PG_DEGRADED` 只進 Slack、且在 `CephClientRisk` 排除清單 → **不** page；整台 down 不會每顆 OSD 各叫一次（`unless on hostname` 去重） | ☐ |
| **維護單顆 OSD / 換硬碟**：`ceph osd ok-to-stop 5` → 停 osd.5 | `OSD_DOWN`（`OSDMap.cc:7342`）；副本掉一份 → `PG_DEGRADED`（`PGMap.cc:2578`）；若先設 `noout` → `OSDMAP_FLAGS`（`OSDMap.cc:7493`） | `CephOSDDaemonDownScoped{ceph_daemon=osd.5}` page（用 ceph_daemon silence）；`PG_DEGRADED`/`OSDMAP_FLAGS` 不 page。唯一仍 page 的是真出事：若掉到 `min_size` 以下變 `PG_AVAILABILITY` → `CephClientBlocked` page（不該 silence） | ☐ |
| **真 MON quorum 失守**：3-mon 掉 2 台（或全掉） | `MON_DOWN`（`HealthMonitor.cc:820`）；mgr/prometheus 對 monmap 每個 mon 都匯出 `mon_quorum_status`（停掉的仍在 monmap，值 0；`prometheus/module.py:1021`） | `CephMonQuorumLost` page（**含全掉**——靠 `or vector(0)`，見下方 F1 註記）；`CephMonDownScoped` 對每台失聯 mon page；**不要 silence** | ☐ |

## 關鍵驗證點（在真 ceph 上對照本計劃的假設）

1. **stopped mon 仍有 metric**：停一台 mon 後，`ceph_mon_quorum_status{ceph_daemon="mon.a"}` 應仍存在且 = 0，`ceph_mon_metadata{ceph_daemon="mon.a",hostname=...}` 仍存在。這是 `CephMonDownScoped` 能精準 silence 的前提（Tier A §4.12 的「缺 metadata 不 fire」測的是反例；這裡確認正例在真 ceph 成立）。查法：
   ```bash
   curl -s "http://<mgr>:9283/metrics" | grep -E 'ceph_mon_(quorum_status|metadata)'
   ```
2. **stopped OSD 的 metadata 仍在**：`ceph_osd_metadata{ceph_daemon="osd.5",hostname=...}` 在 osd.5 down 後仍應存在（否則 `ceph:osd_up:with_hostname` 的 join 會掉這顆，scoped 規則變盲——Tier A §4.8 的「缺 metadata」測的就是這個盲區）。
3. **F1（empty-vector bug）的兩種風險要分開看**：
   - *scenario realism（真叢集的事）*：dev 用 promtool 證明 `count(==1)` 全掉時為空、`or vector(0)` 修好；在真 3-mon 上把 2 台、3 台 mon 停掉，確認 `CephMonQuorumLost` 兩種情況都 page。
   - *fix completeness（dev 已驗、但需你決策的事）*：`or vector(0)` 也會在「`ceph_mon_quorum_status` 完全不存在」（mgr 剛重啟等）時 fire——這是 metric 缺席不是 mon 掛掉，寫死版分不出來。dev 已用 promtool 把這個行為測出來並記錄（寫死版 fire、metadata-anchored 動態版不 fire）。真叢集只驗前者，**不會**幫你回答「要不要接受 absence-fire」——那是設計取捨，見設計頁 callout。
4. **recording rule 的 cardinality 安全（devil #4）**：`count by (hostname)(X==0) == count by (hostname)(X)` 兩邊都是每 hostname 一列，one-to-one 成立。但若 `ceph_osd_metadata` 因故對同一 `ceph_daemon` 出現重複 series（hostname 不同），join 會讓某 hostname 出現多列 → Prometheus 對 many-to-one 是 **eval 時 hard-error 整個 rule group**（不是 silently 算錯）。真叢集若看到該 group `health=err`，先查 metadata 是否有重複。

> 對照完把每列「待填」打勾或記下差異；有出入優先相信真 ceph，並回頭修頁面假設與 Tier A 測試。
