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
. "$here/../lib/scenarios.sh"

# fake 回覆：ceph -s 乾淨、guest fio 回 fixture JSON
cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"
cp "$here/fixtures/fio-sample-a1.json" "$FAKE_SSH_DIR/fio --name=rr-4k-qd1"

b="$(new_bundle unit)"
write_prediction "$b" "rr-4k-qd1 IOPS 預期不變"
[ -f "$b/prediction.txt" ] || { echo "prediction missing"; exit 1; }

run_pattern_once "$b" r1 192.168.18.77 /dev/vdb "rr-4k-qd1:randread:4k:1" || { echo "pattern run failed"; exit 1; }
[ -s "$b/r1/rr-4k-qd1.json" ] || { echo "fio json missing"; ls -R "$b"; exit 1; }
[ -s "$b/r1/ceph-pre.txt" ] || { echo "ceph pre missing"; exit 1; }

# tainted 路徑：recovery 版 ceph -s → 檔案標記 .tainted 且 return 1
cp "$here/fixtures/ceph-s-recovery.txt" "$FAKE_SSH_DIR/ceph -s"
if run_pattern_once "$b" r2 192.168.18.77 /dev/vdb "rr-4k-qd1:randread:4k:1" 2>/dev/null; then
  echo "tainted not detected"; exit 1
fi
[ -e "$b/r2/rr-4k-qd1.json.tainted" ] || { echo "tainted marker missing"; exit 1; }

# emit_verdict 產出檔案
v="$(emit_verdict "$b" rr-4k-qd1 iops none 0.02 \
     "$here/fixtures/fio-sample-a1.json,$here/fixtures/fio-sample-a2.json" \
     "$here/fixtures/fio-sample-a1.json,$here/fixtures/fio-sample-a2.json")"
echo "$v" | grep -q '"verdict": "confirmed"' || { echo "verdict=$v"; exit 1; }
[ -s "$b/verdict-rr-4k-qd1.json" ] || { echo "verdict file missing"; exit 1; }
echo OK
