# System Behavior Research Skill Set Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the three-skill set (`researching-system-behavior` core + `enumerating-adversarial-boundaries` and `designing-falsifiable-experiments` satellites) specified in `docs/superpowers/specs/2026-07-06-system-behavior-research-skillset-design.md`.

**Architecture:** One orchestrator skill owns the Frame → Enumerate → Falsify → Automate → Synthesize loop, the three human gates, and the `HYPOTHESES.md` state machine. Two satellite skills are standalone-usable and referenced (one-way) by the core. All cross-stage state lives in files (`HYPOTHESES.md`, `axes.md`, evidence bundles), never in conversation memory.

**Tech Stack:** Markdown skill files only (SKILL.md + references/). No code. Verification via grep consistency checks, `make validate`, subagent smoke tests, and the superpowers:writing-skills checklist.

## Global Constraints

Copied from the approved spec — every task implicitly includes these:

- All skill files are written in **English**, model-agnostic (same convention as `skills/analyzing-source-code`).
- Skill frontmatter is exactly two fields: `name:` and `description:`; description starts with "Use when".
- Stage names, exact: `Frame`, `Enumerate`, `Falsify`, `Automate`, `Synthesize`.
- Hypothesis status values, exact strings: `proposed`, `predicted`, `confirmed`, `violated`, `synthesized`.
- Gate names, exact: `Gate 1 — backlog triage`, `Gate 2 — destructive operations`, `Gate 3 — findings triage`.
- File contract names, exact: `HYPOTHESES.md` (per research), `references/axes.md` (satellite 1, globally accumulated), `EVIDENCE-SUMMARY-<date>.md` (committed evidence index; raw bundles stay out of git).
- Verification tiers, exact: `T1` = pinned source code, `T2` = official docs cross-check, `T3` = live environment.
- Coupling: core references satellites by relative path; **satellites must never mention the core skill or each other**.
- Gate 2 defers to the repo's existing destructive-operation rules in `AGENTS.md` (ok-to-stop pre-check → inject → collect → immediate rollback → confirm baseline) — reference, don't rewrite.
- Every commit: `make validate` must exit 0 first; commit with `git commit --no-gpg-sign`; commit message ends with the Claude co-author line.
- Acceptance item #1 from the spec (full dry-run on a real new topic) is **deliberately out of this plan** — it runs as the first real use of the skill set on the next research topic. This plan covers acceptance items #2 (backtest), #3 (satellite standalone), #4 (writing-skills validation).

---

### Task 1: Satellite 1 — `enumerating-adversarial-boundaries`

**Files:**
- Create: `skills/enumerating-adversarial-boundaries/SKILL.md`
- Create: `skills/enumerating-adversarial-boundaries/references/axes.md`
- Create: `skills/enumerating-adversarial-boundaries/references/prompt-patterns.md`

**Interfaces:**
- Consumes: nothing (standalone).
- Produces: skill name `enumerating-adversarial-boundaries` and a hypothesis entry format (fields: falsifiable statement, `Status:`, `Tier:`, `Origin:`) that Task 3's `hypothesis-backlog.md` must match field-for-field.

- [ ] **Step 1: Read the authoring guide**

Invoke `superpowers:writing-skills` and keep its checklist in mind for all three files. Also read one existing repo skill for tone/shape: `skills/analyzing-source-code/SKILL.md`.

- [ ] **Step 2: Write `SKILL.md`**

Frontmatter, verbatim:

```markdown
---
name: enumerating-adversarial-boundaries
description: Use when a design, alert set, runbook, or research scope needs systematic boundary discovery — enumerate failure hypotheses with a component × failure-mode × observation-path matrix plus pre-mortem, negative-space, and multi-persona prompts, instead of open-ended "what else could go wrong" questioning. Works standalone for reviews; output can seed a HYPOTHESES.md research backlog.
---
```

Required sections and content:

