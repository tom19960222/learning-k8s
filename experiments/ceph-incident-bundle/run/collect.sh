#!/usr/bin/env bash
set -euo pipefail

# Ceph incident bundle collection entrypoint.

usage() {
  cat >&2 <<'EOF'
Usage: collect.sh --inventory <path> [--ssh-key <path>] [--seed <host>] [--help]
EOF
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    return 1
  fi

  usage
  printf '%s: not implemented yet\n' "${0##*/}" >&2
  return 1
}

main "$@"
