# Triage — auto-detect QA review (2026-06-30)

Consolidated from Code Reviewer + SRE + codex (R: C/S/X). Baseline was green (tests/shellcheck/make validate).

## Fix (real)
| id | sev | reviewers | issue | fix |
|----|-----|-----------|-------|-----|
| A1 | HIGH | X | auto sets rook_done=1 even when rook only allow-skipped (namespace/context missing); with no ceph layer → exit 0, nothing collected | rook_done=1 only if real artifact (pods-wide.txt) exists; auto neither-collected → exit 2 |
| A2 | MED | X | rook_get_first_pod lost `\|\| true`; set -e + pipefail abort on remote pod-lookup ssh failure (regression vs old) | add `\|\| true` to the lookup pipeline |
| A3 | HIGH | C,S | capability probe ssh-failure indistinguishable from "no caps" (2>/dev/null \|\| true) → dropped source silent | detect_node_caps logs probe ssh failures to ERROR_LOG with target+rc |
| A4 | HIGH | S | bundle never records which node was ceph_source/rook_source | append ceph_source/rook_source to environment.txt |
| A5 | LOW | C | `for entry in "${HOSTS[@]}"` unguarded → bash 3.2 + set -u unbound on `HOSTS=()` | guard `${#HOSTS[@]} -gt 0` |
| A6 | MED | C | remote kubectl args (kube_context) reach remote shell unquoted via ssh space-join | validate kube_context charset (kubectl contexts are `[A-Za-z0-9._-]`); reject others |
| A7 | MED | C | remote kubectl-missing presents as "namespace not found" | generic skip wording mentioning target |

## Document only (no code change this pass)
- liveness-blind "first capable" source selection (no fallback to 2nd node); recommend `--seed` to pin a known-good mon. (S MED)
- serial probe latency on large/partly-down inventories; auto probes all nodes when a capability is absent. (S MED)

## Confirmed clean (all reviewers)
probe/seed/early-break logic, bash-3.2 empty-array guards in the collect_clusters/node loops, remote kubectl argv for fixed args, local rook path, dedup, and NO regression to prior hardening (trap, verify-keeps-evidence, redaction, timeouts, manifest-required node check).
