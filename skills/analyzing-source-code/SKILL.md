---
name: analyzing-source-code
description: Use when adding a new open-source project to the documentation site for deep source code analysis, or when generating structured zh-TW documentation covering architecture, features, controllers, APIs, and integrations from a real codebase. Model-agnostic — works with any AI (Cursor, GitHub Copilot, Claude, internal LLMs, etc.).
---

# Analyzing Source Code

## Overview

A systematic workflow for analyzing open-source project source code and generating comprehensive Next.js/MDX documentation in zh-TW. Every piece of documentation must reference real source files — **zero fabrication tolerance**.

**Core principle:** Read the code first, write the docs second. Every code block needs a file path. Every claim needs a source.

**Writing quality:** Technical accuracy alone is not enough. Follow the 5 UX rules in [content-writing-guide.md](./content-writing-guide.md) to ensure readers can actually absorb the content.

## When to Use

- Adding a new open-source project (git submodule) to the documentation site
- Performing deep source code analysis for any Kubernetes operator, Go project, or YAML-based project
- Generating structured, consistent MDX documentation from a codebase
- Expanding an existing multi-project Next.js documentation site

**When NOT to use:**
- Quick README-level summaries (just read the README)
- Projects you don't have source access to
- Non-technical documentation

---

## Overall Workflow

```
Phase 1: Setup          → Add submodule, create content dirs, register project in lib/projects.ts
Phase 2: Explore        → 5 parallel explorations of the source code
Phase 2.5: Plan         → Classify project type → compute complexity → decide page list
Phase 3: Write          → N parallel writing sessions, one per page
Phase 3.5: Story        → Story-driven learning path for the landing page
Phase 4: Integrate      → Sidebar groups, homepage, navigation
Phase 5: Verify         → npm run build + visual review + commit
Phase 6: Update         → (Future) Diff analysis when new version is released
```

---

## Phase 1: Setup

Run these commands sequentially before any AI exploration.

### 1.1 Add the git submodule

```bash
# From the repo root (not next-site/)
git submodule add https://github.com/org/project-name project-name

# Check the actual default branch (may be main, master, develop, etc.)
git -C project-name remote show origin | grep 'HEAD branch'

# Set the tracking branch
git config -f .gitmodules submodule.project-name.branch <actual-default-branch>
```

### 1.2 Create the content directory

```bash
mkdir -p next-site/content/project-name/features
echo '[]' > next-site/content/project-name/quiz.json
```

### 1.3 Record the current version

```bash
# Record the analyzed commit in versions.json at repo root
git -C project-name rev-parse HEAD
# Add the result to versions.json
```

---

## Phase 2: Source Code Exploration

This phase gathers raw facts about the codebase. **Do not write documentation yet.** The goal is to produce structured exploration output that Phase 2.5 and Phase 3 will use.

Run all 5 explorations in parallel — they are independent.

### How to send these prompts

If you are using an AI tool that supports multiple parallel contexts (e.g., running multiple Copilot chats, or multiple Claude conversations), send each prompt in its own conversation simultaneously. If you must run them sequentially, that is fine — the prompts are independent.

> **If your AI does not have filesystem access** (e.g., a plain web chat interface with no IDE integration): paste the file contents directly into the prompt. Suggested order: first paste `README.md` and `go.mod`, then each additional file listed in the exploration prompt. You don't need to paste everything at once — the AI will ask for more if needed. Cursor, VS Code Copilot, and Claude Code all have filesystem access and can read files directly.

---

### Exploration 1: Project Structure

**Send this prompt to your AI:**

