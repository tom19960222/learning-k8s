# SP-1: Framework Bootstrap — Design

> **Status:** Approved (sections §1–§4) on 2026-04-27.
> **Next step:** writing-plans skill to produce the implementation plan.

---

## Project context

The user is building `learning-k8s`, a Next.js 14 + MDX documentation site to support deep, source-level study of the Kubernetes ecosystem (k8s, cilium, kubevirt, ceph, multus) plus a 30-day hands-on lab plan based on the user's own 3-node Proxmox VE 9 + Ceph + 3-node k8s lab.

The project follows a clear scope decomposition into seven sub-projects (SP-1 through SP-7). Each sub-project gets its own spec → plan → implement cycle. **This document covers SP-1 only.**

| Sub-project | Scope |
|---|---|
| **SP-1 (this doc)** | Bootstrap the molearn framework into `learning-k8s/` — empty PROJECTS, build green |
| SP-2 | The `learning-plan` "project" — 30-day labs registered as features |
| SP-3 | k8s v1.36.0 — submodule + first-wave docs (3–4 pages) + quiz |
| SP-4 | cilium v1.19.3 — first-wave docs + quiz |
| SP-5 | kubevirt v1.8.2 — first-wave docs + quiz |
| SP-6 | ceph v19.2.3 — first-wave docs + quiz |
| SP-7 | multus v4.2.4 — first-wave docs + quiz |

Stable version pins (confirmed via `git ls-remote`):

| Project | Tag | Commit |
|---|---|---|
| k8s | v1.36.0 | `02d6d2a6` |
| cilium | v1.19.3 | `f3434643` |
| kubevirt | v1.8.2 | `38a334b3` |
| ceph | v19.2.3 (Squid LTS) | `00193959` |
| multus | v4.2.4 | `705a59ea` |

First-wave depth target: **Option A — MVP**. 3–4 pages per project (overview + architecture + 1–2 core topics). Total ~18–20 pages across SP-3..SP-7. Deeper dives are deferred to second-wave sub-projects.

---

## Goals

SP-1 produces a working "empty shell" of the documentation site. After SP-1 lands:

- `cd next-site && npm install && npm run build` exits 0.
- `cd next-site && npm run dev` serves a homepage (with empty-state UI) at `http://localhost:3000/` without runtime errors.
- `make validate` exits 0 with empty PROJECTS (or `make validate-quick` if `validate` requires content).
- The repo contains the AI-workflow skills (`skills/`) and Python diagram generator scaffolding (`scripts/diagram-generators/`) ready for SP-2..SP-7 to consume.
- Site title, tagline, and metadata are rebranded to `learning-k8s`. Acknowledgement of the molearn fork is on the homepage footer.

SP-1 explicitly does **not** include:

- Adding any of the 5 git submodules — those belong in SP-3..SP-7's setup phase.
- Writing any project content (MDX, quiz.json, diagrams).
- The 30-day lab plan content — that's SP-2.
- GitHub Actions deploy workflow — postponed until publish is requested.

---

## Architecture

### Final repo layout (post-SP-1)

```
learning-k8s/
├── LICENSE                            (preserved as-is)
├── README.md                          (NEW — learning-k8s specific)
├── CLAUDE.md                          (NEW — guides future AI sessions)
├── BOOTSTRAP.md                       (NEW — AI quickstart)
├── Makefile                           (COPY from molearn)
├── package.json                       (COPY — root wrapper)
├── .gitignore                         (COPY)
├── .gitmodules                        (CREATE empty)
├── versions.json                      ({} empty object)
├── docs/
│   └── superpowers/
│       ├── specs/
│       │   └── 2026-04-27-sp1-framework-bootstrap-design.md   (this file)
│       └── plans/
│           └── 2026-04-27-sp1-framework-bootstrap-plan.md     (next step)
├── next-site/                         (COPY tree, with selective deletions)
│   ├── app/
│   │   ├── [project]/
│   │   ├── globals.css
│   │   ├── layout.tsx                 (MODIFY — title/metadata rebrand)
│   │   ├── not-found.tsx
│   │   └── page.tsx                   (MODIFY — homepage hero rebrand + empty-state safe)
│   ├── components/
│   │   ├── Breadcrumb.tsx
│   │   ├── Callout.tsx
│   │   ├── CodeAnchor.tsx
│   │   ├── CodeAnchorClient.tsx
│   │   ├── FeatureMapGraph.tsx
│   │   ├── MDXComponents.tsx
│   │   ├── ProjectSidebar.tsx
│   │   ├── ProjectStory.tsx
│   │   ├── QuizQuestion.tsx
│   │   ├── SiteHeader.tsx             (MODIFY — repo URL placeholder)
│   │   └── TableOfContents.tsx
│   ├── lib/
│   │   ├── code-extractor.ts
│   │   ├── content-loader.ts
│   │   ├── extract-headings.ts
│   │   ├── github-urls.ts
│   │   ├── go-parser.ts
│   │   └── projects.ts                (REWRITE — empty PROJECTS, ProjectId = string)
│   ├── content/                       (empty — preserve dir)
│   ├── public/                        (COPY without diagrams/{old projects})
│   ├── types/
│   ├── package.json
│   ├── package-lock.json
│   ├── next-env.d.ts
│   ├── next.config.mjs
│   ├── postcss.config.mjs
│   ├── tailwind.config.ts
│   └── tsconfig.json
├── scripts/
│   └── diagram-generators/            (COPY — Python diagram tooling)
└── skills/                            (COPY — AI workflow skills)
    ├── analyzing-source-code/
    ├── fireworks-tech-graph/
    ├── quiz-generation/
    └── site-bootstrap/
```

