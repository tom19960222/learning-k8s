# Ceph Incident Bundle Progress Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show live progress on stderr during a run (default on; `--quiet` to suppress) so the operator can tell the tool is working, especially through the ~2-minute silent cephadm-cluster phase.

**Architecture:** A `progress()` helper in `lib/common.sh` writes `[utc] msg` to stderr unless `CEPH_INCIDENT_QUIET` is set. It is called only from workstation-side code (orchestrator + cephadm/rook collectors), never from the remote node collector. stdout stays exactly `bundle: <path>`.

**Tech Stack:** Bash (`set -euo pipefail`, bash-3.2-safe), existing test harness, `shellcheck` 0.11.

## Global Constraints

- Display-only: no change to collection behavior, artifacts, exit codes (0/2/1), or bundle content. (spec)
- bash-3.2-safe; never mutate cluster state. (project)
- stdout = only `bundle: <path>`; all progress to stderr. (spec decision 2)
- `make validate` exit 0; `shellcheck lib/*.sh run/*.sh tests/*.sh` 0; commit `--no-gpg-sign`. (CLAUDE.md)

Working dir for paths: `experiments/ceph-incident-bundle/`.

## Task 1: progress() helper + `--quiet`, wired through all phases

**Files:**
- Modify: `lib/common.sh` (add `progress()`)
- Modify: `run/collect.sh` (`--quiet` flag → `export CEPH_INCIDENT_QUIET=1`; progress calls at start, probe, node loop, finalize)
- Modify: `lib/collect-cluster-cephadm.sh` (per-command progress with `[k/total]`)
- Modify: `lib/collect-cluster-rook.sh` (one progress line at start of collection)
- Test: `tests/test-common.sh` (progress unit), `tests/test-collect.sh` (stderr has progress / stdout clean; `--quiet` silent)

**Interfaces:**
- Produces `progress() { [[ -n "${CEPH_INCIDENT_QUIET:-}" ]] && return 0; printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }`.
- `collect_clusters` / `collect_cluster_cephadm` / `collect_cluster_rook` and `main`'s node loop call `progress`.

- [ ] **Step 1: Write failing unit test** — in `tests/test-common.sh`, add and register:
```bash
test_progress_respects_quiet() {
  local out
  out="$(progress "hello-progress" 2>&1)"
  [[ "$out" == *"hello-progress"* ]] || fail "progress should print when not quiet"
  out="$(CEPH_INCIDENT_QUIET=1 progress "hello-progress" 2>&1)"
  [[ -z "$out" ]] || fail "progress should be silent when CEPH_INCIDENT_QUIET set, got '$out'"
}
```
  Add `test_progress_respects_quiet` to the call list near the bottom.
- [ ] **Step 2: Run, verify fail** — `bash tests/test-common.sh` → FAIL (progress not defined).
- [ ] **Step 3: Implement helper** — in `lib/common.sh` after `ensure_dir`:
```bash
progress() {
  [[ -n "${CEPH_INCIDENT_QUIET:-}" ]] && return 0
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}
```
- [ ] **Step 4: Run, verify pass** — `bash tests/test-common.sh`.
- [ ] **Step 5: Write failing orchestration test** — in `tests/test-collect.sh`, after the auto-mode block, capturing stdout and stderr separately:
```bash
prog_out="$tmpdir/prog.out"; prog_err="$tmpdir/prog.err"
FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="10.0.0.9" \
PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" --ssh-key "$ssh_key" \
  --mode auto --kube-context lab --out "$tmpdir/out-prog" --since 24h --timeout 5 \
  >"$prog_out" 2>"$prog_err"
grep -q 'bundle:' "$prog_out" || fail "stdout must carry bundle: line"
grep -qE 'node (cephnode|kubenode)' "$prog_err" || fail "stderr should show node progress"
grep -q 'bundle:' "$prog_err" && fail "bundle: must not be on stderr" || true
grep -qiE 'probe|ceph ' "$prog_err" || fail "stderr should show probe/ceph progress"
# --quiet suppresses progress but keeps bundle: on stdout
q_out="$tmpdir/q.out"; q_err="$tmpdir/q.err"
FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="10.0.0.9" \
PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" --ssh-key "$ssh_key" \
  --mode auto --kube-context lab --out "$tmpdir/out-quiet" --since 24h --timeout 5 --quiet \
  >"$q_out" 2>"$q_err"
grep -q 'bundle:' "$q_out" || fail "--quiet must still print bundle: to stdout"
grep -qE 'node |probe' "$q_err" && fail "--quiet must suppress progress" || true
```
- [ ] **Step 6: Run, verify fail** — `bash tests/test-collect.sh` → FAIL (no progress yet / `--quiet` unknown).
- [ ] **Step 7: Implement progress wiring:**
  - `run/collect.sh`: add `--quiet) export CEPH_INCIDENT_QUIET=1; shift ;;` to arg parse and `--quiet` to `usage`. After workdir setup: `progress "starting: mode=$mode, ${#HOST_TARGETS[@]} hosts"`. In the node loop: before each, `progress "[$((i+1))/${#HOST_ALIASES[@]}] node $alias…"`; after, `progress "[$((i+1))/${#HOST_ALIASES[@]}] node $alias: ok"` / `"… SKIPPED (exit $node_rc)"`. Before redact/verify/tar: `progress "redacting…"`, `progress "verifying…"`, `progress "packaging…"`.
  - `collect_clusters`: `progress "probing ${#HOST_TARGETS[@]} nodes for capabilities…"` before the probe loop; inside, `progress "[$((i+1))/${#HOST_TARGETS[@]}] probe ${HOST_TARGETS[$i]}: ${caps:-none}"`. Before each layer: `progress "collecting ceph cluster from $ceph_source…"` / `progress "collecting rook from $rook_source (ns=$rook_namespace)…"`.
  - `lib/collect-cluster-cephadm.sh`: in `collect_cluster_cephadm`, compute `local total=$(( ${#json_specs[@]} + ${#text_specs[@]} ))` and a counter; before each `collect_cephadm_command` for the json/text specs, `progress "[$((++k))/$total] ceph ${command}"`. (crash info: `progress "ceph crash info (recent)…"` once.)
  - `lib/collect-cluster-rook.sh`: at the start of real collection (after namespace check), `progress "rook: pods/events/logs/toolbox…"`.
- [ ] **Step 8: Run, verify pass** — `bash tests/run-tests.sh` all green.
- [ ] **Step 9: shellcheck** — `shellcheck lib/*.sh run/*.sh tests/*.sh` → 0.
- [ ] **Step 10: Commit** — `git add -A && git commit --no-gpg-sign -m "ceph-incident-bundle: live progress output on stderr (--quiet to suppress)"`

## Task 2: README + validate

- [ ] README: short note that progress prints to stderr by default and `--quiet` suppresses it (stdout stays `bundle:`).
- [ ] `make validate` exit 0.
- [ ] Commit `--no-gpg-sign -m "ceph-incident-bundle: document progress / --quiet"`.

## Self-Review

- **Spec coverage:** progress points (start/probe/ceph-per-command/rook/node/finalize/done) → Task 1 Step 7; default-on + `--quiet` → Step 7; stderr/stdout split → Step 5 tests; unit test → Steps 1-4; docs → Task 2. Covered.
- **Placeholders:** none — all code/messages specified.
- **Type/name consistency:** `progress`, `CEPH_INCIDENT_QUIET`, `--quiet` used consistently.
