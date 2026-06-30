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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ---------------------------------------------------------------------------
# usage / arg validation
# ---------------------------------------------------------------------------
help_result="$(run_and_capture "$ROOT/run/collect.sh" --help)"
help_status="${help_result%%$'\n'*}"
help_output="${help_result#*$'\n'}"
[[ "$help_status" == "0" ]] || fail "collect.sh --help exited $help_status"
[[ "$help_output" == *"Usage:"* ]] || fail "collect.sh --help did not print usage"
[[ "$help_output" == *"--kube-context"* ]] || fail "help should document --kube-context"

missing_result="$(run_and_capture "$ROOT/run/collect.sh" --inventory "$tmpdir/missing.env")"
missing_status="${missing_result%%$'\n'*}"
[[ "$missing_status" == "1" ]] || fail "missing inventory should exit 1, got $missing_status"

# ---------------------------------------------------------------------------
# fake bins: capability-aware ssh, fake kubectl, passthrough timeout
#   ssh dispatches by the remote command:
#     - "command -v cephadm" (capability probe) -> emit caps based on target
#     - "cephadm shell -- ceph"                 -> delegate to the ceph fixture ssh
#     - "kubectl"                               -> forward to the fake kubectl
#     - "collect-node.sh"                       -> fabricate a node bundle tar
#   Caps per target come from FAKE_CEPH_TARGETS / FAKE_KUBE_TARGETS (substrings).
# ---------------------------------------------------------------------------
fakebin="$tmpdir/fakebin"
mkdir -p "$fakebin"

cat >"$fakebin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--context" ]] && shift 2
cmd="$*"
case "$cmd" in
  "get namespace rook-ceph") printf 'rook-ceph\n' ;;
  "get pods -n rook-ceph -o wide") printf 'NAME READY STATUS\nrook-ceph-operator-0 1/1 Running\n' ;;
  "get events -n rook-ceph --sort-by=.lastTimestamp") printf 'LAST SEEN TYPE\n1m Normal\n' ;;
  *"-n rook-ceph -o yaml") printf 'apiVersion: v1\nitems:\n- kind: CephCluster\n' ;;
  "get pods -n rook-ceph -l app=rook-ceph-operator -o name") printf 'pod/rook-ceph-operator-0\n' ;;
  "logs -n rook-ceph rook-ceph-operator-0 --since="*) printf 'operator log line\n' ;;
  "get pods -n rook-ceph -l app=rook-ceph-tools -o name") exit 0 ;;
  *) printf 'unexpected kubectl: %s\n' "$cmd" >&2; exit 99 ;;
esac
EOF

cat >"$fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${FAKE_TIMEOUT_LOG:?}"
shift
exec "$@"
EOF

cat >"$fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
whole="$*"
args=("$@")
n=${#args[@]}

# Order matters: the capability-probe script also contains "kubectl", so it must
# be matched before the kubectl-forward branch.
case "$whole" in
  *"command -v cephadm"*)
    target="${args[$((n-2))]}"   # probe sends a single-arg remote script
    caps=""
    for t in ${FAKE_CEPH_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps cephadm"; done
    for t in ${FAKE_KUBE_TARGETS:-}; do [[ "$target" == *"$t"* ]] && caps="$caps kubectl"; done
    printf '%s\n' "$caps"
    exit 0
    ;;
  *"cephadm shell -- ceph"*)
    exec "$FIXTURE_SSH" "$@"
    ;;
  *collect-node.sh*)
    alias_name="$(printf '%s\n' "$whole" | sed -n "s/.*--host-alias '\\([^']*\\)'.*/\\1/p")"
    cat >/dev/null
    [[ -n "$alias_name" ]] || { printf 'no alias\n' >&2; exit 99; }
    if [[ "${FAKE_SSH_BAD_TAR_ALIAS:-}" == "$alias_name" ]]; then
      printf 'not a tar archive\n'; exit 0
    fi
    sleep "${FAKE_SSH_SLEEP:-0}"
    t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
    mkdir -p "$t/system"
    printf 'node %s\n' "$alias_name" >"$t/system/hostname.txt"
    if [[ "${FAKE_SSH_NO_MANIFEST_ALIAS:-}" != "$alias_name" ]]; then
      printf '{"node":"%s"}\n' "$alias_name" >"$t/manifest.jsonl"
    fi
    [[ "${FAKE_SSH_PEM_ALIAS:-}" == "$alias_name" ]] && printf 'cert\n' >"$t/system/leak.pem"
    tar -czf - -C "$t" .
    [[ "${FAKE_SSH_FAIL_ALIAS:-}" == "$alias_name" ]] && exit 2
    exit 0
    ;;
  *kubectl*)
    seen=0; kargs=()
    for a in "$@"; do
      if [[ $seen -eq 1 ]]; then kargs+=("$a"); continue; fi
      [[ "$a" == "kubectl" ]] && seen=1
    done
    exec kubectl "${kargs[@]}"
    ;;
  *)
    printf 'unexpected ssh remote: %s\n' "$remote" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$fakebin/kubectl" "$fakebin/ssh" "$fakebin/timeout"

