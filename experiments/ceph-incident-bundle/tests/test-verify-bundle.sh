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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

make_valid_bundle_dir() {
  local dir=$1
  mkdir -p \
    "$dir/cluster/ceph" \
    "$dir/nodes/monitor01/system"

  cat >"$dir/manifest.jsonl" <<'EOF'
{"bundle":"ceph-incident"}
EOF
  printf 'summary\n' >"$dir/summary.txt"
  printf 'read me first\n' >"$dir/README-FIRST.txt"
  printf 'ok\n' >"$dir/cluster/ceph/status.txt"
  printf 'monitor01\n' >"$dir/nodes/monitor01/system/hostname.txt"
}

make_bundle_archive() {
  local source_dir=$1 archive_path=$2
  tar -C "$source_dir" -czf "$archive_path" .
}

assert_pass() {
  local target=$1
  local result status output

  result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$target")"
  status="${result%%$'\n'*}"
  output="${result#*$'\n'}"
  [[ "$status" == "0" ]] || fail "expected success for $target, got status $status: $output"
  [[ "$output" == "VERIFY PASS: $target" ]] || fail "unexpected pass output: $output"
}

assert_fail() {
  local target=$1 expected=$2
  local result status output

  result="$(run_and_capture "$ROOT/lib/verify-bundle.sh" "$target")"
  status="${result%%$'\n'*}"
  output="${result#*$'\n'}"
  [[ "$status" != "0" ]] || fail "expected failure for $target"
  [[ "$output" == *"$expected"* ]] || fail "failure output did not mention '$expected': $output"
}

valid_dir="$tmpdir/valid-dir"
mkdir -p "$valid_dir"
make_valid_bundle_dir "$valid_dir"

valid_archive="$tmpdir/valid-bundle.tar.gz"
make_bundle_archive "$valid_dir" "$valid_archive"

missing_manifest_dir="$tmpdir/missing-manifest"
mkdir -p "$missing_manifest_dir"
make_valid_bundle_dir "$missing_manifest_dir"
rm -f "$missing_manifest_dir/manifest.jsonl"

keyring_dir="$tmpdir/keyring-bundle"
mkdir -p "$keyring_dir/cluster/ceph" "$keyring_dir/nodes/node01/system"
cat >"$keyring_dir/manifest.jsonl" <<'EOF'
{"bundle":"ceph-incident"}
EOF
printf 'summary\n' >"$keyring_dir/summary.txt"
printf 'read me first\n' >"$keyring_dir/README-FIRST.txt"
printf 'secret\n' >"$keyring_dir/cluster/ceph/keyring"
printf 'node01\n' >"$keyring_dir/nodes/node01/system/hostname.txt"

ssh_dir="$tmpdir/ssh-bundle"
mkdir -p "$ssh_dir/cluster/ceph" "$ssh_dir/nodes/node01/.ssh"
cat >"$ssh_dir/manifest.jsonl" <<'EOF'
{"bundle":"ceph-incident"}
EOF
printf 'summary\n' >"$ssh_dir/summary.txt"
printf 'read me first\n' >"$ssh_dir/README-FIRST.txt"
printf 'ok\n' >"$ssh_dir/cluster/ceph/status.txt"
printf 'secret\n' >"$ssh_dir/nodes/node01/.ssh/id_ed25519"

private_key_dir="$tmpdir/private-key-bundle"
mkdir -p "$private_key_dir/cluster/ceph" "$private_key_dir/nodes/node01/system"
cat >"$private_key_dir/manifest.jsonl" <<'EOF'
{"bundle":"ceph-incident"}
EOF
printf 'summary\n' >"$private_key_dir/summary.txt"
printf 'read me first\n' >"$private_key_dir/README-FIRST.txt"
printf 'secret\n' >"$private_key_dir/cluster/ceph/private_key"
printf 'node01\n' >"$private_key_dir/nodes/node01/system/hostname.txt"

assert_pass "$valid_dir"
assert_pass "$valid_archive"
assert_fail "$missing_manifest_dir" "manifest.jsonl"
assert_fail "$keyring_dir" "keyring"
assert_fail "$ssh_dir" ".ssh"
assert_fail "$private_key_dir" "private_key"
