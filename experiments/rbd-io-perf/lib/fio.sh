#!/usr/bin/env bash
# fio pattern table and command rendering. Pure string functions (no ssh).

# shellcheck disable=SC2034  # FIO_PATTERNS is sourced and used externally in tests
FIO_PATTERNS="rr-4k-qd1:randread:4k:1 rr-4k-qd8:randread:4k:8 rr-4k-qd32:randread:4k:32 rw-4k-qd1:randwrite:4k:1 rw-4k-qd8:randwrite:4k:8 rw-4k-qd32:randwrite:4k:32 sr-1m:read:1M:16 sw-1m:write:1M:16"

fio_cmd_numjobs() {
  local entry="$1" filename="$2" numjobs="$3"
  local name rw bs qd
  name="${entry%%:*}"; entry="${entry#*:}"
  rw="${entry%%:*}"; entry="${entry#*:}"
  bs="${entry%%:*}"; qd="${entry##*:}"
  printf 'fio --name=%s --filename=%s --direct=1 --rw=%s --bs=%s --iodepth=%s --numjobs=%s --ioengine=libaio --ramp_time=15 --runtime=60 --time_based --randseed=8675309 --group_reporting --output-format=json\n' \
    "$name" "$filename" "$rw" "$bs" "$qd" "$numjobs"
}

fio_cmd() { fio_cmd_numjobs "$1" "$2" 1; }

prefill_cmd() {
  printf 'fio --name=prefill --filename=%s --direct=1 --rw=write --bs=1M --iodepth=8 --ioengine=libaio --group_reporting --output-format=json\n' "$1"
}
