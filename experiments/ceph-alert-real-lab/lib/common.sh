#!/usr/bin/env bash
set -euo pipefail

LAB_NAMESPACE="${LAB_NAMESPACE:-ceph-alert-lab}"
LAB_KUBECONFIG="${LAB_KUBECONFIG:-/Users/ikaros/.kube/ceph-lab-k8s.kubeconfig}"
LAB_SSH_KEY="${LAB_SSH_KEY:-/Users/ikaros/Documents/code/learning-k8s/.ssh/id_ed25519}"
LAB_SSH_USER="${LAB_SSH_USER:-ikaros}"
LAB_FSID="${LAB_FSID:-0c9bf37e-514a-11f1-b72a-bc24113f1375}"
LAB_MGR_ENDPOINT="${LAB_MGR_ENDPOINT:-http://192.168.18.167:9283}"
LAB_MON_01_HOST="${LAB_MON_01_HOST:-192.168.18.166}"
LAB_MON_02_HOST="${LAB_MON_02_HOST:-192.168.18.167}"
LAB_MON_03_HOST="${LAB_MON_03_HOST:-192.168.18.164}"
LAB_MON_01_NAME="${LAB_MON_01_NAME:-ceph-lab-mon-01}"
LAB_MON_02_NAME="${LAB_MON_02_NAME:-ceph-lab-mon-02}"
LAB_MON_03_NAME="${LAB_MON_03_NAME:-ceph-lab-mon-03}"
LAB_OSD_01_HOST="${LAB_OSD_01_HOST:-192.168.18.169}"
LAB_OSD_02_HOST="${LAB_OSD_02_HOST:-192.168.18.171}"
LAB_OSD_03_HOST="${LAB_OSD_03_HOST:-192.168.18.174}"
LAB_TIMEOUT="${LAB_TIMEOUT:-10}"

lab_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

die() {
  log "FATAL: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

new_result_dir() {
  local scenario=$1 root stamp dir
  root="$(lab_root)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$root/results/${scenario}-${stamp}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

ssh_base_opts() {
  local ssh_key=$1 timeout_seconds=$2
  printf '%s\n' \
    -i "$ssh_key" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o LogLevel=ERROR \
    -o "ConnectTimeout=$timeout_seconds" \
    -o "ServerAliveInterval=$timeout_seconds" \
    -o ServerAliveCountMax=1 \
    -o StrictHostKeyChecking=accept-new
}

require_destructive_ack() {
  local scenario=$1
  shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--yes-really-inject" ]]; then
      return 0
    fi
  done
  printf '%s requires --yes-really-inject\n' "$scenario" >&2
  return 2
}

run_capture() {
  local output_file=$1
  shift
  local started ended rc
  started="$(date -u +%FT%TZ)"
  {
    printf '# started: %s\n' "$started"
    printf '# command:'
    printf ' %q' "$@"
    printf '\n'
  } >"$output_file"
  set +e
  "$@" >>"$output_file" 2>&1
  rc=$?
  set -e
  ended="$(date -u +%FT%TZ)"
  {
    printf '\n# ended: %s\n' "$ended"
    printf '# exit_code: %s\n' "$rc"
  } >>"$output_file"
  return "$rc"
}

poll_until() {
  local description=$1 attempts=$2 sleep_seconds=$3
  shift 3
  local i
  i=1
  while [[ "$i" -le "$attempts" ]]; do
    if "$@"; then
      log "PASS: $description"
      return 0
    fi
    if [[ "$sleep_seconds" -gt 0 ]]; then
      sleep "$sleep_seconds"
    fi
    i=$((i + 1))
  done
  log "TIMEOUT: $description"
  return 1
}

kubectl_lab() {
  KUBECONFIG="$LAB_KUBECONFIG" kubectl "$@"
}

ssh_lab() {
  local host=$1
  shift
  local -a opts
  local opt
  while IFS= read -r opt; do
    opts+=("$opt")
  done < <(ssh_base_opts "$LAB_SSH_KEY" "$LAB_TIMEOUT")
  # shellcheck disable=SC2029
  ssh "${opts[@]}" "${LAB_SSH_USER}@${host}" "$@"
}
