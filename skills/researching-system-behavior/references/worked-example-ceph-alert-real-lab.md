# Worked Example: ceph-alert-real-lab

This is a backtest, not a new experiment. The `ceph-alert-real-lab` effort
(experiments/ceph-alert-real-lab/, evidence committed in
`EVIDENCE-SUMMARY-2026-07-04.md`, findings published at
`next-site/content/ceph/features/prometheus-alert-real-lab-findings.mdx`) ran
before this skill existed. This file retrofits that effort onto the loop —
charter, hypotheses, state machine, synthesis — to show that the framework
would have produced the same findings by enumeration, and to serve as the
skill's teaching example.

Every factual detail below (result directory names, exact metric expressions,
injection methods, timestamps) is quoted or paraphrased from the two source
files named above. Nothing here is invented.

## Charter (as it would have been written at Frame)

```markdown
# ceph-alert-real-lab — Hypothesis Backlog

## Charter
- Goal: verify the redesigned Ceph alert rules (`CephClientBlocked`,
  `CephMonQuorumLost`) fire on real faults, not just synthetic `promtool`
  cases.
- Scope: in — CephClientBlocked (SLOW_OPS, PG_AVAILABILITY paths),
  CephMonQuorumLost (quorum-loss detection). Out — the full
  `ceph-production-coverage` group (only promtool-validated at the time,
  real fault injection deferred).
- Version anchors: Ceph v19.2.3; cephadm lab (3 mon, 9 OSD); Rook external
  on the isolated k0s node; temporary Prometheus + Alertmanager + webhook
  sink in the lab k8s cluster.
- Tiers available: T1 — Ceph source (health check / mgr prometheus module);
  T2 — Ceph docs (health check semantics, PromQL reference); T3 — the real
  cephadm + Rook lab cluster, destructible (mon/OSD stop-restart tested
  with rollback).
```

## Three hypotheses, walked through the state machine

The point is to show these hypotheses were reachable *before* any fault was
injected — the matrix produces the cell, the cell produces the hypothesis,
each one starting life as `Status: proposed`, and only then does the
experiment either confirm or violate it. The entries below show the
terminal state each one actually reached (`synthesized`, since all three
findings were published), with a `State trace` line spelling out the full
progression from `proposed` through to that terminal state.

### H-101: `CephClientBlocked` fires within its window on real SLOW_OPS

```markdown
### H-101: Under a real disk-path slowdown on an acting OSD, CephClientBlocked{name="SLOW_OPS"} fires within its 1m window
- Status: synthesized
- State trace: proposed → predicted → confirmed → synthesized
- Tier: T3
- Origin: matrix "osd × slow × signal arrives"
- Prediction: injecting a realistic disk-path slowdown (not a synthetic
  metric write) produces Ceph health code SLOW_OPS, which the mgr
  prometheus module exports as `ceph_health_detail{name="SLOW_OPS"}==1`,
  which crosses the `for: 1m` window and reaches Alertmanager as
  `state="firing"` routed to the pager receiver.
- Evidence: `results/slow-ops-20260704T101128Z.jVmRwg` — fault injected via
  cgroup v2 `io.max` throttling `osd.6`'s backing device `/dev/sdb` on
  `192.168.18.174` while `rados bench` wrote to the test pool;
  `health-check-SLOW_OPS.txt` shows `SLOW_OPS` (alongside
  `BLUESTORE_SLOW_OP_ALERT`, a co-occurring but distinct signal);
  `prometheus-alerts-CephClientBlocked-name.json` shows
  `state="firing"`, `name="SLOW_OPS"`,
  `activeAt="2026-07-04T10:12:42.762155964Z"`; sink log confirms the
  alert reached the pager receiver.
- Artifacts: none — documented decision: rule fired as designed, no change
  needed (per synthesis-rules.md).
```

