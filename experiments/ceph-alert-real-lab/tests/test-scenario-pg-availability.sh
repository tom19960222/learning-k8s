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
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephClientBlocked","name":"PG_AVAILABILITY"},"state":"firing"},{"labels":{"alertname":"CephPGUnhealthyStates","name":"alert-pg-availability"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","name":"PG_AVAILABILITY","labels":{"name":"PG_AVAILABILITY"}}'
  if grep -q 'systemctl stop ceph-' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","name":"PG_AVAILABILITY","labels":{"name":"PG_AVAILABILITY","fresh":"true"}}'
    printf '%s\n' '{"receiver":"pager","alertname":"CephPGUnhealthyStates","labels":{"name":"alert-pg-availability"}}'
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
  *"ceph health detail"*)
    printf 'HEALTH_WARN Reduced data availability: 1 pg inactive (PG_AVAILABILITY)\n'
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
  *"ceph osd map alert-pg-availability sentinel --format json"*)
    printf '{"acting":[0,1,2]}\n'
    exit 0
    ;;
  *"ceph osd find 0 --format json"*)
    printf '{"crush_location":{"host":"ceph-lab-osd-01"}}\n'
    exit 0
    ;;
  *"ceph osd find 1 --format json"*)
    printf '{"crush_location":{"host":"ceph-lab-osd-02"}}\n'
    exit 0
    ;;
  *"ceph osd pool create "*|*"ceph osd pool set "*|*"rados -p alert-pg-availability put sentinel /etc/hosts"*|*"ceph osd tree"*|*"systemctl stop ceph-"*|*"systemctl start ceph-"*|*"ceph osd pool delete alert-pg-availability alert-pg-availability --yes-i-really-really-mean-it"*)
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
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" "$live_stdout_file" "$live_stderr_file" "$live_trace_file"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'pg-availability-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-pg-availability.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'pg-availability-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-pg-availability should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'pg-availability requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
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
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-pg-availability.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/pg-availability-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi
grep -q '^ssh:sudo systemctl stop ceph-.*@osd\.0\.service$' "$live_trace_file" || fail "missing stop for osd.0"
grep -q '^ssh:sudo systemctl stop ceph-.*@osd\.1\.service$' "$live_trace_file" || fail "missing stop for osd.1"
grep -q '^ssh:sudo systemctl start ceph-.*@osd\.0\.service$' "$live_trace_file" || fail "missing rollback start for osd.0"
grep -q '^ssh:sudo systemctl start ceph-.*@osd\.1\.service$' "$live_trace_file" || fail "missing rollback start for osd.1"
delete_count="$(grep -c '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-pg-availability alert-pg-availability --yes-i-really-really-mean-it' "$live_trace_file" || true)"
[[ "$delete_count" -eq 1 ]] || fail "expected one delete invocation, got $delete_count"

stop0_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@osd\.0\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
stop1_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@osd\.1\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
start0_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.0\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
start1_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.1\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
delete_line="$(grep -n '^ssh:sudo -n cephadm shell -- .*ceph osd pool delete alert-pg-availability alert-pg-availability --yes-i-really-really-mean-it' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$stop0_line" && -n "$stop1_line" && -n "$start0_line" && -n "$start1_line" && -n "$delete_line" ]] || fail "missing trace lines for ordering checks"
(( start0_line > stop0_line )) || fail "rollback start for osd.0 happened before stop"
(( start1_line > stop1_line )) || fail "rollback start for osd.1 happened before stop"
(( delete_line > start0_line && delete_line > start1_line )) || fail "pool delete should happen after restarting stopped OSDs"

# prometheus_alert_is_firing writes prometheus-alerts-<alertname>-<label|none>.json
# keyed on the CALLER's requested alertname/label, not the fake endpoint's response
# body -- its existence proves the scenario itself issued a wait_prometheus_alert
# call for CephPGUnhealthyStates scoped to the $POOL pool name.
result_dir="$ROOT/results/$(basename "$(sed -n 's/^result: //p' "$live_stdout_file")")"
[[ -f "$result_dir/prometheus-alerts-CephPGUnhealthyStates-name.json" ]] || fail "missing CephPGUnhealthyStates prometheus wait evidence"
grep -q 'PASS: sink pager received CephPGUnhealthyStates name=alert-pg-availability' "$live_stderr_file" || fail "missing evidence that pager received CephPGUnhealthyStates for alert-pg-availability"

ok "pg-availability destructive ack guard"
