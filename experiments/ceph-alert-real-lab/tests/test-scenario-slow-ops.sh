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
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","name":"SLOW_OPS","labels":{"name":"SLOW_OPS"}}'
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
  "lsblk -no MAJ:MIN /dev/sdb | head -1")
    printf '8:16\n'
    exit 0
    ;;
  *"printf '%s\\n' \"/sys/fs/cgroup"*)
    printf '/sys/fs/cgroup/system.slice/fake/io.max\n'
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
  *"ceph osd pool create "*|*"ceph osd pool set "*|*"rados -p "*|*"ceph -s"*|*"ceph osd tree"*|*"ceph osd pool delete "*)
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

ok "slow-ops destructive ack guard"
