#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"
export EXP0_ROUNDS=1

if bash "$here/../run/exp0-host-ceiling.sh" 2>/dev/null; then echo "gate missing"; exit 1; fi

printf '/dev/rbd5\n' > "$FAKE_SSH_DIR/rbd map"
cp "$here/fixtures/fio-sample-a1.json" "$FAKE_SSH_DIR/fio --name="
cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"
out="$(bash "$here/../run/exp0-host-ceiling.sh" --yes-really-inject)"
[ -d "$out" ] || { echo "bundle missing: $out"; exit 1; }
[ -s "$out/libaio-r1/rr-4k-qd1.json" ] || { echo "libaio json missing"; ls -R "$out"; exit 1; }
[ -s "$out/io_uring-r1/rr-4k-qd1.json" ] || { echo "io_uring json missing"; exit 1; }
grep -q -- '--ioengine=io_uring' "$FAKE_SSH_LOG" || { echo "no io_uring run"; exit 1; }
grep -q 'rbd unmap /dev/rbd5' "$FAKE_SSH_LOG" || { echo "no unmap"; exit 1; }
grep -q 'rbd rm ioperf/ioperf-ceiling' "$FAKE_SSH_LOG" || { echo "no rm"; exit 1; }
echo OK
