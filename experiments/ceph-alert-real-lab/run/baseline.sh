#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/monitoring.sh
source "$ROOT/lib/monitoring.sh"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/evidence.sh
source "$ROOT/lib/evidence.sh"

require_cmd jq

result_dir="$(new_result_dir baseline)"
collect_baseline "$result_dir"

# Watchdog is Prometheus's dead-man-switch alert (`vector(1)`, always
# firing) routed to its own watchdog receiver. Confirming its heartbeat
# reaches the sink right after deploy proves the whole
# Prometheus -> Alertmanager -> sink pipeline is alive end-to-end,
# independent of any scenario-specific alert ever firing.
record_sink_checkpoint "$result_dir"
wait_sink_alert watchdog Watchdog "" "" "$result_dir" "$result_dir/sink-checkpoint-lines.txt"

printf 'baseline: %s\n' "$result_dir"
