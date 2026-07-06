#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/monitoring.sh
source "$ROOT/lib/monitoring.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

# ---------------------------------------------------------------------------
# scenario_main (cases 1-4): must run in a subprocess because the framework's
# EXIT trap calls `exit`, which would otherwise terminate this test script.
# ---------------------------------------------------------------------------

scratch_dir="$(mktemp -d)"
driver="$scratch_dir/scenario-main-driver.sh"

cleanup_driver() {
  rm -rf "$scratch_dir"
}
trap cleanup_driver EXIT

cat >"$driver" <<DRIVER
#!/usr/bin/env bash
set -euo pipefail

source "$ROOT/lib/common.sh"
source "$ROOT/lib/evidence.sh"
source "$ROOT/lib/monitoring.sh"
source "$ROOT/lib/scenario-framework.sh"

collect_baseline() { :; }
assert_lab_ready() { :; }
record_sink_checkpoint() { :; }
collect_postcheck() { :; }
assert_lab_recovered() { :; }

scenario_inject() { printf 'inject\n' >>"\$TRACE_FILE"; }
scenario_verify() { printf 'verify\n' >>"\$TRACE_FILE"; return "\${FAKE_VERIFY_RC:-0}"; }
scenario_rollback() { printf 'rollback\n' >>"\$TRACE_FILE"; return "\${FAKE_ROLLBACK_RC:-0}"; }

scenario_main fw-smoke "\$@"
DRIVER
chmod +x "$driver"

# --- Case 1: no --yes-really-inject -> exit 2, scenario_inject never runs ---
no_ack_trace="$scratch_dir/no-ack-trace.txt"
no_ack_stdout="$scratch_dir/no-ack-stdout.txt"
no_ack_stderr="$scratch_dir/no-ack-stderr.txt"
: >"$no_ack_trace"

set +e
TRACE_FILE="$no_ack_trace" bash "$driver" >"$no_ack_stdout" 2>"$no_ack_stderr"
rc=$?
set -e

[[ "$rc" -eq 2 ]] || fail "expected exit 2 without --yes-really-inject, got $rc"
grep -Fq -- 'fw-smoke requires --yes-really-inject' "$no_ack_stderr" || fail "missing destructive ack error"
[[ ! -s "$no_ack_stdout" ]] || fail "unexpected stdout without destructive ack"
if grep -Fq 'inject' "$no_ack_trace"; then
  fail "scenario_inject ran before destructive ack was given"
fi

ok "scenario_main requires --yes-really-inject"

# --- Case 2 & 4: normal path -> inject, verify, rollback in order; single
# stdout result line; rollback runs exactly once (idempotent) ---
success_trace="$scratch_dir/success-trace.txt"
success_stdout="$scratch_dir/success-stdout.txt"
success_stderr="$scratch_dir/success-stderr.txt"
: >"$success_trace"

set +e
TRACE_FILE="$success_trace" bash "$driver" --yes-really-inject >"$success_stdout" 2>"$success_stderr"
rc=$?
set -e

[[ "$rc" -eq 0 ]] || fail "expected exit 0 on success path, got $rc (stderr: $(cat "$success_stderr"))"

stdout_lines="$(wc -l <"$success_stdout" | tr -d ' ')"
[[ "$stdout_lines" -eq 1 ]] || fail "expected exactly one stdout line, got $stdout_lines"
grep -Eq '^result: .*/results/fw-smoke-[^/]+$' "$success_stdout" || fail "missing result line on success stdout"

inject_line="$(grep -n '^inject$' "$success_trace" | head -1 | cut -d: -f1)"
verify_line="$(grep -n '^verify$' "$success_trace" | head -1 | cut -d: -f1)"
rollback_line="$(grep -n '^rollback$' "$success_trace" | head -1 | cut -d: -f1)"
[[ -n "$inject_line" && -n "$verify_line" && -n "$rollback_line" ]] || fail "missing inject/verify/rollback trace lines"
(( verify_line > inject_line )) || fail "verify ran before inject"
(( rollback_line > verify_line )) || fail "rollback ran before verify"

