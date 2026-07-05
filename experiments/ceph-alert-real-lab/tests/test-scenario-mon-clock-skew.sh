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
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephMonClockSkew"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"watchdog","alertname":"Watchdog","labels":{}}'
  if grep -q "date -s '+2 seconds'" "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephMonClockSkew","labels":{"fresh":"true"}}'
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

# active_line controls which of the three queried time-sync units the fake
# host reports as active: 1 -> systemd-timesyncd, 2 -> chrony, 3 -> chronyd.
# unit_name must match the corresponding stop/start unit the scenario is
# expected to derive from that line number.
make_fake_ssh() {
  local path=$1 trace_file=$2 active_line=${3:-1} unit_name=${4:-systemd-timesyncd}
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
  *"systemctl is-active systemd-timesyncd chrony chronyd 2>/dev/null | grep -nx active | head -1"*)
    printf '${active_line}:active\n'
    exit 0
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_WARN clock skew detected on mon.ceph-lab-mon-03 (MON_CLOCK_SKEW)\n'
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
  *"ceph osd tree"*|*"systemctl stop ${unit_name}"*|*"systemctl start ${unit_name}"*|*"date -s '+2 seconds'"*|*"date -s '-2 seconds'"*)
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
chronyd_stdout_file="$(mktemp)"
chronyd_stderr_file="$(mktemp)"
chronyd_trace_file="$(mktemp)"
chronyd_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$no_ack_trace_file" "$before_dirs_file" "$after_dirs_file" "$live_stdout_file" "$live_stderr_file" "$live_trace_file" "$chronyd_stdout_file" "$chronyd_stderr_file" "$chronyd_trace_file"
  rm -rf "$fake_bin_dir" "$chronyd_bin_dir"
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

find "$ROOT/results" -maxdepth 1 -type d -name 'mon-clock-skew-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-mon-clock-skew.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'mon-clock-skew-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-mon-clock-skew should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'mon-clock-skew requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
[[ ! -s "$stdout_file" ]] || fail "unexpected stdout without destructive ack"
[[ ! -s "$no_ack_trace_file" ]] || fail "live-capable commands ran before destructive ack"
cmp -s "$before_dirs_file" "$after_dirs_file" || fail "result dir was created before destructive ack"

# --- Variant 1: systemd-timesyncd is the active time-sync service.
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file" 1 systemd-timesyncd

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-mon-clock-skew.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment (systemd-timesyncd), got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/mon-clock-skew-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

grep -Fq 'systemctl stop systemd-timesyncd' "$live_trace_file" || fail "missing stop for systemd-timesyncd"
grep -Fq "date -s '+2 seconds'" "$live_trace_file" || fail "missing forward clock skew"
grep -Fq "date -s '-2 seconds'" "$live_trace_file" || fail "missing rollback clock step-back"
grep -Fq 'systemctl start systemd-timesyncd' "$live_trace_file" || fail "missing rollback start for systemd-timesyncd"

stop_line="$(grep -Fn 'systemctl stop systemd-timesyncd' "$live_trace_file" | head -1 | cut -d: -f1)"
skew_line="$(grep -Fn "date -s '+2 seconds'" "$live_trace_file" | head -1 | cut -d: -f1)"
unskew_line="$(grep -Fn "date -s '-2 seconds'" "$live_trace_file" | head -1 | cut -d: -f1)"
start_line="$(grep -Fn 'systemctl start systemd-timesyncd' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$stop_line" && -n "$skew_line" && -n "$unskew_line" && -n "$start_line" ]] || fail "missing trace lines for ordering checks"
(( skew_line > stop_line )) || fail "clock skew happened before stopping time-sync"
(( unskew_line > skew_line )) || fail "rollback clock step-back happened before forward skew"
(( start_line > unskew_line )) || fail "rollback service start happened before clock step-back"

result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'mon-clock-skew-*' | sort | tail -1)"
[[ -f "$result_dir/time-sync-unit.txt" ]] || fail "missing time-sync-unit.txt evidence file"
[[ "$(cat "$result_dir/time-sync-unit.txt")" == "systemd-timesyncd" ]] || fail "time-sync-unit.txt content mismatch: $(cat "$result_dir/time-sync-unit.txt" 2>/dev/null)"

ok "mon-clock-skew destructive ack guard, systemd-timesyncd discovery, and rollback ordering"

# --- Variant 2: chronyd is the active time-sync service (RHEL/CentOS family).
make_fake_jq "$chronyd_bin_dir/jq" "$real_jq" "$chronyd_trace_file"
make_fake_kubectl "$chronyd_bin_dir/kubectl" "$chronyd_trace_file"
make_fake_curl "$chronyd_bin_dir/curl" "$chronyd_trace_file"
make_fake_ssh "$chronyd_bin_dir/ssh" "$chronyd_trace_file" 3 chronyd

set +e
PATH="$chronyd_bin_dir:$PATH" bash "$ROOT/run/scenario-mon-clock-skew.sh" --yes-really-inject >"$chronyd_stdout_file" 2>"$chronyd_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment (chronyd), got $rc"
grep -Fq 'systemctl stop chronyd' "$chronyd_trace_file" || fail "missing stop for chronyd"
grep -Fq 'systemctl start chronyd' "$chronyd_trace_file" || fail "missing rollback start for chronyd"

chronyd_result_dir="$(find "$ROOT/results" -maxdepth 1 -type d -name 'mon-clock-skew-*' | sort | tail -1)"
[[ "$(cat "$chronyd_result_dir/time-sync-unit.txt")" == "chronyd" ]] || fail "time-sync-unit.txt content mismatch for chronyd variant"

ok "mon-clock-skew chronyd time-sync service discovery and rollback"
