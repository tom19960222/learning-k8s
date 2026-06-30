# Ceph Incident Bundle Per-node Auto-detect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From one inventory, auto-detect each node's capability (cephadm and/or kubectl) and collect the ceph layer and the rook layer accordingly, with a selectable kubectl context.

**Architecture:** A capability probe (`command -v` over ssh per node) picks a cluster-ceph source (first cephadm node, or `--seed`) and a cluster-rook source (first kubectl node). `auto` mode collects both layers if both sources exist. The rook collector is parametrized to run `kubectl` over ssh on the chosen node (or locally when no ssh target — backward compatible). Node-level collection is unchanged.

**Tech Stack:** Bash (`set -euo pipefail`, bash-3.2-safe on the workstation), existing test harness (fake `ssh`/`kubectl` on PATH + env-var fault injection + bundle assertions), `shellcheck` 0.11.

## Global Constraints

- Read-only tool; never mutate cluster state. (spec)
- bash-3.2-safe for workstation-run scripts: no `mapfile`/`readarray`, no namerefs; pass arrays via globals. (hardening lessons)
- Backward compatible: `--mode cephadm --seed ...` and the local-kubectl `collect_cluster_rook` path must keep working. (spec 相容性)
- `make validate` exit 0; `shellcheck lib/*.sh run/*.sh tests/*.sh` 0; commit `--no-gpg-sign`. (CLAUDE.md)
- Every behavior change gets a regression test in the existing harness. (spec 測試)

Working dir for paths: `experiments/ceph-incident-bundle/`.

---

## Task 1: `--kube-context` flag plumbed through collect.sh

**Files:** Modify `run/collect.sh` (usage, arg parse, main local, pass to cluster collection). Test: `tests/test-collect.sh` (assert `--help` lists it; unknown-flag still errors).

**Interfaces:** Produces `kube_context` (default `''`) available to the cluster-collection step.

- [ ] **Step 1: failing test** — in `tests/run-tests.sh` the collect.sh `--help` check exists; add to `tests/test-collect.sh` after the help assertions:
```bash
[[ "$help_output" == *"--kube-context"* ]] || fail "help should document --kube-context"
```
- [ ] **Step 2: run** `bash tests/test-collect.sh` → FAIL.
- [ ] **Step 3: implement** in `run/collect.sh`: add `--kube-context CTX` to `usage`; add `local kube_context=''`; add parse case `--kube-context) kube_context=${2-}; shift 2 ;;`.
- [ ] **Step 4: run** `bash tests/run-tests.sh` → ok.
- [ ] **Step 5: commit** `git add -A && git commit --no-gpg-sign -m "ceph-incident-bundle: add --kube-context flag"`

## Task 2: rook collector runs kubectl over ssh (ssh-target/ssh-key/kube-context) + robust pod lookup

**Files:** Modify `lib/collect-cluster-rook.sh`. Test: `tests/test-rook-collector.sh`, and the fake `kubectl` lookup in `tests/test-collect.sh` (jsonpath → `-o name`).

**Interfaces:**
- Produces `collect_cluster_rook` accepting `--ssh-target USER@HOST --ssh-key PATH --kube-context CTX` in addition to existing flags. Internally a `rook_kubectl_argv` array prefixes every kubectl call: `ssh -i KEY <robust opts> TARGET kubectl [--context CTX]` when `--ssh-target` set, else `kubectl [--context CTX]`.
- `rook_get_first_pod` uses `-o name` (no jsonpath braces — safe over ssh).

