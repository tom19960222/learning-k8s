#!/usr/bin/env bash
set -euo pipefail

# Cephadm collection helpers live here.

CEPHADM_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CEPHADM_COLLECTOR_DIR/common.sh"

collect_cephadm_command() {
  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 artifact=$6
  shift 6

  local artifact_dir
  artifact_dir="$(dirname "$artifact")"
  ensure_dir "$artifact_dir"

  COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
    run_capture "$manifest" "$seed" "collect-cluster-cephadm" "$artifact" -- \
    ssh -i "$ssh_key" "$seed" sudo cephadm shell -- ceph "$@"
}

collect_cephadm_recent_crashes() {
  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 timeout=$5 crash_ls_artifact=$6

  local crash_dir="$outdir/cluster/ceph/json/crash-info"
  local skip_artifact="$outdir/cluster/ceph/text/crash-info-skip.txt"
  local crash_ids
  local parse_output rc=0

  parse_output="$(
    python3 - "$crash_ls_artifact" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    payload = ''.join(line for line in handle if not line.startswith('#'))

try:
    data = json.loads(payload)
except Exception:
    raise SystemExit(1)

if isinstance(data, dict):
    for key in ('crashes', 'items', 'entries', 'crash_ls'):
        if isinstance(data.get(key), list):
            data = data[key]
            break
    else:
        data = []

ids = []
if isinstance(data, list):
    for item in data[:10]:
        if isinstance(item, str):
            ident = item
        elif isinstance(item, dict):
            ident = item.get('crash_id') or item.get('id') or item.get('name')
        else:
            ident = None
        if ident:
            ids.append(str(ident))

print('\n'.join(ids))
PY
  )" || rc=$?

  if [[ $rc -ne 0 ]]; then
    ensure_dir "$(dirname "$skip_artifact")"
    cat >"$skip_artifact" <<'EOF'
SKIPPED: unable to parse crash list JSON for recent crash inspection
EOF
    return 0
  fi

  crash_ids="$parse_output"
  [[ -n "$crash_ids" ]] || return 0

  local crash_id crash_info_artifact
  while IFS= read -r crash_id; do
    [[ -n "$crash_id" ]] || continue
    crash_info_artifact="$crash_dir/$crash_id.json"
    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$crash_info_artifact" crash info "$crash_id"; then
      rc=2
    fi
  done <<<"$crash_ids"

  return "$rc"
}

collect_cluster_cephadm() {
  local outdir=$1 manifest=$2 seed=$3 ssh_key=$4 since=$5 timeout=$6
  local failed=0
  local json_dir="$outdir/cluster/ceph/json"
  local text_dir="$outdir/cluster/ceph/text"

  ensure_dir "$json_dir"
  ensure_dir "$text_dir"

  local -a json_specs=(
    "status.json::status --format json-pretty"
    "health-detail.json::health detail --format json-pretty"
    "versions.json::versions --format json-pretty"
    "df-detail.json::df detail --format json-pretty"
    "osd-tree.json::osd tree --format json-pretty"
    "osd-df.json::osd df --format json-pretty"
    "osd-dump.json::osd dump --format json-pretty"
    "osd-perf.json::osd perf --format json-pretty"
    "osd-blocked-by.json::osd blocked-by --format json-pretty"
    "pg-stat.json::pg stat --format json-pretty"
    "pg-dump.json::pg dump --format json-pretty"
    "pg-dump-stuck.json::pg dump_stuck --format json-pretty"
    "mon-dump.json::mon dump --format json-pretty"
    "quorum-status.json::quorum_status --format json-pretty"
    "mgr-dump.json::mgr dump --format json-pretty"
    "orch-host-ls.json::orch host ls --format json-pretty"
    "orch-ps.json::orch ps --format json-pretty"
    "orch-device-ls-wide.json::orch device ls --wide --format json-pretty"
    "config-dump.json::config dump --format json-pretty"
    "crash-ls.json::crash ls --format json-pretty"
  )

  local -a text_specs=(
    "status.txt::status"
    "health-detail.txt::health detail"
    "osd-tree.txt::osd tree"
    "orch-ps.txt::orch ps"
  )

  local spec artifact command
  local -a command_words
  for spec in "${json_specs[@]}"; do
    artifact=${spec%%::*}
    command=${spec#*::}
    # shellcheck disable=SC2206
    command_words=($command)
    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$json_dir/$artifact" "${command_words[@]}"; then
      failed=1
    fi
  done

  for spec in "${text_specs[@]}"; do
    artifact=${spec%%::*}
    command=${spec#*::}
    # shellcheck disable=SC2206
    command_words=($command)
    if ! collect_cephadm_command "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$text_dir/$artifact" "${command_words[@]}"; then
      failed=1
    fi
  done

  if ! collect_cephadm_recent_crashes "$outdir" "$manifest" "$seed" "$ssh_key" "$timeout" "$json_dir/crash-ls.json"; then
    failed=1
  fi

  if [[ $failed -ne 0 ]]; then
    return 2
  fi

  return 0
}
