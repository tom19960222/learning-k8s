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
  --mode auto|cephadm|rook
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

run_cluster_collector() {
  local mode=$1 workdir=$2 manifest=$3 seed=$4 ssh_key=$5 since=$6 timeout=$7 rook_namespace=$8
  local -a probe_cmd

  case "$mode" in
    cephadm)
      [[ -n "$seed" && -n "$ssh_key" ]] || return 1
      collect_cluster_cephadm "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout"
      ;;
    rook)
      collect_cluster_rook --out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout"
      ;;
    auto)
      local probe_tbin
      probe_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$seed" command -v cephadm)
      probe_tbin="$(timeout_cmd)"
      if [[ -n "$probe_tbin" ]]; then
        probe_cmd=("$probe_tbin" "$timeout" "${probe_cmd[@]}")
      fi
      if [[ -n "$seed" && -n "$ssh_key" ]] && "${probe_cmd[@]}" >/dev/null 2>&1; then
        collect_cluster_cephadm "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout"
      else
        collect_cluster_rook --out "$workdir" --manifest "$manifest" --namespace "$rook_namespace" --since "$since" --timeout "$timeout"
      fi
      ;;
    *)
      return 1
      ;;
  esac
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
  local workdir=$1 redaction_log="$workdir/redactions.log"
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
  local inventory= ssh_key= seed_override= out_dir="$COLLECT_ROOT/results"
  local mode=auto since=24h timeout=20 node_timeout=600 skip_logs=0 keep_workdir=0
  local seed= ssh_user= seed_host= rook_namespace=rook-ceph
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

  set +e
  run_cluster_collector "$mode" "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout" "$rook_namespace"
  cluster_rc=$?
  set -e
  if [[ $cluster_rc -ne 0 ]]; then
    append_error "$workdir" "cluster collector exited $cluster_rc"
    rc=2
  fi

  local entry alias host target node_rc
  for entry in "${HOSTS[@]}"; do
    # Robust parse: a malformed entry must not abort an in-progress collection.
    if [[ "$entry" != *=* ]]; then
      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
      node_failed=$((node_failed + 1))
      rc=2
      continue
    fi
    alias="${entry%%=*}"
    host="${entry#*=}"
    if [[ -z "$alias" || -z "$host" ]]; then
      append_error "$workdir" "skipped malformed HOSTS entry: $entry"
      node_failed=$((node_failed + 1))
      rc=2
      continue
    fi
    target="$(ssh_target_for_host "$host" "$ssh_user")"

    if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs" "$node_timeout"; then
      node_ok=$((node_ok + 1))
    else
      node_rc=$?
      node_failed=$((node_failed + 1))
      append_error "$workdir" "node $alias ($target) collector exited $node_rc"
      rc=2
    fi
  done

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
