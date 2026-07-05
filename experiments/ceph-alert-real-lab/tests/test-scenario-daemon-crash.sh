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
  if grep -q 'sudo kill -SEGV' "$trace_file"; then
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
make_fake_ssh() {
  local path=$1 trace_file=$2 osd_status=${3:-active}
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
  *"systemctl show -p MainPID --value ceph-"*)
    printf '424242\n'
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
  *"ceph osd tree"*|*"sudo kill -SEGV "*|*"ceph crash archive-all"*|*"systemctl start ceph-"*)
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
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" "$live_stdout_file" "$live_stderr_file" "$live_trace_file" "$fallback_stdout_file" "$fallback_stderr_file" "$fallback_trace_file"
  rm -rf "$fake_bin_dir" "$fallback_bin_dir"
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
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file" active

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-daemon-crash.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
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
grep -q '^ssh:systemctl show -p MainPID --value ceph-.*@osd\.0\.service$' "$live_trace_file" || fail "missing MainPID lookup for osd.0"
grep -q '^ssh:sudo kill -SEGV 424242$' "$live_trace_file" || fail "missing kill -SEGV of the resolved PID"
grep -q '^ssh:sudo -n cephadm shell -- ceph crash archive-all$' "$live_trace_file" || fail "missing rollback ceph crash archive-all"
grep -q '^ssh:systemctl is-active ceph-.*@osd\.0\.service$' "$live_trace_file" || fail "missing rollback is-active poll for osd.0"
if grep -q '^ssh:sudo systemctl start ceph-.*@osd\.0\.service$' "$live_trace_file"; then
  fail "explicit systemctl start should not run when the OSD already recovered on its own"
fi

discover_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd ls-tree ceph-lab-osd-01$' "$live_trace_file" | head -1 | cut -d: -f1)"
pid_line="$(grep -n '^ssh:systemctl show -p MainPID --value ceph-.*@osd\.0\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
kill_line="$(grep -n '^ssh:sudo kill -SEGV 424242$' "$live_trace_file" | head -1 | cut -d: -f1)"
archive_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph crash archive-all$' "$live_trace_file" | head -1 | cut -d: -f1)"
active_poll_line="$(grep -n '^ssh:systemctl is-active ceph-.*@osd\.0\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$discover_line" && -n "$pid_line" && -n "$kill_line" && -n "$archive_line" && -n "$active_poll_line" ]] || fail "missing trace lines for ordering checks"
(( pid_line > discover_line )) || fail "MainPID lookup happened before OSD discovery"
(( kill_line > pid_line )) || fail "kill -SEGV happened before MainPID lookup"
(( archive_line > kill_line )) || fail "rollback crash archive-all happened before kill -SEGV"
(( active_poll_line > archive_line )) || fail "rollback is-active poll happened before crash archive-all"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'daemon-crash-*' | sort | tail -1)"
[[ -f "$result_dir/target-osd-pid.txt" ]] || fail "missing target-osd-pid.txt evidence file"
[[ "$(cat "$result_dir/target-osd-pid.txt")" == "424242" ]] || fail "target-osd-pid.txt content mismatch: $(cat "$result_dir/target-osd-pid.txt" 2>/dev/null)"

# assert_sink_absent always writes sink-absent-check.log before the pass/fail branch, regardless of
# outcome. Assert it exists to prove the pager-absence check for CephDaemonRecentCrash actually ran
# (RECENT_CRASH is warning severity and must route to slack only, never pager).
[[ -f "$result_dir/sink-absent-check.log" ]] || fail "missing negative-assertion evidence file for sink pager absence"

ok "daemon-crash destructive ack guard, kill -SEGV injection sequence, and rollback ordering"

# --- Fallback path: the OSD unit never reports "active" on its own (systemd's
# on-failure restart did not bring it back), so scenario_rollback must fall
# through to an explicit `systemctl start`. DAEMON_CRASH_RESTART_ATTEMPTS=1 /
# SLEEP=0 keep the doomed is-active poll from retrying for real (would
# otherwise sleep 5s x 12 attempts before falling back).
make_fake_jq "$fallback_bin_dir/jq" "$real_jq" "$fallback_trace_file"
make_fake_kubectl "$fallback_bin_dir/kubectl" "$fallback_trace_file"
make_fake_curl "$fallback_bin_dir/curl" "$fallback_trace_file"
make_fake_ssh "$fallback_bin_dir/ssh" "$fallback_trace_file" failed

set +e
PATH="$fallback_bin_dir:$PATH" DAEMON_CRASH_RESTART_ATTEMPTS=1 DAEMON_CRASH_RESTART_SLEEP=0 \
  bash "$ROOT/run/scenario-daemon-crash.sh" --yes-really-inject >"$fallback_stdout_file" 2>"$fallback_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success even when the OSD needs an explicit restart, got $rc"
grep -q '^ssh:sudo systemctl start ceph-.*@osd\.0\.service$' "$fallback_trace_file" || fail "missing explicit systemctl start fallback when OSD did not self-recover"

start_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.0\.service$' "$fallback_trace_file" | head -1 | cut -d: -f1)"
fallback_archive_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph crash archive-all$' "$fallback_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$start_line" && -n "$fallback_archive_line" ]] || fail "missing trace lines for fallback ordering checks"
(( start_line > fallback_archive_line )) || fail "explicit systemctl start happened before crash archive-all"

ok "daemon-crash falls back to an explicit systemctl start when the OSD does not self-recover"
