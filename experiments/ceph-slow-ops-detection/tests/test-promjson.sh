#!/usr/bin/env bash
# Unit tests for lib/promjson.py against fixture JSON.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP_DIR="$(dirname "${TESTS_DIR}")"
FIX="${TESTS_DIR}/fixtures"
PJ="python3 ${EXP_DIR}/lib/promjson.py"

fails=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "${want}" = "${got}" ]; then
    echo "ok   ${label}" >&2
  else
    echo "FAIL ${label}: want=${want} got=${got}" >&2
    fails=$((fails + 1))
  fi
}

# range fixture: two series, values over 4 timestamps
expect "max"            "7.0"        "$(${PJ} max "${FIX}/range-two-series.json")"
expect "first_ts_gt_0"  "1700000010" "$(${PJ} first_ts_gt "${FIX}/range-two-series.json" 0)"
expect "first_ts_gt_5"  "1700000030" "$(${PJ} first_ts_gt "${FIX}/range-two-series.json" 5)"
expect "first_ts_gt_99" "none"       "$(${PJ} first_ts_gt "${FIX}/range-two-series.json" 99)"
expect "delta"          "9.0"        "$(${PJ} delta_first_last "${FIX}/range-two-series.json")"
expect "series_count"   "2"          "$(${PJ} series_count "${FIX}/range-two-series.json")"

# empty result fixture
expect "empty_max"    "none" "$(${PJ} max "${FIX}/range-empty.json")"
expect "empty_first"  "none" "$(${PJ} first_ts_gt "${FIX}/range-empty.json" 0)"
expect "empty_delta"  "0.0"  "$(${PJ} delta_first_last "${FIX}/range-empty.json")"
expect "empty_series" "0"    "$(${PJ} series_count "${FIX}/range-empty.json")"

expect "first_val"      "0.0"        "$(${PJ} first_val "${FIX}/range-two-series.json")"
expect "empty_first_val" "none"       "$(${PJ} first_val "${FIX}/range-empty.json")"

# instant vector fixture
expect "instant_max"  "3.0" "$(${PJ} max "${FIX}/instant-vector.json")"
expect "instant_last" "3.0" "$(${PJ} last_val "${FIX}/instant-vector.json")"

exit "${fails}"
