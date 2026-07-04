#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"

require_destructive_ack all "$@"

bash "$ROOT/run/deploy-monitoring.sh"
bash "$ROOT/run/baseline.sh"
bash "$ROOT/run/scenario-slow-ops.sh" --yes-really-inject
bash "$ROOT/run/scenario-pg-availability.sh" --yes-really-inject
bash "$ROOT/run/scenario-mon-quorum-lost.sh" --yes-really-inject
log "all real lab scenarios completed"