The prediction was written before the injection ran: exact signal
(`ceph_health_detail{name="SLOW_OPS"}`), expected value (`==1`, crossing
the window), and an independently checkable window (`for: 1m`). The
experiment (`inject → observe → collect → rollback → assert`) matched the
prediction exactly (`confirmed`), and the finding was written up on the
findings page with no rule change needed, closing the loop at
`synthesized`.

### H-102: `CephClientBlocked{name="PG_AVAILABILITY"}` fires when acting OSDs stop

```markdown
### H-102: Under acting-OSD stop dropping a PG below min_size, CephClientBlocked{name="PG_AVAILABILITY"} fires within its 1m window
- Status: synthesized
- State trace: proposed → predicted → confirmed → synthesized
- Tier: T3
- Origin: matrix "osd × crash × signal arrives"
- Prediction: stopping enough acting OSDs for a test-pool PG to fall below
  `min_size` produces Ceph health code PG_AVAILABILITY, exported as
  `ceph_health_detail{name="PG_AVAILABILITY"}==1`, crossing `for: 1m` and
  reaching the pager receiver as `state="firing"`.
- Evidence: `results/pg-availability-20260704T102730Z.v5y7kq` — stopped
  acting OSDs `5` and `8` for the test pool object;
  `health-check-PG_AVAILABILITY.txt` shows `PG_AVAILABILITY`, `OSD_DOWN`,
  and inactive PG `2.10`; `prometheus-alerts-CephClientBlocked-name.json`
  shows `state="firing"`, `name="PG_AVAILABILITY"`,
  `activeAt="2026-07-04T10:28:57.762155964Z"`; sink log confirms delivery
  to the pager receiver.
- Artifacts: none — documented decision: rule fired as designed, no change
  needed (per synthesis-rules.md).
```

Same shape as H-101: a clean crash-type fault (`osd × crash`), a signal that
arrives on time, prediction matches evidence (`confirmed`), written up with
no rule change needed (`synthesized`).

### H-103: `CephMonQuorumLost` fires when quorum is really lost

```markdown
### H-103: Under real mon quorum loss, CephMonQuorumLost fires within its 1m window
- Status: synthesized
- State trace: proposed → predicted → violated → synthesized
- Tier: T3
- Origin: matrix "mon × real fault × observer lying"
- Prediction: stopping enough mons to break the 3-mon majority causes
  `(count(ceph_mon_quorum_status == 1) or vector(0)) < 2` to evaluate true,
  crossing `for: 1m` and reaching the pager receiver as `state="firing"`
  once real quorum is lost — independent of which mon processes are down.
- Evidence: `results/mon-quorum-lost-20260704T103154Z.W6kB7d` — first
  stopped `ceph-lab-mon-01` and `ceph-lab-mon-03`; `ceph-quorum-after-stop.json`
  exits `255`, showing `ceph quorum_status` could no longer complete (real
  quorum loss, confirmed at the Ceph layer). But
  `prometheus-ceph-mon-quorum-status.json` still reports
  `sum(ceph_mon_quorum_status)=3` at this point — the single scraped mgr
  exporter kept reporting the pre-fault value. The rule did not fire here.
  Only after manually stopping `ceph-lab-mon-02` and the active mgr (killing
  the exporter itself) did `ceph_mon_quorum_status` become an empty series,
  the `or vector(0)` path took effect, and
  `prometheus-alerts-CephMonQuorumLost-none.json` shows `state="firing"`,
  `activeAt="2026-07-04T10:34:37.762155964Z"`; sink log confirms delivery
  to the pager receiver.
- Artifacts: rule doc updated with the empty-series-path caveat; a new
  exporter-blind scenario recorded; see Synthesis below.
- Notes: The prediction said the rule would fire on real quorum loss
  "independent of which mon processes are down" — false. It fired only via
  a different mechanism (empty-series fallback, after the observer itself
  died), not the intended detection path (falling `ceph_mon_quorum_status
  == 1` count). Outcome recorded in the evidence index as "Passed only on
  empty-series path; stale telemetry found."
```

