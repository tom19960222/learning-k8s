#!/usr/bin/env bash
# Own-image lifecycle. Every image name MUST start with "ioperf-";
# anything else is refused so the harness can never touch foreign images.
# Requires lib/common.sh.

_img_guard() {
  case "$1" in
    ioperf-*) : ;;
    *) die "拒絕操作非 ioperf- 前綴的 image: $1" ;;
  esac
}

img_create() {
  local name="$1" size="$2"; shift 2
  _img_guard "$name"
  pve_ssh "sudo -n rbd create $POOL/$name --size $size $*"
}

img_rm() {
  _img_guard "$1"
  pve_ssh "sudo -n rbd rm $POOL/$1"
}

img_exists() {
  _img_guard "$1"
  pve_ssh "sudo -n rbd info $POOL/$1 >/dev/null 2>&1 && echo yes || echo no" | grep -q yes
}

img_info() {
  _img_guard "$1"
  pve_ssh "sudo -n rbd info $POOL/$1"
}

img_map() {
  local name="$1" opts="${2:-}"
  _img_guard "$name"
  local cmd="sudo -n rbd map $POOL/$name"
  [ -n "$opts" ] && cmd="$cmd -o $opts"
  pve_ssh "$cmd" | tr -d '[:space:]'
}

img_unmap() {
  case "$1" in
    /dev/rbd*) : ;;
    *) die "img_unmap 需要 /dev/rbdN 路徑: $1" ;;
  esac
  pve_ssh "sudo -n rbd unmap $1"
}

img_meta_set() {
  _img_guard "$1"
  pve_ssh "sudo -n rbd image-meta set $POOL/$1 $2 $3"
}

img_meta_get() {
  _img_guard "$1"
  pve_ssh "sudo -n rbd image-meta get $POOL/$1 $2"
}
