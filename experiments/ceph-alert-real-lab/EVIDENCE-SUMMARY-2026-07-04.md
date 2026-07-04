# Ceph Alert Real Lab Evidence Summary - 2026-07-04

This summary records the real-lab evidence used by the Ceph alert findings page.
The raw `results/` directories are intentionally ignored by git; keep this file
as the committed evidence index.

## Scope

- Lab: cephadm Ceph v19.2.3 with Rook external on the isolated k0s node.
- Monitoring: temporary Prometheus + Alertmanager + webhook sink in the lab k8s cluster.
- Rules under test: `CephClientBlocked` and `CephMonQuorumLost` from `ceph-stability-first`.
- After this evidence was collected, no further cluster modification is required for the documentation update.

## Evidence Index

| Scenario | Raw result directory | Fault injection | Ceph evidence | Prometheus / Alertmanager evidence | Outcome |
|---|---|---|---|---|---|
| `CephClientBlocked{name="SLOW_OPS"}` | `results/slow-ops-20260704T101128Z.jVmRwg` | cgroup v2 `io.max` throttled `osd.6` on `192.168.18.174`, backing device `/dev/sdb`, while `rados bench` wrote to the test pool | `health-check-SLOW_OPS.txt` shows `SLOW_OPS` and `BLUESTORE_SLOW_OP_ALERT` for `osd.6` | `prometheus-alerts-CephClientBlocked-name.json` shows `state="firing"`, `name="SLOW_OPS"`, `activeAt="2026-07-04T10:12:42.762155964Z"`; sink log reached pager | Passed |
| `CephClientBlocked{name="PG_AVAILABILITY"}` | `results/pg-availability-20260704T102730Z.v5y7kq` | stopped acting OSDs `5` and `8` for the test pool object | `health-check-PG_AVAILABILITY.txt` shows `PG_AVAILABILITY`, `OSD_DOWN`, and inactive PG `2.10` | `prometheus-alerts-CephClientBlocked-name.json` shows `state="firing"`, `name="PG_AVAILABILITY"`, `activeAt="2026-07-04T10:28:57.762155964Z"`; sink log reached pager | Passed |
| `CephMonQuorumLost` | `results/mon-quorum-lost-20260704T103154Z.W6kB7d` | first stopped `ceph-lab-mon-01` and `ceph-lab-mon-03`; then manually stopped `ceph-lab-mon-02` and active mgr to exercise the empty-series path | `ceph-quorum-after-stop.json` exits `255`, showing quorum commands could no longer complete | `prometheus-ceph-mon-quorum-status.json` still reports `3` after the first two mon stops, proving stale mgr/exporter telemetry; after active mgr/exporter stop, `prometheus-alerts-CephMonQuorumLost-none.json` shows `state="firing"`, `activeAt="2026-07-04T10:34:37.762155964Z"`; sink log reached pager | Passed only on empty-series path; stale telemetry found |

## Findings

1. `CephClientBlocked` is effective for both real `SLOW_OPS` and real `PG_AVAILABILITY`.
2. Disk I/O delay can be injected realistically with cgroup v2 `io.max` without remapping live OSD block devices.
3. `SLOW_OPS` may appear together with `BLUESTORE_SLOW_OP_ALERT`; the latter should be tracked as an OSD engine / BlueStore signal, not merged into the immediate client-blocked page.
4. `POOL_APP_NOT_ENABLED` appeared during test-pool scenarios and should not be a critical catch-all page.
5. `CephMonQuorumLost` cannot rely on a single mgr exporter view as the only quorum-loss detector. In this lab, the single scraped exporter kept reporting `sum(ceph_mon_quorum_status)=3` after real quorum loss. The rule fired only after the exporter path became empty and `or vector(0)` took effect.
