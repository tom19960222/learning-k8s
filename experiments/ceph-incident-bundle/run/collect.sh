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

Options:
  --seed USER@HOST
  --out DIR
  --mode auto|cephadm|rook
  --since DURATION
  --timeout SECONDS
  --skip-logs
  --keep-workdir
  --help
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
      probe_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$seed" command -v cephadm)
      if command -v timeout >/dev/null 2>&1; then
        probe_cmd=(timeout "$timeout" "${probe_cmd[@]}")
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
  local workdir=$1 alias=$2 target=$3 ssh_key=$4 since=$5 timeout=$6 skip_logs=$7
  local node_dir="$workdir/nodes/$alias"
  local node_tar="$workdir/.node-$alias.tar.gz"
  local remote_cmd rc=0
  local -a ssh_cmd

  remote_cmd='set -u
alias_name=$1
since=$2
timeout_value=$3
skip_logs=$4
tmp="${TMPDIR:-/tmp}/ceph-incident-node.$$"
rm -rf "$tmp"
mkdir -p "$tmp"
tar -xzf - -C "$tmp"
out="$tmp/out"
args=(--out "$out" --host-alias "$alias_name" --since "$since" --timeout "$timeout_value")
if [[ "$skip_logs" == "1" ]]; then
  args+=(--skip-logs)
fi
set +e
bash "$tmp/lib/collect-node.sh" "${args[@]}"
rc=$?
set -e
tar -czf - -C "$out" .
rm -rf "$tmp"
exit "$rc"'

  ssh_cmd=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$target" bash -c "$remote_cmd" bash "$alias" "$since" "$timeout" "$skip_logs")
  if command -v timeout >/dev/null 2>&1; then
    ssh_cmd=(timeout "$timeout" "${ssh_cmd[@]}")
  fi

  set +e
  tar -czf - -C "$COLLECT_ROOT" lib/common.sh lib/collect-node.sh |
    "${ssh_cmd[@]}" >"$node_tar"
  rc=$?
  set -e

  ensure_dir "$node_dir"
  if [[ -s "$node_tar" ]]; then
    if ! tar -xzf "$node_tar" -C "$node_dir" >/dev/null 2>/dev/null; then
      rm -rf "$node_dir"
      ensure_dir "$node_dir"
      printf 'SKIPPED: invalid node archive returned from %s\n' "$target" >"$node_dir/SKIPPED.txt"
      rc=2
    fi
  else
    printf 'SKIPPED: no node archive returned from %s\n' "$target" >"$node_dir/SKIPPED.txt"
  fi
  rm -f "$node_tar"

  return "$rc"
}

redact_bundle_text() {
  local workdir=$1 redaction_log="$workdir/redactions.log"
  local path

  while IFS= read -r path; do
    redact_file "$path" "$redaction_log"
  done < <(find "$workdir/cluster" "$workdir/nodes" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.yaml' -o -name '*.json' -o -name '*.jsonl' -o -name '*.conf' -o -name 'config' \) -print 2>/dev/null || true)
}

main() {
  local inventory= ssh_key= seed_override= out_dir="$COLLECT_ROOT/results"
  local mode=auto since=24h timeout=20 skip_logs=0 keep_workdir=0
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

  ensure_dir "$out_dir"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  workdir="$out_dir/tmp.$timestamp.$$"
  manifest="$workdir/manifest.jsonl"
  ensure_dir "$workdir"
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
    alias="$(parse_host_entry "$entry" | sed -n '1p')" || die "invalid HOSTS entry: $entry"
    host="$(parse_host_entry "$entry" | sed -n '2p')" || die "invalid HOSTS entry: $entry"
    target="$(ssh_target_for_host "$host" "$ssh_user")"

    if collect_remote_node "$workdir" "$alias" "$target" "$ssh_key" "$since" "$timeout" "$skip_logs"; then
      node_ok=$((node_ok + 1))
    else
      node_rc=$?
      node_failed=$((node_failed + 1))
      append_error "$workdir" "node $alias ($target) collector exited $node_rc"
      rc=2
    fi
  done

  redact_bundle_text "$workdir"
  write_summary "$workdir" "$mode" "$seed" "$node_ok" "$node_failed" "$cluster_rc" "$rc"

  "$COLLECT_ROOT/lib/verify-bundle.sh" "$workdir" >/dev/null

  bundle="$out_dir/ceph-incident-$timestamp.tar.gz"
  tar -czf "$bundle" -C "$workdir" .
  "$COLLECT_ROOT/lib/verify-bundle.sh" "$bundle" >/dev/null

  if [[ $keep_workdir -eq 0 ]]; then
    rm -rf "$workdir"
  else
    printf 'kept workdir: %s\n' "$workdir"
  fi

  printf 'bundle: %s\n' "$bundle"
  return "$rc"
}

main "$@"
