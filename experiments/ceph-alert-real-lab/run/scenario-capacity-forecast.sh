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

# REAL-LAB EVIDENCE (physics, not a rule bug) -- FIX ROUND 3. Three real-lab
# attempts at this scenario have now measured actual sustained throughput on
# the ~900GiB (966329892864-byte) cluster:
#
#   Run 1 (original design): a 1-PG pool fed by rados bench's low default
#   concurrency serialized every write onto that PG's 3 OSDs and sustained
#   only ~0.72 MB/s (used bytes climbed 390MB -> 2.33GB over the whole run).
#   predict_linear(...[1h], 259200) projected a 72h-out total of just
#   183.7GB against the ~821GB threshold (0.85 * 900GiB) -- 4.5x short.
#
#   Run 2 (16-PG pool, size 3, single stream, -t 128): still only sustained
#   0.33-0.72 MB/s despite bursting as high as 12.8 MB/s -- throughput
#   repeatedly collapsed back down under BlueStore backpressure. More PGs
#   and more threads inside ONE stream did not fix it: a single stream has
#   nowhere to hide a per-stream stall (the whole pipe idles while it
#   recovers).
#
#   Run 3 (this fix): the round-2 probe's setup step (`ceph osd pool set
#   alert-forecast size 1 --yes-i-really-mean-it`) actually fails outright on
#   v19.2.3 with `Error EPERM: configuring pool size as 1 is disabled by
#   default` (needs an extra `mon_allow_pool_size_one=true` mon config we do
#   NOT want to toggle just for this scenario) -- and that failure was
#   silent, so the 10-minute probe that measured 6.9 MB/s sustained RAW
#   growth actually ran the whole time at the pool's DEFAULT size=3 (still
#   32 PGs, still 3 parallel held-open bench streams at -t 64 each). That is
#   good news, not a new problem: CephCapacityForecast's rule tracks
#   ceph_cluster_total_used_bytes -- RAW used bytes -- and 3x replication
#   multiplies logical writes into raw growth (~2.3 MB/s logical x 3
#   replicas ~= 6.9 MB/s raw), so size=3 alone already clears the ~3.2 MB/s
#   floor below with room to spare. size=1 is unnecessary (and disabled by
#   default anyway): keep default replication (size 3 / min_size 2,
#   matching every other scenario's pool hygiene) and rely on the 3 parallel
#   streams for the concurrency that actually mattered.
#
# CephCapacityForecast (max(predict_linear(ceph_cluster_total_used_bytes[1h],
# 259200)) > 0.85 * max(ceph_cluster_total_bytes), for: 30m) needs a
# sustained write slope of at least (821GB - current_used) / 72h ~= 3.2
# MB/s for predict_linear's 72h (259200s) extrapolation to clear the
# threshold. At the probed ~6.9 MB/s RAW (size=3, 32 PGs, 3 parallel
# streams), the projection crosses the ~821GB threshold once the [1h]
# least-squares window's average slope exceeds 3.2 MB/s (~25-35 minutes of
# fill), then 30 more continuous minutes for `for: 30m` to latch -- a
# realistic fire time of ~55-70 minutes wall-clock. Bump
# PROMETHEUS_WAIT_ATTEMPTS to 900 attempts * 5s = 4500s (75m) to cover the
# worst case of that window. A real (--yes-really-inject) run of this
# scenario therefore takes up to ~75 MINUTES of wall-clock time -- do not
# run it interactively without expecting a long wait.
PROMETHEUS_WAIT_ATTEMPTS="${PROMETHEUS_WAIT_ATTEMPTS:-900}"
export PROMETHEUS_WAIT_ATTEMPTS