rollback_count="$(grep -c '^rollback$' "$success_trace" || true)"
[[ "$rollback_count" -eq 1 ]] || fail "expected rollback to run exactly once, ran $rollback_count times"

ok "scenario_main normal path: inject -> verify -> rollback, single result line, idempotent rollback"

# --- Case 3: verify fails -> rollback still runs, exit non-zero ---
verify_fail_trace="$scratch_dir/verify-fail-trace.txt"
verify_fail_stdout="$scratch_dir/verify-fail-stdout.txt"
verify_fail_stderr="$scratch_dir/verify-fail-stderr.txt"
: >"$verify_fail_trace"

set +e
TRACE_FILE="$verify_fail_trace" FAKE_VERIFY_RC=1 bash "$driver" --yes-really-inject >"$verify_fail_stdout" 2>"$verify_fail_stderr"
rc=$?
set -e

[[ "$rc" -ne 0 ]] || fail "expected non-zero exit when scenario_verify fails"
grep -Fq -- 'rollback' "$verify_fail_trace" || fail "rollback did not run after scenario_verify failed"

ok "scenario_main runs rollback and exits non-zero when scenario_verify fails"

# ---------------------------------------------------------------------------
# Case 5: assert_prometheus_alert_not_firing
# ---------------------------------------------------------------------------

firing_dir="$(mktemp -d)"
KUBECTL_ALERTS_JSON='{"data":{"alerts":[{"labels":{"alertname":"CephMonDownScoped","hostname":"mon-1"},"state":"firing"}]}}'
# shellcheck disable=SC2329
kubectl_lab() {
  case "$*" in
    *"get pod -l app=prometheus"*)
      printf 'prometheus-0\n'
      ;;
    *"/api/v1/alerts"*)
      printf '%s\n' "$KUBECTL_ALERTS_JSON"
      ;;
    *)
      printf 'unexpected kubectl_lab call: %s\n' "$*" >&2
      return 1
      ;;
  esac
}

if assert_prometheus_alert_not_firing CephMonDownScoped hostname mon-1 "$firing_dir"; then
  fail "assert_prometheus_alert_not_firing should return 1 when the alert is firing"
fi

not_firing_dir="$(mktemp -d)"
KUBECTL_ALERTS_JSON='{"data":{"alerts":[]}}'
assert_prometheus_alert_not_firing CephMonDownScoped hostname mon-1 "$not_firing_dir" ||
  fail "assert_prometheus_alert_not_firing should return 0 when there are no matching alerts"

ok "assert_prometheus_alert_not_firing"

# ---------------------------------------------------------------------------
# Case 6: assert_sink_absent
# ---------------------------------------------------------------------------

present_dir="$(mktemp -d)"
present_checkpoint="$present_dir/checkpoint.txt"
printf '1\n' >"$present_checkpoint"
SINK_LOG=$'{"receiver":"pager","alertname":"OLD","labels":{}}\n{"receiver":"pager","alertname":"CephMonDownScoped","labels":{"hostname":"mon-1"}}'
# shellcheck disable=SC2329
kubectl_lab() {
  case "$*" in
    *"logs deploy/alert-sink"*)
      printf '%s\n' "$SINK_LOG"
      ;;
    *)
      printf 'unexpected kubectl_lab call: %s\n' "$*" >&2
      return 1
      ;;
  esac
}

if assert_sink_absent pager CephMonDownScoped hostname mon-1 "$present_dir" "$present_checkpoint"; then
  fail "assert_sink_absent should return 1 when the sink received the alert after the checkpoint"
fi