1. `## Overview` — Open-ended "anything else to watch for?" questions produce mediocre lists; structured enumeration axes force coverage of cells humans skip. State the core claim with the canonical example: a monitoring exporter that keeps reporting healthy metrics after real quorum loss lives in the cell "mon × real fault × observer lying" — a matrix surfaces that cell before any experiment is run.
2. `## When to Use` — standalone in reviews / design gating / coverage checks (no experiments required), or as Stage `Enumerate` of a larger research loop. Explicitly: this skill only *proposes* hypotheses; it never runs experiments.
3. `## The Matrix` — instructions to build three axes for the system under study:
   - Component axis: enumerate from the system's real topology (daemons, data paths, control paths, time, disk, network).
   - Failure-mode axis, fixed vocabulary: `crash` (dies cleanly), `slow` (alive but degraded), `partial` (some replicas/paths broken), `stale` (alive but serving old state), `lying` (reports healthy while broken).
   - Observation-path axis: for every signal you rely on — does the signal arrive? arrive late? report wrong values? The observer is part of the system and gets its own row.
   Fill cells with falsifiable hypotheses. A cell may be marked `N/A` only with a one-line justification.
4. `## Prompt Patterns` — one-line summary each of pre-mortem, negative-space, multi-persona; point to `references/prompt-patterns.md` for full prompts.
5. `## Completion Criteria` — enumeration is done when: every axis value appears in at least one filled cell; every relied-upon signal has an observation-path hypothesis; at least one pre-mortem and one negative-space pass ran; each hypothesis is a single falsifiable sentence ("Under X, Y happens within Z") with `Status: proposed`, a `Tier:` (T1/T2/T3), and an `Origin:` (matrix cell / pre-mortem / negative-space / persona).
6. `## Output Format` — show one complete example entry:

```markdown
### H-007: If the active mgr dies during quorum loss, `ceph_mon_quorum_status` keeps its last value and no alert fires
- Status: proposed
- Tier: T3
- Origin: matrix "mon × real fault × observer lying"
```

State that entries are appended to the caller's `HYPOTHESES.md` when one exists, or delivered as a standalone findings list otherwise.
7. `## Growing the Axes` — new failure classes discovered downstream get appended to `references/axes.md` so every future enumeration covers them automatically.

- [ ] **Step 3: Write `references/axes.md`**

Content: the reusable axis template (the three axes with the fixed failure-mode vocabulary from Step 2) plus an `## Accumulated Failure Classes` section seeded with the classes already earned by this repo, each with a one-line provenance:

```markdown
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
```

Plus instructions at the top: append one bullet per newly confirmed failure class, always with provenance and a generalized "Check:" question.

- [ ] **Step 4: Write `references/prompt-patterns.md`**

Full prompt text for each pattern, ready to copy:

1. **Pre-mortem** — "Assume `<artifact>` failed silently during a real incident. Write five distinct causes, at least one involving the observation path itself, at least one involving human/process factors."
2. **Negative-space** — "Enumerate the complete set of `<all possible states/codes/inputs>` for `<system>`. For each, name the existing `<rule/handler/doc>` that covers it, or mark UNCOVERED. Output only the UNCOVERED list."
3. **Multi-persona** — dispatch the same design to independent reviewers with distinct lenses (operator woken at 3am; correctness reviewer against pinned source; adversary trying to make the artifact mislead). Instruct that personas run in parallel without seeing each other's output, then results are deduplicated.

Each pattern gets a "When it beats the matrix" note (pre-mortem finds compound failures; negative-space finds missing coverage; personas find framing blind spots).

- [ ] **Step 5: Consistency checks**

Run: `grep -rn "researching-system-behavior\|designing-falsifiable-experiments" skills/enumerating-adversarial-boundaries/`
Expected: no output (satellite knows nothing about core or sibling).

Run: `grep -c "Status: proposed" skills/enumerating-adversarial-boundaries/SKILL.md`
Expected: `1` or more (example entry present).

- [ ] **Step 6: Validate and commit**

