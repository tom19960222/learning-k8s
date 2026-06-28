#!/usr/bin/env bash
set -euo pipefail

# Ceph incident bundle collection entrypoint.

usage() {
  printf 'Usage: %s <inventory-file>\n' "${0##*/}" >&2
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    return 1
  fi
}

main "$@"
