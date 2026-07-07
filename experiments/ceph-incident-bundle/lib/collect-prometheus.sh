#!/usr/bin/env bash
set -euo pipefail

# Collect Prometheus metrics evidence (optional layer). Runs curl on the
# workstation against a user-supplied Prometheus base URL, dumping every
# metric of the matching scrape jobs over the --since window.

PROM_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$PROM_COLLECTOR_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: collect-prometheus.sh --out DIR --manifest PATH --url URL
       [--job-regex RE] [--step SECONDS] [--since DURATION]
       [--timeout SECONDS] [--budget SECONDS]
EOF
}

# Parse a --since style duration into seconds: N (seconds) or N{s,m,h,d,w}.
# Rejects 0 and anything non-matching.
prom_duration_seconds() {
  local value=$1 n unit
  local re='^([0-9]+)([smhdw]?)$'
  [[ $value =~ $re ]] || return 1
  n="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  # Normalize to base-10 immediately to avoid octal interpretation
  n=$((10#$n))
  [[ "$n" -gt 0 ]] || return 1
  case "$unit" in
    ''|s) : ;;
    m) n=$((n * 60)) ;;
    h) n=$((n * 3600)) ;;
    d) n=$((n * 86400)) ;;
    w) n=$((n * 604800)) ;;
  esac
  printf '%s' "$n"
}

# Auto query_range step: smallest step >= 15s that keeps points per series
# under Prometheus's 11,000-point query_range limit (ceil(window/10000)).
prom_auto_step() {
  local window=$1 step
  step=$(((window + 9999) / 10000))
  [[ $step -ge 15 ]] || step=15
  printf '%s' "$step"
}

# Mask embedded basic-auth credentials in a URL before it lands in artifacts.
prom_mask_url() {
  local url=$1
  local re='^([A-Za-z][A-Za-z0-9+.-]*://)([^/@]+)@(.*)$'
  if [[ $url =~ $re ]]; then
    local cred=${BASH_REMATCH[2]}
    printf '%s%s:***@%s' "${BASH_REMATCH[1]}" "${cred%%:*}" "${BASH_REMATCH[3]}"
  else
    printf '%s' "$url"
  fi
}

# Workstation dependencies for this layer. Prints the missing dependency
# (used verbatim as the SKIPPED reason) and returns 1.
prom_require_cmds() {
  local c
  for c in curl python3; do
    if ! command -v "$c" >/dev/null 2>&1; then
      printf '%s not found on this workstation' "$c"
      return 1
    fi
  done
}
