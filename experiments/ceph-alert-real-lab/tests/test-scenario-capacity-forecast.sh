#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/run/scenario-capacity-forecast.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

# --- Static checks: the fast test paths below override
# FORECAST_STREAM_SECONDS / PROMETHEUS_WAIT_ATTEMPTS via env vars for
# speed, so they can't observe the actual real-lab-informed production
# defaults -- pin those defaults directly against the script source
# instead. FIX ROUND 4 (real-lab): a dedicated 10-minute throughput PROBE
# proved ONE continuous `rados bench` per stream (no round loop) x 3
# parallel streams sustains 6.9 MB/s RAW growth at the pool's DEFAULT
# replication (size=3/min_size=2, 32 PGs). Five real-lab runs of the
# PREVIOUS round-loop design (many short rounds per stream, each
# restarting rados bench with a fresh --run-name) never sustained >2 MB/s --
# the restart churn itself was the regression versus the proven probe.
# FORECAST_MAX_ROUNDS / FORECAST_ROUND_SECONDS must not reappear: their
# reintroduction would mean a regression back to the round-loop design.
grep -Eq 'FORECAST_BENCH_THREADS="\$\{FORECAST_BENCH_THREADS:-64\}"' "$SCRIPT" || fail "missing FORECAST_BENCH_THREADS default of 64 (per-stream concurrency)"
grep -Eq 'FORECAST_STREAM_SECONDS="\$\{FORECAST_STREAM_SECONDS:-4500\}"' "$SCRIPT" || fail "missing FORECAST_STREAM_SECONDS default of 4500 (single continuous invocation per stream)"
grep -Eq 'PROMETHEUS_WAIT_ATTEMPTS="\$\{PROMETHEUS_WAIT_ATTEMPTS:-900\}"' "$SCRIPT" || fail "missing PROMETHEUS_WAIT_ATTEMPTS default of 900"

default_stream_seconds="$(grep -Eo 'FORECAST_STREAM_SECONDS:-[0-9]+' "$SCRIPT" | grep -Eo '[0-9]+' || true)"
[[ -n "$default_stream_seconds" ]] || fail "could not extract FORECAST_STREAM_SECONDS default from script"
[[ "$default_stream_seconds" -ge 3600 ]] || fail "FORECAST_STREAM_SECONDS default ($default_stream_seconds) must be >= 3600s to comfortably span the alert's for:30m plus fill time"

# Match actual shell assignments/expansions of the retired round-loop env
# vars (not their historical mentions in the physics comment above, which
# intentionally document the regression that was fixed).
# shellcheck disable=SC2016 # single-quoted grep -E regex, not a shell expansion
if grep -Eq '(FORECAST_MAX_ROUNDS|FORECAST_ROUND_SECONDS)="\$\{|\$FORECAST_(MAX_ROUNDS|ROUND_SECONDS)\b|\$\{FORECAST_(MAX_ROUNDS|ROUND_SECONDS)\}' "$SCRIPT"; then
  fail "round-loop env vars (FORECAST_MAX_ROUNDS/FORECAST_ROUND_SECONDS) must not be assigned or expanded -- regression to round-based restarts"
fi
if grep -Eq 'round=\$\(\(round' "$SCRIPT"; then
  fail "round counter increment must not reappear -- regression to round-based restarts"
