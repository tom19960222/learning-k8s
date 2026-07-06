#!/usr/bin/env bash
# Test gate: run every tests/test-*.sh; summary on stdout.
set -u
cd "$(dirname "$0")" || exit 1
pass=0; fail=0
for t in test-*.sh; do
  [ -e "$t" ] || continue
  if bash "$t" >/dev/null 2>&1; then
    pass=$((pass+1)); echo "PASS $t" >&2
  else
    fail=$((fail+1)); echo "FAIL $t" >&2; bash "$t" >&2 2>&1 || true
  fi
done
echo "tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
