Reading additional input from stdin...
OpenAI Codex v0.142.4
--------
workdir: /Users/ikaros/Documents/code/learning-k8s
model: gpt-5.5
provider: openai
approval: never
sandbox: read-only
reasoning effort: high
reasoning summaries: none
session id: 019f195a-07f6-7392-8b92-9fe5911edf3c
--------
user
Re-review a bash tool after a round of best-practices refactoring. Diff: git diff b44aa8d..HEAD -- experiments/ceph-incident-bundle. Files: run/collect.sh, lib/common.sh, lib/bundle.sh (new), lib/collect-cluster-cephadm.sh, lib/collect-cluster-rook.sh, lib/collect-node.sh, README.md.

Round-1 review findings that were addressed: (1) DRY the SSH option vector into ssh_base_opts() in common.sh, applied at all call sites; (2) one write_skip_artifact()/_once() replacing ~4 duplicate skip writers + inline blocks; (3) removed dead code ceph_incident_bundle_log + parse_host_entry; (4) removed eval in redact_file; (5) collect_clusters changed from 11 positional args to named --flags; (6) extracted pure helpers (ssh_target_for_host, shell_quote, write_initial_metadata, write_summary, append_error, redact_bundle_text) to lib/bundle.sh so collect.sh is a thinner orchestrator; (7) README drift fixed (auto source selection is connectivity-based, not binary-presence).

Constraints (must still hold): bash 3.2 on the jump host (no mapfile/namerefs; empty-array-under-set-u guards), may lack `timeout`; strictly read-only; tests/run-tests.sh green and shellcheck 0; observable behavior unchanged (exit 0/2/1, bundle layout, stdout = only `bundle:`, SSH command strings byte-identical so the tests' ssh-log greps still pass).

Verify:
1. Did the refactor preserve behavior? Any place where ssh_base_opts changes the emitted argv vs the old inline options? Any sourcing-order/dependency problem with lib/bundle.sh (it uses COLLECT_ROOT, redact_file/redact_gz_file)?
2. Are the round-1 findings genuinely resolved, or only partially?
3. Any NEW issues introduced (bash 3.2 array/quoting, set -u, dead refs to removed funcs, write_skip_artifact_once semantics)?
4. Remaining material best-practices issues worth doing, or is it good enough now? Be explicit if you consider it satisfactory.

Output: real findings only, SEVERITY | file:line | problem | fix. If a category is clean, say so in one line. End with a one-line overall verdict (satisfied / not). Do not modify files.
codex
I’ll re-review without editing files. I’m going to load the required workflow guidance briefly, then inspect the requested diff and relevant current files/tests.
exec
/bin/zsh -lc "sed -n '1,240p' /Users/ikaros/.codex/superpowers/skills/using-superpowers/SKILL.md" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
---
name: using-superpowers
description: Use when starting any conversation - establishes how to find and use skills, requiring Skill tool invocation before ANY response including clarifying questions
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, skip this skill.
</SUBAGENT-STOP>

<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, you ABSOLUTELY MUST invoke the skill.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

This is not negotiable. This is not optional. You cannot rationalize your way out of this.
</EXTREMELY-IMPORTANT>

## Instruction Priority

Superpowers skills override default system prompt behavior, but **user instructions always take precedence**:

1. **User's explicit instructions** (CLAUDE.md, GEMINI.md, AGENTS.md, direct requests) — highest priority
2. **Superpowers skills** — override default system behavior where they conflict
3. **Default system prompt** — lowest priority

If CLAUDE.md, GEMINI.md, or AGENTS.md says "don't use TDD" and a skill says "always use TDD," follow the user's instructions. The user is in control.

## How to Access Skills

**In Claude Code:** Use the `Skill` tool. When you invoke a skill, its content is loaded and presented to you—follow it directly. Never use the Read tool on skill files.

**In Copilot CLI:** Use the `skill` tool. Skills are auto-discovered from installed plugins. The `skill` tool works the same as Claude Code's `Skill` tool.

**In Gemini CLI:** Skills activate via the `activate_skill` tool. Gemini loads skill metadata at session start and activates the full content on demand.

**In other environments:** Check your platform's documentation for how skills are loaded.

## Platform Adaptation

Skills use Claude Code tool names. Non-CC platforms: see `references/copilot-tools.md` (Copilot CLI), `references/codex-tools.md` (Codex) for tool equivalents. Gemini CLI users get the tool mapping loaded automatically via GEMINI.md.

# Using Skills

## The Rule

**Invoke relevant or requested skills BEFORE any response or action.** Even a 1% chance a skill might apply means that you should invoke the skill to check. If an invoked skill turns out to be wrong for the situation, you don't need to use it.

```dot
digraph skill_flow {
    "User message received" [shape=doublecircle];
    "About to EnterPlanMode?" [shape=doublecircle];
    "Already brainstormed?" [shape=diamond];
    "Invoke brainstorming skill" [shape=box];
    "Might any skill apply?" [shape=diamond];
    "Invoke Skill tool" [shape=box];
    "Announce: 'Using [skill] to [purpose]'" [shape=box];
    "Has checklist?" [shape=diamond];
    "Create TodoWrite todo per item" [shape=box];
    "Follow skill exactly" [shape=box];
    "Respond (including clarifications)" [shape=doublecircle];

    "About to EnterPlanMode?" -> "Already brainstormed?";
    "Already brainstormed?" -> "Invoke brainstorming skill" [label="no"];
    "Already brainstormed?" -> "Might any skill apply?" [label="yes"];
    "Invoke brainstorming skill" -> "Might any skill apply?";

    "User message received" -> "Might any skill apply?";
    "Might any skill apply?" -> "Invoke Skill tool" [label="yes, even 1%"];
    "Might any skill apply?" -> "Respond (including clarifications)" [label="definitely not"];
    "Invoke Skill tool" -> "Announce: 'Using [skill] to [purpose]'";
    "Announce: 'Using [skill] to [purpose]'" -> "Has checklist?";
    "Has checklist?" -> "Create TodoWrite todo per item" [label="yes"];
    "Has checklist?" -> "Follow skill exactly" [label="no"];
    "Create TodoWrite todo per item" -> "Follow skill exactly";
}
```

## Red Flags

These thoughts mean STOP—you're rationalizing:

| Thought | Reality |
|---------|---------|
| "This is just a simple question" | Questions are tasks. Check for skills. |
| "I need more context first" | Skill check comes BEFORE clarifying questions. |
| "Let me explore the codebase first" | Skills tell you HOW to explore. Check first. |
| "I can check git/files quickly" | Files lack conversation context. Check for skills. |
| "Let me gather information first" | Skills tell you HOW to gather information. |
| "This doesn't need a formal skill" | If a skill exists, use it. |
| "I remember this skill" | Skills evolve. Read current version. |
| "This doesn't count as a task" | Action = task. Check for skills. |
| "The skill is overkill" | Simple things become complex. Use it. |
| "I'll just do this one thing first" | Check BEFORE doing anything. |
| "This feels productive" | Undisciplined action wastes time. Skills prevent this. |
| "I know what that means" | Knowing the concept ≠ using the skill. Invoke it. |

## Skill Priority

When multiple skills could apply, use this order:

1. **Process skills first** (brainstorming, debugging) - these determine HOW to approach the task
2. **Implementation skills second** (frontend-design, mcp-builder) - these guide execution

"Let's build X" → brainstorming first, then implementation skills.
"Fix this bug" → debugging first, then domain-specific skills.

## Skill Types

**Rigid** (TDD, debugging): Follow exactly. Don't adapt away discipline.

**Flexible** (patterns): Adapt principles to context.

The skill itself tells you which.

## User Instructions

Instructions say WHAT, not HOW. "Add X" or "Fix Y" doesn't mean skip workflows.

exec
/bin/zsh -lc 'rg -n "ceph-incident-bundle|collect.sh|write_skip_artifact|ssh_base_opts|bundle.sh" /Users/ikaros/.codex/memories/MEMORY.md' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
33:scope: Building or extending the `ceph-incident-bundle` runnable tooling, operator runbook, and site integration in `learning-k8s`, especially when the user wants a one-command read-only evidence bundle for basic Linux operators and expects reviewer loops plus publish steps.
34:applies_to: cwd=/Users/ikaros/Documents/code/learning-k8s; reuse_rule=safe for similar `ceph-incident-bundle` work in this checkout, but treat lab topology, smoke-bundle contents, and publish state as checkout-specific and revalidate before reuse
44:- ceph-incident-bundle, collect.sh, verify-bundle.sh, experiments/ceph-incident-bundle, README.md, incident-bundle-runbook.mdx, projects.ts, feature-map.json, quiz.json, code-review, git commit --no-gpg-sign, tar.gz, read-only evidence bundle
72:- In this repo, `make validate` remains a hard gate for content-linked tooling work because it checks MDX, quiz JSON, feature wiring, and Next.js/basePath validation; the bundle itself should also be verified with `bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle>` [Task 1]
83:- Symptom: smoke validation looks noisy or slow because of tar warnings and multi-node collection time. Cause: real bundle generation is slower than unit tests and macOS tar can emit warnings. Fix: trust `verify-bundle.sh` plus the archive contents, not the command start or incidental tar noise [Task 2]

exec
/bin/zsh -lc 'git status --short && git diff --stat b44aa8d..HEAD -- experiments/ceph-incident-bundle' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 2441ms:
 m linux
?? docs/superpowers/reviews/2026-07-01-bestpractices-codereviewer.md
?? docs/superpowers/reviews/2026-07-01-bestpractices-codex-round2.md
?? docs/superpowers/reviews/2026-07-01-bestpractices-codex.md
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-AvULZny0' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-tT3IQR5d' (errno=Operation not permitted)
 experiments/ceph-incident-bundle/README.md         |  16 ++-
 experiments/ceph-incident-bundle/lib/bundle.sh     |  88 ++++++++++++
 .../lib/collect-cluster-cephadm.sh                 |  21 +--
 .../lib/collect-cluster-rook.sh                    |  19 +--
 .../ceph-incident-bundle/lib/collect-node.sh       |   5 -
 experiments/ceph-incident-bundle/lib/common.sh     |  45 ++++--
 experiments/ceph-incident-bundle/run/collect.sh    | 152 ++++++---------------
 7 files changed, 189 insertions(+), 157 deletions(-)

codex
Using `superpowers:using-superpowers` for workflow discipline. I found relevant memory for the Ceph incident bundle, so I’m keeping that context in mind while checking the actual diff instead of relying on it.
exec
/bin/zsh -lc "sed -n '25,90p' /Users/ikaros/.codex/memories/MEMORY.md" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:

## Failures and how to do differently

- Symptom: `rg` output for the whole Logseq workspace gets truncated. Cause: broad full-graph search returns too many matches. Fix: use one broad pass to find candidate dates, then narrow immediately to the specific `journals/YYYY_MM_DD.md` files for confirmation [Task 1]
- Symptom: non-interview events get counted as interview dates. Cause: treating every `台積`/`面試` hit as a formal interview. Fix: explicitly filter out notes like `主管來電`, `等待面試`, or `聯絡 HR` before returning final dates [Task 1]

# Task Group: learning-k8s Ceph incident tooling and docs

scope: Building or extending the `ceph-incident-bundle` runnable tooling, operator runbook, and site integration in `learning-k8s`, especially when the user wants a one-command read-only evidence bundle for basic Linux operators and expects reviewer loops plus publish steps.
applies_to: cwd=/Users/ikaros/Documents/code/learning-k8s; reuse_rule=safe for similar `ceph-incident-bundle` work in this checkout, but treat lab topology, smoke-bundle contents, and publish state as checkout-specific and revalidate before reuse

## Task 1: Build the Ceph incident bundle runbook, scripts, and site integration, then publish

### rollout_summary_files

- rollout_summaries/2026-06-28T15-47-47-ct4R-ceph_incident_bundle_runbook_and_timesyncd_evidence.md (cwd=/Users/ikaros/Documents/code/learning-k8s, rollout_path=/Users/ikaros/.codex/sessions/2026/06/28/rollout-2026-06-28T23-47-47-019f0eea-59e6-70f2-aa97-0f82a7847421.jsonl, updated_at=2026-06-29T10:02:26+00:00, thread_id=019f0eea-59e6-70f2-aa97-0f82a7847421, success; initial bundle/runbook implementation plus commit/push)

### keywords

- ceph-incident-bundle, collect.sh, verify-bundle.sh, experiments/ceph-incident-bundle, README.md, incident-bundle-runbook.mdx, projects.ts, feature-map.json, quiz.json, code-review, git commit --no-gpg-sign, tar.gz, read-only evidence bundle

- Related skill: skills/learning-k8s-content-integration/SKILL.md

## Task 2: Add `systemd-timesyncd` evidence to the incident bundle without redesigning it

### rollout_summary_files

- rollout_summaries/2026-06-28T15-47-47-ct4R-ceph_incident_bundle_runbook_and_timesyncd_evidence.md (cwd=/Users/ikaros/Documents/code/learning-k8s, rollout_path=/Users/ikaros/.codex/sessions/2026/06/28/rollout-2026-06-28T23-47-47-019f0eea-59e6-70f2-aa97-0f82a7847421.jsonl, updated_at=2026-06-29T10:02:26+00:00, thread_id=019f0eea-59e6-70f2-aa97-0f82a7847421, success; follow-up extension for time-sync evidence and negative-case coverage)

### keywords

- systemd-timesyncd, timedatectl status, timedatectl show-timesync --all, timedatectl timesync-status, systemctl status systemd-timesyncd, journalctl -u systemd-timesyncd, SKIPPED.txt, FAKE_TIMESYNCD_MISSING, test-node-collector.sh, VERIFY PASS

- Related skill: skills/learning-k8s-content-integration/SKILL.md

## User preferences

- when the user said "只會基本 linux 不懂 ceph 的人也要會操作" -> write similar incident tooling/docs as simple operator runbooks, not expert-only reference prose [Task 1]
- when the user asked for "一個 shell script 就把所有要收集好的東西收集完，打包成一個 gz file" -> default to one orchestrator entrypoint plus helper scripts, not multiple manual collection steps [Task 1]
- when the user said "每次寫完呼叫 Code Reviewer agent review 並修改問題直到沒問題" -> for similar repo work, run a review loop after each meaningful write and fix findings before moving on [Task 1][Task 2]
- when the user added "加上考慮 timesync 用 systemd-timesyncd" -> treat `systemd-timesyncd` as a first-class supported time-sync source in similar Linux evidence collectors and docs [Task 2]
- when the user asked for "commit no gpg & push" -> treat no-GPG commit plus push as part of the definition of done once validation passes [Task 1]

## Reusable knowledge

- The successful repo pattern for this tool family is `experiments/<topic>/` with `run/`, `lib/`, `tests/`, `results/.gitkeep`, and an operator README, paired with a reader-facing MDX feature page plus `projects.ts`, `feature-map.json`, and `quiz.json` updates [Task 1]
- The Ceph incident bundle is intentionally read-only: collect cluster state, node state, logs, manifests, and command errors, then package them as a `.tar.gz`; do not restart daemons, repair, scrub, or change cluster flags [Task 1]
- In this repo, `make validate` remains a hard gate for content-linked tooling work because it checks MDX, quiz JSON, feature wiring, and Next.js/basePath validation; the bundle itself should also be verified with `bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle>` [Task 1]
- The rollout validated the collector on a six-node cephadm lab, and the verifier still accepted archives that preserved optional-command failures in `errors.log` [Task 1]
- The `systemd-timesyncd` extension now collects `timedatectl status`, `timedatectl show-timesync --all`, `timedatectl timesync-status`, `systemctl status systemd-timesyncd`, `journalctl -u systemd-timesyncd`, and `/etc/systemd/timesyncd.conf` plus `/etc/systemd/timesyncd.conf.d/*.conf` [Task 2]
- Missing `systemd-timesyncd` or missing config should not fail node collection; the collector emits `SKIPPED.txt` and keeps the node successful unless an actual copy operation fails [Task 2]
- The updated docs teach that chrony/ntpq remain supported evidence, while `systemd-timesyncd` is explicitly included for Debian/Ubuntu-style hosts [Task 2]

## Failures and how to do differently

- Symptom: the normal reviewer path returns no useful output because of a usage limit. Cause: reviewer-agent availability failure. Fix: switch quickly to a direct read-only CLI review instead of blocking the whole run [Task 1]
- Symptom: docs drift from collector behavior around flags like `--skip-logs`. Cause: prose was edited without matching the actual script behavior. Fix: align the documentation wording to the script when the script behavior is already correct [Task 1]
- Symptom: a follow-up evidence-source addition only covers the happy path. Cause: new collector logic was added without a negative fixture. Fix: add a missing-source case like `FAKE_TIMESYNCD_MISSING=1` so collection still exits 0 and emits `SKIPPED.txt` when `systemd-timesyncd` is absent [Task 2]
- Symptom: smoke validation looks noisy or slow because of tar warnings and multi-node collection time. Cause: real bundle generation is slower than unit tests and macOS tar can emit warnings. Fix: trust `verify-bundle.sh` plus the archive contents, not the command start or incidental tar noise [Task 2]
- Symptom: generated bundle archives leak into the staged diff. Cause: smoke tarballs were created under ignored result paths but not checked before staging. Fix: inspect `git status` before staging and keep `results/*.tar.gz` out of commits [Task 1]

# Task Group: learning-k8s content maintenance / GitHub Pages basePath validation

scope: Whole-repo article-link maintenance and deployed-route correctness in `learning-k8s`, especially when the user asks to review all articles or later broadens scope to include GitHub Pages subpath behavior.
applies_to: cwd=/Users/ikaros/Documents/code/learning-k8s; reuse_rule=safe for similar repo-wide content maintenance in this checkout, but treat current external URLs, deployment config, and validator behavior as checkout-specific and revalidate before reuse


exec
/bin/zsh -lc 'git diff --unified=80 b44aa8d..HEAD -- experiments/ceph-incident-bundle/lib/common.sh experiments/ceph-incident-bundle/lib/bundle.sh' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-IOJihCYG' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-4sLIDAYI' (errno=Operation not permitted)
diff --git a/experiments/ceph-incident-bundle/lib/bundle.sh b/experiments/ceph-incident-bundle/lib/bundle.sh
new file mode 100644
index 0000000..fabb2eb
--- /dev/null
+++ b/experiments/ceph-incident-bundle/lib/bundle.sh
@@ -0,0 +1,88 @@
+#!/usr/bin/env bash
+set -euo pipefail
+
+# Bundle/orchestration helpers used by run/collect.sh. These are pure-ish units
+# (SSH target/quoting, bundle metadata, summary, error log, redaction driver)
+# kept out of the entrypoint so collect.sh stays a thin orchestrator. Relies on
+# common.sh (sourced first by the entrypoint) for redact_file/redact_gz_file.
+
+ssh_target_for_host() {
+  local host=$1 ssh_user=$2
+  if [[ "$host" == *@* || -z "$ssh_user" ]]; then
+    printf '%s' "$host"
+  else
+    printf '%s@%s' "$ssh_user" "$host"
+  fi
+}
+
+# Quote a value for safe interpolation into a remote shell string. Returns 1 if
+# the value contains a single quote (callers treat that as a hard input error).
+shell_quote() {
+  local value=$1
+  [[ "$value" != *"'"* ]] || return 1
+  printf "'%s'" "$value"
+}
+
+write_initial_metadata() {
+  local workdir=$1 mode=$2 seed=$3 since=$4 timeout=$5
+  local git_commit
+  git_commit="$(git -C "$COLLECT_ROOT/../.." rev-parse --short HEAD 2>/dev/null || printf unknown)"
+
+  cat >"$workdir/README-FIRST.txt" <<'EOF'
+Ceph incident bundle
+
+Start with:
+- summary.txt
+- errors.log
+- cluster/
+- nodes/
+
+This bundle is read-only evidence captured at incident time. Review it before sharing outside your team.
+EOF
+
+  cat >"$workdir/environment.txt" <<EOF
+created_utc=$(date -u +%FT%TZ)
+mode=$mode
+seed=$seed
+since=$since
+timeout=$timeout
+git_commit=$git_commit
+EOF
+
+  : >"$workdir/manifest.jsonl"
+  : >"$workdir/errors.log"
+}
+
+write_summary() {
+  local workdir=$1 mode=$2 seed=$3 node_ok=$4 node_failed=$5 cluster_status=$6 final_status=$7
+
+  {
+    printf 'Ceph incident bundle summary\n'
+    printf 'created_utc: %s\n' "$(date -u +%FT%TZ)"
+    printf 'mode: %s\n' "$mode"
+    printf 'seed: %s\n' "$seed"
+    printf 'cluster_status: %s\n' "$cluster_status"
+    printf 'node_ok: %s\n' "$node_ok"
+    printf 'node_failed: %s\n' "$node_failed"
+    printf 'final_status: %s\n' "$final_status"
+  } >"$workdir/summary.txt"
+}
+
+append_error() {
+  local workdir=$1 message=$2
+  printf '%s %s\n' "$(date -u +%FT%TZ)" "$message" >>"$workdir/errors.log"
+}
+
+# Redact every text-ish artifact in the bundle in place (gz handled specially).
+redact_bundle_text() {
+  local workdir=$1
+  local redaction_log="$workdir/redactions.log"
+  local path
+
+  while IFS= read -r path; do
+    case "$path" in
+      *.gz) redact_gz_file "$path" "$redaction_log" ;;
+      *) redact_file "$path" "$redaction_log" ;;
+    esac
+  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' -o -name '*.gz' \) -print 2>/dev/null || true)
+}
diff --git a/experiments/ceph-incident-bundle/lib/common.sh b/experiments/ceph-incident-bundle/lib/common.sh
index b223c37..1726c0e 100644
--- a/experiments/ceph-incident-bundle/lib/common.sh
+++ b/experiments/ceph-incident-bundle/lib/common.sh
@@ -1,196 +1,219 @@
 #!/usr/bin/env bash
 set -euo pipefail
 
 # Shared helpers for the Ceph incident bundle harness.
 
 log() {
   # stderr: stdout is reserved for the final `bundle:` line (machine-readable).
   printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
 }
 
 die() {
   log "FATAL: $*"
   exit 1
 }
 
-ceph_incident_bundle_log() {
-  log "$*"
-}
-
 require_file() {
   [[ -f "$1" ]] || die "missing file: $1"
 }
 
 ensure_dir() {
   mkdir -p "$1"
 }
 
