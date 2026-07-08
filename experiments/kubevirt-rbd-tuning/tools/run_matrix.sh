#!/bin/bash
# guest 內跑：bash run_matrix.sh <輸出目錄>
# 資料盤自動偵測：16GiB(17179869184) 的那顆（不管 vdb 還是 sda）
OUT=$1; mkdir -p $OUT
DEV=/dev/$(lsblk -bdno NAME,SIZE | awk '$2==17179869184{print $1; exit}')
[ "$DEV" = "/dev/" ] && { echo "FATAL: 16GiB data disk not found" >&2; exit 3; }
run(){ sudo fio --name=$1 --filename=$DEV --direct=1 --ioengine=libaio \
  --rw=$2 --bs=$3 --iodepth=$4 --numjobs=1 --time_based --runtime=60 \
  --ramp_time=15 --randseed=8675309 --group_reporting \
  --output-format=json --output=$OUT/fio-$1.json \
  --write_lat_log=$OUT/fio-$1 --log_avg_msec=1000 > /dev/null; }
run rr-qd1  randread  4k 1;  run rr-qd8  randread  4k 8;  run rr-qd32 randread  4k 32
run rw-qd1  randwrite 4k 1;  run rw-qd8  randwrite 4k 8;  run rw-qd32 randwrite 4k 32
run sr-1m   read      1M 16; run sw-1m   write     1M 16