```bash
make validate
git add skills/enumerating-adversarial-boundaries
git commit --no-gpg-sign -m "Add enumerating-adversarial-boundaries skill

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

Expected: validate exits 0; commit succeeds.

---

### Task 2: Satellite 2 — `designing-falsifiable-experiments`

**Files:**
- Create: `skills/designing-falsifiable-experiments/SKILL.md`
- Create: `skills/designing-falsifiable-experiments/references/scenario-checklist.md`

**Interfaces:**
- Consumes: nothing (standalone).
- Produces: skill name `designing-falsifiable-experiments`; the five-phase contract string `inject → observe → collect → rollback → assert` that Task 3's SKILL.md quotes verbatim.

- [ ] **Step 1: Write `SKILL.md`**

Frontmatter, verbatim:

```markdown
---
name: designing-falsifiable-experiments
description: Use when writing an experiment or fault-injection scenario that must be safe to run and honest about its results — enforces prediction-before-run, the inject → observe → collect → rollback → assert contract, idempotency and pre-checks, and machine comparison of predicted vs observed outcomes.
---
```

Required sections and content:

1. `## Overview` — an experiment without a written prediction is a demo, not a test. The single most valuable output of an experiment is a *violated* prediction, and post-hoc rationalization ("oh, that's expected") silently destroys it — so the prediction is written down before injection and compared by machine, never by eye.
2. `## The Contract` — the five phases, each with its obligation:
   - `inject`: one fault, smallest realistic mechanism (prefer resource-level injection over process kill when studying degradation, e.g. cgroup v2 `io.max` throttling instead of remapping a live device).
   - `observe`: watch the *declared* signals for the *declared* window; the window is part of the prediction.
   - `collect`: write the evidence bundle before any cleanup; a scenario that fails after rollback must still leave evidence on disk.
   - `rollback`: reverse the injection based on **observed state**, not on command exit codes (a dropped ssh session does not mean the netem rule was removed).
   - `assert`: verify return to the recorded baseline (e.g. `HEALTH_OK` plus warning-history cleanup) before the scenario may report success or the next scenario may start.
3. `## Prediction Before Run` — the scenario header declares, machine-checkably: expected signal(s) by exact name, expected state/value, time window, and rollback criterion. On completion the runner compares observed vs predicted and marks the run `confirmed` or `violated`; a `violated` run is a *successful* run that found something.
4. `## Safety Boundaries` — a scenario is automation-safe only if it is idempotent, fully reversible, and gated by a pre-check (ok-to-stop / quorum check / capacity check). Anything destructive or irreversible is human-driven, step by step, per the repository's destructive-operation rules (in this repo: `AGENTS.md`) — this skill never grants autonomy over those.
5. `## Evidence Bundle` — bundle = raw command outputs + timestamps + the prediction + the verdict, in a per-run directory kept out of git; a committed `EVIDENCE-SUMMARY-<date>.md` indexes runs with: scenario, injection method, evidence files, outcome. Point to `references/scenario-checklist.md`.
6. `## Scenario Skeleton` — a language-agnostic skeleton showing the declaration block and the five phases:

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

- [ ] **Step 2: Write `references/scenario-checklist.md`**

A pre-flight checklist, one line each, grouped:

- *Prediction*: signal named exactly as the monitoring system exposes it; window justified (rule `for:` duration + scrape interval + margin); verdict comparison is scripted, not eyeballed.
- *Safety*: pre-check exists and aborts on failure; injection reversible; rollback verified by observed state; baseline capture happens before injection; scenario re-runnable without manual cleanup.
- *Evidence*: bundle directory created before injection; every observation command's raw output saved; bundle survives scenario failure (collect before cleanup paths); committed summary index updated.
- *Isolation*: one fault per scenario; shared cleanup (e.g. warning-history reset) factored into a shared helper, not duplicated.

- [ ] **Step 3: Consistency checks**

Run: `grep -rn "researching-system-behavior\|enumerating-adversarial-boundaries" skills/designing-falsifiable-experiments/`
Expected: no output.

Run: `grep -c "inject → observe → collect → rollback → assert" skills/designing-falsifiable-experiments/SKILL.md`
Expected: `1` or more.

- [ ] **Step 4: Validate and commit**

