#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

# --- Static source checks: pin the *shape* of the content-corruption fix so
# a future edit can't silently reintroduce the remove-based injection (which
# races with PG recovery -- see the SAFETY comment at the top of
# run/scenario-data-damage.sh) or drop the active+clean gate / scrub
# re-issue guard it depends on. These run before any fixture/process is set
# up and fail RED against the old remove-based script.
scenario_script="$ROOT/run/scenario-data-damage.sh"
grep -Fq 'set-bytes' "$scenario_script" || fail "scenario no longer injects via ceph-objectstore-tool set-bytes"
# shellcheck disable=SC2016
# Intentional single-quoted literal grep pattern -- matching the scenario
# script's own literal source text (including its unexpanded $OBJECT), not
# expanding anything in this test script.
if grep -Eq '(\$OBJECT|victim) remove\b' "$scenario_script"; then
  fail "scenario must not inject via ceph-objectstore-tool remove (races with PG recovery, see task-19 fix-round-1 report)"
fi
grep -Fq 'pg_query_state_contains "active+clean"' "$scenario_script" || fail "scenario must wait for active+clean (not just active) before deep-scrub"
grep -Fq 'deep_scrub_wait_with_reissue' "$scenario_script" || fail "scenario must re-issue deep-scrub if OSD_SCRUB_ERRORS is slow to appear"
# shellcheck disable=SC2016
# Same reasoning: matching the scenario script's literal unexpanded $PGID.
grep -Fq 'ceph pg repair $PGID' "$scenario_script" || fail "rollback must still run ceph pg repair"
ok "static source checks: set-bytes injection, active+clean gate, scrub reissue, pg repair rollback"

make_fake_jq() {
  local path=$1 real_jq=$2 trace_file=$3
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf 'jq\n' >>"$trace_file"
exec "$real_jq" "\$@"
EOF
  chmod +x "$path"
}

