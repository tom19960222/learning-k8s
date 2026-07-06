#!/usr/bin/env bash
# E-11 (exp11): guest-side IO scheduler — none vs the guest kernel's default
# (mq-deadline typically). Pure guest sysfs; no VM restart needed as long as
# the previous scenario in the chain left the VM running with the baseline
# disk attached (run/all.sh guarantees this — every image-based scenario
# before this one restores + cold-restarts to baseline at its own tail).
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
b="$(new_bundle exp11-sched)"
write_prediction "$b" "E-11: guest I/O scheduler none 對 rr/rw 4k qd8/qd32 略優於預設，qd1 落噪音帶（機制推論）"

ip="$(vm_guest_ip)"
default_sched="$(guest_ssh "$ip" 'cat /sys/block/vdb/queue/scheduler')"
printf '%s\n' "$default_sched" > "$b/default-scheduler.txt"

run_matrix_rounds "$b" default "$ip" /dev/vdb "$ROUNDS"

guest_ssh "$ip" 'echo none | sudo tee /sys/block/vdb/queue/scheduler >/dev/null'
guest_ssh "$ip" 'cat /sys/block/vdb/queue/scheduler' | grep -qE '\[none\]' ||
  die "生效驗證失敗: guest scheduler 未切到 none"

run_matrix_rounds "$b" none "$ip" /dev/vdb "$ROUNDS"

restore="$(printf '%s\n' "$default_sched" | grep -oE '\[[a-z_-]+\]' | tr -d '[]')"
if [ -n "$restore" ]; then
  guest_ssh "$ip" "echo $restore | sudo tee /sys/block/vdb/queue/scheduler >/dev/null" || true
fi

printf '%s\n' "$b"