- [ ] **Step 1: failing test** — in `tests/test-rook-collector.sh`, after the present-mode block, add a remote case using a fake ssh that forwards to the fake kubectl:
```bash
# remote (ssh-target) mode: kubectl runs via ssh, with --context
cat >"$fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
# args: -i key <opts> target kubectl <kubectl args...>; drop everything up to and incl. 'kubectl'
shift_to_kubectl=0; argv=()
for a in "$@"; do
  if [[ $shift_to_kubectl -eq 1 ]]; then argv+=("$a"); continue; fi
  [[ "$a" == "kubectl" ]] && shift_to_kubectl=1
done
exec kubectl "${argv[@]}"
EOF
chmod +x "$fakebin/ssh"
out_remote="$tmpdir/out-remote"; manifest_remote="$tmpdir/manifest-remote.jsonl"
FAKE_KUBECTL_MODE=with-toolbox PATH="$fakebin:$PATH" "$BASH_BIN" "$ROOT/lib/collect-cluster-rook.sh" \
  --out "$out_remote" --manifest "$manifest_remote" --namespace rook-ceph --since 24h --timeout 5 \
  --ssh-target tester@node2 --ssh-key "$tmpdir/key" --kube-context lab
assert_file_contains "$out_remote/cluster/rook/toolbox-status.txt" "cluster is healthy from toolbox"
grep -qF -- '--context lab' "$FAKE_SSH_LOG" || fail "remote kubectl missing --context"
```
  Add `printf k >"$tmpdir/key"` near the inventory setup. Update the fake kubectl in this file: change the two `-o jsonpath={.items[0].metadata.name}` cases to `-o name` returning `pod/rook-ceph-operator-0` / `pod/rook-ceph-tools-0`.
- [ ] **Step 2: run** `bash tests/test-rook-collector.sh` → FAIL (unknown `--ssh-target`).
- [ ] **Step 3: implement** in `lib/collect-cluster-rook.sh`:
  - parse `--ssh-target`, `--ssh-key`, `--kube-context` into `ssh_target='' ssh_key='' kube_context=''`.
  - build prefix after parsing:
```bash
local -a rook_kubectl_argv
if [[ -n "$ssh_target" ]]; then
  rook_kubectl_argv=(ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o "ConnectTimeout=$timeout" -o "ServerAliveInterval=$timeout" -o ServerAliveCountMax=1 "$ssh_target" kubectl)
else
  rook_kubectl_argv=(kubectl)
fi
[[ -n "$kube_context" ]] && rook_kubectl_argv+=(--context "$kube_context")
```
  - presence check: `if [[ -z "$ssh_target" ]] && ! command -v kubectl ...; then rook_skip; return (allow_skip?0:2); fi` (skip local check when remote).
  - replace every `kubectl` with `"${rook_kubectl_argv[@]}"` (namespace get, the three run_capture calls, and `rook_get_first_pod`).
  - `rook_get_first_pod`: `"${rook_kubectl_argv[@]}" get pods -n "$namespace" -l "$label" -o name 2>/dev/null | head -n1 | sed 's#^pod/##'`.
- [ ] **Step 4: run** `bash tests/run-tests.sh` → ok (update test-collect fake kubectl `-o name` too if its rook path asserts pods).
- [ ] **Step 5: commit** `--no-gpg-sign -m "ceph-incident-bundle: rook collector can run kubectl over ssh with --context"`

## Task 3: capability probe + dual cluster collection in collect.sh

**Files:** Modify `run/collect.sh` (parse HOSTS to globals before cluster step; add `detect_node_caps`, `collect_clusters`; replace `run_cluster_collector` call). Test: `tests/test-collect.sh`.

**Interfaces:**
- Produces globals `HOST_ALIASES=()` / `HOST_TARGETS=()` set in `main` from `HOSTS`.
- `detect_node_caps TARGET SSH_KEY TIMEOUT` → echoes a space-joined subset of `cephadm kubectl`.
- `collect_clusters MODE WORKDIR MANIFEST SEED SSH_KEY SINCE TIMEOUT ROOK_NS KUBE_CTX` → picks sources, runs cephadm and/or rook collectors, returns 0/2.

- [ ] **Step 1: failing test** — in `tests/test-collect.sh`, add an external-topology case. The fake ssh (already forwards node tars) must also answer the cap probe and remote kubectl. Add to the inline fake ssh: if the remote command contains `command -v cephadm`, emit caps per `FAKE_CAP_<alias>`; if it contains `kubectl`, forward to fake kubectl. Inventory: `monitor01=10.0.0.1` (cap=cephadm via probe), `k8s1=10.0.0.9` (cap=kubectl). Assert bundle has BOTH `cluster/ceph/json/status.json` and `cluster/rook/pods-wide.txt`, and `--context lab` appears in ssh log. (Full fake-ssh code written during implementation; harness pattern already established.)
- [ ] **Step 2: run** `bash tests/test-collect.sh` → FAIL.
- [ ] **Step 3: implement** in `run/collect.sh`:
  - In `main`, after sourcing inventory, parse into globals:
