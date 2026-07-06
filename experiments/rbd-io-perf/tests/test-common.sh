#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export FAKE_SSH_LOG="$tmp/ssh.log"; : > "$FAKE_SSH_LOG"
export FAKE_SSH_DIR="$tmp/replies"; mkdir -p "$FAKE_SSH_DIR"
export PATH="$here/fakes:$PATH"
export RESULTS_DIR="$tmp/results"
# shellcheck disable=SC1091  # test-time relative source
. "$here/../lib/common.sh"

# 1. pve_ssh 走 fake、帶正確 user@host 與指令
printf 'ok\n' > "$FAKE_SSH_DIR/qm list"
out="$(pve_ssh 'sudo -n qm list')"
[ "$out" = "ok" ] || { echo "pve_ssh reply wrong: $out"; exit 1; }
grep -q 'ioperf@192.168.16.7' "$FAKE_SSH_LOG" || { echo "no user@host"; exit 1; }
grep -q 'sudo -n qm list' "$FAKE_SSH_LOG" || { echo "no cmd"; exit 1; }

# 2. require_inject_flag 擋住無旗標呼叫
if ( require_inject_flag --foo ) 2>/dev/null; then echo "gate not enforced"; exit 1; fi
( require_inject_flag --yes-really-inject ) || { echo "gate false positive"; exit 1; }

# 3. new_bundle 建目錄且 stdout 只有路徑
b="$(new_bundle smoke)"
[ -d "$b" ] || { echo "bundle dir missing"; exit 1; }
case "$b" in "$RESULTS_DIR/smoke/"*) : ;; *) echo "bad bundle path: $b"; exit 1 ;; esac
echo OK
