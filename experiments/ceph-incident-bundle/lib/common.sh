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

  local source_dir tmp_file count line nocasematch_state in_pem redact mode
  source_dir="$(dirname -- "$source_file")"
  tmp_file="$(mktemp "$source_dir/.${source_file##*/}.XXXXXX")"
  count=0
  in_pem=0
  if shopt -q nocasematch; then
    nocasematch_state='shopt -s nocasematch'
  else
    nocasematch_state='shopt -u nocasematch'
  fi
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

  eval "$nocasematch_state"
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

  local -a cmd timeout_cmd
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

  if command -v timeout >/dev/null 2>&1; then
    printf '# timeout: %ss\n' "${COMMAND_TIMEOUT:-20}" >>"$artifact_tmp"
    if timeout "${COMMAND_TIMEOUT:-20}" "${cmd[@]}" >>"$artifact_tmp" 2>&1; then
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

  ended="$(date -u +%FT%TZ)"
  mv -f -- "$artifact_tmp" "$artifact"
  manifest_add "$manifest" "$host" "$collector" "$artifact" "$command_string" "$rc" "$started" "$ended"

  if [[ $rc -ne 0 && -n "${ERROR_LOG:-}" ]]; then
    ensure_dir "$(dirname -- "$ERROR_LOG")"
    printf '%s host=%s collector=%s artifact=%s exit=%s command=%s\n' \
      "$ended" "$host" "$collector" "$artifact" "$rc" "$command_string" >>"$ERROR_LOG"
  fi

  return "$rc"
}

copy_if_exists() {
  local source=$1 dest=$2
  [[ -e "$source" ]] || return 0
  ensure_dir "$(dirname -- "$dest")"
  cp -a -- "$source" "$dest"
}
