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

# make_fake_kubectl <path> <trace_file> [leak_nearfull_on_pager]
# Prometheus always reports all four ladder alerts as firing (matching the
# precedent used by other scenario tests, e.g. daemon-crash/low-priority-notice:
# only the sink log is gated by trace state to prove real ordering). The sink
# log gates each alert's "fresh" delivery on the corresponding ratio-set
# command already having run, so wait_sink_alert's ordering is a real
# assertion, not a vacuous one.
make_fake_kubectl() {
  local path=$1 trace_file=$2 leak_nearfull_on_pager=${3:-}
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
if [[ "\$*" == *"get pod -l app=prometheus -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'prometheus-0\n'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephOSDNearFull"},"state":"firing"},{"labels":{"alertname":"CephOSDBackfillFull"},"state":"firing"},{"labels":{"alertname":"CephClientBlocked","name":"OSD_FULL"},"state":"firing"},{"labels":{"alertname":"CephHealthError"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"watchdog","alertname":"Watchdog","labels":{}}'
  if grep -q 'ceph osd set-nearfull-ratio 0.02\$' "$trace_file"; then
    printf '%s\n' '{"receiver":"slack","alertname":"CephOSDNearFull","labels":{"fresh":"true"}}'
EOF
  if [[ -n "$leak_nearfull_on_pager" ]]; then
    cat >>"$path" <<MIDEOF
    printf '%s\n' '{"receiver":"pager","alertname":"CephOSDNearFull","labels":{"fresh":"true","leak":"true"}}'
MIDEOF
  fi
  cat >>"$path" <<EOF
  fi
  if grep -q 'ceph osd set-backfillfull-ratio 0.022\$' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephOSDBackfillFull","labels":{"fresh":"true"}}'
  fi
  if grep -q 'ceph osd set-full-ratio 0.025\$' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","labels":{"name":"OSD_FULL","fresh":"true"}}'
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

# make_fake_ssh <path> <trace_file> [raw_used_bytes]
# raw_used_bytes controls `ceph df --format json`'s reported
# stats.total_used_raw_bytes on every call; default clears
# CAPACITY_TARGET_RAW_BYTES on round 1. Pass a value below the target to
# exercise the CAPACITY_MAX_ROUNDS die() path.
make_fake_ssh() {
  local path=$1 trace_file=$2 raw_used_bytes=${3:-30000000000}
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
  *"ceph osd dump --format json"*)
    printf '%s\n' '{"nearfull_ratio":0.87,"backfillfull_ratio":0.91,"full_ratio":0.97}'
    exit 0
    ;;
  *"ceph df --format json"*)
    printf '{"stats":{"total_used_raw_bytes":%s}}\n' "$raw_used_bytes"
    exit 0
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_ERR 1 nearfull osd(s) (OSD_NEARFULL); 1 backfillfull osd(s) (OSD_BACKFILLFULL); 1 full osd(s) (OSD_FULL)\n'
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
  *"ceph osd pool create alert-capacity 1"*|*"ceph osd pool set alert-capacity size 3"*|*"ceph osd pool set alert-capacity min_size 2"*|*"rados -p alert-capacity put sentinel /etc/hosts"*|*"rados bench -p alert-capacity 30 write --no-cleanup"*|*"ceph osd set-nearfull-ratio "*|*"ceph osd set-backfillfull-ratio "*|*"ceph osd set-full-ratio "*|*"ceph osd pool delete alert-capacity alert-capacity --yes-i-really-really-mean-it"*)
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
leak_stdout_file="$(mktemp)"
leak_stderr_file="$(mktemp)"
leak_trace_file="$(mktemp)"
leak_bin_dir="$(mktemp -d)"
setupfail_stdout_file="$(mktemp)"
setupfail_stderr_file="$(mktemp)"
setupfail_trace_file="$(mktemp)"
setupfail_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" \
    "$live_stdout_file" "$live_stderr_file" "$live_trace_file" \
    "$leak_stdout_file" "$leak_stderr_file" "$leak_trace_file" \
    "$setupfail_stdout_file" "$setupfail_stderr_file" "$setupfail_trace_file"
  rm -rf "$fake_bin_dir" "$leak_bin_dir" "$setupfail_bin_dir"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'capacity-ladder-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-capacity-ladder.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'capacity-ladder-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-capacity-ladder should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'capacity-ladder requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
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
PATH="$fake_bin_dir:$PATH" PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$ROOT/run/scenario-capacity-ladder.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/capacity-ladder-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool create alert-capacity 1$' "$live_trace_file" || fail "missing pool create"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd dump --format json$' "$live_trace_file" || fail "missing ratios-before capture"
grep -q '^ssh:sudo -n cephadm shell -- rados bench -p alert-capacity 30 write --no-cleanup$' "$live_trace_file" || fail "missing bench round"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio 0.02$' "$live_trace_file" || fail "missing nearfull-ratio injection"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-backfillfull-ratio 0.022$' "$live_trace_file" || fail "missing backfillfull-ratio injection"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio 0.025$' "$live_trace_file" || fail "missing full-ratio injection"

# Rollback must restore the RECORDED ratios (0.87/0.91/0.97 from the fixture
# above), not the fallback defaults (0.85/0.90/0.95), and in full ->
# backfillfull -> nearfull order.
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio 0.97$' "$live_trace_file" || fail "rollback did not restore recorded full_ratio"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-backfillfull-ratio 0.91$' "$live_trace_file" || fail "rollback did not restore recorded backfillfull_ratio"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio 0.87$' "$live_trace_file" || fail "rollback did not restore recorded nearfull_ratio"
grep -q '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-capacity alert-capacity --yes-i-really-really-mean-it' "$live_trace_file" || fail "missing rollback pool delete"

