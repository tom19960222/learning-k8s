#!/usr/bin/env bash
set -euo pipefail

osd_service_name() {
  local fsid=$1 osd_id=$2
  printf 'ceph-%s@osd.%s.service\n' "$fsid" "$osd_id"
}

mon_service_name() {
  local fsid=$1 mon_name=$2
  printf 'ceph-%s@mon.%s.service\n' "$fsid" "$mon_name"
}

lab_osd_host_ip() {
  local host_name=$1
  case "$host_name" in
    ceph-lab-osd-01) printf '%s\n' "$LAB_OSD_01_HOST" ;;
    ceph-lab-osd-02) printf '%s\n' "$LAB_OSD_02_HOST" ;;
    ceph-lab-osd-03) printf '%s\n' "$LAB_OSD_03_HOST" ;;
    *) die "unknown OSD host: $host_name" ;;
  esac
}

cgroup_io_max_path_command() {
  local service=$1
  printf '%s\n' "cg=\$(systemctl show -p ControlGroup --value $service); test -n \"\$cg\"; printf '%s\\n' \"/sys/fs/cgroup\${cg}/io.max\""
}

io_throttle_command() {
  local major_minor=$1 bytes_per_second=$2 io_max_path=$3
  printf '%s\n' "printf '%s\\n' '$major_minor rbps=$bytes_per_second wbps=$bytes_per_second riops=max wiops=max' | sudo tee $io_max_path >/dev/null"
}

io_unthrottle_command() {
  local major_minor=$1 io_max_path=$2
  printf '%s\n' "printf '%s\\n' '$major_minor rbps=max wbps=max riops=max wiops=max' | sudo tee $io_max_path >/dev/null"
}

pool_create_commands() {
  local pool=$1
  printf 'ceph osd pool create %s 1\n' "$pool"
  printf 'ceph osd pool set %s size 3\n' "$pool"
  printf 'ceph osd pool set %s min_size 2\n' "$pool"
  printf 'rados -p %s put sentinel /etc/hosts\n' "$pool"
}

pool_cleanup_commands() {
  local pool=$1
  printf 'rados -p %s cleanup --prefix benchmark_data || true\n' "$pool"
  printf 'ceph osd pool delete %s %s --yes-i-really-really-mean-it || true\n' "$pool" "$pool"
}
