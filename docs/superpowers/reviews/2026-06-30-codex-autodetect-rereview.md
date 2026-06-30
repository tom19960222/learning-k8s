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
session id: 019f1632-a02a-7201-a196-49392156728e
--------
user
Re-review QA fixes just applied to a read-only Ceph incident collector (bash, workstation bash 3.2, no timeout binary). Diff: git diff 0e3b076..HEAD -- experiments/ceph-incident-bundle. Files: run/collect.sh (detect_node_caps now logs probe ssh failures to ERROR_LOG; collect_clusters sets rook_done only if cluster/rook/pods-wide.txt exists, records ceph_source/rook_source to environment.txt; main guards empty HOSTS=() and validates --kube-context charset), lib/collect-cluster-rook.sh (rook_get_first_pod regained `|| true`; namespace skip message reworded).

Confirm the specific fixes are correct and introduced NO new regressions:
1. rook_done logic: in auto, does the run now correctly exit 2 when the only kubectl node's namespace is missing AND there is no ceph layer (nothing actually collected)? Does it still exit 0 when rook IS really collected, and exit 0 for healthy pure-cephadm auto (rook legitimately absent)?
2. rook_get_first_pod `|| true`: does it now survive a remote pod-lookup ssh failure under set -e without aborting, while still writing the operator/toolbox SKIPPED artifact?
3. empty-HOSTS guard: `${#HOSTS[@]} -eq 0` under bash 3.2 set -u — safe? does it die cleanly exit 1?
4. --kube-context validation: pattern `*[!A-Za-z0-9._-]*` — correct rejection, no false positives on normal contexts?
5. environment.txt source recording + ERROR_LOG probe logging: any quoting/`set -e`/unbound risk? detect_node_caps `out=$(...)` then `rc=$?` — correct under the set +e call path?
6. Any NEW regression to prior guarantees (exit-code contract 0/2/1, trap cleanup, verify-keeps-evidence, redaction, dedup)?

Output ONLY real issues: SEVERITY | file:line | problem | fix. If clean, say so per item. Do not modify files.
codex
I’ll use `superpowers:using-superpowers` for the required skill routing, then do a read-only review of the diff and relevant scripts. No files will be modified.
exec
/bin/zsh -lc "sed -n '1,240p' /Users/ikaros/.codex/superpowers/skills/using-superpowers/SKILL.md && rg -n \"Ceph incident bundle|ceph-incident-bundle|collect.sh|verify-keeps-evidence|exit-code\" /Users/ikaros/.codex/memories/MEMORY.md" in /Users/ikaros/Documents/code/learning-k8s
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
71:- The Ceph incident bundle is intentionally read-only: collect cluster state, node state, logs, manifests, and command errors, then package them as a `.tar.gz`; do not restart daemons, repair, scrub, or change cluster flags [Task 1]
72:- In this repo, `make validate` remains a hard gate for content-linked tooling work because it checks MDX, quiz JSON, feature wiring, and Next.js/basePath validation; the bundle itself should also be verified with `bash experiments/ceph-incident-bundle/lib/verify-bundle.sh <bundle>` [Task 1]

codex
I found the prior memory entry for this collector family, so I’ll keep the existing guarantees in scope while checking the new diff against the actual bash flow.
exec
/bin/zsh -lc "sed -n '1,220p' experiments/ceph-incident-bundle/run/collect.sh && sed -n '1,240p' experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
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
  --since DURATION       log/journal window (default: 24h)
  --timeout SECONDS      per-command / SSH-connect timeout (default: 20)
  --node-timeout SECONDS overall timeout for one node's full collection (default: 600)
  --skip-logs            collect state but skip larger Ceph log copies
  --keep-workdir         keep temporary extracted workdir for debugging
  --help                 print this help

Output:
  DIR/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz

Exit codes:
  0 complete, 2 partial collection failure with bundle produced, 1 usage/config/verify failure
EOF
}

parse_host_entry() {
  local entry=$1
  [[ "$entry" == *=* ]] || return 1
  printf '%s\n' "${entry%%=*}" "${entry#*=}"
}

ssh_target_for_host() {
  local host=$1 ssh_user=$2
  if [[ "$host" == *@* || -z "$ssh_user" ]]; then
    printf '%s' "$host"
  else
    printf '%s@%s' "$ssh_user" "$host"
  fi
}

shell_quote() {
  local value=$1
  [[ "$value" != *"'"* ]] || return 1
  printf "'%s'" "$value"
}

write_initial_metadata() {
  local workdir=$1 mode=$2 seed=$3 since=$4 timeout=$5
  local git_commit
  git_commit="$(git -C "$COLLECT_ROOT/../.." rev-parse --short HEAD 2>/dev/null || printf unknown)"

  cat >"$workdir/README-FIRST.txt" <<'EOF'
Ceph incident bundle

Start with:
- summary.txt
- errors.log
- cluster/
- nodes/

This bundle is read-only evidence captured at incident time. Review it before sharing outside your team.
EOF

  cat >"$workdir/environment.txt" <<EOF
created_utc=$(date -u +%FT%TZ)
mode=$mode
seed=$seed
since=$since
timeout=$timeout
git_commit=$git_commit
EOF

  : >"$workdir/manifest.jsonl"
  : >"$workdir/errors.log"
}

write_summary() {
  local workdir=$1 mode=$2 seed=$3 node_ok=$4 node_failed=$5 cluster_status=$6 final_status=$7

  {
    printf 'Ceph incident bundle summary\n'
    printf 'created_utc: %s\n' "$(date -u +%FT%TZ)"
    printf 'mode: %s\n' "$mode"
    printf 'seed: %s\n' "$seed"
    printf 'cluster_status: %s\n' "$cluster_status"
    printf 'node_ok: %s\n' "$node_ok"
    printf 'node_failed: %s\n' "$node_failed"
    printf 'final_status: %s\n' "$final_status"
  } >"$workdir/summary.txt"
}

append_error() {
  local workdir=$1 message=$2
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$message" >>"$workdir/errors.log"
}

