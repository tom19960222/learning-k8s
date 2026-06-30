Reading additional input from stdin...
OpenAI Codex v0.142.4
--------
workdir: /Users/ikaros/Documents/code/learning-k8s
model: gpt-5.5
provider: openai
approval: never
sandbox: read-only
reasoning effort: medium
reasoning summaries: none
session id: 019f1627-14c7-76d1-8cc9-305974f3853e
--------
user
Review the per-node auto-detect feature just added to a read-only Ceph incident collector (bash). Diff range: git diff 38c16e2..HEAD. Key files: run/collect.sh (new detect_node_caps, collect_clusters, --kube-context, HOST_ALIASES/HOST_TARGETS globals, reworked main), lib/collect-cluster-rook.sh (kubectl now runs over ssh via ROOK_KUBECTL_ARGV prefix; pod lookup uses -o name), tests/test-collect.sh + tests/test-rook-collector.sh.

The workstation runs bash 3.2 with no `timeout`/`gtimeout`. The tool must never mutate cluster state and must keep its exit-code contract: 0 = complete, 2 = partial (bundle still produced), 1 = usage/config/verify failure.

Find REAL correctness bugs / regressions ONLY. Focus:
1. collect_clusters source selection: is the "first cephadm node / first kubectl node" logic correct? Can --seed + auto interact wrongly? Does the early-break stop probing correctly?
2. auto vs explicit exit semantics: auto with one layer present (e.g. pure cephadm, no kubectl) must be exit 0, NOT 2. auto with neither = 2. explicit cephadm/rook with no source = 2. Verify the code does this.
3. bash 3.2 traps: empty-array expansion under set -u ("${!HOST_TARGETS[@]}" / "${HOST_ALIASES[@]}"), ${arr[@]+...} guards. Any unbound-variable risk if HOSTS all malformed or empty?
4. rook-over-ssh: ROOK_KUBECTL_ARGV global correctness; does running kubectl through ssh argv mangle any arg (the -o name pod lookup, --since=, label selectors, exec ceph status)? Is the local (no ssh-target) path still intact?
5. did any hardening guarantee regress (trap cleanup, verify-keeps-evidence, redaction, timeouts, manifest-required node check)?
6. dedup: is cluster-ceph / cluster-rook each collected exactly once?

Output ONLY real findings: SEVERITY | file:line | problem | fix. If a category is clean, say so in one line. Do not modify files.
codex
I’ll review the diff only and keep this to concrete regressions. I’m also loading the required repo/session guidance before inspecting the code.
exec
/bin/zsh -lc "sed -n '1,240p' /Users/ikaros/.codex/superpowers/skills/using-superpowers/SKILL.md && rg -n \"Ceph|incident collector|collect_clusters|collect.sh|rook\" /Users/ikaros/.codex/memories/MEMORY.md" in /Users/ikaros/Documents/code/learning-k8s
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
122:- timesyncd-prometheus-monitoring, node_timex_offset_seconds, node_timex_maxerror_seconds, systemd_exporter, CephMonClockSkew, alert-rule block, maxerror < 16s, promtool unavailable
160:- Symptom: monitoring guidance overstates exporter freshness or makes node-level metrics sound authoritative for cross-node skew. Cause: flattening distinct signal layers into one story. Fix: keep the residual/early-proxy framing for `node_timex_*` and reserve the hard authority claim for the Ceph health signal [Task 1][Task 2]
164:# Task Group: learning-k8s Ceph source-first authoring and explanation workflow
166:scope: Source-first Ceph category rewrites, alert-design rewrites, and implementation-grounded config explanations in `learning-k8s`, including publish flow when the user wants the pages landed.
167:applies_to: cwd=/Users/ikaros/Documents/code/learning-k8s; reuse_rule=safe for similar Ceph source-reading and site-content tasks in this checkout, but treat pinned Ceph version, Prometheus tooling availability, and publish state as checkout-specific and revalidate before reuse
169:## Task 1: Audit and rewrite the Ceph category, then publish
181:## Task 2: Rewrite Ceph Prometheus alert design around stability-first plus scoped maintenance, then publish
189:- prometheus-alert-design, CephHealthError, ceph_health_detail, ceph_mon_quorum_status, ceph_mon_metadata, ceph_osd_metadata, CephClientRisk, CephMonQuorumLost, ceph-stability-first, ceph-scoped-availability, recording rules, unless on (hostname)
193:## Task 3: Explain `osd_mclock_scheduler_client_res`, `wgt`, and `lim` from Ceph source
207:- when the user said "有套用預設 alert rules 的情況" and "health err 用預設的" -> keep `CephHealthError` as the upstream default and explain added rules as supplements, not replacements [Task 2]
210:- when the user asked "看原始碼回答我的問題" about `osd_mclock_scheduler_client_lim res wgt` -> answer Ceph config questions from source and explain each shorthand field separately [Task 3]
215:- The durable Ceph source baseline here was `v19.2.3` from `/Users/ikaros/Documents/code/learning-k8s/ceph` at commit `c92aebb`; similar version-sensitive answers should confirm that baseline before explaining behavior [Task 1][Task 2][Task 3]
219:- `CephMonQuorumLost` was hard-coded for the 3-mon case in the page (`count(...) < 2`), so the majority threshold must become dynamic if cluster size changes [Task 2]
220:- `CephClientRisk` must exclude `MON_DOWN` as well as `OSD_DOWN` / `OSD_HOST_DOWN`, or MON maintenance will re-trigger the generic catch-all and defeat scoped silencing [Task 2]
224:- `0` has special meaning for Ceph classic mClock client fields: `0` reservation means no extra reservation path, and `0` limit means no upper-limit enforcement in scheduler internals [Task 3]
229:- Symptom: Ceph prose sounds too deterministic about quorum, auth skew, or recovery boundaries. Cause: flattening stateful admission and threshold behavior into hard guarantees. Fix: default to “stateful / approximate / depends on reconnect or admission gate” wording unless the source proves a hard bound [Task 1]
231:- Symptom: the generic cluster-wide warning keeps firing during MON maintenance. Cause: forgetting to exclude `MON_DOWN` from `CephClientRisk`. Fix: validate maintenance silence paths against the actual health labels before finalizing the page [Task 2]

codex
Using `superpowers:receiving-code-review` for the review discipline, then I’ll inspect the requested diff and tests without editing files.
exec
/bin/zsh -lc "sed -n '1,260p' /Users/ikaros/.codex/superpowers/skills/receiving-code-review/SKILL.md" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
---
name: receiving-code-review
description: Use when receiving code review feedback, before implementing suggestions, especially if feedback seems unclear or technically questionable - requires technical rigor and verification, not performative agreement or blind implementation
---

# Code Review Reception

## Overview

Code review requires technical evaluation, not emotional performance.

**Core principle:** Verify before implementing. Ask before assuming. Technical correctness over social comfort.

## The Response Pattern

```
WHEN receiving code review feedback:

1. READ: Complete feedback without reacting
2. UNDERSTAND: Restate requirement in own words (or ask)
3. VERIFY: Check against codebase reality
4. EVALUATE: Technically sound for THIS codebase?
5. RESPOND: Technical acknowledgment or reasoned pushback
6. IMPLEMENT: One item at a time, test each
```

## Forbidden Responses

**NEVER:**
- "You're absolutely right!" (explicit CLAUDE.md violation)
- "Great point!" / "Excellent feedback!" (performative)
- "Let me implement that now" (before verification)

**INSTEAD:**
- Restate the technical requirement
- Ask clarifying questions
- Push back with technical reasoning if wrong
- Just start working (actions > words)

## Handling Unclear Feedback

```
IF any item is unclear:
  STOP - do not implement anything yet
  ASK for clarification on unclear items

WHY: Items may be related. Partial understanding = wrong implementation.
```

**Example:**
```
your human partner: "Fix 1-6"
You understand 1,2,3,6. Unclear on 4,5.

❌ WRONG: Implement 1,2,3,6 now, ask about 4,5 later
✅ RIGHT: "I understand items 1,2,3,6. Need clarification on 4 and 5 before proceeding."
```

## Source-Specific Handling

### From your human partner
- **Trusted** - implement after understanding
- **Still ask** if scope unclear
- **No performative agreement**
- **Skip to action** or technical acknowledgment

### From External Reviewers
```
BEFORE implementing:
  1. Check: Technically correct for THIS codebase?
  2. Check: Breaks existing functionality?
  3. Check: Reason for current implementation?
  4. Check: Works on all platforms/versions?
  5. Check: Does reviewer understand full context?

IF suggestion seems wrong:
  Push back with technical reasoning

IF can't easily verify:
  Say so: "I can't verify this without [X]. Should I [investigate/ask/proceed]?"

IF conflicts with your human partner's prior decisions:
  Stop and discuss with your human partner first
```

**your human partner's rule:** "External feedback - be skeptical, but check carefully"

## YAGNI Check for "Professional" Features

```
IF reviewer suggests "implementing properly":
  grep codebase for actual usage

  IF unused: "This endpoint isn't called. Remove it (YAGNI)?"
  IF used: Then implement properly
```

**your human partner's rule:** "You and reviewer both report to me. If we don't need this feature, don't add it."

## Implementation Order

```
FOR multi-item feedback:
  1. Clarify anything unclear FIRST
  2. Then implement in this order:
     - Blocking issues (breaks, security)
     - Simple fixes (typos, imports)
     - Complex fixes (refactoring, logic)
  3. Test each fix individually
  4. Verify no regressions
```

## When To Push Back

Push back when:
- Suggestion breaks existing functionality
- Reviewer lacks full context
- Violates YAGNI (unused feature)
- Technically incorrect for this stack
- Legacy/compatibility reasons exist
- Conflicts with your human partner's architectural decisions

**How to push back:**
- Use technical reasoning, not defensiveness
- Ask specific questions
- Reference working tests/code
- Involve your human partner if architectural

**Signal if uncomfortable pushing back out loud:** "Strange things are afoot at the Circle K"

## Acknowledging Correct Feedback

When feedback IS correct:
```
✅ "Fixed. [Brief description of what changed]"
✅ "Good catch - [specific issue]. Fixed in [location]."
✅ [Just fix it and show in the code]

❌ "You're absolutely right!"
❌ "Great point!"
❌ "Thanks for catching that!"
❌ "Thanks for [anything]"
❌ ANY gratitude expression
```

**Why no thanks:** Actions speak. Just fix it. The code itself shows you heard the feedback.

**If you catch yourself about to write "Thanks":** DELETE IT. State the fix instead.

## Gracefully Correcting Your Pushback

If you pushed back and were wrong:
```
✅ "You were right - I checked [X] and it does [Y]. Implementing now."
✅ "Verified this and you're correct. My initial understanding was wrong because [reason]. Fixing."

❌ Long apology
❌ Defending why you pushed back
❌ Over-explaining
```

State the correction factually and move on.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Performative agreement | State requirement or just act |
| Blind implementation | Verify against codebase first |
| Batch without testing | One at a time, test each |
| Assuming reviewer is right | Check if breaks things |
| Avoiding pushback | Technical correctness > comfort |
| Partial implementation | Clarify all items first |
| Can't verify, proceed anyway | State limitation, ask for direction |

## Real Examples

**Performative Agreement (Bad):**
```
Reviewer: "Remove legacy code"
❌ "You're absolutely right! Let me remove that..."
```

**Technical Verification (Good):**
```
Reviewer: "Remove legacy code"
✅ "Checking... build target is 10.15+, this API needs 13+. Need legacy for backward compat. Current impl has wrong bundle ID - fix it or drop pre-13 support?"
```

**YAGNI (Good):**
```
Reviewer: "Implement proper metrics tracking with database, date filters, CSV export"
✅ "Grepped codebase - nothing calls this endpoint. Remove it (YAGNI)? Or is there usage I'm missing?"
```

**Unclear Item (Good):**
```
your human partner: "Fix items 1-6"
You understand 1,2,3,6. Unclear on 4,5.
✅ "Understand 1,2,3,6. Need clarification on 4 and 5 before implementing."
```

## GitHub Thread Replies

When replying to inline review comments on GitHub, reply in the comment thread (`gh api repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies`), not as a top-level PR comment.

## The Bottom Line

**External feedback = suggestions to evaluate, not orders to follow.**

Verify. Question. Then implement.

No performative agreement. Technical rigor always.

codex
I’m going to read the diff and the relevant current files side by side, then check tests only where they prove or contradict the expected exit semantics.
exec
/bin/zsh -lc "nl -ba run/collect.sh | sed -n '1,280p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
nl: run/collect.sh: No such file or directory

exec
/bin/zsh -lc "nl -ba lib/collect-cluster-rook.sh | sed -n '1,260p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
nl: lib/collect-cluster-rook.sh: No such file or directory

exec
/bin/zsh -lc 'git diff --stat 38c16e2..HEAD && git diff --find-renames --find-copies 38c16e2..HEAD -- run/collect.sh lib/collect-cluster-rook.sh tests/test-collect.sh tests/test-rook-collector.sh' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-5DhlYzvs' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-iVCsrx0R' (errno=Operation not permitted)
 .../2026-06-30-ceph-incident-bundle-autodetect.md  | 140 ++++++++
 .../reviews/2026-06-30-lab-validation.md           |   4 +
 ...06-30-ceph-incident-bundle-autodetect-design.md |  84 +++++
 experiments/ceph-incident-bundle/README.md         |  44 +--
 .../lib/collect-cluster-rook.sh                    |  49 ++-
 experiments/ceph-incident-bundle/run/collect.sh    | 191 +++++++----
 .../ceph-incident-bundle/tests/test-collect.sh     | 364 +++++++++++----------
 .../tests/test-rook-collector.sh                   |  44 ++-
 8 files changed, 664 insertions(+), 256 deletions(-)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-GTvl0bcL' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-O1IlZr3s' (errno=Operation not permitted)

exec
/bin/zsh -lc "nl -ba tests/test-collect.sh | sed -n '1,360p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
nl: tests/test-collect.sh: No such file or directory

