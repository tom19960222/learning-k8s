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

test_json_escape() {
  local got
  got="$(json_escape 'a"b\c')"
  [[ "$got" == 'a\"b\\c' ]] || fail "json_escape returned '$got'"
}

test_manifest_add() {
  local manifest="$tmpdir/manifest.jsonl"
  local artifact="$tmpdir/artifact.txt"
  printf 'payload\n' >"$artifact"

  manifest_add \
    "$manifest" \
    "host-1" \
    "collector-1" \
    "$artifact" \
    "command with spaces" \
    7 \
    "2026-06-29T00:00:00Z" \
    "2026-06-29T00:00:01Z"

  python3 - "$manifest" <<'PY'
import json
import sys

path = sys.argv[1]
lines = [line.rstrip("\n") for line in open(path)]
if len(lines) != 1:
    raise SystemExit(f"expected 1 manifest entry, got {len(lines)}")
entry = json.loads(lines[0])
expected = {
    "host": "host-1",
    "collector": "collector-1",
    "artifact": path.replace("manifest.jsonl", "artifact.txt"),
    "command": "command with spaces",
    "exit_code": 7,
    "started": "2026-06-29T00:00:00Z",
    "ended": "2026-06-29T00:00:01Z",
}
for key, value in expected.items():
    if entry.get(key) != value:
        raise SystemExit(f"{key}={entry.get(key)!r} != {value!r}")
PY
}

test_redact_file() {
  local source_file="$tmpdir/secret.txt"
  local redaction_log="$tmpdir/redaction.log"

  cat >"$source_file" <<'EOF'
safe line
Password=abc
SECRET=def
token: ghi
keyring: jkl
private_key=xyz
EOF

  redact_file "$source_file" "$redaction_log"

  [[ "$(sed -n '1p' "$source_file")" == "safe line" ]] || fail "safe line was modified"
  for i in 2 3 4 5 6; do
    [[ "$(sed -n "${i}p" "$source_file")" == "[REDACTED]" ]] || fail "line $i was not redacted"
  done

  [[ -s "$redaction_log" ]] || fail "redaction log is empty"
  grep -q "secret.txt" "$redaction_log" || fail "redaction log does not mention the file"
}

test_json_escape
test_manifest_add
test_redact_file

printf 'ok: common helpers\n'
