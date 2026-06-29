#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="$(command -v bash)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file=$1 expected=$2
  [[ -f "$file" ]] || fail "missing file: $file"
  grep -qF "$expected" "$file" || fail "expected '$expected' in $file"
}

run_rook_collector() {
  local outdir=$1 manifest=$2
  shift 2
  "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
    --out "$outdir" \
    --manifest "$manifest" \
    --namespace rook-ceph \
    --since 24h \
    --timeout 5 \
    "$@"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

minimal_bin="$tmpdir/minimal-bin"
mkdir -p "$minimal_bin"
ln -s "$(command -v dirname)" "$minimal_bin/dirname"
ln -s "$(command -v mkdir)" "$minimal_bin/mkdir"

out_no_kubectl="$tmpdir/out-no-kubectl"
manifest_no_kubectl="$tmpdir/manifest-no-kubectl.jsonl"
PATH="$minimal_bin" "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
  --out "$out_no_kubectl" \
  --manifest "$manifest_no_kubectl" \
  --namespace rook-ceph \
  --since 24h \
  --timeout 5
assert_file_contains "$out_no_kubectl/cluster/rook/SKIPPED.txt" "kubectl command not found"

fakebin="$tmpdir/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG:?}"

mode=${FAKE_KUBECTL_MODE:-present}
cmd="$*"

case "$cmd" in
  "get namespace rook-ceph")
    [[ "$mode" != "missing-namespace" ]] || exit 1
    printf 'rook-ceph\n'
    ;;
  "get pods -n rook-ceph -o wide")
    printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n'
    ;;
  "get events -n rook-ceph --sort-by=.lastTimestamp")
    printf 'LAST SEEN TYPE REASON OBJECT MESSAGE\n1m Normal Started pod/osd started\n'
    ;;
  "get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n rook-ceph -o yaml")
    printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n  metadata:\n    name: rook-ceph\n'
    ;;
  "get pods -n rook-ceph -l app=rook-ceph-operator -o jsonpath={.items[0].metadata.name}")
    printf 'rook-ceph-operator-0'
    ;;
  "logs -n rook-ceph rook-ceph-operator-0 --since=24h")
    printf 'operator log line\n'
    ;;
  "get pods -n rook-ceph -l app=rook-ceph-tools -o jsonpath={.items[0].metadata.name}")
    [[ "$mode" == "with-toolbox" ]] || exit 0
    printf 'rook-ceph-tools-0'
    ;;
  "exec -n rook-ceph rook-ceph-tools-0 -- ceph status")
    printf 'cluster is healthy from toolbox\n'
    ;;
  *)
    printf 'unexpected kubectl command: %s\n' "$cmd" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$fakebin/kubectl"

export FAKE_KUBECTL_LOG="$tmpdir/kubectl.log"

out_missing_ns="$tmpdir/out-missing-ns"
manifest_missing_ns="$tmpdir/manifest-missing-ns.jsonl"
FAKE_KUBECTL_MODE=missing-namespace PATH="$fakebin:$PATH" run_rook_collector "$out_missing_ns" "$manifest_missing_ns"
assert_file_contains "$out_missing_ns/cluster/rook/SKIPPED.txt" "namespace not found: rook-ceph"

out_present="$tmpdir/out-present"
manifest_present="$tmpdir/manifest-present.jsonl"
FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" run_rook_collector "$out_present" "$manifest_present"

assert_file_contains "$out_present/cluster/rook/pods-wide.txt" "rook-ceph-operator-0"
assert_file_contains "$out_present/cluster/rook/events.txt" "osd started"
assert_file_contains "$out_present/cluster/rook/rook-resources.yaml" "kind: CephCluster"
assert_file_contains "$out_present/cluster/rook/operator.log" "operator log line"
assert_file_contains "$out_present/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"

grep -qF 'get namespace rook-ceph' "$FAKE_KUBECTL_LOG" || fail "namespace detection was not called"
grep -qF 'logs -n rook-ceph rook-ceph-operator-0 --since=24h' "$FAKE_KUBECTL_LOG" || fail "operator logs were not collected"
