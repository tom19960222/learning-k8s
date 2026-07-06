#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"

if bash "$here/../run/krbd-check.sh" 2>/dev/null; then echo "inject gate missing"; exit 1; fi

printf '/dev/rbd9\n' > "$FAKE_SSH_DIR/rbd map"
printf 'features: layering\n' > "$FAKE_SSH_DIR/rbd info"
printf 'ioperf-krbd rbd active\n' > "$FAKE_SSH_DIR/pvesm status"
out="$(bash "$here/../run/krbd-check.sh" --yes-really-inject)"
[ "$out" = "krbd: usable" ] || { echo "out=$out"; exit 1; }
grep -q 'rbd create ioperf/ioperf-krbdchk' "$FAKE_SSH_LOG" || exit 1
grep -q 'oflag=direct' "$FAKE_SSH_LOG" || { echo "no direct write probe"; exit 1; }
grep -q 'rbd unmap /dev/rbd9' "$FAKE_SSH_LOG" || exit 1
grep -q 'rbd rm ioperf/ioperf-krbdchk' "$FAKE_SSH_LOG" || exit 1
grep -q 'pvesm add rbd ioperf-krbd --pool ioperf --content images --krbd 1' "$FAKE_SSH_LOG" || exit 1
grep -q 'pvesm remove ioperf-krbd' "$FAKE_SSH_LOG" || exit 1
echo OK
