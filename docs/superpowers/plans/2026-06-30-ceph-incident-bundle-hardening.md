# Ceph Incident Bundle Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the existing read-only `ceph-incident-bundle` collector so it runs correctly on arbitrary production Ceph clusters, not just the lab.

**Architecture:** Review-driven hardening. Three independent reviews (Code Reviewer agent, SRE agent, codex) produce findings; findings are triaged into an ordered backlog; each in-scope finding is fixed TDD-style against the existing bash test harness; then the tool is validated on the real lab cluster under a multi-fault matrix.

**Tech Stack:** Bash (`set -euo pipefail`), existing test harness under `experiments/ceph-incident-bundle/tests/` (fake `ssh`/`kubectl` on PATH + env-var fault injection + bundle assertions), `shellcheck` 0.11.

## Global Constraints

- Tool is **read-only**: never restart/delete/repair/scrub/change cluster state. (verbatim from README safety section)
- No new collection features; hardening only, unless a review proves something is a correctness bug. (spec In-scope/Out-of-scope)
- All zh content Traditional Chinese / Taiwan usage; never-translate list applies; code comments stay English. (CLAUDE.md)
- `make validate` must exit 0 before the final push. (CLAUDE.md)
- Commit with `git commit --no-gpg-sign`; push with `GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none'`. (CLAUDE.md)
- Every fixed finding gets a regression test in the existing harness; `shellcheck lib/*.sh run/*.sh tests/*.sh` must reach 0 warning. (spec success conditions)
- Lab: 3 mon + 9 OSD, replicated, HEALTH_OK. Destructive injection only after `ceph osd ok-to-stop` / quorum check, with immediate rollback and HEALTH_OK reconfirm. (spec validation matrix)

Working dir for all paths below: `experiments/ceph-incident-bundle/`.

---

## Phase 1 — Review (three independent perspectives)

### Task 1: Code Reviewer agent review
- [ ] Dispatch Code Reviewer agent over the full tree (`run/`, `lib/`, `tests/`) with the spec's in-scope list. Ask for: bash correctness bugs, `set -e`/pipefail traps, quoting/word-splitting, exit-code consistency, redaction gaps, portability (GNU-only flags). Output: severity-ranked findings with `file:line` + concrete fix.
- [ ] Save raw output to `docs/superpowers/reviews/2026-06-30-codereviewer.md`.

### Task 2: SRE agent review
- [ ] Dispatch SRE agent with production-operations lens: timeout behavior (per-command vs per-node), partial-failure semantics, SSH robustness, behavior on large/slow nodes, disk usage of workdir, cleanup on interrupt, what's silently dropped. Output: severity-ranked findings with `file:line`.
- [ ] Save raw output to `docs/superpowers/reviews/2026-06-30-sre.md`.

### Task 3: codex cross-model review (saves Claude rate limit)
- [ ] Run `codex exec` (background, `< /dev/null`, no `timeout` on macOS) asking for the same review over the tree. Save to `docs/superpowers/reviews/2026-06-30-codex.md`.

---

## Phase 2 — Triage

### Task 4: Consolidate findings into ordered backlog
- [ ] Merge the three review files; dedupe; drop out-of-scope (new features). Keep correctness/robustness/portability/redaction items.
- [ ] Produce `docs/superpowers/reviews/2026-06-30-triage.md`: a table `id | severity | file:line | summary | in-scope? | test approach`.
- [ ] Confirm the 5 pre-seeded findings below are represented (merge/supersede as the reviews dictate). Each surviving finding becomes a fix task with the same TDD shape as Tasks 5–9.

---

## Phase 3 — Fixes (TDD; one finding per task)

> Test harness: add assertions to the matching `tests/test-*.sh`; run `bash tests/run-tests.sh` for the full gate. Commit after each green task with `--no-gpg-sign`.

### Task 5: Separate per-node timeout from per-command timeout  *(finding #1, HIGH)*

