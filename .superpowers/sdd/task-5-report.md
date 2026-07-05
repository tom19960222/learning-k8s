# Task 5 report — S4/S5/S6 scenario scripts (osd-daemon-down, osd-host-down, mon-down-single)

Status: DONE. All three scenarios framework-migrated, fake-tested (RED→GREEN per scenario), `run-tests.sh` green (19/19 sub-checks), `shellcheck lib/*.sh run/*.sh tests/*.sh` exit 0, `make validate` exit 0. Three separate commits on `master`, not pushed.

## S4 — scenario-osd-daemon-down.sh

**File:** `experiments/ceph-alert-real-lab/run/scenario-osd-daemon-down.sh`
**Test:** `experiments/ceph-alert-real-lab/tests/test-scenario-osd-daemon-down.sh`

Implemented verbatim from the skeleton in `task-5-brief.md` (no deviation):

- `OSD_DOWN_HOST` defaults `ceph-lab-osd-01`; `OSD_DOWN_ID` auto-discovers via `ceph osd ls-tree <host>` (first line) when unset.
- `scenario_setup`: resolves `_host_ip` via `lab_osd_host_ip`, discovers `OSD_DOWN_ID` if empty, dies if none found, resolves `_service` via `osd_service_name`.
- `scenario_inject`: `run_capture` → `ssh_lab "$_host_ip" "sudo systemctl stop $_service"`.
- `scenario_rollback`: same, `systemctl start`.
- `scenario_verify`: `wait_ceph_health_check OSD_DOWN` → `wait_prometheus_alert CephOSDDaemonDownScoped ceph_daemon "osd.$OSD_DOWN_ID"` → `assert_prometheus_alert_not_firing CephOSDHostDownScoped hostname "$OSD_DOWN_HOST"` (single-shot, after the positive wait) → `wait_sink_alert pager CephOSDDaemonDownScoped ceph_daemon "osd.$OSD_DOWN_ID"` → `wait_sink_alert slack CephOSDDown "" ""` (mixin context rule evidence).

**Fake test cases:**
- (a) no `--yes-really-inject` → exit 2, no stdout, zero live-capable commands executed (traced via poison-exit-99 fakes), no result dir created.
- (b) with ack: fake ssh answers `ceph osd ls-tree ceph-lab-osd-01` → `0`, `ceph health detail` → contains `OSD_DOWN`, `ceph -s` → `HEALTH_OK`, `quorum_status --format json` → 3-mon quorum; fake kubectl `/api/v1/alerts` returns `CephOSDDaemonDownScoped{ceph_daemon="osd.0"}` firing and *no* `CephOSDHostDownScoped` entry (so the not-firing assertion passes); sink log gains a pager `CephOSDDaemonDownScoped` line and a slack `CephOSDDown` line only after `systemctl stop` is observed in the trace (checkpoint-gated, mirrors `test-scenario-pg-availability.sh`).
- Assertions: exit 0, single `result: .../osd-daemon-down-*` stdout line, no live-command noise leaked to stdout, discovery→stop→rollback-start ordering verified by line-number comparison in the trace file.

RED: ran test before the script existed → `FAIL: expected exit 2 without destructive ack, got 127` (bash: no such file). GREEN: after writing the script, `ok: osd-daemon-down destructive ack guard, injection sequence, and rollback ordering`.

## S5 — scenario-osd-host-down.sh

**File:** `experiments/ceph-alert-real-lab/run/scenario-osd-host-down.sh`
**Test:** `experiments/ceph-alert-real-lab/tests/test-scenario-osd-host-down.sh`

