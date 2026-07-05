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

# CephOSDFlapping (changes(ceph_osd_up[15m]) >= 4) has no `for:` clause: it
# fires the instant the 4th up/down transition below lands, and it keeps
# firing until the OLDEST of those transitions ages out of the 15m sliding
# window -- i.e. for up to ~15 minutes after this scenario's rollback has
# already restored the OSD to up/in. run/all.sh must sequence scenarios so
# nothing else asserts this same OSD's up/down state while that window is
# still open.
OSD_FLAP_HOST="${OSD_FLAP_HOST:-ceph-lab-osd-01}"
OSD_FLAP_ID="${OSD_FLAP_ID:-}"
OSD_FLAP_POLL_ATTEMPTS="${OSD_FLAP_POLL_ATTEMPTS:-24}"
OSD_FLAP_POLL_SLEEP="${OSD_FLAP_POLL_SLEEP:-5}"
OSD_FLAP_METRIC_ATTEMPTS="${OSD_FLAP_METRIC_ATTEMPTS:-24}"
OSD_FLAP_METRIC_SLEEP="${OSD_FLAP_METRIC_SLEEP:-5}"
_host_ip=""; _service=""
transition_step=1

scenario_setup() {
  _host_ip="$(lab_osd_host_ip "$OSD_FLAP_HOST")"
  if [[ -z "$OSD_FLAP_ID" ]]; then
    # Second OSD on the host (not the first, which osd-daemon-down/S4 and
    # daemon-crash/S14 already default to) so this scenario's up/down
    # transitions land on a different ceph_daemon and don't pollute those
    # scenarios' own changes() windows.
    OSD_FLAP_ID="$(ssh_lab "$LAB_MON_01_HOST" "sudo -n cephadm shell -- ceph osd ls-tree $OSD_FLAP_HOST" | sed -n '2p' | tr -d '[:space:]')"
  fi
  [[ -n "$OSD_FLAP_ID" ]] || die "no second OSD found on $OSD_FLAP_HOST"
  _service="$(osd_service_name "$LAB_FSID" "$OSD_FLAP_ID")"
}

# osd_tree_status_is <up|down> polls `ceph osd tree --format json` and checks
# this scenario's target OSD status. Captures stdout-only into $output_file
# so it holds clean, directly-jq-able JSON as evidence -- `cephadm shell`
# prints a multi-line "Inferring fsid/config .../Using ceph image ..." banner
# to stderr on every invocation, which is NOT '#'-prefixed and would
# otherwise corrupt the JSON body if merged in (e.g. via run_capture's
# 2>&1). That banner is preserved separately as evidence in
# $output_file.log.
osd_tree_status_is() {
  local expected=$1 output_file
  output_file="$RESULT_DIR/osd-tree-poll-$((transition_step)).json"
  ceph_seed_cmd osd tree --format json >"$output_file" 2>"$output_file.log" || return 1
  jq -e --arg osd "$OSD_FLAP_ID" --arg state "$expected" \
    '.nodes[] | select(.id == ($osd|tonumber)) | select(.status == $state)' "$output_file" >/dev/null
}

# prometheus_osd_up_equals <expected 0|1> queries Prometheus's OWN scraped
# ceph_osd_up{ceph_daemon="osd.<OSD_FLAP_ID>"} series -- as opposed to
# osd_tree_status_is, which polls the mon's view via `ceph osd tree` -- and
# checks it already equals expected. Captures the query response JSON to
# $RESULT_DIR as evidence. See wait_prometheus_osd_up for why this poll
# exists.
prometheus_osd_up_equals() {
  local expected=$1 output_file
  output_file="$RESULT_DIR/prometheus-osd-up-poll-$((transition_step)).json"
  prometheus_query "ceph_osd_up{ceph_daemon=\"osd.$OSD_FLAP_ID\"}" >"$output_file"
  [[ "$(jq -r '.data.result[0].value[1] // empty' "$output_file")" == "$expected" ]]
}

