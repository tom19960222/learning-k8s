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
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephDaemonRecentCrash"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"watchdog","alertname":"Watchdog","labels":{}}'
  if grep -q 'ceph crash post -i -' "$trace_file"; then
    printf '%s\n' '{"receiver":"slack","alertname":"CephDaemonRecentCrash","labels":{"fresh":"true"}}'
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

# osd_status controls what `systemctl is-active` reports for the crashed
# OSD's unit during rollback: "active" simulates systemd's on-failure
# restart already having brought it back; anything else forces the
# scenario's explicit `systemctl start` fallback branch.
#
# crash_poll_empty_calls controls how many times the crash-spool `ls`
# reports only the pre-existing ("existing-crash-id") entry before the new
# crash id ("new-crash-id") shows up -- modeling the real lab's crash dir
# appearing a poll cycle or two after the SEGV, per the mgr-standby fake's
# call-counter pattern in test-scenario-mgr-failover.sh. The very first `ls`
# call (the pre-injection snapshot in scenario_setup) always sees only
# "existing-crash-id", proving the scenario diffs against that baseline
# instead of assuming an empty spool.
make_fake_ssh() {
  local path=$1 trace_file=$2 osd_status=${3:-active} crash_poll_empty_calls=${4:-0}
  local counter_file="${trace_file}.crash-ls-calls"
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
  *"ceph osd ls-tree ceph-lab-osd-01"*)
    printf '0\n'
    exit 0
    ;;
  *"podman inspect --format '{{.State.Pid}}' ceph-"*)
    printf '555555\n'
    exit 0
    ;;
  *"pgrep -P 555555 ceph-osd"*)
    printf '666666\n'
    exit 0
    ;;
  *"ls -1 /var/lib/ceph/"*"/crash/"*)
    call_count="\$(cat "$counter_file")"
    call_count=\$((call_count + 1))
    printf '%s\n' "\$call_count" >"$counter_file"
    printf 'existing-crash-id\n'
    if [[ "\$call_count" -gt \$((1 + $crash_poll_empty_calls)) ]]; then
      printf 'new-crash-id\n'
    fi
    exit 0
    ;;
  *"base64 -w0 /var/lib/ceph/"*"/crash/new-crash-id/meta"*)
    printf 'ZmFrZS1jcmFzaC1tZXRh\n'
    exit 0
    ;;
  *"systemctl is-active ceph-"*)
    printf '${osd_status}\n'
    exit 0
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_WARN 1 daemons have recently crashed (RECENT_CRASH)\n'
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
  *"ceph osd tree"*|*"kill -SEGV 666666"*|*"echo ZmFrZS1jcmFzaC1tZXRh | base64 -d | sudo -n cephadm shell -- ceph crash post -i -"*|*"ceph crash archive new-crash-id"*|*"systemctl start ceph-"*)
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
fallback_stdout_file="$(mktemp)"
fallback_stderr_file="$(mktemp)"
fallback_trace_file="$(mktemp)"
fallback_bin_dir="$(mktemp -d)"
timeout_stdout_file="$(mktemp)"
timeout_stderr_file="$(mktemp)"
timeout_trace_file="$(mktemp)"
timeout_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" "$live_stdout_file" "$live_stderr_file" "$live_trace_file" "$live_trace_file.crash-ls-calls" \
    "$fallback_stdout_file" "$fallback_stderr_file" "$fallback_trace_file" "$fallback_trace_file.crash-ls-calls" \
    "$timeout_stdout_file" "$timeout_stderr_file" "$timeout_trace_file" "$timeout_trace_file.crash-ls-calls"
  rm -rf "$fake_bin_dir" "$fallback_bin_dir" "$timeout_bin_dir"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'daemon-crash-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-daemon-crash.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'daemon-crash-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-daemon-crash should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'daemon-crash requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
[[ ! -s "$no_ack_trace_file" ]] || fail "live-capable commands ran before destructive ack"
cmp -s "$before_dirs_file" "$after_dirs_file" || fail "result dir was created before destructive ack"

rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
# crash_poll_empty_calls=2 exercises the crash-dir discovery poll surviving
# two transient "not there yet" cycles before succeeding on the third --
# matching the real lab's crash dir appearing a beat or two after the SEGV.
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file" active 2

set +e
PATH="$fake_bin_dir:$PATH" DAEMON_CRASH_SPOOL_SLEEP=0 \
  bash "$ROOT/run/scenario-daemon-crash.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/daemon-crash-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph osd ls-tree ceph-lab-osd-01$' "$live_trace_file" || fail "missing OSD discovery via ls-tree"