```
Explore the {project-name} repository at {repo-path}/ and provide a comprehensive structural analysis.

Read these files (do not just list directories — actually read the content):
- README.md or docs/README.md
- go.mod (or package.json / requirements.txt if not Go)
- Makefile
- Every file under cmd/ (main entry points)
- PROJECT file (if it exists — operator-sdk scaffold metadata)

Report:
1. What binaries or services does this project produce? (List each cmd/ entry point and its purpose)
2. What is the Go module name? What major external dependencies are used?
3. Is this an operator-sdk project? A plain controller-runtime project? Something else?
4. List the top-level directories and what each contains (one sentence each)
5. What CRDs does this project define? (List from config/crd/bases/ or api/)
6. What is the project's stated purpose (from README)?
7. Any notable build targets in the Makefile?

Zero fabrication: only report what you can read directly from files.
```

---

### Exploration 2: Controllers and Reconcile Loops

**Send this prompt to your AI:**

```
Explore the {project-name} repository at {repo-path}/ and analyze all controllers.

Read these files:
- Every file under controllers/ or pkg/controller/
- Every main.go under cmd/ (to see which controllers are registered)
- Any file named *_controller.go or *reconciler*.go

Report for EACH controller found:
1. Controller name (exact struct name)
2. Which CRD/resource it reconciles
3. The signature of its Reconcile() function
4. What it does in high-level steps (3-5 bullets, based on actual code)
5. Key helper methods it calls (read the actual method implementations, not just call sites)
6. What external systems it calls (API servers, databases, etc.)
7. File path: pkg/... or controllers/...

Also report:
- How are controllers registered? (manager.Add, ctrl.NewControllerManagedBy, etc.)
- Are there any watches beyond the primary resource?
- Is there a rate limiter or custom queue configuration?

Zero fabrication: quote actual function signatures from the files you read.
```

---

### Exploration 3: API Types and CRD Definitions

**Send this prompt to your AI:**

```
Explore the {project-name} repository at {repo-path}/ and analyze all API types and CRD definitions.

Read these files:
- Every *_types.go file under api/ or pkg/apis/
- config/crd/bases/*.yaml (actual CRD YAML if present)
- Any staging/ directory with types

Report for EACH CRD / custom resource:
1. Resource name, Group, Version (e.g., machines.cluster.x-k8s.io v1beta1)
2. The Go struct name for Spec and Status
3. All Spec fields (name, type, required/optional, what it controls)
4. All Status fields (name, type, what it reflects)
5. Any printer columns (+kubebuilder:printcolumn annotations)
6. Any validation rules (+kubebuilder:validation annotations)
7. The file path where the type is defined

Also report:
- Are there any webhook types (ValidatingWebhookConfiguration, MutatingWebhookConfiguration)?
- Are there any Hub/Spoke conversion types for multi-version CRDs?

Zero fabrication: copy the actual field names and types from the source.
```

---

### Exploration 4: Core Features and Business Logic

**Send this prompt to your AI:**

```
Explore the {project-name} repository at {repo-path}/ and analyze the core business logic.

Read files under:
- pkg/ (all subdirectories — read actual .go files, not just ls)
- internal/ (if it exists)
- Any file with names suggesting key algorithms: *strategy*, *planner*, *scheduler*, *selector*, *converter*, *migrat*

Report:
1. What are the 4-6 most important non-trivial algorithms or workflows? For each:
   a. What problem does it solve?
   b. What is the entry point function name and file path?
   c. How does the logic flow? (5-8 step description based on actual code)
   d. Are there any notable design patterns (state machine, strategy pattern, etc.)?

2. Are there any background goroutines, workers, or queues? Where are they defined?

3. Are there any HTTP or gRPC servers beyond the operator metrics/health endpoints?

4. Are there any noteworthy data transformation pipelines?

5. List 3-5 "surprising" things you found in the code that aren't obvious from the README.

Zero fabrication: every function name you mention must exist in the files you read. Quote exact file paths.
```

---

### Exploration 5: Integrations, RBAC, and External Dependencies

**Send this prompt to your AI:**