```bash
make validate
git add skills/designing-falsifiable-experiments
git commit --no-gpg-sign -m "Add designing-falsifiable-experiments skill

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Core — `researching-system-behavior`

**Files:**
- Create: `skills/researching-system-behavior/SKILL.md`
- Create: `skills/researching-system-behavior/references/framing-dialog.md`
- Create: `skills/researching-system-behavior/references/hypothesis-backlog.md`
- Create: `skills/researching-system-behavior/references/evidence-tiers.md`
- Create: `skills/researching-system-behavior/references/synthesis-rules.md`

**Interfaces:**
- Consumes: satellite skill names and paths from Tasks 1–2 (`../enumerating-adversarial-boundaries/SKILL.md`, `../designing-falsifiable-experiments/SKILL.md`); satellite 1's entry fields (`Status:`/`Tier:`/`Origin:`); satellite 2's five-phase contract string.
- Produces: the `HYPOTHESES.md` template (used by Task 5's worked example) and the skill name `researching-system-behavior` (used by Task 4's AGENTS.md entry).

- [ ] **Step 1: Write `SKILL.md`**

Frontmatter, verbatim:

```markdown
---
name: researching-system-behavior
description: Use when researching how a real system behaves under faults, limits, or unknowns and the findings must become verified reports and concrete artifacts — runs the Frame → Enumerate → Falsify → Automate → Synthesize loop with a HYPOTHESES.md backlog, three human gates, and evidence-anchored claims. For technical systems with a verifiable source of truth (pinned source code, live cluster, reproducible environment).
---
```

Required sections and content:

1. `## Overview` — AI's leverage in systems research is three things: exhaustive enumeration (humans skip cells, AI doesn't tire), adversarial pressure (cheap "try to break this" perspectives), and closing the loop from claim to evidence to artifact without shortcuts. The human keeps two jobs: deciding what is worth depth (priority/taste) and gating irreversible actions. Everything else is automated between three gates.
2. `## Preconditions` — a source of truth exists and is pinned (version/commit/cluster); claims that cannot be anchored to it are out of scope for this skill.
3. `## The Loop` — one subsection per stage. Each subsection states: entry condition (backlog state), what the AI does, exit condition, and which reference file has the details.
   - `### Stage: Frame` — preliminary research FIRST (scan the pinned source/env so questions have substance), then a one-question-at-a-time dialog mapping the user's knowledge boundary across three zones (known / known-unknown / unknown-unknown). **Rule: any question the user cannot answer, or answers with "not sure", becomes a hypothesis in the backlog.** Output: charter header + seed hypotheses in `HYPOTHESES.md`. Details: `references/framing-dialog.md`. Note: interaction style borrows from brainstorming-type skills (one question at a time) but the goal differs — mapping knowledge boundaries, not converging on a design.
   - `### Stage: Enumerate` — invoke `../enumerating-adversarial-boundaries/SKILL.md`; append its output to `HYPOTHESES.md` as `proposed`.
   - `### ⛩ Gate 1 — backlog triage` — STOP. Human ranks/prunes the backlog. Do not proceed on your own.
   - `### Stage: Falsify` — per hypothesis: three-tier evidence (T1 source → T2 docs → T3 live env; details in `references/evidence-tiers.md`); parallel fan-out allowed; ends when a machine-comparable prediction is written into the entry → status `predicted`. Research that ends in "understood" without a prediction is not done.
   - `### Stage: Automate` — run experiments per `../designing-falsifiable-experiments/SKILL.md` (`inject → observe → collect → rollback → assert`, prediction compared by machine) → status `confirmed` or `violated`. `### ⛩ Gate 2 — destructive operations` — anything irreversible or destructive is human-driven per the repository's destructive-operation rules (in this repo: `AGENTS.md`); automation-safe scenarios may run unattended.
   - `### Stage: Synthesize` — every finding takes all three routes (report / artifact change / feedback to axes; details in `references/synthesis-rules.md`) → status `synthesized`. `### ⛩ Gate 3 — findings triage` — STOP. Human decides which findings deserve depth or publication. Violated hypotheses and new failure classes flow back into the backlog and `axes.md`.
4. `## Backlog State Machine` — verbatim:

```
proposed → predicted → confirmed | violated → synthesized
```