POOL="${FORECAST_POOL:-alert-forecast}"
# 60 rounds * 90s/round = 5400s (90m) of sustained writes PER STREAM --
# comfortably exceeds the 75m PROMETHEUS_WAIT_ATTEMPTS budget above so the 3
# parallel background loops keep feeding predict_linear's growth slope for
# at least as long as scenario_verify is willing to wait for the alert to
# fire. 90s rounds amortize each round's ~10s cephadm-shell container
# startup dead-time over a larger useful-write window per round.
FORECAST_MAX_ROUNDS="${FORECAST_MAX_ROUNDS:-60}"
FORECAST_ROUND_SECONDS="${FORECAST_ROUND_SECONDS:-90}"
# 64 concurrent writer threads PER STREAM: the real-lab probe (see the
# physics comment above) measured exactly this shape -- a size=3 pool (32
# PGs, default replication) fed by 3 parallel streams at -t 64 each --
# sustaining 6.9 MB/s raw growth. A single stream at higher concurrency
# (-t 128, run 2's design) collapsed to 0.33-0.72 MB/s under BlueStore
# backpressure; parallelizing across 3 independent streams instead of
# piling more threads onto one absorbs a single stream's transient stall
# without stalling the aggregate.
FORECAST_BENCH_THREADS="${FORECAST_BENCH_THREADS:-64}"
LOOP_PID_1=""
LOOP_PID_2=""
LOOP_PID_3=""
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
#
# This function is invoked once per PARALLEL stream (1, 2, 3) below. Each
# stream's loop-of-rounds runs fully independently of the other two. The
# --run-name is `stream<N>-r<round>` -- BOTH the stream index AND the round
# counter -- for two reasons: (1) it keeps concurrent rounds across streams
# from colliding on the same rados bench object names, and (2) critically,
# it keeps CONSECUTIVE rounds of the SAME stream from colliding too. `rados
# bench` derives its object names deterministically from --run-name, so
# round 2 reusing round 1's run-name (e.g. a fixed `stream$i` with no round
# suffix) OVERWRITES round 1's objects instead of writing new ones -- used
# bytes stop growing after the first round of each stream fills, which is
# exactly the plateau real-lab evidence caught (12 rados bench processes
# running, but ceph_cluster_total_used_bytes flat at ~0.10 MB/s after an
# initial climb to ~2.3GB). Appending the round counter makes every round
# write brand-new objects so used bytes keep accumulating round over round,
# matching the 10-minute probe's ONE continuous (non-looping, non-reused)
# `rados bench 600` per stream that measured ~6.9 MB/s sustained RAW growth.
start_forecast_bench_loop() {
  local stream=$1 output_file=$2 pid_file=$3 child_pid_file=$4 pid
  (
    local round=1 rc=0 child="" run_name=""
    : >"$output_file"
    while [[ "$round" -le "$FORECAST_MAX_ROUNDS" ]]; do
      run_name="stream${stream}-r${round}"
      printf '# round %s started: %s\n' "$round" "$(date -u +%FT%TZ)" >>"$output_file"
      set +e
      ssh_lab "$LAB_MON_01_HOST" \
        "sudo -n cephadm shell -- rados bench -p $POOL $FORECAST_ROUND_SECONDS write -b 4194304 -t $FORECAST_BENCH_THREADS --run-name $run_name --no-cleanup" \
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
  pid=$!
  case "$stream" in
    1) LOOP_PID_1=$pid ;;
    2) LOOP_PID_2=$pid ;;
    3) LOOP_PID_3=$pid ;;
  esac
  printf '%s\n' "$pid" >"$pid_file"
}

# stop_forecast_loop <stream> <reason> mirrors scenario-latency-outlier.sh's
# stop_bench_workload exactly, parametrized by stream index: kill the
# in-flight round's ssh child directly first (poll briefly, escalate to
# SIGKILL if it won't die), then kill the outer loop subshell, then wait on
# it -- defense in depth on top of the loop's own internal TERM trap above,
# not a replacement for it. scenario_rollback calls this once per stream (1,
# 2, 3) so all three parallel loops are torn down, not just the first one.
stop_forecast_loop() {
  local stream=$1 reason=$2 child_pid="" i loop_pid=""
  local child_pid_file="$RESULT_DIR/forecast-loop-stream${stream}.child.pid"
  case "$stream" in
    1) loop_pid="$LOOP_PID_1" ;;
    2) loop_pid="$LOOP_PID_2" ;;
    3) loop_pid="$LOOP_PID_3" ;;
  esac
  if [[ -z "$loop_pid" ]]; then
    return 0
  fi

  log "stop capacity-forecast bench loop stream$stream ($reason)"
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
  if kill -0 "$loop_pid" 2>/dev/null; then
    kill "$loop_pid" 2>/dev/null || true
  fi
  wait "$loop_pid" 2>/dev/null || true
  case "$stream" in
    1) LOOP_PID_1="" ;;
    2) LOOP_PID_2="" ;;
    3) LOOP_PID_3="" ;;
  esac
  return 0
}

scenario_setup() {
  # 32 PGs at DEFAULT replication (size 3 / min_size 2, matching every
  # other scenario's pool hygiene): the real-lab probe (see the physics
  # comment above) turned out to have silently kept size=3 the whole time
  # (`size 1 --yes-i-really-mean-it` is EPERM-disabled on v19.2.3 without an
  # extra mon config toggle we do not want to make) and still sustained 6.9
  # MB/s of RAW growth -- 3x replication multiplies logical writes into raw
  # usage, which is exactly the metric CephCapacityForecast's rule tracks,
  # so size=3 clears the needed slope on its own. No need to fight the
  # cluster's size-1 guardrail at all.
  run_live_step "pool-create" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool create $POOL 32"
  run_live_step "pool-set-size" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool set $POOL size 3"
  run_live_step "pool-set-min-size" "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd pool set $POOL min_size 2"
}

scenario_inject() {
  start_forecast_bench_loop 1 "$RESULT_DIR/forecast-bench-loop-stream1.txt" "$RESULT_DIR/forecast-loop-stream1.pid" "$RESULT_DIR/forecast-loop-stream1.child.pid"
  start_forecast_bench_loop 2 "$RESULT_DIR/forecast-bench-loop-stream2.txt" "$RESULT_DIR/forecast-loop-stream2.pid" "$RESULT_DIR/forecast-loop-stream2.child.pid"
  start_forecast_bench_loop 3 "$RESULT_DIR/forecast-bench-loop-stream3.txt" "$RESULT_DIR/forecast-loop-stream3.pid" "$RESULT_DIR/forecast-loop-stream3.child.pid"
}

scenario_verify() {
  wait_prometheus_alert CephCapacityForecast "" "" "$RESULT_DIR"
  wait_sink_alert slack CephCapacityForecast "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
  # CephCapacityForecast is warning severity (source=ceph_coverage, not
  # critical) -- pin the evidence that it never leaks to the pager receiver.
  assert_sink_absent pager CephCapacityForecast "" "" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  local rc=0 stream

  for stream in 1 2 3; do
    stop_forecast_loop "$stream" "before pool cleanup"
  done
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