+# Shared SSH option vector (incl. -i KEY). Printed one argv item per line so
+# callers fill an array with `while IFS= read -r w; do a+=("$w"); done` — the
+# bash-3.2-safe idiom used throughout (no mapfile). Single source of truth so a
+# flag like BatchMode can't drift between call sites.
+ssh_base_opts() {
+  local ssh_key=$1 timeout=$2
+  printf '%s\n' \
+    -i "$ssh_key" \
+    -o BatchMode=yes \
+    -o IdentitiesOnly=yes \
+    -o IdentityAgent=none \
+    -o "ConnectTimeout=$timeout" \
+    -o "ServerAliveInterval=$timeout" \
+    -o ServerAliveCountMax=1
+}
+
+# Write a `SKIPPED: <reason>` artifact. `_once` does not overwrite an existing
+# file (so a collector's specific reason is never clobbered by a generic one).
+write_skip_artifact() {
+  local artifact=$1 reason=$2
+  ensure_dir "$(dirname -- "$artifact")"
+  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
+}
+
+write_skip_artifact_once() {
+  local artifact=$1 reason=$2
+  [[ -f "$artifact" ]] && return 0
+  write_skip_artifact "$artifact" "$reason"
+}
+
 # Live progress to stderr (stdout stays reserved for the final `bundle:` line).
 # Suppressed when CEPH_INCIDENT_QUIET is set. Call only from workstation-side
 # code — NOT from the remote node collector (its stderr is multiplexed over ssh).
 progress() {
   [[ -n "${CEPH_INCIDENT_QUIET:-}" ]] && return 0
   printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
 }
 
 # Resolve a timeout binary: GNU coreutils `timeout`, or `gtimeout` on macOS.
 # Prints the binary name, or nothing if neither is installed.
 timeout_cmd() {
   if command -v timeout >/dev/null 2>&1; then
     printf 'timeout'
   elif command -v gtimeout >/dev/null 2>&1; then
     printf 'gtimeout'
   fi
 }
 
 json_escape() {
   local value=$1
   value=${value//\\/\\\\}
   value=${value//\"/\\\"}
   value=${value//$'\n'/\\n}
   value=${value//$'\r'/\\r}
   value=${value//$'\t'/\\t}
   printf '%s' "$value"
 }
 
 manifest_add() {
   local manifest=$1 host=$2 collector=$3 artifact=$4 command=$5 exit_code=$6 started=$7 ended=$8
   [[ "$exit_code" =~ ^[0-9]+$ ]] || die "manifest_add requires numeric exit_code: $exit_code"
   ensure_dir "$(dirname -- "$manifest")"
   printf '{"host":"%s","collector":"%s","artifact":"%s","command":"%s","exit_code":%s,"started":"%s","ended":"%s"}\n' \
     "$(json_escape "$host")" \
     "$(json_escape "$collector")" \
     "$(json_escape "$artifact")" \
     "$(json_escape "$command")" \
     "$exit_code" \
     "$(json_escape "$started")" \
     "$(json_escape "$ended")" >>"$manifest"
 }
 
 redact_file() {
   local source_file=$1 redaction_log=$2
   require_file "$source_file"
   ensure_dir "$(dirname -- "$redaction_log")"
 
-  local source_dir tmp_file count line nocasematch_state in_pem redact mode
+  local source_dir tmp_file count line nocase_was_set in_pem redact mode
   source_dir="$(dirname -- "$source_file")"
   tmp_file="$(mktemp "$source_dir/.${source_file##*/}.XXXXXX")"
   count=0
   in_pem=0
-  if shopt -q nocasematch; then
-    nocasematch_state='shopt -s nocasematch'
-  else
-    nocasematch_state='shopt -u nocasematch'
-  fi
+  nocase_was_set=0
+  shopt -q nocasematch && nocase_was_set=1
   shopt -s nocasematch
 
   # Best-effort redaction (NOT a complete DLP): keyword lines, ceph key
   # material (`key = AQB..==`, base64 blobs), and whole multi-line PEM private
   # key blocks. Extensions/encodings outside this are intentionally not covered
   # — see README "安全界線"; operators must self-review before sharing.
   while IFS= read -r line || [[ -n "$line" ]]; do
     redact=0
     if [[ "$line" =~ -----BEGIN[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
       in_pem=1
     fi
     if [[ $in_pem -eq 1 ]]; then
       redact=1
       if [[ "$line" =~ -----END[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
         in_pem=0
       fi
     elif [[ "$line" =~ (password|secret|token|keyring|private([[:space:]_-]+)?key) ]]; then
       redact=1
     elif [[ "$line" =~ (^|[^[:alnum:]])key[[:space:]]*[:=] ]]; then
       redact=1
     elif [[ "$line" =~ [A-Za-z0-9+/]{38,}={1,2} ]]; then
       redact=1
     fi
     if [[ $redact -eq 1 ]]; then
       printf '[REDACTED]\n' >>"$tmp_file"
       count=$((count + 1))
     else
       printf '%s\n' "$line" >>"$tmp_file"
     fi
   done <"$source_file"
 
-  eval "$nocasematch_state"
+  if [[ $nocase_was_set -eq 1 ]]; then shopt -s nocasematch; else shopt -u nocasematch; fi
   mode="$(stat -c '%a' "$source_file" 2>/dev/null || stat -f '%Lp' "$source_file" 2>/dev/null || printf '600')"
   chmod "$mode" "$tmp_file" 2>/dev/null || true
   mv -f -- "$tmp_file" "$source_file"
   printf '%s: %s line(s) redacted\n' "$source_file" "$count" >>"$redaction_log"
 }
 
 redact_gz_file() {
   # Decompress a gzipped artifact, redact it, recompress in place so rotated
   # logs (*.gz) get the same redaction as plain text.
   local source_file=$1 redaction_log=$2
   require_file "$source_file"
   ensure_dir "$(dirname -- "$redaction_log")"
 
   local dir tmp_plain
   dir="$(dirname -- "$source_file")"
   tmp_plain="$(mktemp "$dir/.${source_file##*/}.plain.XXXXXX")"
   if ! gzip -dc -- "$source_file" >"$tmp_plain" 2>/dev/null; then
     rm -f -- "$tmp_plain"
     printf '%s: gz decompress failed, left as-is (NOT redacted)\n' "$source_file" >>"$redaction_log"
     return 0
   fi
 
   redact_file "$tmp_plain" "$redaction_log"
   if gzip -c -- "$tmp_plain" >"$source_file"; then
     rm -f -- "$tmp_plain"
   else
     rm -f -- "$tmp_plain"
     return 1
   fi
 }
 
 run_capture() {
   local manifest=$1 host=$2 collector=$3 artifact=$4
   shift 4
   [[ ${1-} == -- ]] || die "run_capture requires -- before the command"
   shift
 
   local -a cmd
   local started ended rc command_string artifact_dir artifact_tmp
 
   cmd=("$@")
   [[ ${#cmd[@]} -gt 0 ]] || die "run_capture requires a command"
 
   started="$(date -u +%FT%TZ)"
   artifact_dir="$(dirname -- "$artifact")"
   ensure_dir "$artifact_dir"
   artifact_tmp="$(mktemp "$artifact_dir/.${artifact##*/}.XXXXXX")"
 
   printf '# host: %s\n# collector: %s\n# started: %s\n' "$host" "$collector" "$started" >"$artifact_tmp"
   printf -v command_string '%q ' "${cmd[@]}"
   command_string=${command_string% }
 
   local tbin
   tbin="$(timeout_cmd)"
   if [[ -n "$tbin" ]]; then
     printf '# timeout: %ss\n' "${COMMAND_TIMEOUT:-20}" >>"$artifact_tmp"
     if "$tbin" "${COMMAND_TIMEOUT:-20}" "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
       rc=0
     else
       rc=$?
     fi
   else
     printf '# timeout: unavailable\n' >>"$artifact_tmp"
     if "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
       rc=0
     else
       rc=$?
     fi
   fi
 
   # Make timeout-kills (124) distinguishable from ordinary command failure, and
   # mark the artifact so a truncated capture is visible to whoever reads it.
   if [[ $rc -eq 124 || $rc -eq 137 ]]; then
     printf '# TRUNCATED: command timed out after %ss (exit %s)\n' "${COMMAND_TIMEOUT:-20}" "$rc" >>"$artifact_tmp"
   fi
 
   ended="$(date -u +%FT%TZ)"
   mv -f -- "$artifact_tmp" "$artifact"
   manifest_add "$manifest" "$host" "$collector" "$artifact" "$command_string" "$rc" "$started" "$ended"
 

exec
/bin/zsh -lc 'git diff --unified=80 b44aa8d..HEAD -- experiments/ceph-incident-bundle/run/collect.sh' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-miN6yBPY' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-tBBg1hV0' (errno=Operation not permitted)
diff --git a/experiments/ceph-incident-bundle/run/collect.sh b/experiments/ceph-incident-bundle/run/collect.sh
index 309a455..e84ad51 100755
--- a/experiments/ceph-incident-bundle/run/collect.sh
+++ b/experiments/ceph-incident-bundle/run/collect.sh
@@ -1,604 +1,538 @@
 #!/usr/bin/env bash
 set -euo pipefail
 
 # Ceph incident bundle collection entrypoint.
 
 COLLECT_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 COLLECT_ROOT="$(cd "$COLLECT_RUN_DIR/.." && pwd)"
 # shellcheck disable=SC1091
 source "$COLLECT_ROOT/lib/common.sh"
 # shellcheck disable=SC1091
 source "$COLLECT_ROOT/lib/collect-cluster-cephadm.sh"
 # shellcheck disable=SC1091
 source "$COLLECT_ROOT/lib/collect-cluster-rook.sh"
+# shellcheck disable=SC1091
+source "$COLLECT_ROOT/lib/bundle.sh"
 
 usage() {
   cat <<'EOF'
 Usage: collect.sh --inventory PATH --ssh-key PATH [options]
 
 One command example:
   bash experiments/ceph-incident-bundle/run/collect.sh \
     --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
     --ssh-key .ssh/id_ed25519 \
     --mode cephadm \
     --since 24h
 
 Required:
   --inventory PATH       shell inventory with HOSTS=( "alias=host" ... )
   --ssh-key PATH         SSH private key used to reach every node
 
 Options:
   --seed USER@HOST       override inventory SEED_HOST
   --out DIR              output dir (default: experiments/ceph-incident-bundle/results)
   --mode auto|cephadm|rook   auto = per-node detect, collect ceph and/or rook layer
   --kube-context CTX     kubectl context for the rook layer (default: none)
   --kube-mode MODE       where the rook layer runs kubectl: remote (on an
                          inventory node, default) or local (this jump host)
   --since DURATION       log/journal window (default: 24h)
   --timeout SECONDS      per-command / SSH-connect timeout (default: 20)
   --node-timeout SECONDS overall timeout for one node's full collection (default: 600)
   --skip-logs            collect state but skip larger Ceph log copies
   --quiet                suppress progress output on stderr (stdout still prints bundle:)
   --keep-workdir         keep temporary extracted workdir for debugging
   --help                 print this help
 
 Output:
   DIR/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
 
 Exit codes:
   0 complete, 2 partial collection failure with bundle produced, 1 usage/config/verify failure
 EOF
 }
 
-parse_host_entry() {
-  local entry=$1
-  [[ "$entry" == *=* ]] || return 1
-  printf '%s\n' "${entry%%=*}" "${entry#*=}"
-}
-
-ssh_target_for_host() {
-  local host=$1 ssh_user=$2
-  if [[ "$host" == *@* || -z "$ssh_user" ]]; then
-    printf '%s' "$host"
-  else
-    printf '%s@%s' "$ssh_user" "$host"
-  fi
-}
-
-shell_quote() {
-  local value=$1
-  [[ "$value" != *"'"* ]] || return 1
-  printf "'%s'" "$value"
-}
-
-write_initial_metadata() {
-  local workdir=$1 mode=$2 seed=$3 since=$4 timeout=$5
-  local git_commit
-  git_commit="$(git -C "$COLLECT_ROOT/../.." rev-parse --short HEAD 2>/dev/null || printf unknown)"
-
-  cat >"$workdir/README-FIRST.txt" <<'EOF'
-Ceph incident bundle
-
-Start with:
-- summary.txt
-- errors.log
-- cluster/
-- nodes/
-
-This bundle is read-only evidence captured at incident time. Review it before sharing outside your team.
-EOF
-
-  cat >"$workdir/environment.txt" <<EOF
-created_utc=$(date -u +%FT%TZ)
-mode=$mode
-seed=$seed
-since=$since
-timeout=$timeout
-git_commit=$git_commit
-EOF
-
-  : >"$workdir/manifest.jsonl"
-  : >"$workdir/errors.log"
-}
-
-write_summary() {
-  local workdir=$1 mode=$2 seed=$3 node_ok=$4 node_failed=$5 cluster_status=$6 final_status=$7
-
-  {
-    printf 'Ceph incident bundle summary\n'
-    printf 'created_utc: %s\n' "$(date -u +%FT%TZ)"
-    printf 'mode: %s\n' "$mode"
-    printf 'seed: %s\n' "$seed"
-    printf 'cluster_status: %s\n' "$cluster_status"
-    printf 'node_ok: %s\n' "$node_ok"
-    printf 'node_failed: %s\n' "$node_failed"
-    printf 'final_status: %s\n' "$final_status"
-  } >"$workdir/summary.txt"
-}
-
-append_error() {
-  local workdir=$1 message=$2
-  printf '%s %s\n' "$(date -u +%FT%TZ)" "$message" >>"$workdir/errors.log"
-}
-
 detect_node_caps() {
   # echo a space-joined subset of "cephadm kubectl" present on the target node.
   # A probe that fails to ssh is NOT the same as "node has no caps" — record the
   # ssh failure to ERROR_LOG so a silently-dropped cluster source is visible.
   local target=$1 ssh_key=$2 timeout=$3
-  local tbin out rc
-  local -a ssh_cmd
+  local tbin out rc _w
+  local -a ssh_cmd sopts
+  while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
   # SC2016: the probe script is single-quoted on purpose — it expands on the remote.
   # shellcheck disable=SC2016
-  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v ceph >/dev/null 2>&1 && caps="$caps ceph"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
+  ssh_cmd=(ssh "${sopts[@]}" "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v ceph >/dev/null 2>&1 && caps="$caps ceph"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
   tbin="$(timeout_cmd)"
   if [[ -n "$tbin" ]]; then
     ssh_cmd=("$tbin" "$timeout" "${ssh_cmd[@]}")
   fi
   out="$("${ssh_cmd[@]}" 2>/dev/null)"
   rc=$?
   if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
     ensure_dir "$(dirname -- "$ERROR_LOG")"
     printf '%s capability probe failed for %s (ssh exit %s) — node not considered as a cluster source\n' \
       "$(date -u +%FT%TZ)" "$target" "$rc" >>"$ERROR_LOG"
   fi
   printf '%s' "$out"
 }
 
 # Does a given runner actually connect to the cluster on this node? "usable" is
 # defined as `ceph -s` succeeding, not merely the binary existing.
 ceph_runner_probe() {
   local target=$1 ssh_key=$2 timeout=$3 method=$4
   local tbin w
-  local -a pfx ssh_cmd
+  local -a pfx ssh_cmd sopts
   while IFS= read -r w; do pfx+=("$w"); done < <(ceph_runner_argv "$method")
-  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" "${pfx[@]}" --connect-timeout 5 -s)
+  while IFS= read -r w; do sopts+=("$w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
+  ssh_cmd=(ssh "${sopts[@]}" "$target" "${pfx[@]}" --connect-timeout 5 -s)
   tbin="$(timeout_cmd)"
   [[ -n "$tbin" ]] && ssh_cmd=("$tbin" "$timeout" "${ssh_cmd[@]}")
   "${ssh_cmd[@]}" >/dev/null 2>&1
 }
 
 # Pick the fastest runner that connects on $target: direct ceph, sudo ceph, then
 # cephadm shell. Echoes the runner token, or nothing if none connects.
 ceph_runner_for() {
   local target=$1 ssh_key=$2 timeout=$3 m
   for m in direct sudo cephadm; do
     if ceph_runner_probe "$target" "$ssh_key" "$timeout" "$m"; then
       printf '%s' "$m"
       return 0
     fi
   done
+  # Contract: success with EMPTY stdout = no runner connected. Callers must test
+  # for empty output, not the exit status (which is always 0).
   return 0
 }
 
 # Probe each node once; pick cluster-ceph source (first cephadm node, or --seed)
 # and cluster-rook source (first kubectl node); collect each requested layer once.
 # Uses globals HOST_TARGETS (set by main).
 collect_clusters() {
-  local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8 kube_context=$9 kube_mode="${10:-remote}" rook_operator_namespace="${11:-}"
+  local mode='' workdir='' manifest='' seed='' ssh_key='' since=24h timeout=20
+  local rook_namespace=rook-ceph kube_context='' kube_mode=remote rook_operator_namespace=''
+  while [[ $# -gt 0 ]]; do
+    case "$1" in
+      --mode) mode=${2-}; shift 2 ;;
+      --workdir) workdir=${2-}; shift 2 ;;
+      --manifest) manifest=${2-}; shift 2 ;;
+      --seed) seed=${2-}; shift 2 ;;
+      --ssh-key) ssh_key=${2-}; shift 2 ;;
+      --since) since=${2-}; shift 2 ;;
+      --timeout) timeout=${2-}; shift 2 ;;
+      --namespace) rook_namespace=${2-}; shift 2 ;;
+      --operator-namespace) rook_operator_namespace=${2-}; shift 2 ;;
+      --kube-context) kube_context=${2-}; shift 2 ;;
+      --kube-mode) kube_mode=${2-}; shift 2 ;;
+      *) return 1 ;;
+    esac
+  done
   local ceph_source='' ceph_runner='' rook_source='' i caps rc=0
   local want_ceph=0 want_rook=0 ceph_done=0 rook_done=0
   # so detect_node_caps can record probe ssh failures
   local ERROR_LOG="$workdir/errors.log"
   case "$mode" in
     cephadm) want_ceph=1 ;;
     rook) want_rook=1 ;;
     auto) want_ceph=1; want_rook=1 ;;
     *) return 1 ;;
   esac
 
   # explicit --seed pins the cluster-ceph source; the runner is still chosen by
   # connectivity (so direct ceph is preferred on the seed too).
   if [[ $want_ceph -eq 1 && -n "$seed" ]]; then
     ceph_source="$seed"
     ceph_runner="$(ceph_runner_for "$seed" "$ssh_key" "$timeout")"
   fi
 
   # Only probe nodes for kubectl when the rook layer runs remotely.
   local probe_rook=0
   [[ $want_rook -eq 1 && "$kube_mode" == remote ]] && probe_rook=1
 
   # probe nodes only if a source we need is still unknown
   if { [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; } || [[ $probe_rook -eq 1 ]]; then
     if [[ ${#HOST_TARGETS[@]} -gt 0 ]]; then
       progress "probing ${#HOST_TARGETS[@]} nodes for capabilities…"
       for i in "${!HOST_TARGETS[@]}"; do
         caps="$(detect_node_caps "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
         progress "[$((i + 1))/${#HOST_TARGETS[@]}] probe ${HOST_TARGETS[$i]}: ${caps:-none}"
         # ceph source = first candidate (has ceph or cephadm binary) whose runner
         # actually connects to the cluster.
         if [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; then
           case " $caps " in
             *" ceph "*|*" cephadm "*)
               ceph_runner="$(ceph_runner_for "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
               [[ -n "$ceph_runner" ]] && ceph_source="${HOST_TARGETS[$i]}"
               ;;
           esac
         fi
         if [[ $probe_rook -eq 1 && -z "$rook_source" ]]; then
           case " $caps " in *" kubectl "*) rook_source="${HOST_TARGETS[$i]}" ;; esac
         fi
         if { [[ $want_ceph -eq 0 || -n "$ceph_source" ]]; } && { [[ $probe_rook -eq 0 || -n "$rook_source" ]]; }; then
           break
         fi
       done
     fi
   fi
 
   # cluster-ceph layer
   if [[ $want_ceph -eq 1 && -n "$ceph_source" ]]; then
     progress "collecting ceph cluster from $ceph_source via ${ceph_runner:-cephadm}…"
     collect_cluster_cephadm "$workdir" "$manifest" "$ceph_source" "$ssh_key" "$since" "$timeout" "${ceph_runner:-cephadm}" || rc=2
     ceph_done=1
   fi
 
   # cluster-rook layer: local (this jump host) or remote (on a kubectl node)
   if [[ $want_rook -eq 1 && ( "$kube_mode" == local || -n "$rook_source" ) ]]; then
     local -a rook_args
     rook_args=(--out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout")
     [[ -n "$rook_operator_namespace" ]] && rook_args+=(--operator-namespace "$rook_operator_namespace")
     if [[ "$kube_mode" == local ]]; then
       rook_source=local
       progress "collecting rook from local kubectl (ns=$rook_namespace)…"
     else
       rook_args+=(--ssh-target "$rook_source" --ssh-key "$ssh_key")
       progress "collecting rook from $rook_source (ns=$rook_namespace)…"
     fi
     [[ -n "$kube_context" ]] && rook_args+=(--kube-context "$kube_context")
     [[ "$mode" == auto ]] && rook_args+=(--allow-skip)
     collect_cluster_rook "${rook_args[@]}" || rc=2
     # "done" means real rook evidence was collected — NOT just an --allow-skip
     # (e.g. namespace missing) which returns 0 but only writes SKIPPED.txt.
     [[ -f "$workdir/cluster/rook/pods-wide.txt" ]] && rook_done=1
   fi
 
   # missing-source handling
   # When a layer wasn't collected, leave a SKIPPED.txt — but never clobber a more
   # specific reason the collector already wrote (e.g. "namespace not found").
   if [[ "$mode" == cephadm && $ceph_done -eq 0 ]]; then
-    ensure_dir "$workdir/cluster/ceph"
-    [[ -f "$workdir/cluster/ceph/SKIPPED.txt" ]] || printf 'SKIPPED: no cephadm-capable node found (or --seed unreachable)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
+    write_skip_artifact_once "$workdir/cluster/ceph/SKIPPED.txt" "no cephadm-capable node found (or --seed unreachable)"
     rc=2
   elif [[ "$mode" == rook && $rook_done -eq 0 ]]; then
-    ensure_dir "$workdir/cluster/rook"
-    [[ -f "$workdir/cluster/rook/SKIPPED.txt" ]] || printf 'SKIPPED: no kubectl-capable node found\n' >"$workdir/cluster/rook/SKIPPED.txt"
+    write_skip_artifact_once "$workdir/cluster/rook/SKIPPED.txt" "no kubectl-capable node found"
     rc=2
   elif [[ "$mode" == auto ]]; then
     # auto = collect whatever exists; only a hard failure if NEITHER layer found
-    if [[ $ceph_done -eq 0 ]]; then
-      ensure_dir "$workdir/cluster/ceph"
-      [[ -f "$workdir/cluster/ceph/SKIPPED.txt" ]] || printf 'SKIPPED: no cephadm-capable node in inventory (auto)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
-    fi
-    if [[ $rook_done -eq 0 ]]; then
-      ensure_dir "$workdir/cluster/rook"
-      [[ -f "$workdir/cluster/rook/SKIPPED.txt" ]] || printf 'SKIPPED: no kubectl-capable node in inventory (auto)\n' >"$workdir/cluster/rook/SKIPPED.txt"
-    fi
-    if [[ $ceph_done -eq 0 && $rook_done -eq 0 ]]; then
-      rc=2
-    fi
+    [[ $ceph_done -eq 0 ]] && write_skip_artifact_once "$workdir/cluster/ceph/SKIPPED.txt" "no cephadm-capable node in inventory (auto)"
+    [[ $rook_done -eq 0 ]] && write_skip_artifact_once "$workdir/cluster/rook/SKIPPED.txt" "no kubectl-capable node in inventory (auto)"
+    [[ $ceph_done -eq 0 && $rook_done -eq 0 ]] && rc=2
   fi
 
   # Record which node each cluster layer was collected from (observability:
   # "which host did we trust for ceph status?").
   {
     printf 'ceph_source=%s\n' "${ceph_source:-<none>}"
     printf 'ceph_runner=%s\n' "${ceph_runner:-<none>}"
     printf 'rook_source=%s\n' "${rook_source:-<none>}"
   } >>"$workdir/environment.txt"
 
   return "$rc"
 }
 
 collect_remote_node() {
   local workdir=$1 alias=$2 target=$3 ssh_key=$4 since=$5 timeout=$6 skip_logs=$7 node_timeout=$8
   local node_dir="$workdir/nodes/$alias"
   local node_tar="$workdir/.node-$alias.tar.gz"
-  local remote_cmd rc=0 tbin
+  local remote_cmd rc=0 tbin _w
   local q_alias q_since q_timeout
-  local -a ssh_cmd
+  local -a ssh_cmd sopts
 
   q_alias="$(shell_quote "$alias")" || return 1
   q_since="$(shell_quote "$since")" || return 1
   q_timeout="$(shell_quote "$timeout")" || return 1
 
   # Remote side uses a gzip pipe (not `tar -z`) so minimal/BusyBox tar still works,
   # and traps its own temp dir so an interrupted/timed-out run leaves nothing behind.
   remote_cmd="set -u; tmp=\"\${TMPDIR:-/tmp}/ceph-incident-node.\$\$\"; rm -rf \"\$tmp\"; mkdir -p \"\$tmp\" || { printf 'SKIPPED: remote tmp not writable\n' >&2; exit 75; }; trap 'rm -rf \"\$tmp\"' EXIT INT TERM; gzip -dc | tar -xf - -C \"\$tmp\"; out=\"\$tmp/out\"; set +e; bash \"\$tmp/lib/collect-node.sh\" --out \"\$out\" --host-alias $q_alias --since $q_since --timeout $q_timeout"
   if [[ "$skip_logs" == "1" ]]; then
     remote_cmd+=" --skip-logs"
   fi
   remote_cmd+="; rc=\$?; set -e; if [ -d \"\$out\" ]; then tar -cf - -C \"\$out\" . | gzip -c; else mkdir -p \"\$out\"; printf 'SKIPPED: remote collect-node did not create output\n' >\"\$out/SKIPPED.txt\"; tar -cf - -C \"\$out\" . | gzip -c; fi; exit \"\$rc\""
 
-  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" "$remote_cmd")
+  while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
+  ssh_cmd=(ssh "${sopts[@]}" "$target" "$remote_cmd")
   tbin="$(timeout_cmd)"
   if [[ -n "$tbin" ]]; then
     # Outer wrapper bounds the WHOLE node collection — must be the generous
     # node timeout, never the small per-command timeout (which would kill a
     # slow/large node mid-collection).
     ssh_cmd=("$tbin" "$node_timeout" "${ssh_cmd[@]}")
   fi
 
   # macOS bsdtar embeds com.apple.* xattr headers that make the remote GNU tar
   # print "Ignoring unknown extended header keyword" noise; strip them at source.
   local noxattrs=''
   if tar --version 2>&1 | grep -qi 'bsdtar'; then
     noxattrs='--no-xattrs'
   fi
 
   set +e
   # shellcheck disable=SC2086
   COPYFILE_DISABLE=1 tar $noxattrs -cf - -C "$COLLECT_ROOT" lib/common.sh lib/collect-node.sh | gzip -c |
     "${ssh_cmd[@]}" >"$node_tar"
   rc=$?
   set -e
 
   ensure_dir "$node_dir"
   if [[ $rc -eq 124 || $rc -eq 137 ]]; then
     printf 'SKIPPED: node collection timed out after %ss (exit %s) from %s\n' "$node_timeout" "$rc" "$target" >"$node_dir/SKIPPED.txt"
     rm -f "$node_tar"
     return 2
   fi
 
   if [[ -s "$node_tar" ]] && tar -xzf "$node_tar" -C "$node_dir" >/dev/null 2>/dev/null; then
     # A node that streamed a valid archive but is missing its own manifest.jsonl
     # was truncated (partial/interrupted transfer) — do not count it as ok.
     if [[ ! -f "$node_dir/manifest.jsonl" ]]; then
       printf 'SKIPPED: node archive from %s is incomplete (no manifest.jsonl); treated as failure\n' "$target" >"$node_dir/SKIPPED.txt"
       rc=2
     fi
   else
     rm -rf "$node_dir"
     ensure_dir "$node_dir"
     printf 'SKIPPED: no usable node archive returned from %s (ssh exit %s)\n' "$target" "$rc" >"$node_dir/SKIPPED.txt"
     [[ $rc -ne 0 ]] || rc=2
   fi
   rm -f "$node_tar"
 
   return "$rc"
 }
 
-redact_bundle_text() {
-  local workdir=$1
-  local redaction_log="$workdir/redactions.log"
-  local path
-
-  while IFS= read -r path; do
-    case "$path" in
-      *.gz) redact_gz_file "$path" "$redaction_log" ;;
-      *) redact_file "$path" "$redaction_log" ;;
-    esac
-  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' -o -name '*.gz' \) -print 2>/dev/null || true)
-}
-
 # Single cleanup point. Uses globals (not main's locals) so it works as an
 # EXIT trap, which fires after main has returned and its locals are gone.
 CLEANUP_WORKDIR=
 CLEANUP_KEEP=0
 # Parsed inventory (alias/target pairs); filled by main, read by collect_clusters + node loop.
 HOST_ALIASES=()
 HOST_TARGETS=()
 cleanup_workdir() {
   local rc=$?
   if [[ -n "${CLEANUP_WORKDIR:-}" && -d "$CLEANUP_WORKDIR" ]]; then
     if [[ "${CLEANUP_KEEP:-0}" -eq 1 ]]; then
       printf 'kept workdir: %s\n' "$CLEANUP_WORKDIR" >&2
     else
       rm -rf -- "$CLEANUP_WORKDIR"
     fi
   fi
   return "$rc"
 }
 
 main() {
   local inventory='' ssh_key='' seed_override='' out_dir="$COLLECT_ROOT/results"
   local mode=auto since=24h timeout=20 node_timeout=600 skip_logs=0 keep_workdir=0
   local seed='' ssh_user='' seed_host='' rook_namespace=rook-ceph rook_operator_namespace=rook-ceph kube_context='' kube_mode=remote
   local timestamp workdir manifest bundle rc=0 cluster_rc=0 node_ok=0 node_failed=0
 
   if [[ $# -eq 0 ]]; then
     usage >&2
     return 1
   fi
 
   while [[ $# -gt 0 ]]; do
     case "$1" in
       --inventory)
         inventory=${2-}
         shift 2
         ;;
       --ssh-key)
         ssh_key=${2-}
         shift 2
         ;;
       --seed)
         seed_override=${2-}
         shift 2
         ;;
       --out)
         out_dir=${2-}
         shift 2
         ;;
       --mode)
         mode=${2-}
         shift 2
         ;;
       --kube-context)
         kube_context=${2-}
         shift 2
         ;;
       --kube-mode)
         kube_mode=${2-}
         shift 2
         ;;
       --since)
         since=${2-}
         shift 2
         ;;
       --timeout)
         timeout=${2-}
         shift 2
         ;;
       --node-timeout)
         node_timeout=${2-}
         shift 2
         ;;
       --skip-logs)
         skip_logs=1
         shift
         ;;
       --quiet)
         export CEPH_INCIDENT_QUIET=1
         shift
         ;;
       --keep-workdir)
         keep_workdir=1
         shift
         ;;
       --help|-h)
         usage
         return 0
         ;;
       *)
         usage >&2
         return 1
         ;;
     esac
   done
 
   [[ "$mode" == "auto" || "$mode" == "cephadm" || "$mode" == "rook" ]] || die "unsupported mode: $mode"
   # kube-context runs through a remote shell (ssh kubectl --context ...). Block the
   # actual shell metacharacters but allow the chars real contexts use (@ : / for
   # e.g. kubernetes-admin@kubernetes and EKS ARNs).
   if [[ -n "$kube_context" && "$kube_context" == *[!A-Za-z0-9._@:/-]* ]]; then
     die "invalid --kube-context (allowed: A-Za-z0-9._@:/-): $kube_context"
   fi
   [[ "$kube_mode" == "local" || "$kube_mode" == "remote" ]] || die "invalid --kube-mode (local|remote): $kube_mode"
   [[ -n "$inventory" && -f "$inventory" ]] || die "missing inventory: ${inventory:-<unset>}"
   [[ -n "$ssh_key" && -f "$ssh_key" ]] || die "missing ssh key: ${ssh_key:-<unset>}"
 
   # shellcheck disable=SC1090
   source "$inventory"
 
   if ! declare -p HOSTS >/dev/null 2>&1; then
     die "inventory must define HOSTS"
   fi
 
   ssh_user=${SSH_USER:-}
   seed_host=${SEED_HOST:-}
   rook_namespace=${ROOK_NAMESPACE:-rook-ceph}
   rook_operator_namespace=${ROOK_OPERATOR_NAMESPACE:-rook-ceph}
   if [[ -n "$seed_override" ]]; then
     seed=$seed_override
   elif [[ -n "$seed_host" ]]; then
     seed="$(ssh_target_for_host "$seed_host" "$ssh_user")"
   fi
 
   if [[ -z "$(timeout_cmd)" ]]; then
     log "WARNING: no 'timeout'/'gtimeout' found on this workstation; outer timeouts are disabled — relying on SSH ConnectTimeout/ServerAlive only (install coreutils for full bounding)"
   fi
 
   ensure_dir "$out_dir"
   timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
   workdir="$out_dir/tmp.$timestamp.$$"
   manifest="$workdir/manifest.jsonl"
   ensure_dir "$workdir"
   CLEANUP_WORKDIR="$workdir"
   CLEANUP_KEEP=$keep_workdir
   trap cleanup_workdir EXIT INT TERM
   write_initial_metadata "$workdir" "$mode" "$seed" "$since" "$timeout"
 
   # Parse HOSTS once into globals (used by the cluster capability probe AND the
   # node loop). A malformed entry is recorded but must not abort collection.
   local entry
   HOST_ALIASES=()
   HOST_TARGETS=()
   # bash 3.2 + set -u: expanding an empty array errors, so guard it.
   if [[ ${#HOSTS[@]} -eq 0 ]]; then
     die "inventory HOSTS is empty"
   fi
   for entry in "${HOSTS[@]}"; do
     if [[ "$entry" != *=* || -z "${entry%%=*}" || -z "${entry#*=}" ]]; then
       append_error "$workdir" "skipped malformed HOSTS entry: $entry"
       rc=2
       continue
     fi
     HOST_ALIASES+=("${entry%%=*}")
     HOST_TARGETS+=("$(ssh_target_for_host "${entry#*=}" "$ssh_user")")
   done
 
   progress "starting: mode=$mode, ${#HOST_TARGETS[@]} hosts"
 
   set +e
-  collect_clusters "$mode" "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout" "$rook_namespace" "$kube_context" "$kube_mode" "$rook_operator_namespace"
+  collect_clusters \
+    --mode "$mode" --workdir "$workdir" --manifest "$manifest" \
+    --seed "$seed" --ssh-key "$ssh_key" --since "$since" --timeout "$timeout" \
+    --namespace "$rook_namespace" --operator-namespace "$rook_operator_namespace" \
+    --kube-context "$kube_context" --kube-mode "$kube_mode"
   cluster_rc=$?
   set -e
   if [[ $cluster_rc -ne 0 ]]; then
     append_error "$workdir" "cluster collection exited $cluster_rc"
     rc=2
   fi
 
   local i alias target node_rc ntotal
   ntotal=${#HOST_ALIASES[@]}
   if [[ $ntotal -gt 0 ]]; then
     for i in "${!HOST_ALIASES[@]}"; do
       alias="${HOST_ALIASES[$i]}"
       target="${HOST_TARGETS[$i]}"
       progress "[$((i + 1))/$ntotal] node ${alias}…"
       if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs" "$node_timeout"; then
         node_ok=$((node_ok + 1))
         progress "[$((i + 1))/$ntotal] node $alias: ok"
       else
         node_rc=$?
         node_failed=$((node_failed + 1))
         append_error "$workdir" "node $alias ($target) collector exited $node_rc"
         progress "[$((i + 1))/$ntotal] node $alias: SKIPPED (exit $node_rc)"
         rc=2
       fi
     done
   fi
 
   # Test-only hook: simulate a mid-run abort to exercise trap cleanup. Inert in production.
   if [[ -n "${COLLECT_TEST_ABORT_AFTER_NODES:-}" ]]; then
     die "test abort after nodes"
   fi
 
   progress "redacting…"
   redact_bundle_text "$workdir"
   write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "$rc"
 
   progress "verifying…"
   # Verify BEFORE packaging, but never let verification destroy collected
   # evidence: capture its result instead of aborting under set -e. On failure,
   # keep the workdir for inspection and do not produce a shareable bundle.
   local verify_rc=0
   set +e
   "$COLLECT_ROOT/lib/verify-bundle.sh" "$workdir" >/dev/null 2>>"$workdir/errors.log"
   verify_rc=$?
   set -e
   if [[ $verify_rc -ne 0 ]]; then
     CLEANUP_KEEP=1
     append_error "$workdir" "bundle verification failed (rc=$verify_rc); workdir kept, NOT packaged for sharing"
     write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "1"
     printf 'VERIFY FAILED: workdir kept at %s (not packaged) — review errors.log\n' "$workdir" >&2
     return 1
   fi
 
   progress "packaging…"
   bundle="$out_dir/ceph-incident-$timestamp.tar.gz"
   COPYFILE_DISABLE=1 tar -czf "$bundle" -C "$workdir" .
   set +e
   "$COLLECT_ROOT/lib/verify-bundle.sh" "$bundle" >/dev/null 2>>"$workdir/errors.log"
   verify_rc=$?
   set -e
   if [[ $verify_rc -ne 0 ]]; then
     CLEANUP_KEEP=1
     rm -f -- "$bundle"
     printf 'VERIFY FAILED on packaged bundle; removed it, workdir kept at %s\n' "$workdir" >&2
     return 1
   fi
 
   printf 'bundle: %s\n' "$bundle"
   return "$rc"
 }
 
 main "$@"

codex
The core extraction looks straightforward so far: `bundle.sh` is sourced after `common.sh`, which matches its dependency comments. I’m checking the SSH argv construction and every new helper call site next, because that’s where behavior can drift subtly.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/common.sh | sed -n '1,260p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	# Shared helpers for the Ceph incident bundle harness.
     5	
     6	log() {
     7	  # stderr: stdout is reserved for the final `bundle:` line (machine-readable).
     8	  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
     9	}
    10	
    11	die() {
    12	  log "FATAL: $*"
    13	  exit 1
    14	}
    15	
    16	require_file() {
    17	  [[ -f "$1" ]] || die "missing file: $1"
    18	}
    19	
    20	ensure_dir() {
    21	  mkdir -p "$1"
    22	}
    23	
    24	# Shared SSH option vector (incl. -i KEY). Printed one argv item per line so
    25	# callers fill an array with `while IFS= read -r w; do a+=("$w"); done` — the
    26	# bash-3.2-safe idiom used throughout (no mapfile). Single source of truth so a
    27	# flag like BatchMode can't drift between call sites.
    28	ssh_base_opts() {
    29	  local ssh_key=$1 timeout=$2
    30	  printf '%s\n' \
    31	    -i "$ssh_key" \
    32	    -o BatchMode=yes \
    33	    -o IdentitiesOnly=yes \
    34	    -o IdentityAgent=none \
    35	    -o "ConnectTimeout=$timeout" \
    36	    -o "ServerAliveInterval=$timeout" \
    37	    -o ServerAliveCountMax=1
    38	}
    39	
    40	# Write a `SKIPPED: <reason>` artifact. `_once` does not overwrite an existing
    41	# file (so a collector's specific reason is never clobbered by a generic one).
    42	write_skip_artifact() {
    43	  local artifact=$1 reason=$2
    44	  ensure_dir "$(dirname -- "$artifact")"
    45	  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
    46	}
    47	
    48	write_skip_artifact_once() {
    49	  local artifact=$1 reason=$2
    50	  [[ -f "$artifact" ]] && return 0
    51	  write_skip_artifact "$artifact" "$reason"
    52	}
    53	
    54	# Live progress to stderr (stdout stays reserved for the final `bundle:` line).
    55	# Suppressed when CEPH_INCIDENT_QUIET is set. Call only from workstation-side
    56	# code — NOT from the remote node collector (its stderr is multiplexed over ssh).
    57	progress() {
    58	  [[ -n "${CEPH_INCIDENT_QUIET:-}" ]] && return 0
    59	  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
    60	}
    61	
    62	# Resolve a timeout binary: GNU coreutils `timeout`, or `gtimeout` on macOS.
    63	# Prints the binary name, or nothing if neither is installed.
    64	timeout_cmd() {
    65	  if command -v timeout >/dev/null 2>&1; then
    66	    printf 'timeout'
    67	  elif command -v gtimeout >/dev/null 2>&1; then
    68	    printf 'gtimeout'
    69	  fi
    70	}
    71	
    72	json_escape() {
    73	  local value=$1
    74	  value=${value//\\/\\\\}
    75	  value=${value//\"/\\\"}
    76	  value=${value//$'\n'/\\n}
    77	  value=${value//$'\r'/\\r}
    78	  value=${value//$'\t'/\\t}
    79	  printf '%s' "$value"
    80	}
    81	
    82	manifest_add() {
    83	  local manifest=$1 host=$2 collector=$3 artifact=$4 command=$5 exit_code=$6 started=$7 ended=$8
    84	  [[ "$exit_code" =~ ^[0-9]+$ ]] || die "manifest_add requires numeric exit_code: $exit_code"
    85	  ensure_dir "$(dirname -- "$manifest")"
    86	  printf '{"host":"%s","collector":"%s","artifact":"%s","command":"%s","exit_code":%s,"started":"%s","ended":"%s"}\n' \
    87	    "$(json_escape "$host")" \
    88	    "$(json_escape "$collector")" \
    89	    "$(json_escape "$artifact")" \
    90	    "$(json_escape "$command")" \
    91	    "$exit_code" \
    92	    "$(json_escape "$started")" \
    93	    "$(json_escape "$ended")" >>"$manifest"
    94	}
    95	
    96	redact_file() {
    97	  local source_file=$1 redaction_log=$2
    98	  require_file "$source_file"
    99	  ensure_dir "$(dirname -- "$redaction_log")"
   100	
   101	  local source_dir tmp_file count line nocase_was_set in_pem redact mode
   102	  source_dir="$(dirname -- "$source_file")"
   103	  tmp_file="$(mktemp "$source_dir/.${source_file##*/}.XXXXXX")"
   104	  count=0
   105	  in_pem=0
   106	  nocase_was_set=0
   107	  shopt -q nocasematch && nocase_was_set=1
   108	  shopt -s nocasematch
   109	
   110	  # Best-effort redaction (NOT a complete DLP): keyword lines, ceph key
   111	  # material (`key = AQB..==`, base64 blobs), and whole multi-line PEM private
   112	  # key blocks. Extensions/encodings outside this are intentionally not covered
   113	  # — see README "安全界線"; operators must self-review before sharing.
   114	  while IFS= read -r line || [[ -n "$line" ]]; do
   115	    redact=0
   116	    if [[ "$line" =~ -----BEGIN[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
   117	      in_pem=1
   118	    fi
   119	    if [[ $in_pem -eq 1 ]]; then
   120	      redact=1
   121	      if [[ "$line" =~ -----END[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
   122	        in_pem=0
   123	      fi
   124	    elif [[ "$line" =~ (password|secret|token|keyring|private([[:space:]_-]+)?key) ]]; then
   125	      redact=1
   126	    elif [[ "$line" =~ (^|[^[:alnum:]])key[[:space:]]*[:=] ]]; then
   127	      redact=1
   128	    elif [[ "$line" =~ [A-Za-z0-9+/]{38,}={1,2} ]]; then
   129	      redact=1
   130	    fi
   131	    if [[ $redact -eq 1 ]]; then
   132	      printf '[REDACTED]\n' >>"$tmp_file"
   133	      count=$((count + 1))
   134	    else
   135	      printf '%s\n' "$line" >>"$tmp_file"
   136	    fi
   137	  done <"$source_file"
   138	
   139	  if [[ $nocase_was_set -eq 1 ]]; then shopt -s nocasematch; else shopt -u nocasematch; fi
   140	  mode="$(stat -c '%a' "$source_file" 2>/dev/null || stat -f '%Lp' "$source_file" 2>/dev/null || printf '600')"
   141	  chmod "$mode" "$tmp_file" 2>/dev/null || true
   142	  mv -f -- "$tmp_file" "$source_file"
   143	  printf '%s: %s line(s) redacted\n' "$source_file" "$count" >>"$redaction_log"
   144	}
   145	
   146	redact_gz_file() {
   147	  # Decompress a gzipped artifact, redact it, recompress in place so rotated
   148	  # logs (*.gz) get the same redaction as plain text.
   149	  local source_file=$1 redaction_log=$2
   150	  require_file "$source_file"
   151	  ensure_dir "$(dirname -- "$redaction_log")"
   152	
   153	  local dir tmp_plain
   154	  dir="$(dirname -- "$source_file")"
   155	  tmp_plain="$(mktemp "$dir/.${source_file##*/}.plain.XXXXXX")"
   156	  if ! gzip -dc -- "$source_file" >"$tmp_plain" 2>/dev/null; then
   157	    rm -f -- "$tmp_plain"
   158	    printf '%s: gz decompress failed, left as-is (NOT redacted)\n' "$source_file" >>"$redaction_log"
   159	    return 0
   160	  fi
   161	
   162	  redact_file "$tmp_plain" "$redaction_log"
   163	  if gzip -c -- "$tmp_plain" >"$source_file"; then
   164	    rm -f -- "$tmp_plain"
   165	  else
   166	    rm -f -- "$tmp_plain"
   167	    return 1
   168	  fi
   169	}
   170	
   171	run_capture() {
   172	  local manifest=$1 host=$2 collector=$3 artifact=$4
   173	  shift 4
   174	  [[ ${1-} == -- ]] || die "run_capture requires -- before the command"
   175	  shift
   176	
   177	  local -a cmd
   178	  local started ended rc command_string artifact_dir artifact_tmp
   179	
   180	  cmd=("$@")
   181	  [[ ${#cmd[@]} -gt 0 ]] || die "run_capture requires a command"
   182	
   183	  started="$(date -u +%FT%TZ)"
   184	  artifact_dir="$(dirname -- "$artifact")"
   185	  ensure_dir "$artifact_dir"
   186	  artifact_tmp="$(mktemp "$artifact_dir/.${artifact##*/}.XXXXXX")"
   187	
   188	  printf '# host: %s\n# collector: %s\n# started: %s\n' "$host" "$collector" "$started" >"$artifact_tmp"
   189	  printf -v command_string '%q ' "${cmd[@]}"
   190	  command_string=${command_string% }
   191	
   192	  local tbin
   193	  tbin="$(timeout_cmd)"
   194	  if [[ -n "$tbin" ]]; then
   195	    printf '# timeout: %ss\n' "${COMMAND_TIMEOUT:-20}" >>"$artifact_tmp"
   196	    if "$tbin" "${COMMAND_TIMEOUT:-20}" "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
   197	      rc=0
   198	    else
   199	      rc=$?
   200	    fi
   201	  else
   202	    printf '# timeout: unavailable\n' >>"$artifact_tmp"
   203	    if "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
   204	      rc=0
   205	    else
   206	      rc=$?
   207	    fi
   208	  fi
   209	
   210	  # Make timeout-kills (124) distinguishable from ordinary command failure, and
   211	  # mark the artifact so a truncated capture is visible to whoever reads it.
   212	  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
   213	    printf '# TRUNCATED: command timed out after %ss (exit %s)\n' "${COMMAND_TIMEOUT:-20}" "$rc" >>"$artifact_tmp"
   214	  fi
   215	
   216	  ended="$(date -u +%FT%TZ)"
   217	  mv -f -- "$artifact_tmp" "$artifact"
   218	  manifest_add "$manifest" "$host" "$collector" "$artifact" "$command_string" "$rc" "$started" "$ended"
   219	
   220	  if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
   221	    ensure_dir "$(dirname -- "$ERROR_LOG")"
   222	    printf '%s host=%s collector=%s artifact=%s exit=%s command=%s\n' \
   223	      "$ended" "$host" "$collector" "$artifact" "$rc" "$command_string" >>"$ERROR_LOG"
   224	  fi
   225	
   226	  return "$rc"
   227	}
   228	
   229	copy_if_exists() {
   230	  local source=$1 dest=$2
   231	  [[ -e "$source" ]] || return 0
   232	  ensure_dir "$(dirname -- "$dest")"
   233	  cp -a -- "$source" "$dest"
   234	}

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/bundle.sh | sed -n '1,180p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	# Bundle/orchestration helpers used by run/collect.sh. These are pure-ish units
     5	# (SSH target/quoting, bundle metadata, summary, error log, redaction driver)
     6	# kept out of the entrypoint so collect.sh stays a thin orchestrator. Relies on
     7	# common.sh (sourced first by the entrypoint) for redact_file/redact_gz_file.
     8	
     9	ssh_target_for_host() {
    10	  local host=$1 ssh_user=$2
    11	  if [[ "$host" == *@* || -z "$ssh_user" ]]; then
    12	    printf '%s' "$host"
    13	  else
    14	    printf '%s@%s' "$ssh_user" "$host"
    15	  fi
    16	}
    17	
    18	# Quote a value for safe interpolation into a remote shell string. Returns 1 if
    19	# the value contains a single quote (callers treat that as a hard input error).
    20	shell_quote() {
    21	  local value=$1
    22	  [[ "$value" != *"'"* ]] || return 1
    23	  printf "'%s'" "$value"
    24	}
    25	
    26	write_initial_metadata() {
    27	  local workdir=$1 mode=$2 seed=$3 since=$4 timeout=$5
    28	  local git_commit
    29	  git_commit="$(git -C "$COLLECT_ROOT/../.." rev-parse --short HEAD 2>/dev/null || printf unknown)"
    30	
    31	  cat >"$workdir/README-FIRST.txt" <<'EOF'
    32	Ceph incident bundle
    33	
    34	Start with:
    35	- summary.txt
    36	- errors.log
    37	- cluster/
    38	- nodes/
    39	
    40	This bundle is read-only evidence captured at incident time. Review it before sharing outside your team.
    41	EOF
    42	
    43	  cat >"$workdir/environment.txt" <<EOF
    44	created_utc=$(date -u +%FT%TZ)
    45	mode=$mode
    46	seed=$seed
    47	since=$since
    48	timeout=$timeout
    49	git_commit=$git_commit
    50	EOF
    51	
    52	  : >"$workdir/manifest.jsonl"
    53	  : >"$workdir/errors.log"
    54	}
    55	
    56	write_summary() {
    57	  local workdir=$1 mode=$2 seed=$3 node_ok=$4 node_failed=$5 cluster_status=$6 final_status=$7
    58	
    59	  {
    60	    printf 'Ceph incident bundle summary\n'
    61	    printf 'created_utc: %s\n' "$(date -u +%FT%TZ)"
    62	    printf 'mode: %s\n' "$mode"
    63	    printf 'seed: %s\n' "$seed"
    64	    printf 'cluster_status: %s\n' "$cluster_status"
    65	    printf 'node_ok: %s\n' "$node_ok"
    66	    printf 'node_failed: %s\n' "$node_failed"
    67	    printf 'final_status: %s\n' "$final_status"
    68	  } >"$workdir/summary.txt"
    69	}
    70	
    71	append_error() {
    72	  local workdir=$1 message=$2
    73	  printf '%s %s\n' "$(date -u +%FT%TZ)" "$message" >>"$workdir/errors.log"
    74	}
    75	
    76	# Redact every text-ish artifact in the bundle in place (gz handled specially).
    77	redact_bundle_text() {
    78	  local workdir=$1
    79	  local redaction_log="$workdir/redactions.log"
    80	  local path
    81	
    82	  while IFS= read -r path; do
    83	    case "$path" in
    84	      *.gz) redact_gz_file "$path" "$redaction_log" ;;
    85	      *) redact_file "$path" "$redaction_log" ;;
    86	    esac
    87	  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' -o -name '*.gz' \) -print 2>/dev/null || true)
    88	}

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/run/collect.sh | sed -n '1,620p'" in /Users/ikaros/Documents/code/learning-k8s
exec
/bin/zsh -lc 'git diff --unified=100 b44aa8d..HEAD -- experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh experiments/ceph-incident-bundle/lib/collect-node.sh experiments/ceph-incident-bundle/README.md' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	# Ceph incident bundle collection entrypoint.
     5	
     6	COLLECT_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
     7	COLLECT_ROOT="$(cd "$COLLECT_RUN_DIR/.." && pwd)"
     8	# shellcheck disable=SC1091
     9	source "$COLLECT_ROOT/lib/common.sh"
    10	# shellcheck disable=SC1091
    11	source "$COLLECT_ROOT/lib/collect-cluster-cephadm.sh"
    12	# shellcheck disable=SC1091
    13	source "$COLLECT_ROOT/lib/collect-cluster-rook.sh"
    14	# shellcheck disable=SC1091
    15	source "$COLLECT_ROOT/lib/bundle.sh"
    16	
    17	usage() {
    18	  cat <<'EOF'
    19	Usage: collect.sh --inventory PATH --ssh-key PATH [options]
    20	
    21	One command example:
    22	  bash experiments/ceph-incident-bundle/run/collect.sh \
    23	    --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
    24	    --ssh-key .ssh/id_ed25519 \
    25	    --mode cephadm \
    26	    --since 24h
    27	
    28	Required:
    29	  --inventory PATH       shell inventory with HOSTS=( "alias=host" ... )
    30	  --ssh-key PATH         SSH private key used to reach every node
    31	
    32	Options:
    33	  --seed USER@HOST       override inventory SEED_HOST
    34	  --out DIR              output dir (default: experiments/ceph-incident-bundle/results)
    35	  --mode auto|cephadm|rook   auto = per-node detect, collect ceph and/or rook layer
    36	  --kube-context CTX     kubectl context for the rook layer (default: none)
    37	  --kube-mode MODE       where the rook layer runs kubectl: remote (on an
    38	                         inventory node, default) or local (this jump host)
    39	  --since DURATION       log/journal window (default: 24h)
    40	  --timeout SECONDS      per-command / SSH-connect timeout (default: 20)
    41	  --node-timeout SECONDS overall timeout for one node's full collection (default: 600)
    42	  --skip-logs            collect state but skip larger Ceph log copies
    43	  --quiet                suppress progress output on stderr (stdout still prints bundle:)
    44	  --keep-workdir         keep temporary extracted workdir for debugging
    45	  --help                 print this help
    46	
    47	Output:
    48	  DIR/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
    49	
    50	Exit codes:
    51	  0 complete, 2 partial collection failure with bundle produced, 1 usage/config/verify failure
    52	EOF
    53	}
    54	
    55	detect_node_caps() {
    56	  # echo a space-joined subset of "cephadm kubectl" present on the target node.
    57	  # A probe that fails to ssh is NOT the same as "node has no caps" — record the
    58	  # ssh failure to ERROR_LOG so a silently-dropped cluster source is visible.
    59	  local target=$1 ssh_key=$2 timeout=$3
    60	  local tbin out rc _w
    61	  local -a ssh_cmd sopts
    62	  while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
    63	  # SC2016: the probe script is single-quoted on purpose — it expands on the remote.
    64	  # shellcheck disable=SC2016
    65	  ssh_cmd=(ssh "${sopts[@]}" "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v ceph >/dev/null 2>&1 && caps="$caps ceph"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
    66	  tbin="$(timeout_cmd)"
    67	  if [[ -n "$tbin" ]]; then
    68	    ssh_cmd=("$tbin" "$timeout" "${ssh_cmd[@]}")
    69	  fi
    70	  out="$("${ssh_cmd[@]}" 2>/dev/null)"
    71	  rc=$?
    72	  if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
    73	    ensure_dir "$(dirname -- "$ERROR_LOG")"
    74	    printf '%s capability probe failed for %s (ssh exit %s) — node not considered as a cluster source\n' \
    75	      "$(date -u +%FT%TZ)" "$target" "$rc" >>"$ERROR_LOG"
    76	  fi
    77	  printf '%s' "$out"
    78	}
    79	
    80	# Does a given runner actually connect to the cluster on this node? "usable" is
    81	# defined as `ceph -s` succeeding, not merely the binary existing.
    82	ceph_runner_probe() {
    83	  local target=$1 ssh_key=$2 timeout=$3 method=$4
    84	  local tbin w
    85	  local -a pfx ssh_cmd sopts
    86	  while IFS= read -r w; do pfx+=("$w"); done < <(ceph_runner_argv "$method")
    87	  while IFS= read -r w; do sopts+=("$w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
    88	  ssh_cmd=(ssh "${sopts[@]}" "$target" "${pfx[@]}" --connect-timeout 5 -s)
    89	  tbin="$(timeout_cmd)"
    90	  [[ -n "$tbin" ]] && ssh_cmd=("$tbin" "$timeout" "${ssh_cmd[@]}")
    91	  "${ssh_cmd[@]}" >/dev/null 2>&1
    92	}
    93	
    94	# Pick the fastest runner that connects on $target: direct ceph, sudo ceph, then
    95	# cephadm shell. Echoes the runner token, or nothing if none connects.
    96	ceph_runner_for() {
    97	  local target=$1 ssh_key=$2 timeout=$3 m
    98	  for m in direct sudo cephadm; do
    99	    if ceph_runner_probe "$target" "$ssh_key" "$timeout" "$m"; then
   100	      printf '%s' "$m"
   101	      return 0
   102	    fi
   103	  done
   104	  # Contract: success with EMPTY stdout = no runner connected. Callers must test
   105	  # for empty output, not the exit status (which is always 0).
   106	  return 0
   107	}
   108	
   109	# Probe each node once; pick cluster-ceph source (first cephadm node, or --seed)
   110	# and cluster-rook source (first kubectl node); collect each requested layer once.
   111	# Uses globals HOST_TARGETS (set by main).
   112	collect_clusters() {
   113	  local mode='' workdir='' manifest='' seed='' ssh_key='' since=24h timeout=20
   114	  local rook_namespace=rook-ceph kube_context='' kube_mode=remote rook_operator_namespace=''
   115	  while [[ $# -gt 0 ]]; do
   116	    case "$1" in
   117	      --mode) mode=${2-}; shift 2 ;;
   118	      --workdir) workdir=${2-}; shift 2 ;;
   119	      --manifest) manifest=${2-}; shift 2 ;;
   120	      --seed) seed=${2-}; shift 2 ;;
   121	      --ssh-key) ssh_key=${2-}; shift 2 ;;
   122	      --since) since=${2-}; shift 2 ;;
   123	      --timeout) timeout=${2-}; shift 2 ;;
   124	      --namespace) rook_namespace=${2-}; shift 2 ;;
   125	      --operator-namespace) rook_operator_namespace=${2-}; shift 2 ;;
   126	      --kube-context) kube_context=${2-}; shift 2 ;;
   127	      --kube-mode) kube_mode=${2-}; shift 2 ;;
   128	      *) return 1 ;;
   129	    esac
   130	  done
   131	  local ceph_source='' ceph_runner='' rook_source='' i caps rc=0
   132	  local want_ceph=0 want_rook=0 ceph_done=0 rook_done=0
   133	  # so detect_node_caps can record probe ssh failures
   134	  local ERROR_LOG="$workdir/errors.log"
   135	  case "$mode" in
   136	    cephadm) want_ceph=1 ;;
   137	    rook) want_rook=1 ;;
   138	    auto) want_ceph=1; want_rook=1 ;;
   139	    *) return 1 ;;
   140	  esac
   141	
   142	  # explicit --seed pins the cluster-ceph source; the runner is still chosen by
   143	  # connectivity (so direct ceph is preferred on the seed too).
   144	  if [[ $want_ceph -eq 1 && -n "$seed" ]]; then
   145	    ceph_source="$seed"
   146	    ceph_runner="$(ceph_runner_for "$seed" "$ssh_key" "$timeout")"
   147	  fi
   148	
   149	  # Only probe nodes for kubectl when the rook layer runs remotely.
   150	  local probe_rook=0
   151	  [[ $want_rook -eq 1 && "$kube_mode" == remote ]] && probe_rook=1
   152	
   153	  # probe nodes only if a source we need is still unknown
   154	  if { [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; } || [[ $probe_rook -eq 1 ]]; then
   155	    if [[ ${#HOST_TARGETS[@]} -gt 0 ]]; then
   156	      progress "probing ${#HOST_TARGETS[@]} nodes for capabilities…"
   157	      for i in "${!HOST_TARGETS[@]}"; do
   158	        caps="$(detect_node_caps "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
   159	        progress "[$((i + 1))/${#HOST_TARGETS[@]}] probe ${HOST_TARGETS[$i]}: ${caps:-none}"
   160	        # ceph source = first candidate (has ceph or cephadm binary) whose runner
   161	        # actually connects to the cluster.
   162	        if [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; then
   163	          case " $caps " in
   164	            *" ceph "*|*" cephadm "*)
   165	              ceph_runner="$(ceph_runner_for "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
   166	              [[ -n "$ceph_runner" ]] && ceph_source="${HOST_TARGETS[$i]}"
   167	              ;;
   168	          esac
   169	        fi
   170	        if [[ $probe_rook -eq 1 && -z "$rook_source" ]]; then
   171	          case " $caps " in *" kubectl "*) rook_source="${HOST_TARGETS[$i]}" ;; esac
   172	        fi
   173	        if { [[ $want_ceph -eq 0 || -n "$ceph_source" ]]; } && { [[ $probe_rook -eq 0 || -n "$rook_source" ]]; }; then
   174	          break
   175	        fi
   176	      done
   177	    fi
   178	  fi
   179	
   180	  # cluster-ceph layer
   181	  if [[ $want_ceph -eq 1 && -n "$ceph_source" ]]; then
   182	    progress "collecting ceph cluster from $ceph_source via ${ceph_runner:-cephadm}…"
   183	    collect_cluster_cephadm "$workdir" "$manifest" "$ceph_source" "$ssh_key" "$since" "$timeout" "${ceph_runner:-cephadm}" || rc=2
   184	    ceph_done=1
   185	  fi
   186	
   187	  # cluster-rook layer: local (this jump host) or remote (on a kubectl node)
   188	  if [[ $want_rook -eq 1 && ( "$kube_mode" == local || -n "$rook_source" ) ]]; then
   189	    local -a rook_args
   190	    rook_args=(--out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout")
   191	    [[ -n "$rook_operator_namespace" ]] && rook_args+=(--operator-namespace "$rook_operator_namespace")
   192	    if [[ "$kube_mode" == local ]]; then
   193	      rook_source=local
   194	      progress "collecting rook from local kubectl (ns=$rook_namespace)…"
   195	    else
   196	      rook_args+=(--ssh-target "$rook_source" --ssh-key "$ssh_key")
   197	      progress "collecting rook from $rook_source (ns=$rook_namespace)…"
   198	    fi
   199	    [[ -n "$kube_context" ]] && rook_args+=(--kube-context "$kube_context")
   200	    [[ "$mode" == auto ]] && rook_args+=(--allow-skip)
   201	    collect_cluster_rook "${rook_args[@]}" || rc=2
   202	    # "done" means real rook evidence was collected — NOT just an --allow-skip
   203	    # (e.g. namespace missing) which returns 0 but only writes SKIPPED.txt.
   204	    [[ -f "$workdir/cluster/rook/pods-wide.txt" ]] && rook_done=1
   205	  fi
   206	
   207	  # missing-source handling
   208	  # When a layer wasn't collected, leave a SKIPPED.txt — but never clobber a more
   209	  # specific reason the collector already wrote (e.g. "namespace not found").
   210	  if [[ "$mode" == cephadm && $ceph_done -eq 0 ]]; then
   211	    write_skip_artifact_once "$workdir/cluster/ceph/SKIPPED.txt" "no cephadm-capable node found (or --seed unreachable)"
   212	    rc=2
   213	  elif [[ "$mode" == rook && $rook_done -eq 0 ]]; then
   214	    write_skip_artifact_once "$workdir/cluster/rook/SKIPPED.txt" "no kubectl-capable node found"
   215	    rc=2
   216	  elif [[ "$mode" == auto ]]; then
   217	    # auto = collect whatever exists; only a hard failure if NEITHER layer found
   218	    [[ $ceph_done -eq 0 ]] && write_skip_artifact_once "$workdir/cluster/ceph/SKIPPED.txt" "no cephadm-capable node in inventory (auto)"
   219	    [[ $rook_done -eq 0 ]] && write_skip_artifact_once "$workdir/cluster/rook/SKIPPED.txt" "no kubectl-capable node in inventory (auto)"
   220	    [[ $ceph_done -eq 0 && $rook_done -eq 0 ]] && rc=2
   221	  fi
   222	
   223	  # Record which node each cluster layer was collected from (observability:
   224	  # "which host did we trust for ceph status?").
   225	  {
   226	    printf 'ceph_source=%s\n' "${ceph_source:-<none>}"
   227	    printf 'ceph_runner=%s\n' "${ceph_runner:-<none>}"
   228	    printf 'rook_source=%s\n' "${rook_source:-<none>}"
   229	  } >>"$workdir/environment.txt"
   230	
   231	  return "$rc"
   232	}
   233	
   234	collect_remote_node() {
   235	  local workdir=$1 alias=$2 target=$3 ssh_key=$4 since=$5 timeout=$6 skip_logs=$7 node_timeout=$8
   236	  local node_dir="$workdir/nodes/$alias"
   237	  local node_tar="$workdir/.node-$alias.tar.gz"
   238	  local remote_cmd rc=0 tbin _w
   239	  local q_alias q_since q_timeout
   240	  local -a ssh_cmd sopts
   241	
   242	  q_alias="$(shell_quote "$alias")" || return 1
   243	  q_since="$(shell_quote "$since")" || return 1
   244	  q_timeout="$(shell_quote "$timeout")" || return 1
   245	
   246	  # Remote side uses a gzip pipe (not `tar -z`) so minimal/BusyBox tar still works,
   247	  # and traps its own temp dir so an interrupted/timed-out run leaves nothing behind.
   248	  remote_cmd="set -u; tmp=\"\${TMPDIR:-/tmp}/ceph-incident-node.\$\$\"; rm -rf \"\$tmp\"; mkdir -p \"\$tmp\" || { printf 'SKIPPED: remote tmp not writable\n' >&2; exit 75; }; trap 'rm -rf \"\$tmp\"' EXIT INT TERM; gzip -dc | tar -xf - -C \"\$tmp\"; out=\"\$tmp/out\"; set +e; bash \"\$tmp/lib/collect-node.sh\" --out \"\$out\" --host-alias $q_alias --since $q_since --timeout $q_timeout"
   249	  if [[ "$skip_logs" == "1" ]]; then
   250	    remote_cmd+=" --skip-logs"
   251	  fi
   252	  remote_cmd+="; rc=\$?; set -e; if [ -d \"\$out\" ]; then tar -cf - -C \"\$out\" . | gzip -c; else mkdir -p \"\$out\"; printf 'SKIPPED: remote collect-node did not create output\n' >\"\$out/SKIPPED.txt\"; tar -cf - -C \"\$out\" . | gzip -c; fi; exit \"\$rc\""
   253	
   254	  while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
   255	  ssh_cmd=(ssh "${sopts[@]}" "$target" "$remote_cmd")
   256	  tbin="$(timeout_cmd)"
   257	  if [[ -n "$tbin" ]]; then
   258	    # Outer wrapper bounds the WHOLE node collection — must be the generous
   259	    # node timeout, never the small per-command timeout (which would kill a
   260	    # slow/large node mid-collection).
   261	    ssh_cmd=("$tbin" "$node_timeout" "${ssh_cmd[@]}")
   262	  fi
   263	
   264	  # macOS bsdtar embeds com.apple.* xattr headers that make the remote GNU tar
   265	  # print "Ignoring unknown extended header keyword" noise; strip them at source.
   266	  local noxattrs=''
   267	  if tar --version 2>&1 | grep -qi 'bsdtar'; then
   268	    noxattrs='--no-xattrs'
   269	  fi
   270	
   271	  set +e
   272	  # shellcheck disable=SC2086
   273	  COPYFILE_DISABLE=1 tar $noxattrs -cf - -C "$COLLECT_ROOT" lib/common.sh lib/collect-node.sh | gzip -c |
   274	    "${ssh_cmd[@]}" >"$node_tar"
   275	  rc=$?
   276	  set -e
   277	
   278	  ensure_dir "$node_dir"
   279	  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
   280	    printf 'SKIPPED: node collection timed out after %ss (exit %s) from %s\n' "$node_timeout" "$rc" "$target" >"$node_dir/SKIPPED.txt"
   281	    rm -f "$node_tar"
   282	    return 2
   283	  fi
   284	
   285	  if [[ -s "$node_tar" ]] && tar -xzf "$node_tar" -C "$node_dir" >/dev/null 2>/dev/null; then
   286	    # A node that streamed a valid archive but is missing its own manifest.jsonl
   287	    # was truncated (partial/interrupted transfer) — do not count it as ok.
   288	    if [[ ! -f "$node_dir/manifest.jsonl" ]]; then
   289	      printf 'SKIPPED: node archive from %s is incomplete (no manifest.jsonl); treated as failure\n' "$target" >"$node_dir/SKIPPED.txt"
   290	      rc=2
   291	    fi
   292	  else
   293	    rm -rf "$node_dir"
   294	    ensure_dir "$node_dir"
   295	    printf 'SKIPPED: no usable node archive returned from %s (ssh exit %s)\n' "$target" "$rc" >"$node_dir/SKIPPED.txt"
   296	    [[ $rc -ne 0 ]] || rc=2
   297	  fi
   298	  rm -f "$node_tar"
   299	
   300	  return "$rc"
   301	}
   302	
   303	# Single cleanup point. Uses globals (not main's locals) so it works as an
   304	# EXIT trap, which fires after main has returned and its locals are gone.
   305	CLEANUP_WORKDIR=
   306	CLEANUP_KEEP=0
   307	# Parsed inventory (alias/target pairs); filled by main, read by collect_clusters + node loop.
   308	HOST_ALIASES=()
   309	HOST_TARGETS=()
   310	cleanup_workdir() {
   311	  local rc=$?
   312	  if [[ -n "${CLEANUP_WORKDIR:-}" && -d "$CLEANUP_WORKDIR" ]]; then
   313	    if [[ "${CLEANUP_KEEP:-0}" -eq 1 ]]; then
   314	      printf 'kept workdir: %s\n' "$CLEANUP_WORKDIR" >&2
   315	    else
   316	      rm -rf -- "$CLEANUP_WORKDIR"
   317	    fi
   318	  fi
   319	  return "$rc"
   320	}
   321	
   322	main() {
   323	  local inventory='' ssh_key='' seed_override='' out_dir="$COLLECT_ROOT/results"
   324	  local mode=auto since=24h timeout=20 node_timeout=600 skip_logs=0 keep_workdir=0
   325	  local seed='' ssh_user='' seed_host='' rook_namespace=rook-ceph rook_operator_namespace=rook-ceph kube_context='' kube_mode=remote
   326	  local timestamp workdir manifest bundle rc=0 cluster_rc=0 node_ok=0 node_failed=0
   327	
   328	  if [[ $# -eq 0 ]]; then
   329	    usage >&2
   330	    return 1
   331	  fi
   332	
   333	  while [[ $# -gt 0 ]]; do
   334	    case "$1" in
   335	      --inventory)
   336	        inventory=${2-}
   337	        shift 2
   338	        ;;
   339	      --ssh-key)
   340	        ssh_key=${2-}
   341	        shift 2
   342	        ;;
   343	      --seed)
   344	        seed_override=${2-}
   345	        shift 2
   346	        ;;
   347	      --out)
   348	        out_dir=${2-}
   349	        shift 2
   350	        ;;
   351	      --mode)
   352	        mode=${2-}
   353	        shift 2
   354	        ;;
   355	      --kube-context)
   356	        kube_context=${2-}
   357	        shift 2
   358	        ;;
   359	      --kube-mode)
   360	        kube_mode=${2-}
   361	        shift 2
   362	        ;;
   363	      --since)
   364	        since=${2-}
   365	        shift 2
   366	        ;;
   367	      --timeout)
   368	        timeout=${2-}
   369	        shift 2
   370	        ;;
   371	      --node-timeout)
   372	        node_timeout=${2-}
   373	        shift 2
   374	        ;;
   375	      --skip-logs)
   376	        skip_logs=1
   377	        shift
   378	        ;;
   379	      --quiet)
   380	        export CEPH_INCIDENT_QUIET=1
   381	        shift
   382	        ;;
   383	      --keep-workdir)
   384	        keep_workdir=1
   385	        shift
   386	        ;;
   387	      --help|-h)
   388	        usage
   389	        return 0
   390	        ;;
   391	      *)
   392	        usage >&2
   393	        return 1
   394	        ;;
   395	    esac
   396	  done
   397	
   398	  [[ "$mode" == "auto" || "$mode" == "cephadm" || "$mode" == "rook" ]] || die "unsupported mode: $mode"
   399	  # kube-context runs through a remote shell (ssh kubectl --context ...). Block the
   400	  # actual shell metacharacters but allow the chars real contexts use (@ : / for
   401	  # e.g. kubernetes-admin@kubernetes and EKS ARNs).
   402	  if [[ -n "$kube_context" && "$kube_context" == *[!A-Za-z0-9._@:/-]* ]]; then
   403	    die "invalid --kube-context (allowed: A-Za-z0-9._@:/-): $kube_context"
   404	  fi
   405	  [[ "$kube_mode" == "local" || "$kube_mode" == "remote" ]] || die "invalid --kube-mode (local|remote): $kube_mode"
   406	  [[ -n "$inventory" && -f "$inventory" ]] || die "missing inventory: ${inventory:-<unset>}"
   407	  [[ -n "$ssh_key" && -f "$ssh_key" ]] || die "missing ssh key: ${ssh_key:-<unset>}"
   408	
   409	  # shellcheck disable=SC1090
   410	  source "$inventory"
   411	
   412	  if ! declare -p HOSTS >/dev/null 2>&1; then
   413	    die "inventory must define HOSTS"
   414	  fi
   415	
   416	  ssh_user=${SSH_USER:-}
   417	  seed_host=${SEED_HOST:-}
   418	  rook_namespace=${ROOK_NAMESPACE:-rook-ceph}
   419	  rook_operator_namespace=${ROOK_OPERATOR_NAMESPACE:-rook-ceph}
   420	  if [[ -n "$seed_override" ]]; then
   421	    seed=$seed_override
   422	  elif [[ -n "$seed_host" ]]; then
   423	    seed="$(ssh_target_for_host "$seed_host" "$ssh_user")"
   424	  fi
   425	
   426	  if [[ -z "$(timeout_cmd)" ]]; then
   427	    log "WARNING: no 'timeout'/'gtimeout' found on this workstation; outer timeouts are disabled — relying on SSH ConnectTimeout/ServerAlive only (install coreutils for full bounding)"
   428	  fi
   429	
   430	  ensure_dir "$out_dir"
   431	  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
   432	  workdir="$out_dir/tmp.$timestamp.$$"
   433	  manifest="$workdir/manifest.jsonl"
   434	  ensure_dir "$workdir"
   435	  CLEANUP_WORKDIR="$workdir"
   436	  CLEANUP_KEEP=$keep_workdir
   437	  trap cleanup_workdir EXIT INT TERM
   438	  write_initial_metadata "$workdir" "$mode" "$seed" "$since" "$timeout"
   439	
   440	  # Parse HOSTS once into globals (used by the cluster capability probe AND the
   441	  # node loop). A malformed entry is recorded but must not abort collection.
   442	  local entry
   443	  HOST_ALIASES=()
   444	  HOST_TARGETS=()
   445	  # bash 3.2 + set -u: expanding an empty array errors, so guard it.
   446	  if [[ ${#HOSTS[@]} -eq 0 ]]; then
   447	    die "inventory HOSTS is empty"
   448	  fi
   449	  for entry in "${HOSTS[@]}"; do
   450	    if [[ "$entry" != *=* || -z "${entry%%=*}" || -z "${entry#*=}" ]]; then
   451	      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
   452	      rc=2
   453	      continue
   454	    fi
   455	    HOST_ALIASES+=("${entry%%=*}")
   456	    HOST_TARGETS+=("$(ssh_target_for_host "${entry#*=}" "$ssh_user")")
   457	  done
   458	
   459	  progress "starting: mode=$mode, ${#HOST_TARGETS[@]} hosts"
   460	
   461	  set +e
   462	  collect_clusters \
   463	    --mode "$mode" --workdir "$workdir" --manifest "$manifest" \
   464	    --seed "$seed" --ssh-key "$ssh_key" --since "$since" --timeout "$timeout" \
   465	    --namespace "$rook_namespace" --operator-namespace "$rook_operator_namespace" \
   466	    --kube-context "$kube_context" --kube-mode "$kube_mode"
   467	  cluster_rc=$?
   468	  set -e
   469	  if [[ $cluster_rc -ne 0 ]]; then
   470	    append_error "$workdir" "cluster collection exited $cluster_rc"
   471	    rc=2
   472	  fi
   473	
   474	  local i alias target node_rc ntotal
   475	  ntotal=${#HOST_ALIASES[@]}
   476	  if [[ $ntotal -gt 0 ]]; then
   477	    for i in "${!HOST_ALIASES[@]}"; do
   478	      alias="${HOST_ALIASES[$i]}"
   479	      target="${HOST_TARGETS[$i]}"
   480	      progress "[$((i + 1))/$ntotal] node ${alias}…"
   481	      if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs" "$node_timeout"; then
   482	        node_ok=$((node_ok + 1))
   483	        progress "[$((i + 1))/$ntotal] node $alias: ok"
   484	      else
   485	        node_rc=$?
   486	        node_failed=$((node_failed + 1))
   487	        append_error "$workdir" "node $alias ($target) collector exited $node_rc"
   488	        progress "[$((i + 1))/$ntotal] node $alias: SKIPPED (exit $node_rc)"
   489	        rc=2
   490	      fi
   491	    done
   492	  fi
   493	
   494	  # Test-only hook: simulate a mid-run abort to exercise trap cleanup. Inert in production.
   495	  if [[ -n "${COLLECT_TEST_ABORT_AFTER_NODES:-}" ]]; then
   496	    die "test abort after nodes"
   497	  fi
   498	
   499	  progress "redacting…"
   500	  redact_bundle_text "$workdir"
   501	  write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "$rc"
   502	
   503	  progress "verifying…"
   504	  # Verify BEFORE packaging, but never let verification destroy collected
   505	  # evidence: capture its result instead of aborting under set -e. On failure,
   506	  # keep the workdir for inspection and do not produce a shareable bundle.
   507	  local verify_rc=0
   508	  set +e
   509	  "$COLLECT_ROOT/lib/verify-bundle.sh" "$workdir" >/dev/null 2>>"$workdir/errors.log"
   510	  verify_rc=$?
   511	  set -e
   512	  if [[ $verify_rc -ne 0 ]]; then
   513	    CLEANUP_KEEP=1
   514	    append_error "$workdir" "bundle verification failed (rc=$verify_rc); workdir kept, NOT packaged for sharing"
   515	    write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "1"
   516	    printf 'VERIFY FAILED: workdir kept at %s (not packaged) — review errors.log\n' "$workdir" >&2
   517	    return 1
   518	  fi
   519	
   520	  progress "packaging…"
   521	  bundle="$out_dir/ceph-incident-$timestamp.tar.gz"
   522	  COPYFILE_DISABLE=1 tar -czf "$bundle" -C "$workdir" .
   523	  set +e
   524	  "$COLLECT_ROOT/lib/verify-bundle.sh" "$bundle" >/dev/null 2>>"$workdir/errors.log"
   525	  verify_rc=$?
   526	  set -e
   527	  if [[ $verify_rc -ne 0 ]]; then
   528	    CLEANUP_KEEP=1
   529	    rm -f -- "$bundle"
   530	    printf 'VERIFY FAILED on packaged bundle; removed it, workdir kept at %s\n' "$workdir" >&2
   531	    return 1
   532	  fi
   533	
   534	  printf 'bundle: %s\n' "$bundle"
   535	  return "$rc"
   536	}
   537	
   538	main "$@"

 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-5A1m13ia' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-FuYiA70v' (errno=Operation not permitted)
diff --git a/experiments/ceph-incident-bundle/README.md b/experiments/ceph-incident-bundle/README.md
index 8a70c58..7d3f327 100644
--- a/experiments/ceph-incident-bundle/README.md
+++ b/experiments/ceph-incident-bundle/README.md
@@ -1,180 +1,190 @@
 # Ceph Incident Bundle
 
 ## 這是做什麼的
 
 這套 script 是事故發生時的「先保留現場」工具。它會從一台工作機透過 SSH 到所有 Ceph node 收集系統狀態、Ceph 狀態、log 清單與必要 log，最後打包成一個 `.tar.gz`。
 
 它不會修復 Ceph，也不會執行 restart、delete、repair、scrub 這類會改變 cluster 狀態的操作。
 
 ## 什麼時候執行
 
 建議在以下情境先跑一次：
 
 - `ceph health detail` 出現 `HEALTH_WARN` 或 `HEALTH_ERR`
 - OSD down、PG stuck、I/O latency 異常、MON quorum 異常
 - node CPU、RAM、disk、網路看起來異常，但還不確定是不是 Ceph 問題
 - 準備請別人或 AI 協助判讀，需要保留當下證據
 
+## 前置需求（known_hosts）
+
+工具的 SSH 都用 `BatchMode=yes`(不互動),所以**第一次從一台新跳板機執行前**,跳板機的 `known_hosts` 必須已經有所有目標 node 的 host key,否則每台會以 `Host key verification failed` 失敗、被標 SKIPPED(exit 2)。先做一次:
+
+```bash
+# 對 inventory 裡每台 host 先建立 host key（擇一）
+ssh-keyscan -H 192.168.18.166 192.168.18.167 ... >> ~/.ssh/known_hosts
+# 或手動 ssh 每台一次，確認指紋後接受
+```
+
 ## 最短操作流程
 
 在 repo root 執行：
 
 ```bash
 bash experiments/ceph-incident-bundle/run/collect.sh \
   --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
   --ssh-key .ssh/id_ed25519 \
   --seed ikaros@192.168.18.166 \
   --mode cephadm \
   --since 24h
 ```
 
 成功後會看到：
 
 ```text
 bundle: experiments/ceph-incident-bundle/results/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
 ```
 
 驗證 bundle：
 
 ```bash
 bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle.tar.gz>
 ```
 
 ## 如何填 inventory
 
 Inventory 是 shell 檔案，格式如下：
 
 ```bash
 SSH_USER="ikaros"
 SEED_HOST="192.168.18.166"
 ROOK_NAMESPACE="rook-ceph"
 HOSTS=(
   "monitor01=192.168.18.166"
   "mon02=192.168.18.167"
   "osd01=192.168.18.169"
 )
 ```
 
 - `SSH_USER`：登入每台 node 的 Linux 帳號。
-- `SEED_HOST`：**選填**。手動指定 cluster-level `ceph` command 要在哪台跑;不填則 `auto` 會自動挑第一台有 `cephadm` 的 node。
+- `SEED_HOST`：**選填**。手動指定 cluster-level `ceph` command 要在哪台跑;不填則 `auto` 會自動挑第一台「ceph 連得上」的 node(有 `ceph` 或 `cephadm` 且 `ceph -s` 成功)。
 - `ROOK_NAMESPACE`：Rook 的 namespace，未填時預設 `rook-ceph`。
 - `HOSTS`：每個項目是 `alias=host`，alias 會成為 bundle 裡 `nodes/<alias>/` 的目錄名稱。external-ceph rook 拓樸可以把 **external ceph 主機與 k8s node 混在同一份** `HOSTS` 裡。
 
 ## 自動偵測（auto，預設）
 
 預設 `--mode auto` 會逐台 node 經 ssh 偵測能力，再分層收集：
 
 - node 上有 `ceph` 或 `cephadm` → 從**第一台連得上 cluster** 的 node 收 cluster-level ceph。執行方式優先序：直接 `ceph`（最快，免每條起 container）→ `sudo -n ceph` → `sudo -n cephadm shell -- ceph`。「可用」= `ceph -s` 連得上,不是 binary 存在;選到哪個會記在進度（`via ceph` / `via cephadm shell`）與 `environment.txt` 的 `ceph_runner=`。
 - rook 層的 `kubectl` 由 `--kube-mode` 決定（預設 `remote`）：
   - `remote`（預設）：從**第一台**有 kubectl 的 inventory node、用 ssh 在該 node 上跑 `kubectl`。
   - `local`：在**執行工具的跳板機本機**跑 `kubectl`（kubectl/kubeconfig 在跳板機、不在 node 上時用這個）。
   - 兩種都可配 `--kube-context`。
 - 兩層都有來源就都收、各收一次;node 層一律每台都收。
 
 ```bash
 bash experiments/ceph-incident-bundle/run/collect.sh \
   --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
   --ssh-key .ssh/id_ed25519 \
   --since 24h
 ```
 
 ## external ceph + rook（一份 inventory）
 
 把 external ceph 主機和有 `kubectl` 的 k8s node 列進同一份 `HOSTS`，`auto` 會：ceph 層從 ceph 主機收、rook 層在 k8s node 上跑 kubectl 收。指定 context：
 
 ```bash
 SSH_USER="ikaros"
 HOSTS=(
   "mon01=10.0.0.1"     # external ceph（有 cephadm）
   "osd01=10.0.0.2"     # external ceph
   "k8s1=10.0.0.9"      # k8s node（有 kubectl）
 )
 ```
 
 ```bash
 bash experiments/ceph-incident-bundle/run/collect.sh \
   --inventory inventory/external.env \
   --ssh-key ~/.ssh/id_ed25519 \
   --kube-context my-cluster \
   --since 24h
 ```
 
 ## 只收單層（覆寫）
 
 - `--mode cephadm`（可配 `--seed USER@HOST`）：只收 ceph 層。
 - `--mode rook`：只收 rook 層（在第一台有 kubectl 的 node 上跑）。
 
 ## auto 的限制（已知）
 
-- **來源挑「第一台」、不看 liveness**：cluster-ceph 取第一台有 `cephadm` 的 node、cluster-rook 取第一台有 `kubectl` 的 node;只看指令存在、不檢查該 node 的 ceph/k8s 是否健康,也不會自動 fallback 到第二台。若想釘住一台已知健康的 mon,用 `--seed USER@HOST`。
+- **來源挑「第一台」**：cluster-ceph 取第一台**ceph 連得上**的 node(會實際試 `ceph -s`,連不上就換下一個候選);cluster-rook(remote)取第一台**有 `kubectl` 指令**的 node(只看指令存在,不檢查 k8s 健康、不 fallback 到第二台)。若想釘住一台已知健康的 mon,用 `--seed USER@HOST`。
 - **探測是逐台序列 ssh**:某層的能力完全不存在時(例如純 cephadm 叢集仍會為了 rook 掃完每台),或 node 沒回應時,探測會逐台等到 `ConnectTimeout`。大型 inventory 建議直接用 `--mode cephadm --seed ...` 跳過探測。探測 ssh 失敗的 node 會記進 `errors.log`(`capability probe failed for ...`),不會被當成「沒有該能力」而靜默忽略。
 
 ## 逾時與大型 log
 
 - `--timeout`（預設 20s）是**單一指令 / SSH 連線**的逾時。
 - `--node-timeout`（預設 600s）是**單一 node 整輪收集**的逾時。兩者分開：慢或大的 node 不會被單指令逾時誤殺。
 - 大型 Ceph log（超過 `CEPH_INCIDENT_LOG_FILE_CAP_BYTES`，預設 1 MiB）不會被靜默丟棄，而是收最後一段（tail）並附 `<檔名>.TRUNCATED` 記錄原始大小；壓縮過的 `*.gz` 過大時則只記錄、不收（gzip 的尾段無法解壓）。
 - 被逾時砍掉（exit 124/137）的指令輸出會在 artifact 末尾標 `# TRUNCATED`，讓判讀者知道內容被截斷。
 - **工作機若沒有 `timeout` / `gtimeout`**（如預設 macOS），會在開頭印警告；此時外層逾時停用，只靠 SSH `ConnectTimeout` / `ServerAlive` 把關。要完整把關可 `brew install coreutils`（提供 `gtimeout`），或在 Linux ops 機執行。
 
 ## 進度顯示
 
 執行時會把進度印到 **stderr**（探測每台 node、cluster ceph 的逐條指令 `[k/24]`、每台 node 收集、redact/verify/packaging）。**stdout 只會有最後一行 `bundle: <path>`**，方便 script 直接抓。
 
 要安靜（cron / 腳本）加 `--quiet`：不印進度,但 `bundle:` 與錯誤訊息照舊。
 
 ```bash
 # 看得到進度（預設）
 bash .../run/collect.sh --inventory inv.env --ssh-key key --since 24h
 # 安靜，只取 bundle 路徑
 BUNDLE=$(bash .../run/collect.sh --inventory inv.env --ssh-key key --since 24h --quiet | sed 's/^bundle: //')
 ```
 
 ## bundle 內有什麼
 
 主要檔案：
 
 - `README-FIRST.txt`：打開 bundle 後先看的入口。
 - `summary.txt`：本次收集摘要與成功/失敗數。
 - `environment.txt`：收集時間、mode、seed、git commit。
 - `manifest.jsonl`：每個 artifact 的 command、exit code、時間。
 - `errors.log`：非零 exit code、SSH 失敗、部分失敗。
 - `cluster/`：cephadm 或 Rook cluster-level 狀態。
 - `nodes/<alias>/`：每台 node 的系統、資源、disk、kernel、systemd、Ceph log 與 cephadm 狀態。
 
 ## exit code 怎麼看
 
 - `0`：收集完成，沒有已知失敗。（注意：OSD/MON down 這類**叢集故障本身**會被收進 bundle，不算收集失敗，仍是 `0`。）
 - `2`：有部分 command 或部分 node 失敗，但 bundle 已產生。先看 `errors.log` 和 `summary.txt`。
 - `1`：使用方式或必要輸入錯誤（inventory / SSH key 不存在），或 **bundle 驗證失敗**。驗證失敗時不會打包可分享的 `.tar.gz`，而是**保留 workdir**（印出路徑）讓你檢查——已收集的證據不會因驗證失敗被刪掉。
 
 ## 常見失敗與處理
 
 - `missing inventory`：確認 `--inventory` 路徑存在。
 - `missing ssh key`：確認 `--ssh-key` 路徑存在，且本機可讀。
-- `node <alias> collector exited 255`：通常是 SSH 連線、帳號、key、known_hosts 或 sudo 權限問題。
+- `node <alias> collector exited 255` / `Host key verification failed`：SSH 連線、帳號、key、**known_hosts**(見上方「前置需求」)或 sudo 權限問題。新跳板機最常見的是 known_hosts 還沒有該 node 的 host key。
 - `VERIFY FAIL`：bundle 結構不完整，或包含 `keyring`、`.ssh`、`id_ed25519`、`private_key`、`*.pem`/`*.key`/`*.crt` 這類路徑，或檔案內容殘留未遮蔽的 private key / `key = <base64>` 金鑰材料。此時 workdir 會被保留、不打包，先看印出的路徑與 `errors.log`。
 - exit code `2`：先不要重跑覆蓋判讀脈絡，先保留 `.tar.gz`，再看 `errors.log` 決定是否針對失敗 node 補跑。
 
 ## 安全界線
 
 - 這套工具以 read-only 收集為原則，不會主動修復或改變 Ceph 狀態。
 - 遮蔽（redaction）涵蓋：含 `password`/`secret`/`token`/`keyring`/`private key` 的文字行、Ceph 金鑰材料（`key = AQB..==` 與 base64 區塊）、整段多行 PEM private key block；並會把 `*.gz` 解壓後遮蔽再壓回。但這**不是完整 DLP**。
 - `verify-bundle.sh` 會以**檔名**（keyring/.ssh/id_ed25519/private_key/*.pem/*.key/*.crt）與**內容**（殘留的 PRIVATE KEY block / `key = <base64>`）兩道把關，但仍不能保證內容完全沒有敏感資料。
 - 分享 bundle 前仍應自行檢查是否包含內部 IP、hostname、路徑、帳號名稱或其他敏感資料。
 
 ## Lab 驗證（multi-fault）
 
 2026-06-30 在真 cephadm v19.2.3 叢集（3 mon + 9 OSD、pool `.mgr` size 3）跑過多故障矩陣，破壞性情境皆先 `ok-to-stop` / 確認 quorum 後注入並立即回退，最後 HEALTH_OK：
 
 | 情境 | 注入 | bundle | exit |
 |---|---|---|---|
 | 健康基準 | 無 | VERIFY PASS、6/6 node、312 行遮蔽 | 0 |
 | OSD down | 停 osd.0 | 收到 `OSD_DOWN`（text+json）| 0 |
 | MON 少一台 | 停 mon-02（quorum 在）| 收到 `MON_DOWN`（out of quorum）| 0 |
 | node 不可達 | inventory 加假 host | 該 node `SKIPPED.txt`、其餘照收、errors.log 有記 | 2 |
 | seed 不可達 | `--seed` 指死 host | cluster collector 失敗、6 node 仍收 | 2 |
 
 詳見 `docs/superpowers/reviews/2026-06-30-lab-validation.md`。
 
 - 已知 optional/read-only 非零紀錄：各 node 的 LVM 查詢（`pvs` / `vgs` / `lvs`）、`docker ps -a`、node-level `sudo cephadm ls --format json-pretty` 可能回非零；artifact 與 node 內部 `errors.log` 會保留原始輸出，整體 bundle 仍驗證通過。
diff --git a/experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh b/experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh
index 85fe9c4..b5de1c6 100644
--- a/experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh
+++ b/experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh
@@ -1,152 +1,141 @@
 #!/usr/bin/env bash
 set -euo pipefail
 
 # Cephadm collection helpers live here.
 
 CEPHADM_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 # shellcheck disable=SC1091
 source "$CEPHADM_COLLECTOR_DIR/common.sh"
 
 # The remote prefix that actually runs ceph on the source node, by runner token:
 #   direct  -> ceph                          (fast: no container per command)
 #   sudo    -> sudo -n ceph
 #   cephadm -> sudo -n cephadm shell -- ceph (default; spins a container each call)
 ceph_runner_argv() {
   case "$1" in
     direct) printf '%s\n' ceph ;;
     sudo) printf '%s\n' sudo -n ceph ;;
     *) printf '%s\n' sudo -n cephadm shell -- ceph ;;
   esac
 }
 
 collect_cephadm_command() {
   local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 runner=$6 artifact=$7
   shift 7
 
   local artifact_dir
   artifact_dir="$(dirname -- "$artifact")"
   ensure_dir "$artifact_dir"
 
-  local -a runner_argv
+  local -a runner_argv sopts
+  local _w
   while IFS= read -r _w; do runner_argv+=("$_w"); done < <(ceph_runner_argv "$runner")
+  while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
 
   COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
     run_capture "$manifest" "$seed" "collect-cluster-cephadm" "$artifact" -- \
-    ssh \
-      -i "$ssh_key" \
-      -o BatchMode=yes \
-      -o IdentitiesOnly=yes \
-      -o IdentityAgent=none \
-      -o "ConnectTimeout=$timeout" \
-      -o "ServerAliveInterval=$timeout" \
-      -o ServerAliveCountMax=1 \
-      "$seed" \
-      "${runner_argv[@]}" "$@"
+    ssh "${sopts[@]}" "$seed" "${runner_argv[@]}" "$@"
 }
 
 write_cephadm_crash_skip() {
-  local skip_artifact=$1
-  ensure_dir "$(dirname -- "$skip_artifact")"
-  cat >"$skip_artifact" <<'EOF'
-SKIPPED: unable to parse crash list JSON for recent crash inspection
-EOF
+  write_skip_artifact "$1" "unable to parse crash list JSON for recent crash inspection"
 }
 
 extract_cephadm_crash_ids() {
   local crash_ls_artifact=$1
   local payload compact ids
 
   [[ -f "$crash_ls_artifact" ]] || return 1
   payload="$(sed '/^[[:space:]]*#/d' "$crash_ls_artifact")" || return 1
 
   # Anchor strictly to crash_id; matching id/name too would capture unrelated
   # nested fields and feed bogus ids back into `ceph crash info`.
   ids="$(
     printf '%s\n' "$payload" |
       grep -oE '"crash_id"[[:space:]]*:[[:space:]]*"[^"]*"' |
       sed -E 's/^"crash_id"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/' |
       head -n 10
   )" || true
 
   if [[ -n "$ids" ]]; then
     printf '%s\n' "$ids"
     return 0
   fi
 
   compact="$(printf '%s' "$payload" | tr -d '[:space:]')"
   case "$compact" in
     "[]"|"{}"|"{\"crashes\":[]}"|"{\"items\":[]}"|"{\"entries\":[]}"|"{\"crash_ls\":[]}")
       return 0
       ;;
   esac
 
   return 1
 }
 
 cephadm_crash_artifact_name() {
   local crash_id=$1 safe_id
   safe_id="$(printf '%s' "$crash_id" | tr -c 'A-Za-z0-9._-' '_')"
   while [[ "$safe_id" == *..* ]]; do
     safe_id="${safe_id//../__}"
   done
   [[ -n "$safe_id" ]] || safe_id="crash"
   printf '%s' "$safe_id"
 }
 
 cephadm_unique_crash_artifact() {
   local crash_dir=$1 safe_id=$2
   local artifact="$crash_dir/$safe_id.json"
   local suffix=2
 
   while [[ -e "$artifact" ]]; do
     artifact="$crash_dir/$safe_id-$suffix.json"
     suffix=$((suffix + 1))
   done
 
   printf '%s' "$artifact"
 }
 
 collect_cephadm_recent_crashes() {
   local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 runner=$6 crash_ls_artifact=$7
 
   local crash_dir="$outdir/cluster/ceph/json/crash-info"
   local skip_artifact="$outdir/cluster/ceph/text/crash-info-skip.txt"
   local crash_ids rc=0
 
   if ! crash_ids="$(extract_cephadm_crash_ids "$crash_ls_artifact")"; then
     write_cephadm_crash_skip "$skip_artifact"
     return 0
   fi
 
   [[ -n "$crash_ids" ]] || return 0
 
   local crash_id safe_id crash_info_artifact
   while IFS= read -r crash_id; do
     [[ -n "$crash_id" ]] || continue
     safe_id="$(cephadm_crash_artifact_name "$crash_id")"
     crash_info_artifact="$(cephadm_unique_crash_artifact "$crash_dir" "$safe_id")"
     if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$runner" "$crash_info_artifact" crash info "$crash_id"; then
       rc=2
     fi
   done <<<"$crash_ids"
 
   return "$rc"
 }
 
 collect_cluster_cephadm() {
   local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 since=$5 timeout=$6 runner="${7:-cephadm}"
   local failed=0
   local json_dir="$outdir/cluster/ceph/json"
   local text_dir="$outdir/cluster/ceph/text"
 
   # Cluster-level ceph commands are point-in-time snapshots; node collectors apply the time window.
   : "$since"
 
   ensure_dir "$json_dir"
   ensure_dir "$text_dir"
 
   local -a json_specs=(
     "status.json::status --format json-pretty"
     "health-detail.json::health detail --format json-pretty"
     "versions.json::versions --format json-pretty"
     "df-detail.json::df detail --format json-pretty"
diff --git a/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh b/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
index e714114..93d2a12 100644
--- a/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
+++ b/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
@@ -1,186 +1,179 @@
 #!/usr/bin/env bash
 set -euo pipefail
 
 # Collect read-only Rook/Ceph Kubernetes evidence.
 
 ROOK_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 # shellcheck disable=SC1091
 source "$ROOK_COLLECTOR_DIR/common.sh"
 
 # Default kubectl prefix (local); collect_cluster_rook overrides it per call.
 ROOK_KUBECTL_ARGV=(kubectl)
 
 usage() {
   cat <<'EOF'
 Usage: collect-cluster-rook.sh --out DIR --manifest PATH [--namespace rook-ceph]
        [--operator-namespace rook-ceph] [--since DURATION] [--timeout SECONDS] [--allow-skip]
        [--ssh-target USER@HOST --ssh-key PATH] [--kube-context CTX]
 EOF
 }
 
 rook_skip() {
-  local outdir=$1 reason=$2
-  local artifact="$outdir/cluster/rook/SKIPPED.txt"
-  ensure_dir "$(dirname -- "$artifact")"
-  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
-}
-
-rook_write_skip_artifact() {
-  local artifact=$1 reason=$2
-  ensure_dir "$(dirname -- "$artifact")"
-  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
+  write_skip_artifact "$1/cluster/rook/SKIPPED.txt" "$2"
 }
 
 rook_run_capture() {
   local outdir=$1 manifest=$2 timeout=$3 artifact_rel=$4
   shift 4
 
   local artifact="$outdir/$artifact_rel"
   if ! COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
     run_capture "$manifest" "rook" "collect-cluster-rook" "$artifact" -- "$@"; then
     return 2
   fi
   return 0
 }
 
 rook_get_first_pod() {
   local namespace=$1 label=$2
   # -o name (not jsonpath) so the arg has no braces/brackets to mangle over ssh.
   # `|| true`: a lookup failure (e.g. remote kubectl/ssh error) must yield an
   # empty result (-> SKIPPED artifact), not abort the collector under set -e.
   { "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -l "$label" -o name 2>/dev/null || true; } |
     head -n1 | sed 's#^pod/##'
 }
 
 collect_cluster_rook() {
   local outdir='' manifest='' namespace=rook-ceph since=24h timeout=20 allow_skip=0
   local operator_namespace='' ssh_target='' ssh_key='' kube_context=''
 
   while [[ $# -gt 0 ]]; do
     case "$1" in
       --out)
         outdir=${2-}
         shift 2
         ;;
       --manifest)
         manifest=${2-}
         shift 2
         ;;
       --namespace)
         namespace=${2-}
         shift 2
         ;;
       --operator-namespace)
         operator_namespace=${2-}
         shift 2
         ;;
       --since)
         since=${2-}
         shift 2
         ;;
       --timeout)
         timeout=${2-}
         shift 2
         ;;
       --allow-skip)
         allow_skip=1
         shift
         ;;
       --ssh-target)
         ssh_target=${2-}
         shift 2
         ;;
       --ssh-key)
         ssh_key=${2-}
         shift 2
         ;;
       --kube-context)
         kube_context=${2-}
         shift 2
         ;;
       --help|-h)
         usage
         return 0
         ;;
       *)
         usage >&2
         return 1
         ;;
     esac
   done
 
   [[ -n "$outdir" && -n "$manifest" ]] || {
     usage >&2
     return 1
   }
 
   ensure_dir "$outdir/cluster/rook"
   [[ -n "$operator_namespace" ]] || operator_namespace="$namespace"
 
   # Build the kubectl prefix once. With --ssh-target, kubectl runs ON that node
   # over ssh (the node where kubectl/kubeconfig lives); otherwise locally.
   # ROOK_KUBECTL_ARGV is global so rook_get_first_pod can use the same prefix.
   if [[ -n "$ssh_target" ]]; then
-    ROOK_KUBECTL_ARGV=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$ssh_target" kubectl)
+    local -a sopts; local _w
+    while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
+    ROOK_KUBECTL_ARGV=(ssh "${sopts[@]}" "$ssh_target" kubectl)
   else
     ROOK_KUBECTL_ARGV=(kubectl)
   fi
   [[ -n "$kube_context" ]] && ROOK_KUBECTL_ARGV+=(--context "$kube_context")
 
   # Missing kubectl / namespace means we collected NO cluster evidence. In
   # explicit rook mode that is a partial failure (exit 2) so the bundle does not
   # falsely look complete; auto-mode fallback passes --allow-skip to tolerate it.
   # (When kubectl is remote we already probed it exists, so skip the local check.)
   if [[ -z "$ssh_target" ]] && ! command -v kubectl >/dev/null 2>&1; then
     rook_skip "$outdir" "kubectl command not found"
     [[ "$allow_skip" == "1" ]] && return 0 || return 2
   fi
 
   if ! "${ROOK_KUBECTL_ARGV[@]}" get namespace "$namespace" >/dev/null 2>&1; then
     rook_skip "$outdir" "namespace not found (or kubectl unavailable on ${ssh_target:-local}): $namespace"
     [[ "$allow_skip" == "1" ]] && return 0 || return 2
   fi
 
   progress "rook: pods/events/resources/operator-log/toolbox…"
   local failed=0
   if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/pods-wide.txt" \
     "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -o wide; then
     failed=1
   fi
   if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/events.txt" \
     "${ROOK_KUBECTL_ARGV[@]}" get events -n "$namespace" --sort-by=.lastTimestamp; then
     failed=1
   fi
   if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/rook-resources.yaml" \
     "${ROOK_KUBECTL_ARGV[@]}" get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n "$namespace" -o yaml; then
     failed=1
   fi
 
   local operator_pod toolbox_pod
   operator_pod="$(rook_get_first_pod "$operator_namespace" "app=rook-ceph-operator")"
   if [[ -n "$operator_pod" ]]; then
     if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
       "${ROOK_KUBECTL_ARGV[@]}" logs -n "$operator_namespace" "$operator_pod" --since="$since"; then
       failed=1
     fi
   else
-    rook_write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found in namespace: $operator_namespace"
+    write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found in namespace: $operator_namespace"
   fi
 
   toolbox_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-tools")"
   if [[ -n "$toolbox_pod" ]]; then
     if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
       "${ROOK_KUBECTL_ARGV[@]}" exec -n "$namespace" "$toolbox_pod" -- ceph status; then
       failed=1
     fi
   else
-    rook_write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
+    write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
   fi
 
   [[ $failed -eq 0 ]] || return 2
   return 0
 }
 
 if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
   collect_cluster_rook "$@"
 fi
diff --git a/experiments/ceph-incident-bundle/lib/collect-node.sh b/experiments/ceph-incident-bundle/lib/collect-node.sh
index dd0972d..a2a2bc1 100644
--- a/experiments/ceph-incident-bundle/lib/collect-node.sh
+++ b/experiments/ceph-incident-bundle/lib/collect-node.sh
@@ -1,120 +1,115 @@
 #!/usr/bin/env bash
 set -euo pipefail
 
 # Collect read-only node evidence for a Ceph incident bundle.
 
 NODE_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 # shellcheck disable=SC1091
 source "$NODE_COLLECTOR_DIR/common.sh"
 
 usage() {
   cat <<'EOF'
 Usage: collect-node.sh --out DIR --host-alias ALIAS [--since DURATION] [--timeout SECONDS] [--skip-logs]
 EOF
 }
 
-write_skip_artifact() {
-  local artifact=$1 reason=$2
-  ensure_dir "$(dirname -- "$artifact")"
-  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
-}
 
 node_run_capture() {
   local outdir=$1 manifest=$2 host_alias=$3 timeout=$4 artifact_rel=$5
   shift 5
 
   local artifact="$outdir/$artifact_rel"
   if ! COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
     run_capture "$manifest" "$host_alias" "collect-node" "$artifact" -- "$@"; then
     return 2
   fi
   return 0
 }
 
 node_run_optional() {
   local outdir=$1 manifest=$2 host_alias=$3 timeout=$4 artifact_rel=$5 command_name=$6
   shift 6
 
   if ! command -v "$command_name" >/dev/null 2>&1; then
     write_skip_artifact "$outdir/$artifact_rel" "command not found: $command_name"
     return 0
   fi
 
   node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" "$command_name" "$@" || return 0
 }
 
 node_run_privileged() {
   local outdir=$1 manifest=$2 host_alias=$3 timeout=$4 artifact_rel=$5 command_name=$6
   shift 6
 
   if [[ $EUID -eq 0 ]]; then
     node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" "$command_name" "$@"
     return $?
   fi
 
   if ! command -v sudo >/dev/null 2>&1; then
     write_skip_artifact "$outdir/$artifact_rel" "sudo command not found for privileged read: $command_name"
     return 0
   fi
 
   node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" sudo -n "$command_name" "$@"
 }
 
 journal_since_arg() {
   local since=$1
   if [[ "$since" =~ ^[0-9]+[smhdw]$ ]]; then
     printf -- '-%s' "$since"
   else
     printf '%s' "$since"
   fi
 }
 
 node_find0() {
   local root=$1
   shift
 
   if [[ $EUID -eq 0 ]]; then
     find "$root" "$@"
     return $?
   fi
 
   if command -v sudo >/dev/null 2>&1; then
     sudo -n find "$root" "$@"
     return $?
   fi
 
   find "$root" "$@" 2>/dev/null
 }
 
 node_file_size() {
   local source=$1 size
 
   if [[ $EUID -eq 0 || -r "$source" ]]; then
     size="$(wc -c <"$source" 2>/dev/null | tr -d '[:space:]')" || return 1
   elif command -v sudo >/dev/null 2>&1; then
     size="$(sudo -n wc -c "$source" 2>/dev/null | awk '{print $1}')" || return 1
   else
     return 1
   fi
 
   [[ "$size" =~ ^[0-9]+$ ]] || return 1
   printf '%s' "$size"
 }
 
 node_copy_file() {
   local source=$1 dest=$2
   ensure_dir "$(dirname -- "$dest")"
 
   if [[ $EUID -eq 0 || -r "$source" ]]; then
     cp -p -- "$source" "$dest"
     return $?
   fi
 
   if command -v sudo >/dev/null 2>&1; then
     # Intentional: read the source as root, but write $dest as the calling user
     # (who owns the bundle). `sudo tee` would create $dest as root — not wanted.
     # shellcheck disable=SC2024
     sudo -n cat -- "$source" >"$dest"
     return $?
   fi
 

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh | sed -n '1,220p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	# Cephadm collection helpers live here.
     5	
     6	CEPHADM_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
     7	# shellcheck disable=SC1091
     8	source "$CEPHADM_COLLECTOR_DIR/common.sh"
     9	
    10	# The remote prefix that actually runs ceph on the source node, by runner token:
    11	#   direct  -> ceph                          (fast: no container per command)
    12	#   sudo    -> sudo -n ceph
    13	#   cephadm -> sudo -n cephadm shell -- ceph (default; spins a container each call)
    14	ceph_runner_argv() {
    15	  case "$1" in
    16	    direct) printf '%s\n' ceph ;;
    17	    sudo) printf '%s\n' sudo -n ceph ;;
    18	    *) printf '%s\n' sudo -n cephadm shell -- ceph ;;
    19	  esac
    20	}
    21	
    22	collect_cephadm_command() {
    23	  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 runner=$6 artifact=$7
    24	  shift 7
    25	
    26	  local artifact_dir
    27	  artifact_dir="$(dirname -- "$artifact")"
    28	  ensure_dir "$artifact_dir"
    29	
    30	  local -a runner_argv sopts
    31	  local _w
    32	  while IFS= read -r _w; do runner_argv+=("$_w"); done < <(ceph_runner_argv "$runner")
    33	  while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
    34	
    35	  COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
    36	    run_capture "$manifest" "$seed" "collect-cluster-cephadm" "$artifact" -- \
    37	    ssh "${sopts[@]}" "$seed" "${runner_argv[@]}" "$@"
    38	}
    39	
    40	write_cephadm_crash_skip() {
    41	  write_skip_artifact "$1" "unable to parse crash list JSON for recent crash inspection"
    42	}
    43	
    44	extract_cephadm_crash_ids() {
    45	  local crash_ls_artifact=$1
    46	  local payload compact ids
    47	
    48	  [[ -f "$crash_ls_artifact" ]] || return 1
    49	  payload="$(sed '/^[[:space:]]*#/d' "$crash_ls_artifact")" || return 1
    50	
    51	  # Anchor strictly to crash_id; matching id/name too would capture unrelated
    52	  # nested fields and feed bogus ids back into `ceph crash info`.
    53	  ids="$(
    54	    printf '%s\n' "$payload" |
    55	      grep -oE '"crash_id"[[:space:]]*:[[:space:]]*"[^"]*"' |
    56	      sed -E 's/^"crash_id"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/' |
    57	      head -n 10
    58	  )" || true
    59	
    60	  if [[ -n "$ids" ]]; then
    61	    printf '%s\n' "$ids"
    62	    return 0
    63	  fi
    64	
    65	  compact="$(printf '%s' "$payload" | tr -d '[:space:]')"
    66	  case "$compact" in
    67	    "[]"|"{}"|"{\"crashes\":[]}"|"{\"items\":[]}"|"{\"entries\":[]}"|"{\"crash_ls\":[]}")
    68	      return 0
    69	      ;;
    70	  esac
    71	
    72	  return 1
    73	}
    74	
    75	cephadm_crash_artifact_name() {
    76	  local crash_id=$1 safe_id
    77	  safe_id="$(printf '%s' "$crash_id" | tr -c 'A-Za-z0-9._-' '_')"
    78	  while [[ "$safe_id" == *..* ]]; do
    79	    safe_id="${safe_id//../__}"
    80	  done
    81	  [[ -n "$safe_id" ]] || safe_id="crash"
    82	  printf '%s' "$safe_id"
    83	}
    84	
    85	cephadm_unique_crash_artifact() {
    86	  local crash_dir=$1 safe_id=$2
    87	  local artifact="$crash_dir/$safe_id.json"
    88	  local suffix=2
    89	
    90	  while [[ -e "$artifact" ]]; do
    91	    artifact="$crash_dir/$safe_id-$suffix.json"
    92	    suffix=$((suffix + 1))
    93	  done
    94	
    95	  printf '%s' "$artifact"
    96	}
    97	
    98	collect_cephadm_recent_crashes() {
    99	  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 runner=$6 crash_ls_artifact=$7
   100	
   101	  local crash_dir="$outdir/cluster/ceph/json/crash-info"
   102	  local skip_artifact="$outdir/cluster/ceph/text/crash-info-skip.txt"
   103	  local crash_ids rc=0
   104	
   105	  if ! crash_ids="$(extract_cephadm_crash_ids "$crash_ls_artifact")"; then
   106	    write_cephadm_crash_skip "$skip_artifact"
   107	    return 0
   108	  fi
   109	
   110	  [[ -n "$crash_ids" ]] || return 0
   111	
   112	  local crash_id safe_id crash_info_artifact
   113	  while IFS= read -r crash_id; do
   114	    [[ -n "$crash_id" ]] || continue
   115	    safe_id="$(cephadm_crash_artifact_name "$crash_id")"
   116	    crash_info_artifact="$(cephadm_unique_crash_artifact "$crash_dir" "$safe_id")"
   117	    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$runner" "$crash_info_artifact" crash info "$crash_id"; then
   118	      rc=2
   119	    fi
   120	  done <<<"$crash_ids"
   121	
   122	  return "$rc"
   123	}
   124	
   125	collect_cluster_cephadm() {
   126	  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 since=$5 timeout=$6 runner="${7:-cephadm}"
   127	  local failed=0
   128	  local json_dir="$outdir/cluster/ceph/json"
   129	  local text_dir="$outdir/cluster/ceph/text"
   130	
   131	  # Cluster-level ceph commands are point-in-time snapshots; node collectors apply the time window.
   132	  : "$since"
   133	
   134	  ensure_dir "$json_dir"
   135	  ensure_dir "$text_dir"
   136	
   137	  local -a json_specs=(
   138	    "status.json::status --format json-pretty"
   139	    "health-detail.json::health detail --format json-pretty"
   140	    "versions.json::versions --format json-pretty"
   141	    "df-detail.json::df detail --format json-pretty"
   142	    "osd-tree.json::osd tree --format json-pretty"
   143	    "osd-df.json::osd df --format json-pretty"
   144	    "osd-dump.json::osd dump --format json-pretty"
   145	    "osd-perf.json::osd perf --format json-pretty"
   146	    "osd-blocked-by.json::osd blocked-by --format json-pretty"
   147	    "pg-stat.json::pg stat --format json-pretty"
   148	    "pg-dump.json::pg dump --format json-pretty"
   149	    "pg-dump-stuck.json::pg dump_stuck --format json-pretty"
   150	    "mon-dump.json::mon dump --format json-pretty"
   151	    "quorum-status.json::quorum_status --format json-pretty"
   152	    "mgr-dump.json::mgr dump --format json-pretty"
   153	    "orch-host-ls.json::orch host ls --format json-pretty"
   154	    "orch-ps.json::orch ps --format json-pretty"
   155	    "orch-device-ls-wide.json::orch device ls --wide --format json-pretty"
   156	    "config-dump.json::config dump --format json-pretty"
   157	    "crash-ls.json::crash ls --format json-pretty"
   158	  )
   159	
   160	  local -a text_specs=(
   161	    "status.txt::status"
   162	    "health-detail.txt::health detail"
   163	    "osd-tree.txt::osd tree"
   164	    "orch-ps.txt::orch ps"
   165	  )
   166	
   167	  local spec artifact command
   168	  local -a command_words
   169	  local total=$(( ${#json_specs[@]} + ${#text_specs[@]} )) k=0
   170	  for spec in "${json_specs[@]}"; do
   171	    artifact=${spec%%::*}
   172	    command=${spec#*::}
   173	    k=$((k + 1))
   174	    progress "[$k/$total] ceph $command"
   175	    # shellcheck disable=SC2206
   176	    command_words=($command)
   177	    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$runner" "$json_dir/$artifact" "${command_words[@]}"; then
   178	      failed=1
   179	    fi
   180	  done
   181	
   182	  for spec in "${text_specs[@]}"; do
   183	    artifact=${spec%%::*}
   184	    command=${spec#*::}
   185	    k=$((k + 1))
   186	    progress "[$k/$total] ceph $command"
   187	    # shellcheck disable=SC2206
   188	    command_words=($command)
   189	    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$runner" "$text_dir/$artifact" "${command_words[@]}"; then
   190	      failed=1
   191	    fi
   192	  done
   193	
   194	  progress "ceph crash info (recent)…"
   195	  if ! collect_cephadm_recent_crashes "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$runner" "$json_dir/crash-ls.json"; then
   196	    failed=1
   197	  fi
   198	
   199	  if [[ $failed -ne 0 ]]; then
   200	    return 2
   201	  fi
   202	
   203	  return 0
   204	}

exec
/bin/zsh -lc 'rg -n "ceph_incident_bundle_log|parse_host_entry|ssh_base_opts|write_skip_artifact|write_skip_artifact_once|redact_bundle_text|ssh_target_for_host|shell_quote|append_error|write_initial_metadata|write_summary|redact_file|redact_gz_file|COLLECT_ROOT" experiments/ceph-incident-bundle' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:33:  while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:41:  write_skip_artifact "$1" "unable to parse crash list JSON for recent crash inspection"
experiments/ceph-incident-bundle/lib/bundle.sh:7:# common.sh (sourced first by the entrypoint) for redact_file/redact_gz_file.
experiments/ceph-incident-bundle/lib/bundle.sh:9:ssh_target_for_host() {
experiments/ceph-incident-bundle/lib/bundle.sh:20:shell_quote() {
experiments/ceph-incident-bundle/lib/bundle.sh:26:write_initial_metadata() {
experiments/ceph-incident-bundle/lib/bundle.sh:29:  git_commit="$(git -C "$COLLECT_ROOT/../.." rev-parse --short HEAD 2>/dev/null || printf unknown)"
experiments/ceph-incident-bundle/lib/bundle.sh:56:write_summary() {
experiments/ceph-incident-bundle/lib/bundle.sh:71:append_error() {
experiments/ceph-incident-bundle/lib/bundle.sh:77:redact_bundle_text() {
experiments/ceph-incident-bundle/lib/bundle.sh:84:      *.gz) redact_gz_file "$path" "$redaction_log" ;;
experiments/ceph-incident-bundle/lib/bundle.sh:85:      *) redact_file "$path" "$redaction_log" ;;
experiments/ceph-incident-bundle/run/collect.sh:7:COLLECT_ROOT="$(cd "$COLLECT_RUN_DIR/.." && pwd)"
experiments/ceph-incident-bundle/run/collect.sh:9:source "$COLLECT_ROOT/lib/common.sh"
experiments/ceph-incident-bundle/run/collect.sh:11:source "$COLLECT_ROOT/lib/collect-cluster-cephadm.sh"
experiments/ceph-incident-bundle/run/collect.sh:13:source "$COLLECT_ROOT/lib/collect-cluster-rook.sh"
experiments/ceph-incident-bundle/run/collect.sh:15:source "$COLLECT_ROOT/lib/bundle.sh"
experiments/ceph-incident-bundle/run/collect.sh:62:  while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
experiments/ceph-incident-bundle/run/collect.sh:87:  while IFS= read -r w; do sopts+=("$w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
experiments/ceph-incident-bundle/run/collect.sh:211:    write_skip_artifact_once "$workdir/cluster/ceph/SKIPPED.txt" "no cephadm-capable node found (or --seed unreachable)"
experiments/ceph-incident-bundle/run/collect.sh:214:    write_skip_artifact_once "$workdir/cluster/rook/SKIPPED.txt" "no kubectl-capable node found"
experiments/ceph-incident-bundle/run/collect.sh:218:    [[ $ceph_done -eq 0 ]] && write_skip_artifact_once "$workdir/cluster/ceph/SKIPPED.txt" "no cephadm-capable node in inventory (auto)"
experiments/ceph-incident-bundle/run/collect.sh:219:    [[ $rook_done -eq 0 ]] && write_skip_artifact_once "$workdir/cluster/rook/SKIPPED.txt" "no kubectl-capable node in inventory (auto)"
experiments/ceph-incident-bundle/run/collect.sh:242:  q_alias="$(shell_quote "$alias")" || return 1
experiments/ceph-incident-bundle/run/collect.sh:243:  q_since="$(shell_quote "$since")" || return 1
experiments/ceph-incident-bundle/run/collect.sh:244:  q_timeout="$(shell_quote "$timeout")" || return 1
experiments/ceph-incident-bundle/run/collect.sh:254:  while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
experiments/ceph-incident-bundle/run/collect.sh:273:  COPYFILE_DISABLE=1 tar $noxattrs -cf - -C "$COLLECT_ROOT" lib/common.sh lib/collect-node.sh | gzip -c |
experiments/ceph-incident-bundle/run/collect.sh:323:  local inventory='' ssh_key='' seed_override='' out_dir="$COLLECT_ROOT/results"
experiments/ceph-incident-bundle/run/collect.sh:423:    seed="$(ssh_target_for_host "$seed_host" "$ssh_user")"
experiments/ceph-incident-bundle/run/collect.sh:438:  write_initial_metadata "$workdir" "$mode" "$seed" "$since" "$timeout"
experiments/ceph-incident-bundle/run/collect.sh:451:      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
experiments/ceph-incident-bundle/run/collect.sh:456:    HOST_TARGETS+=("$(ssh_target_for_host "${entry#*=}" "$ssh_user")")
experiments/ceph-incident-bundle/run/collect.sh:470:    append_error "$workdir" "cluster collection exited $cluster_rc"
experiments/ceph-incident-bundle/run/collect.sh:487:        append_error "$workdir" "node $alias ($target) collector exited $node_rc"
experiments/ceph-incident-bundle/run/collect.sh:500:  redact_bundle_text "$workdir"
experiments/ceph-incident-bundle/run/collect.sh:501:  write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "$rc"
experiments/ceph-incident-bundle/run/collect.sh:509:  "$COLLECT_ROOT/lib/verify-bundle.sh" "$workdir" >/dev/null 2>>"$workdir/errors.log"
experiments/ceph-incident-bundle/run/collect.sh:514:    append_error "$workdir" "bundle verification failed (rc=$verify_rc); workdir kept, NOT packaged for sharing"
experiments/ceph-incident-bundle/run/collect.sh:515:    write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "1"
experiments/ceph-incident-bundle/run/collect.sh:524:  "$COLLECT_ROOT/lib/verify-bundle.sh" "$bundle" >/dev/null 2>>"$workdir/errors.log"
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:22:  write_skip_artifact "$1/cluster/rook/SKIPPED.txt" "$2"
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:116:    while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:160:    write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found in namespace: $operator_namespace"
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:170:    write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
experiments/ceph-incident-bundle/lib/collect-node.sh:34:    write_skip_artifact "$outdir/$artifact_rel" "command not found: $command_name"
experiments/ceph-incident-bundle/lib/collect-node.sh:51:    write_skip_artifact "$outdir/$artifact_rel" "sudo command not found for privileged read: $command_name"
experiments/ceph-incident-bundle/lib/collect-node.sh:244:    write_skip_artifact "$outdir/cephadm/var-lib-ceph-listing.txt" "$ceph_dir is not a readable directory on this node"
experiments/ceph-incident-bundle/lib/collect-node.sh:379:    write_skip_artifact "$outdir/cephadm/cephadm-ls.json" "command not found: cephadm"
experiments/ceph-incident-bundle/lib/collect-node.sh:388:    write_skip_artifact "$outdir/logs/ceph-log-listing.txt" "log collection disabled by --skip-logs"
experiments/ceph-incident-bundle/lib/common.sh:28:ssh_base_opts() {
experiments/ceph-incident-bundle/lib/common.sh:42:write_skip_artifact() {
experiments/ceph-incident-bundle/lib/common.sh:48:write_skip_artifact_once() {
experiments/ceph-incident-bundle/lib/common.sh:51:  write_skip_artifact "$artifact" "$reason"
experiments/ceph-incident-bundle/lib/common.sh:96:redact_file() {
experiments/ceph-incident-bundle/lib/common.sh:146:redact_gz_file() {
experiments/ceph-incident-bundle/lib/common.sh:162:  redact_file "$tmp_plain" "$redaction_log"
experiments/ceph-incident-bundle/tests/test-common.sh:109:test_redact_file() {
experiments/ceph-incident-bundle/tests/test-common.sh:122:  redact_file "$source_file" "$redaction_log"
experiments/ceph-incident-bundle/tests/test-common.sh:133:test_redact_file_private_key_variants() {
experiments/ceph-incident-bundle/tests/test-common.sh:144:  redact_file "$source_file" "$redaction_log"
experiments/ceph-incident-bundle/tests/test-common.sh:152:test_redact_file_multiline_pem_body() {
experiments/ceph-incident-bundle/tests/test-common.sh:165:  redact_file "$source_file" "$redaction_log"
experiments/ceph-incident-bundle/tests/test-common.sh:174:test_redact_file_ceph_key_material() {
experiments/ceph-incident-bundle/tests/test-common.sh:185:  redact_file "$source_file" "$redaction_log"
experiments/ceph-incident-bundle/tests/test-common.sh:193:test_redact_file_preserves_mode() {
experiments/ceph-incident-bundle/tests/test-common.sh:199:  redact_file "$source_file" "$redaction_log"
experiments/ceph-incident-bundle/tests/test-common.sh:206:test_redact_gz_file() {
experiments/ceph-incident-bundle/tests/test-common.sh:215:  redact_gz_file "$gz" "$redaction_log"
experiments/ceph-incident-bundle/tests/test-common.sh:359:test_redact_file
experiments/ceph-incident-bundle/tests/test-common.sh:360:test_redact_file_private_key_variants
experiments/ceph-incident-bundle/tests/test-common.sh:361:test_redact_file_multiline_pem_body
experiments/ceph-incident-bundle/tests/test-common.sh:362:test_redact_file_ceph_key_material
experiments/ceph-incident-bundle/tests/test-common.sh:363:test_redact_file_preserves_mode
experiments/ceph-incident-bundle/tests/test-common.sh:364:test_redact_gz_file

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh | sed -n '1,240p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	# Collect read-only Rook/Ceph Kubernetes evidence.
     5	
     6	ROOK_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
     7	# shellcheck disable=SC1091
     8	source "$ROOK_COLLECTOR_DIR/common.sh"
     9	
    10	# Default kubectl prefix (local); collect_cluster_rook overrides it per call.
    11	ROOK_KUBECTL_ARGV=(kubectl)
    12	
    13	usage() {
    14	  cat <<'EOF'
    15	Usage: collect-cluster-rook.sh --out DIR --manifest PATH [--namespace rook-ceph]
    16	       [--operator-namespace rook-ceph] [--since DURATION] [--timeout SECONDS] [--allow-skip]
    17	       [--ssh-target USER@HOST --ssh-key PATH] [--kube-context CTX]
    18	EOF
    19	}
    20	
    21	rook_skip() {
    22	  write_skip_artifact "$1/cluster/rook/SKIPPED.txt" "$2"
    23	}
    24	
    25	rook_run_capture() {
    26	  local outdir=$1 manifest=$2 timeout=$3 artifact_rel=$4
    27	  shift 4
    28	
    29	  local artifact="$outdir/$artifact_rel"
    30	  if ! COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
    31	    run_capture "$manifest" "rook" "collect-cluster-rook" "$artifact" -- "$@"; then
    32	    return 2
    33	  fi
    34	  return 0
    35	}
    36	
    37	rook_get_first_pod() {
    38	  local namespace=$1 label=$2
    39	  # -o name (not jsonpath) so the arg has no braces/brackets to mangle over ssh.
    40	  # `|| true`: a lookup failure (e.g. remote kubectl/ssh error) must yield an
    41	  # empty result (-> SKIPPED artifact), not abort the collector under set -e.
    42	  { "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -l "$label" -o name 2>/dev/null || true; } |
    43	    head -n1 | sed 's#^pod/##'
    44	}
    45	
    46	collect_cluster_rook() {
    47	  local outdir='' manifest='' namespace=rook-ceph since=24h timeout=20 allow_skip=0
    48	  local operator_namespace='' ssh_target='' ssh_key='' kube_context=''
    49	
    50	  while [[ $# -gt 0 ]]; do
    51	    case "$1" in
    52	      --out)
    53	        outdir=${2-}
    54	        shift 2
    55	        ;;
    56	      --manifest)
    57	        manifest=${2-}
    58	        shift 2
    59	        ;;
    60	      --namespace)
    61	        namespace=${2-}
    62	        shift 2
    63	        ;;
    64	      --operator-namespace)
    65	        operator_namespace=${2-}
    66	        shift 2
    67	        ;;
    68	      --since)
    69	        since=${2-}
    70	        shift 2
    71	        ;;
    72	      --timeout)
    73	        timeout=${2-}
    74	        shift 2
    75	        ;;
    76	      --allow-skip)
    77	        allow_skip=1
    78	        shift
    79	        ;;
    80	      --ssh-target)
    81	        ssh_target=${2-}
    82	        shift 2
    83	        ;;
    84	      --ssh-key)
    85	        ssh_key=${2-}
    86	        shift 2
    87	        ;;
    88	      --kube-context)
    89	        kube_context=${2-}
    90	        shift 2
    91	        ;;
    92	      --help|-h)
    93	        usage
    94	        return 0
    95	        ;;
    96	      *)
    97	        usage >&2
    98	        return 1
    99	        ;;
   100	    esac
   101	  done
   102	
   103	  [[ -n "$outdir" && -n "$manifest" ]] || {
   104	    usage >&2
   105	    return 1
   106	  }
   107	
   108	  ensure_dir "$outdir/cluster/rook"
   109	  [[ -n "$operator_namespace" ]] || operator_namespace="$namespace"
   110	
   111	  # Build the kubectl prefix once. With --ssh-target, kubectl runs ON that node
   112	  # over ssh (the node where kubectl/kubeconfig lives); otherwise locally.
   113	  # ROOK_KUBECTL_ARGV is global so rook_get_first_pod can use the same prefix.
   114	  if [[ -n "$ssh_target" ]]; then
   115	    local -a sopts; local _w
   116	    while IFS= read -r _w; do sopts+=("$_w"); done < <(ssh_base_opts "$ssh_key" "$timeout")
   117	    ROOK_KUBECTL_ARGV=(ssh "${sopts[@]}" "$ssh_target" kubectl)
   118	  else
   119	    ROOK_KUBECTL_ARGV=(kubectl)
   120	  fi
   121	  [[ -n "$kube_context" ]] && ROOK_KUBECTL_ARGV+=(--context "$kube_context")
   122	
   123	  # Missing kubectl / namespace means we collected NO cluster evidence. In
   124	  # explicit rook mode that is a partial failure (exit 2) so the bundle does not
   125	  # falsely look complete; auto-mode fallback passes --allow-skip to tolerate it.
   126	  # (When kubectl is remote we already probed it exists, so skip the local check.)
   127	  if [[ -z "$ssh_target" ]] && ! command -v kubectl >/dev/null 2>&1; then
   128	    rook_skip "$outdir" "kubectl command not found"
   129	    [[ "$allow_skip" == "1" ]] && return 0 || return 2
   130	  fi
   131	
   132	  if ! "${ROOK_KUBECTL_ARGV[@]}" get namespace "$namespace" >/dev/null 2>&1; then
   133	    rook_skip "$outdir" "namespace not found (or kubectl unavailable on ${ssh_target:-local}): $namespace"
   134	    [[ "$allow_skip" == "1" ]] && return 0 || return 2
   135	  fi
   136	
   137	  progress "rook: pods/events/resources/operator-log/toolbox…"
   138	  local failed=0
   139	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/pods-wide.txt" \
   140	    "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -o wide; then
   141	    failed=1
   142	  fi
   143	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/events.txt" \
   144	    "${ROOK_KUBECTL_ARGV[@]}" get events -n "$namespace" --sort-by=.lastTimestamp; then
   145	    failed=1
   146	  fi
   147	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/rook-resources.yaml" \
   148	    "${ROOK_KUBECTL_ARGV[@]}" get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n "$namespace" -o yaml; then
   149	    failed=1
   150	  fi
   151	
   152	  local operator_pod toolbox_pod
   153	  operator_pod="$(rook_get_first_pod "$operator_namespace" "app=rook-ceph-operator")"
   154	  if [[ -n "$operator_pod" ]]; then
   155	    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
   156	      "${ROOK_KUBECTL_ARGV[@]}" logs -n "$operator_namespace" "$operator_pod" --since="$since"; then
   157	      failed=1
   158	    fi
   159	  else
   160	    write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found in namespace: $operator_namespace"
   161	  fi
   162	
   163	  toolbox_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-tools")"
   164	  if [[ -n "$toolbox_pod" ]]; then
   165	    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
   166	      "${ROOK_KUBECTL_ARGV[@]}" exec -n "$namespace" "$toolbox_pod" -- ceph status; then
   167	      failed=1
   168	    fi
   169	  else
   170	    write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
   171	  fi
   172	
   173	  [[ $failed -eq 0 ]] || return 2
   174	  return 0
   175	}
   176	
   177	if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
   178	  collect_cluster_rook "$@"
   179	fi

exec
/bin/zsh -lc "ls -la experiments/ceph-incident-bundle/tests && nl -ba experiments/ceph-incident-bundle/tests/run-tests.sh | sed -n '1,260p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
total 160
drwxr-xr-x@ 10 ikaros  staff    320 Jun 30 17:30 .
drwxr-xr-x@  9 ikaros  staff    288 Jul  1 00:25 ..
drwxr-xr-x@  4 ikaros  staff    128 Jun 30 00:40 fixtures
-rwxr-xr-x@  1 ikaros  staff   4495 Jun 30 00:40 run-tests.sh
-rwxr-xr-x@  1 ikaros  staff   7667 Jun 30 13:59 test-cephadm-collector.sh
-rwxr-xr-x@  1 ikaros  staff  20627 Jun 30 17:30 test-collect.sh
-rwxr-xr-x@  1 ikaros  staff  11325 Jun 30 10:45 test-common.sh
-rwxr-xr-x@  1 ikaros  staff   7225 Jun 30 23:18 test-node-collector.sh
-rwxr-xr-x@  1 ikaros  staff   8221 Jun 30 23:36 test-rook-collector.sh
-rwxr-xr-x@  1 ikaros  staff   6648 Jun 30 01:00 test-verify-bundle.sh
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
     5	
     6	fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
     7	ok() { printf 'ok: %s\n' "$*"; }
     8	
     9	run_and_capture() {
    10	  local output status
    11	  set +e
    12	  output="$("$@" 2>&1)"
    13	  status=$?
    14	  set -e
    15	  printf '%s\n%s' "$status" "$output"
    16	}
    17	
    18	for path in \
    19	  "$ROOT/run/collect.sh" \
    20	  "$ROOT/lib/common.sh" \
    21	  "$ROOT/lib/collect-cluster-cephadm.sh" \
    22	  "$ROOT/lib/collect-cluster-rook.sh" \
    23	  "$ROOT/lib/collect-node.sh" \
    24	  "$ROOT/lib/verify-bundle.sh" \
    25	  "$ROOT/tests/test-collect.sh" \
    26	  "$ROOT/tests/test-cephadm-collector.sh" \
    27	  "$ROOT/tests/test-node-collector.sh" \
    28	  "$ROOT/tests/test-rook-collector.sh" \
    29	  "$ROOT/tests/test-verify-bundle.sh"; do
    30	  [[ -f "$path" ]] || fail "missing $path"
    31	done
    32	
    33	for path in "$ROOT/run/collect.sh" "$ROOT/lib/verify-bundle.sh"; do
    34	  [[ -x "$path" ]] || fail "not executable $path"
    35	done
    36	
    37	collect_no_args="$(run_and_capture "$ROOT/run/collect.sh")"
    38	collect_no_args_status="${collect_no_args%%$'\n'*}"
    39	collect_no_args_output="${collect_no_args#*$'\n'}"
    40	[[ "$collect_no_args_status" == "1" ]] || fail "collect.sh no args should exit 1, got $collect_no_args_status"
    41	[[ "$collect_no_args_output" == *"Usage:"* ]] || fail "collect.sh no args should print usage"
    42	
    43	verify_no_args="$(run_and_capture "$ROOT/lib/verify-bundle.sh")"
    44	verify_no_args_status="${verify_no_args%%$'\n'*}"
    45	verify_no_args_output="${verify_no_args#*$'\n'}"
    46	[[ "$verify_no_args_status" == "1" ]] || fail "verify-bundle.sh no args should exit 1, got $verify_no_args_status"
    47	[[ "$verify_no_args_output" == *"Usage:"* ]] || fail "verify-bundle.sh no args should print usage"
    48	
    49	verify_placeholder_args="$(run_and_capture "$ROOT/lib/verify-bundle.sh" /tmp/definitely-not-a-bundle)"
    50	verify_placeholder_status="${verify_placeholder_args%%$'\n'*}"
    51	verify_placeholder_output="${verify_placeholder_args#*$'\n'}"
    52	[[ "$verify_placeholder_status" != "0" ]] || fail "verify-bundle.sh placeholder args should not exit 0"
    53	[[ "$verify_placeholder_output" == *"VERIFY FAIL:"* || "$verify_placeholder_output" == *"Usage:"* || "$verify_placeholder_output" == *"error"* ]] || fail "verify-bundle.sh placeholder args should explain failure"
    54	
    55	collect_placeholder_args="$(run_and_capture "$ROOT/run/collect.sh" --inventory /tmp/example.env --ssh-key /tmp/id_ed25519 --seed 192.168.18.166)"
    56	collect_placeholder_status="${collect_placeholder_args%%$'\n'*}"
    57	collect_placeholder_output="${collect_placeholder_args#*$'\n'}"
    58	[[ "$collect_placeholder_status" != "0" ]] || fail "collect.sh placeholder args should not exit 0"
    59	[[ "$collect_placeholder_output" == *"missing inventory"* || "$collect_placeholder_output" == *"Usage:"* || "$collect_placeholder_output" == *"error"* ]] || fail "collect.sh placeholder args should explain failure"
    60	
    61	common_helpers_args="$(run_and_capture "$ROOT/tests/test-common.sh")"
    62	common_helpers_status="${common_helpers_args%%$'\n'*}"
    63	common_helpers_output="${common_helpers_args#*$'\n'}"
    64	[[ "$common_helpers_status" == "0" ]] || fail "test-common.sh failed: $common_helpers_output"
    65	
    66	verify_bundle_args="$(run_and_capture "$ROOT/tests/test-verify-bundle.sh")"
    67	verify_bundle_status="${verify_bundle_args%%$'\n'*}"
    68	verify_bundle_output="${verify_bundle_args#*$'\n'}"
    69	[[ "$verify_bundle_status" == "0" ]] || fail "test-verify-bundle.sh failed: $verify_bundle_output"
    70	
    71	cephadm_collector_args="$(run_and_capture "$ROOT/tests/test-cephadm-collector.sh")"
    72	cephadm_collector_status="${cephadm_collector_args%%$'\n'*}"
    73	cephadm_collector_output="${cephadm_collector_args#*$'\n'}"
    74	[[ "$cephadm_collector_status" == "0" ]] || fail "test-cephadm-collector.sh failed: $cephadm_collector_output"
    75	
    76	node_collector_args="$(run_and_capture "$ROOT/tests/test-node-collector.sh")"
    77	node_collector_status="${node_collector_args%%$'\n'*}"
    78	node_collector_output="${node_collector_args#*$'\n'}"
    79	[[ "$node_collector_status" == "0" ]] || fail "test-node-collector.sh failed: $node_collector_output"
    80	
    81	rook_collector_args="$(run_and_capture "$ROOT/tests/test-rook-collector.sh")"
    82	rook_collector_status="${rook_collector_args%%$'\n'*}"
    83	rook_collector_output="${rook_collector_args#*$'\n'}"
    84	[[ "$rook_collector_status" == "0" ]] || fail "test-rook-collector.sh failed: $rook_collector_output"
    85	
    86	collect_args="$(run_and_capture "$ROOT/tests/test-collect.sh")"
    87	collect_status="${collect_args%%$'\n'*}"
    88	collect_output="${collect_args#*$'\n'}"
    89	[[ "$collect_status" == "0" ]] || fail "test-collect.sh failed: $collect_output"
    90	
    91	ok "required files exist"

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/run-tests.sh | sed -n '92,180p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
codex
No dead references showed up in the requested tool tree: the removed functions are absent, and the new helpers are called from the expected places. I’m going to compare the actual emitted SSH command strings against the old version now, not just eyeball the option list.
exec
/bin/zsh -lc "rg -n \"shellcheck|ceph-incident-bundle/tests/run-tests|test-ceph|experiments/ceph-incident-bundle\" Makefile scripts experiments/ceph-incident-bundle -g '"'!results/**'"'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/run/collect.sh:8:# shellcheck disable=SC1091
experiments/ceph-incident-bundle/run/collect.sh:10:# shellcheck disable=SC1091
experiments/ceph-incident-bundle/run/collect.sh:12:# shellcheck disable=SC1091
experiments/ceph-incident-bundle/run/collect.sh:14:# shellcheck disable=SC1091
experiments/ceph-incident-bundle/run/collect.sh:22:  bash experiments/ceph-incident-bundle/run/collect.sh \
experiments/ceph-incident-bundle/run/collect.sh:23:    --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
experiments/ceph-incident-bundle/run/collect.sh:34:  --out DIR              output dir (default: experiments/ceph-incident-bundle/results)
experiments/ceph-incident-bundle/run/collect.sh:64:  # shellcheck disable=SC2016
experiments/ceph-incident-bundle/run/collect.sh:272:  # shellcheck disable=SC2086
experiments/ceph-incident-bundle/run/collect.sh:409:  # shellcheck disable=SC1090
experiments/ceph-incident-bundle/README.md:33:bash experiments/ceph-incident-bundle/run/collect.sh \
experiments/ceph-incident-bundle/README.md:34:  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
experiments/ceph-incident-bundle/README.md:44:bundle: experiments/ceph-incident-bundle/results/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
experiments/ceph-incident-bundle/README.md:50:bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle.tar.gz>
experiments/ceph-incident-bundle/README.md:85:bash experiments/ceph-incident-bundle/run/collect.sh \
experiments/ceph-incident-bundle/README.md:86:  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
experiments/ceph-incident-bundle/README.md:105:bash experiments/ceph-incident-bundle/run/collect.sh \
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:7:# shellcheck disable=SC1091
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:175:    # shellcheck disable=SC2206
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:187:    # shellcheck disable=SC2206
experiments/ceph-incident-bundle/lib/collect-node.sh:7:# shellcheck disable=SC1091
experiments/ceph-incident-bundle/lib/collect-node.sh:111:    # shellcheck disable=SC2024
experiments/ceph-incident-bundle/lib/collect-node.sh:130:    # shellcheck disable=SC2024
experiments/ceph-incident-bundle/lib/collect-node.sh:156:    # shellcheck disable=SC2016
experiments/ceph-incident-bundle/lib/collect-node.sh:225:    # shellcheck disable=SC2016
experiments/ceph-incident-bundle/lib/collect-node.sh:331:    # shellcheck disable=SC2206
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:7:# shellcheck disable=SC1091
experiments/ceph-incident-bundle/tests/test-common.sh:14:# shellcheck disable=SC1091
experiments/ceph-incident-bundle/tests/test-common.sh:90:      # shellcheck disable=SC1091
experiments/ceph-incident-bundle/tests/test-common.sh:294:      # shellcheck disable=SC1091
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:24:# shellcheck disable=SC1091
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:26:# shellcheck disable=SC1091
experiments/ceph-incident-bundle/tests/run-tests.sh:26:  "$ROOT/tests/test-cephadm-collector.sh" \
experiments/ceph-incident-bundle/tests/run-tests.sh:71:cephadm_collector_args="$(run_and_capture "$ROOT/tests/test-cephadm-collector.sh")"
experiments/ceph-incident-bundle/tests/run-tests.sh:74:[[ "$cephadm_collector_status" == "0" ]] || fail "test-cephadm-collector.sh failed: $cephadm_collector_output"

exec
/bin/zsh -lc "git show b44aa8d:experiments/ceph-incident-bundle/run/collect.sh | nl -ba | sed -n '50,310p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-FQgiVz0G' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-d5YgVJ5f' (errno=Operation not permitted)
    50	EOF
    51	}
    52	
    53	parse_host_entry() {
    54	  local entry=$1
    55	  [[ "$entry" == *=* ]] || return 1
    56	  printf '%s\n' "${entry%%=*}" "${entry#*=}"
    57	}
    58	
    59	ssh_target_for_host() {
    60	  local host=$1 ssh_user=$2
    61	  if [[ "$host" == *@* || -z "$ssh_user" ]]; then
    62	    printf '%s' "$host"
    63	  else
    64	    printf '%s@%s' "$ssh_user" "$host"
    65	  fi
    66	}
    67	
    68	shell_quote() {
    69	  local value=$1
    70	  [[ "$value" != *"'"* ]] || return 1
    71	  printf "'%s'" "$value"
    72	}
    73	
    74	write_initial_metadata() {
    75	  local workdir=$1 mode=$2 seed=$3 since=$4 timeout=$5
    76	  local git_commit
    77	  git_commit="$(git -C "$COLLECT_ROOT/../.." rev-parse --short HEAD 2>/dev/null || printf unknown)"
    78	
    79	  cat >"$workdir/README-FIRST.txt" <<'EOF'
    80	Ceph incident bundle
    81	
    82	Start with:
    83	- summary.txt
    84	- errors.log
    85	- cluster/
    86	- nodes/
    87	
    88	This bundle is read-only evidence captured at incident time. Review it before sharing outside your team.
    89	EOF
    90	
    91	  cat >"$workdir/environment.txt" <<EOF
    92	created_utc=$(date -u +%FT%TZ)
    93	mode=$mode
    94	seed=$seed
    95	since=$since
    96	timeout=$timeout
    97	git_commit=$git_commit
    98	EOF
    99	
   100	  : >"$workdir/manifest.jsonl"
   101	  : >"$workdir/errors.log"
   102	}
   103	
   104	write_summary() {
   105	  local workdir=$1 mode=$2 seed=$3 node_ok=$4 node_failed=$5 cluster_status=$6 final_status=$7
   106	
   107	  {
   108	    printf 'Ceph incident bundle summary\n'
   109	    printf 'created_utc: %s\n' "$(date -u +%FT%TZ)"
   110	    printf 'mode: %s\n' "$mode"
   111	    printf 'seed: %s\n' "$seed"
   112	    printf 'cluster_status: %s\n' "$cluster_status"
   113	    printf 'node_ok: %s\n' "$node_ok"
   114	    printf 'node_failed: %s\n' "$node_failed"
   115	    printf 'final_status: %s\n' "$final_status"
   116	  } >"$workdir/summary.txt"
   117	}
   118	
   119	append_error() {
   120	  local workdir=$1 message=$2
   121	  printf '%s %s\n' "$(date -u +%FT%TZ)" "$message" >>"$workdir/errors.log"
   122	}
   123	
   124	detect_node_caps() {
   125	  # echo a space-joined subset of "cephadm kubectl" present on the target node.
   126	  # A probe that fails to ssh is NOT the same as "node has no caps" — record the
   127	  # ssh failure to ERROR_LOG so a silently-dropped cluster source is visible.
   128	  local target=$1 ssh_key=$2 timeout=$3
   129	  local tbin out rc
   130	  local -a ssh_cmd
   131	  # SC2016: the probe script is single-quoted on purpose — it expands on the remote.
   132	  # shellcheck disable=SC2016
   133	  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v ceph >/dev/null 2>&1 && caps="$caps ceph"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
   134	  tbin="$(timeout_cmd)"
   135	  if [[ -n "$tbin" ]]; then
   136	    ssh_cmd=("$tbin" "$timeout" "${ssh_cmd[@]}")
   137	  fi
   138	  out="$("${ssh_cmd[@]}" 2>/dev/null)"
   139	  rc=$?
   140	  if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
   141	    ensure_dir "$(dirname -- "$ERROR_LOG")"
   142	    printf '%s capability probe failed for %s (ssh exit %s) — node not considered as a cluster source\n' \
   143	      "$(date -u +%FT%TZ)" "$target" "$rc" >>"$ERROR_LOG"
   144	  fi
   145	  printf '%s' "$out"
   146	}
   147	
   148	# Does a given runner actually connect to the cluster on this node? "usable" is
   149	# defined as `ceph -s` succeeding, not merely the binary existing.
   150	ceph_runner_probe() {
   151	  local target=$1 ssh_key=$2 timeout=$3 method=$4
   152	  local tbin w
   153	  local -a pfx ssh_cmd
   154	  while IFS= read -r w; do pfx+=("$w"); done < <(ceph_runner_argv "$method")
   155	  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" "${pfx[@]}" --connect-timeout 5 -s)
   156	  tbin="$(timeout_cmd)"
   157	  [[ -n "$tbin" ]] && ssh_cmd=("$tbin" "$timeout" "${ssh_cmd[@]}")
   158	  "${ssh_cmd[@]}" >/dev/null 2>&1
   159	}
   160	
   161	# Pick the fastest runner that connects on $target: direct ceph, sudo ceph, then
   162	# cephadm shell. Echoes the runner token, or nothing if none connects.
   163	ceph_runner_for() {
   164	  local target=$1 ssh_key=$2 timeout=$3 m
   165	  for m in direct sudo cephadm; do
   166	    if ceph_runner_probe "$target" "$ssh_key" "$timeout" "$m"; then
   167	      printf '%s' "$m"
   168	      return 0
   169	    fi
   170	  done
   171	  return 0
   172	}
   173	
   174	# Probe each node once; pick cluster-ceph source (first cephadm node, or --seed)
   175	# and cluster-rook source (first kubectl node); collect each requested layer once.
   176	# Uses globals HOST_TARGETS (set by main).
   177	collect_clusters() {
   178	  local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8 kube_context=$9 kube_mode="${10:-remote}" rook_operator_namespace="${11:-}"
   179	  local ceph_source='' ceph_runner='' rook_source='' i caps rc=0
   180	  local want_ceph=0 want_rook=0 ceph_done=0 rook_done=0
   181	  # so detect_node_caps can record probe ssh failures
   182	  local ERROR_LOG="$workdir/errors.log"
   183	  case "$mode" in
   184	    cephadm) want_ceph=1 ;;
   185	    rook) want_rook=1 ;;
   186	    auto) want_ceph=1; want_rook=1 ;;
   187	    *) return 1 ;;
   188	  esac
   189	
   190	  # explicit --seed pins the cluster-ceph source; the runner is still chosen by
   191	  # connectivity (so direct ceph is preferred on the seed too).
   192	  if [[ $want_ceph -eq 1 && -n "$seed" ]]; then
   193	    ceph_source="$seed"
   194	    ceph_runner="$(ceph_runner_for "$seed" "$ssh_key" "$timeout")"
   195	  fi
   196	
   197	  # Only probe nodes for kubectl when the rook layer runs remotely.
   198	  local probe_rook=0
   199	  [[ $want_rook -eq 1 && "$kube_mode" == remote ]] && probe_rook=1
   200	
   201	  # probe nodes only if a source we need is still unknown
   202	  if { [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; } || [[ $probe_rook -eq 1 ]]; then
   203	    if [[ ${#HOST_TARGETS[@]} -gt 0 ]]; then
   204	      progress "probing ${#HOST_TARGETS[@]} nodes for capabilities…"
   205	      for i in "${!HOST_TARGETS[@]}"; do
   206	        caps="$(detect_node_caps "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
   207	        progress "[$((i + 1))/${#HOST_TARGETS[@]}] probe ${HOST_TARGETS[$i]}: ${caps:-none}"
   208	        # ceph source = first candidate (has ceph or cephadm binary) whose runner
   209	        # actually connects to the cluster.
   210	        if [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; then
   211	          case " $caps " in
   212	            *" ceph "*|*" cephadm "*)
   213	              ceph_runner="$(ceph_runner_for "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
   214	              [[ -n "$ceph_runner" ]] && ceph_source="${HOST_TARGETS[$i]}"
   215	              ;;
   216	          esac
   217	        fi
   218	        if [[ $probe_rook -eq 1 && -z "$rook_source" ]]; then
   219	          case " $caps " in *" kubectl "*) rook_source="${HOST_TARGETS[$i]}" ;; esac
   220	        fi
   221	        if { [[ $want_ceph -eq 0 || -n "$ceph_source" ]]; } && { [[ $probe_rook -eq 0 || -n "$rook_source" ]]; }; then
   222	          break
   223	        fi
   224	      done
   225	    fi
   226	  fi
   227	
   228	  # cluster-ceph layer
   229	  if [[ $want_ceph -eq 1 && -n "$ceph_source" ]]; then
   230	    progress "collecting ceph cluster from $ceph_source via ${ceph_runner:-cephadm}…"
   231	    collect_cluster_cephadm "$workdir" "$manifest" "$ceph_source" "$ssh_key" "$since" "$timeout" "${ceph_runner:-cephadm}" || rc=2
   232	    ceph_done=1
   233	  fi
   234	
   235	  # cluster-rook layer: local (this jump host) or remote (on a kubectl node)
   236	  if [[ $want_rook -eq 1 && ( "$kube_mode" == local || -n "$rook_source" ) ]]; then
   237	    local -a rook_args
   238	    rook_args=(--out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout")
   239	    [[ -n "$rook_operator_namespace" ]] && rook_args+=(--operator-namespace "$rook_operator_namespace")
   240	    if [[ "$kube_mode" == local ]]; then
   241	      rook_source=local
   242	      progress "collecting rook from local kubectl (ns=$rook_namespace)…"
   243	    else
   244	      rook_args+=(--ssh-target "$rook_source" --ssh-key "$ssh_key")
   245	      progress "collecting rook from $rook_source (ns=$rook_namespace)…"
   246	    fi
   247	    [[ -n "$kube_context" ]] && rook_args+=(--kube-context "$kube_context")
   248	    [[ "$mode" == auto ]] && rook_args+=(--allow-skip)
   249	    collect_cluster_rook "${rook_args[@]}" || rc=2
   250	    # "done" means real rook evidence was collected — NOT just an --allow-skip
   251	    # (e.g. namespace missing) which returns 0 but only writes SKIPPED.txt.
   252	    [[ -f "$workdir/cluster/rook/pods-wide.txt" ]] && rook_done=1
   253	  fi
   254	
   255	  # missing-source handling
   256	  # When a layer wasn't collected, leave a SKIPPED.txt — but never clobber a more
   257	  # specific reason the collector already wrote (e.g. "namespace not found").
   258	  if [[ "$mode" == cephadm && $ceph_done -eq 0 ]]; then
   259	    ensure_dir "$workdir/cluster/ceph"
   260	    [[ -f "$workdir/cluster/ceph/SKIPPED.txt" ]] || printf 'SKIPPED: no cephadm-capable node found (or --seed unreachable)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
   261	    rc=2
   262	  elif [[ "$mode" == rook && $rook_done -eq 0 ]]; then
   263	    ensure_dir "$workdir/cluster/rook"
   264	    [[ -f "$workdir/cluster/rook/SKIPPED.txt" ]] || printf 'SKIPPED: no kubectl-capable node found\n' >"$workdir/cluster/rook/SKIPPED.txt"
   265	    rc=2
   266	  elif [[ "$mode" == auto ]]; then
   267	    # auto = collect whatever exists; only a hard failure if NEITHER layer found
   268	    if [[ $ceph_done -eq 0 ]]; then
   269	      ensure_dir "$workdir/cluster/ceph"
   270	      [[ -f "$workdir/cluster/ceph/SKIPPED.txt" ]] || printf 'SKIPPED: no cephadm-capable node in inventory (auto)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
   271	    fi
   272	    if [[ $rook_done -eq 0 ]]; then
   273	      ensure_dir "$workdir/cluster/rook"
   274	      [[ -f "$workdir/cluster/rook/SKIPPED.txt" ]] || printf 'SKIPPED: no kubectl-capable node in inventory (auto)\n' >"$workdir/cluster/rook/SKIPPED.txt"
   275	    fi
   276	    if [[ $ceph_done -eq 0 && $rook_done -eq 0 ]]; then
   277	      rc=2
   278	    fi
   279	  fi
   280	
   281	  # Record which node each cluster layer was collected from (observability:
   282	  # "which host did we trust for ceph status?").
   283	  {
   284	    printf 'ceph_source=%s\n' "${ceph_source:-<none>}"
   285	    printf 'ceph_runner=%s\n' "${ceph_runner:-<none>}"
   286	    printf 'rook_source=%s\n' "${rook_source:-<none>}"
   287	  } >>"$workdir/environment.txt"
   288	
   289	  return "$rc"
   290	}
   291	
   292	collect_remote_node() {
   293	  local workdir=$1 alias=$2 target=$3 ssh_key=$4 since=$5 timeout=$6 skip_logs=$7 node_timeout=$8
   294	  local node_dir="$workdir/nodes/$alias"
   295	  local node_tar="$workdir/.node-$alias.tar.gz"
   296	  local remote_cmd rc=0 tbin
   297	  local q_alias q_since q_timeout
   298	  local -a ssh_cmd
   299	
   300	  q_alias="$(shell_quote "$alias")" || return 1
   301	  q_since="$(shell_quote "$since")" || return 1
   302	  q_timeout="$(shell_quote "$timeout")" || return 1
   303	
   304	  # Remote side uses a gzip pipe (not `tar -z`) so minimal/BusyBox tar still works,
   305	  # and traps its own temp dir so an interrupted/timed-out run leaves nothing behind.
   306	  remote_cmd="set -u; tmp=\"\${TMPDIR:-/tmp}/ceph-incident-node.\$\$\"; rm -rf \"\$tmp\"; mkdir -p \"\$tmp\" || { printf 'SKIPPED: remote tmp not writable\n' >&2; exit 75; }; trap 'rm -rf \"\$tmp\"' EXIT INT TERM; gzip -dc | tar -xf - -C \"\$tmp\"; out=\"\$tmp/out\"; set +e; bash \"\$tmp/lib/collect-node.sh\" --out \"\$out\" --host-alias $q_alias --since $q_since --timeout $q_timeout"
   307	  if [[ "$skip_logs" == "1" ]]; then
   308	    remote_cmd+=" --skip-logs"
   309	  fi
   310	  remote_cmd+="; rc=\$?; set -e; if [ -d \"\$out\" ]; then tar -cf - -C \"\$out\" . | gzip -c; else mkdir -p \"\$out\"; printf 'SKIPPED: remote collect-node did not create output\n' >\"\$out/SKIPPED.txt\"; tar -cf - -C \"\$out\" . | gzip -c; fi; exit \"\$rc\""

exec
/bin/zsh -lc "git show b44aa8d:experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh | nl -ba | sed -n '1,70p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-lJ1m0Bsc' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-5UYUnZ9x' (errno=Operation not permitted)
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	# Cephadm collection helpers live here.
     5	
     6	CEPHADM_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
     7	# shellcheck disable=SC1091
     8	source "$CEPHADM_COLLECTOR_DIR/common.sh"
     9	
    10	# The remote prefix that actually runs ceph on the source node, by runner token:
    11	#   direct  -> ceph                          (fast: no container per command)
    12	#   sudo    -> sudo -n ceph
    13	#   cephadm -> sudo -n cephadm shell -- ceph (default; spins a container each call)
    14	ceph_runner_argv() {
    15	  case "$1" in
    16	    direct) printf '%s\n' ceph ;;
    17	    sudo) printf '%s\n' sudo -n ceph ;;
    18	    *) printf '%s\n' sudo -n cephadm shell -- ceph ;;
    19	  esac
    20	}
    21	
    22	collect_cephadm_command() {
    23	  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 runner=$6 artifact=$7
    24	  shift 7
    25	
    26	  local artifact_dir
    27	  artifact_dir="$(dirname -- "$artifact")"
    28	  ensure_dir "$artifact_dir"
    29	
    30	  local -a runner_argv
    31	  while IFS= read -r _w; do runner_argv+=("$_w"); done < <(ceph_runner_argv "$runner")
    32	
    33	  COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
    34	    run_capture "$manifest" "$seed" "collect-cluster-cephadm" "$artifact" -- \
    35	    ssh \
    36	      -i "$ssh_key" \
    37	      -o BatchMode=yes \
    38	      -o IdentitiesOnly=yes \
    39	      -o IdentityAgent=none \
    40	      -o "ConnectTimeout=$timeout" \
    41	      -o "ServerAliveInterval=$timeout" \
    42	      -o ServerAliveCountMax=1 \
    43	      "$seed" \
    44	      "${runner_argv[@]}" "$@"
    45	}
    46	
    47	write_cephadm_crash_skip() {
    48	  local skip_artifact=$1
    49	  ensure_dir "$(dirname -- "$skip_artifact")"
    50	  cat >"$skip_artifact" <<'EOF'
    51	SKIPPED: unable to parse crash list JSON for recent crash inspection
    52	EOF
    53	}
    54	
    55	extract_cephadm_crash_ids() {
    56	  local crash_ls_artifact=$1
    57	  local payload compact ids
    58	
    59	  [[ -f "$crash_ls_artifact" ]] || return 1
    60	  payload="$(sed '/^[[:space:]]*#/d' "$crash_ls_artifact")" || return 1
    61	
    62	  # Anchor strictly to crash_id; matching id/name too would capture unrelated
    63	  # nested fields and feed bogus ids back into `ceph crash info`.
    64	  ids="$(
    65	    printf '%s\n' "$payload" |
    66	      grep -oE '"crash_id"[[:space:]]*:[[:space:]]*"[^"]*"' |
    67	      sed -E 's/^"crash_id"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/' |
    68	      head -n 10
    69	  )" || true
    70	

exec
/bin/zsh -lc "git show b44aa8d:experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh | nl -ba | sed -n '100,130p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-FYOtUg07' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-XV0OHmLt' (errno=Operation not permitted)
   100	        ;;
   101	      --help|-h)
   102	        usage
   103	        return 0
   104	        ;;
   105	      *)
   106	        usage >&2
   107	        return 1
   108	        ;;
   109	    esac
   110	  done
   111	
   112	  [[ -n "$outdir" && -n "$manifest" ]] || {
   113	    usage >&2
   114	    return 1
   115	  }
   116	
   117	  ensure_dir "$outdir/cluster/rook"
   118	  [[ -n "$operator_namespace" ]] || operator_namespace="$namespace"
   119	
   120	  # Build the kubectl prefix once. With --ssh-target, kubectl runs ON that node
   121	  # over ssh (the node where kubectl/kubeconfig lives); otherwise locally.
   122	  # ROOK_KUBECTL_ARGV is global so rook_get_first_pod can use the same prefix.
   123	  if [[ -n "$ssh_target" ]]; then
   124	    ROOK_KUBECTL_ARGV=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$ssh_target" kubectl)
   125	  else
   126	    ROOK_KUBECTL_ARGV=(kubectl)
   127	  fi
   128	  [[ -n "$kube_context" ]] && ROOK_KUBECTL_ARGV+=(--context "$kube_context")
   129	
   130	  # Missing kubectl / namespace means we collected NO cluster evidence. In

exec
/bin/zsh -lc "git show b44aa8d:experiments/ceph-incident-bundle/run/collect.sh | nl -ba | sed -n '310,380p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-zunsNtRE' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-1Yp9UayT' (errno=Operation not permitted)
   310	  remote_cmd+="; rc=\$?; set -e; if [ -d \"\$out\" ]; then tar -cf - -C \"\$out\" . | gzip -c; else mkdir -p \"\$out\"; printf 'SKIPPED: remote collect-node did not create output\n' >\"\$out/SKIPPED.txt\"; tar -cf - -C \"\$out\" . | gzip -c; fi; exit \"\$rc\""
   311	
   312	  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" "$remote_cmd")
   313	  tbin="$(timeout_cmd)"
   314	  if [[ -n "$tbin" ]]; then
   315	    # Outer wrapper bounds the WHOLE node collection — must be the generous
   316	    # node timeout, never the small per-command timeout (which would kill a
   317	    # slow/large node mid-collection).
   318	    ssh_cmd=("$tbin" "$node_timeout" "${ssh_cmd[@]}")
   319	  fi
   320	
   321	  # macOS bsdtar embeds com.apple.* xattr headers that make the remote GNU tar
   322	  # print "Ignoring unknown extended header keyword" noise; strip them at source.
   323	  local noxattrs=''
   324	  if tar --version 2>&1 | grep -qi 'bsdtar'; then
   325	    noxattrs='--no-xattrs'
   326	  fi
   327	
   328	  set +e
   329	  # shellcheck disable=SC2086
   330	  COPYFILE_DISABLE=1 tar $noxattrs -cf - -C "$COLLECT_ROOT" lib/common.sh lib/collect-node.sh | gzip -c |
   331	    "${ssh_cmd[@]}" >"$node_tar"
   332	  rc=$?
   333	  set -e
   334	
   335	  ensure_dir "$node_dir"
   336	  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
   337	    printf 'SKIPPED: node collection timed out after %ss (exit %s) from %s\n' "$node_timeout" "$rc" "$target" >"$node_dir/SKIPPED.txt"
   338	    rm -f "$node_tar"
   339	    return 2
   340	  fi
   341	
   342	  if [[ -s "$node_tar" ]] && tar -xzf "$node_tar" -C "$node_dir" >/dev/null 2>/dev/null; then
   343	    # A node that streamed a valid archive but is missing its own manifest.jsonl
   344	    # was truncated (partial/interrupted transfer) — do not count it as ok.
   345	    if [[ ! -f "$node_dir/manifest.jsonl" ]]; then
   346	      printf 'SKIPPED: node archive from %s is incomplete (no manifest.jsonl); treated as failure\n' "$target" >"$node_dir/SKIPPED.txt"
   347	      rc=2
   348	    fi
   349	  else
   350	    rm -rf "$node_dir"
   351	    ensure_dir "$node_dir"
   352	    printf 'SKIPPED: no usable node archive returned from %s (ssh exit %s)\n' "$target" "$rc" >"$node_dir/SKIPPED.txt"
   353	    [[ $rc -ne 0 ]] || rc=2
   354	  fi
   355	  rm -f "$node_tar"
   356	
   357	  return "$rc"
   358	}
   359	
   360	redact_bundle_text() {
   361	  local workdir=$1
   362	  local redaction_log="$workdir/redactions.log"
   363	  local path
   364	
   365	  while IFS= read -r path; do
   366	    case "$path" in
   367	      *.gz) redact_gz_file "$path" "$redaction_log" ;;
   368	      *) redact_file "$path" "$redaction_log" ;;
   369	    esac
   370	  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' -o -name '*.gz' \) -print 2>/dev/null || true)
   371	}
   372	
   373	# Single cleanup point. Uses globals (not main's locals) so it works as an
   374	# EXIT trap, which fires after main has returned and its locals are gone.
   375	CLEANUP_WORKDIR=
   376	CLEANUP_KEEP=0
   377	# Parsed inventory (alias/target pairs); filled by main, read by collect_clusters + node loop.
   378	HOST_ALIASES=()
   379	HOST_TARGETS=()
   380	cleanup_workdir() {

codex
The old and new SSH option order is byte-for-byte equivalent at the call sites I checked: `ssh`, `-i key`, each `-o ...`, target, then remote command/prefix. I’m doing a syntax/shellcheck/test attempt now; if the sandbox blocks writable temp usage I’ll separate that from review findings.
exec
/bin/zsh -lc 'bash -n experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/common.sh experiments/ceph-incident-bundle/lib/bundle.sh experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh experiments/ceph-incident-bundle/lib/collect-node.sh' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
exec
/bin/zsh -lc 'command -v shellcheck && shellcheck experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/common.sh experiments/ceph-incident-bundle/lib/bundle.sh experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh experiments/ceph-incident-bundle/lib/collect-node.sh' in /Users/ikaros/Documents/code/learning-k8s
exec
/bin/zsh -lc 'bash experiments/ceph-incident-bundle/tests/run-tests.sh' in /Users/ikaros/Documents/code/learning-k8s
 exited 1 in 0ms:
FAIL: collect.sh no args should print usage

 succeeded in 1596ms:
exec
/bin/zsh -lc "set +e; experiments/ceph-incident-bundle/run/collect.sh 2>&1; printf '\\nstatus=%s\\n' "'$?' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/run/collect.sh: line 18: cannot create temp file for here document: Operation not permitted

status=1

codex
The test harness did not run in this managed read-only sandbox because zsh/bash cannot create here-doc temp files under `/tmp`; that failure happens before the script’s usage text is emitted. `bash -n` and `shellcheck` on the changed files both exited 0.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-collect.sh | sed -n '1,260p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
     5	
     6	fail() {
     7	  printf 'FAIL: %s\n' "$*" >&2
     8	  exit 1
     9	}
    10	
    11	run_and_capture() {
    12	  local output status
    13	  set +e
    14	  output="$("$@" 2>&1)"
    15	  status=$?
    16	  set -e
    17	  printf '%s\n%s' "$status" "$output"
    18	}
    19	
    20	find_bundle() {
    21	  local outdir=$1 bundle
    22	  bundle="$(find "$outdir" -maxdepth 1 -name 'ceph-incident-*.tar.gz' -print -quit)"
    23	  [[ -n "$bundle" ]] || fail "missing generated bundle in $outdir"
    24	  printf '%s' "$bundle"
    25	}
    26	
    27	assert_archive_contains() {
    28	  local bundle=$1 expected=$2
    29	  tar -tzf "$bundle" | sed 's#^\./##' | grep -qF "$expected" || fail "archive missing $expected"
    30	}
    31	
    32	tmpdir="$(mktemp -d)"
    33	trap 'rm -rf "$tmpdir"' EXIT
    34	
    35	# ---------------------------------------------------------------------------
    36	# usage / arg validation
    37	# ---------------------------------------------------------------------------
    38	help_result="$(run_and_capture "$ROOT/run/collect.sh" --help)"
    39	help_status="${help_result%%$'\n'*}"
    40	help_output="${help_result#*$'\n'}"
    41	[[ "$help_status" == "0" ]] || fail "collect.sh --help exited $help_status"
    42	[[ "$help_output" == *"Usage:"* ]] || fail "collect.sh --help did not print usage"
    43	[[ "$help_output" == *"--kube-context"* ]] || fail "help should document --kube-context"
    44	
    45	missing_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$tmpdir/missing.env")"
    46	missing_status="${missing_result%%$'\n'*}"
    47	[[ "$missing_status" == "1" ]] || fail "missing inventory should exit 1, got $missing_status"
    48	
    49	# ---------------------------------------------------------------------------
    50	# fake bins: capability-aware ssh, fake kubectl, passthrough timeout
    51	#   ssh dispatches by the remote command:
    52	#     - "command -v cephadm" (capability probe) -> emit caps based on target
    53	#     - "cephadm shell -- ceph"                 -> delegate to the ceph fixture ssh
    54	#     - "kubectl"                               -> forward to the fake kubectl
    55	#     - "collect-node.sh"                       -> fabricate a node bundle tar
    56	#   Caps per target come from FAKE_CEPH_TARGETS / FAKE_KUBE_TARGETS (substrings).
    57	# ---------------------------------------------------------------------------
    58	fakebin="$tmpdir/fakebin"
    59	mkdir -p "$fakebin"
    60	
    61	cat >"$fakebin/kubectl" <<'EOF'
    62	#!/usr/bin/env bash
    63	set -euo pipefail
    64	[[ "${1:-}" == "--context" ]] && shift 2
    65	cmd="$*"
    66	case "$cmd" in
    67	  "get namespace rook-ceph") [[ "${FAKE_KUBE_NS_MISSING:-}" == "1" ]] && exit 1; printf 'rook-ceph\n' ;;
    68	  "get pods -n rook-ceph -o wide") printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n' ;;
    69	  "get events -n rook-ceph --sort-by=.lastTimestamp") printf 'LAST SEEN TYPE\n1m Normal\n' ;;
    70	  *"-n rook-ceph -o yaml") printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n' ;;
    71	  "get pods -n rook-ceph -l app=rook-ceph-operator -o name") printf 'pod/rook-ceph-operator-0\n' ;;
    72	  "logs -n rook-ceph rook-ceph-operator-0 --since="*) printf 'operator log line\n' ;;
    73	  "get pods -n rook-ceph -l app=rook-ceph-tools -o name") exit 0 ;;
    74	  *) printf 'unexpected kubectl: %s\n' "$cmd" >&2; exit 99 ;;
    75	esac
    76	EOF
    77	
    78	cat >"$fakebin/timeout" <<'EOF'
    79	#!/usr/bin/env bash
    80	printf '%s\n' "$1" >>"${FAKE_TIMEOUT_LOG:?}"
    81	shift
    82	exec "$@"
    83	EOF
    84	
    85	cat >"$fakebin/ssh" <<'EOF'
    86	#!/usr/bin/env bash
    87	set -euo pipefail
    88	printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
    89	whole="$*"
    90	args=("$@")
    91	n=${#args[@]}
    92	
    93	# target = first arg after the -i KEY / -o OPT option pairs
    94	target=''; j=0
    95	while [[ $j -lt $n ]]; do
    96	  case "${args[$j]}" in
    97	    -i|-o) j=$((j + 2)) ;;
    98	    *) target="${args[$j]}"; break ;;
    99	  esac
   100	done
   101	
   102	# Order matters: the capability-probe script also contains "kubectl", and the
   103	# runner connectivity probe ("--connect-timeout 5 -s") must be matched before the
   104	# generic ceph/cephadm command branches.
   105	case "$whole" in
   106	  *"--connect-timeout 5 -s"*)
   107	    # ceph runner connectivity probe; succeed per method+target env
   108	    case "$whole" in
   109	      *"cephadm shell"*) method=cephadm ;;
   110	      *"sudo -n ceph"*) method=sudo ;;
   111	      *) method=direct ;;
   112	    esac
   113	    ok=0
   114	    case "$method" in
   115	      direct) for t in ${FAKE_CEPH_DIRECT_OK:-}; do [[ "$target" == *"$t"* ]] && ok=1; done ;;
   116	      sudo) for t in ${FAKE_CEPH_SUDO_OK:-}; do [[ "$target" == *"$t"* ]] && ok=1; done ;;
   117	      cephadm) for t in ${FAKE_CEPHADM_OK:-${FAKE_CEPH_TARGETS:-}}; do [[ "$target" == *"$t"* ]] && ok=1; done ;;
   118	    esac
   119	    exit $(( ok == 1 ? 0 : 1 ))
   120	    ;;
   121	  *"command -v cephadm"*)
   122	    for t in ${FAKE_PROBE_FAIL_TARGETS:-}; do [[ "$target" == *"$t"* ]] && exit 255; done
   123	    caps=""
   124	    for t in ${FAKE_CEPH_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps cephadm"; done
   125	    for t in ${FAKE_CEPH_BIN_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps ceph"; done
   126	    for t in ${FAKE_KUBE_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps kubectl"; done
   127	    printf '%s\n' "$caps"
   128	    exit 0
   129	    ;;
   130	  *"cephadm shell -- ceph"*)
   131	    exec "$FIXTURE_SSH" "$@"
   132	    ;;
   133	  *collect-node.sh*)
   134	    alias_name="$(printf '%s\n' "$whole" | sed -n "s/.*--host-alias '\\([^']*\\)'.*/\\1/p")"
   135	    cat >/dev/null
   136	    [[ -n "$alias_name" ]] || { printf 'no alias\n' >&2; exit 99; }
   137	    if [[ "${FAKE_SSH_BAD_TAR_ALIAS:-}" == "$alias_name" ]]; then
   138	      printf 'not a tar archive\n'; exit 0
   139	    fi
   140	    sleep "${FAKE_SSH_SLEEP:-0}"
   141	    t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
   142	    mkdir -p "$t/system"
   143	    printf 'node %s\n' "$alias_name" >"$t/system/hostname.txt"
   144	    if [[ "${FAKE_SSH_NO_MANIFEST_ALIAS:-}" != "$alias_name" ]]; then
   145	      printf '{"node":"%s"}\n' "$alias_name" >"$t/manifest.jsonl"
   146	    fi
   147	    [[ "${FAKE_SSH_PEM_ALIAS:-}" == "$alias_name" ]] && printf 'cert\n' >"$t/system/leak.pem"
   148	    tar -czf - -C "$t" .
   149	    [[ "${FAKE_SSH_FAIL_ALIAS:-}" == "$alias_name" ]] && exit 2
   150	    exit 0
   151	    ;;
   152	  *kubectl*)
   153	    seen=0; kargs=()
   154	    for a in "$@"; do
   155	      if [[ $seen -eq 1 ]]; then kargs+=("$a"); continue; fi
   156	      [[ "$a" == "kubectl" ]] && seen=1
   157	    done
   158	    exec kubectl "${kargs[@]}"
   159	    ;;
   160	  *" ceph "*)
   161	    # direct/sudo `ceph <args>` cluster commands — same responses as cephadm shell
   162	    exec "$FIXTURE_SSH" "$@"
   163	    ;;
   164	  *)
   165	    printf 'unexpected ssh remote: %s\n' "$whole" >&2
   166	    exit 99
   167	    ;;
   168	esac
   169	EOF
   170	chmod +x "$fakebin/kubectl" "$fakebin/ssh" "$fakebin/timeout"
   171	
   172	ssh_key="$tmpdir/id_ed25519"
   173	printf 'fake key\n' >"$ssh_key"
   174	export FAKE_SSH_LOG="$tmpdir/ssh.log"
   175	export FAKE_TIMEOUT_LOG="$tmpdir/timeout.log"
   176	export FIXTURE_SSH="$ROOT/tests/fixtures/bin/ssh"
   177	
   178	# external topology: a ceph node + a kube node
   179	inventory="$tmpdir/inv-external.env"
   180	cat >"$inventory" <<'EOF'
   181	SSH_USER="tester"
   182	ROOK_NAMESPACE="rook-ceph"
   183	HOSTS=(
   184	  "cephnode=10.0.0.1"
   185	  "kubenode=10.0.0.9"
   186	)
   187	EOF
   188	
   189	# ---------------------------------------------------------------------------
   190	# auto: dual-layer collection (ceph from cephnode, rook from kubenode), --context
   191	# ---------------------------------------------------------------------------
   192	out_auto="$tmpdir/out-auto"
   193	: >"$FAKE_SSH_LOG"
   194	FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="10.0.0.9" \
   195	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   196	  --inventory "$inventory" --ssh-key "$ssh_key" \
   197	  --mode auto --kube-context lab --out "$out_auto" --since 24h --timeout 5 --node-timeout 90
   198	bundle_auto="$(find_bundle "$out_auto")"
   199	assert_archive_contains "$bundle_auto" "cluster/ceph/json/status.json"
   200	assert_archive_contains "$bundle_auto" "cluster/rook/pods-wide.txt"
   201	assert_archive_contains "$bundle_auto" "nodes/cephnode/system/hostname.txt"
   202	assert_archive_contains "$bundle_auto" "nodes/kubenode/system/hostname.txt"
   203	grep -qF -- '--context lab' "$FAKE_SSH_LOG" || fail "rook kubectl missing --context in auto mode"
   204	grep -qF '10.0.0.9 kubectl' "$FAKE_SSH_LOG" || fail "rook kubectl did not run on the kube node"
   205	grep -qx '90' "$FAKE_TIMEOUT_LOG" || fail "node wrapper should use --node-timeout 90"
   206	# A4: the chosen cluster sources are recorded in environment.txt
   207	env_txt="$(tar -xOzf "$bundle_auto" ./environment.txt 2>/dev/null)"
   208	[[ "$env_txt" == *"ceph_source=tester@10.0.0.1"* ]] || fail "environment.txt missing ceph_source"
   209	[[ "$env_txt" == *"rook_source=tester@10.0.0.9"* ]] || fail "environment.txt missing rook_source"
   210	
   211	# ---------------------------------------------------------------------------
   212	# auto with NO capable nodes: both layers SKIPPED, nodes still collected, exit 2
   213	# ---------------------------------------------------------------------------
   214	out_nocap="$tmpdir/out-nocap"
   215	nocap_status=0
   216	set +e
   217	FAKE_CEPH_TARGETS="" FAKE_KUBE_TARGETS="" \
   218	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   219	  --inventory "$inventory" --ssh-key "$ssh_key" \
   220	  --mode auto --out "$out_nocap" --since 24h --timeout 5
   221	nocap_status=$?
   222	set -e
   223	[[ "$nocap_status" == "2" ]] || fail "auto with no capable node should exit 2, got $nocap_status"
   224	bundle_nocap="$(find_bundle "$out_nocap")"
   225	assert_archive_contains "$bundle_nocap" "cluster/ceph/SKIPPED.txt"
   226	assert_archive_contains "$bundle_nocap" "cluster/rook/SKIPPED.txt"
   227	assert_archive_contains "$bundle_nocap" "nodes/cephnode/system/hostname.txt"
   228	
   229	# ---------------------------------------------------------------------------
   230	# explicit --mode cephadm --seed: only ceph layer, no kubectl probing/collection
   231	# ---------------------------------------------------------------------------
   232	out_ceph="$tmpdir/out-ceph"
   233	: >"$FAKE_SSH_LOG"
   234	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   235	  --inventory "$inventory" --ssh-key "$ssh_key" \
   236	  --seed tester@10.0.0.1 --mode cephadm --out "$out_ceph" --since 24h --timeout 5
   237	bundle_ceph="$(find_bundle "$out_ceph")"
   238	assert_archive_contains "$bundle_ceph" "cluster/ceph/json/status.json"
   239	grep -qF 'kubectl' "$FAKE_SSH_LOG" && fail "cephadm mode should not run kubectl" || true
   240	
   241	# ---------------------------------------------------------------------------
   242	# two cephadm nodes: cluster ceph collected from the FIRST only
   243	# ---------------------------------------------------------------------------
   244	inv_two="$tmpdir/inv-two-ceph.env"
   245	cat >"$inv_two" <<'EOF'
   246	SSH_USER="tester"
   247	HOSTS=(
   248	  "c1=10.0.0.1"
   249	  "c2=10.0.0.2"
   250	)
   251	EOF
   252	out_two="$tmpdir/out-two"
   253	: >"$FAKE_SSH_LOG"
   254	FAKE_CEPH_TARGETS="10.0.0.1 10.0.0.2" FAKE_KUBE_TARGETS="" \
   255	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   256	  --inventory "$inv_two" --ssh-key "$ssh_key" \
   257	  --mode auto --out "$out_two" --since 24h --timeout 5
   258	grep -qF '10.0.0.1 sudo -n cephadm shell -- ceph status --format json-pretty' "$FAKE_SSH_LOG" \
   259	  || fail "cluster ceph should be collected from first cephadm node"
   260	grep -qF '10.0.0.2 sudo -n cephadm shell -- ceph status' "$FAKE_SSH_LOG" \

exec
/bin/zsh -lc 'rg -n "ssh-log|ssh log|BatchMode|IdentitiesOnly|IdentityAgent|ConnectTimeout|ServerAlive|cephadm shell|kubectl|bundle:" experiments/ceph-incident-bundle/tests' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:38:out_no_kubectl="$tmpdir/out-no-kubectl"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:39:manifest_no_kubectl="$tmpdir/manifest-no-kubectl.jsonl"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:40:no_kubectl_rc=0
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:43:  --out "$out_no_kubectl" \
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:44:  --manifest "$manifest_no_kubectl" \
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:48:no_kubectl_rc=$?
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:50:# R4: explicit rook mode with no kubectl is a real failure (not a silent success)
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:51:[[ "$no_kubectl_rc" == "2" ]] || fail "explicit rook with no kubectl should exit 2, got $no_kubectl_rc"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:52:assert_file_contains "$out_no_kubectl/cluster/rook/SKIPPED.txt" "kubectl command not found"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:55:out_no_kubectl_skip="$tmpdir/out-no-kubectl-skip"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:56:manifest_no_kubectl_skip="$tmpdir/manifest-no-kubectl-skip.jsonl"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:60:  --out "$out_no_kubectl_skip" \
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:61:  --manifest "$manifest_no_kubectl_skip" \
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:68:[[ "$allow_skip_rc" == "0" ]] || fail "rook with --allow-skip and no kubectl should exit 0, got $allow_skip_rc"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:69:assert_file_contains "$out_no_kubectl_skip/cluster/rook/SKIPPED.txt" "kubectl command not found"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:73:cat >"$fakebin/kubectl" <<'EOF'
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:127:    printf 'unexpected kubectl command: %s\n' "$cmd" >&2
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:132:chmod +x "$fakebin/kubectl"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:134:export FAKE_KUBECTL_LOG="$tmpdir/kubectl.log"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:171:# --- remote (ssh-target) mode: kubectl runs via ssh on the chosen node, with --context ---
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:177:# argv: -i key <opts...> target kubectl <kubectl args...>; forward everything after 'kubectl'
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:182:  [[ "$a" == "kubectl" ]] && seen=1
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:184:exec kubectl "${argv[@]}"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:199:grep -qF -- '--context lab' "$fake_ssh_log" || fail "remote kubectl missing --context"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:200:grep -qF 'tester@node2 kubectl' "$fake_ssh_log" || fail "kubectl did not run via ssh on the target node"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:82:  grep -qF 'sudo -n cephadm shell -- ceph status --format json-pretty' "$ssh_log" || fail "ssh log missing cephadm shell invocation"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:83:  grep -qF 'sudo -n cephadm shell -- ceph status' "$ssh_log" || fail "ssh log missing text status invocation"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:84:  grep -qF 'sudo -n cephadm shell -- ceph crash info crash-10' "$ssh_log" || fail "ssh log missing 10th crash info invocation"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:86:  grep -qF 'ConnectTimeout=30' "$ssh_log" || fail "cluster ssh missing ConnectTimeout"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:87:  grep -qF 'ServerAliveInterval=30' "$ssh_log" || fail "cluster ssh missing ServerAliveInterval"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:142:  if grep -qF 'cephadm shell' "$ssh_log"; then
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:143:    fail "direct runner must NOT use cephadm shell"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:161:  if grep -qF 'cephadm shell' "$ssh_log"; then
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:162:    fail "sudo runner must NOT use cephadm shell"
experiments/ceph-incident-bundle/tests/test-collect.sh:50:# fake bins: capability-aware ssh, fake kubectl, passthrough timeout
experiments/ceph-incident-bundle/tests/test-collect.sh:53:#     - "cephadm shell -- ceph"                 -> delegate to the ceph fixture ssh
experiments/ceph-incident-bundle/tests/test-collect.sh:54:#     - "kubectl"                               -> forward to the fake kubectl
experiments/ceph-incident-bundle/tests/test-collect.sh:61:cat >"$fakebin/kubectl" <<'EOF'
experiments/ceph-incident-bundle/tests/test-collect.sh:74:  *) printf 'unexpected kubectl: %s\n' "$cmd" >&2; exit 99 ;;
experiments/ceph-incident-bundle/tests/test-collect.sh:102:# Order matters: the capability-probe script also contains "kubectl", and the
experiments/ceph-incident-bundle/tests/test-collect.sh:109:      *"cephadm shell"*) method=cephadm ;;
experiments/ceph-incident-bundle/tests/test-collect.sh:126:    for t in ${FAKE_KUBE_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps kubectl"; done
experiments/ceph-incident-bundle/tests/test-collect.sh:130:  *"cephadm shell -- ceph"*)
experiments/ceph-incident-bundle/tests/test-collect.sh:152:  *kubectl*)
experiments/ceph-incident-bundle/tests/test-collect.sh:156:      [[ "$a" == "kubectl" ]] && seen=1
experiments/ceph-incident-bundle/tests/test-collect.sh:158:    exec kubectl "${kargs[@]}"
experiments/ceph-incident-bundle/tests/test-collect.sh:161:    # direct/sudo `ceph <args>` cluster commands — same responses as cephadm shell
experiments/ceph-incident-bundle/tests/test-collect.sh:170:chmod +x "$fakebin/kubectl" "$fakebin/ssh" "$fakebin/timeout"
experiments/ceph-incident-bundle/tests/test-collect.sh:203:grep -qF -- '--context lab' "$FAKE_SSH_LOG" || fail "rook kubectl missing --context in auto mode"
experiments/ceph-incident-bundle/tests/test-collect.sh:204:grep -qF '10.0.0.9 kubectl' "$FAKE_SSH_LOG" || fail "rook kubectl did not run on the kube node"
experiments/ceph-incident-bundle/tests/test-collect.sh:230:# explicit --mode cephadm --seed: only ceph layer, no kubectl probing/collection
experiments/ceph-incident-bundle/tests/test-collect.sh:239:grep -qF 'kubectl' "$FAKE_SSH_LOG" && fail "cephadm mode should not run kubectl" || true
experiments/ceph-incident-bundle/tests/test-collect.sh:258:grep -qF '10.0.0.1 sudo -n cephadm shell -- ceph status --format json-pretty' "$FAKE_SSH_LOG" \
experiments/ceph-incident-bundle/tests/test-collect.sh:260:grep -qF '10.0.0.2 sudo -n cephadm shell -- ceph status' "$FAKE_SSH_LOG" \
experiments/ceph-incident-bundle/tests/test-collect.sh:323:# A1: auto with a kubectl node but missing namespace AND no ceph node -> nothing
experiments/ceph-incident-bundle/tests/test-collect.sh:377:# prefer direct ceph: a node where `ceph -s` connects uses plain `ceph` (no cephadm shell)
experiments/ceph-incident-bundle/tests/test-collect.sh:394:grep -qF 'cephadm shell' "$FAKE_SSH_LOG" && fail "direct runner must not use cephadm shell" || true
experiments/ceph-incident-bundle/tests/test-collect.sh:397:# fallback: direct/sudo don't connect but cephadm does -> cephadm shell runner
experiments/ceph-incident-bundle/tests/test-collect.sh:412:grep -qF '10.0.0.1 sudo -n cephadm shell -- ceph status --format json-pretty' "$FAKE_SSH_LOG" || fail "fallback should use cephadm shell"
experiments/ceph-incident-bundle/tests/test-collect.sh:415:# --kube-mode local: rook layer uses the jump host's local kubectl (no ssh), not a node
experiments/ceph-incident-bundle/tests/test-collect.sh:425:grep -qF 'kubectl' "$FAKE_SSH_LOG" && fail "kube-mode local must not run kubectl over ssh" || true
experiments/ceph-incident-bundle/tests/test-collect.sh:434:# Progress: default-on goes to stderr; stdout stays just `bundle:`; --quiet silences it.
experiments/ceph-incident-bundle/tests/test-collect.sh:441:grep -qF 'bundle:' "$prog_out" || fail "stdout must carry the bundle: line"
experiments/ceph-incident-bundle/tests/test-collect.sh:444:grep -qF 'bundle:' "$prog_err" && fail "bundle: must not be on stderr" || true
experiments/ceph-incident-bundle/tests/test-collect.sh:452:grep -qF 'bundle:' "$q_out" || fail "--quiet must still print bundle: to stdout"

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh | sed -n '1,220p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
     5	
     6	fail() {
     7	  printf 'FAIL: %s\n' "$*" >&2
     8	  exit 1
     9	}
    10	
    11	tmpdir="$(mktemp -d)"
    12	trap 'rm -rf "$tmpdir"' EXIT
    13	
    14	fakebin="$tmpdir/fakebin"
    15	mkdir -p "$fakebin"
    16	cat >"$fakebin/python3" <<'EOF'
    17	#!/usr/bin/env bash
    18	printf 'python3 should not be used by cephadm collector\n' >&2
    19	exit 99
    20	EOF
    21	chmod +x "$fakebin/python3"
    22	PATH="$fakebin:$ROOT/tests/fixtures/bin:$PATH"
    23	
    24	# shellcheck disable=SC1091
    25	source "$ROOT/lib/common.sh"
    26	# shellcheck disable=SC1091
    27	source "$ROOT/lib/collect-cluster-cephadm.sh"
    28	
    29	make_fake_ssh() {
    30	  local log_file=$1
    31	  local fail_on=${2:-}
    32	  local crash_ls_broken=${3:-0}
    33	
    34	  export FAKE_SSH_LOG="$log_file"
    35	  export FAKE_SSH_FAIL_ON="$fail_on"
    36	  export FAKE_SSH_CRASH_LS_BROKEN="$crash_ls_broken"
    37	}
    38	
    39	assert_file_contains() {
    40	  local file=$1 expected=$2
    41	  [[ -f "$file" ]] || fail "missing file: $file"
    42	  grep -qF "$expected" "$file" || fail "expected '$expected' in $file"
    43	}
    44	
    45	read_manifest_count() {
    46	  local manifest=$1
    47	  [[ -f "$manifest" ]] || fail "missing manifest: $manifest"
    48	  wc -l <"$manifest" | tr -d ' '
    49	}
    50	
    51	test_collect_cluster_cephadm_happy_path_and_limit_recent_crashes() {
    52	  local outdir="$tmpdir/out-happy"
    53	  local manifest="$tmpdir/manifest-happy.jsonl"
    54	  local ssh_log="$tmpdir/ssh-happy.log"
    55	  mkdir -p "$outdir"
    56	  touch "$tmpdir/id_ed25519"
    57	
    58	  make_fake_ssh "$ssh_log"
    59	  collect_cluster_cephadm "$outdir" "$manifest" "monitor01@example.invalid" "$tmpdir/id_ed25519" "7 days ago" "30"
    60	
    61	  [[ -f "$outdir/cluster/ceph/json/status.json" ]] || fail "missing status json artifact"
    62	  [[ -f "$outdir/cluster/ceph/text/status.txt" ]] || fail "missing status text artifact"
    63	  [[ -f "$outdir/cluster/ceph/text/health-detail.txt" ]] || fail "missing health detail text artifact"
    64	  [[ -f "$outdir/cluster/ceph/text/osd-tree.txt" ]] || fail "missing osd tree text artifact"
    65	  [[ -f "$outdir/cluster/ceph/text/orch-ps.txt" ]] || fail "missing orch ps text artifact"
    66	  [[ -f "$outdir/cluster/ceph/json/crash-ls.json" ]] || fail "missing crash ls artifact"
    67	  [[ -f "$outdir/cluster/ceph/json/crash-info/crash-01.json" ]] || fail "missing first crash info artifact"
    68	  [[ -f "$outdir/cluster/ceph/json/crash-info/crash_02.json" ]] || fail "missing sanitized crash info artifact"
    69	  [[ -f "$outdir/cluster/ceph/json/crash-info/crash_02-2.json" ]] || fail "missing collision-safe crash info artifact"
    70	  [[ -f "$outdir/cluster/ceph/json/crash-info/crash-10.json" ]] || fail "missing tenth crash info artifact"
    71	  [[ ! -f "$outdir/cluster/ceph/json/crash-info/crash-11.json" ]] || fail "collector did not cap crash info at 10"
    72	
    73	  assert_file_contains "$outdir/cluster/ceph/text/status.txt" "cluster is healthy"
    74	  assert_file_contains "$outdir/cluster/ceph/text/health-detail.txt" "HEALTH_OK"
    75	  assert_file_contains "$outdir/cluster/ceph/text/orch-ps.txt" "NAME HOST STATUS"
    76	  assert_file_contains "$outdir/cluster/ceph/json/status.json" "\"health\":\"HEALTH_OK\""
    77	  assert_file_contains "$outdir/cluster/ceph/json/crash-info/crash-01.json" "\"crash_id\":\"crash-01\""
    78	  assert_file_contains "$outdir/cluster/ceph/json/crash-info/crash_02.json" "\"crash_id\":\"crash/02\""
    79	  assert_file_contains "$outdir/cluster/ceph/json/crash-info/crash_02-2.json" "\"crash_id\":\"crash:02\""
    80	
    81	  [[ "$(read_manifest_count "$manifest")" == "34" ]] || fail "expected 34 manifest entries"
    82	  grep -qF 'sudo -n cephadm shell -- ceph status --format json-pretty' "$ssh_log" || fail "ssh log missing cephadm shell invocation"
    83	  grep -qF 'sudo -n cephadm shell -- ceph status' "$ssh_log" || fail "ssh log missing text status invocation"
    84	  grep -qF 'sudo -n cephadm shell -- ceph crash info crash-10' "$ssh_log" || fail "ssh log missing 10th crash info invocation"
    85	  # R1: cluster SSH must carry connect/keepalive bounds (was missing -> could hang on a half-open seed)
    86	  grep -qF 'ConnectTimeout=30' "$ssh_log" || fail "cluster ssh missing ConnectTimeout"
    87	  grep -qF 'ServerAliveInterval=30' "$ssh_log" || fail "cluster ssh missing ServerAliveInterval"
    88	}
    89	
    90	test_collect_cluster_cephadm_returns_partial_failure_and_keeps_collecting() {
    91	  local outdir="$tmpdir/out-partial"
    92	  local manifest="$tmpdir/manifest-partial.jsonl"
    93	  local ssh_log="$tmpdir/ssh-partial.log"
    94	  local rc=0
    95	  mkdir -p "$outdir"
    96	  touch "$tmpdir/id_ed25519"
    97	
    98	  make_fake_ssh "$ssh_log" "osd perf"
    99	  set +e
   100	  collect_cluster_cephadm "$outdir" "$manifest" "monitor01@example.invalid" "$tmpdir/id_ed25519" "7 days ago" "30"
   101	  rc=$?
   102	  set -e
   103	
   104	  [[ "$rc" == "2" ]] || fail "expected partial failure exit 2, got $rc"
   105	  [[ -f "$outdir/cluster/ceph/json/osd-perf.json" ]] || fail "missing failed osd perf artifact"
   106	  [[ -f "$outdir/cluster/ceph/json/pg-stat.json" ]] || fail "collector stopped before later artifacts"
   107	  assert_file_contains "$outdir/cluster/ceph/json/osd-perf.json" "simulated failure"
   108	  grep -qF 'ceph pg stat --format json-pretty' "$ssh_log" || fail "collector did not continue after failure"
   109	  grep -qF 'exit_code":17' "$manifest" || fail "manifest did not record the failing command"
   110	}
   111	
   112	test_collect_cluster_cephadm_records_skip_text_when_crash_list_is_invalid() {
   113	  local outdir="$tmpdir/out-broken"
   114	  local manifest="$tmpdir/manifest-broken.jsonl"
   115	  local ssh_log="$tmpdir/ssh-broken.log"
   116	  mkdir -p "$outdir"
   117	  touch "$tmpdir/id_ed25519"
   118	
   119	  make_fake_ssh "$ssh_log" "" 1
   120	  collect_cluster_cephadm "$outdir" "$manifest" "monitor01@example.invalid" "$tmpdir/id_ed25519" "7 days ago" "30"
   121	
   122	  [[ -f "$outdir/cluster/ceph/text/crash-info-skip.txt" ]] || fail "missing crash parse skip artifact"
   123	  assert_file_contains "$outdir/cluster/ceph/text/crash-info-skip.txt" "SKIPPED"
   124	  [[ ! -d "$outdir/cluster/ceph/json/crash-info" ]] || fail "collector should not create crash info artifacts when parsing fails"
   125	  if grep -qF 'crash info' "$ssh_log"; then
   126	    fail "collector tried to inspect crash ids after parse failure"
   127	  fi
   128	}
   129	
   130	test_collect_cluster_cephadm_runner_direct() {
   131	  local outdir="$tmpdir/out-direct"
   132	  local manifest="$tmpdir/manifest-direct.jsonl"
   133	  local ssh_log="$tmpdir/ssh-direct.log"
   134	  mkdir -p "$outdir"
   135	  touch "$tmpdir/id_ed25519"
   136	
   137	  make_fake_ssh "$ssh_log"
   138	  collect_cluster_cephadm "$outdir" "$manifest" "monitor01@example.invalid" "$tmpdir/id_ed25519" "7 days ago" "30" "direct"
   139	
   140	  [[ -f "$outdir/cluster/ceph/json/status.json" ]] || fail "direct runner produced no status artifact"
   141	  grep -qF 'monitor01@example.invalid ceph status --format json-pretty' "$ssh_log" || fail "direct runner should run plain 'ceph', got: $(grep -F 'ceph status --format json-pretty' "$ssh_log" | head -1)"
   142	  if grep -qF 'cephadm shell' "$ssh_log"; then
   143	    fail "direct runner must NOT use cephadm shell"
   144	  fi
   145	  if grep -qF 'sudo -n ceph' "$ssh_log"; then
   146	    fail "direct runner must NOT use sudo"
   147	  fi
   148	}
   149	
   150	test_collect_cluster_cephadm_runner_sudo() {
   151	  local outdir="$tmpdir/out-sudo"
   152	  local manifest="$tmpdir/manifest-sudo.jsonl"
   153	  local ssh_log="$tmpdir/ssh-sudo.log"
   154	  mkdir -p "$outdir"
   155	  touch "$tmpdir/id_ed25519"
   156	
   157	  make_fake_ssh "$ssh_log"
   158	  collect_cluster_cephadm "$outdir" "$manifest" "monitor01@example.invalid" "$tmpdir/id_ed25519" "7 days ago" "30" "sudo"
   159	
   160	  grep -qF 'monitor01@example.invalid sudo -n ceph status --format json-pretty' "$ssh_log" || fail "sudo runner should run 'sudo -n ceph'"
   161	  if grep -qF 'cephadm shell' "$ssh_log"; then
   162	    fail "sudo runner must NOT use cephadm shell"
   163	  fi
   164	}
   165	
   166	test_collect_cluster_cephadm_happy_path_and_limit_recent_crashes
   167	test_collect_cluster_cephadm_returns_partial_failure_and_keeps_collecting
   168	test_collect_cluster_cephadm_records_skip_text_when_crash_list_is_invalid
   169	test_collect_cluster_cephadm_runner_direct
   170	test_collect_cluster_cephadm_runner_sudo

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-rook-collector.sh | sed -n '1,220p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
     5	BASH_BIN="$(command -v bash)"
     6	
     7	fail() {
     8	  printf 'FAIL: %s\n' "$*" >&2
     9	  exit 1
    10	}
    11	
    12	assert_file_contains() {
    13	  local file=$1 expected=$2
    14	  [[ -f "$file" ]] || fail "missing file: $file"
    15	  grep -qF "$expected" "$file" || fail "expected '$expected' in $file"
    16	}
    17	
    18	run_rook_collector() {
    19	  local outdir=$1 manifest=$2
    20	  shift 2
    21	  "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
    22	    --out "$outdir" \
    23	    --manifest "$manifest" \
    24	    --namespace rook-ceph \
    25	    --since 24h \
    26	    --timeout 5 \
    27	    "$@"
    28	}
    29	
    30	tmpdir="$(mktemp -d)"
    31	trap 'rm -rf "$tmpdir"' EXIT
    32	
    33	minimal_bin="$tmpdir/minimal-bin"
    34	mkdir -p "$minimal_bin"
    35	ln -s "$(command -v dirname)" "$minimal_bin/dirname"
    36	ln -s "$(command -v mkdir)" "$minimal_bin/mkdir"
    37	
    38	out_no_kubectl="$tmpdir/out-no-kubectl"
    39	manifest_no_kubectl="$tmpdir/manifest-no-kubectl.jsonl"
    40	no_kubectl_rc=0
    41	set +e
    42	PATH="$minimal_bin" "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
    43	  --out "$out_no_kubectl" \
    44	  --manifest "$manifest_no_kubectl" \
    45	  --namespace rook-ceph \
    46	  --since 24h \
    47	  --timeout 5
    48	no_kubectl_rc=$?
    49	set -e
    50	# R4: explicit rook mode with no kubectl is a real failure (not a silent success)
    51	[[ "$no_kubectl_rc" == "2" ]] || fail "explicit rook with no kubectl should exit 2, got $no_kubectl_rc"
    52	assert_file_contains "$out_no_kubectl/cluster/rook/SKIPPED.txt" "kubectl command not found"
    53	
    54	# R4: auto-mode fallback passes --allow-skip, so the same situation is a graceful skip (rc 0)
    55	out_no_kubectl_skip="$tmpdir/out-no-kubectl-skip"
    56	manifest_no_kubectl_skip="$tmpdir/manifest-no-kubectl-skip.jsonl"
    57	allow_skip_rc=0
    58	set +e
    59	PATH="$minimal_bin" "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
    60	  --out "$out_no_kubectl_skip" \
    61	  --manifest "$manifest_no_kubectl_skip" \
    62	  --namespace rook-ceph \
    63	  --since 24h \
    64	  --timeout 5 \
    65	  --allow-skip
    66	allow_skip_rc=$?
    67	set -e
    68	[[ "$allow_skip_rc" == "0" ]] || fail "rook with --allow-skip and no kubectl should exit 0, got $allow_skip_rc"
    69	assert_file_contains "$out_no_kubectl_skip/cluster/rook/SKIPPED.txt" "kubectl command not found"
    70	
    71	fakebin="$tmpdir/fakebin"
    72	mkdir -p "$fakebin"
    73	cat >"$fakebin/kubectl" <<'EOF'
    74	#!/usr/bin/env bash
    75	set -euo pipefail
    76	printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG:?}"
    77	
    78	# tolerate a leading "--context CTX" (added in remote/ssh mode)
    79	if [[ "${1:-}" == "--context" ]]; then
    80	  shift 2
    81	fi
    82	
    83	mode=${FAKE_KUBECTL_MODE:-present}
    84	cmd="$*"
    85	
    86	case "$cmd" in
    87	  "get namespace rook-ceph")
    88	    [[ "$mode" != "missing-namespace" ]] || exit 1
    89	    printf 'rook-ceph\n'
    90	    ;;
    91	  "get namespace rook-ceph-external")
    92	    printf 'rook-ceph-external\n'
    93	    ;;
    94	  "get pods -n rook-ceph -o wide")
    95	    printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n'
    96	    ;;
    97	  "get pods -n rook-ceph-external -o wide")
    98	    printf 'No resources found in rook-ceph-external namespace.\n'
    99	    ;;
   100	  "get events -n rook-ceph --sort-by=.lastTimestamp")
   101	    printf 'LAST SEEN TYPE REASON OBJECT MESSAGE\n1m Normal Started pod/osd started\n'
   102	    ;;
   103	  "get events -n rook-ceph-external --sort-by=.lastTimestamp")
   104	    printf 'LAST SEEN TYPE REASON OBJECT MESSAGE\n1m Normal ClusterConnected cephcluster/rook-ceph-external connected\n'
   105	    ;;
   106	  "get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n rook-ceph -o yaml")
   107	    printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n  metadata:\n    name: rook-ceph\n'
   108	    ;;
   109	  "get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n rook-ceph-external -o yaml")
   110	    printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n  metadata:\n    name: rook-ceph-external\n'
   111	    ;;
   112	  "get pods -n rook-ceph -l app=rook-ceph-operator -o name")
   113	    [[ "$mode" == "op-lookup-fail" ]] && exit 1
   114	    printf 'pod/rook-ceph-operator-0\n'
   115	    ;;
   116	  "logs -n rook-ceph rook-ceph-operator-0 --since=24h")
   117	    printf 'operator log line\n'
   118	    ;;
   119	  "get pods -n rook-ceph -l app=rook-ceph-tools -o name")
   120	    [[ "$mode" == "with-toolbox" ]] || exit 0
   121	    printf 'pod/rook-ceph-tools-0\n'
   122	    ;;
   123	  "exec -n rook-ceph rook-ceph-tools-0 -- ceph status")
   124	    printf 'cluster is healthy from toolbox\n'
   125	    ;;
   126	  *)
   127	    printf 'unexpected kubectl command: %s\n' "$cmd" >&2
   128	    exit 99
   129	    ;;
   130	esac
   131	EOF
   132	chmod +x "$fakebin/kubectl"
   133	
   134	export FAKE_KUBECTL_LOG="$tmpdir/kubectl.log"
   135	
   136	out_missing_ns="$tmpdir/out-missing-ns"
   137	manifest_missing_ns="$tmpdir/manifest-missing-ns.jsonl"
   138	missing_ns_rc=0
   139	set +e
   140	FAKE_KUBECTL_MODE=missing-namespace PATH="$fakebin:$PATH" run_rook_collector "$out_missing_ns" "$manifest_missing_ns"
   141	missing_ns_rc=$?
   142	set -e
   143	[[ "$missing_ns_rc" == "2" ]] || fail "explicit rook with missing namespace should exit 2, got $missing_ns_rc"
   144	assert_file_contains "$out_missing_ns/cluster/rook/SKIPPED.txt" "namespace not found"
   145	
   146	out_present="$tmpdir/out-present"
   147	manifest_present="$tmpdir/manifest-present.jsonl"
   148	FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" run_rook_collector "$out_present" "$manifest_present"
   149	
   150	assert_file_contains "$out_present/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
   151	assert_file_contains "$out_present/cluster/rook/events.txt" "osd started"
   152	assert_file_contains "$out_present/cluster/rook/rook-resources.yaml" "kind: CephCluster"
   153	assert_file_contains "$out_present/cluster/rook/operator.log" "operator log line"
   154	assert_file_contains "$out_present/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
   155	
   156	grep -qF 'get namespace rook-ceph' "$FAKE_KUBECTL_LOG" || fail "namespace detection was not called"
   157	grep -qF 'logs -n rook-ceph rook-ceph-operator-0 --since=24h' "$FAKE_KUBECTL_LOG" || fail "operator logs were not collected"
   158	
   159	out_external="$tmpdir/out-external"
   160	manifest_external="$tmpdir/manifest-external.jsonl"
   161	FAKE_KUBECTL_MODE=present PATH="$fakebin:$PATH" \
   162	  "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
   163	  --out "$out_external" --manifest "$manifest_external" \
   164	  --namespace rook-ceph-external --operator-namespace rook-ceph \
   165	  --since 24h --timeout 5
   166	
   167	assert_file_contains "$out_external/cluster/rook/rook-resources.yaml" "name: rook-ceph-external"
   168	assert_file_contains "$out_external/cluster/rook/operator.log" "operator log line"
   169	grep -qF 'logs -n rook-ceph rook-ceph-operator-0 --since=24h' "$FAKE_KUBECTL_LOG" || fail "external cluster operator logs were not collected from operator namespace"
   170	
   171	# --- remote (ssh-target) mode: kubectl runs via ssh on the chosen node, with --context ---
   172	fake_ssh_log="$tmpdir/ssh.log"
   173	cat >"$fakebin/ssh" <<'EOF'
   174	#!/usr/bin/env bash
   175	set -euo pipefail
   176	printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
   177	# argv: -i key <opts...> target kubectl <kubectl args...>; forward everything after 'kubectl'
   178	seen=0
   179	argv=()
   180	for a in "$@"; do
   181	  if [[ $seen -eq 1 ]]; then argv+=("$a"); continue; fi
   182	  [[ "$a" == "kubectl" ]] && seen=1
   183	done
   184	exec kubectl "${argv[@]}"
   185	EOF
   186	chmod +x "$fakebin/ssh"
   187	printf 'k\n' >"$tmpdir/key"
   188	
   189	out_remote="$tmpdir/out-remote"
   190	manifest_remote="$tmpdir/manifest-remote.jsonl"
   191	FAKE_SSH_LOG="$fake_ssh_log" FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" \
   192	  "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
   193	  --out "$out_remote" --manifest "$manifest_remote" \
   194	  --namespace rook-ceph --since 24h --timeout 5 \
   195	  --ssh-target tester@node2 --ssh-key "$tmpdir/key" --kube-context lab
   196	
   197	assert_file_contains "$out_remote/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
   198	assert_file_contains "$out_remote/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
   199	grep -qF -- '--context lab' "$fake_ssh_log" || fail "remote kubectl missing --context"
   200	grep -qF 'tester@node2 kubectl' "$fake_ssh_log" || fail "kubectl did not run via ssh on the target node"
   201	
   202	# A2 regression: a pod-lookup failure must not abort the collector under set -e
   203	out_oplookup="$tmpdir/out-oplookup"
   204	manifest_oplookup="$tmpdir/manifest-oplookup.jsonl"
   205	oplookup_rc=0
   206	set +e
   207	FAKE_KUBECTL_MODE=op-lookup-fail PATH="$fakebin:$PATH" run_rook_collector "$out_oplookup" "$manifest_oplookup"
   208	oplookup_rc=$?
   209	set -e
   210	[[ "$oplookup_rc" == "0" ]] || fail "operator pod-lookup failure should not abort collector, got $oplookup_rc"
   211	assert_file_contains "$out_oplookup/cluster/rook/operator-SKIPPED.txt" "operator Pod not found"

