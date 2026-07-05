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
  # FAKE_ALERTS_COUNT_FILE + FAKE_SLOW_OPS_ALERT_DELAY simulate the
  # CephDaemonSlowOps gauge only starting to fire after N alerts-endpoint
  # polls (real-lab evidence: it only sustains > 0 continuously well into
  # a long bench run). Only the CephDaemonSlowOps entry is delayed;
  # CephClientBlocked always fires immediately, matching the real for:1m
  # rule already validated on the real lab. Unset/0 preserves the
  # original always-both-firing behavior for every other test below.
  count_file="\${FAKE_ALERTS_COUNT_FILE:-}"
  delay="\${FAKE_SLOW_OPS_ALERT_DELAY:-0}"
  include_slow_ops=1
  if [[ -n "\$count_file" && "\$delay" -gt 0 ]]; then
    count=0
    [[ -f "\$count_file" ]] && count="\$(cat "\$count_file")"
    count=\$((count + 1))
    printf '%s' "\$count" >"\$count_file"
    if [[ "\$count" -lt "\$delay" ]]; then
      include_slow_ops=0
    fi
  fi
  if [[ "\$include_slow_ops" -eq 1 ]]; then
    printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephClientBlocked","name":"SLOW_OPS"},"state":"firing"},{"labels":{"alertname":"CephDaemonSlowOps","ceph_daemon":"osd.4"},"state":"firing"}]}}'
  else
    printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephClientBlocked","name":"SLOW_OPS"},"state":"firing"}]}}'
  fi
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","name":"SLOW_OPS","labels":{"name":"SLOW_OPS"}}'
  if grep -q 'rbps=262144' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","name":"SLOW_OPS","labels":{"name":"SLOW_OPS","fresh":"true"}}'
    printf '%s\n' '{"receiver":"slack","alertname":"CephDaemonSlowOps","labels":{"ceph_daemon":"osd.4"}}'
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
  "sudo -n ceph-volume lvm list --format json")
    if [[ "\${FAKE_CEPH_VOLUME_HOST_FAIL:-0}" == "1" ]]; then
      printf 'ceph-volume: command not found\n' >&2
      exit 127
    fi
    printf '{"4":[{"devices":["/dev/sdc"]}]}\n'
    exit 0
    ;;
  "sudo -n cephadm shell -- ceph-volume lvm list --format json")
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
  *"pkill -f \"[r]ados bench -p "*)
    printf 'pkill-live-noise\n'
    exit 0
    ;;
  *"rados bench -p "*)
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
if grep -q '^ssh:sudo -n cephadm shell -- .*cleanup --prefix benchmark_data' "$live_trace_file"; then
  fail "slow-ops cleanup should delete the temporary pool instead of running rados cleanup"
fi
delete_count="$(grep -c '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-slow-ops alert-slow-ops --yes-i-really-really-mean-it' "$live_trace_file" || true)"
[[ "$delete_count" -eq 1 ]] || fail "expected one delete invocation, got $delete_count"
pkill_count="$(grep -F -c "ssh:sudo -n cephadm shell -- sh -c 'pkill -f \"[r]ados bench -p alert-slow-ops\" || true'" "$live_trace_file" || true)"
[[ "$pkill_count" -eq 1 ]] || fail "expected one scoped rados bench pkill, got $pkill_count"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd map alert-slow-ops sentinel --format json$' "$live_trace_file" || fail "missing dynamic osd map"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd find 4 --format json$' "$live_trace_file" || fail "missing selected osd find"
grep -q '^ssh:sudo -n ceph-volume lvm list --format json$' "$live_trace_file" || fail "missing ceph-volume device discovery"
grep -q '^ssh:lsblk -no MAJ:MIN /dev/sdc | head -1$' "$live_trace_file" || fail "missing selected device maj:min lookup"
if grep -q '/dev/sdb' "$live_trace_file"; then
  fail "slow-ops used hard-coded /dev/sdb"
fi
grep -q 'osd_id=4' "$ROOT/results/$(basename "$(sed -n 's/^result: //p' "$live_stdout_file")")/selected-target.env" || fail "selected target did not record osd.4"

