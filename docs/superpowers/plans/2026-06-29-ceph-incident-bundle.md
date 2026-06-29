# Ceph Incident Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a one-command Ceph incident evidence collector that gathers cephadm/Rook cluster state plus per-node Linux state into one `.tar.gz`, then document it as a Ceph feature page.

**Architecture:** `run/collect.sh` is the single operator entrypoint. It loads a shell inventory, calls focused helper scripts under `lib/`, streams the node collector over SSH, records every command in a JSONL manifest, redacts obvious secrets, verifies the bundle, and packages it. The implementation keeps scripts small, table-driven, read-only, and robust to partial failures.

**Tech Stack:** Bash 4+, OpenSSH, sudo, cephadm, optional kubectl, tar/gzip, Python 3 only for test assertions where plain shell becomes hard to read.

---

## Global Constraints

- Follow `docs/superpowers/specs/2026-06-29-ceph-incident-bundle-design.md`.
- zh-TW Taiwan wording in docs and MDX; keep technical terms like node, cluster, command, Pod, Secret, ConfigMap, PVC, CRD, daemon, sidecar, label, controller, reconcile in English.
- Shell comments are English.
- The user-facing run path is one command: `bash experiments/ceph-incident-bundle/run/collect.sh ...`.
- Internal implementation may use multiple scripts, but helpers must stay simple and readable. Prefer small functions and table-driven command lists over copied command blocks.
- TDD is required for script behavior that can be tested locally: write the failing test, run it, then implement.
- All collectors are read-only. Do not run repair, restart, scrub, compact, destroy, delete, or raw block device reads.
- Every command must have bounded runtime via timeout handling.
- Individual command, SSH, or node failures must be recorded and must not prevent other collectors from running.
- Exit codes: `0` all required collectors succeed; `2` partial failure with bundle produced; `1` fatal error before bundle exists.
- Do not commit generated full incident bundles. Keep `results/` ignored except `.gitkeep`.
- Before any commit, run `make validate` and ensure it exits 0.
- Commit with `git commit --no-gpg-sign`.
- Push with `GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push`.

## File Structure

- Create `experiments/ceph-incident-bundle/.gitignore`: ignore `results/*`, keep `results/.gitkeep`, ignore local `env.sh`, `tmp/`, and generated archives.
- Create `experiments/ceph-incident-bundle/README.md`: operator runbook.
- Create `experiments/ceph-incident-bundle/inventory/ceph-lab.example.env`: six-node lab inventory.
- Create `experiments/ceph-incident-bundle/lib/common.sh`: shared helpers.
- Create `experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh`: cephadm cluster collector.
- Create `experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh`: Rook/Kubernetes cluster collector.
- Create `experiments/ceph-incident-bundle/lib/collect-node.sh`: remote node collector.
- Create `experiments/ceph-incident-bundle/lib/verify-bundle.sh`: bundle verifier.
- Create `experiments/ceph-incident-bundle/run/collect.sh`: single entrypoint.
- Create `experiments/ceph-incident-bundle/tests/run-tests.sh`: local test runner.
- Create `experiments/ceph-incident-bundle/tests/test-common.sh`: tests for common helpers.
- Create `experiments/ceph-incident-bundle/tests/test-collect.sh`: integration-style tests using fake SSH and fake collectors.
- Create `experiments/ceph-incident-bundle/tests/fixtures/`: fixture bundle trees and fake command binaries.
- Create `experiments/ceph-incident-bundle/results/.gitkeep`.
- Create `next-site/content/ceph/features/incident-bundle-runbook.mdx`.
- Modify `next-site/lib/projects.ts`.
- Modify `next-site/content/ceph/feature-map.json`.
- Modify `next-site/content/ceph/quiz.json`.

## Task 1: Harness Skeleton, Inventory, and Test Runner

**Files:**
- Create: `experiments/ceph-incident-bundle/.gitignore`
- Create: `experiments/ceph-incident-bundle/inventory/ceph-lab.example.env`
- Create: `experiments/ceph-incident-bundle/results/.gitkeep`
- Create: `experiments/ceph-incident-bundle/tests/run-tests.sh`
- Create: `experiments/ceph-incident-bundle/tests/fixtures/README.md`

- [ ] **Step 1: Write the failing skeleton test**

Create `tests/run-tests.sh` with a first assertion that all required script paths exist and are executable where appropriate. It should fail because the files do not exist yet.

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

for path in \
  "$ROOT/run/collect.sh" \
  "$ROOT/lib/common.sh" \
  "$ROOT/lib/collect-cluster-cephadm.sh" \
  "$ROOT/lib/collect-cluster-rook.sh" \
  "$ROOT/lib/collect-node.sh" \
  "$ROOT/lib/verify-bundle.sh"; do
  [[ -f "$path" ]] || fail "missing $path"