# make_fake_kubectl's CephDataDamage alert and sink delivery only start
# firing once the scenario's deep-scrub trace line exists (which only
# happens after the objectstore-tool damage + OSD restart + PG-active poll
# have all already succeeded) -- this proves scenario_verify genuinely
# depends on that full sequence, not just on the scenario having started.
# CephHealthError is deliberately not modeled here: real-lab evidence showed
# it flickers PENDING->ERR->WARN for this fault type and never fires within
# for:5m, and scenario-data-damage.sh no longer asserts it (see that
# script's scenario_verify comment; CephHealthError -> pager is validated by
# scenario-capacity-ladder.sh instead).
make_fake_kubectl() {
  local path=$1 trace_file=$2
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
scrubbed=\$(grep -c 'ceph pg deep-scrub 3\.0' "$trace_file" || true)
if [[ "\$*" == *"get pod -l app=prometheus -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'prometheus-0\n'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  if [[ "\$scrubbed" -ge 1 ]]; then
    printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephDataDamage"},"state":"firing"}]}}'
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
  if [[ "\$scrubbed" -ge 1 ]]; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephDataDamage","labels":{"fresh":"true"}}'
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

# osd.5 up/down state and cluster health/damage state are both derived
# purely from counts in the trace file, so a single fixture can answer every
# poll correctly across the whole scenario:
#   - osd.5 is down whenever it has more systemctl stops than starts.
#   - cluster health reports OSD_SCRUB_ERRORS/PG_DAMAGED once at least 2
#     deep-scrub requests have been issued (and no repair has run yet).
#     Requiring 2 (not 1) models a deep-scrub whose first request gets
#     deferred by ceph's scrub scheduler -- OSD_SCRUB_ERRORS only actually
#     surfaces once the scenario's own re-issue-on-timeout path
#     (deep_scrub_wait_with_reissue in run/scenario-data-damage.sh) has
#     re-requested it, exercising that path rather than assuming the first
#     request always lands. Any `pg repair` call unconditionally clears
#     health back to HEALTH_OK (see the "ceph health detail" case below).
# FAKE_OBJECTSTORE_TOOL_FAIL=1 makes the ceph-objectstore-tool invocation
# itself fail, for the "scenario_inject fails partway" rollback test.
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
  *"ceph osd map alert-damage victim --format json"*)
    printf '{"pgid":"3.0","acting":[2,5,8]}\n'
    exit 0
    ;;
  *"ceph osd find 5 --format json"*)
    printf '{"crush_location":{"host":"ceph-lab-osd-02"}}\n'
    exit 0
    ;;
  *"ceph osd tree --format json"*)
    stops=\$(grep -c 'systemctl stop ceph-.*@osd\.5\.service' "$trace_file" || true)
    starts=\$(grep -c 'systemctl start ceph-.*@osd\.5\.service' "$trace_file" || true)
    if [[ "\$stops" -gt "\$starts" ]]; then
      status=down
    else
      status=up
    fi
    # Real cephadm shell prints this 4-line banner to STDERR on every
    # invocation (fsid/config inference + image pull info); it is NOT
    # '#'-prefixed. Modeling it here regression-tests that the JSON poll
    # helper parses stdout only and never merges this banner into the JSON.
    printf 'Inferring fsid 0c9bf37e-514a-11f1-b72a-bc24113f1375\n' >&2
    printf 'Inferring config /var/lib/ceph/0c9bf37e-514a-11f1-b72a-bc24113f1375/mon.ceph-lab-mon-01/config\n' >&2
    printf "Using ceph image with id 'abcdef123456' and tag 'v19.2.3' created on 2025-01-01 00:00:00 +0000 UTC\n" >&2
    printf 'quay.io/ceph/ceph@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' >&2
    printf '{"nodes":[{"id":5,"name":"osd.5","type":"osd","status":"%s"}]}\n' "\$status"
    exit 0
    ;;
  *"head -c 65536 /dev/urandom >/tmp/data-damage-garbage && ceph-objectstore-tool --data-path /var/lib/ceph/osd/ceph-5 --pgid 3.0 victim set-bytes /tmp/data-damage-garbage"*)
    if [[ "\${FAKE_OBJECTSTORE_TOOL_FAIL:-0}" == "1" ]]; then
      printf 'simulated ceph-objectstore-tool failure\n' >&2
      exit 1
    fi
    printf 'objectstore-tool-live-noise\n'
    exit 0
    ;;
  *"ceph pg 3.0 query --format json"*)
    # Same cephadm-shell stderr banner as the osd tree poll above -- see that
    # branch's comment for why this is modeled here.
    printf 'Inferring fsid 0c9bf37e-514a-11f1-b72a-bc24113f1375\n' >&2
    printf 'Inferring config /var/lib/ceph/0c9bf37e-514a-11f1-b72a-bc24113f1375/mon.ceph-lab-mon-01/config\n' >&2
    printf "Using ceph image with id 'abcdef123456' and tag 'v19.2.3' created on 2025-01-01 00:00:00 +0000 UTC\n" >&2
    printf 'quay.io/ceph/ceph@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' >&2
    printf '{"state":"active+clean"}\n'
    exit 0
    ;;
  *"ceph health detail"*)
    deep_scrubs=\$(grep -c 'ceph pg deep-scrub 3\.0' "$trace_file" || true)
    repairs=\$(grep -c 'ceph pg repair 3\.0' "$trace_file" || true)
    # A repair always wins and clears health outright (real pg repair
    # fixes the PG; nothing here re-scrubs afterward to reintroduce the
    # error), regardless of how many deep-scrub requests preceded it --
    # this must NOT be a simple deep_scrubs>repairs comparison, since that
    # would keep reporting ERR forever once 2+ scrubs were re-issued (2 > 1
    # repair) and the rollback poll below would never clear.
    if [[ "\$repairs" -ge 1 ]]; then
      printf 'HEALTH_OK\n'
    elif [[ "\$deep_scrubs" -ge 2 ]]; then
      printf 'HEALTH_ERR\n'
      printf '[ERR] OSD_SCRUB_ERRORS: 1 scrub errors\n'
      printf '[ERR] PG_DAMAGED: Possible data damage: 1 pg inconsistent\n'
    else
      printf 'HEALTH_OK\n'
    fi
    exit 0
    ;;
  *"quorum_status --format json"*)
    printf '{"quorum":[0,1,2]}\n'
    exit 0
    ;;
  *"ceph osd pool create "*|*"ceph osd pool set "*|*"rados -p alert-damage put victim /etc/hosts"*|*"ceph pg deep-scrub 3.0"*|*"ceph pg repair 3.0"*|*"ceph osd pool delete "*|*"systemctl stop ceph-"*|*"systemctl start ceph-"*)
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
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" \
    "$live_stdout_file" "$live_stderr_file" "$live_trace_file" \
    "$fail_stdout_file" "$fail_stderr_file" "$fail_trace_file"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'data-damage-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-data-damage.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'data-damage-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-data-damage should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'data-damage requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