ssh_key="$tmpdir/id_ed25519"
printf 'fake key\n' >"$ssh_key"
export FAKE_SSH_LOG="$tmpdir/ssh.log"
export FAKE_TIMEOUT_LOG="$tmpdir/timeout.log"
export FIXTURE_SSH="$ROOT/tests/fixtures/bin/ssh"

# external topology: a ceph node + a kube node
inventory="$tmpdir/inv-external.env"
cat >"$inventory" <<'EOF'
SSH_USER="tester"
ROOK_NAMESPACE="rook-ceph"
HOSTS=(
  "cephnode=10.0.0.1"
  "kubenode=10.0.0.9"
)
EOF

# ---------------------------------------------------------------------------
# auto: dual-layer collection (ceph from cephnode, rook from kubenode), --context
# ---------------------------------------------------------------------------
out_auto="$tmpdir/out-auto"
: >"$FAKE_SSH_LOG"
FAKE_CEPH_TARGETS="10.0.0.1" FAKE_KUBE_TARGETS="10.0.0.9" \
PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" --ssh-key "$ssh_key" \
  --mode auto --kube-context lab --out "$out_auto" --since 24h --timeout 5 --node-timeout 90
bundle_auto="$(find_bundle "$out_auto")"
assert_archive_contains "$bundle_auto" "cluster/ceph/json/status.json"
assert_archive_contains "$bundle_auto" "cluster/rook/pods-wide.txt"
assert_archive_contains "$bundle_auto" "nodes/cephnode/system/hostname.txt"
assert_archive_contains "$bundle_auto" "nodes/kubenode/system/hostname.txt"
grep -qF -- '--context lab' "$FAKE_SSH_LOG" || fail "rook kubectl missing --context in auto mode"
grep -qF '10.0.0.9 kubectl' "$FAKE_SSH_LOG" || fail "rook kubectl did not run on the kube node"
grep -qx '90' "$FAKE_TIMEOUT_LOG" || fail "node wrapper should use --node-timeout 90"

# ---------------------------------------------------------------------------
# auto with NO capable nodes: both layers SKIPPED, nodes still collected, exit 2
# ---------------------------------------------------------------------------
out_nocap="$tmpdir/out-nocap"
nocap_status=0
set +e
FAKE_CEPH_TARGETS="" FAKE_KUBE_TARGETS="" \
PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" --ssh-key "$ssh_key" \
  --mode auto --out "$out_nocap" --since 24h --timeout 5
nocap_status=$?
set -e
[[ "$nocap_status" == "2" ]] || fail "auto with no capable node should exit 2, got $nocap_status"
bundle_nocap="$(find_bundle "$out_nocap")"
assert_archive_contains "$bundle_nocap" "cluster/ceph/SKIPPED.txt"
assert_archive_contains "$bundle_nocap" "cluster/rook/SKIPPED.txt"
assert_archive_contains "$bundle_nocap" "nodes/cephnode/system/hostname.txt"

# ---------------------------------------------------------------------------
# explicit --mode cephadm --seed: only ceph layer, no kubectl probing/collection
# ---------------------------------------------------------------------------
out_ceph="$tmpdir/out-ceph"
: >"$FAKE_SSH_LOG"
PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" --ssh-key "$ssh_key" \
  --seed tester@10.0.0.1 --mode cephadm --out "$out_ceph" --since 24h --timeout 5
bundle_ceph="$(find_bundle "$out_ceph")"
assert_archive_contains "$bundle_ceph" "cluster/ceph/json/status.json"
grep -qF 'kubectl' "$FAKE_SSH_LOG" && fail "cephadm mode should not run kubectl" || true

