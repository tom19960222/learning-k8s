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
  local path=$1 trace_file=$2 pager_leak_json=${3:-}
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
if [[ "\$*" == *"get pod -l app=prometheus -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'prometheus-0\n'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=%28time%28%29%20-%20timestamp%28ceph_health_status%29%29%20%3C%2030"* ]]; then
  # Realistic fixture: a PromQL comparison without the bool modifier is a
  # filter that keeps the LHS value, so a matching series carries the AGE in
  # seconds (here "2"), never "1". A probe comparing the value against "1"
  # must fail here.
  printf '%s\n' '{"status":"success","data":{"result":[{"metric":{},"value":[1700000000,"2"]}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephMgrNoStandby"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"watchdog","alertname":"Watchdog","labels":{}}'
  if grep -q 'systemctl stop ceph-.*@mgr\.' "$trace_file"; then
    printf '%s\n' '{"receiver":"slack","alertname":"CephMgrNoStandby","labels":{"fresh":"true"}}'
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
  local path=$1 trace_file=$2 mgr_dump_empty_calls=${3:-0}
  local counter_file="${trace_file}.mgr-dump-calls"
  printf '0\n' >"$counter_file"
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
  *"ceph mgr dump --format json"*)
    # Real-lab fixture: the demoted mgr can take several polling cycles to
    # re-register as a standby after \`ceph mgr fail\`. Return an empty
    # standbys list for the first \$mgr_dump_empty_calls calls, then a
    # populated one, so tests can exercise discover_standby_mgr's poll loop.
    call_count="\$(cat "$counter_file")"
    call_count=\$((call_count + 1))
    printf '%s\n' "\$call_count" >"$counter_file"
    if [[ "\$call_count" -le $mgr_dump_empty_calls ]]; then
      printf '%s\n' '{"active_name":"a","standbys":[]}'
    else
      printf '%s\n' '{"active_name":"a","standbys":[{"name":"ceph-lab-mon-02.wmkpax"}]}'
    fi
    exit 0
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_OK\n'
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
  *"ceph osd tree"*|*"ceph mgr fail"*|*"systemctl stop ceph-"*|*"systemctl start ceph-"*)
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
pager_leak_stdout_file="$(mktemp)"
pager_leak_stderr_file="$(mktemp)"
pager_leak_trace_file="$(mktemp)"
pager_leak_bin_dir="$(mktemp -d)"
standby_poll_stdout_file="$(mktemp)"
standby_poll_stderr_file="$(mktemp)"
standby_poll_trace_file="$(mktemp)"
standby_poll_bin_dir="$(mktemp -d)"
standby_timeout_stdout_file="$(mktemp)"
standby_timeout_stderr_file="$(mktemp)"
standby_timeout_trace_file="$(mktemp)"
standby_timeout_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" "$live_stdout_file" "$live_stderr_file" "$live_trace_file" "$pager_leak_stdout_file" "$pager_leak_stderr_file" "$pager_leak_trace_file" \
    "$standby_poll_stdout_file" "$standby_poll_stderr_file" "$standby_poll_trace_file" "$standby_poll_trace_file.mgr-dump-calls" \
    "$standby_timeout_stdout_file" "$standby_timeout_stderr_file" "$standby_timeout_trace_file" "$standby_timeout_trace_file.mgr-dump-calls" \
    "$live_trace_file.mgr-dump-calls" "$pager_leak_trace_file.mgr-dump-calls"
  rm -rf "$fake_bin_dir" "$pager_leak_bin_dir" "$standby_poll_bin_dir" "$standby_timeout_bin_dir"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'mgr-failover-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-mgr-failover.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'mgr-failover-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-mgr-failover should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'mgr-failover requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
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
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-mgr-failover.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/mgr-failover-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph mgr fail$' "$live_trace_file" || fail "missing ceph mgr fail injection"
grep -q '^ssh:sudo -n cephadm shell -- ceph mgr dump --format json$' "$live_trace_file" || fail "missing standby mgr discovery"
grep -q '^ssh:sudo systemctl stop ceph-.*@mgr\.ceph-lab-mon-02\.wmkpax\.service$' "$live_trace_file" || fail "missing stop for standby mgr"
grep -q '^ssh:sudo systemctl start ceph-.*@mgr\.ceph-lab-mon-02\.wmkpax\.service$' "$live_trace_file" || fail "missing rollback start for standby mgr"

fail_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph mgr fail$' "$live_trace_file" | head -1 | cut -d: -f1)"
dump_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph mgr dump --format json$' "$live_trace_file" | head -1 | cut -d: -f1)"
stop_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@mgr\.ceph-lab-mon-02\.wmkpax\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
start_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@mgr\.ceph-lab-mon-02\.wmkpax\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$fail_line" && -n "$dump_line" && -n "$stop_line" && -n "$start_line" ]] || fail "missing trace lines for ordering checks"
(( dump_line > fail_line )) || fail "standby discovery happened before mgr fail"
(( stop_line > dump_line )) || fail "standby stop happened before discovery"
(( start_line > stop_line )) || fail "rollback start happened before stop"