- `OSD_HOST_DOWN_HOST` defaults `ceph-lab-osd-02`.
- `scenario_setup`: resolves `_host_ip`; runs `ceph osd ls-tree $OSD_HOST_DOWN_HOST` and redirects stdout straight into `$RESULT_DIR/target-osds.txt` (one id per line); dies if the file is empty (`wc -l` guard, no arrays — bash-3.2 safe).
- `scenario_inject`: `while IFS= read -r osd; do ... done <"$target_file"` — for each id, resolves the per-OSD service via `osd_service_name` and `systemctl stop`s it, one `run_capture` file per step (`stop-osd-N.txt`).
- `scenario_verify`: `wait_prometheus_alert CephOSDHostDownScoped hostname "$OSD_HOST_DOWN_HOST"` first, then loops the same target file asserting `assert_prometheus_alert_not_firing CephOSDDaemonDownScoped ceph_daemon "osd.$osd"` per id (the `unless`-dedup evidence — daemon-down must NOT co-fire once host-down is up), then `wait_sink_alert pager CephOSDHostDownScoped hostname "$OSD_HOST_DOWN_HOST"`.
- `scenario_rollback`: re-reads `$RESULT_DIR/target-osds.txt` (guarded with `[[ -f "$target_file" ]]`) and `systemctl start`s each id; order doesn't matter per the brief, kept forward/sequential.