detect_node_caps() {
  # echo a space-joined subset of "cephadm kubectl" present on the target node.
  # A probe that fails to ssh is NOT the same as "node has no caps" — record the
  # ssh failure to ERROR_LOG so a silently-dropped cluster source is visible.
  local target=$1 ssh_key=$2 timeout=$3
  local tbin out rc
  local -a ssh_cmd
  # SC2016: the probe script is single-quoted on purpose — it expands on the remote.
  # shellcheck disable=SC2016
  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
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

# Probe each node once; pick cluster-ceph source (first cephadm node, or --seed)
# and cluster-rook source (first kubectl node); collect each requested layer once.
# Uses globals HOST_TARGETS (set by main).
collect_clusters() {
  local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8 kube_context=$9
  local ceph_source='' rook_source='' i caps rc=0
  local want_ceph=0 want_rook=0 ceph_done=0 rook_done=0
  # so detect_node_caps can record probe ssh failures
  local ERROR_LOG="$workdir/errors.log"
  case "$mode" in
    cephadm) want_ceph=1 ;;
    rook) want_rook=1 ;;
    auto) want_ceph=1; want_rook=1 ;;
    *) return 1 ;;
  esac

  # explicit --seed pins the cluster-ceph source (no probe needed for it)
  if [[ $want_ceph -eq 1 && -n "$seed" ]]; then
    ceph_source="$seed"
  fi

  # probe nodes only if a source we need is still unknown
  if { [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; } || [[ $want_rook -eq 1 ]]; then
    if [[ ${#HOST_TARGETS[@]} -gt 0 ]]; then
      for i in "${!HOST_TARGETS[@]}"; do
        caps="$(detect_node_caps "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
        if [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; then
          case " $caps " in *" cephadm "*) ceph_source="${HOST_TARGETS[$i]}" ;; esac
        fi
        if [[ $want_rook -eq 1 && -z "$rook_source" ]]; then
          case " $caps " in *" kubectl "*) rook_source="${HOST_TARGETS[$i]}" ;; esac
        fi
        if { [[ $want_ceph -eq 0 || -n "$ceph_source" ]]; } && { [[ $want_rook -eq 0 || -n "$rook_source" ]]; }; then
          break
        fi
      done
    fi
  fi

  # cluster-ceph layer
  if [[ $want_ceph -eq 1 && -n "$ceph_source" ]]; then
    collect_cluster_cephadm "$workdir" "$manifest" "$ceph_source" "$ssh_key" "$since" "$timeout" || rc=2
    ceph_done=1
  fi

  # cluster-rook layer
  if [[ $want_rook -eq 1 && -n "$rook_source" ]]; then
    local -a rook_args
    rook_args=(--out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout" --ssh-target "$rook_source" --ssh-key "$ssh_key")
    [[ -n "$kube_context" ]] && rook_args+=(--kube-context "$kube_context")
    [[ "$mode" == auto ]] && rook_args+=(--allow-skip)
    collect_cluster_rook "${rook_args[@]}" || rc=2
    # "done" means real rook evidence was collected — NOT just an --allow-skip
    # (e.g. namespace missing) which returns 0 but only writes SKIPPED.txt.
    [[ -f "$workdir/cluster/rook/pods-wide.txt" ]] && rook_done=1
  fi

  # missing-source handling
  if [[ "$mode" == cephadm && $ceph_done -eq 0 ]]; then
    ensure_dir "$workdir/cluster/ceph"
    printf 'SKIPPED: no cephadm-capable node found (or --seed unreachable)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
    rc=2
  elif [[ "$mode" == rook && $rook_done -eq 0 ]]; then
    ensure_dir "$workdir/cluster/rook"
    printf 'SKIPPED: no kubectl-capable node found\n' >"$workdir/cluster/rook/SKIPPED.txt"
    rc=2
  elif [[ "$mode" == auto ]]; then
    # auto = collect whatever exists; only a hard failure if NEITHER layer found
    if [[ $ceph_done -eq 0 ]]; then
      ensure_dir "$workdir/cluster/ceph"
      printf 'SKIPPED: no cephadm-capable node in inventory (auto)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
    fi
    if [[ $rook_done -eq 0 ]]; then
      ensure_dir "$workdir/cluster/rook"
      printf 'SKIPPED: no kubectl-capable node in inventory (auto)\n' >"$workdir/cluster/rook/SKIPPED.txt"
    fi
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
       [--since DURATION] [--timeout SECONDS] [--allow-skip]
       [--ssh-target USER@HOST --ssh-key PATH] [--kube-context CTX]
EOF
}

rook_skip() {
  local outdir=$1 reason=$2
  local artifact="$outdir/cluster/rook/SKIPPED.txt"
  ensure_dir "$(dirname -- "$artifact")"
  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
}

rook_write_skip_artifact() {
  local artifact=$1 reason=$2
  ensure_dir "$(dirname -- "$artifact")"
  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
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
  local ssh_target='' ssh_key='' kube_context=''

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

  # Build the kubectl prefix once. With --ssh-target, kubectl runs ON that node
  # over ssh (the node where kubectl/kubeconfig lives); otherwise locally.
  # ROOK_KUBECTL_ARGV is global so rook_get_first_pod can use the same prefix.
  if [[ -n "$ssh_target" ]]; then
    ROOK_KUBECTL_ARGV=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$ssh_target" kubectl)
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
  operator_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-operator")"
  if [[ -n "$operator_pod" ]]; then
    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
      "${ROOK_KUBECTL_ARGV[@]}" logs -n "$namespace" "$operator_pod" --since="$since"; then
      failed=1
    fi
  else
    rook_write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found"
  fi

  toolbox_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-tools")"
  if [[ -n "$toolbox_pod" ]]; then
    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
      "${ROOK_KUBECTL_ARGV[@]}" exec -n "$namespace" "$toolbox_pod" -- ceph status; then
      failed=1
    fi
  else
    rook_write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
  fi

  [[ $failed -eq 0 ]] || return 2
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  collect_cluster_rook "$@"
fi

exec
/bin/zsh -lc 'git diff --unified=80 0e3b076..HEAD -- experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-MWf5IlIc' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-wLssAHwN' (errno=Operation not permitted)
diff --git a/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh b/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
index 7545827..623a2c0 100644
--- a/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
+++ b/experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh
@@ -1,178 +1,180 @@
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
        [--since DURATION] [--timeout SECONDS] [--allow-skip]
        [--ssh-target USER@HOST --ssh-key PATH] [--kube-context CTX]
 EOF
 }
 
 rook_skip() {
   local outdir=$1 reason=$2
   local artifact="$outdir/cluster/rook/SKIPPED.txt"
   ensure_dir "$(dirname -- "$artifact")"
   printf 'SKIPPED: %s\n' "$reason" >"$artifact"
 }
 
 rook_write_skip_artifact() {
   local artifact=$1 reason=$2
   ensure_dir "$(dirname -- "$artifact")"
   printf 'SKIPPED: %s\n' "$reason" >"$artifact"
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
-  "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -l "$label" -o name 2>/dev/null |
+  # `|| true`: a lookup failure (e.g. remote kubectl/ssh error) must yield an
+  # empty result (-> SKIPPED artifact), not abort the collector under set -e.
+  { "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -l "$label" -o name 2>/dev/null || true; } |
     head -n1 | sed 's#^pod/##'
 }
 
 collect_cluster_rook() {
   local outdir='' manifest='' namespace=rook-ceph since=24h timeout=20 allow_skip=0
   local ssh_target='' ssh_key='' kube_context=''
 
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
 
   # Build the kubectl prefix once. With --ssh-target, kubectl runs ON that node
   # over ssh (the node where kubectl/kubeconfig lives); otherwise locally.
   # ROOK_KUBECTL_ARGV is global so rook_get_first_pod can use the same prefix.
   if [[ -n "$ssh_target" ]]; then
     ROOK_KUBECTL_ARGV=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$ssh_target" kubectl)
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
-    rook_skip "$outdir" "namespace not found: $namespace"
+    rook_skip "$outdir" "namespace not found (or kubectl unavailable on ${ssh_target:-local}): $namespace"
     [[ "$allow_skip" == "1" ]] && return 0 || return 2
   fi
 
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
   operator_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-operator")"
   if [[ -n "$operator_pod" ]]; then
     if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
       "${ROOK_KUBECTL_ARGV[@]}" logs -n "$namespace" "$operator_pod" --since="$since"; then
       failed=1
     fi
   else
     rook_write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found"
   fi
 
   toolbox_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-tools")"
   if [[ -n "$toolbox_pod" ]]; then
     if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
       "${ROOK_KUBECTL_ARGV[@]}" exec -n "$namespace" "$toolbox_pod" -- ceph status; then
       failed=1
     fi
   else
     rook_write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
   fi
 
   [[ $failed -eq 0 ]] || return 2
   return 0
 }
 
 if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
   collect_cluster_rook "$@"
 fi

exec
/bin/zsh -lc 'git diff --stat 0e3b076..HEAD -- experiments/ceph-incident-bundle && git diff --unified=80 0e3b076..HEAD -- experiments/ceph-incident-bundle/run/collect.sh' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-t3G1VuBU' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-GTS56AQU' (errno=Operation not permitted)
 experiments/ceph-incident-bundle/README.md         |  5 +++
 .../lib/collect-cluster-rook.sh                    |  6 ++-
 experiments/ceph-incident-bundle/run/collect.sh    | 37 +++++++++++++--
 .../ceph-incident-bundle/tests/test-collect.sh     | 52 +++++++++++++++++++++-
 .../tests/test-rook-collector.sh                   | 14 +++++-
 5 files changed, 106 insertions(+), 8 deletions(-)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-bElwEXwt' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-cPQYIkeM' (errno=Operation not permitted)
diff --git a/experiments/ceph-incident-bundle/run/collect.sh b/experiments/ceph-incident-bundle/run/collect.sh
index e9ceebd..ab945ce 100755
--- a/experiments/ceph-incident-bundle/run/collect.sh
+++ b/experiments/ceph-incident-bundle/run/collect.sh
@@ -42,251 +42,271 @@ Options:
 Output:
   DIR/ceph-incident-YYYYMMDDTHHMMSSZ.tar.gz
 
 Exit codes:
   0 complete, 2 partial collection failure with bundle produced, 1 usage/config/verify failure
 EOF
 }
 
 parse_host_entry() {
   local entry=$1
   [[ "$entry" == *=* ]] || return 1
   printf '%s\n' "${entry%%=*}" "${entry#*=}"
 }
 
 ssh_target_for_host() {
   local host=$1 ssh_user=$2
   if [[ "$host" == *@* || -z "$ssh_user" ]]; then
     printf '%s' "$host"
   else
     printf '%s@%s' "$ssh_user" "$host"
   fi
 }
 
 shell_quote() {
   local value=$1
   [[ "$value" != *"'"* ]] || return 1
   printf "'%s'" "$value"
 }
 
 write_initial_metadata() {
   local workdir=$1 mode=$2 seed=$3 since=$4 timeout=$5
   local git_commit
   git_commit="$(git -C "$COLLECT_ROOT/../.." rev-parse --short HEAD 2>/dev/null || printf unknown)"
 
   cat >"$workdir/README-FIRST.txt" <<'EOF'
 Ceph incident bundle
 
 Start with:
 - summary.txt
 - errors.log
 - cluster/
 - nodes/
 
 This bundle is read-only evidence captured at incident time. Review it before sharing outside your team.
 EOF
 
   cat >"$workdir/environment.txt" <<EOF
 created_utc=$(date -u +%FT%TZ)
 mode=$mode
 seed=$seed
 since=$since
 timeout=$timeout
 git_commit=$git_commit
 EOF
 
   : >"$workdir/manifest.jsonl"
   : >"$workdir/errors.log"
 }
 
 write_summary() {
   local workdir=$1 mode=$2 seed=$3 node_ok=$4 node_failed=$5 cluster_status=$6 final_status=$7
 
   {
     printf 'Ceph incident bundle summary\n'
     printf 'created_utc: %s\n' "$(date -u +%FT%TZ)"
     printf 'mode: %s\n' "$mode"
     printf 'seed: %s\n' "$seed"
     printf 'cluster_status: %s\n' "$cluster_status"
     printf 'node_ok: %s\n' "$node_ok"
     printf 'node_failed: %s\n' "$node_failed"
     printf 'final_status: %s\n' "$final_status"
   } >"$workdir/summary.txt"
 }
 
 append_error() {
   local workdir=$1 message=$2
   printf '%s %s\n' "$(date -u +%FT%TZ)" "$message" >>"$workdir/errors.log"
 }
 
 detect_node_caps() {
-  # echo a space-joined subset of "cephadm kubectl" present on the target node
+  # echo a space-joined subset of "cephadm kubectl" present on the target node.
+  # A probe that fails to ssh is NOT the same as "node has no caps" — record the
+  # ssh failure to ERROR_LOG so a silently-dropped cluster source is visible.
   local target=$1 ssh_key=$2 timeout=$3
-  local tbin
+  local tbin out rc
   local -a ssh_cmd
   # SC2016: the probe script is single-quoted on purpose — it expands on the remote.
   # shellcheck disable=SC2016
   ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
   tbin="$(timeout_cmd)"
   if [[ -n "$tbin" ]]; then
     ssh_cmd=("$tbin" "$timeout" "${ssh_cmd[@]}")
   fi
-  "${ssh_cmd[@]}" 2>/dev/null || true
+  out="$("${ssh_cmd[@]}" 2>/dev/null)"
+  rc=$?
+  if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
+    ensure_dir "$(dirname -- "$ERROR_LOG")"
+    printf '%s capability probe failed for %s (ssh exit %s) — node not considered as a cluster source\n' \
+      "$(date -u +%FT%TZ)" "$target" "$rc" >>"$ERROR_LOG"
+  fi
+  printf '%s' "$out"
 }
 
 # Probe each node once; pick cluster-ceph source (first cephadm node, or --seed)
 # and cluster-rook source (first kubectl node); collect each requested layer once.
 # Uses globals HOST_TARGETS (set by main).
 collect_clusters() {
   local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8 kube_context=$9
   local ceph_source='' rook_source='' i caps rc=0
   local want_ceph=0 want_rook=0 ceph_done=0 rook_done=0
+  # so detect_node_caps can record probe ssh failures
+  local ERROR_LOG="$workdir/errors.log"
   case "$mode" in
     cephadm) want_ceph=1 ;;
     rook) want_rook=1 ;;
     auto) want_ceph=1; want_rook=1 ;;
     *) return 1 ;;
   esac
 
   # explicit --seed pins the cluster-ceph source (no probe needed for it)
   if [[ $want_ceph -eq 1 && -n "$seed" ]]; then
     ceph_source="$seed"
   fi
 
   # probe nodes only if a source we need is still unknown
   if { [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; } || [[ $want_rook -eq 1 ]]; then
     if [[ ${#HOST_TARGETS[@]} -gt 0 ]]; then
       for i in "${!HOST_TARGETS[@]}"; do
         caps="$(detect_node_caps "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
         if [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; then
           case " $caps " in *" cephadm "*) ceph_source="${HOST_TARGETS[$i]}" ;; esac
         fi
         if [[ $want_rook -eq 1 && -z "$rook_source" ]]; then
           case " $caps " in *" kubectl "*) rook_source="${HOST_TARGETS[$i]}" ;; esac
         fi
         if { [[ $want_ceph -eq 0 || -n "$ceph_source" ]]; } && { [[ $want_rook -eq 0 || -n "$rook_source" ]]; }; then
           break
         fi
       done
     fi
   fi
 
   # cluster-ceph layer
   if [[ $want_ceph -eq 1 && -n "$ceph_source" ]]; then
     collect_cluster_cephadm "$workdir" "$manifest" "$ceph_source" "$ssh_key" "$since" "$timeout" || rc=2
     ceph_done=1
   fi
 
   # cluster-rook layer
   if [[ $want_rook -eq 1 && -n "$rook_source" ]]; then
     local -a rook_args
     rook_args=(--out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout" --ssh-target "$rook_source" --ssh-key "$ssh_key")
     [[ -n "$kube_context" ]] && rook_args+=(--kube-context "$kube_context")
     [[ "$mode" == auto ]] && rook_args+=(--allow-skip)
     collect_cluster_rook "${rook_args[@]}" || rc=2
-    rook_done=1
+    # "done" means real rook evidence was collected — NOT just an --allow-skip
+    # (e.g. namespace missing) which returns 0 but only writes SKIPPED.txt.
+    [[ -f "$workdir/cluster/rook/pods-wide.txt" ]] && rook_done=1
   fi
 
   # missing-source handling
   if [[ "$mode" == cephadm && $ceph_done -eq 0 ]]; then
     ensure_dir "$workdir/cluster/ceph"
     printf 'SKIPPED: no cephadm-capable node found (or --seed unreachable)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
     rc=2
   elif [[ "$mode" == rook && $rook_done -eq 0 ]]; then
     ensure_dir "$workdir/cluster/rook"
     printf 'SKIPPED: no kubectl-capable node found\n' >"$workdir/cluster/rook/SKIPPED.txt"
     rc=2
   elif [[ "$mode" == auto ]]; then
     # auto = collect whatever exists; only a hard failure if NEITHER layer found
     if [[ $ceph_done -eq 0 ]]; then
       ensure_dir "$workdir/cluster/ceph"
       printf 'SKIPPED: no cephadm-capable node in inventory (auto)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
     fi
     if [[ $rook_done -eq 0 ]]; then
       ensure_dir "$workdir/cluster/rook"
       printf 'SKIPPED: no kubectl-capable node in inventory (auto)\n' >"$workdir/cluster/rook/SKIPPED.txt"
     fi
     if [[ $ceph_done -eq 0 && $rook_done -eq 0 ]]; then
       rc=2
     fi
   fi
 
+  # Record which node each cluster layer was collected from (observability:
+  # "which host did we trust for ceph status?").
+  {
+    printf 'ceph_source=%s\n' "${ceph_source:-<none>}"
+    printf 'rook_source=%s\n' "${rook_source:-<none>}"
+  } >>"$workdir/environment.txt"
+
   return "$rc"
 }
 
 collect_remote_node() {
   local workdir=$1 alias=$2 target=$3 ssh_key=$4 since=$5 timeout=$6 skip_logs=$7 node_timeout=$8
   local node_dir="$workdir/nodes/$alias"
   local node_tar="$workdir/.node-$alias.tar.gz"
   local remote_cmd rc=0 tbin
   local q_alias q_since q_timeout
   local -a ssh_cmd
 
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
 
   ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" "$remote_cmd")
   tbin="$(timeout_cmd)"
   if [[ -n "$tbin" ]]; then
     # Outer wrapper bounds the WHOLE node collection — must be the generous
     # node timeout, never the small per-command timeout (which would kill a
     # slow/large node mid-collection).
     ssh_cmd=("$tbin" "$node_timeout" "${ssh_cmd[@]}")
   fi
 
   set +e
   COPYFILE_DISABLE=1 tar -cf - -C "$COLLECT_ROOT" lib/common.sh lib/collect-node.sh | gzip -c |
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
 
 redact_bundle_text() {
   local workdir=$1
   local redaction_log="$workdir/redactions.log"
   local path
 
   while IFS= read -r path; do
     case "$path" in
       *.gz) redact_gz_file "$path" "$redaction_log" ;;
       *) redact_file "$path" "$redaction_log" ;;
     esac
   done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' -o -name '*.gz' \) -print 2>/dev/null || true)
 }
 
 # Single cleanup point. Uses globals (not main's locals) so it works as an
 # EXIT trap, which fires after main has returned and its locals are gone.
 CLEANUP_WORKDIR=
 CLEANUP_KEEP=0
@@ -299,193 +319,202 @@ cleanup_workdir() {
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
   local seed='' ssh_user='' seed_host='' rook_namespace=rook-ceph kube_context=''
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
   [[ -n "$inventory" && -f "$inventory" ]] || die "missing inventory: ${inventory:-<unset>}"
   [[ -n "$ssh_key" && -f "$ssh_key" ]] || die "missing ssh key: ${ssh_key:-<unset>}"
+  # kube-context runs through a remote shell (ssh kubectl --context ...); restrict
+  # to the characters kubectl contexts actually use so it cannot word-split/inject.
+  if [[ -n "$kube_context" && "$kube_context" == *[!A-Za-z0-9._-]* ]]; then
+    die "invalid --kube-context (allowed: A-Za-z0-9._-): $kube_context"
+  fi
 
   # shellcheck disable=SC1090
   source "$inventory"
 
   if ! declare -p HOSTS >/dev/null 2>&1; then
     die "inventory must define HOSTS"
   fi
 
   ssh_user=${SSH_USER:-}
   seed_host=${SEED_HOST:-}
   rook_namespace=${ROOK_NAMESPACE:-rook-ceph}
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
+  # bash 3.2 + set -u: expanding an empty array errors, so guard it.
+  if [[ ${#HOSTS[@]} -eq 0 ]]; then
+    die "inventory HOSTS is empty"
+  fi
   for entry in "${HOSTS[@]}"; do
     if [[ "$entry" != *=* || -z "${entry%%=*}" || -z "${entry#*=}" ]]; then
       append_error "$workdir" "skipped malformed HOSTS entry: $entry"
       rc=2
       continue
     fi
     HOST_ALIASES+=("${entry%%=*}")
     HOST_TARGETS+=("$(ssh_target_for_host "${entry#*=}" "$ssh_user")")
   done
 
   set +e
   collect_clusters "$mode" "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout" "$rook_namespace" "$kube_context"
   cluster_rc=$?
   set -e
   if [[ $cluster_rc -ne 0 ]]; then
     append_error "$workdir" "cluster collection exited $cluster_rc"
     rc=2
   fi
 
   local i alias target node_rc
   if [[ ${#HOST_ALIASES[@]} -gt 0 ]]; then
     for i in "${!HOST_ALIASES[@]}"; do
       alias="${HOST_ALIASES[$i]}"
       target="${HOST_TARGETS[$i]}"
       if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs" "$node_timeout"; then
         node_ok=$((node_ok + 1))
       else
         node_rc=$?
         node_failed=$((node_failed + 1))
         append_error "$workdir" "node $alias ($target) collector exited $node_rc"
         rc=2
       fi
     done
   fi
 
   # Test-only hook: simulate a mid-run abort to exercise trap cleanup. Inert in production.
   if [[ -n "${COLLECT_TEST_ABORT_AFTER_NODES:-}" ]]; then
     die "test abort after nodes"
   fi
 
   redact_bundle_text "$workdir"
   write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "$rc"
 
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

exec
/bin/zsh -lc "nl -ba /Users/ikaros/.codex/memories/MEMORY.md | sed -n '30,76p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
    30	
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

codex
The core paths are now clear. I’m checking the surrounding helpers next because the risk is mostly `set -euo pipefail`, command substitution, and whether “collected” is inferred from the right artifact.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/run/collect.sh | sed -n '320,450p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
   320	      printf 'kept workdir: %s\n' "$CLEANUP_WORKDIR" >&2
   321	    else
   322	      rm -rf -- "$CLEANUP_WORKDIR"
   323	    fi
   324	  fi
   325	  return "$rc"
   326	}
   327	
   328	main() {
   329	  local inventory='' ssh_key='' seed_override='' out_dir="$COLLECT_ROOT/results"
   330	  local mode=auto since=24h timeout=20 node_timeout=600 skip_logs=0 keep_workdir=0
   331	  local seed='' ssh_user='' seed_host='' rook_namespace=rook-ceph kube_context=''
   332	  local timestamp workdir manifest bundle rc=0 cluster_rc=0 node_ok=0 node_failed=0
   333	
   334	  if [[ $# -eq 0 ]]; then
   335	    usage >&2
   336	    return 1
   337	  fi
   338	
   339	  while [[ $# -gt 0 ]]; do
   340	    case "$1" in
   341	      --inventory)
   342	        inventory=${2-}
   343	        shift 2
   344	        ;;
   345	      --ssh-key)
   346	        ssh_key=${2-}
   347	        shift 2
   348	        ;;
   349	      --seed)
   350	        seed_override=${2-}
   351	        shift 2
   352	        ;;
   353	      --out)
   354	        out_dir=${2-}
   355	        shift 2
   356	        ;;
   357	      --mode)
   358	        mode=${2-}
   359	        shift 2
   360	        ;;
   361	      --kube-context)
   362	        kube_context=${2-}
   363	        shift 2
   364	        ;;
   365	      --since)
   366	        since=${2-}
   367	        shift 2
   368	        ;;
   369	      --timeout)
   370	        timeout=${2-}
   371	        shift 2
   372	        ;;
   373	      --node-timeout)
   374	        node_timeout=${2-}
   375	        shift 2
   376	        ;;
   377	      --skip-logs)
   378	        skip_logs=1
   379	        shift
   380	        ;;
   381	      --keep-workdir)
   382	        keep_workdir=1
   383	        shift
   384	        ;;
   385	      --help|-h)
   386	        usage
   387	        return 0
   388	        ;;
   389	      *)
   390	        usage >&2
   391	        return 1
   392	        ;;
   393	    esac
   394	  done
   395	
   396	  [[ "$mode" == "auto" || "$mode" == "cephadm" || "$mode" == "rook" ]] || die "unsupported mode: $mode"
   397	  [[ -n "$inventory" && -f "$inventory" ]] || die "missing inventory: ${inventory:-<unset>}"
   398	  [[ -n "$ssh_key" && -f "$ssh_key" ]] || die "missing ssh key: ${ssh_key:-<unset>}"
   399	  # kube-context runs through a remote shell (ssh kubectl --context ...); restrict
   400	  # to the characters kubectl contexts actually use so it cannot word-split/inject.
   401	  if [[ -n "$kube_context" && "$kube_context" == *[!A-Za-z0-9._-]* ]]; then
   402	    die "invalid --kube-context (allowed: A-Za-z0-9._-): $kube_context"
   403	  fi
   404	
   405	  # shellcheck disable=SC1090
   406	  source "$inventory"
   407	
   408	  if ! declare -p HOSTS >/dev/null 2>&1; then
   409	    die "inventory must define HOSTS"
   410	  fi
   411	
   412	  ssh_user=${SSH_USER:-}
   413	  seed_host=${SEED_HOST:-}
   414	  rook_namespace=${ROOK_NAMESPACE:-rook-ceph}
   415	  if [[ -n "$seed_override" ]]; then
   416	    seed=$seed_override
   417	  elif [[ -n "$seed_host" ]]; then
   418	    seed="$(ssh_target_for_host "$seed_host" "$ssh_user")"
   419	  fi
   420	
   421	  if [[ -z "$(timeout_cmd)" ]]; then
   422	    log "WARNING: no 'timeout'/'gtimeout' found on this workstation; outer timeouts are disabled — relying on SSH ConnectTimeout/ServerAlive only (install coreutils for full bounding)"
   423	  fi
   424	
   425	  ensure_dir "$out_dir"
   426	  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
   427	  workdir="$out_dir/tmp.$timestamp.$$"
   428	  manifest="$workdir/manifest.jsonl"
   429	  ensure_dir "$workdir"
   430	  CLEANUP_WORKDIR="$workdir"
   431	  CLEANUP_KEEP=$keep_workdir
   432	  trap cleanup_workdir EXIT INT TERM
   433	  write_initial_metadata "$workdir" "$mode" "$seed" "$since" "$timeout"
   434	
   435	  # Parse HOSTS once into globals (used by the cluster capability probe AND the
   436	  # node loop). A malformed entry is recorded but must not abort collection.
   437	  local entry
   438	  HOST_ALIASES=()
   439	  HOST_TARGETS=()
   440	  # bash 3.2 + set -u: expanding an empty array errors, so guard it.
   441	  if [[ ${#HOSTS[@]} -eq 0 ]]; then
   442	    die "inventory HOSTS is empty"
   443	  fi
   444	  for entry in "${HOSTS[@]}"; do
   445	    if [[ "$entry" != *=* || -z "${entry%%=*}" || -z "${entry#*=}" ]]; then
   446	      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
   447	      rc=2
   448	      continue
   449	    fi
   450	    HOST_ALIASES+=("${entry%%=*}")

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/run/collect.sh | sed -n '105,245p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
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
   122	  # echo a space-joined subset of "cephadm kubectl" present on the target node.
   123	  # A probe that fails to ssh is NOT the same as "node has no caps" — record the
   124	  # ssh failure to ERROR_LOG so a silently-dropped cluster source is visible.
   125	  local target=$1 ssh_key=$2 timeout=$3
   126	  local tbin out rc
   127	  local -a ssh_cmd
   128	  # SC2016: the probe script is single-quoted on purpose — it expands on the remote.
   129	  # shellcheck disable=SC2016
   130	  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" 'caps=""; command -v cephadm >/dev/null 2>&1 && caps="$caps cephadm"; command -v kubectl >/dev/null 2>&1 && caps="$caps kubectl"; printf "%s\n" "$caps"')
   131	  tbin="$(timeout_cmd)"
   132	  if [[ -n "$tbin" ]]; then
   133	    ssh_cmd=("$tbin" "$timeout" "${ssh_cmd[@]}")
   134	  fi
   135	  out="$("${ssh_cmd[@]}" 2>/dev/null)"
   136	  rc=$?
   137	  if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
   138	    ensure_dir "$(dirname -- "$ERROR_LOG")"
   139	    printf '%s capability probe failed for %s (ssh exit %s) — node not considered as a cluster source\n' \
   140	      "$(date -u +%FT%TZ)" "$target" "$rc" >>"$ERROR_LOG"
   141	  fi
   142	  printf '%s' "$out"
   143	}
   144	
   145	# Probe each node once; pick cluster-ceph source (first cephadm node, or --seed)
   146	# and cluster-rook source (first kubectl node); collect each requested layer once.
   147	# Uses globals HOST_TARGETS (set by main).
   148	collect_clusters() {
   149	  local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8 kube_context=$9
   150	  local ceph_source='' rook_source='' i caps rc=0
   151	  local want_ceph=0 want_rook=0 ceph_done=0 rook_done=0
   152	  # so detect_node_caps can record probe ssh failures
   153	  local ERROR_LOG="$workdir/errors.log"
   154	  case "$mode" in
   155	    cephadm) want_ceph=1 ;;
   156	    rook) want_rook=1 ;;
   157	    auto) want_ceph=1; want_rook=1 ;;
   158	    *) return 1 ;;
   159	  esac
   160	
   161	  # explicit --seed pins the cluster-ceph source (no probe needed for it)
   162	  if [[ $want_ceph -eq 1 && -n "$seed" ]]; then
   163	    ceph_source="$seed"
   164	  fi
   165	
   166	  # probe nodes only if a source we need is still unknown
   167	  if { [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; } || [[ $want_rook -eq 1 ]]; then
   168	    if [[ ${#HOST_TARGETS[@]} -gt 0 ]]; then
   169	      for i in "${!HOST_TARGETS[@]}"; do
   170	        caps="$(detect_node_caps "${HOST_TARGETS[$i]}" "$ssh_key" "$timeout")"
   171	        if [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; then
   172	          case " $caps " in *" cephadm "*) ceph_source="${HOST_TARGETS[$i]}" ;; esac
   173	        fi
   174	        if [[ $want_rook -eq 1 && -z "$rook_source" ]]; then
   175	          case " $caps " in *" kubectl "*) rook_source="${HOST_TARGETS[$i]}" ;; esac
   176	        fi
   177	        if { [[ $want_ceph -eq 0 || -n "$ceph_source" ]]; } && { [[ $want_rook -eq 0 || -n "$rook_source" ]]; }; then
   178	          break
   179	        fi
   180	      done
   181	    fi
   182	  fi
   183	
   184	  # cluster-ceph layer
   185	  if [[ $want_ceph -eq 1 && -n "$ceph_source" ]]; then
   186	    collect_cluster_cephadm "$workdir" "$manifest" "$ceph_source" "$ssh_key" "$since" "$timeout" || rc=2
   187	    ceph_done=1
   188	  fi
   189	
   190	  # cluster-rook layer
   191	  if [[ $want_rook -eq 1 && -n "$rook_source" ]]; then
   192	    local -a rook_args
   193	    rook_args=(--out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout" --ssh-target "$rook_source" --ssh-key "$ssh_key")
   194	    [[ -n "$kube_context" ]] && rook_args+=(--kube-context "$kube_context")
   195	    [[ "$mode" == auto ]] && rook_args+=(--allow-skip)
   196	    collect_cluster_rook "${rook_args[@]}" || rc=2
   197	    # "done" means real rook evidence was collected — NOT just an --allow-skip
   198	    # (e.g. namespace missing) which returns 0 but only writes SKIPPED.txt.
   199	    [[ -f "$workdir/cluster/rook/pods-wide.txt" ]] && rook_done=1
   200	  fi
   201	
   202	  # missing-source handling
   203	  if [[ "$mode" == cephadm && $ceph_done -eq 0 ]]; then
   204	    ensure_dir "$workdir/cluster/ceph"
   205	    printf 'SKIPPED: no cephadm-capable node found (or --seed unreachable)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
   206	    rc=2
   207	  elif [[ "$mode" == rook && $rook_done -eq 0 ]]; then
   208	    ensure_dir "$workdir/cluster/rook"
   209	    printf 'SKIPPED: no kubectl-capable node found\n' >"$workdir/cluster/rook/SKIPPED.txt"
   210	    rc=2
   211	  elif [[ "$mode" == auto ]]; then
   212	    # auto = collect whatever exists; only a hard failure if NEITHER layer found
   213	    if [[ $ceph_done -eq 0 ]]; then
   214	      ensure_dir "$workdir/cluster/ceph"
   215	      printf 'SKIPPED: no cephadm-capable node in inventory (auto)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
   216	    fi
   217	    if [[ $rook_done -eq 0 ]]; then
   218	      ensure_dir "$workdir/cluster/rook"
   219	      printf 'SKIPPED: no kubectl-capable node in inventory (auto)\n' >"$workdir/cluster/rook/SKIPPED.txt"
   220	    fi
   221	    if [[ $ceph_done -eq 0 && $rook_done -eq 0 ]]; then
   222	      rc=2
   223	    fi
   224	  fi
   225	
   226	  # Record which node each cluster layer was collected from (observability:
   227	  # "which host did we trust for ceph status?").
   228	  {
   229	    printf 'ceph_source=%s\n' "${ceph_source:-<none>}"
   230	    printf 'rook_source=%s\n' "${rook_source:-<none>}"
   231	  } >>"$workdir/environment.txt"
   232	
   233	  return "$rc"
   234	}
   235	
   236	collect_remote_node() {
   237	  local workdir=$1 alias=$2 target=$3 ssh_key=$4 since=$5 timeout=$6 skip_logs=$7 node_timeout=$8
   238	  local node_dir="$workdir/nodes/$alias"
   239	  local node_tar="$workdir/.node-$alias.tar.gz"
   240	  local remote_cmd rc=0 tbin
   241	  local q_alias q_since q_timeout
   242	  local -a ssh_cmd
   243	
   244	  q_alias="$(shell_quote "$alias")" || return 1
   245	  q_since="$(shell_quote "$since")" || return 1

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh | sed -n '35,170p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
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
    57	  local ssh_target='' ssh_key='' kube_context=''
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
    73	      --since)
    74	        since=${2-}
    75	        shift 2
    76	        ;;
    77	      --timeout)
    78	        timeout=${2-}
    79	        shift 2
    80	        ;;
    81	      --allow-skip)
    82	        allow_skip=1
    83	        shift
    84	        ;;
    85	      --ssh-target)
    86	        ssh_target=${2-}
    87	        shift 2
    88	        ;;
    89	      --ssh-key)
    90	        ssh_key=${2-}
    91	        shift 2
    92	        ;;
    93	      --kube-context)
    94	        kube_context=${2-}
    95	        shift 2
    96	        ;;
    97	      --help|-h)
    98	        usage
    99	        return 0
   100	        ;;
   101	      *)
   102	        usage >&2
   103	        return 1
   104	        ;;
   105	    esac
   106	  done
   107	
   108	  [[ -n "$outdir" && -n "$manifest" ]] || {
   109	    usage >&2
   110	    return 1
   111	  }
   112	
   113	  ensure_dir "$outdir/cluster/rook"
   114	
   115	  # Build the kubectl prefix once. With --ssh-target, kubectl runs ON that node
   116	  # over ssh (the node where kubectl/kubeconfig lives); otherwise locally.
   117	  # ROOK_KUBECTL_ARGV is global so rook_get_first_pod can use the same prefix.
   118	  if [[ -n "$ssh_target" ]]; then
   119	    ROOK_KUBECTL_ARGV=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$ssh_target" kubectl)
   120	  else
   121	    ROOK_KUBECTL_ARGV=(kubectl)
   122	  fi
   123	  [[ -n "$kube_context" ]] && ROOK_KUBECTL_ARGV+=(--context "$kube_context")
   124	
   125	  # Missing kubectl / namespace means we collected NO cluster evidence. In
   126	  # explicit rook mode that is a partial failure (exit 2) so the bundle does not
   127	  # falsely look complete; auto-mode fallback passes --allow-skip to tolerate it.
   128	  # (When kubectl is remote we already probed it exists, so skip the local check.)
   129	  if [[ -z "$ssh_target" ]] && ! command -v kubectl >/dev/null 2>&1; then
   130	    rook_skip "$outdir" "kubectl command not found"
   131	    [[ "$allow_skip" == "1" ]] && return 0 || return 2
   132	  fi
   133	
   134	  if ! "${ROOK_KUBECTL_ARGV[@]}" get namespace "$namespace" >/dev/null 2>&1; then
   135	    rook_skip "$outdir" "namespace not found (or kubectl unavailable on ${ssh_target:-local}): $namespace"
   136	    [[ "$allow_skip" == "1" ]] && return 0 || return 2
   137	  fi
   138	
   139	  local failed=0
   140	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/pods-wide.txt" \
   141	    "${ROOK_KUBECTL_ARGV[@]}" get pods -n "$namespace" -o wide; then
   142	    failed=1
   143	  fi
   144	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/events.txt" \
   145	    "${ROOK_KUBECTL_ARGV[@]}" get events -n "$namespace" --sort-by=.lastTimestamp; then
   146	    failed=1
   147	  fi
   148	  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/rook-resources.yaml" \
   149	    "${ROOK_KUBECTL_ARGV[@]}" get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n "$namespace" -o yaml; then
   150	    failed=1
   151	  fi
   152	
   153	  local operator_pod toolbox_pod
   154	  operator_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-operator")"
   155	  if [[ -n "$operator_pod" ]]; then
   156	    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
   157	      "${ROOK_KUBECTL_ARGV[@]}" logs -n "$namespace" "$operator_pod" --since="$since"; then
   158	      failed=1
   159	    fi
   160	  else
   161	    rook_write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found"
   162	  fi
   163	
   164	  toolbox_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-tools")"
   165	  if [[ -n "$toolbox_pod" ]]; then
   166	    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
   167	      "${ROOK_KUBECTL_ARGV[@]}" exec -n "$namespace" "$toolbox_pod" -- ceph status; then
   168	      failed=1
   169	    fi
   170	  else

exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/common.sh | sed -n '1,240p'" in /Users/ikaros/Documents/code/learning-k8s
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
One behavior difference surfaced while tracing auto mode: the exit code is corrected, but I’m checking whether the specific Rook skip artifact is preserved or overwritten before I call it clean.
exec
/bin/zsh -lc "nl -ba experiments/ceph-incident-bundle/lib/verify-bundle.sh | sed -n '1,260p'" in /Users/ikaros/Documents/code/learning-k8s
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
/bin/zsh -lc 'git diff --unified=80 0e3b076..HEAD -- experiments/ceph-incident-bundle/tests/test-collect.sh' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-ZttLHnVK' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-cOAlcvKI' (errno=Operation not permitted)
diff --git a/experiments/ceph-incident-bundle/tests/test-collect.sh b/experiments/ceph-incident-bundle/tests/test-collect.sh
index bf5840a..a664bff 100755
--- a/experiments/ceph-incident-bundle/tests/test-collect.sh
+++ b/experiments/ceph-incident-bundle/tests/test-collect.sh
@@ -1,289 +1,339 @@
 #!/usr/bin/env bash
 set -euo pipefail
 
 ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
 
 fail() {
   printf 'FAIL: %s\n' "$*" >&2
   exit 1
 }
 
 run_and_capture() {
   local output status
   set +e
   output="$("$@" 2>&1)"
   status=$?
   set -e
   printf '%s\n%s' "$status" "$output"
 }
 
 find_bundle() {
   local outdir=$1 bundle
   bundle="$(find "$outdir" -maxdepth 1 -name 'ceph-incident-*.tar.gz' -print -quit)"
   [[ -n "$bundle" ]] || fail "missing generated bundle in $outdir"
   printf '%s' "$bundle"
 }
 
 assert_archive_contains() {
   local bundle=$1 expected=$2
   tar -tzf "$bundle" | sed 's#^\./##' | grep -qF "$expected" || fail "archive missing $expected"
 }
 
 tmpdir="$(mktemp -d)"
 trap 'rm -rf "$tmpdir"' EXIT
 
 # ---------------------------------------------------------------------------
 # usage / arg validation
 # ---------------------------------------------------------------------------
 help_result="$(run_and_capture "$ROOT/run/collect.sh" --help)"
 help_status="${help_result%%$'\n'*}"
 help_output="${help_result#*$'\n'}"
 [[ "$help_status" == "0" ]] || fail "collect.sh --help exited $help_status"
 [[ "$help_output" == *"Usage:"* ]] || fail "collect.sh --help did not print usage"
 [[ "$help_output" == *"--kube-context"* ]] || fail "help should document --kube-context"
 
 missing_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$tmpdir/missing.env")"
 missing_status="${missing_result%%$'\n'*}"
 [[ "$missing_status" == "1" ]] || fail "missing inventory should exit 1, got $missing_status"
 
 # ---------------------------------------------------------------------------
 # fake bins: capability-aware ssh, fake kubectl, passthrough timeout
 #   ssh dispatches by the remote command:
 #     - "command -v cephadm" (capability probe) -> emit caps based on target
 #     - "cephadm shell -- ceph"                 -> delegate to the ceph fixture ssh
 #     - "kubectl"                               -> forward to the fake kubectl
 #     - "collect-node.sh"                       -> fabricate a node bundle tar
 #   Caps per target come from FAKE_CEPH_TARGETS / FAKE_KUBE_TARGETS (substrings).
 # ---------------------------------------------------------------------------
 fakebin="$tmpdir/fakebin"
 mkdir -p "$fakebin"
 
 cat >"$fakebin/kubectl" <<'EOF'
 #!/usr/bin/env bash
 set -euo pipefail
 [[ "${1:-}" == "--context" ]] && shift 2
 cmd="$*"
 case "$cmd" in
