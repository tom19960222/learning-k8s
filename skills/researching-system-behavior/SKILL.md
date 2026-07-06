---
name: researching-system-behavior
description: Use when researching how a real system behaves under faults, limits, or unknowns and the findings must become verified reports and concrete artifacts — runs the Frame → Enumerate → Falsify → Automate → Synthesize loop with a HYPOTHESES.md backlog, three human gates, and evidence-anchored claims. For technical systems with a verifiable source of truth (pinned source code, live cluster, reproducible environment).
---

# Researching System Behavior

## Overview

AI's leverage in systems research is three things: exhaustive enumeration (humans skip cells, AI doesn't tire), adversarial pressure (cheap "try to break this" perspectives), and closing the loop from claim to evidence to artifact without shortcuts. The human keeps two jobs: deciding what is worth depth (priority/taste) and gating irreversible actions. Everything else is automated between three gates.

## Preconditions

A source of truth exists and is pinned (version/commit/cluster); claims that cannot be anchored to it are out of scope for this skill.

## The Loop

One subsection per stage. Each subsection states: entry condition (backlog state), what the AI does, exit condition, and which reference file has the details.

### Stage: Frame

- **Entry condition:** no backlog yet, or a new research question outside the current charter.
- **What the AI does:** preliminary research FIRST (scan the pinned source/env so questions have substance), then a one-question-at-a-time dialog mapping the user's knowledge boundary across three zones (known / known-unknown / unknown-unknown). **Rule: any question the user cannot answer, or answers with "not sure", becomes a hypothesis in the backlog.**
- **Exit condition:** charter header + seed hypotheses written into `HYPOTHESES.md`.
- **Details:** [references/framing-dialog.md](references/framing-dialog.md).

Note: interaction style borrows from brainstorming-type skills (one question at a time) but the goal differs — mapping knowledge boundaries, not converging on a design.

### Stage: Enumerate

- **Entry condition:** charter and seed hypotheses exist in `HYPOTHESES.md`.
- **What the AI does:** invoke [../enumerating-adversarial-boundaries/SKILL.md](../enumerating-adversarial-boundaries/SKILL.md); append its output to `HYPOTHESES.md` as `proposed`.
- **Exit condition:** the matrix and prompt-pattern passes are complete per that skill's own completion criteria, and every new hypothesis is appended with `Status: proposed`.

### ⛩ Gate 1 — backlog triage

STOP. Human ranks/prunes the backlog. Do not proceed on your own.

### Stage: Falsify

- **Entry condition:** at least one `proposed` hypothesis in the backlog, selected by the human at Gate 1.
- **What the AI does:** per hypothesis, three-tier evidence (T1 source → T2 docs → T3 live env; details in [references/evidence-tiers.md](references/evidence-tiers.md)); parallel fan-out allowed.
- **Exit condition:** ends when a machine-comparable prediction is written into the entry → status `predicted`. Research that ends in "understood" without a prediction is not done.

### Stage: Automate

- **Entry condition:** hypothesis is `predicted`.
- **What the AI does:** run experiments per [../designing-falsifiable-experiments/SKILL.md](../designing-falsifiable-experiments/SKILL.md) (`inject → observe → collect → rollback → assert`, prediction compared by machine).
- **Exit condition:** status becomes `confirmed` or `violated`.

### ⛩ Gate 2 — destructive operations

Anything irreversible or destructive is human-driven per the repository's destructive-operation rules (in this repo: `AGENTS.md`); automation-safe scenarios may run unattended.

### Stage: Synthesize

- **Entry condition:** hypothesis is `confirmed` or `violated`.
- **What the AI does:** every finding takes all three routes (report / artifact change / feedback to axes; details in [references/synthesis-rules.md](references/synthesis-rules.md)).
- **Exit condition:** status becomes `synthesized`.

### ⛩ Gate 3 — findings triage

STOP. Human decides which findings deserve depth or publication. Violated hypotheses and new failure classes flow back into the backlog and `axes.md`.

## Backlog State Machine

```
proposed → predicted → confirmed | violated → synthesized
```

| State | Set by stage | Required fields before entering |
|---|---|---|
| `proposed` | Enumerate (or Frame, for seed hypotheses) | `Status`, `Tier`, `Origin` |
| `predicted` | Falsify | `Prediction:` — exact signal, expected value, window |
| `confirmed` \| `violated` | Automate | `Evidence:` — file:line, bundle dir, command output path |
| `synthesized` | Synthesize | `Artifacts:` — files changed because of this finding |

## Entering Mid-Loop

The backlog file is the state; resume from whatever state its entries are in (e.g. entries in `predicted` → start at Automate). If no `HYPOTHESES.md` exists, start at Frame. A standalone enumeration findings list can be adopted as a backlog by adding the charter header.

## Driving Discipline

- One falsifiable question at a time (Frame's job is to convert vague asks into specific ones).
- Producer ≠ verifier — the session that writes a rule never validates it; use an independent agent or a different model.
- Artifacts are cross-session memory — `HYPOTHESES.md`, evidence summaries, axes — the next session resumes from files, not from chat history.

## Output Adapters

The loop is output-agnostic. In learning-k8s: report route uses `../source-first-topic-page/SKILL.md`, diagrams use `../fireworks-tech-graph/SKILL.md`, quizzes use `../quiz-generation/SKILL.md`. In other repos: substitute the local reporting conventions; the three-route rule itself does not change.
