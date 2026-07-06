#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"
# shellcheck disable=SC1091
. "$here/../lib/common.sh"
# shellcheck disable=SC1091
. "$here/../lib/fio.sh"
# shellcheck disable=SC1091
. "$here/../lib/collect.sh"
# shellcheck disable=SC1091
. "$here/../lib/pve.sh"
# shellcheck disable=SC1091
. "$here/../lib/scenarios.sh"

cp "$here/fixtures/qm-config-baseline.txt" "$FAKE_SSH_DIR/qm config 1031"
cp "$here/fixtures/qm-agent-ip.json" "$FAKE_SSH_DIR/network-get-interfaces"
printf 'stopped\n' > "$FAKE_SSH_DIR/qm status"
printf 'up\n' > "$FAKE_SSH_DIR/qm agent 1031 ping"
printf '9999\n' > "$FAKE_SSH_DIR/1031.pid"
printf 'qemu aio=native x\n' > "$FAKE_SSH_DIR/proc"
cp "$here/fixtures/fio-sample-a1.json" "$FAKE_SSH_DIR/fio --name="
cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"

out="$(SCEN_ROUNDS=1 run_qm_variant_scenario unitqm "pred" \
  "ioperf:vm-1031-disk-1" "ioperf:vm-1031-disk-1,aio=native,cache=none" "aio=native" 1)"
[ -d "$out" ] || { echo "bundle missing"; exit 1; }
grep -q 'qm set 1031 --virtio1 ioperf:vm-1031-disk-1,aio=native,cache=none' "$FAKE_SSH_LOG" || { echo "variant set missing"; exit 1; }
[ -s "$out/A-r1/rr-4k-qd1.json" ] || { echo "A round missing"; ls -R "$out"; exit 1; }
[ -s "$out/B-r1/rr-4k-qd1.json" ] || { echo "B round missing"; exit 1; }
# 收尾回設 baseline spec（log 最後一次 qm set 是 baseline）
tail -5 "$FAKE_SSH_LOG" | grep -q 'qm set 1031 --virtio1 ioperf:vm-1031-disk-1$' || { echo "no baseline restore"; exit 1; }

# 12 支 wrapper：語法 + inject gate
for s in "$here"/../run/scenario-*.sh; do
  bash -n "$s" || { echo "syntax: $s"; exit 1; }
  if bash "$s" 2>/dev/null; then echo "gate missing: $s"; exit 1; fi
done
echo OK