# ---------------------------------------------------------------------------
# two cephadm nodes: cluster ceph collected from the FIRST only
# ---------------------------------------------------------------------------
inv_two="$tmpdir/inv-two-ceph.env"
cat >"$inv_two" <<'EOF'
SSH_USER="tester"
HOSTS=(
  "c1=10.0.0.1"
  "c2=10.0.0.2"
)
EOF
out_two="$tmpdir/out-two"
: >"$FAKE_SSH_LOG"
FAKE_CEPH_TARGETS="10.0.0.1 10.0.0.2" FAKE_KUBE_TARGETS="" \
PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inv_two" --ssh-key "$ssh_key" \
  --mode auto --out "$out_two" --since 24h --timeout 5
grep -qF '10.0.0.1 sudo -n cephadm shell -- ceph status --format json-pretty' "$FAKE_SSH_LOG" \
  || fail "cluster ceph should be collected from first cephadm node"
grep -qF '10.0.0.2 sudo -n cephadm shell -- ceph status' "$FAKE_SSH_LOG" \
  && fail "cluster ceph must not be collected twice" || true

# ---------------------------------------------------------------------------
# node-level orchestration (use cephadm --seed to keep the cluster layer simple)
# ---------------------------------------------------------------------------
run_nodecase() {
  # $1=outdir ; remaining env set by caller
  PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
    --inventory "$inventory" --ssh-key "$ssh_key" \
    --seed tester@10.0.0.1 --mode cephadm --out "$1" --since 24h --timeout 5
}

# C4: truncated node (no manifest) -> SKIPPED, exit 2
out_nomani="$tmpdir/out-nomani"
st=0; set +e
FAKE_SSH_NO_MANIFEST_ALIAS=kubenode run_nodecase "$out_nomani"
st=$?; set -e
[[ "$st" == "2" ]] || fail "missing node manifest should exit 2, got $st"
assert_archive_contains "$(find_bundle "$out_nomani")" "nodes/kubenode/SKIPPED.txt"

# bad tar -> SKIPPED, exit 2
out_badtar="$tmpdir/out-badtar"
st=0; set +e
FAKE_SSH_BAD_TAR_ALIAS=kubenode run_nodecase "$out_badtar"
st=$?; set -e
[[ "$st" == "2" ]] || fail "bad node tar should exit 2, got $st"
assert_archive_contains "$(find_bundle "$out_badtar")" "nodes/kubenode/SKIPPED.txt"

# one failed host -> exit 2, errors.log present
out_fail="$tmpdir/out-fail"
st=0; set +e
FAKE_SSH_FAIL_ALIAS=kubenode run_nodecase "$out_fail"
st=$?; set -e
[[ "$st" == "2" ]] || fail "one failed host should exit 2, got $st"
assert_archive_contains "$(find_bundle "$out_fail")" "errors.log"

# C2: abort mid-run -> trap cleans workdir (no tmp.* left)
out_abort="$tmpdir/out-abort"
set +e
COLLECT_TEST_ABORT_AFTER_NODES=1 PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" --ssh-key "$ssh_key" \
  --seed tester@10.0.0.1 --mode cephadm --out "$out_abort" --since 24h --timeout 5 >/dev/null 2>&1
abort_status=$?
set -e
[[ "$abort_status" != "0" ]] || fail "abort hook should exit non-zero"
leftover="$(find "$out_abort" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
[[ "$leftover" == "0" ]] || fail "abort left $leftover tmp workdir(s)"

# C3: verify failure (forbidden secret path) -> exit 1, workdir kept, no bundle
out_verify="$tmpdir/out-verify"
set +e
FAKE_SSH_PEM_ALIAS=kubenode PATH="$fakebin:$PATH" "$ROOT/run/collect.sh" \
  --inventory "$inventory" --ssh-key "$ssh_key" \
  --seed tester@10.0.0.1 --mode cephadm --out "$out_verify" --since 24h --timeout 5 >/dev/null 2>&1
verify_status=$?
set -e
[[ "$verify_status" == "1" ]] || fail "verify failure should exit 1, got $verify_status"
produced="$(find "$out_verify" -maxdepth 1 -name 'ceph-incident-*.tar.gz' 2>/dev/null | wc -l | tr -d '[:space:]')"
[[ "$produced" == "0" ]] || fail "verify failure must not package a bundle"
kept="$(find "$out_verify" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
[[ "$kept" == "1" ]] || fail "verify failure should keep the workdir (found $kept)"

printf 'ok: collect orchestration\n'
