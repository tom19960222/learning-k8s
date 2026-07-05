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

# make_fake_kubectl's CephCapacityForecast alert only starts firing once at
# least $1 rounds of the forecast bench loop have been observed in the trace
# file -- this is what proves scenario_verify's poll genuinely waits on (and
# outlasts) the looping bench, not just a single round.
make_fake_kubectl() {
  local path=$1 trace_file=$2 min_rounds=$3 pager_leak_json=${4:-}
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
if [[ "\$*" == *"get pod -l app=prometheus -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'prometheus-0\n'
  exit 0
fi
rounds=\$(grep -Ec '^ssh:sudo -n cephadm shell -- rados bench -p alert-forecast ' "$trace_file" || true)
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  if [[ "\$rounds" -ge $min_rounds ]]; then
    printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephCapacityForecast"},"state":"firing"}]}}'
  else
    printf '%s\n' '{"data":{"alerts":[]}}'
  fi
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"watchdog","alertname":"Watchdog","labels":{}}'
  if [[ "\$rounds" -ge $min_rounds ]]; then
    printf '%s\n' '{"receiver":"slack","alertname":"CephCapacityForecast","labels":{"fresh":"true"}}'
EOF
  if [[ -n "$pager_leak_json" ]]; then
    cat >>"$path" <<MIDEOF
    printf '%s\n' '$pager_leak_json'
MIDEOF
  fi
  cat >>"$path" <<EOF
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
  *"ceph -s"*)
    printf 'HEALTH_OK\n'
    exit 0
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_OK\n'
    exit 0
    ;;
  *"quorum_status --format json"*)
    printf '{"quorum":[0,1,2]}\n'
    exit 0
    ;;
  *"rados bench -p alert-forecast "*)
    if [[ -n "\${FAKE_BENCH_STARTED_FILE:-}" ]]; then
      printf 'started\n' >"\$FAKE_BENCH_STARTED_FILE"
    fi
    if [[ -n "\${FAKE_BENCH_BLOCK_FILE:-}" ]]; then
      trap 'printf terminated >"\${FAKE_BENCH_TERMINATED_FILE:-/dev/null}"; exit 143' TERM INT
      while [[ ! -f "\$FAKE_BENCH_BLOCK_FILE" ]]; do
        sleep 1
      done
    fi
    printf 'bench-live-noise\n'
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
before_dirs_file="$(mktemp)"
after_dirs_file="$(mktemp)"
live_stdout_file="$(mktemp)"
live_stderr_file="$(mktemp)"
live_trace_file="$(mktemp)"
fake_bin_dir="$(mktemp -d)"
async_stdout_file="$(mktemp)"
async_stderr_file="$(mktemp)"
async_trace_file="$(mktemp)"
bench_started_file="$(mktemp)"
bench_block_file="$(mktemp)"
bench_terminated_file="$(mktemp)"
async_bin_dir="$(mktemp -d)"
pager_leak_stdout_file="$(mktemp)"
pager_leak_stderr_file="$(mktemp)"
pager_leak_trace_file="$(mktemp)"
pager_leak_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" \
    "$live_stdout_file" "$live_stderr_file" "$live_trace_file" \
    "$async_stdout_file" "$async_stderr_file" "$async_trace_file" \
    "$bench_started_file" "$bench_block_file" "$bench_terminated_file" \
    "$pager_leak_stdout_file" "$pager_leak_stderr_file" "$pager_leak_trace_file"
  rm -rf "$fake_bin_dir" "$async_bin_dir" "$pager_leak_bin_dir"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'capacity-forecast-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-capacity-forecast.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'capacity-forecast-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-capacity-forecast should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'capacity-forecast requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
[[ ! -s "$no_ack_trace_file" ]] || fail "live-capable commands ran before destructive ack"
cmp -s "$before_dirs_file" "$after_dirs_file" || fail "result dir was created before destructive ack"

