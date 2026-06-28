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

test_json_escape_is_shell_native() {
  local fakebin="$tmpdir/fakebin"
  mkdir -p "$fakebin"
  cat >"$fakebin/python3" <<'EOF'
#!/usr/bin/env bash
printf 'python3 should not be used\n' >&2
exit 99
EOF
  chmod +x "$fakebin/python3"

  local got
  got="$(PATH="$fakebin:$PATH" json_escape 'a"b\c')"
  [[ "$got" == 'a\"b\\c' ]] || fail "shell-native json_escape failed with '$got'"
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

test_manifest_add_rejects_non_numeric_exit_code() {
  local manifest="$tmpdir/invalid-manifest.jsonl"
  local artifact="$tmpdir/artifact-invalid.txt"
  printf 'payload\n' >"$artifact"

  local output rc
  set +e
  output="$(
    bash -c '
      set -euo pipefail
      ROOT=$1
      MANIFEST=$2
      ARTIFACT=$3
      # shellcheck disable=SC1091
      source "$ROOT/lib/common.sh"
      manifest_add \
        "$MANIFEST" \
        "host-1" \
        "collector-1" \
        "$ARTIFACT" \
        "bad command" \
        "abc" \
        "2026-06-29T00:00:00Z" \
        "2026-06-29T00:00:01Z"
    ' bash "$ROOT" "$manifest" "$artifact" 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != "0" ]] || fail "manifest_add accepted a non-numeric exit code"
  [[ "$output" == *"exit_code"* ]] || fail "manifest_add did not explain the exit_code failure"
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

test_redact_file_private_key_variants() {
  local source_file="$tmpdir/private-keys.txt"
  local redaction_log="$tmpdir/private-keys.log"

  cat >"$source_file" <<'EOF'
plain
-----BEGIN OPENSSH PRIVATE KEY-----
private-key: abc
PRIVATE KEY material
EOF

  redact_file "$source_file" "$redaction_log"

  [[ "$(sed -n '1p' "$source_file")" == "plain" ]] || fail "plain line was modified"
  for i in 2 3 4; do
    [[ "$(sed -n "${i}p" "$source_file")" == "[REDACTED]" ]] || fail "private key marker on line $i was not redacted"
  done
}

test_run_capture_success() {
  local manifest="$tmpdir/run-manifest.jsonl"
  local artifact="$tmpdir/run-artifact.txt"

  run_capture "$manifest" "host-a" "collector-a" "$artifact" -- printf 'hello world\n'

  [[ "$(sed -n '1p' "$artifact")" == "# host: host-a" ]] || fail "artifact header missing host"
  grep -q 'hello world' "$artifact" || fail "artifact output missing"
  python3 - "$manifest" "$artifact" <<'PY'
import json
import sys

manifest_path, artifact_path = sys.argv[1:3]
lines = [line.rstrip("\n") for line in open(manifest_path)]
if len(lines) != 1:
    raise SystemExit(f"expected 1 manifest entry, got {len(lines)}")
entry = json.loads(lines[0])
if entry["artifact"] != artifact_path:
    raise SystemExit("artifact path mismatch")
if entry["exit_code"] != 0:
    raise SystemExit(f"unexpected exit code {entry['exit_code']}")
PY
}

test_run_capture_non_zero_writes_error_log_and_returns_code() {
  local manifest="$tmpdir/run-manifest-fail.jsonl"
  local artifact="$tmpdir/run-artifact-fail.txt"
  local error_log="$tmpdir/errors.log"
  local rc=0

  ERROR_LOG="$error_log" run_capture "$manifest" "host-b" "collector-b" "$artifact" -- bash -c 'printf fail-output; exit 7' || rc=$?
  [[ "$rc" == "7" ]] || fail "run_capture returned $rc instead of 7"
  grep -q 'fail-output' "$artifact" || fail "failure output missing from artifact"
  grep -q 'exit=7' "$error_log" || fail "error log missing exit code"
  python3 - "$manifest" <<'PY'
import json
import sys

entry = json.loads(open(sys.argv[1]).readline())
if entry["exit_code"] != 7:
    raise SystemExit(f"unexpected exit code {entry['exit_code']}")
PY
}

test_run_capture_missing_double_dash_is_fatal() {
  local manifest="$tmpdir/run-manifest-missing-dash.jsonl"
  local artifact="$tmpdir/run-artifact-missing-dash.txt"
  local rc output

  set +e
  output="$(
    bash -c '
      set -euo pipefail
      ROOT=$1
      MANIFEST=$2
      ARTIFACT=$3
      # shellcheck disable=SC1091
      source "$ROOT/lib/common.sh"
      run_capture "$MANIFEST" "host-c" "collector-c" "$ARTIFACT" printf "missing-dash\n"
    ' bash "$ROOT" "$manifest" "$artifact" 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != "0" ]] || fail "run_capture accepted missing --"
  [[ "$output" == *"-- before the command"* ]] || fail "missing -- failure was not explained"
}

test_run_capture_timeout_branch() {
  local fakebin="$tmpdir/timeout-bin"
  local timeout_log="$tmpdir/timeout.log"
  mkdir -p "$fakebin"
  cat >"$fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TIMEOUT_LOG"
shift
"$@"
EOF
  chmod +x "$fakebin/timeout"

  local manifest="$tmpdir/run-manifest-timeout.jsonl"
  local artifact="$tmpdir/run-artifact-timeout.txt"
  PATH="$fakebin:$PATH" TIMEOUT_LOG="$timeout_log" run_capture "$manifest" "host-d" "collector-d" "$artifact" -- printf 'timeout-path\n'

  grep -q 'timeout-path' "$artifact" || fail "timeout branch did not execute command"
  grep -q '^20 printf timeout-path\\n$' "$timeout_log" || fail "fake timeout was not used"
  grep -q '^# timeout: 20s$' "$artifact" || fail "timeout header missing"
}

test_run_capture_preserves_errexit_state() {
  local manifest="$tmpdir/run-manifest-state.jsonl"
  local artifact="$tmpdir/run-artifact-state.txt"
  local status

  set +e
  run_capture "$manifest" "host-e" "collector-e" "$artifact" -- bash -c 'exit 3'
  status=$?
  false
  status=$?
  set -e

  [[ "$status" == "1" ]] || fail "run_capture changed errexit state"
}

test_json_escape
test_json_escape_is_shell_native
test_manifest_add
test_manifest_add_rejects_non_numeric_exit_code
test_redact_file
test_redact_file_private_key_variants
test_run_capture_success
test_run_capture_non_zero_writes_error_log_and_returns_code
test_run_capture_missing_double_dash_is_fatal
test_run_capture_timeout_branch
test_run_capture_preserves_errexit_state

printf 'ok: common helpers\n'