# wait_prometheus_osd_up <expected 0|1> -- CephOSDFlapping's
# changes(ceph_osd_up[15m]) >= 4 only counts states that actually land as
# distinct SCRAPED samples in Prometheus. The mon's view (`ceph osd tree`,
# polled by osd_tree_status_is) flips the instant the OSD daemon
# stops/starts, but the mgr Prometheus exporter lags that mon view, and
# Prometheus scrapes it only every 5s (see the prometheus.yml rendered in
# lib/monitoring.sh). Confirmed against the real lab: one "up" window
# lasted only ~4s -- shorter than a scrape interval -- so ceph_osd_up never
# recorded that state as its own sample, and changes() under-counted 2
# transitions even though the OSD (and `ceph osd tree`) genuinely flapped 4
# times. Blocking scenario_inject on Prometheus's own ceph_osd_up value
# (not just the mon's) after every transition guarantees each of the 4
# real states lands as a distinct scraped sample before the next
# transition starts. Let poll_until's non-zero return propagate (no `||
# true`) so this scenario fails loudly on timeout instead of silently
# under-counting like the real-lab incident this fixes.
wait_prometheus_osd_up() {
  local expected=$1
  poll_until "Prometheus ceph_osd_up{ceph_daemon=osd.$OSD_FLAP_ID} == $expected (transition $transition_step)" \
    "$OSD_FLAP_METRIC_ATTEMPTS" "$OSD_FLAP_METRIC_SLEEP" prometheus_osd_up_equals "$expected"
}

scenario_inject() {
  run_capture "$RESULT_DIR/stop-osd-1.txt" ssh_lab "$_host_ip" "sudo systemctl stop $_service"
  poll_until "osd.$OSD_FLAP_ID down (transition 1)" "$OSD_FLAP_POLL_ATTEMPTS" "$OSD_FLAP_POLL_SLEEP" osd_tree_status_is down
  wait_prometheus_osd_up 0
  transition_step=$((transition_step + 1))

  run_capture "$RESULT_DIR/start-osd-1.txt" ssh_lab "$_host_ip" "sudo systemctl start $_service"
  poll_until "osd.$OSD_FLAP_ID up (transition 2)" "$OSD_FLAP_POLL_ATTEMPTS" "$OSD_FLAP_POLL_SLEEP" osd_tree_status_is up
  wait_prometheus_osd_up 1
  transition_step=$((transition_step + 1))

  run_capture "$RESULT_DIR/stop-osd-2.txt" ssh_lab "$_host_ip" "sudo systemctl stop $_service"
  poll_until "osd.$OSD_FLAP_ID down (transition 3)" "$OSD_FLAP_POLL_ATTEMPTS" "$OSD_FLAP_POLL_SLEEP" osd_tree_status_is down
  wait_prometheus_osd_up 0
  transition_step=$((transition_step + 1))

  run_capture "$RESULT_DIR/start-osd-2.txt" ssh_lab "$_host_ip" "sudo systemctl start $_service"
  poll_until "osd.$OSD_FLAP_ID up (transition 4)" "$OSD_FLAP_POLL_ATTEMPTS" "$OSD_FLAP_POLL_SLEEP" osd_tree_status_is up
  wait_prometheus_osd_up 1
}

scenario_verify() {
  wait_prometheus_alert CephOSDFlapping ceph_daemon "osd.$OSD_FLAP_ID" "$RESULT_DIR"
  wait_sink_alert pager CephOSDFlapping ceph_daemon "osd.$OSD_FLAP_ID" "$RESULT_DIR" "$SINK_CHECKPOINT"
}

scenario_rollback() {
  # Transition 4 in scenario_inject already leaves the OSD started; this is
  # an idempotent final safety net in case an earlier step failed partway
  # (systemctl start on an already-started unit is a no-op success).
  run_capture "$RESULT_DIR/rollback-start-osd.txt" ssh_lab "$_host_ip" "sudo systemctl start $_service" || return 1
}

scenario_main osd-flapping "$@"
