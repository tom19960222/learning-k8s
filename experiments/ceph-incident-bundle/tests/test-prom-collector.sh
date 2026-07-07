#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/bundle.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/collect-prometheus.sh"

test_duration_parser() {
  [[ "$(prom_duration_seconds 90)" == "90" ]] || fail "90 -> 90"
  [[ "$(prom_duration_seconds 45s)" == "45" ]] || fail "45s -> 45"
  [[ "$(prom_duration_seconds 30m)" == "1800" ]] || fail "30m -> 1800"
  [[ "$(prom_duration_seconds 24h)" == "86400" ]] || fail "24h -> 86400"
  [[ "$(prom_duration_seconds 7d)" == "604800" ]] || fail "7d -> 604800"
  [[ "$(prom_duration_seconds 2w)" == "1209600" ]] || fail "2w -> 1209600"
  prom_duration_seconds yesterday >/dev/null 2>&1 && fail "'yesterday' should be rejected" || true
  prom_duration_seconds 5x >/dev/null 2>&1 && fail "'5x' should be rejected" || true
  prom_duration_seconds '' >/dev/null 2>&1 && fail "empty should be rejected" || true
  prom_duration_seconds 0 >/dev/null 2>&1 && fail "'0' should be rejected" || true
}

test_auto_step() {
  [[ "$(prom_auto_step 86400)" == "15" ]] || fail "24h window -> 15s floor"
  [[ "$(prom_auto_step 604800)" == "61" ]] || fail "7d window -> ceil(604800/10000)=61"
  [[ "$(prom_auto_step 60)" == "15" ]] || fail "tiny window -> 15s floor"
}

test_mask_url() {
  [[ "$(prom_mask_url 'http://u:sekrit@h:9090')" == 'http://u:***@h:9090' ]] || fail "credentials should be masked"
  [[ "$(prom_mask_url 'http://h:9090/sub')" == 'http://h:9090/sub' ]] || fail "no-credential URL should pass through"
}

test_require_cmds() {
  local onlycurl="$tmpdir/onlycurl" out
  mkdir -p "$onlycurl"
  printf '#!/bin/sh\nexit 0\n' >"$onlycurl/curl"
  chmod +x "$onlycurl/curl"
  # command -v is a builtin, so a bare restricted PATH is enough here.
  out="$(PATH="$onlycurl" prom_require_cmds 2>&1)" && fail "should fail when python3 is missing" || true
  [[ "$out" == *python3* ]] || fail "reason should name python3, got '$out'"
}

test_duration_parser
test_auto_step
test_mask_url
test_require_cmds

printf 'ok: prom collector\n'