This is the interesting one. The prediction was falsifiable and specific
enough to be wrong in an informative way: the rule *did* eventually fire, so
a coarse "did it page" check would have called this a pass. The prediction
was more precise than that — it named the mechanism (`ceph_mon_quorum_status`
count crossing below 2) — and that mechanism did not fire during the actual
quorum loss window: `violated`. It only reaches `synthesized` once all
three synthesis routes below are taken.

## The violated hypothesis's three synthesis routes

Per `synthesis-rules.md`, a `violated` finding is not done until all three
routes are taken. Here is what actually happened for H-103, in the order the
real effort executed them (all three did happen, just without the label):

**Report** — the finding was written up in
`next-site/content/ceph/features/prometheus-alert-real-lab-findings.mdx`,
with its own evidence table row and inline reasoning: *"這次真機結果讓我不建議把
`CephMonQuorumLost` 當唯一 quorum-loss detector"* ("real-machine results here mean I
would not recommend treating `CephMonQuorumLost` as the sole quorum-loss
detector"). The page keeps the evidence anchors: result dir, the two JSON
snapshots, the two `activeAt` timestamps.

**Artifact** — two concrete changes, both traceable to the finding:
1. The rule itself is documented as relying on the empty-series guard
   (`or vector(0)`) as a *necessary* fallback path, not just a defensive
   nicety — the finding shows it is the path that actually fired.
2. A new class of scenario was named for future test design: the
   "exporter-blind" scenario, where the fault kills the thing being
   monitored *and* the thing doing the monitoring stays silent about it.
   The findings page's proposed v2 alert set adds `CephMetricsAbsent`
   (`absent(ceph_health_status)`), `CephExporterAllDown` /
   `CephExporterTargetDown` (split all-down vs. single-target), and a
   documented need for a non-mgr-exporter MON observation path
   (node-exporter systemd collector cross-check) precisely because of this
   finding.

**Feedback** — the finding was generalized and appended to
`enumerating-adversarial-boundaries/references/axes.md` under
`## Accumulated Failure Classes` as **"Observer lying / stale telemetry"**:

> a metrics exporter kept reporting `sum(ceph_mon_quorum_status)=3` after
> real mon quorum loss; the alert only fired via the empty-series path.
> Source: experiments/ceph-alert-real-lab, 2026-07-04. Check: for every
> alert rule, what happens when its metric source freezes at the last
> healthy value?

That "Check:" question is now asked automatically in every future
enumeration pass over any monitoring system, not just Ceph.

With all three routes taken, H-103 becomes `Status: synthesized`.

## Closing note: enumeration, not luck

The matrix cell that produced H-103 — **"mon × real fault × observer
lying"** — exists in `enumerating-adversarial-boundaries/SKILL.md` as the
skill's own headline example, independent of this lab: *"a monitoring
exporter that keeps reporting healthy metrics after real quorum loss lives
in the cell 'mon × real fault × observer lying'."* That cell is reachable by
crossing three fixed axes (component: `mon`; failure-mode: the fixed
vocabulary includes `lying`; observation-path: does the signal report wrong
values) — it does not require having already seen this specific failure.

This is the value test for the whole framework: **the two confirmed
hypotheses (H-101, H-102) are useful, but the violated one (H-103) is the
one worth teaching from.** A team relying on open-ended "what else could go
wrong" review would very plausibly ship `CephMonQuorumLost` as-is, because
free-form brainstorming rarely reaches a cell where the thing you'd ask
("is quorum lost?") is answered confidently and wrongly by the very system
you'd ask it of. The matrix does not need luck, memory, or someone having
been burned by this exact failure before — it needs the observer to be
listed as a component with its own row, and the `lying` failure-mode column
to be filled in for it. Confirmed hypotheses validate that the rule works;
a violated hypothesis, forced into existence by the matrix before any
experiment ran, is what actually changed the artifact.
