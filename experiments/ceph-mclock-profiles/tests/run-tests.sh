#!/usr/bin/env bash
# 總測試 gate：跑 tests/test-*.sh，每支獨立可單跑。
# stdout 只放最後的機器行；逐檔進度走 stderr。
set -u

here="$(cd "$(dirname "$0")" && pwd)"
pass=0
fail=0

for t in "$here"/test-*.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t")"
  out="$(bash "$t" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    printf 'PASS %s — %s\n' "$name" "$(printf '%s\n' "$out" | tail -1)" >&2
  else
    fail=$((fail + 1))
    printf 'FAIL %s (rc=%d)\n' "$name" "$rc" >&2
    printf '%s\n' "$out" >&2
  fi
done

printf 'tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
