#!/usr/bin/env bash
set -euo pipefail

# Bundle/orchestration helpers used by run/collect.sh. These are pure-ish units
# (SSH target/quoting, bundle metadata, summary, error log, redaction driver)
# kept out of the entrypoint so collect.sh stays a thin orchestrator. Relies on
# common.sh (sourced first by the entrypoint) for redact_file/redact_gz_file.

ssh_target_for_host() {
  local host=$1 ssh_user=$2
  if [[ "$host" == *@* || -z "$ssh_user" ]]; then
    printf '%s' "$host"
  else
    printf '%s@%s' "$ssh_user" "$host"
  fi
}

# Quote a value for safe interpolation into a remote shell string. Returns 1 if
# the value contains a single quote (callers treat that as a hard input error).
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

# Redact every text-ish artifact in the bundle in place (gz handled specially).
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
