#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for the Ceph incident bundle harness.

ceph_incident_bundle_log() {
  printf '%s\n' "$*"
}
