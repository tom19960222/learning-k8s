# Task 1 Report: Harness Skeleton, Inventory, and Test Runner

## What I implemented

- Added the initial Ceph incident bundle harness skeleton under `experiments/ceph-incident-bundle/`.
- Created the test runner at `experiments/ceph-incident-bundle/tests/run-tests.sh`.
- Added the required shell entrypoints and helper skeletons:
  - `experiments/ceph-incident-bundle/run/collect.sh`
  - `experiments/ceph-incident-bundle/lib/common.sh`
  - `experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh`
  - `experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh`
  - `experiments/ceph-incident-bundle/lib/collect-node.sh`
  - `experiments/ceph-incident-bundle/lib/verify-bundle.sh`
- Added the lab inventory example at `experiments/ceph-incident-bundle/inventory/ceph-lab.example.env`.
- Added the results placeholder and ignore rules:
  - `experiments/ceph-incident-bundle/results/.gitkeep`
  - `experiments/ceph-incident-bundle/.gitignore`
- Added a fixtures placeholder README at `experiments/ceph-incident-bundle/tests/fixtures/README.md`.

## What I tested and test results

- `bash experiments/ceph-incident-bundle/tests/run-tests.sh`
  - Result: passes
  - Output:
    ```text
    ok: required files exist
    ```
- `bash -n experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/*.sh`
  - Result: passes with exit 0

## TDD Evidence

### RED

Command:

```bash
bash experiments/ceph-incident-bundle/tests/run-tests.sh
```

Output:

```text
FAIL: missing /Users/ikaros/Documents/code/learning-k8s/.claude/worktrees/ceph-incident-bundle/experiments/ceph-incident-bundle/run/collect.sh
```

### GREEN

Command:

```bash
bash experiments/ceph-incident-bundle/tests/run-tests.sh
bash -n experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/*.sh
```

Output:

```text
ok: required files exist
```

## Files changed

- `experiments/ceph-incident-bundle/.gitignore`
- `experiments/ceph-incident-bundle/inventory/ceph-lab.example.env`
- `experiments/ceph-incident-bundle/results/.gitkeep`
- `experiments/ceph-incident-bundle/tests/run-tests.sh`
- `experiments/ceph-incident-bundle/tests/fixtures/README.md`
- `experiments/ceph-incident-bundle/run/collect.sh`
- `experiments/ceph-incident-bundle/lib/common.sh`
- `experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh`
- `experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh`
- `experiments/ceph-incident-bundle/lib/collect-node.sh`
- `experiments/ceph-incident-bundle/lib/verify-bundle.sh`

## Self-review findings

- The harness test is narrowly scoped to file existence and executability, which matches Task 1.
- The executable entrypoints use `set -euo pipefail`, a short English comment, and a `main "$@"` guard.
- Helper scripts only define stub functions and do not implement collector logic yet.

## Any concerns

- None for this task slice. The bundle is still a skeleton by design; real collector behavior is intentionally deferred to later tasks.
