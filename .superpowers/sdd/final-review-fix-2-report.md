# Final Review Fix 2 Report

## Scope

Fixed the remaining final re-review blockers for `experiments/ceph-alert-real-lab` before live Task 9:

- Changed `SLOW_OPS` so `rados bench` runs as a local background capture instead of blocking the rollback path.
- Added cleanup logic that kills and waits the background bench capture before and after unthrottling.
- Made manual `run/cleanup.sh` load the newest `results/slow-ops-*/selected-target.env` before considering explicit `SLOW_OPS_*` overrides.
- Removed the stale implicit cleanup default of OSD 0 / `/dev/sdb`.
- Added host `ceph-volume` discovery with fallback to `sudo -n cephadm shell -- ceph-volume lvm list --format json`.
- Recorded `ceph_volume_method=host|cephadm` in `selected-target.env` and `ceph-volume-method.txt`.
- Added portable URL encoding for Prometheus instant query PromQL.
- Updated README SLOW_OPS usage so the dynamic command is first and overrides are troubleshooting-only.

## RED Evidence

After adding the first focused regression test, the old cleanup behavior failed:

```text
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
...
FAIL: missing selected-target cgroup cleanup command
```

Later focused test additions also protected the other blockers:

- `test-scenario-slow-ops.sh` now fails if the scenario does not poll health while a fake bench is still running.
- `test-scenario-slow-ops.sh` now fails unless host `ceph-volume` failure falls back to cephadm and records `ceph_volume_method=cephadm`.
- `test-monitoring-render.sh` now fails unless PromQL URLs contain encoded forms like `up%7Bjob%3D%22ceph%22%7D` and `sum%28ceph_mon_quorum_status%29`.

## GREEN Evidence

```text
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Result:

```text
ok: common helpers
ok: all.sh destructive ack guard
ok: cleanup best-effort and stdout clean
ok: scenario command generation
ok: slow-ops destructive ack guard
ok: pg-availability destructive ack guard
ok: mon-quorum-lost destructive ack guard
ok: evidence helpers
ok: monitoring manifest render
ok: unit tests
```

The expected negative-path assertions still print timeout lines for recovery and stale sink alerts.

```text
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
```

Exited 0.

```text
make validate
```

Exited 0. `scripts/validate.py` reported all checks passed, including the Next.js build and `/learning-k8s` exported HTML basePath check.

## Commands Run

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```

All three commands exited 0 after the fixes.

## Concerns

- Per instruction, I did not run live/destructive cluster commands. Live Task 9 still needs to prove the async bench lifecycle, cephadm `ceph-volume` fallback, and recorded selected-target cleanup against the real Ceph/Rook/Prometheus lab.
- The pre-existing dirty `linux` submodule was not touched.
