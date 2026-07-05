#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/monitoring.sh
source "$ROOT/lib/monitoring.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/evidence.sh
source "$ROOT/lib/evidence.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/scenarios.sh
source "$ROOT/lib/scenarios.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/scenario-framework.sh
source "$ROOT/lib/scenario-framework.sh"

# CephCapacityForecast (max(predict_linear(ceph_cluster_total_used_bytes[1h],
# 259200)) > 0.85 * max(ceph_cluster_total_bytes), for: 30m) needs enough
# poll attempts to reliably outlast the 30m `for:` window; bump it to 540
# attempts * 5s = 2700s (45m), which also comfortably covers the bench loop
# below building up predict_linear's 1h slope in the first place. A real
# (--yes-really-inject) run of this scenario therefore takes up to ~45
# MINUTES of wall-clock time -- do not run it interactively without
# expecting a long wait.
PROMETHEUS_WAIT_ATTEMPTS="${PROMETHEUS_WAIT_ATTEMPTS:-540}"
export PROMETHEUS_WAIT_ATTEMPTS

POOL="${FORECAST_POOL:-alert-forecast}"
# 45 rounds * 60s/round = 2700s (45m) of sustained writes -- matched to the
# PROMETHEUS_WAIT_ATTEMPTS budget above so the background loop keeps feeding
# predict_linear's growth slope for roughly as long as scenario_verify is
# willing to wait for the alert to fire.
FORECAST_MAX_ROUNDS="${FORECAST_MAX_ROUNDS:-45}"
FORECAST_ROUND_SECONDS="${FORECAST_ROUND_SECONDS:-60}"
LOOP_PID=""
pool_step=1
cleanup_step=1

run_live_step() {
  local label=$1 host=$2 command=$3
  run_capture "$RESULT_DIR/${label}.txt" ssh_lab "$host" "$command"
}

# CONTROLLER CORRECTION (binding, supersedes the original task brief): do
# NOT launch the bench loop with `nohup ... &` *inside* the cephadm shell
# container -- the container is a foreground `podman run --rm` without
# --pid=host (see scenario-latency-outlier.sh's start_background_capture
# comment for the full analysis), so a nohup'd background job inside it
# dies the instant the container's own foreground entrypoint returns. This
# exact bug was found and fixed in S11 (scenario-slow-ops.sh's ancestor) and
# again in S18's predecessor design here.
#
# Instead, each round's `rados bench` runs as the FOREGROUND command of its
# own ssh + cephadm-shell invocation (keeping that round's container alive
# for the round's full duration), and only the outer *loop* of rounds is
# backgrounded locally, in this script's own process -- imitating
# scenario-latency-outlier.sh's start_background_capture/stop_bench_workload
# mechanics, but repeated across up to FORECAST_MAX_ROUNDS consecutive
# rounds instead of a single long-lived bench.
start_forecast_bench_loop() {
  local output_file=$1 pid_file=$2 child_pid_file=$3
  (
    local round=1 rc=0 child=""
    : >"$output_file"
    while [[ "$round" -le "$FORECAST_MAX_ROUNDS" ]]; do
      printf '# round %s started: %s\n' "$round" "$(date -u +%FT%TZ)" >>"$output_file"
      set +e
      ssh_lab "$LAB_MON_01_HOST" \
        "sudo -n cephadm shell -- rados bench -p $POOL $FORECAST_ROUND_SECONDS write --no-cleanup" \
        >>"$output_file" 2>&1 &
      child=$!
      printf '%s\n' "$child" >"$child_pid_file"
      trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
      wait "$child"
      rc=$?
      trap - TERM INT
      set -e
      printf '# round %s exit_code: %s\n' "$round" "$rc" >>"$output_file"
      if [[ "$rc" -ne 0 ]]; then
        break
      fi
      round=$((round + 1))
    done
    exit "$rc"
  ) &
  LOOP_PID=$!
  printf '%s\n' "$LOOP_PID" >"$pid_file"
}

# stop_forecast_loop mirrors scenario-latency-outlier.sh's stop_bench_workload
# exactly: kill the in-flight round's ssh child directly first (poll briefly,
# escalate to SIGKILL if it won't die), then kill the outer loop subshell,
# then wait on it -- defense in depth on top of the loop's own internal TERM
# trap above, not a replacement for it.
stop_forecast_loop() {
  local reason=$1 child_pid_file="$RESULT_DIR/forecast-loop.child.pid" child_pid="" i
  if [[ -z "$LOOP_PID" ]]; then
    return 0
  fi

  log "stop capacity-forecast bench loop ($reason)"
  if [[ -f "$child_pid_file" ]]; then
    child_pid="$(cat "$child_pid_file")"
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
      kill "$child_pid" 2>/dev/null || true
      i=0
      while [[ "$i" -lt 20 ]] && kill -0 "$child_pid" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
      done
      if kill -0 "$child_pid" 2>/dev/null; then
        kill -KILL "$child_pid" 2>/dev/null || true
      fi
    fi
  fi
  if kill -0 "$LOOP_PID" 2>/dev/null; then
    kill "$LOOP_PID" 2>/dev/null || true
  fi
  wait "$LOOP_PID" 2>/dev/null || true
  LOOP_PID=""
  return 0
}

scenario_setup() {
  while IFS= read -r pool_cmd; do
    run_live_step "pool-setup-$((pool_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $pool_cmd"
    pool_step=$((pool_step + 1))
  done < <(pool_create_commands "$POOL")
}

scenario_inject() {
  start_forecast_bench_loop "$RESULT_DIR/forecast-bench-loop.txt" "$RESULT_DIR/forecast-loop.pid" "$RESULT_DIR/forecast-loop.child.pid"
}

scenario_verify() {
  wait_prometheus_alert CephCapacityForecast "" "" "$RESULT_DIR"
  wait_sink_alert slack CephCapacityForecast "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
  # CephCapacityForecast is warning severity (source=ceph_coverage, not
  # critical) -- pin the evidence that it never leaks to the pager receiver.
  assert_sink_absent pager CephCapacityForecast "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local rc=0

  stop_forecast_loop "before pool cleanup"

  while IFS= read -r cleanup_cmd; do
    run_live_step "rollback-pool-cleanup-$((cleanup_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $cleanup_cmd" || rc=1
    cleanup_step=$((cleanup_step + 1))
  done < <(pool_cleanup_commands "$POOL")
  return "$rc"
}

scenario_main capacity-forecast "$@"
