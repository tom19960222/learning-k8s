#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"

# 無旗標必須擋
if bash "$here/../run/cleanup.sh" 2>/dev/null; then echo "inject gate missing"; exit 1; fi

printf 'ioperf-data\nioperf-krbd-a\n' > "$FAKE_SSH_DIR/rbd ls"
printf 'id pool namespace image snap device\n0 ioperf - ioperf-data - /dev/rbd7\n' > "$FAKE_SSH_DIR/showmapped"
bash "$here/../run/cleanup.sh" --yes-really-inject || { echo "cleanup failed"; exit 1; }
grep -q 'qm destroy 1031' "$FAKE_SSH_LOG" || { echo "no vm destroy"; exit 1; }
grep -q 'rbd unmap /dev/rbd7' "$FAKE_SSH_LOG" || { echo "no unmap"; exit 1; }
grep -q 'rbd rm ioperf/ioperf-data' "$FAKE_SSH_LOG" || { echo "no img rm"; exit 1; }
grep -q 'pvesm remove ioperf-krbd' "$FAKE_SSH_LOG" || { echo "no storage remove"; exit 1; }
echo OK
