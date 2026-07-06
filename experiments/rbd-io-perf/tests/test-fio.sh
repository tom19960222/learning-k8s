#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"

n=0
# shellcheck disable=SC2034  # p is unused; we only count pattern entries
for p in $FIO_PATTERNS; do n=$((n+1)); done
[ "$n" -eq 8 ] || { echo "want 8 patterns, got $n"; exit 1; }

c="$(fio_cmd "rr-4k-qd32:randread:4k:32" /dev/vdb)"
echo "$c" | grep -q -- '--rw=randread' || { echo "rw missing: $c"; exit 1; }
echo "$c" | grep -q -- '--bs=4k' || exit 1
echo "$c" | grep -q -- '--iodepth=32' || exit 1
echo "$c" | grep -q -- '--filename=/dev/vdb' || exit 1
echo "$c" | grep -q -- '--ramp_time=15' || exit 1
echo "$c" | grep -q -- '--output-format=json' || exit 1
echo "$c" | grep -q -- '--randseed=8675309' || exit 1
echo "$c" | grep -q -- '--numjobs=1' || exit 1

c="$(fio_cmd_numjobs "rr-4k-qd8:randread:4k:8" /dev/vdb 4)"
echo "$c" | grep -q -- '--numjobs=4' || { echo "numjobs missing: $c"; exit 1; }

c="$(prefill_cmd /dev/vdb)"
echo "$c" | grep -q -- '--rw=write' || exit 1
echo "$c" | grep -q -- '--filename=/dev/vdb' || exit 1
echo OK