codex
The files are under `experiments/ceph-incident-bundle/`, so I’m re-reading with the correct paths. The initial `git diff --stat` succeeded; the path-specific reads missed the subdirectory.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/run/collect.sh | sed -n '1,360p'" in /Users/ikaros/Documents/code/learning-k8s
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
    14	
    15	usage() {
    16	  cat <<'EOF'
    17	Usage: collect.sh --inventory PATH --ssh-key PATH [options]
    18	
    19	One command example:
    20	  bash experiments/ceph-incident-bundle/run/collect.sh \
    21	    --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
    22	    --ssh-key .ssh/id_ed25519 \
    23	    --mode cephadm \
    24	    --since 24h
    25	
    26	Required:
    27	  --inventory PATH       shell inventory with HOSTS=( "alias=host" ... )
    28	  --ssh-key PATH         SSH private key used to reach every node
    29	
    30	Options:
    31	  --seed USER@HOST       override inventory SEED_HOST
    32	  --out DIR              output dir (default: experiments/ceph-incident-bundle/results)
    33	  --mode auto|cephadm|rook   auto = per-node detect, collect ceph and/or rook layer
    34	  --kube-context CTX     kubectl context for the rook layer (default: none)
    35	  --since DURATION       log/journal window (default: 24h)
    36	  --timeout SECONDS      per-command / SSH-connect timeout (default: 20)
    37	  --node-timeout SECONDS overall timeout for one node's full collection (default: 600)
    38	  --skip-logs            collect state but skip larger Ceph log copies
    39	  --keep-workdir         keep temporary extracted workdir for debugging
    40	  --help                 print this help
    41	
    42	Output:
    43	  DIR/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
    44	
    45	Exit codes:
    46	  0 complete, 2 partial collection failure with bundle produced, 1 usage/config/verify failure
    47	EOF
    48	}
    49	
    50	parse_host_entry() {
    51	  local entry=$1
    52	  [[ "$entry" == *=* ]] || return 1
    53	  printf '%s\n' "${entry%%=*}" "${entry#*=}"
    54	}
    55	
    56	ssh_target_for_host() {
    57	  local host=$1 ssh_user=$2
    58	  if [[ "$host" == *@* || -z "$ssh_user" ]]; then
    59	    printf '%s' "$host"
    60	  else
    61	    printf '%s@%s' "$ssh_user" "$host"
    62	  fi
    63	}
    64	
    65	shell_quote() {
    66	  local value=$1
    67	  [[ "$value" != *"'"* ]] || return 1
    68	  printf "'%s'" "$value"
    69	}
    70	
    71	write_initial_metadata() {
    72	  local workdir=$1 mode=$2 seed=$3 since=$4 timeout=$5
    73	  local git_commit
    74	  git_commit="$(git -C "$COLLECT_ROOT/../.." rev-parse --short HEAD 2>/dev/null || printf unknown)"
    75	
    76	  cat >"$workdir/README-FIRST.txt" <<'EOF'
    77	Ceph incident bundle
    78	
    79	Start with:
    80	- summary.txt
    81	- errors.log
    82	- cluster/
    83	- nodes/
    84	
    85	This bundle is read-only evidence captured at incident time. Review it before sharing outside your team.
    86	EOF
    87	
    88	  cat >"$workdir/environment.txt" <<EOF
    89	created_utc=$(date -u +%FT%TZ)
    90	mode=$mode
    91	seed=$seed
    92	since=$since
    93	timeout=$timeout
    94	git_commit=$git_commit
    95	EOF
    96	
    97	  : >"$workdir/manifest.jsonl"
    98	  : >"$workdir/errors.log"
    99	}
   100	
   101	write_summary() {
   102	  local workdir=$1 mode=$2 seed=$3 node_ok=$4 node_failed=$5 cluster_status=$6 final_status=$7
   103	
   104	  {
   105	    printf 'Ceph incident bundle summary\n'
   106	    printf 'created_utc: %s\n' "$(date -u +%FT%TZ)"
   107	    printf 'mode: %s\n' "$mode"
   108	    printf 'seed: %s\n' "$seed"
   109	    printf 'cluster_status: %s\n' "$cluster_status"
   110	    printf 'node_ok: %s\n' "$node_ok"
   111	    printf 'node_failed: %s\n' "$node_failed"
   112	    printf 'final_status: %s\n' "$final_status"
   113	  } >"$workdir/summary.txt"
   114	}
   115	
   116	append_error() {
   117	  local workdir=$1 message=$2
   118	  printf '%s %s\n' "$(date -u +%FT%TZ)" "$message" >>"$workdir/errors.log"
   119	}
   120	
   121	detect_node_caps() {
   122	  # echo a space-joined subset of "cephadm kubectl" present on the target node
   123	  local target=$1 ssh_key=$2 timeout=$3
   124	  local tbin
   125	  local -a ssh_cmd
   126	  # SC2016: the probe script is single-quoted on purpose — it expands on the remote.
   127	  # shellcheck disable=SC2016
   128	  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
   129	  tbin="$(timeout_cmd)"
   130	  if [[ -n "$tbin" ]]; then
   131	    ssh_cmd=("$tbin" "$timeout" "${ssh_cmd[@]}")
   132	  fi
   133	  "${ssh_cmd[@]}" 2>/dev/null || true
   134	}
   135	
   136	# Probe each node once; pick cluster-ceph source (first cephadm node, or --seed)
   137	# and cluster-rook source (first kubectl node); collect each requested layer once.
   138	# Uses globals HOST_TARGETS (set by main).
   139	collect_clusters() {
   140	  local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8 kube_context=$9
   141	  local ceph_source='' rook_source='' i caps rc=0
   142	  local want_ceph=0 want_rook=0 ceph_done=0 rook_done=0
   143	  case "$mode" in
   144	    cephadm) want_ceph=1 ;;
   145	    rook) want_rook=1 ;;
   146	    auto) want_ceph=1; want_rook=1 ;;
   147	    *) return 1 ;;
   148	  esac
   149	
   150	  # explicit --seed pins the cluster-ceph source (no probe needed for it)
   151	  if [[ $want_ceph -eq 1 && -n "$seed" ]]; then
   152	    ceph_source="$seed"
   153	  fi
   154	
   155	  # probe nodes only if a source we need is still unknown
   156	  if { [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; } || [[ $want_rook -eq 1 ]]; then
   157	    if [[ ${#HOST_TARGETS[@]} -gt 0 ]]; then
   158	      for i in "${!HOST_TARGETS[@]}"; do
   159	        caps="$(detect_node_caps "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
   160	        if [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; then
   161	          case " $caps " in *" cephadm "*) ceph_source="${HOST_TARGETS[$i]}" ;; esac
   162	        fi
   163	        if [[ $want_rook -eq 1 && -z "$rook_source" ]]; then
   164	          case " $caps " in *" kubectl "*) rook_source="${HOST_TARGETS[$i]}" ;; esac
   165	        fi
   166	        if { [[ $want_ceph -eq 0 || -n "$ceph_source" ]]; } && { [[ $want_rook -eq 0 || -n "$rook_source" ]]; }; then
   167	          break
   168	        fi
   169	      done
   170	    fi
   171	  fi
   172	
   173	  # cluster-ceph layer
   174	  if [[ $want_ceph -eq 1 && -n "$ceph_source" ]]; then
   175	    collect_cluster_cephadm "$workdir" "$manifest" "$ceph_source" "$ssh_key" "$since" "$timeout" || rc=2
   176	    ceph_done=1
   177	  fi
   178	
   179	  # cluster-rook layer
   180	  if [[ $want_rook -eq 1 && -n "$rook_source" ]]; then
   181	    local -a rook_args
   182	    rook_args=(--out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout" --ssh-target "$rook_source" --ssh-key "$ssh_key")
   183	    [[ -n "$kube_context" ]] && rook_args+=(--kube-context "$kube_context")
   184	    [[ "$mode" == auto ]] && rook_args+=(--allow-skip)
   185	    collect_cluster_rook "${rook_args[@]}" || rc=2
   186	    rook_done=1
   187	  fi
   188	
   189	  # missing-source handling
   190	  if [[ "$mode" == cephadm && $ceph_done -eq 0 ]]; then
   191	    ensure_dir "$workdir/cluster/ceph"
   192	    printf 'SKIPPED: no cephadm-capable node found (or --seed unreachable)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
   193	    rc=2
   194	  elif [[ "$mode" == rook && $rook_done -eq 0 ]]; then
   195	    ensure_dir "$workdir/cluster/rook"
   196	    printf 'SKIPPED: no kubectl-capable node found\n' >"$workdir/cluster/rook/SKIPPED.txt"
   197	    rc=2
   198	  elif [[ "$mode" == auto ]]; then
   199	    # auto = collect whatever exists; only a hard failure if NEITHER layer found
   200	    if [[ $ceph_done -eq 0 ]]; then
   201	      ensure_dir "$workdir/cluster/ceph"
   202	      printf 'SKIPPED: no cephadm-capable node in inventory (auto)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
   203	    fi
   204	    if [[ $rook_done -eq 0 ]]; then
   205	      ensure_dir "$workdir/cluster/rook"
   206	      printf 'SKIPPED: no kubectl-capable node in inventory (auto)\n' >"$workdir/cluster/rook/SKIPPED.txt"
   207	    fi
   208	    if [[ $ceph_done -eq 0 && $rook_done -eq 0 ]]; then
   209	      rc=2
   210	    fi
   211	  fi
   212	
   213	  return "$rc"
   214	}
   215	
   216	collect_remote_node() {
   217	  local workdir=$1 alias=$2 target=$3 ssh_key=$4 since=$5 timeout=$6 skip_logs=$7 node_timeout=$8
   218	  local node_dir="$workdir/nodes/$alias"
   219	  local node_tar="$workdir/.node-$alias.tar.gz"
   220	  local remote_cmd rc=0 tbin
   221	  local q_alias q_since q_timeout
   222	  local -a ssh_cmd
   223	
   224	  q_alias="$(shell_quote "$alias")" || return 1
   225	  q_since="$(shell_quote "$since")" || return 1
   226	  q_timeout="$(shell_quote "$timeout")" || return 1
   227	
   228	  # Remote side uses a gzip pipe (not `tar -z`) so minimal/BusyBox tar still works,
   229	  # and traps its own temp dir so an interrupted/timed-out run leaves nothing behind.
   230	  remote_cmd="set -u; tmp=\"\${TMPDIR:-/tmp}/ceph-incident-node.\$\$\"; rm -rf \"\$tmp\"; mkdir -p \"\$tmp\" || { printf 'SKIPPED: remote tmp not writable\n' >&2; exit 75; }; trap 'rm -rf \"\$tmp\"' EXIT INT TERM; gzip -dc | tar -xf - -C \"\$tmp\"; out=\"\$tmp/out\"; set +e; bash \"\$tmp/lib/collect-node.sh\" --out \"\$out\" --host-alias $q_alias --since $q_since --timeout $q_timeout"
   231	  if [[ "$skip_logs" == "1" ]]; then
   232	    remote_cmd+=" --skip-logs"
   233	  fi
   234	  remote_cmd+="; rc=\$?; set -e; if [ -d \"\$out\" ]; then tar -cf - -C \"\$out\" . | gzip -c; else mkdir -p \"\$out\"; printf 'SKIPPED: remote collect-node did not create output\n' >\"\$out/SKIPPED.txt\"; tar -cf - -C \"\$out\" . | gzip -c; fi; exit \"\$rc\""
   235	
   236	  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" "$remote_cmd")
   237	  tbin="$(timeout_cmd)"
   238	  if [[ -n "$tbin" ]]; then
   239	    # Outer wrapper bounds the WHOLE node collection — must be the generous
   240	    # node timeout, never the small per-command timeout (which would kill a
   241	    # slow/large node mid-collection).
   242	    ssh_cmd=("$tbin" "$node_timeout" "${ssh_cmd[@]}")
   243	  fi
   244	
   245	  set +e
   246	  COPYFILE_DISABLE=1 tar -cf - -C "$COLLECT_ROOT" lib/common.sh lib/collect-node.sh | gzip -c |
   247	    "${ssh_cmd[@]}" >"$node_tar"
   248	  rc=$?
   249	  set -e
   250	
   251	  ensure_dir "$node_dir"
   252	  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
   253	    printf 'SKIPPED: node collection timed out after %ss (exit %s) from %s\n' "$node_timeout" "$rc" "$target" >"$node_dir/SKIPPED.txt"
   254	    rm -f "$node_tar"
   255	    return 2
   256	  fi
   257	
   258	  if [[ -s "$node_tar" ]] && tar -xzf "$node_tar" -C "$node_dir" >/dev/null 2>/dev/null; then
   259	    # A node that streamed a valid archive but is missing its own manifest.jsonl
   260	    # was truncated (partial/interrupted transfer) — do not count it as ok.
   261	    if [[ ! -f "$node_dir/manifest.jsonl" ]]; then
   262	      printf 'SKIPPED: node archive from %s is incomplete (no manifest.jsonl); treated as failure\n' "$target" >"$node_dir/SKIPPED.txt"
   263	      rc=2
   264	    fi
   265	  else
   266	    rm -rf "$node_dir"
   267	    ensure_dir "$node_dir"
   268	    printf 'SKIPPED: no usable node archive returned from %s (ssh exit %s)\n' "$target" "$rc" >"$node_dir/SKIPPED.txt"
   269	    [[ $rc -ne 0 ]] || rc=2
   270	  fi
   271	  rm -f "$node_tar"
   272	
   273	  return "$rc"
   274	}
   275	
   276	redact_bundle_text() {
   277	  local workdir=$1
   278	  local redaction_log="$workdir/redactions.log"
   279	  local path
   280	
   281	  while IFS= read -r path; do
   282	    case "$path" in
   283	      *.gz) redact_gz_file "$path" "$redaction_log" ;;
   284	      *) redact_file "$path" "$redaction_log" ;;
   285	    esac
   286	  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' -o -name '*.gz' \) -print 2>/dev/null || true)
   287	}
   288	
   289	# Single cleanup point. Uses globals (not main's locals) so it works as an
   290	# EXIT trap, which fires after main has returned and its locals are gone.
   291	CLEANUP_WORKDIR=
   292	CLEANUP_KEEP=0
   293	# Parsed inventory (alias/target pairs); filled by main, read by collect_clusters + node loop.
   294	HOST_ALIASES=()
   295	HOST_TARGETS=()
   296	cleanup_workdir() {
   297	  local rc=$?
   298	  if [[ -n "${CLEANUP_WORKDIR:-}" && -d "$CLEANUP_WORKDIR" ]]; then
   299	    if [[ "${CLEANUP_KEEP:-0}" -eq 1 ]]; then
   300	      printf 'kept workdir: %s\n' "$CLEANUP_WORKDIR" >&2
   301	    else
   302	      rm -rf -- "$CLEANUP_WORKDIR"
   303	    fi
   304	  fi
   305	  return "$rc"
   306	}
   307	
   308	main() {
   309	  local inventory='' ssh_key='' seed_override='' out_dir="$COLLECT_ROOT/results"
   310	  local mode=auto since=24h timeout=20 node_timeout=600 skip_logs=0 keep_workdir=0
   311	  local seed='' ssh_user='' seed_host='' rook_namespace=rook-ceph kube_context=''
   312	  local timestamp workdir manifest bundle rc=0 cluster_rc=0 node_ok=0 node_failed=0
   313	
   314	  if [[ $# -eq 0 ]]; then
   315	    usage >&2
   316	    return 1
   317	  fi
   318	
   319	  while [[ $# -gt 0 ]]; do
   320	    case "$1" in
   321	      --inventory)
   322	        inventory=${2-}
   323	        shift 2
   324	        ;;
   325	      --ssh-key)
   326	        ssh_key=${2-}
   327	        shift 2
   328	        ;;
   329	      --seed)
   330	        seed_override=${2-}
   331	        shift 2
   332	        ;;
   333	      --out)
   334	        out_dir=${2-}
   335	        shift 2
   336	        ;;
   337	      --mode)
   338	        mode=${2-}
   339	        shift 2
   340	        ;;
   341	      --kube-context)
   342	        kube_context=${2-}
   343	        shift 2
   344	        ;;
   345	      --since)
   346	        since=${2-}
   347	        shift 2
   348	        ;;
   349	      --timeout)
   350	        timeout=${2-}
   351	        shift 2
   352	        ;;
   353	      --node-timeout)
   354	        node_timeout=${2-}
   355	        shift 2
   356	        ;;
   357	      --skip-logs)
   358	        skip_logs=1
   359	        shift
   360	        ;;

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh | sed -n '1,320p'" in /Users/ikaros/Documents/code/learning-k8s
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
    16	       [--since DURATION] [--timeout SECONDS] [--allow-skip]
    17	       [--ssh-target USER@HOST --ssh-key PATH] [--kube-context CTX]
    18	EOF
    19	}
    20	
    21	rook_skip() {
    22	  local outdir=$1 reason=$2
    23	  local artifact="$outdir/cluster/rook/SKIPPED.txt"
    24	  ensure_dir "$(dirname -- "$artifact")"
    25	  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
    26	}
    27	
    28	rook_write_skip_artifact() {
    29	  local artifact=$1 reason=$2
    30	  ensure_dir "$(dirname -- "$artifact")"
    31	  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
    32	}
    33	
    34	rook_run_capture() {
    35	  local outdir=$1 manifest=$2 timeout=$3 artifact_rel=$4
    36	  shift 4
    37	
    38	  local artifact="$outdir/$artifact_rel"
    39	  if ! COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
    40	    run_capture "$manifest" "rook" "collect-cluster-rook" "$artifact" -- "$@"; then
    41	    return 2
    42	  fi
    43	  return 0
    44	}
    45	
    46	rook_get_first_pod() {
    47	  local namespace=$1 label=$2
    48	  # -o name (not jsonpath) so the arg has no braces/brackets to mangle over ssh.
    49	  "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -l "$label" -o name 2>/dev/null |
    50	    head -n1 | sed 's#^pod/##'
    51	}
    52	
    53	collect_cluster_rook() {
    54	  local outdir='' manifest='' namespace=rook-ceph since=24h timeout=20 allow_skip=0
    55	  local ssh_target='' ssh_key='' kube_context=''
    56	
    57	  while [[ $# -gt 0 ]]; do
    58	    case "$1" in
    59	      --out)
    60	        outdir=${2-}
    61	        shift 2
    62	        ;;
    63	      --manifest)
    64	        manifest=${2-}
    65	        shift 2
    66	        ;;
    67	      --namespace)
    68	        namespace=${2-}
    69	        shift 2
    70	        ;;
    71	      --since)
    72	        since=${2-}
    73	        shift 2
    74	        ;;
    75	      --timeout)
    76	        timeout=${2-}
    77	        shift 2
    78	        ;;
    79	      --allow-skip)
    80	        allow_skip=1
    81	        shift
    82	        ;;
    83	      --ssh-target)
    84	        ssh_target=${2-}
    85	        shift 2
    86	        ;;
    87	      --ssh-key)
    88	        ssh_key=${2-}
    89	        shift 2
    90	        ;;
    91	      --kube-context)
    92	        kube_context=${2-}
    93	        shift 2
    94	        ;;
    95	      --help|-h)
    96	        usage
    97	        return 0
    98	        ;;
    99	      *)
   100	        usage >&2
   101	        return 1
   102	        ;;
   103	    esac
   104	  done
   105	
   106	  [[ -n "$outdir" && -n "$manifest" ]] || {
   107	    usage >&2
   108	    return 1
   109	  }
   110	
   111	  ensure_dir "$outdir/cluster/rook"
   112	
   113	  # Build the kubectl prefix once. With --ssh-target, kubectl runs ON that node
   114	  # over ssh (the node where kubectl/kubeconfig lives); otherwise locally.
   115	  # ROOK_KUBECTL_ARGV is global so rook_get_first_pod can use the same prefix.
   116	  if [[ -n "$ssh_target" ]]; then
   117	    ROOK_KUBECTL_ARGV=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$ssh_target" kubectl)
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
   133	    rook_skip "$outdir" "namespace not found: $namespace"
   134	    [[ "$allow_skip" == "1" ]] && return 0 || return 2
   135	  fi
   136	
   137	  local failed=0
   138	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/pods-wide.txt" \
   139	    "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -o wide; then
   140	    failed=1
   141	  fi
   142	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/events.txt" \
   143	    "${ROOK_KUBECTL_ARGV[@]}" get events -n "$namespace" --sort-by=.lastTimestamp; then
   144	    failed=1
   145	  fi
   146	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/rook-resources.yaml" \
   147	    "${ROOK_KUBECTL_ARGV[@]}" get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n "$namespace" -o yaml; then
   148	    failed=1
   149	  fi
   150	
   151	  local operator_pod toolbox_pod
   152	  operator_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-operator")"
   153	  if [[ -n "$operator_pod" ]]; then
   154	    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
   155	      "${ROOK_KUBECTL_ARGV[@]}" logs -n "$namespace" "$operator_pod" --since="$since"; then
   156	      failed=1
   157	    fi
   158	  else
   159	    rook_write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found"
   160	  fi
   161	
   162	  toolbox_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-tools")"
   163	  if [[ -n "$toolbox_pod" ]]; then
   164	    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
   165	      "${ROOK_KUBECTL_ARGV[@]}" exec -n "$namespace" "$toolbox_pod" -- ceph status; then
   166	      failed=1
   167	    fi
   168	  else
   169	    rook_write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
   170	  fi
   171	
   172	  [[ $failed -eq 0 ]] || return 2
   173	  return 0
   174	}
   175	
   176	if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
   177	  collect_cluster_rook "$@"
   178	fi

exec
/bin/zsh -lc 'git diff --find-renames --find-copies 38c16e2..HEAD -- experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh experiments/ceph-incident-bundle/tests/test-collect.sh experiments/ceph-incident-bundle/tests/test-rook-collector.sh' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-Xwhgw7mQ' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-2SMFrpSp' (errno=Operation not permitted)
diff --git a/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh b/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
index 24d7d50..7545827 100644
--- a/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
+++ b/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
@@ -7,9 +7,14 @@ ROOK_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 # shellcheck disable=SC1091
 source "$ROOK_COLLECTOR_DIR/common.sh"
 
+# Default kubectl prefix (local); collect_cluster_rook overrides it per call.
+ROOK_KUBECTL_ARGV=(kubectl)
+
 usage() {
   cat <<'EOF'
-Usage: collect-cluster-rook.sh --out DIR --manifest PATH [--namespace rook-ceph] [--since DURATION] [--timeout SECONDS]
+Usage: collect-cluster-rook.sh --out DIR --manifest PATH [--namespace rook-ceph]
+       [--since DURATION] [--timeout SECONDS] [--allow-skip]
+       [--ssh-target USER@HOST --ssh-key PATH] [--kube-context CTX]
 EOF
 }
 
@@ -40,11 +45,14 @@ rook_run_capture() {
 
 rook_get_first_pod() {
   local namespace=$1 label=$2
-  kubectl get pods -n "$namespace" -l "$label" -o 'jsonpath={.items[0].metadata.name}' 2>/dev/null || true
+  # -o name (not jsonpath) so the arg has no braces/brackets to mangle over ssh.
+  "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -l "$label" -o name 2>/dev/null |
+    head -n1 | sed 's#^pod/##'
 }
 
 collect_cluster_rook() {
   local outdir='' manifest='' namespace=rook-ceph since=24h timeout=20 allow_skip=0
+  local ssh_target='' ssh_key='' kube_context=''
 
   while [[ $# -gt 0 ]]; do
     case "$1" in
@@ -72,6 +80,18 @@ collect_cluster_rook() {
         allow_skip=1
         shift
         ;;
+      --ssh-target)
+        ssh_target=${2-}
+        shift 2
+        ;;
+      --ssh-key)
+        ssh_key=${2-}
+        shift 2
+        ;;
+      --kube-context)
+        kube_context=${2-}
+        shift 2
+        ;;
       --help|-h)
         usage
         return 0
@@ -90,30 +110,41 @@ collect_cluster_rook() {
 
   ensure_dir "$outdir/cluster/rook"
 
+  # Build the kubectl prefix once. With --ssh-target, kubectl runs ON that node
+  # over ssh (the node where kubectl/kubeconfig lives); otherwise locally.
+  # ROOK_KUBECTL_ARGV is global so rook_get_first_pod can use the same prefix.
+  if [[ -n "$ssh_target" ]]; then
+    ROOK_KUBECTL_ARGV=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$ssh_target" kubectl)
+  else
+    ROOK_KUBECTL_ARGV=(kubectl)
+  fi
+  [[ -n "$kube_context" ]] && ROOK_KUBECTL_ARGV+=(--context "$kube_context")
+
   # Missing kubectl / namespace means we collected NO cluster evidence. In
   # explicit rook mode that is a partial failure (exit 2) so the bundle does not
   # falsely look complete; auto-mode fallback passes --allow-skip to tolerate it.
-  if ! command -v kubectl >/dev/null 2>&1; then
+  # (When kubectl is remote we already probed it exists, so skip the local check.)
+  if [[ -z "$ssh_target" ]] && ! command -v kubectl >/dev/null 2>&1; then
     rook_skip "$outdir" "kubectl command not found"
     [[ "$allow_skip" == "1" ]] && return 0 || return 2
   fi
 
-  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
+  if ! "${ROOK_KUBECTL_ARGV[@]}" get namespace "$namespace" >/dev/null 2>&1; then
     rook_skip "$outdir" "namespace not found: $namespace"
     [[ "$allow_skip" == "1" ]] && return 0 || return 2
   fi
 
   local failed=0
   if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/pods-wide.txt" \
-    kubectl get pods -n "$namespace" -o wide; then
+    "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -o wide; then
     failed=1
   fi
   if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/events.txt" \
-    kubectl get events -n "$namespace" --sort-by=.lastTimestamp; then
+    "${ROOK_KUBECTL_ARGV[@]}" get events -n "$namespace" --sort-by=.lastTimestamp; then
     failed=1
   fi
   if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/rook-resources.yaml" \
-    kubectl get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n "$namespace" -o yaml; then
+    "${ROOK_KUBECTL_ARGV[@]}" get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n "$namespace" -o yaml; then
     failed=1
   fi
 
@@ -121,7 +152,7 @@ collect_cluster_rook() {
   operator_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-operator")"
   if [[ -n "$operator_pod" ]]; then
     if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
-      kubectl logs -n "$namespace" "$operator_pod" --since="$since"; then
+      "${ROOK_KUBECTL_ARGV[@]}" logs -n "$namespace" "$operator_pod" --since="$since"; then
       failed=1
     fi
   else
@@ -131,7 +162,7 @@ collect_cluster_rook() {
   toolbox_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-tools")"
   if [[ -n "$toolbox_pod" ]]; then
     if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
-      kubectl exec -n "$namespace" "$toolbox_pod" -- ceph status; then
+      "${ROOK_KUBECTL_ARGV[@]}" exec -n "$namespace" "$toolbox_pod" -- ceph status; then
       failed=1
     fi
   else
diff --git a/experiments/ceph-incident-bundle/run/collect.sh b/experiments/ceph-incident-bundle/run/collect.sh
index bf42c7f..e9ceebd 100755
--- a/experiments/ceph-incident-bundle/run/collect.sh
+++ b/experiments/ceph-incident-bundle/run/collect.sh
@@ -30,7 +30,8 @@ Required:
 Options:
   --seed USER@HOST       override inventory SEED_HOST
   --out DIR              output dir (default: experiments/ceph-incident-bundle/results)
-  --mode auto|cephadm|rook
+  --mode auto|cephadm|rook   auto = per-node detect, collect ceph and/or rook layer
+  --kube-context CTX     kubectl context for the rook layer (default: none)
   --since DURATION       log/journal window (default: 24h)
   --timeout SECONDS      per-command / SSH-connect timeout (default: 20)
   --node-timeout SECONDS overall timeout for one node's full collection (default: 600)
@@ -117,36 +118,99 @@ append_error() {
   printf '%s %s\n' "$(date -u +%FT%TZ)" "$message" >>"$workdir/errors.log"
 }
 
-run_cluster_collector() {
-  local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8
-  local -a probe_cmd
+detect_node_caps() {
+  # echo a space-joined subset of "cephadm kubectl" present on the target node
+  local target=$1 ssh_key=$2 timeout=$3
+  local tbin
+  local -a ssh_cmd
+  # SC2016: the probe script is single-quoted on purpose — it expands on the remote.
+  # shellcheck disable=SC2016
+  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
+  tbin="$(timeout_cmd)"
+  if [[ -n "$tbin" ]]; then
+    ssh_cmd=("$tbin" "$timeout" "${ssh_cmd[@]}")
+  fi
+  "${ssh_cmd[@]}" 2>/dev/null || true
+}
 
+# Probe each node once; pick cluster-ceph source (first cephadm node, or --seed)
+# and cluster-rook source (first kubectl node); collect each requested layer once.
+# Uses globals HOST_TARGETS (set by main).
+collect_clusters() {
+  local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8 kube_context=$9
+  local ceph_source='' rook_source='' i caps rc=0
+  local want_ceph=0 want_rook=0 ceph_done=0 rook_done=0
   case "$mode" in
-    cephadm)
-      [[ -n "$seed" && -n "$ssh_key" ]] || return 1
-      collect_cluster_cephadm "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout"
-      ;;
-    rook)
-      collect_cluster_rook --out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout"
-      ;;
-    auto)
-      local probe_tbin
-      probe_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$seed" command -v cephadm)
-      probe_tbin="$(timeout_cmd)"
-      if [[ -n "$probe_tbin" ]]; then
-        probe_cmd=("$probe_tbin" "$timeout" "${probe_cmd[@]}")
-      fi
-      if [[ -n "$seed" && -n "$ssh_key" ]] && "${probe_cmd[@]}" >/dev/null 2>&1; then
-        collect_cluster_cephadm "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout"
-      else
-        # auto-fallback is a guess; tolerate a non-rook cluster gracefully
-        collect_cluster_rook --out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout" --allow-skip
-      fi
-      ;;
-    *)
-      return 1
-      ;;
+    cephadm) want_ceph=1 ;;
+    rook) want_rook=1 ;;
+    auto) want_ceph=1; want_rook=1 ;;
+    *) return 1 ;;
   esac