-  "get namespace rook-ceph") printf 'rook-ceph\n' ;;
+  "get namespace rook-ceph") [[ "${FAKE_KUBE_NS_MISSING:-}" == "1" ]] && exit 1; printf 'rook-ceph\n' ;;
   "get pods -n rook-ceph -o wide") printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n' ;;
   "get events -n rook-ceph --sort-by=.lastTimestamp") printf 'LAST SEEN TYPE\n1m Normal\n' ;;
   *"-n rook-ceph -o yaml") printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n' ;;
   "get pods -n rook-ceph -l app=rook-ceph-operator -o name") printf 'pod/rook-ceph-operator-0\n' ;;
   "logs -n rook-ceph rook-ceph-operator-0 --since="*) printf 'operator log line\n' ;;
   "get pods -n rook-ceph -l app=rook-ceph-tools -o name") exit 0 ;;
   *) printf 'unexpected kubectl: %s\n' "$cmd" >&2; exit 99 ;;
 esac
 EOF
 
 cat >"$fakebin/timeout" <<'EOF'
 #!/usr/bin/env bash
 printf '%s\n' "$1" >>"${FAKE_TIMEOUT_LOG:?}"
 shift
 exec "$@"
 EOF
 
 cat >"$fakebin/ssh" <<'EOF'
 #!/usr/bin/env bash
 set -euo pipefail
 printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
 whole="$*"
 args=("$@")
 n=${#args[@]}
 
 # Order matters: the capability-probe script also contains "kubectl", so it must
 # be matched before the kubectl-forward branch.
 case "$whole" in
   *"command -v cephadm"*)
     target="${args[$((n-2))]}"   # probe sends a single-arg remote script