done

for path in "$ROOT/run/collect.sh" "$ROOT/lib/verify-bundle.sh"; do
  [[ -x "$path" ]] || fail "not executable $path"
done

ok "required files exist"
```

- [ ] **Step 2: Verify the skeleton test fails**

Run:

```bash
bash experiments/ceph-incident-bundle/tests/run-tests.sh
```

Expected: fails with `missing .../run/collect.sh`.

- [ ] **Step 3: Add skeleton files and lab inventory**

Create executable skeleton scripts with `set -euo pipefail`, a short English comment, and a `main "$@"` guard for executable scripts. `collect.sh` should print usage and exit 1 when called with no args. `verify-bundle.sh` should print usage and exit 1 when called with no args. Helper scripts should only define functions for now.

Create `inventory/ceph-lab.example.env`:

```bash
SSH_USER="ikaros"
SEED_HOST="192.168.18.166"
HOSTS=(
  "monitor01=192.168.18.166"
  "mon02=192.168.18.167"
  "mon03=192.168.18.164"
  "osd01=192.168.18.169"
  "osd02=192.168.18.171"
  "osd03=192.168.18.174"
)
```

Create `.gitignore`:

```gitignore
/results/*
!/results/.gitkeep
/tmp/
/env.sh
/*.tar.gz
```

- [ ] **Step 4: Verify skeleton test passes**

Run:

```bash
bash experiments/ceph-incident-bundle/tests/run-tests.sh
bash -n experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/*.sh
```

Expected: `ok: required files exist`, then `bash -n` exits 0.

## Task 2: Common Helpers with TDD

**Files:**
- Modify: `experiments/ceph-incident-bundle/lib/common.sh`
- Create: `experiments/ceph-incident-bundle/tests/test-common.sh`
- Modify: `experiments/ceph-incident-bundle/tests/run-tests.sh`

Common helper API:

```bash
log INFO "message"
die "message"
require_file "path"
ensure_dir "path"
json_escape "string"
manifest_add "$manifest" "$host" "$collector" "$artifact" "$command" "$exit_code" "$started" "$ended"
redact_file "path" "$redaction_log"
run_capture "$manifest" "$host" "$collector" "$artifact" -- command args...
copy_if_exists "$source" "$dest"
```

- [ ] **Step 1: Write failing tests for `json_escape`, `manifest_add`, and `redact_file`**

`tests/test-common.sh` should create a temp dir, source `lib/common.sh`, and assert:

- `json_escape 'a"b\c'` returns `a\"b\\c`.
- `manifest_add` writes valid JSONL parseable by Python.
- `redact_file` replaces lines containing `password`, `secret`, `token`, `keyring`, or `private_key` case-insensitively with `[REDACTED]` and writes the redaction log.

Run:

```bash
bash experiments/ceph-incident-bundle/tests/test-common.sh
```

Expected: fails because helpers are not implemented.

- [ ] **Step 2: Implement minimal common helpers**

Implementation constraints:

- No external JSON tool dependency for writing manifest.
- `run_capture` captures stdout/stderr combined into the artifact path, appends a manifest entry, writes non-zero command failures into `${ERROR_LOG:-}` if set, and returns the command exit code.
- `run_capture` must support command names after `--`.
- Use `timeout "${COMMAND_TIMEOUT:-20}"` when available; if `timeout` is missing, run the command directly and record that timeout is unavailable in the artifact header.
- `redact_file` edits via a temp file and atomic `mv`.

- [ ] **Step 3: Verify tests pass**

Run:

```bash
bash experiments/ceph-incident-bundle/tests/test-common.sh
bash experiments/ceph-incident-bundle/tests/run-tests.sh
```

Expected: both exit 0.

## Task 3: Bundle Verifier with TDD

**Files:**
- Modify: `experiments/ceph-incident-bundle/lib/verify-bundle.sh`
- Create: `experiments/ceph-incident-bundle/tests/test-verify-bundle.sh`
- Modify: `experiments/ceph-incident-bundle/tests/run-tests.sh`

- [ ] **Step 1: Write failing verifier tests**

Tests create fixture directories and archives:

- valid tree contains `manifest.jsonl`, `summary.txt`, `README-FIRST.txt`, `cluster/ceph/status.txt`, and `nodes/monitor01/system/hostname.txt`.
- invalid tree missing `manifest.jsonl` fails.
- tree containing any path matching `keyring` fails.

Run:

```bash
bash experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
```

Expected: fails because verifier is not implemented.

- [ ] **Step 2: Implement `verify-bundle.sh`**

Behavior:

- Accept either a `.tar.gz` path or an extracted directory.
- For `.tar.gz`, run `tar -tzf` first to prove gzip integrity.
- Extract archive to a temp dir for structure checks.
- Require `manifest.jsonl`, `summary.txt`, and `README-FIRST.txt`.
- Require at least one `cluster/` artifact and one `nodes/` artifact.
- Fail if any archive member path contains `keyring`, `.ssh`, `id_ed25519`, or `private_key`.
- Print `VERIFY PASS: <path>` on success.

- [ ] **Step 3: Verify tests pass**

Run:

```bash
bash experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
bash experiments/ceph-incident-bundle/tests/run-tests.sh
```

Expected: all tests exit 0.

## Task 4: cephadm Cluster Collector

**Files:**
- Modify: `experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh`
- Create: `experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh`
- Modify: `experiments/ceph-incident-bundle/tests/run-tests.sh`

- [ ] **Step 1: Write failing tests with fake SSH**

Test contract:

- The collector accepts: output dir, manifest path, seed `user@host`, ssh key, since, timeout.
- It calls `ssh ... sudo cephadm shell -- ceph ...`.
- It writes JSON artifacts under `cluster/ceph/json/` and text artifacts under `cluster/ceph/text/`.
- If one fake command exits non-zero, collector returns partial failure code `2` but still writes later artifacts.

Use a fake `ssh` script in `tests/fixtures/bin/ssh` that records its arguments and emits canned output based on the requested ceph command.

Run:

```bash
PATH="$PWD/experiments/ceph-incident-bundle/tests/fixtures/bin:$PATH" \
  bash experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh
```

Expected: fails before implementation.

- [ ] **Step 2: Implement table-driven cephadm collector**

Command table must include the spec list:

- `status`, `health detail`, `versions`, `df detail`, `osd tree`, `osd df`, `osd dump`, `osd perf`, `osd blocked-by`, `pg stat`, `pg dump`, `pg dump_stuck`, `mon dump`, `quorum_status`, `mgr dump`, `orch host ls`, `orch ps`, `orch device ls --wide`, `config dump`, `crash ls`.

Also write text variants for `status`, `health detail`, `osd tree`, `orch ps`.

For recent crashes: collect `crash info <id>` for at most 10 ids parsed from `crash ls --format json-pretty`; if parsing fails, record skip text instead of failing.

- [ ] **Step 3: Verify collector tests pass**

Run:

```bash
bash experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh
bash experiments/ceph-incident-bundle/tests/run-tests.sh
```

Expected: all tests exit 0.

## Task 5: Node Collector

**Files:**
- Modify: `experiments/ceph-incident-bundle/lib/collect-node.sh`
- Create: `experiments/ceph-incident-bundle/tests/test-node-collector.sh`
- Modify: `experiments/ceph-incident-bundle/tests/run-tests.sh`

- [ ] **Step 1: Write failing local node collector tests**

Tests run `collect-node.sh` locally with fake `sudo`, `journalctl`, `podman`, `docker`, and `cephadm` in PATH. Assert it creates:

- `system/hostname.txt`
- `system/uname.txt`
- `system/uptime.txt`
- `resources/free.txt`
- `storage/df.txt`
- `storage/lsblk.txt`
- `network/ip-addr.txt`
- `kernel/dmesg.txt`
- `systemd/failed-units.txt`
- `cephadm/cephadm-ls.json`
- `logs/ceph-log-listing.txt`

Expected: fails before implementation.

- [ ] **Step 2: Implement node collector**

Behavior:

- Args: `--out DIR --host-alias ALIAS --since DURATION --timeout SECONDS --skip-logs`.
- Source `common.sh`.
- Use table-driven `run_capture` lists.
- Use `sudo -n` for privileged read-only commands when not root.
- If optional commands are missing (`iostat`, `chronyc`, `ntpq`, `pvs`, `vgs`, `lvs`, `podman`, `docker`), write an artifact saying `SKIPPED: command not found`.
- Copy `/etc/os-release`, `/etc/hosts`, `/etc/resolv.conf` if readable.
- For `/var/log/ceph`, copy text and `.gz` logs up to a per-file cap or write listing when copying is skipped.
- For `/var/lib/ceph`, collect safe listings and selected `config` files only; exclude keyrings.

- [ ] **Step 3: Verify node collector tests pass**

Run:

```bash
bash experiments/ceph-incident-bundle/tests/test-node-collector.sh
bash experiments/ceph-incident-bundle/tests/run-tests.sh
```

Expected: all tests exit 0.

## Task 6: Rook Collector

**Files:**
- Modify: `experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh`
- Create: `experiments/ceph-incident-bundle/tests/test-rook-collector.sh`
- Modify: `experiments/ceph-incident-bundle/tests/run-tests.sh`

- [ ] **Step 1: Write failing fake kubectl tests**

Fake `kubectl` should support namespace detection and canned `get` / `logs` output. Assert:

- no `kubectl` or no namespace returns skip code 0 with `cluster/rook/SKIPPED.txt`;
- namespace present writes `pods-wide.txt`, `events.txt`, `rook-resources.yaml`, and operator log artifact.

- [ ] **Step 2: Implement Rook collector**

Behavior:

- Args: `--out DIR --manifest PATH --namespace rook-ceph --since DURATION --timeout SECONDS`.
- Detect namespace with `kubectl get namespace`.
- Use only read-only `kubectl get` and `kubectl logs`.
- Collect toolbox ceph status only if a toolbox/deployment Pod is discoverable; otherwise write `toolbox-SKIPPED.txt`.

- [ ] **Step 3: Verify Rook collector tests pass**

Run:

```bash
bash experiments/ceph-incident-bundle/tests/test-rook-collector.sh
bash experiments/ceph-incident-bundle/tests/run-tests.sh
```

Expected: all tests exit 0.

## Task 7: One-Command Orchestrator

**Files:**
- Modify: `experiments/ceph-incident-bundle/run/collect.sh`
- Create: `experiments/ceph-incident-bundle/tests/test-collect.sh`
- Modify: `experiments/ceph-incident-bundle/tests/run-tests.sh`

- [ ] **Step 1: Write failing orchestrator tests**

Use fake SSH and fake collector helpers. Assert:

- `--help` prints usage and exits 0.
- missing inventory exits 1.
- valid inventory creates a `.tar.gz`.
- one failed host still creates `.tar.gz` and exits 2.
- archive contains `manifest.jsonl`, `summary.txt`, `README-FIRST.txt`, `cluster/`, and `nodes/<alias>/`.

- [ ] **Step 2: Implement argument parsing and inventory loading**

Support exact options from the spec:

```text
--inventory PATH
--ssh-key PATH
--seed USER@HOST
--out DIR
--mode auto|cephadm|rook
--since DURATION
--timeout SECONDS
--skip-logs
--keep-workdir
--help
```

Validate inventory defines `HOSTS`. Default `SSH_USER`, `SEED_HOST`, `ROOK_NAMESPACE`, output dir, mode, since, and timeout as in the spec.

- [ ] **Step 3: Implement orchestration**

Flow:

1. Create workdir under `results/tmp.<timestamp>.<pid>`.
2. Write `environment.txt`, `README-FIRST.txt`, `summary.txt` skeleton.
3. Run cluster collector based on mode:
   - `auto`: try cephadm if seed has `cephadm`; try Rook if local `kubectl` can see namespace.
   - `cephadm`: run cephadm collector only.
   - `rook`: run Rook collector only.
4. For each inventory host, stream `lib/common.sh` and `lib/collect-node.sh` over SSH or copy to a remote temp dir, run it, and pull back a tar stream.
5. Run `redact_file` on text artifacts.
6. Run `verify-bundle.sh` on the workdir.
7. Package as `ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz`.
8. Clean workdir unless `--keep-workdir`.
9. Return `0`, `2`, or `1` per spec.

- [ ] **Step 4: Verify orchestrator tests pass**

Run:

```bash
bash experiments/ceph-incident-bundle/tests/test-collect.sh
bash experiments/ceph-incident-bundle/tests/run-tests.sh
```

Expected: all tests exit 0.

## Task 8: README and Operator UX Polish

**Files:**
- Modify: `experiments/ceph-incident-bundle/README.md`
- Modify: `experiments/ceph-incident-bundle/run/collect.sh`
- Modify: `experiments/ceph-incident-bundle/lib/verify-bundle.sh`

- [ ] **Step 1: Write README**

README sections:

- 這是做什麼的
- 什麼時候執行
- 最短操作流程
- 如何填 inventory
- cephadm 範例
- Rook 範例
- bundle 內有什麼
- exit code 怎麼看
- 常見失敗與處理
- 安全界線：read-only、secret redaction 不是完整 DLP

- [ ] **Step 2: UX review of command output**

Run help and a fake collection:

```bash
bash experiments/ceph-incident-bundle/run/collect.sh --help
bash experiments/ceph-incident-bundle/tests/test-collect.sh
```

Expected: help text names the one command, required options, and output path clearly.

- [ ] **Step 3: Run all local tests**

Run:

```bash
bash experiments/ceph-incident-bundle/tests/run-tests.sh
```

Expected: all tests exit 0.

## Task 9: Live Lab Smoke Test

**Files:**
- Modify: `experiments/ceph-incident-bundle/README.md`
- Create: `experiments/ceph-incident-bundle/results/.gitkeep` if not present
- Do not commit generated full bundles

- [ ] **Step 1: Run live collector on the provided lab**

Run from repo root:

```bash
bash experiments/ceph-incident-bundle/run/collect.sh \
  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
  --ssh-key .ssh/id_ed25519 \
  --seed ikaros@192.168.18.166 \
  --mode cephadm \
  --since 24h
```

Expected: exit 0 or 2 with a produced `.tar.gz`. Exit 2 is acceptable only if `errors.log` shows non-critical optional command skips or per-command read failures; SSH failure to a provided host must be investigated.

- [ ] **Step 2: Verify generated bundle**

Run:

```bash
bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle-path>
tar -tzf <bundle-path> | sed -n '1,120p'
```

Expected: verifier prints `VERIFY PASS`; archive listing contains all six node aliases.

- [ ] **Step 3: Record scrubbed smoke summary**

Update README with a short "Lab smoke test" section:

- date
- cluster mode
- host count
- exit code
- bundle verifier result
- any known optional skips

Do not include secrets or large logs.

## Task 10: Ceph Feature Page and Site Integration

**Files:**
- Create: `next-site/content/ceph/features/incident-bundle-runbook.mdx`
- Modify: `next-site/lib/projects.ts`
- Modify: `next-site/content/ceph/feature-map.json`
- Modify: `next-site/content/ceph/quiz.json`

- [ ] **Step 1: Write MDX page**

Page requirements:

- frontmatter `layout: doc`, `title: Ceph — Incident Bundle：出事時一鍵保留現場證據`
- explain 緣起 / 來龍去脈 / 要做的事 / 操作流程 / bundle 結構 / 收集清單 / 安全界線 / lab 實測結果 / 結論
- do not import components
- do not put quiz in MDX
- mention exact script path and command
- explain exit codes 0/2/1
- explain that the script is evidence collection, not repair
- include source references to local scripts and smoke-test artifacts, not invented Ceph internals

- [ ] **Step 2: Integrate in site metadata**

Add slug `incident-bundle-runbook`:

- `PROJECTS.ceph.features`
- `PROJECTS.ceph.featureGroups` under `監控與告警`
- `feature-map.json` node near existing alert/tooling nodes, with an edge from `prometheus-alert-testing` or `slow-ops-and-bluestore-alerts` to `incident-bundle-runbook`
- `quiz.json` with 2 questions, `id` integer and answer 0-indexed

- [ ] **Step 3: Run local article checks**

Run:

```bash
python3 scripts/validate.py --no-build
```

Expected: exits 0.

## Task 11: Review Loops and Final Validation

**Files:**
- Potentially modify any files from Tasks 1-10 based on review findings.

- [ ] **Step 1: Per-task Code Reviewer gates**

For each implementation task, use Code Reviewer agent after the task. Do not mark task complete until spec compliance and code quality are approved or only non-blocking nits remain.

- [ ] **Step 2: Final whole-branch Code Reviewer**

After all implementation tasks and local tests pass, dispatch a final Code Reviewer agent over the full branch diff.

Fix Critical and Important findings, then re-review.

- [ ] **Step 3: Source-first page review**

Run `/reviewing-source-first-pages` on `next-site/content/ceph/features/incident-bundle-runbook.mdx`.

Review inputs:

- page path
- local script paths under `experiments/ceph-incident-bundle/`
- committed smoke-test summary in README
- project zh-TW / never-translate / no Mermaid / no MDX import rules

Loop until PASS.

- [ ] **Step 4: Final tests**

Run:

```bash
bash experiments/ceph-incident-bundle/tests/run-tests.sh
make validate
```

Expected: both exit 0.

- [ ] **Step 5: Final commit and push**

Run:

```bash
git status --short
git add experiments/ceph-incident-bundle next-site/content/ceph/features/incident-bundle-runbook.mdx next-site/lib/projects.ts next-site/content/ceph/feature-map.json next-site/content/ceph/quiz.json docs/superpowers/plans/2026-06-29-ceph-incident-bundle.md
git commit --no-gpg-sign -m "ceph: 新增 incident evidence bundle 工具"
GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push -u origin codex/ceph-incident-bundle
```

Expected: commit succeeds and push succeeds.
