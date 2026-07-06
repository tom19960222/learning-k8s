# Ceph Alert Real Lab

這個 harness 會在隔離 lab 裡製造真實 Ceph 故障，驗證 `prometheus-alert-design` 的 `CephClientBlocked` 與 `CephMonQuorumLost` 是否真的 firing 並送到 Alertmanager pager receiver。

## 安全界線

- 每個注入腳本都需要 `--yes-really-inject`。
- 先跑 `run/deploy-monitoring.sh` 與 `run/baseline.sh`。
- 每個情境完成後都要確認 Ceph 回到 `HEALTH_OK` 再跑下一個。
- 不要在非 lab 環境執行。

## 建議順序

`run/all.sh` v2 內建 `run/cleanup.sh`，跑完整條情境鏈後會自動清理，不用再手動補一次：

```bash
bash experiments/ceph-alert-real-lab/run/all.sh --yes-really-inject
```

如果要逐步執行，再照下面順序跑（完整順序與隔離原因見下方「情境一覽」與 `run/all.sh` 內的分組註解）：

```bash
bash experiments/ceph-alert-real-lab/run/deploy-monitoring.sh
bash experiments/ceph-alert-real-lab/run/baseline.sh
bash experiments/ceph-alert-real-lab/run/scenario-catch-all-risk.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/scenario-mon-disk-low.sh --yes-really-inject
# ...（其餘情境依 run/all.sh 的順序逐一執行）
bash experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/cleanup.sh
```

`run/cleanup.sh` 本身是 best-effort、可重複執行：任何一個情境中途失敗、`all.sh` 提早中止時，都可以單獨補跑它。