**Files:**
- Modify: `run/collect.sh` (arg parsing; `collect_remote_node` ssh wrapper; `usage`)
- Modify: `tests/fixtures/bin/ssh`? No — use `tests/test-collect.sh` with a sleeping fake ssh defined inline.
- Test: `tests/test-collect.sh`

**Interfaces:**
- Produces: new CLI flag `--node-timeout SECONDS` (default 300); `collect_remote_node` wraps the whole remote SSH in `timeout "$node_timeout"`, while `--timeout` (default 20) stays the per-command timeout used inside `collect-node.sh`.

- [ ] **Step 1: Write the failing test.** In `tests/test-collect.sh`, after the existing bad-tar block, add a slow-node case. Use an inline fake ssh that sleeps then emits a valid node tar:

```bash
out_slow="$tmpdir/out-slow"
cat >"$fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
cat >/dev/null
remote_command="${@: -1}"
alias_name="$(printf '%s\n' "$remote_command" | sed -n "s/.*--host-alias '\\([^']*\\)'.*/\\1/p")"
sleep "${FAKE_SSH_SLEEP:-0}"
tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/system"
printf 'node %s\n' "$alias_name" >"$tmpdir/system/hostname.txt"
tar -czf - -C "$tmpdir" .
EOF
chmod +x "$fakebin/ssh"
# per-command timeout 1s, node timeout 10s, node sleeps 3s -> must still succeed
FAKE_SSH_SLEEP=3 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" --ssh-key "$ssh_key" \
  --seed tester@seed.example.invalid --mode rook \
  --out "$out_slow" --since 24h --timeout 1 --node-timeout 10
bundle_slow="$(find_bundle "$out_slow")"
assert_archive_contains "$bundle_slow" "nodes/monitor01/system/hostname.txt"
```

- [ ] **Step 2: Run, verify it fails.** `bash tests/test-collect.sh` → FAIL (unknown flag `--node-timeout`, or node truncated at 1s).
- [ ] **Step 3: Implement.** In `run/collect.sh`: add `node_timeout=300` default; parse `--node-timeout`; in `collect_remote_node` accept and use it so `ssh_cmd=(timeout "$node_timeout" "${ssh_cmd[@]}")`; document both timeouts in `usage`.
- [ ] **Step 4: Run, verify pass.** `bash tests/run-tests.sh` → all ok.
- [ ] **Step 5: Commit.** `git add -A && git commit --no-gpg-sign -m "ceph-incident-bundle: separate per-node from per-command timeout"`

### Task 6: Capture truncated tail of oversized Ceph logs instead of silent drop  *(finding #2, MED)*

**Files:**
- Modify: `lib/collect-node.sh` (`copy_ceph_logs`)
- Test: `tests/test-node-collector.sh`

**Interfaces:**
- Produces: oversized logs (> `CEPH_INCIDENT_LOG_FILE_CAP_BYTES`) are copied as a last-`cap`-bytes tail to `logs/ceph/<rel>` and a sibling `logs/ceph/<rel>.TRUNCATED` marker records original size; no longer silently `continue`d.