codex
The fake-SSH tests grep for target plus remote command substrings, and the refactor keeps that ordering. I’m scanning the larger orchestration tests for named-flag/skip-artifact edge cases before writing the verdict.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-collect.sh | sed -n '260,480p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
   260	grep -qF '10.0.0.2 sudo -n cephadm shell -- ceph status' "$FAKE_SSH_LOG" \
   261	  && fail "cluster ceph must not be collected twice" || true
   262	
   263	# ---------------------------------------------------------------------------
   264	# node-level orchestration (use cephadm --seed to keep the cluster layer simple)
   265	# ---------------------------------------------------------------------------
   266	run_nodecase() {
   267	  # $1=outdir ; remaining env set by caller
   268	  PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   269	    --inventory "$inventory" --ssh-key "$ssh_key" \
   270	    --seed tester@10.0.0.1 --mode cephadm --out "$1" --since 24h --timeout 5
   271	}
   272	
   273	# C4: truncated node (no manifest) -> SKIPPED, exit 2
   274	out_nomani="$tmpdir/out-nomani"
   275	st=0; set +e
   276	FAKE_SSH_NO_MANIFEST_ALIAS=kubenode run_nodecase "$out_nomani"
   277	st=$?; set -e
   278	[[ "$st" == "2" ]] || fail "missing node manifest should exit 2, got $st"
   279	assert_archive_contains "$(find_bundle "$out_nomani")" "nodes/kubenode/SKIPPED.txt"
   280	
   281	# bad tar -> SKIPPED, exit 2
   282	out_badtar="$tmpdir/out-badtar"
   283	st=0; set +e
   284	FAKE_SSH_BAD_TAR_ALIAS=kubenode run_nodecase "$out_badtar"
   285	st=$?; set -e
   286	[[ "$st" == "2" ]] || fail "bad node tar should exit 2, got $st"
   287	assert_archive_contains "$(find_bundle "$out_badtar")" "nodes/kubenode/SKIPPED.txt"
   288	
   289	# one failed host -> exit 2, errors.log present
   290	out_fail="$tmpdir/out-fail"
   291	st=0; set +e
   292	FAKE_SSH_FAIL_ALIAS=kubenode run_nodecase "$out_fail"
   293	st=$?; set -e
   294	[[ "$st" == "2" ]] || fail "one failed host should exit 2, got $st"
   295	assert_archive_contains "$(find_bundle "$out_fail")" "errors.log"
   296	
   297	# C2: abort mid-run -> trap cleans workdir (no tmp.* left)
   298	out_abort="$tmpdir/out-abort"
   299	set +e
   300	COLLECT_TEST_ABORT_AFTER_NODES=1 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   301	  --inventory "$inventory" --ssh-key "$ssh_key" \
   302	  --seed tester@10.0.0.1 --mode cephadm --out "$out_abort" --since 24h --timeout 5 >/dev/null 2>&1
   303	abort_status=$?
   304	set -e
   305	[[ "$abort_status" != "0" ]] || fail "abort hook should exit non-zero"
   306	leftover="$(find "$out_abort" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
   307	[[ "$leftover" == "0" ]] || fail "abort left $leftover tmp workdir(s)"
   308	
   309	# C3: verify failure (forbidden secret path) -> exit 1, workdir kept, no bundle
   310	out_verify="$tmpdir/out-verify"
   311	set +e
   312	FAKE_SSH_PEM_ALIAS=kubenode PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   313	  --inventory "$inventory" --ssh-key "$ssh_key" \
   314	  --seed tester@10.0.0.1 --mode cephadm --out "$out_verify" --since 24h --timeout 5 >/dev/null 2>&1
   315	verify_status=$?
   316	set -e
   317	[[ "$verify_status" == "1" ]] || fail "verify failure should exit 1, got $verify_status"
   318	produced="$(find "$out_verify" -maxdepth 1 -name 'ceph-incident-*.tar.gz' 2>/dev/null | wc -l | tr -d '[:space:]')"
   319	[[ "$produced" == "0" ]] || fail "verify failure must not package a bundle"
   320	kept="$(find "$out_verify" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
   321	[[ "$kept" == "1" ]] || fail "verify failure should keep the workdir (found $kept)"
   322	
   323	# A1: auto with a kubectl node but missing namespace AND no ceph node -> nothing
   324	# actually collected -> exit 2 (must NOT be a green exit-0).
   325	inv_kubeonly="$tmpdir/inv-kubeonly.env"
   326	cat >"$inv_kubeonly" <<'EOF'
   327	SSH_USER="tester"
   328	HOSTS=(
   329	  "kubenode=10.0.0.9"
   330	)
   331	EOF
   332	out_nsmiss="$tmpdir/out-nsmiss"
   333	st=0; set +e
   334	FAKE_CEPH_TARGETS="" FAKE_KUBE_TARGETS="10.0.0.9" FAKE_KUBE_NS_MISSING=1 \
   335	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   336	  --inventory "$inv_kubeonly" --ssh-key "$ssh_key" \
   337	  --mode auto --out "$out_nsmiss" --since 24h --timeout 5
   338	st=$?; set -e
   339	[[ "$st" == "2" ]] || fail "auto with rook allow-skip and no ceph should exit 2, got $st"
   340	# the specific collector reason must survive (not be overwritten by the generic auto skip)
   341	tar -xOzf "$(find_bundle "$out_nsmiss")" ./cluster/rook/SKIPPED.txt 2>/dev/null | grep -qF 'namespace not found' \
   342	  || fail "auto skip overwrote the specific rook SKIPPED reason"
   343	
   344	# A3: a node whose capability probe ssh fails is recorded in errors.log
   345	out_probefail="$tmpdir/out-probefail"
   346	set +e
   347	FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="" FAKE_PROBE_FAIL_TARGETS="10.0.0.9" \
   348	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   349	  --inventory "$inventory" --ssh-key "$ssh_key" \
   350	  --mode auto --out "$out_probefail" --since 24h --timeout 5 >/dev/null 2>&1
   351	set -e
   352	assert_archive_contains "$(find_bundle "$out_probefail")" "errors.log"
   353	tar -xOzf "$(find_bundle "$out_probefail")" ./errors.log 2>/dev/null | grep -qF 'capability probe failed for tester@10.0.0.9' \
   354	  || fail "probe ssh failure was not recorded in errors.log"
   355	
   356	# A5: empty HOSTS=() -> exit 1 with a clear message (no bash-3.2 unbound error)
   357	inv_empty="$tmpdir/inv-empty.env"
   358	printf 'SSH_USER="t"\nHOSTS=()\n' >"$inv_empty"
   359	empty_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$inv_empty" --ssh-key "$ssh_key" --mode cephadm --seed t@1.2.3.4)"
   360	empty_status="${empty_result%%$'\n'*}"
   361	empty_output="${empty_result#*$'\n'}"
   362	[[ "$empty_status" == "1" ]] || fail "empty HOSTS should exit 1, got $empty_status"
   363	[[ "$empty_output" == *"HOSTS is empty"* ]] || fail "empty HOSTS should explain the failure"
   364	
   365	# A6: --kube-context with shell metacharacters is rejected (exit 1)...
   366	ctx_bad="$(run_and_capture "$ROOT/run/collect.sh" --kube-context 'bad;ctx' --inventory "$inventory" --ssh-key "$ssh_key")"
   367	ctx_bad_status="${ctx_bad%%$'\n'*}"
   368	ctx_bad_output="${ctx_bad#*$'\n'}"
   369	[[ "$ctx_bad_status" == "1" ]] || fail "invalid --kube-context should exit 1, got $ctx_bad_status"
   370	[[ "$ctx_bad_output" == *"invalid --kube-context"* ]] || fail "bad context should explain failure"
   371	# ...but a real context (kubernetes-admin@kubernetes / EKS ARN chars @ : /) is accepted:
   372	# it passes validation and fails later on the missing inventory instead.
   373	ctx_ok="$(run_and_capture "$ROOT/run/collect.sh" --kube-context 'arn:aws:eks:us-east-1:1/x@k8s' --inventory /nope.env --ssh-key "$ssh_key")"
   374	ctx_ok_output="${ctx_ok#*$'\n'}"
   375	[[ "$ctx_ok_output" == *"missing inventory"* ]] || fail "valid kube-context wrongly rejected: $ctx_ok_output"
   376	
   377	# prefer direct ceph: a node where `ceph -s` connects uses plain `ceph` (no cephadm shell)
   378	inv_direct="$tmpdir/inv-direct.env"
   379	cat >"$inv_direct" <<'EOF'
   380	SSH_USER="tester"
   381	HOSTS=(
   382	  "cephnode=10.0.0.1"
   383	)
   384	EOF
   385	out_direct="$tmpdir/out-direct"
   386	: >"$FAKE_SSH_LOG"
   387	FAKE_CEPH_BIN_TARGETS="10.0.0.1" FAKE_CEPH_DIRECT_OK="10.0.0.1" FAKE_CEPH_TARGETS="" FAKE_KUBE_TARGETS="" \
   388	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   389	  --inventory "$inv_direct" --ssh-key "$ssh_key" \
   390	  --mode cephadm --out "$out_direct" --since 24h --timeout 5
   391	bundle_direct="$(find_bundle "$out_direct")"
   392	assert_archive_contains "$bundle_direct" "cluster/ceph/json/status.json"
   393	grep -qF '10.0.0.1 ceph status --format json-pretty' "$FAKE_SSH_LOG" || fail "direct runner should use plain ceph"
   394	grep -qF 'cephadm shell' "$FAKE_SSH_LOG" && fail "direct runner must not use cephadm shell" || true
   395	tar -xOzf "$bundle_direct" ./environment.txt 2>/dev/null | grep -qF 'ceph_runner=direct' || fail "environment.txt should record ceph_runner=direct"
   396	
   397	# fallback: direct/sudo don't connect but cephadm does -> cephadm shell runner
   398	inv_fb="$tmpdir/inv-fb.env"
   399	cat >"$inv_fb" <<'EOF'
   400	SSH_USER="tester"
   401	HOSTS=(
   402	  "c1=10.0.0.1"
   403	)
   404	EOF
   405	out_fb="$tmpdir/out-fb"
   406	: >"$FAKE_SSH_LOG"
   407	FAKE_CEPH_TARGETS="10.0.0.1" FAKE_CEPH_DIRECT_OK="" FAKE_CEPH_SUDO_OK="" FAKE_KUBE_TARGETS="" \
   408	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   409	  --inventory "$inv_fb" --ssh-key "$ssh_key" \
   410	  --mode cephadm --out "$out_fb" --since 24h --timeout 5
   411	bundle_fb="$(find_bundle "$out_fb")"
   412	grep -qF '10.0.0.1 sudo -n cephadm shell -- ceph status --format json-pretty' "$FAKE_SSH_LOG" || fail "fallback should use cephadm shell"
   413	tar -xOzf "$bundle_fb" ./environment.txt 2>/dev/null | grep -qF 'ceph_runner=cephadm' || fail "environment.txt should record ceph_runner=cephadm"
   414	
   415	# --kube-mode local: rook layer uses the jump host's local kubectl (no ssh), not a node
   416	out_klocal="$tmpdir/out-klocal"
   417	: >"$FAKE_SSH_LOG"
   418	FAKE_CEPH_TARGETS="" FAKE_KUBE_TARGETS="" \
   419	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   420	  --inventory "$inventory" --ssh-key "$ssh_key" \
   421	  --mode rook --kube-mode local --kube-context lab --out "$out_klocal" --since 24h --timeout 5
   422	bundle_klocal="$(find_bundle "$out_klocal")"
   423	assert_archive_contains "$bundle_klocal" "cluster/rook/pods-wide.txt"
   424	tar -xOzf "$bundle_klocal" ./environment.txt 2>/dev/null | grep -qF 'rook_source=local' || fail "kube-mode local should record rook_source=local"
   425	grep -qF 'kubectl' "$FAKE_SSH_LOG" && fail "kube-mode local must not run kubectl over ssh" || true
   426	
   427	# --kube-mode invalid -> exit 1
   428	km_bad="$(run_and_capture "$ROOT/run/collect.sh" --kube-mode bogus --inventory "$inventory" --ssh-key "$ssh_key")"
   429	km_bad_status="${km_bad%%$'\n'*}"
   430	km_bad_out="${km_bad#*$'\n'}"
   431	[[ "$km_bad_status" == "1" ]] || fail "invalid --kube-mode should exit 1, got $km_bad_status"
   432	[[ "$km_bad_out" == *"invalid --kube-mode"* ]] || fail "bad --kube-mode should explain failure"
   433	
   434	# Progress: default-on goes to stderr; stdout stays just `bundle:`; --quiet silences it.
   435	prog_out="$tmpdir/prog.out"; prog_err="$tmpdir/prog.err"
   436	FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="10.0.0.9" \
   437	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   438	  --inventory "$inventory" --ssh-key "$ssh_key" \
   439	  --mode auto --kube-context lab --out "$tmpdir/out-prog" --since 24h --timeout 5 \
   440	  >"$prog_out" 2>"$prog_err"
   441	grep -qF 'bundle:' "$prog_out" || fail "stdout must carry the bundle: line"
   442	grep -qE 'node (cephnode|kubenode)' "$prog_err" || fail "stderr should show node progress"
   443	grep -qiE 'probing|collecting ceph' "$prog_err" || fail "stderr should show probe/ceph progress"
   444	grep -qF 'bundle:' "$prog_err" && fail "bundle: must not be on stderr" || true
   445	
   446	q_out="$tmpdir/q.out"; q_err="$tmpdir/q.err"
   447	FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="10.0.0.9" \
   448	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   449	  --inventory "$inventory" --ssh-key "$ssh_key" \
   450	  --mode auto --kube-context lab --out "$tmpdir/out-quiet" --since 24h --timeout 5 --quiet \
   451	  >"$q_out" 2>"$q_err"
   452	grep -qF 'bundle:' "$q_out" || fail "--quiet must still print bundle: to stdout"
   453	grep -qE 'probing|node cephnode|collecting ceph' "$q_err" && fail "--quiet must suppress progress" || true
   454	
   455	printf 'ok: collect orchestration\n'

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-common.sh | sed -n '1,390p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
     5	
     6	fail() {
     7	  printf 'FAIL: %s\n' "$*" >&2
     8	  exit 1
     9	}
    10	
    11	tmpdir="$(mktemp -d)"
    12	trap 'rm -rf "$tmpdir"' EXIT
    13	
    14	# shellcheck disable=SC1091
    15	source "$ROOT/lib/common.sh"
    16	
    17	test_json_escape() {
    18	  local got
    19	  got="$(json_escape 'a"b\c')"
    20	  [[ "$got" == 'a\"b\\c' ]] || fail "json_escape returned '$got'"
    21	}
    22	
    23	test_json_escape_is_shell_native() {
    24	  local fakebin="$tmpdir/fakebin"
    25	  mkdir -p "$fakebin"
    26	  cat >"$fakebin/python3" <<'EOF'
    27	#!/usr/bin/env bash
    28	printf 'python3 should not be used\n' >&2
    29	exit 99
    30	EOF
    31	  chmod +x "$fakebin/python3"
    32	
    33	  local got
    34	  got="$(PATH="$fakebin:$PATH" json_escape 'a"b\c')"
    35	  [[ "$got" == 'a\"b\\c' ]] || fail "shell-native json_escape failed with '$got'"
    36	}
    37	
    38	test_manifest_add() {
    39	  local manifest="$tmpdir/manifest.jsonl"
    40	  local artifact="$tmpdir/artifact.txt"
    41	  printf 'payload\n' >"$artifact"
    42	
    43	  manifest_add \
    44	    "$manifest" \
    45	    "host-1" \
    46	    "collector-1" \
    47	    "$artifact" \
    48	    "command with spaces" \
    49	    7 \
    50	    "2026-06-29T00:00:00Z" \
    51	    "2026-06-29T00:00:01Z"
    52	
    53	  python3 - "$manifest" <<'PY'
    54	import json
    55	import sys
    56	
    57	path = sys.argv[1]
    58	lines = [line.rstrip("\n") for line in open(path)]
    59	if len(lines) != 1:
    60	    raise SystemExit(f"expected 1 manifest entry, got {len(lines)}")
    61	entry = json.loads(lines[0])
    62	expected = {
    63	    "host": "host-1",
    64	    "collector": "collector-1",
    65	    "artifact": path.replace("manifest.jsonl", "artifact.txt"),
    66	    "command": "command with spaces",
    67	    "exit_code": 7,
    68	    "started": "2026-06-29T00:00:00Z",
    69	    "ended": "2026-06-29T00:00:01Z",
    70	}
    71	for key, value in expected.items():
    72	    if entry.get(key) != value:
    73	        raise SystemExit(f"{key}={entry.get(key)!r} != {value!r}")
    74	PY
    75	}
    76	
    77	test_manifest_add_rejects_non_numeric_exit_code() {
    78	  local manifest="$tmpdir/invalid-manifest.jsonl"
    79	  local artifact="$tmpdir/artifact-invalid.txt"
    80	  printf 'payload\n' >"$artifact"
    81	
    82	  local output rc
    83	  set +e
    84	  output="$(
    85	    bash -c '
    86	      set -euo pipefail
    87	      ROOT=$1
    88	      MANIFEST=$2
    89	      ARTIFACT=$3
    90	      # shellcheck disable=SC1091
    91	      source "$ROOT/lib/common.sh"
    92	      manifest_add \
    93	        "$MANIFEST" \
    94	        "host-1" \
    95	        "collector-1" \
    96	        "$ARTIFACT" \
    97	        "bad command" \
    98	        "abc" \
    99	        "2026-06-29T00:00:00Z" \
   100	        "2026-06-29T00:00:01Z"
   101	    ' bash "$ROOT" "$manifest" "$artifact" 2>&1
   102	  )"
   103	  rc=$?
   104	  set -e
   105	  [[ "$rc" != "0" ]] || fail "manifest_add accepted a non-numeric exit code"
   106	  [[ "$output" == *"exit_code"* ]] || fail "manifest_add did not explain the exit_code failure"
   107	}
   108	
   109	test_redact_file() {
   110	  local source_file="$tmpdir/secret.txt"
   111	  local redaction_log="$tmpdir/redaction.log"
   112	
   113	  cat >"$source_file" <<'EOF'
   114	safe line
   115	Password=abc
   116	SECRET=def
   117	token: ghi
   118	keyring: jkl
   119	private_key=xyz
   120	EOF
   121	
   122	  redact_file "$source_file" "$redaction_log"
   123	
   124	  [[ "$(sed -n '1p' "$source_file")" == "safe line" ]] || fail "safe line was modified"
   125	  for i in 2 3 4 5 6; do
   126	    [[ "$(sed -n "${i}p" "$source_file")" == "[REDACTED]" ]] || fail "line $i was not redacted"
   127	  done
   128	
   129	  [[ -s "$redaction_log" ]] || fail "redaction log is empty"
   130	  grep -q "secret.txt" "$redaction_log" || fail "redaction log does not mention the file"
   131	}
   132	
   133	test_redact_file_private_key_variants() {
   134	  local source_file="$tmpdir/private-keys.txt"
   135	  local redaction_log="$tmpdir/private-keys.log"
   136	
   137	  cat >"$source_file" <<'EOF'
   138	plain
   139	-----BEGIN OPENSSH PRIVATE KEY-----
   140	private-key: abc
   141	PRIVATE KEY material
   142	EOF
   143	
   144	  redact_file "$source_file" "$redaction_log"
   145	
   146	  [[ "$(sed -n '1p' "$source_file")" == "plain" ]] || fail "plain line was modified"
   147	  for i in 2 3 4; do
   148	    [[ "$(sed -n "${i}p" "$source_file")" == "[REDACTED]" ]] || fail "private key marker on line $i was not redacted"
   149	  done
   150	}
   151	
   152	test_redact_file_multiline_pem_body() {
   153	  local source_file="$tmpdir/pem.txt"
   154	  local redaction_log="$tmpdir/pem.log"
   155	
   156	  cat >"$source_file" <<'EOF'
   157	prefix safe
   158	-----BEGIN RSA PRIVATE KEY-----
   159	MIIEowIBAAKCAQEA1234567890abcdefghijKLMNOPqrstuv
   160	ZZZZnormalbodyline+slashes/and+more1234567890ab==
   161	-----END RSA PRIVATE KEY-----
   162	suffix safe
   163	EOF
   164	
   165	  redact_file "$source_file" "$redaction_log"
   166	
   167	  [[ "$(sed -n '1p' "$source_file")" == "prefix safe" ]] || fail "pem prefix modified"
   168	  for i in 2 3 4 5; do
   169	    [[ "$(sed -n "${i}p" "$source_file")" == "[REDACTED]" ]] || fail "pem body line $i not redacted"
   170	  done
   171	  [[ "$(sed -n '6p' "$source_file")" == "suffix safe" ]] || fail "pem suffix modified"
   172	}
   173	
   174	test_redact_file_ceph_key_material() {
   175	  local source_file="$tmpdir/keymat.txt"
   176	  local redaction_log="$tmpdir/keymat.log"
   177	
   178	  cat >"$source_file" <<'EOF'
   179	[client.admin]
   180		key = AQBabcdefghij0123456789KLMNOPQRSTUVWXyz==
   181	"auth_key": "AQBZZZZ1111222233334444555566667777abcd=="
   182	just a normal sentence with words
   183	EOF
   184	
   185	  redact_file "$source_file" "$redaction_log"
   186	
   187	  [[ "$(sed -n '1p' "$source_file")" == "[client.admin]" ]] || fail "section header modified"
   188	  [[ "$(sed -n '2p' "$source_file")" == "[REDACTED]" ]] || fail "ceph 'key =' line not redacted"
   189	  [[ "$(sed -n '3p' "$source_file")" == "[REDACTED]" ]] || fail "base64 key blob not redacted"
   190	  [[ "$(sed -n '4p' "$source_file")" == "just a normal sentence with words" ]] || fail "normal line over-redacted"
   191	}
   192	
   193	test_redact_file_preserves_mode() {
   194	  local source_file="$tmpdir/mode.txt"
   195	  local redaction_log="$tmpdir/mode.log"
   196	  printf 'token: leak\nplain\n' >"$source_file"
   197	  chmod 640 "$source_file"
   198	
   199	  redact_file "$source_file" "$redaction_log"
   200	
   201	  local got
   202	  got="$(stat -c '%a' "$source_file" 2>/dev/null || stat -f '%Lp' "$source_file" 2>/dev/null)"
   203	  [[ "$got" == "640" ]] || fail "redaction did not preserve file mode (got $got)"
   204	}
   205	
   206	test_redact_gz_file() {
   207	  local plain="$tmpdir/rotated.log"
   208	  local gz="$tmpdir/rotated.log.gz"
   209	  local redaction_log="$tmpdir/gz.log"
   210	
   211	  printf 'normal rotated line\n\tkey = AQBsecretkeymaterial0123456789abcdefghij==\nanother line\n' >"$plain"
   212	  gzip -c "$plain" >"$gz"
   213	  rm -f "$plain"
   214	
   215	  redact_gz_file "$gz" "$redaction_log"
   216	
   217	  local decoded
   218	  decoded="$(gzip -dc "$gz")"
   219	  [[ "$decoded" == *"normal rotated line"* ]] || fail "gz lost normal content"
   220	  [[ "$decoded" == *"[REDACTED]"* ]] || fail "gz secret not redacted"
   221	  [[ "$decoded" != *"AQBsecretkeymaterial"* ]] || fail "gz secret leaked"
   222	}
   223	
   224	test_progress_respects_quiet() {
   225	  local out
   226	  out="$(progress "hello-progress" 2>&1)"
   227	  [[ "$out" == *"hello-progress"* ]] || fail "progress should print when not quiet"
   228	  out="$(CEPH_INCIDENT_QUIET=1 progress "hello-progress" 2>&1)"
   229	  [[ -z "$out" ]] || fail "progress should be silent when CEPH_INCIDENT_QUIET set, got '$out'"
   230	}
   231	
   232	test_progress_goes_to_stderr() {
   233	  local on_stdout
   234	  on_stdout="$(progress "stderr-check" 2>/dev/null)"
   235	  [[ -z "$on_stdout" ]] || fail "progress must not write to stdout, got '$on_stdout'"
   236	}
   237	
   238	test_run_capture_success() {
   239	  local manifest="$tmpdir/run-manifest.jsonl"
   240	  local artifact="$tmpdir/run-artifact.txt"
   241	
   242	  run_capture "$manifest" "host-a" "collector-a" "$artifact" -- printf 'hello world\n'
   243	
   244	  [[ "$(sed -n '1p' "$artifact")" == "# host: host-a" ]] || fail "artifact header missing host"
   245	  grep -q 'hello world' "$artifact" || fail "artifact output missing"
   246	  python3 - "$manifest" "$artifact" <<'PY'
   247	import json
   248	import sys
   249	
   250	manifest_path, artifact_path = sys.argv[1:3]
   251	lines = [line.rstrip("\n") for line in open(manifest_path)]
   252	if len(lines) != 1:
   253	    raise SystemExit(f"expected 1 manifest entry, got {len(lines)}")
   254	entry = json.loads(lines[0])
   255	if entry["artifact"] != artifact_path:
   256	    raise SystemExit("artifact path mismatch")
   257	if entry["exit_code"] != 0:
   258	    raise SystemExit(f"unexpected exit code {entry['exit_code']}")
   259	PY
   260	}
   261	
   262	test_run_capture_non_zero_writes_error_log_and_returns_code() {
   263	  local manifest="$tmpdir/run-manifest-fail.jsonl"
   264	  local artifact="$tmpdir/run-artifact-fail.txt"
   265	  local error_log="$tmpdir/errors.log"
   266	  local rc=0
   267	
   268	  ERROR_LOG="$error_log" run_capture "$manifest" "host-b" "collector-b" "$artifact" -- bash -c 'printf fail-output; exit 7' || rc=$?
   269	  [[ "$rc" == "7" ]] || fail "run_capture returned $rc instead of 7"
   270	  grep -q 'fail-output' "$artifact" || fail "failure output missing from artifact"
   271	  grep -q 'exit=7' "$error_log" || fail "error log missing exit code"
   272	  python3 - "$manifest" <<'PY'
   273	import json
   274	import sys
   275	
   276	entry = json.loads(open(sys.argv[1]).readline())
   277	if entry["exit_code"] != 7:
   278	    raise SystemExit(f"unexpected exit code {entry['exit_code']}")
   279	PY
   280	}
   281	
   282	test_run_capture_missing_double_dash_is_fatal() {
   283	  local manifest="$tmpdir/run-manifest-missing-dash.jsonl"
   284	  local artifact="$tmpdir/run-artifact-missing-dash.txt"
   285	  local rc output
   286	
   287	  set +e
   288	  output="$(
   289	    bash -c '
   290	      set -euo pipefail
   291	      ROOT=$1
   292	      MANIFEST=$2
   293	      ARTIFACT=$3
   294	      # shellcheck disable=SC1091
   295	      source "$ROOT/lib/common.sh"
   296	      run_capture "$MANIFEST" "host-c" "collector-c" "$ARTIFACT" printf "missing-dash\n"
   297	    ' bash "$ROOT" "$manifest" "$artifact" 2>&1
   298	  )"
   299	  rc=$?
   300	  set -e
   301	  [[ "$rc" != "0" ]] || fail "run_capture accepted missing --"
   302	  [[ "$output" == *"-- before the command"* ]] || fail "missing -- failure was not explained"
   303	}
   304	
   305	test_run_capture_timeout_branch() {
   306	  local fakebin="$tmpdir/timeout-bin"
   307	  local timeout_log="$tmpdir/timeout.log"
   308	  mkdir -p "$fakebin"
   309	  cat >"$fakebin/timeout" <<'EOF'
   310	#!/usr/bin/env bash
   311	printf '%s\n' "$*" >>"$TIMEOUT_LOG"
   312	shift
   313	"$@"
   314	EOF
   315	  chmod +x "$fakebin/timeout"
   316	
   317	  local manifest="$tmpdir/run-manifest-timeout.jsonl"
   318	  local artifact="$tmpdir/run-artifact-timeout.txt"
   319	  PATH="$fakebin:$PATH" TIMEOUT_LOG="$timeout_log" run_capture "$manifest" "host-d" "collector-d" "$artifact" -- printf 'timeout-path\n'
   320	
   321	  grep -q 'timeout-path' "$artifact" || fail "timeout branch did not execute command"
   322	  grep -q '^20 printf timeout-path\\n$' "$timeout_log" || fail "fake timeout was not used"
   323	  grep -q '^# timeout: 20s$' "$artifact" || fail "timeout header missing"
   324	}
   325	
   326	test_run_capture_handles_leading_dash_artifact() {
   327	  local manifest="$tmpdir/run-manifest-leading-dash.jsonl"
   328	  local cwd="$tmpdir/leading-dash"
   329	  mkdir -p "$cwd"
   330	
   331	  (
   332	    cd "$cwd"
   333	    run_capture "$manifest" "host-dash" "collector-dash" "-leading-dash.txt" -- printf 'dash-safe\n'
   334	  )
   335	
   336	  [[ -f "$cwd/-leading-dash.txt" ]] || fail "leading-dash artifact was not created"
   337	  grep -q 'dash-safe' "$cwd/-leading-dash.txt" || fail "leading-dash artifact output missing"
   338	}
   339	
   340	test_run_capture_preserves_errexit_state() {
   341	  local manifest="$tmpdir/run-manifest-state.jsonl"
   342	  local artifact="$tmpdir/run-artifact-state.txt"
   343	  local status
   344	
   345	  set +e
   346	  run_capture "$manifest" "host-e" "collector-e" "$artifact" -- bash -c 'exit 3'
   347	  status=$?
   348	  false
   349	  status=$?
   350	  set -e
   351	
   352	  [[ "$status" == "1" ]] || fail "run_capture changed errexit state"
   353	}
   354	
   355	test_json_escape
   356	test_json_escape_is_shell_native
   357	test_manifest_add
   358	test_manifest_add_rejects_non_numeric_exit_code
   359	test_redact_file
   360	test_redact_file_private_key_variants
   361	test_redact_file_multiline_pem_body
   362	test_redact_file_ceph_key_material
   363	test_redact_file_preserves_mode
   364	test_redact_gz_file
   365	test_progress_respects_quiet
   366	test_progress_goes_to_stderr
   367	test_run_capture_success
   368	test_run_capture_non_zero_writes_error_log_and_returns_code
   369	test_run_capture_missing_double_dash_is_fatal
   370	test_run_capture_timeout_branch
   371	test_run_capture_handles_leading_dash_artifact
   372	test_run_capture_preserves_errexit_state
   373	
   374	printf 'ok: common helpers\n'