```
Explore the {project-name} repository at {repo-path}/ and analyze external integrations, RBAC, and webhooks.

Read these files:
- go.mod (external dependencies)
- config/rbac/ (all YAML files)
- Every *_webhook.go file
- Any file importing cloud provider SDKs (aws-sdk-go, azure-sdk-for-go, google.golang.org/api)
- Any file importing storage or database clients

Report:
1. External systems this project integrates with:
   - Cloud providers (AWS, Azure, GCP, MAAS, vSphere, etc.)
   - Storage systems
   - Message queues
   - Databases
   - Other Kubernetes projects (list import paths)

2. RBAC permissions: what ClusterRoles and Roles does this project require? List the key verbs/resources.

3. Webhooks:
   - List every webhook (path, type: validating/mutating, which resource)
   - What does each webhook validate or mutate?

4. Is there a multi-cluster or remote cluster capability? How is it implemented?

5. Authentication mechanisms: ServiceAccount, mTLS, Bearer token?

6. Any notable optional integrations (feature flags, build tags, operator config flags)?

Zero fabrication: base all answers on actual go.mod imports and config/ YAML files you read.
```

---

## Phase 2.5: Project Type Classification and Structure Planning

After the 5 explorations return their results, **run this planning step before writing any documentation**.

This step is done by you (or your primary AI session), synthesizing the exploration outputs.

### Step 1: Classify the project type

| Signal | Project Type |
|--------|-------------|
| Has `controllers/`, `Reconcile()` functions, operator-sdk structure; fewer than 5 controllers | Controller Operator |
| 5+ controllers, 10+ CRDs, multiple binaries/services, REST API | Large Platform |
| Core output is PrometheusRule, AlertRule, Dashboard JSON, no controllers | Monitoring/Observability |
| Core output is YAML/JSON resource definitions, Kustomize overlays, no controllers | Resource Definition |
| Provides CLI tool or SDK package, no CRDs | Tool/Library |
| Django/Flask/Rails apps, ORM models, REST + GraphQL, templates | Web Application Platform |

### Step 2: Compute the Complexity Score (CS)

Add up points from this table based on the exploration results:

| Signal | Score |
|--------|-------|
| Each Reconciler / controller | +1 per |
| Each CRD or ORM Model | +0.5 per |
| Each independent `cmd/` entry point | +0.5 per |
| Each external system integration | +0.5 per |
| Unique algorithm (state machine, scheduler, CBT, conversion) | +2 per |
| Both Validating + Mutating webhooks present | +2 |
| Supports 3+ different providers/backends | +3 |
| Async workflow (background jobs, queue, lease coordination) | +2 |
| REST + GraphQL both present | +2 |
| Plugin/extension framework | +2 |

**Reference benchmarks:**

| Project | CS | Pages |
|---------|----|-------|
| NMO (1 controller, 1 CRD, lease + webhook) | ~10 | 11 |
| Forklift (9 controllers, 9 CRDs, 7 providers, virt-v2v, CBT) | ~30 | 20 |
| NetBox (10 apps, 26+ models, REST+GraphQL, plugins) | ~45 | 35 |

**Page count formula:**
```
base_pages = { Controller Operator: 4, Large Platform: 6, Web Application: 8, other: 4 }
suggested_pages = max(base_pages, floor(CS × 0.7) + base_pages)
```

### Step 3: Identify pages that deserve independent treatment

For each notable feature from the exploration, ask:
1. **Depth**: Does understanding this require 500+ words?
2. **Independence**: Can it be read without requiring other pages first?
3. **Reader value**: Which audience needs this as a reference?

If all three are yes → independent page. If two → fold into the most relevant existing page as a `##` section.

**Common triggers for independent pages:**