+    for t in ${FAKE_PROBE_FAIL_TARGETS:-}; do [[ "$target" == *"$t"* ]] && exit 255; done
     caps=""
     for t in ${FAKE_CEPH_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps cephadm"; done
     for t in ${FAKE_KUBE_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps kubectl"; done
     printf '%s\n' "$caps"
     exit 0
     ;;
   *"cephadm shell -- ceph"*)
     exec "$FIXTURE_SSH" "$@"
     ;;
   *collect-node.sh*)
     alias_name="$(printf '%s\n' "$whole" | sed -n "s/.*--host-alias '\\([^']*\\)'.*/\\1/p")"
     cat >/dev/null
     [[ -n "$alias_name" ]] || { printf 'no alias\n' >&2; exit 99; }
     if [[ "${FAKE_SSH_BAD_TAR_ALIAS:-}" == "$alias_name" ]]; then
       printf 'not a tar archive\n'; exit 0
     fi
     sleep "${FAKE_SSH_SLEEP:-0}"
     t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
     mkdir -p "$t/system"
     printf 'node %s\n' "$alias_name" >"$t/system/hostname.txt"
     if [[ "${FAKE_SSH_NO_MANIFEST_ALIAS:-}" != "$alias_name" ]]; then
       printf '{"node":"%s"}\n' "$alias_name" >"$t/manifest.jsonl"
     fi
     [[ "${FAKE_SSH_PEM_ALIAS:-}" == "$alias_name" ]] && printf 'cert\n' >"$t/system/leak.pem"
     tar -czf - -C "$t" .
     [[ "${FAKE_SSH_FAIL_ALIAS:-}" == "$alias_name" ]] && exit 2
     exit 0
     ;;
   *kubectl*)
     seen=0; kargs=()
     for a in "$@"; do
       if [[ $seen -eq 1 ]]; then kargs+=("$a"); continue; fi
       [[ "$a" == "kubectl" ]] && seen=1
     done
     exec kubectl "${kargs[@]}"
     ;;
   *)
     printf 'unexpected ssh remote: %s\n' "$remote" >&2
     exit 99
     ;;
 esac
 EOF
 chmod +x "$fakebin/kubectl" "$fakebin/ssh" "$fakebin/timeout"
 
 ssh_key="$tmpdir/id_ed25519"
 printf 'fake key\n' >"$ssh_key"
 export FAKE_SSH_LOG="$tmpdir/ssh.log"
 export FAKE_TIMEOUT_LOG="$tmpdir/timeout.log"
 export FIXTURE_SSH="$ROOT/tests/fixtures/bin/ssh"
 
 # external topology: a ceph node + a kube node
 inventory="$tmpdir/inv-external.env"
 cat >"$inventory" <<'EOF'
 SSH_USER="tester"
 ROOK_NAMESPACE="rook-ceph"
 HOSTS=(
   "cephnode=10.0.0.1"
   "kubenode=10.0.0.9"
 )
 EOF
 
 # ---------------------------------------------------------------------------
 # auto: dual-layer collection (ceph from cephnode, rook from kubenode), --context
 # ---------------------------------------------------------------------------
 out_auto="$tmpdir/out-auto"
 : >"$FAKE_SSH_LOG"
 FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="10.0.0.9" \
 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   --inventory "$inventory" --ssh-key "$ssh_key" \
   --mode auto --kube-context lab --out "$out_auto" --since 24h --timeout 5 --node-timeout 90
 bundle_auto="$(find_bundle "$out_auto")"
 assert_archive_contains "$bundle_auto" "cluster/ceph/json/status.json"
 assert_archive_contains "$bundle_auto" "cluster/rook/pods-wide.txt"
 assert_archive_contains "$bundle_auto" "nodes/cephnode/system/hostname.txt"
 assert_archive_contains "$bundle_auto" "nodes/kubenode/system/hostname.txt"
 grep -qF -- '--context lab' "$FAKE_SSH_LOG" || fail "rook kubectl missing --context in auto mode"
 grep -qF '10.0.0.9 kubectl' "$FAKE_SSH_LOG" || fail "rook kubectl did not run on the kube node"
 grep -qx '90' "$FAKE_TIMEOUT_LOG" || fail "node wrapper should use --node-timeout 90"
