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

# required_marker (checked at fake-kubectl runtime, not generation time) is
# 'rbps=4194304' by default (the primary throttle rate) or 'rbps=1048576'
# when FAKE_LATENCY_REQUIRE_RETRY=1 (the scenario's built-in retry rate) —
# this lets one fixture serve both the immediate-success and the
# retry-then-success test cases by gating on which throttle rate has
# actually been applied so far, exactly the discriminator scenario_verify's
# retry logic depends on.
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
required_marker='rbps=4194304'
if [[ "\${FAKE_LATENCY_REQUIRE_RETRY:-0}" == "1" ]]; then
  required_marker='rbps=1048576'
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  if grep -q "\$required_marker" "$trace_file"; then
    printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephOSDLatencyOutlier","ceph_daemon":"osd.4"},"state":"firing"}]}}'
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
  if grep -q "\$required_marker" "$trace_file"; then
    printf '%s\n' '{"receiver":"slack","alertname":"CephOSDLatencyOutlier","labels":{"ceph_daemon":"osd.4","fresh":"true"}}'
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
  "stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs")
    exit 0
    ;;
  "lsblk -no MAJ:MIN /dev/sdc | head -1")
    printf '8:32\n'
    exit 0
    ;;
  *"ceph osd map alert-latency-outlier sentinel --format json"*)
    printf '{"acting":[4,0,1]}\n'
    exit 0
    ;;
  *"ceph osd find 4 --format json"*)
    printf '{"crush_location":{"host":"ceph-lab-osd-02"}}\n'
    exit 0
    ;;
  "sudo -n ceph-volume lvm list --format json")
    printf '{"4":[{"devices":["/dev/sdc"]}]}\n'
    exit 0
    ;;
  *"printf '%s\\n' \"/sys/fs/cgroup"*)
    printf '/sys/fs/cgroup/system.slice/fake/io.max\n'
    exit 0
    ;;
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
  *"nohup rados bench -p alert-latency-outlier 300 write"*)
    printf 'started\n'
    exit 0
    ;;
  *"pkill -f \"[r]ados bench -p alert-latency-outlier\""*)
    printf 'pkill-live-noise\n'
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
before_dirs_file="$(mktemp)"
after_dirs_file="$(mktemp)"
live_stdout_file="$(mktemp)"
live_stderr_file="$(mktemp)"
live_trace_file="$(mktemp)"
fake_bin_dir="$(mktemp -d)"
retry_stdout_file="$(mktemp)"
retry_stderr_file="$(mktemp)"
retry_trace_file="$(mktemp)"
retry_bin_dir="$(mktemp -d)"
pager_leak_stdout_file="$(mktemp)"
pager_leak_stderr_file="$(mktemp)"
pager_leak_trace_file="$(mktemp)"
pager_leak_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" \
    "$live_stdout_file" "$live_stderr_file" "$live_trace_file" \
    "$retry_stdout_file" "$retry_stderr_file" "$retry_trace_file" \
    "$pager_leak_stdout_file" "$pager_leak_stderr_file" "$pager_leak_trace_file"
  rm -rf "$fake_bin_dir" "$retry_bin_dir" "$pager_leak_bin_dir"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'latency-outlier-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-latency-outlier.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'latency-outlier-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-latency-outlier should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'latency-outlier requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
[[ ! -s "$no_ack_trace_file" ]] || fail "live-capable commands ran before destructive ack"
cmp -s "$before_dirs_file" "$after_dirs_file" || fail "result dir was created before destructive ack"

# --- Success path: primary throttle (4MB/s) is enough; no retry needed.
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" PROMETHEUS_WAIT_ATTEMPTS=2 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$ROOT/run/scenario-latency-outlier.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/latency-outlier-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|tee-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph osd map alert-latency-outlier sentinel --format json$' "$live_trace_file" || fail "missing dynamic osd map"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd find 4 --format json$' "$live_trace_file" || fail "missing selected osd find"
grep -q '^ssh:sudo -n ceph-volume lvm list --format json$' "$live_trace_file" || fail "missing ceph-volume device discovery"
grep -q '^ssh:lsblk -no MAJ:MIN /dev/sdc | head -1$' "$live_trace_file" || fail "missing selected device maj:min lookup"
grep -q "rbps=4194304" "$live_trace_file" || fail "missing primary throttle at default LATENCY_BPS"
if grep -q 'rbps=1048576' "$live_trace_file"; then
  fail "immediate-success path should not have triggered the retry throttle"
fi
if grep -q 'retrying once with a tighter limit' "$live_stderr_file"; then
  fail "immediate-success path should not have logged a retry"
fi
grep -q "^ssh:sudo -n cephadm shell -- sh -c 'nohup rados bench -p alert-latency-outlier 300 write -b 4194304 -t 16 --no-cleanup >/dev/null 2>&1 & echo started'\$" "$live_trace_file" || fail "missing nohup bench launch on seed host"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'latency-outlier-*' | sort | tail -1)"
[[ -f "$result_dir/start-bench.txt" ]] || fail "missing bench-launch evidence file"
grep -q 'started' "$result_dir/start-bench.txt" || fail "bench-launch evidence file missing started confirmation"
grep -q 'osd_id=4' "$result_dir/selected-target.env" || fail "selected target did not record osd.4"

