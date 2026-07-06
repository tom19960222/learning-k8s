#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"

cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"
printf 'pve-manager/9.0.11\n' > "$FAKE_SSH_DIR/pveversion"

out="$(bash "$here/../run/preflight.sh")"
[ -f "$out" ] || { echo "snapshot file missing: $out"; exit 1; }
grep -q '=== ceph -s ===' "$out" || { echo "section missing"; exit 1; }
grep -q 'pve-manager/9.0.11' "$out" || { echo "pveversion missing"; exit 1; }
# read-only：不得出現任何變更動詞
if grep -qE 'qm (create|set|destroy)|rbd (create|rm|map)' "$FAKE_SSH_LOG"; then
  echo "preflight not read-only"; exit 1
fi
echo OK