| Signal | Page name |
|--------|-----------|
| Lease / distributed coordination mechanism | `coordination.mdx` |
| Taint management with complex logic | `node-management.mdx` |
| Webhook logic > 200 lines | `webhooks.mdx` |
| Warm migration / CBT / incremental backup | `warm-migration.mdx` |
| Guest OS conversion (virt-v2v etc.) | `guest-conversion.mdx` |
| Multiple volume populator implementations | `volume-populators.mdx` |
| Cross-cluster / multi-cluster flow | `remote-cluster.mdx` |
| REST API with 20+ endpoints | `api-reference.mdx` |
| GraphQL schema | `graphql-api.mdx` |
| Plugin development framework | `plugin-development.mdx` |
| Complex RBAC across multiple API groups | `rbac-permissions.mdx` |
| CLI tool with 5+ subcommands | `cli-reference.mdx` |
| Custom Prometheus metrics > 10 | `observability.mdx` |
| Multiple provider/backend types | `provider-types.mdx` |
| Pre/post hook execution framework | `hooks.mdx` |
| Validation / pre-flight check system | `validations.mdx` |
| Background tasks / queue / scheduling | `background-jobs.mdx` |
| Change log / audit trail | `audit-logging.mdx` |

### Step 4: Group pages into sections (when total ≥ 8 pages)

| Section name | Page types to include |
|-------------|----------------------|
| 系統架構 | architecture, overview, deployment |
| 核心概念 | CRD spec, data models, workflows |
| 進階功能 | Project-specific deep features |
| API 與整合 | REST, GraphQL, webhooks, external integrations |
| 維運操作 | Installation, RBAC, troubleshooting, performance |
| 開發指南 | Controller implementation, testing, extensibility |

### Structure Planner output format

After completing the above steps, write this summary before starting Phase 3:

```
## Structure Planner Output: {project-name}

Complexity Score: {N}
Project type: {type}
Suggested pages: {N} pages in {M} sections

### Page List

| # | Filename | Title | Section | Reason |
|---|----------|-------|---------|--------|
| 1 | index.mdx | Project Overview | — | Required baseline |
| 2 | architecture.mdx | System Architecture | 系統架構 | Required baseline |
| 3 | ... | ... | ... | ... |
| N | {filename}.mdx | {title} | {section} | {trigger signal} |

### Per-page detail

#### {filename}.mdx — {title}
- Target readers: developer / ops / architect
- Key topics:
  1. {topic 1}
  2. {topic 2}
  3. {topic 3}
- Key source files: {paths from exploration output}
```

---

## Phase 3: Documentation Writing

**One writing session per page. All pages can be written in parallel.**

### How to send Phase 3 prompts

For each page identified by the Structure Planner, send the following prompt in its own AI conversation (or sequentially if you only have one context):

---

**Template prompt for each documentation page:**

```
You are a technical documentation writer. Write the {filename}.mdx documentation page for the {project-name} project.

## Target page
- Filename: content/{project-name}/features/{filename}.mdx
- Title: {title}
- Target readers: {developer / ops / architect}

## Topics to cover (from Structure Planner)
{paste the per-page detail section here}

## Source code to reference
The project source code is at: {repo-path}/
Key files to read for this page: {list from exploration output}

## Exploration findings to use
{paste the relevant sections from Phase 2 exploration outputs}

## Writing standards (MANDATORY)
See the 5 UX rules below — violations make the page unacceptable.

### UX Rule 1: Scene before mechanism
Open with 1-2 sentences describing a real engineer scenario BEFORE any code or technical detail.

### UX Rule 2: No waterfall listing
Never write "Function A does X, Function B does Y, Function C does Z" as a prose list.
Instead explain the flow: "When X happens, A starts → B validates → C applies".

### UX Rule 3: Architecture diagram before code
If the page has both a concept diagram and code snippets, the diagram comes first.

### UX Rule 4: Progressive disclosure
Structure: Overview → Why it matters → How it works → Code detail → Edge cases.

### UX Rule 5: Explain before quote
Every code block must be preceded by one sentence explaining what the reader is about to see.

## Zero Fabrication Rule (MANDATORY)
Before writing ANY function name, type name, or method name into the documentation:
1. Run: grep -r "FunctionName" {repo-path}/
2. If grep finds no result → do NOT use that name. Write a concept-level explanation instead.
3. Every code block must have the real file path as the first comment line:
   // File: {repo-path}/path/to/actual/file.go

Forbidden:
- Inventing function names based on naming conventions
- Using names from README without grep-verifying them in the actual source
- Code blocks without a file path comment

## Output format (MDX)
The file must start with frontmatter:
---
title: "{project-name} — {page title}"
description: "One-line description"
---

Then the page content. Use these MDX components as needed:

<Callout type="info" title="...">...</Callout>
<Callout type="warning" title="...">...</Callout>
<Callout type="tip" title="...">...</Callout>
<Callout type="danger" title="...">...</Callout>

Do NOT add import statements — components are injected automatically.

## Page quality checklist (every page must have ALL of these)
- [ ] Opens with a real engineer scenario (UX Rule 1)
- [ ] At least 1 architecture or flow diagram reference (![caption](/diagrams/{project}/{name}.png))
- [ ] At least 2 code blocks, each with a real file path comment
- [ ] At least 1 data table (CRD fields, config options, state mapping, etc.)
- [ ] At least 1 <Callout> component
- [ ] Ends with a "Related pages" callout linking to sibling pages
```