# --- Success path: the bench loop must run FORECAST_MAX_ROUNDS=3 consecutive
# rounds (proving the loop actually iterates, not just a single bench call),
# and scenario_verify's poll must genuinely wait for that looping growth
# before CephCapacityForecast is considered firing.
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file" 3
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" FORECAST_MAX_ROUNDS=3 FORECAST_ROUND_SECONDS=0 \
  PROMETHEUS_WAIT_ATTEMPTS=50 PROMETHEUS_WAIT_SLEEP=0.05 SINK_WAIT_ATTEMPTS=50 SINK_WAIT_SLEEP=0.05 \
  bash "$ROOT/run/scenario-capacity-forecast.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/capacity-forecast-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|bench-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

bench_round_count="$(grep -Ec '^ssh:sudo -n cephadm shell -- rados bench -p alert-forecast 0 write --no-cleanup$' "$live_trace_file" || true)"
[[ "$bench_round_count" -eq 3 ]] || fail "expected exactly 3 forecast bench loop rounds, got $bench_round_count"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'capacity-forecast-*' | sort | tail -1)"
[[ -f "$result_dir/forecast-bench-loop.txt" ]] || fail "missing forecast bench loop evidence file"
grep -q '# round 3 exit_code: 0' "$result_dir/forecast-bench-loop.txt" || fail "loop evidence file missing round 3 success marker"
[[ -f "$result_dir/forecast-loop.pid" ]] || fail "missing forecast-loop.pid evidence file"

# assert_sink_absent always writes sink-absent-check.log before its pass/fail
# branch, regardless of outcome -- assert it exists to prove the
# pager-absence check for CephCapacityForecast actually ran (a vacuous check
# would also "pass" but leave no evidence file behind).
[[ -f "$result_dir/sink-absent-check.log" ]] || fail "missing negative-assertion evidence file for sink pager absence"

pool_create_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd pool create alert-forecast 1$' "$live_trace_file" | head -1 | cut -d: -f1)"
last_bench_line="$(grep -n '^ssh:sudo -n cephadm shell -- rados bench -p alert-forecast 0 write --no-cleanup$' "$live_trace_file" | tail -1 | cut -d: -f1)"
pool_delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- sh -c '"'"'ceph config set mon mon_allow_pool_delete true' "$live_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$pool_create_line" && -n "$last_bench_line" && -n "$pool_delete_line" ]] || fail "missing trace lines for ordering checks"
(( last_bench_line > pool_create_line )) || fail "bench rounds ran before pool creation"
(( pool_delete_line > last_bench_line )) || fail "pool delete happened before the bench loop finished"

ok "capacity-forecast destructive ack guard, 3-round loop injection, and rollback ordering"

# --- Async lifetime: the whole point of the loop-of-rounds design is that
# each round's rados bench keeps running independent of the ssh round-trip
# that launched it, and rollback must explicitly terminate whichever round
# is currently in flight (never leaving an orphaned background process).
# Block round 1 open until explicitly released, confirm the scenario
# proceeds past the launch (on to alert polling) while round 1 is still
# running, then confirm rollback kills it (captured as exit_code 143).
rm -f "$bench_started_file" "$bench_block_file" "$bench_terminated_file"
make_fake_jq "$async_bin_dir/jq" "$real_jq" "$async_trace_file"
make_fake_kubectl "$async_bin_dir/kubectl" "$async_trace_file" 1
make_fake_curl "$async_bin_dir/curl" "$async_trace_file"
make_fake_ssh "$async_bin_dir/ssh" "$async_trace_file"

set +e
PATH="$async_bin_dir:$PATH" FORECAST_MAX_ROUNDS=45 PROMETHEUS_WAIT_ATTEMPTS=20 PROMETHEUS_WAIT_SLEEP=0.05 SINK_WAIT_ATTEMPTS=20 SINK_WAIT_SLEEP=0.05 \
  FAKE_BENCH_STARTED_FILE="$bench_started_file" \
  FAKE_BENCH_BLOCK_FILE="$bench_block_file" \
  FAKE_BENCH_TERMINATED_FILE="$bench_terminated_file" \
  bash "$ROOT/run/scenario-capacity-forecast.sh" --yes-really-inject >"$async_stdout_file" 2>"$async_stderr_file" &
async_pid=$!
set -e

started_wait=0
while [[ "$started_wait" -lt 20 && ! -f "$bench_started_file" ]]; do
  sleep 0.2
  started_wait=$((started_wait + 1))
