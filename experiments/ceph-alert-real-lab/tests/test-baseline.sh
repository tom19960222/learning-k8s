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

# make_fake_kubectl's "logs deploy/alert-sink" case models the real
# Watchdog behavior: it fires continuously (`vector(1)`, `repeat_interval:
# 1m` in the lab route), so a fresh heartbeat line genuinely accrues between
# record_sink_checkpoint's read and wait_sink_alert's first poll. A static
# response present from the very first call would already be counted at
# checkpoint time (before the "line count" baseline is taken), making the
# "NR > start" new-lines filter never see it as new -- so this fake counts
# calls and only starts emitting the Watchdog row from the second call
# onward, exactly like a heartbeat that arrives just after the checkpoint.
make_fake_kubectl() {
  local path=$1 trace_file=$2
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
if [[ "\$*" == *"-n rook-ceph-external get cephcluster -o wide"* ]]; then
  printf '%s\n' 'rook-ceph-external Connected HEALTH_OK'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  count_file="${trace_file}.sinkcalls"
  count=0
  [[ -f "\$count_file" ]] && count="\$(cat "\$count_file")"
  count=\$((count + 1))
  printf '%s' "\$count" >"\$count_file"
  if [[ "\$count" -ge 2 ]]; then
    printf '%s\n' '{"receiver":"watchdog","alertname":"Watchdog","labels":{}}'
  fi
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
  *"ceph -s"*)
    printf 'HEALTH_OK\n'
    exit 0
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_OK\n'
    exit 0
    ;;
  *"ceph osd tree"*)
    printf 'ssh-live-noise\n'
    exit 0
    ;;
  *"quorum_status --format json"*)
    printf '{"quorum":[0,1,2]}\n'
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
live_trace_file="$(mktemp)"
fake_bin_dir="$(mktemp -d)"
real_jq="$(command -v jq)"

cleanup() {
  rm -f "$stdout_file" "$stderr_file" "$live_trace_file" "${live_trace_file}.sinkcalls"
  rm -rf "$fake_bin_dir"
}

trap cleanup EXIT

make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$live_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$live_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$live_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$live_trace_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/baseline.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected baseline.sh to succeed, got $rc"
stdout_lines="$(wc -l <"$stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^baseline: .*/results/baseline-[^/]+$' "$stdout_file" || fail "missing baseline result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$stdout_file"; then
  fail "live command stdout leaked into baseline stdout"
fi

result_dir="$ROOT/results/$(basename "$(sed -n 's/^baseline: //p' "$stdout_file")")"
[[ -f "$result_dir/sink-checkpoint-lines.txt" ]] || fail "missing sink checkpoint evidence"
grep -q 'PASS: sink watchdog received Watchdog =' "$stderr_file" || fail "missing evidence that the Watchdog heartbeat reached the sink post-deploy"

ok "baseline.sh asserts the Watchdog heartbeat reaches the sink after collecting baseline evidence"