+# A4: the chosen cluster sources are recorded in environment.txt
+env_txt="$(tar -xOzf "$bundle_auto" ./environment.txt 2>/dev/null)"
+[[ "$env_txt" == *"ceph_source=tester@10.0.0.1"* ]] || fail "environment.txt missing ceph_source"
+[[ "$env_txt" == *"rook_source=tester@10.0.0.9"* ]] || fail "environment.txt missing rook_source"
 
 # ---------------------------------------------------------------------------
 # auto with NO capable nodes: both layers SKIPPED, nodes still collected, exit 2
 # ---------------------------------------------------------------------------
 out_nocap="$tmpdir/out-nocap"
 nocap_status=0
 set +e
 FAKE_CEPH_TARGETS="" FAKE_KUBE_TARGETS="" \
 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   --inventory "$inventory" --ssh-key "$ssh_key" \
   --mode auto --out "$out_nocap" --since 24h --timeout 5
 nocap_status=$?
 set -e
 [[ "$nocap_status" == "2" ]] || fail "auto with no capable node should exit 2, got $nocap_status"
 bundle_nocap="$(find_bundle "$out_nocap")"
 assert_archive_contains "$bundle_nocap" "cluster/ceph/SKIPPED.txt"
 assert_archive_contains "$bundle_nocap" "cluster/rook/SKIPPED.txt"
 assert_archive_contains "$bundle_nocap" "nodes/cephnode/system/hostname.txt"
 
 # ---------------------------------------------------------------------------
 # explicit --mode cephadm --seed: only ceph layer, no kubectl probing/collection
 # ---------------------------------------------------------------------------
 out_ceph="$tmpdir/out-ceph"
 : >"$FAKE_SSH_LOG"
 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   --inventory "$inventory" --ssh-key "$ssh_key" \
   --seed tester@10.0.0.1 --mode cephadm --out "$out_ceph" --since 24h --timeout 5
 bundle_ceph="$(find_bundle "$out_ceph")"
 assert_archive_contains "$bundle_ceph" "cluster/ceph/json/status.json"
 grep -qF 'kubectl' "$FAKE_SSH_LOG" && fail "cephadm mode should not run kubectl" || true
 
 # ---------------------------------------------------------------------------
 # two cephadm nodes: cluster ceph collected from the FIRST only
 # ---------------------------------------------------------------------------
 inv_two="$tmpdir/inv-two-ceph.env"
 cat >"$inv_two" <<'EOF'
 SSH_USER="tester"
 HOSTS=(
   "c1=10.0.0.1"
   "c2=10.0.0.2"
 )
 EOF
 out_two="$tmpdir/out-two"
 : >"$FAKE_SSH_LOG"
 FAKE_CEPH_TARGETS="10.0.0.1 10.0.0.2" FAKE_KUBE_TARGETS="" \
 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   --inventory "$inv_two" --ssh-key "$ssh_key" \
   --mode auto --out "$out_two" --since 24h --timeout 5
 grep -qF '10.0.0.1 sudo -n cephadm shell -- ceph status --format json-pretty' "$FAKE_SSH_LOG" \
   || fail "cluster ceph should be collected from first cephadm node"
 grep -qF '10.0.0.2 sudo -n cephadm shell -- ceph status' "$FAKE_SSH_LOG" \
   && fail "cluster ceph must not be collected twice" || true
 
 # ---------------------------------------------------------------------------
 # node-level orchestration (use cephadm --seed to keep the cluster layer simple)
 # ---------------------------------------------------------------------------
 run_nodecase() {
   # $1=outdir ; remaining env set by caller
   PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
     --inventory "$inventory" --ssh-key "$ssh_key" \
     --seed tester@10.0.0.1 --mode cephadm --out "$1" --since 24h --timeout 5
 }
 
 # C4: truncated node (no manifest) -> SKIPPED, exit 2
 out_nomani="$tmpdir/out-nomani"
 st=0; set +e
 FAKE_SSH_NO_MANIFEST_ALIAS=kubenode run_nodecase "$out_nomani"
 st=$?; set -e
 [[ "$st" == "2" ]] || fail "missing node manifest should exit 2, got $st"
 assert_archive_contains "$(find_bundle "$out_nomani")" "nodes/kubenode/SKIPPED.txt"
 
 # bad tar -> SKIPPED, exit 2
 out_badtar="$tmpdir/out-badtar"
 st=0; set +e
 FAKE_SSH_BAD_TAR_ALIAS=kubenode run_nodecase "$out_badtar"
 st=$?; set -e
 [[ "$st" == "2" ]] || fail "bad node tar should exit 2, got $st"
 assert_archive_contains "$(find_bundle "$out_badtar")" "nodes/kubenode/SKIPPED.txt"
 
 # one failed host -> exit 2, errors.log present
 out_fail="$tmpdir/out-fail"
 st=0; set +e
 FAKE_SSH_FAIL_ALIAS=kubenode run_nodecase "$out_fail"
 st=$?; set -e
 [[ "$st" == "2" ]] || fail "one failed host should exit 2, got $st"
 assert_archive_contains "$(find_bundle "$out_fail")" "errors.log"
 
 # C2: abort mid-run -> trap cleans workdir (no tmp.* left)
 out_abort="$tmpdir/out-abort"
 set +e
 COLLECT_TEST_ABORT_AFTER_NODES=1 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   --inventory "$inventory" --ssh-key "$ssh_key" \
   --seed tester@10.0.0.1 --mode cephadm --out "$out_abort" --since 24h --timeout 5 >/dev/null 2>&1
 abort_status=$?
 set -e
 [[ "$abort_status" != "0" ]] || fail "abort hook should exit non-zero"
 leftover="$(find "$out_abort" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
 [[ "$leftover" == "0" ]] || fail "abort left $leftover tmp workdir(s)"
 
 # C3: verify failure (forbidden secret path) -> exit 1, workdir kept, no bundle
 out_verify="$tmpdir/out-verify"
 set +e
 FAKE_SSH_PEM_ALIAS=kubenode PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
   --inventory "$inventory" --ssh-key "$ssh_key" \
   --seed tester@10.0.0.1 --mode cephadm --out "$out_verify" --since 24h --timeout 5 >/dev/null 2>&1
 verify_status=$?
 set -e
 [[ "$verify_status" == "1" ]] || fail "verify failure should exit 1, got $verify_status"
 produced="$(find "$out_verify" -maxdepth 1 -name 'ceph-incident-*.tar.gz' 2>/dev/null | wc -l | tr -d '[:space:]')"
 [[ "$produced" == "0" ]] || fail "verify failure must not package a bundle"
 kept="$(find "$out_verify" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
 [[ "$kept" == "1" ]] || fail "verify failure should keep the workdir (found $kept)"
 
+# A1: auto with a kubectl node but missing namespace AND no ceph node -> nothing
+# actually collected -> exit 2 (must NOT be a green exit-0).
+inv_kubeonly="$tmpdir/inv-kubeonly.env"
+cat >"$inv_kubeonly" <<'EOF'
+SSH_USER="tester"
+HOSTS=(
+  "kubenode=10.0.0.9"
+)
+EOF
+out_nsmiss="$tmpdir/out-nsmiss"
+st=0; set +e
+FAKE_CEPH_TARGETS="" FAKE_KUBE_TARGETS="10.0.0.9" FAKE_KUBE_NS_MISSING=1 \
+PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
+  --inventory "$inv_kubeonly" --ssh-key "$ssh_key" \
+  --mode auto --out "$out_nsmiss" --since 24h --timeout 5
+st=$?; set -e
+[[ "$st" == "2" ]] || fail "auto with rook allow-skip and no ceph should exit 2, got $st"
+assert_archive_contains "$(find_bundle "$out_nsmiss")" "cluster/rook/SKIPPED.txt"
+
+# A3: a node whose capability probe ssh fails is recorded in errors.log
+out_probefail="$tmpdir/out-probefail"
+set +e
+FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="" FAKE_PROBE_FAIL_TARGETS="10.0.0.9" \
+PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
+  --inventory "$inventory" --ssh-key "$ssh_key" \
+  --mode auto --out "$out_probefail" --since 24h --timeout 5 >/dev/null 2>&1
+set -e
+assert_archive_contains "$(find_bundle "$out_probefail")" "errors.log"
+tar -xOzf "$(find_bundle "$out_probefail")" ./errors.log 2>/dev/null | grep -qF 'capability probe failed for tester@10.0.0.9' \
+  || fail "probe ssh failure was not recorded in errors.log"
+
+# A5: empty HOSTS=() -> exit 1 with a clear message (no bash-3.2 unbound error)
+inv_empty="$tmpdir/inv-empty.env"
+printf 'SSH_USER="t"\nHOSTS=()\n' >"$inv_empty"
+empty_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$inv_empty" --ssh-key "$ssh_key" --mode cephadm --seed t@1.2.3.4)"
+empty_status="${empty_result%%$'\n'*}"
+empty_output="${empty_result#*$'\n'}"
+[[ "$empty_status" == "1" ]] || fail "empty HOSTS should exit 1, got $empty_status"
+[[ "$empty_output" == *"HOSTS is empty"* ]] || fail "empty HOSTS should explain the failure"
+
+# A6: --kube-context with shell metacharacters is rejected (exit 1)
+ctx_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$inventory" --ssh-key "$ssh_key" --kube-context 'bad;ctx')"
+ctx_status="${ctx_result%%$'\n'*}"
+[[ "$ctx_status" == "1" ]] || fail "invalid --kube-context should exit 1, got $ctx_status"
+
 printf 'ok: collect orchestration\n'

