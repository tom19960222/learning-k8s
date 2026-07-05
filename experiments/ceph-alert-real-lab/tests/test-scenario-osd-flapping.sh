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
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephOSDFlapping","ceph_daemon":"osd.1","hostname":"ceph-lab-osd-01"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"watchdog","alertname":"Watchdog","labels":{}}'
  starts=\$(grep -c 'systemctl start ceph-.*@osd\.1\.service' "$trace_file" || true)
  if [[ "\$starts" -ge 2 ]]; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephOSDFlapping","labels":{"ceph_daemon":"osd.1","fresh":"true"}}'
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

# make_fake_kubectl_never_fires simulates a real-cluster edge case: the
# transitions land, but CephOSDFlapping's changes() window has not (yet)
# reported firing to Prometheus, and no sink delivery ever shows up either.
# Used to prove scenario_verify's failure still lets scenario_rollback run.
make_fake_kubectl_never_fires() {
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
  printf '%s\n' '{"data":{"alerts":[]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"watchdog","alertname":"Watchdog","labels":{}}'
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

# osd.1 state machine: report "down" whenever this trace file shows more
# stops than starts for osd.1's systemctl unit, "up" otherwise. This lets a
# single fixture answer every `ceph osd tree --format json` poll correctly
# across all four stop/start transitions without any external counters.
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
  *"ceph osd ls-tree ceph-lab-osd-01"*)
    printf '0\n1\n2\n'
    exit 0
    ;;
  *"ceph osd tree --format json"*)
    stops=\$(grep -c 'systemctl stop ceph-.*@osd\.1\.service' "$trace_file" || true)
    starts=\$(grep -c 'systemctl start ceph-.*@osd\.1\.service' "$trace_file" || true)
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
    printf '{"nodes":[{"id":1,"name":"osd.1","type":"osd","status":"%s"}]}\n' "\$status"
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
  *"systemctl stop ceph-"*|*"systemctl start ceph-"*)
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
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" "$live_stdout_file" "$live_stderr_file" "$live_trace_file" "$fail_stdout_file" "$fail_stderr_file" "$fail_trace_file"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'osd-flapping-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-osd-flapping.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'osd-flapping-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-osd-flapping should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'osd-flapping requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
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
PATH="$fake_bin_dir:$PATH" PROMETHEUS_WAIT_ATTEMPTS=2 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  OSD_FLAP_POLL_ATTEMPTS=2 OSD_FLAP_POLL_SLEEP=0 \
  bash "$ROOT/run/scenario-osd-flapping.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/osd-flapping-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph osd ls-tree ceph-lab-osd-01$' "$live_trace_file" || fail "missing OSD discovery via ls-tree"
stop_count="$(grep -c '^ssh:sudo systemctl stop ceph-.*@osd\.1\.service$' "$live_trace_file" || true)"
start_count="$(grep -c '^ssh:sudo systemctl start ceph-.*@osd\.1\.service$' "$live_trace_file" || true)"
[[ "$stop_count" -eq 2 ]] || fail "expected exactly 2 systemctl stop calls for osd.1, got $stop_count"
# 2 transitions-worth of start calls + 1 final rollback safety-net start.
[[ "$start_count" -eq 3 ]] || fail "expected exactly 3 systemctl start calls for osd.1 (2 transitions + rollback), got $start_count"

discover_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd ls-tree ceph-lab-osd-01$' "$live_trace_file" | head -1 | cut -d: -f1)"
stop1_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@osd\.1\.service$' "$live_trace_file" | sed -n '1p' | cut -d: -f1)"
start1_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.1\.service$' "$live_trace_file" | sed -n '1p' | cut -d: -f1)"
stop2_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@osd\.1\.service$' "$live_trace_file" | sed -n '2p' | cut -d: -f1)"
start2_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.1\.service$' "$live_trace_file" | sed -n '2p' | cut -d: -f1)"

[[ -n "$discover_line" && -n "$stop1_line" && -n "$start1_line" && -n "$stop2_line" && -n "$start2_line" ]] || fail "missing trace lines for ordering checks"
(( stop1_line > discover_line )) || fail "first stop happened before OSD discovery"
(( start1_line > stop1_line )) || fail "first start happened before first stop"
(( stop2_line > start1_line )) || fail "second stop happened before first start"
(( start2_line > stop2_line )) || fail "second start happened before second stop"

tree_poll_count="$(grep -c '^ssh:sudo -n cephadm shell -- ceph osd tree --format json$' "$live_trace_file" || true)"
[[ "$tree_poll_count" -ge 4 ]] || fail "expected at least 4 osd tree polls (one per transition), got $tree_poll_count"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'osd-flapping-*' | sort | tail -1)"
[[ -f "$result_dir/osd-tree-poll-1.json" ]] || fail "missing osd-tree-poll-1.json evidence file"
[[ -f "$result_dir/osd-tree-poll-4.json" ]] || fail "missing osd-tree-poll-4.json evidence file"
grep -q '"alertname":"CephOSDFlapping"' "$result_dir/sink.log" || fail "missing CephOSDFlapping entry in captured sink log"
grep -q '"fresh":"true"' "$result_dir/sink.log" || fail "missing fresh (post-transition) pager delivery evidence for CephOSDFlapping"

ok "osd-flapping destructive ack guard, 4-transition injection sequence, and rollback ordering"

# --- Failure path: CephOSDFlapping never reports firing to Prometheus (and
# the sink never delivers it either) -- e.g. the changes() window has not
# caught up yet on a real cluster. Proves scenario_verify's failure still
# lets the EXIT trap run scenario_rollback (the idempotent final start).
make_fake_jq "$fail_bin_dir/jq" "$real_jq" "$fail_trace_file"
make_fake_kubectl_never_fires "$fail_bin_dir/kubectl" "$fail_trace_file"
make_fake_curl "$fail_bin_dir/curl" "$fail_trace_file"
make_fake_ssh "$fail_bin_dir/ssh" "$fail_trace_file"

set +e
PATH="$fail_bin_dir:$PATH" PROMETHEUS_WAIT_ATTEMPTS=1 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=1 SINK_WAIT_SLEEP=0 \
  OSD_FLAP_POLL_ATTEMPTS=2 OSD_FLAP_POLL_SLEEP=0 \
  bash "$ROOT/run/scenario-osd-flapping.sh" --yes-really-inject >"$fail_stdout_file" 2>"$fail_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when CephOSDFlapping never fires"
grep -q 'TIMEOUT: Prometheus alert CephOSDFlapping' "$fail_stderr_file" || fail "missing timeout log for CephOSDFlapping"
final_start_count="$(grep -c '^ssh:sudo systemctl start ceph-.*@osd\.1\.service$' "$fail_trace_file" || true)"
# 2 transition starts + 1 rollback safety-net start, even though verify failed.
[[ "$final_start_count" -eq 3 ]] || fail "rollback safety-net start missing after verify failure, got $final_start_count starts"

ok "osd-flapping still rolls back the OSD when CephOSDFlapping never reaches Prometheus/sink"
