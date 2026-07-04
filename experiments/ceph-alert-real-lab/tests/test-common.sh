#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/Users/ikaros/Documents/code/learning-k8s/experiments/ceph-alert-real-lab/lib/common.sh
source "$ROOT/lib/common.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

root="$(lab_root)"
[[ "$root" == "$ROOT" ]] || fail "lab_root should be $ROOT, got $root"

result_dir="$(new_result_dir smoke)"
[[ -d "$result_dir" ]] || fail "new_result_dir did not create directory"
[[ "$result_dir" == "$ROOT/results/smoke-"* ]] || fail "unexpected result dir: $result_dir"
second_result_dir="$(new_result_dir smoke)"
[[ -d "$second_result_dir" ]] || fail "second new_result_dir did not create directory"
[[ "$second_result_dir" == "$ROOT/results/smoke-"* ]] || fail "unexpected second result dir: $second_result_dir"
[[ "$second_result_dir" != "$result_dir" ]] || fail "new_result_dir returned the same path twice"

opts_file="$(mktemp)"
ssh_base_opts "$ROOT/test-key" 7 >"$opts_file"
grep -qx -- '-i' "$opts_file" || fail "ssh opts missing -i"
grep -qx -- "$ROOT/test-key" "$opts_file" || fail "ssh opts missing key path"
grep -qx -- '-o' "$opts_file" || fail "ssh opts missing -o entries"
grep -qx -- 'IdentitiesOnly=yes' "$opts_file" || fail "ssh opts missing IdentitiesOnly"
grep -qx -- 'IdentityAgent=none' "$opts_file" || fail "ssh opts missing IdentityAgent"
grep -qx -- 'ConnectTimeout=7' "$opts_file" || fail "ssh opts missing ConnectTimeout"

ack_out_file="$(mktemp)"
ack_err_file="$(mktemp)"
if require_destructive_ack scenario-name >"$ack_out_file" 2>"$ack_err_file"; then
  fail "require_destructive_ack should fail without --yes-really-inject"
fi
grep -q 'requires --yes-really-inject' "$ack_err_file" || fail "ack failure message missing"
require_destructive_ack scenario-name --yes-really-inject

capture_file="$(mktemp)"
if ! run_capture "$capture_file" bash -c 'printf stdout-line; printf stderr-line >&2'; then
  fail "run_capture should return success"
fi
grep -q 'stdout-line' "$capture_file" || fail "run_capture missed stdout"
grep -q 'stderr-line' "$capture_file" || fail "run_capture missed stderr"
grep -q '# exit_code: 0' "$capture_file" || fail "run_capture did not record exit code"

capture_guard_file="$(mktemp)"
capture_guard_err_file="$(mktemp)"
if run_capture "$capture_guard_file" 2>"$capture_guard_err_file"; then
  fail "run_capture should fail when no command is provided"
fi
grep -Eq 'requires at least an output file and a command|missing command' "$capture_guard_file" || fail "run_capture guard message missing from output file"
grep -Eq 'requires at least an output file and a command|missing command' "$capture_guard_err_file" || fail "run_capture guard message missing from stderr"

attempt_file="$(mktemp)"
printf 0 >"$attempt_file"
# shellcheck disable=SC2016
poll_until "counter reaches 2" 5 0 bash -c 'n=$(cat "$1"); n=$((n+1)); printf "%s" "$n" >"$1"; test "$n" -ge 2' _ "$attempt_file"
[[ "$(cat "$attempt_file")" == "2" ]] || fail "poll_until did not retry until success"

ok "common helpers"