# prometheus_alert_is_firing writes prometheus-alerts-<alertname>-<label|none>.json
# keyed on the CALLER's requested alertname/label, not the fake endpoint's response
# body -- its existence proves the scenario itself issued a wait_prometheus_alert
# call for CephDaemonSlowOps scoped to the dynamically-selected osd.4.
result_dir="$ROOT/results/$(basename "$(sed -n 's/^result: //p' "$live_stdout_file")")"
[[ -f "$result_dir/prometheus-alerts-CephDaemonSlowOps-ceph_daemon.json" ]] || fail "missing CephDaemonSlowOps prometheus wait evidence"
grep -q 'PASS: sink slack received CephDaemonSlowOps ceph_daemon=osd.4' "$live_stderr_file" || fail "missing evidence that slack received CephDaemonSlowOps for osd.4"

# The rados bench must outlast CephDaemonSlowOps' for:3m window plus ~60s
# ramp-up under continuous load (real-lab evidence: a 180s bench let the
# per-daemon SLOW_OPS gauge drop to 0 before ever sustaining 3 continuous
# minutes, so the for: clock kept resetting). Assert >= 360s so a future
# shortening of SLOW_OPS_BENCH_SECONDS regresses this test.
bench_line="$(grep -E '^ssh:sudo -n cephadm shell -- rados bench -p alert-slow-ops [0-9]+ write -b 4194304 -t 16 --no-cleanup$' "$live_trace_file" | head -1)"
[[ -n "$bench_line" ]] || fail "missing rados bench invocation with expected command shape in trace"
bench_duration="$(printf '%s\n' "$bench_line" | grep -oE '[0-9]+' | head -1)"
[[ "$bench_duration" -ge 360 ]] || fail "expected slow-ops bench duration >= 360s to outlast CephDaemonSlowOps for:3m + ramp-up, got ${bench_duration}s"

cephadm_fallback_stdout_file="$(mktemp)"
cephadm_fallback_stderr_file="$(mktemp)"
cephadm_fallback_trace_file="$(mktemp)"
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$cephadm_fallback_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$cephadm_fallback_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$cephadm_fallback_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$cephadm_fallback_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" \
  FAKE_CEPH_VOLUME_HOST_FAIL=1 \
  bash "$ROOT/run/scenario-slow-ops.sh" --yes-really-inject >"$cephadm_fallback_stdout_file" 2>"$cephadm_fallback_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with cephadm ceph-volume fallback, got $rc"
grep -q '^ssh:sudo -n ceph-volume lvm list --format json$' "$cephadm_fallback_trace_file" || fail "missing host ceph-volume attempt before fallback"
grep -q '^ssh:sudo -n cephadm shell -- ceph-volume lvm list --format json$' "$cephadm_fallback_trace_file" || fail "missing cephadm ceph-volume fallback"
grep -q 'ceph_volume_method=cephadm' "$ROOT/results/$(basename "$(sed -n 's/^result: //p' "$cephadm_fallback_stdout_file")")/selected-target.env" || fail "selected target did not record cephadm method"

async_stdout_file="$(mktemp)"
async_stderr_file="$(mktemp)"
async_trace_file="$(mktemp)"
bench_started_file="$(mktemp)"
bench_block_file="$(mktemp)"
bench_terminated_file="$(mktemp)"
rm -f "$bench_started_file" "$bench_block_file" "$bench_terminated_file"
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$async_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$async_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$async_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$async_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" \
  FAKE_BENCH_STARTED_FILE="$bench_started_file" \
  FAKE_BENCH_BLOCK_FILE="$bench_block_file" \
  FAKE_BENCH_TERMINATED_FILE="$bench_terminated_file" \
  bash "$ROOT/run/scenario-slow-ops.sh" --yes-really-inject >"$async_stdout_file" 2>"$async_stderr_file" &
async_pid=$!
set -e

started_wait=0
while [[ "$started_wait" -lt 20 && ! -f "$bench_started_file" ]]; do
  sleep 0.2
  started_wait=$((started_wait + 1))
done
[[ -f "$bench_started_file" ]] || fail "fake bench did not start"

poll_wait=0
while [[ "$poll_wait" -lt 20 ]] && ! grep -q 'ceph health detail' "$async_trace_file"; do
  sleep 0.2
  poll_wait=$((poll_wait + 1))
done
if ! grep -q 'ceph health detail' "$async_trace_file"; then
  kill "$async_pid" 2>/dev/null || true
  wait "$async_pid" 2>/dev/null || true
  fail "scenario did not poll Ceph health while rados bench was still running"
