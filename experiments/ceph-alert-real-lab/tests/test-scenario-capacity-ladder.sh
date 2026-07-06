#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/run/scenario-capacity-ladder.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

# --- Static check: the old fixed 27GiB-raw-used target (real-lab evidence
# showed it was never reachable -- 10 rounds of throttled bench topped out
# around 900MB on this ~900GiB cluster) must not have crept back in.
if grep -q '28991029248' "$SCRIPT"; then
  fail "fixed 27GiB byte literal (28991029248) must not remain in scenario-capacity-ladder.sh"
fi
if grep -q 'CAPACITY_TARGET_RAW_BYTES' "$SCRIPT"; then
  fail "fixed CAPACITY_TARGET_RAW_BYTES target must not remain in scenario-capacity-ladder.sh"
fi
ok "no fixed 27GiB raw-used target remains"

make_fake_jq() {
  local path=$1 real_jq=$2 trace_file=$3
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf 'jq\n' >>"$trace_file"
exec "$real_jq" "\$@"
EOF
  chmod +x "$path"
}

# make_fake_kubectl <path> <trace_file> <nearfull_ratio> <backfillfull_ratio>
#   <full_ratio> [leak_nearfull_on_pager]
# Prometheus always reports all four ladder alerts as firing (matching the
# precedent used by other scenario tests: only the sink log is gated by
# trace state to prove real ordering). The sink log gates each alert's
# "fresh" delivery on the corresponding *dynamic* ratio-set command already
# having run with the value this test computed for the measured
# fullest-OSD utilization, so wait_sink_alert's ordering is a real assertion
# tied to the actual dynamic ratios, not a vacuous one.
make_fake_kubectl() {
  local path=$1 trace_file=$2 nearfull_ratio=$3 backfillfull_ratio=$4 full_ratio=$5 leak_nearfull_on_pager=${6:-}
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
  if grep -q 'ceph osd set-nearfull-ratio $nearfull_ratio\$' "$trace_file"; then
    printf '%s\n' '{"receiver":"slack","alertname":"CephOSDNearFull","labels":{"fresh":"true"}}'
EOF
  if [[ -n "$leak_nearfull_on_pager" ]]; then
    cat >>"$path" <<MIDEOF
    printf '%s\n' '{"receiver":"pager","alertname":"CephOSDNearFull","labels":{"fresh":"true","leak":"true"}}'
MIDEOF
  fi
  cat >>"$path" <<EOF
  fi
  if grep -q 'ceph osd set-backfillfull-ratio $backfillfull_ratio\$' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephOSDBackfillFull","labels":{"fresh":"true"}}'
  fi
  if grep -q 'ceph osd set-full-ratio $full_ratio\$' "$trace_file"; then
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

# make_fake_ssh <path> <trace_file> [util_step_percent=0.3]
# Models `ceph osd df --format json` reporting the FULLEST OSD's utilization
# (a percent, e.g. 0.5 means 0.5%) as (completed "rados bench" rounds so far)
# * util_step_percent -- i.e. it rises with each bench round, gated on the
# trace's bench-call count, exactly like fill_capacity measures it for real.
# `ceph health detail` reports BLUESTORE_SLOW_OP_ALERT until this trace shows
# clear_bluestore_slow_ops's `config set ... bluestore_slow_ops_warn_lifetime
# 1` has already run, modeling the real remediation this scenario's rollback
# depends on.
make_fake_ssh() {
  local path=$1 trace_file=$2 util_step_percent=${3:-0.3}
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
  *"ceph osd df --format json"*)
    rounds=\$(grep -c 'rados bench -p alert-capacity' "$trace_file" || true)
    util=\$(awk -v n="\$rounds" -v step="$util_step_percent" 'BEGIN{printf "%.5f", n*step}')
    printf '{"nodes":[{"id":0,"type":"osd","utilization":%s},{"id":1,"type":"osd","utilization":0}]}\n' "\$util"
    exit 0
    ;;
  *"ceph health detail"*)
    if grep -q 'bluestore_slow_ops_warn_lifetime 1\$' "$trace_file"; then
      printf 'HEALTH_WARN\n'
    else
      printf 'HEALTH_ERR 1 nearfull osd(s) (OSD_NEARFULL); 1 backfillfull osd(s) (OSD_BACKFILLFULL); 1 full osd(s) (OSD_FULL); BLUESTORE_SLOW_OP_ALERT 1 OSD(s) experiencing slow operations\n'
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
  *"ceph osd pool create alert-capacity 8"*|*"ceph osd pool set alert-capacity size 3"*|*"ceph osd pool set alert-capacity min_size 2"*|*"rados bench -p alert-capacity "*"write -b 4194304 -t 64 --no-cleanup"*|*"ceph osd set-nearfull-ratio "*|*"ceph osd set-backfillfull-ratio "*|*"ceph osd set-full-ratio "*|*"ceph config set osd bluestore_slow_ops_warn_lifetime 1"*|*"ceph config set osd bluestore_slow_ops_warn_threshold 1"*|*"ceph config rm osd bluestore_slow_ops_warn_lifetime"*|*"ceph config rm osd bluestore_slow_ops_warn_threshold"*|*"ceph osd pool delete alert-capacity alert-capacity --yes-i-really-really-mean-it"*)
    printf 'ssh-live-noise\n'
    exit 0
    ;;
