# Task 6 Report: PG_AVAILABILITY scenario

## Status

- Completed locally without touching the live lab.
- Scope limited to Task 6 files plus local test wiring.

## Files changed

- `experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh`
- `experiments/ceph-alert-real-lab/README.md`
- `experiments/ceph-alert-real-lab/tests/test-scenario-pg-availability.sh`
- `experiments/ceph-alert-real-lab/tests/run-tests.sh`

## What was implemented

### Script

Added `scenario-pg-availability.sh` with:

- `--yes-really-inject` ack gate before any result dir creation or live-capable command
- baseline collection
- test pool creation and sentinel object write
- acting-set lookup via `ceph osd map`
- target OSD host resolution via `ceph osd find`
- stop of two acting OSD systemd services
- health check assertion for `PG_AVAILABILITY`
- Prometheus wait for `CephClientBlocked{name="PG_AVAILABILITY"}`
- sink wait for pager delivery
- rollback that restarts stopped OSDs from `stopped-osds.txt`
- best-effort pool delete under `cephadm shell`
- postcheck collection
- clean stdout with only final `result: <dir>` on success

### README

Added a `PG_AVAILABILITY` section with scenario description and invocation example.

### Tests

Added `test-scenario-pg-availability.sh` covering:

- no-ack exit code/message
- no result dir creation before ack
- no fake live-capable command execution before ack
- fake-live success path
- clean stdout on success
- stop/restart trace for both target OSDs
- rollback ordering: restart before pool delete

Updated `tests/run-tests.sh` to include the new test.

## Evidence

Ran these commands successfully:

```bash
bash experiments/ceph-alert-real-lab/tests/test-scenario-pg-availability.sh
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
bash -n experiments/ceph-alert-real-lab/run/scenario-pg-availability.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```

Observed results:

- `test-scenario-pg-availability.sh`: `ok: pg-availability destructive ack guard`
- `run-tests.sh`: all unit tests passed, including the new PG availability scenario test
- `bash -n`: exit 0
- `shellcheck`: exit 0
- `make validate`: exit 0, including Next.js build and `/learning-k8s` basePath checks

## Self-review

- Kept the ack check before `new_result_dir`, matching the destructive-safety requirement.
- Reused the `slow-ops` pattern for `run_capture`, rollback trap, and stdout cleanliness.
- Avoided real lab execution; fake tests intercept `ssh`, `kubectl`, `curl`, and `jq` only.
- Rollback is intentionally best-effort so partial failures still collect postcheck evidence.
- Did not touch the dirty `linux` submodule.

## Concerns

- The OSD host-name to IP mapping is currently explicit for `ceph-lab-osd-01..03`; if the lab naming changes, the script will fail fast rather than guessing.
- Local tests validate command flow and ordering, but they do not prove real-cluster timing for `PG_AVAILABILITY`, Prometheus firing latency, or pager delivery latency.