grep -q "^ssh:sudo -n podman inspect --format '{{.State.Pid}}' ceph-.*-osd-0\$" "$live_trace_file" || fail "missing podman inspect for the OSD container"
grep -q '^ssh:sudo -n pgrep -P 555555 ceph-osd$' "$live_trace_file" || fail "missing pgrep -P of podman-init for the real ceph-osd PID"
grep -q '^ssh:sudo -n kill -SEGV 666666$' "$live_trace_file" || fail "missing kill -SEGV of the resolved ceph-osd PID (not conmon/podman-init)"
grep -q '^ssh:echo ZmFrZS1jcmFzaC1tZXRh | base64 -d | sudo -n cephadm shell -- ceph crash post -i -$' "$live_trace_file" || fail "missing crash post via seed admin shell"
grep -q '^ssh:sudo -n cephadm shell -- ceph crash archive new-crash-id$' "$live_trace_file" || fail "missing rollback ceph crash archive of the specific crash id"
if grep -q 'ceph crash archive-all' "$live_trace_file"; then
  fail "rollback must archive the specific crash id, not archive-all"
fi
grep -q '^ssh:systemctl is-active ceph-.*@osd\.0\.service$' "$live_trace_file" || fail "missing rollback is-active poll for osd.0"
if grep -q '^ssh:sudo systemctl start ceph-.*@osd\.0\.service$' "$live_trace_file"; then
  fail "explicit systemctl start should not run when the OSD already recovered on its own"
fi

ls_calls="$(grep -c '^ssh:sudo -n ls -1 /var/lib/ceph/' "$live_trace_file")"
[[ "$ls_calls" -ge 4 ]] || fail "expected at least 4 crash-spool ls calls (1 baseline + 3 poll cycles), got $ls_calls"

inspect_line="$(grep -n "^ssh:sudo -n podman inspect --format '{{.State.Pid}}' ceph-.*-osd-0\$" "$live_trace_file" | head -1 | cut -d: -f1)"
pgrep_line="$(grep -n '^ssh:sudo -n pgrep -P 555555 ceph-osd$' "$live_trace_file" | head -1 | cut -d: -f1)"
kill_line="$(grep -n '^ssh:sudo -n kill -SEGV 666666$' "$live_trace_file" | head -1 | cut -d: -f1)"
first_ls_line="$(grep -n '^ssh:sudo -n ls -1 /var/lib/ceph/' "$live_trace_file" | head -1 | cut -d: -f1)"
last_ls_line="$(grep -n '^ssh:sudo -n ls -1 /var/lib/ceph/' "$live_trace_file" | tail -1 | cut -d: -f1)"
post_line="$(grep -n '^ssh:echo ZmFrZS1jcmFzaC1tZXRh | base64 -d | sudo -n cephadm shell -- ceph crash post -i -$' "$live_trace_file" | head -1 | cut -d: -f1)"
archive_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph crash archive new-crash-id$' "$live_trace_file" | head -1 | cut -d: -f1)"
active_poll_line="$(grep -n '^ssh:systemctl is-active ceph-.*@osd\.0\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$inspect_line" && -n "$pgrep_line" && -n "$kill_line" && -n "$first_ls_line" && -n "$last_ls_line" && -n "$post_line" && -n "$archive_line" && -n "$active_poll_line" ]] \
  || fail "missing trace lines for ordering checks"
(( pgrep_line > inspect_line )) || fail "pgrep -P happened before podman inspect"
(( kill_line > pgrep_line )) || fail "kill -SEGV happened before pgrep -P"
(( first_ls_line < kill_line )) || fail "crash-spool baseline snapshot did not happen before kill -SEGV"
(( last_ls_line > kill_line )) || fail "crash-spool poll (spool diff) did not happen after kill -SEGV"
(( post_line > last_ls_line )) || fail "crash post happened before the new crash dir was discovered"
(( archive_line > post_line )) || fail "rollback crash archive happened before crash post"
(( active_poll_line > archive_line )) || fail "rollback is-active poll happened before crash archive"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'daemon-crash-*' | sort | tail -1)"
[[ -f "$result_dir/target-osd-container.txt" ]] || fail "missing target-osd-container.txt evidence file"
grep -Eq '^ceph-.*-osd-0$' "$result_dir/target-osd-container.txt" || fail "target-osd-container.txt content mismatch: $(cat "$result_dir/target-osd-container.txt" 2>/dev/null)"
[[ -f "$result_dir/target-osd-pid.txt" ]] || fail "missing target-osd-pid.txt evidence file"
[[ "$(cat "$result_dir/target-osd-pid.txt")" == "666666" ]] || fail "target-osd-pid.txt content mismatch: $(cat "$result_dir/target-osd-pid.txt" 2>/dev/null)"
[[ -f "$result_dir/crash-id.txt" ]] || fail "missing crash-id.txt evidence file"
[[ "$(cat "$result_dir/crash-id.txt")" == "new-crash-id" ]] || fail "crash-id.txt content mismatch: $(cat "$result_dir/crash-id.txt" 2>/dev/null)"
[[ -f "$result_dir/crash-spool-before.txt" ]] || fail "missing crash-spool-before.txt evidence file"
[[ "$(cat "$result_dir/crash-spool-before.txt")" == "existing-crash-id" ]] || fail "crash-spool-before.txt must only contain the pre-existing crash id"

