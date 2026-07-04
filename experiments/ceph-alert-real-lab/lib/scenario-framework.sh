#!/usr/bin/env bash
set -euo pipefail

# scenario_main <scenario-name> "$@"
# Caller must define: scenario_inject, scenario_rollback, scenario_verify.
# Optional: scenario_setup (runs before sink checkpoint; put pool creation here).
_SCENARIO_CLEANED=0

_scenario_cleanup() {
  local rc=0
  if [[ "$_SCENARIO_CLEANED" -eq 1 ]]; then
    return 0
  fi
  log "rollback: $_SCENARIO_NAME"
  scenario_rollback || rc=1
  collect_postcheck "$RESULT_DIR/postcheck" || true
  assert_lab_recovered "$RESULT_DIR/recovery" || rc=1
  _SCENARIO_CLEANED=1
  return "$rc"
}

_scenario_cleanup_on_exit() {
  local rc=$?
  _scenario_cleanup || true
  exit "$rc"
}

scenario_main() {
  _SCENARIO_NAME=$1
  shift
  require_destructive_ack "$_SCENARIO_NAME" "$@"
  require_cmd jq
  RESULT_DIR="$(new_result_dir "$_SCENARIO_NAME")"
  # shellcheck disable=SC2034
  # SINK_CHECKPOINT is global state for scenario_verify/scenario_rollback
  # implementations defined in caller scripts (e.g. as the checkpoint_file
  # argument to assert_sink_absent/wait_sink_alert), not consumed here.
  SINK_CHECKPOINT="$RESULT_DIR/sink-checkpoint-lines.txt"
  trap _scenario_cleanup_on_exit EXIT
  collect_baseline "$RESULT_DIR/baseline"
  assert_lab_ready "$RESULT_DIR/ready-before-injection"
  if declare -F scenario_setup >/dev/null; then
    scenario_setup
  fi
  record_sink_checkpoint "$RESULT_DIR"
  scenario_inject
  scenario_verify
  trap - EXIT
  _scenario_cleanup || exit 1
  printf 'result: %s\n' "$RESULT_DIR"
}
