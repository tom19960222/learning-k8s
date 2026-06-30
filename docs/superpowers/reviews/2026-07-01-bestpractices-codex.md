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
session id: 019f1948-412d-7d43-a31a-b8ccb0233a9f
--------
user
Review a bash tool for software-design best practices: KISS, DRY, SOLID (applied pragmatically to shell), readability, maintainability, naming, clear function/file boundaries. This is a QUALITY/DESIGN review — correctness is already hardened and lab-validated; focus on structure and craftsmanship (note any real bug you happen to see, but don't hunt).

Files (experiments/ceph-incident-bundle/): run/collect.sh, lib/common.sh, lib/collect-cluster-cephadm.sh, lib/collect-cluster-rook.sh, lib/collect-node.sh, lib/verify-bundle.sh, tests/*.sh, README.md.

Constraints (NOT smells): workstation/jump host runs bash 3.2 (no mapfile/namerefs; empty-array-under-set-u guards are deliberate), may lack a `timeout` binary; tool is strictly read-only; a strong test suite (tests/run-tests.sh) exists and shellcheck is at 0 — any refactor must keep both green and not change observable behavior (exit codes 0/2/1, bundle layout, stdout = only `bundle:`).

Evaluate specifically:
- DRY: duplicated ssh option lists across functions/files; repeated skip-artifact writers; repeated arg-parse blocks. Identify and propose a shared helper.
- KISS: needlessly complex control flow; functions doing too much.
- SRP/boundaries: is run/collect.sh too large / mixed responsibilities? Are the libs cohesive?
- Interface clarity: long positional-arg functions (e.g. collect_clusters takes 11 positional args) vs named options; cross-lib consistency.
- naming, comments, dead code.

Output a SEVERITY-ranked list. For EACH: SEVERITY | file:line | problem (which principle) | concrete behavior-preserving fix. Pragmatic for shell — no rewrite-in-another-language, no OO ceremony. Don't modify files.
codex
I’ll use the required superpowers startup skill, then do a lightweight memory pass for this repo/tool before reading the target files. I’ll keep this as a review only and won’t edit anything.
exec
/bin/zsh -lc "sed -n '1,240p' /Users/ikaros/.codex/superpowers/skills/using-superpowers/SKILL.md && rg -n \"ceph-incident-bundle|collect.sh|verify-bundle|systemd-timesyncd|incident bundle\" /Users/ikaros/.codex/memories/MEMORY.md" in /Users/ikaros/Documents/code/learning-k8s
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
33:scope: Building or extending the `ceph-incident-bundle` runnable tooling, operator runbook, and site integration in `learning-k8s`, especially when the user wants a one-command read-only evidence bundle for basic Linux operators and expects reviewer loops plus publish steps.
34:applies_to: cwd=/Users/ikaros/Documents/code/learning-k8s; reuse_rule=safe for similar `ceph-incident-bundle` work in this checkout, but treat lab topology, smoke-bundle contents, and publish state as checkout-specific and revalidate before reuse
36:## Task 1: Build the Ceph incident bundle runbook, scripts, and site integration, then publish
44:- ceph-incident-bundle, collect.sh, verify-bundle.sh, experiments/ceph-incident-bundle, README.md, incident-bundle-runbook.mdx, projects.ts, feature-map.json, quiz.json, code-review, git commit --no-gpg-sign, tar.gz, read-only evidence bundle
48:## Task 2: Add `systemd-timesyncd` evidence to the incident bundle without redesigning it
56:- systemd-timesyncd, timedatectl status, timedatectl show-timesync --all, timedatectl timesync-status, systemctl status systemd-timesyncd, journalctl -u systemd-timesyncd, SKIPPED.txt, FAKE_TIMESYNCD_MISSING, test-node-collector.sh, VERIFY PASS
65:- when the user added "加上考慮 timesync 用 systemd-timesyncd" -> treat `systemd-timesyncd` as a first-class supported time-sync source in similar Linux evidence collectors and docs [Task 2]
71:- The Ceph incident bundle is intentionally read-only: collect cluster state, node state, logs, manifests, and command errors, then package them as a `.tar.gz`; do not restart daemons, repair, scrub, or change cluster flags [Task 1]
72:- In this repo, `make validate` remains a hard gate for content-linked tooling work because it checks MDX, quiz JSON, feature wiring, and Next.js/basePath validation; the bundle itself should also be verified with `bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle>` [Task 1]
74:- The `systemd-timesyncd` extension now collects `timedatectl status`, `timedatectl show-timesync --all`, `timedatectl timesync-status`, `systemctl status systemd-timesyncd`, `journalctl -u systemd-timesyncd`, and `/etc/systemd/timesyncd.conf` plus `/etc/systemd/timesyncd.conf.d/*.conf` [Task 2]
75:- Missing `systemd-timesyncd` or missing config should not fail node collection; the collector emits `SKIPPED.txt` and keeps the node successful unless an actual copy operation fails [Task 2]
76:- The updated docs teach that chrony/ntpq remain supported evidence, while `systemd-timesyncd` is explicitly included for Debian/Ubuntu-style hosts [Task 2]
82:- Symptom: a follow-up evidence-source addition only covers the happy path. Cause: new collector logic was added without a negative fixture. Fix: add a missing-source case like `FAKE_TIMESYNCD_MISSING=1` so collection still exits 0 and emits `SKIPPED.txt` when `systemd-timesyncd` is absent [Task 2]
83:- Symptom: smoke validation looks noisy or slow because of tar warnings and multi-node collection time. Cause: real bundle generation is slower than unit tests and macOS tar can emit warnings. Fix: trust `verify-bundle.sh` plus the archive contents, not the command start or incidental tar noise [Task 2]
182:# Task Group: learning-k8s systemd-timesyncd source-first authoring and explanation workflow
184:scope: Source-first `systemd-timesyncd` category rewrites, monitoring-page rewrites, and implementation-grounded wait/sync explanations in `learning-k8s`, including the repo’s publish path when the user wants the content landed.
187:## Task 1: Audit and rewrite the `systemd-timesyncd` category, then publish
195:- systemd-timesyncd, source-first, community scenarios, manager_sample_spike_detection, RootDistanceMaxSec, time-set.target, time-sync.target, timedated, quiz.json, projects.ts, git commit --no-gpg-sign, GIT_SSH_COMMAND
223:- when the user asked to "Review systemd-timesyncd 分類內的所有文章…重視高品質內容詳細" -> treat similar `learning-k8s` content review requests as full category audits and rewrites, not narrow page fixes [Task 1]
234:- `systemd-timesyncd` has no static-config reload path; changed config requires restart [Task 1]
237:- `timedated`’s synchronized state is based on kernel `maxerror < 16s`, so it can diverge from the `systemd-timesyncd` sync-helper file at `/run/systemd/timesync/synchronized` [Task 1][Task 2][Task 3]

codex
Using `superpowers:using-superpowers` for the session rules. I found prior memory for this exact bundle, so I’m using it only to preserve constraints like read-only behavior and bundle verification expectations while I inspect the current files directly.
exec
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/run/collect.sh' in /Users/ikaros/Documents/code/learning-k8s
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
    35	  --kube-mode MODE       where the rook layer runs kubectl: remote (on an
    36	                         inventory node, default) or local (this jump host)
    37	  --since DURATION       log/journal window (default: 24h)
    38	  --timeout SECONDS      per-command / SSH-connect timeout (default: 20)
    39	  --node-timeout SECONDS overall timeout for one node's full collection (default: 600)
    40	  --skip-logs            collect state but skip larger Ceph log copies
    41	  --quiet                suppress progress output on stderr (stdout still prints bundle:)
    42	  --keep-workdir         keep temporary extracted workdir for debugging
    43	  --help                 print this help
    44	
    45	Output:
    46	  DIR/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
    47	
    48	Exit codes:
    49	  0 complete, 2 partial collection failure with bundle produced, 1 usage/config/verify failure
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
   381	  local rc=$?
   382	  if [[ -n "${CLEANUP_WORKDIR:-}" && -d "$CLEANUP_WORKDIR" ]]; then
   383	    if [[ "${CLEANUP_KEEP:-0}" -eq 1 ]]; then
   384	      printf 'kept workdir: %s\n' "$CLEANUP_WORKDIR" >&2
   385	    else
   386	      rm -rf -- "$CLEANUP_WORKDIR"
   387	    fi
   388	  fi
   389	  return "$rc"
   390	}
   391	
   392	main() {
   393	  local inventory='' ssh_key='' seed_override='' out_dir="$COLLECT_ROOT/results"
   394	  local mode=auto since=24h timeout=20 node_timeout=600 skip_logs=0 keep_workdir=0
   395	  local seed='' ssh_user='' seed_host='' rook_namespace=rook-ceph rook_operator_namespace=rook-ceph kube_context='' kube_mode=remote
   396	  local timestamp workdir manifest bundle rc=0 cluster_rc=0 node_ok=0 node_failed=0
   397	
   398	  if [[ $# -eq 0 ]]; then
   399	    usage >&2
   400	    return 1
   401	  fi
   402	
   403	  while [[ $# -gt 0 ]]; do
   404	    case "$1" in
   405	      --inventory)
   406	        inventory=${2-}
   407	        shift 2
   408	        ;;
   409	      --ssh-key)
   410	        ssh_key=${2-}
   411	        shift 2
   412	        ;;
   413	      --seed)
   414	        seed_override=${2-}
   415	        shift 2
   416	        ;;
   417	      --out)
   418	        out_dir=${2-}
   419	        shift 2
   420	        ;;
   421	      --mode)
   422	        mode=${2-}
   423	        shift 2
   424	        ;;
   425	      --kube-context)
   426	        kube_context=${2-}
   427	        shift 2
   428	        ;;
   429	      --kube-mode)
   430	        kube_mode=${2-}
   431	        shift 2
   432	        ;;
   433	      --since)
   434	        since=${2-}
   435	        shift 2
   436	        ;;
   437	      --timeout)
   438	        timeout=${2-}
   439	        shift 2
   440	        ;;
   441	      --node-timeout)
   442	        node_timeout=${2-}
   443	        shift 2
   444	        ;;
   445	      --skip-logs)
   446	        skip_logs=1
   447	        shift
   448	        ;;
   449	      --quiet)
   450	        export CEPH_INCIDENT_QUIET=1
   451	        shift
   452	        ;;
   453	      --keep-workdir)
   454	        keep_workdir=1
   455	        shift
   456	        ;;
   457	      --help|-h)
   458	        usage
   459	        return 0
   460	        ;;
   461	      *)
   462	        usage >&2
   463	        return 1
   464	        ;;
   465	    esac
   466	  done
   467	
   468	  [[ "$mode" == "auto" || "$mode" == "cephadm" || "$mode" == "rook" ]] || die "unsupported mode: $mode"
   469	  # kube-context runs through a remote shell (ssh kubectl --context ...). Block the
   470	  # actual shell metacharacters but allow the chars real contexts use (@ : / for
   471	  # e.g. kubernetes-admin@kubernetes and EKS ARNs).
   472	  if [[ -n "$kube_context" && "$kube_context" == *[!A-Za-z0-9._@:/-]* ]]; then
   473	    die "invalid --kube-context (allowed: A-Za-z0-9._@:/-): $kube_context"
   474	  fi
   475	  [[ "$kube_mode" == "local" || "$kube_mode" == "remote" ]] || die "invalid --kube-mode (local|remote): $kube_mode"
   476	  [[ -n "$inventory" && -f "$inventory" ]] || die "missing inventory: ${inventory:-<unset>}"
   477	  [[ -n "$ssh_key" && -f "$ssh_key" ]] || die "missing ssh key: ${ssh_key:-<unset>}"
   478	
   479	  # shellcheck disable=SC1090
   480	  source "$inventory"
   481	
   482	  if ! declare -p HOSTS >/dev/null 2>&1; then
   483	    die "inventory must define HOSTS"
   484	  fi
   485	
   486	  ssh_user=${SSH_USER:-}
   487	  seed_host=${SEED_HOST:-}
   488	  rook_namespace=${ROOK_NAMESPACE:-rook-ceph}
   489	  rook_operator_namespace=${ROOK_OPERATOR_NAMESPACE:-rook-ceph}
   490	  if [[ -n "$seed_override" ]]; then
   491	    seed=$seed_override
   492	  elif [[ -n "$seed_host" ]]; then
   493	    seed="$(ssh_target_for_host "$seed_host" "$ssh_user")"
   494	  fi
   495	
   496	  if [[ -z "$(timeout_cmd)" ]]; then
   497	    log "WARNING: no 'timeout'/'gtimeout' found on this workstation; outer timeouts are disabled — relying on SSH ConnectTimeout/ServerAlive only (install coreutils for full bounding)"
   498	  fi
   499	
   500	  ensure_dir "$out_dir"
   501	  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
   502	  workdir="$out_dir/tmp.$timestamp.$$"
   503	  manifest="$workdir/manifest.jsonl"
   504	  ensure_dir "$workdir"
   505	  CLEANUP_WORKDIR="$workdir"
   506	  CLEANUP_KEEP=$keep_workdir
   507	  trap cleanup_workdir EXIT INT TERM
   508	  write_initial_metadata "$workdir" "$mode" "$seed" "$since" "$timeout"
   509	
   510	  # Parse HOSTS once into globals (used by the cluster capability probe AND the
   511	  # node loop). A malformed entry is recorded but must not abort collection.
   512	  local entry
   513	  HOST_ALIASES=()
   514	  HOST_TARGETS=()
   515	  # bash 3.2 + set -u: expanding an empty array errors, so guard it.
   516	  if [[ ${#HOSTS[@]} -eq 0 ]]; then
   517	    die "inventory HOSTS is empty"
   518	  fi
   519	  for entry in "${HOSTS[@]}"; do
   520	    if [[ "$entry" != *=* || -z "${entry%%=*}" || -z "${entry#*=}" ]]; then
   521	      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
   522	      rc=2
   523	      continue
   524	    fi
   525	    HOST_ALIASES+=("${entry%%=*}")
   526	    HOST_TARGETS+=("$(ssh_target_for_host "${entry#*=}" "$ssh_user")")
   527	  done
   528	
   529	  progress "starting: mode=$mode, ${#HOST_TARGETS[@]} hosts"
   530	
   531	  set +e
   532	  collect_clusters "$mode" "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout" "$rook_namespace" "$kube_context" "$kube_mode" "$rook_operator_namespace"
   533	  cluster_rc=$?
   534	  set -e
   535	  if [[ $cluster_rc -ne 0 ]]; then
   536	    append_error "$workdir" "cluster collection exited $cluster_rc"
   537	    rc=2
   538	  fi
   539	
   540	  local i alias target node_rc ntotal
   541	  ntotal=${#HOST_ALIASES[@]}
   542	  if [[ $ntotal -gt 0 ]]; then
   543	    for i in "${!HOST_ALIASES[@]}"; do
   544	      alias="${HOST_ALIASES[$i]}"
   545	      target="${HOST_TARGETS[$i]}"
   546	      progress "[$((i + 1))/$ntotal] node ${alias}…"
   547	      if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs" "$node_timeout"; then
   548	        node_ok=$((node_ok + 1))
   549	        progress "[$((i + 1))/$ntotal] node $alias: ok"
   550	      else
   551	        node_rc=$?
   552	        node_failed=$((node_failed + 1))
   553	        append_error "$workdir" "node $alias ($target) collector exited $node_rc"
   554	        progress "[$((i + 1))/$ntotal] node $alias: SKIPPED (exit $node_rc)"
   555	        rc=2
   556	      fi
   557	    done
   558	  fi
   559	
   560	  # Test-only hook: simulate a mid-run abort to exercise trap cleanup. Inert in production.
   561	  if [[ -n "${COLLECT_TEST_ABORT_AFTER_NODES:-}" ]]; then
   562	    die "test abort after nodes"
   563	  fi
   564	
   565	  progress "redacting…"
   566	  redact_bundle_text "$workdir"
   567	  write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "$rc"
   568	
   569	  progress "verifying…"
   570	  # Verify BEFORE packaging, but never let verification destroy collected
   571	  # evidence: capture its result instead of aborting under set -e. On failure,
   572	  # keep the workdir for inspection and do not produce a shareable bundle.
   573	  local verify_rc=0
   574	  set +e
   575	  "$COLLECT_ROOT/lib/verify-bundle.sh" "$workdir" >/dev/null 2>>"$workdir/errors.log"
   576	  verify_rc=$?
   577	  set -e
   578	  if [[ $verify_rc -ne 0 ]]; then
   579	    CLEANUP_KEEP=1
   580	    append_error "$workdir" "bundle verification failed (rc=$verify_rc); workdir kept, NOT packaged for sharing"
   581	    write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "1"
   582	    printf 'VERIFY FAILED: workdir kept at %s (not packaged) — review errors.log\n' "$workdir" >&2
   583	    return 1
   584	  fi
   585	
   586	  progress "packaging…"
   587	  bundle="$out_dir/ceph-incident-$timestamp.tar.gz"
   588	  COPYFILE_DISABLE=1 tar -czf "$bundle" -C "$workdir" .
   589	  set +e
   590	  "$COLLECT_ROOT/lib/verify-bundle.sh" "$bundle" >/dev/null 2>>"$workdir/errors.log"
   591	  verify_rc=$?
   592	  set -e
   593	  if [[ $verify_rc -ne 0 ]]; then
   594	    CLEANUP_KEEP=1
   595	    rm -f -- "$bundle"
   596	    printf 'VERIFY FAILED on packaged bundle; removed it, workdir kept at %s\n' "$workdir" >&2
   597	    return 1
   598	  fi
   599	
   600	  printf 'bundle: %s\n' "$bundle"
   601	  return "$rc"
   602	}
   603	
   604	main "$@"

exec
/bin/zsh -lc 'rg --files experiments/ceph-incident-bundle' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/README.md
experiments/ceph-incident-bundle/lib/verify-bundle.sh
experiments/ceph-incident-bundle/lib/common.sh
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
experiments/ceph-incident-bundle/lib/collect-node.sh
experiments/ceph-incident-bundle/inventory/ceph-lab.example.env
experiments/ceph-incident-bundle/run/collect.sh
experiments/ceph-incident-bundle/results/.gitkeep
experiments/ceph-incident-bundle/tests/test-common.sh
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh
experiments/ceph-incident-bundle/tests/run-tests.sh
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
experiments/ceph-incident-bundle/tests/test-collect.sh
experiments/ceph-incident-bundle/tests/test-node-collector.sh
experiments/ceph-incident-bundle/tests/test-rook-collector.sh
experiments/ceph-incident-bundle/tests/fixtures/README.md
experiments/ceph-incident-bundle/tests/fixtures/bin/ssh

exec
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/lib/common.sh' in /Users/ikaros/Documents/code/learning-k8s
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
    16	ceph_incident_bundle_log() {
    17	  log "$*"
    18	}
    19	
    20	require_file() {
    21	  [[ -f "$1" ]] || die "missing file: $1"
    22	}
    23	
    24	ensure_dir() {
    25	  mkdir -p "$1"
    26	}
    27	
    28	# Live progress to stderr (stdout stays reserved for the final `bundle:` line).
    29	# Suppressed when CEPH_INCIDENT_QUIET is set. Call only from workstation-side
    30	# code — NOT from the remote node collector (its stderr is multiplexed over ssh).
    31	progress() {
    32	  [[ -n "${CEPH_INCIDENT_QUIET:-}" ]] && return 0
    33	  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
    34	}
    35	
    36	# Resolve a timeout binary: GNU coreutils `timeout`, or `gtimeout` on macOS.
    37	# Prints the binary name, or nothing if neither is installed.
    38	timeout_cmd() {
    39	  if command -v timeout >/dev/null 2>&1; then
    40	    printf 'timeout'
    41	  elif command -v gtimeout >/dev/null 2>&1; then
    42	    printf 'gtimeout'
    43	  fi
    44	}
    45	
    46	json_escape() {
    47	  local value=$1
    48	  value=${value//\\/\\\\}
    49	  value=${value//\"/\\\"}
    50	  value=${value//$'\n'/\\n}
    51	  value=${value//$'\r'/\\r}
    52	  value=${value//$'\t'/\\t}
    53	  printf '%s' "$value"
    54	}
    55	
    56	manifest_add() {
    57	  local manifest=$1 host=$2 collector=$3 artifact=$4 command=$5 exit_code=$6 started=$7 ended=$8
    58	  [[ "$exit_code" =~ ^[0-9]+$ ]] || die "manifest_add requires numeric exit_code: $exit_code"
    59	  ensure_dir "$(dirname -- "$manifest")"
    60	  printf '{"host":"%s","collector":"%s","artifact":"%s","command":"%s","exit_code":%s,"started":"%s","ended":"%s"}\n' \
    61	    "$(json_escape "$host")" \
    62	    "$(json_escape "$collector")" \
    63	    "$(json_escape "$artifact")" \
    64	    "$(json_escape "$command")" \
    65	    "$exit_code" \
    66	    "$(json_escape "$started")" \
    67	    "$(json_escape "$ended")" >>"$manifest"
    68	}
    69	
    70	redact_file() {
    71	  local source_file=$1 redaction_log=$2
    72	  require_file "$source_file"
    73	  ensure_dir "$(dirname -- "$redaction_log")"
    74	
    75	  local source_dir tmp_file count line nocasematch_state in_pem redact mode
    76	  source_dir="$(dirname -- "$source_file")"
    77	  tmp_file="$(mktemp "$source_dir/.${source_file##*/}.XXXXXX")"
    78	  count=0
    79	  in_pem=0
    80	  if shopt -q nocasematch; then
    81	    nocasematch_state='shopt -s nocasematch'
    82	  else
    83	    nocasematch_state='shopt -u nocasematch'
    84	  fi
    85	  shopt -s nocasematch
    86	
    87	  # Best-effort redaction (NOT a complete DLP): keyword lines, ceph key
    88	  # material (`key = AQB..==`, base64 blobs), and whole multi-line PEM private
    89	  # key blocks. Extensions/encodings outside this are intentionally not covered
    90	  # — see README "安全界線"; operators must self-review before sharing.
    91	  while IFS= read -r line || [[ -n "$line" ]]; do
    92	    redact=0
    93	    if [[ "$line" =~ -----BEGIN[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
    94	      in_pem=1
    95	    fi
    96	    if [[ $in_pem -eq 1 ]]; then
    97	      redact=1
    98	      if [[ "$line" =~ -----END[[:space:]].*PRIVATE[[:space:]]KEY----- ]]; then
    99	        in_pem=0
   100	      fi
   101	    elif [[ "$line" =~ (password|secret|token|keyring|private([[:space:]_-]+)?key) ]]; then
   102	      redact=1
   103	    elif [[ "$line" =~ (^|[^[:alnum:]])key[[:space:]]*[:=] ]]; then
   104	      redact=1
   105	    elif [[ "$line" =~ [A-Za-z0-9+/]{38,}={1,2} ]]; then
   106	      redact=1
   107	    fi
   108	    if [[ $redact -eq 1 ]]; then
   109	      printf '[REDACTED]\n' >>"$tmp_file"
   110	      count=$((count + 1))
   111	    else
   112	      printf '%s\n' "$line" >>"$tmp_file"
   113	    fi
   114	  done <"$source_file"
   115	
   116	  eval "$nocasematch_state"
   117	  mode="$(stat -c '%a' "$source_file" 2>/dev/null || stat -f '%Lp' "$source_file" 2>/dev/null || printf '600')"
   118	  chmod "$mode" "$tmp_file" 2>/dev/null || true
   119	  mv -f -- "$tmp_file" "$source_file"
   120	  printf '%s: %s line(s) redacted\n' "$source_file" "$count" >>"$redaction_log"
   121	}
   122	
   123	redact_gz_file() {
   124	  # Decompress a gzipped artifact, redact it, recompress in place so rotated
   125	  # logs (*.gz) get the same redaction as plain text.
   126	  local source_file=$1 redaction_log=$2
   127	  require_file "$source_file"
   128	  ensure_dir "$(dirname -- "$redaction_log")"
   129	
   130	  local dir tmp_plain
   131	  dir="$(dirname -- "$source_file")"
   132	  tmp_plain="$(mktemp "$dir/.${source_file##*/}.plain.XXXXXX")"
   133	  if ! gzip -dc -- "$source_file" >"$tmp_plain" 2>/dev/null; then
   134	    rm -f -- "$tmp_plain"
   135	    printf '%s: gz decompress failed, left as-is (NOT redacted)\n' "$source_file" >>"$redaction_log"
   136	    return 0
   137	  fi
   138	
   139	  redact_file "$tmp_plain" "$redaction_log"
   140	  if gzip -c -- "$tmp_plain" >"$source_file"; then
   141	    rm -f -- "$tmp_plain"
   142	  else
   143	    rm -f -- "$tmp_plain"
   144	    return 1
   145	  fi
   146	}
   147	
   148	run_capture() {
   149	  local manifest=$1 host=$2 collector=$3 artifact=$4
   150	  shift 4
   151	  [[ ${1-} == -- ]] || die "run_capture requires -- before the command"
   152	  shift
   153	
   154	  local -a cmd
   155	  local started ended rc command_string artifact_dir artifact_tmp
   156	
   157	  cmd=("$@")
   158	  [[ ${#cmd[@]} -gt 0 ]] || die "run_capture requires a command"
   159	
   160	  started="$(date -u +%FT%TZ)"
   161	  artifact_dir="$(dirname -- "$artifact")"
   162	  ensure_dir "$artifact_dir"
   163	  artifact_tmp="$(mktemp "$artifact_dir/.${artifact##*/}.XXXXXX")"
   164	
   165	  printf '# host: %s\n# collector: %s\n# started: %s\n' "$host" "$collector" "$started" >"$artifact_tmp"
   166	  printf -v command_string '%q ' "${cmd[@]}"
   167	  command_string=${command_string% }
   168	
   169	  local tbin
   170	  tbin="$(timeout_cmd)"
   171	  if [[ -n "$tbin" ]]; then
   172	    printf '# timeout: %ss\n' "${COMMAND_TIMEOUT:-20}" >>"$artifact_tmp"
   173	    if "$tbin" "${COMMAND_TIMEOUT:-20}" "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
   174	      rc=0
   175	    else
   176	      rc=$?
   177	    fi
   178	  else
   179	    printf '# timeout: unavailable\n' >>"$artifact_tmp"
   180	    if "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
   181	      rc=0
   182	    else
   183	      rc=$?
   184	    fi
   185	  fi
   186	
   187	  # Make timeout-kills (124) distinguishable from ordinary command failure, and
   188	  # mark the artifact so a truncated capture is visible to whoever reads it.
   189	  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
   190	    printf '# TRUNCATED: command timed out after %ss (exit %s)\n' "${COMMAND_TIMEOUT:-20}" "$rc" >>"$artifact_tmp"
   191	  fi
   192	
   193	  ended="$(date -u +%FT%TZ)"
   194	  mv -f -- "$artifact_tmp" "$artifact"
   195	  manifest_add "$manifest" "$host" "$collector" "$artifact" "$command_string" "$rc" "$started" "$ended"
   196	
   197	  if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
   198	    ensure_dir "$(dirname -- "$ERROR_LOG")"
   199	    printf '%s host=%s collector=%s artifact=%s exit=%s command=%s\n' \
   200	      "$ended" "$host" "$collector" "$artifact" "$rc" "$command_string" >>"$ERROR_LOG"
   201	  fi
   202	
   203	  return "$rc"
   204	}
   205	
   206	copy_if_exists() {
   207	  local source=$1 dest=$2
   208	  [[ -e "$source" ]] || return 0
   209	  ensure_dir "$(dirname -- "$dest")"
   210	  cp -a -- "$source" "$dest"
   211	}

codex
I’ve finished the entrypoint and common helper pass. The main structural pressure point is already visible: `run/collect.sh` owns CLI, inventory normalization, cluster orchestration, remote node packaging, redaction, verification, and packaging, while some cross-cutting shell helpers live outside it.
exec
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh' in /Users/ikaros/Documents/code/learning-k8s
exec
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh' in /Users/ikaros/Documents/code/learning-k8s
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
    71	  if [[ -n "$ids" ]]; then
    72	    printf '%s\n' "$ids"
    73	    return 0
    74	  fi
    75	
    76	  compact="$(printf '%s' "$payload" | tr -d '[:space:]')"
    77	  case "$compact" in
    78	    "[]"|"{}"|"{\"crashes\":[]}"|"{\"items\":[]}"|"{\"entries\":[]}"|"{\"crash_ls\":[]}")
    79	      return 0
    80	      ;;
    81	  esac
    82	
    83	  return 1
    84	}
    85	
    86	cephadm_crash_artifact_name() {
    87	  local crash_id=$1 safe_id
    88	  safe_id="$(printf '%s' "$crash_id" | tr -c 'A-Za-z0-9._-' '_')"
    89	  while [[ "$safe_id" == *..* ]]; do
    90	    safe_id="${safe_id//../__}"
    91	  done
    92	  [[ -n "$safe_id" ]] || safe_id="crash"
    93	  printf '%s' "$safe_id"
    94	}
    95	
    96	cephadm_unique_crash_artifact() {
    97	  local crash_dir=$1 safe_id=$2
    98	  local artifact="$crash_dir/$safe_id.json"
    99	  local suffix=2
   100	
   101	  while [[ -e "$artifact" ]]; do
   102	    artifact="$crash_dir/$safe_id-$suffix.json"
   103	    suffix=$((suffix + 1))
   104	  done
   105	
   106	  printf '%s' "$artifact"
   107	}
   108	
   109	collect_cephadm_recent_crashes() {
   110	  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 runner=$6 crash_ls_artifact=$7
   111	
   112	  local crash_dir="$outdir/cluster/ceph/json/crash-info"
   113	  local skip_artifact="$outdir/cluster/ceph/text/crash-info-skip.txt"
   114	  local crash_ids rc=0
   115	
   116	  if ! crash_ids="$(extract_cephadm_crash_ids "$crash_ls_artifact")"; then
   117	    write_cephadm_crash_skip "$skip_artifact"
   118	    return 0
   119	  fi
   120	
   121	  [[ -n "$crash_ids" ]] || return 0
   122	
   123	  local crash_id safe_id crash_info_artifact
   124	  while IFS= read -r crash_id; do
   125	    [[ -n "$crash_id" ]] || continue
   126	    safe_id="$(cephadm_crash_artifact_name "$crash_id")"
   127	    crash_info_artifact="$(cephadm_unique_crash_artifact "$crash_dir" "$safe_id")"
   128	    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$runner" "$crash_info_artifact" crash info "$crash_id"; then
   129	      rc=2
   130	    fi
   131	  done <<<"$crash_ids"
   132	
   133	  return "$rc"
   134	}
   135	
   136	collect_cluster_cephadm() {
   137	  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 since=$5 timeout=$6 runner="${7:-cephadm}"
   138	  local failed=0
   139	  local json_dir="$outdir/cluster/ceph/json"
   140	  local text_dir="$outdir/cluster/ceph/text"
   141	
   142	  # Cluster-level ceph commands are point-in-time snapshots; node collectors apply the time window.
   143	  : "$since"
   144	
   145	  ensure_dir "$json_dir"
   146	  ensure_dir "$text_dir"
   147	
   148	  local -a json_specs=(
   149	    "status.json::status --format json-pretty"
   150	    "health-detail.json::health detail --format json-pretty"
   151	    "versions.json::versions --format json-pretty"
   152	    "df-detail.json::df detail --format json-pretty"
   153	    "osd-tree.json::osd tree --format json-pretty"
   154	    "osd-df.json::osd df --format json-pretty"
   155	    "osd-dump.json::osd dump --format json-pretty"
   156	    "osd-perf.json::osd perf --format json-pretty"
   157	    "osd-blocked-by.json::osd blocked-by --format json-pretty"
   158	    "pg-stat.json::pg stat --format json-pretty"
   159	    "pg-dump.json::pg dump --format json-pretty"
   160	    "pg-dump-stuck.json::pg dump_stuck --format json-pretty"
   161	    "mon-dump.json::mon dump --format json-pretty"
   162	    "quorum-status.json::quorum_status --format json-pretty"
   163	    "mgr-dump.json::mgr dump --format json-pretty"
   164	    "orch-host-ls.json::orch host ls --format json-pretty"
   165	    "orch-ps.json::orch ps --format json-pretty"
   166	    "orch-device-ls-wide.json::orch device ls --wide --format json-pretty"
   167	    "config-dump.json::config dump --format json-pretty"
   168	    "crash-ls.json::crash ls --format json-pretty"
   169	  )
   170	
   171	  local -a text_specs=(
   172	    "status.txt::status"
   173	    "health-detail.txt::health detail"
   174	    "osd-tree.txt::osd tree"
   175	    "orch-ps.txt::orch ps"
   176	  )
   177	
   178	  local spec artifact command
   179	  local -a command_words
   180	  local total=$(( ${#json_specs[@]} + ${#text_specs[@]} )) k=0
   181	  for spec in "${json_specs[@]}"; do
   182	    artifact=${spec%%::*}
   183	    command=${spec#*::}
   184	    k=$((k + 1))
   185	    progress "[$k/$total] ceph $command"
   186	    # shellcheck disable=SC2206
   187	    command_words=($command)
   188	    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$runner" "$json_dir/$artifact" "${command_words[@]}"; then
   189	      failed=1
   190	    fi
   191	  done
   192	
   193	  for spec in "${text_specs[@]}"; do
   194	    artifact=${spec%%::*}
   195	    command=${spec#*::}
   196	    k=$((k + 1))
   197	    progress "[$k/$total] ceph $command"
   198	    # shellcheck disable=SC2206
   199	    command_words=($command)
   200	    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$runner" "$text_dir/$artifact" "${command_words[@]}"; then
   201	      failed=1
   202	    fi
   203	  done
   204	
   205	  progress "ceph crash info (recent)…"
   206	  if ! collect_cephadm_recent_crashes "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$runner" "$json_dir/crash-ls.json"; then
   207	    failed=1
   208	  fi
   209	
   210	  if [[ $failed -ne 0 ]]; then
   211	    return 2
   212	  fi
   213	
   214	  return 0
   215	}

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
    49	  # `|| true`: a lookup failure (e.g. remote kubectl/ssh error) must yield an
    50	  # empty result (-> SKIPPED artifact), not abort the collector under set -e.
    51	  { "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -l "$label" -o name 2>/dev/null || true; } |
    52	    head -n1 | sed 's#^pod/##'
    53	}
    54	
    55	collect_cluster_rook() {
    56	  local outdir='' manifest='' namespace=rook-ceph since=24h timeout=20 allow_skip=0
    57	  local operator_namespace='' ssh_target='' ssh_key='' kube_context=''
    58	
    59	  while [[ $# -gt 0 ]]; do
    60	    case "$1" in
    61	      --out)
    62	        outdir=${2-}
    63	        shift 2
    64	        ;;
    65	      --manifest)
    66	        manifest=${2-}
    67	        shift 2
    68	        ;;
    69	      --namespace)
    70	        namespace=${2-}
    71	        shift 2
    72	        ;;
    73	      --operator-namespace)
    74	        operator_namespace=${2-}
    75	        shift 2
    76	        ;;
    77	      --since)
    78	        since=${2-}
    79	        shift 2
    80	        ;;
    81	      --timeout)
    82	        timeout=${2-}
    83	        shift 2
    84	        ;;
    85	      --allow-skip)
    86	        allow_skip=1
    87	        shift
    88	        ;;
    89	      --ssh-target)
    90	        ssh_target=${2-}
    91	        shift 2
    92	        ;;
    93	      --ssh-key)
    94	        ssh_key=${2-}
    95	        shift 2
    96	        ;;
    97	      --kube-context)
    98	        kube_context=${2-}
    99	        shift 2
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
   131	  # explicit rook mode that is a partial failure (exit 2) so the bundle does not
   132	  # falsely look complete; auto-mode fallback passes --allow-skip to tolerate it.
   133	  # (When kubectl is remote we already probed it exists, so skip the local check.)
   134	  if [[ -z "$ssh_target" ]] && ! command -v kubectl >/dev/null 2>&1; then
   135	    rook_skip "$outdir" "kubectl command not found"
   136	    [[ "$allow_skip" == "1" ]] && return 0 || return 2
   137	  fi
   138	
   139	  if ! "${ROOK_KUBECTL_ARGV[@]}" get namespace "$namespace" >/dev/null 2>&1; then
   140	    rook_skip "$outdir" "namespace not found (or kubectl unavailable on ${ssh_target:-local}): $namespace"
   141	    [[ "$allow_skip" == "1" ]] && return 0 || return 2
   142	  fi
   143	
   144	  progress "rook: pods/events/resources/operator-log/toolbox…"
   145	  local failed=0
   146	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/pods-wide.txt" \
   147	    "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -o wide; then
   148	    failed=1
   149	  fi
   150	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/events.txt" \
   151	    "${ROOK_KUBECTL_ARGV[@]}" get events -n "$namespace" --sort-by=.lastTimestamp; then
   152	    failed=1
   153	  fi
   154	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/rook-resources.yaml" \
   155	    "${ROOK_KUBECTL_ARGV[@]}" get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n "$namespace" -o yaml; then
   156	    failed=1
   157	  fi
   158	
   159	  local operator_pod toolbox_pod
   160	  operator_pod="$(rook_get_first_pod "$operator_namespace" "app=rook-ceph-operator")"
   161	  if [[ -n "$operator_pod" ]]; then
   162	    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
   163	      "${ROOK_KUBECTL_ARGV[@]}" logs -n "$operator_namespace" "$operator_pod" --since="$since"; then
   164	      failed=1
   165	    fi
   166	  else
   167	    rook_write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found in namespace: $operator_namespace"
   168	  fi
   169	
   170	  toolbox_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-tools")"
   171	  if [[ -n "$toolbox_pod" ]]; then
   172	    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
   173	      "${ROOK_KUBECTL_ARGV[@]}" exec -n "$namespace" "$toolbox_pod" -- ceph status; then
   174	      failed=1
   175	    fi
   176	  else
   177	    rook_write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
   178	  fi
   179	
   180	  [[ $failed -eq 0 ]] || return 2
   181	  return 0
   182	}
   183	
   184	if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
   185	  collect_cluster_rook "$@"
   186	fi

exec
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/lib/collect-node.sh' in /Users/ikaros/Documents/code/learning-k8s
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
   349	  if ! node_run_optional "$outdir" "$manifest" "$host_alias" "$heavy_timeout" "systemd/journal-ceph.txt" sudo -n journalctl --since "$journal_since" -u 'ceph*' --no-pager; then
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

codex
The collectors are cohesive by domain, but there are repeated small primitives: SSH option construction, `SKIPPED:` artifact creation, and nearly identical `run_capture` wrappers. I’m checking verification and tests next to avoid mistaking intentional compatibility scaffolding for design debt.
exec
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/lib/verify-bundle.sh' in /Users/ikaros/Documents/code/learning-k8s
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

exec
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/tests/test-common.sh' in /Users/ikaros/Documents/code/learning-k8s
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
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/tests/run-tests.sh' in /Users/ikaros/Documents/code/learning-k8s
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

codex
Tests cover a lot of compatibility and failure-shape behavior, so I’m treating wrapper duplication as a refactor target only where it can be centralized behind the same output/exit contract. I’m scanning the rest of the test files and README for public interface promises before ranking findings.
exec
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/tests/test-collect.sh' in /Users/ikaros/Documents/code/learning-k8s
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
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh' in /Users/ikaros/Documents/code/learning-k8s
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
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/tests/test-rook-collector.sh' in /Users/ikaros/Documents/code/learning-k8s
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
The public README mostly reinforces the same contract: single command, read-only, stdout reserved for `bundle:`, and `SKIPPED.txt` as a visible non-fatal artifact. I’m doing one targeted grep now for duplication hotspots so the recommendations are concrete rather than stylistic.
exec
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/tests/test-node-collector.sh' in /Users/ikaros/Documents/code/learning-k8s
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
    52	if [[ "${FAKE_JOURNALCTL_NO_CEPH:-}" == "1" ]]; then
    53	  printf 'no entries\n'
    54	  exit 1
    55	fi
    56	printf 'fake journalctl %s\n' "$*"
    57	EOF
    58	
    59	cat >"$fakebin/podman" <<'EOF'
    60	#!/usr/bin/env bash
    61	set -euo pipefail
    62	printf 'fake podman %s\n' "$*"
    63	EOF
    64	
    65	cat >"$fakebin/docker" <<'EOF'
    66	#!/usr/bin/env bash
    67	set -euo pipefail
    68	printf 'fake docker %s\n' "$*"
    69	exit 1
    70	EOF
    71	
    72	cat >"$fakebin/cephadm" <<'EOF'
    73	#!/usr/bin/env bash
    74	set -euo pipefail
    75	case "$*" in
    76	  "ls --format json-pretty") printf '[{"name":"mon.a","style":"cephadm"}]\n' ;;
    77	  *) printf 'fake cephadm %s\n' "$*" ;;
    78	esac
    79	EOF
    80	
    81	cat >"$fakebin/timeout" <<'EOF'
    82	#!/usr/bin/env bash
    83	shift
    84	exec "$@"
    85	EOF
    86	
    87	cat >"$fakebin/dmesg" <<'EOF'
    88	#!/usr/bin/env bash
    89	set -euo pipefail
    90	printf 'fake kernel ring buffer\n'
    91	EOF
    92	
    93	cat >"$fakebin/hostname" <<'EOF'
    94	#!/usr/bin/env bash
    95	set -euo pipefail
    96	printf 'monitor01\n'
    97	EOF
    98	
    99	cat >"$fakebin/uname" <<'EOF'
   100	#!/usr/bin/env bash
   101	set -euo pipefail
   102	printf 'Linux monitor01 6.1.0 fake\n'
   103	EOF
   104	
   105	cat >"$fakebin/uptime" <<'EOF'
   106	#!/usr/bin/env bash
   107	set -euo pipefail
   108	printf 'up 1 day\n'
   109	EOF
   110	
   111	cat >"$fakebin/free" <<'EOF'
   112	#!/usr/bin/env bash
   113	set -euo pipefail
   114	printf 'Mem: 1Gi 512Mi 512Mi\n'
   115	EOF
   116	
   117	cat >"$fakebin/df" <<'EOF'
   118	#!/usr/bin/env bash
   119	set -euo pipefail
   120	printf 'Filesystem Type Size Used Avail Mounted on\n'
   121	EOF
   122	
   123	cat >"$fakebin/lsblk" <<'EOF'
   124	#!/usr/bin/env bash
   125	set -euo pipefail
   126	printf 'NAME SIZE TYPE MOUNTPOINT\nsda 100G disk\n'
   127	EOF
   128	
   129	cat >"$fakebin/ip" <<'EOF'
   130	#!/usr/bin/env bash
   131	set -euo pipefail
   132	printf '1: lo: <LOOPBACK,UP>\n'
   133	EOF
   134	
   135	cat >"$fakebin/systemctl" <<'EOF'
   136	#!/usr/bin/env bash
   137	set -euo pipefail
   138	printf '0 loaded units listed.\n'
   139	EOF
   140	
   141	for tool in iostat chronyc ntpq pvs vgs lvs; do
   142	  cat >"$fakebin/$tool" <<'EOF'
   143	#!/usr/bin/env bash
   144	set -euo pipefail
   145	tool=${0##*/}
   146	{
   147	  printf '%s' "$tool"
   148	  for arg in "$@"; do
   149	    printf ' <%s>' "$arg"
   150	  done
   151	  printf '\n'
   152	} >>"${FAKE_OPTIONAL_LOG:?}"
   153	printf 'fake optional command %s\n' "$tool"
   154	EOF
   155	done
   156	
   157	rm -f "$fakebin/ntpq"
   158	
   159	chmod +x "$fakebin"/*
   160	
   161	export FAKE_SUDO_LOG="$tmpdir/sudo.log"
   162	export FAKE_OPTIONAL_LOG="$tmpdir/optional.log"
   163	PATH="$fakebin:$PATH"
   164	
   165	outdir="$tmpdir/node"
   166	set +e
   167	CEPH_INCIDENT_VAR_LOG_CEPH_DIR="$fake_log_dir" \
   168	CEPH_INCIDENT_VAR_LIB_CEPH_DIR="$fake_var_lib" \
   169	CEPH_INCIDENT_LOG_FILE_CAP_BYTES=128 \
   170	bash "$ROOT/lib/collect-node.sh" \
   171	  --out "$outdir" \
   172	  --host-alias monitor01 \
   173	  --since "24h" \
   174	  --timeout 5
   175	rc=$?
   176	set -e
   177	if [[ "$rc" != "0" ]]; then
   178	  [[ -f "$outdir/errors.log" ]] && sed -n '1,120p' "$outdir/errors.log" >&2
   179	  fail "collect-node.sh exited $rc"
   180	fi
   181	
   182	for artifact in \
   183	  system/hostname.txt \
   184	  system/uname.txt \
   185	  system/uptime.txt \
   186	  resources/free.txt \
   187	  storage/df.txt \
   188	  storage/lsblk.txt \
   189	  network/ip-addr.txt \
   190	  kernel/dmesg.txt \
   191	  systemd/failed-units.txt \
   192	  cephadm/cephadm-ls.json \
   193	  logs/ceph-log-listing.txt; do
   194	  [[ -f "$outdir/$artifact" ]] || fail "missing artifact: $artifact"
   195	done
   196	
   197	assert_file_contains "$outdir/cephadm/cephadm-ls.json" '"style":"cephadm"'
   198	assert_file_contains "$outdir/kernel/dmesg.txt" 'fake kernel ring buffer'
   199	assert_file_contains "$outdir/containers/docker-ps.txt" 'fake docker'
   200	assert_file_contains "$outdir/logs/ceph-log-listing.txt" "$fake_log_dir"
   201	assert_file_contains "$outdir/time/ntpq-peers.txt" 'SKIPPED: command not found: ntpq'
   202	
   203	[[ -f "$outdir/logs/ceph/ceph.log" ]] || fail "missing copied current ceph log"
   204	[[ -f "$outdir/logs/ceph/ceph.log.1" ]] || fail "missing copied rotated ceph log"
   205	[[ -f "$outdir/logs/ceph/ceph-osd.0.log.1" ]] || fail "missing copied rotated osd log"
   206	[[ -f "$outdir/logs/ceph/ceph.log.2.gz" ]] || fail "missing copied gz ceph log"
   207	# R2: oversized logs are tail-captured (not silently dropped) with a marker
   208	[[ -f "$outdir/logs/ceph/ceph-too-large.log" ]] || fail "oversized ceph log should be tail-captured"
   209	toobig_bytes="$(wc -c <"$outdir/logs/ceph/ceph-too-large.log" | tr -d '[:space:]')"
   210	[[ "$toobig_bytes" -le 128 ]] || fail "oversized ceph log tail should be <= cap (got $toobig_bytes)"
   211	[[ -f "$outdir/logs/ceph/ceph-too-large.log.TRUNCATED" ]] || fail "oversized ceph log missing .TRUNCATED marker"
   212	assert_file_contains "$outdir/logs/ceph/ceph-too-large.log.TRUNCATED" "original_bytes="
   213	
   214	[[ -f "$outdir/cephadm/var-lib-ceph-configs/fsid/mon.a/config" ]] || fail "missing copied var-lib ceph config"
   215	[[ ! -e "$outdir/cephadm/var-lib-ceph-configs/fsid/mon.a/keyring" ]] || fail "keyring should not be copied from var-lib ceph"
   216	if grep -qF 'keyring' "$outdir/cephadm/var-lib-ceph-listing.txt"; then
   217	  fail "var-lib ceph listing should exclude keyrings"
   218	fi
   219	
   220	grep -qF 'iostat <-xz> <1> <3>' "$FAKE_OPTIONAL_LOG" || fail "iostat argv was not preserved"
   221	grep -qF 'pvs <--noheadings> <--separator> < >' "$FAKE_OPTIONAL_LOG" || fail "pvs separator argv was not preserved"
   222	grep -qF 'vgs <--noheadings> <--separator> < >' "$FAKE_OPTIONAL_LOG" || fail "vgs separator argv was not preserved"
   223	grep -qF 'lvs <--noheadings> <--separator> < >' "$FAKE_OPTIONAL_LOG" || fail "lvs separator argv was not preserved"
   224	
   225	grep -qF -- '-n dmesg' "$FAKE_SUDO_LOG" || fail "dmesg was not collected through sudo -n"
   226	
   227	# C8: dmesg and ceph journal get a heavier timeout than the per-command --timeout (5),
   228	# so large kernel ring / journals are not silently truncated.
   229	assert_file_contains "$outdir/kernel/dmesg.txt" '# timeout: 120s'
   230	assert_file_contains "$outdir/systemd/journal-ceph.txt" '# timeout: 120s'
   231	
   232	outdir_no_ceph_journal="$tmpdir/node-no-ceph-journal"
   233	set +e
   234	FAKE_JOURNALCTL_NO_CEPH=1 \
   235	CEPH_INCIDENT_VAR_LOG_CEPH_DIR="$fake_log_dir" \
   236	CEPH_INCIDENT_VAR_LIB_CEPH_DIR="$fake_var_lib" \
   237	CEPH_INCIDENT_LOG_FILE_CAP_BYTES=128 \
   238	bash "$ROOT/lib/collect-node.sh" \
   239	  --out "$outdir_no_ceph_journal" \
   240	  --host-alias kubenode \
   241	  --since "24h" \
   242	  --timeout 5 \
   243	  --skip-logs
   244	rc=$?
   245	set -e
   246	[[ "$rc" == "0" ]] || fail "missing ceph journal should not fail non-ceph node collection (got $rc)"
   247	assert_file_contains "$outdir_no_ceph_journal/systemd/journal-ceph.txt" 'no entries'

exec
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/tests/test-verify-bundle.sh' in /Users/ikaros/Documents/code/learning-k8s
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
/bin/zsh -lc 'nl -ba experiments/ceph-incident-bundle/README.md' in /Users/ikaros/Documents/code/learning-k8s
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
    18	## 前置需求（known_hosts）
    19	
    20	工具的 SSH 都用 `BatchMode=yes`(不互動),所以**第一次從一台新跳板機執行前**,跳板機的 `known_hosts` 必須已經有所有目標 node 的 host key,否則每台會以 `Host key verification failed` 失敗、被標 SKIPPED(exit 2)。先做一次:
    21	
    22	```bash
    23	# 對 inventory 裡每台 host 先建立 host key（擇一）
    24	ssh-keyscan -H 192.168.18.166 192.168.18.167 ... >> ~/.ssh/known_hosts
    25	# 或手動 ssh 每台一次，確認指紋後接受
    26	```
    27	
    28	## 最短操作流程
    29	
    30	在 repo root 執行：
    31	
    32	```bash
    33	bash experiments/ceph-incident-bundle/run/collect.sh \
    34	  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
    35	  --ssh-key .ssh/id_ed25519 \
    36	  --seed ikaros@192.168.18.166 \
    37	  --mode cephadm \
    38	  --since 24h
    39	```
    40	
    41	成功後會看到：
    42	
    43	```text
    44	bundle: experiments/ceph-incident-bundle/results/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
    45	```
    46	
    47	驗證 bundle：
    48	
    49	```bash
    50	bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle.tar.gz>
    51	```
    52	
    53	## 如何填 inventory
    54	
    55	Inventory 是 shell 檔案，格式如下：
    56	
    57	```bash
    58	SSH_USER="ikaros"
    59	SEED_HOST="192.168.18.166"
    60	ROOK_NAMESPACE="rook-ceph"
    61	HOSTS=(
    62	  "monitor01=192.168.18.166"
    63	  "mon02=192.168.18.167"
    64	  "osd01=192.168.18.169"
    65	)
    66	```
    67	
    68	- `SSH_USER`：登入每台 node 的 Linux 帳號。
    69	- `SEED_HOST`：**選填**。手動指定 cluster-level `ceph` command 要在哪台跑;不填則 `auto` 會自動挑第一台有 `cephadm` 的 node。
    70	- `ROOK_NAMESPACE`：Rook 的 namespace，未填時預設 `rook-ceph`。
    71	- `HOSTS`：每個項目是 `alias=host`，alias 會成為 bundle 裡 `nodes/<alias>/` 的目錄名稱。external-ceph rook 拓樸可以把 **external ceph 主機與 k8s node 混在同一份** `HOSTS` 裡。
    72	
    73	## 自動偵測（auto，預設）
    74	
    75	預設 `--mode auto` 會逐台 node 經 ssh 偵測能力，再分層收集：
    76	
    77	- node 上有 `ceph` 或 `cephadm` → 從**第一台連得上 cluster** 的 node 收 cluster-level ceph。執行方式優先序：直接 `ceph`（最快，免每條起 container）→ `sudo -n ceph` → `sudo -n cephadm shell -- ceph`。「可用」= `ceph -s` 連得上,不是 binary 存在;選到哪個會記在進度（`via ceph` / `via cephadm shell`）與 `environment.txt` 的 `ceph_runner=`。
    78	- rook 層的 `kubectl` 由 `--kube-mode` 決定（預設 `remote`）：
    79	  - `remote`（預設）：從**第一台**有 kubectl 的 inventory node、用 ssh 在該 node 上跑 `kubectl`。
    80	  - `local`：在**執行工具的跳板機本機**跑 `kubectl`（kubectl/kubeconfig 在跳板機、不在 node 上時用這個）。
    81	  - 兩種都可配 `--kube-context`。
    82	- 兩層都有來源就都收、各收一次;node 層一律每台都收。
    83	
    84	```bash
    85	bash experiments/ceph-incident-bundle/run/collect.sh \
    86	  --inventory experiments/ceph-incident-bundle/inventory/ceph-lab.example.env \
    87	  --ssh-key .ssh/id_ed25519 \
    88	  --since 24h
    89	```
    90	
    91	## external ceph + rook（一份 inventory）
    92	
    93	把 external ceph 主機和有 `kubectl` 的 k8s node 列進同一份 `HOSTS`，`auto` 會：ceph 層從 ceph 主機收、rook 層在 k8s node 上跑 kubectl 收。指定 context：
    94	
    95	```bash
    96	SSH_USER="ikaros"
    97	HOSTS=(
    98	  "mon01=10.0.0.1"     # external ceph（有 cephadm）
    99	  "osd01=10.0.0.2"     # external ceph
   100	  "k8s1=10.0.0.9"      # k8s node（有 kubectl）
   101	)
   102	```
   103	
   104	```bash
   105	bash experiments/ceph-incident-bundle/run/collect.sh \
   106	  --inventory inventory/external.env \
   107	  --ssh-key ~/.ssh/id_ed25519 \
   108	  --kube-context my-cluster \
   109	  --since 24h
   110	```
   111	
   112	## 只收單層（覆寫）
   113	
   114	- `--mode cephadm`（可配 `--seed USER@HOST`）：只收 ceph 層。
   115	- `--mode rook`：只收 rook 層（在第一台有 kubectl 的 node 上跑）。
   116	
   117	## auto 的限制（已知）
   118	
   119	- **來源挑「第一台」、不看 liveness**：cluster-ceph 取第一台有 `cephadm` 的 node、cluster-rook 取第一台有 `kubectl` 的 node;只看指令存在、不檢查該 node 的 ceph/k8s 是否健康,也不會自動 fallback 到第二台。若想釘住一台已知健康的 mon,用 `--seed USER@HOST`。
   120	- **探測是逐台序列 ssh**:某層的能力完全不存在時(例如純 cephadm 叢集仍會為了 rook 掃完每台),或 node 沒回應時,探測會逐台等到 `ConnectTimeout`。大型 inventory 建議直接用 `--mode cephadm --seed ...` 跳過探測。探測 ssh 失敗的 node 會記進 `errors.log`(`capability probe failed for ...`),不會被當成「沒有該能力」而靜默忽略。
   121	
   122	## 逾時與大型 log
   123	
   124	- `--timeout`（預設 20s）是**單一指令 / SSH 連線**的逾時。
   125	- `--node-timeout`（預設 600s）是**單一 node 整輪收集**的逾時。兩者分開：慢或大的 node 不會被單指令逾時誤殺。
   126	- 大型 Ceph log（超過 `CEPH_INCIDENT_LOG_FILE_CAP_BYTES`，預設 1 MiB）不會被靜默丟棄，而是收最後一段（tail）並附 `<檔名>.TRUNCATED` 記錄原始大小；壓縮過的 `*.gz` 過大時則只記錄、不收（gzip 的尾段無法解壓）。
   127	- 被逾時砍掉（exit 124/137）的指令輸出會在 artifact 末尾標 `# TRUNCATED`，讓判讀者知道內容被截斷。
   128	- **工作機若沒有 `timeout` / `gtimeout`**（如預設 macOS），會在開頭印警告；此時外層逾時停用，只靠 SSH `ConnectTimeout` / `ServerAlive` 把關。要完整把關可 `brew install coreutils`（提供 `gtimeout`），或在 Linux ops 機執行。
   129	
   130	## 進度顯示
   131	
   132	執行時會把進度印到 **stderr**（探測每台 node、cluster ceph 的逐條指令 `[k/24]`、每台 node 收集、redact/verify/packaging）。**stdout 只會有最後一行 `bundle: <path>`**，方便 script 直接抓。
   133	
   134	要安靜（cron / 腳本）加 `--quiet`：不印進度,但 `bundle:` 與錯誤訊息照舊。
   135	
   136	```bash
   137	# 看得到進度（預設）
   138	bash .../run/collect.sh --inventory inv.env --ssh-key key --since 24h
   139	# 安靜，只取 bundle 路徑
   140	BUNDLE=$(bash .../run/collect.sh --inventory inv.env --ssh-key key --since 24h --quiet | sed 's/^bundle: //')
   141	```
   142	
   143	## bundle 內有什麼
   144	
   145	主要檔案：
   146	
   147	- `README-FIRST.txt`：打開 bundle 後先看的入口。
   148	- `summary.txt`：本次收集摘要與成功/失敗數。
   149	- `environment.txt`：收集時間、mode、seed、git commit。
   150	- `manifest.jsonl`：每個 artifact 的 command、exit code、時間。
   151	- `errors.log`：非零 exit code、SSH 失敗、部分失敗。
   152	- `cluster/`：cephadm 或 Rook cluster-level 狀態。
   153	- `nodes/<alias>/`：每台 node 的系統、資源、disk、kernel、systemd、Ceph log 與 cephadm 狀態。
   154	
   155	## exit code 怎麼看
   156	
   157	- `0`：收集完成，沒有已知失敗。（注意：OSD/MON down 這類**叢集故障本身**會被收進 bundle，不算收集失敗，仍是 `0`。）
   158	- `2`：有部分 command 或部分 node 失敗，但 bundle 已產生。先看 `errors.log` 和 `summary.txt`。
   159	- `1`：使用方式或必要輸入錯誤（inventory / SSH key 不存在），或 **bundle 驗證失敗**。驗證失敗時不會打包可分享的 `.tar.gz`，而是**保留 workdir**（印出路徑）讓你檢查——已收集的證據不會因驗證失敗被刪掉。
   160	
   161	## 常見失敗與處理
   162	
   163	- `missing inventory`：確認 `--inventory` 路徑存在。
   164	- `missing ssh key`：確認 `--ssh-key` 路徑存在，且本機可讀。
   165	- `node <alias> collector exited 255` / `Host key verification failed`：SSH 連線、帳號、key、**known_hosts**(見上方「前置需求」)或 sudo 權限問題。新跳板機最常見的是 known_hosts 還沒有該 node 的 host key。
   166	- `VERIFY FAIL`：bundle 結構不完整，或包含 `keyring`、`.ssh`、`id_ed25519`、`private_key`、`*.pem`/`*.key`/`*.crt` 這類路徑，或檔案內容殘留未遮蔽的 private key / `key = <base64>` 金鑰材料。此時 workdir 會被保留、不打包，先看印出的路徑與 `errors.log`。
   167	- exit code `2`：先不要重跑覆蓋判讀脈絡，先保留 `.tar.gz`，再看 `errors.log` 決定是否針對失敗 node 補跑。
   168	
   169	## 安全界線
   170	
   171	- 這套工具以 read-only 收集為原則，不會主動修復或改變 Ceph 狀態。
   172	- 遮蔽（redaction）涵蓋：含 `password`/`secret`/`token`/`keyring`/`private key` 的文字行、Ceph 金鑰材料（`key = AQB..==` 與 base64 區塊）、整段多行 PEM private key block；並會把 `*.gz` 解壓後遮蔽再壓回。但這**不是完整 DLP**。
   173	- `verify-bundle.sh` 會以**檔名**（keyring/.ssh/id_ed25519/private_key/*.pem/*.key/*.crt）與**內容**（殘留的 PRIVATE KEY block / `key = <base64>`）兩道把關，但仍不能保證內容完全沒有敏感資料。
   174	- 分享 bundle 前仍應自行檢查是否包含內部 IP、hostname、路徑、帳號名稱或其他敏感資料。
   175	
   176	## Lab 驗證（multi-fault）
   177	
   178	2026-06-30 在真 cephadm v19.2.3 叢集（3 mon + 9 OSD、pool `.mgr` size 3）跑過多故障矩陣，破壞性情境皆先 `ok-to-stop` / 確認 quorum 後注入並立即回退，最後 HEALTH_OK：
   179	
   180	| 情境 | 注入 | bundle | exit |
   181	|---|---|---|---|
   182	| 健康基準 | 無 | VERIFY PASS、6/6 node、312 行遮蔽 | 0 |
   183	| OSD down | 停 osd.0 | 收到 `OSD_DOWN`（text+json）| 0 |
   184	| MON 少一台 | 停 mon-02（quorum 在）| 收到 `MON_DOWN`（out of quorum）| 0 |
   185	| node 不可達 | inventory 加假 host | 該 node `SKIPPED.txt`、其餘照收、errors.log 有記 | 2 |
   186	| seed 不可達 | `--seed` 指死 host | cluster collector 失敗、6 node 仍收 | 2 |
   187	
   188	詳見 `docs/superpowers/reviews/2026-06-30-lab-validation.md`。
   189	
   190	- 已知 optional/read-only 非零紀錄：各 node 的 LVM 查詢（`pvs` / `vgs` / `lvs`）、`docker ps -a`、node-level `sudo cephadm ls --format json-pretty` 可能回非零；artifact 與 node 內部 `errors.log` 會保留原始輸出，整體 bundle 仍驗證通過。

exec
/bin/zsh -lc "rg -n \"BatchMode=yes|IdentitiesOnly=yes|IdentityAgent=none|ConnectTimeout|ServerAliveInterval|ServerAliveCountMax|SKIPPED:|while \\[\\[ \\"'$# -gt 0 '"\\]\\]|run_capture|usage\\(\\)|local .*\\"'$1.*'"\\"'$2.*'"\\"'$3.*'"\\"'$4.*'"\\"'$5.*'"\\"'$6" experiments/ceph-incident-bundle/run experiments/ceph-incident-bundle/lib experiments/ceph-incident-bundle/tests' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:86:  grep -qF 'ConnectTimeout=30' "$ssh_log" || fail "cluster ssh missing ConnectTimeout"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:87:  grep -qF 'ServerAliveInterval=30' "$ssh_log" || fail "cluster ssh missing ServerAliveInterval"
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:34:    run_capture "$manifest" "$seed" "collect-cluster-cephadm" "$artifact" -- \
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:37:      -o BatchMode=yes \
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:38:      -o IdentitiesOnly=yes \
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:39:      -o IdentityAgent=none \
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:40:      -o "ConnectTimeout=$timeout" \
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:41:      -o "ServerAliveInterval=$timeout" \
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:42:      -o ServerAliveCountMax=1 \
experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:51:SKIPPED: unable to parse crash list JSON for recent crash inspection
experiments/ceph-incident-bundle/lib/collect-node.sh:10:usage() {
experiments/ceph-incident-bundle/lib/collect-node.sh:19:  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
experiments/ceph-incident-bundle/lib/collect-node.sh:22:node_run_capture() {
experiments/ceph-incident-bundle/lib/collect-node.sh:28:    run_capture "$manifest" "$host_alias" "collect-node" "$artifact" -- "$@"; then
experiments/ceph-incident-bundle/lib/collect-node.sh:43:  node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" "$command_name" "$@" || return 0
experiments/ceph-incident-bundle/lib/collect-node.sh:51:    node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" "$command_name" "$@"
experiments/ceph-incident-bundle/lib/collect-node.sh:60:  node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact_rel" sudo -n "$command_name" "$@"
experiments/ceph-incident-bundle/lib/collect-node.sh:173:    printf 'SKIPPED: %s is not a readable directory on this node\n' "$log_dir" >"$listing"
experiments/ceph-incident-bundle/lib/collect-node.sh:338:    if ! node_run_capture "$outdir" "$manifest" "$host_alias" "$timeout" "$artifact" "${command_words[@]}"; then
experiments/ceph-incident-bundle/lib/common.sh:148:run_capture() {
experiments/ceph-incident-bundle/lib/common.sh:151:  [[ ${1-} == -- ]] || die "run_capture requires -- before the command"
experiments/ceph-incident-bundle/lib/common.sh:158:  [[ ${#cmd[@]} -gt 0 ]] || die "run_capture requires a command"
experiments/ceph-incident-bundle/tests/test-common.sh:238:test_run_capture_success() {
experiments/ceph-incident-bundle/tests/test-common.sh:242:  run_capture "$manifest" "host-a" "collector-a" "$artifact" -- printf 'hello world\n'
experiments/ceph-incident-bundle/tests/test-common.sh:262:test_run_capture_non_zero_writes_error_log_and_returns_code() {
experiments/ceph-incident-bundle/tests/test-common.sh:268:  ERROR_LOG="$error_log" run_capture "$manifest" "host-b" "collector-b" "$artifact" -- bash -c 'printf fail-output; exit 7' || rc=$?
experiments/ceph-incident-bundle/tests/test-common.sh:269:  [[ "$rc" == "7" ]] || fail "run_capture returned $rc instead of 7"
experiments/ceph-incident-bundle/tests/test-common.sh:282:test_run_capture_missing_double_dash_is_fatal() {
experiments/ceph-incident-bundle/tests/test-common.sh:296:      run_capture "$MANIFEST" "host-c" "collector-c" "$ARTIFACT" printf "missing-dash\n"
experiments/ceph-incident-bundle/tests/test-common.sh:301:  [[ "$rc" != "0" ]] || fail "run_capture accepted missing --"
experiments/ceph-incident-bundle/tests/test-common.sh:305:test_run_capture_timeout_branch() {
experiments/ceph-incident-bundle/tests/test-common.sh:319:  PATH="$fakebin:$PATH" TIMEOUT_LOG="$timeout_log" run_capture "$manifest" "host-d" "collector-d" "$artifact" -- printf 'timeout-path\n'
experiments/ceph-incident-bundle/tests/test-common.sh:326:test_run_capture_handles_leading_dash_artifact() {
experiments/ceph-incident-bundle/tests/test-common.sh:333:    run_capture "$manifest" "host-dash" "collector-dash" "-leading-dash.txt" -- printf 'dash-safe\n'
experiments/ceph-incident-bundle/tests/test-common.sh:340:test_run_capture_preserves_errexit_state() {
experiments/ceph-incident-bundle/tests/test-common.sh:346:  run_capture "$manifest" "host-e" "collector-e" "$artifact" -- bash -c 'exit 3'
experiments/ceph-incident-bundle/tests/test-common.sh:352:  [[ "$status" == "1" ]] || fail "run_capture changed errexit state"
experiments/ceph-incident-bundle/tests/test-common.sh:367:test_run_capture_success
experiments/ceph-incident-bundle/tests/test-common.sh:368:test_run_capture_non_zero_writes_error_log_and_returns_code
experiments/ceph-incident-bundle/tests/test-common.sh:369:test_run_capture_missing_double_dash_is_fatal
experiments/ceph-incident-bundle/tests/test-common.sh:370:test_run_capture_timeout_branch
experiments/ceph-incident-bundle/tests/test-common.sh:371:test_run_capture_handles_leading_dash_artifact
experiments/ceph-incident-bundle/tests/test-common.sh:372:test_run_capture_preserves_errexit_state
experiments/ceph-incident-bundle/lib/verify-bundle.sh:6:usage() {
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:13:usage() {
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:25:  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:31:  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:34:rook_run_capture() {
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:40:    run_capture "$manifest" "rook" "collect-cluster-rook" "$artifact" -- "$@"; then
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:124:    ROOK_KUBECTL_ARGV=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$ssh_target" kubectl)
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:146:  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/pods-wide.txt" \
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:150:  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/events.txt" \
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:154:  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/rook-resources.yaml" \
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:162:    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:172:    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
experiments/ceph-incident-bundle/run/collect.sh:15:usage() {
experiments/ceph-incident-bundle/run/collect.sh:133:  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v ceph >/dev/null 2>&1 && caps="$caps ceph"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
experiments/ceph-incident-bundle/run/collect.sh:155:  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" "${pfx[@]}" --connect-timeout 5 -s)
experiments/ceph-incident-bundle/run/collect.sh:260:    [[ -f "$workdir/cluster/ceph/SKIPPED.txt" ]] || printf 'SKIPPED: no cephadm-capable node found (or --seed unreachable)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:264:    [[ -f "$workdir/cluster/rook/SKIPPED.txt" ]] || printf 'SKIPPED: no kubectl-capable node found\n' >"$workdir/cluster/rook/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:270:      [[ -f "$workdir/cluster/ceph/SKIPPED.txt" ]] || printf 'SKIPPED: no cephadm-capable node in inventory (auto)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:274:      [[ -f "$workdir/cluster/rook/SKIPPED.txt" ]] || printf 'SKIPPED: no kubectl-capable node in inventory (auto)\n' >"$workdir/cluster/rook/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:306:  remote_cmd="set -u; tmp=\"\${TMPDIR:-/tmp}/ceph-incident-node.\$\$\"; rm -rf \"\$tmp\"; mkdir -p \"\$tmp\" || { printf 'SKIPPED: remote tmp not writable\n' >&2; exit 75; }; trap 'rm -rf \"\$tmp\"' EXIT INT TERM; gzip -dc | tar -xf - -C \"\$tmp\"; out=\"\$tmp/out\"; set +e; bash \"\$tmp/lib/collect-node.sh\" --out \"\$out\" --host-alias $q_alias --since $q_since --timeout $q_timeout"
experiments/ceph-incident-bundle/run/collect.sh:310:  remote_cmd+="; rc=\$?; set -e; if [ -d \"\$out\" ]; then tar -cf - -C \"\$out\" . | gzip -c; else mkdir -p \"\$out\"; printf 'SKIPPED: remote collect-node did not create output\n' >\"\$out/SKIPPED.txt\"; tar -cf - -C \"\$out\" . | gzip -c; fi; exit \"\$rc\""
experiments/ceph-incident-bundle/run/collect.sh:312:  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" "$remote_cmd")
experiments/ceph-incident-bundle/run/collect.sh:337:    printf 'SKIPPED: node collection timed out after %ss (exit %s) from %s\n' "$node_timeout" "$rc" "$target" >"$node_dir/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:346:      printf 'SKIPPED: node archive from %s is incomplete (no manifest.jsonl); treated as failure\n' "$target" >"$node_dir/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:352:    printf 'SKIPPED: no usable node archive returned from %s (ssh exit %s)\n' "$target" "$rc" >"$node_dir/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:497:    log "WARNING: no 'timeout'/'gtimeout' found on this workstation; outer timeouts are disabled — relying on SSH ConnectTimeout/ServerAlive only (install coreutils for full bounding)"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:201:assert_file_contains "$outdir/time/ntpq-peers.txt" 'SKIPPED: command not found: ntpq'

codex
I have enough for the ranked review. I’m not running the suite because the request is design-only and the sandbox is read-only; all recommendations will be behavior-preserving refactors that should be gated by `tests/run-tests.sh` and `shellcheck` afterward.
exec
/bin/zsh -lc "rg -n \"parse_host_entry|ceph_incident_bundle_log|require_file|copy_if_exists|rook_skip|rook_write_skip_artifact|write_skip_artifact|run_and_capture|assert_file_contains|fail\\(\\)\" experiments/ceph-incident-bundle" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/run/collect.sh:53:parse_host_entry() {
experiments/ceph-incident-bundle/lib/verify-bundle.sh:15:verify_fail() {
experiments/ceph-incident-bundle/lib/common.sh:16:ceph_incident_bundle_log() {
experiments/ceph-incident-bundle/lib/common.sh:20:require_file() {
experiments/ceph-incident-bundle/lib/common.sh:72:  require_file "$source_file"
experiments/ceph-incident-bundle/lib/common.sh:127:  require_file "$source_file"
experiments/ceph-incident-bundle/lib/common.sh:206:copy_if_exists() {
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:21:rook_skip() {
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:28:rook_write_skip_artifact() {
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:135:    rook_skip "$outdir" "kubectl command not found"
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:140:    rook_skip "$outdir" "namespace not found (or kubectl unavailable on ${ssh_target:-local}): $namespace"
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:167:    rook_write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found in namespace: $operator_namespace"
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:177:    rook_write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
experiments/ceph-incident-bundle/lib/collect-node.sh:16:write_skip_artifact() {
experiments/ceph-incident-bundle/lib/collect-node.sh:39:    write_skip_artifact "$outdir/$artifact_rel" "command not found: $command_name"
experiments/ceph-incident-bundle/lib/collect-node.sh:56:    write_skip_artifact "$outdir/$artifact_rel" "sudo command not found for privileged read: $command_name"
experiments/ceph-incident-bundle/lib/collect-node.sh:150:    copy_if_exists "$source" "$outdir/system/$dest_name"
experiments/ceph-incident-bundle/lib/collect-node.sh:249:    write_skip_artifact "$outdir/cephadm/var-lib-ceph-listing.txt" "$ceph_dir is not a readable directory on this node"
experiments/ceph-incident-bundle/lib/collect-node.sh:384:    write_skip_artifact "$outdir/cephadm/cephadm-ls.json" "command not found: cephadm"
experiments/ceph-incident-bundle/lib/collect-node.sh:393:    write_skip_artifact "$outdir/logs/ceph-log-listing.txt" "log collection disabled by --skip-logs"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:7:fail() {
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:12:assert_file_contains() {
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:52:assert_file_contains "$out_no_kubectl/cluster/rook/SKIPPED.txt" "kubectl command not found"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:69:assert_file_contains "$out_no_kubectl_skip/cluster/rook/SKIPPED.txt" "kubectl command not found"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:144:assert_file_contains "$out_missing_ns/cluster/rook/SKIPPED.txt" "namespace not found"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:150:assert_file_contains "$out_present/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:151:assert_file_contains "$out_present/cluster/rook/events.txt" "osd started"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:152:assert_file_contains "$out_present/cluster/rook/rook-resources.yaml" "kind: CephCluster"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:153:assert_file_contains "$out_present/cluster/rook/operator.log" "operator log line"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:154:assert_file_contains "$out_present/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:167:assert_file_contains "$out_external/cluster/rook/rook-resources.yaml" "name: rook-ceph-external"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:168:assert_file_contains "$out_external/cluster/rook/operator.log" "operator log line"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:197:assert_file_contains "$out_remote/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:198:assert_file_contains "$out_remote/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:211:assert_file_contains "$out_oplookup/cluster/rook/operator-SKIPPED.txt" "operator Pod not found"
experiments/ceph-incident-bundle/tests/fixtures/bin/ssh:22:maybe_fail() {
experiments/ceph-incident-bundle/tests/test-common.sh:6:fail() {
experiments/ceph-incident-bundle/tests/test-node-collector.sh:6:fail() {
experiments/ceph-incident-bundle/tests/test-node-collector.sh:11:assert_file_contains() {
experiments/ceph-incident-bundle/tests/test-node-collector.sh:197:assert_file_contains "$outdir/cephadm/cephadm-ls.json" '"style":"cephadm"'
experiments/ceph-incident-bundle/tests/test-node-collector.sh:198:assert_file_contains "$outdir/kernel/dmesg.txt" 'fake kernel ring buffer'
experiments/ceph-incident-bundle/tests/test-node-collector.sh:199:assert_file_contains "$outdir/containers/docker-ps.txt" 'fake docker'
experiments/ceph-incident-bundle/tests/test-node-collector.sh:200:assert_file_contains "$outdir/logs/ceph-log-listing.txt" "$fake_log_dir"
experiments/ceph-incident-bundle/tests/test-node-collector.sh:201:assert_file_contains "$outdir/time/ntpq-peers.txt" 'SKIPPED: command not found: ntpq'
experiments/ceph-incident-bundle/tests/test-node-collector.sh:212:assert_file_contains "$outdir/logs/ceph/ceph-too-large.log.TRUNCATED" "original_bytes="
experiments/ceph-incident-bundle/tests/test-node-collector.sh:229:assert_file_contains "$outdir/kernel/dmesg.txt" '# timeout: 120s'
experiments/ceph-incident-bundle/tests/test-node-collector.sh:230:assert_file_contains "$outdir/systemd/journal-ceph.txt" '# timeout: 120s'
experiments/ceph-incident-bundle/tests/test-node-collector.sh:247:assert_file_contains "$outdir_no_ceph_journal/systemd/journal-ceph.txt" 'no entries'
experiments/ceph-incident-bundle/tests/run-tests.sh:6:fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
experiments/ceph-incident-bundle/tests/run-tests.sh:9:run_and_capture() {
experiments/ceph-incident-bundle/tests/run-tests.sh:37:collect_no_args="$(run_and_capture "$ROOT/run/collect.sh")"
experiments/ceph-incident-bundle/tests/run-tests.sh:43:verify_no_args="$(run_and_capture "$ROOT/lib/verify-bundle.sh")"
experiments/ceph-incident-bundle/tests/run-tests.sh:49:verify_placeholder_args="$(run_and_capture "$ROOT/lib/verify-bundle.sh" /tmp/definitely-not-a-bundle)"
experiments/ceph-incident-bundle/tests/run-tests.sh:55:collect_placeholder_args="$(run_and_capture "$ROOT/run/collect.sh" --inventory /tmp/example.env --ssh-key /tmp/id_ed25519 --seed 192.168.18.166)"
experiments/ceph-incident-bundle/tests/run-tests.sh:61:common_helpers_args="$(run_and_capture "$ROOT/tests/test-common.sh")"
experiments/ceph-incident-bundle/tests/run-tests.sh:66:verify_bundle_args="$(run_and_capture "$ROOT/tests/test-verify-bundle.sh")"
experiments/ceph-incident-bundle/tests/run-tests.sh:71:cephadm_collector_args="$(run_and_capture "$ROOT/tests/test-cephadm-collector.sh")"
experiments/ceph-incident-bundle/tests/run-tests.sh:76:node_collector_args="$(run_and_capture "$ROOT/tests/test-node-collector.sh")"
experiments/ceph-incident-bundle/tests/run-tests.sh:81:rook_collector_args="$(run_and_capture "$ROOT/tests/test-rook-collector.sh")"
experiments/ceph-incident-bundle/tests/run-tests.sh:86:collect_args="$(run_and_capture "$ROOT/tests/test-collect.sh")"
experiments/ceph-incident-bundle/tests/test-collect.sh:6:fail() {
experiments/ceph-incident-bundle/tests/test-collect.sh:11:run_and_capture() {
experiments/ceph-incident-bundle/tests/test-collect.sh:38:help_result="$(run_and_capture "$ROOT/run/collect.sh" --help)"
experiments/ceph-incident-bundle/tests/test-collect.sh:45:missing_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$tmpdir/missing.env")"
experiments/ceph-incident-bundle/tests/test-collect.sh:359:empty_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$inv_empty" --ssh-key "$ssh_key" --mode cephadm --seed t@1.2.3.4)"
experiments/ceph-incident-bundle/tests/test-collect.sh:366:ctx_bad="$(run_and_capture "$ROOT/run/collect.sh" --kube-context 'bad;ctx' --inventory "$inventory" --ssh-key "$ssh_key")"
experiments/ceph-incident-bundle/tests/test-collect.sh:373:ctx_ok="$(run_and_capture "$ROOT/run/collect.sh" --kube-context 'arn:aws:eks:us-east-1:1/x@k8s' --inventory /nope.env --ssh-key "$ssh_key")"
experiments/ceph-incident-bundle/tests/test-collect.sh:428:km_bad="$(run_and_capture "$ROOT/run/collect.sh" --kube-mode bogus --inventory "$inventory" --ssh-key "$ssh_key")"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:6:fail() {
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:39:assert_file_contains() {
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:73:  assert_file_contains "$outdir/cluster/ceph/text/status.txt" "cluster is healthy"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:74:  assert_file_contains "$outdir/cluster/ceph/text/health-detail.txt" "HEALTH_OK"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:75:  assert_file_contains "$outdir/cluster/ceph/text/orch-ps.txt" "NAME HOST STATUS"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:76:  assert_file_contains "$outdir/cluster/ceph/json/status.json" "\"health\":\"HEALTH_OK\""
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:77:  assert_file_contains "$outdir/cluster/ceph/json/crash-info/crash-01.json" "\"crash_id\":\"crash-01\""
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:78:  assert_file_contains "$outdir/cluster/ceph/json/crash-info/crash_02.json" "\"crash_id\":\"crash/02\""
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:79:  assert_file_contains "$outdir/cluster/ceph/json/crash-info/crash_02-2.json" "\"crash_id\":\"crash:02\""
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:107:  assert_file_contains "$outdir/cluster/ceph/json/osd-perf.json" "simulated failure"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:123:  assert_file_contains "$outdir/cluster/ceph/text/crash-info-skip.txt" "SKIPPED"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:6:fail() {
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:11:run_and_capture() {
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:47:  result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$target")"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:54:assert_fail() {
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:58:  result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$target")"
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh:179:extra_args_result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$valid_dir" extra)"

exec
/bin/zsh -lc "find experiments/ceph-incident-bundle/tests -maxdepth 1 -name '*.sh' -print -exec wc -l {} \\;" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
     183 experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
experiments/ceph-incident-bundle/tests/run-tests.sh
      91 experiments/ceph-incident-bundle/tests/run-tests.sh
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh
     170 experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh
experiments/ceph-incident-bundle/tests/test-common.sh
     374 experiments/ceph-incident-bundle/tests/test-common.sh
experiments/ceph-incident-bundle/tests/test-node-collector.sh
     247 experiments/ceph-incident-bundle/tests/test-node-collector.sh
experiments/ceph-incident-bundle/tests/test-collect.sh
     455 experiments/ceph-incident-bundle/tests/test-collect.sh
experiments/ceph-incident-bundle/tests/test-rook-collector.sh
     211 experiments/ceph-incident-bundle/tests/test-rook-collector.sh

exec
/bin/zsh -lc 'wc -l experiments/ceph-incident-bundle/run/collect.sh experiments/ceph-incident-bundle/lib/*.sh experiments/ceph-incident-bundle/tests/*.sh experiments/ceph-incident-bundle/README.md' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
     604 experiments/ceph-incident-bundle/run/collect.sh
     215 experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh
     186 experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
     411 experiments/ceph-incident-bundle/lib/collect-node.sh
     211 experiments/ceph-incident-bundle/lib/common.sh
     124 experiments/ceph-incident-bundle/lib/verify-bundle.sh
      91 experiments/ceph-incident-bundle/tests/run-tests.sh
     170 experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh
     455 experiments/ceph-incident-bundle/tests/test-collect.sh
     374 experiments/ceph-incident-bundle/tests/test-common.sh
     247 experiments/ceph-incident-bundle/tests/test-node-collector.sh
     211 experiments/ceph-incident-bundle/tests/test-rook-collector.sh
     183 experiments/ceph-incident-bundle/tests/test-verify-bundle.sh
     190 experiments/ceph-incident-bundle/README.md
    3672 total

codex
No HIGH findings. The tool is generally well-contained for bash, but there are several maintainability issues worth cleaning up before it grows.

- MEDIUM | [run/collect.sh:392](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:392) | SRP/KISS: `collect.sh` is a 604-line entrypoint that owns CLI parsing, inventory normalization, cluster source selection, remote node bootstrap, redaction, verification, packaging, cleanup.  
  Fix: keep `run/collect.sh` as a thin CLI/orchestrator and move stable units into `lib/inventory.sh`, `lib/collect-remote-node.sh`, and `lib/package-bundle.sh`.

- MEDIUM | [run/collect.sh:177](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:177) | Interface clarity: `collect_clusters` takes 11 positional args plus reads global `HOST_TARGETS`. This is hard to audit and easy to mis-call.  
  Fix: convert internal calls to named options, matching `collect_cluster_rook`: `collect_clusters --mode "$mode" --workdir "$workdir" ...`. Keep public CLI unchanged.

- MEDIUM | [run/collect.sh:133](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:133) | DRY: SSH options are duplicated in capability probe, runner probe, node collection, cephadm collector, and rook remote kubectl.  
  Fix: add a Bash-3.2-safe helper in `common.sh`, e.g. `ssh_argv "$ssh_key" "$timeout" "$target"` printing one argv item per line; callers fill arrays with `while read`. This avoids `eval` and keeps quoting safe.

- MEDIUM | [run/collect.sh:306](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:306) | KISS/readability: the remote node bootstrap is a long inline shell string that mixes tempdir setup, unpacking, invoking `collect-node.sh`, archive streaming, fallback skip creation, and exit handling.  
  Fix: ship a small `lib/remote-node-entrypoint.sh` inside the tar stream and invoke it with quoted args. Observable bundle layout and exit behavior can stay identical.

- LOW | [lib/collect-node.sh:16](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/lib/collect-node.sh:16) | DRY: `SKIPPED:` writers are repeated in node, rook, cephadm, and `collect.sh`, with slightly different overwrite behavior.  
  Fix: centralize as `write_skip_artifact PATH REASON` and `write_skip_artifact_once PATH REASON` in `common.sh`.

- LOW | [run/collect.sh:403](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:403) | DRY/interface clarity: arg parsing is repeated across `collect.sh`, `collect-node.sh`, and `collect-cluster-rook.sh`; missing option values will also get inconsistent handling.  
  Fix: add small helpers like `require_option_value "$opt" "${2-}"` and `usage_error`, not a full parser framework.

- LOW | [lib/collect-cluster-rook.sh:34](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:34) | DRY: `rook_run_capture` and `node_run_capture` are near-identical wrappers around `run_capture`.  
  Fix: add `collector_run_capture "$outdir" "$manifest" "$host" "$collector" "$timeout" "$artifact_rel" -- ...` in `common.sh`; keep thin domain wrappers only if they improve call-site readability.

- LOW | [lib/collect-cluster-cephadm.sh:148](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:148) | Maintainability: command specs encode artifact and argv in strings, then rely on word splitting. It is okay for fixed literals, but fragile for future commands with unusual args.  
  Fix: prefer helper calls such as `collect_cephadm_json status.json status --format json-pretty` and `collect_node_basic system/uname.txt uname -a`.

- LOW | [tests/test-collect.sh:85](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/tests/test-collect.sh:85) | Test maintainability: large fake binaries and repeated test helpers are embedded per test file.  
  Fix: add `tests/helpers.sh` for `fail`, `run_and_capture`, assertions, and fixture builders; move fake ssh/kubectl setup into small functions.

- LOW | [run/collect.sh:53](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:53) | Dead code/naming: `parse_host_entry` is unused; [common.sh:16](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/lib/common.sh:16) has an unused logging alias unless it is a deliberate compatibility shim.  
  Fix: remove unused helpers, or add a comment/test if they are intended as stable extension points.

- LOW | [README.md:119](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/README.md:119) | Comment/docs drift: README says auto “只看指令存在、不檢查” and no fallback, but code probes `ceph -s` via `ceph_runner_for` and can continue scanning until a usable ceph source is found.  
  Fix: update the README wording to match the current source-selection behavior.

Review only; I did not modify files or run tests.


tokens used
170,606
No HIGH findings. The tool is generally well-contained for bash, but there are several maintainability issues worth cleaning up before it grows.

- MEDIUM | [run/collect.sh:392](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:392) | SRP/KISS: `collect.sh` is a 604-line entrypoint that owns CLI parsing, inventory normalization, cluster source selection, remote node bootstrap, redaction, verification, packaging, cleanup.  
  Fix: keep `run/collect.sh` as a thin CLI/orchestrator and move stable units into `lib/inventory.sh`, `lib/collect-remote-node.sh`, and `lib/package-bundle.sh`.

- MEDIUM | [run/collect.sh:177](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:177) | Interface clarity: `collect_clusters` takes 11 positional args plus reads global `HOST_TARGETS`. This is hard to audit and easy to mis-call.  
  Fix: convert internal calls to named options, matching `collect_cluster_rook`: `collect_clusters --mode "$mode" --workdir "$workdir" ...`. Keep public CLI unchanged.

- MEDIUM | [run/collect.sh:133](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:133) | DRY: SSH options are duplicated in capability probe, runner probe, node collection, cephadm collector, and rook remote kubectl.  
  Fix: add a Bash-3.2-safe helper in `common.sh`, e.g. `ssh_argv "$ssh_key" "$timeout" "$target"` printing one argv item per line; callers fill arrays with `while read`. This avoids `eval` and keeps quoting safe.

- MEDIUM | [run/collect.sh:306](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:306) | KISS/readability: the remote node bootstrap is a long inline shell string that mixes tempdir setup, unpacking, invoking `collect-node.sh`, archive streaming, fallback skip creation, and exit handling.  
  Fix: ship a small `lib/remote-node-entrypoint.sh` inside the tar stream and invoke it with quoted args. Observable bundle layout and exit behavior can stay identical.

- LOW | [lib/collect-node.sh:16](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/lib/collect-node.sh:16) | DRY: `SKIPPED:` writers are repeated in node, rook, cephadm, and `collect.sh`, with slightly different overwrite behavior.  
  Fix: centralize as `write_skip_artifact PATH REASON` and `write_skip_artifact_once PATH REASON` in `common.sh`.

- LOW | [run/collect.sh:403](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:403) | DRY/interface clarity: arg parsing is repeated across `collect.sh`, `collect-node.sh`, and `collect-cluster-rook.sh`; missing option values will also get inconsistent handling.  
  Fix: add small helpers like `require_option_value "$opt" "${2-}"` and `usage_error`, not a full parser framework.

- LOW | [lib/collect-cluster-rook.sh:34](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:34) | DRY: `rook_run_capture` and `node_run_capture` are near-identical wrappers around `run_capture`.  
  Fix: add `collector_run_capture "$outdir" "$manifest" "$host" "$collector" "$timeout" "$artifact_rel" -- ...` in `common.sh`; keep thin domain wrappers only if they improve call-site readability.

- LOW | [lib/collect-cluster-cephadm.sh:148](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/lib/collect-cluster-cephadm.sh:148) | Maintainability: command specs encode artifact and argv in strings, then rely on word splitting. It is okay for fixed literals, but fragile for future commands with unusual args.  
  Fix: prefer helper calls such as `collect_cephadm_json status.json status --format json-pretty` and `collect_node_basic system/uname.txt uname -a`.

- LOW | [tests/test-collect.sh:85](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/tests/test-collect.sh:85) | Test maintainability: large fake binaries and repeated test helpers are embedded per test file.  
  Fix: add `tests/helpers.sh` for `fail`, `run_and_capture`, assertions, and fixture builders; move fake ssh/kubectl setup into small functions.

- LOW | [run/collect.sh:53](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/run/collect.sh:53) | Dead code/naming: `parse_host_entry` is unused; [common.sh:16](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/lib/common.sh:16) has an unused logging alias unless it is a deliberate compatibility shim.  
  Fix: remove unused helpers, or add a comment/test if they are intended as stable extension points.

- LOW | [README.md:119](/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-incident-bundle/README.md:119) | Comment/docs drift: README says auto “只看指令存在、不檢查” and no fallback, but code probes `ceph -s` via `ceph_runner_for` and can continue scanning until a usable ceph source is found.  
  Fix: update the README wording to match the current source-selection behavior.

Review only; I did not modify files or run tests.


