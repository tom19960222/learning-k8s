#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

make_fake_jq() {
  local path=$1 real_jq=$2 trace_file=$3
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf 'jq\n' >>"$trace_file"
exec "$real_jq" "\$@"
EOF
  chmod +x "$path"
}

make_fake_kubectl() {
  local path=$1 trace_file=$2
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
if [[ "\$*" == *"get pod -l app=prometheus -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'prometheus-0\n'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephClientBlocked","name":"SLOW_OPS"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up{job=\"ceph\"}"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","name":"SLOW_OPS","labels":{"name":"SLOW_OPS"}}'
  if grep -q 'rbps=65536' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","name":"SLOW_OPS","labels":{"name":"SLOW_OPS","fresh":"true"}}'
  fi
  exit 0
fi
if [[ "\$*" == *"-n rook-ceph-external get cephcluster -o wide"* ]]; then
  printf '%s\n' 'rook-ceph-external Connected HEALTH_OK'
  exit 0
fi
printf 'kubectl-noise-for-%s\n' "\$*" >&1
EOF
  chmod +x "$path"
}

make_fake_curl() {
  local path=$1 trace_file=$2
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf 'curl:%s\n' "\$*" >>"$trace_file"
printf '# fake metrics\nceph_health_status 1\n'
EOF
  chmod +x "$path"
}

make_fake_ssh() {
  local path=$1 trace_file=$2
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
command=''
seen_host=0
for arg in "\$@"; do
  if [[ "\$seen_host" -eq 0 ]]; then
    case "\$arg" in
      *@*)
        seen_host=1
        ;;
    esac
    continue
  fi
  if [[ -n "\$command" ]]; then
    command="\$command \$arg"
  else
    command="\$arg"
  fi
done
printf 'ssh:%s\n' "\$command" >>"$trace_file"
case "\$command" in
  "stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs")
    exit 0
    ;;
  "lsblk -no MAJ:MIN /dev/sdc | head -1")
    printf '8:32\n'
    exit 0
    ;;
  *"ceph osd map alert-slow-ops sentinel --format json"*)
    printf '{"acting":[4,0,1]}\n'
    exit 0
    ;;
  *"ceph osd find 4 --format json"*)
    printf '{"crush_location":{"host":"ceph-lab-osd-02"}}\n'
    exit 0
    ;;
  "sudo ceph-volume lvm list --format json")
    printf '{"4":[{"devices":["/dev/sdc"]}]}\n'
    exit 0
    ;;
  *"printf '%s\\n' \"/sys/fs/cgroup"*)
    printf '/sys/fs/cgroup/system.slice/fake/io.max\n'
    exit 0
    ;;
  *"ceph -s"*)
    count_file="\${FAKE_CEPH_S_COUNT_FILE:-}"
    if [[ -n "\$count_file" ]]; then
      count=0
      [[ -f "\$count_file" ]] && count="\$(cat "\$count_file")"
      count=\$((count + 1))
      printf '%s' "\$count" >"\$count_file"
      if [[ "\${FAKE_RECOVERY_FAIL:-0}" == "1" && "\$count" -ge 3 ]]; then
        printf 'HEALTH_ERR recovery failed\n'
        exit 0
      fi
    fi
    printf 'HEALTH_OK\n'
    exit 0
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_WARN 1 slow ops, oldest one blocked for 99 sec (SLOW_OPS)\n'
    exit 0
    ;;
  *"quorum_status --format json"*)
    printf '{"quorum":[0,1,2]}\n'
    exit 0
    ;;
  *"rados bench -p "*)
    printf 'bench-live-noise\n'
    exit 0
    ;;
  *"sudo tee "*)
    printf 'tee-live-noise\n'
    exit 0
    ;;
  *"ceph osd pool create "*|*"ceph osd pool set "*|*"rados -p "*|*"ceph osd tree"*|*"ceph osd pool delete "*)
    printf 'ssh-live-noise\n'
    exit 0
    ;;
