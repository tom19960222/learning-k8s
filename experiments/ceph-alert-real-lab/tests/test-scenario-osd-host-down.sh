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
  local alerts_json=${3:-'{"data":{"alerts":[{"labels":{"alertname":"CephOSDHostDownScoped","hostname":"ceph-lab-osd-02"},"state":"firing"}]}}'}
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
if [[ "\$*" == *"get pod -l app=prometheus -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'prometheus-0\n'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  printf '%s\n' '$alerts_json'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"pager","alertname":"CephOSDHostDownScoped","labels":{"hostname":"ceph-lab-osd-02"}}'
  if grep -q 'systemctl stop ceph-' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephOSDHostDownScoped","labels":{"hostname":"ceph-lab-osd-02","fresh":"true"}}'
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
  *"ceph osd ls-tree ceph-lab-osd-02"*)
    printf '3\n4\n5\n'
    exit 0
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_WARN 3 osds down (OSD_DOWN); 1 host (3 osds) down (OSD_HOST_DOWN)\n'
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

find "$ROOT/results" -maxdepth 1 -type d -name 'osd-host-down-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-osd-host-down.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'osd-host-down-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-osd-host-down should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'osd-host-down requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
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
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-osd-host-down.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/osd-host-down-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -q '^ssh:sudo -n cephadm shell -- ceph osd ls-tree ceph-lab-osd-02$' "$live_trace_file" || fail "missing OSD discovery via ls-tree"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'osd-host-down-*' | sort | tail -1)"
target_file="$result_dir/target-osds.txt"
[[ -f "$target_file" ]] || fail "missing target-osds.txt evidence file"
[[ "$(cat "$target_file")" == $'3\n4\n5' ]] || fail "target-osds.txt content mismatch: $(cat "$target_file" 2>/dev/null)"

# assert_prometheus_alert_not_firing always writes prometheus-alerts-<alertname>-<label_name|none>.json
# via prometheus_alert_is_firing, regardless of the firing outcome. Assert the file exists to prove
# the not-firing check for CephOSDDaemonDownScoped actually ran for the per-OSD loop. NOTE: the
# filename pattern keys on label_name ("ceph_daemon"), not label_value ("osd.3"/"osd.4"/"osd.5"), so
# all three per-OSD checks overwrite this single file rather than producing three distinct files.
[[ -f "$result_dir/prometheus-alerts-CephOSDDaemonDownScoped-ceph_daemon.json" ]] || fail "missing negative-assertion evidence file for CephOSDDaemonDownScoped"

discover_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph osd ls-tree ceph-lab-osd-02$' "$live_trace_file" | head -1 | cut -d: -f1)"

for osd in 3 4 5; do
  grep -q "^ssh:sudo systemctl stop ceph-.*@osd\\.${osd}\\.service\$" "$live_trace_file" || fail "missing stop for osd.$osd"
  grep -q "^ssh:sudo systemctl start ceph-.*@osd\\.${osd}\\.service\$" "$live_trace_file" || fail "missing rollback start for osd.$osd"

  stop_line="$(grep -n "^ssh:sudo systemctl stop ceph-.*@osd\\.${osd}\\.service\$" "$live_trace_file" | head -1 | cut -d: -f1)"
  start_line="$(grep -n "^ssh:sudo systemctl start ceph-.*@osd\\.${osd}\\.service\$" "$live_trace_file" | head -1 | cut -d: -f1)"

  [[ -n "$stop_line" && -n "$start_line" ]] || fail "missing trace lines for osd.$osd ordering checks"
  (( stop_line > discover_line )) || fail "stop for osd.$osd happened before OSD discovery"
  (( start_line > stop_line )) || fail "rollback start for osd.$osd happened before stop"
done

ok "osd-host-down destructive ack guard, injection sequence, and rollback ordering"

# --- Failure path: scenario_verify never observes CephOSDHostDownScoped firing ->
# scenario_main's EXIT trap must still run scenario_rollback, which re-reads
# target-osds.txt and issues "systemctl start" for every discovered OSD (3, 4, 5).
# PROMETHEUS_WAIT_ATTEMPTS=1 / PROMETHEUS_WAIT_SLEEP=0 keep the doomed wait_prometheus_alert
# poll from retrying (would otherwise sleep 5s x 60 attempts before failing).
make_fake_jq "$fail_bin_dir/jq" "$real_jq" "$fail_trace_file"
make_fake_kubectl "$fail_bin_dir/kubectl" "$fail_trace_file" '{"data":{"alerts":[]}}'
make_fake_curl "$fail_bin_dir/curl" "$fail_trace_file"
make_fake_ssh "$fail_bin_dir/ssh" "$fail_trace_file"

set +e
PATH="$fail_bin_dir:$PATH" PROMETHEUS_WAIT_ATTEMPTS=1 PROMETHEUS_WAIT_SLEEP=0 SINK_WAIT_ATTEMPTS=1 SINK_WAIT_SLEEP=0 \
  bash "$ROOT/run/scenario-osd-host-down.sh" --yes-really-inject >"$fail_stdout_file" 2>"$fail_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when CephOSDHostDownScoped never fires"

for osd in 3 4 5; do
  grep -q "^ssh:sudo systemctl start ceph-.*@osd\\.${osd}\\.service\$" "$fail_trace_file" || fail "rollback start missing for osd.$osd after failed verify"
done

ok "osd-host-down rollback restarts all three OSDs when scenario_verify never observes CephOSDHostDownScoped"
