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
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephMonDiskLow"},"state":"firing"},{"labels":{"alertname":"CephMonDiskCritical"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  if grep -q 'ceph config set mon mon_data_avail_warn' "$trace_file"; then
    printf '%s\n' '{"receiver":"slack","alertname":"CephMonDiskLow","labels":{}}'
  fi
  if grep -q 'ceph config set mon mon_data_avail_crit' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephMonDiskCritical","labels":{"fresh":"true"}}'
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

# make_fake_ssh <path> <trace_file> [used_pct]
# used_pct defaults to 18 (matches the design spec's observed ~82% free on
# mon-01), producing warn_threshold=85 / crit_threshold=83.
make_fake_ssh() {
  local path=$1 trace_file=$2 used_pct="${3:-18}"
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
  "df --output=pcent /var/lib/ceph")
    printf 'Use%%\n'
    printf ' ${used_pct}%%\n'
    exit 0
    ;;
  *"ceph health detail"*)
    printf 'HEALTH_ERR 1 mons low on available space (MON_DISK_LOW); 1 mons very low on available space (MON_DISK_CRIT)\n'
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
  *"ceph osd tree"*|*"ceph config set mon mon_data_avail_warn "*|*"ceph config set mon mon_data_avail_crit "*|*"ceph config rm mon mon_data_avail_crit"*|*"ceph config rm mon mon_data_avail_warn"*)
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

find "$ROOT/results" -maxdepth 1 -type d -name 'mon-disk-low-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-mon-disk-low.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'mon-disk-low-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-mon-disk-low should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'mon-disk-low requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
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
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-mon-disk-low.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/mon-disk-low-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi

result_dir_path="$ROOT/results/$(basename "$(sed -n 's/^result: //p' "$live_stdout_file")")"

grep -q '^ssh:df --output=pcent /var/lib/ceph$' "$live_trace_file" || fail "missing host-level df threshold derivation"
grep -q 'used_pct=18' "$result_dir_path/mon-disk-thresholds.env" || fail "missing derived used_pct in thresholds evidence"
grep -q 'free_pct=82' "$result_dir_path/mon-disk-thresholds.env" || fail "missing derived free_pct in thresholds evidence"
grep -q 'warn_threshold=85' "$result_dir_path/mon-disk-thresholds.env" || fail "missing derived warn_threshold in thresholds evidence"
grep -q 'crit_threshold=83' "$result_dir_path/mon-disk-thresholds.env" || fail "missing derived crit_threshold in thresholds evidence"

grep -q '^ssh:sudo -n cephadm shell -- ceph config set mon mon_data_avail_warn 85$' "$live_trace_file" || fail "missing warn threshold config set"
grep -q '^ssh:sudo -n cephadm shell -- ceph config set mon mon_data_avail_crit 83$' "$live_trace_file" || fail "missing crit threshold config set"
grep -q '^ssh:sudo -n cephadm shell -- ceph config rm mon mon_data_avail_crit$' "$live_trace_file" || fail "missing rollback config rm crit"
grep -q '^ssh:sudo -n cephadm shell -- ceph config rm mon mon_data_avail_warn$' "$live_trace_file" || fail "missing rollback config rm warn"

warn_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph config set mon mon_data_avail_warn 85$' "$live_trace_file" | head -1 | cut -d: -f1)"
crit_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph config set mon mon_data_avail_crit 83$' "$live_trace_file" | head -1 | cut -d: -f1)"
rm_crit_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph config rm mon mon_data_avail_crit$' "$live_trace_file" | head -1 | cut -d: -f1)"
rm_warn_line="$(grep -n '^ssh:sudo -n cephadm shell -- ceph config rm mon mon_data_avail_warn$' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$warn_line" && -n "$crit_line" && -n "$rm_crit_line" && -n "$rm_warn_line" ]] || fail "missing trace lines for ordering checks"
(( crit_line > warn_line )) || fail "crit threshold was set before warn threshold (phase 1 must complete first)"
(( rm_crit_line > crit_line )) || fail "rollback ran before crit threshold was set"
(( rm_warn_line > rm_crit_line )) || fail "rollback config rm order should be crit then warn"

# Prometheus's evidence filename is keyed on the CALLER's requested
# alertname/label, not on the fake endpoint's response body -- so its mere
# existence proves the scenario itself issued a wait_prometheus_alert call
# for that exact alertname (a static fake response alone cannot fake this).
[[ -f "$result_dir_path/prometheus-alerts-CephMonDiskLow-none.json" ]] || fail "missing CephMonDiskLow prometheus wait evidence"
[[ -f "$result_dir_path/prometheus-alerts-CephMonDiskCritical-none.json" ]] || fail "missing CephMonDiskCritical prometheus wait evidence"

grep -q 'PASS: sink slack received CephMonDiskLow =' "$live_stderr_file" || fail "missing evidence that slack received CephMonDiskLow"
grep -q 'PASS: sink pager did not receive CephMonDiskLow' "$live_stderr_file" || fail "missing evidence that pager did NOT receive CephMonDiskLow"
grep -q 'PASS: sink pager received CephMonDiskCritical =' "$live_stderr_file" || fail "missing evidence that pager received CephMonDiskCritical"

ok "mon-disk-low destructive ack guard, two-phase injection sequence, and rollback ordering"

# --- Setup-failure path: mon-01 has almost no disk used (free% >= 97), so
# derive_disk_thresholds' die() must fire before any config is touched. The
# framework's EXIT trap must still run scenario_rollback safely (removing
# config keys that were never set is a no-op) instead of leaking or crashing.
toohigh_stdout_file="$(mktemp)"
toohigh_stderr_file="$(mktemp)"
toohigh_trace_file="$(mktemp)"
rm -rf "$fake_bin_dir"
fake_bin_dir="$(mktemp -d)"
make_fake_jq "$fake_bin_dir/jq" "$real_jq" "$toohigh_trace_file"
make_fake_kubectl "$fake_bin_dir/kubectl" "$toohigh_trace_file"
make_fake_curl "$fake_bin_dir/curl" "$toohigh_trace_file"
make_fake_ssh "$fake_bin_dir/ssh" "$toohigh_trace_file" 2

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-mon-disk-low.sh" --yes-really-inject >"$toohigh_stdout_file" 2>"$toohigh_stderr_file"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected failure when mon-01 free space is too high for thresholds"
[[ ! -s "$toohigh_stdout_file" ]] || fail "unexpected result line when die() should have fired first"
grep -q 'FATAL: mon-01 free space (98%) is too high' "$toohigh_stderr_file" || fail "missing die() message for excessive free space"
if grep -q '^ssh:sudo -n cephadm shell -- ceph config set mon mon_data_avail_warn ' "$toohigh_trace_file"; then
  fail "config set ran despite die() firing during setup"
fi

rm -f "$toohigh_stdout_file" "$toohigh_stderr_file" "$toohigh_trace_file"
rm -rf "$fake_bin_dir"

ok "mon-disk-low dies before touching config when mon-01 free space is too high"
