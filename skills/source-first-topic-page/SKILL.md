---
name: source-first-topic-page
description: Use when a user asks to research a concrete Kubernetes ecosystem topic from source code and turn it into a learning-k8s MDX feature page, especially requests mentioning 深入研究, 專題頁面, source-first, 原始碼 single source of truth, or adding a page under next-site/content/{project}/features.
---

# Source First Topic Page

## Overview

Produce one durable feature page from a source-code investigation. Treat the local pinned source tree as the single source of truth; docs, blog posts, and memory can suggest where to look, but they cannot justify claims by themselves.

Use this for a focused topic inside an existing project. If the task is to add a whole new project, use `../analyzing-source-code/SKILL.md` first.

## Required Inputs

Before writing content, identify:

- Project id: one key in `next-site/lib/projects.ts`.
- Topic and target slug: the behavior, subsystem, API, or operational path being researched.
- Source baseline: local source path, tag/commit, and any adjacent repos needed.
- Output surfaces: MDX page, `PROJECTS` feature list/groups, `feature-map.json`, and optional `quiz.json`.

If any of these are unclear and cannot be inferred from repo context, ask one concise question.

## Workflow

### 1. Load Project Rules

Read `AGENTS.md`, then read only the relevant repo-local skills:

- `../analyzing-source-code/SKILL.md` for source-first exploration rules.
- `../analyzing-source-code/content-writing-guide.md` before drafting MDX.
- `../quiz-generation/SKILL.md` only when adding or changing quiz questions.
- `../fireworks-tech-graph/SKILL.md` only when generating static diagram assets.

If `$using-superpowers` is available or explicitly requested, use it first. For a broad new SP-N effort, follow this repo's brainstorm -> spec -> plan -> implement loop. For a narrow page inside an existing plan, continue with this skill and cite the existing plan/spec when relevant.

### 2. Build an Evidence Ledger

Create a temporary research ledger before drafting. Load `references/evidence-ledger.md` for the template.

For every claim that may appear in the page, record:

- Claim in plain language.
- Source file path and line range.
- Exact symbol names: function, type, field, constant, or YAML key.
- How the source proves the claim.
- Whether a claim was rejected because source evidence was missing.

Do not write a function, type, field, or behavior into MDX unless it is in this ledger.

### 3. Trace From Entry Point to Effect

Start from the user's topic, then walk both directions:

- Entry points: CLI command, controller registration, API type, reconcile loop, daemon startup, webhook, RPC, or YAML manifest.
- Core path: follow calls through the real implementation, not just interface names.
- Side effects: Kubernetes API writes, status updates, network/storage/runtime calls, metrics, events, or generated config.
- Boundaries: error handling, retry/requeue behavior, feature gates, defaults, version-specific branches, and tests.

Prefer narrow searches:

```bash
rg -n "symbol|topic" {project}/pkg {project}/cmd {project}/api
git -C {project} describe --tags --exact-match
git -C {project} rev-parse --short HEAD
nl -ba {source-file} | sed -n '120,180p'
```

Avoid broad repo-root `rg` unless scoped searches fail. If adjacent source is required and not present, initialize the existing submodule or ask before cloning/downloading.

### 4. Decide Page Shape

Keep one page to one topic. Split or defer if the trace has multiple independent flows.

Use this page structure unless the existing project has a stronger local pattern:

```mdx
---
layout: doc
title: {Project} - {Topic}
description: {Concrete summary in zh-TW}
---

## 場景

## {Mechanism}

## 原始碼路徑

## 邊界與除錯

## 接下來 / 相關頁面
```

Follow `content-writing-guide.md`: scene before mechanism, diagram before code, explain before quote, progressive disclosure, no waterfall listing.

### 5. Write With Zero Fabrication

Content rules:

- Write zh-TW with Taiwan wording. Preserve the repo never-translate terms from `AGENTS.md`.
- Do not import global MDX components.
- Do not put quiz questions in MDX.
- Do not use Mermaid. Use ASCII flow or static PNG under `next-site/public/diagrams/{project}/`.
- Use `File: project/path/file.go (line N)` before code snippets. Prefer snippets under 20 lines.
- Do not link GitHub blob URLs as primary evidence. The local submodule version is the reference.
- If a command or lab step is included, apply the validation level from `AGENTS.md`.

When source and external docs disagree, source wins. If source is unclear, state the uncertainty or omit the claim.

### 6. Integrate the Page

Update only the necessary site surfaces:

- Add the MDX file under `next-site/content/{project}/features/{slug}.mdx`.
- Add the slug to `features` in `next-site/lib/projects.ts`.
- Add the slug to the appropriate `featureGroups` entry, or create a narrowly named group if needed.
- Update `learningPaths` only if the new page changes the recommended reading path.
- Update `next-site/content/{project}/feature-map.json` if the project uses a feature map.
- Update `quiz.json` only when there is enough source-backed material for good questions.

Keep unrelated framework code untouched.

### 7. Verify

Run the relevant checks before completion:

```bash
make validate
```

If only the skill itself changed, also run:

```bash
python3 /Users/ikaros/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/source-first-topic-page
```

For new visual assets or layout-sensitive content, inspect the local page in Browser after starting the dev server.

## Completion Criteria

Finish only when:

- Every MDX implementation claim has source evidence.
- New slugs resolve through `projects.ts`.
- Quiz questions, if changed, are source-backed and valid JSON.
- `make validate` passes, or any failure is clearly unrelated and reported with evidence.
- The final response lists changed paths, validation results, and any source gaps deliberately left out.
