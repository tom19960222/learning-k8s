---
name: writing-experiment-reports
description: Use when turning a completed batch of experiments or research evidence (ledgers, hypothesis backlogs, raw numbers) into a standalone report for a manager or colleague who did not participate and will only read this one document — or when a report draft got rejected with "I can't tell what you actually tested, what worked, or what to change".
---

# Writing Experiment Reports

## Overview

A report for a non-participant is a different artifact from a findings summary. The natural failure is writing a narrative digest ("four big findings") that the writer finds elegant but the reader cannot interrogate: they finish it unable to say what was tested, what was predicted, or what to set a parameter to. This skill is the contract and recipe that prevents that.

**Core principle: the reader has ONLY this report.** Before shipping, they must be able to answer all seven: (1) premises — system, environment, judgment criteria; (2) what experiments were planned and why; (3) what parameter each one adjusted, over what values; (4) what was predicted beforehand; (5) what happened, with effect sizes; (6) the concrete recommendation per parameter; (7) the overall conclusion and what to do next.

## When to Use

- A research effort finished (evidence ledger + hypothesis backlog exist) and the results must reach people outside the loop.
- A draft report bounced with feedback like「看不出調了哪些參數」「哪些有用哪些沒用」.
- NOT for: progress updates mid-research (use the ledger), or single-experiment writeups (the six-field protocol already covers those).

## The Recipe

Follow `report-template.md` in this directory for the section skeleton. The load-bearing parts:

1. **Premises are a section, not a scatter.** SUT spec (CPU/RAM/OS/disk), load matrix (every pattern × duration × repetitions), judgment thresholds, and credibility defenses (noise band, effectiveness pre-checks, interleaving) live together up front. If a metric denominator appears later ("22/26 metrics in band"), its universe is defined here.
2. **Planning overview table covers every PLANNED experiment** — including the ones not run, each with its reason. Bookkeeping must reconcile: planned = executed + merged-into-others + skipped. One row per experiment: parameter (value range, default marked) / why / prediction / result, with ✅ hit ❌ overturned ➖ indistinguishable markers.
3. **Per-experiment detail uses five fixed fields**: parameter adjusted / why tested / prediction (written before the run) / result (before→after numbers + multiplier) / recommendation. Group chapters by experiment purpose (performance vs stability/fault-injection vs changeability) so the classification is visible in the table of contents.
4. **Prediction stays separate from result.** Overturned predictions are the highest-value content — mark them loudly, never blend them into the result prose.
5. **Effect sizes are numbers, not adjectives.** "p99 7.6→55.8ms (×7.4)" — always before value, after value, multiplier. If the mean hides the story, say so and report the percentile that shows it.
6. **Every conclusion carries its applicability condition in the same sentence.** "Losing a whole host is a non-event" must become "…when recovered before the auto-out threshold (only 4 min tested)". A caveat in a distant limitations section does not cancel an unconditional sentence.
7. **A parameter recommendation table** closes the loop: parameter / recommended value / evidence (experiment id) / effect size / how changeable (runtime, restart, rebuild). Recommendations must be executable — a value and a condition, not "should be monitored" (give starting thresholds and where the existing rules live).
8. **Reader test for jargon**: zero undefined internal codenames (project nicknames, priority codes, hypothesis ids). Domain terms the audience may lack get a 2–3 line primer in §0, placed before first use.
9. **Honest sections survive**: limitations (what is environment-bound vs mechanism-level), incidents during the research, and open questions — these buy credibility, keep them.

## Review Gate (required)

Before delivery, spawn a reviewer subagent with a manager persona who reads ONLY the report, grading each of the seven reader questions PASS/WEAK/FAIL with quoted locations, plus: undefined-jargon hunt, internal contradictions, over-extrapolated conclusions. Fix, re-review with the same reviewer until ACCEPT. Content errors the reviewer finds (not just style) must be back-ported to every other artifact that makes the same claim.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Narrative "key findings" replaces per-experiment structure | Findings synthesis comes AFTER the tables, as §summary — not instead of them |
| SUT spec discoverable only by inference from result cells | Premises section owns it |
| "significant/almost/much better" without numbers | before→after + multiplier, every time |
| Prediction only implied by verdict labels | Explicit prediction field per experiment |
| Unconditional extrapolation of a bounded result | Condition into the sentence itself |
| Internal codenames (priority tiers, repo nicknames) | Define or remove; run the reader test |
| Recommendation = "pay attention to X" | Value + condition + where the rules/thresholds live |
| Skipping the review gate because the draft "looks complete" | The v1 that bounced also looked complete; the gate found a decision-affecting error (over-extrapolation) style-reading missed |
