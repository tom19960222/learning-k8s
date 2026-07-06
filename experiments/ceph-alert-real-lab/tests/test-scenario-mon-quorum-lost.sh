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
if [[ "\$*" == *"get pod -l app=alertmanager -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'alertmanager-0\n'
  exit 0
fi
if [[ "\$*" == *"exec alertmanager-0 -- wget -qO- --header=Content-Type: application/json --post-data="*"http://127.0.0.1:9093/api/v2/alerts"* ]]; then
  printf 'ok\n'
  exit 0
fi
if [[ "\$*" == *"exec alertmanager-0 -- wget -qO- http://127.0.0.1:9093/api/v2/alerts"* ]]; then
  # Gate on the synthetic POST having already happened in the trace -- this
  # proves the scenario really posted before it can observe inhibitedBy,
  # rather than the fake unconditionally claiming inhibition.
  if grep -q -- '--post-data=' "$trace_file"; then
    printf '%s\n' '[{"labels":{"alertname":"CephMonDownScoped"},"status":{"inhibitedBy":["synthetic-CephMonQuorumLost"]}}]'
  else
    printf '%s\n' '[{"labels":{"alertname":"CephMonDownScoped"},"status":{"inhibitedBy":[]}}]'
  fi
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/alerts"* ]]; then
  printf '%s\n' '{"data":{"alerts":[{"labels":{"alertname":"CephMonQuorumLost"},"state":"firing"}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=%28count%28ceph_mon_quorum_status%20%3D%3D%201%29%20or%20vector%280%29%29%20%3C%202"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  printf '%s\n' '{"receiver":"pager","alertname":"CephMonQuorumLost","labels":{}}'
  if grep -q 'systemctl stop ceph-' "$trace_file"; then
    printf '%s\n' '{"receiver":"pager","alertname":"CephMonQuorumLost","labels":{"fresh":"true"}}'
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
    printf 'HEALTH_WARN mons down, quorum reduced (MON_DOWN)\n'
    exit 0
    ;;
  *"ceph -s"*)
    printf 'HEALTH_OK\n'
    exit 0
    ;;
  *"quorum_status --format json"*)
    printf '{"quorum":[1]}\n'
    exit 0
    ;;
  *"ceph mgr dump --format json"*)
    printf '{"active_name":"ceph-lab-mon-02.fake"}\n'
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

find "$ROOT/results" -maxdepth 1 -type d -name 'mon-quorum-lost-*' | sort >"$before_dirs_file"

set +e
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-mon-quorum-lost.sh" >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e

find "$ROOT/results" -maxdepth 1 -type d -name 'mon-quorum-lost-*' | sort >"$after_dirs_file"

if [[ "$rc" -eq 0 ]]; then
  fail "scenario-mon-quorum-lost should require destructive ack"
fi
[[ "$rc" -eq 2 ]] || fail "expected exit 2 without destructive ack, got $rc"
grep -Fq -- 'mon-quorum-lost requires --yes-really-inject' "$stderr_file" || fail "missing destructive ack error"
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
PATH="$fake_bin_dir:$PATH" bash "$ROOT/run/scenario-mon-quorum-lost.sh" --yes-really-inject >"$live_stdout_file" 2>"$live_stderr_file"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected success with fake live environment, got $rc"
stdout_lines="$(wc -l <"$live_stdout_file" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected one stdout line on success, got $stdout_lines"
grep -Eq '^result: .*/results/mon-quorum-lost-[^/]+$' "$live_stdout_file" || fail "missing result line on success stdout"
if grep -Eq 'ssh-live-noise|kubectl-noise-for-' "$live_stdout_file"; then
  fail "live command stdout leaked into scenario stdout"
fi
grep -q '^ssh:sudo systemctl stop ceph-.*@mon\.ceph-lab-mon-01\.service$' "$live_trace_file" || fail "missing stop for mon-01"
grep -q '^ssh:sudo systemctl stop ceph-.*@mon\.ceph-lab-mon-03\.service$' "$live_trace_file" || fail "missing stop for mon-03"
if grep -q '^ssh:sudo systemctl stop ceph-.*@mon\.ceph-lab-mon-02\.service$' "$live_trace_file"; then
  fail "mon-02 should stay running for Prometheus scrape continuity"