esac
printf 'unexpected ssh command: %s\n' "\$command" >&2
exit 1
EOF
  chmod +x "$path"
}

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
no_ack_trace_file="$(mktemp)"
live_stdout_file="$(mktemp)"
live_stderr_file="$(mktemp)"
live_trace_file="$(mktemp)"
fake_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$live_stdout_file" "$live_stderr_file" "$live_trace_file"
  rm -rf "$fake_bin_dir"
}

trap cleanup EXIT

make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$no_ack_trace_file"
cat >"$fake_bin_dir/ssh" <<EOF
#!/usr/bin/env bash
printf 'ssh:%s\n' "\$*" >>"$no_ack_trace_file"
exit 99
EOF
chmod +x "$fake_bin_dir/ssh"
cat >"$fake_bin_dir/kubectl" <<EOF
#!/usr/bin/env bash
printf 'kubectl:%s\n' "\$*" >>"$no_ack_trace_file"
exit 99
EOF
chmod +x "$fake_bin_dir/kubectl"
cat >"$fake_bin_dir/curl" <<EOF
#!/usr/bin/env bash
printf 'curl:%s\n' "\$*" >>"$no_ack_trace_file"
exit 99
EOF
chmod +x "$fake_bin_dir/curl"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-slow-ops.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-slow-ops should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'slow-ops requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
[[ ! -s "$no_ack_trace_file" ]] || fail "live-capable commands ran before destructive ack"

rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-slow-ops.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/slow-ops-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|tee-live-noise|bench-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi
cleanup_count="$(grep -c '^ssh:sudo -n cephadm shell -- .*cleanup --prefix benchmark_data' "$live_trace_file" || true)"
[[ "$cleanup_count" -eq 1 ]] || fail "expected one cleanup invocation, got $cleanup_count"
delete_count="$(grep -c '^ssh:sudo -n cephadm shell -- ceph osd pool delete alert-slow-ops alert-slow-ops --yes-i-really-really-mean-it' "$live_trace_file" || true)"
[[ "$delete_count" -eq 1 ]] || fail "expected one delete invocation, got $delete_count"
if grep -q '^ssh:sudo -n cephadm shell -- .*cleanup --prefix benchmark_data.*ceph osd pool delete' "$live_trace_file"; then
  fail "cleanup and delete commands were combined into one cephadm shell invocation"
fi
grep -q '^ssh:sudo -n cephadm shell -- ceph osd map alert-slow-ops sentinel --format json$' "$live_trace_file" || fail "missing dynamic osd map"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd find 4 --format json$' "$live_trace_file" || fail "missing selected osd find"
grep -q '^ssh:sudo ceph-volume lvm list --format json$' "$live_trace_file" || fail "missing ceph-volume device discovery"
grep -q '^ssh:lsblk -no MAJ:MIN /dev/sdc | head -1$' "$live_trace_file" || fail "missing selected device maj:min lookup"
if grep -q '/dev/sdb' "$live_trace_file"; then
  fail "slow-ops used hard-coded /dev/sdb"
fi
grep -q 'osd_id=4' "$ROOT/results/$(basename "$(sed -n 's/^result: //p' "$live_stdout_file")")/selected-target.env" || fail "selected target did not record osd.4"

recovery_fail_stdout_file="$(mktemp)"
recovery_fail_stderr_file="$(mktemp)"
recovery_fail_trace_file="$(mktemp)"
recovery_fail_count_file="$(mktemp)"
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$recovery_fail_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$recovery_fail_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$recovery_fail_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$recovery_fail_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" \
  FAKE_RECOVERY_FAIL=1 \
  FAKE_CEPH_S_COUNT_FILE="$recovery_fail_count_file" \
  LAB_RECOVERY_ATTEMPTS=1 \
  LAB_RECOVERY_SLEEP=0 \
  bash "$ROOT/run/scenario-slow-ops.sh" --yes-really-inject >"$recovery_fail_stdout_file" 2>"$recovery_fail_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected recovery failure to exit nonzero"
if grep -q '^result:' "$recovery_fail_stdout_file"; then
  fail "recovery failure printed misleading result line"
fi
grep -q 'TIMEOUT: Ceph/Rook/Prometheus recovered' "$recovery_fail_stderr_file" || fail "missing recovery failure timeout evidence"

ok "slow-ops destructive ack guard"
