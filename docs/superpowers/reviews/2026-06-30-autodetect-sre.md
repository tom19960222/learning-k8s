# SRE — auto-detect feature (2026-06-30). Read-only verdict confirmed.

## HIGH
- Down kubectl/cephadm node during probe is downgraded to "absent": detect_node_caps returns "" on ssh failure, so a capable-but-down node never sets the source; cluster/<layer>/SKIPPED.txt says "no X-capable node in inventory (auto)" — misleading. (Exit code is still 2 in practice because the node loop also fails that node; but the message and the silent layer-drop are wrong.) Fix: distinguish "no node advertised X" from "X node present but unreachable/failed"; surface a precise reason + ensure rc=2.
- Bundle never records which node was the ceph_source / rook_source, nor a precise skip reason. ceph_source/rook_source are function-local; summary prints only (empty in auto) seed; rook manifest rows hardcode host="rook". Fix: write ceph_source/rook_source to environment.txt + summary; pass real rook target as the manifest host.

## MED
- Serial pre-collection probe: when a capability is absent (pure-cephadm auto still probes all nodes for kubectl) or the node is last/down, every node probed serially; no timeout binary on workstation → ~ConnectTimeout per node. Large inventories slow. Fix: document; lower probe-only connect timeout; (parallel = out of scope).
- "First capable" is liveness-blind: an SSH-up but ceph-wedged node becomes ceph_source; no fallback to a second capable node. Fix: cheap liveness check and/or fallback to next; at minimum document + recommend --seed to pin a known-good mon.

## LOW
- --allow-skip semantics only correct together with the down-node fix (#1).
- probe swallows stderr+rc (2>/dev/null || true) → auth/transient failures look like "incapable". Fix: log probe failures with target+rc.

## Verified OK
- Safety: probe = command -v only; cephadm/rook commands read-only; sudo -n/BatchMode fail closed. No mutation.
- Unreachable-during-probe node STILL attempted for node-level collection (HOST_TARGETS parsed independently) → gets its own SKIPPED + rc=2. Correct.
- Exit-semantics: healthy pure-cephadm auto → exit 0; no-capable-node auto → exit 2 (tested); explicit/no-source → 2.
