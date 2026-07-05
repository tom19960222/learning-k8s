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

# make_fake_kubectl's CephObjectUnfound alert/sink fire whenever osd.7 (B --
# the OSD holding the newer object version) currently has more systemctl
# stops than starts in the trace file, mirroring the real unfound condition
# this scenario reproduces: B down + A up-but-stale = unfound.
make_fake_kubectl() {
  local path=$1 trace_file=$2
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
b_stops=\$(grep -c 'systemctl stop ceph-.*@osd\.7\.service' "$trace_file" || true)
b_starts=\$(grep -c 'systemctl start ceph-.*@osd\.7\.service' "$trace_file" || true)
unfound=0
if [[ "\$b_stops" -gt "\$b_starts" ]]; then
  unfound=1
fi
if [[ "\$*" == *"get pod -l app=prometheus -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'prometheus-0\n'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  if [[ "\$unfound" -eq 1 ]]; then
    printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephObjectUnfound"},"state":"firing"}]}}'
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
  if [[ "\$unfound" -eq 1 ]]; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephObjectUnfound","labels":{"fresh":"true"}}'
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

# osd.3 (A) and osd.7 (B) up/down state, cluster health's OBJECT_UNFOUND, and
# the norecover flag are all derived purely from counts in the trace file:
#   - an OSD is down whenever it has more systemctl stops than starts.
#   - OBJECT_UNFOUND is present whenever B currently has more stops than
#     starts (mirrors make_fake_kubectl's logic above).
#   - the norecover flag is present whenever `ceph osd set norecover` has
#     been called more times than `ceph osd unset norecover`.
# FAKE_START_A_FAIL_MARKER, if set, makes the FIRST "systemctl start" call
# for osd.3 fail once (creating the marker file); every subsequent call
# (including scenario_rollback's own retry) succeeds -- this models a
# transient failure partway through scenario_inject's step 4.
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
  *"ceph osd map alert-unfound victim --format json"*)
    printf '{"acting":[3,7]}\n'
    exit 0
    ;;
  *"ceph osd find 3 --format json"*)
    printf '{"crush_location":{"host":"ceph-lab-osd-01"}}\n'
    exit 0
    ;;
  *"ceph osd find 7 --format json"*)
    printf '{"crush_location":{"host":"ceph-lab-osd-03"}}\n'
    exit 0
    ;;
  *"systemctl start ceph-"*"@osd.3.service")
    if [[ -n "\${FAKE_START_A_FAIL_MARKER:-}" && ! -f "\$FAKE_START_A_FAIL_MARKER" ]]; then
      : >"\$FAKE_START_A_FAIL_MARKER"
      printf 'simulated systemctl start failure for osd.3\n' >&2
      exit 1
    fi
    printf 'ssh-live-noise\n'
    exit 0
    ;;
  *"ceph osd tree --format json"*)
    a_stops=\$(grep -c 'systemctl stop ceph-.*@osd\.3\.service' "$trace_file" || true)
    a_starts=\$(grep -c 'systemctl start ceph-.*@osd\.3\.service' "$trace_file" || true)
    b_stops=\$(grep -c 'systemctl stop ceph-.*@osd\.7\.service' "$trace_file" || true)
    b_starts=\$(grep -c 'systemctl start ceph-.*@osd\.7\.service' "$trace_file" || true)
    a_status=up
    if [[ "\$a_stops" -gt "\$a_starts" ]]; then
      a_status=down
    fi
    b_status=up
    if [[ "\$b_stops" -gt "\$b_starts" ]]; then
      b_status=down
    fi
    # Real cephadm shell prints this 4-line banner to STDERR on every
    # invocation (fsid/config inference + image pull info); it is NOT
    # '#'-prefixed. Modeling it here regression-tests that the JSON poll
    # helper parses stdout only and never merges this banner into the JSON.
    printf 'Inferring fsid 0c9bf37e-514a-11f1-b72a-bc24113f1375\n' >&2
    printf 'Inferring config /var/lib/ceph/0c9bf37e-514a-11f1-b72a-bc24113f1375/mon.ceph-lab-mon-01/config\n' >&2
    printf "Using ceph image with id 'abcdef123456' and tag 'v19.2.3' created on 2025-01-01 00:00:00 +0000 UTC\n" >&2
    printf 'quay.io/ceph/ceph@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' >&2
    printf '{"nodes":[{"id":3,"name":"osd.3","type":"osd","status":"%s"},{"id":7,"name":"osd.7","type":"osd","status":"%s"}]}\n' "\$a_status" "\$b_status"
    exit 0
    ;;
  *"ceph health detail"*)
    b_stops=\$(grep -c 'systemctl stop ceph-.*@osd\.7\.service' "$trace_file" || true)
    b_starts=\$(grep -c 'systemctl start ceph-.*@osd\.7\.service' "$trace_file" || true)
    if [[ "\$b_stops" -gt "\$b_starts" ]]; then
      printf 'HEALTH_WARN\n'
      printf '[WRN] OBJECT_UNFOUND: 1/1 objects unfound (100.000%%)\n'
    else
      printf 'HEALTH_OK\n'
    fi
    exit 0
    ;;
  *"ceph osd dump"*)
    set_count=\$(grep -c 'ceph osd set norecover' "$trace_file" || true)
    unset_count=\$(grep -c 'ceph osd unset norecover' "$trace_file" || true)
    if [[ "\$set_count" -gt "\$unset_count" ]]; then
      printf 'flags: sortbitwise,norecover\n'
    else
      printf 'flags: sortbitwise\n'
    fi
    exit 0
    ;;
  *"quorum_status --format json"*)
    printf '{"quorum":[0,1,2]}\n'
    exit 0
    ;;
  *"ceph osd pool create "*|*"ceph osd pool set "*|*"rados -p alert-unfound put victim /etc/hosts"*|*"rados -p alert-unfound put victim /etc/os-release"*|*"ceph osd set norecover"*|*"ceph osd unset norecover"*|*"ceph osd pool delete "*|*"systemctl stop ceph-"*|*"systemctl start ceph-"*)
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
fail_stdout_file="$(mktemp)"
fail_stderr_file="$(mktemp)"
fail_trace_file="$(mktemp)"
fail_bin_dir="$(mktemp -d)"
fail_marker_file="$(mktemp -u)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" \
    "$live_stdout_file" "$live_stderr_file" "$live_trace_file" \
    "$fail_stdout_file" "$fail_stderr_file" "$fail_trace_file" "$fail_marker_file"
  rm -rf "$fake_bin_dir" "$fail_bin_dir"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'object-unfound-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-object-unfound.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'object-unfound-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-object-unfound should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'object-unfound requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