absent_dir="$(mktemp -d)"
absent_checkpoint="$absent_dir/checkpoint.txt"
printf '1\n' >"$absent_checkpoint"
SINK_LOG=$'{"receiver":"pager","alertname":"CephMonDownScoped","labels":{"hostname":"mon-1"}}\n{"receiver":"pager","alertname":"OTHER","labels":{}}'

assert_sink_absent pager CephMonDownScoped hostname mon-1 "$absent_dir" "$absent_checkpoint" ||
  fail "assert_sink_absent should return 0 when the alert only appeared before the checkpoint"

ok "assert_sink_absent"

# ---------------------------------------------------------------------------
# Case 7: wait_alertmanager_inhibited
# ---------------------------------------------------------------------------

inhibited_dir="$(mktemp -d)"
# shellcheck disable=SC2329
kubectl_lab() {
  case "$*" in
    *"get pod -l app=alertmanager"*)
      printf 'alertmanager-0\n'
      ;;
    *"/api/v2/alerts"*)
      printf '%s\n' '[{"labels":{"alertname":"CephMonDownScoped"},"status":{"inhibitedBy":["abc"]}}]'
      ;;
    *)
      printf 'unexpected kubectl_lab call: %s\n' "$*" >&2
      return 1
      ;;
  esac
}

ALERTMANAGER_WAIT_ATTEMPTS=1 ALERTMANAGER_WAIT_SLEEP=0 \
  wait_alertmanager_inhibited CephMonDownScoped "$inhibited_dir" ||
  fail "wait_alertmanager_inhibited should pass when inhibitedBy is non-empty"

ok "wait_alertmanager_inhibited"

# ---------------------------------------------------------------------------
# Case 8: assert_inhibit_via_synthetic_post
# ---------------------------------------------------------------------------

synthetic_dir="$(mktemp -d)"
SYNTHETIC_POST_SEEN=0
# shellcheck disable=SC2329
kubectl_lab() {
  case "$*" in
    *"exec alertmanager-0 -- wget -qO- --header=Content-Type: application/json --post-data="*"CephMonQuorumLost"*"CephMonDownScoped"*"http://127.0.0.1:9093/api/v2/alerts"*)
      SYNTHETIC_POST_SEEN=1
      printf 'ok\n'
      ;;
    *"get pod -l app=alertmanager"*)
      printf 'alertmanager-0\n'
      ;;
    *"/api/v2/alerts"*)
      if [[ "$SYNTHETIC_POST_SEEN" -eq 1 ]]; then
        printf '%s\n' '[{"labels":{"alertname":"CephMonDownScoped"},"status":{"inhibitedBy":["CephMonQuorumLost"]}}]'
      else
        printf '%s\n' '[{"labels":{"alertname":"CephMonDownScoped"},"status":{"inhibitedBy":[]}}]'
      fi
      ;;
    *)
      printf 'unexpected kubectl_lab call: %s\n' "$*" >&2
      return 1
      ;;
  esac
}

SYNTHETIC_INHIBIT_WAIT_ATTEMPTS=1 SYNTHETIC_INHIBIT_WAIT_SLEEP=0 \
  assert_inhibit_via_synthetic_post CephMonQuorumLost CephMonDownScoped "$synthetic_dir" ||
  fail "assert_inhibit_via_synthetic_post should pass once the target alert shows inhibitedBy after the POST"

[[ "$SYNTHETIC_POST_SEEN" -eq 1 ]] || fail "assert_inhibit_via_synthetic_post did not POST the synthetic alert pair"
[[ -f "$synthetic_dir/synthetic-inhibit-post-CephMonQuorumLost-CephMonDownScoped.json" ]] ||
  fail "assert_inhibit_via_synthetic_post did not capture POST response evidence"
[[ -f "$synthetic_dir/alertmanager-alerts-CephMonDownScoped.json" ]] ||
  fail "assert_inhibit_via_synthetic_post did not capture inhibited-poll evidence"

ok "assert_inhibit_via_synthetic_post"

ok "scenario framework and negative assertion helpers"
