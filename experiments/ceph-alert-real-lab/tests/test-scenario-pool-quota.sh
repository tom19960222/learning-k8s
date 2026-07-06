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

# make_fake_kubectl <path> <trace_file> <state_file> [reject_at_or_above]
# Sink log freshness is gated on the SAME bytes-used state file the ssh fake
# below maintains, so "CephPoolNearQuota fired" / "CephClientBlocked fired"
# reflect the actual accumulated pool usage at the moment each is polled,
# not a fixed script-independent fixture.
make_fake_kubectl() {
  local path=$1 trace_file=$2 state_file=$3 reject_at_or_above=${4:-999999999999}
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
if [[ "\$*" == *"get pod -l app=prometheus -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'prometheus-0\n'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephPoolNearQuota","name":"alert-quota"},"state":"firing"},{"labels":{"alertname":"CephClientBlocked","name":"POOL_FULL"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"watchdog","alertname":"Watchdog","labels":{}}'
  current=\$(cat "$state_file" 2>/dev/null || printf '0')
  if [[ "\$current" -ge 27262976 ]]; then
    printf '%s\n' '{"receiver":"slack","alertname":"CephPoolNearQuota","labels":{"name":"alert-quota","fresh":"true"}}'
  fi
  if [[ "\$current" -ge "$reject_at_or_above" ]] || [[ "\$current" -ge 33554432 ]]; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","labels":{"name":"POOL_FULL","fresh":"true"}}'
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

# make_fake_ssh <path> <trace_file> <state_file> [reject_at_or_above] [failure_mode] [pool_full_after_puts]
#
# state_file tracks alert-quota's simulated bytes_used across `rados put`
# calls. Near-quota puts (no `timeout` wrapper) always succeed and add
# exactly 4194304 bytes = 4MiB. Past-quota puts (wrapped in `timeout 30`,
# matching the scenario's bounded-put fix) succeed the same way UNTIL
# bytes_used-before-this-put is >= reject_at_or_above, at which point the put
# itself fails instead of succeeding, per failure_mode:
#   - "timeout": exit 124, no stdout -- models a put that blocked on the
#     quota and was killed by the remote `timeout` wrapper.
#   - "reject":  exit 1 with an EDQUOT-style stderr message -- models the
#     mon rejecting the put outright.
# Both are real, expected pool-full signals that write_past_quota must
# tolerate and keep looping past.
#
# `ceph health detail` reports POOL_FULL only once at least
# pool_full_after_puts PAST-QUOTA put attempts (i.e. `timeout 30 rados ...`
# commands specifically) have appeared in the trace file -- modeling the
# real-lab finding that Ceph's mon only raises the POOL_FULL health check
# once it has observed sustained write pressure against the full pool, not
# merely once `ceph df` reports bytes_used at/over the quota.
make_fake_ssh() {
  local path=$1 trace_file=$2 state_file=$3 reject_at_or_above=${4:-33554432} \
    failure_mode=${5:-timeout} pool_full_after_puts=${6:-3}
  printf '0\n' >"$state_file"
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
  *"cephadm shell --mount /tmp:/tmp -- timeout 30 rados -p alert-quota put obj-"*)
    current=\$(cat "$state_file")
    if [[ "\$current" -ge "$reject_at_or_above" ]]; then
      if [[ "$failure_mode" == "timeout" ]]; then
        printf 'put timed out waiting on quota\n' >&2
        exit 124
      fi
      printf 'error putting alert-quota/obj: (1) Operation not permitted (quota exceeded)\n' >&2
      exit 1
    fi
    printf '%s\n' "\$((current + 4194304))" >"$state_file"
    exit 0
    ;;
  *"cephadm shell --mount /tmp:/tmp -- rados -p alert-quota put obj-"*)
    current=\$(cat "$state_file")
    printf '%s\n' "\$((current + 4194304))" >"$state_file"
    exit 0
    ;;
  *"ceph df --format json"*)
    current=\$(cat "$state_file")
    printf '{"pools":[{"name":"alert-quota","stats":{"bytes_used":%s}}]}\n' "\$current"
    exit 0
    ;;
  *"dd if=/dev/zero of=/tmp/alert-quota-4mib.bin bs=1M count=4"*)
    printf 'ssh-live-noise\n'
    exit 0
    ;;
  *"rm -f /tmp/alert-quota-4mib.bin"*)
    printf 'ssh-live-noise\n'
    exit 0
    ;;
  *"ceph health detail"*)
    past_quota_puts=\$(grep -c 'timeout 30 rados -p alert-quota put obj-' "$trace_file" || true)
    past_quota_puts=\${past_quota_puts:-0}
    if [[ "\$past_quota_puts" -ge "$pool_full_after_puts" ]]; then
      printf 'HEALTH_ERR 1 pool(s) full (POOL_FULL)\n'
    else
      printf 'HEALTH_WARN 1 pool(s) nearfull (POOL_NEAR_FULL)\n'
    fi
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
  *"ceph osd pool create alert-quota 1"*|*"ceph osd pool set alert-quota size 3"*|*"ceph osd pool set alert-quota min_size 2"*|*"rados -p alert-quota put sentinel /etc/hosts"*|*"ceph osd pool set-quota alert-quota max_bytes 33554432"*|*"ceph osd pool delete alert-quota alert-quota --yes-i-really-really-mean-it"*)
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
live_state_file="$(mktemp)"
fake_bin_dir="$(mktemp -d)"
reject_stdout_file="$(mktemp)"
reject_stderr_file="$(mktemp)"
reject_trace_file="$(mktemp)"
reject_state_file="$(mktemp)"
reject_bin_dir="$(mktemp -d)"
exhaust_stdout_file="$(mktemp)"
exhaust_stderr_file="$(mktemp)"
exhaust_trace_file="$(mktemp)"
exhaust_state_file="$(mktemp)"
exhaust_bin_dir="$(mktemp -d)"
poolfull_stdout_file="$(mktemp)"
poolfull_stderr_file="$(mktemp)"
poolfull_trace_file="$(mktemp)"
poolfull_state_file="$(mktemp)"
poolfull_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" \
    "$live_stdout_file" "$live_stderr_file" "$live_trace_file" "$live_state_file" \
    "$reject_stdout_file" "$reject_stderr_file" "$reject_trace_file" "$reject_state_file" \
    "$exhaust_stdout_file" "$exhaust_stderr_file" "$exhaust_trace_file" "$exhaust_state_file" \
    "$poolfull_stdout_file" "$poolfull_stderr_file" "$poolfull_trace_file" "$poolfull_state_file"
  rm -rf "$fake_bin_dir" "$reject_bin_dir" "$exhaust_bin_dir" "$poolfull_bin_dir"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'pool-quota-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-pool-quota.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'pool-quota-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-pool-quota should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'pool-quota requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
