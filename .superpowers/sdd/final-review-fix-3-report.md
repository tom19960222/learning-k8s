# Final Review Fix 3 Report

## Scope

Fixed the last live-safety review findings before Task 9:

- `cgroup_io_max_path_command` now fails closed if `systemctl show` fails or returns an empty `ControlGroup`, instead of printing `/sys/fs/cgroup/io.max`.
- Host-side `ceph-volume` probing now uses `sudo -n` so it cannot block on an interactive password prompt before falling back to `cephadm shell`.
- `SLOW_OPS` cleanup now issues a scoped best-effort remote `pkill` for `rados bench -p <pool>` before pool cleanup, reducing risk from orphaned remote workloads.

## Evidence

Focused checks passed:

```text
bash experiments/ceph-alert-real-lab/tests/test-scenario-commands.sh
bash experiments/ceph-alert-real-lab/tests/test-scenario-slow-ops.sh
bash -n experiments/ceph-alert-real-lab/run/scenario-slow-ops.sh experiments/ceph-alert-real-lab/tests/test-scenario-slow-ops.sh experiments/ceph-alert-real-lab/tests/test-scenario-commands.sh
```

The full local gate was run after these focused checks:

```text
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh experiments/ceph-alert-real-lab/run/*.sh experiments/ceph-alert-real-lab/tests/*.sh
make validate
```

## Concerns

No live/destructive cluster commands were run in this fix.
