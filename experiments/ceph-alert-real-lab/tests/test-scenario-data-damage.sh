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

# make_fake_kubectl's CephDataDamage/CephHealthError alerts and sink
# deliveries only start firing once the scenario's deep-scrub trace line
# exists (which only happens after the objectstore-tool damage + OSD
# restart + PG-active poll have all already succeeded) -- this proves
# scenario_verify genuinely depends on that full sequence, not just on the
# scenario having started.
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
    printf '%s\n' '{"receiver":"pager","alertname":"CephHealthError","labels":{"fresh":"true"}}'
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
#   - cluster health reports OSD_SCRUB_ERRORS/PG_DAMAGED whenever a
#     deep-scrub has run more times than a repair (i.e. damage was
#     introduced and not yet repaired).
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
    printf '{"nodes":[{"id":5,"name":"osd.5","type":"osd","status":"%s"}]}\n' "\$status"
    exit 0
    ;;
  *"ceph-objectstore-tool --data-path /var/lib/ceph/osd/ceph-5 --pgid 3.0 victim remove"*)
    if [[ "\${FAKE_OBJECTSTORE_TOOL_FAIL:-0}" == "1" ]]; then
      printf 'simulated ceph-objectstore-tool failure\n' >&2
      exit 1
    fi
    printf 'objectstore-tool-live-noise\n'
    exit 0
    ;;
  *"ceph pg 3.0 query --format json"*)
    printf '{"state":"active+clean"}\n'
    exit 0
    ;;
  *"ceph health detail"*)
    deep_scrubs=\$(grep -c 'ceph pg deep-scrub 3\.0' "$trace_file" || true)
    repairs=\$(grep -c 'ceph pg repair 3\.0' "$trace_file" || true)
    if [[ "\$deep_scrubs" -gt "\$repairs" ]]; then
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

# --- Success path: stop osd.5, objectstore-tool remove, restart, poll PG
# active, deep-scrub, verify, then repair + rollback.
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
grep -q '^ssh:sudo cephadm shell --name osd\.5 -- ceph-objectstore-tool --data-path /var/lib/ceph/osd/ceph-5 --pgid 3\.0 victim remove$' "$live_trace_file" || fail "missing ceph-objectstore-tool invocation on the OSD's own host"
start_count="$(grep -c '^ssh:sudo systemctl start ceph-.*@osd\.5\.service$' "$live_trace_file" || true)"
[[ "$start_count" -ge 1 ]] || fail "missing restart for osd.5"
grep -q '^ssh:sudo -n cephadm shell -- ceph pg 3\.0 query --format json$' "$live_trace_file" || fail "missing PG-active poll after restart"
grep -q '^ssh:sudo -n cephadm shell -- ceph pg deep-scrub 3\.0$' "$live_trace_file" || fail "missing deep-scrub trigger"
grep -q '^ssh:sudo -n cephadm shell -- ceph pg repair 3\.0$' "$live_trace_file" || fail "missing rollback pg repair"
delete_count="$(grep -c '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-damage alert-damage --yes-i-really-really-mean-it' "$live_trace_file" || true)"
[[ "$delete_count" -eq 1 ]] || fail "expected one delete invocation, got $delete_count"

stop_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@osd\.5\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
objtool_line="$(grep -n '^ssh:sudo cephadm shell --name osd\.5 -- ceph-objectstore-tool' "$live_trace_file" | head -1 | cut -d: -f1)"
start_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.5\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
scrub_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph pg deep-scrub 3\.0$' "$live_trace_file" | head -1 | cut -d: -f1)"
repair_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph pg repair 3\.0$' "$live_trace_file" | head -1 | cut -d: -f1)"
delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-damage alert-damage --yes-i-really-really-mean-it' "$live_trace_file" | head -1 | cut -d: -f1)"
[[ -n "$stop_line" && -n "$objtool_line" && -n "$start_line" && -n "$scrub_line" && -n "$repair_line" && -n "$delete_line" ]] || fail "missing trace lines for ordering checks"
(( objtool_line > stop_line )) || fail "objectstore-tool ran before the OSD was stopped"
(( start_line > objtool_line )) || fail "OSD restart happened before objectstore-tool ran"
(( scrub_line > start_line )) || fail "deep-scrub requested before the OSD restart"
(( repair_line > scrub_line )) || fail "rollback repair happened before the injected deep-scrub"
(( delete_line > repair_line )) || fail "pool delete happened before rollback repair"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'data-damage-*' | sort | tail -1)"
[[ -f "$result_dir/objectstore-tool-remove.txt" ]] || fail "missing objectstore-tool evidence file"
grep -q '# exit_code: 0' "$result_dir/objectstore-tool-remove.txt" || fail "objectstore-tool evidence missing successful exit code"

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
