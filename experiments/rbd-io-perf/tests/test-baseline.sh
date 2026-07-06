#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"
export BASELINE_ROUNDS=1
export SSH_KEY="$tmp/key"; : > "$SSH_KEY"; printf 'ssh-ed25519 AAA test\n' > "$SSH_KEY.pub"

if bash "$here/../run/baseline.sh" 2>/dev/null; then echo "gate missing"; exit 1; fi

printf '/mnt/pve/cephfs/template/iso/noble-server-cloudimg-amd64.img\n' > "$FAKE_SSH_DIR/ls /mnt"
cp "$here/fixtures/qm-config-baseline.txt" "$FAKE_SSH_DIR/qm config 1031"
cp "$here/fixtures/qm-agent-ip.json" "$FAKE_SSH_DIR/network-get-interfaces"
printf 'stopped\n' > "$FAKE_SSH_DIR/qm status"
printf 'up\n' > "$FAKE_SSH_DIR/qm agent 1031 ping"
printf '9999\n' > "$FAKE_SSH_DIR/1031.pid"
printf 'qemu x y\n' > "$FAKE_SSH_DIR/proc"
cp "$here/fixtures/fio-sample-a1.json" "$FAKE_SSH_DIR/fio --name="
cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"
printf '/usr/bin/fio\n' > "$FAKE_SSH_DIR/which fio"
printf '0 1 2 3\n' > "$FAKE_SSH_DIR/sys"

out="$(bash "$here/../run/baseline.sh" --yes-really-inject)"
[ -d "$out" ] || { echo "bundle missing: $out"; exit 1; }
[ -s "$out/base-r1/rr-4k-qd1.json" ] || { echo "matrix json missing"; ls -R "$out"; exit 1; }
[ -s "$out/qm-config.txt" ] || { echo "config record missing"; exit 1; }
[ -s "$out/noise.json" ] || { echo "noise.json missing"; exit 1; }
grep -q 'qm create 1031' "$FAKE_SSH_LOG" || { echo "no vm create"; exit 1; }
echo OK