exec
/bin/zsh -lc 'git diff --check b44aa8d..HEAD -- experiments/ceph-incident-bundle' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-uf9muAUi' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-95q1kt5r' (errno=Operation not permitted)

codex
One thing to be careful about in the final: `tests/run-tests.sh` failed here for environmental temp-file reasons, not because of a regression in the diff. I’m doing one last all-shell shellcheck pass over the tool and tests so the verification note is precise.
exec
/bin/zsh -lc 'shellcheck experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/common.sh experiments/ceph-incident-bundle/lib/bundle.sh experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh experiments/ceph-incident-bundle/lib/collect-node.sh experiments/ceph-incident-bundle/lib/verify-bundle.sh experiments/ceph-incident-bundle/tests/*.sh' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 2841ms:
exec
/bin/zsh -lc "nl -ba /Users/ikaros/.codex/memories/MEMORY.md | sed -n '31,84p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
    31	# Task Group: learning-k8s Ceph incident tooling and docs
    32	
    33	scope: Building or extending the `ceph-incident-bundle` runnable tooling, operator runbook, and site integration in `learning-k8s`, especially when the user wants a one-command read-only evidence bundle for basic Linux operators and expects reviewer loops plus publish steps.
    34	applies_to: cwd=/Users/ikaros/Documents/code/learning-k8s; reuse_rule=safe for similar `ceph-incident-bundle` work in this checkout, but treat lab topology, smoke-bundle contents, and publish state as checkout-specific and revalidate before reuse
    35	
    36	## Task 1: Build the Ceph incident bundle runbook, scripts, and site integration, then publish
    37	
    38	### rollout_summary_files
    39	
    40	- rollout_summaries/2026-06-28T15-47-47-ct4R-ceph_incident_bundle_runbook_and_timesyncd_evidence.md (cwd=/Users/ikaros/Documents/code/learning-k8s, rollout_path=/Users/ikaros/.codex/sessions/2026/06/28/rollout-2026-06-28T23-47-47-019f0eea-59e6-70f2-aa97-0f82a7847421.jsonl, updated_at=2026-06-29T10:02:26+00:00, thread_id=019f0eea-59e6-70f2-aa97-0f82a7847421, success; initial bundle/runbook implementation plus commit/push)
    41	
    42	### keywords
    43	
    44	- ceph-incident-bundle, collect.sh, verify-bundle.sh, experiments/ceph-incident-bundle, README.md, incident-bundle-runbook.mdx, projects.ts, feature-map.json, quiz.json, code-review, git commit --no-gpg-sign, tar.gz, read-only evidence bundle
    45	
    46	- Related skill: skills/learning-k8s-content-integration/SKILL.md
    47	
    48	## Task 2: Add `systemd-timesyncd` evidence to the incident bundle without redesigning it
    49	
    50	### rollout_summary_files
    51	
    52	- rollout_summaries/2026-06-28T15-47-47-ct4R-ceph_incident_bundle_runbook_and_timesyncd_evidence.md (cwd=/Users/ikaros/Documents/code/learning-k8s, rollout_path=/Users/ikaros/.codex/sessions/2026/06/28/rollout-2026-06-28T23-47-47-019f0eea-59e6-70f2-aa97-0f82a7847421.jsonl, updated_at=2026-06-29T10:02:26+00:00, thread_id=019f0eea-59e6-70f2-aa97-0f82a7847421, success; follow-up extension for time-sync evidence and negative-case coverage)
    53	
    54	### keywords
    55	
    56	- systemd-timesyncd, timedatectl status, timedatectl show-timesync --all, timedatectl timesync-status, systemctl status systemd-timesyncd, journalctl -u systemd-timesyncd, SKIPPED.txt, FAKE_TIMESYNCD_MISSING, test-node-collector.sh, VERIFY PASS
    57	
    58	- Related skill: skills/learning-k8s-content-integration/SKILL.md
    59	
    60	## User preferences
    61	
    62	- when the user said "只會基本 linux 不懂 ceph 的人也要會操作" -> write similar incident tooling/docs as simple operator runbooks, not expert-only reference prose [Task 1]
    63	- when the user asked for "一個 shell script 就把所有要收集好的東西收集完，打包成一個 gz file" -> default to one orchestrator entrypoint plus helper scripts, not multiple manual collection steps [Task 1]
    64	- when the user said "每次寫完呼叫 Code Reviewer agent review 並修改問題直到沒問題" -> for similar repo work, run a review loop after each meaningful write and fix findings before moving on [Task 1][Task 2]
    65	- when the user added "加上考慮 timesync 用 systemd-timesyncd" -> treat `systemd-timesyncd` as a first-class supported time-sync source in similar Linux evidence collectors and docs [Task 2]
    66	- when the user asked for "commit no gpg & push" -> treat no-GPG commit plus push as part of the definition of done once validation passes [Task 1]
    67	
    68	## Reusable knowledge
    69	
    70	- The successful repo pattern for this tool family is `experiments/<topic>/` with `run/`, `lib/`, `tests/`, `results/.gitkeep`, and an operator README, paired with a reader-facing MDX feature page plus `projects.ts`, `feature-map.json`, and `quiz.json` updates [Task 1]
    71	- The Ceph incident bundle is intentionally read-only: collect cluster state, node state, logs, manifests, and command errors, then package them as a `.tar.gz`; do not restart daemons, repair, scrub, or change cluster flags [Task 1]
    72	- In this repo, `make validate` remains a hard gate for content-linked tooling work because it checks MDX, quiz JSON, feature wiring, and Next.js/basePath validation; the bundle itself should also be verified with `bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle>` [Task 1]
    73	- The rollout validated the collector on a six-node cephadm lab, and the verifier still accepted archives that preserved optional-command failures in `errors.log` [Task 1]
    74	- The `systemd-timesyncd` extension now collects `timedatectl status`, `timedatectl show-timesync --all`, `timedatectl timesync-status`, `systemctl status systemd-timesyncd`, `journalctl -u systemd-timesyncd`, and `/etc/systemd/timesyncd.conf` plus `/etc/systemd/timesyncd.conf.d/*.conf` [Task 2]
    75	- Missing `systemd-timesyncd` or missing config should not fail node collection; the collector emits `SKIPPED.txt` and keeps the node successful unless an actual copy operation fails [Task 2]
    76	- The updated docs teach that chrony/ntpq remain supported evidence, while `systemd-timesyncd` is explicitly included for Debian/Ubuntu-style hosts [Task 2]
    77	
    78	## Failures and how to do differently
    79	
    80	- Symptom: the normal reviewer path returns no useful output because of a usage limit. Cause: reviewer-agent availability failure. Fix: switch quickly to a direct read-only CLI review instead of blocking the whole run [Task 1]
    81	- Symptom: docs drift from collector behavior around flags like `--skip-logs`. Cause: prose was edited without matching the actual script behavior. Fix: align the documentation wording to the script when the script behavior is already correct [Task 1]
    82	- Symptom: a follow-up evidence-source addition only covers the happy path. Cause: new collector logic was added without a negative fixture. Fix: add a missing-source case like `FAKE_TIMESYNCD_MISSING=1` so collection still exits 0 and emits `SKIPPED.txt` when `systemd-timesyncd` is absent [Task 2]
    83	- Symptom: smoke validation looks noisy or slow because of tar warnings and multi-node collection time. Cause: real bundle generation is slower than unit tests and macOS tar can emit warnings. Fix: trust `verify-bundle.sh` plus the archive contents, not the command start or incidental tar noise [Task 2]
    84	- Symptom: generated bundle archives leak into the staged diff. Cause: smoke tarballs were created under ignored result paths but not checked before staging. Fix: inspect `git status` before staging and keep `results/*.tar.gz` out of commits [Task 1]

