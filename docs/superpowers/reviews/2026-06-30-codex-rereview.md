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
session id: 019f1483-f094-7aa3-b16d-81ae3e9cd7a3
--------
user
Re-review the HARDENED ceph-incident-bundle bash tool at experiments/ceph-incident-bundle/ (run/collect.sh, lib/*.sh, tests/*.sh). It was just hardened: per-node vs per-command timeout split (--node-timeout), trap cleanup of workdir, verify-under-set+e that keeps evidence on failure, require node manifest.jsonl post-extract, stateful PEM + ceph key-material + *.gz redaction, verifier filename+content secret checks, sudo -n + ConnectTimeout on cluster SSH, oversized-log tail capture, rook --allow-skip semantics.

Your job: find REGRESSIONS or NEW bugs introduced by these changes ONLY. Specifically check: (1) does the EXIT trap ever delete a bundle or wanted data on the SUCCESS path? (2) can verify_no_secret_content false-positive on a normal redacted bundle and block a good run? (3) is the gzip|tar remote pipe correct (does the receiving side still extract)? (4) any bash 3.2 incompatibility (the workstation runs bash 3.2)? (5) does the redaction over-redact so much it destroys evidence value? (6) exit-code contract still 0/2/1 consistent?

Output: only real regressions as SEVERITY | file:line | problem | fix. If you find none in a category, say so briefly. Do not modify files.
codex
I’ll review this as a regression pass only and keep it read-only. I’m using the repo instructions plus the code-review stance, focusing on the hardened deltas and the six checks you listed.
exec
/bin/zsh -lc "sed -n '1,220p' /Users/ikaros/.codex/superpowers/skills/using-superpowers/SKILL.md" in /Users/ikaros/Documents/code/learning-k8s
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
/bin/zsh -lc 'rg -n "ceph-incident-bundle|incident-bundle|ceph" /Users/ikaros/.codex/memories/MEMORY.md' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 103ms:
151:- For monitoring, `node_exporter` timex metrics are the right kernel-state layer, `systemd_exporter` is only the daemon-alive layer, and `ceph_health_detail{name="MON_CLOCK_SKEW"}` remains the cross-mon authority for the 50 ms cluster-wide decision [Task 1][Task 2]
173:- rollout_summaries/2026-06-01T15-35-19-DTz0-ceph_source_first_audit_rewrite_commit_push.md (cwd=/Users/ikaros/Documents/code/learning-k8s, rollout_path=/Users/ikaros/.codex/sessions/2026/06/01/rollout-2026-06-01T23-35-19-019e83d3-3deb-7ec3-b6ed-f7ae7bdebede.jsonl, updated_at=2026-06-02T00:05:00+00:00, thread_id=019e83d3-3deb-7ec3-b6ed-f7ae7bdebede, success; 15 MDX files audited and rewritten on a dedicated branch)
177:- ceph, v19.2.3, source-first, external experience, edge cases, pg_num, pgp_num, BlueFS spillover, MON_CLOCK_SKEW, ok-to-stop, safe-to-destroy, make validate, codex/ceph-content-review
185:- rollout_summaries/2026-06-02T01-17-20-CaGR-ceph_prometheus_alerts_scoped_maintenance_rewrite.md (cwd=/Users/ikaros/Documents/code/learning-k8s, rollout_path=/Users/ikaros/.codex/sessions/2026/06/02/rollout-2026-06-02T09-17-20-019e85e8-157c-7fb2-beee-e1f4ff135b69.jsonl, updated_at=2026-06-02T15:32:54+00:00, thread_id=019e85e8-157c-7fb2-beee-e1f4ff135b69, success; page rewritten around user-supplied base rules and simpler OSD PromQL)
189:- prometheus-alert-design, CephHealthError, ceph_health_detail, ceph_mon_quorum_status, ceph_mon_metadata, ceph_osd_metadata, CephClientRisk, CephMonQuorumLost, ceph-stability-first, ceph-scoped-availability, recording rules, unless on (hostname)
197:- rollout_summaries/2026-06-04T08-36-11-MEyB-ceph_mclock_client_res_wgt_lim_source_explanation.md (cwd=/Users/ikaros/Documents/code/learning-k8s, rollout_path=/Users/ikaros/.codex/sessions/2026/06/04/rollout-2026-06-04T16-36-11-019e91c6-95dd-7430-8c67-8b76f74c4101.jsonl, updated_at=2026-06-04T08:39:17+00:00, thread_id=019e91c6-95dd-7430-8c67-8b76f74c4101, success; classic-OID mClock client QoS semantics explained from source)
205:- when the user asked to "Review ceph 分類內的所有文章，去網路上搜尋大家的經驗，加上你自己發想的各種情境…重視高品質內容詳細" -> default to source-first review plus external experience search plus invented edge-case thinking, not just local doc editing [Task 1]
215:- The durable Ceph source baseline here was `v19.2.3` from `/Users/ikaros/Documents/code/learning-k8s/ceph` at commit `c92aebb`; similar version-sensitive answers should confirm that baseline before explaining behavior [Task 1][Task 2][Task 3]
218:- `ceph_health_detail` only exposes `name` and `severity`, so host-scoped silence needs metadata joins; `ceph_mon_quorum_status` is per-mon, and `ceph_mon_metadata` / `ceph_osd_metadata` carry the labels needed for scoped MON/OSD alerts [Task 1][Task 2]

codex
Using `superpowers:using-superpowers` for process discipline; no editing skill applies because this is a read-only regression review. I’ll inspect the scripts and tests directly, then report only concrete regressions.
exec
/bin/zsh -lc 'git status --short' in /Users/ikaros/Documents/code/learning-k8s
exec
/bin/zsh -lc 'git log --oneline --decorate --max-count=8 -- experiments/ceph-incident-bundle' in /Users/ikaros/Documents/code/learning-k8s
exec
/bin/zsh -lc 'rg --files experiments/ceph-incident-bundle' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/run/collect.sh
experiments/ceph-incident-bundle/tests/test-rook-collector.sh
experiments/ceph-incident-bundle/tests/test-common.sh
experiments/ceph-incident-bundle/tests/run-tests.sh
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh
experiments/ceph-incident-bundle/tests/test-collect.sh
experiments/ceph-incident-bundle/tests/test-node-collector.sh
experiments/ceph-incident-bundle/README.md
experiments/ceph-incident-bundle/inventory/ceph-lab.example.env
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
experiments/ceph-incident-bundle/lib/common.sh
experiments/ceph-incident-bundle/lib/collect-node.sh
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh
experiments/ceph-incident-bundle/lib/verify-bundle.sh
experiments/ceph-incident-bundle/results/.gitkeep
experiments/ceph-incident-bundle/tests/fixtures/README.md
experiments/ceph-incident-bundle/tests/fixtures/bin/ssh

 succeeded in 187ms:
0aa5bc6 (HEAD -> claude/ceph-incident-bundle-hardening) ceph-incident-bundle: README - timeouts, large-log tail, verify/exit semantics, lab validation
16fbf3f ceph-incident-bundle: shellcheck clean (0 warnings)
3e7bd5d ceph-incident-bundle: harden cluster collectors (cephadm SSH/sudo, rook skip semantics)
ca64f25 ceph-incident-bundle: node collector - tail oversized logs, heavier journal/dmesg timeout
1dc4567 ceph-incident-bundle: harden orchestrator (timeouts, cleanup, verify-safety, partial failure)
02b35f4 ceph-incident-bundle: strengthen bundle verifier (key-file types, content grep, NUL-safe)
b5f759a ceph-incident-bundle: harden redaction (PEM blocks, ceph key material, *.gz, portable mode)
8374cf1 ceph: validate incident bundle on lab

 succeeded in 4315ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-1PFW9dm8' (errno=Operation not permitted)
 m linux
?? docs/superpowers/reviews/2026-06-30-codex-rereview.md

codex
I see the hardening series on the current branch, with unrelated existing dirtiness outside this tool. I’m comparing the current scripts against the pre-hardening baseline so I can distinguish new regressions from pre-existing behavior.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/run/collect.sh | sed -n '1,260p'" in /Users/ikaros/Documents/code/learning-k8s
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
   241	main() {
   242	  local inventory='' ssh_key='' seed_override='' out_dir="$COLLECT_ROOT/results"
   243	  local mode=auto since=24h timeout=20 node_timeout=600 skip_logs=0 keep_workdir=0
   244	  local seed='' ssh_user='' seed_host='' rook_namespace=rook-ceph
   245	  local timestamp workdir manifest bundle rc=0 cluster_rc=0 node_ok=0 node_failed=0
   246	
   247	  if [[ $# -eq 0 ]]; then
   248	    usage >&2
   249	    return 1
   250	  fi
   251	
   252	  while [[ $# -gt 0 ]]; do
   253	    case "$1" in
   254	      --inventory)
   255	        inventory=${2-}
   256	        shift 2
   257	        ;;
   258	      --ssh-key)
   259	        ssh_key=${2-}
   260	        shift 2

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/verify-bundle.sh | sed -n '1,360p'" in /Users/ikaros/Documents/code/learning-k8s
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/common.sh | sed -n '1,320p'" in /Users/ikaros/Documents/code/learning-k8s
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

codex
The first pass found the key control points: cleanup is global EXIT state, node collection streams a gzipped tar into remote `gzip -dc | tar -xf -`, and verification now has filename and content secret checks. I’m reading the collectors/tests next, including line references for any finding.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/run/collect.sh | sed -n '260,560p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
   260	        shift 2
   261	        ;;
   262	      --seed)
   263	        seed_override=${2-}
   264	        shift 2
   265	        ;;
   266	      --out)
   267	        out_dir=${2-}
   268	        shift 2
   269	        ;;
   270	      --mode)
   271	        mode=${2-}
   272	        shift 2
   273	        ;;
   274	      --since)
   275	        since=${2-}
   276	        shift 2
   277	        ;;
   278	      --timeout)
   279	        timeout=${2-}
   280	        shift 2
   281	        ;;
   282	      --node-timeout)
   283	        node_timeout=${2-}
   284	        shift 2
   285	        ;;
   286	      --skip-logs)
   287	        skip_logs=1
   288	        shift
   289	        ;;
   290	      --keep-workdir)
   291	        keep_workdir=1
   292	        shift
   293	        ;;
   294	      --help|-h)
   295	        usage
   296	        return 0
   297	        ;;
   298	      *)
   299	        usage >&2
   300	        return 1
   301	        ;;
   302	    esac
   303	  done
   304	
   305	  [[ "$mode" == "auto" || "$mode" == "cephadm" || "$mode" == "rook" ]] || die "unsupported mode: $mode"
   306	  [[ -n "$inventory" && -f "$inventory" ]] || die "missing inventory: ${inventory:-<unset>}"
   307	  [[ -n "$ssh_key" && -f "$ssh_key" ]] || die "missing ssh key: ${ssh_key:-<unset>}"
   308	
   309	  # shellcheck disable=SC1090
   310	  source "$inventory"
   311	
   312	  if ! declare -p HOSTS >/dev/null 2>&1; then
   313	    die "inventory must define HOSTS"
   314	  fi
   315	
   316	  ssh_user=${SSH_USER:-}
   317	  seed_host=${SEED_HOST:-}
   318	  rook_namespace=${ROOK_NAMESPACE:-rook-ceph}
   319	  if [[ -n "$seed_override" ]]; then
   320	    seed=$seed_override
   321	  elif [[ -n "$seed_host" ]]; then
   322	    seed="$(ssh_target_for_host "$seed_host" "$ssh_user")"
   323	  fi
   324	
   325	  if [[ -z "$(timeout_cmd)" ]]; then
   326	    log "WARNING: no 'timeout'/'gtimeout' found on this workstation; outer timeouts are disabled — relying on SSH ConnectTimeout/ServerAlive only (install coreutils for full bounding)"
   327	  fi
   328	
   329	  ensure_dir "$out_dir"
   330	  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
   331	  workdir="$out_dir/tmp.$timestamp.$$"
   332	  manifest="$workdir/manifest.jsonl"
   333	  ensure_dir "$workdir"
   334	  CLEANUP_WORKDIR="$workdir"
   335	  CLEANUP_KEEP=$keep_workdir
   336	  trap cleanup_workdir EXIT INT TERM
   337	  write_initial_metadata "$workdir" "$mode" "$seed" "$since" "$timeout"
   338	
   339	  set +e
   340	  run_cluster_collector "$mode" "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout" "$rook_namespace"
   341	  cluster_rc=$?
   342	  set -e
   343	  if [[ $cluster_rc -ne 0 ]]; then
   344	    append_error "$workdir" "cluster collector exited $cluster_rc"
   345	    rc=2
   346	  fi
   347	
   348	  local entry alias host target node_rc
   349	  for entry in "${HOSTS[@]}"; do
   350	    # Robust parse: a malformed entry must not abort an in-progress collection.
   351	    if [[ "$entry" != *=* ]]; then
   352	      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
   353	      node_failed=$((node_failed + 1))
   354	      rc=2
   355	      continue
   356	    fi
   357	    alias="${entry%%=*}"
   358	    host="${entry#*=}"
   359	    if [[ -z "$alias" || -z "$host" ]]; then
   360	      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
   361	      node_failed=$((node_failed + 1))
   362	      rc=2
   363	      continue
   364	    fi
   365	    target="$(ssh_target_for_host "$host" "$ssh_user")"
   366	
   367	    if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs" "$node_timeout"; then
   368	      node_ok=$((node_ok + 1))
   369	    else
   370	      node_rc=$?
   371	      node_failed=$((node_failed + 1))
   372	      append_error "$workdir" "node $alias ($target) collector exited $node_rc"
   373	      rc=2
   374	    fi
   375	  done
   376	
   377	  # Test-only hook: simulate a mid-run abort to exercise trap cleanup. Inert in production.
   378	  if [[ -n "${COLLECT_TEST_ABORT_AFTER_NODES:-}" ]]; then
   379	    die "test abort after nodes"
   380	  fi
   381	
   382	  redact_bundle_text "$workdir"
   383	  write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "$rc"
   384	
   385	  # Verify BEFORE packaging, but never let verification destroy collected
   386	  # evidence: capture its result instead of aborting under set -e. On failure,
   387	  # keep the workdir for inspection and do not produce a shareable bundle.
   388	  local verify_rc=0
   389	  set +e
   390	  "$COLLECT_ROOT/lib/verify-bundle.sh" "$workdir" >/dev/null 2>>"$workdir/errors.log"
   391	  verify_rc=$?
   392	  set -e
   393	  if [[ $verify_rc -ne 0 ]]; then
   394	    CLEANUP_KEEP=1
   395	    append_error "$workdir" "bundle verification failed (rc=$verify_rc); workdir kept, NOT packaged for sharing"
   396	    write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "1"
   397	    printf 'VERIFY FAILED: workdir kept at %s (not packaged) — review errors.log\n' "$workdir" >&2
   398	    return 1
   399	  fi
   400	
   401	  bundle="$out_dir/ceph-incident-$timestamp.tar.gz"
   402	  COPYFILE_DISABLE=1 tar -czf "$bundle" -C "$workdir" .
   403	  set +e
   404	  "$COLLECT_ROOT/lib/verify-bundle.sh" "$bundle" >/dev/null 2>>"$workdir/errors.log"
   405	  verify_rc=$?
   406	  set -e
   407	  if [[ $verify_rc -ne 0 ]]; then
   408	    CLEANUP_KEEP=1
   409	    rm -f -- "$bundle"
   410	    printf 'VERIFY FAILED on packaged bundle; removed it, workdir kept at %s\n' "$workdir" >&2
   411	    return 1
   412	  fi
   413	
   414	  printf 'bundle: %s\n' "$bundle"
   415	  return "$rc"
   416	}
   417	
   418	main "$@"

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/collect-node.sh | sed -n '1,360p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     1	#!/usr/bin/env bash
     2	set -euo pipefail
     3	
     4	# Collect read-only node evidence for a Ceph incident bundle.
     5	
     6	NODE_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
     7	# shellcheck disable=SC1091
     8	source "$NODE_COLLECTOR_DIR/common.sh"
     9	
    10	usage() {
    11	  cat <<'EOF'
    12	Usage: collect-node.sh --out DIR --host-alias ALIAS [--since DURATION] [--timeout SECONDS] [--skip-logs]
    13	EOF
    14	}
    15	
    16	write_skip_artifact() {
    17	  local artifact=$1 reason=$2
    18	  ensure_dir "$(dirname -- "$artifact")"
    19	  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
    20	}
    21	
    22	node_run_capture() {
    23	  local outdir=$1 manifest=$2 host_alias=$3 timeout=$4 artifact_rel=$5
    24	  shift 5
    25	
    26	  local artifact="$outdir/$artifact_rel"
    27	  if ! COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
    28	    run_capture "$manifest" "$host_alias" "collect-node" "$artifact" -- "$@"; then
    29	    return 2
    30	  fi
    31	  return 0
    32	}
    33	
    34	node_run_optional() {
    35	  local outdir=$1 manifest=$2 host_alias=$3 timeout=$4 artifact_rel=$5 command_name=$6
    36	  shift 6
    37	
    38	  if ! command -v "$command_name" >/dev/null 2>&1; then
    39	    write_skip_artifact "$outdir/$artifact_rel" "command not found: $command_name"
    40	    return 0
    41	  fi
    42	
    43	  node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" "$command_name" "$@" || return 0
    44	}
    45	
    46	node_run_privileged() {
    47	  local outdir=$1 manifest=$2 host_alias=$3 timeout=$4 artifact_rel=$5 command_name=$6
    48	  shift 6
    49	
    50	  if [[ $EUID -eq 0 ]]; then
    51	    node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" "$command_name" "$@"
    52	    return $?
    53	  fi
    54	
    55	  if ! command -v sudo >/dev/null 2>&1; then
    56	    write_skip_artifact "$outdir/$artifact_rel" "sudo command not found for privileged read: $command_name"
    57	    return 0
    58	  fi
    59	
    60	  node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" sudo -n "$command_name" "$@"
    61	}
    62	
    63	journal_since_arg() {
    64	  local since=$1
    65	  if [[ "$since" =~ ^[0-9]+[smhdw]$ ]]; then
    66	    printf -- '-%s' "$since"
    67	  else
    68	    printf '%s' "$since"
    69	  fi
    70	}
    71	
    72	node_find0() {
    73	  local root=$1
    74	  shift
    75	
    76	  if [[ $EUID -eq 0 ]]; then
    77	    find "$root" "$@"
    78	    return $?
    79	  fi
    80	
    81	  if command -v sudo >/dev/null 2>&1; then
    82	    sudo -n find "$root" "$@"
    83	    return $?
    84	  fi
    85	
    86	  find "$root" "$@" 2>/dev/null
    87	}
    88	
    89	node_file_size() {
    90	  local source=$1 size
    91	
    92	  if [[ $EUID -eq 0 || -r "$source" ]]; then
    93	    size="$(wc -c <"$source" 2>/dev/null | tr -d '[:space:]')" || return 1
    94	  elif command -v sudo >/dev/null 2>&1; then
    95	    size="$(sudo -n wc -c "$source" 2>/dev/null | awk '{print $1}')" || return 1
    96	  else
    97	    return 1
    98	  fi
    99	
   100	  [[ "$size" =~ ^[0-9]+$ ]] || return 1
   101	  printf '%s' "$size"
   102	}
   103	
   104	node_copy_file() {
   105	  local source=$1 dest=$2
   106	  ensure_dir "$(dirname -- "$dest")"
   107	
   108	  if [[ $EUID -eq 0 || -r "$source" ]]; then
   109	    cp -p -- "$source" "$dest"
   110	    return $?
   111	  fi
   112	
   113	  if command -v sudo >/dev/null 2>&1; then
   114	    # Intentional: read the source as root, but write $dest as the calling user
   115	    # (who owns the bundle). `sudo tee` would create $dest as root — not wanted.
   116	    # shellcheck disable=SC2024
   117	    sudo -n cat -- "$source" >"$dest"
   118	    return $?
   119	  fi
   120	
   121	  return 1
   122	}
   123	
   124	node_tail_file() {
   125	  local source=$1 nbytes=$2 dest=$3
   126	  ensure_dir "$(dirname -- "$dest")"
   127	
   128	  if [[ $EUID -eq 0 || -r "$source" ]]; then
   129	    tail -c "$nbytes" "$source" >"$dest"
   130	    return $?
   131	  fi
   132	
   133	  if command -v sudo >/dev/null 2>&1; then
   134	    # Intentional: read as root, write $dest as the calling user (see node_copy_file).
   135	    # shellcheck disable=SC2024
   136	    sudo -n tail -c "$nbytes" "$source" >"$dest"
   137	    return $?
   138	  fi
   139	
   140	  return 1
   141	}
   142	
   143	copy_readable_etc_files() {
   144	  local outdir=$1
   145	  local source dest_name
   146	
   147	  for source in /etc/os-release /etc/hosts /etc/resolv.conf; do
   148	    [[ -r "$source" ]] || continue
   149	    dest_name="${source#/etc/}"
   150	    copy_if_exists "$source" "$outdir/system/$dest_name"
   151	  done
   152	}
   153	
   154	collect_ceph_log_listing() {
   155	  local outdir=$1 manifest=$2 host_alias=$3 timeout=$4
   156	  local log_dir=${CEPH_INCIDENT_VAR_LOG_CEPH_DIR:-/var/log/ceph}
   157	  local listing="$outdir/logs/ceph-log-listing.txt"
   158	
   159	  if [[ -d "$log_dir" ]]; then
   160	    # SC2016: the sh -c body is meant to expand on the remote sh, not here.
   161	    # shellcheck disable=SC2016
   162	    if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "logs/ceph-log-listing.txt" \
   163	      find "$log_dir" -maxdepth 2 -type f -exec sh -c '
   164	        for path do
   165	          size=$(wc -c <"$path" 2>/dev/null || printf unknown)
   166	          printf "%s %s bytes\n" "$path" "$size"
   167	        done
   168	      ' sh {} +; then
   169	      return 2
   170	    fi
   171	  else
   172	    ensure_dir "$(dirname -- "$listing")"
   173	    printf 'SKIPPED: %s is not a readable directory on this node\n' "$log_dir" >"$listing"
   174	  fi
   175	}
   176	
   177	copy_ceph_logs() {
   178	  local outdir=$1
   179	  local log_dir=${CEPH_INCIDENT_VAR_LOG_CEPH_DIR:-/var/log/ceph}
   180	  local cap_bytes=${CEPH_INCIDENT_LOG_FILE_CAP_BYTES:-1048576}
   181	  local copied_dir="$outdir/logs/ceph"
   182	  local source rel dest size
   183	  local failed=0
   184	
   185	  [[ -d "$log_dir" ]] || return 0
   186	  ensure_dir "$copied_dir"
   187	
   188	  while IFS= read -r -d '' source; do
   189	    if ! size="$(node_file_size "$source")"; then
   190	      failed=1
   191	      continue
   192	    fi
   193	    rel="${source#"$log_dir"/}"
   194	    dest="$copied_dir/$rel"
   195	    if (( size <= cap_bytes )); then
   196	      if ! node_copy_file "$source" "$dest"; then
   197	        failed=1
   198	      fi
   199	    elif [[ "$source" == *.gz ]]; then
   200	      # A byte-tail of a gzip stream is not decompressible (and would evade
   201	      # redaction); record it instead of shipping garbage.
   202	      ensure_dir "$(dirname -- "$dest")"
   203	      printf 'original_bytes=%s\nnote=oversized compressed log skipped (gzip tail is not usable)\n' \
   204	        "$size" >"$dest.TRUNCATED"
   205	    else
   206	      # Oversized: keep the most recent cap_bytes (tail) instead of dropping the
   207	      # file silently — the active large log is often exactly what's wanted —
   208	      # and record the truncation so the omission is visible.
   209	      if node_tail_file "$source" "$cap_bytes" "$dest"; then
   210	        printf 'original_bytes=%s\ntail_bytes=%s\nnote=captured trailing bytes only (file exceeded cap)\n' \
   211	          "$size" "$cap_bytes" >"$dest.TRUNCATED"
   212	      else
   213	        failed=1
   214	      fi
   215	    fi
   216	  done < <(node_find0 "$log_dir" -maxdepth 2 -type f \( -name '*.log' -o -name '*.log.*' -o -name '*.txt' -o -name '*.gz' \) -print0 2>/dev/null || true)
   217	
   218	  [[ $failed -eq 0 ]] || return 2
   219	}
   220	
   221	collect_var_lib_ceph() {
   222	  local outdir=$1 manifest=$2 host_alias=$3 timeout=$4
   223	  local ceph_dir=${CEPH_INCIDENT_VAR_LIB_CEPH_DIR:-/var/lib/ceph}
   224	  local config_dest="$outdir/cephadm/var-lib-ceph-configs"
   225	  local source rel dest
   226	  local failed=0
   227	
   228	  if [[ -d "$ceph_dir" ]]; then
   229	    # SC2016: the sh -c body is meant to expand on the remote sh, not here.
   230	    # shellcheck disable=SC2016
   231	    if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "cephadm/var-lib-ceph-listing.txt" \
   232	      find "$ceph_dir" -maxdepth 3 \
   233	        \( -iname '*keyring*' -o -iname '*private_key*' -o -path '*/.ssh/*' \) -prune \
   234	        -o -exec sh -c '
   235	          for path do
   236	            if [ -d "$path" ]; then
   237	              type=d
   238	            elif [ -f "$path" ]; then
   239	              type=f
   240	            else
   241	              type=o
   242	            fi
   243	            printf "%s %s\n" "$type" "$path"
   244	          done
   245	        ' sh {} +; then
   246	      return 2
   247	    fi
   248	  else
   249	    write_skip_artifact "$outdir/cephadm/var-lib-ceph-listing.txt" "$ceph_dir is not a readable directory on this node"
   250	    return 0
   251	  fi
   252	
   253	  ensure_dir "$config_dest"
   254	  while IFS= read -r -d '' source; do
   255	    rel="${source#"$ceph_dir"/}"
   256	    dest="$config_dest/$rel"
   257	    if ! node_copy_file "$source" "$dest"; then
   258	      failed=1
   259	    fi
   260	  done < <(node_find0 "$ceph_dir" -maxdepth 4 \
   261	    \( -iname '*keyring*' -o -iname '*private_key*' -o -path '*/.ssh/*' \) -prune \
   262	    -o -type f \( -name 'ceph.conf' -o -name '*.conf' -o -name 'config' -o -name '*.config' \) -print0 2>/dev/null || true)
   263	
   264	  [[ $failed -eq 0 ]] || return 2
   265	}
   266	
   267	collect_node_main() {
   268	  local outdir='' host_alias='' since="24h" timeout=20 skip_logs=0
   269	
   270	  while [[ $# -gt 0 ]]; do
   271	    case "$1" in
   272	      --out)
   273	        outdir=${2-}
   274	        shift 2
   275	        ;;
   276	      --host-alias)
   277	        host_alias=${2-}
   278	        shift 2
   279	        ;;
   280	      --since)
   281	        since=${2-}
   282	        shift 2
   283	        ;;
   284	      --timeout)
   285	        timeout=${2-}
   286	        shift 2
   287	        ;;
   288	      --skip-logs)
   289	        skip_logs=1
   290	        shift
   291	        ;;
   292	      --help|-h)
   293	        usage
   294	        return 0
   295	        ;;
   296	      *)
   297	        usage >&2
   298	        return 1
   299	        ;;
   300	    esac
   301	  done
   302	
   303	  [[ -n "$outdir" && -n "$host_alias" ]] || {
   304	    usage >&2
   305	    return 1
   306	  }
   307	
   308	  ensure_dir "$outdir"
   309	  local manifest="$outdir/manifest.jsonl"
   310	  local failed=0
   311	  local journal_since
   312	  journal_since="$(journal_since_arg "$since")"
   313	
   314	  # dmesg and the ceph journal can be large under load; give them a heavier
   315	  # timeout than the per-command one so they are not silently truncated.
   316	  local heavy_timeout=$timeout
   317	  if [[ "$heavy_timeout" =~ ^[0-9]+$ ]] && (( heavy_timeout < 120 )); then
   318	    heavy_timeout=120
   319	  fi
   320	
   321	  local -a basic_specs=(
   322	    "system/hostname.txt::hostname"
   323	    "system/uname.txt::uname -a"
   324	    "system/uptime.txt::uptime"
   325	    "resources/free.txt::free -h"
   326	    "storage/df.txt::df -hT"
   327	    "network/ip-addr.txt::ip addr show"
   328	    "systemd/failed-units.txt::systemctl --failed --no-pager --plain"
   329	  )
   330	
   331	  local spec artifact command
   332	  local -a command_words
   333	  for spec in "${basic_specs[@]}"; do
   334	    artifact=${spec%%::*}
   335	    command=${spec#*::}
   336	    # shellcheck disable=SC2206
   337	    command_words=($command)
   338	    if ! node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact" "${command_words[@]}"; then
   339	      failed=1
   340	    fi
   341	  done
   342	
   343	  if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "storage/lsblk.txt" lsblk -a -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL; then
   344	    failed=1
   345	  fi
   346	  if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$heavy_timeout" "kernel/dmesg.txt" dmesg -T; then
   347	    failed=1
   348	  fi
   349	  if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$heavy_timeout" "systemd/journal-ceph.txt" journalctl --since "$journal_since" -u 'ceph*' --no-pager; then
   350	    failed=1
   351	  fi
   352	
   353	  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "resources/iostat.txt" iostat -xz 1 3; then
   354	    failed=1
   355	  fi
   356	  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "time/chronyc-tracking.txt" chronyc tracking; then
   357	    failed=1
   358	  fi
   359	  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "time/chronyc-sources.txt" chronyc sources -v; then
   360	    failed=1

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh | sed -n '1,360p'" in /Users/ikaros/Documents/code/learning-k8s
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
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh | sed -n '1,360p'" in /Users/ikaros/Documents/code/learning-k8s
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
So far I have one likely regression candidate around `grep` option parsing in `verify_no_secret_content`, and I’m checking whether it is actually exercised by tests or masked. I’m also checking bash 3.2 features, trap behavior, and exit-code tests before calling it.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-verify-bundle.sh | sed -n '1,360p'" in /Users/ikaros/Documents/code/learning-k8s
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
    20	tmpdir="$(mktemp -d)"
    21	trap 'rm -rf "$tmpdir"' EXIT
    22	
    23	make_valid_bundle_dir() {
    24	  local dir=$1
    25	  mkdir -p \
    26	    "$dir/cluster/ceph" \
    27	    "$dir/nodes/monitor01/system"
    28	
    29	  cat >"$dir/manifest.jsonl" <<'EOF'
    30	{"bundle":"ceph-incident"}
    31	EOF
    32	  printf 'summary\n' >"$dir/summary.txt"
    33	  printf 'read me first\n' >"$dir/README-FIRST.txt"
    34	  printf 'ok\n' >"$dir/cluster/ceph/status.txt"
    35	  printf 'monitor01\n' >"$dir/nodes/monitor01/system/hostname.txt"
    36	}
    37	
    38	make_bundle_archive() {
    39	  local source_dir=$1 archive_path=$2
    40	  tar -C "$source_dir" -czf "$archive_path" .
    41	}
    42	
    43	assert_pass() {
    44	  local target=$1
    45	  local result status output
    46	
    47	  result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$target")"
    48	  status="${result%%$'\n'*}"
    49	  output="${result#*$'\n'}"
    50	  [[ "$status" == "0" ]] || fail "expected success for $target, got status $status: $output"
    51	  [[ "$output" == "VERIFY PASS: $target" ]] || fail "unexpected pass output: $output"
    52	}
    53	
    54	assert_fail() {
    55	  local target=$1 expected=$2
    56	  local result status output
    57	
    58	  result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$target")"
    59	  status="${result%%$'\n'*}"
    60	  output="${result#*$'\n'}"
    61	  [[ "$status" != "0" ]] || fail "expected failure for $target"
    62	  [[ "$output" == *"$expected"* ]] || fail "failure output did not mention '$expected': $output"
    63	}
    64	
    65	valid_dir="$tmpdir/valid-dir"
    66	mkdir -p "$valid_dir"
    67	make_valid_bundle_dir "$valid_dir"
    68	
    69	valid_archive="$tmpdir/valid-bundle.tar.gz"
    70	make_bundle_archive "$valid_dir" "$valid_archive"
    71	
    72	missing_manifest_dir="$tmpdir/missing-manifest"
    73	mkdir -p "$missing_manifest_dir"
    74	make_valid_bundle_dir "$missing_manifest_dir"
    75	rm -f "$missing_manifest_dir/manifest.jsonl"
    76	missing_manifest_archive="$tmpdir/missing-manifest.tar.gz"
    77	make_bundle_archive "$missing_manifest_dir" "$missing_manifest_archive"
    78	
    79	keyring_dir="$tmpdir/keyring-bundle"
    80	mkdir -p "$keyring_dir/cluster/ceph" "$keyring_dir/nodes/node01/system"
    81	cat >"$keyring_dir/manifest.jsonl" <<'EOF'
    82	{"bundle":"ceph-incident"}
    83	EOF
    84	printf 'summary\n' >"$keyring_dir/summary.txt"
    85	printf 'read me first\n' >"$keyring_dir/README-FIRST.txt"
    86	printf 'secret\n' >"$keyring_dir/cluster/ceph/keyring"
    87	printf 'node01\n' >"$keyring_dir/nodes/node01/system/hostname.txt"
    88	keyring_archive="$tmpdir/keyring-bundle.tar.gz"
    89	make_bundle_archive "$keyring_dir" "$keyring_archive"
    90	
    91	ssh_dir="$tmpdir/ssh-bundle"
    92	mkdir -p "$ssh_dir/cluster/ceph" "$ssh_dir/nodes/node01/.ssh"
    93	cat >"$ssh_dir/manifest.jsonl" <<'EOF'
    94	{"bundle":"ceph-incident"}
    95	EOF
    96	printf 'summary\n' >"$ssh_dir/summary.txt"
    97	printf 'read me first\n' >"$ssh_dir/README-FIRST.txt"
    98	printf 'ok\n' >"$ssh_dir/cluster/ceph/status.txt"
    99	printf 'secret\n' >"$ssh_dir/nodes/node01/.ssh/id_ed25519"
   100	ssh_archive="$tmpdir/ssh-bundle.tar.gz"
   101	make_bundle_archive "$ssh_dir" "$ssh_archive"
   102	
   103	id_ed25519_dir="$tmpdir/id-ed25519-bundle"
   104	mkdir -p "$id_ed25519_dir/cluster/ceph" "$id_ed25519_dir/nodes/node01/system"
   105	cat >"$id_ed25519_dir/manifest.jsonl" <<'EOF'
   106	{"bundle":"ceph-incident"}
   107	EOF
   108	printf 'summary\n' >"$id_ed25519_dir/summary.txt"
   109	printf 'read me first\n' >"$id_ed25519_dir/README-FIRST.txt"
   110	printf 'ok\n' >"$id_ed25519_dir/cluster/ceph/id_ed25519"
   111	printf 'node01\n' >"$id_ed25519_dir/nodes/node01/system/hostname.txt"
   112	id_ed25519_archive="$tmpdir/id-ed25519-bundle.tar.gz"
   113	make_bundle_archive "$id_ed25519_dir" "$id_ed25519_archive"
   114	
   115	private_key_dir="$tmpdir/private-key-bundle"
   116	mkdir -p "$private_key_dir/cluster/ceph" "$private_key_dir/nodes/node01/system"
   117	cat >"$private_key_dir/manifest.jsonl" <<'EOF'
   118	{"bundle":"ceph-incident"}
   119	EOF
   120	printf 'summary\n' >"$private_key_dir/summary.txt"
   121	printf 'read me first\n' >"$private_key_dir/README-FIRST.txt"
   122	printf 'secret\n' >"$private_key_dir/cluster/ceph/private_key"
   123	printf 'node01\n' >"$private_key_dir/nodes/node01/system/hostname.txt"
   124	private_key_archive="$tmpdir/private-key-bundle.tar.gz"
   125	make_bundle_archive "$private_key_dir" "$private_key_archive"
   126	
   127	pem_dir="$tmpdir/pem-bundle"
   128	mkdir -p "$pem_dir/cluster/ceph" "$pem_dir/nodes/node01/system"
   129	cat >"$pem_dir/manifest.jsonl" <<'EOF'
   130	{"bundle":"ceph-incident"}
   131	EOF
   132	printf 'summary\n' >"$pem_dir/summary.txt"
   133	printf 'read me first\n' >"$pem_dir/README-FIRST.txt"
   134	printf 'ok\n' >"$pem_dir/cluster/ceph/status.txt"
   135	printf 'node01\n' >"$pem_dir/nodes/node01/system/hostname.txt"
   136	printf 'cert material\n' >"$pem_dir/nodes/node01/system/tls.pem"
   137	pem_archive="$tmpdir/pem-bundle.tar.gz"
   138	make_bundle_archive "$pem_dir" "$pem_archive"
   139	
   140	content_key_dir="$tmpdir/content-key-bundle"
   141	mkdir -p "$content_key_dir/cluster/ceph" "$content_key_dir/nodes/node01/system"
   142	cat >"$content_key_dir/manifest.jsonl" <<'EOF'
   143	{"bundle":"ceph-incident"}
   144	EOF
   145	printf 'summary\n' >"$content_key_dir/summary.txt"
   146	printf 'read me first\n' >"$content_key_dir/README-FIRST.txt"
   147	printf 'node01\n' >"$content_key_dir/nodes/node01/system/hostname.txt"
   148	# an un-redacted PEM body slipped into an allowed extension
   149	{
   150	  printf 'some log preamble\n'
   151	  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n'
   152	  printf 'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB\n'
   153	  printf -- '-----END OPENSSH PRIVATE KEY-----\n'
   154	} >"$content_key_dir/cluster/ceph/leak.txt"
   155	content_key_archive="$tmpdir/content-key-bundle.tar.gz"
   156	make_bundle_archive "$content_key_dir" "$content_key_archive"
   157	
   158	corrupt_archive="$tmpdir/corrupt-bundle.tar.gz"
   159	printf 'not a tar.gz\n' >"$corrupt_archive"
   160	
   161	assert_pass "$valid_dir"
   162	assert_pass "$valid_archive"
   163	assert_fail "$missing_manifest_dir" "manifest.jsonl"
   164	assert_fail "$missing_manifest_archive" "manifest.jsonl"
   165	assert_fail "$keyring_dir" "keyring"
   166	assert_fail "$keyring_archive" "keyring"
   167	assert_fail "$ssh_dir" ".ssh"
   168	assert_fail "$ssh_archive" ".ssh"
   169	assert_fail "$id_ed25519_dir" "id_ed25519"
   170	assert_fail "$id_ed25519_archive" "id_ed25519"
   171	assert_fail "$private_key_dir" "private_key"
   172	assert_fail "$private_key_archive" "private_key"
   173	assert_fail "$pem_dir" "tls.pem"
   174	assert_fail "$pem_archive" "tls.pem"
   175	assert_fail "$content_key_dir" "PRIVATE KEY"
   176	assert_fail "$content_key_archive" "PRIVATE KEY"
   177	assert_fail "$corrupt_archive" "invalid archive"
   178	
   179	extra_args_result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$valid_dir" extra)"
   180	extra_args_status="${extra_args_result%%$'\n'*}"
   181	extra_args_output="${extra_args_result#*$'\n'}"
   182	[[ "$extra_args_status" != "0" ]] || fail "expected failure for extra args"
   183	[[ "$extra_args_output" == *"Usage:"* ]] || fail "extra args should print usage: $extra_args_output"

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-collect.sh | sed -n '1,420p'" in /Users/ikaros/Documents/code/learning-k8s
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
    32	assert_archive_file_contains() {
    33	  local bundle=$1 path=$2 expected=$3
    34	  tar -xOzf "$bundle" "./$path" 2>/dev/null | grep -qF "$expected" || fail "archive file $path missing $expected"
    35	}
    36	
    37	tmpdir="$(mktemp -d)"
    38	trap 'rm -rf "$tmpdir"' EXIT
    39	
    40	help_result="$(run_and_capture "$ROOT/run/collect.sh" --help)"
    41	help_status="${help_result%%$'\n'*}"
    42	help_output="${help_result#*$'\n'}"
    43	[[ "$help_status" == "0" ]] || fail "collect.sh --help exited $help_status"
    44	[[ "$help_output" == *"Usage:"* ]] || fail "collect.sh --help did not print usage"
    45	
    46	missing_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$tmpdir/missing.env")"
    47	missing_status="${missing_result%%$'\n'*}"
    48	[[ "$missing_status" == "1" ]] || fail "missing inventory should exit 1, got $missing_status"
    49	
    50	fakebin="$tmpdir/fakebin"
    51	mkdir -p "$fakebin"
    52	
    53	cat >"$fakebin/kubectl" <<'EOF'
    54	#!/usr/bin/env bash
    55	set -euo pipefail
    56	printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG:?}"
    57	cmd="$*"
    58	case "$cmd" in
    59	  "get namespace rook-ceph")
    60	    printf 'rook-ceph\n'
    61	    ;;
    62	  "get pods -n rook-ceph -o wide")
    63	    printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n'
    64	    ;;
    65	  "get events -n rook-ceph --sort-by=.lastTimestamp")
    66	    printf 'LAST SEEN TYPE REASON OBJECT MESSAGE\n1m Normal Started pod/osd started\n'
    67	    ;;
    68	  "get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n rook-ceph -o yaml")
    69	    printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n'
    70	    ;;
    71	  "get pods -n rook-ceph -l app=rook-ceph-operator -o jsonpath={.items[0].metadata.name}")
    72	    printf 'rook-ceph-operator-0'
    73	    ;;
    74	  "logs -n rook-ceph rook-ceph-operator-0 --since=24h")
    75	    printf 'operator log line\n'
    76	    ;;
    77	  "get pods -n rook-ceph -l app=rook-ceph-tools -o jsonpath={.items[0].metadata.name}")
    78	    exit 0
    79	    ;;
    80	  *)
    81	    printf 'unexpected kubectl command: %s\n' "$cmd" >&2
    82	    exit 99
    83	    ;;
    84	esac
    85	EOF
    86	
    87	cat >"$fakebin/ssh" <<'EOF'
    88	#!/usr/bin/env bash
    89	set -euo pipefail
    90	printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
    91	cat >/dev/null
    92	
    93	remote_command="${@: -1}"
    94	alias_name="$(printf '%s\n' "$remote_command" | sed -n "s/.*--host-alias '\\([^']*\\)'.*/\\1/p")"
    95	[[ -n "$alias_name" ]] || {
    96	  printf 'remote command did not preserve quoted --host-alias: %s\n' "$remote_command" >&2
    97	  exit 99
    98	}
    99	if [[ "${FAKE_SSH_BAD_TAR_ALIAS:-}" == "$alias_name" ]]; then
   100	  printf 'not a tar archive\n'
   101	  exit 0
   102	fi
   103	
   104	sleep "${FAKE_SSH_SLEEP:-0}"
   105	
   106	tmpdir="$(mktemp -d)"
   107	trap 'rm -rf "$tmpdir"' EXIT
   108	mkdir -p "$tmpdir/system"
   109	mkdir -p "$tmpdir/cephadm/var-lib-ceph-configs/fsid/mon.a"
   110	printf 'node %s\n' "$alias_name" >"$tmpdir/system/hostname.txt"
   111	printf 'secret = should-redact\n' >"$tmpdir/cephadm/var-lib-ceph-configs/fsid/mon.a/config"
   112	if [[ "${FAKE_SSH_NO_MANIFEST_ALIAS:-}" != "$alias_name" ]]; then
   113	  printf '{"node":"%s"}\n' "$alias_name" >"$tmpdir/manifest.jsonl"
   114	fi
   115	if [[ "${FAKE_SSH_PEM_ALIAS:-}" == "$alias_name" ]]; then
   116	  printf 'cert\n' >"$tmpdir/system/leak.pem"
   117	fi
   118	tar -czf - -C "$tmpdir" .
   119	
   120	if [[ "${FAKE_SSH_FAIL_ALIAS:-}" == "$alias_name" ]]; then
   121	  exit 2
   122	fi
   123	EOF
   124	cat >"$fakebin/timeout" <<'EOF'
   125	#!/usr/bin/env bash
   126	printf '%s\n' "$1" >>"${FAKE_TIMEOUT_LOG:?}"
   127	shift
   128	exec "$@"
   129	EOF
   130	chmod +x "$fakebin/kubectl" "$fakebin/ssh" "$fakebin/timeout"
   131	
   132	inventory="$tmpdir/inventory.env"
   133	cat >"$inventory" <<'EOF'
   134	SSH_USER="tester"
   135	SEED_HOST="seed.example.invalid"
   136	ROOK_NAMESPACE="rook-ceph"
   137	HOSTS=(
   138	  "monitor01=10.0.0.1"
   139	  "osd01=10.0.0.2"
   140	)
   141	EOF
   142	
   143	ssh_key="$tmpdir/id_ed25519"
   144	printf 'fake key\n' >"$ssh_key"
   145	
   146	export FAKE_KUBECTL_LOG="$tmpdir/kubectl.log"
   147	export FAKE_SSH_LOG="$tmpdir/ssh.log"
   148	export FAKE_TIMEOUT_LOG="$tmpdir/timeout.log"
   149	
   150	out_success="$tmpdir/out-success"
   151	PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   152	  --inventory "$inventory" \
   153	  --ssh-key "$ssh_key" \
   154	  --seed tester@seed.example.invalid \
   155	  --mode rook \
   156	  --out "$out_success" \
   157	  --since 24h \
   158	  --timeout 5 \
   159	  --node-timeout 90
   160	
   161	bundle_success="$(find_bundle "$out_success")"
   162	assert_archive_contains "$bundle_success" "manifest.jsonl"
   163	assert_archive_contains "$bundle_success" "summary.txt"
   164	assert_archive_contains "$bundle_success" "README-FIRST.txt"
   165	assert_archive_contains "$bundle_success" "cluster/rook/pods-wide.txt"
   166	assert_archive_contains "$bundle_success" "nodes/monitor01/system/hostname.txt"
   167	assert_archive_contains "$bundle_success" "nodes/osd01/system/hostname.txt"
   168	assert_archive_file_contains "$bundle_success" "nodes/monitor01/cephadm/var-lib-ceph-configs/fsid/mon.a/config" "[REDACTED]"
   169	grep -qF 'ConnectTimeout=5' "$FAKE_SSH_LOG" || fail "ssh calls should include ConnectTimeout from --timeout"
   170	# C1: the whole-node SSH wrapper must use --node-timeout (90), not the per-command timeout (5)
   171	grep -qx '90' "$FAKE_TIMEOUT_LOG" || fail "node SSH wrapper should use --node-timeout (90); timeout log: $(cat "$FAKE_TIMEOUT_LOG")"
   172	
   173	out_partial="$tmpdir/out-partial"
   174	partial_status=0
   175	set +e
   176	FAKE_SSH_FAIL_ALIAS=osd01 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   177	  --inventory "$inventory" \
   178	  --ssh-key "$ssh_key" \
   179	  --seed tester@seed.example.invalid \
   180	  --mode rook \
   181	  --out "$out_partial" \
   182	  --since 24h \
   183	  --timeout 5
   184	partial_status=$?
   185	set -e
   186	[[ "$partial_status" == "2" ]] || fail "one failed host should exit 2, got $partial_status"
   187	
   188	bundle_partial="$(find_bundle "$out_partial")"
   189	assert_archive_contains "$bundle_partial" "nodes/osd01/system/hostname.txt"
   190	assert_archive_contains "$bundle_partial" "errors.log"
   191	
   192	out_bad_tar="$tmpdir/out-bad-tar"
   193	bad_tar_status=0
   194	set +e
   195	FAKE_SSH_BAD_TAR_ALIAS=osd01 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   196	  --inventory "$inventory" \
   197	  --ssh-key "$ssh_key" \
   198	  --seed tester@seed.example.invalid \
   199	  --mode rook \
   200	  --out "$out_bad_tar" \
   201	  --since 24h \
   202	  --timeout 5
   203	bad_tar_status=$?
   204	set -e
   205	[[ "$bad_tar_status" == "2" ]] || fail "bad node tar should exit 2, got $bad_tar_status"
   206	
   207	bundle_bad_tar="$(find_bundle "$out_bad_tar")"
   208	assert_archive_contains "$bundle_bad_tar" "nodes/osd01/SKIPPED.txt"
   209	
   210	# C4: a node tar that extracts but is missing its own manifest.jsonl (truncated
   211	# transfer) must be treated as a failure, not silently counted as ok.
   212	out_no_manifest="$tmpdir/out-no-manifest"
   213	no_manifest_status=0
   214	set +e
   215	FAKE_SSH_NO_MANIFEST_ALIAS=osd01 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   216	  --inventory "$inventory" --ssh-key "$ssh_key" \
   217	  --seed tester@seed.example.invalid --mode rook \
   218	  --out "$out_no_manifest" --since 24h --timeout 5
   219	no_manifest_status=$?
   220	set -e
   221	[[ "$no_manifest_status" == "2" ]] || fail "truncated node (no manifest) should exit 2, got $no_manifest_status"
   222	bundle_no_manifest="$(find_bundle "$out_no_manifest")"
   223	assert_archive_contains "$bundle_no_manifest" "nodes/osd01/SKIPPED.txt"
   224	assert_archive_contains "$bundle_no_manifest" "nodes/monitor01/system/hostname.txt"
   225	
   226	# C2: on mid-run abort, the temp workdir must be trap-cleaned (no tmp.* left behind).
   227	out_abort="$tmpdir/out-abort"
   228	set +e
   229	COLLECT_TEST_ABORT_AFTER_NODES=1 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   230	  --inventory "$inventory" --ssh-key "$ssh_key" \
   231	  --seed tester@seed.example.invalid --mode rook \
   232	  --out "$out_abort" --since 24h --timeout 5 >/dev/null 2>&1
   233	abort_status=$?
   234	set -e
   235	[[ "$abort_status" != "0" ]] || fail "abort hook should make collect.sh exit non-zero"
   236	leftover="$(find "$out_abort" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
   237	[[ "$leftover" == "0" ]] || fail "abort left $leftover tmp workdir(s) behind"
   238	
   239	# C3: if verification fails (forbidden secret path), evidence is preserved
   240	# (workdir kept) and NO shareable .tar.gz is produced; exit 1.
   241	out_verify_fail="$tmpdir/out-verify-fail"
   242	set +e
   243	FAKE_SSH_PEM_ALIAS=osd01 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   244	  --inventory "$inventory" --ssh-key "$ssh_key" \
   245	  --seed tester@seed.example.invalid --mode rook \
   246	  --out "$out_verify_fail" --since 24h --timeout 5 >/dev/null 2>&1
   247	verify_fail_status=$?
   248	set -e
   249	[[ "$verify_fail_status" == "1" ]] || fail "verify failure should exit 1, got $verify_fail_status"
   250	produced="$(find "$out_verify_fail" -maxdepth 1 -name 'ceph-incident-*.tar.gz' 2>/dev/null | wc -l | tr -d '[:space:]')"
   251	[[ "$produced" == "0" ]] || fail "verify failure must not produce a shareable bundle"
   252	kept="$(find "$out_verify_fail" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
   253	[[ "$kept" == "1" ]] || fail "verify failure should keep the workdir for inspection (found $kept)"

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-common.sh | sed -n '1,420p'" in /Users/ikaros/Documents/code/learning-k8s
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
   224	test_run_capture_success() {
   225	  local manifest="$tmpdir/run-manifest.jsonl"
   226	  local artifact="$tmpdir/run-artifact.txt"
   227	
   228	  run_capture "$manifest" "host-a" "collector-a" "$artifact" -- printf 'hello world\n'
   229	
   230	  [[ "$(sed -n '1p' "$artifact")" == "# host: host-a" ]] || fail "artifact header missing host"
   231	  grep -q 'hello world' "$artifact" || fail "artifact output missing"
   232	  python3 - "$manifest" "$artifact" <<'PY'
   233	import json
   234	import sys
   235	
   236	manifest_path, artifact_path = sys.argv[1:3]
   237	lines = [line.rstrip("\n") for line in open(manifest_path)]
   238	if len(lines) != 1:
   239	    raise SystemExit(f"expected 1 manifest entry, got {len(lines)}")
   240	entry = json.loads(lines[0])
   241	if entry["artifact"] != artifact_path:
   242	    raise SystemExit("artifact path mismatch")
   243	if entry["exit_code"] != 0:
   244	    raise SystemExit(f"unexpected exit code {entry['exit_code']}")
   245	PY
   246	}
   247	
   248	test_run_capture_non_zero_writes_error_log_and_returns_code() {
   249	  local manifest="$tmpdir/run-manifest-fail.jsonl"
   250	  local artifact="$tmpdir/run-artifact-fail.txt"
   251	  local error_log="$tmpdir/errors.log"
   252	  local rc=0
   253	
   254	  ERROR_LOG="$error_log" run_capture "$manifest" "host-b" "collector-b" "$artifact" -- bash -c 'printf fail-output; exit 7' || rc=$?
   255	  [[ "$rc" == "7" ]] || fail "run_capture returned $rc instead of 7"
   256	  grep -q 'fail-output' "$artifact" || fail "failure output missing from artifact"
   257	  grep -q 'exit=7' "$error_log" || fail "error log missing exit code"
   258	  python3 - "$manifest" <<'PY'
   259	import json
   260	import sys
   261	
   262	entry = json.loads(open(sys.argv[1]).readline())
   263	if entry["exit_code"] != 7:
   264	    raise SystemExit(f"unexpected exit code {entry['exit_code']}")
   265	PY
   266	}
   267	
   268	test_run_capture_missing_double_dash_is_fatal() {
   269	  local manifest="$tmpdir/run-manifest-missing-dash.jsonl"
   270	  local artifact="$tmpdir/run-artifact-missing-dash.txt"
   271	  local rc output
   272	
   273	  set +e
   274	  output="$(
   275	    bash -c '
   276	      set -euo pipefail
   277	      ROOT=$1
   278	      MANIFEST=$2
   279	      ARTIFACT=$3
   280	      # shellcheck disable=SC1091
   281	      source "$ROOT/lib/common.sh"
   282	      run_capture "$MANIFEST" "host-c" "collector-c" "$ARTIFACT" printf "missing-dash\n"
   283	    ' bash "$ROOT" "$manifest" "$artifact" 2>&1
   284	  )"
   285	  rc=$?
   286	  set -e
   287	  [[ "$rc" != "0" ]] || fail "run_capture accepted missing --"
   288	  [[ "$output" == *"-- before the command"* ]] || fail "missing -- failure was not explained"
   289	}
   290	
   291	test_run_capture_timeout_branch() {
   292	  local fakebin="$tmpdir/timeout-bin"
   293	  local timeout_log="$tmpdir/timeout.log"
   294	  mkdir -p "$fakebin"
   295	  cat >"$fakebin/timeout" <<'EOF'
   296	#!/usr/bin/env bash
   297	printf '%s\n' "$*" >>"$TIMEOUT_LOG"
   298	shift
   299	"$@"
   300	EOF
   301	  chmod +x "$fakebin/timeout"
   302	
   303	  local manifest="$tmpdir/run-manifest-timeout.jsonl"
   304	  local artifact="$tmpdir/run-artifact-timeout.txt"
   305	  PATH="$fakebin:$PATH" TIMEOUT_LOG="$timeout_log" run_capture "$manifest" "host-d" "collector-d" "$artifact" -- printf 'timeout-path\n'
   306	
   307	  grep -q 'timeout-path' "$artifact" || fail "timeout branch did not execute command"
   308	  grep -q '^20 printf timeout-path\\n$' "$timeout_log" || fail "fake timeout was not used"
   309	  grep -q '^# timeout: 20s$' "$artifact" || fail "timeout header missing"
   310	}
   311	
   312	test_run_capture_handles_leading_dash_artifact() {
   313	  local manifest="$tmpdir/run-manifest-leading-dash.jsonl"
   314	  local cwd="$tmpdir/leading-dash"
   315	  mkdir -p "$cwd"
   316	
   317	  (
   318	    cd "$cwd"
   319	    run_capture "$manifest" "host-dash" "collector-dash" "-leading-dash.txt" -- printf 'dash-safe\n'
   320	  )
   321	
   322	  [[ -f "$cwd/-leading-dash.txt" ]] || fail "leading-dash artifact was not created"
   323	  grep -q 'dash-safe' "$cwd/-leading-dash.txt" || fail "leading-dash artifact output missing"
   324	}
   325	
   326	test_run_capture_preserves_errexit_state() {
   327	  local manifest="$tmpdir/run-manifest-state.jsonl"
   328	  local artifact="$tmpdir/run-artifact-state.txt"
   329	  local status
   330	
   331	  set +e
   332	  run_capture "$manifest" "host-e" "collector-e" "$artifact" -- bash -c 'exit 3'
   333	  status=$?
   334	  false
   335	  status=$?
   336	  set -e
   337	
   338	  [[ "$status" == "1" ]] || fail "run_capture changed errexit state"
   339	}
   340	
   341	test_json_escape
   342	test_json_escape_is_shell_native
   343	test_manifest_add
   344	test_manifest_add_rejects_non_numeric_exit_code
   345	test_redact_file
   346	test_redact_file_private_key_variants
   347	test_redact_file_multiline_pem_body
   348	test_redact_file_ceph_key_material
   349	test_redact_file_preserves_mode
   350	test_redact_gz_file
   351	test_run_capture_success
   352	test_run_capture_non_zero_writes_error_log_and_returns_code
   353	test_run_capture_missing_double_dash_is_fatal
   354	test_run_capture_timeout_branch
   355	test_run_capture_handles_leading_dash_artifact
   356	test_run_capture_preserves_errexit_state
   357	
   358	printf 'ok: common helpers\n'

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-node-collector.sh | sed -n '1,420p'" in /Users/ikaros/Documents/code/learning-k8s
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
    11	assert_file_contains() {
    12	  local file=$1 expected=$2
    13	  [[ -f "$file" ]] || fail "missing file: $file"
    14	  grep -qF "$expected" "$file" || fail "expected '$expected' in $file"
    15	}
    16	
    17	tmpdir="$(mktemp -d)"
    18	trap 'rm -rf "$tmpdir"' EXIT
    19	
    20	fakebin="$tmpdir/fakebin"
    21	mkdir -p "$fakebin"
    22	fake_log_dir="$tmpdir/var-log-ceph"
    23	fake_var_lib="$tmpdir/var-lib-ceph"
    24	mkdir -p "$fake_log_dir" "$fake_var_lib/fsid/mon.a"
    25	
    26	printf 'current ceph log\n' >"$fake_log_dir/ceph.log"
    27	printf 'rotated ceph log\n' >"$fake_log_dir/ceph.log.1"
    28	printf 'rotated osd log\n' >"$fake_log_dir/ceph-osd.0.log.1"
    29	printf 'compressed ceph log bytes\n' >"$fake_log_dir/ceph.log.2.gz"
    30	printf '%0200d\n' 1 >"$fake_log_dir/ceph-too-large.log"
    31	
    32	printf 'fsid = fake\n' >"$fake_var_lib/fsid/mon.a/config"
    33	printf 'secret key material\n' >"$fake_var_lib/fsid/mon.a/keyring"
    34	
    35	cat >"$fakebin/sudo" <<'EOF'
    36	#!/usr/bin/env bash
    37	set -euo pipefail
    38	printf '%s\n' "$*" >>"${FAKE_SUDO_LOG:?}"
    39	if [[ ${1-} == "-n" ]]; then
    40	  shift
    41	fi
    42	exec "$@"
    43	EOF
    44	
    45	cat >"$fakebin/journalctl" <<'EOF'
    46	#!/usr/bin/env bash
    47	set -euo pipefail
    48	case "$*" in
    49	  *"--since -24h"*) ;;
    50	  *) printf 'journalctl expected --since -24h, got: %s\n' "$*" >&2; exit 12 ;;
    51	esac
    52	printf 'fake journalctl %s\n' "$*"
    53	EOF
    54	
    55	cat >"$fakebin/podman" <<'EOF'
    56	#!/usr/bin/env bash
    57	set -euo pipefail
    58	printf 'fake podman %s\n' "$*"
    59	EOF
    60	
    61	cat >"$fakebin/docker" <<'EOF'
    62	#!/usr/bin/env bash
    63	set -euo pipefail
    64	printf 'fake docker %s\n' "$*"
    65	exit 1
    66	EOF
    67	
    68	cat >"$fakebin/cephadm" <<'EOF'
    69	#!/usr/bin/env bash
    70	set -euo pipefail
    71	case "$*" in
    72	  "ls --format json-pretty") printf '[{"name":"mon.a","style":"cephadm"}]\n' ;;
    73	  *) printf 'fake cephadm %s\n' "$*" ;;
    74	esac
    75	EOF
    76	
    77	cat >"$fakebin/timeout" <<'EOF'
    78	#!/usr/bin/env bash
    79	shift
    80	exec "$@"
    81	EOF
    82	
    83	cat >"$fakebin/dmesg" <<'EOF'
    84	#!/usr/bin/env bash
    85	set -euo pipefail
    86	printf 'fake kernel ring buffer\n'
    87	EOF
    88	
    89	cat >"$fakebin/hostname" <<'EOF'
    90	#!/usr/bin/env bash
    91	set -euo pipefail
    92	printf 'monitor01\n'
    93	EOF
    94	
    95	cat >"$fakebin/uname" <<'EOF'
    96	#!/usr/bin/env bash
    97	set -euo pipefail
    98	printf 'Linux monitor01 6.1.0 fake\n'
    99	EOF
   100	
   101	cat >"$fakebin/uptime" <<'EOF'
   102	#!/usr/bin/env bash
   103	set -euo pipefail
   104	printf 'up 1 day\n'
   105	EOF
   106	
   107	cat >"$fakebin/free" <<'EOF'
   108	#!/usr/bin/env bash
   109	set -euo pipefail
   110	printf 'Mem: 1Gi 512Mi 512Mi\n'
   111	EOF
   112	
   113	cat >"$fakebin/df" <<'EOF'
   114	#!/usr/bin/env bash
   115	set -euo pipefail
   116	printf 'Filesystem Type Size Used Avail Mounted on\n'
   117	EOF
   118	
   119	cat >"$fakebin/lsblk" <<'EOF'
   120	#!/usr/bin/env bash
   121	set -euo pipefail
   122	printf 'NAME SIZE TYPE MOUNTPOINT\nsda 100G disk\n'
   123	EOF
   124	
   125	cat >"$fakebin/ip" <<'EOF'
   126	#!/usr/bin/env bash
   127	set -euo pipefail
   128	printf '1: lo: <LOOPBACK,UP>\n'
   129	EOF
   130	
   131	cat >"$fakebin/systemctl" <<'EOF'
   132	#!/usr/bin/env bash
   133	set -euo pipefail
   134	printf '0 loaded units listed.\n'
   135	EOF
   136	
   137	for tool in iostat chronyc ntpq pvs vgs lvs; do
   138	  cat >"$fakebin/$tool" <<'EOF'
   139	#!/usr/bin/env bash
   140	set -euo pipefail
   141	tool=${0##*/}
   142	{
   143	  printf '%s' "$tool"
   144	  for arg in "$@"; do
   145	    printf ' <%s>' "$arg"
   146	  done
   147	  printf '\n'
   148	} >>"${FAKE_OPTIONAL_LOG:?}"
   149	printf 'fake optional command %s\n' "$tool"
   150	EOF
   151	done
   152	
   153	rm -f "$fakebin/ntpq"
   154	
   155	chmod +x "$fakebin"/*
   156	
   157	export FAKE_SUDO_LOG="$tmpdir/sudo.log"
   158	export FAKE_OPTIONAL_LOG="$tmpdir/optional.log"
   159	PATH="$fakebin:$PATH"
   160	
   161	outdir="$tmpdir/node"
   162	set +e
   163	CEPH_INCIDENT_VAR_LOG_CEPH_DIR="$fake_log_dir" \
   164	CEPH_INCIDENT_VAR_LIB_CEPH_DIR="$fake_var_lib" \
   165	CEPH_INCIDENT_LOG_FILE_CAP_BYTES=128 \
   166	bash "$ROOT/lib/collect-node.sh" \
   167	  --out "$outdir" \
   168	  --host-alias monitor01 \
   169	  --since "24h" \
   170	  --timeout 5
   171	rc=$?
   172	set -e
   173	if [[ "$rc" != "0" ]]; then
   174	  [[ -f "$outdir/errors.log" ]] && sed -n '1,120p' "$outdir/errors.log" >&2
   175	  fail "collect-node.sh exited $rc"
   176	fi
   177	
   178	for artifact in \
   179	  system/hostname.txt \
   180	  system/uname.txt \
   181	  system/uptime.txt \
   182	  resources/free.txt \
   183	  storage/df.txt \
   184	  storage/lsblk.txt \
   185	  network/ip-addr.txt \
   186	  kernel/dmesg.txt \
   187	  systemd/failed-units.txt \
   188	  cephadm/cephadm-ls.json \
   189	  logs/ceph-log-listing.txt; do
   190	  [[ -f "$outdir/$artifact" ]] || fail "missing artifact: $artifact"
   191	done
   192	
   193	assert_file_contains "$outdir/cephadm/cephadm-ls.json" '"style":"cephadm"'
   194	assert_file_contains "$outdir/kernel/dmesg.txt" 'fake kernel ring buffer'
   195	assert_file_contains "$outdir/containers/docker-ps.txt" 'fake docker'
   196	assert_file_contains "$outdir/logs/ceph-log-listing.txt" "$fake_log_dir"
   197	assert_file_contains "$outdir/time/ntpq-peers.txt" 'SKIPPED: command not found: ntpq'
   198	
   199	[[ -f "$outdir/logs/ceph/ceph.log" ]] || fail "missing copied current ceph log"
   200	[[ -f "$outdir/logs/ceph/ceph.log.1" ]] || fail "missing copied rotated ceph log"
   201	[[ -f "$outdir/logs/ceph/ceph-osd.0.log.1" ]] || fail "missing copied rotated osd log"
   202	[[ -f "$outdir/logs/ceph/ceph.log.2.gz" ]] || fail "missing copied gz ceph log"
   203	# R2: oversized logs are tail-captured (not silently dropped) with a marker
   204	[[ -f "$outdir/logs/ceph/ceph-too-large.log" ]] || fail "oversized ceph log should be tail-captured"
   205	toobig_bytes="$(wc -c <"$outdir/logs/ceph/ceph-too-large.log" | tr -d '[:space:]')"
   206	[[ "$toobig_bytes" -le 128 ]] || fail "oversized ceph log tail should be <= cap (got $toobig_bytes)"
   207	[[ -f "$outdir/logs/ceph/ceph-too-large.log.TRUNCATED" ]] || fail "oversized ceph log missing .TRUNCATED marker"
   208	assert_file_contains "$outdir/logs/ceph/ceph-too-large.log.TRUNCATED" "original_bytes="
   209	
   210	[[ -f "$outdir/cephadm/var-lib-ceph-configs/fsid/mon.a/config" ]] || fail "missing copied var-lib ceph config"
   211	[[ ! -e "$outdir/cephadm/var-lib-ceph-configs/fsid/mon.a/keyring" ]] || fail "keyring should not be copied from var-lib ceph"
   212	if grep -qF 'keyring' "$outdir/cephadm/var-lib-ceph-listing.txt"; then
   213	  fail "var-lib ceph listing should exclude keyrings"
   214	fi
   215	
   216	grep -qF 'iostat <-xz> <1> <3>' "$FAKE_OPTIONAL_LOG" || fail "iostat argv was not preserved"
   217	grep -qF 'pvs <--noheadings> <--separator> < >' "$FAKE_OPTIONAL_LOG" || fail "pvs separator argv was not preserved"
   218	grep -qF 'vgs <--noheadings> <--separator> < >' "$FAKE_OPTIONAL_LOG" || fail "vgs separator argv was not preserved"
   219	grep -qF 'lvs <--noheadings> <--separator> < >' "$FAKE_OPTIONAL_LOG" || fail "lvs separator argv was not preserved"
   220	
   221	grep -qF -- '-n dmesg' "$FAKE_SUDO_LOG" || fail "dmesg was not collected through sudo -n"
   222	
   223	# C8: dmesg and ceph journal get a heavier timeout than the per-command --timeout (5),
   224	# so large kernel ring / journals are not silently truncated.
   225	assert_file_contains "$outdir/kernel/dmesg.txt" '# timeout: 120s'
   226	assert_file_contains "$outdir/systemd/journal-ceph.txt" '# timeout: 120s'

codex
The test suite covers several hardening paths, but it misses a shell-version issue in the test fake SSH itself and does not isolate the `verify_no_secret_content` option-parsing edge. I’m now doing targeted command probes where the sandbox permits reads/execution, without changing files.
exec
/bin/zsh -lc "bash --version | sed -n '1p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin24)

exec
/bin/zsh -lc "printf 'safe\\n' > /tmp/codex-safe-verify.txt; grep -rlIE -e '-----BEGIN[ A-Za-z]*PRIVATE KEY-----' -e '"'^[[:space:]]*key[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{20,}={0,2}'"' /tmp/codex-safe-verify.txt 2>&1; rm -f /tmp/codex-safe-verify.txt" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
zsh:1: operation not permitted: /tmp/codex-safe-verify.txt
grep: /tmp/codex-safe-verify.txt: No such file or directory

exec
/bin/zsh -lc "git diff 8374cf1..HEAD -- experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/common.sh experiments/ceph-incident-bundle/lib/verify-bundle.sh experiments/ceph-incident-bundle/lib/collect-node.sh experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh | sed -n '1,260p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-N7nlK6nK' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-kwaDEDua' (errno=Operation not permitted)
diff --git a/experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh b/experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh
index 2a68c60..3d067fc 100644
--- a/experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh
+++ b/experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh
@@ -22,8 +22,11 @@ collect_cephadm_command() {
       -o BatchMode=yes \
       -o IdentitiesOnly=yes \
       -o IdentityAgent=none \
+      -o "ConnectTimeout=$timeout" \
+      -o "ServerAliveInterval=$timeout" \
+      -o ServerAliveCountMax=1 \
       "$seed" \
-      sudo cephadm shell -- ceph "$@"
+      sudo -n cephadm shell -- ceph "$@"
 }
 
 write_cephadm_crash_skip() {
@@ -41,10 +44,12 @@ extract_cephadm_crash_ids() {
   [[ -f "$crash_ls_artifact" ]] || return 1
   payload="$(sed '/^[[:space:]]*#/d' "$crash_ls_artifact")" || return 1
 
+  # Anchor strictly to crash_id; matching id/name too would capture unrelated
+  # nested fields and feed bogus ids back into `ceph crash info`.
   ids="$(
     printf '%s\n' "$payload" |
-      grep -oE '"(crash_id|id|name)"[[:space:]]*:[[:space:]]*"[^"]*"' |
-      sed -E 's/^"(crash_id|id|name)"[[:space:]]*:[[:space:]]*"([^"]*)"$/\2/' |
+      grep -oE '"crash_id"[[:space:]]*:[[:space:]]*"[^"]*"' |
+      sed -E 's/^"crash_id"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/' |
       head -n 10
   )" || true
 
diff --git a/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh b/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
index 7b2a3b9..24d7d50 100644
--- a/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
+++ b/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
@@ -44,7 +44,7 @@ rook_get_first_pod() {
 }
 
 collect_cluster_rook() {
-  local outdir= manifest= namespace=rook-ceph since=24h timeout=20
+  local outdir='' manifest='' namespace=rook-ceph since=24h timeout=20 allow_skip=0
 
   while [[ $# -gt 0 ]]; do
     case "$1" in
@@ -68,6 +68,10 @@ collect_cluster_rook() {
         timeout=${2-}
         shift 2
         ;;
+      --allow-skip)
+        allow_skip=1
+        shift
+        ;;
       --help|-h)
         usage
         return 0
@@ -86,14 +90,17 @@ collect_cluster_rook() {
 
   ensure_dir "$outdir/cluster/rook"
 
+  # Missing kubectl / namespace means we collected NO cluster evidence. In
+  # explicit rook mode that is a partial failure (exit 2) so the bundle does not
+  # falsely look complete; auto-mode fallback passes --allow-skip to tolerate it.
   if ! command -v kubectl >/dev/null 2>&1; then
     rook_skip "$outdir" "kubectl command not found"
-    return 0
+    [[ "$allow_skip" == "1" ]] && return 0 || return 2
   fi
 
   if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
     rook_skip "$outdir" "namespace not found: $namespace"
-    return 0
+    [[ "$allow_skip" == "1" ]] && return 0 || return 2
   fi
 
   local failed=0
diff --git a/experiments/ceph-incident-bundle/lib/collect-node.sh b/experiments/ceph-incident-bundle/lib/collect-node.sh
index 3def215..8ece985 100644
--- a/experiments/ceph-incident-bundle/lib/collect-node.sh
+++ b/experiments/ceph-incident-bundle/lib/collect-node.sh
@@ -111,6 +111,9 @@ node_copy_file() {
   fi
 
   if command -v sudo >/dev/null 2>&1; then
+    # Intentional: read the source as root, but write $dest as the calling user
+    # (who owns the bundle). `sudo tee` would create $dest as root — not wanted.
+    # shellcheck disable=SC2024
     sudo -n cat -- "$source" >"$dest"
     return $?
   fi
@@ -118,6 +121,25 @@ node_copy_file() {
   return 1
 }
 
+node_tail_file() {
+  local source=$1 nbytes=$2 dest=$3
+  ensure_dir "$(dirname -- "$dest")"
+
+  if [[ $EUID -eq 0 || -r "$source" ]]; then
+    tail -c "$nbytes" "$source" >"$dest"
+    return $?
+  fi
+
+  if command -v sudo >/dev/null 2>&1; then
+    # Intentional: read as root, write $dest as the calling user (see node_copy_file).
+    # shellcheck disable=SC2024
+    sudo -n tail -c "$nbytes" "$source" >"$dest"
+    return $?
+  fi
+
+  return 1
+}
+
 copy_readable_etc_files() {
   local outdir=$1
   local source dest_name
@@ -135,6 +157,8 @@ collect_ceph_log_listing() {
   local listing="$outdir/logs/ceph-log-listing.txt"
 
   if [[ -d "$log_dir" ]]; then
+    # SC2016: the sh -c body is meant to expand on the remote sh, not here.
+    # shellcheck disable=SC2016
     if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "logs/ceph-log-listing.txt" \
       find "$log_dir" -maxdepth 2 -type f -exec sh -c '
         for path do
@@ -166,11 +190,28 @@ copy_ceph_logs() {
       failed=1
       continue
     fi
-    (( size <= cap_bytes )) || continue
-    rel="${source#$log_dir/}"
+    rel="${source#"$log_dir"/}"
     dest="$copied_dir/$rel"
-    if ! node_copy_file "$source" "$dest"; then
-      failed=1
+    if (( size <= cap_bytes )); then
+      if ! node_copy_file "$source" "$dest"; then
+        failed=1
+      fi
+    elif [[ "$source" == *.gz ]]; then
+      # A byte-tail of a gzip stream is not decompressible (and would evade
+      # redaction); record it instead of shipping garbage.
+      ensure_dir "$(dirname -- "$dest")"
+      printf 'original_bytes=%s\nnote=oversized compressed log skipped (gzip tail is not usable)\n' \
+        "$size" >"$dest.TRUNCATED"
+    else
+      # Oversized: keep the most recent cap_bytes (tail) instead of dropping the
+      # file silently — the active large log is often exactly what's wanted —
+      # and record the truncation so the omission is visible.
+      if node_tail_file "$source" "$cap_bytes" "$dest"; then
+        printf 'original_bytes=%s\ntail_bytes=%s\nnote=captured trailing bytes only (file exceeded cap)\n' \
+          "$size" "$cap_bytes" >"$dest.TRUNCATED"
+      else
+        failed=1
+      fi
     fi
   done < <(node_find0 "$log_dir" -maxdepth 2 -type f \( -name '*.log' -o -name '*.log.*' -o -name '*.txt' -o -name '*.gz' \) -print0 2>/dev/null || true)
 
@@ -185,6 +226,8 @@ collect_var_lib_ceph() {
   local failed=0
 
   if [[ -d "$ceph_dir" ]]; then
+    # SC2016: the sh -c body is meant to expand on the remote sh, not here.
+    # shellcheck disable=SC2016
     if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "cephadm/var-lib-ceph-listing.txt" \
       find "$ceph_dir" -maxdepth 3 \
         \( -iname '*keyring*' -o -iname '*private_key*' -o -path '*/.ssh/*' \) -prune \
@@ -209,7 +252,7 @@ collect_var_lib_ceph() {
 
   ensure_dir "$config_dest"
   while IFS= read -r -d '' source; do
-    rel="${source#$ceph_dir/}"
+    rel="${source#"$ceph_dir"/}"
     dest="$config_dest/$rel"
     if ! node_copy_file "$source" "$dest"; then
       failed=1
@@ -222,7 +265,7 @@ collect_var_lib_ceph() {
 }
 
 collect_node_main() {
-  local outdir= host_alias= since="24h" timeout=20 skip_logs=0
+  local outdir='' host_alias='' since="24h" timeout=20 skip_logs=0
 
   while [[ $# -gt 0 ]]; do
     case "$1" in
@@ -268,6 +311,13 @@ collect_node_main() {
   local journal_since
   journal_since="$(journal_since_arg "$since")"
 
+  # dmesg and the ceph journal can be large under load; give them a heavier
+  # timeout than the per-command one so they are not silently truncated.
+  local heavy_timeout=$timeout
+  if [[ "$heavy_timeout" =~ ^[0-9]+$ ]] && (( heavy_timeout < 120 )); then
+    heavy_timeout=120
+  fi
+
   local -a basic_specs=(
     "system/hostname.txt::hostname"
     "system/uname.txt::uname -a"
@@ -293,10 +343,10 @@ collect_node_main() {
   if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "storage/lsblk.txt" lsblk -a -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL; then
     failed=1
   fi
-  if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "kernel/dmesg.txt" dmesg -T; then
+  if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$heavy_timeout" "kernel/dmesg.txt" dmesg -T; then
     failed=1
   fi
-  if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "systemd/journal-ceph.txt" journalctl --since "$journal_since" -u 'ceph*' --no-pager; then
+  if ! node_run_privileged "$outdir" "$manifest" "$host_alias" "$heavy_timeout" "systemd/journal-ceph.txt" journalctl --since "$journal_since" -u 'ceph*' --no-pager; then
     failed=1
   fi
 
diff --git a/experiments/ceph-incident-bundle/lib/common.sh b/experiments/ceph-incident-bundle/lib/common.sh
index 36806fe..f39c4ec 100644
--- a/experiments/ceph-incident-bundle/lib/common.sh
+++ b/experiments/ceph-incident-bundle/lib/common.sh
@@ -24,6 +24,16 @@ ensure_dir() {
   mkdir -p "$1"
 }
 
+# Resolve a timeout binary: GNU coreutils `timeout`, or `gtimeout` on macOS.
+# Prints the binary name, or nothing if neither is installed.
+timeout_cmd() {
+  if command -v timeout >/dev/null 2>&1; then
+    printf 'timeout'
+  elif command -v gtimeout >/dev/null 2>&1; then
+    printf 'gtimeout'
+  fi
+}
+
 json_escape() {
   local value=$1
   value=${value//\\/\\\\}
@@ -53,10 +63,11 @@ redact_file() {
   require_file "$source_file"
   ensure_dir "$(dirname -- "$redaction_log")"
 
-  local source_dir tmp_file count line nocasematch_state
+  local source_dir tmp_file count line nocasematch_state in_pem redact mode
   source_dir="$(dirname -- "$source_file")"
   tmp_file="$(mktemp "$source_dir/.${source_file##*/}.XXXXXX")"
   count=0