esac
printf 'unexpected ssh command: %s\n' "\$command" >&2
exit 1
EOF
  chmod +x "$path"
}

# expected_ratio <util_percent> <fraction> mirrors the scenario's own
# ratio_fraction_of so this test derives its expectations the same way the
# implementation does, instead of pasting independently-guessed literals.
expected_ratio() {
  awk -v u="$1" -v f="$2" 'BEGIN{printf "%.5f", (u/100)*f}'
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
caphit_stdout_file="$(mktemp)"
caphit_stderr_file="$(mktemp)"
caphit_trace_file="$(mktemp)"
caphit_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" \
    "$live_stdout_file" "$live_stderr_file" "$live_trace_file" \
    "$leak_stdout_file" "$leak_stderr_file" "$leak_trace_file" \
    "$setupfail_stdout_file" "$setupfail_stderr_file" "$setupfail_trace_file" \
    "$caphit_stdout_file" "$caphit_stderr_file" "$caphit_trace_file"
  rm -rf "$fake_bin_dir" "$leak_bin_dir" "$setupfail_bin_dir" "$caphit_bin_dir"
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
PATH="$fake_bin_dir:$PATH" bash "$SCRIPT" >"$stdout_file" 2>"$stderr_file"
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

ok "capacity-ladder destructive ack guard"

# --- Success path: fullest-OSD utilization rises 0.3% -> 0.6% over 2 bench
# rounds, clearing the default CAPACITY_TARGET_OSD_UTIL=0.5% at round 2.
# Measured U = 0.6% (ratio 0.006) drives the three ladder ratios as
# fractions 0.6/0.7/0.8 of U.
util_b=0.6
nearfull_b="$(expected_ratio "$util_b" 0.6)"
backfillfull_b="$(expected_ratio "$util_b" 0.7)"
full_b="$(expected_ratio "$util_b" 0.8)"

rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file" "$nearfull_b" "$backfillfull_b" "$full_b"
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file" 0.3

set +e
PATH="$fake_bin_dir:$PATH" PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$SCRIPT" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/capacity-ladder-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool create alert-capacity 8$' "$live_trace_file" || fail "missing 8-PG pool create"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool set alert-capacity size 3$' "$live_trace_file" || fail "missing pool size set"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd pool set alert-capacity min_size 2$' "$live_trace_file" || fail "missing pool min_size set"
grep -q '^ssh:sudo -n cephadm shell -- rados bench -p alert-capacity 60 write -b 4194304 -t 64 --no-cleanup$' "$live_trace_file" || fail "missing high-concurrency bench round"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd df --format json$' "$live_trace_file" || fail "missing osd df utilization measurement"

# The three ladder ratios must be exactly fraction*U (computed the same way
# the implementation does) and strictly ordered nearfull < backfillfull < full.
grep -q "^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio ${nearfull_b}\$" "$live_trace_file" || fail "missing dynamic nearfull-ratio injection ($nearfull_b)"
grep -q "^ssh:sudo -n cephadm shell -- ceph osd set-backfillfull-ratio ${backfillfull_b}\$" "$live_trace_file" || fail "missing dynamic backfillfull-ratio injection ($backfillfull_b)"
grep -q "^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio ${full_b}\$" "$live_trace_file" || fail "missing dynamic full-ratio injection ($full_b)"
awk -v a="$nearfull_b" -v b="$backfillfull_b" 'BEGIN{exit !(a+0 < b+0)}' || fail "nearfull ratio not below backfillfull ratio"
awk -v a="$backfillfull_b" -v b="$full_b" 'BEGIN{exit !(a+0 < b+0)}' || fail "backfillfull ratio not below full ratio"

# Rollback must restore ceph's stock DEFAULTS (0.95/0.9/0.85), not the
# dynamic injected values, in full -> backfillfull -> nearfull order.
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio 0.95$' "$live_trace_file" || fail "rollback did not restore default full_ratio 0.95"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-backfillfull-ratio 0.9$' "$live_trace_file" || fail "rollback did not restore default backfillfull_ratio 0.9"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio 0.85$' "$live_trace_file" || fail "rollback did not restore default nearfull_ratio 0.85"
grep -q '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-capacity alert-capacity --yes-i-really-really-mean-it' "$live_trace_file" || fail "missing rollback pool delete"

# clear_bluestore_slow_ops must have actually run its remediation (not just
# been a no-op): the heavy fill leaves BLUESTORE_SLOW_OP_ALERT latched (per
# the fake's health-detail gating above), so rollback must age it out via
# the config set/rm pair.
grep -q '^ssh:sudo -n cephadm shell -- ceph config set osd bluestore_slow_ops_warn_lifetime 1$' "$live_trace_file" || fail "rollback did not call clear_bluestore_slow_ops (missing warn_lifetime set)"
grep -q '^ssh:sudo -n cephadm shell -- ceph config set osd bluestore_slow_ops_warn_threshold 1$' "$live_trace_file" || fail "rollback did not call clear_bluestore_slow_ops (missing warn_threshold set)"
grep -q '^ssh:sudo -n cephadm shell -- ceph config rm osd bluestore_slow_ops_warn_lifetime$' "$live_trace_file" || fail "rollback did not restore warn_lifetime default"
grep -q '^ssh:sudo -n cephadm shell -- ceph config rm osd bluestore_slow_ops_warn_threshold$' "$live_trace_file" || fail "rollback did not restore warn_threshold default"

nearfull_inject_line="$(grep -n "^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio ${nearfull_b}\$" "$live_trace_file" | head -1 | cut -d: -f1)"
backfillfull_inject_line="$(grep -n "^ssh:sudo -n cephadm shell -- ceph osd set-backfillfull-ratio ${backfillfull_b}\$" "$live_trace_file" | head -1 | cut -d: -f1)"
full_inject_line="$(grep -n "^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio ${full_b}\$" "$live_trace_file" | head -1 | cut -d: -f1)"
full_rollback_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio 0.95$' "$live_trace_file" | head -1 | cut -d: -f1)"
backfillfull_rollback_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd set-backfillfull-ratio 0.9$' "$live_trace_file" | head -1 | cut -d: -f1)"
nearfull_rollback_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio 0.85$' "$live_trace_file" | head -1 | cut -d: -f1)"
bluestore_clear_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph config rm osd bluestore_slow_ops_warn_threshold$' "$live_trace_file" | head -1 | cut -d: -f1)"
delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-capacity alert-capacity --yes-i-really-really-mean-it' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$nearfull_inject_line" && -n "$backfillfull_inject_line" && -n "$full_inject_line" && -n "$full_rollback_line" && -n "$backfillfull_rollback_line" && -n "$nearfull_rollback_line" && -n "$bluestore_clear_line" && -n "$delete_line" ]] \
  || fail "missing trace lines for ordering checks"
(( backfillfull_inject_line > nearfull_inject_line )) || fail "backfillfull injected before nearfull"
(( full_inject_line > backfillfull_inject_line )) || fail "full injected before backfillfull"
(( full_rollback_line > full_inject_line )) || fail "full-ratio rollback happened before injection completed"
(( backfillfull_rollback_line > full_rollback_line )) || fail "rollback did not restore full before backfillfull"
(( nearfull_rollback_line > backfillfull_rollback_line )) || fail "rollback did not restore backfillfull before nearfull"
(( bluestore_clear_line > nearfull_rollback_line )) || fail "clear_bluestore_slow_ops did not run after ratio restore"
(( delete_line > bluestore_clear_line )) || fail "pool delete happened before clear_bluestore_slow_ops completed"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'capacity-ladder-*' | sort | tail -1)"
[[ -f "$result_dir/measured-fullest-osd-util-percent.txt" ]] || fail "missing measured-fullest-osd-util-percent.txt evidence file"
[[ -f "$result_dir/measured-fullest-osd-util-ratio.txt" ]] || fail "missing measured-fullest-osd-util-ratio.txt evidence file"
[[ -f "$result_dir/sink-absent-check.log" ]] || fail "missing negative-assertion evidence file for pager/CephOSDNearFull absence"
grep -q '"alertname":"CephHealthError"' "$result_dir/sink.log" || fail "missing CephHealthError sink evidence (final ladder rung)"