fi
grep -q '^ssh:sudo systemctl start ceph-.*@mon\.ceph-lab-mon-01\.service$' "$live_trace_file" || fail "missing rollback start for mon-01"
grep -q '^ssh:sudo systemctl start ceph-.*@mon\.ceph-lab-mon-03\.service$' "$live_trace_file" || fail "missing rollback start for mon-03"

stop1_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@mon\.ceph-lab-mon-01\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
stop3_line="$(grep -n '^ssh:sudo systemctl stop ceph-.*@mon\.ceph-lab-mon-03\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
start1_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@mon\.ceph-lab-mon-01\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"
start3_line="$(grep -n '^ssh:sudo systemctl start ceph-.*@mon\.ceph-lab-mon-03\.service$' "$live_trace_file" | head -1 | cut -d: -f1)"

[[ -n "$stop1_line" && -n "$stop3_line" && -n "$start1_line" && -n "$start3_line" ]] || fail "missing trace lines for ordering checks"
(( start1_line > stop1_line )) || fail "rollback start for mon-01 happened before stop"
(( start3_line > stop3_line )) || fail "rollback start for mon-03 happened before stop"
grep -q 'query=%28count%28ceph_mon_quorum_status%20%3D%3D%201%29%20or%20vector%280%29%29%20%3C%202' "$live_trace_file" || fail "missing Prometheus quorum-loss evidence query"

# The mon-quorum-lost real fault cannot temporally overlap CephMonQuorumLost
# firing with CephMonDownScoped being active (mgr exporter telemetry freezes
# during real quorum loss -- see scenario_verify's comment), so the inhibit
# relationship is validated deterministically instead: POST a synthetic pair
# of alerts straight to Alertmanager and confirm the config actually
# suppresses the target. Assert the scenario really POSTed both alertnames
# (not just that the fake unconditionally claims inhibition), and that the
# resulting inhibited-by evidence is only produced once that POST happened.
grep -q -- '--post-data=.*CephMonQuorumLost.*CephMonDownScoped.*http://127.0.0.1:9093/api/v2/alerts' "$live_trace_file" || fail "missing synthetic POST of both CephMonQuorumLost and CephMonDownScoped to Alertmanager"

result_dir="$ROOT/results/$(basename "$(sed -n 's/^result: //p' "$live_stdout_file")")"
post_evidence_file="$result_dir/synthetic-inhibit-post-CephMonQuorumLost-CephMonDownScoped.json"
[[ -f "$post_evidence_file" ]] || fail "missing synthetic inhibit POST evidence file"
[[ -f "$result_dir/alertmanager-alerts-CephMonDownScoped.json" ]] || fail "missing CephMonDownScoped alertmanager inhibited-poll evidence"
grep -q '"inhibitedBy":\["synthetic-CephMonQuorumLost"\]' "$result_dir/alertmanager-alerts-CephMonDownScoped.json" || fail "alertmanager evidence file missing inhibitedBy content gated on the synthetic POST"
grep -q 'PASS: Alertmanager alert CephMonDownScoped inhibited via synthetic CephMonQuorumLost POST' "$live_stderr_file" || fail "missing evidence that CephMonDownScoped was confirmed inhibited via synthetic POST"

quorum_lost_line="$(grep -n 'PASS: Prometheus alert CephMonQuorumLost' "$live_stderr_file" | head -1 | cut -d: -f1)"
inhibited_line="$(grep -n 'PASS: Alertmanager alert CephMonDownScoped inhibited via synthetic CephMonQuorumLost POST' "$live_stderr_file" | head -1 | cut -d: -f1)"
[[ -n "$quorum_lost_line" && -n "$inhibited_line" ]] || fail "missing stderr lines for ordering check"
(( inhibited_line > quorum_lost_line )) || fail "synthetic inhibit-config check should run after the CephMonQuorumLost waits"

ok "mon-quorum-lost destructive ack guard"