# assert_prometheus_alert_not_firing always writes prometheus-alerts-<alertname>-<label_name|none>.json
# via prometheus_alert_is_firing, regardless of the firing outcome. Assert the file exists to prove
# the phase (a) not-firing check for CephMetricsAbsent actually ran (a vacuous/never-called assertion
# would also pass the "not firing" check but would leave no evidence file behind).
result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'mgr-failover-*' | sort | tail -1)"
[[ -f "$result_dir/prometheus-alerts-CephMetricsAbsent-none.json" ]] || fail "missing negative-assertion evidence file for CephMetricsAbsent"
[[ -f "$result_dir/mgr-failover-continuity.json" ]] || fail "missing continuity probe evidence file"

# assert_sink_absent always writes sink-absent-check.log before the pass/fail branch, regardless of
# outcome. Assert it exists to prove the phase (b) pager-absence check for CephMgrNoStandby actually ran.
[[ -f "$result_dir/sink-absent-check.log" ]] || fail "missing negative-assertion evidence file for sink pager absence"

ok "mgr-failover destructive ack guard, two-phase injection sequence, and rollback ordering"

# --- Failure path: alert-sink also delivers CephMgrNoStandby via the pager receiver.
# This proves assert_sink_absent's pass/fail branches are both reachable (not vacuously
# true): a leaked pager alert must make scenario_verify fail, which must still let
# scenario_main's EXIT trap run scenario_rollback (restarting the standby mgr).
make_fake_jq "$pager_leak_bin_dir/jq" "$real_jq" "$pager_leak_trace_file"
make_fake_kubectl "$pager_leak_bin_dir/kubectl" "$pager_leak_trace_file" '{"receiver":"pager","alertname":"CephMgrNoStandby","labels":{"fresh":"true"}}'
make_fake_curl "$pager_leak_bin_dir/curl" "$pager_leak_trace_file"
make_fake_ssh "$pager_leak_bin_dir/ssh" "$pager_leak_trace_file"

set +e
PATH="$pager_leak_bin_dir:$PATH" bash "$ROOT/run/scenario-mgr-failover.sh" --yes-really-inject >"$pager_leak_stdout_file" 2>"$pager_leak_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when pager sink leaks CephMgrNoStandby"
grep -q 'FAIL: sink pager unexpectedly received CephMgrNoStandby' "$pager_leak_stderr_file" || fail "missing assert_sink_absent failure log for leaked pager alert"
grep -q '^ssh:sudo systemctl start ceph-.*@mgr\.ceph-lab-mon-02\.wmkpax\.service$' "$pager_leak_trace_file" || fail "rollback start missing for standby mgr after pager-leak failure"

ok "mgr-failover assert_sink_absent fails and still rolls back when pager leaks CephMgrNoStandby"

# --- Real-lab race: after `ceph mgr fail`, the demoted mgr takes seconds to
# tens of seconds to re-register as a standby. discover_standby_mgr must poll
# `ceph mgr dump` instead of querying once -- assert the scenario survives
# two transient empty-standbys responses before a third, populated one.
make_fake_jq "$standby_poll_bin_dir/jq" "$real_jq" "$standby_poll_trace_file"
make_fake_kubectl "$standby_poll_bin_dir/kubectl" "$standby_poll_trace_file"
make_fake_curl "$standby_poll_bin_dir/curl" "$standby_poll_trace_file"
make_fake_ssh "$standby_poll_bin_dir/ssh" "$standby_poll_trace_file" 2

set +e
PATH="$standby_poll_bin_dir:$PATH" MGR_STANDBY_ATTEMPTS=5 MGR_STANDBY_SLEEP=0 \
  bash "$ROOT/run/scenario-mgr-failover.sh" --yes-really-inject >"$standby_poll_stdout_file" 2>"$standby_poll_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success once standby mgr re-registers after transient emptiness, got $rc"
mgr_dump_calls="$(grep -c '^ssh:sudo -n cephadm shell -- ceph mgr dump --format json$' "$standby_poll_trace_file")"
[[ "$mgr_dump_calls" -ge 3 ]] || fail "expected discover_standby_mgr to poll ceph mgr dump at least 3 times, got $mgr_dump_calls"

standby_poll_result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'mgr-failover-*' | sort | tail -1)"
jq -e '.standbys | length > 0' "$standby_poll_result_dir/mgr-dump-after-fail.json" >/dev/null \
  || fail "expected final mgr-dump-after-fail.json evidence to show a populated standby"

ok "mgr-failover survives transient empty ceph mgr dump standbys after mgr fail"

# --- Failure path: the standby mgr never re-registers within the poll
# budget. The script must `die` with the documented message instead of
# treating the empty-standbys jq result as a missing standby immediately.
make_fake_jq "$standby_timeout_bin_dir/jq" "$real_jq" "$standby_timeout_trace_file"
make_fake_kubectl "$standby_timeout_bin_dir/kubectl" "$standby_timeout_trace_file"
make_fake_curl "$standby_timeout_bin_dir/curl" "$standby_timeout_trace_file"
make_fake_ssh "$standby_timeout_bin_dir/ssh" "$standby_timeout_trace_file" 99

set +e
PATH="$standby_timeout_bin_dir:$PATH" MGR_STANDBY_ATTEMPTS=3 MGR_STANDBY_SLEEP=0 \
  bash "$ROOT/run/scenario-mgr-failover.sh" --yes-really-inject >"$standby_timeout_stdout_file" 2>"$standby_timeout_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected failure when standby mgr never re-registers within the poll budget"
grep -q 'FATAL: no standby mgr found after ceph mgr fail' "$standby_timeout_stderr_file" || fail "missing die message for standby poll timeout"

ok "mgr-failover dies with the documented message when standby mgr poll times out"