[[ ! -s "$no_ack_trace_file" ]] || fail "live-capable commands ran before destructive ack"
cmp -s "$before_dirs_file" "$after_dirs_file" || fail "result dir was created before destructive ack"

# --- Happy path: near-quota puts obj-1..7 (unbounded, always succeed), then
# past-quota keeps sustained write pressure with BOUNDED (`timeout 30`)
# puts: obj-8 succeeds and lands exactly on the 32MiB quota, obj-9 and obj-10
# both hit the quota wall and TIME OUT (exit 124) -- tolerated, not a
# failure -- and only once 3 past-quota attempts have appeared in the trace
# does `ceph health detail` start reporting POOL_FULL, which the scenario
# picks up on its next poll and stops looping.
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file" "$live_state_file"
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file" "$live_state_file" 33554432 timeout 3

set +e
PATH="$fake_bin_dir:$PATH" PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  CEPH_HEALTH_CHECK_ATTEMPTS=5 CEPH_HEALTH_CHECK_SLEEP=0 \
  bash "$ROOT/run/scenario-pool-quota.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/pool-quota-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool create alert-quota 1$' "$live_trace_file" || fail "missing pool create"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool set-quota alert-quota max_bytes 33554432$' "$live_trace_file" || fail "missing set-quota"
grep -q '^ssh:dd if=/dev/zero of=/tmp/alert-quota-4mib.bin bs=1M count=4$' "$live_trace_file" || fail "missing tmpfile creation (plain host dd, not wrapped in cephadm shell)"

near_put_count="$(grep -c '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- rados -p alert-quota put obj-' "$live_trace_file" || true)"
[[ "$near_put_count" -eq 7 ]] || fail "expected exactly 7 near-quota puts (unbounded, no timeout wrapper), got $near_put_count"
past_put_count="$(grep -c '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- timeout 30 rados -p alert-quota put obj-' "$live_trace_file" || true)"
[[ "$past_put_count" -eq 3 ]] || fail "expected exactly 3 bounded past-quota put attempts (stops once POOL_FULL appears after 3), got $past_put_count"

grep -q '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- rados -p alert-quota put obj-7 /tmp/alert-quota-4mib.bin$' "$live_trace_file" || fail "missing near-quota put obj-7 (crosses the 26MiB near-quota target)"
grep -q '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- timeout 30 rados -p alert-quota put obj-8 /tmp/alert-quota-4mib.bin$' "$live_trace_file" || fail "missing bounded past-quota put obj-8 (reaches the 32MiB quota)"
grep -q '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- timeout 30 rados -p alert-quota put obj-9 /tmp/alert-quota-4mib.bin$' "$live_trace_file" || fail "missing bounded past-quota put obj-9 (the one that times out)"
grep -q '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- timeout 30 rados -p alert-quota put obj-10 /tmp/alert-quota-4mib.bin$' "$live_trace_file" || fail "missing bounded past-quota put obj-10 (POOL_FULL surfaces after this one)"

