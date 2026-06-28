#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for the Ceph incident bundle harness.

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

die() {
  log "FATAL: $*"
  exit 1
}

ceph_incident_bundle_log() {
  log "$*"
}

require_file() {
  [[ -f "$1" ]] || die "missing file: $1"
}

ensure_dir() {
  mkdir -p "$1"
}

json_escape() {
  python3 - "$1" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1])[1:-1])
PY
}

manifest_add() {
  local manifest=$1 host=$2 collector=$3 artifact=$4 command=$5 exit_code=$6 started=$7 ended=$8
  ensure_dir "$(dirname "$manifest")"
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
  ensure_dir "$(dirname "$redaction_log")"

  local source_dir tmp_file count line nocasematch_state
  source_dir="$(dirname "$source_file")"
  tmp_file="$(mktemp "$source_dir/.${source_file##*/}.XXXXXX")"
  count=0
  if shopt -q nocasematch; then
    nocasematch_state='shopt -s nocasematch'
  else
    nocasematch_state='shopt -u nocasematch'
  fi
  shopt -s nocasematch

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ (password|secret|token|keyring|private_key) ]]; then
      printf '[REDACTED]\n' >>"$tmp_file"
      count=$((count + 1))
    else
      printf '%s\n' "$line" >>"$tmp_file"
    fi
  done <"$source_file"

  eval "$nocasematch_state"
  chmod --reference="$source_file" "$tmp_file" 2>/dev/null || true
  mv -f "$tmp_file" "$source_file"
  printf '%s: %s line(s) redacted\n' "$source_file" "$count" >>"$redaction_log"
}

run_capture() {
  local manifest=$1 host=$2 collector=$3 artifact=$4
  shift 4
  [[ ${1-} == -- ]] || die "run_capture requires -- before the command"
  shift

  local -a cmd timeout_cmd
  local started ended rc command_string artifact_dir artifact_tmp

  cmd=("$@")
  [[ ${#cmd[@]} -gt 0 ]] || die "run_capture requires a command"

  started="$(date -u +%FT%TZ)"
  artifact_dir="$(dirname "$artifact")"
  ensure_dir "$artifact_dir"
  artifact_tmp="$(mktemp "$artifact_dir/.${artifact##*/}.XXXXXX")"

  printf '# host: %s\n# collector: %s\n# started: %s\n' "$host" "$collector" "$started" >"$artifact_tmp"
  printf -v command_string '%q ' "${cmd[@]}"
  command_string=${command_string% }

  if command -v timeout >/dev/null 2>&1; then
    printf '# timeout: %ss\n' "${COMMAND_TIMEOUT:-20}" >>"$artifact_tmp"
    timeout_cmd=(timeout "${COMMAND_TIMEOUT:-20}")
    set +e
    "${timeout_cmd[@]}" "${cmd[@]}" >>"$artifact_tmp" 2>&1
    rc=$?
    set -e
  else
    printf '# timeout: unavailable\n' >>"$artifact_tmp"
    set +e
    "${cmd[@]}" >>"$artifact_tmp" 2>&1
    rc=$?
    set -e
  fi

  ended="$(date -u +%FT%TZ)"
  mv -f "$artifact_tmp" "$artifact"
  manifest_add "$manifest" "$host" "$collector" "$artifact" "$command_string" "$rc" "$started" "$ended"

  if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
    ensure_dir "$(dirname "$ERROR_LOG")"
    printf '%s host=%s collector=%s artifact=%s exit=%s command=%s\n' \
      "$ended" "$host" "$collector" "$artifact" "$rc" "$command_string" >>"$ERROR_LOG"
  fi

  return "$rc"
}

copy_if_exists() {
  local source=$1 dest=$2
  [[ -e "$source" ]] || return 0
  ensure_dir "$(dirname "$dest")"
  cp -a "$source" "$dest"
}