nearfull_inject_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio 0.02$' "$live_trace_file" | head -1 | cut -d: -f1)"
backfillfull_inject_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd set-backfillfull-ratio 0.022$' "$live_trace_file" | head -1 | cut -d: -f1)"
full_inject_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio 0.025$' "$live_trace_file" | head -1 | cut -d: -f1)"
full_rollback_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio 0.97$' "$live_trace_file" | head -1 | cut -d: -f1)"
backfillfull_rollback_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd set-backfillfull-ratio 0.91$' "$live_trace_file" | head -1 | cut -d: -f1)"
nearfull_rollback_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio 0.87$' "$live_trace_file" | head -1 | cut -d: -f1)"
delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-capacity alert-capacity --yes-i-really-really-mean-it' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$nearfull_inject_line" && -n "$backfillfull_inject_line" && -n "$full_inject_line" && -n "$full_rollback_line" && -n "$backfillfull_rollback_line" && -n "$nearfull_rollback_line" && -n "$delete_line" ]] \
  || fail "missing trace lines for ordering checks"
(( backfillfull_inject_line > nearfull_inject_line )) || fail "backfillfull injected before nearfull"
(( full_inject_line > backfillfull_inject_line )) || fail "full injected before backfillfull"
(( full_rollback_line > full_inject_line )) || fail "full-ratio rollback happened before injection completed"
(( backfillfull_rollback_line > full_rollback_line )) || fail "rollback did not restore full before backfillfull"
(( nearfull_rollback_line > backfillfull_rollback_line )) || fail "rollback did not restore backfillfull before nearfull"
(( delete_line > nearfull_rollback_line )) || fail "pool delete happened before ratio restore completed"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'capacity-ladder-*' | sort | tail -1)"
[[ -f "$result_dir/ratios-before.json" ]] || fail "missing ratios-before.json evidence file"
[[ -f "$result_dir/sink-absent-check.log" ]] || fail "missing negative-assertion evidence file for pager/CephOSDNearFull absence"
grep -q '"alertname":"CephHealthError"' "$result_dir/sink.log" || fail "missing CephHealthError sink evidence (final ladder rung)"

ok "capacity-ladder destructive ack guard, 3-rung ladder ordering, and recorded-ratio rollback"

# --- Failure path: pager also (incorrectly) receives CephOSDNearFull. Proves
# assert_sink_absent's failure still lets the EXIT trap run scenario_rollback
# (ratio restore + pool delete), even though it fires mid-ladder (rung 1).
make_fake_jq "$leak_bin_dir/jq" "$real_jq" "$leak_trace_file"
make_fake_kubectl "$leak_bin_dir/kubectl" "$leak_trace_file" leak
make_fake_curl "$leak_bin_dir/curl" "$leak_trace_file"
make_fake_ssh "$leak_bin_dir/ssh" "$leak_trace_file"

set +e
PATH="$leak_bin_dir:$PATH" PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$ROOT/run/scenario-capacity-ladder.sh" --yes-really-inject >"$leak_stdout_file" 2>"$leak_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when pager leaks CephOSDNearFull"
grep -q 'FAIL: sink pager unexpectedly received CephOSDNearFull' "$leak_stderr_file" || fail "missing assert_sink_absent failure log for leaked pager CephOSDNearFull"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio 0.97$' "$leak_trace_file" || fail "rollback ratio restore missing after pager-leak failure"
grep -q '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-capacity alert-capacity --yes-i-really-really-mean-it' "$leak_trace_file" || fail "rollback pool delete missing after pager-leak failure"
# The leak fires at rung 1, before rungs 2/3 ever inject -- prove the ladder
# actually stopped there instead of continuing regardless of the failure.
if grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-backfillfull-ratio 0.022$' "$leak_trace_file"; then
  fail "ladder continued to rung 2 despite the rung-1 assert_sink_absent failure"
fi

ok "capacity-ladder halts the ladder and still rolls back when pager leaks CephOSDNearFull at rung 1"

# --- Setup-failure path: raw used bytes never reach CAPACITY_TARGET_RAW_BYTES,
# so fill_capacity's die() fires inside scenario_setup. The framework's EXIT
# trap must still run scenario_rollback (ratio restore + pool delete), proving
# a setup failure doesn't leak the pool.
make_fake_jq "$setupfail_bin_dir/jq" "$real_jq" "$setupfail_trace_file"
make_fake_kubectl "$setupfail_bin_dir/kubectl" "$setupfail_trace_file"
make_fake_curl "$setupfail_bin_dir/curl" "$setupfail_trace_file"
make_fake_ssh "$setupfail_bin_dir/ssh" "$setupfail_trace_file" 1000

set +e
PATH="$setupfail_bin_dir:$PATH" CAPACITY_MAX_ROUNDS=1 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$ROOT/run/scenario-capacity-ladder.sh" --yes-really-inject >"$setupfail_stdout_file" 2>"$setupfail_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when raw used bytes never reach the capacity target"
grep -q 'FATAL: capacity-ladder: raw used bytes did not reach' "$setupfail_stderr_file" || fail "missing die() message for unreached capacity target"
grep -q '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-capacity alert-capacity --yes-i-really-really-mean-it' "$setupfail_trace_file" || fail "rollback pool delete missing after setup failure"
if grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio 0.02$' "$setupfail_trace_file"; then
  fail "ladder injection ran despite setup (fill_capacity) never completing"
fi

ok "capacity-ladder still deletes the pool via rollback when fill_capacity's round budget is exhausted"