grep -q 'timed out after 30s' "$live_stderr_file" || fail "missing tolerated-timeout (exit 124) log line"

quota_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd pool set-quota alert-quota max_bytes 33554432$' "$live_trace_file" | head -1 | cut -d: -f1)"
tmpfile_line="$(grep -n '^ssh:dd if=/dev/zero' "$live_trace_file" | head -1 | cut -d: -f1)"
put1_line="$(grep -n '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- rados -p alert-quota put obj-1 ' "$live_trace_file" | head -1 | cut -d: -f1)"
put7_line="$(grep -n '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- rados -p alert-quota put obj-7 ' "$live_trace_file" | head -1 | cut -d: -f1)"
put8_line="$(grep -n '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- timeout 30 rados -p alert-quota put obj-8 ' "$live_trace_file" | head -1 | cut -d: -f1)"
put10_line="$(grep -n '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- timeout 30 rados -p alert-quota put obj-10 ' "$live_trace_file" | head -1 | cut -d: -f1)"
delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-quota alert-quota --yes-i-really-really-mean-it' "$live_trace_file" | head -1 | cut -d: -f1)"
rm_tmpfile_line="$(grep -n '^ssh:rm -f /tmp/alert-quota-4mib.bin$' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$quota_line" && -n "$tmpfile_line" && -n "$put1_line" && -n "$put7_line" && -n "$put8_line" && -n "$put10_line" && -n "$delete_line" && -n "$rm_tmpfile_line" ]] \
  || fail "missing trace lines for ordering checks"
(( tmpfile_line > quota_line )) || fail "tmpfile created before quota was set"
(( put1_line > tmpfile_line )) || fail "first put happened before tmpfile creation"
(( put7_line > put1_line )) || fail "near-quota puts out of order"
(( put8_line > put7_line )) || fail "past-quota puts happened before near-quota puts finished"
(( put10_line > put8_line )) || fail "past-quota puts out of order"
(( delete_line > put10_line )) || fail "pool delete happened before injection completed"
(( rm_tmpfile_line > delete_line )) || fail "tmpfile removal happened before pool delete"

# Every near-quota checkpoint (puts 1..7) must stay strictly below the
# 32MiB quota -- the controlled loop must never overshoot into POOL_FULL
# territory during the near-quota phase.
result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'pool-quota-*' | sort | tail -1)"
for i in 1 2 3 4 5 6 7; do
  df_file="$result_dir/ceph-df-check-$i.json"
  [[ -f "$df_file" ]] || fail "missing ceph-df-check-$i.json evidence file"
  used="$(jq -r '.pools[0].stats.bytes_used' "$df_file")"
  [[ "$used" -lt 33554432 ]] || fail "near-quota put $i already at/over the 32MiB quota (used=$used)"
done
final_used="$(jq -r '.pools[0].stats.bytes_used' "$result_dir/ceph-df-check-8.json")"
[[ "$final_used" -eq 33554432 ]] || fail "expected obj-8 (the only successful past-quota put) to land exactly on the 32MiB quota, got $final_used"

ok "pool-quota destructive ack guard, controlled near-quota write staying below quota, and bounded-put timeout (124) tolerance surfacing POOL_FULL"

# --- Rejected-put path: the mon rejects past-quota puts outright (rc=1,
# EDQUOT-style) instead of the bounded put timing out. Proves
# write_past_quota tolerates BOTH failure modes -- a hard rejection and a
# `timeout 30`-triggered exit 124 -- as the expected quota-pressure signal,
# not a scenario error, while still confirming POOL_FULL/CephClientBlocked.
rm -rf "$reject_bin_dir"
reject_bin_dir="$(mktemp -d)"
make_fake_jq "$reject_bin_dir/jq" "$real_jq" "$reject_trace_file"
make_fake_kubectl "$reject_bin_dir/kubectl" "$reject_trace_file" "$reject_state_file"
make_fake_curl "$reject_bin_dir/curl" "$reject_trace_file"
make_fake_ssh "$reject_bin_dir/ssh" "$reject_trace_file" "$reject_state_file" 33554432 reject 3

set +e
PATH="$reject_bin_dir:$PATH" PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  CEPH_HEALTH_CHECK_ATTEMPTS=5 CEPH_HEALTH_CHECK_SLEEP=0 \
  bash "$ROOT/run/scenario-pool-quota.sh" --yes-really-inject >"$reject_stdout_file" 2>"$reject_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success even when past-quota puts are rejected outright, got $rc"