# assert_sink_absent always writes sink-absent-check.log before the pass/fail branch, regardless of
# outcome. Assert it exists to prove the pager-absence check for CephDaemonRecentCrash actually ran
# (RECENT_CRASH is warning severity and must route to slack only, never pager).
[[ -f "$result_dir/sink-absent-check.log" ]] || fail "missing negative-assertion evidence file for sink pager absence"

ok "daemon-crash destructive ack guard, podman-inspect/pgrep/kill/spool-diff/post injection sequence, and rollback ordering"

# --- Fallback path: the OSD unit never reports "active" on its own (systemd's
# on-failure restart did not bring it back), so scenario_rollback must fall
# through to an explicit `systemctl start`. DAEMON_CRASH_RESTART_ATTEMPTS=1 /
# SLEEP=0 keep the doomed is-active poll from retrying for real (would
# otherwise sleep 5s x 12 attempts before falling back).
make_fake_jq "$fallback_bin_dir/jq" "$real_jq" "$fallback_trace_file"
make_fake_kubectl "$fallback_bin_dir/kubectl" "$fallback_trace_file"
make_fake_curl "$fallback_bin_dir/curl" "$fallback_trace_file"
make_fake_ssh "$fallback_bin_dir/ssh" "$fallback_trace_file" failed 0

set +e
PATH="$fallback_bin_dir:$PATH" DAEMON_CRASH_SPOOL_SLEEP=0 DAEMON_CRASH_RESTART_ATTEMPTS=1 DAEMON_CRASH_RESTART_SLEEP=0 \
  bash "$ROOT/run/scenario-daemon-crash.sh" --yes-really-inject >"$fallback_stdout_file" 2>"$fallback_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success even when the OSD needs an explicit restart, got $rc"
grep -q '^ssh:sudo systemctl start ceph-.*@osd\.0\.service$' "$fallback_trace_file" || fail "missing explicit systemctl start fallback when OSD did not self-recover"
grep -q '^ssh:sudo -n cephadm shell -- ceph crash archive new-crash-id$' "$fallback_trace_file" || fail "missing rollback crash archive in fallback path"

start_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.0\.service$' "$fallback_trace_file" | head -1 | cut -d: -f1)"
fallback_archive_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph crash archive new-crash-id$' "$fallback_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$start_line" && -n "$fallback_archive_line" ]] || fail "missing trace lines for fallback ordering checks"
(( start_line > fallback_archive_line )) || fail "explicit systemctl start happened before crash archive"

ok "daemon-crash falls back to an explicit systemctl start when the OSD does not self-recover"

# --- Failure path: no new crash dir ever appears under the crash spool (the
# SEGV somehow didn't produce one, or ceph-osd's crash-dump path is broken).
# scenario_inject must `die` instead of silently proceeding into verify with
# an empty crash id, and the EXIT trap must still run scenario_rollback,
# which must still ensure the OSD service is active (even though there is no
# crash id to archive).
make_fake_jq "$timeout_bin_dir/jq" "$real_jq" "$timeout_trace_file"
make_fake_kubectl "$timeout_bin_dir/kubectl" "$timeout_trace_file"
make_fake_curl "$timeout_bin_dir/curl" "$timeout_trace_file"
make_fake_ssh "$timeout_bin_dir/ssh" "$timeout_trace_file" active 99

set +e
PATH="$timeout_bin_dir:$PATH" DAEMON_CRASH_SPOOL_ATTEMPTS=2 DAEMON_CRASH_SPOOL_SLEEP=0 \
  bash "$ROOT/run/scenario-daemon-crash.sh" --yes-really-inject >"$timeout_stdout_file" 2>"$timeout_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected failure when no new crash dir ever appears under the spool"
grep -q 'FATAL: no new crash dir appeared under /var/lib/ceph/' "$timeout_stderr_file" || fail "missing die message for crash-spool poll timeout"
if grep -q 'ceph crash post -i -' "$timeout_trace_file"; then
  fail "crash post must not run when no new crash dir was ever discovered"
fi
if grep -q 'ceph crash archive new-crash-id' "$timeout_trace_file"; then
  fail "rollback must not attempt to archive a crash id that was never discovered"
fi
grep -q '^ssh:systemctl is-active ceph-.*@osd\.0\.service$' "$timeout_trace_file" || fail "rollback must still ensure the OSD service is active even when crash discovery failed"

ok "daemon-crash dies when no new crash dir appears, and rollback still ensures the OSD is active"