ok "capacity-ladder 8-PG pool, dynamic ratio ladder ordering, and default-ratio rollback with BlueStore cleanup"

# --- Failure path: pager also (incorrectly) receives CephOSDNearFull. Proves
# assert_sink_absent's failure still lets the EXIT trap run scenario_rollback
# (ratio restore + BlueStore cleanup + pool delete), even though it fires
# mid-ladder (rung 1).
make_fake_jq "$leak_bin_dir/jq" "$real_jq" "$leak_trace_file"
make_fake_kubectl "$leak_bin_dir/kubectl" "$leak_trace_file" "$nearfull_b" "$backfillfull_b" "$full_b" leak
make_fake_curl "$leak_bin_dir/curl" "$leak_trace_file"
make_fake_ssh "$leak_bin_dir/ssh" "$leak_trace_file" 0.3

set +e
PATH="$leak_bin_dir:$PATH" PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$SCRIPT" --yes-really-inject >"$leak_stdout_file" 2>"$leak_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when pager leaks CephOSDNearFull"
grep -q 'FAIL: sink pager unexpectedly received CephOSDNearFull' "$leak_stderr_file" || fail "missing assert_sink_absent failure log for leaked pager CephOSDNearFull"
grep -q '^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio 0.95$' "$leak_trace_file" || fail "rollback ratio restore missing after pager-leak failure"
grep -q '^ssh:sudo -n cephadm shell -- ceph config rm osd bluestore_slow_ops_warn_threshold$' "$leak_trace_file" || fail "rollback BlueStore cleanup missing after pager-leak failure"
grep -q '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-capacity alert-capacity --yes-i-really-really-mean-it' "$leak_trace_file" || fail "rollback pool delete missing after pager-leak failure"
# The leak fires at rung 1, before rungs 2/3 ever inject -- prove the ladder
# actually stopped there instead of continuing regardless of the failure.
if grep -q "^ssh:sudo -n cephadm shell -- ceph osd set-backfillfull-ratio ${backfillfull_b}\$" "$leak_trace_file"; then
  fail "ladder continued to rung 2 despite the rung-1 assert_sink_absent failure"