+  in_pem=0
   if shopt -q nocasematch; then
     nocasematch_state='shopt -s nocasematch'
   else
@@ -64,8 +75,28 @@ redact_file() {
   fi
   shopt -s nocasematch
 
+  # Best-effort redaction (NOT a complete DLP): keyword lines, ceph key
+  # material (`key = AQB..==`, base64 blobs), and whole multi-line PEM private
+  # key blocks. Extensions/encodings outside this are intentionally not covered
+  # — see README "安全界線"; operators must self-review before sharing.
   while IFS= read -r line || [[ -n "$line" ]]; do
-    if [[ "$line" =~ (password|secret|token|keyring|private([[:space:]_-]+)?key) ]]; then
+    redact=0
+    if [[ "$line" =~ -----BEGIN[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
+      in_pem=1
+    fi

codex
The workstation `bash` is 3.2 as expected. The sandbox blocks writes outside the repo, so I’m using existing fixtures and source reasoning rather than creating ad hoc temp bundles outside the workspace.
exec
/bin/zsh -lc "rg -n \"declare -[A-Z]|mapfile|readarray|coproc|\\"'$'"\\{["'^}]+,,|'"\\"'$'"\\{["'^}]+'"\\"'^|BASH_REMATCH|printf -v|read -r -d|local -a|'"\\[\\[|=~\" experiments/ceph-incident-bundle/run experiments/ceph-incident-bundle/lib experiments/ceph-incident-bundle/tests" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:49:  while [[ $# -gt 0 ]]; do
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:86:  [[ -n "$outdir" && -n "$manifest" ]] || {
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:98:    [[ "$allow_skip" == "1" ]] && return 0 || return 2
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:103:    [[ "$allow_skip" == "1" ]] && return 0 || return 2
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:122:  if [[ -n "$operator_pod" ]]; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:132:  if [[ -n "$toolbox_pod" ]]; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:141:  [[ $failed -eq 0 ]] || return 2
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:145:if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
experiments/ceph-incident-bundle/lib/common.sh:20:  [[ -f "$1" ]] || die "missing file: $1"
experiments/ceph-incident-bundle/lib/common.sh:49:  [[ "$exit_code" =~ ^[0-9]+$ ]] || die "manifest_add requires numeric exit_code: $exit_code"
experiments/ceph-incident-bundle/lib/common.sh:82:  while IFS= read -r line || [[ -n "$line" ]]; do
experiments/ceph-incident-bundle/lib/common.sh:84:    if [[ "$line" =~ -----BEGIN[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
experiments/ceph-incident-bundle/lib/common.sh:87:    if [[ $in_pem -eq 1 ]]; then
experiments/ceph-incident-bundle/lib/common.sh:89:      if [[ "$line" =~ -----END[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
experiments/ceph-incident-bundle/lib/common.sh:92:    elif [[ "$line" =~ (password|secret|token|keyring|private([[:space:]_-]+)?key) ]]; then
experiments/ceph-incident-bundle/lib/common.sh:94:    elif [[ "$line" =~ (^|[^[:alnum:]])key[[:space:]]*[:=] ]]; then
experiments/ceph-incident-bundle/lib/common.sh:96:    elif [[ "$line" =~ [A-Za-z0-9+/]{38,}={1,2} ]]; then
experiments/ceph-incident-bundle/lib/common.sh:99:    if [[ $redact -eq 1 ]]; then
experiments/ceph-incident-bundle/lib/common.sh:142:  [[ ${1-} == -- ]] || die "run_capture requires -- before the command"
experiments/ceph-incident-bundle/lib/common.sh:145:  local -a cmd
experiments/ceph-incident-bundle/lib/common.sh:149:  [[ ${#cmd[@]} -gt 0 ]] || die "run_capture requires a command"
experiments/ceph-incident-bundle/lib/common.sh:157:  printf -v command_string '%q ' "${cmd[@]}"
experiments/ceph-incident-bundle/lib/common.sh:162:  if [[ -n "$tbin" ]]; then
experiments/ceph-incident-bundle/lib/common.sh:180:  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
experiments/ceph-incident-bundle/lib/common.sh:188:  if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
experiments/ceph-incident-bundle/lib/common.sh:199:  [[ -e "$source" ]] || return 0
experiments/ceph-incident-bundle/tests/test-node-collector.sh:13:  [[ -f "$file" ]] || fail "missing file: $file"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:39:if [[ ${1-} == "-n" ]]; then
experiments/ceph-incident-bundle/tests/test-node-collector.sh:173:if [[ "$rc" != "0" ]]; then
experiments/ceph-incident-bundle/tests/test-node-collector.sh:174:  [[ -f "$outdir/errors.log" ]] && sed -n '1,120p' "$outdir/errors.log" >&2
experiments/ceph-incident-bundle/tests/test-node-collector.sh:190:  [[ -f "$outdir/$artifact" ]] || fail "missing artifact: $artifact"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:199:[[ -f "$outdir/logs/ceph/ceph.log" ]] || fail "missing copied current ceph log"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:200:[[ -f "$outdir/logs/ceph/ceph.log.1" ]] || fail "missing copied rotated ceph log"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:201:[[ -f "$outdir/logs/ceph/ceph-osd.0.log.1" ]] || fail "missing copied rotated osd log"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:202:[[ -f "$outdir/logs/ceph/ceph.log.2.gz" ]] || fail "missing copied gz ceph log"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:204:[[ -f "$outdir/logs/ceph/ceph-too-large.log" ]] || fail "oversized ceph log should be tail-captured"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:206:[[ "$toobig_bytes" -le 128 ]] || fail "oversized ceph log tail should be <= cap (got $toobig_bytes)"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:207:[[ -f "$outdir/logs/ceph/ceph-too-large.log.TRUNCATED" ]] || fail "oversized ceph log missing .TRUNCATED marker"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:210:[[ -f "$outdir/cephadm/var-lib-ceph-configs/fsid/mon.a/config" ]] || fail "missing copied var-lib ceph config"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:211:[[ ! -e "$outdir/cephadm/var-lib-ceph-configs/fsid/mon.a/keyring" ]] || fail "keyring should not be copied from var-lib ceph"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:14:  [[ -f "$file" ]] || fail "missing file: $file"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:51:[[ "$no_kubectl_rc" == "2" ]] || fail "explicit rook with no kubectl should exit 2, got $no_kubectl_rc"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:68:[[ "$allow_skip_rc" == "0" ]] || fail "rook with --allow-skip and no kubectl should exit 0, got $allow_skip_rc"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:83:    [[ "$mode" != "missing-namespace" ]] || exit 1
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:102:    [[ "$mode" == "with-toolbox" ]] || exit 0
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:125:[[ "$missing_ns_rc" == "2" ]] || fail "explicit rook with missing namespace should exit 2, got $missing_ns_rc"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:41:  [[ -f "$file" ]] || fail "missing file: $file"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:47:  [[ -f "$manifest" ]] || fail "missing manifest: $manifest"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:61:  [[ -f "$outdir/cluster/ceph/json/status.json" ]] || fail "missing status json artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:62:  [[ -f "$outdir/cluster/ceph/text/status.txt" ]] || fail "missing status text artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:63:  [[ -f "$outdir/cluster/ceph/text/health-detail.txt" ]] || fail "missing health detail text artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:64:  [[ -f "$outdir/cluster/ceph/text/osd-tree.txt" ]] || fail "missing osd tree text artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:65:  [[ -f "$outdir/cluster/ceph/text/orch-ps.txt" ]] || fail "missing orch ps text artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:66:  [[ -f "$outdir/cluster/ceph/json/crash-ls.json" ]] || fail "missing crash ls artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:67:  [[ -f "$outdir/cluster/ceph/json/crash-info/crash-01.json" ]] || fail "missing first crash info artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:68:  [[ -f "$outdir/cluster/ceph/json/crash-info/crash_02.json" ]] || fail "missing sanitized crash info artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:69:  [[ -f "$outdir/cluster/ceph/json/crash-info/crash_02-2.json" ]] || fail "missing collision-safe crash info artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:70:  [[ -f "$outdir/cluster/ceph/json/crash-info/crash-10.json" ]] || fail "missing tenth crash info artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:71:  [[ ! -f "$outdir/cluster/ceph/json/crash-info/crash-11.json" ]] || fail "collector did not cap crash info at 10"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:81:  [[ "$(read_manifest_count "$manifest")" == "34" ]] || fail "expected 34 manifest entries"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:104:  [[ "$rc" == "2" ]] || fail "expected partial failure exit 2, got $rc"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:105:  [[ -f "$outdir/cluster/ceph/json/osd-perf.json" ]] || fail "missing failed osd perf artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:106:  [[ -f "$outdir/cluster/ceph/json/pg-stat.json" ]] || fail "collector stopped before later artifacts"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:122:  [[ -f "$outdir/cluster/ceph/text/crash-info-skip.txt" ]] || fail "missing crash parse skip artifact"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:124:  [[ ! -d "$outdir/cluster/ceph/json/crash-info" ]] || fail "collector should not create crash info artifacts when parsing fails"
experiments/ceph-incident-bundle/lib/verify-bundle.sh:25:  while IFS= read -r -d '' path; do
experiments/ceph-incident-bundle/lib/verify-bundle.sh:39:  hit="$(grep -rlIE -e '-----BEGIN[ A-Za-z]*PRIVATE KEY-----' -e '^[[:space:]]*key[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{20,}={0,2}' "$root" 2>/dev/null | head -n1 || true)"
experiments/ceph-incident-bundle/lib/verify-bundle.sh:40:  if [[ -n "$hit" ]]; then
experiments/ceph-incident-bundle/lib/verify-bundle.sh:51:    [[ -f "$root/$required" ]] || {
experiments/ceph-incident-bundle/lib/verify-bundle.sh:62:  [[ -n "$cluster_artifact" ]] || {
experiments/ceph-incident-bundle/lib/verify-bundle.sh:68:  [[ -n "$nodes_artifact" ]] || {
experiments/ceph-incident-bundle/lib/verify-bundle.sh:86:  if [[ -d "$bundle" ]]; then
experiments/ceph-incident-bundle/lib/verify-bundle.sh:92:  [[ -f "$bundle" && "$bundle" == *.tar.gz ]] || { verify_fail "expected a directory or .tar.gz bundle: $bundle"; return 1; }
experiments/ceph-incident-bundle/lib/verify-bundle.sh:116:  if [[ $# -ne 1 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:51:  [[ "$entry" == *=* ]] || return 1
experiments/ceph-incident-bundle/run/collect.sh:57:  if [[ "$host" == *@* || -z "$ssh_user" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:66:  [[ "$value" != *"'"* ]] || return 1
experiments/ceph-incident-bundle/run/collect.sh:122:  local -a probe_cmd
experiments/ceph-incident-bundle/run/collect.sh:126:      [[ -n "$seed" && -n "$ssh_key" ]] || return 1
experiments/ceph-incident-bundle/run/collect.sh:136:      if [[ -n "$probe_tbin" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:139:      if [[ -n "$seed" && -n "$ssh_key" ]] && "${probe_cmd[@]}" >/dev/null 2>&1; then
experiments/ceph-incident-bundle/run/collect.sh:158:  local -a ssh_cmd
experiments/ceph-incident-bundle/run/collect.sh:167:  if [[ "$skip_logs" == "1" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:174:  if [[ -n "$tbin" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:188:  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:194:  if [[ -s "$node_tar" ]] && tar -xzf "$node_tar" -C "$node_dir" >/dev/null 2>/dev/null; then
experiments/ceph-incident-bundle/run/collect.sh:197:    if [[ ! -f "$node_dir/manifest.jsonl" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:205:    [[ $rc -ne 0 ]] || rc=2
experiments/ceph-incident-bundle/run/collect.sh:231:  if [[ -n "${CLEANUP_WORKDIR:-}" && -d "$CLEANUP_WORKDIR" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:232:    if [[ "${CLEANUP_KEEP:-0}" -eq 1 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:247:  if [[ $# -eq 0 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:252:  while [[ $# -gt 0 ]]; do
experiments/ceph-incident-bundle/run/collect.sh:305:  [[ "$mode" == "auto" || "$mode" == "cephadm" || "$mode" == "rook" ]] || die "unsupported mode: $mode"
experiments/ceph-incident-bundle/run/collect.sh:306:  [[ -n "$inventory" && -f "$inventory" ]] || die "missing inventory: ${inventory:-<unset>}"
experiments/ceph-incident-bundle/run/collect.sh:307:  [[ -n "$ssh_key" && -f "$ssh_key" ]] || die "missing ssh key: ${ssh_key:-<unset>}"
experiments/ceph-incident-bundle/run/collect.sh:319:  if [[ -n "$seed_override" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:321:  elif [[ -n "$seed_host" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:325:  if [[ -z "$(timeout_cmd)" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:343:  if [[ $cluster_rc -ne 0 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:351:    if [[ "$entry" != *=* ]]; then
experiments/ceph-incident-bundle/run/collect.sh:359:    if [[ -z "$alias" || -z "$host" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:378:  if [[ -n "${COLLECT_TEST_ABORT_AFTER_NODES:-}" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:393:  if [[ $verify_rc -ne 0 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:407:  if [[ $verify_rc -ne 0 ]]; then
experiments/ceph-incident-bundle/tests/test-collect.sh:23:  [[ -n "$bundle" ]] || fail "missing generated bundle in $outdir"
experiments/ceph-incident-bundle/tests/test-collect.sh:43:[[ "$help_status" == "0" ]] || fail "collect.sh --help exited $help_status"
experiments/ceph-incident-bundle/tests/test-collect.sh:44:[[ "$help_output" == *"Usage:"* ]] || fail "collect.sh --help did not print usage"
experiments/ceph-incident-bundle/tests/test-collect.sh:48:[[ "$missing_status" == "1" ]] || fail "missing inventory should exit 1, got $missing_status"
experiments/ceph-incident-bundle/tests/test-collect.sh:95:[[ -n "$alias_name" ]] || {
experiments/ceph-incident-bundle/tests/test-collect.sh:99:if [[ "${FAKE_SSH_BAD_TAR_ALIAS:-}" == "$alias_name" ]]; then
experiments/ceph-incident-bundle/tests/test-collect.sh:112:if [[ "${FAKE_SSH_NO_MANIFEST_ALIAS:-}" != "$alias_name" ]]; then
experiments/ceph-incident-bundle/tests/test-collect.sh:115:if [[ "${FAKE_SSH_PEM_ALIAS:-}" == "$alias_name" ]]; then
experiments/ceph-incident-bundle/tests/test-collect.sh:120:if [[ "${FAKE_SSH_FAIL_ALIAS:-}" == "$alias_name" ]]; then
experiments/ceph-incident-bundle/tests/test-collect.sh:186:[[ "$partial_status" == "2" ]] || fail "one failed host should exit 2, got $partial_status"
experiments/ceph-incident-bundle/tests/test-collect.sh:205:[[ "$bad_tar_status" == "2" ]] || fail "bad node tar should exit 2, got $bad_tar_status"
experiments/ceph-incident-bundle/tests/test-collect.sh:221:[[ "$no_manifest_status" == "2" ]] || fail "truncated node (no manifest) should exit 2, got $no_manifest_status"
experiments/ceph-incident-bundle/tests/test-collect.sh:235:[[ "$abort_status" != "0" ]] || fail "abort hook should make collect.sh exit non-zero"
experiments/ceph-incident-bundle/tests/test-collect.sh:237:[[ "$leftover" == "0" ]] || fail "abort left $leftover tmp workdir(s) behind"
experiments/ceph-incident-bundle/tests/test-collect.sh:249:[[ "$verify_fail_status" == "1" ]] || fail "verify failure should exit 1, got $verify_fail_status"
experiments/ceph-incident-bundle/tests/test-collect.sh:251:[[ "$produced" == "0" ]] || fail "verify failure must not produce a shareable bundle"
experiments/ceph-incident-bundle/tests/test-collect.sh:253:[[ "$kept" == "1" ]] || fail "verify failure should keep the workdir for inspection (found $kept)"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:50:  [[ "$status" == "0" ]] || fail "expected success for $target, got status $status: $output"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:51:  [[ "$output" == "VERIFY PASS: $target" ]] || fail "unexpected pass output: $output"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:61:  [[ "$status" != "0" ]] || fail "expected failure for $target"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:62:  [[ "$output" == *"$expected"* ]] || fail "failure output did not mention '$expected': $output"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:182:[[ "$extra_args_status" != "0" ]] || fail "expected failure for extra args"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:183:[[ "$extra_args_output" == *"Usage:"* ]] || fail "extra args should print usage: $extra_args_output"
experiments/ceph-incident-bundle/tests/test-common.sh:20:  [[ "$got" == 'a\"b\\c' ]] || fail "json_escape returned '$got'"
experiments/ceph-incident-bundle/tests/test-common.sh:35:  [[ "$got" == 'a\"b\\c' ]] || fail "shell-native json_escape failed with '$got'"
experiments/ceph-incident-bundle/tests/test-common.sh:105:  [[ "$rc" != "0" ]] || fail "manifest_add accepted a non-numeric exit code"
experiments/ceph-incident-bundle/tests/test-common.sh:106:  [[ "$output" == *"exit_code"* ]] || fail "manifest_add did not explain the exit_code failure"
experiments/ceph-incident-bundle/tests/test-common.sh:124:  [[ "$(sed -n '1p' "$source_file")" == "safe line" ]] || fail "safe line was modified"
experiments/ceph-incident-bundle/tests/test-common.sh:126:    [[ "$(sed -n "${i}p" "$source_file")" == "[REDACTED]" ]] || fail "line $i was not redacted"
experiments/ceph-incident-bundle/tests/test-common.sh:129:  [[ -s "$redaction_log" ]] || fail "redaction log is empty"
experiments/ceph-incident-bundle/tests/test-common.sh:146:  [[ "$(sed -n '1p' "$source_file")" == "plain" ]] || fail "plain line was modified"
experiments/ceph-incident-bundle/tests/test-common.sh:148:    [[ "$(sed -n "${i}p" "$source_file")" == "[REDACTED]" ]] || fail "private key marker on line $i was not redacted"
experiments/ceph-incident-bundle/tests/test-common.sh:167:  [[ "$(sed -n '1p' "$source_file")" == "prefix safe" ]] || fail "pem prefix modified"
experiments/ceph-incident-bundle/tests/test-common.sh:169:    [[ "$(sed -n "${i}p" "$source_file")" == "[REDACTED]" ]] || fail "pem body line $i not redacted"
experiments/ceph-incident-bundle/tests/test-common.sh:171:  [[ "$(sed -n '6p' "$source_file")" == "suffix safe" ]] || fail "pem suffix modified"
experiments/ceph-incident-bundle/tests/test-common.sh:187:  [[ "$(sed -n '1p' "$source_file")" == "[client.admin]" ]] || fail "section header modified"
experiments/ceph-incident-bundle/tests/test-common.sh:188:  [[ "$(sed -n '2p' "$source_file")" == "[REDACTED]" ]] || fail "ceph 'key =' line not redacted"
experiments/ceph-incident-bundle/tests/test-common.sh:189:  [[ "$(sed -n '3p' "$source_file")" == "[REDACTED]" ]] || fail "base64 key blob not redacted"
experiments/ceph-incident-bundle/tests/test-common.sh:190:  [[ "$(sed -n '4p' "$source_file")" == "just a normal sentence with words" ]] || fail "normal line over-redacted"
experiments/ceph-incident-bundle/tests/test-common.sh:203:  [[ "$got" == "640" ]] || fail "redaction did not preserve file mode (got $got)"
experiments/ceph-incident-bundle/tests/test-common.sh:219:  [[ "$decoded" == *"normal rotated line"* ]] || fail "gz lost normal content"
experiments/ceph-incident-bundle/tests/test-common.sh:220:  [[ "$decoded" == *"[REDACTED]"* ]] || fail "gz secret not redacted"
experiments/ceph-incident-bundle/tests/test-common.sh:221:  [[ "$decoded" != *"AQBsecretkeymaterial"* ]] || fail "gz secret leaked"
experiments/ceph-incident-bundle/tests/test-common.sh:230:  [[ "$(sed -n '1p' "$artifact")" == "# host: host-a" ]] || fail "artifact header missing host"
experiments/ceph-incident-bundle/tests/test-common.sh:255:  [[ "$rc" == "7" ]] || fail "run_capture returned $rc instead of 7"
experiments/ceph-incident-bundle/tests/test-common.sh:287:  [[ "$rc" != "0" ]] || fail "run_capture accepted missing --"
experiments/ceph-incident-bundle/tests/test-common.sh:288:  [[ "$output" == *"-- before the command"* ]] || fail "missing -- failure was not explained"
experiments/ceph-incident-bundle/tests/test-common.sh:322:  [[ -f "$cwd/-leading-dash.txt" ]] || fail "leading-dash artifact was not created"
experiments/ceph-incident-bundle/tests/test-common.sh:338:  [[ "$status" == "1" ]] || fail "run_capture changed errexit state"
experiments/ceph-incident-bundle/tests/run-tests.sh:30:  [[ -f "$path" ]] || fail "missing $path"
experiments/ceph-incident-bundle/tests/run-tests.sh:34:  [[ -x "$path" ]] || fail "not executable $path"
experiments/ceph-incident-bundle/tests/run-tests.sh:40:[[ "$collect_no_args_status" == "1" ]] || fail "collect.sh no args should exit 1, got $collect_no_args_status"
experiments/ceph-incident-bundle/tests/run-tests.sh:41:[[ "$collect_no_args_output" == *"Usage:"* ]] || fail "collect.sh no args should print usage"
experiments/ceph-incident-bundle/tests/run-tests.sh:46:[[ "$verify_no_args_status" == "1" ]] || fail "verify-bundle.sh no args should exit 1, got $verify_no_args_status"
experiments/ceph-incident-bundle/tests/run-tests.sh:47:[[ "$verify_no_args_output" == *"Usage:"* ]] || fail "verify-bundle.sh no args should print usage"
experiments/ceph-incident-bundle/tests/run-tests.sh:52:[[ "$verify_placeholder_status" != "0" ]] || fail "verify-bundle.sh placeholder args should not exit 0"
experiments/ceph-incident-bundle/tests/run-tests.sh:53:[[ "$verify_placeholder_output" == *"VERIFY FAIL:"* || "$verify_placeholder_output" == *"Usage:"* || "$verify_placeholder_output" == *"error"* ]] || fail "verify-bundle.sh placeholder args should explain failure"
experiments/ceph-incident-bundle/tests/run-tests.sh:58:[[ "$collect_placeholder_status" != "0" ]] || fail "collect.sh placeholder args should not exit 0"
experiments/ceph-incident-bundle/tests/run-tests.sh:59:[[ "$collect_placeholder_output" == *"missing inventory"* || "$collect_placeholder_output" == *"Usage:"* || "$collect_placeholder_output" == *"error"* ]] || fail "collect.sh placeholder args should explain failure"
experiments/ceph-incident-bundle/tests/run-tests.sh:64:[[ "$common_helpers_status" == "0" ]] || fail "test-common.sh failed: $common_helpers_output"
experiments/ceph-incident-bundle/tests/run-tests.sh:69:[[ "$verify_bundle_status" == "0" ]] || fail "test-verify-bundle.sh failed: $verify_bundle_output"
experiments/ceph-incident-bundle/tests/run-tests.sh:74:[[ "$cephadm_collector_status" == "0" ]] || fail "test-cephadm-collector.sh failed: $cephadm_collector_output"
experiments/ceph-incident-bundle/tests/run-tests.sh:79:[[ "$node_collector_status" == "0" ]] || fail "test-node-collector.sh failed: $node_collector_output"
experiments/ceph-incident-bundle/tests/run-tests.sh:84:[[ "$rook_collector_status" == "0" ]] || fail "test-rook-collector.sh failed: $rook_collector_output"
experiments/ceph-incident-bundle/tests/run-tests.sh:89:[[ "$collect_status" == "0" ]] || fail "test-collect.sh failed: $collect_output"
experiments/ceph-incident-bundle/tests/fixtures/bin/ssh:8:if [[ -n "$log_file" ]]; then
experiments/ceph-incident-bundle/tests/fixtures/bin/ssh:24:  if [[ -n "$fail_on" && "$cmd" == *"$needle"* ]]; then
experiments/ceph-incident-bundle/tests/fixtures/bin/ssh:125:    if [[ "$crash_ls_broken" == "1" ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:50:  if [[ $EUID -eq 0 ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:65:  if [[ "$since" =~ ^[0-9]+[smhdw]$ ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:76:  if [[ $EUID -eq 0 ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:92:  if [[ $EUID -eq 0 || -r "$source" ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:100:  [[ "$size" =~ ^[0-9]+$ ]] || return 1
experiments/ceph-incident-bundle/lib/collect-node.sh:108:  if [[ $EUID -eq 0 || -r "$source" ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:128:  if [[ $EUID -eq 0 || -r "$source" ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:148:    [[ -r "$source" ]] || continue
experiments/ceph-incident-bundle/lib/collect-node.sh:159:  if [[ -d "$log_dir" ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:185:  [[ -d "$log_dir" ]] || return 0
experiments/ceph-incident-bundle/lib/collect-node.sh:188:  while IFS= read -r -d '' source; do
experiments/ceph-incident-bundle/lib/collect-node.sh:199:    elif [[ "$source" == *.gz ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:218:  [[ $failed -eq 0 ]] || return 2
experiments/ceph-incident-bundle/lib/collect-node.sh:228:  if [[ -d "$ceph_dir" ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:254:  while IFS= read -r -d '' source; do
experiments/ceph-incident-bundle/lib/collect-node.sh:264:  [[ $failed -eq 0 ]] || return 2
experiments/ceph-incident-bundle/lib/collect-node.sh:270:  while [[ $# -gt 0 ]]; do
experiments/ceph-incident-bundle/lib/collect-node.sh:303:  [[ -n "$outdir" && -n "$host_alias" ]] || {
experiments/ceph-incident-bundle/lib/collect-node.sh:317:  if [[ "$heavy_timeout" =~ ^[0-9]+$ ]] && (( heavy_timeout < 120 )); then
experiments/ceph-incident-bundle/lib/collect-node.sh:321:  local -a basic_specs=(
experiments/ceph-incident-bundle/lib/collect-node.sh:332:  local -a command_words
experiments/ceph-incident-bundle/lib/collect-node.sh:392:  if [[ $skip_logs -eq 1 ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:403:  if [[ $failed -ne 0 ]]; then
experiments/ceph-incident-bundle/lib/collect-node.sh:409:if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:44:  [[ -f "$crash_ls_artifact" ]] || return 1
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:45:  payload="$(sed '/^[[:space:]]*#/d' "$crash_ls_artifact")" || return 1
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:51:      grep -oE '"crash_id"[[:space:]]*:[[:space:]]*"[^"]*"' |
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:52:      sed -E 's/^"crash_id"[[:space:]]*:[[:space:]]*"([^"]*)"$/\1/' |
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:56:  if [[ -n "$ids" ]]; then
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:74:  while [[ "$safe_id" == *..* ]]; do
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:77:  [[ -n "$safe_id" ]] || safe_id="crash"
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:86:  while [[ -e "$artifact" ]]; do
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:106:  [[ -n "$crash_ids" ]] || return 0
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:110:    [[ -n "$crash_id" ]] || continue
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:133:  local -a json_specs=(
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:156:  local -a text_specs=(
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:164:  local -a command_words
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:189:  if [[ $failed -ne 0 ]]; then

exec
/bin/zsh -lc "git diff 8374cf1..HEAD -- experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/common.sh experiments/ceph-incident-bundle/lib/verify-bundle.sh experiments/ceph-incident-bundle/lib/collect-node.sh experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh | sed -n '260,620p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-gExGbFh5' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-vICvsGRZ' (errno=Operation not permitted)
+    fi
+    if [[ $in_pem -eq 1 ]]; then
+      redact=1
+      if [[ "$line" =~ -----END[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
+        in_pem=0
+      fi
+    elif [[ "$line" =~ (password|secret|token|keyring|private([[:space:]_-]+)?key) ]]; then
+      redact=1
+    elif [[ "$line" =~ (^|[^[:alnum:]])key[[:space:]]*[:=] ]]; then
+      redact=1
+    elif [[ "$line" =~ [A-Za-z0-9+/]{38,}={1,2} ]]; then
+      redact=1
+    fi
+    if [[ $redact -eq 1 ]]; then
       printf '[REDACTED]\n' >>"$tmp_file"
       count=$((count + 1))
     else
@@ -74,18 +105,44 @@ redact_file() {
   done <"$source_file"
 
   eval "$nocasematch_state"
-  chmod --reference="$source_file" "$tmp_file" 2>/dev/null || true
+  mode="$(stat -c '%a' "$source_file" 2>/dev/null || stat -f '%Lp' "$source_file" 2>/dev/null || printf '600')"
+  chmod "$mode" "$tmp_file" 2>/dev/null || true
   mv -f -- "$tmp_file" "$source_file"
   printf '%s: %s line(s) redacted\n' "$source_file" "$count" >>"$redaction_log"
 }
 
+redact_gz_file() {
+  # Decompress a gzipped artifact, redact it, recompress in place so rotated
+  # logs (*.gz) get the same redaction as plain text.
+  local source_file=$1 redaction_log=$2
+  require_file "$source_file"
+  ensure_dir "$(dirname -- "$redaction_log")"
+
+  local dir tmp_plain
+  dir="$(dirname -- "$source_file")"
+  tmp_plain="$(mktemp "$dir/.${source_file##*/}.plain.XXXXXX")"
+  if ! gzip -dc -- "$source_file" >"$tmp_plain" 2>/dev/null; then
+    rm -f -- "$tmp_plain"
+    printf '%s: gz decompress failed, left as-is (NOT redacted)\n' "$source_file" >>"$redaction_log"
+    return 0
+  fi
+
+  redact_file "$tmp_plain" "$redaction_log"
+  if gzip -c -- "$tmp_plain" >"$source_file"; then
+    rm -f -- "$tmp_plain"
+  else
+    rm -f -- "$tmp_plain"
+    return 1
+  fi
+}
+
 run_capture() {
   local manifest=$1 host=$2 collector=$3 artifact=$4
   shift 4
   [[ ${1-} == -- ]] || die "run_capture requires -- before the command"
   shift
 
-  local -a cmd timeout_cmd
+  local -a cmd
   local started ended rc command_string artifact_dir artifact_tmp
 
   cmd=("$@")
@@ -100,9 +157,11 @@ run_capture() {
   printf -v command_string '%q ' "${cmd[@]}"
   command_string=${command_string% }
 
-  if command -v timeout >/dev/null 2>&1; then
+  local tbin
+  tbin="$(timeout_cmd)"
+  if [[ -n "$tbin" ]]; then
     printf '# timeout: %ss\n' "${COMMAND_TIMEOUT:-20}" >>"$artifact_tmp"
-    if timeout "${COMMAND_TIMEOUT:-20}" "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
+    if "$tbin" "${COMMAND_TIMEOUT:-20}" "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
       rc=0
     else
       rc=$?
@@ -116,6 +175,12 @@ run_capture() {
     fi
   fi
 
+  # Make timeout-kills (124) distinguishable from ordinary command failure, and
+  # mark the artifact so a truncated capture is visible to whoever reads it.
+  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
+    printf '# TRUNCATED: command timed out after %ss (exit %s)\n' "${COMMAND_TIMEOUT:-20}" "$rc" >>"$artifact_tmp"
+  fi
+
   ended="$(date -u +%FT%TZ)"
   mv -f -- "$artifact_tmp" "$artifact"
   manifest_add "$manifest" "$host" "$collector" "$artifact" "$command_string" "$rc" "$started" "$ended"
diff --git a/experiments/ceph-incident-bundle/lib/verify-bundle.sh b/experiments/ceph-incident-bundle/lib/verify-bundle.sh
index 790e08f..f925c9c 100755
--- a/experiments/ceph-incident-bundle/lib/verify-bundle.sh
+++ b/experiments/ceph-incident-bundle/lib/verify-bundle.sh
@@ -20,14 +20,27 @@ verify_fail() {
 verify_members() {
   local root=$1 path
 
-  while IFS= read -r path; do
+  # -print0 so newlines in filenames cannot smuggle a forbidden component
+  # past the glob (this is a security boundary).
+  while IFS= read -r -d '' path; do
     case "$path" in
-      *keyring*|*.ssh*|*id_ed25519*|*private_key*)
+      *keyring*|*.ssh*|*id_ed25519*|*private_key*|*.pem|*.key|*.crt|*.pfx|*.p12)
         verify_fail "forbidden path: ${path#./}"
         return 1
         ;;
     esac
-  done < <(cd "$root" && find . -mindepth 1 -print)
+  done < <(cd "$root" && find . -mindepth 1 -print0)
+}
+
+verify_no_secret_content() {
+  # Defense-in-depth: even if redaction missed something, refuse to bless a
+  # bundle whose files still contain obvious unredacted key material.
+  local root=$1 hit
+  hit="$(grep -rlIE -e '-----BEGIN[ A-Za-z]*PRIVATE KEY-----' -e '^[[:space:]]*key[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{20,}={0,2}' "$root" 2>/dev/null | head -n1 || true)"
+  if [[ -n "$hit" ]]; then
+    verify_fail "unredacted PRIVATE KEY / key material in: ${hit#"$root"/}"
+    return 1
+  fi
 }
 
 verify_required_files() {
@@ -62,6 +75,7 @@ verify_bundle_tree() {
   local root=$1
 
   verify_members "$root" || return 1
+  verify_no_secret_content "$root" || return 1
   verify_required_files "$root" || return 1
   verify_required_artifacts "$root" || return 1
 }
diff --git a/experiments/ceph-incident-bundle/run/collect.sh b/experiments/ceph-incident-bundle/run/collect.sh
index 6d2ed85..bf42c7f 100755
--- a/experiments/ceph-incident-bundle/run/collect.sh
+++ b/experiments/ceph-incident-bundle/run/collect.sh
@@ -32,7 +32,8 @@ Options:
   --out DIR              output dir (default: experiments/ceph-incident-bundle/results)
   --mode auto|cephadm|rook
   --since DURATION       log/journal window (default: 24h)
-  --timeout SECONDS      per command/SSH timeout (default: 20)
+  --timeout SECONDS      per-command / SSH-connect timeout (default: 20)
+  --node-timeout SECONDS overall timeout for one node's full collection (default: 600)
   --skip-logs            collect state but skip larger Ceph log copies
   --keep-workdir         keep temporary extracted workdir for debugging
   --help                 print this help
@@ -129,14 +130,17 @@ run_cluster_collector() {
       collect_cluster_rook --out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout"
       ;;
     auto)
+      local probe_tbin
       probe_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$seed" command -v cephadm)
-      if command -v timeout >/dev/null 2>&1; then
-        probe_cmd=(timeout "$timeout" "${probe_cmd[@]}")
+      probe_tbin="$(timeout_cmd)"
+      if [[ -n "$probe_tbin" ]]; then
+        probe_cmd=("$probe_tbin" "$timeout" "${probe_cmd[@]}")
       fi
       if [[ -n "$seed" && -n "$ssh_key" ]] && "${probe_cmd[@]}" >/dev/null 2>&1; then
         collect_cluster_cephadm "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout"
       else
-        collect_cluster_rook --out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout"
+        # auto-fallback is a guess; tolerate a non-rook cluster gracefully
+        collect_cluster_rook --out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout" --allow-skip
       fi
       ;;
     *)
@@ -146,10 +150,10 @@ run_cluster_collector() {
 }
 
 collect_remote_node() {
-  local workdir=$1 alias=$2 target=$3 ssh_key=$4 since=$5 timeout=$6 skip_logs=$7
+  local workdir=$1 alias=$2 target=$3 ssh_key=$4 since=$5 timeout=$6 skip_logs=$7 node_timeout=$8
   local node_dir="$workdir/nodes/$alias"
   local node_tar="$workdir/.node-$alias.tar.gz"
-  local remote_cmd rc=0
+  local remote_cmd rc=0 tbin
   local q_alias q_since q_timeout
   local -a ssh_cmd
 
@@ -157,33 +161,48 @@ collect_remote_node() {
   q_since="$(shell_quote "$since")" || return 1
   q_timeout="$(shell_quote "$timeout")" || return 1
 
-  remote_cmd="set -u; tmp=\"\${TMPDIR:-/tmp}/ceph-incident-node.\$\$\"; rm -rf \"\$tmp\"; mkdir -p \"\$tmp\"; tar -xzf - -C \"\$tmp\"; out=\"\$tmp/out\"; set +e; bash \"\$tmp/lib/collect-node.sh\" --out \"\$out\" --host-alias $q_alias --since $q_since --timeout $q_timeout"
+  # Remote side uses a gzip pipe (not `tar -z`) so minimal/BusyBox tar still works,
+  # and traps its own temp dir so an interrupted/timed-out run leaves nothing behind.
+  remote_cmd="set -u; tmp=\"\${TMPDIR:-/tmp}/ceph-incident-node.\$\$\"; rm -rf \"\$tmp\"; mkdir -p \"\$tmp\" || { printf 'SKIPPED: remote tmp not writable\n' >&2; exit 75; }; trap 'rm -rf \"\$tmp\"' EXIT INT TERM; gzip -dc | tar -xf - -C \"\$tmp\"; out=\"\$tmp/out\"; set +e; bash \"\$tmp/lib/collect-node.sh\" --out \"\$out\" --host-alias $q_alias --since $q_since --timeout $q_timeout"
   if [[ "$skip_logs" == "1" ]]; then
     remote_cmd+=" --skip-logs"
   fi
-  remote_cmd+="; rc=\$?; set -e; if [ -d \"\$out\" ]; then tar -czf - -C \"\$out\" .; else mkdir -p \"\$out\"; printf 'SKIPPED: remote collect-node did not create output\n' >\"\$out/SKIPPED.txt\"; tar -czf - -C \"\$out\" .; fi; rm -rf \"\$tmp\"; exit \"\$rc\""
+  remote_cmd+="; rc=\$?; set -e; if [ -d \"\$out\" ]; then tar -cf - -C \"\$out\" . | gzip -c; else mkdir -p \"\$out\"; printf 'SKIPPED: remote collect-node did not create output\n' >\"\$out/SKIPPED.txt\"; tar -cf - -C \"\$out\" . | gzip -c; fi; exit \"\$rc\""
 
   ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" "$remote_cmd")
-  if command -v timeout >/dev/null 2>&1; then
-    ssh_cmd=(timeout "$timeout" "${ssh_cmd[@]}")
+  tbin="$(timeout_cmd)"
+  if [[ -n "$tbin" ]]; then
+    # Outer wrapper bounds the WHOLE node collection — must be the generous
+    # node timeout, never the small per-command timeout (which would kill a
+    # slow/large node mid-collection).
+    ssh_cmd=("$tbin" "$node_timeout" "${ssh_cmd[@]}")
   fi
 
   set +e
-  COPYFILE_DISABLE=1 tar -czf - -C "$COLLECT_ROOT" lib/common.sh lib/collect-node.sh |
+  COPYFILE_DISABLE=1 tar -cf - -C "$COLLECT_ROOT" lib/common.sh lib/collect-node.sh | gzip -c |
     "${ssh_cmd[@]}" >"$node_tar"
   rc=$?
   set -e
 
   ensure_dir "$node_dir"
-  if [[ -s "$node_tar" ]]; then
-    if ! tar -xzf "$node_tar" -C "$node_dir" >/dev/null 2>/dev/null; then
-      rm -rf "$node_dir"
-      ensure_dir "$node_dir"
-      printf 'SKIPPED: invalid node archive returned from %s\n' "$target" >"$node_dir/SKIPPED.txt"
+  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
+    printf 'SKIPPED: node collection timed out after %ss (exit %s) from %s\n' "$node_timeout" "$rc" "$target" >"$node_dir/SKIPPED.txt"
+    rm -f "$node_tar"
+    return 2
+  fi
+
+  if [[ -s "$node_tar" ]] && tar -xzf "$node_tar" -C "$node_dir" >/dev/null 2>/dev/null; then
+    # A node that streamed a valid archive but is missing its own manifest.jsonl
+    # was truncated (partial/interrupted transfer) — do not count it as ok.
+    if [[ ! -f "$node_dir/manifest.jsonl" ]]; then
+      printf 'SKIPPED: node archive from %s is incomplete (no manifest.jsonl); treated as failure\n' "$target" >"$node_dir/SKIPPED.txt"
       rc=2
     fi
   else
-    printf 'SKIPPED: no node archive returned from %s\n' "$target" >"$node_dir/SKIPPED.txt"
+    rm -rf "$node_dir"
+    ensure_dir "$node_dir"
+    printf 'SKIPPED: no usable node archive returned from %s (ssh exit %s)\n' "$target" "$rc" >"$node_dir/SKIPPED.txt"
+    [[ $rc -ne 0 ]] || rc=2
   fi
   rm -f "$node_tar"
 
@@ -191,18 +210,38 @@ collect_remote_node() {
 }
 
 redact_bundle_text() {
-  local workdir=$1 redaction_log="$workdir/redactions.log"
+  local workdir=$1
+  local redaction_log="$workdir/redactions.log"
   local path
 
   while IFS= read -r path; do
-    redact_file "$path" "$redaction_log"
-  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' \) -print 2>/dev/null || true)
+    case "$path" in
+      *.gz) redact_gz_file "$path" "$redaction_log" ;;
+      *) redact_file "$path" "$redaction_log" ;;
+    esac
+  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' -o -name '*.gz' \) -print 2>/dev/null || true)
+}
+
+# Single cleanup point. Uses globals (not main's locals) so it works as an
+# EXIT trap, which fires after main has returned and its locals are gone.
+CLEANUP_WORKDIR=
+CLEANUP_KEEP=0
+cleanup_workdir() {
+  local rc=$?
+  if [[ -n "${CLEANUP_WORKDIR:-}" && -d "$CLEANUP_WORKDIR" ]]; then
+    if [[ "${CLEANUP_KEEP:-0}" -eq 1 ]]; then
+      printf 'kept workdir: %s\n' "$CLEANUP_WORKDIR" >&2
+    else
+      rm -rf -- "$CLEANUP_WORKDIR"
+    fi
+  fi
+  return "$rc"
 }
 
 main() {
-  local inventory= ssh_key= seed_override= out_dir="$COLLECT_ROOT/results"
-  local mode=auto since=24h timeout=20 skip_logs=0 keep_workdir=0
-  local seed= ssh_user= seed_host= rook_namespace=rook-ceph
+  local inventory='' ssh_key='' seed_override='' out_dir="$COLLECT_ROOT/results"
+  local mode=auto since=24h timeout=20 node_timeout=600 skip_logs=0 keep_workdir=0
+  local seed='' ssh_user='' seed_host='' rook_namespace=rook-ceph
   local timestamp workdir manifest bundle rc=0 cluster_rc=0 node_ok=0 node_failed=0
 
   if [[ $# -eq 0 ]]; then
@@ -240,6 +279,10 @@ main() {
         timeout=${2-}
         shift 2
         ;;
+      --node-timeout)
+        node_timeout=${2-}
+        shift 2
+        ;;
       --skip-logs)
         skip_logs=1
         shift
@@ -279,11 +322,18 @@ main() {
     seed="$(ssh_target_for_host "$seed_host" "$ssh_user")"
   fi
 
+  if [[ -z "$(timeout_cmd)" ]]; then
+    log "WARNING: no 'timeout'/'gtimeout' found on this workstation; outer timeouts are disabled — relying on SSH ConnectTimeout/ServerAlive only (install coreutils for full bounding)"
+  fi
+
   ensure_dir "$out_dir"
   timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
   workdir="$out_dir/tmp.$timestamp.$$"
   manifest="$workdir/manifest.jsonl"
   ensure_dir "$workdir"
+  CLEANUP_WORKDIR="$workdir"
+  CLEANUP_KEEP=$keep_workdir
+  trap cleanup_workdir EXIT INT TERM
   write_initial_metadata "$workdir" "$mode" "$seed" "$since" "$timeout"
 
   set +e
@@ -297,11 +347,24 @@ main() {
 
   local entry alias host target node_rc
   for entry in "${HOSTS[@]}"; do
-    alias="$(parse_host_entry "$entry" | sed -n '1p')" || die "invalid HOSTS entry: $entry"
-    host="$(parse_host_entry "$entry" | sed -n '2p')" || die "invalid HOSTS entry: $entry"
+    # Robust parse: a malformed entry must not abort an in-progress collection.
+    if [[ "$entry" != *=* ]]; then
+      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
+      node_failed=$((node_failed + 1))
+      rc=2
+      continue
+    fi
+    alias="${entry%%=*}"
+    host="${entry#*=}"
+    if [[ -z "$alias" || -z "$host" ]]; then
+      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
+      node_failed=$((node_failed + 1))
+      rc=2
+      continue
+    fi
     target="$(ssh_target_for_host "$host" "$ssh_user")"
 
-    if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs"; then
+    if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs" "$node_timeout"; then
       node_ok=$((node_ok + 1))
     else
       node_rc=$?
@@ -311,19 +374,41 @@ main() {
     fi
   done
 
+  # Test-only hook: simulate a mid-run abort to exercise trap cleanup. Inert in production.
+  if [[ -n "${COLLECT_TEST_ABORT_AFTER_NODES:-}" ]]; then
+    die "test abort after nodes"
+  fi
+
   redact_bundle_text "$workdir"
   write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "$rc"
 
-  "$COLLECT_ROOT/lib/verify-bundle.sh" "$workdir" >/dev/null
+  # Verify BEFORE packaging, but never let verification destroy collected
+  # evidence: capture its result instead of aborting under set -e. On failure,
+  # keep the workdir for inspection and do not produce a shareable bundle.

exec
/bin/zsh -lc 'bash experiments/ceph-incident-bundle/tests/run-tests.sh' in /Users/ikaros/Documents/code/learning-k8s
 exited 1 in 0ms:
FAIL: collect.sh no args should print usage

codex
Running `tests/run-tests.sh` on this shell fails early at the harness’ “no args should print usage” check, before it reaches the hardened scenarios. I’m checking whether that is a new product regression or just a brittle test assertion, then I’ll keep findings scoped to the tool behavior.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/run-tests.sh | sed -n '1,130p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
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
/bin/zsh -lc 'set +e; out="$(bash experiments/ceph-incident-bundle/run/collect.sh 2>&1)"; st=$?; printf '"'status=<%s>\\noutput=<%s>\\n' \""'$st" "$out"' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
status=<1>
output=<experiments/ceph-incident-bundle/run/collect.sh: line 16: cannot create temp file for here document: Operation not permitted>

exec
/bin/zsh -lc "grep -rlIE -e '-----BEGIN[ A-Za-z]*PRIVATE KEY-----' -e '"'^[[:space:]]*key[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{20,}={0,2}'"' experiments/ceph-incident-bundle/tests/fixtures 2>&1 | sed -n '1,20p'; printf 'rc=%s\\n' "'$?' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
rc=0

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/collect-node.sh | sed -n '360,430p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
   360	    failed=1
   361	  fi
   362	  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "time/ntpq-peers.txt" ntpq -pn; then
   363	    failed=1
   364	  fi
   365	  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "storage/pvs.txt" pvs --noheadings --separator ' '; then
   366	    failed=1
   367	  fi
   368	  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "storage/vgs.txt" vgs --noheadings --separator ' '; then
   369	    failed=1
   370	  fi
   371	  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "storage/lvs.txt" lvs --noheadings --separator ' '; then
   372	    failed=1
   373	  fi
   374	  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "containers/podman-ps.txt" podman ps -a; then
   375	    failed=1
   376	  fi
   377	  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$timeout" "containers/docker-ps.txt" docker ps -a; then
   378	    failed=1
   379	  fi
   380	
   381	  if command -v cephadm >/dev/null 2>&1; then
   382	    node_run_privileged "$outdir" "$manifest" "$host_alias" "$timeout" "cephadm/cephadm-ls.json" cephadm ls --format json-pretty || true
   383	  else
   384	    write_skip_artifact "$outdir/cephadm/cephadm-ls.json" "command not found: cephadm"
   385	  fi
   386	
   387	  copy_readable_etc_files "$outdir"
   388	  if ! collect_var_lib_ceph "$outdir" "$manifest" "$host_alias" "$timeout"; then
   389	    failed=1
   390	  fi
   391	
   392	  if [[ $skip_logs -eq 1 ]]; then
   393	    write_skip_artifact "$outdir/logs/ceph-log-listing.txt" "log collection disabled by --skip-logs"
   394	  else
   395	    if ! collect_ceph_log_listing "$outdir" "$manifest" "$host_alias" "$timeout"; then
   396	      failed=1
   397	    fi
   398	    if ! copy_ceph_logs "$outdir"; then
   399	      failed=1
   400	    fi
   401	  fi
   402	
   403	  if [[ $failed -ne 0 ]]; then
   404	    return 2
   405	  fi
   406	  return 0
   407	}
   408	
   409	if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
   410	  collect_node_main "$@"
   411	fi

exec
/bin/zsh -lc "grep --version 2>&1 | sed -n '1,3p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
grep (BSD grep, GNU compatible) 2.6.0-FreeBSD

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/tests/test-rook-collector.sh | sed -n '1,180p'" in /Users/ikaros/Documents/code/learning-k8s
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
    78	mode=${FAKE_KUBECTL_MODE:-present}
    79	cmd="$*"
    80	
    81	case "$cmd" in
    82	  "get namespace rook-ceph")
    83	    [[ "$mode" != "missing-namespace" ]] || exit 1
    84	    printf 'rook-ceph\n'
    85	    ;;
    86	  "get pods -n rook-ceph -o wide")
    87	    printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n'
    88	    ;;
    89	  "get events -n rook-ceph --sort-by=.lastTimestamp")
    90	    printf 'LAST SEEN TYPE REASON OBJECT MESSAGE\n1m Normal Started pod/osd started\n'
    91	    ;;
    92	  "get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n rook-ceph -o yaml")
    93	    printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n  metadata:\n    name: rook-ceph\n'
    94	    ;;
    95	  "get pods -n rook-ceph -l app=rook-ceph-operator -o jsonpath={.items[0].metadata.name}")
    96	    printf 'rook-ceph-operator-0'
    97	    ;;
    98	  "logs -n rook-ceph rook-ceph-operator-0 --since=24h")
    99	    printf 'operator log line\n'
   100	    ;;
   101	  "get pods -n rook-ceph -l app=rook-ceph-tools -o jsonpath={.items[0].metadata.name}")
   102	    [[ "$mode" == "with-toolbox" ]] || exit 0
   103	    printf 'rook-ceph-tools-0'
   104	    ;;
   105	  "exec -n rook-ceph rook-ceph-tools-0 -- ceph status")
   106	    printf 'cluster is healthy from toolbox\n'
   107	    ;;
   108	  *)
   109	    printf 'unexpected kubectl command: %s\n' "$cmd" >&2
   110	    exit 99
   111	    ;;
   112	esac
   113	EOF
   114	chmod +x "$fakebin/kubectl"
   115	
   116	export FAKE_KUBECTL_LOG="$tmpdir/kubectl.log"
   117	
   118	out_missing_ns="$tmpdir/out-missing-ns"
   119	manifest_missing_ns="$tmpdir/manifest-missing-ns.jsonl"
   120	missing_ns_rc=0
   121	set +e
   122	FAKE_KUBECTL_MODE=missing-namespace PATH="$fakebin:$PATH" run_rook_collector "$out_missing_ns" "$manifest_missing_ns"
   123	missing_ns_rc=$?
   124	set -e
   125	[[ "$missing_ns_rc" == "2" ]] || fail "explicit rook with missing namespace should exit 2, got $missing_ns_rc"
   126	assert_file_contains "$out_missing_ns/cluster/rook/SKIPPED.txt" "namespace not found: rook-ceph"
   127	
   128	out_present="$tmpdir/out-present"
   129	manifest_present="$tmpdir/manifest-present.jsonl"
   130	FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" run_rook_collector "$out_present" "$manifest_present"
   131	
   132	assert_file_contains "$out_present/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
   133	assert_file_contains "$out_present/cluster/rook/events.txt" "osd started"
   134	assert_file_contains "$out_present/cluster/rook/rook-resources.yaml" "kind: CephCluster"
   135	assert_file_contains "$out_present/cluster/rook/operator.log" "operator log line"
   136	assert_file_contains "$out_present/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
   137	
   138	grep -qF 'get namespace rook-ceph' "$FAKE_KUBECTL_LOG" || fail "namespace detection was not called"
   139	grep -qF 'logs -n rook-ceph rook-ceph-operator-0 --since=24h' "$FAKE_KUBECTL_LOG" || fail "operator logs were not collected"

exec
/bin/zsh -lc "bash -c 'set -- a b c; printf \"<%s>\\n\" \""'${@: -1}"'"'; printf 'rc=%s\\n' "'$?' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
<c>
rc=0

exec
/bin/zsh -lc "bash -n experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/common.sh experiments/ceph-incident-bundle/lib/verify-bundle.sh experiments/ceph-incident-bundle/lib/collect-node.sh experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh experiments/ceph-incident-bundle/tests/test-collect.sh; printf 'rc=%s\\n' "'$?' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
rc=0

exec
/bin/zsh -lc "rg -n \"\\"'$'"\\{@: -|\\"'$'"\\{@:|read -r -d|printf -v|local -a|process substitution|< <\\(\" experiments/ceph-incident-bundle/run experiments/ceph-incident-bundle/lib experiments/ceph-incident-bundle/tests" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/lib/verify-bundle.sh:25:  while IFS= read -r -d '' path; do
experiments/ceph-incident-bundle/lib/verify-bundle.sh:32:  done < <(cd "$root" && find . -mindepth 1 -print0)
experiments/ceph-incident-bundle/run/collect.sh:122:  local -a probe_cmd
experiments/ceph-incident-bundle/run/collect.sh:158:  local -a ssh_cmd
experiments/ceph-incident-bundle/run/collect.sh:222:  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' -o -name '*.gz' \) -print 2>/dev/null || true)
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:133:  local -a json_specs=(
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:156:  local -a text_specs=(
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:164:  local -a command_words
experiments/ceph-incident-bundle/lib/common.sh:145:  local -a cmd
experiments/ceph-incident-bundle/lib/common.sh:157:  printf -v command_string '%q ' "${cmd[@]}"
experiments/ceph-incident-bundle/lib/collect-node.sh:188:  while IFS= read -r -d '' source; do
experiments/ceph-incident-bundle/lib/collect-node.sh:216:  done < <(node_find0 "$log_dir" -maxdepth 2 -type f \( -name '*.log' -o -name '*.log.*' -o -name '*.txt' -o -name '*.gz' \) -print0 2>/dev/null || true)
experiments/ceph-incident-bundle/lib/collect-node.sh:254:  while IFS= read -r -d '' source; do
experiments/ceph-incident-bundle/lib/collect-node.sh:260:  done < <(node_find0 "$ceph_dir" -maxdepth 4 \
experiments/ceph-incident-bundle/lib/collect-node.sh:321:  local -a basic_specs=(
experiments/ceph-incident-bundle/lib/collect-node.sh:332:  local -a command_words

codex
No product-side bash 3.2 syntax issue has shown up: the scripts parse under the local Bash 3.2, and the Bash features in use are supported there. The full tests cannot run in this read-only sandbox because `mktemp`/here-doc temp creation is blocked, so I’m separating sandbox failures from script regressions.
codex
No real regressions found.

SUCCESS cleanup: none. EXIT trap deletes only `tmp.*` workdir; produced bundle is outside it, and `--keep-workdir`/verify-fail paths preserve workdir.

`verify_no_secret_content`: no normal redacted-bundle false positive found.

Remote `gzip | tar`: receiving side still extracts correctly.

Bash 3.2: no product-script incompatibility found.

Redaction evidence loss: no new over-redaction severe enough to destroy incident value found.

Exit-code contract: still consistent: `0` complete, `2` partial bundle produced, `1` usage/config/verify failure.

Note: full tests could not run in this read-only sandbox because `mktemp`/shell temp creation is blocked, so this is source review plus parse/probe only.


tokens used
88,622
No real regressions found.

SUCCESS cleanup: none. EXIT trap deletes only `tmp.*` workdir; produced bundle is outside it, and `--keep-workdir`/verify-fail paths preserve workdir.

`verify_no_secret_content`: no normal redacted-bundle false positive found.

Remote `gzip | tar`: receiving side still extracts correctly.

Bash 3.2: no product-script incompatibility found.

Redaction evidence loss: no new over-redaction severe enough to destroy incident value found.

Exit-code contract: still consistent: `0` complete, `2` partial bundle produced, `1` usage/config/verify failure.

Note: full tests could not run in this read-only sandbox because `mktemp`/shell temp creation is blocked, so this is source review plus parse/probe only.


