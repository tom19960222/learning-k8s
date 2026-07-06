#!/usr/bin/env bash
# E-07 (exp2): iothread=1 vs PVE baseline (no iothread flag on virtio1).
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

run_qm_variant_scenario "exp2-iothread" \
  "E-07: iothread=1 讓資料盤 IO 移出 QEMU 主執行緒，高 qd（qd8/qd32）下略優；qd1 差異落噪音帶（機制推論）" \
  "$BASE" "$BASE,iothread=1" "iothread" "$ROUNDS"
