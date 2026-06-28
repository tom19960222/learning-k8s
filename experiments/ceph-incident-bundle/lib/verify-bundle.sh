#!/usr/bin/env bash
set -euo pipefail

# Ceph incident bundle verification entrypoint.

usage() {
  printf 'Usage: %s <bundle-dir>\n' "${0##*/}" >&2
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    return 1
  fi
}

main "$@"