# assert_sink_absent always writes sink-absent-check.log before the pass/fail branch, regardless of
# outcome. Assert it exists to prove the pager-absence check for CephOSDLatencyOutlier actually ran
# (a vacuous/never-called assertion would also "pass" but would leave no evidence file behind).
[[ -f "$result_dir/sink-absent-check.log" ]] || fail "missing negative-assertion evidence file for sink pager absence"

unthrottle_line="$(grep -n "rbps=max" "$live_trace_file" | head -1 | cut -d: -f1)"
pkill_line="$(grep -n '^ssh:sudo -n cephadm shell -- sh -c '"'"'pkill -f "\[r\]ados bench -p alert-latency-outlier" || true'"'"'$' "$live_trace_file" | head -1 | cut -d: -f1)"
pool_delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- sh -c '"'"'ceph config set mon mon_allow_pool_delete true' "$live_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$unthrottle_line" && -n "$pkill_line" && -n "$pool_delete_line" ]] || fail "missing rollback trace lines for ordering checks"
(( pkill_line > unthrottle_line )) || fail "rollback did not unthrottle before killing rados bench"
(( pool_delete_line > pkill_line )) || fail "rollback did not kill rados bench before deleting the pool"

ok "latency-outlier destructive ack guard, injection/setup sequence, and rollback ordering"

# --- Retry path: primary throttle is (simulated as) insufficient within the first wait window;
# scenario_verify must log the retry, re-throttle tighter, and succeed on the second wait.
rm -rf "$retry_bin_dir"
retry_bin_dir="$(mktemp -d)"
make_fake_jq "$retry_bin_dir/jq" "$real_jq" "$retry_trace_file"
make_fake_kubectl "$retry_bin_dir/kubectl" "$retry_trace_file"
make_fake_curl "$retry_bin_dir/curl" "$retry_trace_file"
make_fake_ssh "$retry_bin_dir/ssh" "$retry_trace_file"

set +e
PATH="$retry_bin_dir:$PATH" FAKE_LATENCY_REQUIRE_RETRY=1 PROMETHEUS_WAIT_ATTEMPTS=1 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$ROOT/run/scenario-latency-outlier.sh" --yes-really-inject >"$retry_stdout_file" 2>"$retry_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected retry path to eventually succeed, got $rc"
grep -q 'retrying once with a tighter limit (1048576 bps)' "$retry_stderr_file" || fail "missing retry log line"
grep -q 'rbps=4194304' "$retry_trace_file" || fail "retry path missing primary throttle"
grep -q 'rbps=1048576' "$retry_trace_file" || fail "retry path missing tighter retry throttle"

primary_line="$(grep -n "rbps=4194304" "$retry_trace_file" | head -1 | cut -d: -f1)"
retry_line="$(grep -n "rbps=1048576" "$retry_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$primary_line" && -n "$retry_line" ]] || fail "missing throttle trace lines for retry ordering check"
(( retry_line > primary_line )) || fail "retry throttle happened before primary throttle"

ok "latency-outlier retries once with a tighter throttle when the first wait window times out"

# --- Failure path: alert-sink also delivers CephOSDLatencyOutlier via the pager receiver.
# This proves assert_sink_absent's pass/fail branches are both reachable (not vacuously
# true): a leaked pager alert must make scenario_verify fail, which must still let
# scenario_main's EXIT trap run scenario_rollback (unthrottle, pkill, pool delete).
make_fake_jq "$pager_leak_bin_dir/jq" "$real_jq" "$pager_leak_trace_file"
make_fake_kubectl "$pager_leak_bin_dir/kubectl" "$pager_leak_trace_file" '{"receiver":"pager","alertname":"CephOSDLatencyOutlier","labels":{"ceph_daemon":"osd.4","fresh":"true"}}'
make_fake_curl "$pager_leak_bin_dir/curl" "$pager_leak_trace_file"
make_fake_ssh "$pager_leak_bin_dir/ssh" "$pager_leak_trace_file"

set +e
PATH="$pager_leak_bin_dir:$PATH" PROMETHEUS_WAIT_ATTEMPTS=2 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$ROOT/run/scenario-latency-outlier.sh" --yes-really-inject >"$pager_leak_stdout_file" 2>"$pager_leak_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when pager sink leaks CephOSDLatencyOutlier"
grep -q 'FAIL: sink pager unexpectedly received CephOSDLatencyOutlier' "$pager_leak_stderr_file" || fail "missing assert_sink_absent failure log for leaked pager alert"
grep -q "rbps=max" "$pager_leak_trace_file" || fail "rollback unthrottle missing after pager-leak failure"
grep -q "^ssh:sudo -n cephadm shell -- sh -c 'pkill -f \"\[r\]ados bench -p alert-latency-outlier\" || true'\$" "$pager_leak_trace_file" || fail "rollback pkill missing after pager-leak failure"

ok "latency-outlier assert_sink_absent fails and still rolls back when pager leaks CephOSDLatencyOutlier"
