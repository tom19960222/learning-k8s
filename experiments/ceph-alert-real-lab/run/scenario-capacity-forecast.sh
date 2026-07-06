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

# REAL-LAB EVIDENCE (physics, not a rule bug): a prior --yes-really-inject
# run against this ~900GiB (966329892864-byte) cluster used a 1-PG pool
# (pool_create_commands' default) fed by rados bench's low default
# concurrency. That serializes every write onto the pool's single PG's 3
# OSDs and measured only ~0.72 MB/s average throughput (used bytes climbed
# 390MB -> 2.33GB over the whole run). predict_linear(...[1h], 259200)
# projected a 72h-out total of just 183.7GB against the ~821GB threshold
# (0.85 * 900GiB) -- 4.5x short. CephCapacityForecast correctly never
# fired: the rule did its job, the injected trend was simply too weak to
# extrapolate past the threshold. The fix below is THROUGHPUT (more PGs for
# parallelism + higher bench concurrency + longer rounds to amortize
# cephadm-shell container startup dead-time), not the rule or the wait
# budget's shape.
#
# CephCapacityForecast (max(predict_linear(ceph_cluster_total_used_bytes[1h],
# 259200)) > 0.85 * max(ceph_cluster_total_bytes), for: 30m) needs a
# sustained write slope of at least (821GB - current_used) / 72h ~= 3.2
# MB/s for predict_linear's 72h (259200s) extrapolation to clear the
# threshold, held long enough for the [1h] least-squares window to mostly
# reflect it (~25-40 minutes of fill at good throughput before the window
# is largely growth-signal), THEN 30 more continuous minutes for `for: 30m`
# to latch -- a realistic fire time of ~55-75 minutes wall-clock. The 16-PG
# pool + -t $FORECAST_BENCH_THREADS (128) below is expected to sustain
# >=8 MB/s, comfortably above the ~3.2 MB/s floor. Bump PROMETHEUS_WAIT_ATTEMPTS
# to 900 attempts * 5s = 4500s (75m) to cover the worst case of that window.
# A real (--yes-really-inject) run of this scenario therefore takes up to
# ~75 MINUTES of wall-clock time -- do not run it interactively without
# expecting a long wait.
PROMETHEUS_WAIT_ATTEMPTS="${PROMETHEUS_WAIT_ATTEMPTS:-900}"
export PROMETHEUS_WAIT_ATTEMPTS

POOL="${FORECAST_POOL:-alert-forecast}"
# 60 rounds * 90s/round = 5400s (90m) of sustained writes -- comfortably
# exceeds the 75m PROMETHEUS_WAIT_ATTEMPTS budget above so the background
# loop keeps feeding predict_linear's growth slope for at least as long as
# scenario_verify is willing to wait for the alert to fire. 90s rounds (vs
# the old 60s) amortize each round's ~10s cephadm-shell container startup
# dead-time over a larger useful-write window per round.
FORECAST_MAX_ROUNDS="${FORECAST_MAX_ROUNDS:-60}"
FORECAST_ROUND_SECONDS="${FORECAST_ROUND_SECONDS:-90}"
# 128 concurrent writer threads: the real-lab root cause of the ~0.72 MB/s
# throughput was a 1-PG pool serializing writes onto one PG's 3 OSDs, not
# insufficient bandwidth -- pairing this with the 16-PG pool below (see
# scenario_setup) lets bench's concurrency actually parallelize.
FORECAST_BENCH_THREADS="${FORECAST_BENCH_THREADS:-128}"
LOOP_PID=""
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
        "sudo -n cephadm shell -- rados bench -p $POOL $FORECAST_ROUND_SECONDS write -b 4194304 -t $FORECAST_BENCH_THREADS --no-cleanup" \
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
  # 16 PGs (vs pool_create_commands' 1-PG default) so bench's high
  # concurrency (-t $FORECAST_BENCH_THREADS) can actually parallelize writes
  # across multiple PGs/OSDs instead of serializing onto a single PG -- the
  # real-lab root cause of the original design's ~0.72 MB/s throughput (see
  # the physics comment near the top of this file). Mirrors how
  # scenario-capacity-ladder.sh builds its 8-PG pool inline.
  run_live_step "pool-create" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool create $POOL 16"
  run_live_step "pool-set-size" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool set $POOL size 3"
  run_live_step "pool-set-min-size" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool set $POOL min_size 2"
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
  # The sustained heavy writes above can also latch BLUESTORE_SLOW_OP_ALERT
  # on the OSDs backing this pool's PGs; clear it before pool cleanup so
  # assert_lab_recovered's HEALTH_OK gate doesn't time out (same latch
  # issue previously fixed in scenario-slow-ops.sh / scenario-latency-outlier.sh
  # / scenario-capacity-ladder.sh).
  clear_bluestore_slow_ops "$RESULT_DIR" || rc=1

  while IFS= read -r cleanup_cmd; do
    run_live_step "rollback-pool-cleanup-$((cleanup_step))" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- $cleanup_cmd" || rc=1
    cleanup_step=$((cleanup_step + 1))
  done < <(pool_cleanup_commands "$POOL")
  return "$rc"
}

scenario_main capacity-forecast "$@"