grep -q 'rejected (rc=1)' "$reject_stderr_file" || fail "missing tolerated-rejection log line"
past_put_count_reject="$(grep -c '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- timeout 30 rados -p alert-quota put obj-' "$reject_trace_file" || true)"
[[ "$past_put_count_reject" -eq 3 ]] || fail "expected exactly 3 bounded past-quota put attempts (stops once POOL_FULL appears after 3), got $past_put_count_reject"
grep -q '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-quota alert-quota --yes-i-really-really-mean-it' "$reject_trace_file" || fail "missing rollback pool delete after put-rejection path"

ok "pool-quota tolerates an outright-rejected past-quota put as the quota-full signal and still confirms POOL_FULL"

# --- Near-quota exhaustion path: NEARQUOTA_TARGET_BYTES is set unreachably
# high with NEARQUOTA_MAX_PUTS=1, so write_near_quota's die() fires. Proves
# the EXIT trap still runs scenario_rollback (pool delete + tmpfile removal)
# even though injection never got past the near-quota phase.
rm -rf "$exhaust_bin_dir"
exhaust_bin_dir="$(mktemp -d)"
make_fake_jq "$exhaust_bin_dir/jq" "$real_jq" "$exhaust_trace_file"
make_fake_kubectl "$exhaust_bin_dir/kubectl" "$exhaust_trace_file" "$exhaust_state_file"
make_fake_curl "$exhaust_bin_dir/curl" "$exhaust_trace_file"
make_fake_ssh "$exhaust_bin_dir/ssh" "$exhaust_trace_file" "$exhaust_state_file"

set +e
PATH="$exhaust_bin_dir:$PATH" NEARQUOTA_TARGET_BYTES=999999999 NEARQUOTA_MAX_PUTS=1 \
  PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$ROOT/run/scenario-pool-quota.sh" --yes-really-inject >"$exhaust_stdout_file" 2>"$exhaust_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when the near-quota target is never reached"
grep -q 'FATAL: pool-quota: did not reach near-quota target' "$exhaust_stderr_file" || fail "missing die() message for unreached near-quota target"
grep -q '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-quota alert-quota --yes-i-really-really-mean-it' "$exhaust_trace_file" || fail "rollback pool delete missing after near-quota exhaustion"
grep -q '^ssh:rm -f /tmp/alert-quota-4mib.bin$' "$exhaust_trace_file" || fail "rollback tmpfile removal missing after near-quota exhaustion"

ok "pool-quota still deletes the pool and removes the tmpfile when the near-quota put budget is exhausted"

# --- Past-quota exhaustion path: pool_full_after_puts is set unreachably
# high (so `ceph health detail` never reports POOL_FULL) and
# OVERQUOTA_MAX_PUTS is capped at 2, so write_past_quota's die() fires after
# exactly 2 bounded put attempts instead of looping forever. Proves the
# max-attempts safety net actually bounds the loop, and rollback still runs.
rm -rf "$poolfull_bin_dir"
poolfull_bin_dir="$(mktemp -d)"
make_fake_jq "$poolfull_bin_dir/jq" "$real_jq" "$poolfull_trace_file"
make_fake_kubectl "$poolfull_bin_dir/kubectl" "$poolfull_trace_file" "$poolfull_state_file"
make_fake_curl "$poolfull_bin_dir/curl" "$poolfull_trace_file"
make_fake_ssh "$poolfull_bin_dir/ssh" "$poolfull_trace_file" "$poolfull_state_file" 33554432 timeout 999

set +e
PATH="$poolfull_bin_dir:$PATH" OVERQUOTA_MAX_PUTS=2 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  CEPH_HEALTH_CHECK_ATTEMPTS=5 CEPH_HEALTH_CHECK_SLEEP=0 \
  bash "$ROOT/run/scenario-pool-quota.sh" --yes-really-inject >"$poolfull_stdout_file" 2>"$poolfull_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when POOL_FULL never appears within the attempt cap"
grep -q 'FATAL: pool-quota: POOL_FULL health check did not appear after 2 past-quota put attempts' "$poolfull_stderr_file" || fail "missing die() message for exhausted past-quota attempt cap"
past_put_count_poolfull="$(grep -c '^ssh:sudo -n cephadm shell --mount /tmp:/tmp -- timeout 30 rados -p alert-quota put obj-' "$poolfull_trace_file" || true)"
[[ "$past_put_count_poolfull" -eq 2 ]] || fail "expected exactly 2 bounded past-quota put attempts before giving up, got $past_put_count_poolfull"
grep -q '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-quota alert-quota --yes-i-really-really-mean-it' "$poolfull_trace_file" || fail "rollback pool delete missing after past-quota attempt-cap exhaustion"

ok "pool-quota gives up after OVERQUOTA_MAX_PUTS bounded attempts when POOL_FULL never appears, and still rolls back"