### Files: COPY / MODIFY / CREATE / SKIP

**COPY** (verbatim from `/tmp/molearn/`):

```
.gitignore
Makefile
package.json
next-site/app/[project]/                    (entire subtree)
next-site/app/globals.css
next-site/app/not-found.tsx
next-site/components/                       (all .tsx)
next-site/lib/                              (everything except projects.ts)
next-site/public/                           (excluding diagrams/{old-projects})
next-site/types/
next-site/next-env.d.ts
next-site/next.config.mjs
next-site/postcss.config.mjs
next-site/tailwind.config.ts
next-site/tsconfig.json
next-site/package.json
next-site/package-lock.json
scripts/diagram-generators/                 (entire tree)
skills/                                     (entire tree, all 4 skills)
```

**MODIFY** (copied then edited):

| File | Change |
|---|---|
| `next-site/lib/projects.ts` | Rewrite: keep all `interface` and `type` declarations. Change `ProjectId` from union literal to `string`. Set `PROJECTS: Record<ProjectId, ProjectMeta> = {}`. Set `PROJECT_IDS: ProjectId[] = []`. Keep `getProject()` helper. |
| `next-site/app/layout.tsx` | Update `metadata.title` and `metadata.description`. |
| `next-site/app/page.tsx` | Replace hero text. Wrap project-list rendering in an empty-state guard so `PROJECT_IDS.length === 0` shows "尚未加入任何專案 — 詳見 `BOOTSTRAP.md`" instead of crashing. |
| `next-site/components/SiteHeader.tsx` | Replace molearn repo URL with a placeholder (`#` or env-driven) and keep the github icon. |
| `.gitmodules` | Empty file (no submodules yet). |
| `versions.json` | `{}` |

**CREATE** (new files unique to learning-k8s):

| File | Outline |
|---|---|
| `README.md` | Purpose, tech stack, local dev commands, sub-project list, acknowledgement of molearn |
| `CLAUDE.md` | Future-AI guide: 5 target projects + learning-plan, content language (zh-TW), `make validate` rule, lab-verification level |
| `BOOTSTRAP.md` | Adapted from molearn — the 5-step "add a new project" guide |

**SKIP** (do not copy):

```
/tmp/molearn/.git/
/tmp/molearn/.github/
/tmp/molearn/README.md
/tmp/molearn/CLAUDE.md
/tmp/molearn/BOOTSTRAP.md
/tmp/molearn/cluster-api/
/tmp/molearn/cluster-api-provider-maas/
/tmp/molearn/cluster-api-provider-metal3/
/tmp/molearn/rook/
/tmp/molearn/kube-ovn/
/tmp/molearn/kubevirt/
/tmp/molearn/next-site/content/cluster-api/
/tmp/molearn/next-site/content/cluster-api-provider-maas/
/tmp/molearn/next-site/content/cluster-api-provider-metal3/
/tmp/molearn/next-site/content/rook/                        (if present)
/tmp/molearn/next-site/content/kube-ovn/                    (if present)
/tmp/molearn/next-site/content/kubevirt/                    (if present)
/tmp/molearn/next-site/public/diagrams/{any old project}/
```