[[ ! -s "$no_ack_trace_file" ]] || fail "live-capable commands ran before destructive ack"
cmp -s "$before_dirs_file" "$after_dirs_file" || fail "result dir was created before destructive ack"

# --- Success path: full deterministic 6-step unfound dance, verify, then
# rollback (start B, poll unfound clear, defensive norecover check, delete).
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" \
  UNFOUND_POLL_ATTEMPTS=5 UNFOUND_POLL_SLEEP=0 \
  CEPH_HEALTH_CHECK_ATTEMPTS=5 CEPH_HEALTH_CHECK_SLEEP=0 \
  PROMETHEUS_WAIT_ATTEMPTS=5 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=5 SINK_WAIT_SLEEP=0 \
  UNFOUND_RECOVERY_ATTEMPTS=5 UNFOUND_RECOVERY_SLEEP=0 \
  bash "$ROOT/run/scenario-object-unfound.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/object-unfound-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo systemctl stop ceph-.*@osd\.3\.service$' "$live_trace_file" || fail "missing step 1 stop for osd.3 (A)"
grep -q '^ssh:sudo -n cephadm shell -- rados -p alert-unfound put victim /etc/os-release$' "$live_trace_file" || fail "missing step 2 new-version put"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set norecover$' "$live_trace_file" || fail "missing step 3 set norecover"
grep -q '^ssh:sudo systemctl start ceph-.*@osd\.3\.service$' "$live_trace_file" || fail "missing step 4 start for osd.3 (A)"
grep -q '^ssh:sudo systemctl stop ceph-.*@osd\.7\.service$' "$live_trace_file" || fail "missing step 5 stop for osd.7 (B)"
unset_count="$(grep -c '^ssh:sudo -n cephadm shell -- ceph osd unset norecover$' "$live_trace_file" || true)"
[[ "$unset_count" -eq 1 ]] || fail "expected exactly 1 unset norecover call (step 6 only, no defensive rollback unset needed), got $unset_count"
grep -q '^ssh:sudo systemctl start ceph-.*@osd\.7\.service$' "$live_trace_file" || fail "missing rollback start for osd.7 (B)"
delete_count="$(grep -c '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-unfound alert-unfound --yes-i-really-really-mean-it' "$live_trace_file" || true)"
[[ "$delete_count" -eq 1 ]] || fail "expected one delete invocation, got $delete_count"

stop_a_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@osd\.3\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
put_new_line="$(grep -n '^ssh:sudo -n cephadm shell -- rados -p alert-unfound put victim /etc/os-release$' "$live_trace_file" | head -1 | cut -d: -f1)"
set_norecover_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd set norecover$' "$live_trace_file" | head -1 | cut -d: -f1)"
start_a_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.3\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
stop_b_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@osd\.7\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
unset_norecover_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd unset norecover$' "$live_trace_file" | head -1 | cut -d: -f1)"
start_b_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.7\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-unfound alert-unfound --yes-i-really-really-mean-it' "$live_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$stop_a_line" && -n "$put_new_line" && -n "$set_norecover_line" && -n "$start_a_line" && -n "$stop_b_line" && -n "$unset_norecover_line" && -n "$start_b_line" && -n "$delete_line" ]] ||
  fail "missing trace lines for 6-step ordering checks"