exec
/bin/zsh -lc 'rg -n "rook_done|namespace not found|kubectl-capable|kube-context|HOSTS is empty|capability probe failed|ceph_source|rook_source|exit 2|auto" experiments/ceph-incident-bundle/tests experiments/ceph-incident-bundle/README.md experiments/ceph-incident-bundle/lib experiments/ceph-incident-bundle/run' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
experiments/ceph-incident-bundle/README.md:59:- `SEED_HOST`：**選填**。手動指定 cluster-level `ceph` command 要在哪台跑;不填則 `auto` 會自動挑第一台有 `cephadm` 的 node。
experiments/ceph-incident-bundle/README.md:63:## 自動偵測（auto，預設）
experiments/ceph-incident-bundle/README.md:65:預設 `--mode auto` 會逐台 node 經 ssh 偵測能力，再分層收集：
experiments/ceph-incident-bundle/README.md:68:- node 上有 `kubectl` → 從**第一台**有 kubectl 的 node、用 ssh 在該 node 上跑 `kubectl`（可加 `--kube-context`）收 rook 層。
experiments/ceph-incident-bundle/README.md:80:把 external ceph 主機和有 `kubectl` 的 k8s node 列進同一份 `HOSTS`，`auto` 會：ceph 層從 ceph 主機收、rook 層在 k8s node 上跑 kubectl 收。指定 context：
experiments/ceph-incident-bundle/README.md:95:  --kube-context my-cluster \
experiments/ceph-incident-bundle/README.md:104:## auto 的限制（已知）
experiments/ceph-incident-bundle/README.md:107:- **探測是逐台序列 ssh**:某層的能力完全不存在時(例如純 cephadm 叢集仍會為了 rook 掃完每台),或 node 沒回應時,探測會逐台等到 `ConnectTimeout`。大型 inventory 建議直接用 `--mode cephadm --seed ...` 跳過探測。探測 ssh 失敗的 node 會記進 `errors.log`(`capability probe failed for ...`),不會被當成「沒有該能力」而靜默忽略。
experiments/ceph-incident-bundle/run/collect.sh:33:  --mode auto|cephadm|rook   auto = per-node detect, collect ceph and/or rook layer
experiments/ceph-incident-bundle/run/collect.sh:34:  --kube-context CTX     kubectl context for the rook layer (default: none)
experiments/ceph-incident-bundle/run/collect.sh:139:    printf '%s capability probe failed for %s (ssh exit %s) — node not considered as a cluster source\n' \
experiments/ceph-incident-bundle/run/collect.sh:150:  local ceph_source='' rook_source='' i caps rc=0
experiments/ceph-incident-bundle/run/collect.sh:151:  local want_ceph=0 want_rook=0 ceph_done=0 rook_done=0
experiments/ceph-incident-bundle/run/collect.sh:157:    auto) want_ceph=1; want_rook=1 ;;
experiments/ceph-incident-bundle/run/collect.sh:163:    ceph_source="$seed"
experiments/ceph-incident-bundle/run/collect.sh:167:  if { [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; } || [[ $want_rook -eq 1 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:171:        if [[ $want_ceph -eq 1 && -z "$ceph_source" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:172:          case " $caps " in *" cephadm "*) ceph_source="${HOST_TARGETS[$i]}" ;; esac
experiments/ceph-incident-bundle/run/collect.sh:174:        if [[ $want_rook -eq 1 && -z "$rook_source" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:175:          case " $caps " in *" kubectl "*) rook_source="${HOST_TARGETS[$i]}" ;; esac
experiments/ceph-incident-bundle/run/collect.sh:177:        if { [[ $want_ceph -eq 0 || -n "$ceph_source" ]]; } && { [[ $want_rook -eq 0 || -n "$rook_source" ]]; }; then
experiments/ceph-incident-bundle/run/collect.sh:185:  if [[ $want_ceph -eq 1 && -n "$ceph_source" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:186:    collect_cluster_cephadm "$workdir" "$manifest" "$ceph_source" "$ssh_key" "$since" "$timeout" || rc=2
experiments/ceph-incident-bundle/run/collect.sh:191:  if [[ $want_rook -eq 1 && -n "$rook_source" ]]; then
experiments/ceph-incident-bundle/run/collect.sh:193:    rook_args=(--out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout" --ssh-target "$rook_source" --ssh-key "$ssh_key")
experiments/ceph-incident-bundle/run/collect.sh:194:    [[ -n "$kube_context" ]] && rook_args+=(--kube-context "$kube_context")
experiments/ceph-incident-bundle/run/collect.sh:195:    [[ "$mode" == auto ]] && rook_args+=(--allow-skip)
experiments/ceph-incident-bundle/run/collect.sh:199:    [[ -f "$workdir/cluster/rook/pods-wide.txt" ]] && rook_done=1
experiments/ceph-incident-bundle/run/collect.sh:207:  elif [[ "$mode" == rook && $rook_done -eq 0 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:209:    printf 'SKIPPED: no kubectl-capable node found\n' >"$workdir/cluster/rook/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:211:  elif [[ "$mode" == auto ]]; then
experiments/ceph-incident-bundle/run/collect.sh:212:    # auto = collect whatever exists; only a hard failure if NEITHER layer found
experiments/ceph-incident-bundle/run/collect.sh:215:      printf 'SKIPPED: no cephadm-capable node in inventory (auto)\n' >"$workdir/cluster/ceph/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:217:    if [[ $rook_done -eq 0 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:219:      printf 'SKIPPED: no kubectl-capable node in inventory (auto)\n' >"$workdir/cluster/rook/SKIPPED.txt"
experiments/ceph-incident-bundle/run/collect.sh:221:    if [[ $ceph_done -eq 0 && $rook_done -eq 0 ]]; then
experiments/ceph-incident-bundle/run/collect.sh:229:    printf 'ceph_source=%s\n' "${ceph_source:-<none>}"
experiments/ceph-incident-bundle/run/collect.sh:230:    printf 'rook_source=%s\n' "${rook_source:-<none>}"
experiments/ceph-incident-bundle/run/collect.sh:330:  local mode=auto since=24h timeout=20 node_timeout=600 skip_logs=0 keep_workdir=0
experiments/ceph-incident-bundle/run/collect.sh:361:      --kube-context)
experiments/ceph-incident-bundle/run/collect.sh:396:  [[ "$mode" == "auto" || "$mode" == "cephadm" || "$mode" == "rook" ]] || die "unsupported mode: $mode"
experiments/ceph-incident-bundle/run/collect.sh:399:  # kube-context runs through a remote shell (ssh kubectl --context ...); restrict
experiments/ceph-incident-bundle/run/collect.sh:402:    die "invalid --kube-context (allowed: A-Za-z0-9._-): $kube_context"
experiments/ceph-incident-bundle/run/collect.sh:442:    die "inventory HOSTS is empty"
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:17:       [--ssh-target USER@HOST --ssh-key PATH] [--kube-context CTX]
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:93:      --kube-context)
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:126:  # explicit rook mode that is a partial failure (exit 2) so the bundle does not
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:127:  # falsely look complete; auto-mode fallback passes --allow-skip to tolerate it.
experiments/ceph-incident-bundle/lib/collect-cluster-rook.sh:135:    rook_skip "$outdir" "namespace not found (or kubectl unavailable on ${ssh_target:-local}): $namespace"
experiments/ceph-incident-bundle/tests/test-cephadm-collector.sh:104:  [[ "$rc" == "2" ]] || fail "expected partial failure exit 2, got $rc"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:51:[[ "$no_kubectl_rc" == "2" ]] || fail "explicit rook with no kubectl should exit 2, got $no_kubectl_rc"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:54:# R4: auto-mode fallback passes --allow-skip, so the same situation is a graceful skip (rc 0)
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:131:[[ "$missing_ns_rc" == "2" ]] || fail "explicit rook with missing namespace should exit 2, got $missing_ns_rc"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:132:assert_file_contains "$out_missing_ns/cluster/rook/SKIPPED.txt" "namespace not found"
experiments/ceph-incident-bundle/tests/test-rook-collector.sh:171:  --ssh-target tester@node2 --ssh-key "$tmpdir/key" --kube-context lab
experiments/ceph-incident-bundle/tests/test-collect.sh:43:[[ "$help_output" == *"--kube-context"* ]] || fail "help should document --kube-context"
experiments/ceph-incident-bundle/tests/test-collect.sh:98:    for t in ${FAKE_PROBE_FAIL_TARGETS:-}; do [[ "$target" == *"$t"* ]] && exit 255; done
experiments/ceph-incident-bundle/tests/test-collect.sh:124:    [[ "${FAKE_SSH_FAIL_ALIAS:-}" == "$alias_name" ]] && exit 2
experiments/ceph-incident-bundle/tests/test-collect.sh:161:# auto: dual-layer collection (ceph from cephnode, rook from kubenode), --context
experiments/ceph-incident-bundle/tests/test-collect.sh:163:out_auto="$tmpdir/out-auto"
experiments/ceph-incident-bundle/tests/test-collect.sh:168:  --mode auto --kube-context lab --out "$out_auto" --since 24h --timeout 5 --node-timeout 90
experiments/ceph-incident-bundle/tests/test-collect.sh:169:bundle_auto="$(find_bundle "$out_auto")"
experiments/ceph-incident-bundle/tests/test-collect.sh:170:assert_archive_contains "$bundle_auto" "cluster/ceph/json/status.json"
experiments/ceph-incident-bundle/tests/test-collect.sh:171:assert_archive_contains "$bundle_auto" "cluster/rook/pods-wide.txt"
experiments/ceph-incident-bundle/tests/test-collect.sh:172:assert_archive_contains "$bundle_auto" "nodes/cephnode/system/hostname.txt"
experiments/ceph-incident-bundle/tests/test-collect.sh:173:assert_archive_contains "$bundle_auto" "nodes/kubenode/system/hostname.txt"
experiments/ceph-incident-bundle/tests/test-collect.sh:174:grep -qF -- '--context lab' "$FAKE_SSH_LOG" || fail "rook kubectl missing --context in auto mode"
experiments/ceph-incident-bundle/tests/test-collect.sh:178:env_txt="$(tar -xOzf "$bundle_auto" ./environment.txt 2>/dev/null)"
experiments/ceph-incident-bundle/tests/test-collect.sh:179:[[ "$env_txt" == *"ceph_source=tester@10.0.0.1"* ]] || fail "environment.txt missing ceph_source"
experiments/ceph-incident-bundle/tests/test-collect.sh:180:[[ "$env_txt" == *"rook_source=tester@10.0.0.9"* ]] || fail "environment.txt missing rook_source"
experiments/ceph-incident-bundle/tests/test-collect.sh:183:# auto with NO capable nodes: both layers SKIPPED, nodes still collected, exit 2
experiments/ceph-incident-bundle/tests/test-collect.sh:191:  --mode auto --out "$out_nocap" --since 24h --timeout 5
experiments/ceph-incident-bundle/tests/test-collect.sh:194:[[ "$nocap_status" == "2" ]] || fail "auto with no capable node should exit 2, got $nocap_status"
experiments/ceph-incident-bundle/tests/test-collect.sh:228:  --mode auto --out "$out_two" --since 24h --timeout 5
experiments/ceph-incident-bundle/tests/test-collect.sh:244:# C4: truncated node (no manifest) -> SKIPPED, exit 2
experiments/ceph-incident-bundle/tests/test-collect.sh:249:[[ "$st" == "2" ]] || fail "missing node manifest should exit 2, got $st"
experiments/ceph-incident-bundle/tests/test-collect.sh:252:# bad tar -> SKIPPED, exit 2
experiments/ceph-incident-bundle/tests/test-collect.sh:257:[[ "$st" == "2" ]] || fail "bad node tar should exit 2, got $st"
experiments/ceph-incident-bundle/tests/test-collect.sh:260:# one failed host -> exit 2, errors.log present
experiments/ceph-incident-bundle/tests/test-collect.sh:265:[[ "$st" == "2" ]] || fail "one failed host should exit 2, got $st"
experiments/ceph-incident-bundle/tests/test-collect.sh:294:# A1: auto with a kubectl node but missing namespace AND no ceph node -> nothing
experiments/ceph-incident-bundle/tests/test-collect.sh:295:# actually collected -> exit 2 (must NOT be a green exit-0).
experiments/ceph-incident-bundle/tests/test-collect.sh:308:  --mode auto --out "$out_nsmiss" --since 24h --timeout 5
experiments/ceph-incident-bundle/tests/test-collect.sh:310:[[ "$st" == "2" ]] || fail "auto with rook allow-skip and no ceph should exit 2, got $st"
experiments/ceph-incident-bundle/tests/test-collect.sh:319:  --mode auto --out "$out_probefail" --since 24h --timeout 5 >/dev/null 2>&1
experiments/ceph-incident-bundle/tests/test-collect.sh:322:tar -xOzf "$(find_bundle "$out_probefail")" ./errors.log 2>/dev/null | grep -qF 'capability probe failed for tester@10.0.0.9' \
experiments/ceph-incident-bundle/tests/test-collect.sh:332:[[ "$empty_output" == *"HOSTS is empty"* ]] || fail "empty HOSTS should explain the failure"
experiments/ceph-incident-bundle/tests/test-collect.sh:334:# A6: --kube-context with shell metacharacters is rejected (exit 1)
experiments/ceph-incident-bundle/tests/test-collect.sh:335:ctx_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$inventory" --ssh-key "$ssh_key" --kube-context 'bad;ctx')"
experiments/ceph-incident-bundle/tests/test-collect.sh:337:[[ "$ctx_status" == "1" ]] || fail "invalid --kube-context should exit 1, got $ctx_status"

exec
/bin/zsh -lc 'git diff --unified=80 0e3b076..HEAD -- experiments/ceph-incident-bundle/tests/test-rook-collector.sh' in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-ZNFpXoXv' (errno=Operation not permitted)
git: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead
git: error: couldn't create cache file '/tmp/xcrun_db-FzupHonB' (errno=Operation not permitted)
diff --git a/experiments/ceph-incident-bundle/tests/test-rook-collector.sh b/experiments/ceph-incident-bundle/tests/test-rook-collector.sh
index 27e6d36..eff738b 100755
--- a/experiments/ceph-incident-bundle/tests/test-rook-collector.sh
+++ b/experiments/ceph-incident-bundle/tests/test-rook-collector.sh
@@ -21,155 +21,167 @@ run_rook_collector() {
   "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
     --out "$outdir" \
     --manifest "$manifest" \
     --namespace rook-ceph \
     --since 24h \
     --timeout 5 \
     "$@"
 }
 
 tmpdir="$(mktemp -d)"
 trap 'rm -rf "$tmpdir"' EXIT
 
 minimal_bin="$tmpdir/minimal-bin"
 mkdir -p "$minimal_bin"
 ln -s "$(command -v dirname)" "$minimal_bin/dirname"
 ln -s "$(command -v mkdir)" "$minimal_bin/mkdir"
 
 out_no_kubectl="$tmpdir/out-no-kubectl"
 manifest_no_kubectl="$tmpdir/manifest-no-kubectl.jsonl"
 no_kubectl_rc=0
 set +e
 PATH="$minimal_bin" "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
   --out "$out_no_kubectl" \
   --manifest "$manifest_no_kubectl" \
   --namespace rook-ceph \
   --since 24h \
   --timeout 5
 no_kubectl_rc=$?
 set -e
 # R4: explicit rook mode with no kubectl is a real failure (not a silent success)
 [[ "$no_kubectl_rc" == "2" ]] || fail "explicit rook with no kubectl should exit 2, got $no_kubectl_rc"
 assert_file_contains "$out_no_kubectl/cluster/rook/SKIPPED.txt" "kubectl command not found"
 
 # R4: auto-mode fallback passes --allow-skip, so the same situation is a graceful skip (rc 0)
 out_no_kubectl_skip="$tmpdir/out-no-kubectl-skip"
 manifest_no_kubectl_skip="$tmpdir/manifest-no-kubectl-skip.jsonl"
 allow_skip_rc=0
 set +e
 PATH="$minimal_bin" "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
   --out "$out_no_kubectl_skip" \
   --manifest "$manifest_no_kubectl_skip" \
   --namespace rook-ceph \
   --since 24h \
   --timeout 5 \
   --allow-skip
 allow_skip_rc=$?
 set -e
 [[ "$allow_skip_rc" == "0" ]] || fail "rook with --allow-skip and no kubectl should exit 0, got $allow_skip_rc"
 assert_file_contains "$out_no_kubectl_skip/cluster/rook/SKIPPED.txt" "kubectl command not found"
 
 fakebin="$tmpdir/fakebin"
 mkdir -p "$fakebin"
 cat >"$fakebin/kubectl" <<'EOF'
 #!/usr/bin/env bash
 set -euo pipefail
 printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG:?}"
 
 # tolerate a leading "--context CTX" (added in remote/ssh mode)
 if [[ "${1:-}" == "--context" ]]; then
   shift 2
 fi
 
 mode=${FAKE_KUBECTL_MODE:-present}
 cmd="$*"
 
 case "$cmd" in
   "get namespace rook-ceph")
     [[ "$mode" != "missing-namespace" ]] || exit 1
     printf 'rook-ceph\n'
     ;;
   "get pods -n rook-ceph -o wide")
     printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n'
     ;;
   "get events -n rook-ceph --sort-by=.lastTimestamp")
     printf 'LAST SEEN TYPE REASON OBJECT MESSAGE\n1m Normal Started pod/osd started\n'
     ;;
   "get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n rook-ceph -o yaml")
     printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n  metadata:\n    name: rook-ceph\n'
     ;;
   "get pods -n rook-ceph -l app=rook-ceph-operator -o name")
+    [[ "$mode" == "op-lookup-fail" ]] && exit 1
     printf 'pod/rook-ceph-operator-0\n'
     ;;
   "logs -n rook-ceph rook-ceph-operator-0 --since=24h")
     printf 'operator log line\n'
     ;;
   "get pods -n rook-ceph -l app=rook-ceph-tools -o name")
     [[ "$mode" == "with-toolbox" ]] || exit 0
     printf 'pod/rook-ceph-tools-0\n'
     ;;
   "exec -n rook-ceph rook-ceph-tools-0 -- ceph status")
     printf 'cluster is healthy from toolbox\n'
     ;;
   *)
     printf 'unexpected kubectl command: %s\n' "$cmd" >&2
     exit 99
     ;;
 esac
 EOF
 chmod +x "$fakebin/kubectl"
 
 export FAKE_KUBECTL_LOG="$tmpdir/kubectl.log"
 
 out_missing_ns="$tmpdir/out-missing-ns"
 manifest_missing_ns="$tmpdir/manifest-missing-ns.jsonl"
 missing_ns_rc=0
 set +e
 FAKE_KUBECTL_MODE=missing-namespace PATH="$fakebin:$PATH" run_rook_collector "$out_missing_ns" "$manifest_missing_ns"
 missing_ns_rc=$?
 set -e
 [[ "$missing_ns_rc" == "2" ]] || fail "explicit rook with missing namespace should exit 2, got $missing_ns_rc"
