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
. "$here/../lib/collect.sh"

# taint_check
taint_check "$here/fixtures/ceph-s-clean.txt" || { echo "clean judged tainted"; exit 1; }
if taint_check "$here/fixtures/ceph-s-recovery.txt"; then echo "recovery not tainted"; exit 1; fi

# guard_check: ERR should die (subshell validates exit)
if ( guard_check "$here/fixtures/ceph-s-health-err.txt" "$here/fixtures/ceph-s-clean.txt" ) 2>/dev/null; then
  echo "guard passed HEALTH_ERR"; exit 1
fi
( guard_check "$here/fixtures/ceph-s-clean.txt" "$here/fixtures/ceph-s-clean.txt" ) || { echo "guard false positive"; exit 1; }

# guard_check: NEW slow ops should die (baseline has none, current has it)
cur_slowops="$tmp/cur-slowops.txt"
cat > "$cur_slowops" << 'EOF'
  cluster:
    id:     abc1234
    health: HEALTH_WARN

  progress:
    14 slow ops, oldest one blocked for 32 sec
EOF
base_noslowops="$tmp/base-noslowops.txt"
cp "$here/fixtures/ceph-s-clean.txt" "$base_noslowops"
if ( guard_check "$cur_slowops" "$base_noslowops" ) 2>/dev/null; then
  echo "guard passed NEW slow ops"; exit 1
fi

# guard_check: when baseline ALSO has slow ops, guard should pass
cur_slowops2="$tmp/cur-slowops2.txt"
cat > "$cur_slowops2" << 'EOF'
  cluster:
    id:     abc1234
    health: HEALTH_WARN

  progress:
    14 slow ops, oldest one blocked for 32 sec
EOF
base_slowops="$tmp/base-slowops.txt"
cat > "$base_slowops" << 'EOF'
  cluster:
    id:     abc1234
    health: HEALTH_WARN

  progress:
    slow ops found
EOF
( guard_check "$cur_slowops2" "$base_slowops" ) || { echo "guard rejected matching slow ops"; exit 1; }

# qemu_pid via fake
# fixture filename can't contain /: use pattern fragment
rm -rf "$FAKE_SSH_DIR"; mkdir -p "$FAKE_SSH_DIR"
printf '4321\n' > "$FAKE_SSH_DIR/1031.pid"
p="$(qemu_pid 1031)"
[ "$p" = "4321" ] || { echo "qemu_pid=$p"; exit 1; }
echo OK