done
[[ -f "$bench_started_file" ]] || fail "fake bench round 1 did not start"

# make_fake_kubectl's min_rounds=1 requires round 1's ssh trace line to
# exist before the alert fires. The fake ssh script writes that trace line
# immediately (before it blocks on FAKE_BENCH_BLOCK_FILE), so this becomes
# true almost as soon as the loop launches round 1 -- well before round 1
# itself finishes. That is exactly the case this test targets: verify
# proceeds and succeeds concurrently with a still-in-flight round. Poll for
# the alerts query itself, which only runs inside scenario_verify --
# strictly after scenario_inject (the loop launch) has returned.
poll_wait=0
while [[ "$poll_wait" -lt 20 ]] && ! grep -q 'wget -qO- http://127.0.0.1:9090/api/v1/alerts' "$async_trace_file"; do
  sleep 0.2
  poll_wait=$((poll_wait + 1))
done
if ! grep -q 'wget -qO- http://127.0.0.1:9090/api/v1/alerts' "$async_trace_file"; then
  kill "$async_pid" 2>/dev/null || true
  wait "$async_pid" 2>/dev/null || true
  fail "scenario did not proceed to alert polling while round 1 was still running"
fi

exit_wait=0
while [[ "$exit_wait" -lt 30 ]] && kill -0 "$async_pid" 2>/dev/null; do
  sleep 0.2
  exit_wait=$((exit_wait + 1))
done
if kill -0 "$async_pid" 2>/dev/null; then
  kill "$async_pid" 2>/dev/null || true
  wait "$async_pid" 2>/dev/null || true
  fail "scenario left the async fake bench loop running"
fi
wait "$async_pid"
rc=$?
[[ "$rc" -eq 0 ]] || fail "expected async fake bench scenario success, got $rc"

async_result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'capacity-forecast-*' | sort | tail -1)"
grep -Fq '# round 1 exit_code: 143' "$async_result_dir/forecast-bench-loop.txt" ||
  fail "rollback did not terminate and capture the still-running round-1 fake bench"

ok "capacity-forecast keeps the bench loop alive independent of the ssh round-trip, and rollback kills the in-flight round explicitly"

# --- Failure path: alert-sink also delivers CephCapacityForecast via the
# pager receiver. Proves assert_sink_absent's pass/fail branches are both
# reachable (not vacuously true): a leaked pager alert must make
# scenario_verify fail, which must still let scenario_main's EXIT trap run
# scenario_rollback (kill the loop, delete the pool).
make_fake_jq "$pager_leak_bin_dir/jq" "$real_jq" "$pager_leak_trace_file"
make_fake_kubectl "$pager_leak_bin_dir/kubectl" "$pager_leak_trace_file" 1 '{"receiver":"pager","alertname":"CephCapacityForecast","labels":{"fresh":"true"}}'
make_fake_curl "$pager_leak_bin_dir/curl" "$pager_leak_trace_file"
make_fake_ssh "$pager_leak_bin_dir/ssh" "$pager_leak_trace_file"

set +e
PATH="$pager_leak_bin_dir:$PATH" FORECAST_MAX_ROUNDS=1 FORECAST_ROUND_SECONDS=0 \
  PROMETHEUS_WAIT_ATTEMPTS=20 PROMETHEUS_WAIT_SLEEP=0.05 SINK_WAIT_ATTEMPTS=20 SINK_WAIT_SLEEP=0.05 \
  bash "$ROOT/run/scenario-capacity-forecast.sh" --yes-really-inject >"$pager_leak_stdout_file" 2>"$pager_leak_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when pager sink leaks CephCapacityForecast"
grep -q 'FAIL: sink pager unexpectedly received CephCapacityForecast' "$pager_leak_stderr_file" || fail "missing assert_sink_absent failure log for leaked pager alert"
pool_delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- sh -c '"'"'ceph config set mon mon_allow_pool_delete true' "$pager_leak_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$pool_delete_line" ]] || fail "rollback pool delete missing after pager-leak failure"

ok "capacity-forecast assert_sink_absent fails and still rolls back when pager leaks CephCapacityForecast"
