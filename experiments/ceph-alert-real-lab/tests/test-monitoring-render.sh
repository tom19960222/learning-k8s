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
grep -q '192.168.18.167:9283' "$out" || fail "mgr scrape target missing"
grep -q 'alertname=~\"CephClientBlocked|CephClientRisk|CephMonQuorumLost|CephExporterDown|CephOSDHostDownScoped|CephOSDDaemonDownScoped|CephMonDownScoped\"' "$out" || fail "pager route matcher missing"
grep -q 'CephClientBlocked' "$out" || fail "CephClientBlocked rule missing"
grep -q 'CephMonQuorumLost' "$out" || fail "CephMonQuorumLost rule missing"

ok "monitoring manifest render"
