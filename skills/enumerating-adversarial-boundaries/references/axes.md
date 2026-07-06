# Enumeration Axes Reference

Reusable template for the three enumeration axes. Read the `## Accumulated Failure Classes`
section below before starting a new enumeration — every class listed there was earned by
a real review or incident, and belongs in the matrix or prompt pass for the next one too.

## Axis Template

**Component axis** — enumerate from the system's real topology: daemons, data paths,
control paths, time, disk, network. Use the system's actual component names, not
placeholders.

**Failure-mode axis** — fixed vocabulary, always these five:

- `crash` — dies cleanly
- `slow` — alive but degraded
- `partial` — some replicas/paths broken
- `stale` — alive but serving old state
- `lying` — reports healthy while broken

**Observation-path axis** — for every signal relied on: does it arrive? Does it arrive
late? Does it report wrong values? The observer is part of the system and gets its own
row.

## Accumulated Failure Classes

- **Observer lying / stale telemetry** — a metrics exporter kept reporting
  `sum(ceph_mon_quorum_status)=3` after real mon quorum loss; the alert only
  fired via the empty-series path. Source: experiments/ceph-alert-real-lab,
  2026-07-04. Check: for every alert rule, what happens when its metric
  source freezes at the last healthy value?
- **Catch-all absorption** — a low-severity health code
  (POOL_APP_NOT_ENABLED) matched a critical catch-all rule. Check: enumerate
  every health code the catch-all can match, not just the intended ones.
- **Signal co-occurrence** — SLOW_OPS arrived together with
  BLUESTORE_SLOW_OP_ALERT; merging them into one page hides the engine-level
  signal. Check: which signals fire together, and should they page separately?
