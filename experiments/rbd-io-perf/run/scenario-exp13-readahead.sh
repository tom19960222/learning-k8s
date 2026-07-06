#!/usr/bin/env bash
# E-13 (exp13): guest read_ahead_kb sweep — 0 / 128 / 4096 (H-022: readahead
# was entirely uncovered by the original matrix). Pure guest sysfs; no VM
# restart needed. Focus pattern is sr-1m (sequential read) though the full
# matrix still runs each leg for completeness.
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
b="$(new_bundle exp13-readahead)"
write_prediction "$b" "E-13: read_ahead_kb 越大 sr-1m 吞吐越高，隨機 pattern 落噪音帶（機制推論，焦點 sr-1m，H-022）"

ip="$(vm_guest_ip)"
default_ra="$(guest_ssh "$ip" 'cat /sys/block/vdb/queue/read_ahead_kb' | tr -d '[:space:]')"
printf '%s\n' "$default_ra" > "$b/default-read_ahead_kb.txt"

# Trap-restore the original read_ahead_kb, matching the trap-cleanup
# discipline of the image-based wrappers — a die mid-sweep must not leave
# the guest on a swept value.
cleanup() {
  if [ -n "$default_ra" ]; then
    guest_ssh "$ip" "echo $default_ra | sudo tee /sys/block/vdb/queue/read_ahead_kb >/dev/null" 2>/dev/null || true
  fi
}
trap cleanup EXIT

for ra in 0 128 4096; do
  guest_ssh "$ip" "echo $ra | sudo tee /sys/block/vdb/queue/read_ahead_kb >/dev/null"
  guest_ssh "$ip" 'cat /sys/block/vdb/queue/read_ahead_kb' | grep -qE "^$ra\$" ||
    die "生效驗證失敗: read_ahead_kb 未切到 $ra"
  run_matrix_rounds "$b" "ra$ra" "$ip" /dev/vdb "$ROUNDS"
done

printf '%s\n' "$b"
