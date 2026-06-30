# Code Reviewer — auto-detect feature (2026-06-30)

## HIGH
- run/collect.sh detect_node_caps/collect_clusters — probe ssh failure is indistinguishable from "node has no caps" (`2>/dev/null || true`). If the only cephadm node is briefly unreachable during probe, ceph_source stays empty → ceph layer SKIPPED; if rook succeeded the run still exits 0 ("complete" bundle missing the whole ceph layer, nothing logged). Fix: detect_node_caps should distinguish ssh-failure (capture rc; append_error/log "probe ssh failed: target") so a dropped source is visible.

## MED
- collect-cluster-rook.sh remote kubectl over ssh — kubectl args passed as separate words; ssh re-joins with spaces, NO quoting. Today's args are metachar-free, but `--context "$kube_context"`, namespace, `-l label`, `--since=` are interpolated; a value with space/`$`/`;`/glob would word-split or inject in the remote shell (esp. `exec -- ceph status`). Fix: shell-quote each remote kubectl arg (printf %q) when ssh_target set.
- collect_clusters --seed in auto suppresses probe fallback: an unreachable/typo'd seed sets ceph_done=1 and auto never probes the real cephadm nodes. Likely intended (override) but document precedence; optionally fall back to probe if seeded ceph fails.
- collect-cluster-rook.sh remote kubectl-missing presents as "namespace not found" (skipped local `command -v` when ssh_target). Misleading reason. Fix: generic skip wording or distinguish ssh exit 127.

## LOW
- collect.sh `for entry in "${HOSTS[@]}"` unguarded: an inventory with `HOSTS=()` under bash 3.2 + set -u errors (unbound) before graceful handling. Fix: guard `${#HOSTS[@]} -gt 0`.
- rook_get_first_pod pipes through head|sed → ssh failure yields rc0/empty → "pod not found" SKIPPED instead of failure. Document or check rc.
- collect_cluster_rook: no check that ssh_key non-empty when ssh_target set (`ssh -i ''`). Fix: validate.
- collect_clusters 9 positional args, no arity guard (not a live bug).

## No regressions
trap cleanup, verify-keeps-evidence, redaction, manifest-required node check, set+e/cluster_rc capture, exit-semantics (auto/one→0, auto/neither→2, explicit/no-source→2) all intact.