+
+  # explicit --seed pins the cluster-ceph source (no probe needed for it)
+  if [[ $want_ceph -eq 1 && -n "$seed" ]]; then
+    ceph_source="$seed"
+  fi
+
+  # probe nodes only if a source we need is still unknown
+  if { [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; } || [[ $want_rook -eq 1 ]]; then
+    if [[ ${#HOST_TARGETS[@]} -gt 0 ]]; then
+      for i in "${!HOST_TARGETS[@]}"; do
+        caps="$(detect_node_caps "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
+        if [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; then
+          case " $caps " in *" cephadm "*) ceph_source="${HOST_TARGETS[$i]}" ;; esac
+        fi
+        if [[ $want_rook -eq 1 && -z "$rook_source" ]]; then
+          case " $caps " in *" kubectl "*) rook_source="${HOST_TARGETS[$i]}" ;; esac
+        fi
+        if { [[ $want_ceph -eq 0 || -n "$ceph_source" ]]; } && { [[ $want_rook -eq 0 || -n "$rook_source" ]]; }; then
+          break
+        fi
+      done
+    fi
+  fi
+
+  # cluster-ceph layer
+  if [[ $want_ceph -eq 1 && -n "$ceph_source" ]]; then
+    collect_cluster_cephadm "$workdir" "$manifest" "$ceph_source" "$ssh_key" "$since" "$timeout" || rc=2
+    ceph_done=1
+  fi
+
+  # cluster-rook layer
+  if [[ $want_rook -eq 1 && -n "$rook_source" ]]; then
+    local -a rook_args
+    rook_args=(--out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout" --ssh-target "$rook_source" --ssh-key "$ssh_key")
+    [[ -n "$kube_context" ]] && rook_args+=(--kube-context "$kube_context")
+    [[ "$mode" == auto ]] && rook_args+=(--allow-skip)
+    collect_cluster_rook "${rook_args[@]}" || rc=2
+    rook_done=1
+  fi
+
+  # missing-source handling
+  if [[ "$mode" == cephadm && $ceph_done -eq 0 ]]; then
+    ensure_dir "$workdir/cluster/ceph"
+    printf 'SKIPPED: no cephadm-capable node found (or --seed unreachable)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
+    rc=2
+  elif [[ "$mode" == rook && $rook_done -eq 0 ]]; then
+    ensure_dir "$workdir/cluster/rook"
+    printf 'SKIPPED: no kubectl-capable node found\n' >"$workdir/cluster/rook/SKIPPED.txt"
+    rc=2
+  elif [[ "$mode" == auto ]]; then
+    # auto = collect whatever exists; only a hard failure if NEITHER layer found
+    if [[ $ceph_done -eq 0 ]]; then
+      ensure_dir "$workdir/cluster/ceph"
+      printf 'SKIPPED: no cephadm-capable node in inventory (auto)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
+    fi
+    if [[ $rook_done -eq 0 ]]; then
+      ensure_dir "$workdir/cluster/rook"
+      printf 'SKIPPED: no kubectl-capable node in inventory (auto)\n' >"$workdir/cluster/rook/SKIPPED.txt"
+    fi
+    if [[ $ceph_done -eq 0 && $rook_done -eq 0 ]]; then
+      rc=2
+    fi
+  fi
+
+  return "$rc"
 }
 
 collect_remote_node() {
@@ -226,6 +290,9 @@ redact_bundle_text() {
 # EXIT trap, which fires after main has returned and its locals are gone.
 CLEANUP_WORKDIR=
 CLEANUP_KEEP=0
+# Parsed inventory (alias/target pairs); filled by main, read by collect_clusters + node loop.
+HOST_ALIASES=()
+HOST_TARGETS=()
 cleanup_workdir() {
   local rc=$?
   if [[ -n "${CLEANUP_WORKDIR:-}" && -d "$CLEANUP_WORKDIR" ]]; then
@@ -241,7 +308,7 @@ cleanup_workdir() {
 main() {
   local inventory='' ssh_key='' seed_override='' out_dir="$COLLECT_ROOT/results"
   local mode=auto since=24h timeout=20 node_timeout=600 skip_logs=0 keep_workdir=0
-  local seed='' ssh_user='' seed_host='' rook_namespace=rook-ceph
+  local seed='' ssh_user='' seed_host='' rook_namespace=rook-ceph kube_context=''
   local timestamp workdir manifest bundle rc=0 cluster_rc=0 node_ok=0 node_failed=0
 
   if [[ $# -eq 0 ]]; then
@@ -271,6 +338,10 @@ main() {
         mode=${2-}
         shift 2
         ;;
+      --kube-context)
+        kube_context=${2-}
+        shift 2
+        ;;
       --since)
         since=${2-}
         shift 2
@@ -336,43 +407,45 @@ main() {
   trap cleanup_workdir EXIT INT TERM
   write_initial_metadata "$workdir" "$mode" "$seed" "$since" "$timeout"
 
+  # Parse HOSTS once into globals (used by the cluster capability probe AND the
+  # node loop). A malformed entry is recorded but must not abort collection.
+  local entry
+  HOST_ALIASES=()
+  HOST_TARGETS=()
+  for entry in "${HOSTS[@]}"; do
+    if [[ "$entry" != *=* || -z "${entry%%=*}" || -z "${entry#*=}" ]]; then
+      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
+      rc=2
+      continue
+    fi
+    HOST_ALIASES+=("${entry%%=*}")
+    HOST_TARGETS+=("$(ssh_target_for_host "${entry#*=}" "$ssh_user")")
+  done
+
   set +e
-  run_cluster_collector "$mode" "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout" "$rook_namespace"
+  collect_clusters "$mode" "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout" "$rook_namespace" "$kube_context"
   cluster_rc=$?
   set -e
   if [[ $cluster_rc -ne 0 ]]; then
-    append_error "$workdir" "cluster collector exited $cluster_rc"
+    append_error "$workdir" "cluster collection exited $cluster_rc"
     rc=2
   fi
 
-  local entry alias host target node_rc
-  for entry in "${HOSTS[@]}"; do
-    # Robust parse: a malformed entry must not abort an in-progress collection.
-    if [[ "$entry" != *=* ]]; then
-      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
-      node_failed=$((node_failed + 1))
-      rc=2
-      continue
-    fi
-    alias="${entry%%=*}"
-    host="${entry#*=}"
-    if [[ -z "$alias" || -z "$host" ]]; then
-      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
-      node_failed=$((node_failed + 1))
-      rc=2
-      continue
-    fi
-    target="$(ssh_target_for_host "$host" "$ssh_user")"
-
-    if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs" "$node_timeout"; then
-      node_ok=$((node_ok + 1))
-    else
-      node_rc=$?
-      node_failed=$((node_failed + 1))
-      append_error "$workdir" "node $alias ($target) collector exited $node_rc"
-      rc=2
-    fi
-  done
+  local i alias target node_rc
+  if [[ ${#HOST_ALIASES[@]} -gt 0 ]]; then
+    for i in "${!HOST_ALIASES[@]}"; do
+      alias="${HOST_ALIASES[$i]}"
+      target="${HOST_TARGETS[$i]}"
+      if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs" "$node_timeout"; then
+        node_ok=$((node_ok + 1))
+      else
+        node_rc=$?
+        node_failed=$((node_failed + 1))
+        append_error "$workdir" "node $alias ($target) collector exited $node_rc"
+        rc=2
+      fi
+    done
+  fi
 
   # Test-only hook: simulate a mid-run abort to exercise trap cleanup. Inert in production.
   if [[ -n "${COLLECT_TEST_ABORT_AFTER_NODES:-}" ]]; then
diff --git a/experiments/ceph-incident-bundle/tests/test-collect.sh b/experiments/ceph-incident-bundle/tests/test-collect.sh
index 5c387c5..bf5840a 100755
--- a/experiments/ceph-incident-bundle/tests/test-collect.sh
+++ b/experiments/ceph-incident-bundle/tests/test-collect.sh
@@ -29,225 +29,261 @@ assert_archive_contains() {
   tar -tzf "$bundle" | sed 's#^\./##' | grep -qF "$expected" || fail "archive missing $expected"
 }
 
-assert_archive_file_contains() {
-  local bundle=$1 path=$2 expected=$3
-  tar -xOzf "$bundle" "./$path" 2>/dev/null | grep -qF "$expected" || fail "archive file $path missing $expected"
-}
-
 tmpdir="$(mktemp -d)"
 trap 'rm -rf "$tmpdir"' EXIT
 
+# ---------------------------------------------------------------------------
+# usage / arg validation
+# ---------------------------------------------------------------------------
 help_result="$(run_and_capture "$ROOT/run/collect.sh" --help)"
 help_status="${help_result%%$'\n'*}"
 help_output="${help_result#*$'\n'}"
 [[ "$help_status" == "0" ]] || fail "collect.sh --help exited $help_status"
 [[ "$help_output" == *"Usage:"* ]] || fail "collect.sh --help did not print usage"
+[[ "$help_output" == *"--kube-context"* ]] || fail "help should document --kube-context"
 
 missing_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$tmpdir/missing.env")"
 missing_status="${missing_result%%$'\n'*}"
 [[ "$missing_status" == "1" ]] || fail "missing inventory should exit 1, got $missing_status"
 
+# ---------------------------------------------------------------------------
+# fake bins: capability-aware ssh, fake kubectl, passthrough timeout
+#   ssh dispatches by the remote command:
+#     - "command -v cephadm" (capability probe) -> emit caps based on target
+#     - "cephadm shell -- ceph"                 -> delegate to the ceph fixture ssh
+#     - "kubectl"                               -> forward to the fake kubectl
+#     - "collect-node.sh"                       -> fabricate a node bundle tar
+#   Caps per target come from FAKE_CEPH_TARGETS / FAKE_KUBE_TARGETS (substrings).
+# ---------------------------------------------------------------------------
 fakebin="$tmpdir/fakebin"
 mkdir -p "$fakebin"
 
 cat >"$fakebin/kubectl" <<'EOF'
 #!/usr/bin/env bash
 set -euo pipefail
-printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG:?}"
+[[ "${1:-}" == "--context" ]] && shift 2
 cmd="$*"
 case "$cmd" in
-  "get namespace rook-ceph")
-    printf 'rook-ceph\n'
-    ;;
-  "get pods -n rook-ceph -o wide")
-    printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n'
-    ;;
-  "get events -n rook-ceph --sort-by=.lastTimestamp")
-    printf 'LAST SEEN TYPE REASON OBJECT MESSAGE\n1m Normal Started pod/osd started\n'
-    ;;
-  "get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n rook-ceph -o yaml")
-    printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n'
-    ;;
-  "get pods -n rook-ceph -l app=rook-ceph-operator -o jsonpath={.items[0].metadata.name}")
-    printf 'rook-ceph-operator-0'
-    ;;
-  "logs -n rook-ceph rook-ceph-operator-0 --since=24h")
-    printf 'operator log line\n'
-    ;;
-  "get pods -n rook-ceph -l app=rook-ceph-tools -o jsonpath={.items[0].metadata.name}")
-    exit 0
-    ;;
-  *)
-    printf 'unexpected kubectl command: %s\n' "$cmd" >&2
-    exit 99
-    ;;
+  "get namespace rook-ceph") printf 'rook-ceph\n' ;;
+  "get pods -n rook-ceph -o wide") printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n' ;;
+  "get events -n rook-ceph --sort-by=.lastTimestamp") printf 'LAST SEEN TYPE\n1m Normal\n' ;;
+  *"-n rook-ceph -o yaml") printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n' ;;
+  "get pods -n rook-ceph -l app=rook-ceph-operator -o name") printf 'pod/rook-ceph-operator-0\n' ;;
+  "logs -n rook-ceph rook-ceph-operator-0 --since="*) printf 'operator log line\n' ;;
+  "get pods -n rook-ceph -l app=rook-ceph-tools -o name") exit 0 ;;
+  *) printf 'unexpected kubectl: %s\n' "$cmd" >&2; exit 99 ;;
 esac
 EOF
 
-cat >"$fakebin/ssh" <<'EOF'
-#!/usr/bin/env bash
-set -euo pipefail
-printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
-cat >/dev/null
-
-remote_command="${@: -1}"
-alias_name="$(printf '%s\n' "$remote_command" | sed -n "s/.*--host-alias '\\([^']*\\)'.*/\\1/p")"
-[[ -n "$alias_name" ]] || {
-  printf 'remote command did not preserve quoted --host-alias: %s\n' "$remote_command" >&2
-  exit 99
-}
-if [[ "${FAKE_SSH_BAD_TAR_ALIAS:-}" == "$alias_name" ]]; then
-  printf 'not a tar archive\n'
-  exit 0
-fi
-
-sleep "${FAKE_SSH_SLEEP:-0}"
-
-tmpdir="$(mktemp -d)"
-trap 'rm -rf "$tmpdir"' EXIT
-mkdir -p "$tmpdir/system"
-mkdir -p "$tmpdir/cephadm/var-lib-ceph-configs/fsid/mon.a"
-printf 'node %s\n' "$alias_name" >"$tmpdir/system/hostname.txt"
-printf 'secret = should-redact\n' >"$tmpdir/cephadm/var-lib-ceph-configs/fsid/mon.a/config"
-if [[ "${FAKE_SSH_NO_MANIFEST_ALIAS:-}" != "$alias_name" ]]; then
-  printf '{"node":"%s"}\n' "$alias_name" >"$tmpdir/manifest.jsonl"
-fi
-if [[ "${FAKE_SSH_PEM_ALIAS:-}" == "$alias_name" ]]; then
-  printf 'cert\n' >"$tmpdir/system/leak.pem"
-fi
-tar -czf - -C "$tmpdir" .
-
-if [[ "${FAKE_SSH_FAIL_ALIAS:-}" == "$alias_name" ]]; then
-  exit 2
-fi
-EOF
 cat >"$fakebin/timeout" <<'EOF'
 #!/usr/bin/env bash
 printf '%s\n' "$1" >>"${FAKE_TIMEOUT_LOG:?}"
 shift
 exec "$@"
 EOF
+
+cat >"$fakebin/ssh" <<'EOF'
+#!/usr/bin/env bash
+set -euo pipefail
+printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
+whole="$*"
+args=("$@")
+n=${#args[@]}
+
+# Order matters: the capability-probe script also contains "kubectl", so it must
+# be matched before the kubectl-forward branch.
+case "$whole" in
+  *"command -v cephadm"*)
+    target="${args[$((n-2))]}"   # probe sends a single-arg remote script
+    caps=""
+    for t in ${FAKE_CEPH_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps cephadm"; done
+    for t in ${FAKE_KUBE_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps kubectl"; done
+    printf '%s\n' "$caps"
+    exit 0
+    ;;
+  *"cephadm shell -- ceph"*)
+    exec "$FIXTURE_SSH" "$@"
+    ;;
+  *collect-node.sh*)
+    alias_name="$(printf '%s\n' "$whole" | sed -n "s/.*--host-alias '\\([^']*\\)'.*/\\1/p")"
+    cat >/dev/null
+    [[ -n "$alias_name" ]] || { printf 'no alias\n' >&2; exit 99; }
+    if [[ "${FAKE_SSH_BAD_TAR_ALIAS:-}" == "$alias_name" ]]; then
+      printf 'not a tar archive\n'; exit 0
+    fi
+    sleep "${FAKE_SSH_SLEEP:-0}"
+    t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
+    mkdir -p "$t/system"
+    printf 'node %s\n' "$alias_name" >"$t/system/hostname.txt"
+    if [[ "${FAKE_SSH_NO_MANIFEST_ALIAS:-}" != "$alias_name" ]]; then
+      printf '{"node":"%s"}\n' "$alias_name" >"$t/manifest.jsonl"
+    fi
+    [[ "${FAKE_SSH_PEM_ALIAS:-}" == "$alias_name" ]] && printf 'cert\n' >"$t/system/leak.pem"
+    tar -czf - -C "$t" .
+    [[ "${FAKE_SSH_FAIL_ALIAS:-}" == "$alias_name" ]] && exit 2
+    exit 0
+    ;;
+  *kubectl*)
+    seen=0; kargs=()
+    for a in "$@"; do
+      if [[ $seen -eq 1 ]]; then kargs+=("$a"); continue; fi
+      [[ "$a" == "kubectl" ]] && seen=1
+    done
+    exec kubectl "${kargs[@]}"
+    ;;
+  *)
+    printf 'unexpected ssh remote: %s\n' "$remote" >&2
+    exit 99
+    ;;
+esac
+EOF
 chmod +x "$fakebin/kubectl" "$fakebin/ssh" "$fakebin/timeout"
 
-inventory="$tmpdir/inventory.env"
+ssh_key="$tmpdir/id_ed25519"
+printf 'fake key\n' >"$ssh_key"
+export FAKE_SSH_LOG="$tmpdir/ssh.log"
+export FAKE_TIMEOUT_LOG="$tmpdir/timeout.log"
+export FIXTURE_SSH="$ROOT/tests/fixtures/bin/ssh"
+
+# external topology: a ceph node + a kube node
+inventory="$tmpdir/inv-external.env"
 cat >"$inventory" <<'EOF'
 SSH_USER="tester"
-SEED_HOST="seed.example.invalid"
 ROOK_NAMESPACE="rook-ceph"
 HOSTS=(
-  "monitor01=10.0.0.1"
-  "osd01=10.0.0.2"
+  "cephnode=10.0.0.1"
+  "kubenode=10.0.0.9"
 )
 EOF
 
-ssh_key="$tmpdir/id_ed25519"
-printf 'fake key\n' >"$ssh_key"
-
-export FAKE_KUBECTL_LOG="$tmpdir/kubectl.log"
-export FAKE_SSH_LOG="$tmpdir/ssh.log"
-export FAKE_TIMEOUT_LOG="$tmpdir/timeout.log"
-
-out_success="$tmpdir/out-success"
+# ---------------------------------------------------------------------------
+# auto: dual-layer collection (ceph from cephnode, rook from kubenode), --context
+# ---------------------------------------------------------------------------
+out_auto="$tmpdir/out-auto"
+: >"$FAKE_SSH_LOG"
+FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="10.0.0.9" \
 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
-  --inventory "$inventory" \
-  --ssh-key "$ssh_key" \
-  --seed tester@seed.example.invalid \
-  --mode rook \
-  --out "$out_success" \
-  --since 24h \
-  --timeout 5 \
-  --node-timeout 90
-
-bundle_success="$(find_bundle "$out_success")"
-assert_archive_contains "$bundle_success" "manifest.jsonl"
-assert_archive_contains "$bundle_success" "summary.txt"
-assert_archive_contains "$bundle_success" "README-FIRST.txt"
-assert_archive_contains "$bundle_success" "cluster/rook/pods-wide.txt"
-assert_archive_contains "$bundle_success" "nodes/monitor01/system/hostname.txt"
-assert_archive_contains "$bundle_success" "nodes/osd01/system/hostname.txt"
-assert_archive_file_contains "$bundle_success" "nodes/monitor01/cephadm/var-lib-ceph-configs/fsid/mon.a/config" "[REDACTED]"
-grep -qF 'ConnectTimeout=5' "$FAKE_SSH_LOG" || fail "ssh calls should include ConnectTimeout from --timeout"
-# C1: the whole-node SSH wrapper must use --node-timeout (90), not the per-command timeout (5)
-grep -qx '90' "$FAKE_TIMEOUT_LOG" || fail "node SSH wrapper should use --node-timeout (90); timeout log: $(cat "$FAKE_TIMEOUT_LOG")"
-
-out_partial="$tmpdir/out-partial"
-partial_status=0
+  --inventory "$inventory" --ssh-key "$ssh_key" \
+  --mode auto --kube-context lab --out "$out_auto" --since 24h --timeout 5 --node-timeout 90
+bundle_auto="$(find_bundle "$out_auto")"
+assert_archive_contains "$bundle_auto" "cluster/ceph/json/status.json"
+assert_archive_contains "$bundle_auto" "cluster/rook/pods-wide.txt"
+assert_archive_contains "$bundle_auto" "nodes/cephnode/system/hostname.txt"
+assert_archive_contains "$bundle_auto" "nodes/kubenode/system/hostname.txt"
+grep -qF -- '--context lab' "$FAKE_SSH_LOG" || fail "rook kubectl missing --context in auto mode"
+grep -qF '10.0.0.9 kubectl' "$FAKE_SSH_LOG" || fail "rook kubectl did not run on the kube node"
+grep -qx '90' "$FAKE_TIMEOUT_LOG" || fail "node wrapper should use --node-timeout 90"
+
+# ---------------------------------------------------------------------------
+# auto with NO capable nodes: both layers SKIPPED, nodes still collected, exit 2
+# ---------------------------------------------------------------------------
+out_nocap="$tmpdir/out-nocap"
+nocap_status=0
 set +e
-FAKE_SSH_FAIL_ALIAS=osd01 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
-  --inventory "$inventory" \
-  --ssh-key "$ssh_key" \
-  --seed tester@seed.example.invalid \
-  --mode rook \
-  --out "$out_partial" \
-  --since 24h \
-  --timeout 5
-partial_status=$?
+FAKE_CEPH_TARGETS="" FAKE_KUBE_TARGETS="" \
+PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
+  --inventory "$inventory" --ssh-key "$ssh_key" \
+  --mode auto --out "$out_nocap" --since 24h --timeout 5
+nocap_status=$?
 set -e
-[[ "$partial_status" == "2" ]] || fail "one failed host should exit 2, got $partial_status"
+[[ "$nocap_status" == "2" ]] || fail "auto with no capable node should exit 2, got $nocap_status"
+bundle_nocap="$(find_bundle "$out_nocap")"
+assert_archive_contains "$bundle_nocap" "cluster/ceph/SKIPPED.txt"
+assert_archive_contains "$bundle_nocap" "cluster/rook/SKIPPED.txt"
+assert_archive_contains "$bundle_nocap" "nodes/cephnode/system/hostname.txt"
 
-bundle_partial="$(find_bundle "$out_partial")"
-assert_archive_contains "$bundle_partial" "nodes/osd01/system/hostname.txt"
-assert_archive_contains "$bundle_partial" "errors.log"
+# ---------------------------------------------------------------------------
+# explicit --mode cephadm --seed: only ceph layer, no kubectl probing/collection
+# ---------------------------------------------------------------------------
+out_ceph="$tmpdir/out-ceph"
+: >"$FAKE_SSH_LOG"
+PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
+  --inventory "$inventory" --ssh-key "$ssh_key" \
+  --seed tester@10.0.0.1 --mode cephadm --out "$out_ceph" --since 24h --timeout 5
+bundle_ceph="$(find_bundle "$out_ceph")"
+assert_archive_contains "$bundle_ceph" "cluster/ceph/json/status.json"
+grep -qF 'kubectl' "$FAKE_SSH_LOG" && fail "cephadm mode should not run kubectl" || true
 
-out_bad_tar="$tmpdir/out-bad-tar"
-bad_tar_status=0
-set +e
-FAKE_SSH_BAD_TAR_ALIAS=osd01 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
-  --inventory "$inventory" \
-  --ssh-key "$ssh_key" \
-  --seed tester@seed.example.invalid \
-  --mode rook \
-  --out "$out_bad_tar" \
-  --since 24h \
-  --timeout 5
-bad_tar_status=$?
-set -e
-[[ "$bad_tar_status" == "2" ]] || fail "bad node tar should exit 2, got $bad_tar_status"
+# ---------------------------------------------------------------------------
+# two cephadm nodes: cluster ceph collected from the FIRST only
+# ---------------------------------------------------------------------------
+inv_two="$tmpdir/inv-two-ceph.env"
+cat >"$inv_two" <<'EOF'
+SSH_USER="tester"
+HOSTS=(
+  "c1=10.0.0.1"
+  "c2=10.0.0.2"
+)
+EOF
+out_two="$tmpdir/out-two"
+: >"$FAKE_SSH_LOG"
+FAKE_CEPH_TARGETS="10.0.0.1 10.0.0.2" FAKE_KUBE_TARGETS="" \
+PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
+  --inventory "$inv_two" --ssh-key "$ssh_key" \
+  --mode auto --out "$out_two" --since 24h --timeout 5
+grep -qF '10.0.0.1 sudo -n cephadm shell -- ceph status --format json-pretty' "$FAKE_SSH_LOG" \
+  || fail "cluster ceph should be collected from first cephadm node"
+grep -qF '10.0.0.2 sudo -n cephadm shell -- ceph status' "$FAKE_SSH_LOG" \
+  && fail "cluster ceph must not be collected twice" || true
 
-bundle_bad_tar="$(find_bundle "$out_bad_tar")"
-assert_archive_contains "$bundle_bad_tar" "nodes/osd01/SKIPPED.txt"
+# ---------------------------------------------------------------------------
+# node-level orchestration (use cephadm --seed to keep the cluster layer simple)
+# ---------------------------------------------------------------------------
+run_nodecase() {
+  # $1=outdir ; remaining env set by caller
+  PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
+    --inventory "$inventory" --ssh-key "$ssh_key" \
+    --seed tester@10.0.0.1 --mode cephadm --out "$1" --since 24h --timeout 5
+}
 
-# C4: a node tar that extracts but is missing its own manifest.jsonl (truncated
-# transfer) must be treated as a failure, not silently counted as ok.
-out_no_manifest="$tmpdir/out-no-manifest"
-no_manifest_status=0
-set +e
-FAKE_SSH_NO_MANIFEST_ALIAS=osd01 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
-  --inventory "$inventory" --ssh-key "$ssh_key" \
-  --seed tester@seed.example.invalid --mode rook \
-  --out "$out_no_manifest" --since 24h --timeout 5
-no_manifest_status=$?
-set -e
-[[ "$no_manifest_status" == "2" ]] || fail "truncated node (no manifest) should exit 2, got $no_manifest_status"
-bundle_no_manifest="$(find_bundle "$out_no_manifest")"
-assert_archive_contains "$bundle_no_manifest" "nodes/osd01/SKIPPED.txt"
-assert_archive_contains "$bundle_no_manifest" "nodes/monitor01/system/hostname.txt"
+# C4: truncated node (no manifest) -> SKIPPED, exit 2
+out_nomani="$tmpdir/out-nomani"
+st=0; set +e
+FAKE_SSH_NO_MANIFEST_ALIAS=kubenode run_nodecase "$out_nomani"
+st=$?; set -e
+[[ "$st" == "2" ]] || fail "missing node manifest should exit 2, got $st"
+assert_archive_contains "$(find_bundle "$out_nomani")" "nodes/kubenode/SKIPPED.txt"
+
+# bad tar -> SKIPPED, exit 2
+out_badtar="$tmpdir/out-badtar"
+st=0; set +e
+FAKE_SSH_BAD_TAR_ALIAS=kubenode run_nodecase "$out_badtar"
+st=$?; set -e
+[[ "$st" == "2" ]] || fail "bad node tar should exit 2, got $st"
+assert_archive_contains "$(find_bundle "$out_badtar")" "nodes/kubenode/SKIPPED.txt"
 
