# Task 3 Report: Bundle Verifier with TDD

## What I implemented

- Implemented `experiments/ceph-incident-bundle/lib/verify-bundle.sh` as a real bundle verifier.
- The verifier now accepts either an extracted directory or a `.tar.gz` bundle.
- For `.tar.gz` input, it first runs `tar -tzf` to validate gzip integrity, then extracts to a temporary directory for inspection.
- It verifies the required bundle shape:
  - `manifest.jsonl`
  - `summary.txt`
  - `README-FIRST.txt`
  - at least one file under `cluster/`
  - at least one file under `nodes/`
- It rejects bundle member paths containing any of:
  - `keyring`
  - `.ssh`
  - `id_ed25519`
  - `private_key`
- On success, it prints `VERIFY PASS: <path>`.
- I also created `experiments/ceph-incident-bundle/tests/test-verify-bundle.sh` and wired it into `experiments/ceph-incident-bundle/tests/run-tests.sh`.

## What I tested and test results

- Ran the verifier test script directly:
  - `bash experiments/ceph-incident-bundle/tests/test-verify-bundle.sh`
  - Result: passed
- Ran the full test entrypoint:
  - `bash experiments/ceph-incident-bundle/tests/run-tests.sh`
  - Result: passed
- Ran repo validation:
  - `make validate`
  - Result: passed

## TDD Evidence

### RED

Command:

```bash
bash experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
```

Output:

```text
FAIL: expected success for /var/folders/0r/03g4qs0s1p75k5tsvwpk_41c0000gn/T/tmp.lKjfVbg4zv/valid-dir, got status 1: Usage: verify-bundle.sh <bundle-dir>
verify-bundle.sh: not implemented yet
```

### GREEN

Command:

```bash
bash experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
```

Output:

```text
```

Command:

```bash
bash experiments/ceph-incident-bundle/tests/run-tests.sh
```

Output:

```text
ok: required files exist
```

Command:

```bash
make validate
```

Output:

```text
✓ All checks passed!
```

## Files changed

- `experiments/ceph-incident-bundle/lib/verify-bundle.sh`
- `experiments/ceph-incident-bundle/tests/test-verify-bundle.sh`
- `experiments/ceph-incident-bundle/tests/run-tests.sh`

## Self-review findings

- I found and fixed a shell cleanup bug while verifying the archive path: a `RETURN` trap referenced an out-of-scope local variable and triggered `set -u`.
- I updated the shared test runner so its placeholder check now matches the verifier's real failure style.
- I expanded the verifier tests to cover the full forbidden-path set, not just `keyring`.

## Any concerns

- The verifier assumes bundle contents are rooted directly at the archive top level, matching the test fixtures and current task brief.
- I did not push the branch, per instruction.

## Fix addendum

### What I fixed

- Propagated failures explicitly inside `verify_bundle_tree` so archive verification cannot keep going after a validator fails.
- Added archive-negative coverage for:
  - `.tar.gz` missing `manifest.jsonl`
  - `.tar.gz` containing `keyring`
  - `.tar.gz` containing `.ssh`
  - `.tar.gz` containing `id_ed25519`
  - `.tar.gz` containing `private_key`
  - corrupt `.tar.gz`
- Rejected extra arguments with usage and a non-zero exit status.

### TDD evidence

RED command:

```bash
bash experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
```

RED output:

```text
FAIL: expected failure for /var/folders/0r/03g4qs0s1p75k5tsvwpk_41c0000gn/T/tmp.htLTVAN3d6/missing-manifest.tar.gz
```

GREEN command:

```bash
bash experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
```

GREEN output:

```text
```

### Follow-up verification

- `bash experiments/ceph-incident-bundle/tests/run-tests.sh` passed
- `make validate` passed

## Second fix addendum

### What I fixed

- Made the directory branch in `verify_bundle_path` explicitly propagate `verify_bundle_tree` failures with `|| return 1`.
- Removed the dead `lib/common.sh` import from `verify-bundle.sh`, since the verifier does not use shared helpers.
- Added an isolated `id_ed25519` negative case outside `.ssh` and covered both the extracted directory and `.tar.gz` forms.

### Test update

- Added a focused fixture that places `id_ed25519` at `cluster/ceph/id_ed25519`.
- Kept the existing `.ssh/id_ed25519` coverage so both the token and the path shape remain exercised.

### Verification

- `bash experiments/ceph-incident-bundle/tests/test-verify-bundle.sh` passed
- `bash experiments/ceph-incident-bundle/tests/run-tests.sh` passed
- `make validate` passed

## Third fix addendum

### What I fixed

- Changed the invalid path guard in `verify_bundle_path` to explicitly return after `verify_fail`, rather than relying on `set -e`.
- Removed the unused `ROOT` variable from `verify-bundle.sh`.
- Wrapped archive list/extract failures with `verify_fail "invalid archive: ..."` and suppressed tar's own stderr so corrupt archive output is consistent.

### Test update

- Updated the corrupt archive expectation from a tar-specific substring to `invalid archive`.

### Verification

- `bash experiments/ceph-incident-bundle/tests/test-verify-bundle.sh` passed
- `bash experiments/ceph-incident-bundle/tests/run-tests.sh` passed
- `make validate` passed

## Second fix addendum

### What I fixed

- Made the directory branch in `verify_bundle_path` explicitly propagate `verify_bundle_tree` failures with `|| return 1`.
- Removed the unused `lib/common.sh` import from `verify-bundle.sh`.
- Added an isolated `id_ed25519` negative case outside `.ssh`, plus archive coverage for the same token.

### Test update

- Added a fixture at `cluster/ceph/id_ed25519` so the forbidden token is tested independently of `.ssh`.
- Kept the existing `.ssh/id_ed25519` case so both the token and the path shape remain covered.

### Verification

- `bash experiments/ceph-incident-bundle/tests/test-verify-bundle.sh` passed
- `bash experiments/ceph-incident-bundle/tests/run-tests.sh` passed
- `make validate` passed