---

### Phase 3.5: Story-Driven Landing Page

After all feature pages are written, create the landing page story. This powers the `ProjectStory` component on `app/[project]/page.tsx`.

**Send this prompt to your AI:**

```
Write the story data for the {project-name} landing page. This goes into lib/projects.ts as the `story` field of the project's ProjectMeta entry.

The story must have:
- protagonist: a real engineer persona (e.g., "小王，平台工程師") with a concrete job
- challenge: 2-3 sentences describing the business/technical problem they face
- scenes: 4-6 scenes, each with:
  - icon: an emoji representing the moment
  - actor: who is acting (the engineer or a system component)
  - action: one short sentence (what they do)
  - detail: 2-3 sentences of realistic context (what they discover, what goes wrong, what works)
- outcome: the happy ending — concrete measurable improvement (e.g., "migration time reduced from 4 hours to 30 minutes")

The story should naturally introduce the core concepts of {project-name}:
- {list 3-4 core concepts from the exploration output}

The protagonist should make at least one mistake or hit one unexpected obstacle. Real learning involves confusion.

The story is in Traditional Chinese (zh-TW). All Kubernetes terms stay in English — refer to the Never-translate list in Documentation Quality Standards. Never write 節點/叢集/控制器/標籤/排程/映像/工作負載/閘道/滾動更新.
```

---

## Phase 4: Site Integration

After all pages are written, integrate them into the Next.js site.

### 4.1 Register the project in `lib/projects.ts`

Add a new entry to the `PROJECTS` object. Fill in all required fields from the `ProjectMeta` interface (see `skills/site-bootstrap/SKILL.md` for the full schema).

The `featureGroups` array must list every page slug and group them into logical sidebar sections matching the Structure Planner output.

### 4.2 Sidebar groups in featureGroups

For a project with 11 pages across 4 sections:

```typescript
featureGroups: [
  {
    label: '系統架構',
    icon: '🏗',
    slugs: ['architecture', 'installation'],
  },
  {
    label: '核心概念',
    icon: '⚙️',
    slugs: ['crd-spec', 'machine-lifecycle', 'bootstrap'],
  },
  {
    label: '進階功能',
    icon: '🚀',
    slugs: ['webhooks', 'coordination', 'taints'],
  },
  {
    label: '維運',
    icon: '🔧',
    slugs: ['rbac', 'troubleshooting', 'observability'],
  },
],
```

### 4.3 Learning path integration

After writing the story and all feature pages, update the landing page at `app/[project]/page.tsx` to pass the story data to `<ProjectStory>` and list all feature groups with descriptions as "learning paths".

### 4.4 Verify the project appears in the site

```bash
cd next-site && npm run dev
# Open http://localhost:3000/{project-name}
# Verify: sidebar shows all groups + pages
# Verify: all feature page links work
# Verify: story renders on landing page
```

---

## Phase 5: Verification

```bash
# From repo root — runs ALL checks including build (mandatory)
make validate
```

