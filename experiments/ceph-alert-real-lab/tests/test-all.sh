#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
before_dirs_file="$(mktemp)"
after_dirs_file="$(mktemp)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$before_dirs_file" "$after_dirs_file"
}

trap cleanup EXIT

find "$ROOT/results" -maxdepth 1 -type d | sort >"$before_dirs_file"

set +e
bash "$ROOT/run/all.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "all.sh should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'all requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
cmp -s "$before_dirs_file" "$after_dirs_file" || fail "all.sh created result dirs before destructive ack"

ok "all.sh destructive ack guard"
