# Ceph Alert Real Lab

這個 harness 會在隔離 lab 裡製造真實 Ceph 故障，驗證 `prometheus-alert-design` 的 `CephClientBlocked` 與 `CephMonQuorumLost` 是否真的 firing 並送到 Alertmanager pager receiver。

## 安全界線

- 每個注入腳本都需要 `--yes-really-inject`。
- 先跑 `run/deploy-monitoring.sh` 與 `run/baseline.sh`。
- 每個情境完成後都要確認 Ceph 回到 `HEALTH_OK` 再跑下一個。
- 不要在非 lab 環境執行。

## 建議順序

```bash
bash experiments/ceph-alert-real-lab/run/deploy-monitoring.sh
bash experiments/ceph-alert-real-lab/run/baseline.sh
bash experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh --yes-really-inject
bash experiments/ceph-alert-real-lab/run/cleanup.sh
```

## SLOW_OPS

主測用 cgroup v2 `io.max` 對 OSD backing device 限速，然後用 `rados bench` 打測試 pool。

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
