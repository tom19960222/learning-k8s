# Task 7 Report: CephMonQuorumLost scenario

## Status

Completed locally without touching the live lab. This task only added the scenario script, local tests, and README docs.

## Requirements covered

- Added `experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh`.
- Updated `experiments/ceph-alert-real-lab/README.md` with usage and scenario description.
- Added local test coverage for:
  - destructive ack guard before any live-capable command or result dir creation
  - fake-live success path
  - stop/restart ordering
  - stdout cleanliness on success
- Kept the script Bash 3.2 compatible.
- Did not execute real ssh, kubectl, or ceph commands.

## Implementation summary

### Scenario script

- Uses `require_destructive_ack mon-quorum-lost "$@"` before `new_result_dir`.
- Collects baseline into `baseline/`.
- Stops only:
  - `ceph-lab-mon-01`
  - `ceph-lab-mon-03`
- Leaves `ceph-lab-mon-02` untouched.
- Records each target in `stopped-mons.txt` before issuing the stop command so rollback can restore partial injection.
- Waits for:
  - Prometheus `CephMonQuorumLost`
  - pager sink receipt of `CephMonQuorumLost`
- Always rolls back via `trap cleanup EXIT`, restarting any recorded mons and collecting `postcheck/`.
- Keeps stdout clean except for the final `result: <dir>` line.
- Routes operational output through `run_capture`.

### Test coverage

- Added `experiments/ceph-alert-real-lab/tests/test-scenario-mon-quorum-lost.sh`.
- Extended `experiments/ceph-alert-real-lab/tests/run-tests.sh`.
- Fake-live test verifies:
  - no live-capable commands run before `--yes-really-inject`
  - no result dir is created before destructive ack
  - stop commands target mon-01 and mon-03
  - rollback restarts mon-01 and mon-03
  - restart ordering happens after stop ordering
  - scenario stdout contains only the final result line

## Files changed

- `experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh`
- `experiments/ceph-alert-real-lab/tests/test-scenario-mon-quorum-lost.sh`
- `experiments/ceph-alert-real-lab/tests/run-tests.sh`
- `experiments/ceph-alert-real-lab/README.md`

## Verification evidence

### Local fake-live artifact check

The fake-live success test created a result directory with the expected outputs, including:

- `baseline/`
- `stop-mon-1.txt`
- `stop-mon-2.txt`
- `stopped-mons.txt`
- `prometheus-alerts-CephMonQuorumLost-none.json`
- `sink.log`
- `rollback-restart-1.txt`
- `rollback-restart-2.txt`
- `postcheck/`

Sample verified result directory:

- `experiments/ceph-alert-real-lab/results/mon-quorum-lost-20260704T041416Z.gGwNiq`

### Commands run

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
bash -n experiments/ceph-alert-real-lab/run/scenario-mon-quorum-lost.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```

### Results

- `tests/run-tests.sh`: passed
- `bash -n scenario-mon-quorum-lost.sh`: passed
- `shellcheck ...`: passed with no findings
- `make validate`: passed, including Next.js build and `/learning-k8s` basePath checks

## Self-review

- Ack-first guard is in the correct position, before any result dir creation.
- Rollback is resilient to partial injection because restart targets are recorded before each stop.
- The script follows the existing scenario pattern instead of introducing new helpers or behavior.
- The implementation does not rely on live-cluster execution for validation.

## Concerns

- No live lab execution was performed by design, so end-to-end timing and real alert latency remain unverified until a separate real-lab run.
