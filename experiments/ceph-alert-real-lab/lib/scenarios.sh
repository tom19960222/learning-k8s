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

lab_mon_host_ip() {
  local host_name=$1
  case "$host_name" in
    "$LAB_MON_01_NAME") printf '%s\n' "$LAB_MON_01_HOST" ;;
    "$LAB_MON_02_NAME") printf '%s\n' "$LAB_MON_02_HOST" ;;
    "$LAB_MON_03_NAME") printf '%s\n' "$LAB_MON_03_HOST" ;;
    *) die "unknown MON host: $host_name" ;;
  esac
}

shell_quote_arg() {
  local value=$1
  case "$value" in
    *"'"*)
      printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
      ;;
    *)
      printf "'%s'" "$value"
      ;;
  esac
}

cgroup_io_max_path_command() {
  local service=$1
  printf '%s\n' "cg=\$(systemctl show -p ControlGroup --value $service) || exit 1; test -n \"\$cg\" || exit 1; printf '%s\\n' \"/sys/fs/cgroup\${cg}/io.max\""
}

io_throttle_command() {
  local major_minor=$1 bytes_per_second=$2 io_max_path=$3 quoted_path
  quoted_path="$(shell_quote_arg "$io_max_path")"
  printf '%s\n' "printf '%s\\n' '$major_minor rbps=$bytes_per_second wbps=$bytes_per_second riops=max wiops=max' | sudo tee $quoted_path >/dev/null"
}

io_unthrottle_command() {
  local major_minor=$1 io_max_path=$2 quoted_path
  quoted_path="$(shell_quote_arg "$io_max_path")"
  printf '%s\n' "printf '%s\\n' '$major_minor rbps=max wbps=max riops=max wiops=max' | sudo tee $quoted_path >/dev/null"
}

pool_create_commands() {
  local pool=$1
  printf 'ceph osd pool create %s 1\n' "$pool"
  printf 'ceph osd pool set %s size 3\n' "$pool"
  printf 'ceph osd pool set %s min_size 2\n' "$pool"
  printf 'rados -p %s put sentinel /etc/hosts\n' "$pool"
}

pool_delete_command() {
  local pool=$1
  printf "%s\n" "sh -c 'ceph config set mon mon_allow_pool_delete true; ceph osd pool delete $pool $pool --yes-i-really-really-mean-it; rc=\$?; ceph config set mon mon_allow_pool_delete false; exit \$rc'"
}

pool_cleanup_commands() {
  local pool=$1
  printf '%s || true\n' "$(pool_delete_command "$pool")"
}
