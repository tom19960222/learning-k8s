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
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephOSDDaemonDownScoped","ceph_daemon":"osd.0","hostname":"ceph-lab-osd-01"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"pager","alertname":"CephOSDDaemonDownScoped","labels":{"ceph_daemon":"osd.0"}}'
  if grep -q 'systemctl stop ceph-' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephOSDDaemonDownScoped","labels":{"ceph_daemon":"osd.0","fresh":"true"}}'
    printf '%s\n' '{"receiver":"slack","alertname":"CephOSDDown","labels":{"fresh":"true"}}'
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
  *"ceph osd ls-tree ceph-lab-osd-01"*)
    printf '0\n'
    exit 0
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_WARN 1 osds down (OSD_DOWN)\n'
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
  *"ceph osd tree"*|*"systemctl stop ceph-"*|*"systemctl start ceph-"*)
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

find "$ROOT/results" -maxdepth 1 -type d -name 'osd-daemon-down-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-osd-daemon-down.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'osd-daemon-down-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-osd-daemon-down should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'osd-daemon-down requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
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
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-osd-daemon-down.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/osd-daemon-down-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph osd ls-tree ceph-lab-osd-01$' "$live_trace_file" || fail "missing OSD discovery via ls-tree"
grep -q '^ssh:sudo systemctl stop ceph-.*@osd\.0\.service$' "$live_trace_file" || fail "missing stop for osd.0"
grep -q '^ssh:sudo systemctl start ceph-.*@osd\.0\.service$' "$live_trace_file" || fail "missing rollback start for osd.0"

discover_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd ls-tree ceph-lab-osd-01$' "$live_trace_file" | head -1 | cut -d: -f1)"
stop_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@osd\.0\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
start_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@osd\.0\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$discover_line" && -n "$stop_line" && -n "$start_line" ]] || fail "missing trace lines for ordering checks"
(( stop_line > discover_line )) || fail "stop happened before OSD discovery"
(( start_line > stop_line )) || fail "rollback start happened before stop"

# assert_prometheus_alert_not_firing always writes prometheus-alerts-<alertname>-<label_name|none>.json
# via prometheus_alert_is_firing, regardless of the firing outcome. Assert the file exists to prove
# the not-firing check for CephOSDHostDownScoped actually ran (a vacuous/never-called assertion would
# also pass the "not firing" check but would leave no evidence file behind).
result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'osd-daemon-down-*' | sort | tail -1)"
[[ -f "$result_dir/prometheus-alerts-CephOSDHostDownScoped-hostname.json" ]] || fail "missing negative-assertion evidence file for CephOSDHostDownScoped"

ok "osd-daemon-down destructive ack guard, injection sequence, and rollback ordering"
