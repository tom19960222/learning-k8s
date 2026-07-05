# Ceph Alert Real Lab

這個 harness 會在隔離 lab 裡製造真實 Ceph 故障，驗證 `prometheus-alert-design` 的 `CephClientBlocked` 與 `CephMonQuorumLost` 是否真的 firing 並送到 Alertmanager pager receiver。

## 安全界線

- 每個注入腳本都需要 `--yes-really-inject`。
- 先跑 `run/deploy-monitoring.sh` 與 `run/baseline.sh`。
- 每個情境完成後都要確認 Ceph 回到 `HEALTH_OK` 再跑下一個。
- 不要在非 lab 環境執行。

## 建議順序

```bash
bash experiments/ceph-alert-real-lab/run/all.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/cleanup.sh
```

如果要逐步執行，再照下面順序跑：

```bash
bash experiments/ceph-alert-real-lab/run/deploy-monitoring.sh
bash experiments/ceph-alert-real-lab/run/baseline.sh
bash experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/cleanup.sh
```

## 本機驗證 gate

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```

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

這個情境會用一個「本機背景迴圈」持續打 `rados bench` 到測試 pool（最多 45 輪、每輪 60 秒），讓 `ceph_cluster_total_used_bytes` 累積出足夠的成長斜率，等待 `predict_linear(...)` 推算 3 天後會超過 85% 容量並觸發 `CephCapacityForecast`，確認只進 Slack、不進 pager，最後 kill 掉背景迴圈並刪除 pool rollback。**注意：`for: 30m`，真的跑（`--yes-really-inject`）wall-clock 可能超過 45 分鐘，且會在測試 pool 寫入數十 GiB 的資料（這個 lab 叢集有 900GiB 可用空間，足夠安全）。**

```bash
bash experiments/ceph-alert-real-lab/run/scenario-capacity-forecast.sh --yes-really-inject
```