-# C2: on mid-run abort, the temp workdir must be trap-cleaned (no tmp.* left behind).
+# one failed host -> exit 2, errors.log present
+out_fail="$tmpdir/out-fail"
+st=0; set +e
+FAKE_SSH_FAIL_ALIAS=kubenode run_nodecase "$out_fail"
+st=$?; set -e
+[[ "$st" == "2" ]] || fail "one failed host should exit 2, got $st"
+assert_archive_contains "$(find_bundle "$out_fail")" "errors.log"
+
+# C2: abort mid-run -> trap cleans workdir (no tmp.* left)
 out_abort="$tmpdir/out-abort"
 set +e
 COLLECT_TEST_ABORT_AFTER_NODES=1 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   --inventory "$inventory" --ssh-key "$ssh_key" \
-  --seed tester@seed.example.invalid --mode rook \
-  --out "$out_abort" --since 24h --timeout 5 >/dev/null 2>&1
+  --seed tester@10.0.0.1 --mode cephadm --out "$out_abort" --since 24h --timeout 5 >/dev/null 2>&1
 abort_status=$?
 set -e
-[[ "$abort_status" != "0" ]] || fail "abort hook should make collect.sh exit non-zero"
+[[ "$abort_status" != "0" ]] || fail "abort hook should exit non-zero"
 leftover="$(find "$out_abort" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
-[[ "$leftover" == "0" ]] || fail "abort left $leftover tmp workdir(s) behind"
+[[ "$leftover" == "0" ]] || fail "abort left $leftover tmp workdir(s)"
 
-# C3: if verification fails (forbidden secret path), evidence is preserved
-# (workdir kept) and NO shareable .tar.gz is produced; exit 1.
-out_verify_fail="$tmpdir/out-verify-fail"
+# C3: verify failure (forbidden secret path) -> exit 1, workdir kept, no bundle
+out_verify="$tmpdir/out-verify"
 set +e
-FAKE_SSH_PEM_ALIAS=osd01 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
+FAKE_SSH_PEM_ALIAS=kubenode PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   --inventory "$inventory" --ssh-key "$ssh_key" \
-  --seed tester@seed.example.invalid --mode rook \
-  --out "$out_verify_fail" --since 24h --timeout 5 >/dev/null 2>&1
-verify_fail_status=$?
+  --seed tester@10.0.0.1 --mode cephadm --out "$out_verify" --since 24h --timeout 5 >/dev/null 2>&1
+verify_status=$?
 set -e
-[[ "$verify_fail_status" == "1" ]] || fail "verify failure should exit 1, got $verify_fail_status"
-produced="$(find "$out_verify_fail" -maxdepth 1 -name 'ceph-incident-*.tar.gz' 2>/dev/null | wc -l | tr -d '[:space:]')"
-[[ "$produced" == "0" ]] || fail "verify failure must not produce a shareable bundle"
-kept="$(find "$out_verify_fail" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
-[[ "$kept" == "1" ]] || fail "verify failure should keep the workdir for inspection (found $kept)"
+[[ "$verify_status" == "1" ]] || fail "verify failure should exit 1, got $verify_status"
+produced="$(find "$out_verify" -maxdepth 1 -name 'ceph-incident-*.tar.gz' 2>/dev/null | wc -l | tr -d '[:space:]')"
+[[ "$produced" == "0" ]] || fail "verify failure must not package a bundle"
+kept="$(find "$out_verify" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
+[[ "$kept" == "1" ]] || fail "verify failure should keep the workdir (found $kept)"
+
+printf 'ok: collect orchestration\n'
diff --git a/experiments/ceph-incident-bundle/tests/test-rook-collector.sh b/experiments/ceph-incident-bundle/tests/test-rook-collector.sh
index 9f25936..27e6d36 100755
--- a/experiments/ceph-incident-bundle/tests/test-rook-collector.sh
+++ b/experiments/ceph-incident-bundle/tests/test-rook-collector.sh
@@ -75,6 +75,11 @@ cat >"$fakebin/kubectl" <<'EOF'
 set -euo pipefail
 printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG:?}"
 
+# tolerate a leading "--context CTX" (added in remote/ssh mode)
+if [[ "${1:-}" == "--context" ]]; then
+  shift 2
+fi
+
 mode=${FAKE_KUBECTL_MODE:-present}
 cmd="$*"
 
@@ -92,15 +97,15 @@ case "$cmd" in
   "get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n rook-ceph -o yaml")
     printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n  metadata:\n    name: rook-ceph\n'
     ;;
-  "get pods -n rook-ceph -l app=rook-ceph-operator -o jsonpath={.items[0].metadata.name}")
-    printf 'rook-ceph-operator-0'
+  "get pods -n rook-ceph -l app=rook-ceph-operator -o name")
+    printf 'pod/rook-ceph-operator-0\n'
     ;;
   "logs -n rook-ceph rook-ceph-operator-0 --since=24h")
     printf 'operator log line\n'
     ;;
-  "get pods -n rook-ceph -l app=rook-ceph-tools -o jsonpath={.items[0].metadata.name}")
+  "get pods -n rook-ceph -l app=rook-ceph-tools -o name")
     [[ "$mode" == "with-toolbox" ]] || exit 0
-    printf 'rook-ceph-tools-0'
+    printf 'pod/rook-ceph-tools-0\n'
     ;;
   "exec -n rook-ceph rook-ceph-tools-0 -- ceph status")
     printf 'cluster is healthy from toolbox\n'
@@ -137,3 +142,34 @@ assert_file_contains "$out_present/cluster/rook/toolbox-status.txt" "cluster is
 
 grep -qF 'get namespace rook-ceph' "$FAKE_KUBECTL_LOG" || fail "namespace detection was not called"
 grep -qF 'logs -n rook-ceph rook-ceph-operator-0 --since=24h' "$FAKE_KUBECTL_LOG" || fail "operator logs were not collected"
+
+# --- remote (ssh-target) mode: kubectl runs via ssh on the chosen node, with --context ---
+fake_ssh_log="$tmpdir/ssh.log"
+cat >"$fakebin/ssh" <<'EOF'
+#!/usr/bin/env bash
+set -euo pipefail
+printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
+# argv: -i key <opts...> target kubectl <kubectl args...>; forward everything after 'kubectl'
+seen=0
+argv=()
+for a in "$@"; do
+  if [[ $seen -eq 1 ]]; then argv+=("$a"); continue; fi
+  [[ "$a" == "kubectl" ]] && seen=1
+done
+exec kubectl "${argv[@]}"
+EOF
+chmod +x "$fakebin/ssh"
+printf 'k\n' >"$tmpdir/key"
+
+out_remote="$tmpdir/out-remote"
+manifest_remote="$tmpdir/manifest-remote.jsonl"
+FAKE_SSH_LOG="$fake_ssh_log" FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" \
+  "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
+  --out "$out_remote" --manifest "$manifest_remote" \
+  --namespace rook-ceph --since 24h --timeout 5 \
+  --ssh-target tester@node2 --ssh-key "$tmpdir/key" --kube-context lab
+
+assert_file_contains "$out_remote/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
+assert_file_contains "$out_remote/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
+grep -qF -- '--context lab' "$fake_ssh_log" || fail "remote kubectl missing --context"
+grep -qF 'tester@node2 kubectl' "$fake_ssh_log" || fail "kubectl did not run via ssh on the target node"

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-collect.sh | sed -n '1,460p'" in /Users/ikaros/Documents/code/learning-k8s
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
    67	  "get namespace rook-ceph") printf 'rook-ceph\n' ;;
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
    93	# Order matters: the capability-probe script also contains "kubectl", so it must
    94	# be matched before the kubectl-forward branch.
    95	case "$whole" in
    96	  *"command -v cephadm"*)
    97	    target="${args[$((n-2))]}"   # probe sends a single-arg remote script
    98	    caps=""
    99	    for t in ${FAKE_CEPH_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps cephadm"; done
   100	    for t in ${FAKE_KUBE_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps kubectl"; done
   101	    printf '%s\n' "$caps"
   102	    exit 0
   103	    ;;
   104	  *"cephadm shell -- ceph"*)
   105	    exec "$FIXTURE_SSH" "$@"
   106	    ;;
   107	  *collect-node.sh*)
   108	    alias_name="$(printf '%s\n' "$whole" | sed -n "s/.*--host-alias '\\([^']*\\)'.*/\\1/p")"
   109	    cat >/dev/null
   110	    [[ -n "$alias_name" ]] || { printf 'no alias\n' >&2; exit 99; }
   111	    if [[ "${FAKE_SSH_BAD_TAR_ALIAS:-}" == "$alias_name" ]]; then
   112	      printf 'not a tar archive\n'; exit 0
   113	    fi
   114	    sleep "${FAKE_SSH_SLEEP:-0}"
   115	    t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
   116	    mkdir -p "$t/system"
   117	    printf 'node %s\n' "$alias_name" >"$t/system/hostname.txt"
   118	    if [[ "${FAKE_SSH_NO_MANIFEST_ALIAS:-}" != "$alias_name" ]]; then
   119	      printf '{"node":"%s"}\n' "$alias_name" >"$t/manifest.jsonl"
   120	    fi
   121	    [[ "${FAKE_SSH_PEM_ALIAS:-}" == "$alias_name" ]] && printf 'cert\n' >"$t/system/leak.pem"
   122	    tar -czf - -C "$t" .
   123	    [[ "${FAKE_SSH_FAIL_ALIAS:-}" == "$alias_name" ]] && exit 2
   124	    exit 0
   125	    ;;
   126	  *kubectl*)
   127	    seen=0; kargs=()
   128	    for a in "$@"; do
   129	      if [[ $seen -eq 1 ]]; then kargs+=("$a"); continue; fi
   130	      [[ "$a" == "kubectl" ]] && seen=1
   131	    done
   132	    exec kubectl "${kargs[@]}"
   133	    ;;
   134	  *)
   135	    printf 'unexpected ssh remote: %s\n' "$remote" >&2
   136	    exit 99
   137	    ;;
   138	esac
   139	EOF
   140	chmod +x "$fakebin/kubectl" "$fakebin/ssh" "$fakebin/timeout"
   141	
   142	ssh_key="$tmpdir/id_ed25519"
   143	printf 'fake key\n' >"$ssh_key"
   144	export FAKE_SSH_LOG="$tmpdir/ssh.log"
   145	export FAKE_TIMEOUT_LOG="$tmpdir/timeout.log"
   146	export FIXTURE_SSH="$ROOT/tests/fixtures/bin/ssh"
   147	
   148	# external topology: a ceph node + a kube node
   149	inventory="$tmpdir/inv-external.env"
   150	cat >"$inventory" <<'EOF'
   151	SSH_USER="tester"
   152	ROOK_NAMESPACE="rook-ceph"
   153	HOSTS=(
   154	  "cephnode=10.0.0.1"
   155	  "kubenode=10.0.0.9"
   156	)
   157	EOF
   158	
   159	# ---------------------------------------------------------------------------
   160	# auto: dual-layer collection (ceph from cephnode, rook from kubenode), --context
   161	# ---------------------------------------------------------------------------
   162	out_auto="$tmpdir/out-auto"
   163	: >"$FAKE_SSH_LOG"
   164	FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="10.0.0.9" \
   165	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   166	  --inventory "$inventory" --ssh-key "$ssh_key" \
   167	  --mode auto --kube-context lab --out "$out_auto" --since 24h --timeout 5 --node-timeout 90
   168	bundle_auto="$(find_bundle "$out_auto")"
   169	assert_archive_contains "$bundle_auto" "cluster/ceph/json/status.json"
   170	assert_archive_contains "$bundle_auto" "cluster/rook/pods-wide.txt"
   171	assert_archive_contains "$bundle_auto" "nodes/cephnode/system/hostname.txt"
   172	assert_archive_contains "$bundle_auto" "nodes/kubenode/system/hostname.txt"
   173	grep -qF -- '--context lab' "$FAKE_SSH_LOG" || fail "rook kubectl missing --context in auto mode"
   174	grep -qF '10.0.0.9 kubectl' "$FAKE_SSH_LOG" || fail "rook kubectl did not run on the kube node"
   175	grep -qx '90' "$FAKE_TIMEOUT_LOG" || fail "node wrapper should use --node-timeout 90"
   176	
   177	# ---------------------------------------------------------------------------
   178	# auto with NO capable nodes: both layers SKIPPED, nodes still collected, exit 2
   179	# ---------------------------------------------------------------------------
   180	out_nocap="$tmpdir/out-nocap"
   181	nocap_status=0
   182	set +e
   183	FAKE_CEPH_TARGETS="" FAKE_KUBE_TARGETS="" \
   184	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   185	  --inventory "$inventory" --ssh-key "$ssh_key" \
   186	  --mode auto --out "$out_nocap" --since 24h --timeout 5
   187	nocap_status=$?
   188	set -e
   189	[[ "$nocap_status" == "2" ]] || fail "auto with no capable node should exit 2, got $nocap_status"
   190	bundle_nocap="$(find_bundle "$out_nocap")"
   191	assert_archive_contains "$bundle_nocap" "cluster/ceph/SKIPPED.txt"
   192	assert_archive_contains "$bundle_nocap" "cluster/rook/SKIPPED.txt"
   193	assert_archive_contains "$bundle_nocap" "nodes/cephnode/system/hostname.txt"
   194	
   195	# ---------------------------------------------------------------------------
   196	# explicit --mode cephadm --seed: only ceph layer, no kubectl probing/collection
   197	# ---------------------------------------------------------------------------
   198	out_ceph="$tmpdir/out-ceph"
   199	: >"$FAKE_SSH_LOG"
   200	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   201	  --inventory "$inventory" --ssh-key "$ssh_key" \
   202	  --seed tester@10.0.0.1 --mode cephadm --out "$out_ceph" --since 24h --timeout 5
   203	bundle_ceph="$(find_bundle "$out_ceph")"
   204	assert_archive_contains "$bundle_ceph" "cluster/ceph/json/status.json"
   205	grep -qF 'kubectl' "$FAKE_SSH_LOG" && fail "cephadm mode should not run kubectl" || true
   206	
   207	# ---------------------------------------------------------------------------
   208	# two cephadm nodes: cluster ceph collected from the FIRST only
   209	# ---------------------------------------------------------------------------
   210	inv_two="$tmpdir/inv-two-ceph.env"
   211	cat >"$inv_two" <<'EOF'
   212	SSH_USER="tester"
   213	HOSTS=(
   214	  "c1=10.0.0.1"
   215	  "c2=10.0.0.2"
   216	)
   217	EOF
   218	out_two="$tmpdir/out-two"
   219	: >"$FAKE_SSH_LOG"
   220	FAKE_CEPH_TARGETS="10.0.0.1 10.0.0.2" FAKE_KUBE_TARGETS="" \
   221	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   222	  --inventory "$inv_two" --ssh-key "$ssh_key" \
   223	  --mode auto --out "$out_two" --since 24h --timeout 5
   224	grep -qF '10.0.0.1 sudo -n cephadm shell -- ceph status --format json-pretty' "$FAKE_SSH_LOG" \
   225	  || fail "cluster ceph should be collected from first cephadm node"
   226	grep -qF '10.0.0.2 sudo -n cephadm shell -- ceph status' "$FAKE_SSH_LOG" \
   227	  && fail "cluster ceph must not be collected twice" || true
   228	
   229	# ---------------------------------------------------------------------------
   230	# node-level orchestration (use cephadm --seed to keep the cluster layer simple)
   231	# ---------------------------------------------------------------------------
   232	run_nodecase() {
   233	  # $1=outdir ; remaining env set by caller
   234	  PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   235	    --inventory "$inventory" --ssh-key "$ssh_key" \
   236	    --seed tester@10.0.0.1 --mode cephadm --out "$1" --since 24h --timeout 5
   237	}
   238	
   239	# C4: truncated node (no manifest) -> SKIPPED, exit 2
   240	out_nomani="$tmpdir/out-nomani"
   241	st=0; set +e
   242	FAKE_SSH_NO_MANIFEST_ALIAS=kubenode run_nodecase "$out_nomani"
   243	st=$?; set -e
   244	[[ "$st" == "2" ]] || fail "missing node manifest should exit 2, got $st"
   245	assert_archive_contains "$(find_bundle "$out_nomani")" "nodes/kubenode/SKIPPED.txt"
   246	
   247	# bad tar -> SKIPPED, exit 2
   248	out_badtar="$tmpdir/out-badtar"
   249	st=0; set +e
   250	FAKE_SSH_BAD_TAR_ALIAS=kubenode run_nodecase "$out_badtar"
   251	st=$?; set -e
   252	[[ "$st" == "2" ]] || fail "bad node tar should exit 2, got $st"
   253	assert_archive_contains "$(find_bundle "$out_badtar")" "nodes/kubenode/SKIPPED.txt"
   254	
   255	# one failed host -> exit 2, errors.log present
   256	out_fail="$tmpdir/out-fail"
   257	st=0; set +e
   258	FAKE_SSH_FAIL_ALIAS=kubenode run_nodecase "$out_fail"
   259	st=$?; set -e
   260	[[ "$st" == "2" ]] || fail "one failed host should exit 2, got $st"
   261	assert_archive_contains "$(find_bundle "$out_fail")" "errors.log"
   262	
   263	# C2: abort mid-run -> trap cleans workdir (no tmp.* left)
   264	out_abort="$tmpdir/out-abort"
   265	set +e
   266	COLLECT_TEST_ABORT_AFTER_NODES=1 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   267	  --inventory "$inventory" --ssh-key "$ssh_key" \
   268	  --seed tester@10.0.0.1 --mode cephadm --out "$out_abort" --since 24h --timeout 5 >/dev/null 2>&1
   269	abort_status=$?
   270	set -e
   271	[[ "$abort_status" != "0" ]] || fail "abort hook should exit non-zero"
   272	leftover="$(find "$out_abort" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
   273	[[ "$leftover" == "0" ]] || fail "abort left $leftover tmp workdir(s)"
   274	
   275	# C3: verify failure (forbidden secret path) -> exit 1, workdir kept, no bundle
   276	out_verify="$tmpdir/out-verify"
   277	set +e
   278	FAKE_SSH_PEM_ALIAS=kubenode PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   279	  --inventory "$inventory" --ssh-key "$ssh_key" \
   280	  --seed tester@10.0.0.1 --mode cephadm --out "$out_verify" --since 24h --timeout 5 >/dev/null 2>&1
   281	verify_status=$?
   282	set -e
   283	[[ "$verify_status" == "1" ]] || fail "verify failure should exit 1, got $verify_status"
   284	produced="$(find "$out_verify" -maxdepth 1 -name 'ceph-incident-*.tar.gz' 2>/dev/null | wc -l | tr -d '[:space:]')"
   285	[[ "$produced" == "0" ]] || fail "verify failure must not package a bundle"
   286	kept="$(find "$out_verify" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
   287	[[ "$kept" == "1" ]] || fail "verify failure should keep the workdir (found $kept)"
   288	
   289	printf 'ok: collect orchestration\n'

