---
name: designing-falsifiable-experiments
description: Use when writing an experiment or fault-injection scenario that must be safe to run and honest about its results — enforces prediction-before-run, the inject → observe → collect → rollback → assert contract, idempotency and pre-checks, and machine comparison of predicted vs observed outcomes.
---

# Designing Falsifiable Experiments

## Overview

An experiment without a written prediction is a demo, not a test. The single most valuable output of an experiment is a *violated* prediction, and post-hoc rationalization ("oh, that's expected") silently destroys it — so the prediction is written down before injection and compared by machine, never by eye.

## The Contract

Every scenario runs through five phases, in order, each with its own obligation:

- **inject** — one fault, smallest realistic mechanism. Prefer resource-level injection over process kill when studying degradation, e.g. cgroup v2 `io.max` throttling instead of remapping a live device.
- **observe** — watch the *declared* signals for the *declared* window; the window is part of the prediction, not an afterthought decided while watching.
- **collect** — write the evidence bundle before any cleanup; a scenario that fails after rollback must still leave evidence on disk.
- **rollback** — reverse the injection based on **observed state**, not on command exit codes (a dropped ssh session does not mean the netem rule was removed).
- **assert** — verify return to the recorded baseline (e.g. `HEALTH_OK` plus warning-history cleanup) before the scenario may report success or the next scenario may start.

The contract string, verbatim: `inject → observe → collect → rollback → assert`.

## Prediction Before Run

The scenario header declares, machine-checkably:

- expected signal(s), by exact name
- expected state/value
- time window
- rollback criterion

On completion the runner compares observed vs predicted and marks the run `confirmed` or `violated`. A `violated` run is a *successful* run that found something — it is not a failure of the scenario, and it must never be quietly reclassified as "expected" after the fact. The comparison is scripted, not eyeballed, precisely so that reclassification cannot happen.

## Safety Boundaries

A scenario is automation-safe only if it is:

- idempotent — running it twice in a row does not compound damage or require manual intervention between runs
- fully reversible — the rollback phase can always restore the recorded baseline
- gated by a pre-check — ok-to-stop / quorum check / capacity check, and the scenario aborts if the pre-check fails

Anything destructive or irreversible is human-driven, step by step, per the repository's destructive-operation rules (in this repo: `AGENTS.md`). This skill never grants autonomy over those operations — it only shapes what an automatable scenario must look like once a human has decided it may run.

## Evidence Bundle

A bundle is raw command outputs + timestamps + the prediction + the verdict, written into a per-run directory kept out of git. A committed `EVIDENCE-SUMMARY-<date>.md` indexes runs with: scenario, injection method, evidence files, outcome.

See [references/scenario-checklist.md](references/scenario-checklist.md) for the pre-flight checklist to run before any scenario is executed.

## Scenario Skeleton

A language-agnostic skeleton showing the declaration block and the five phases:

```
SCENARIO: <name>
PREDICTION:
  signal: <exact alert/metric/log name>
  expected: <state or value>
  window: <duration>
BASELINE: <recorded pre-run state>
PRE-CHECK: <ok-to-stop / quorum / capacity check — abort if it fails>
1. inject:   <single fault, smallest realistic mechanism>
2. observe:  <poll declared signal for declared window>
3. collect:  <write raw outputs + prediction into bundle dir>
4. rollback: <reverse injection; verify by observed state>
5. assert:   <baseline restored; emit verdict: confirmed | violated>
```