(( put_new_line > stop_a_line )) || fail "step 2 (new version put) happened before step 1 (stop A)"
(( set_norecover_line > put_new_line )) || fail "step 3 (set norecover) happened before step 2 (new version put)"
(( start_a_line > set_norecover_line )) || fail "step 4 (start A) happened before step 3 (set norecover)"
(( stop_b_line > start_a_line )) || fail "step 5 (stop B) happened before step 4 (start A)"
(( unset_norecover_line > stop_b_line )) || fail "step 6 (unset norecover) happened before step 5 (stop B)"
(( start_b_line > unset_norecover_line )) || fail "rollback start of B happened before step 6 (unset norecover)"
(( delete_line > start_b_line )) || fail "pool delete happened before rollback restarted B"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'object-unfound-*' | sort | tail -1)"
for f in step-1-stop-osd-a.txt step-2-put-new-version.txt step-3-set-norecover.txt step-4-start-osd-a.txt step-5-stop-osd-b.txt step-6-unset-norecover.txt; do
  [[ -f "$result_dir/$f" ]] || fail "missing per-step evidence file $f"
done
[[ -f "$result_dir/rollback-osd-dump-flags.txt" ]] || fail "missing rollback norecover-flag evidence file"
[[ ! -f "$result_dir/rollback-unset-norecover.txt" ]] || fail "defensive unset should not have run when step 6 already cleared norecover"

ok "object-unfound destructive ack guard, 6-step injection sequence, and rollback ordering"

# --- Failure path: step 4 (start A) fails once. This proves two rollback
# safety nets at the same time: (a) without an explicit "ensure osd.3
# started" step, a partial-inject failure here would leave A down forever
# -- scenario_rollback's retry of the same start command must succeed on a
# transient failure; (b) since scenario_inject aborts before step 6 runs,
# norecover is left set -- scenario_rollback's defensive
# grep-then-unset-if-still-set branch must actually fire (not just exist
# vacuously), which the success-path test above proves does NOT fire when
# unneeded.
rm -f "$fail_marker_file"
make_fake_jq "$fail_bin_dir/jq" "$real_jq" "$fail_trace_file"
make_fake_kubectl "$fail_bin_dir/kubectl" "$fail_trace_file"
make_fake_curl "$fail_bin_dir/curl" "$fail_trace_file"
make_fake_ssh "$fail_bin_dir/ssh" "$fail_trace_file"

set +e
PATH="$fail_bin_dir:$PATH" FAKE_START_A_FAIL_MARKER="$fail_marker_file" \
  UNFOUND_POLL_ATTEMPTS=5 UNFOUND_POLL_SLEEP=0 \
  CEPH_HEALTH_CHECK_ATTEMPTS=5 CEPH_HEALTH_CHECK_SLEEP=0 \
  PROMETHEUS_WAIT_ATTEMPTS=5 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=5 SINK_WAIT_SLEEP=0 \
  UNFOUND_RECOVERY_ATTEMPTS=5 UNFOUND_RECOVERY_SLEEP=0 \
  bash "$ROOT/run/scenario-object-unfound.sh" --yes-really-inject >"$fail_stdout_file" 2>"$fail_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when step 4's osd.3 start fails"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set norecover$' "$fail_trace_file" || fail "missing step 3 (set norecover) before the simulated step 4 failure"
if grep -q '^ssh:sudo systemctl stop ceph-.*@osd\.7\.service$' "$fail_trace_file"; then
  fail "step 5 (stop B) should never have been reached after step 4 failed"
fi
if grep -q '^ssh:sudo -n cephadm shell -- ceph pg .* query' "$fail_trace_file"; then
  fail "no PG query is expected in this scenario at all"
fi
osd3_start_count="$(grep -c '^ssh:sudo systemctl start ceph-.*@osd\.3\.service$' "$fail_trace_file" || true)"
[[ "$osd3_start_count" -ge 2 ]] || fail "expected at least 2 start attempts for osd.3 (the failed one + rollback's retry), got $osd3_start_count"
grep -q '^ssh:sudo systemctl start ceph-.*@osd\.7\.service$' "$fail_trace_file" || fail "rollback should still start osd.7 (B) even though it was never stopped"
unset_count="$(grep -c '^ssh:sudo -n cephadm shell -- ceph osd unset norecover$' "$fail_trace_file" || true)"
[[ "$unset_count" -eq 1 ]] || fail "expected exactly 1 unset norecover call (the defensive rollback branch, since step 6 never ran), got $unset_count"
delete_count="$(grep -c '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-unfound alert-unfound --yes-i-really-really-mean-it' "$fail_trace_file" || true)"
[[ "$delete_count" -eq 1 ]] || fail "rollback pool delete missing after partial inject failure"

fail_result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'object-unfound-*' | sort | tail -1)"
[[ -f "$fail_result_dir/rollback-unset-norecover.txt" ]] || fail "defensive unset-norecover evidence file missing when it should have fired"

ok "object-unfound rollback safety nets retry the failed osd.3 restart and defensively unset norecover when scenario_inject aborts before step 6"
