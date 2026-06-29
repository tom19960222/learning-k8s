#!/usr/bin/env bash
set -euo pipefail

# Collect read-only Rook/Ceph Kubernetes evidence.

ROOK_COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOK_COLLECTOR_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: collect-cluster-rook.sh --out DIR --manifest PATH [--namespace rook-ceph] [--since DURATION] [--timeout SECONDS]
EOF
}

rook_skip() {
  local outdir=$1 reason=$2
  local artifact="$outdir/cluster/rook/SKIPPED.txt"
  ensure_dir "$(dirname -- "$artifact")"
  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
}

rook_write_skip_artifact() {
  local artifact=$1 reason=$2
  ensure_dir "$(dirname -- "$artifact")"
  printf 'SKIPPED: %s\n' "$reason" >"$artifact"
}

rook_run_capture() {
  local outdir=$1 manifest=$2 timeout=$3 artifact_rel=$4
  shift 4

  local artifact="$outdir/$artifact_rel"
  if ! COMMAND_TIMEOUT="$timeout" ERROR_LOG="${ERROR_LOG:-$outdir/errors.log}" \
    run_capture "$manifest" "rook" "collect-cluster-rook" "$artifact" -- "$@"; then
    return 2
  fi
  return 0
}

rook_get_first_pod() {
  local namespace=$1 label=$2
  kubectl get pods -n "$namespace" -l "$label" -o 'jsonpath={.items[0].metadata.name}' 2>/dev/null || true
}

collect_cluster_rook() {
  local outdir='' manifest='' namespace=rook-ceph since=24h timeout=20 allow_skip=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        outdir=${2-}
        shift 2
        ;;
      --manifest)
        manifest=${2-}
        shift 2
        ;;
      --namespace)
        namespace=${2-}
        shift 2
        ;;
      --since)
        since=${2-}
        shift 2
        ;;
      --timeout)
        timeout=${2-}
        shift 2
        ;;
      --allow-skip)
        allow_skip=1
        shift
        ;;
      --help|-h)
        usage
        return 0
        ;;
      *)
        usage >&2
        return 1
        ;;
    esac
  done

  [[ -n "$outdir" && -n "$manifest" ]] || {
    usage >&2
    return 1
  }

  ensure_dir "$outdir/cluster/rook"

  # Missing kubectl / namespace means we collected NO cluster evidence. In
  # explicit rook mode that is a partial failure (exit 2) so the bundle does not
  # falsely look complete; auto-mode fallback passes --allow-skip to tolerate it.
  if ! command -v kubectl >/dev/null 2>&1; then
    rook_skip "$outdir" "kubectl command not found"
    [[ "$allow_skip" == "1" ]] && return 0 || return 2
  fi

  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
    rook_skip "$outdir" "namespace not found: $namespace"
    [[ "$allow_skip" == "1" ]] && return 0 || return 2
  fi

  local failed=0
  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/pods-wide.txt" \
    kubectl get pods -n "$namespace" -o wide; then
    failed=1
  fi
  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/events.txt" \
    kubectl get events -n "$namespace" --sort-by=.lastTimestamp; then
    failed=1
  fi
  if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/rook-resources.yaml" \
    kubectl get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n "$namespace" -o yaml; then
    failed=1
  fi

  local operator_pod toolbox_pod
  operator_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-operator")"
  if [[ -n "$operator_pod" ]]; then
    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/operator.log" \
      kubectl logs -n "$namespace" "$operator_pod" --since="$since"; then
      failed=1
    fi
  else
    rook_write_skip_artifact "$outdir/cluster/rook/operator-SKIPPED.txt" "rook operator Pod not found"
  fi

  toolbox_pod="$(rook_get_first_pod "$namespace" "app=rook-ceph-tools")"
  if [[ -n "$toolbox_pod" ]]; then
    if ! rook_run_capture "$outdir" "$manifest" "$timeout" "cluster/rook/toolbox-status.txt" \
      kubectl exec -n "$namespace" "$toolbox_pod" -- ceph status; then
      failed=1
    fi
  else
    rook_write_skip_artifact "$outdir/cluster/rook/toolbox-SKIPPED.txt" "rook toolbox Pod not found"
  fi

  [[ $failed -eq 0 ]] || return 2
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  collect_cluster_rook "$@"
fi