[[ ! -s "$no_ack_trace_file" ]] || fail "live-capable commands ran before destructive ack"
cmp -s "$before_dirs_file" "$after_dirs_file" || fail "result dir was created before destructive ack"

# --- Success path: stop osd.5, objectstore-tool set-bytes (content
# corruption), restart, poll PG active+clean, deep-scrub (re-issued once
# per the fixture's deep_scrubs>=2 gate -- see make_fake_ssh's comment
# above), verify, then repair + rollback.
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" \
  DATA_DAMAGE_POLL_ATTEMPTS=5 DATA_DAMAGE_POLL_SLEEP=0 \
  DATA_DAMAGE_PG_POLL_ATTEMPTS=5 DATA_DAMAGE_PG_POLL_SLEEP=0 \
  CEPH_HEALTH_CHECK_ATTEMPTS=5 CEPH_HEALTH_CHECK_SLEEP=0 \
  DATA_DAMAGE_SCRUB_SUBWINDOW_ATTEMPTS=2 DATA_DAMAGE_SCRUB_REISSUE_ROUNDS=4 \
  PROMETHEUS_WAIT_ATTEMPTS=5 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=5 SINK_WAIT_SLEEP=0 \
  DATA_DAMAGE_REPAIR_ATTEMPTS=5 DATA_DAMAGE_REPAIR_SLEEP=0 \
  bash "$ROOT/run/scenario-data-damage.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/data-damage-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|objectstore-tool-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph osd map alert-damage victim --format json$' "$live_trace_file" || fail "missing dynamic osd map"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd find 5 --format json$' "$live_trace_file" || fail "missing osd find for selected non-primary OSD"
grep -q '^ssh:sudo systemctl stop ceph-.*@osd\.5\.service$' "$live_trace_file" || fail "missing stop for osd.5"
expected_corrupt_cmd="sudo -n cephadm shell --name osd.5 -- sh -c 'head -c 65536 /dev/urandom >/tmp/data-damage-garbage && ceph-objectstore-tool --data-path /var/lib/ceph/osd/ceph-5 --pgid 3.0 victim set-bytes /tmp/data-damage-garbage'"
grep -Fxq "ssh:$expected_corrupt_cmd" "$live_trace_file" || fail "missing ceph-objectstore-tool set-bytes invocation on the OSD's own host"
if grep -q 'ceph-objectstore-tool.*victim remove' "$live_trace_file"; then
  fail "injection used ceph-objectstore-tool remove instead of set-bytes (races with PG recovery)"
fi
start_count="$(grep -c '^ssh:sudo systemctl start ceph-.*@osd\.5\.service$' "$live_trace_file" || true)"
[[ "$start_count" -ge 1 ]] || fail "missing restart for osd.5"
grep -q '^ssh:sudo -n cephadm shell -- ceph pg 3\.0 query --format json$' "$live_trace_file" || fail "missing PG-active poll after restart"
scrub_count="$(grep -c '^ssh:sudo -n cephadm shell -- ceph pg deep-scrub 3\.0$' "$live_trace_file" || true)"
[[ "$scrub_count" -ge 2 ]] || fail "expected the deep-scrub to be re-issued at least once, got $scrub_count total"
grep -q '^ssh:sudo -n cephadm shell -- ceph pg repair 3\.0$' "$live_trace_file" || fail "missing rollback pg repair"
delete_count="$(grep -c '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-damage alert-damage --yes-i-really-really-mean-it' "$live_trace_file" || true)"
[[ "$delete_count" -eq 1 ]] || fail "expected one delete invocation, got $delete_count"

