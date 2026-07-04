#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/monitoring.sh
source "$ROOT/lib/monitoring.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

out="$(mktemp)"
render_monitoring_manifest "$out"

grep -q 'name: ceph-alert-lab' "$out" || fail "namespace missing"
grep -q 'prom/prometheus:v3.2.1' "$out" || fail "Prometheus image missing"
grep -q 'prom/alertmanager:v0.28.1' "$out" || fail "Alertmanager image missing"
grep -q 'python:3.12-alpine' "$out" || fail "alert sink image missing"
grep -q '192.168.18.166:9283' "$out" || fail "mgr scrape target 166 missing"
grep -q '192.168.18.167:9283' "$out" || fail "mgr scrape target 167 missing"
grep -q 'ceph-production-coverage.yml' "$out" || fail "coverage rules key missing"
grep -q 'default-mixin.yml' "$out" || fail "default mixin rules key missing"
grep -q 'source=~\"ceph_stability|ceph_scoped|ceph_coverage\"' "$out" || fail "label-based pager route matcher missing"
grep -q 'watchdog-ceph' "$out" || fail "watchdog receiver missing"
grep -q 'CephClientBlocked' "$out" || fail "CephClientBlocked rule missing"
grep -q 'CephMonQuorumLost' "$out" || fail "CephMonQuorumLost rule missing"
grep -q 'CephPGUnhealthyStates' "$out" || fail "CephPGUnhealthyStates rule missing"

fake_bin_dir="$(mktemp -d)"
sink_dir="$(mktemp -d)"
sink_log_file="$(mktemp)"
trace_file="$(mktemp)"

cleanup() {
  rm -f "$out" "$sink_log_file" "$trace_file"
  rm -rf "$fake_bin_dir" "$sink_dir"
}

trap cleanup EXIT

cat >"$fake_bin_dir/kubectl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl:%s\n' "\$*" >>"$trace_file"
if [[ "\$*" == *"logs deploy/alert-sink"* ]]; then
  cat "$sink_log_file"
  exit 0
fi
if [[ "\$*" == *"get pod -l app=prometheus -o jsonpath={.items[0].metadata.name}"* ]]; then
  printf 'prometheus-0\n'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22ceph%22%7D"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
if [[ "\$*" == *"exec prometheus-0 -- wget -qO- http://127.0.0.1:9090/api/v1/query?query=sum%28ceph_mon_quorum_status%29"* ]]; then
  printf '%s\n' '{"data":{"result":[{"value":[1,"1"]}]}}'
  exit 0
fi
printf 'unexpected kubectl command: %s\n' "\$*" >&2
exit 1
EOF
chmod +x "$fake_bin_dir/kubectl"

printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","labels":{"name":"SLOW_OPS"}}' >"$sink_log_file"
PATH="$fake_bin_dir:$PATH" record_sink_checkpoint "$sink_dir"
SINK_WAIT_ATTEMPTS=1 SINK_WAIT_SLEEP=0 PATH="$fake_bin_dir:$PATH" \
  wait_sink_alert pager CephClientBlocked name SLOW_OPS "$sink_dir" "$sink_dir/sink-checkpoint-lines.txt" &&
  fail "wait_sink_alert should ignore a stale pre-checkpoint alert"

printf '%s\n' '{"receiver":"pager","alertname":"CephClientBlocked","labels":{"name":"SLOW_OPS"}}' >>"$sink_log_file"
SINK_WAIT_ATTEMPTS=1 SINK_WAIT_SLEEP=0 PATH="$fake_bin_dir:$PATH" \
  wait_sink_alert pager CephClientBlocked name SLOW_OPS "$sink_dir" "$sink_dir/sink-checkpoint-lines.txt" ||
  fail "wait_sink_alert should pass on a post-checkpoint alert"

PATH="$fake_bin_dir:$PATH" prometheus_query 'up{job="ceph"}' >/dev/null ||
  fail "prometheus_query should URL-encode label matcher queries"
PATH="$fake_bin_dir:$PATH" prometheus_query 'sum(ceph_mon_quorum_status)' >/dev/null ||
  fail "prometheus_query should URL-encode function queries"
grep -Fq 'query=up%7Bjob%3D%22ceph%22%7D' "$trace_file" || fail "label matcher query was not URL-encoded"
grep -Fq 'query=sum%28ceph_mon_quorum_status%29' "$trace_file" || fail "function query was not URL-encoded"

ok "monitoring manifest render"