with a table: state / set by stage / required fields before entering (predicted requires `Prediction:`; synthesized requires `Artifacts:`).
5. `## Entering Mid-Loop` — the backlog file is the state; resume from whatever state its entries are in (e.g. entries in `predicted` → start at Automate). If no `HYPOTHESES.md` exists, start at Frame. A standalone enumeration findings list can be adopted as a backlog by adding the charter header.
6. `## Driving Discipline` — one falsifiable question at a time (Frame's job is to convert vague asks into specific ones); producer ≠ verifier (the session that writes a rule never validates it — use an independent agent or a different model); artifacts are cross-session memory (`HYPOTHESES.md`, evidence summaries, axes — the next session resumes from files, not from chat history).
7. `## Output Adapters` — the loop is output-agnostic. In learning-k8s: report route uses `../source-first-topic-page/SKILL.md`, diagrams use `../fireworks-tech-graph/SKILL.md`, quizzes use `../quiz-generation/SKILL.md`. In other repos: substitute the local reporting conventions; the three-route rule itself does not change.

- [ ] **Step 2: Write `references/framing-dialog.md`**

Content:

1. Preliminary research checklist (before asking anything): identify the system's components and versions; skim the main data/control paths in source; list the observability surfaces (metrics, logs, health outputs); note anything surprising — surprises are question fuel.
2. The three zones with 2–3 example question templates each:
   - Known: "You run X with Y — is Z the invariant you rely on?" (builds anchors)
   - Known-unknown: "You asked about X — what would you *expect* to happen? " (extracts the user's implicit prediction)
   - Unknown-unknown: "Your questions never touched `<area seen in preliminary research>` — do you know how it behaves when `<failure mode>`?" (the pre-mortem zone)
3. The conversion rule, verbatim: **"Any question the user cannot answer, or answers with 'not sure', is converted into a `proposed` hypothesis with `Origin: framing-dialog`."**
4. Charter fields the dialog must fill: goal (one falsifiable sentence), scope in/out, version anchors, which tiers are available in this environment (is there a live cluster? is it destructible?).
5. Exit condition: user confirms the charter; at least the known-unknown and unknown-unknown zones each contributed ≥1 backlog entry (a framing that only confirms known facts has failed).

- [ ] **Step 3: Write `references/hypothesis-backlog.md`**

The complete `HYPOTHESES.md` template, verbatim:

```markdown
# <topic> — Hypothesis Backlog

## Charter
- Goal: <one falsifiable research goal>
- Scope: <in / out>
- Version anchors: <project + version/commit; environment identifiers>
- Tiers available: <T1 source path; T2 doc sources; T3 environment + destructibility>

## Hypotheses

### H-001: <single falsifiable sentence: under X, Y happens within Z>
- Status: proposed
- Tier: T3
- Origin: <framing-dialog | matrix "<cell>" | pre-mortem | negative-space | persona | feedback>
- Prediction: <required before status: predicted — exact signal, expected value, window>
- Evidence: <required before confirmed/violated — file:line, bundle dir, command output path>
- Artifacts: <required before synthesized — files changed because of this finding>
- Notes:
```

Plus: numbering is `H-NNN`, append-only (never renumber); killed hypotheses get `Status: proposed` struck through with a one-line reason rather than deletion (rejected ideas must stay visible or they will be re-proposed every round); one file per research effort, living in that effort's working directory.

- [ ] **Step 4: Write `references/evidence-tiers.md`**

Content:

1. Tier definitions: T1 = pinned source (claims cite `file:line` at the pinned version); T2 = official docs (version-matched; docs may *suggest*, never *conclude* alone); T3 = live environment (raw command output saved to the evidence bundle).
2. Cross-check rule: a claim is research-grade when T1 and at least one other tier agree; a T2-only claim is a lead, not a finding.
3. Anchor format: every claim in any output carries its anchor inline — no anchor, no claim (zero-fabrication).
4. Fan-out guidance: hypotheses are independent — research them in parallel (subagents per hypothesis or per subsystem); convergence happens in the backlog file, and each writer updates only its own entries.
5. The finish line, verbatim: **"Research ends with a written prediction, not with understanding."**

- [ ] **Step 5: Write `references/synthesis-rules.md`**

Content:

1. The three routes, each mandatory per finding:
   - Report: the finding written for a future reader (evidence summary, feature page) with its evidence anchors.
   - Artifact: a concrete change — rule, script, runbook, config. Verbatim rule: **"A finding that changes no artifact is trivia."** If a finding is genuinely informational, the artifact route may be satisfied by a documented decision *not* to change anything, recorded with a reason — but that must be explicit, never silent.
   - Feedback: if the finding revealed a new failure class, append it to `enumerating-adversarial-boundaries/references/axes.md` with provenance and a generalized "Check:" question.
2. Gate 3 procedure: present findings grouped by verdict (`violated` first — they carry the most information), each with proposed route contents; human selects depth/publication; only then execute routes; set entries to `synthesized`.
3. Loop closure: `violated` entries spawn follow-up hypotheses (`Origin: feedback`); the loop ends when Gate 3 yields no new backlog entries, or the human closes the charter.

- [ ] **Step 6: Consistency checks**

Run: `grep -rn "proposed → predicted → confirmed | violated → synthesized" skills/researching-system-behavior/`
Expected: at least 1 match (SKILL.md).

Run: `grep -n "enumerating-adversarial-boundaries\|designing-falsifiable-experiments" skills/researching-system-behavior/SKILL.md`
Expected: both satellite paths referenced.

Run: `ls skills/enumerating-adversarial-boundaries/SKILL.md skills/designing-falsifiable-experiments/SKILL.md`
Expected: both exist (referenced paths resolve).

Run: `grep -rn "Status: proposed" skills/researching-system-behavior/references/hypothesis-backlog.md`
Expected: 1 match (template entry, field names identical to satellite 1's output format).

- [ ] **Step 7: Validate and commit**

```bash
make validate
git add skills/researching-system-behavior
git commit --no-gpg-sign -m "Add researching-system-behavior orchestrator skill

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Register the skill set in AGENTS.md

**Files:**
- Modify: `AGENTS.md` (add one subsection after 「分析單一新專題頁的方法論」; `CLAUDE.md` is a symlink and needs no change)

**Interfaces:**
- Consumes: the three skill names from Tasks 1–3.
- Produces: discoverability — future sessions reading AGENTS.md find the skill set.

- [ ] **Step 1: Add the subsection**

Insert after the 「### 分析單一新專題頁的方法論」 block, matching the file's zh-TW style:

```markdown
### 系統行為研究的方法論

當需求是「研究某個系統在故障／極限／未知情況下的行為，並產出報告 + script／alert rules 等 artifact」時，用 `skills/researching-system-behavior/SKILL.md`（Frame → Enumerate → Falsify → Automate → Synthesize 迴圈、三閘門、`HYPOTHESES.md` backlog）。兩顆衛星 skill 可單獨使用：

- `skills/enumerating-adversarial-boundaries/SKILL.md`：對任何設計／alert 集合做結構化邊界窮舉（review 把關可單用）。
- `skills/designing-falsifiable-experiments/SKILL.md`：寫任何「可回退、prediction 先行」的實驗 scenario 時單用。
```

- [ ] **Step 2: Verify symlink integrity**

Run: `ls -la CLAUDE.md && grep -c "系統行為研究的方法論" CLAUDE.md`
Expected: symlink to `AGENTS.md`; count `1`.

- [ ] **Step 3: Validate and commit**

```bash
make validate
git add AGENTS.md
git commit --no-gpg-sign -m "Register system-behavior-research skill set in AGENTS.md

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Backtest worked example (spec acceptance #2)

**Files:**
- Create: `skills/researching-system-behavior/references/worked-example-ceph-alert-real-lab.md`

**Interfaces:**
- Consumes: `HYPOTHESES.md` template from Task 3; axes vocabulary from Task 1; source material `experiments/ceph-alert-real-lab/EVIDENCE-SUMMARY-2026-07-04.md` and `next-site/content/ceph/features/prometheus-alert-real-lab-findings.mdx`.
- Produces: proof the framework reproduces the lab's key findings, doubling as the skill's teaching example.

- [ ] **Step 1: Write the worked example**

Retrospectively map the ceph-alert-real-lab effort onto the loop. Required content:

1. A filled-in charter (goal: "verify the redesigned Ceph alert rules fire on real faults"; anchors: Ceph v19.2.3, cephadm lab, Rook external on k0s; tiers: T1 ceph source, T2 Ceph docs, T3 the real cluster).
2. Three hypotheses written as backlog entries **as they would have looked before the experiments**, each walked through the full state machine:
   - `CephClientBlocked` fires within its window on real SLOW_OPS (matrix "osd × slow × signal arrives") → prediction → **confirmed** (evidence: `results/slow-ops-20260704T101128Z.jVmRwg`).
   - `CephClientBlocked{name="PG_AVAILABILITY"}` fires when acting OSDs stop (matrix "osd × crash × signal arrives") → **confirmed**.
   - `CephMonQuorumLost` fires when quorum is really lost (matrix "mon × real fault × observer lying") → prediction: fires within window → **violated**: the single scraped exporter kept reporting `sum(ceph_mon_quorum_status)=3`; the rule only fired via the empty-series `or vector(0)` path after the active mgr also died.
3. The violated hypothesis's three synthesis routes as they actually happened: report (`prometheus-alert-real-lab-findings.mdx`), artifact (rule relies on empty-series guard; exporter-blind scenario added), feedback (the "observer lying / stale telemetry" class in `axes.md`).
4. Closing note: the framework's value test — the matrix cell "mon × real fault × observer lying" exists *before* any experiment, so this finding is reachable by enumeration, not luck.

- [ ] **Step 2: Verify against sources**

Run: `grep -n "sum(ceph_mon_quorum_status)=3\|or vector(0)" experiments/ceph-alert-real-lab/EVIDENCE-SUMMARY-2026-07-04.md`
Expected: matches confirming the quoted evidence exists; every claim in the worked example must trace to that file or the findings MDX (zero-fabrication).

- [ ] **Step 3: Validate and commit**

```bash
make validate
git add skills/researching-system-behavior/references/worked-example-ceph-alert-real-lab.md
git commit --no-gpg-sign -m "Add ceph-alert-real-lab backtest worked example

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Satellite standalone smoke tests (spec acceptance #3)

**Files:**
- Create: none committed — outputs go to the session scratchpad directory only.

**Interfaces:**
- Consumes: Tasks 1–2 skill files.
- Produces: pass/fail evidence that each satellite works standalone; skill-text fixes if they fail.

- [ ] **Step 1: Smoke test satellite 1**

Dispatch a fresh subagent (it must have no context beyond the prompt):

> Read `skills/enumerating-adversarial-boundaries/SKILL.md` and its references. Apply it to the design in `docs/superpowers/specs/2026-06-29-ceph-incident-bundle-design.md`. Output only the findings list in the skill's output format, to `<scratchpad>/smoke-satellite1.md`. Do not run any experiments or modify any files outside the scratchpad.

Pass criteria (checked by the orchestrator, not the subagent):
- Every entry is a single falsifiable sentence with `Status: proposed`, `Tier:`, `Origin:`.
- At least one entry has an observation-path origin (the tool's own collection path failing).
- At least one entry originates from pre-mortem or negative-space.
- No experiments were attempted.

- [ ] **Step 2: Smoke test satellite 2**

Dispatch a fresh subagent:

> Read `skills/designing-falsifiable-experiments/SKILL.md` and its references. Draft a scenario skeleton (do NOT execute anything) for: "stop one of three Ceph mons, verify the mon-down alert fires, restore it." Write it to `<scratchpad>/smoke-satellite2.txt`.

Pass criteria:
- PREDICTION block present before the inject phase, naming an exact signal and window.
- All five phases present in order; rollback keyed to observed state; assert checks baseline restore.
- A PRE-CHECK (quorum/ok-to-stop) present.
- Nothing was executed against any cluster.

- [ ] **Step 3: Fix-and-rerun loop**

If a pass criterion fails, the defect is in the skill text (the subagent had nothing else). Fix the skill file, re-dispatch a fresh subagent, repeat until both pass.

- [ ] **Step 4: Commit any skill-text fixes**

```bash
make validate
git add skills/
git commit --no-gpg-sign -m "Harden satellite skills based on standalone smoke tests

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Skip the commit if no fixes were needed; record the smoke-test outcome in the task report either way.)

---

### Task 7: writing-skills validation pass (spec acceptance #4)

**Files:**
- Modify: any of the three skills' files, as the checklist demands.

**Interfaces:**
- Consumes: all files from Tasks 1–5.
- Produces: the completed skill set.

- [ ] **Step 1: Run the checklist**

Invoke `superpowers:writing-skills` and apply its verification checklist to all three skills. Additionally check, from the spec:
- Descriptions trigger correctly and do not overlap with `analyzing-source-code`, `source-first-topic-page`, or `superpowers:brainstorming` (the Frame stage note in the core SKILL.md must disambiguate).
- Status strings, stage names, gate names, and file names are byte-identical across all files (re-run every grep from Tasks 1, 2, 3).
- No file rewrites the destructive-operation rules — they reference `AGENTS.md`.

- [ ] **Step 2: Fix findings inline**

Apply fixes directly; re-run the affected greps.

- [ ] **Step 3: Final validate and commit**

```bash
make validate
git add skills/ && git status --short
git commit --no-gpg-sign -m "Finalize system-behavior-research skill set after writing-skills review

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Skip the commit if Step 2 changed nothing.)

---

## Deferred (explicitly out of plan)

- **Spec acceptance #1 (full dry-run):** the first real research topic run with `researching-system-behavior` end-to-end serves as the dry-run; treat the skill set as provisional until that run completes and its retrospective feeds fixes back into the skill files.
