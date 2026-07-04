# Final Review Fix Report

## Scope

Fixed the final whole-branch review blockers for `experiments/ceph-alert-real-lab` before live Task 9:

- Added mandatory pre-injection readiness and post-cleanup recovery gates.
- Made scenario success require bounded recovery before printing `result:`.
- Changed `SLOW_OPS` from hard-coded OSD 0 / `/dev/sdb` to dynamic acting OSD, host, and ceph-volume device discovery with override verification.
- Added `wait_ceph_health_check` polling for `SLOW_OPS` and `PG_AVAILABILITY`.
- Added mon quorum-loss evidence capture via `sum(ceph_mon_quorum_status)` with Ceph CLI quorum fallback evidence.
- Added sink log checkpointing so stale pre-injection pager logs do not satisfy `wait_sink_alert`.
- Moved monitoring apply/rollout output to stderr and made `run/deploy-monitoring.sh` emit one stdout line: `monitoring: ceph-alert-lab`.
- Removed the unused `sys` import from the alert sink script.
- Added a negative assertion that the mon quorum scenario does not stop mon-02.

## RED Evidence

New/expanded fake tests initially failed before the final fixes:

```text
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
...
FAIL: expected one stdout line on success, got 0
```

Root cause found during the RED run:

```text
/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/monitoring.sh: line 318: result_dir: unbound variable
```

This exposed two real issues while exercising the new blockers:

- The best-effort `EXIT` trap could mask an earlier scenario failure.
- Same-line `local result_dir=$1 output_file="$result_dir/..."` was brittle under Bash 3.2 + `set -u`.

## GREEN Evidence

```text
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Result:

```text
ok: slow-ops destructive ack guard
ok: pg-availability destructive ack guard
ok: mon-quorum-lost destructive ack guard
TIMEOUT: Ceph/Rook/Prometheus recovered
ok: evidence helpers
TIMEOUT: sink pager received CephClientBlocked name=SLOW_OPS
PASS: sink pager received CephClientBlocked name=SLOW_OPS
ok: monitoring manifest render
ok: unit tests
```

The timeout lines are expected negative-path assertions:

- Recovery failure exits nonzero and does not print `result:`.
- A stale pre-checkpoint sink log does not satisfy `wait_sink_alert`.

## Commands Run

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```

All three commands exited 0 after the fixes.

## Concerns

- Per instruction, I did not run live/destructive cluster commands. The real lab still needs live Task 9 validation to prove the selected OSD/device and recovery gates against the actual Ceph/Rook/Prometheus environment.
- `wait_sink_alert` still uses a raw `kubectl --kubeconfig ...` inside its inline polling script. I kept this known minor issue because the requested stale-log blocker is fixed without widening that refactor.
- The pre-existing dirty `linux` submodule was not touched.
