---
name: enumerating-adversarial-boundaries
description: Use when a design, alert set, runbook, or research scope needs systematic boundary discovery — enumerate failure hypotheses with a component × failure-mode × observation-path matrix plus pre-mortem, negative-space, and multi-persona prompts, instead of open-ended "what else could go wrong" questioning. Works standalone for reviews; output can seed a HYPOTHESES.md research backlog.
---

# Enumerating Adversarial Boundaries

## Overview

Open-ended "anything else to watch for?" questions produce mediocre lists — they lean on whatever the reviewer happens to remember, and they skip whole categories of failure nobody thought to ask about. Structured enumeration axes force coverage of the cells humans skip by turning "what else could go wrong" into a grid that has to be filled in, cell by cell.

**Core claim:** a monitoring exporter that keeps reporting healthy metrics after real quorum loss lives in the cell "mon × real fault × observer lying". A matrix surfaces that cell — and forces someone to write a hypothesis for it — before any experiment is ever run. Free-form brainstorming almost never reaches it, because the failure is invisible from every signal the brainstormer trusts.

## When to Use

- Standalone, in design reviews, alert-set reviews, runbook reviews, or coverage checks — no experiments required.
- As the `Enumerate` stage of a larger system-behavior research loop, when hypotheses need to exist before any test is designed.

This skill only *proposes* hypotheses. It never runs experiments, never collects evidence, and never changes a hypothesis's status past `proposed`. Enumeration produces a backlog; validating that backlog is a separate concern outside this skill's scope.

## The Matrix

Build three axes for the system under study, then fill the cells.

**Component axis** — enumerate from the system's real topology, not from imagination: daemons, data paths, control paths, time, disk, network. Use the actual names in the system (e.g., `mon`, `osd`, `mgr`, `etcd`, `kubelet`) rather than generic placeholders.

**Failure-mode axis** — fixed vocabulary, always these five:

| Mode | Meaning |
|------|---------|
| `crash` | dies cleanly |
| `slow` | alive but degraded |
| `partial` | some replicas/paths broken |
| `stale` | alive but serving old state |
| `lying` | reports healthy while broken |

**Observation-path axis** — for every signal you rely on to know the system's state, ask: does the signal arrive? Does it arrive late? Does it report wrong values? The observer (exporter, agent, sidecar, log shipper) is part of the system under study, not a neutral window onto it, and gets its own row in the matrix like any other component.

Fill cells with falsifiable hypotheses — one per cell, or more if a cell has multiple distinct failure stories. A cell may be marked `N/A` only with a one-line justification (e.g., "N/A — this daemon has no persistent state, `stale` cannot apply").

## Prompt Patterns

Three prompts fill in coverage the matrix alone tends to miss:

- **Pre-mortem** — assume the artifact already failed silently; work backward to plausible causes.
- **Negative-space** — enumerate the full space of states/codes/inputs and mark what's covered vs. `UNCOVERED`.
- **Multi-persona** — run independent reviewers with different lenses over the same design in parallel.

Full prompt text for each is in [references/prompt-patterns.md](references/prompt-patterns.md).

## Completion Criteria

Enumeration is done when:

- Every failure-mode value (`crash`, `slow`, `partial`, `stale`, `lying`) appears in at least one filled cell.
- Every signal you rely on has an observation-path hypothesis.
- At least one pre-mortem pass and one negative-space pass have run.
- Each hypothesis is a single falsifiable sentence in the form "Under X, Y happens within Z", carrying:
  - `Status: proposed`
  - `Tier:` — `T1`, `T2`, or `T3`
  - `Origin:` — matrix cell, pre-mortem, negative-space, or persona

## Output Format

Each hypothesis is a heading plus three fields. One complete example:

```markdown
### H-007: If the active mgr dies during quorum loss, `ceph_mon_quorum_status` keeps its last value and no alert fires
- Status: proposed
- Tier: T3
- Origin: matrix "mon × real fault × observer lying"
```

If the caller has a `HYPOTHESES.md`, append new entries to it in this format. Otherwise, deliver the entries as a standalone findings list in the same format — the format does not change based on where it lands.

## Growing the Axes

Every enumeration is a chance to discover a failure class the axis template didn't have a slot for. When downstream work (a review, an incident, a real experiment) confirms a genuinely new class of failure, append it to [references/axes.md](references/axes.md) under `## Accumulated Failure Classes`, with provenance and a generalized "Check:" question. Future enumerations read that file first, so every new failure class earned once gets checked automatically from then on.
