# Task 2 Report: Monitoring Stack Rendering And Deployment

## Scope

Implemented local-only Task 2 work for `experiments/ceph-alert-real-lab`:

- created `lib/monitoring.sh`
- created `run/deploy-monitoring.sh`
- created `run/cleanup.sh`
- created `tests/test-monitoring-render.sh`
- updated `tests/run-tests.sh`

Did not deploy to the live k8s lab and did not run `kubectl` against the real cluster.

## RED Evidence

TDD started by adding the new monitoring render test and wiring it into `run-tests.sh` before production code existed.

Command:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Observed failure:

```text
FAIL: missing /Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/monitoring.sh
```

This matches the brief's expected RED state.

## GREEN Evidence

After implementing `lib/monitoring.sh` plus the run wrappers:

Command:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Observed success:

```text
[2026-07-04T03:16:00Z] PASS: counter reaches 2
ok: common helpers
ok: monitoring manifest render
ok: unit tests
```

## Verification

### Unit tests

Command:

```bash
bash experiments/ceph-alert-real-lab/tests/run-tests.sh
```

Result: pass

### ShellCheck

Command:

```bash
shellcheck -x experiments/ceph-alert-real-lab/lib/*.sh \
  experiments/ceph-alert-real-lab/run/*.sh \
  experiments/ceph-alert-real-lab/tests/*.sh
```

Result: pass

Note: `wait_sink_alert` needs a single-quoted inline script so the jq variables expand in the subshell. Added a scoped `SC2016` suppression with an explanatory comment.

### Repo validation

Command:

```bash
make validate
```

Result: pass

Highlights:

- all 105 MDX files passed frontmatter/image/quiz checks
- Next.js build passed
- exported HTML links include `/learning-k8s` basePath

## Files Changed

- `experiments/ceph-alert-real-lab/lib/monitoring.sh`
- `experiments/ceph-alert-real-lab/run/deploy-monitoring.sh`
- `experiments/ceph-alert-real-lab/run/cleanup.sh`
- `experiments/ceph-alert-real-lab/tests/test-monitoring-render.sh`
- `experiments/ceph-alert-real-lab/tests/run-tests.sh`

## Self-Review

- Followed the brief's exact manifest content, image tags, rule route matcher, and helper function shape.
- Kept implementation Bash 3.2 compatible.
- Limited verification to local render/unit testing only.
- Left the pre-existing dirty `linux` submodule untouched.

## Concerns

- `wait_sink_alert` and `prometheus_alert_is_firing` depend on `jq` and live-cluster `kubectl` behavior, but Task 2 intentionally stops at local render/unit coverage.
