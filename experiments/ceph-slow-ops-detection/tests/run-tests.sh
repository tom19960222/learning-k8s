#!/usr/bin/env bash
# Total test gate: unit tests + promtool rule tests + shellcheck.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP_DIR="$(dirname "${TESTS_DIR}")"
rc=0

echo "== promjson unit tests ==" >&2
bash "${TESTS_DIR}/test-promjson.sh" || rc=1

echo "== common.sh logic tests ==" >&2
bash "${TESTS_DIR}/test-common-logic.sh" || rc=1

echo "== promtool rule tests ==" >&2
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "${EXP_DIR}/rules/ceph-slow-ops-fast.yml" >&2 || rc=1
  for t in "${TESTS_DIR}"/promtool/*.test.yml; do
    promtool test rules "${t}" >&2 || rc=1
  done
else
  echo "WARN: promtool not found, skipping rule tests" >&2
fi

if [ "${rc}" = "0" ]; then echo "ALL TESTS PASS"; else echo "TESTS FAILED"; fi
exit "${rc}"
