#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/rbdimg.sh"

# Prefix guard: non-ioperf- names must be rejected
if ( img_create vm-103-disk-0 16G ) 2>/dev/null; then echo "prefix guard missing"; exit 1; fi
if ( img_rm vm-103-disk-0 ) 2>/dev/null; then echo "rm prefix guard missing"; exit 1; fi

img_create ioperf-data 16G --object-size 16M
grep -q 'rbd create ioperf/ioperf-data --size 16G --object-size 16M' "$FAKE_SSH_LOG" || { echo "create cmd wrong"; cat "$FAKE_SSH_LOG"; exit 1; }

printf '/dev/rbd7\n' > "$FAKE_SSH_DIR/rbd map"
d="$(img_map ioperf-data queue_depth=128)"
[ "$d" = "/dev/rbd7" ] || { echo "map dev=$d"; exit 1; }
grep -q -- '-o queue_depth=128' "$FAKE_SSH_LOG" || { echo "map options missing"; exit 1; }

img_unmap /dev/rbd7
grep -q 'rbd unmap /dev/rbd7' "$FAKE_SSH_LOG" || exit 1

img_meta_set ioperf-data conf_rbd_cache false
grep -q 'rbd image-meta set ioperf/ioperf-data conf_rbd_cache false' "$FAKE_SSH_LOG" || exit 1
echo OK