-assert_file_contains "$out_missing_ns/cluster/rook/SKIPPED.txt" "namespace not found: rook-ceph"
+assert_file_contains "$out_missing_ns/cluster/rook/SKIPPED.txt" "namespace not found"
 
 out_present="$tmpdir/out-present"
 manifest_present="$tmpdir/manifest-present.jsonl"
 FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" run_rook_collector "$out_present" "$manifest_present"
 
 assert_file_contains "$out_present/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
 assert_file_contains "$out_present/cluster/rook/events.txt" "osd started"
 assert_file_contains "$out_present/cluster/rook/rook-resources.yaml" "kind: CephCluster"
 assert_file_contains "$out_present/cluster/rook/operator.log" "operator log line"
 assert_file_contains "$out_present/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
 
 grep -qF 'get namespace rook-ceph' "$FAKE_KUBECTL_LOG" || fail "namespace detection was not called"
 grep -qF 'logs -n rook-ceph rook-ceph-operator-0 --since=24h' "$FAKE_KUBECTL_LOG" || fail "operator logs were not collected"
 
 # --- remote (ssh-target) mode: kubectl runs via ssh on the chosen node, with --context ---
 fake_ssh_log="$tmpdir/ssh.log"
 cat >"$fakebin/ssh" <<'EOF'
 #!/usr/bin/env bash
 set -euo pipefail
 printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
 # argv: -i key <opts...> target kubectl <kubectl args...>; forward everything after 'kubectl'
 seen=0
 argv=()
 for a in "$@"; do
   if [[ $seen -eq 1 ]]; then argv+=("$a"); continue; fi
   [[ "$a" == "kubectl" ]] && seen=1
 done
 exec kubectl "${argv[@]}"
 EOF
 chmod +x "$fakebin/ssh"
 printf 'k\n' >"$tmpdir/key"
 
 out_remote="$tmpdir/out-remote"
 manifest_remote="$tmpdir/manifest-remote.jsonl"
 FAKE_SSH_LOG="$fake_ssh_log" FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" \
   "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
   --out "$out_remote" --manifest "$manifest_remote" \
   --namespace rook-ceph --since 24h --timeout 5 \
   --ssh-target tester@node2 --ssh-key "$tmpdir/key" --kube-context lab
 
 assert_file_contains "$out_remote/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
 assert_file_contains "$out_remote/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
 grep -qF -- '--context lab' "$fake_ssh_log" || fail "remote kubectl missing --context"
 grep -qF 'tester@node2 kubectl' "$fake_ssh_log" || fail "kubectl did not run via ssh on the target node"
+
+# A2 regression: a pod-lookup failure must not abort the collector under set -e
+out_oplookup="$tmpdir/out-oplookup"
+manifest_oplookup="$tmpdir/manifest-oplookup.jsonl"
+oplookup_rc=0
+set +e
+FAKE_KUBECTL_MODE=op-lookup-fail PATH="$fakebin:$PATH" run_rook_collector "$out_oplookup" "$manifest_oplookup"
+oplookup_rc=$?
+set -e
+[[ "$oplookup_rc" == "0" ]] || fail "operator pod-lookup failure should not abort collector, got $oplookup_rc"
+assert_file_contains "$out_oplookup/cluster/rook/operator-SKIPPED.txt" "operator Pod not found"

codex
The new tests cover the requested scenarios at a high level, but one assertion only checks that `SKIPPED.txt` exists, not which skip reason survives. I’m doing a couple of shell semantics checks now instead of relying only on tests.
exec
/bin/zsh -lc "/bin/bash --version | sed -n '1p'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin24)

exec
/bin/zsh -lc "/bin/bash -c 'set -u; HOSTS=(); if [[ "'${#HOSTS[@]} -eq 0 ]]; then echo safe-empty; fi; for x in "${HOSTS[@]}"; do echo "$x"; done; echo done'"'" in /Users/ikaros/Documents/code/learning-k8s
 exited 127 in 0ms:
safe-empty
/bin/bash: HOSTS[@]: unbound variable

exec
/bin/zsh -lc "/bin/bash -c 'set -euo pipefail; f(){ { false || true; } | head -n1 | sed s/x/y/; echo survived; }; v="'$(f); rc=$?; printf "rc=%s v=%q'"\\n\" \""'$rc" "$v"'"'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
rc=0 v=survived

exec
/bin/zsh -lc "/bin/bash -c 'set +e; detect(){ out="'$(false); rc=$?; printf "rc=%s out=%s'"\\n\" \""'$rc" "$out"; }; caps=$(detect); st=$?; printf "st=%s caps=%q'"\\n\" \""'$st" "$caps"'"'" in /Users/ikaros/Documents/code/learning-k8s
 succeeded in 0ms:
st=0 caps=rc=1\ out=

codex
MEDIUM | experiments/ceph-incident-bundle/run/collect.sh:401 | `--kube-context` rejects common valid context names such as `kubernetes-admin@kubernetes` and EKS ARN contexts containing `:`/`/`; this is a false positive for normal kube contexts, even though the shell-injection intent is correct. | Relax to a safe allowlist that includes common non-metacharacters, e.g. `A-Za-z0-9._@:/-`, or quote the remote kubectl command robustly instead of over-restricting names.

LOW | experiments/ceph-incident-bundle/run/collect.sh:217 | In auto mode, when a kubectl-capable node exists but the Rook namespace is missing, `collect_cluster_rook` writes the useful namespace/unavailable reason, then `collect_clusters` overwrites `cluster/rook/SKIPPED.txt` with `no kubectl-capable node in inventory (auto)`. Exit code is correctly 2, but the diagnostic artifact is now misleading. | Only write the generic auto skip if `cluster/rook/SKIPPED.txt` does not already exist, or use a separate source-missing message path.
tokens used
56,876
MEDIUM | experiments/ceph-incident-bundle/run/collect.sh:401 | `--kube-context` rejects common valid context names such as `kubernetes-admin@kubernetes` and EKS ARN contexts containing `:`/`/`; this is a false positive for normal kube contexts, even though the shell-injection intent is correct. | Relax to a safe allowlist that includes common non-metacharacters, e.g. `A-Za-z0-9._@:/-`, or quote the remote kubectl command robustly instead of over-restricting names.

LOW | experiments/ceph-incident-bundle/run/collect.sh:217 | In auto mode, when a kubectl-capable node exists but the Rook namespace is missing, `collect_cluster_rook` writes the useful namespace/unavailable reason, then `collect_clusters` overwrites `cluster/rook/SKIPPED.txt` with `no kubectl-capable node in inventory (auto)`. Exit code is correctly 2, but the diagnostic artifact is now misleading. | Only write the generic auto skip if `cluster/rook/SKIPPED.txt` does not already exist, or use a separate source-missing message path.