**This must exit 0 before any commit.** Build failures here are bugs, not warnings.

**Common build errors and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `Module not found` | MDX file references a component that isn't in MDX_COMPONENTS | Add it to MDXComponents.tsx |
| `hydration mismatch` | Client component rendered differently on server | Check 'use client' directive |
| `Cannot find module 'content/...'` | File doesn't exist at expected path | Create the missing .mdx file |
| `Cannot find module './vendor-chunks/...js'` | Stale `.next` cache after dependency changes | `rm -rf next-site/.next && make validate` |
| Broken link in ToC | Heading ID doesn't match ToC anchor | Check slugify output vs rehype-slug |
| `Unhandled Runtime Error` in dev server | Stale `.next` cache after code changes | `rm -rf next-site/.next`, restart dev server |

**After successful validation, commit:**

```bash
git add next-site/content/{project-name}/ next-site/lib/projects.ts
git commit -m "docs({project-name}): add {N}-page documentation with story-driven landing

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Zero Fabrication Rule (Summary)

This rule appears in every Phase 3 prompt but is worth stating independently:

**Before writing any symbol (function name, type name, method name, constant, field name) into documentation:**

1. Search the source code: `grep -r "SymbolName" {project}/`
2. Read the actual definition: open the file and verify the semantics match what you plan to write
3. Quote the real file path in the first line of every code block

If grep returns no results → the symbol does not exist in this version. Do not use it. Write a conceptual explanation without naming specific symbols instead.

**The most common fabrication pitfall:** README or older blog posts describe a function that was renamed or removed. Always verify against the actual source files, not secondary sources.

---

## Documentation Quality Standards

### Language
- All documentation in **zh-TW** (Traditional Chinese)
- Technical terms keep English originals (Controller, CRD, Webhook, Reconcile, etc.)
- Code comments remain in English

#### ❌ Never-translate list — always keep in English, no exceptions

| ❌ 錯誤（翻譯） | ✅ 正確（英文） |
|--------------|--------------|
| 節點 | node |
| 叢集 | cluster |
| 控制器 | controller |
| 標籤 | label |
| 滾動更新 | rolling update |
| 映像 / 映像檔 | image |
| 工作負載 | workload |
| 閘道 | gateway |
| 排程 | scheduling / schedule |
| 裸金屬 | bare-metal |
| 命名空間 | namespace |
| 容器 | container |

> 這些詞在 Kubernetes 生態系中都是專有名詞，翻譯後反而增加混淆。即使在比喻或類比段落中，仍應使用英文原詞。

### Content UX
See [content-writing-guide.md](./content-writing-guide.md) for:
- The 5 UX rules with before/after examples
- MDX page templates for each page type
- Component usage reference

### Diagrams
- All flow diagrams and architecture diagrams are **static SVG/PNG** files
- Generated with `skills/fireworks-tech-graph/` skill
- Stored at: `next-site/public/diagrams/{project}/{diagram-name}.png`
- Referenced in MDX as: `![caption](/diagrams/{project}/{diagram-name}.png)`
- Generator scripts (if any) go in `scripts/diagram-generators/`
- **Never add Mermaid diagrams**

---

## Quick Reference

| Phase | Action | Can parallelize? |
|-------|--------|-----------------|
| 1: Setup | Submodule + dirs + quiz.json | No |
| 2: Explore | 5 exploration prompts | Yes — all 5 at once |
| 2.5: Plan | Classify + score + page list | No — synthesizes all exploration output |
| 3: Write | N page prompts | Yes — all pages at once |
| 3.5: Story | Landing page story data | Yes — parallel with Phase 3 |
| 4: Integrate | projects.ts + sidebar groups | No |
| 5: Verify | npm run build + commit | No |
| 6: Update | Diff → identify changed areas → update MDX | No |

---

## Phase 6: Updating Docs When Source Changes

Use this phase when the upstream project releases a new version **after** you already completed Phases 1–5.

### 6.1 Find what changed

```bash
# Check which commit you previously documented (stored in repo root)
cat versions.json

