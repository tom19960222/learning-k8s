# Code Reviewer — best practices (KISS/DRY/SOLID) — 2026-07-01

All findings behavior-preserving; no correctness bugs. shellcheck 0, suite thorough.

## HIGH
- **SSH base-options duplicated 5×** (collect.sh detect_node_caps/ceph_runner_probe/collect_remote_node, collect-cluster-cephadm.sh, collect-cluster-rook.sh): same `-o BatchMode/IdentitiesOnly/IdentityAgent/ConnectTimeout/ServerAlive*` vector hand-written. Drift risk. → `ssh_base_opts ssh_key timeout` helper in common.sh emitting one opt/line (bash-3.2 read-array idiom); command strings stay byte-identical (tests grep them).
- **collect.sh too large / SRP** (~600 lines, 8+ jobs). Library-shaped helpers (parse_host_entry, ssh_target_for_host, shell_quote, append_error, write_summary, write_initial_metadata, redact_bundle_text) belong in a lib. → extract to lib (e.g. common.sh / new lib), source it; leaves collect.sh = parse→hosts→orchestrate→finalize. Single call sites → safe.

## MED
- **collect_clusters 11 positional args** (single caller) → reduce via shared locals/globals (house style already uses HOST_TARGETS/ERROR_LOG globals) or named; at least avoid `${10:-}`/`${11:-}` index math.
- **4 near-identical skip-artifact writers** (rook_skip, rook_write_skip_artifact, node write_skip_artifact, write_cephadm_crash_skip) + inline skip blocks in collect_clusters → one `write_skip_artifact artifact reason` in common.sh.
- **spec-loop `name::command` duplicated** (cephadm json+text loops, node basic_specs) → `run_spec_list collector_fn` helper reading specs on stdin; keep per-collector progress counter in caller.
- **`ceph_incident_bundle_log` dead code** (common.sh) → delete.

## LOW
- `parse_host_entry` dead code (collect.sh) → delete.
- rook/node have standalone `usage`+guard, cephadm doesn't → pick one convention + comment.
- arg-parse case dup across 3 files → **LEAVE** (generic bash parser is less readable; real KISS>DRY tradeoff); optional `# --- arg parse ---` banner.
- `eval "$nocasematch_state"` in redact_file → replace with plain if/else branch (no eval).
- `ceph_runner_for` always `return 0` (empty stdout = none) → add one-line contract comment.
- manifest hand-built JSON → fine (zero-dep); optional comment naming the escaped-char set.

## Already good (don't touch)
124/137 timeout distinction + truncation markers; "valid archive but no manifest ⇒ fail"; verify-before/after-package with workdir retention; bash-3.2 empty-array guards + read-array idiom (don't modernize to mapfile); verify-bundle.sh small single-purpose functions = the SRP model.