fi

ok "capacity-ladder halts the ladder and still rolls back (with BlueStore cleanup) when pager leaks CephOSDNearFull at rung 1"

# --- Setup-failure path: fullest-OSD utilization stays at 0% for every
# round (util_step_percent=0), so fill_capacity's implausibility guard fires
# inside scenario_setup instead of ever reaching the ladder. The framework's
# EXIT trap must still run scenario_rollback (ratio restore + pool delete),
# proving a setup failure doesn't leak the pool -- and no ladder ratio was
# ever injected.
make_fake_jq "$setupfail_bin_dir/jq" "$real_jq" "$setupfail_trace_file"
make_fake_kubectl "$setupfail_bin_dir/kubectl" "$setupfail_trace_file" "$nearfull_b" "$backfillfull_b" "$full_b"
make_fake_curl "$setupfail_bin_dir/curl" "$setupfail_trace_file"
make_fake_ssh "$setupfail_bin_dir/ssh" "$setupfail_trace_file" 0

set +e
PATH="$setupfail_bin_dir:$PATH" CAPACITY_MAX_ROUNDS=2 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$SCRIPT" --yes-really-inject >"$setupfail_stdout_file" 2>"$setupfail_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when fullest OSD utilization never rises above implausible"
grep -q 'FATAL: capacity-ladder: fullest OSD utilization implausibly low' "$setupfail_stderr_file" || fail "missing die() message for implausibly-low utilization"
grep -q '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-capacity alert-capacity --yes-i-really-really-mean-it' "$setupfail_trace_file" || fail "rollback pool delete missing after setup failure"
# Dynamic ladder ratios are always formatted to exactly 5 decimal places
# (ratio_fraction_of's `%.5f`); rollback's fixed defaults (0.85/0.9/0.95)
# never match that shape, so this pattern only matches a REAL injection.
if grep -Eq '^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio [0-9]+\.[0-9]{5}$' "$setupfail_trace_file"; then
  fail "ladder injection ran despite setup (fill_capacity) never completing"
