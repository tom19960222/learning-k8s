#!/bin/bash
OUT=$1; DEV=/dev/rbd0; mkdir -p $OUT
run(){ sudo fio --name=$1 --filename=$DEV --direct=1 --ioengine=libaio \
  --rw=$2 --bs=$3 --iodepth=$4 --numjobs=1 --time_based --runtime=60 \
  --ramp_time=15 --randseed=8675309 --group_reporting \
  --output-format=json --output=$OUT/fio-$1.json \
  --write_lat_log=$OUT/fio-$1 --log_avg_msec=1000 > /dev/null 2>&1; }
run rr-qd1  randread  4k 1;  run rr-qd8  randread  4k 8;  run rr-qd32 randread  4k 32
run rw-qd1  randwrite 4k 1;  run rw-qd8  randwrite 4k 8;  run rw-qd32 randwrite 4k 32
run sr-1m   read      1M 16; run sw-1m   write     1M 16