- [ ] **Step 1: Write the failing test.** In `tests/test-node-collector.sh`, add: create `$logdir/big.log` of cap+1KB, run `collect-node.sh --out ... --host-alias t` with `CEPH_INCIDENT_VAR_LOG_CEPH_DIR=$logdir CEPH_INCIDENT_LOG_FILE_CAP_BYTES=4096`, assert `logs/ceph/big.log` exists, size ≤ 4096, and `logs/ceph/big.log.TRUNCATED` exists. (Match the file's existing setup/assert helpers.)
- [ ] **Step 2: Run, verify it fails.** `bash tests/test-node-collector.sh` → FAIL (file absent: currently skipped).
- [ ] **Step 3: Implement.** In `copy_ceph_logs`: when `size > cap_bytes`, `tail -c "$cap_bytes"` (via `node_copy_file` tail variant or `sudo -n tail`) into dest and write `<dest>.TRUNCATED` with `original_bytes=<size>`; keep `failed` semantics on copy error.
- [ ] **Step 4: Run, verify pass.** `bash tests/run-tests.sh`.
- [ ] **Step 5: Commit.** `--no-gpg-sign -m "ceph-incident-bundle: tail oversized logs instead of dropping"`

### Task 7: Clean up workdir + node tars on interrupt/failure  *(finding #3, MED)*

**Files:**
- Modify: `run/collect.sh` (install trap after `workdir` is created)
- Test: `tests/test-collect.sh`

**Interfaces:**
- Produces: `trap` on `EXIT INT TERM` removes `$workdir` and any `$workdir/.node-*.tar.gz` unless `--keep-workdir`; normal success/partial paths unchanged.

- [ ] **Step 1: Write the failing test.** Add a `COLLECT_TEST_ABORT_AFTER_NODES` hook honored in `collect.sh` (after the node loop, `[[ -n "${COLLECT_TEST_ABORT_AFTER_NODES:-}" ]] && die "test abort"`). Test: run collect with that env set, expect non-zero, then assert `find "$out_dir" -maxdepth 1 -name 'tmp.*' | wc -l` is 0.
- [ ] **Step 2: Run, verify it fails.** FAIL (leftover `tmp.*` workdir).
- [ ] **Step 3: Implement.** Add `cleanup_workdir() { [[ $keep_workdir -eq 1 ]] && { printf 'kept workdir: %s\n' "$workdir"; return; }; rm -rf "$workdir"; }` and `trap cleanup_workdir EXIT` right after `ensure_dir "$workdir"`; remove the now-redundant tail cleanup. Keep the abort hook guarded so it is inert in production.
- [ ] **Step 4: Run, verify pass.** `bash tests/run-tests.sh`.
- [ ] **Step 5: Commit.** `--no-gpg-sign -m "ceph-incident-bundle: trap-clean workdir on interrupt/failure"`

### Task 8: Portable redaction temp-file permissions  *(finding #4, LOW)*

**Files:**
- Modify: `lib/common.sh` (`redact_file`)
- Test: `tests/test-common.sh`

**Interfaces:**
- Produces: redacted temp file gets source mode via a portable path (read source mode with `stat` for both GNU and BSD, fall back to `chmod 600`), not GNU-only `chmod --reference`.

- [ ] **Step 1: Write the failing test.** In `tests/test-common.sh`, create a file `chmod 640`, write a secret line, `redact_file` it, assert resulting mode is `640` (use `stat -f '%Lp'` on darwin / `stat -c '%a'` on linux via a small `file_mode` helper in the test). On a system without `chmod --reference` this currently drifts.
- [ ] **Step 2: Run, verify it fails** on darwin workstation. `bash tests/test-common.sh`.
- [ ] **Step 3: Implement.** Replace `chmod --reference` with: `mode="$(stat -c '%a' "$source_file" 2>/dev/null || stat -f '%Lp' "$source_file" 2>/dev/null || printf '600')"; chmod "$mode" "$tmp_file"`.
- [ ] **Step 4: Run, verify pass.** `bash tests/run-tests.sh`.
- [ ] **Step 5: Commit.** `--no-gpg-sign -m "ceph-incident-bundle: portable redaction file mode"`

### Task 9: Tiered timeout for heavy cluster commands  *(finding #5, LOW)*

**Files:**
- Modify: `lib/collect-cluster-cephadm.sh` (heavy specs get a larger timeout)
- Test: `tests/test-cephadm-collector.sh`

**Interfaces:**
- Produces: heavy commands (`pg dump`, `osd dump`, `pg dump_stuck`, `config dump`) use `COMMAND_TIMEOUT_HEAVY` (default `max(timeout, 60)`); others keep `timeout`.

- [ ] **Step 1: Write the failing test.** In `tests/test-cephadm-collector.sh`, assert the `pg-dump.json` artifact header records the heavy timeout (`# timeout: 60s`) when run with `--timeout 20`. (The artifact header already prints `# timeout: Ns` via `run_capture`.)
- [ ] **Step 2: Run, verify it fails.** Currently prints `# timeout: 20s`.
- [ ] **Step 3: Implement.** Add a `heavy` set; in `collect_cluster_cephadm`, for heavy specs call `collect_cephadm_command` with `COMMAND_TIMEOUT` set to the heavy value.
- [ ] **Step 4: Run, verify pass.** `bash tests/run-tests.sh`.
- [ ] **Step 5: Commit.** `--no-gpg-sign -m "ceph-incident-bundle: tiered timeout for heavy cluster commands"`

### Task 10: Resolve remaining review findings
- [ ] For each surviving triaged finding not covered by Tasks 5–9, create and execute a fix task with the same 5-step TDD shape. Commit each separately.

### Task 11: shellcheck to zero
- [ ] Run `shellcheck lib/*.sh run/*.sh tests/*.sh`. Fix each of the 13 warnings + 4 notes (quoting, unused vars, `read` without `-r`, etc.) — preferring real fixes over `# shellcheck disable`. Re-run until clean.
- [ ] `bash tests/run-tests.sh` still green. Commit `--no-gpg-sign -m "ceph-incident-bundle: shellcheck clean"`.

---

## Phase 4 — Lab validation (multi-fault, SRE agent)

### Task 12: Healthy baseline
- [ ] SRE agent runs `run/collect.sh` against the lab inventory (`--mode cephadm`, seed `ikaros@192.168.18.166`, key `.ssh/id_ed25519`); assert exit 0 + `verify-bundle.sh` PASS + each of the 6 node dirs populated. Record bundle path + summary.txt.

### Task 13: OSD-down scenario
- [ ] `ceph osd ok-to-stop <id>` → if ok, `ceph orch daemon stop osd.<id>`; wait for `PG_DEGRADED`; run collector; assert bundle captures `health detail`/degraded PGs and exit 0. **Rollback:** `ceph orch daemon restart osd.<id>`; wait HEALTH_OK.

### Task 14: MON-loss scenario (quorum retained)
- [ ] Stop 1 mon (`ceph orch daemon stop mon.<host>`); confirm quorum still held; run collector; assert `MON_DOWN` captured, exit 0. **Rollback:** restart mon; confirm 3/3 quorum.

### Task 15: Partial-failure scenarios
- [ ] Add an unreachable host to a copy of the inventory; run; assert that node `SKIPPED`, others collected, `errors.log` records it, exit 2.
- [ ] Run with `--seed <unreachable>`; assert cluster collector fails but nodes still collected, exit 2.
- [ ] Record all results in `docs/superpowers/reviews/2026-06-30-lab-validation.md`.

---

## Phase 5 — Finalize

### Task 16: README + docs sync
- [ ] Update `README.md`: document `--node-timeout`, large-log tail/`.TRUNCATED` behavior, refreshed exit-code/known-nonzero notes; refresh "Lab smoke test" with the 2026-06-30 multi-fault results. Keep zh-TW.

### Task 17: Full validate + push + PR
- [ ] `make validate` → exit 0.
- [ ] Push branch with the repo key; open PR via `gh` summarizing findings fixed + lab validation matrix results.

---

## Self-Review

- **Spec coverage:** in-scope list → Tasks 5–11; multi-fault matrix → Tasks 12–15; success conditions (tests/shellcheck/exit-codes/README/make validate) → Tasks 11,16,17. Reviews (Code Reviewer+SRE+codex) → Tasks 1–3. Covered.
- **Placeholders:** Task 10 is intentionally a template for review-surfaced findings (shape fully specified); all pre-seeded tasks have concrete code/commands.
- **Type/name consistency:** `--node-timeout`/`node_timeout`, `CEPH_INCIDENT_LOG_FILE_CAP_BYTES`, `.TRUNCATED`, `COMMAND_TIMEOUT_HEAVY`, `cleanup_workdir` used consistently across tasks.