codex
Behavior preservation: clean. `ssh_base_opts()` preserves the old SSH argv ordering at all changed call sites; `bundle.sh` sourcing order is valid because `COLLECT_ROOT` is set before source and `common.sh` is sourced first.

Round-1 resolution: clean. The listed DRY/removal/named-flag/helper-extraction/README-drift items are genuinely addressed.

New issues: none found. No bash 3.2 array/set-u problems, no dead refs to removed functions, and `write_skip_artifact_once()` preserves the old no-clobber semantics.

Remaining best-practices issues: satisfactory; nothing material worth blocking.

Verification: `bash -n` clean; `shellcheck` over tool + tests exited 0. `tests/run-tests.sh` could not be verified in this read-only sandbox because bash failed creating here-doc temp files (`Operation not permitted`) before usage output.

Overall verdict: satisfied.


tokens used
110,852
Behavior preservation: clean. `ssh_base_opts()` preserves the old SSH argv ordering at all changed call sites; `bundle.sh` sourcing order is valid because `COLLECT_ROOT` is set before source and `common.sh` is sourced first.

Round-1 resolution: clean. The listed DRY/removal/named-flag/helper-extraction/README-drift items are genuinely addressed.

New issues: none found. No bash 3.2 array/set-u problems, no dead refs to removed functions, and `write_skip_artifact_once()` preserves the old no-clobber semantics.

Remaining best-practices issues: satisfactory; nothing material worth blocking.

Verification: `bash -n` clean; `shellcheck` over tool + tests exited 0. `tests/run-tests.sh` could not be verified in this read-only sandbox because bash failed creating here-doc temp files (`Operation not permitted`) before usage output.

Overall verdict: satisfied.