fi
ok "capacity-forecast throughput defaults (64-thread-per-stream, single continuous FORECAST_STREAM_SECONDS>=3600 invocation, 75m wait budget, no round-loop vars)"

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
# least $1 stream invocations (summed across all 3 parallel streams) have
# been observed in the trace file -- this is what proves scenario_verify's
# poll genuinely waits on (and outlasts) scenario_inject launching every
# parallel stream, not just the first one.
make_fake_kubectl() {
  local path=$1 trace_file=$2 min_starts=$3 pager_leak_json=${4:-}
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
if [[ "\$*" == *"get pod -l app=prometheus -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'prometheus-0\n'
  exit 0
fi
starts=\$(grep -Ec '^ssh:sudo -n cephadm shell -- rados bench -p alert-forecast ' "$trace_file" || true)
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  if [[ "\$starts" -ge $min_starts ]]; then
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
  if [[ "\$starts" -ge $min_starts ]]; then
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
    if grep -q 'bluestore_slow_ops_warn_lifetime 1\$' "$trace_file"; then
      printf 'HEALTH_OK\n'
    else
      printf 'HEALTH_WARN BLUESTORE_SLOW_OP_ALERT 1 OSD(s) experiencing slow operations\n'
    fi
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
  *"ceph osd pool create "*|*"ceph osd pool set "*|*"rados -p "*|*"ceph osd tree"*|*"ceph osd pool delete "*|*"ceph config set osd bluestore_slow_ops_warn_"*|*"ceph config rm osd bluestore_slow_ops_warn_"*|*"pkill -f "*)
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

# --- Success path: EACH of the 3 parallel streams must run exactly ONE
# continuous `rados bench` invocation under its own distinct --run-name
# (stream1/stream2/stream3, no round suffix) -- proving the streams
# actually run independently in parallel with no round-loop restarts -- and
# scenario_verify's poll must genuinely wait for all 3 streams to have
# started before CephCapacityForecast is considered firing.
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file" 3
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" FORECAST_STREAM_SECONDS=0 \
  PROMETHEUS_WAIT_ATTEMPTS=50 PROMETHEUS_WAIT_SLEEP=0.05 SINK_WAIT_ATTEMPTS=50 SINK_WAIT_SLEEP=0.05 \
  BLUESTORE_CLEAR_DRAIN_SECONDS=0 \
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

for stream_n in 1 2 3; do
  stream_invocation_count="$(grep -Ec "^ssh:sudo -n cephadm shell -- rados bench -p alert-forecast 0 write -b 4194304 -t 64 --run-name stream${stream_n} --no-cleanup\$" "$live_trace_file" || true)"
  [[ "$stream_invocation_count" -eq 1 ]] || fail "expected exactly ONE continuous rados bench invocation for stream$stream_n at -t 64 concurrency, got $stream_invocation_count"
done
total_invocation_count="$(grep -Ec '^ssh:sudo -n cephadm shell -- rados bench -p alert-forecast 0 write -b 4194304 -t 64 --run-name stream[123] --no-cleanup$' "$live_trace_file" || true)"
[[ "$total_invocation_count" -eq 3 ]] || fail "expected 3 total bench invocations (one per stream, no rounds), got $total_invocation_count"
# Regression guard: a round loop would produce round-suffixed run-names
# (stream1-r1, stream1-r2, ...) instead of one bare stream$i run-name.
if grep -Eq -- '--run-name stream[123]-r[0-9]+' "$live_trace_file"; then
  fail "found round-suffixed --run-name (regression to round-loop restarts)"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool create alert-forecast 32$' "$live_trace_file" || fail "missing 32-PG pool create"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool set alert-forecast size 3$' "$live_trace_file" || fail "missing pool size=3 set"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool set alert-forecast min_size 2$' "$live_trace_file" || fail "missing pool min_size=2 set"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'capacity-forecast-*' | sort | tail -1)"
for stream_n in 1 2 3; do
  [[ -f "$result_dir/forecast-bench-stream${stream_n}.txt" ]] || fail "missing forecast bench stream evidence file for stream$stream_n"
  grep -q '# exit_code: 0' "$result_dir/forecast-bench-stream${stream_n}.txt" || fail "stream$stream_n evidence file missing success exit marker"
  [[ -f "$result_dir/forecast-bench-stream${stream_n}.pid" ]] || fail "missing forecast-bench-stream${stream_n}.pid evidence file"
done

# assert_sink_absent always writes sink-absent-check.log before its pass/fail
# branch, regardless of outcome -- assert it exists to prove the
# pager-absence check for CephCapacityForecast actually ran (a vacuous check
# would also "pass" but leave no evidence file behind).
[[ -f "$result_dir/sink-absent-check.log" ]] || fail "missing negative-assertion evidence file for sink pager absence"

pool_create_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd pool create alert-forecast 32$' "$live_trace_file" | head -1 | cut -d: -f1)"
last_bench_line="$(grep -nE '^ssh:sudo -n cephadm shell -- rados bench -p alert-forecast 0 write -b 4194304 -t 64 --run-name stream[123] --no-cleanup$' "$live_trace_file" | tail -1 | cut -d: -f1)"
pkill_line="$(grep -n '^ssh:sudo -n cephadm shell -- sh -c '"'"'pkill -f "\[r\]ados bench -p alert-forecast" || true'"'"'$' "$live_trace_file" | head -1 | cut -d: -f1)"
bluestore_clear_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph config rm osd bluestore_slow_ops_warn_threshold$' "$live_trace_file" | head -1 | cut -d: -f1)"
pool_delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- sh -c '"'"'ceph config set mon mon_allow_pool_delete true' "$live_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$pool_create_line" && -n "$last_bench_line" && -n "$pkill_line" && -n "$bluestore_clear_line" && -n "$pool_delete_line" ]] || fail "missing trace lines for ordering checks"
(( last_bench_line > pool_create_line )) || fail "bench streams ran before pool creation"
(( pkill_line > last_bench_line )) || fail "remote pkill did not run after every stream's bench invocation"
(( bluestore_clear_line > pkill_line )) || fail "BlueStore slow-ops clear did not run after remote pkill"
(( pool_delete_line > bluestore_clear_line )) || fail "pool delete happened before clear_bluestore_slow_ops completed"

# clear_bluestore_slow_ops must have actually run its remediation (not just
# been a no-op): the fake ssh's health-detail gating above latches
# BLUESTORE_SLOW_OP_ALERT until the warn_lifetime/warn_threshold config set
# pair runs, so rollback must age it out via that config set/rm pair before
# pool cleanup.
grep -q '^ssh:sudo -n cephadm shell -- ceph config set osd bluestore_slow_ops_warn_lifetime 1$' "$live_trace_file" || fail "rollback did not call clear_bluestore_slow_ops (missing warn_lifetime set)"
grep -q '^ssh:sudo -n cephadm shell -- ceph config set osd bluestore_slow_ops_warn_threshold 1$' "$live_trace_file" || fail "rollback did not call clear_bluestore_slow_ops (missing warn_threshold set)"
grep -q '^ssh:sudo -n cephadm shell -- ceph config rm osd bluestore_slow_ops_warn_lifetime$' "$live_trace_file" || fail "rollback did not restore warn_lifetime default"
grep -q '^ssh:sudo -n cephadm shell -- ceph config rm osd bluestore_slow_ops_warn_threshold$' "$live_trace_file" || fail "rollback did not restore warn_threshold default"

ok "capacity-forecast destructive ack guard, 32-PG size=3 pool, 3-parallel-stream continuous injection with distinct run-names (no round loop), remote pkill, and BlueStore-cleanup rollback ordering"

# --- Async lifetime: the whole point of the continuous-per-stream design is
# that each stream's single rados bench keeps running independent of the
# ssh round-trip that launched it, for the FULL FORECAST_STREAM_SECONDS
# duration, and rollback must explicitly terminate whichever stream is
# still in flight for ALL THREE streams (never leaving an orphaned
# background process on any of them). Block every stream's single
# invocation open until explicitly released, confirm the scenario proceeds
# past the launch (on to alert polling) while all 3 streams are still
# running, then confirm rollback kills all 3 (each captured as exit_code
# 143).
rm -f "$bench_started_file" "$bench_block_file" "$bench_terminated_file"
make_fake_jq "$async_bin_dir/jq" "$real_jq" "$async_trace_file"
make_fake_kubectl "$async_bin_dir/kubectl" "$async_trace_file" 1
make_fake_curl "$async_bin_dir/curl" "$async_trace_file"
make_fake_ssh "$async_bin_dir/ssh" "$async_trace_file"

set +e
PATH="$async_bin_dir:$PATH" PROMETHEUS_WAIT_ATTEMPTS=20 PROMETHEUS_WAIT_SLEEP=0.05 SINK_WAIT_ATTEMPTS=20 SINK_WAIT_SLEEP=0.05 \
  BLUESTORE_CLEAR_DRAIN_SECONDS=0 \
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
[[ -f "$bench_started_file" ]] || fail "fake bench stream invocation did not start"

# make_fake_kubectl's min_starts=1 requires at least one stream's ssh trace
# line to exist before the alert fires. The fake ssh script writes that
# trace line immediately (before it blocks on FAKE_BENCH_BLOCK_FILE), so
# this becomes true almost as soon as the streams launch -- well before any
# stream itself finishes. That is exactly the case this test targets:
# verify proceeds and succeeds concurrently with all 3 streams still in
# flight. Poll for the alerts query itself, which only runs inside
# scenario_verify -- strictly after scenario_inject (launching all 3
# streams) has returned.
poll_wait=0
while [[ "$poll_wait" -lt 20 ]] && ! grep -q 'wget -qO- http://127.0.0.1:9090/api/v1/alerts' "$async_trace_file"; do
  sleep 0.2
  poll_wait=$((poll_wait + 1))
done
if ! grep -q 'wget -qO- http://127.0.0.1:9090/api/v1/alerts' "$async_trace_file"; then
  kill "$async_pid" 2>/dev/null || true
  wait "$async_pid" 2>/dev/null || true
  fail "scenario did not proceed to alert polling while streams were still running"
fi

exit_wait=0
while [[ "$exit_wait" -lt 30 ]] && kill -0 "$async_pid" 2>/dev/null; do
  sleep 0.2
  exit_wait=$((exit_wait + 1))
done
if kill -0 "$async_pid" 2>/dev/null; then
  kill "$async_pid" 2>/dev/null || true
  wait "$async_pid" 2>/dev/null || true
  fail "scenario left the async fake bench streams running"
fi
wait "$async_pid"
rc=$?
[[ "$rc" -eq 0 ]] || fail "expected async fake bench scenario success, got $rc"

async_result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'capacity-forecast-*' | sort | tail -1)"
for stream_n in 1 2 3; do
  grep -Fq '# exit_code: 143' "$async_result_dir/forecast-bench-stream${stream_n}.txt" ||
    fail "rollback did not terminate and capture the still-running continuous bench for stream$stream_n"
done

ok "capacity-forecast keeps all 3 parallel continuous bench streams alive independent of the ssh round-trip, and rollback kills every in-flight stream explicitly"

# --- Failure path: alert-sink also delivers CephCapacityForecast via the
# pager receiver. Proves assert_sink_absent's pass/fail branches are both
# reachable (not vacuously true): a leaked pager alert must make
# scenario_verify fail, which must still let scenario_main's EXIT trap run
# scenario_rollback (kill all 3 stream invocations, delete the pool).
make_fake_jq "$pager_leak_bin_dir/jq" "$real_jq" "$pager_leak_trace_file"
make_fake_kubectl "$pager_leak_bin_dir/kubectl" "$pager_leak_trace_file" 1 '{"receiver":"pager","alertname":"CephCapacityForecast","labels":{"fresh":"true"}}'
make_fake_curl "$pager_leak_bin_dir/curl" "$pager_leak_trace_file"
make_fake_ssh "$pager_leak_bin_dir/ssh" "$pager_leak_trace_file"

set +e
PATH="$pager_leak_bin_dir:$PATH" FORECAST_STREAM_SECONDS=0 \
  PROMETHEUS_WAIT_ATTEMPTS=20 PROMETHEUS_WAIT_SLEEP=0.05 SINK_WAIT_ATTEMPTS=20 SINK_WAIT_SLEEP=0.05 \
  BLUESTORE_CLEAR_DRAIN_SECONDS=0 \
  bash "$ROOT/run/scenario-capacity-forecast.sh" --yes-really-inject >"$pager_leak_stdout_file" 2>"$pager_leak_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when pager sink leaks CephCapacityForecast"
grep -q 'FAIL: sink pager unexpectedly received CephCapacityForecast' "$pager_leak_stderr_file" || fail "missing assert_sink_absent failure log for leaked pager alert"
pool_delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- sh -c '"'"'ceph config set mon mon_allow_pool_delete true' "$pager_leak_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$pool_delete_line" ]] || fail "rollback pool delete missing after pager-leak failure"

ok "capacity-forecast assert_sink_absent fails and still rolls back when pager leaks CephCapacityForecast"