## 本機驗證 gate

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```

## 情境一覽

`run/all.sh` v2 的執行順序（隔離原因見腳本內註解：config-only 先跑 → service-level → 單一 daemon up/down（`osd-flapping` 因為 `changes(ceph_osd_up[15m])` 的 15 分鐘視窗殿後）→ IO/網路劣化 → `pg-availability`（一次停兩顆 OSD）→ capacity 三部曲 → 資料完整性 → `low-priority-notice`（長 wall-clock 但獨立）→ `mon-quorum-lost`（影響面最大，殿後）→ `cleanup`）：

| 場景 | 注入手法 | 預期 alert（`for:`） | Wall-clock（設計估算，未經真機量測） | 特殊參數 |
|---|---|---|---|---|
| `catch-all-risk` | `ceph config set mon mon_osd_down_out_interval 0` | `CephClientRisk`{name=`OSD_NO_DOWN_OUT_INTERVAL`}（5m） | 約 5–8 分鐘 | 無 |
| `mon-disk-low` | 依 mon-01 實際 free% 動態算 `mon_data_avail_warn`/`mon_data_avail_crit`（兩階段 `ceph config set`） | `CephMonDiskLow`（10m，Slack）→ `CephMonDiskCritical`（1m，pager） | 約 12–15 分鐘 | 無（門檻自動推導；mon-01 free% ≥ 97% 會 `die`） |
| `mon-clock-skew` | 停 mon-03 的 `systemd-timesyncd`/`chronyd`，`date -s '+2 seconds'` | `CephMonClockSkew`（2m） | 約 3–5 分鐘 | `MON_CLOCK_SKEW_NAME` |
| `mgr-failover` | `ceph mgr fail` 後停 standby mgr | `CephMgrNoStandby`（5m，Slack） | 約 6–9 分鐘 | 無 |
| `exporter-blind` | `ceph mgr module disable prometheus` | `CephMetricsAbsent`（5m）+ `CephExporterAllDown`（5m），皆 pager | 約 6–9 分鐘 | 無 |
| `osd-daemon-down` | 停單顆 OSD systemd service | `CephOSDDaemonDownScoped`（5m，pager）+ `CephOSDDown`（Slack） | 約 6–9 分鐘 | `OSD_DOWN_HOST`、`OSD_DOWN_ID` |
| `mon-down-single` | 停單顆非 active-mgr 所在的 mon | `CephMonDownScoped`（30s，pager） | 約 2–3 分鐘 | `MON_DOWN_NAME` |
| `osd-host-down` | 停整台 host 上所有 OSD | `CephOSDHostDownScoped`（5m，pager） | 約 6–9 分鐘 | `OSD_HOST_DOWN_HOST` |
| `daemon-crash` | `kill -SEGV` OSD process | `CephDaemonRecentCrash`（5m，Slack；pager 需 absent） | 約 6–10 分鐘 | `DAEMON_CRASH_HOST`、`DAEMON_CRASH_OSD_ID` |
| `osd-flapping` | 單顆 OSD 連續 4 次 stop/start | `CephOSDFlapping`（無 `for:`，pager） | 約 3–6 分鐘 | `OSD_FLAP_HOST`、`OSD_FLAP_ID` |
| `slow-ops` | cgroup v2 `io.max` 限速 backing device + `rados bench` | `CephClientBlocked`{name=`SLOW_OPS`}（1m）+ `CephDaemonSlowOps`（3m，Slack） | 約 5–8 分鐘 | `SLOW_OPS_OSD_ID`/`_OSD_HOST`/`_DEVICE`、`SLOW_OPS_POOL` |
| `latency-outlier` | 較輕的 `io.max` 限速 + 涵蓋整個 `for:` 視窗的 `rados bench`（必要時重試一次） | `CephOSDLatencyOutlier`（10m，Slack；pager 需 absent） | 約 19–38 分鐘（視是否重試） | `LATENCY_BENCH_SECONDS` |
| `net-slow-heartbeat` | `tc qdisc add ... netem delay 1200ms`（預先武裝 auto-revert 計時器） | `CephOSDSlowHeartbeat`（2m，pager） | 約 3–5 分鐘 | `NET_SLOW_HEARTBEAT_ARM_SLEEP` |
| `pg-availability` | 停測試 pool sentinel object 的兩顆 acting OSD | `CephClientBlocked`{name=`PG_AVAILABILITY`}（1m）+ `CephPGUnhealthyStates`{name=pool}（3m），皆 pager | 約 5–8 分鐘 | `PG_AVAIL_POOL`、`PG_AVAIL_OBJECT` |
| `pool-quota` | 受控 `rados put` 打到 81% quota，再打到滿 | `CephPoolNearQuota`（10m，Slack）→ `POOL_FULL`/`CephClientBlocked`（1m，pager） | 約 12–16 分鐘 | `QUOTA_POOL`、`QUOTA_MAX_BYTES`、`NEARQUOTA_TARGET_BYTES` |
| `capacity-ladder` | 動態量測最滿 OSD 的實際使用率，再依序調低 nearfull/backfillfull/full 三階 ratio（三個 ratio 分別是量到的使用率的 0.6／0.7／0.8 倍，動態推導、非固定門檻） | `CephOSDNearFull`（10m，Slack）→ `CephOSDBackfillFull`（5m，pager）→ `CephClientBlocked`{name=`OSD_FULL`}（1m）→ `CephHealthError`（5m） | 約 25–30 分鐘 | `CAPACITY_POOL`、`CAPACITY_TARGET_OSD_UTIL`（預設 0.5，即 0.5%）、`CAPACITY_MAX_ROUNDS` |
| `capacity-forecast` | 3 條並行、各自連續執行到底的 `rados bench` stream（不是分輪迴圈，每條 stream 一次跑滿整個注入視窗）拉出成長斜率 | `CephCapacityForecast`（30m，Slack；pager 需 absent） | **注意：`for: 30m`，wall-clock 約 55–75 分鐘**，且會寫入約 27GiB 測試資料 | `FORECAST_STREAM_SECONDS`（預設 4500）、`FORECAST_BENCH_THREADS`、`FORECAST_POOL` |
| `data-damage` | 停 OSD → `ceph-objectstore-tool ... set-bytes` 損毀單一 replica 的 object 內容（而非刪除，deterministic、不會被 recovery 自動治好）→ 重啟 → `deep-scrub` | `CephDataDamage`{name=`PG_DAMAGED`\|`OSD_SCRUB_ERRORS`}（1m，pager） | 約 8–15 分鐘（deep-scrub 排程時間不定） | `DATA_DAMAGE_POOL`、`DATA_DAMAGE_OBJECT` |
| `object-unfound` | 6 步驟操作兩顆 acting OSD + `rados put` 造出兩個版本 + `norecover` | `CephObjectUnfound`（1m，pager） | 約 4–7 分鐘 | `UNFOUND_POOL`、`UNFOUND_OBJECT` |
| `low-priority-notice` | `ceph osd set noout` | `CephLowPriorityNotice`{name=`OSDMAP_FLAGS`}（30m，Slack；pager 需 absent） | **注意：`for: 30m`，wall-clock 會超過 30 分鐘** | 無 |
| `mon-quorum-lost` | 停 mon-01 與 mon-03（保留 active-mgr 所在的 mon-02） | `CephMonQuorumLost`（1m，pager）+ `CephMonDownScoped` 需在 Alertmanager 被 inhibit | 約 5–20 分鐘（真機 mgr exporter 在全 quorum 遺失時會凍結，見腳本內註解的時序風險） | 無 |

`mon-disk-low`（S21）與 `baseline.sh` 的 Watchdog 心跳斷言（S22）是本次新增；`slow-ops`（S1）、`pg-availability`（S2）、`mon-quorum-lost`（S3）在本次擴充了原本就有的斷言（見上表對應行）。所有 wall-clock 都是依 `for:` 條款與 poll 次數推算的設計估算值，尚未在真機 Phase 2 執行中逐一量測；真機驗證後應對照更新。

## SLOW_OPS

主測用 cgroup v2 `io.max` 對 OSD backing device 限速，然後用 `rados bench` 打測試 pool。

```bash
bash experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh --yes-really-inject
```

正常情況會自動從測試 object 的 acting set 選 OSD，並用 `ceph-volume` 找 backing device。只有在排查自動選擇結果時才手動指定：

```bash
SLOW_OPS_OSD_ID=0 \
SLOW_OPS_OSD_HOST=192.168.18.169 \
SLOW_OPS_DEVICE=/dev/sdb \
bash experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh --yes-really-inject
```

## PG_AVAILABILITY

這個情境會建立測試 pool，找 sentinel object 的 acting set，停止兩顆 acting OSD，等待 `PG_AVAILABILITY` 與 `CephClientBlocked{name="PG_AVAILABILITY"}` 出現，再自動 rollback。

```bash
bash experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh --yes-really-inject
```

## CephMonQuorumLost

這個情境會保留 active mgr 所在的 `ceph-lab-mon-02`，停止 `ceph-lab-mon-01` 與 `ceph-lab-mon-03`，等待 `CephMonQuorumLost` firing 並進 pager，最後自動 rollback。

```bash
bash experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh --yes-really-inject
```

## CephLowPriorityNotice

這個情境會 `ceph osd set noout` 觸發 `OSDMAP_FLAGS`，等待 `CephLowPriorityNotice{name="OSDMAP_FLAGS"}` 只進 Slack、不進 pager，最後 `ceph osd unset noout` rollback。**注意：`for: 30m`，真的跑（`--yes-really-inject`）wall-clock 會超過 30 分鐘。**

```bash
bash experiments/ceph-alert-real-lab/run/scenario-low-priority-notice.sh --yes-really-inject
```

## CephCapacityForecast

這個情境會啟動 3 條並行、各自連續執行到底的 `rados bench` stream（每條撐滿整個 `FORECAST_STREAM_SECONDS` 注入視窗，不是分輪迴圈、不會重啟），讓 `ceph_cluster_total_used_bytes` 累積出足夠的成長斜率，等待 `predict_linear(...)` 推算 3 天後會超過 85% 容量並觸發 `CephCapacityForecast`，確認只進 Slack、不進 pager，最後停掉 3 條 stream 並刪除 pool rollback。**注意：`for: 30m`，真的跑（`--yes-really-inject`）wall-clock 約 55–75 分鐘，且會在測試 pool 寫入約 27GiB 的資料（這個 lab 叢集有 900GiB 可用空間，足夠安全）。**

```bash
bash experiments/ceph-alert-real-lab/run/scenario-capacity-forecast.sh --yes-really-inject
```