```bash
HOST_ALIASES=(); HOST_TARGETS=()
for entry in "${HOSTS[@]}"; do
  [[ "$entry" == *=* ]] || { append_error "$workdir" "skipped malformed HOSTS entry: $entry"; node_failed=$((node_failed+1)); rc=2; continue; }
  HOST_ALIASES+=("${entry%%=*}"); HOST_TARGETS+=("$(ssh_target_for_host "${entry#*=}" "$ssh_user")")
done
```
  (move parsing before cluster step; node loop iterates these globals.)
  - `detect_node_caps`: ssh the target running `command -v cephadm` / `command -v kubectl`, echo caps; wrap in `timeout_cmd` like other ssh calls.
  - `collect_clusters`: pick `ceph_source` (= `$seed` if set, else first target whose caps include cephadm) and `rook_source` (first target whose caps include kubectl) by probing each target once (cache caps; stop early once both found); then for `auto|cephadm` run `collect_cluster_cephadm` against `ceph_source`, for `auto|rook` run `collect_cluster_rook --ssh-target "$rook_source" --ssh-key ... --kube-context ...` (with `--allow-skip` only when mode=auto). Write a SKIPPED note + rc=2 when a requested layer has no source.
  - Replace the `run_cluster_collector ...` call in main with `collect_clusters "$mode" "$workdir" "$manifest" "$seed" "$ssh_key" "$since" "$timeout" "$rook_namespace" "$kube_context"`; keep capturing `cluster_rc`.
  - Node loop: iterate `"${!HOST_ALIASES[@]}"`.
- [ ] **Step 4: run** `bash tests/run-tests.sh` → ok.
- [ ] **Step 5: commit** `--no-gpg-sign -m "ceph-incident-bundle: per-node capability probe + dual cluster collection"`

## Task 4: backward-compat + edge tests

**Files:** Test: `tests/test-collect.sh`.

- [ ] **Step 1: tests** — assert: (a) `--mode cephadm --seed tester@seed` still collects only the ceph layer (no rook probe needed); (b) two cephadm-capable nodes ⇒ `cluster/ceph/json/status.json` collected once (one set of cephadm artifacts); (c) inventory with NO cephadm and NO kubectl in `auto` ⇒ both layers SKIPPED, node layer still collected, exit 2.
- [ ] **Step 2: run** → FAIL where behavior missing.
- [ ] **Step 3: implement** any gaps surfaced (e.g. explicit-mode short-circuits the probe; skip-note artifacts).
- [ ] **Step 4: run** `bash tests/run-tests.sh` → ok.
- [ ] **Step 5: commit** `--no-gpg-sign -m "ceph-incident-bundle: auto-detect backward-compat + edge tests"`

## Task 5: shellcheck, README, validate

- [ ] `shellcheck lib/*.sh run/*.sh tests/*.sh` → fix to 0.
- [ ] README: replace the two-inventory external-ceph guidance with the single-inventory auto-detect flow; document `--kube-context`; note `--seed` = cluster-ceph source override; one inventory mixing external ceph hosts + k8s node.
- [ ] `make validate` exit 0.
- [ ] commit `--no-gpg-sign -m "ceph-incident-bundle: docs + shellcheck for auto-detect"`.

---

## Self-Review

- **Spec coverage:** decisions 1–4 → Tasks 1–3; dual collection + dedup → Task 3; backward compat → Task 4; error handling/exit codes → Tasks 3–4; docs → Task 5. Covered.
- **Placeholders:** Task 3 Step 1's full fake-ssh body is written at implementation against the established harness pattern; all signatures/behaviors are specified.
- **Type/name consistency:** `HOST_ALIASES`/`HOST_TARGETS`, `detect_node_caps`, `collect_clusters`, `rook_kubectl_argv`, `--ssh-target`/`--ssh-key`/`--kube-context`, `ceph_source`/`rook_source` used consistently across tasks.
