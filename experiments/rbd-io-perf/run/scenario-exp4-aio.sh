#!/usr/bin/env bash
# E-06 (exp4): aio=io_uring / native / threads, A/B interleaved vs PVE default.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"
# shellcheck disable=SC1091
. "$here/../lib/scenarios.sh"
require_inject_flag "$@"

ROUNDS="${SCEN_ROUNDS:-3}"
BASE="${DATA_SPEC:-ioperf:vm-1031-disk-1}"

for aio in native threads; do
  spec="$BASE,aio=$aio"
  [ "$aio" = "native" ] && spec="$spec,cache=none"
  run_qm_variant_scenario "exp4-aio-$aio" \
    "E-06: 高 QD 下 threads 落後 native/io_uring；qd1 三者接近（機制推論）" \
    "$BASE" "$spec" "aio=$aio" "$ROUNDS"
done
