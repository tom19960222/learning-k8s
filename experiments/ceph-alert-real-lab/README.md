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