**Fake test cases:** same ack-guard shape as S4. Live path: fake ssh returns `3\n4\n5\n` for `ceph osd ls-tree ceph-lab-osd-02`; fake kubectl `/api/v1/alerts` returns only `CephOSDHostDownScoped{hostname="ceph-lab-osd-02"}` firing (no per-OSD `CephOSDDaemonDownScoped` entries, satisfying all three not-firing checks); sink log gains a fresh pager `CephOSDHostDownScoped` line after stop is observed. Assertions verify: `target-osds.txt` content is exactly `3\n4\n5`, discovery happens before every stop, and for each of osd.3/4/5 the stop→rollback-start ordering holds (looped, not hardcoded per-id like S4's single-OSD case).

RED: `FAIL: expected exit 2 without destructive ack, got 127` before the script existed. GREEN: `ok: osd-host-down destructive ack guard, injection sequence, and rollback ordering`.

## S6 — scenario-mon-down-single.sh

**File:** `experiments/ceph-alert-real-lab/run/scenario-mon-down-single.sh`
**Test:** `experiments/ceph-alert-real-lab/tests/test-scenario-mon-down-single.sh`

Isomorphic to S4's skeleton but for a named mon (no auto-discovery needed since the target is a fixed name):

- `MON_DOWN_NAME` defaults `ceph-lab-mon-03` (avoids the active mgr host and the `LAB_MON_01_HOST` seed used for `cephadm shell` commands).
- `scenario_setup`: `_host_ip="$(lab_mon_host_ip "$MON_DOWN_NAME")"`, `_service="$(mon_service_name "$LAB_FSID" "$MON_DOWN_NAME")"`.
- `scenario_inject`/`scenario_rollback`: single `systemctl stop`/`start` via `ssh_lab`, same shape as S4.
- `scenario_verify`: `wait_ceph_health_check MON_DOWN` → `wait_prometheus_alert CephMonDownScoped ceph_daemon "mon.$MON_DOWN_NAME"` → `assert_prometheus_alert_not_firing CephMonQuorumLost "" ""` (single-shot, after the positive wait — with 2-of-3 mons still up, quorum-loss must stay quiet) → `wait_sink_alert pager CephMonDownScoped ceph_daemon "mon.$MON_DOWN_NAME"`.

**Fake test cases:** ack guard identical shape. Live path: fake ssh `ceph health detail` → contains `MON_DOWN`; fake kubectl `/api/v1/alerts` returns `CephMonDownScoped{ceph_daemon="mon.ceph-lab-mon-03"}` firing and *no* `CephMonQuorumLost` entry; sink log gains a fresh pager `CephMonDownScoped` line after stop. Assertions verify stop→rollback-start ordering via trace line numbers.

RED: `FAIL: expected exit 2 without destructive ack, got 127` before the script existed. GREEN: `ok: mon-down-single destructive ack guard, injection sequence, and rollback ordering`.

## Gate results

- `bash tests/run-tests.sh`: all 19 sub-checks `ok:` (includes the 3 new scenario tests plus every pre-existing test — `test-scenario-framework.sh`'s generic Case 3 already covers "verify fails → rollback still runs" at the framework level, so per-scenario tests only needed the ack-guard + full-success-with-ordering shape, matching the existing `pg-availability`/`mon-quorum-lost` pattern).
- `shellcheck lib/*.sh run/*.sh tests/*.sh`: exit 0, no findings, no `# shellcheck disable` needed in the new files.
- `make validate`: exit 0 (frontmatter, images, quiz, projects.ts↔MDX, 大陸用語黑名單, Next.js build all green) — ran once after each of the 3 commits.

## Self-review findings / concerns

- All three scripts source the same four libs + framework in the same order as the canonical `scenario-pg-availability.sh`; no drift.
- `run/all.sh` was **not** updated to chain these three new scenarios — the shared spec and task briefs for this batch only scoped "script + test," and wiring into `all.sh`/orchestration is presumably a later task (task list item #6: "真機逐一注入故障驗證每條 alert"). Flagging this explicitly in case the orchestrator expected `all.sh` updated in this batch — it wasn't, to avoid scope creep beyond the brief.
- S5's `scenario_rollback` guards `[[ -f "$target_file" ]]` before reading, so a `scenario_setup` failure before `ceph osd ls-tree` even runs (e.g. `lab_osd_host_ip` rejecting an unknown host) leaves rollback a no-op — consistent with how `scenario-pg-availability.sh` guards its own `stopped-osds.txt`.
- No new `PROMETHEUS_WAIT_ATTEMPTS`/`SINK_WAIT_ATTEMPTS` overrides were added in any of the three scripts — briefs for S4/S5/S6 didn't call for overriding the generous default (60×5s), and the `for: 5m` (OSD scoped) / `for: 30s` (mon scoped) thresholds fit inside that budget.
- Real-cluster injection (actually stopping OSD/mon daemons on `.169`/`.171`/`.164` etc.) was **not** performed — this task was scoped to script + fake test per the shared spec; real-lab validation is tracked separately (task list item #6: "真機逐一注入故障驗證每條 alert").
- No unrelated dirty files were touched or committed; each commit contains exactly the new `run/*.sh` + `tests/test-*.sh` + the `tests/run-tests.sh` registration diff for that scenario.

## Fix round 1

Addressed two Important review findings on the S4/S5/S6 fake tests. Scope was test-only — `run/scenario-osd-daemon-down.sh`, `run/scenario-osd-host-down.sh`, `run/scenario-mon-down-single.sh`, and all `lib/*.sh` were **not** touched.

### Finding 1 — negative assertions could pass vacuously

`assert_prometheus_alert_not_firing` (in `lib/monitoring.sh`) calls `prometheus_alert_is_firing`, which unconditionally writes `$result_dir/prometheus-alerts-<alertname>-<label_name|none>.json` before evaluating the jq predicate — so the file's existence is direct proof the not-firing check actually executed (a call that was silently skipped, e.g. by a refactor that deleted the assertion line, would still leave the "alert not observed" condition vacuously true but leave zero evidence behind). Added file-existence assertions to each scenario's success-path test, right before the final `ok` line:

- **`tests/test-scenario-osd-daemon-down.sh`**: asserts `prometheus-alerts-CephOSDHostDownScoped-hostname.json` exists in the discovered `osd-daemon-down-*` result dir.
- **`tests/test-scenario-mon-down-single.sh`**: asserts `prometheus-alerts-CephMonQuorumLost-none.json` exists in the discovered `mon-down-single-*` result dir.
- **`tests/test-scenario-osd-host-down.sh`**: asserts `prometheus-alerts-CephOSDDaemonDownScoped-ceph_daemon.json` exists in the discovered `osd-host-down-*` result dir. Also refactored the existing `target_file` lookup to share a single `result_dir="$(find ... | sort | tail -1)"` computation instead of re-running `find` twice.

**Filename-pattern answer for S5 (as asked):** `prometheus_alert_is_firing`'s filename is `prometheus-alerts-${alertname}-${label_name:-none}.json` — it keys on the label **name** (`ceph_daemon`), not the label **value** (`osd.3`/`osd.4`/`osd.5`). Since `scenario-osd-host-down.sh`'s per-OSD loop calls `assert_prometheus_alert_not_firing CephOSDDaemonDownScoped ceph_daemon "osd.$osd"` for osd 3, 4, 5 with the same `alertname`/`label_name` each time, all three calls write to the exact same file (`prometheus-alerts-CephOSDDaemonDownScoped-ceph_daemon.json`), overwriting it in turn. There is no way to get three distinct per-OSD evidence files without changing `lib/monitoring.sh` (out of scope here), so the test asserts on the single overwritten file and documents this in an inline comment.

**Proof each assertion can fail:** for each of the three new assertions, made a scratch copy of the test file (with `ROOT` hardcoded to the real repo path) and substituted the correct filename for a nonexistent one (`prometheus-alerts-WRONG-nope.json`). All three scratch copies failed with the expected `FAIL: missing negative-assertion evidence file for ...` message before being reverted/discarded; the actual committed files (with the correct filenames) pass.

### Finding 2 — S5's rollback path was never exercised under a failed verify

`scenario-osd-host-down.sh`'s `scenario_rollback` re-reads `target-osds.txt` and loops three `systemctl start` calls — this stateful, multi-service rollback had no test coverage for the "verify fails" path (only the framework-generic single-service case in `test-scenario-framework.sh` covered that shape). Added a new failure-path test case at the end of `tests/test-scenario-osd-host-down.sh`:

- Parameterized the existing `make_fake_kubectl` helper with an optional 3rd `alerts_json` argument (default unchanged — the existing firing payload — so the pre-existing success-path call site is untouched).
- New block runs `bash run/scenario-osd-host-down.sh --yes-really-inject` with `PROMETHEUS_WAIT_ATTEMPTS=1 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=1 SINK_WAIT_SLEEP=0` and a fake kubectl whose `/api/v1/alerts` endpoint always returns `{"data":{"alerts":[]}}` (`CephOSDHostDownScoped` never fires), using the same fake ssh (which stops/starts osd 3/4/5 based on `ceph osd ls-tree` returning `3\n4\n5`).
- Asserts: (a) exit code is non-zero, (b) all three `systemctl start ceph-...@osd.{3,4,5}.service` rollback lines appear in the trace file.
- New mktemp'd files/dir (`fail_stdout_file`, `fail_stderr_file`, `fail_trace_file`, `fail_bin_dir`) were added to the existing top-level `cleanup()` trap so they're removed even if a later `fail()` call exits early.
- Runtime: the whole new block completes in well under a second (verify fails on its very first check — `wait_prometheus_alert CephOSDHostDownScoped` — so none of the per-OSD or sink checks are ever reached; the low-attempt env vars just avoid the 60×5s default poll budget).

**Proof it can fail:** (1) reverted the fake kubectl to the default (firing) alerts payload in a scratch copy — verify then succeeds, exit code is 0, and the "expected non-zero exit" assertion failed as expected (`FAIL: expected non-zero exit when CephOSDHostDownScoped never fires`). (2) In a separate scratch copy, changed the new assertion's `for osd in 3 4 5` loop to `for osd in 3 4 6` — since the real scenario only ever stops/starts osd 3/4/5, this failed with `FAIL: rollback start missing for osd.6 after failed verify`, confirming the loop actually checks each of the three real OSD ids rather than trivially passing. Both scratch copies were discarded after verification; only the correct version is in the committed file.

### Gate results (fix round 1)

- `bash experiments/ceph-alert-real-lab/tests/run-tests.sh`: all sub-checks `ok:` (20 sub-checks now, up from 19, plus the final `ok: unit tests` summary line — the new S5 failure-path case adds one).
- `shellcheck -x experiments/ceph-alert-real-lab/tests/*.sh` (and full `lib/*.sh run/*.sh tests/*.sh`): exit 0, zero findings.
- `make validate`: exit 0.
- Commit `Strengthen scenario tests for negative assertions and rollback` touches only the three named test files (`test-scenario-osd-daemon-down.sh`, `test-scenario-osd-host-down.sh`, `test-scenario-mon-down-single.sh`) plus this report; not pushed. Other pre-existing dirty files in the working tree (`task-1/2/3-report.md`, the `linux` submodule pointer) were left untouched per instructions.