stop_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@osd\.5\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
objtool_line="$(grep -Fn "ssh:$expected_corrupt_cmd" "$live_trace_file" | head -1 | cut -d: -f1)"
start_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.5\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
scrub_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph pg deep-scrub 3\.0$' "$live_trace_file" | head -1 | cut -d: -f1)"
last_scrub_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph pg deep-scrub 3\.0$' "$live_trace_file" | tail -1 | cut -d: -f1)"
repair_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph pg repair 3\.0$' "$live_trace_file" | head -1 | cut -d: -f1)"
delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-damage alert-damage --yes-i-really-really-mean-it' "$live_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$stop_line" && -n "$objtool_line" && -n "$start_line" && -n "$scrub_line" && -n "$repair_line" && -n "$delete_line" ]] || fail "missing trace lines for ordering checks"
(( objtool_line > stop_line )) || fail "objectstore-tool ran before the OSD was stopped"
(( start_line > objtool_line )) || fail "OSD restart happened before objectstore-tool ran"
(( scrub_line > start_line )) || fail "deep-scrub requested before the OSD restart"
(( repair_line > last_scrub_line )) || fail "rollback repair happened before the last (re-issued) deep-scrub"
(( delete_line > repair_line )) || fail "pool delete happened before rollback repair"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'data-damage-*' | sort | tail -1)"
[[ -f "$result_dir/objectstore-tool-corrupt.txt" ]] || fail "missing objectstore-tool evidence file"
grep -q '# exit_code: 0' "$result_dir/objectstore-tool-corrupt.txt" || fail "objectstore-tool evidence missing successful exit code"

ok "data-damage destructive ack guard, injection/setup sequence, and rollback ordering"

# --- Failure path: ceph-objectstore-tool itself fails (osd.5 is already
# stopped at this point). This proves the rollback safety-net added
# specifically for this scenario: without an explicit "ensure OSD started"
# step in scenario_rollback, a partial-inject failure here would leave
# osd.5 down forever. Assert scenario_main's EXIT trap still runs
# scenario_rollback, which must still restart osd.5 despite scenario_inject
# never reaching its own restart step.
make_fake_jq "$fail_bin_dir/jq" "$real_jq" "$fail_trace_file"
make_fake_kubectl "$fail_bin_dir/kubectl" "$fail_trace_file"
make_fake_curl "$fail_bin_dir/curl" "$fail_trace_file"
make_fake_ssh "$fail_bin_dir/ssh" "$fail_trace_file"

set +e
PATH="$fail_bin_dir:$PATH" FAKE_OBJECTSTORE_TOOL_FAIL=1 \
  DATA_DAMAGE_POLL_ATTEMPTS=5 DATA_DAMAGE_POLL_SLEEP=0 \
  DATA_DAMAGE_PG_POLL_ATTEMPTS=5 DATA_DAMAGE_PG_POLL_SLEEP=0 \
  CEPH_HEALTH_CHECK_ATTEMPTS=5 CEPH_HEALTH_CHECK_SLEEP=0 \
  PROMETHEUS_WAIT_ATTEMPTS=5 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=5 SINK_WAIT_SLEEP=0 \
  DATA_DAMAGE_REPAIR_ATTEMPTS=5 DATA_DAMAGE_REPAIR_SLEEP=0 \
  bash "$ROOT/run/scenario-data-damage.sh" --yes-really-inject >"$fail_stdout_file" 2>"$fail_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when ceph-objectstore-tool fails"
grep -q '^ssh:sudo systemctl stop ceph-.*@osd\.5\.service$' "$fail_trace_file" || fail "missing initial stop before the simulated objectstore-tool failure"
if grep -q '^ssh:sudo -n cephadm shell -- ceph pg deep-scrub 3\.0$' "$fail_trace_file"; then
  fail "deep-scrub should never have been reached after objectstore-tool failed"
fi
restart_count="$(grep -c '^ssh:sudo systemctl start ceph-.*@osd\.5\.service$' "$fail_trace_file" || true)"
[[ "$restart_count" -ge 1 ]] || fail "rollback safety net did not restart osd.5 after the partial inject failure"
delete_count="$(grep -c '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-damage alert-damage --yes-i-really-really-mean-it' "$fail_trace_file" || true)"
[[ "$delete_count" -eq 1 ]] || fail "rollback pool delete missing after partial inject failure"

ok "data-damage rollback safety net restarts the OSD even when ceph-objectstore-tool itself fails partway through injection"
