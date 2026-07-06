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

# --- run_matrix_rounds happy path：1 round，FIO_PATTERNS 全跑，皆不 tainted ---
# 通用 fixture：檔名 "fio --name=" 是 grep -F pattern，任何 fio 呼叫都會命中。
cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"
cp "$here/fixtures/fio-sample-a1.json" "$FAKE_SSH_DIR/fio --name="
mb="$(new_bundle matrix-happy)"
run_matrix_rounds "$mb" lbl 192.168.18.77 /dev/vdb 1 ||
  { echo "run_matrix_rounds happy path failed"; exit 1; }
for entry in $FIO_PATTERNS; do
  nm="${entry%%:*}"
  [ -s "$mb/lbl-r1/$nm.json" ] || { echo "matrix missing $nm"; ls -R "$mb"; exit 1; }
done

# --- Double-taint abort：retry 證據不覆蓋第一次的 .tainted ---
cp "$here/fixtures/ceph-s-recovery.txt" "$FAKE_SSH_DIR/ceph -s"
mb2="$(new_bundle matrix-taint)"
if ( run_matrix_rounds "$mb2" lbl 192.168.18.77 /dev/vdb 1 ) 2>/dev/null; then
  echo "run_matrix_rounds should have died on double taint"; exit 1
fi
[ -e "$mb2/lbl-r1/rr-4k-qd1.json.tainted" ] || { echo "first taint evidence missing"; ls -R "$mb2"; exit 1; }
[ -e "$mb2/lbl-r1-retry/rr-4k-qd1.json.tainted" ] || { echo "retry taint evidence missing"; ls -R "$mb2"; exit 1; }
cp "$here/fixtures/ceph-s-clean.txt" "$FAKE_SSH_DIR/ceph -s"

# --- ab_rounds interleave：A/B setup+run 依序交錯，不是先跑完 A 全部回合 ---
ab_log="$tmp/ab.log"; : > "$ab_log"
a_setup() { printf 'A-setup\n' >> "$ab_log"; }
b_setup() { printf 'B-setup\n' >> "$ab_log"; }
a_run() { printf 'A-run:%s\n' "$1" >> "$ab_log"; }
b_run() { printf 'B-run:%s\n' "$1" >> "$ab_log"; }
ab_rounds "$b" 2 a_setup b_setup a_run b_run 2>/dev/null
expected_ab="A-setup
A-run:1
B-setup
B-run:1
A-setup
A-run:2
B-setup
B-run:2"
actual_ab="$(cat "$ab_log")"
[ "$actual_ab" = "$expected_ab" ] || { echo "ab_rounds order mismatch:"; echo "$actual_ab"; exit 1; }

# --- emit_verdict 失敗路徑：baseline 檔案不存在 → 非 0 結束，且不留 verdict 檔 ---
if ( emit_verdict "$b" ghost-pattern iops none 0.02 \
     "$tmp/does-not-exist.json" \
     "$here/fixtures/fio-sample-a1.json" ) 2>/dev/null; then
  echo "emit_verdict should have failed on missing baseline"; exit 1
fi
[ -e "$b/verdict-ghost-pattern.json" ] && { echo "verdict file should not exist on failure"; exit 1; }

# --- host_dev 分支：iostat-host-<name>.txt 產出 ---
cp "$here/fixtures/iostat-host.txt" "$FAKE_SSH_DIR/iostat -x"
b3="$(new_bundle hostdev)"
run_pattern_once "$b3" r1 192.168.18.77 /dev/vdb "rr-4k-qd1:randread:4k:1" /dev/rbd7 ||
  { echo "host_dev pattern run failed"; exit 1; }
[ -s "$b3/r1/iostat-host-rr-4k-qd1.txt" ] || { echo "iostat-host file missing"; ls -R "$b3"; exit 1; }

echo OK
