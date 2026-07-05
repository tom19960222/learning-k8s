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
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephOSDSlowHeartbeat"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"watchdog","alertname":"Watchdog","labels":{}}'
  if grep -q 'tc qdisc add dev eth0 root netem delay 1200ms' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephOSDSlowHeartbeat","labels":{"fresh":"true"}}'
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
  local path=$1 trace_file=$2 kill0_rc="${3:-0}"
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
  *"ip route get 192.168.18.166 | sed -n 's/.* dev "*)
    printf 'eth0\n'
    exit 0
    ;;
  *"nohup sh -c 'sleep 900; tc qdisc del dev eth0 root' >/dev/null 2>&1 &"*)
    printf '54321\n'
    exit 0
    ;;
  *"sudo kill -0 54321"*)
    exit $kill0_rc
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_WARN 1 osds have slow heartbeats (OSD_SLOW_PING_TIME_BACK)\n'
    exit 0
    ;;
  *"ceph -s"*)
    printf 'HEALTH_OK\n'
    exit 0
    ;;
  *"quorum_status --format json"*)
    printf '{"quorum":[0,1,2]}\n'
    exit 0
    ;;
  *"ceph osd tree"*|*"sudo tc qdisc add dev eth0 root netem delay 1200ms"*|*"sudo tc qdisc del dev eth0 root || true"*|*"sudo pkill -f 'sleep 900' || true"*)
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
before_dirs_file="$(mktemp)"
after_dirs_file="$(mktemp)"
live_stdout_file="$(mktemp)"
live_stderr_file="$(mktemp)"
live_trace_file="$(mktemp)"
fake_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" "$live_stdout_file" "$live_stderr_file" "$live_trace_file"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'net-slow-heartbeat-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-net-slow-heartbeat.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'net-slow-heartbeat-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-net-slow-heartbeat should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'net-slow-heartbeat requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
[[ ! -s "$no_ack_trace_file" ]] || fail "live-capable commands ran before destructive ack"
cmp -s "$before_dirs_file" "$after_dirs_file" || fail "result dir was created before destructive ack"

rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-net-slow-heartbeat.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/net-slow-heartbeat-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -Fq 'ip route get 192.168.18.166' "$live_trace_file" || fail "missing iface discovery via ip route get"
grep -Fq "nohup sh -c 'sleep 900; tc qdisc del dev eth0 root' >/dev/null 2>&1 &" "$live_trace_file" || fail "missing pre-armed auto-revert sleeper"
grep -Fq 'sudo kill -0 54321' "$live_trace_file" || fail "missing armed-revert liveness confirmation"
grep -Fq 'sudo tc qdisc add dev eth0 root netem delay 1200ms' "$live_trace_file" || fail "missing netem qdisc injection"
grep -Fq 'sudo tc qdisc del dev eth0 root || true' "$live_trace_file" || fail "missing rollback qdisc delete"
grep -Fq "sudo pkill -f 'sleep 900' || true" "$live_trace_file" || fail "missing rollback kill of armed sleeper"

discover_line="$(grep -Fn 'ip route get 192.168.18.166' "$live_trace_file" | head -1 | cut -d: -f1)"
arm_line="$(grep -Fn "nohup sh -c 'sleep 900; tc qdisc del dev eth0 root' >/dev/null 2>&1 &" "$live_trace_file" | head -1 | cut -d: -f1)"
liveness_line="$(grep -Fn 'sudo kill -0 54321' "$live_trace_file" | head -1 | cut -d: -f1)"
add_line="$(grep -Fn 'sudo tc qdisc add dev eth0 root netem delay 1200ms' "$live_trace_file" | head -1 | cut -d: -f1)"
del_line="$(grep -Fn 'sudo tc qdisc del dev eth0 root || true' "$live_trace_file" | head -1 | cut -d: -f1)"
pkill_line="$(grep -Fn "sudo pkill -f 'sleep 900' || true" "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$discover_line" && -n "$arm_line" && -n "$liveness_line" && -n "$add_line" && -n "$del_line" && -n "$pkill_line" ]] || fail "missing trace lines for ordering checks"
(( arm_line > discover_line )) || fail "iface discovery happened after arming the auto-revert sleeper"
(( liveness_line > arm_line )) || fail "liveness confirmation happened before (or at) arming the auto-revert sleeper"
(( add_line > liveness_line )) || fail "netem qdisc was applied before the armed sleeper's liveness was confirmed"
(( del_line > add_line )) || fail "rollback qdisc delete happened before qdisc add"
(( pkill_line > add_line )) || fail "rollback sleeper kill happened before qdisc add"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'net-slow-heartbeat-*' | sort | tail -1)"
[[ -f "$result_dir/target-iface.txt" ]] || fail "missing target-iface.txt evidence file"
[[ "$(cat "$result_dir/target-iface.txt")" == "eth0" ]] || fail "target-iface.txt content mismatch: $(cat "$result_dir/target-iface.txt" 2>/dev/null)"
[[ -f "$result_dir/armed-revert.pid" ]] || fail "missing armed-revert.pid evidence file"
[[ "$(cat "$result_dir/armed-revert.pid")" == "54321" ]] || fail "armed-revert.pid content mismatch: $(cat "$result_dir/armed-revert.pid" 2>/dev/null)"
[[ -f "$result_dir/armed-revert-liveness.txt" ]] || fail "missing armed-revert-liveness.txt evidence file"

ok "net-slow-heartbeat destructive ack guard, pre-armed auto-revert ordering, and rollback"

# --- liveness check failure: fork succeeded (non-empty PID) but the sleeper
# is not actually alive -- the scenario must die before ever applying the
# netem qdisc, with no destructive delay left unguarded.
dead_stdout_file="$(mktemp)"
dead_stderr_file="$(mktemp)"
dead_trace_file="$(mktemp)"
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$dead_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$dead_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$dead_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$dead_trace_file" 1

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-net-slow-heartbeat.sh" --yes-really-inject >"$dead_stdout_file" 2>"$dead_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when armed-revert liveness check fails"
grep -Fq 'sudo kill -0 54321' "$dead_trace_file" || fail "missing liveness check attempt in dead-sleeper run"
if grep -Fq 'sudo tc qdisc add dev eth0 root netem delay 1200ms' "$dead_trace_file"; then
  fail "netem qdisc was applied even though armed-revert liveness check failed"
fi
grep -Fq 'sudo tc qdisc del dev eth0 root || true' "$dead_trace_file" || fail "rollback qdisc delete did not run after liveness failure"
grep -Fq "sudo pkill -f 'sleep 900' || true" "$dead_trace_file" || fail "rollback sleeper kill did not run after liveness failure"

dead_result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'net-slow-heartbeat-*' | sort | tail -1)"
[[ -f "$dead_result_dir/armed-revert-liveness.txt" ]] || fail "missing armed-revert-liveness.txt evidence file on failure path"

rm -f "$dead_stdout_file" "$dead_stderr_file" "$dead_trace_file"

ok "net-slow-heartbeat dies before netem injection when armed-revert liveness check fails, rollback stays safe"