fi

ok "capacity-ladder fatals only on implausibly-low utilization, and still deletes the pool via rollback"

# --- Cap-hit-but-not-fatal path: fullest-OSD utilization rises SLOWLY
# (0.01%/round) and never reaches the default 0.5% target within the
# (overridden, small) CAPACITY_MAX_ROUNDS budget -- but it is comfortably
# above the implausibility floor, so this must NOT be fatal. The ladder
# proceeds using whatever utilization was actually measured (0.02% after 2
# rounds), proving the redesign's core guarantee: hitting the round cap
# before the target is not a failure.
util_e=0.02
nearfull_e="$(expected_ratio "$util_e" 0.6)"
backfillfull_e="$(expected_ratio "$util_e" 0.7)"
full_e="$(expected_ratio "$util_e" 0.8)"

make_fake_jq "$caphit_bin_dir/jq" "$real_jq" "$caphit_trace_file"
make_fake_kubectl "$caphit_bin_dir/kubectl" "$caphit_trace_file" "$nearfull_e" "$backfillfull_e" "$full_e"
make_fake_curl "$caphit_bin_dir/curl" "$caphit_trace_file"
make_fake_ssh "$caphit_bin_dir/ssh" "$caphit_trace_file" 0.01

set +e
PATH="$caphit_bin_dir:$PATH" CAPACITY_MAX_ROUNDS=2 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=2 SINK_WAIT_SLEEP=0 \
  bash "$SCRIPT" --yes-really-inject >"$caphit_stdout_file" 2>"$caphit_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "hitting the round cap before the target should not be fatal, got rc=$rc"
grep -q 'FATAL' "$caphit_stderr_file" && fail "cap-hit path must not FATAL"
grep -q "^ssh:sudo -n cephadm shell -- ceph osd set-nearfull-ratio ${nearfull_e}\$" "$caphit_trace_file" || fail "cap-hit path did not derive ladder from the measured (below-target) utilization"
grep -q "^ssh:sudo -n cephadm shell -- ceph osd set-full-ratio ${full_e}\$" "$caphit_trace_file" || fail "cap-hit path did not reach rung 3 with the below-target-derived ratio"
awk -v a="$nearfull_e" -v b="$backfillfull_e" 'BEGIN{exit !(a+0 < b+0)}' || fail "cap-hit nearfull ratio not below backfillfull ratio"
awk -v a="$backfillfull_e" -v b="$full_e" 'BEGIN{exit !(a+0 < b+0)}' || fail "cap-hit backfillfull ratio not below full ratio"
bench_rounds_run="$(grep -c 'rados bench -p alert-capacity' "$caphit_trace_file")"
[[ "$bench_rounds_run" -eq 2 ]] || fail "expected exactly CAPACITY_MAX_ROUNDS=2 bench rounds when the target is never reached, got $bench_rounds_run"

ok "capacity-ladder proceeds (not fatal) when the round cap is hit before the target, deriving the ladder from whatever utilization was measured"