fi

exit_wait=0
while [[ "$exit_wait" -lt 30 ]] && kill -0 "$async_pid" 2>/dev/null; do
  sleep 0.2
  exit_wait=$((exit_wait + 1))
done
if kill -0 "$async_pid" 2>/dev/null; then
  kill "$async_pid" 2>/dev/null || true
  wait "$async_pid" 2>/dev/null || true
  fail "scenario left the async fake bench running"
fi
wait "$async_pid"
rc=$?
[[ "$rc" -eq 0 ]] || fail "expected async fake bench scenario success, got $rc"
grep -Fq '# exit_code: 143' "$ROOT/results/$(basename "$(sed -n 's/^result: //p' "$async_stdout_file")")/rados-bench.txt" ||
  fail "cleanup did not terminate and capture the still-running fake bench"
grep -Eq "^ssh:printf '%s\\\\n' '8:32 rbps=max wbps=max riops=max wiops=max' \\| sudo tee '/sys/fs/cgroup/system\\.slice/fake/io\\.max' >/dev/null$" "$async_trace_file" || fail "missing unthrottle during async cleanup"

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

# CephDaemonSlowOps has for:3m, and real-lab evidence showed its
# per-daemon SLOW_OPS gauge only starts sustaining continuously well past
# the default 60*5s=300s wait budget every other alert in this lab uses.
# FAKE_SLOW_OPS_ALERT_DELAY makes the alerts endpoint withhold the
# CephDaemonSlowOps entry until its 70th poll (needs >60 attempts, still
# fits the scenario's elevated 84-attempt budget for that one wait) to
# prove scenario-slow-ops.sh actually raises the attempts budget for it.
slow_ops_delay_stdout_file="$(mktemp)"
slow_ops_delay_stderr_file="$(mktemp)"
slow_ops_delay_trace_file="$(mktemp)"
slow_ops_delay_count_file="$(mktemp)"
rm -f "$slow_ops_delay_count_file"
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$slow_ops_delay_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$slow_ops_delay_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$slow_ops_delay_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$slow_ops_delay_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" \
  FAKE_ALERTS_COUNT_FILE="$slow_ops_delay_count_file" \
  FAKE_SLOW_OPS_ALERT_DELAY=70 \
  PROMETHEUS_WAIT_SLEEP=0 \
  bash "$ROOT/run/scenario-slow-ops.sh" --yes-really-inject >"$slow_ops_delay_stdout_file" 2>"$slow_ops_delay_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected scenario to survive CephDaemonSlowOps firing only on the 70th poll (needs the elevated attempts budget), got $rc"
grep -q 'PASS: Prometheus alert CephDaemonSlowOps ceph_daemon=osd.4 firing' "$slow_ops_delay_stderr_file" || fail "missing PASS evidence for delayed CephDaemonSlowOps prometheus wait"

# Prove the budget is elevated but still bounded (not e.g. an unrelated
# infinite-ish default): the same delay pushed past the 84-attempt budget
# must time out.
slow_ops_timeout_stdout_file="$(mktemp)"
slow_ops_timeout_stderr_file="$(mktemp)"
slow_ops_timeout_trace_file="$(mktemp)"
slow_ops_timeout_count_file="$(mktemp)"
rm -f "$slow_ops_timeout_count_file"
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$slow_ops_timeout_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$slow_ops_timeout_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$slow_ops_timeout_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$slow_ops_timeout_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" \
  FAKE_ALERTS_COUNT_FILE="$slow_ops_timeout_count_file" \
  FAKE_SLOW_OPS_ALERT_DELAY=90 \
  PROMETHEUS_WAIT_SLEEP=0 \
  bash "$ROOT/run/scenario-slow-ops.sh" --yes-really-inject >"$slow_ops_timeout_stdout_file" 2>"$slow_ops_timeout_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected CephDaemonSlowOps firing on the 90th poll to exceed the 84-attempt budget and fail"
grep -q 'TIMEOUT: Prometheus alert CephDaemonSlowOps ceph_daemon=osd.4 firing' "$slow_ops_timeout_stderr_file" || fail "missing TIMEOUT evidence for CephDaemonSlowOps prometheus wait"

ok "slow-ops destructive ack guard"
