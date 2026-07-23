#!/bin/bash
# ceph-time-sync-alerts 測試總 gate：E-05a promtool 規則測試 + E-01(L1) parser 判決。
# stdout 只放機器要抓的那行（PASS/FAIL），其餘 log 走 stderr（repo 慣例）。
set -euo pipefail

cd "$(dirname "$0")"

status=0

if command -v promtool >/dev/null 2>&1; then
    for f in promtool/*.test.yml; do
        echo "== promtool test rules ${f}" >&2
        if ! promtool test rules "${f}" >&2; then
            status=1
        fi
    done
else
    echo "warn: promtool 不存在，跳過規則測試（brew install prometheus）" >&2
fi

echo "== parser tests" >&2
if ! bash parser/run-parser-tests.sh >/dev/null; then
    status=1
fi

if [[ ${status} -eq 0 ]]; then
    echo "PASS"
else
    echo "FAIL"
fi
exit "${status}"