# Fetch the latest upstream code
git -C {project-name} fetch origin
git -C {project-name} checkout <new-tag-or-commit>

# List all changed Go/YAML files between the old commit and new commit
OLD_COMMIT=$(python3 -c "import json; d=json.load(open('versions.json')); print(d['{project-name}']['commit'])")
NEW_COMMIT=$(git -C {project-name} rev-parse HEAD)

git -C {project-name} diff --name-only $OLD_COMMIT $NEW_COMMIT -- '*.go' '*.yaml' '*.json'
```

### 6.2 Categorize the changes

Send this prompt to your AI:

```
I documented {project-name} at commit {OLD_COMMIT}.
The project is now at commit {NEW_COMMIT}.

Here are the changed files:
{paste: git -C {project-name} diff --name-only $OLD_COMMIT $NEW_COMMIT}

Here are the key diffs for the most critical files:
{paste: git -C {project-name} diff $OLD_COMMIT $NEW_COMMIT -- path/to/important/file.go}

Our documentation site has these existing pages:
{paste: ls next-site/content/{project-name}/features/}

For each changed file, tell me:
1. Which existing doc page covers this code (if any)?
2. What changed — new function, renamed type, new CRD field, new webhook, deleted feature?
3. Action: UPDATE (edit existing page) or ADD (create new page)?
4. Priority: High (visible user-facing change) / Medium / Low (internal refactor)

Output as a table: Changed File | Doc Page | Change Type | Action | Priority
```

### 6.3 Execute the updates

**For each HIGH priority UPDATE (existing page needs editing):**
```
Read next-site/content/{project}/features/{page}.mdx
and the diff below.

Update only the sections that are affected by this diff.
Do not change accurate sections. Correct any symbol names or file paths
that no longer match the new source code.

IMPORTANT: Every symbol you write must exist in the NEW commit at {NEW_COMMIT}.
Run grep to verify before writing.

Diff:
{paste relevant diff}
```

**For each HIGH priority ADD (new feature, new page):**
Follow the full Phase 3 writing prompt for the new page, then add the new page to `featureGroups` in `next-site/lib/projects.ts`.

### 6.4 Update versions.json

After all pages are updated:

```bash
NEW_COMMIT=$(git -C {project-name} rev-parse HEAD)
NEW_TAG=$(git -C {project-name} describe --tags --abbrev=0 2>/dev/null || echo "no-tag")
TODAY=$(date +%Y-%m-%d)
```

Edit `versions.json` manually to update the entry:
```json
"{project-name}": {
  "commit": "{NEW_COMMIT}",
  "tag": "{NEW_TAG}",
  "analyzed_at": "{TODAY}"
}
```

### 6.5 Verify and commit

```bash
cd next-site && npm run build   # must succeed with 0 errors

git add next-site/content/{project-name}/ versions.json
git commit -m "docs({project-name}): update docs for {new-tag}

Updated pages: {list}
New pages: {list if any}
Source: {project-name} @ {NEW_COMMIT}

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push origin main
```

---


| Mistake | Fix |
|---------|-----|
| Fabricating code that looks plausible | Always grep the actual file first |
| Missing file paths on code blocks | Add `// File: path/to/file.go` as first comment line |
| Shallow directory listing without reading code | Read main.go, reconciler, types.go — not just ls |
| Copy-paste from README without verification | README can be outdated; verify against actual source |
| Skipping Structure Planner and writing 4 fixed pages | Always run the planner; page count follows complexity |
| All pages in one flat sidebar section | Group into featureGroups when total pages ≥ 6 |
| Not building before committing | Always npm run build before git commit |
| Opening a page with a definition instead of a scenario | UX Rule 1: scene first, mechanism second |
| Waterfall listing of functions | UX Rule 2: explain the flow, not the inventory |
| Code block without explanation | UX Rule 5: one sentence before every code block |
