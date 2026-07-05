#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"

require_destructive_ack all "$@"

bash "$ROOT/run/deploy-monitoring.sh"
# Collects cluster/Rook/Prometheus baseline evidence and asserts the
# Watchdog heartbeat reaches the sink (S22) -- proves the whole
# Prometheus -> Alertmanager -> sink pipeline is alive before any scenario
# below ever runs.
bash "$ROOT/run/baseline.sh"

# Config-only scenarios: neither stops nor restarts any daemon, so they carry
# no daemon-recovery risk and are cheapest to run first.
bash "$ROOT/run/scenario-catch-all-risk.sh" --yes-really-inject
bash "$ROOT/run/scenario-mon-disk-low.sh" --yes-really-inject

# Service-level scenarios: touch a supporting service (time-sync, mgr) but
# never an OSD/mon up/down transition, so they stay isolated from the
# daemon-down group below.
bash "$ROOT/run/scenario-mon-clock-skew.sh" --yes-really-inject
bash "$ROOT/run/scenario-mgr-failover.sh" --yes-really-inject
bash "$ROOT/run/scenario-exporter-blind.sh" --yes-really-inject

# Single-daemon up/down scenarios, grouped together; osd-flapping runs LAST
# in this group because its rule watches changes(ceph_osd_up[15m]) over a
# 15-minute window that must not have residual up/down transitions from the
# other scenarios in this group bleeding into its change count.
bash "$ROOT/run/scenario-osd-daemon-down.sh" --yes-really-inject
bash "$ROOT/run/scenario-mon-down-single.sh" --yes-really-inject
bash "$ROOT/run/scenario-osd-host-down.sh" --yes-really-inject
bash "$ROOT/run/scenario-daemon-crash.sh" --yes-really-inject
bash "$ROOT/run/scenario-osd-flapping.sh" --yes-really-inject

# Degradation scenarios (throttle/netem): OSDs stay up throughout, so they
# carry none of the up/down flapping-window risk above.
bash "$ROOT/run/scenario-slow-ops.sh" --yes-really-inject
bash "$ROOT/run/scenario-latency-outlier.sh" --yes-really-inject
bash "$ROOT/run/scenario-net-slow-heartbeat.sh" --yes-really-inject

# Stops two OSDs together -- harsher than any single-daemon scenario above,
# so it runs on its own after the lighter degradation scenarios.
bash "$ROOT/run/scenario-pg-availability.sh" --yes-really-inject

# Capacity stages: progressively fill pool/cluster capacity and share the
# same capacity-metric domain (ratios, quotas, predict_linear trend), so
# they run back-to-back rather than interleaved with unrelated scenarios.
bash "$ROOT/run/scenario-pool-quota.sh" --yes-really-inject
bash "$ROOT/run/scenario-capacity-ladder.sh" --yes-really-inject
bash "$ROOT/run/scenario-capacity-forecast.sh" --yes-really-inject

# Data-integrity scenarios: deliberately corrupt/orphan PG replicas, the
# highest-severity data-risk tier, so they run after capacity (which never
# touches data integrity) and before the final full-cluster scenarios.
bash "$ROOT/run/scenario-data-damage.sh" --yes-really-inject
bash "$ROOT/run/scenario-object-unfound.sh" --yes-really-inject

# Long wall-clock (`for: 30m`) but functionally isolated -- doesn't interact
# with any other scenario's state, so it's fine to leave until near the end.
bash "$ROOT/run/scenario-low-priority-notice.sh" --yes-really-inject

# Most-disruptive-last: loses quorum on 2 of the 3 mons, so it runs LAST to
# minimize how long the whole cluster stays degraded before cleanup.
bash "$ROOT/run/scenario-mon-quorum-lost.sh" --yes-really-inject

bash "$ROOT/run/cleanup.sh"
log "all real lab scenarios completed"
