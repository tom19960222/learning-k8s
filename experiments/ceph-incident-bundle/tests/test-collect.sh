#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_and_capture() {
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  printf '%s\n%s' "$status" "$output"
}

find_bundle() {
  local outdir=$1 bundle
  bundle="$(find "$outdir" -maxdepth 1 -name 'ceph-incident-*.tar.gz' -print -quit)"
  [[ -n "$bundle" ]] || fail "missing generated bundle in $outdir"
  printf '%s' "$bundle"
}

assert_archive_contains() {
  local bundle=$1 expected=$2
  tar -tzf "$bundle" | sed 's#^\./##' | grep -qF "$expected" || fail "archive missing $expected"
}

assert_archive_file_contains() {
  local bundle=$1 path=$2 expected=$3
  tar -xOzf "$bundle" "./$path" 2>/dev/null | grep -qF "$expected" || fail "archive file $path missing $expected"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

help_result="$(run_and_capture "$ROOT/run/collect.sh" --help)"
help_status="${help_result%%$'\n'*}"
help_output="${help_result#*$'\n'}"
[[ "$help_status" == "0" ]] || fail "collect.sh --help exited $help_status"
[[ "$help_output" == *"Usage:"* ]] || fail "collect.sh --help did not print usage"

missing_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$tmpdir/missing.env")"
missing_status="${missing_result%%$'\n'*}"
[[ "$missing_status" == "1" ]] || fail "missing inventory should exit 1, got $missing_status"

fakebin="$tmpdir/fakebin"
mkdir -p "$fakebin"

cat >"$fakebin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_KUBECTL_LOG:?}"
cmd="$*"
case "$cmd" in
  "get namespace rook-ceph")
    printf 'rook-ceph\n'
    ;;
  "get pods -n rook-ceph -o wide")
    printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n'
    ;;
  "get events -n rook-ceph --sort-by=.lastTimestamp")
    printf 'LAST SEEN TYPE REASON OBJECT MESSAGE\n1m Normal Started pod/osd started\n'
    ;;
  "get cephclusters.ceph.rook.io,cephblockpools.ceph.rook.io,cephfilesystems.ceph.rook.io,cephobjectstores.ceph.rook.io -n rook-ceph -o yaml")
    printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n'
    ;;
  "get pods -n rook-ceph -l app=rook-ceph-operator -o jsonpath={.items[0].metadata.name}")
    printf 'rook-ceph-operator-0'
    ;;
  "logs -n rook-ceph rook-ceph-operator-0 --since=24h")
    printf 'operator log line\n'
    ;;
  "get pods -n rook-ceph -l app=rook-ceph-tools -o jsonpath={.items[0].metadata.name}")
    exit 0
    ;;
  *)
    printf 'unexpected kubectl command: %s\n' "$cmd" >&2
    exit 99
    ;;
esac
EOF

cat >"$fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
cat >/dev/null

remote_command="${@: -1}"
alias_name="$(printf '%s\n' "$remote_command" | sed -n "s/.*--host-alias '\\([^']*\\)'.*/\\1/p")"
[[ -n "$alias_name" ]] || {
  printf 'remote command did not preserve quoted --host-alias: %s\n' "$remote_command" >&2
  exit 99
}
if [[ "${FAKE_SSH_BAD_TAR_ALIAS:-}" == "$alias_name" ]]; then
  printf 'not a tar archive\n'
  exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/system"
mkdir -p "$tmpdir/cephadm/var-lib-ceph-configs/fsid/mon.a"
printf 'node %s\n' "$alias_name" >"$tmpdir/system/hostname.txt"
printf 'secret = should-redact\n' >"$tmpdir/cephadm/var-lib-ceph-configs/fsid/mon.a/config"
tar -czf - -C "$tmpdir" .

if [[ "${FAKE_SSH_FAIL_ALIAS:-}" == "$alias_name" ]]; then
  exit 2
fi
EOF
chmod +x "$fakebin/kubectl" "$fakebin/ssh"

inventory="$tmpdir/inventory.env"
cat >"$inventory" <<'EOF'
SSH_USER="tester"
SEED_HOST="seed.example.invalid"
ROOK_NAMESPACE="rook-ceph"
HOSTS=(
  "monitor01=10.0.0.1"
  "osd01=10.0.0.2"
)
EOF

ssh_key="$tmpdir/id_ed25519"
printf 'fake key\n' >"$ssh_key"

export FAKE_KUBECTL_LOG="$tmpdir/kubectl.log"
export FAKE_SSH_LOG="$tmpdir/ssh.log"

out_success="$tmpdir/out-success"
PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" \
  --ssh-key "$ssh_key" \
  --seed tester@seed.example.invalid \
  --mode rook \
  --out "$out_success" \
  --since 24h \
  --timeout 5

bundle_success="$(find_bundle "$out_success")"
assert_archive_contains "$bundle_success" "manifest.jsonl"
assert_archive_contains "$bundle_success" "summary.txt"
assert_archive_contains "$bundle_success" "README-FIRST.txt"
assert_archive_contains "$bundle_success" "cluster/rook/pods-wide.txt"
assert_archive_contains "$bundle_success" "nodes/monitor01/system/hostname.txt"
assert_archive_contains "$bundle_success" "nodes/osd01/system/hostname.txt"
assert_archive_file_contains "$bundle_success" "nodes/monitor01/cephadm/var-lib-ceph-configs/fsid/mon.a/config" "[REDACTED]"
grep -qF 'ConnectTimeout=5' "$FAKE_SSH_LOG" || fail "ssh calls should include ConnectTimeout from --timeout"

out_partial="$tmpdir/out-partial"
partial_status=0
set +e
FAKE_SSH_FAIL_ALIAS=osd01 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" \
  --ssh-key "$ssh_key" \
  --seed tester@seed.example.invalid \
  --mode rook \
  --out "$out_partial" \
  --since 24h \
  --timeout 5
partial_status=$?
set -e
[[ "$partial_status" == "2" ]] || fail "one failed host should exit 2, got $partial_status"

bundle_partial="$(find_bundle "$out_partial")"
assert_archive_contains "$bundle_partial" "nodes/osd01/system/hostname.txt"
assert_archive_contains "$bundle_partial" "errors.log"

out_bad_tar="$tmpdir/out-bad-tar"
bad_tar_status=0
set +e
FAKE_SSH_BAD_TAR_ALIAS=osd01 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" \
  --ssh-key "$ssh_key" \
  --seed tester@seed.example.invalid \
  --mode rook \
  --out "$out_bad_tar" \
  --since 24h \
  --timeout 5
bad_tar_status=$?
set -e
[[ "$bad_tar_status" == "2" ]] || fail "bad node tar should exit 2, got $bad_tar_status"

bundle_bad_tar="$(find_bundle "$out_bad_tar")"
assert_archive_contains "$bundle_bad_tar" "nodes/osd01/SKIPPED.txt"