codex
I’ve got the main control flow now. Next I’m checking the validation/package tail and the underlying helpers, because exit-code and “read-only” regressions often hide outside the new detection block.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/run/collect.sh | sed -n '360,620p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
   360	        ;;
   361	      --keep-workdir)
   362	        keep_workdir=1
   363	        shift
   364	        ;;
   365	      --help|-h)
   366	        usage
   367	        return 0
   368	        ;;
   369	      *)
   370	        usage >&2
   371	        return 1
   372	        ;;
   373	    esac
   374	  done
   375	
   376	  [[ "$mode" == "auto" || "$mode" == "cephadm" || "$mode" == "rook" ]] || die "unsupported mode: $mode"
   377	  [[ -n "$inventory" && -f "$inventory" ]] || die "missing inventory: ${inventory:-<unset>}"
   378	  [[ -n "$ssh_key" && -f "$ssh_key" ]] || die "missing ssh key: ${ssh_key:-<unset>}"
   379	
   380	  # shellcheck disable=SC1090
   381	  source "$inventory"
   382	
   383	  if ! declare -p HOSTS >/dev/null 2>&1; then
   384	    die "inventory must define HOSTS"
   385	  fi
   386	
   387	  ssh_user=${SSH_USER:-}
   388	  seed_host=${SEED_HOST:-}
   389	  rook_namespace=${ROOK_NAMESPACE:-rook-ceph}
   390	  if [[ -n "$seed_override" ]]; then
   391	    seed=$seed_override
   392	  elif [[ -n "$seed_host" ]]; then
   393	    seed="$(ssh_target_for_host "$seed_host" "$ssh_user")"
   394	  fi
   395	
   396	  if [[ -z "$(timeout_cmd)" ]]; then
   397	    log "WARNING: no 'timeout'/'gtimeout' found on this workstation; outer timeouts are disabled — relying on SSH ConnectTimeout/ServerAlive only (install coreutils for full bounding)"
   398	  fi
   399	
   400	  ensure_dir "$out_dir"
   401	  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
   402	  workdir="$out_dir/tmp.$timestamp.$$"
   403	  manifest="$workdir/manifest.jsonl"
   404	  ensure_dir "$workdir"
   405	  CLEANUP_WORKDIR="$workdir"
   406	  CLEANUP_KEEP=$keep_workdir
   407	  trap cleanup_workdir EXIT INT TERM
   408	  write_initial_metadata "$workdir" "$mode" "$seed" "$since" "$timeout"
   409	
   410	  # Parse HOSTS once into globals (used by the cluster capability probe AND the
   411	  # node loop). A malformed entry is recorded but must not abort collection.
   412	  local entry
   413	  HOST_ALIASES=()
   414	  HOST_TARGETS=()
   415	  for entry in "${HOSTS[@]}"; do
   416	    if [[ "$entry" != *=* || -z "${entry%%=*}" || -z "${entry#*=}" ]]; then
   417	      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
   418	      rc=2
   419	      continue
   420	    fi
   421	    HOST_ALIASES+=("${entry%%=*}")
   422	    HOST_TARGETS+=("$(ssh_target_for_host "${entry#*=}" "$ssh_user")")
   423	  done
   424	
   425	  set +e
   426	  collect_clusters "$mode" "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout" "$rook_namespace" "$kube_context"
   427	  cluster_rc=$?
   428	  set -e
   429	  if [[ $cluster_rc -ne 0 ]]; then
   430	    append_error "$workdir" "cluster collection exited $cluster_rc"
   431	    rc=2
   432	  fi
   433	
   434	  local i alias target node_rc
   435	  if [[ ${#HOST_ALIASES[@]} -gt 0 ]]; then
   436	    for i in "${!HOST_ALIASES[@]}"; do
   437	      alias="${HOST_ALIASES[$i]}"
   438	      target="${HOST_TARGETS[$i]}"
   439	      if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs" "$node_timeout"; then
   440	        node_ok=$((node_ok + 1))
   441	      else
   442	        node_rc=$?
   443	        node_failed=$((node_failed + 1))
   444	        append_error "$workdir" "node $alias ($target) collector exited $node_rc"
   445	        rc=2
   446	      fi
   447	    done
   448	  fi
   449	
   450	  # Test-only hook: simulate a mid-run abort to exercise trap cleanup. Inert in production.
   451	  if [[ -n "${COLLECT_TEST_ABORT_AFTER_NODES:-}" ]]; then
   452	    die "test abort after nodes"
   453	  fi
   454	
   455	  redact_bundle_text "$workdir"
   456	  write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "$rc"
   457	
   458	  # Verify BEFORE packaging, but never let verification destroy collected
   459	  # evidence: capture its result instead of aborting under set -e. On failure,
   460	  # keep the workdir for inspection and do not produce a shareable bundle.
   461	  local verify_rc=0
   462	  set +e
   463	  "$COLLECT_ROOT/lib/verify-bundle.sh" "$workdir" >/dev/null 2>>"$workdir/errors.log"
   464	  verify_rc=$?
   465	  set -e
   466	  if [[ $verify_rc -ne 0 ]]; then
   467	    CLEANUP_KEEP=1
   468	    append_error "$workdir" "bundle verification failed (rc=$verify_rc); workdir kept, NOT packaged for sharing"
   469	    write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "1"
   470	    printf 'VERIFY FAILED: workdir kept at %s (not packaged) — review errors.log\n' "$workdir" >&2
   471	    return 1
   472	  fi
   473	
   474	  bundle="$out_dir/ceph-incident-$timestamp.tar.gz"
   475	  COPYFILE_DISABLE=1 tar -czf "$bundle" -C "$workdir" .
   476	  set +e
   477	  "$COLLECT_ROOT/lib/verify-bundle.sh" "$bundle" >/dev/null 2>>"$workdir/errors.log"
   478	  verify_rc=$?
   479	  set -e
   480	  if [[ $verify_rc -ne 0 ]]; then
   481	    CLEANUP_KEEP=1
   482	    rm -f -- "$bundle"
   483	    printf 'VERIFY FAILED on packaged bundle; removed it, workdir kept at %s\n' "$workdir" >&2
   484	    return 1
   485	  fi
   486	
   487	  printf 'bundle: %s\n' "$bundle"
   488	  return "$rc"
   489	}
   490	
   491	main "$@"

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh | sed -n '1,320p'" in /Users/ikaros/Documents/code/learning-k8s
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
    10	collect_cephadm_command() {
    11	  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 artifact=$6
    12	  shift 6
    13	
    14	  local artifact_dir
    15	  artifact_dir="$(dirname -- "$artifact")"
    16	  ensure_dir "$artifact_dir"
    17	
    18	  COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
    19	    run_capture "$manifest" "$seed" "collect-cluster-cephadm" "$artifact" -- \
    20	    ssh \
    21	      -i "$ssh_key" \
    22	      -o BatchMode=yes \
    23	      -o IdentitiesOnly=yes \
    24	      -o IdentityAgent=none \
    25	      -o "ConnectTimeout=$timeout" \
    26	      -o "ServerAliveInterval=$timeout" \
    27	      -o ServerAliveCountMax=1 \
    28	      "$seed" \
    29	      sudo -n cephadm shell -- ceph "$@"
    30	}
    31	
    32	write_cephadm_crash_skip() {
    33	  local skip_artifact=$1
    34	  ensure_dir "$(dirname -- "$skip_artifact")"
    35	  cat >"$skip_artifact" <<'EOF'
    36	SKIPPED: unable to parse crash list JSON for recent crash inspection
    37	EOF
    38	}
    39	
    40	extract_cephadm_crash_ids() {
    41	  local crash_ls_artifact=$1
    42	  local payload compact ids
    43	
    44	  [[ -f "$crash_ls_artifact" ]] || return 1
    45	  payload="$(sed '/^[[:space:]]*#/d' "$crash_ls_artifact")" || return 1
    46	
    47	  # Anchor strictly to crash_id; matching id/name too would capture unrelated
    48	  # nested fields and feed bogus ids back into `ceph crash info`.
    49	  ids="$(
    50	    printf '%s\n' "$payload" |
    51	      grep -oE '"crash_id"[[:space:]]*:[[:space:]]*"[^"]*"' |
    52	      sed -E 's/^"crash_id"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/' |
    53	      head -n 10
    54	  )" || true
    55	
    56	  if [[ -n "$ids" ]]; then
    57	    printf '%s\n' "$ids"
    58	    return 0
    59	  fi
    60	
    61	  compact="$(printf '%s' "$payload" | tr -d '[:space:]')"
    62	  case "$compact" in
    63	    "[]"|"{}"|"{\"crashes\":[]}"|"{\"items\":[]}"|"{\"entries\":[]}"|"{\"crash_ls\":[]}")
    64	      return 0
    65	      ;;
    66	  esac
    67	
    68	  return 1
    69	}
    70	
    71	cephadm_crash_artifact_name() {
    72	  local crash_id=$1 safe_id
    73	  safe_id="$(printf '%s' "$crash_id" | tr -c 'A-Za-z0-9._-' '_')"
    74	  while [[ "$safe_id" == *..* ]]; do
    75	    safe_id="${safe_id//../__}"
    76	  done
    77	  [[ -n "$safe_id" ]] || safe_id="crash"
    78	  printf '%s' "$safe_id"
    79	}
    80	
    81	cephadm_unique_crash_artifact() {
    82	  local crash_dir=$1 safe_id=$2
    83	  local artifact="$crash_dir/$safe_id.json"
    84	  local suffix=2
    85	
    86	  while [[ -e "$artifact" ]]; do
    87	    artifact="$crash_dir/$safe_id-$suffix.json"
    88	    suffix=$((suffix + 1))
    89	  done
    90	
    91	  printf '%s' "$artifact"
    92	}
    93	
    94	collect_cephadm_recent_crashes() {
    95	  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 crash_ls_artifact=$6
    96	
    97	  local crash_dir="$outdir/cluster/ceph/json/crash-info"
    98	  local skip_artifact="$outdir/cluster/ceph/text/crash-info-skip.txt"
    99	  local crash_ids rc=0
   100	
   101	  if ! crash_ids="$(extract_cephadm_crash_ids "$crash_ls_artifact")"; then
   102	    write_cephadm_crash_skip "$skip_artifact"
   103	    return 0
   104	  fi
   105	
   106	  [[ -n "$crash_ids" ]] || return 0
   107	
   108	  local crash_id safe_id crash_info_artifact
   109	  while IFS= read -r crash_id; do
   110	    [[ -n "$crash_id" ]] || continue
   111	    safe_id="$(cephadm_crash_artifact_name "$crash_id")"
   112	    crash_info_artifact="$(cephadm_unique_crash_artifact "$crash_dir" "$safe_id")"
   113	    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$crash_info_artifact" crash info "$crash_id"; then
   114	      rc=2
   115	    fi
   116	  done <<<"$crash_ids"
   117	
   118	  return "$rc"
   119	}
   120	
   121	collect_cluster_cephadm() {
   122	  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 since=$5 timeout=$6
   123	  local failed=0
   124	  local json_dir="$outdir/cluster/ceph/json"
   125	  local text_dir="$outdir/cluster/ceph/text"
   126	
   127	  # Cluster-level ceph commands are point-in-time snapshots; node collectors apply the time window.
   128	  : "$since"
   129	
   130	  ensure_dir "$json_dir"
   131	  ensure_dir "$text_dir"
   132	
   133	  local -a json_specs=(
   134	    "status.json::status --format json-pretty"
   135	    "health-detail.json::health detail --format json-pretty"
   136	    "versions.json::versions --format json-pretty"
   137	    "df-detail.json::df detail --format json-pretty"
   138	    "osd-tree.json::osd tree --format json-pretty"
   139	    "osd-df.json::osd df --format json-pretty"
   140	    "osd-dump.json::osd dump --format json-pretty"
   141	    "osd-perf.json::osd perf --format json-pretty"
   142	    "osd-blocked-by.json::osd blocked-by --format json-pretty"
   143	    "pg-stat.json::pg stat --format json-pretty"
   144	    "pg-dump.json::pg dump --format json-pretty"
   145	    "pg-dump-stuck.json::pg dump_stuck --format json-pretty"
   146	    "mon-dump.json::mon dump --format json-pretty"
   147	    "quorum-status.json::quorum_status --format json-pretty"
   148	    "mgr-dump.json::mgr dump --format json-pretty"
   149	    "orch-host-ls.json::orch host ls --format json-pretty"
   150	    "orch-ps.json::orch ps --format json-pretty"
   151	    "orch-device-ls-wide.json::orch device ls --wide --format json-pretty"
   152	    "config-dump.json::config dump --format json-pretty"
   153	    "crash-ls.json::crash ls --format json-pretty"
   154	  )
   155	
   156	  local -a text_specs=(
   157	    "status.txt::status"
   158	    "health-detail.txt::health detail"
   159	    "osd-tree.txt::osd tree"
   160	    "orch-ps.txt::orch ps"
   161	  )
   162	
   163	  local spec artifact command
   164	  local -a command_words
   165	  for spec in "${json_specs[@]}"; do
   166	    artifact=${spec%%::*}
   167	    command=${spec#*::}
   168	    # shellcheck disable=SC2206
   169	    command_words=($command)
   170	    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$json_dir/$artifact" "${command_words[@]}"; then
   171	      failed=1
   172	    fi
   173	  done
   174	
   175	  for spec in "${text_specs[@]}"; do
   176	    artifact=${spec%%::*}
   177	    command=${spec#*::}
   178	    # shellcheck disable=SC2206
   179	    command_words=($command)
   180	    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$text_dir/$artifact" "${command_words[@]}"; then
   181	      failed=1
   182	    fi
   183	  done
   184	
   185	  if ! collect_cephadm_recent_crashes "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$json_dir/crash-ls.json"; then
   186	    failed=1
   187	  fi
   188	
   189	  if [[ $failed -ne 0 ]]; then
   190	    return 2
   191	  fi
   192	
   193	  return 0
   194	}

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/common.sh | sed -n '1,360p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	# Shared helpers for the Ceph incident bundle harness.
     5	
     6	log() {
     7	  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
     8	}
     9	
    10	die() {
    11	  log "FATAL: $*"
    12	  exit 1
    13	}
    14	
    15	ceph_incident_bundle_log() {
    16	  log "$*"
    17	}
    18	
    19	require_file() {
    20	  [[ -f "$1" ]] || die "missing file: $1"
    21	}
    22	
    23	ensure_dir() {
    24	  mkdir -p "$1"
    25	}
    26	
    27	# Resolve a timeout binary: GNU coreutils `timeout`, or `gtimeout` on macOS.
    28	# Prints the binary name, or nothing if neither is installed.
    29	timeout_cmd() {
    30	  if command -v timeout >/dev/null 2>&1; then
    31	    printf 'timeout'
    32	  elif command -v gtimeout >/dev/null 2>&1; then
    33	    printf 'gtimeout'
    34	  fi
    35	}
    36	
    37	json_escape() {
    38	  local value=$1
    39	  value=${value//\\/\\\\}
    40	  value=${value//\"/\\\"}
    41	  value=${value//$'\n'/\\n}
    42	  value=${value//$'\r'/\\r}
    43	  value=${value//$'\t'/\\t}
    44	  printf '%s' "$value"
    45	}
    46	
    47	manifest_add() {
    48	  local manifest=$1 host=$2 collector=$3 artifact=$4 command=$5 exit_code=$6 started=$7 ended=$8
    49	  [[ "$exit_code" =~ ^[0-9]+$ ]] || die "manifest_add requires numeric exit_code: $exit_code"
    50	  ensure_dir "$(dirname -- "$manifest")"
    51	  printf '{"host":"%s","collector":"%s","artifact":"%s","command":"%s","exit_code":%s,"started":"%s","ended":"%s"}\n' \
    52	    "$(json_escape "$host")" \
    53	    "$(json_escape "$collector")" \
    54	    "$(json_escape "$artifact")" \
    55	    "$(json_escape "$command")" \
    56	    "$exit_code" \
    57	    "$(json_escape "$started")" \
    58	    "$(json_escape "$ended")" >>"$manifest"
    59	}
    60	
    61	redact_file() {
    62	  local source_file=$1 redaction_log=$2
    63	  require_file "$source_file"
    64	  ensure_dir "$(dirname -- "$redaction_log")"
    65	
    66	  local source_dir tmp_file count line nocasematch_state in_pem redact mode
    67	  source_dir="$(dirname -- "$source_file")"
    68	  tmp_file="$(mktemp "$source_dir/.${source_file##*/}.XXXXXX")"
    69	  count=0
    70	  in_pem=0
    71	  if shopt -q nocasematch; then
    72	    nocasematch_state='shopt -s nocasematch'
    73	  else
    74	    nocasematch_state='shopt -u nocasematch'
    75	  fi
    76	  shopt -s nocasematch
    77	
    78	  # Best-effort redaction (NOT a complete DLP): keyword lines, ceph key
    79	  # material (`key = AQB..==`, base64 blobs), and whole multi-line PEM private
    80	  # key blocks. Extensions/encodings outside this are intentionally not covered
    81	  # — see README "安全界線"; operators must self-review before sharing.
    82	  while IFS= read -r line || [[ -n "$line" ]]; do
    83	    redact=0
    84	    if [[ "$line" =~ -----BEGIN[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
    85	      in_pem=1
    86	    fi
    87	    if [[ $in_pem -eq 1 ]]; then
    88	      redact=1
    89	      if [[ "$line" =~ -----END[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
    90	        in_pem=0
    91	      fi
    92	    elif [[ "$line" =~ (password|secret|token|keyring|private([[:space:]_-]+)?key) ]]; then
    93	      redact=1
    94	    elif [[ "$line" =~ (^|[^[:alnum:]])key[[:space:]]*[:=] ]]; then
    95	      redact=1
    96	    elif [[ "$line" =~ [A-Za-z0-9+/]{38,}={1,2} ]]; then
    97	      redact=1
    98	    fi
    99	    if [[ $redact -eq 1 ]]; then
   100	      printf '[REDACTED]\n' >>"$tmp_file"
   101	      count=$((count + 1))
   102	    else
   103	      printf '%s\n' "$line" >>"$tmp_file"
   104	    fi
   105	  done <"$source_file"
   106	
   107	  eval "$nocasematch_state"
   108	  mode="$(stat -c '%a' "$source_file" 2>/dev/null || stat -f '%Lp' "$source_file" 2>/dev/null || printf '600')"
   109	  chmod "$mode" "$tmp_file" 2>/dev/null || true
   110	  mv -f -- "$tmp_file" "$source_file"
   111	  printf '%s: %s line(s) redacted\n' "$source_file" "$count" >>"$redaction_log"
   112	}
   113	
   114	redact_gz_file() {
   115	  # Decompress a gzipped artifact, redact it, recompress in place so rotated
   116	  # logs (*.gz) get the same redaction as plain text.
   117	  local source_file=$1 redaction_log=$2
   118	  require_file "$source_file"
   119	  ensure_dir "$(dirname -- "$redaction_log")"
   120	
   121	  local dir tmp_plain
   122	  dir="$(dirname -- "$source_file")"
   123	  tmp_plain="$(mktemp "$dir/.${source_file##*/}.plain.XXXXXX")"
   124	  if ! gzip -dc -- "$source_file" >"$tmp_plain" 2>/dev/null; then
   125	    rm -f -- "$tmp_plain"
   126	    printf '%s: gz decompress failed, left as-is (NOT redacted)\n' "$source_file" >>"$redaction_log"
   127	    return 0
   128	  fi
   129	
   130	  redact_file "$tmp_plain" "$redaction_log"
   131	  if gzip -c -- "$tmp_plain" >"$source_file"; then
   132	    rm -f -- "$tmp_plain"
   133	  else
   134	    rm -f -- "$tmp_plain"
   135	    return 1
   136	  fi
   137	}
   138	
   139	run_capture() {
   140	  local manifest=$1 host=$2 collector=$3 artifact=$4
   141	  shift 4
   142	  [[ ${1-} == -- ]] || die "run_capture requires -- before the command"
   143	  shift
   144	
   145	  local -a cmd
   146	  local started ended rc command_string artifact_dir artifact_tmp
   147	
   148	  cmd=("$@")
   149	  [[ ${#cmd[@]} -gt 0 ]] || die "run_capture requires a command"
   150	
   151	  started="$(date -u +%FT%TZ)"
   152	  artifact_dir="$(dirname -- "$artifact")"
   153	  ensure_dir "$artifact_dir"
   154	  artifact_tmp="$(mktemp "$artifact_dir/.${artifact##*/}.XXXXXX")"
   155	
   156	  printf '# host: %s\n# collector: %s\n# started: %s\n' "$host" "$collector" "$started" >"$artifact_tmp"
   157	  printf -v command_string '%q ' "${cmd[@]}"
   158	  command_string=${command_string% }
   159	
   160	  local tbin
   161	  tbin="$(timeout_cmd)"
   162	  if [[ -n "$tbin" ]]; then
   163	    printf '# timeout: %ss\n' "${COMMAND_TIMEOUT:-20}" >>"$artifact_tmp"
   164	    if "$tbin" "${COMMAND_TIMEOUT:-20}" "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
   165	      rc=0
   166	    else
   167	      rc=$?
   168	    fi
   169	  else
   170	    printf '# timeout: unavailable\n' >>"$artifact_tmp"
   171	    if "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
   172	      rc=0
   173	    else
   174	      rc=$?
   175	    fi
   176	  fi
   177	
   178	  # Make timeout-kills (124) distinguishable from ordinary command failure, and
   179	  # mark the artifact so a truncated capture is visible to whoever reads it.
   180	  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
   181	    printf '# TRUNCATED: command timed out after %ss (exit %s)\n' "${COMMAND_TIMEOUT:-20}" "$rc" >>"$artifact_tmp"
   182	  fi
   183	
   184	  ended="$(date -u +%FT%TZ)"
   185	  mv -f -- "$artifact_tmp" "$artifact"
   186	  manifest_add "$manifest" "$host" "$collector" "$artifact" "$command_string" "$rc" "$started" "$ended"
   187	
   188	  if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
   189	    ensure_dir "$(dirname -- "$ERROR_LOG")"
   190	    printf '%s host=%s collector=%s artifact=%s exit=%s command=%s\n' \
   191	      "$ended" "$host" "$collector" "$artifact" "$rc" "$command_string" >>"$ERROR_LOG"
   192	  fi
   193	
   194	  return "$rc"
   195	}
   196	
   197	copy_if_exists() {
   198	  local source=$1 dest=$2
   199	  [[ -e "$source" ]] || return 0
   200	  ensure_dir "$(dirname -- "$dest")"
   201	  cp -a -- "$source" "$dest"
   202	}

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-rook-collector.sh | sed -n '1,240p'" in /Users/ikaros/Documents/code/learning-k8s
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
    91	  "get pods -n rook-ceph -o wide")
    92	    printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n'
    93	    ;;
    94	  "get events -n rook-ceph --sort-by=.lastTimestamp")
    95	    printf 'LAST SEEN TYPE REASON OBJECT MESSAGE\n1m Normal Started pod/osd started\n'
    96	    ;;
    97	  "get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n rook-ceph -o yaml")
    98	    printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n  metadata:\n    name: rook-ceph\n'
    99	    ;;
   100	  "get pods -n rook-ceph -l app=rook-ceph-operator -o name")
   101	    printf 'pod/rook-ceph-operator-0\n'
   102	    ;;
   103	  "logs -n rook-ceph rook-ceph-operator-0 --since=24h")
   104	    printf 'operator log line\n'
   105	    ;;
   106	  "get pods -n rook-ceph -l app=rook-ceph-tools -o name")
   107	    [[ "$mode" == "with-toolbox" ]] || exit 0
   108	    printf 'pod/rook-ceph-tools-0\n'
   109	    ;;
   110	  "exec -n rook-ceph rook-ceph-tools-0 -- ceph status")
   111	    printf 'cluster is healthy from toolbox\n'
   112	    ;;
   113	  *)
   114	    printf 'unexpected kubectl command: %s\n' "$cmd" >&2
   115	    exit 99
   116	    ;;
   117	esac
   118	EOF
   119	chmod +x "$fakebin/kubectl"
   120	
   121	export FAKE_KUBECTL_LOG="$tmpdir/kubectl.log"
   122	
   123	out_missing_ns="$tmpdir/out-missing-ns"
   124	manifest_missing_ns="$tmpdir/manifest-missing-ns.jsonl"
   125	missing_ns_rc=0
   126	set +e
   127	FAKE_KUBECTL_MODE=missing-namespace PATH="$fakebin:$PATH" run_rook_collector "$out_missing_ns" "$manifest_missing_ns"
   128	missing_ns_rc=$?
   129	set -e
   130	[[ "$missing_ns_rc" == "2" ]] || fail "explicit rook with missing namespace should exit 2, got $missing_ns_rc"
   131	assert_file_contains "$out_missing_ns/cluster/rook/SKIPPED.txt" "namespace not found: rook-ceph"
   132	
   133	out_present="$tmpdir/out-present"
   134	manifest_present="$tmpdir/manifest-present.jsonl"
   135	FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" run_rook_collector "$out_present" "$manifest_present"
   136	
   137	assert_file_contains "$out_present/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
   138	assert_file_contains "$out_present/cluster/rook/events.txt" "osd started"
   139	assert_file_contains "$out_present/cluster/rook/rook-resources.yaml" "kind: CephCluster"
   140	assert_file_contains "$out_present/cluster/rook/operator.log" "operator log line"
   141	assert_file_contains "$out_present/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
   142	
   143	grep -qF 'get namespace rook-ceph' "$FAKE_KUBECTL_LOG" || fail "namespace detection was not called"
   144	grep -qF 'logs -n rook-ceph rook-ceph-operator-0 --since=24h' "$FAKE_KUBECTL_LOG" || fail "operator logs were not collected"
   145	
   146	# --- remote (ssh-target) mode: kubectl runs via ssh on the chosen node, with --context ---
   147	fake_ssh_log="$tmpdir/ssh.log"
   148	cat >"$fakebin/ssh" <<'EOF'
   149	#!/usr/bin/env bash
   150	set -euo pipefail
   151	printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
   152	# argv: -i key <opts...> target kubectl <kubectl args...>; forward everything after 'kubectl'
   153	seen=0
   154	argv=()
   155	for a in "$@"; do
   156	  if [[ $seen -eq 1 ]]; then argv+=("$a"); continue; fi
   157	  [[ "$a" == "kubectl" ]] && seen=1
   158	done
   159	exec kubectl "${argv[@]}"
   160	EOF
   161	chmod +x "$fakebin/ssh"
   162	printf 'k\n' >"$tmpdir/key"
   163	
   164	out_remote="$tmpdir/out-remote"
   165	manifest_remote="$tmpdir/manifest-remote.jsonl"
   166	FAKE_SSH_LOG="$fake_ssh_log" FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" \
   167	  "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
   168	  --out "$out_remote" --manifest "$manifest_remote" \
   169	  --namespace rook-ceph --since 24h --timeout 5 \
   170	  --ssh-target tester@node2 --ssh-key "$tmpdir/key" --kube-context lab
   171	
   172	assert_file_contains "$out_remote/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
   173	assert_file_contains "$out_remote/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
   174	grep -qF -- '--context lab' "$fake_ssh_log" || fail "remote kubectl missing --context"
   175	grep -qF 'tester@node2 kubectl' "$fake_ssh_log" || fail "kubectl did not run via ssh on the target node"

codex
The key paths are small enough to audit directly. I’m also checking Bash-version behavior because `${!array[@]}` under `set -u` is a known portability edge on the stated workstation.
exec
/bin/zsh -lc 'bash --version | head -n1' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin24)

exec
/bin/zsh -lc "rg -n \"HOST_ALIASES|HOST_TARGETS|ROOK_KUBECTL_ARGV|collect_clusters|detect_node_caps|collect_cluster_rook|kubectl|timeout_cmd|trap|verify-bundle|manifest\" experiments/ceph-incident-bundle -g '*.sh'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/run/collect.sh:34:  --kube-context CTX     kubectl context for the rook layer (default: none)
experiments/ceph-incident-bundle/run/collect.sh:97:  : >"$workdir/manifest.jsonl"
experiments/ceph-incident-bundle/run/collect.sh:121:detect_node_caps() {
experiments/ceph-incident-bundle/run/collect.sh:122:  # echo a space-joined subset of "cephadm kubectl" present on the target node
experiments/ceph-incident-bundle/run/collect.sh:128:  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
experiments/ceph-incident-bundle/run/collect.sh:129:  tbin="$(timeout_cmd)"
experiments/ceph-incident-bundle/run/collect.sh:137:# and cluster-rook source (first kubectl node); collect each requested layer once.
experiments/ceph-incident-bundle/run/collect.sh:138:# Uses globals HOST_TARGETS (set by main).
experiments/ceph-incident-bundle/run/collect.sh:139:collect_clusters() {
experiments/ceph-incident-bundle/run/collect.sh:140:  local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8 kube_context=$9
experiments/ceph-incident-bundle/run/collect.sh:157:    if [[ ${#HOST_TARGETS[@]} -gt 0 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:158:      for i in "${!HOST_TARGETS[@]}"; do
experiments/ceph-incident-bundle/run/collect.sh:159:        caps="$(detect_node_caps "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
experiments/ceph-incident-bundle/run/collect.sh:161:          case " $caps " in *" cephadm "*) ceph_source="${HOST_TARGETS[$i]}" ;; esac
experiments/ceph-incident-bundle/run/collect.sh:164:          case " $caps " in *" kubectl "*) rook_source="${HOST_TARGETS[$i]}" ;; esac
experiments/ceph-incident-bundle/run/collect.sh:175:    collect_cluster_cephadm "$workdir" "$manifest" "$ceph_source" "$ssh_key" "$since" "$timeout" || rc=2
experiments/ceph-incident-bundle/run/collect.sh:182:    rook_args=(--out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout" --ssh-target "$rook_source" --ssh-key "$ssh_key")
experiments/ceph-incident-bundle/run/collect.sh:185:    collect_cluster_rook "${rook_args[@]}" || rc=2
experiments/ceph-incident-bundle/run/collect.sh:196:    printf 'SKIPPED: no kubectl-capable node found\n' >"$workdir/cluster/rook/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:206:      printf 'SKIPPED: no kubectl-capable node in inventory (auto)\n' >"$workdir/cluster/rook/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:229:  # and traps its own temp dir so an interrupted/timed-out run leaves nothing behind.
experiments/ceph-incident-bundle/run/collect.sh:230:  remote_cmd="set -u; tmp=\"\${TMPDIR:-/tmp}/ceph-incident-node.\$\$\"; rm -rf \"\$tmp\"; mkdir -p \"\$tmp\" || { printf 'SKIPPED: remote tmp not writable\n' >&2; exit 75; }; trap 'rm -rf \"\$tmp\"' EXIT INT TERM; gzip -dc | tar -xf - -C \"\$tmp\"; out=\"\$tmp/out\"; set +e; bash \"\$tmp/lib/collect-node.sh\" --out \"\$out\" --host-alias $q_alias --since $q_since --timeout $q_timeout"
experiments/ceph-incident-bundle/run/collect.sh:237:  tbin="$(timeout_cmd)"
experiments/ceph-incident-bundle/run/collect.sh:259:    # A node that streamed a valid archive but is missing its own manifest.jsonl
experiments/ceph-incident-bundle/run/collect.sh:261:    if [[ ! -f "$node_dir/manifest.jsonl" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:262:      printf 'SKIPPED: node archive from %s is incomplete (no manifest.jsonl); treated as failure\n' "$target" >"$node_dir/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:290:# EXIT trap, which fires after main has returned and its locals are gone.
experiments/ceph-incident-bundle/run/collect.sh:293:# Parsed inventory (alias/target pairs); filled by main, read by collect_clusters + node loop.
experiments/ceph-incident-bundle/run/collect.sh:294:HOST_ALIASES=()
experiments/ceph-incident-bundle/run/collect.sh:295:HOST_TARGETS=()
experiments/ceph-incident-bundle/run/collect.sh:312:  local timestamp workdir manifest bundle rc=0 cluster_rc=0 node_ok=0 node_failed=0
experiments/ceph-incident-bundle/run/collect.sh:396:  if [[ -z "$(timeout_cmd)" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:403:  manifest="$workdir/manifest.jsonl"
experiments/ceph-incident-bundle/run/collect.sh:407:  trap cleanup_workdir EXIT INT TERM
experiments/ceph-incident-bundle/run/collect.sh:413:  HOST_ALIASES=()
experiments/ceph-incident-bundle/run/collect.sh:414:  HOST_TARGETS=()
experiments/ceph-incident-bundle/run/collect.sh:421:    HOST_ALIASES+=("${entry%%=*}")
experiments/ceph-incident-bundle/run/collect.sh:422:    HOST_TARGETS+=("$(ssh_target_for_host "${entry#*=}" "$ssh_user")")
experiments/ceph-incident-bundle/run/collect.sh:426:  collect_clusters "$mode" "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout" "$rook_namespace" "$kube_context"
experiments/ceph-incident-bundle/run/collect.sh:435:  if [[ ${#HOST_ALIASES[@]} -gt 0 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:436:    for i in "${!HOST_ALIASES[@]}"; do
experiments/ceph-incident-bundle/run/collect.sh:437:      alias="${HOST_ALIASES[$i]}"
experiments/ceph-incident-bundle/run/collect.sh:438:      target="${HOST_TARGETS[$i]}"
experiments/ceph-incident-bundle/run/collect.sh:450:  # Test-only hook: simulate a mid-run abort to exercise trap cleanup. Inert in production.
experiments/ceph-incident-bundle/run/collect.sh:463:  "$COLLECT_ROOT/lib/verify-bundle.sh" "$workdir" >/dev/null 2>>"$workdir/errors.log"
experiments/ceph-incident-bundle/run/collect.sh:477:  "$COLLECT_ROOT/lib/verify-bundle.sh" "$bundle" >/dev/null 2>>"$workdir/errors.log"
experiments/ceph-incident-bundle/lib/verify-bundle.sh:8:Usage: verify-bundle.sh <bundle-dir|bundle.tar.gz>
experiments/ceph-incident-bundle/lib/verify-bundle.sh:50:  for required in manifest.jsonl summary.txt README-FIRST.txt; do
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:11:  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 artifact=$6
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:19:    run_capture "$manifest" "$seed" "collect-cluster-cephadm" "$artifact" -- \
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:95:  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 crash_ls_artifact=$6
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:113:    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$crash_info_artifact" crash info "$crash_id"; then
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:122:  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 since=$5 timeout=$6
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:170:    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$json_dir/$artifact" "${command_words[@]}"; then
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:180:    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$text_dir/$artifact" "${command_words[@]}"; then
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:185:  if ! collect_cephadm_recent_crashes "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$json_dir/crash-ls.json"; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:10:# Default kubectl prefix (local); collect_cluster_rook overrides it per call.
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:11:ROOK_KUBECTL_ARGV=(kubectl)
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:15:Usage: collect-cluster-rook.sh --out DIR --manifest PATH [--namespace rook-ceph]
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:35:  local outdir=$1 manifest=$2 timeout=$3 artifact_rel=$4
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:40:    run_capture "$manifest" "rook" "collect-cluster-rook" "$artifact" -- "$@"; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:49:  "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -l "$label" -o name 2>/dev/null |
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:53:collect_cluster_rook() {
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:54:  local outdir='' manifest='' namespace=rook-ceph since=24h timeout=20 allow_skip=0
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:63:      --manifest)
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:64:        manifest=${2-}
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:106:  [[ -n "$outdir" && -n "$manifest" ]] || {
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:113:  # Build the kubectl prefix once. With --ssh-target, kubectl runs ON that node
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:114:  # over ssh (the node where kubectl/kubeconfig lives); otherwise locally.
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:115:  # ROOK_KUBECTL_ARGV is global so rook_get_first_pod can use the same prefix.
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:117:    ROOK_KUBECTL_ARGV=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$ssh_target" kubectl)
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:119:    ROOK_KUBECTL_ARGV=(kubectl)
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:121:  [[ -n "$kube_context" ]] && ROOK_KUBECTL_ARGV+=(--context "$kube_context")
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:123:  # Missing kubectl / namespace means we collected NO cluster evidence. In
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:126:  # (When kubectl is remote we already probed it exists, so skip the local check.)
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:127:  if [[ -z "$ssh_target" ]] && ! command -v kubectl >/dev/null 2>&1; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:128:    rook_skip "$outdir" "kubectl command not found"
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:132:  if ! "${ROOK_KUBECTL_ARGV[@]}" get namespace "$namespace" >/dev/null 2>&1; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:138:  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/pods-wide.txt" \
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:139:    "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -o wide; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:142:  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/events.txt" \
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:143:    "${ROOK_KUBECTL_ARGV[@]}" get events -n "$namespace" --sort-by=.lastTimestamp; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:146:  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/rook-resources.yaml" \
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:147:    "${ROOK_KUBECTL_ARGV[@]}" get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n "$namespace" -o yaml; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:154:    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:155:      "${ROOK_KUBECTL_ARGV[@]}" logs -n "$namespace" "$operator_pod" --since="$since"; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:164:    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:165:      "${ROOK_KUBECTL_ARGV[@]}" exec -n "$namespace" "$toolbox_pod" -- ceph status; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:177:  collect_cluster_rook "$@"
experiments/ceph-incident-bundle/lib/common.sh:29:timeout_cmd() {
experiments/ceph-incident-bundle/lib/common.sh:47:manifest_add() {
experiments/ceph-incident-bundle/lib/common.sh:48:  local manifest=$1 host=$2 collector=$3 artifact=$4 command=$5 exit_code=$6 started=$7 ended=$8
experiments/ceph-incident-bundle/lib/common.sh:49:  [[ "$exit_code" =~ ^[0-9]+$ ]] || die "manifest_add requires numeric exit_code: $exit_code"
experiments/ceph-incident-bundle/lib/common.sh:50:  ensure_dir "$(dirname -- "$manifest")"
experiments/ceph-incident-bundle/lib/common.sh:58:    "$(json_escape "$ended")" >>"$manifest"
experiments/ceph-incident-bundle/lib/common.sh:140:  local manifest=$1 host=$2 collector=$3 artifact=$4
experiments/ceph-incident-bundle/lib/common.sh:161:  tbin="$(timeout_cmd)"
experiments/ceph-incident-bundle/lib/common.sh:186:  manifest_add "$manifest" "$host" "$collector" "$artifact" "$command_string" "$rc" "$started" "$ended"
experiments/ceph-incident-bundle/lib/collect-node.sh:23:  local outdir=$1 manifest=$2 host_alias=$3 timeout=$4 artifact_rel=$5
experiments/ceph-incident-bundle/lib/collect-node.sh:28:    run_capture "$manifest" "$host_alias" "collect-node" "$artifact" -- "$@"; then
experiments/ceph-incident-bundle/lib/collect-node.sh:35:  local outdir=$1 manifest=$2 host_alias=$3 timeout=$4 artifact_rel=$5 command_name=$6
experiments/ceph-incident-bundle/lib/collect-node.sh:43:  node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" "$command_name" "$@" || return 0
experiments/ceph-incident-bundle/lib/collect-node.sh:47:  local outdir=$1 manifest=$2 host_alias=$3 timeout=$4 artifact_rel=$5 command_name=$6
experiments/ceph-incident-bundle/lib/collect-node.sh:51:    node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" "$command_name" "$@"
experiments/ceph-incident-bundle/lib/collect-node.sh:60:  node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" sudo -n "$command_name" "$@"
experiments/ceph-incident-bundle/lib/collect-node.sh:155:  local outdir=$1 manifest=$2 host_alias=$3 timeout=$4
experiments/ceph-incident-bundle/lib/collect-node.sh:162:    if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "logs/ceph-log-listing.txt" \
experiments/ceph-incident-bundle/lib/collect-node.sh:222:  local outdir=$1 manifest=$2 host_alias=$3 timeout=$4
experiments/ceph-incident-bundle/lib/collect-node.sh:231:    if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "cephadm/var-lib-ceph-listing.txt" \
experiments/ceph-incident-bundle/lib/collect-node.sh:309:  local manifest="$outdir/manifest.jsonl"
experiments/ceph-incident-bundle/lib/collect-node.sh:338:    if ! node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact" "${command_words[@]}"; then
experiments/ceph-incident-bundle/lib/collect-node.sh:343:  if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "storage/lsblk.txt" lsblk -a -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL; then
experiments/ceph-incident-bundle/lib/collect-node.sh:346:  if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$heavy_timeout" "kernel/dmesg.txt" dmesg -T; then
experiments/ceph-incident-bundle/lib/collect-node.sh:349:  if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$heavy_timeout" "systemd/journal-ceph.txt" journalctl --since "$journal_since" -u 'ceph*' --no-pager; then
experiments/ceph-incident-bundle/lib/collect-node.sh:353:  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "resources/iostat.txt" iostat -xz 1 3; then
experiments/ceph-incident-bundle/lib/collect-node.sh:356:  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "time/chronyc-tracking.txt" chronyc tracking; then
experiments/ceph-incident-bundle/lib/collect-node.sh:359:  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "time/chronyc-sources.txt" chronyc sources -v; then
experiments/ceph-incident-bundle/lib/collect-node.sh:362:  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "time/ntpq-peers.txt" ntpq -pn; then
experiments/ceph-incident-bundle/lib/collect-node.sh:365:  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "storage/pvs.txt" pvs --noheadings --separator ' '; then
experiments/ceph-incident-bundle/lib/collect-node.sh:368:  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "storage/vgs.txt" vgs --noheadings --separator ' '; then
experiments/ceph-incident-bundle/lib/collect-node.sh:371:  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "storage/lvs.txt" lvs --noheadings --separator ' '; then
experiments/ceph-incident-bundle/lib/collect-node.sh:374:  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "containers/podman-ps.txt" podman ps -a; then
experiments/ceph-incident-bundle/lib/collect-node.sh:377:  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "containers/docker-ps.txt" docker ps -a; then
experiments/ceph-incident-bundle/lib/collect-node.sh:382:    node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "cephadm/cephadm-ls.json" cephadm ls --format json-pretty || true
experiments/ceph-incident-bundle/lib/collect-node.sh:388:  if ! collect_var_lib_ceph "$outdir" "$manifest" "$host_alias" "$timeout"; then
experiments/ceph-incident-bundle/lib/collect-node.sh:395:    if ! collect_ceph_log_listing "$outdir" "$manifest" "$host_alias" "$timeout"; then
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:19:  local outdir=$1 manifest=$2
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:23:    --manifest "$manifest" \
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:31:trap 'rm -rf "$tmpdir"' EXIT
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
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:114:    printf 'unexpected kubectl command: %s\n' "$cmd" >&2
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:119:chmod +x "$fakebin/kubectl"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:121:export FAKE_KUBECTL_LOG="$tmpdir/kubectl.log"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:124:manifest_missing_ns="$tmpdir/manifest-missing-ns.jsonl"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:127:FAKE_KUBECTL_MODE=missing-namespace PATH="$fakebin:$PATH" run_rook_collector "$out_missing_ns" "$manifest_missing_ns"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:134:manifest_present="$tmpdir/manifest-present.jsonl"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:135:FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" run_rook_collector "$out_present" "$manifest_present"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:146:# --- remote (ssh-target) mode: kubectl runs via ssh on the chosen node, with --context ---
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:152:# argv: -i key <opts...> target kubectl <kubectl args...>; forward everything after 'kubectl'
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:157:  [[ "$a" == "kubectl" ]] && seen=1
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:159:exec kubectl "${argv[@]}"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:165:manifest_remote="$tmpdir/manifest-remote.jsonl"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:168:  --out "$out_remote" --manifest "$manifest_remote" \
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:174:grep -qF -- '--context lab' "$fake_ssh_log" || fail "remote kubectl missing --context"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:175:grep -qF 'tester@node2 kubectl' "$fake_ssh_log" || fail "kubectl did not run via ssh on the target node"
experiments/ceph-incident-bundle/tests/test-collect.sh:33:trap 'rm -rf "$tmpdir"' EXIT
experiments/ceph-incident-bundle/tests/test-collect.sh:50:# fake bins: capability-aware ssh, fake kubectl, passthrough timeout
experiments/ceph-incident-bundle/tests/test-collect.sh:54:#     - "kubectl"                               -> forward to the fake kubectl
experiments/ceph-incident-bundle/tests/test-collect.sh:61:cat >"$fakebin/kubectl" <<'EOF'
experiments/ceph-incident-bundle/tests/test-collect.sh:74:  *) printf 'unexpected kubectl: %s\n' "$cmd" >&2; exit 99 ;;
experiments/ceph-incident-bundle/tests/test-collect.sh:93:# Order matters: the capability-probe script also contains "kubectl", so it must
experiments/ceph-incident-bundle/tests/test-collect.sh:94:# be matched before the kubectl-forward branch.
experiments/ceph-incident-bundle/tests/test-collect.sh:100:    for t in ${FAKE_KUBE_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps kubectl"; done
experiments/ceph-incident-bundle/tests/test-collect.sh:115:    t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
experiments/ceph-incident-bundle/tests/test-collect.sh:119:      printf '{"node":"%s"}\n' "$alias_name" >"$t/manifest.jsonl"
experiments/ceph-incident-bundle/tests/test-collect.sh:126:  *kubectl*)
experiments/ceph-incident-bundle/tests/test-collect.sh:130:      [[ "$a" == "kubectl" ]] && seen=1
experiments/ceph-incident-bundle/tests/test-collect.sh:132:    exec kubectl "${kargs[@]}"
experiments/ceph-incident-bundle/tests/test-collect.sh:140:chmod +x "$fakebin/kubectl" "$fakebin/ssh" "$fakebin/timeout"
experiments/ceph-incident-bundle/tests/test-collect.sh:173:grep -qF -- '--context lab' "$FAKE_SSH_LOG" || fail "rook kubectl missing --context in auto mode"
experiments/ceph-incident-bundle/tests/test-collect.sh:174:grep -qF '10.0.0.9 kubectl' "$FAKE_SSH_LOG" || fail "rook kubectl did not run on the kube node"
experiments/ceph-incident-bundle/tests/test-collect.sh:196:# explicit --mode cephadm --seed: only ceph layer, no kubectl probing/collection
experiments/ceph-incident-bundle/tests/test-collect.sh:205:grep -qF 'kubectl' "$FAKE_SSH_LOG" && fail "cephadm mode should not run kubectl" || true
experiments/ceph-incident-bundle/tests/test-collect.sh:239:# C4: truncated node (no manifest) -> SKIPPED, exit 2
experiments/ceph-incident-bundle/tests/test-collect.sh:244:[[ "$st" == "2" ]] || fail "missing node manifest should exit 2, got $st"
experiments/ceph-incident-bundle/tests/test-collect.sh:263:# C2: abort mid-run -> trap cleans workdir (no tmp.* left)
experiments/ceph-incident-bundle/tests/test-node-collector.sh:18:trap 'rm -rf "$tmpdir"' EXIT
experiments/ceph-incident-bundle/tests/test-common.sh:12:trap 'rm -rf "$tmpdir"' EXIT
experiments/ceph-incident-bundle/tests/test-common.sh:38:test_manifest_add() {
experiments/ceph-incident-bundle/tests/test-common.sh:39:  local manifest="$tmpdir/manifest.jsonl"
experiments/ceph-incident-bundle/tests/test-common.sh:43:  manifest_add \
experiments/ceph-incident-bundle/tests/test-common.sh:44:    "$manifest" \
experiments/ceph-incident-bundle/tests/test-common.sh:53:  python3 - "$manifest" <<'PY'
experiments/ceph-incident-bundle/tests/test-common.sh:60:    raise SystemExit(f"expected 1 manifest entry, got {len(lines)}")
experiments/ceph-incident-bundle/tests/test-common.sh:65:    "artifact": path.replace("manifest.jsonl", "artifact.txt"),
experiments/ceph-incident-bundle/tests/test-common.sh:77:test_manifest_add_rejects_non_numeric_exit_code() {
experiments/ceph-incident-bundle/tests/test-common.sh:78:  local manifest="$tmpdir/invalid-manifest.jsonl"
experiments/ceph-incident-bundle/tests/test-common.sh:92:      manifest_add \
experiments/ceph-incident-bundle/tests/test-common.sh:101:    ' bash "$ROOT" "$manifest" "$artifact" 2>&1
experiments/ceph-incident-bundle/tests/test-common.sh:105:  [[ "$rc" != "0" ]] || fail "manifest_add accepted a non-numeric exit code"
experiments/ceph-incident-bundle/tests/test-common.sh:106:  [[ "$output" == *"exit_code"* ]] || fail "manifest_add did not explain the exit_code failure"
experiments/ceph-incident-bundle/tests/test-common.sh:225:  local manifest="$tmpdir/run-manifest.jsonl"
experiments/ceph-incident-bundle/tests/test-common.sh:228:  run_capture "$manifest" "host-a" "collector-a" "$artifact" -- printf 'hello world\n'
experiments/ceph-incident-bundle/tests/test-common.sh:232:  python3 - "$manifest" "$artifact" <<'PY'
experiments/ceph-incident-bundle/tests/test-common.sh:236:manifest_path, artifact_path = sys.argv[1:3]
experiments/ceph-incident-bundle/tests/test-common.sh:237:lines = [line.rstrip("\n") for line in open(manifest_path)]
experiments/ceph-incident-bundle/tests/test-common.sh:239:    raise SystemExit(f"expected 1 manifest entry, got {len(lines)}")
experiments/ceph-incident-bundle/tests/test-common.sh:249:  local manifest="$tmpdir/run-manifest-fail.jsonl"
experiments/ceph-incident-bundle/tests/test-common.sh:254:  ERROR_LOG="$error_log" run_capture "$manifest" "host-b" "collector-b" "$artifact" -- bash -c 'printf fail-output; exit 7' || rc=$?
experiments/ceph-incident-bundle/tests/test-common.sh:258:  python3 - "$manifest" <<'PY'
experiments/ceph-incident-bundle/tests/test-common.sh:269:  local manifest="$tmpdir/run-manifest-missing-dash.jsonl"
experiments/ceph-incident-bundle/tests/test-common.sh:283:    ' bash "$ROOT" "$manifest" "$artifact" 2>&1
experiments/ceph-incident-bundle/tests/test-common.sh:303:  local manifest="$tmpdir/run-manifest-timeout.jsonl"
experiments/ceph-incident-bundle/tests/test-common.sh:305:  PATH="$fakebin:$PATH" TIMEOUT_LOG="$timeout_log" run_capture "$manifest" "host-d" "collector-d" "$artifact" -- printf 'timeout-path\n'
experiments/ceph-incident-bundle/tests/test-common.sh:313:  local manifest="$tmpdir/run-manifest-leading-dash.jsonl"
experiments/ceph-incident-bundle/tests/test-common.sh:319:    run_capture "$manifest" "host-dash" "collector-dash" "-leading-dash.txt" -- printf 'dash-safe\n'
experiments/ceph-incident-bundle/tests/test-common.sh:327:  local manifest="$tmpdir/run-manifest-state.jsonl"
experiments/ceph-incident-bundle/tests/test-common.sh:332:  run_capture "$manifest" "host-e" "collector-e" "$artifact" -- bash -c 'exit 3'
experiments/ceph-incident-bundle/tests/test-common.sh:343:test_manifest_add
experiments/ceph-incident-bundle/tests/test-common.sh:344:test_manifest_add_rejects_non_numeric_exit_code
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:12:trap 'rm -rf "$tmpdir"' EXIT
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:45:read_manifest_count() {
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:46:  local manifest=$1
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:47:  [[ -f "$manifest" ]] || fail "missing manifest: $manifest"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:48:  wc -l <"$manifest" | tr -d ' '
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:53:  local manifest="$tmpdir/manifest-happy.jsonl"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:59:  collect_cluster_cephadm "$outdir" "$manifest" "monitor01@example.invalid" "$tmpdir/id_ed25519" "7 days ago" "30"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:81:  [[ "$(read_manifest_count "$manifest")" == "34" ]] || fail "expected 34 manifest entries"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:92:  local manifest="$tmpdir/manifest-partial.jsonl"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:100:  collect_cluster_cephadm "$outdir" "$manifest" "monitor01@example.invalid" "$tmpdir/id_ed25519" "7 days ago" "30"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:109:  grep -qF 'exit_code":17' "$manifest" || fail "manifest did not record the failing command"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:114:  local manifest="$tmpdir/manifest-broken.jsonl"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:120:  collect_cluster_cephadm "$outdir" "$manifest" "monitor01@example.invalid" "$tmpdir/id_ed25519" "7 days ago" "30"
experiments/ceph-incident-bundle/tests/run-tests.sh:24:  "$ROOT/lib/verify-bundle.sh" \
experiments/ceph-incident-bundle/tests/run-tests.sh:29:  "$ROOT/tests/test-verify-bundle.sh"; do
experiments/ceph-incident-bundle/tests/run-tests.sh:33:for path in "$ROOT/run/collect.sh" "$ROOT/lib/verify-bundle.sh"; do
experiments/ceph-incident-bundle/tests/run-tests.sh:43:verify_no_args="$(run_and_capture "$ROOT/lib/verify-bundle.sh")"
experiments/ceph-incident-bundle/tests/run-tests.sh:46:[[ "$verify_no_args_status" == "1" ]] || fail "verify-bundle.sh no args should exit 1, got $verify_no_args_status"
experiments/ceph-incident-bundle/tests/run-tests.sh:47:[[ "$verify_no_args_output" == *"Usage:"* ]] || fail "verify-bundle.sh no args should print usage"
experiments/ceph-incident-bundle/tests/run-tests.sh:49:verify_placeholder_args="$(run_and_capture "$ROOT/lib/verify-bundle.sh" /tmp/definitely-not-a-bundle)"
experiments/ceph-incident-bundle/tests/run-tests.sh:52:[[ "$verify_placeholder_status" != "0" ]] || fail "verify-bundle.sh placeholder args should not exit 0"
experiments/ceph-incident-bundle/tests/run-tests.sh:53:[[ "$verify_placeholder_output" == *"VERIFY FAIL:"* || "$verify_placeholder_output" == *"Usage:"* || "$verify_placeholder_output" == *"error"* ]] || fail "verify-bundle.sh placeholder args should explain failure"
experiments/ceph-incident-bundle/tests/run-tests.sh:66:verify_bundle_args="$(run_and_capture "$ROOT/tests/test-verify-bundle.sh")"
experiments/ceph-incident-bundle/tests/run-tests.sh:69:[[ "$verify_bundle_status" == "0" ]] || fail "test-verify-bundle.sh failed: $verify_bundle_output"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:21:trap 'rm -rf "$tmpdir"' EXIT
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:29:  cat >"$dir/manifest.jsonl" <<'EOF'
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:47:  result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$target")"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:58:  result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$target")"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:72:missing_manifest_dir="$tmpdir/missing-manifest"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:73:mkdir -p "$missing_manifest_dir"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:74:make_valid_bundle_dir "$missing_manifest_dir"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:75:rm -f "$missing_manifest_dir/manifest.jsonl"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:76:missing_manifest_archive="$tmpdir/missing-manifest.tar.gz"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:77:make_bundle_archive "$missing_manifest_dir" "$missing_manifest_archive"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:81:cat >"$keyring_dir/manifest.jsonl" <<'EOF'
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:93:cat >"$ssh_dir/manifest.jsonl" <<'EOF'
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:105:cat >"$id_ed25519_dir/manifest.jsonl" <<'EOF'
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:117:cat >"$private_key_dir/manifest.jsonl" <<'EOF'
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:129:cat >"$pem_dir/manifest.jsonl" <<'EOF'
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:142:cat >"$content_key_dir/manifest.jsonl" <<'EOF'
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:163:assert_fail "$missing_manifest_dir" "manifest.jsonl"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:164:assert_fail "$missing_manifest_archive" "manifest.jsonl"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:179:extra_args_result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$valid_dir" extra)"

exec
/bin/zsh -lc 'rg -n "''^(HOSTS|SSH_USER|SEED_HOST|ROOK_NAMESPACE)|HOSTS=|SEED_HOST" experiments/ceph-incident-bundle/inventory experiments/ceph-incident-bundle -g '"'*.env' -g '*.md'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/inventory/ceph-lab.example.env:1:SSH_USER="ikaros"
experiments/ceph-incident-bundle/inventory/ceph-lab.example.env:2:SEED_HOST="192.168.18.166"
experiments/ceph-incident-bundle/inventory/ceph-lab.example.env:3:HOSTS=(
experiments/ceph-incident-bundle/README.md:48:SSH_USER="ikaros"
experiments/ceph-incident-bundle/README.md:49:SEED_HOST="192.168.18.166"
experiments/ceph-incident-bundle/README.md:50:ROOK_NAMESPACE="rook-ceph"
experiments/ceph-incident-bundle/README.md:51:HOSTS=(
experiments/ceph-incident-bundle/README.md:59:- `SEED_HOST`：**選填**。手動指定 cluster-level `ceph` command 要在哪台跑;不填則 `auto` 會自動挑第一台有 `cephadm` 的 node。
experiments/ceph-incident-bundle/README.md:83:SSH_USER="ikaros"
experiments/ceph-incident-bundle/README.md:84:HOSTS=(
experiments/ceph-incident-bundle/inventory/ceph-lab.example.env:1:SSH_USER="ikaros"
experiments/ceph-incident-bundle/inventory/ceph-lab.example.env:2:SEED_HOST="192.168.18.166"
experiments/ceph-incident-bundle/inventory/ceph-lab.example.env:3:HOSTS=(

codex
The implementation is using Bash 3.2 here, so I can directly check the empty-array cases without changing the repo. That should settle whether the new guarded loops are actually safe.
exec
/bin/zsh -lc "bash -uc 'a=(); echo len="'${#a[@]}; if [[ ${#a[@]} -gt 0 ]]; then for i in "${!a[@]}"; do echo "$i"; done; fi; echo ok'"' ; bash -uc 'a=(); printf \"<%s>\\n\" \""'${a[@]+${a[@]}}"; echo ok'"'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
len=0
ok
<>
ok

codex
The Bash empty-array checks pass under the local Bash 3.2. I’m going to run the two targeted test scripts if the sandbox allows temp-file writes; if it fails due sandbox, I’ll treat that as an environment limit rather than evidence.
codex
One thing I’m validating against docs is whether `rook` is now intentionally remote-only through inventory, or whether local `kubectl` from the workstation is still a supported path in the main entrypoint. That distinction decides whether a missing local fallback is a real regression or just a changed contract.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/README.md | sed -n '1,180p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	# Ceph Incident Bundle
     2	
     3	## 這是做什麼的
     4	
     5	這套 script 是事故發生時的「先保留現場」工具。它會從一台工作機透過 SSH 到所有 Ceph node 收集系統狀態、Ceph 狀態、log 清單與必要 log，最後打包成一個 `.tar.gz`。
     6	
     7	它不會修復 Ceph，也不會執行 restart、delete、repair、scrub 這類會改變 cluster 狀態的操作。
     8	
     9	## 什麼時候執行
    10	
    11	建議在以下情境先跑一次：
    12	
    13	- `ceph health detail` 出現 `HEALTH_WARN` 或 `HEALTH_ERR`
    14	- OSD down、PG stuck、I/O latency 異常、MON quorum 異常
    15	- node CPU、RAM、disk、網路看起來異常，但還不確定是不是 Ceph 問題
    16	- 準備請別人或 AI 協助判讀，需要保留當下證據
    17	
    18	## 最短操作流程
    19	
    20	在 repo root 執行：
    21	
    22	```bash
    23	bash experiments/ceph-incident-bundle/run/collect.sh \
    24	  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
    25	  --ssh-key .ssh/id_ed25519 \
    26	  --seed ikaros@192.168.18.166 \
    27	  --mode cephadm \
    28	  --since 24h
    29	```
    30	
    31	成功後會看到：
    32	
    33	```text
    34	bundle: experiments/ceph-incident-bundle/results/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
    35	```
    36	
    37	驗證 bundle：
    38	
    39	```bash
    40	bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle.tar.gz>
    41	```
    42	
    43	## 如何填 inventory
    44	
    45	Inventory 是 shell 檔案，格式如下：
    46	
    47	```bash
    48	SSH_USER="ikaros"
    49	SEED_HOST="192.168.18.166"
    50	ROOK_NAMESPACE="rook-ceph"
    51	HOSTS=(
    52	  "monitor01=192.168.18.166"
    53	  "mon02=192.168.18.167"
    54	  "osd01=192.168.18.169"
    55	)
    56	```
    57	
    58	- `SSH_USER`：登入每台 node 的 Linux 帳號。
    59	- `SEED_HOST`：**選填**。手動指定 cluster-level `ceph` command 要在哪台跑;不填則 `auto` 會自動挑第一台有 `cephadm` 的 node。
    60	- `ROOK_NAMESPACE`：Rook 的 namespace，未填時預設 `rook-ceph`。
    61	- `HOSTS`：每個項目是 `alias=host`，alias 會成為 bundle 裡 `nodes/<alias>/` 的目錄名稱。external-ceph rook 拓樸可以把 **external ceph 主機與 k8s node 混在同一份** `HOSTS` 裡。
    62	
    63	## 自動偵測（auto，預設）
    64	
    65	預設 `--mode auto` 會逐台 node 經 ssh 偵測能力，再分層收集：
    66	
    67	- node 上有 `cephadm` → 從**第一台**有 cephadm 的 node 收 cluster-level ceph（`sudo -n cephadm shell -- ceph ...`）。
    68	- node 上有 `kubectl` → 從**第一台**有 kubectl 的 node、用 ssh 在該 node 上跑 `kubectl`（可加 `--kube-context`）收 rook 層。
    69	- 兩層都有來源就都收、各收一次;node 層一律每台都收。
    70	
    71	```bash
    72	bash experiments/ceph-incident-bundle/run/collect.sh \
    73	  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
    74	  --ssh-key .ssh/id_ed25519 \
    75	  --since 24h
    76	```
    77	
    78	## external ceph + rook（一份 inventory）
    79	
    80	把 external ceph 主機和有 `kubectl` 的 k8s node 列進同一份 `HOSTS`，`auto` 會：ceph 層從 ceph 主機收、rook 層在 k8s node 上跑 kubectl 收。指定 context：
    81	
    82	```bash
    83	SSH_USER="ikaros"
    84	HOSTS=(
    85	  "mon01=10.0.0.1"     # external ceph（有 cephadm）
    86	  "osd01=10.0.0.2"     # external ceph
    87	  "k8s1=10.0.0.9"      # k8s node（有 kubectl）
    88	)
    89	```
    90	
    91	```bash
    92	bash experiments/ceph-incident-bundle/run/collect.sh \
    93	  --inventory inventory/external.env \
    94	  --ssh-key ~/.ssh/id_ed25519 \
    95	  --kube-context my-cluster \
    96	  --since 24h
    97	```
    98	
    99	## 只收單層（覆寫）
   100	
   101	- `--mode cephadm`（可配 `--seed USER@HOST`）：只收 ceph 層。
   102	- `--mode rook`：只收 rook 層（在第一台有 kubectl 的 node 上跑）。
   103	
   104	## 逾時與大型 log
   105	
   106	- `--timeout`（預設 20s）是**單一指令 / SSH 連線**的逾時。
   107	- `--node-timeout`（預設 600s）是**單一 node 整輪收集**的逾時。兩者分開：慢或大的 node 不會被單指令逾時誤殺。
   108	- 大型 Ceph log（超過 `CEPH_INCIDENT_LOG_FILE_CAP_BYTES`，預設 1 MiB）不會被靜默丟棄，而是收最後一段（tail）並附 `<檔名>.TRUNCATED` 記錄原始大小；壓縮過的 `*.gz` 過大時則只記錄、不收（gzip 的尾段無法解壓）。
   109	- 被逾時砍掉（exit 124/137）的指令輸出會在 artifact 末尾標 `# TRUNCATED`，讓判讀者知道內容被截斷。
   110	- **工作機若沒有 `timeout` / `gtimeout`**（如預設 macOS），會在開頭印警告；此時外層逾時停用，只靠 SSH `ConnectTimeout` / `ServerAlive` 把關。要完整把關可 `brew install coreutils`（提供 `gtimeout`），或在 Linux ops 機執行。
   111	
   112	## bundle 內有什麼
   113	
   114	主要檔案：
   115	
   116	- `README-FIRST.txt`：打開 bundle 後先看的入口。
   117	- `summary.txt`：本次收集摘要與成功/失敗數。
   118	- `environment.txt`：收集時間、mode、seed、git commit。
   119	- `manifest.jsonl`：每個 artifact 的 command、exit code、時間。
   120	- `errors.log`：非零 exit code、SSH 失敗、部分失敗。
   121	- `cluster/`：cephadm 或 Rook cluster-level 狀態。
   122	- `nodes/<alias>/`：每台 node 的系統、資源、disk、kernel、systemd、Ceph log 與 cephadm 狀態。
   123	
   124	## exit code 怎麼看
   125	
   126	- `0`：收集完成，沒有已知失敗。（注意：OSD/MON down 這類**叢集故障本身**會被收進 bundle，不算收集失敗，仍是 `0`。）
   127	- `2`：有部分 command 或部分 node 失敗，但 bundle 已產生。先看 `errors.log` 和 `summary.txt`。
   128	- `1`：使用方式或必要輸入錯誤（inventory / SSH key 不存在），或 **bundle 驗證失敗**。驗證失敗時不會打包可分享的 `.tar.gz`，而是**保留 workdir**（印出路徑）讓你檢查——已收集的證據不會因驗證失敗被刪掉。
   129	
   130	## 常見失敗與處理
   131	
   132	- `missing inventory`：確認 `--inventory` 路徑存在。
   133	- `missing ssh key`：確認 `--ssh-key` 路徑存在，且本機可讀。
   134	- `node <alias> collector exited 255`：通常是 SSH 連線、帳號、key、known_hosts 或 sudo 權限問題。
   135	- `VERIFY FAIL`：bundle 結構不完整，或包含 `keyring`、`.ssh`、`id_ed25519`、`private_key`、`*.pem`/`*.key`/`*.crt` 這類路徑，或檔案內容殘留未遮蔽的 private key / `key = <base64>` 金鑰材料。此時 workdir 會被保留、不打包，先看印出的路徑與 `errors.log`。
   136	- exit code `2`：先不要重跑覆蓋判讀脈絡，先保留 `.tar.gz`，再看 `errors.log` 決定是否針對失敗 node 補跑。
   137	
   138	## 安全界線
   139	
   140	- 這套工具以 read-only 收集為原則，不會主動修復或改變 Ceph 狀態。
   141	- 遮蔽（redaction）涵蓋：含 `password`/`secret`/`token`/`keyring`/`private key` 的文字行、Ceph 金鑰材料（`key = AQB..==` 與 base64 區塊）、整段多行 PEM private key block；並會把 `*.gz` 解壓後遮蔽再壓回。但這**不是完整 DLP**。
   142	- `verify-bundle.sh` 會以**檔名**（keyring/.ssh/id_ed25519/private_key/*.pem/*.key/*.crt）與**內容**（殘留的 PRIVATE KEY block / `key = <base64>`）兩道把關，但仍不能保證內容完全沒有敏感資料。
   143	- 分享 bundle 前仍應自行檢查是否包含內部 IP、hostname、路徑、帳號名稱或其他敏感資料。
   144	
   145	## Lab 驗證（multi-fault）
   146	
   147	2026-06-30 在真 cephadm v19.2.3 叢集（3 mon + 9 OSD、pool `.mgr` size 3）跑過多故障矩陣，破壞性情境皆先 `ok-to-stop` / 確認 quorum 後注入並立即回退，最後 HEALTH_OK：
   148	
   149	| 情境 | 注入 | bundle | exit |
   150	|---|---|---|---|
   151	| 健康基準 | 無 | VERIFY PASS、6/6 node、312 行遮蔽 | 0 |
   152	| OSD down | 停 osd.0 | 收到 `OSD_DOWN`（text+json）| 0 |
   153	| MON 少一台 | 停 mon-02（quorum 在）| 收到 `MON_DOWN`（out of quorum）| 0 |
   154	| node 不可達 | inventory 加假 host | 該 node `SKIPPED.txt`、其餘照收、errors.log 有記 | 2 |
   155	| seed 不可達 | `--seed` 指死 host | cluster collector 失敗、6 node 仍收 | 2 |
   156	
   157	詳見 `docs/superpowers/reviews/2026-06-30-lab-validation.md`。
   158	
   159	- 已知 optional/read-only 非零紀錄：各 node 的 LVM 查詢（`pvs` / `vgs` / `lvs`）、`docker ps -a`、node-level `sudo cephadm ls --format json-pretty` 可能回非零；artifact 與 node 內部 `errors.log` 會保留原始輸出，整體 bundle 仍驗證通過。

exec
/bin/zsh -lc 'git diff 38c16e2..HEAD -- experiments/ceph-incident-bundle/README.md docs/superpowers/specs/2026-06-30-ceph-incident-bundle-autodetect.md docs/superpowers/plans/2026-06-30-ceph-incident-bundle-autodetect-design.md' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-VQWosivJ' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-FV9BWFio' (errno=Operation not permitted)
diff --git a/experiments/ceph-incident-bundle/README.md b/experiments/ceph-incident-bundle/README.md
index 3e264bf..8c0e6e4 100644
--- a/experiments/ceph-incident-bundle/README.md
+++ b/experiments/ceph-incident-bundle/README.md
@@ -56,46 +56,50 @@ HOSTS=(
 ```
 
 - `SSH_USER`：登入每台 node 的 Linux 帳號。
-- `SEED_HOST`：cephadm mode 用來跑 cluster-level `ceph` command 的 node。
-- `ROOK_NAMESPACE`：Rook mode 的 namespace，未填時預設 `rook-ceph`。
-- `HOSTS`：每個項目是 `alias=host`，alias 會成為 bundle 裡 `nodes/<alias>/` 的目錄名稱。
+- `SEED_HOST`：**選填**。手動指定 cluster-level `ceph` command 要在哪台跑;不填則 `auto` 會自動挑第一台有 `cephadm` 的 node。
+- `ROOK_NAMESPACE`：Rook 的 namespace，未填時預設 `rook-ceph`。
+- `HOSTS`：每個項目是 `alias=host`，alias 會成為 bundle 裡 `nodes/<alias>/` 的目錄名稱。external-ceph rook 拓樸可以把 **external ceph 主機與 k8s node 混在同一份** `HOSTS` 裡。
 
-## cephadm 範例
+## 自動偵測（auto，預設）
+
+預設 `--mode auto` 會逐台 node 經 ssh 偵測能力，再分層收集：
+
+- node 上有 `cephadm` → 從**第一台**有 cephadm 的 node 收 cluster-level ceph（`sudo -n cephadm shell -- ceph ...`）。
+- node 上有 `kubectl` → 從**第一台**有 kubectl 的 node、用 ssh 在該 node 上跑 `kubectl`（可加 `--kube-context`）收 rook 層。
+- 兩層都有來源就都收、各收一次;node 層一律每台都收。
 
 ```bash
 bash experiments/ceph-incident-bundle/run/collect.sh \
   --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
   --ssh-key .ssh/id_ed25519 \
-  --mode cephadm \
   --since 24h
 ```
 
-cephadm mode 會透過 seed node 執行：
-
-```text
-sudo cephadm shell -- ceph ...
-```
-
-## Rook 範例
+## external ceph + rook（一份 inventory）
 
-先建立自己的 inventory：
+把 external ceph 主機和有 `kubectl` 的 k8s node 列進同一份 `HOSTS`，`auto` 會：ceph 層從 ceph 主機收、rook 層在 k8s node 上跑 kubectl 收。指定 context：
 
 ```bash
-cp experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
-  experiments/ceph-incident-bundle/inventory/rook.env
+SSH_USER="ikaros"
+HOSTS=(
+  "mon01=10.0.0.1"     # external ceph（有 cephadm）
+  "osd01=10.0.0.2"     # external ceph
+  "k8s1=10.0.0.9"      # k8s node（有 kubectl）
+)
 ```
 
-編輯 `experiments/ceph-incident-bundle/inventory/rook.env`，把 `HOSTS` 改成 Rook 所在的 Kubernetes node，並確認 `ROOK_NAMESPACE`。
-
 ```bash
 bash experiments/ceph-incident-bundle/run/collect.sh \
-  --inventory experiments/ceph-incident-bundle/inventory/rook.env \
+  --inventory inventory/external.env \
   --ssh-key ~/.ssh/id_ed25519 \
-  --mode rook \
+  --kube-context my-cluster \
   --since 24h
 ```
 
-Rook mode 會在本機使用 `kubectl get`、`kubectl logs`，並在 toolbox Pod 存在時執行 read-only 的 `ceph status`。
+## 只收單層（覆寫）
+
+- `--mode cephadm`（可配 `--seed USER@HOST`）：只收 ceph 層。
+- `--mode rook`：只收 rook 層（在第一台有 kubectl 的 node 上跑）。
 
 ## 逾時與大型 log
 

exec
/bin/zsh -lc "git show 38c16e2:experiments/ceph-incident-bundle/run/collect.sh | nl -ba | sed -n '1,240p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-VRyZr34G' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-sBKN28p7' (errno=Operation not permitted)
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
    14	
    15	usage() {
    16	  cat <<'EOF'
    17	Usage: collect.sh --inventory PATH --ssh-key PATH [options]
    18	
    19	One command example:
    20	  bash experiments/ceph-incident-bundle/run/collect.sh \
    21	    --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
    22	    --ssh-key .ssh/id_ed25519 \
    23	    --mode cephadm \
    24	    --since 24h
    25	
    26	Required:
    27	  --inventory PATH       shell inventory with HOSTS=( "alias=host" ... )
    28	  --ssh-key PATH         SSH private key used to reach every node
    29	
    30	Options:
    31	  --seed USER@HOST       override inventory SEED_HOST
    32	  --out DIR              output dir (default: experiments/ceph-incident-bundle/results)
    33	  --mode auto|cephadm|rook
    34	  --since DURATION       log/journal window (default: 24h)
    35	  --timeout SECONDS      per-command / SSH-connect timeout (default: 20)
    36	  --node-timeout SECONDS overall timeout for one node's full collection (default: 600)
    37	  --skip-logs            collect state but skip larger Ceph log copies
    38	  --keep-workdir         keep temporary extracted workdir for debugging
    39	  --help                 print this help
    40	
    41	Output:
    42	  DIR/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
    43	
    44	Exit codes:
    45	  0 complete, 2 partial collection failure with bundle produced, 1 usage/config/verify failure
    46	EOF
    47	}
    48	
    49	parse_host_entry() {
    50	  local entry=$1
    51	  [[ "$entry" == *=* ]] || return 1
    52	  printf '%s\n' "${entry%%=*}" "${entry#*=}"
    53	}
    54	
    55	ssh_target_for_host() {
    56	  local host=$1 ssh_user=$2
    57	  if [[ "$host" == *@* || -z "$ssh_user" ]]; then
    58	    printf '%s' "$host"
    59	  else
    60	    printf '%s@%s' "$ssh_user" "$host"
    61	  fi
    62	}
    63	
    64	shell_quote() {
    65	  local value=$1
    66	  [[ "$value" != *"'"* ]] || return 1
    67	  printf "'%s'" "$value"
    68	}
    69	
    70	write_initial_metadata() {
    71	  local workdir=$1 mode=$2 seed=$3 since=$4 timeout=$5
    72	  local git_commit
    73	  git_commit="$(git -C "$COLLECT_ROOT/../.." rev-parse --short HEAD 2>/dev/null || printf unknown)"
    74	
    75	  cat >"$workdir/README-FIRST.txt" <<'EOF'
    76	Ceph incident bundle
    77	
    78	Start with:
    79	- summary.txt
    80	- errors.log
    81	- cluster/
    82	- nodes/
    83	
    84	This bundle is read-only evidence captured at incident time. Review it before sharing outside your team.
    85	EOF
    86	
    87	  cat >"$workdir/environment.txt" <<EOF
    88	created_utc=$(date -u +%FT%TZ)
    89	mode=$mode
    90	seed=$seed
    91	since=$since
    92	timeout=$timeout
    93	git_commit=$git_commit
    94	EOF
    95	
    96	  : >"$workdir/manifest.jsonl"
    97	  : >"$workdir/errors.log"
    98	}
    99	
   100	write_summary() {
   101	  local workdir=$1 mode=$2 seed=$3 node_ok=$4 node_failed=$5 cluster_status=$6 final_status=$7
   102	
   103	  {
   104	    printf 'Ceph incident bundle summary\n'
   105	    printf 'created_utc: %s\n' "$(date -u +%FT%TZ)"
   106	    printf 'mode: %s\n' "$mode"
   107	    printf 'seed: %s\n' "$seed"
   108	    printf 'cluster_status: %s\n' "$cluster_status"
   109	    printf 'node_ok: %s\n' "$node_ok"
   110	    printf 'node_failed: %s\n' "$node_failed"
   111	    printf 'final_status: %s\n' "$final_status"
   112	  } >"$workdir/summary.txt"
   113	}
   114	
   115	append_error() {
   116	  local workdir=$1 message=$2
   117	  printf '%s %s\n' "$(date -u +%FT%TZ)" "$message" >>"$workdir/errors.log"
   118	}
   119	
   120	run_cluster_collector() {
   121	  local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8
   122	  local -a probe_cmd
   123	
   124	  case "$mode" in
   125	    cephadm)
   126	      [[ -n "$seed" && -n "$ssh_key" ]] || return 1
   127	      collect_cluster_cephadm "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout"
   128	      ;;
   129	    rook)
   130	      collect_cluster_rook --out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout"
   131	      ;;
   132	    auto)
   133	      local probe_tbin
   134	      probe_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$seed" command -v cephadm)
   135	      probe_tbin="$(timeout_cmd)"
   136	      if [[ -n "$probe_tbin" ]]; then
   137	        probe_cmd=("$probe_tbin" "$timeout" "${probe_cmd[@]}")
   138	      fi
   139	      if [[ -n "$seed" && -n "$ssh_key" ]] && "${probe_cmd[@]}" >/dev/null 2>&1; then
   140	        collect_cluster_cephadm "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout"
   141	      else
   142	        # auto-fallback is a guess; tolerate a non-rook cluster gracefully
   143	        collect_cluster_rook --out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout" --allow-skip
   144	      fi
   145	      ;;
   146	    *)
   147	      return 1
   148	      ;;
   149	  esac
   150	}
   151	
   152	collect_remote_node() {
   153	  local workdir=$1 alias=$2 target=$3 ssh_key=$4 since=$5 timeout=$6 skip_logs=$7 node_timeout=$8
   154	  local node_dir="$workdir/nodes/$alias"
   155	  local node_tar="$workdir/.node-$alias.tar.gz"
   156	  local remote_cmd rc=0 tbin
   157	  local q_alias q_since q_timeout
   158	  local -a ssh_cmd
   159	
   160	  q_alias="$(shell_quote "$alias")" || return 1
   161	  q_since="$(shell_quote "$since")" || return 1
   162	  q_timeout="$(shell_quote "$timeout")" || return 1
   163	
   164	  # Remote side uses a gzip pipe (not `tar -z`) so minimal/BusyBox tar still works,
   165	  # and traps its own temp dir so an interrupted/timed-out run leaves nothing behind.
   166	  remote_cmd="set -u; tmp=\"\${TMPDIR:-/tmp}/ceph-incident-node.\$\$\"; rm -rf \"\$tmp\"; mkdir -p \"\$tmp\" || { printf 'SKIPPED: remote tmp not writable\n' >&2; exit 75; }; trap 'rm -rf \"\$tmp\"' EXIT INT TERM; gzip -dc | tar -xf - -C \"\$tmp\"; out=\"\$tmp/out\"; set +e; bash \"\$tmp/lib/collect-node.sh\" --out \"\$out\" --host-alias $q_alias --since $q_since --timeout $q_timeout"
   167	  if [[ "$skip_logs" == "1" ]]; then
   168	    remote_cmd+=" --skip-logs"
   169	  fi
   170	  remote_cmd+="; rc=\$?; set -e; if [ -d \"\$out\" ]; then tar -cf - -C \"\$out\" . | gzip -c; else mkdir -p \"\$out\"; printf 'SKIPPED: remote collect-node did not create output\n' >\"\$out/SKIPPED.txt\"; tar -cf - -C \"\$out\" . | gzip -c; fi; exit \"\$rc\""
   171	
   172	  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" "$remote_cmd")
   173	  tbin="$(timeout_cmd)"
   174	  if [[ -n "$tbin" ]]; then
   175	    # Outer wrapper bounds the WHOLE node collection — must be the generous
   176	    # node timeout, never the small per-command timeout (which would kill a
   177	    # slow/large node mid-collection).
   178	    ssh_cmd=("$tbin" "$node_timeout" "${ssh_cmd[@]}")
   179	  fi
   180	
   181	  set +e
   182	  COPYFILE_DISABLE=1 tar -cf - -C "$COLLECT_ROOT" lib/common.sh lib/collect-node.sh | gzip -c |
   183	    "${ssh_cmd[@]}" >"$node_tar"
   184	  rc=$?
   185	  set -e
   186	
   187	  ensure_dir "$node_dir"
   188	  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
   189	    printf 'SKIPPED: node collection timed out after %ss (exit %s) from %s\n' "$node_timeout" "$rc" "$target" >"$node_dir/SKIPPED.txt"
   190	    rm -f "$node_tar"
   191	    return 2
   192	  fi
   193	
   194	  if [[ -s "$node_tar" ]] && tar -xzf "$node_tar" -C "$node_dir" >/dev/null 2>/dev/null; then
   195	    # A node that streamed a valid archive but is missing its own manifest.jsonl
   196	    # was truncated (partial/interrupted transfer) — do not count it as ok.
   197	    if [[ ! -f "$node_dir/manifest.jsonl" ]]; then
   198	      printf 'SKIPPED: node archive from %s is incomplete (no manifest.jsonl); treated as failure\n' "$target" >"$node_dir/SKIPPED.txt"
   199	      rc=2
   200	    fi
   201	  else
   202	    rm -rf "$node_dir"
   203	    ensure_dir "$node_dir"
   204	    printf 'SKIPPED: no usable node archive returned from %s (ssh exit %s)\n' "$target" "$rc" >"$node_dir/SKIPPED.txt"
   205	    [[ $rc -ne 0 ]] || rc=2
   206	  fi
   207	  rm -f "$node_tar"
   208	
   209	  return "$rc"
   210	}
   211	
   212	redact_bundle_text() {
   213	  local workdir=$1
   214	  local redaction_log="$workdir/redactions.log"
   215	  local path
   216	
   217	  while IFS= read -r path; do
   218	    case "$path" in
   219	      *.gz) redact_gz_file "$path" "$redaction_log" ;;
   220	      *) redact_file "$path" "$redaction_log" ;;
   221	    esac
   222	  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' -o -name '*.gz' \) -print 2>/dev/null || true)
   223	}
   224	
   225	# Single cleanup point. Uses globals (not main's locals) so it works as an
   226	# EXIT trap, which fires after main has returned and its locals are gone.
   227	CLEANUP_WORKDIR=
   228	CLEANUP_KEEP=0
   229	cleanup_workdir() {
   230	  local rc=$?
   231	  if [[ -n "${CLEANUP_WORKDIR:-}" && -d "$CLEANUP_WORKDIR" ]]; then
   232	    if [[ "${CLEANUP_KEEP:-0}" -eq 1 ]]; then
   233	      printf 'kept workdir: %s\n' "$CLEANUP_WORKDIR" >&2
   234	    else
   235	      rm -rf -- "$CLEANUP_WORKDIR"
   236	    fi
   237	  fi
   238	  return "$rc"
   239	}
   240	

exec
/bin/zsh -lc "git show 38c16e2:experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh | nl -ba | sed -n '1,220p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-dv2BqYYx' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-0RVaFZja' (errno=Operation not permitted)
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	# Collect read-only Rook/Ceph Kubernetes evidence.
     5	
     6	ROOK_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
     7	# shellcheck disable=SC1091
     8	source "$ROOK_COLLECTOR_DIR/common.sh"
     9	
    10	usage() {
    11	  cat <<'EOF'
    12	Usage: collect-cluster-rook.sh --out DIR --manifest PATH [--namespace rook-ceph] [--since DURATION] [--timeout SECONDS]
    13	EOF
    14	}
    15	
    16	rook_skip() {
    17	  local outdir=$1 reason=$2
    18	  local artifact="$outdir/cluster/rook/SKIPPED.txt"
    19	  ensure_dir "$(dirname -- "$artifact")"
    20	  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
    21	}
    22	
    23	rook_write_skip_artifact() {
    24	  local artifact=$1 reason=$2
    25	  ensure_dir "$(dirname -- "$artifact")"
    26	  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
    27	}
    28	
    29	rook_run_capture() {
    30	  local outdir=$1 manifest=$2 timeout=$3 artifact_rel=$4
    31	  shift 4
    32	
    33	  local artifact="$outdir/$artifact_rel"
    34	  if ! COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
    35	    run_capture "$manifest" "rook" "collect-cluster-rook" "$artifact" -- "$@"; then
    36	    return 2
    37	  fi
    38	  return 0
    39	}
    40	
    41	rook_get_first_pod() {
    42	  local namespace=$1 label=$2
    43	  kubectl get pods -n "$namespace" -l "$label" -o 'jsonpath={.items[0].metadata.name}' 2>/dev/null || true
    44	}
    45	
    46	collect_cluster_rook() {
    47	  local outdir='' manifest='' namespace=rook-ceph since=24h timeout=20 allow_skip=0
    48	
    49	  while [[ $# -gt 0 ]]; do
    50	    case "$1" in
    51	      --out)
    52	        outdir=${2-}
    53	        shift 2
    54	        ;;
    55	      --manifest)
    56	        manifest=${2-}
    57	        shift 2
    58	        ;;
    59	      --namespace)
    60	        namespace=${2-}
    61	        shift 2
    62	        ;;
    63	      --since)
    64	        since=${2-}
    65	        shift 2
    66	        ;;
    67	      --timeout)
    68	        timeout=${2-}
    69	        shift 2
    70	        ;;
    71	      --allow-skip)
    72	        allow_skip=1
    73	        shift
    74	        ;;
    75	      --help|-h)
    76	        usage
    77	        return 0
    78	        ;;
    79	      *)
    80	        usage >&2
    81	        return 1
    82	        ;;
    83	    esac
    84	  done
    85	
    86	  [[ -n "$outdir" && -n "$manifest" ]] || {
    87	    usage >&2
    88	    return 1
    89	  }
    90	
    91	  ensure_dir "$outdir/cluster/rook"
    92	
    93	  # Missing kubectl / namespace means we collected NO cluster evidence. In
    94	  # explicit rook mode that is a partial failure (exit 2) so the bundle does not
    95	  # falsely look complete; auto-mode fallback passes --allow-skip to tolerate it.
    96	  if ! command -v kubectl >/dev/null 2>&1; then
    97	    rook_skip "$outdir" "kubectl command not found"
    98	    [[ "$allow_skip" == "1" ]] && return 0 || return 2
    99	  fi
   100	
   101	  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
   102	    rook_skip "$outdir" "namespace not found: $namespace"
   103	    [[ "$allow_skip" == "1" ]] && return 0 || return 2
   104	  fi
   105	
   106	  local failed=0
   107	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/pods-wide.txt" \
   108	    kubectl get pods -n "$namespace" -o wide; then
   109	    failed=1
   110	  fi
   111	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/events.txt" \
   112	    kubectl get events -n "$namespace" --sort-by=.lastTimestamp; then
   113	    failed=1
   114	  fi
   115	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/rook-resources.yaml" \
   116	    kubectl get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n "$namespace" -o yaml; then
   117	    failed=1
   118	  fi
   119	
   120	  local operator_pod toolbox_pod
   121	  operator_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-operator")"
   122	  if [[ -n "$operator_pod" ]]; then
   123	    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
   124	      kubectl logs -n "$namespace" "$operator_pod" --since="$since"; then
   125	      failed=1
   126	    fi
   127	  else
   128	    rook_write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found"
   129	  fi
   130	
   131	  toolbox_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-tools")"
   132	  if [[ -n "$toolbox_pod" ]]; then
   133	    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
   134	      kubectl exec -n "$namespace" "$toolbox_pod" -- ceph status; then
   135	      failed=1
   136	    fi
   137	  else
   138	    rook_write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
   139	  fi
   140	
   141	  [[ $failed -eq 0 ]] || return 2
   142	  return 0
   143	}
   144	
   145	if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
   146	  collect_cluster_rook "$@"
   147	fi

codex
The docs now describe `--mode rook` as “first node with kubectl,” so the main entrypoint’s remote-only rook behavior appears intentional. I’m narrowing now to actual failures: malformed/empty inventory, source probing, and whether the test suite itself masks any bad state.
exec
/bin/zsh -lc "bash -uc 'HOSTS=(); for entry in \""'${HOSTS[@]}"; do echo x; done; echo ok'"' ; bash -uc 'unset HOSTS; declare -p HOSTS >/dev/null 2>&1 || echo missing; for entry in \""'${HOSTS[@]}"; do echo x; done; echo after'"'" in /Users/ikaros/Documents/code/learning-k8s
 exited 127 in 0ms:
bash: HOSTS[@]: unbound variable
bash: HOSTS[@]: unbound variable
missing

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/verify-bundle.sh | sed -n '1,180p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	# Ceph incident bundle verification entrypoint.
     5	
     6	usage() {
     7	  cat >&2 <<'EOF'
     8	Usage: verify-bundle.sh <bundle-dir|bundle.tar.gz>
     9	
    10	Checks gzip integrity, required top-level files, cluster/node artifacts,
    11	and obvious secret paths such as keyring, .ssh, id_ed25519, private_key.
    12	EOF
    13	}
    14	
    15	verify_fail() {
    16	  printf 'VERIFY FAIL: %s\n' "$*" >&2
    17	  return 1
    18	}
    19	
    20	verify_members() {
    21	  local root=$1 path
    22	
    23	  # -print0 so newlines in filenames cannot smuggle a forbidden component
    24	  # past the glob (this is a security boundary).
    25	  while IFS= read -r -d '' path; do
    26	    case "$path" in
    27	      *keyring*|*.ssh*|*id_ed25519*|*private_key*|*.pem|*.key|*.crt|*.pfx|*.p12)
    28	        verify_fail "forbidden path: ${path#./}"
    29	        return 1
    30	        ;;
    31	    esac
    32	  done < <(cd "$root" && find . -mindepth 1 -print0)
    33	}
    34	
    35	verify_no_secret_content() {
    36	  # Defense-in-depth: even if redaction missed something, refuse to bless a
    37	  # bundle whose files still contain obvious unredacted key material.
    38	  local root=$1 hit
    39	  hit="$(grep -rlIE -e '-----BEGIN[ A-Za-z]*PRIVATE KEY-----' -e '^[[:space:]]*key[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{20,}={0,2}' "$root" 2>/dev/null | head -n1 || true)"
    40	  if [[ -n "$hit" ]]; then
    41	    verify_fail "unredacted PRIVATE KEY / key material in: ${hit#"$root"/}"
    42	    return 1
    43	  fi
    44	}
    45	
    46	verify_required_files() {
    47	  local root=$1
    48	  local required
    49	
    50	  for required in manifest.jsonl summary.txt README-FIRST.txt; do
    51	    [[ -f "$root/$required" ]] || {
    52	      verify_fail "missing required file: $required"
    53	      return 1
    54	    }
    55	  done
    56	}
    57	
    58	verify_required_artifacts() {
    59	  local root=$1 cluster_artifact nodes_artifact
    60	
    61	  cluster_artifact="$(find "$root/cluster" -type f -print -quit 2>/dev/null || true)"
    62	  [[ -n "$cluster_artifact" ]] || {
    63	    verify_fail "missing cluster/ artifact"
    64	    return 1
    65	  }
    66	
    67	  nodes_artifact="$(find "$root/nodes" -type f -print -quit 2>/dev/null || true)"
    68	  [[ -n "$nodes_artifact" ]] || {
    69	    verify_fail "missing nodes/ artifact"
    70	    return 1
    71	  }
    72	}
    73	
    74	verify_bundle_tree() {
    75	  local root=$1
    76	
    77	  verify_members "$root" || return 1
    78	  verify_no_secret_content "$root" || return 1
    79	  verify_required_files "$root" || return 1
    80	  verify_required_artifacts "$root" || return 1
    81	}
    82	
    83	verify_bundle_path() {
    84	  local bundle=$1 workdir extracted_root
    85	
    86	  if [[ -d "$bundle" ]]; then
    87	    verify_bundle_tree "$bundle" || return 1
    88	    printf 'VERIFY PASS: %s\n' "$bundle"
    89	    return 0
    90	  fi
    91	
    92	  [[ -f "$bundle" && "$bundle" == *.tar.gz ]] || { verify_fail "expected a directory or .tar.gz bundle: $bundle"; return 1; }
    93	
    94	  workdir="$(mktemp -d)"
    95	  if ! tar -tzf "$bundle" >/dev/null 2>/dev/null; then
    96	    verify_fail "invalid archive: $bundle"
    97	    rm -rf "$workdir"
    98	    return 1
    99	  fi
   100	  if ! tar -xzf "$bundle" -C "$workdir" >/dev/null 2>/dev/null; then
   101	    verify_fail "invalid archive: $bundle"
   102	    rm -rf "$workdir"
   103	    return 1
   104	  fi
   105	
   106	  extracted_root="$workdir"
   107	  if ! verify_bundle_tree "$extracted_root"; then
   108	    rm -rf "$workdir"
   109	    return 1
   110	  fi
   111	  rm -rf "$workdir"
   112	  printf 'VERIFY PASS: %s\n' "$bundle"
   113	}
   114	
   115	main() {
   116	  if [[ $# -ne 1 ]]; then
   117	    usage
   118	    return 1
   119	  fi
   120	
   121	  verify_bundle_path "$1"
   122	}
   123	
   124	main "$@"

codex
HIGH | experiments/ceph-incident-bundle/run/collect.sh:184 | auto mode marks `rook_done=1` even when `collect_cluster_rook --allow-skip` only wrote `cluster/rook/SKIPPED.txt` for missing namespace/wrong context and returned 0; with no cephadm layer this returns exit 0 even though neither layer was collected | Set `rook_done` only after real rook artifacts are collected, or make source-level rook skip distinguishable and convert to exit 2 when no other layer completed.

MEDIUM | experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:49 | `rook_get_first_pod` lost the old `|| true`; when run standalone under `set -euo pipefail`, a pod lookup error aborts the collector instead of writing the operator/toolbox SKIPPED artifact or returning partial cleanly | Add `|| true` to the lookup pipeline or handle the lookup under `set +e`.

Clean | collect_clusters first cephadm / first kubectl probing, `--seed` pinning, and early break logic otherwise look correct.

Clean | Bash 3.2 empty `HOST_ALIASES` / `HOST_TARGETS` guarded loops look safe; all-malformed HOSTS does not hit an unbound expansion.

Clean | remote kubectl argv for the fixed arguments reviewed (`-o name`, `--since=`, label selectors, `exec -- ceph status`) looks intact; local `collect_cluster_rook` no-ssh path remains intact.

Clean | trap cleanup, verify-keeps-evidence, redaction, timeout fallback, manifest-required node check, and ceph/rook dedup did not show a real regression in this diff.
tokens used
115,438
HIGH | experiments/ceph-incident-bundle/run/collect.sh:184 | auto mode marks `rook_done=1` even when `collect_cluster_rook --allow-skip` only wrote `cluster/rook/SKIPPED.txt` for missing namespace/wrong context and returned 0; with no cephadm layer this returns exit 0 even though neither layer was collected | Set `rook_done` only after real rook artifacts are collected, or make source-level rook skip distinguishable and convert to exit 2 when no other layer completed.

MEDIUM | experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:49 | `rook_get_first_pod` lost the old `|| true`; when run standalone under `set -euo pipefail`, a pod lookup error aborts the collector instead of writing the operator/toolbox SKIPPED artifact or returning partial cleanly | Add `|| true` to the lookup pipeline or handle the lookup under `set +e`.

Clean | collect_clusters first cephadm / first kubectl probing, `--seed` pinning, and early break logic otherwise look correct.

Clean | Bash 3.2 empty `HOST_ALIASES` / `HOST_TARGETS` guarded loops look safe; all-malformed HOSTS does not hit an unbound expansion.

Clean | remote kubectl argv for the fixed arguments reviewed (`-o name`, `--since=`, label selectors, `exec -- ceph status`) looks intact; local `collect_cluster_rook` no-ssh path remains intact.

Clean | trap cleanup, verify-keeps-evidence, redaction, timeout fallback, manifest-required node check, and ceph/rook dedup did not show a real regression in this diff.
