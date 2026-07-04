# Task 8 Report: Full Orchestrator, Cleanup, And Final Gates

## Status

DONE

## Scope completed

- Created `experiments/ceph-alert-real-lab/run/all.sh`
- Expanded `experiments/ceph-alert-real-lab/run/cleanup.sh`
- Updated `experiments/ceph-alert-real-lab/README.md`
- Added focused local tests for orchestrator ack-first behavior and cleanup stdout cleanliness

## Files changed

- `experiments/ceph-alert-real-lab/run/all.sh`
- `experiments/ceph-alert-real-lab/run/cleanup.sh`
- `experiments/ceph-alert-real-lab/README.md`
- `experiments/ceph-alert-real-lab/tests/test-all.sh`
- `experiments/ceph-alert-real-lab/tests/test-cleanup.sh`
- `experiments/ceph-alert-real-lab/tests/run-tests.sh`

## Implementation notes

### `run/all.sh`

- Uses `require_destructive_ack all "$@"` before invoking any deploy, baseline, or scenario script
- Runs the existing sequence:
  1. `run/deploy-monitoring.sh`
  2. `run/baseline.sh`
  3. `run/scenario-slow-ops.sh --yes-really-inject`
  4. `run/scenario-pg-availability.sh --yes-really-inject`
  5. `run/scenario-mon-quorum-lost.sh --yes-really-inject`
- Emits final completion log to stderr

### `run/cleanup.sh`

- Keeps stdout clean by redirecting live-command stdout/stderr away from the caller
- Best-effort deletes:
  - monitoring namespace
  - `alert-slow-ops` pool
  - `alert-pg-availability` pool
- Best-effort clears the known slow-ops cgroup throttle using existing helpers from `lib/scenarios.sh`
- Logs cleanup outcomes to stderr only

### `README.md`

- Documents the top-level orchestrator path
- Keeps the step-by-step sequence for manual execution
- Adds the required local validation gate commands exactly as requested

## Test and validation evidence

### Focused red/green

- `bash experiments/ceph-alert-real-lab/tests/test-all.sh`
  - Initial red: missing `run/all.sh`, exit `127`
  - Final green: `ok: all.sh destructive ack guard`
- `bash experiments/ceph-alert-real-lab/tests/test-cleanup.sh`
  - Initial red: cleanup leaked stdout
  - Final green: `ok: cleanup best-effort and stdout clean`

### Required final gates

1. `bash experiments/ceph-alert-real-lab/tests/run-tests.sh`
   - Passed
   - Included:
     - `ok: all.sh destructive ack guard`
     - `ok: cleanup best-effort and stdout clean`
     - existing scenario/evidence/render tests all green

2. `shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh`
   - Passed with exit 0
   - No output

3. `make validate`
   - Passed
   - Summary ended with `All checks passed!`

## Self-review

- `run/all.sh` performs the destructive acknowledgement check before any downstream script invocation
- `cleanup.sh` remains bash 3.2 compatible
- `cleanup.sh` does not print to stdout in the local test harness
- Cleanup stays best-effort and does not fail the whole script on individual pool-delete or throttle-clear misses
- No destructive live-lab scenarios were executed during this task
- Did not touch the dirty `linux` submodule

## Concerns

- The cgroup throttle cleanup intentionally targets the known slow-ops default path (`SLOW_OPS_*` or lab defaults). If future scenarios add new throttle locations, cleanup will need a matching explicit safe cleanup path.
