# Task 5 Report: SLOW_OPS scenario

## Status

DONE_WITH_CONCERNS

## Requirements handled

- Created `experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh`
- Updated `experiments/ceph-alert-real-lab/README.md` with the exact `SLOW_OPS` invocation
- Added a local test for the destructive ack guard and wired it into `tests/run-tests.sh`
- Kept the implementation on the corrected live-discovery interface `cgroup_io_max_path_command(service_name)`

## Files changed

- `experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh`
- `experiments/ceph-alert-real-lab/README.md`
- `experiments/ceph-alert-real-lab/tests/test-scenario-slow-ops.sh`
- `experiments/ceph-alert-real-lab/tests/run-tests.sh`

## Implementation notes

### `scenario-slow-ops.sh`

- Requires `--yes-really-inject` before any live-capable action
- Collects baseline into `results/.../baseline` before pool creation or throttling
- Verifies cgroup v2 on the target OSD host
- Resolves the OSD backing device `MAJ:MIN` with `lsblk`
- Resolves `io.max` dynamically through `systemctl show -p ControlGroup` via `cgroup_io_max_path_command`
- Applies throttling with `io_throttle_command`
- Runs `rados bench` against a dedicated test pool
- Asserts `SLOW_OPS`, then waits for Prometheus `CephClientBlocked` and pager sink delivery
- Uses an EXIT trap rollback that:
  - unthrottles when both `MAJMIN` and `IO_PATH` were resolved
  - deletes the test pool best-effort
  - collects postcheck evidence best-effort

### Local test added

- `tests/test-scenario-slow-ops.sh` runs the script without `--yes-really-inject`
- Verifies exit code `2`
- Verifies stderr contains `slow-ops requires --yes-really-inject`
- Verifies no stdout is emitted in that path

## Evidence

### Red -> green TDD step

Initial run before the script existed:

```text
bash experiments/ceph-alert-real-lab/tests/test-scenario-slow-ops.sh
FAIL: expected exit 2 without destructive ack, got 127
```

Passing run after implementation:

```text
bash experiments/ceph-alert-real-lab/tests/test-scenario-slow-ops.sh
ok: slow-ops destructive ack guard
```

### Required validation

```text
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
ok: common helpers
ok: scenario command generation
ok: slow-ops destructive ack guard
ok: evidence helpers
ok: monitoring manifest render
ok: unit tests
```

```text
bash -n experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh
exit 0
```

```text
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
exit 0
```

### Additional validation

```text
make validate
All checks passed, including Next.js build and /learning-k8s basePath export validation.
```

## Self-review

- Confirmed no hard-coded cgroup path was introduced; the script uses `cgroup_io_max_path_command("$OSD_SERVICE")`
- Confirmed rollback is safe to call even on partial setup because cleanup gates unthrottle on resolved values and makes pool/postcheck best-effort
- Confirmed the task diff does not touch the dirty `linux` submodule
- Confirmed README wording stays in繁體中文 and keeps required technical nouns in English

## Concerns

- The destructive live path was intentionally not executed per task instruction, so end-to-end validation against the real lab remains pending for a later authorized run.