---

## Branding & Site Identity

| Surface | New value |
|---|---|
| `<title>` | "Kubernetes 深潛 — k8s / cilium / kubevirt / ceph / multus 原始碼學習站" |
| `<meta name="description">` | "從原始碼深度分析 Kubernetes 與其生態系，附 30 天 hands-on lab" |
| Homepage hero headline | "從原始碼學習 Kubernetes 生態系" |
| Homepage hero subline | "以 30 天動手實驗 + 5 個專案的深度原始碼導讀，建立可開發 KubeVirt 平台的能力" |
| Repo URL in header | placeholder `#` (filled when repo is pushed to GitHub) |
| Homepage footer | "框架 fork 自 [hwchiu/molearn](https://github.com/hwchiu/molearn)，感謝 @hwchiu" |
| Design tokens (colors) | Unchanged — keep molearn's GitHub Dark palette |
| Favicon / logo | Unchanged — keep molearn defaults |

---

## Verification

SP-1 is complete only when ALL of the following pass:

```bash
cd /Users/ikaros/Documents/code/learning-k8s/next-site

# 1. Install
npm install                              # exit 0

# 2. Static build
npm run build                            # exit 0; out/ exists

# 3. Dev server smoke test
npm run dev &
DEV_PID=$!
sleep 5
curl -fsS http://localhost:3000/ | head -c 500
# expect: HTML 200 with the new hero text
curl -fsS -o /dev/null -w '%{http_code}' http://localhost:3000/nonexistent
# expect: 404 (not 500)
kill $DEV_PID

# 4. Make validate
cd /Users/ikaros/Documents/code/learning-k8s
make validate-quick                      # must pass
make validate                            # must pass (or be patched to accept empty PROJECTS)
```

### Manual visual check (must do)

- Open `http://localhost:3000/` in a browser. Confirm:
  - Hero text matches the new tagline.
  - Page does NOT crash on empty PROJECTS.
  - Footer shows the molearn acknowledgement link.
  - GitHub Dark palette renders correctly (background `#0d1117`).

---

## Error handling — known traps and fallbacks

| Trap | Trigger | Fallback |
|---|---|---|
| `Record<never, ProjectMeta>` TypeScript error | If we tried `ProjectId = never` | Use `ProjectId = string` from the start (chosen) |
| Homepage hard-codes a specific project id | `app/page.tsx` references `PROJECTS['cluster-api']` etc. | Add `if (PROJECT_IDS.length === 0) return <EmptyState />` before any indexed access |
| `generateStaticParams()` returns `[]` | Empty PROJECTS for `[project]` route | Expected; Next.js logs an info message but build succeeds |
| `tsc` complains about hard-coded ProjectId in other files | Some component might import a literal `'cluster-api'` | grep before build; widen those references to `string` if found |
| `vendor-chunks` build failure | Stale `.next` cache after deps change | `rm -rf next-site/.next && npm run build` |
| `package-lock.json` mismatch on macOS | Native deps re-resolve | `rm -rf node_modules package-lock.json && npm install` (commit the new lockfile) |
| `make validate` fails on empty PROJECTS | Validate script may assume ≥1 project | Locate the script via `grep -rn 'PROJECTS' Makefile scripts/`, then patch it to accept empty PROJECTS as a valid state. Patched script must be committed as part of SP-1. |

---

## Testing strategy

molearn has no unit tests; the framework is verified through:

1. **Static check:** `tsc --noEmit` (run as part of `npm run build`)
2. **Build check:** `npm run build` exits 0
3. **Smoke test:** `npm run dev` + `curl` for `/` and a 404 path
4. **Validate scripts:** both `make validate-quick` and `make validate` exit 0

No new tests are added in SP-1. Future SPs may add MDX validation tests (e.g., a frontmatter-presence check) but that's out of scope here.

---

## Out of scope (explicit)

- Adding any of the 5 project submodules
- Writing any MDX content
- Authoring any quiz.json
- Generating any diagrams
- The 30-day lab plan
- GitHub Actions deploy workflow
- Custom logo / favicon
- Changes to the design tokens or per-project accent colors
- Any deviations from molearn's component code

---

## Open questions (none blocking)

All four sections (Architecture, Files, Verification, Branding) were approved by the user. No open questions remain for SP-1.

The repo URL placeholder (`#`) in the header will be revisited when the user pushes to GitHub.
