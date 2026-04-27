# SP-1 Framework Bootstrap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork the molearn `next-site` framework into `learning-k8s/`, empty all project content, rebrand homepage and metadata to learning-k8s, and verify build green so SP-2..SP-7 can layer content on top.

**Architecture:** Selective `cp` of `/tmp/molearn/{next-site,scripts/diagram-generators,skills,Makefile,package.json,.gitignore}` into `/Users/ikaros/Documents/code/learning-k8s/`. Remove molearn-only project content (`content/{cluster-api,cluster-api-provider-maas,cluster-api-provider-metal3,rook,kube-ovn,kubevirt}` + matching `public/diagrams/*`). Refactor 3 framework files (`lib/github-urls.ts`, `lib/code-extractor.ts`, `app/[project]/source/[...filepath]/page.tsx`) so they derive GitHub URLs from `PROJECTS[id].githubUrl` instead of a hard-coded record — this avoids SP-3..SP-7 having to touch framework code. Widen `ProjectId` from union literal to `string`. Replace `app/layout.tsx`, `app/page.tsx`, `components/SiteHeader.tsx` with learning-k8s branding (Taiwan Mandarin). Create new `README.md`, `CLAUDE.md`, `BOOTSTRAP.md`.

**Tech Stack:** Next.js 14.2.5 (App Router, `output: 'export'`), React 18, TypeScript 5, Tailwind CSS 3.4, MDX (`next-mdx-remote` 5), shiki, lucide-react, Python 3 (`scripts/validate.py`).

**Success criteria:**
- `cd next-site && npm install` exits 0
- `cd next-site && npm run build` exits 0 with `out/index.html` present
- `npm run dev` serves `/` (HTML 200) and `/nonexistent-path` (404 not 500)
- `make validate` exits 0 (with empty PROJECTS, validate.py is content-tolerant)
- Homepage hero shows the new Taiwan Mandarin tagline; molearn ack link in footer
- No reference to "MoLearn" / "molearn" / "cluster-api" / "hwchiu" remains in `next-site/app/`, `next-site/components/`, `next-site/lib/` (acceptable in `skills/` because those are doc artifacts)

---

## File structure (post-SP-1)

```
learning-k8s/
├── LICENSE                          (preserved as-is)
├── README.md                        (CREATE)
├── CLAUDE.md                        (CREATE)
├── BOOTSTRAP.md                     (CREATE)
├── Makefile                         (COPY verbatim)
├── package.json                     (COPY verbatim — root wrapper)
├── .gitignore                       (COPY verbatim)
├── .gitmodules                      (CREATE empty)
├── versions.json                    (CREATE: {})
├── docs/superpowers/
│   ├── specs/2026-04-27-sp1-framework-bootstrap-design.md   (already committed)
│   └── plans/2026-04-27-sp1-framework-bootstrap.md          (this file)
├── next-site/                       (COPY tree, then trim)
│   ├── app/
│   │   ├── [project]/               (COPY verbatim)
│   │   │   └── source/[...filepath]/page.tsx   (MODIFY — remove inner GITHUB_BASES dict)
│   │   ├── globals.css              (COPY verbatim)
│   │   ├── layout.tsx               (REWRITE — new metadata)
│   │   ├── not-found.tsx            (COPY verbatim)
│   │   └── page.tsx                 (REWRITE — new hero, empty-state safe)
│   ├── components/                  (COPY verbatim except SiteHeader)
│   │   └── SiteHeader.tsx           (MODIFY — brand name + repo URL)
│   ├── lib/
│   │   ├── projects.ts              (REWRITE — empty)
│   │   ├── github-urls.ts           (REWRITE — derive from PROJECTS)
│   │   ├── code-extractor.ts        (MODIFY — remove inner GITHUB_BASES, use github-urls)
│   │   └── (rest)                   (COPY verbatim)
│   ├── content/                     (CREATE empty dir)
│   ├── public/
│   │   ├── diagrams/                (CREATE empty dir; molearn diagrams removed)
│   │   └── (rest of public)         (COPY verbatim)
│   ├── types/                       (COPY verbatim)
│   ├── package.json                 (COPY verbatim; later: npm install)
│   ├── package-lock.json            (COPY verbatim)
│   ├── next-env.d.ts                (COPY)
│   ├── next.config.mjs              (COPY)
│   ├── postcss.config.mjs           (COPY)
│   ├── tailwind.config.ts           (COPY)
│   └── tsconfig.json                (COPY)
├── scripts/
│   ├── validate.py                  (COPY verbatim)
│   └── diagram-generators/          (COPY verbatim)
└── skills/                          (COPY verbatim)
```

---

## Important reconnaissance facts (already verified)

- **`scripts/validate.py` works fine with empty PROJECTS.** Each `check_*()` short-circuits gracefully when there are 0 MDX/quiz/feature files. Confirmed by reading `/tmp/molearn/scripts/validate.py` lines 47–248. **No patching of validate.py is needed.**
- **`generateStaticParams()` returning `[]` is acceptable in Next.js 14** (logs an info message, build succeeds).
- **Three files contain hard-coded `Record<ProjectId, string>` GitHub bases** that we'll refactor to derive from `PROJECTS[id].githubUrl`:
  - `next-site/lib/github-urls.ts` (lines 3–10)
  - `next-site/lib/code-extractor.ts` (lines 26–33)
  - `next-site/app/[project]/source/[...filepath]/page.tsx` (lines 20–24)

---

## Tasks

### Task 1: Copy framework files from `/tmp/molearn`

**Files:**
- Modify: `/Users/ikaros/Documents/code/learning-k8s/` (multiple new files)

- [ ] **Step 1: Verify working directory state**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
ls -la
```
Expected: only `LICENSE`, `.git/`, and `docs/` (with the spec/plan files already committed). If any other files exist, STOP and ask the user.

- [ ] **Step 2: Verify molearn source is at /tmp/molearn**

```bash
test -d /tmp/molearn/next-site || (echo "MISSING /tmp/molearn — clone first: git clone https://github.com/hwchiu/molearn.git /tmp/molearn"; exit 1)
ls /tmp/molearn/next-site/lib/projects.ts /tmp/molearn/scripts/validate.py /tmp/molearn/skills /tmp/molearn/Makefile
```
Expected: all 4 paths print without error.

- [ ] **Step 3: Copy root-level framework files**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
cp /tmp/molearn/Makefile ./Makefile
cp /tmp/molearn/.gitignore ./.gitignore
cp /tmp/molearn/package.json ./package.json
```

- [ ] **Step 4: Copy next-site/, scripts/, skills/ subtrees**

```bash
cp -R /tmp/molearn/next-site ./next-site
cp -R /tmp/molearn/scripts ./scripts
cp -R /tmp/molearn/skills ./skills
```

- [ ] **Step 5: Remove molearn-specific project content under next-site/**

```bash
# Drop content of all 6 projects molearn shipped
rm -rf next-site/content/cluster-api
rm -rf next-site/content/cluster-api-provider-maas
rm -rf next-site/content/cluster-api-provider-metal3
rm -rf next-site/content/rook
rm -rf next-site/content/kube-ovn
rm -rf next-site/content/kubevirt

# Drop their diagrams
rm -rf next-site/public/diagrams/capi
rm -rf next-site/public/diagrams/maas
rm -rf next-site/public/diagrams/metal3
rm -rf next-site/public/diagrams/rook
rm -rf next-site/public/diagrams/kubevirt

# Verify content/ is empty (only the parent dir kept)
ls next-site/content
```
Expected: empty output (no children).

- [ ] **Step 6: Create empty .gitmodules and versions.json**

```bash
: > .gitmodules
echo '{}' > versions.json
```

- [ ] **Step 7: Inspect what was copied**

```bash
ls -1 /Users/ikaros/Documents/code/learning-k8s
# Expected lines (order may vary):
# .git
# .gitignore
# .gitmodules
# BOOTSTRAP.md  ← will appear at Task 11; absent now is OK
# CLAUDE.md     ← will appear at Task 10; absent now is OK
# LICENSE
# Makefile
# README.md     ← will appear at Task 9; absent now is OK
# docs
# next-site
# package.json
# scripts
# skills
# versions.json
```

- [ ] **Step 8: Commit framework files**

```bash
git add .
git status
# Expected: many "new file:" lines under next-site/, scripts/, skills/, plus root files
git -c commit.gpgsign=false commit -m "feat(sp-1): copy molearn next-site framework with empty project content

Forked from hwchiu/molearn at /tmp/molearn (initial clone).
Removed molearn project content; PROJECTS will be cleared in next task.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Empty `next-site/lib/projects.ts`

**Files:**
- Modify: `next-site/lib/projects.ts`

- [ ] **Step 1: Replace projects.ts with the empty version**

Write this exact content to `next-site/lib/projects.ts`:

```typescript
import path from 'path'

export type ProjectId = string

export interface LearningPathStep {
  slug: string
  note: string
}

export interface FeatureGroup {
  label: string
  icon: string
  slugs: string[]
}

export interface StoryScene {
  step: number
  icon: string
  actor: string
  action: string
  detail: string
}

export interface ProjectStory {
  protagonist: string
  challenge: string
  scenes: StoryScene[]
  outcome: string
}

export interface ProjectMeta {
  id: ProjectId
  displayName: string
  shortName: string
  description: string
  githubUrl: string
  submodulePath: string
  color: string
  accentClass: string
  features: string[]
  featureGroups: FeatureGroup[]
  usecases: string[]
  difficulty: '🟢 入門' | '🟡 中階' | '🔴 進階'
  difficultyColor: string
  problemStatement: string
  story: ProjectStory
  learningPaths: {
    beginner: LearningPathStep[]
    intermediate: LearningPathStep[]
    advanced: LearningPathStep[]
  }
}

const REPO_ROOT = path.join(process.cwd(), '..')
export { REPO_ROOT }

// Empty until SP-2..SP-7 register their projects.
export const PROJECTS: Record<ProjectId, ProjectMeta> = {}

export const PROJECT_IDS: ProjectId[] = Object.keys(PROJECTS)

export function getProject(id: string): ProjectMeta | undefined {
  return PROJECTS[id]
}
```

- [ ] **Step 2: Verify the file is syntactically OK with tsc**

```bash
cd /Users/ikaros/Documents/code/learning-k8s/next-site
npx tsc --noEmit lib/projects.ts 2>&1 | head -20
```
Expected: no error output (or only "Cannot find module" warnings for cross-file imports — those are normal for single-file `tsc`).

- [ ] **Step 3: Commit**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/lib/projects.ts
git -c commit.gpgsign=false commit -m "feat(sp-1): empty PROJECTS and widen ProjectId to string

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Refactor `next-site/lib/github-urls.ts` to derive from PROJECTS

**Files:**
- Modify: `next-site/lib/github-urls.ts`

Rationale: this avoids SP-3..SP-7 having to update a separate hard-coded URL table.

- [ ] **Step 1: Replace github-urls.ts**

Write this exact content to `next-site/lib/github-urls.ts`:

```typescript
import { PROJECTS } from './projects'
import type { ProjectId } from './projects'

function baseUrl(project: ProjectId): string {
  const meta = PROJECTS[project]
  if (!meta) return ''
  return meta.githubUrl
}

export function buildGithubBlobUrl(project: ProjectId, file: string, lineStart?: number, lineEnd?: number): string {
  const base = baseUrl(project)
  if (!base) return ''
  let url = `${base}/blob/main/${file}`
  if (lineStart) url += `#L${lineStart}`
  if (lineEnd) url += `-L${lineEnd}`
  return url
}

export function buildGithubTreeUrl(project: ProjectId, dir: string): string {
  const base = baseUrl(project)
  if (!base) return ''
  return `${base}/tree/main/${dir}`
}
```

- [ ] **Step 2: Commit**

```bash
git add next-site/lib/github-urls.ts
git -c commit.gpgsign=false commit -m "refactor(sp-1): derive GitHub base URL from PROJECTS[id].githubUrl

Removes the hard-coded record so SP-3..SP-7 only touch projects.ts
when adding a new project.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Refactor `next-site/lib/code-extractor.ts` to use PROJECTS

**Files:**
- Modify: `next-site/lib/code-extractor.ts`

The inner `bases: Record<ProjectId, string>` table at lines 26–33 must go. We replace `buildGithubUrl()` with a call to the shared helper from `github-urls.ts`.

- [ ] **Step 1: Read the current file in full to know what to preserve**

```bash
wc -l /Users/ikaros/Documents/code/learning-k8s/next-site/lib/code-extractor.ts
```

Read the full file. The function `extractCodeSnippet` and its helpers (detectLang, etc.) must be preserved verbatim except for the `buildGithubUrl` private function.

- [ ] **Step 2: Apply edit — replace the private buildGithubUrl helper**

Use `Edit` tool to replace this exact block in `next-site/lib/code-extractor.ts`:

```typescript
function buildGithubUrl(project: ProjectId, file: string, start: number, end: number): string {
  const bases: Record<ProjectId, string> = {
    'cluster-api': 'https://github.com/kubernetes-sigs/cluster-api',
    'cluster-api-provider-maas': 'https://github.com/spectrocloud/cluster-api-provider-maas',
    'cluster-api-provider-metal3': 'https://github.com/metal3-io/cluster-api-provider-metal3',
    'rook': 'https://github.com/rook/rook',
    'kube-ovn': 'https://github.com/kubeovn/kube-ovn',
    'kubevirt': 'https://github.com/kubevirt/kubevirt',
  }
  return `${bases[project]}/blob/main/${file}#L${start}-L${end}`
}
```

with:

```typescript
import { buildGithubBlobUrl } from './github-urls'

function buildGithubUrl(project: ProjectId, file: string, start: number, end: number): string {
  return buildGithubBlobUrl(project, file, start, end)
}
```

If the existing `import { buildGithubBlobUrl } from './github-urls'` statement already exists at the top of the file (it doesn't right now), do NOT add a duplicate. Otherwise, add it at the top alongside the other imports.

- [ ] **Step 3: Verify no leftover references**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
grep -n "kubernetes-sigs\|spectrocloud\|metal3-io\|kubeovn" next-site/lib/code-extractor.ts
```
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add next-site/lib/code-extractor.ts
git -c commit.gpgsign=false commit -m "refactor(sp-1): code-extractor reuses buildGithubBlobUrl helper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: Refactor `app/[project]/source/[...filepath]/page.tsx`

**Files:**
- Modify: `next-site/app/[project]/source/[...filepath]/page.tsx`

- [ ] **Step 1: Replace the inner bases dict**

Use `Edit` to change this block:

```typescript
  const file = params.filepath.join('/')
  const bases: Record<string, string> = {
    'cluster-api': 'https://github.com/kubernetes-sigs/cluster-api',
    'cluster-api-provider-maas': 'https://github.com/spectrocloud/cluster-api-provider-maas',
    'cluster-api-provider-metal3': 'https://github.com/metal3-io/cluster-api-provider-metal3',
  }
  const githubUrl = `${bases[project.id] ?? ''}/blob/main/${file}`
```

into:

```typescript
  const file = params.filepath.join('/')
  const githubUrl = project.githubUrl ? `${project.githubUrl}/blob/main/${file}` : ''
```

- [ ] **Step 2: Verify**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
grep -n "kubernetes-sigs\|spectrocloud\|metal3-io" next-site/app/\[project\]/source/\[...filepath\]/page.tsx
```
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add 'next-site/app/[project]/source/[...filepath]/page.tsx'
git -c commit.gpgsign=false commit -m "refactor(sp-1): source page derives github URL from project.githubUrl

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: Rewrite `next-site/app/layout.tsx` (metadata)

**Files:**
- Modify: `next-site/app/layout.tsx`

- [ ] **Step 1: Replace layout.tsx**

Write this exact content to `next-site/app/layout.tsx`:

```typescript
import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  title: 'Kubernetes 深潛 — k8s / cilium / kubevirt / ceph / multus 原始碼學習站',
  description: '從原始碼深度分析 Kubernetes 與其生態系，附 30 天 hands-on lab',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-TW" className="dark">
      <body className="antialiased min-h-screen">
        {children}
      </body>
    </html>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add next-site/app/layout.tsx
git -c commit.gpgsign=false commit -m "feat(sp-1): rebrand <title> and <meta description> to learning-k8s

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: Rewrite `next-site/app/page.tsx` (homepage)

**Files:**
- Modify: `next-site/app/page.tsx`

The new homepage must:
- Show the new hero + tagline
- Render `PROJECT_IDS.map(...)` (currently `[]` so the section is empty-state)
- Show "尚未加入任何專案" when `PROJECT_IDS.length === 0`
- Drop the molearn-specific "什麼是 Cluster API 生態系" section
- Replace `LEARNING_PATHS` with neutral copy about source-driven learning
- Show molearn acknowledgement in footer
- Use `#` placeholder for the GitHub repo link (will be filled when repo is pushed)

- [ ] **Step 1: Replace page.tsx**

Write this exact content to `next-site/app/page.tsx`:

```typescript
import Link from 'next/link'
import { SiteHeader } from '@/components/SiteHeader'
import { PROJECTS, PROJECT_IDS } from '@/lib/projects'
import { ExternalLink, BookOpen, Map, HelpCircle, ArrowRight, Layers, Cpu, GitBranch } from 'lucide-react'

const COLOR_CLASSES: Record<string, { badge: string; card: string }> = {
  blue:   { badge: 'bg-blue-500/10 text-blue-400 border-blue-500/30',     card: 'hover:border-blue-500/50' },
  orange: { badge: 'bg-orange-500/10 text-orange-400 border-orange-500/30', card: 'hover:border-orange-500/50' },
  purple: { badge: 'bg-purple-500/10 text-purple-400 border-purple-500/30', card: 'hover:border-purple-500/50' },
  teal:   { badge: 'bg-teal-500/10 text-teal-400 border-teal-500/30',     card: 'hover:border-teal-500/50' },
  green:  { badge: 'bg-green-500/10 text-green-400 border-green-500/30',  card: 'hover:border-green-500/50' },
  rose:   { badge: 'bg-rose-500/10 text-rose-400 border-rose-500/30',     card: 'hover:border-rose-500/50' },
  amber:  { badge: 'bg-amber-500/10 text-amber-400 border-amber-500/30',  card: 'hover:border-amber-500/50' },
}

const LEARNING_PATHS = [
  {
    level: '🟢 初學者',
    title: '剛接觸 Kubernetes 生態系',
    color: 'border-green-500/30 bg-green-500/5',
    labelColor: 'text-green-400',
    steps: [
      { label: '① 從 30 天 lab 開始', desc: '依時間軸動手做實驗，快速建立可操作的整體圖像' },
      { label: '② 配合各專案 overview', desc: '每天 lab 完成後，閱讀對應專案的概觀頁建立背景知識' },
      { label: '③ 完成互動測驗', desc: '以選擇題自我檢查，找出仍模糊的概念回頭補強' },
    ],
  },
  {
    level: '🟡 中階工程師',
    title: '已會基本操作，要懂內部運作',
    color: 'border-yellow-500/30 bg-yellow-500/5',
    labelColor: 'text-yellow-400',
    steps: [
      { label: '① 由 architecture 切入', desc: '聚焦各專案的元件職責與資料流，看清誰跟誰互動' },
      { label: '② 跟著 reconcile loop 走', desc: '挑一個 Controller，從事件進入到 status 寫回的完整路徑' },
      { label: '③ 對照 lab 結果驗證', desc: '用 kubectl describe / events 對齊原始碼上的狀態變化' },
    ],
  },
  {
    level: '🔴 資深工程師',
    title: '要深度貢獻或建構平台',
    color: 'border-red-500/30 bg-red-500/5',
    labelColor: 'text-red-400',
    steps: [
      { label: '① 跨專案閱讀', desc: '同時看 cilium / multus / kubevirt 的 CNI 介接，比較設計取捨' },
      { label: '② 邊界條件分析', desc: '研究錯誤路徑、finalizer、leader election 的失敗模式' },
      { label: '③ 自行擴充', desc: '依 lab 末段挑戰題目實作小型 controller / CNI 外掛 / VM 操作工具' },
    ],
  },
]

export default function HomePage() {
  return (
    <div className="min-h-screen flex flex-col">
      <SiteHeader />
      <main className="flex-1">

        {/* Hero */}
        <section className="px-6 py-24 max-w-5xl mx-auto text-center">
          <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-[#161b22] border border-[#30363d] text-xs text-[#8b949e] mb-8">
            <span className="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse"></span>
            以原始碼為基礎的深度學習
          </div>
          <h1 className="text-5xl md:text-6xl font-bold text-white mb-6 leading-tight tracking-tight">
            從原始碼學習<br />
            <span className="text-[#2f81f7]">Kubernetes 生態系</span>
          </h1>
          <p className="text-xl text-[#8b949e] max-w-2xl mx-auto mb-10 leading-relaxed">
            以 30 天動手實驗加 5 個專案的深度原始碼導讀，<br />
            建立可開發 KubeVirt 平台的能力。
          </p>
          <div className="flex items-center justify-center gap-4">
            {PROJECT_IDS.length > 0 ? (
              <Link href={`/${PROJECT_IDS[0]}`}
                className="inline-flex items-center gap-2 px-6 py-3 rounded-lg bg-[#2f81f7] text-white font-semibold hover:bg-blue-600 transition-colors">
                開始學習 <ArrowRight size={16} />
              </Link>
            ) : (
              <span className="inline-flex items-center gap-2 px-6 py-3 rounded-lg bg-[#161b22] border border-[#30363d] text-[#8b949e] text-sm">
                尚未加入任何專案 — 詳見 BOOTSTRAP.md
              </span>
            )}
            <a href="#" target="_blank" rel="noopener noreferrer"
              className="inline-flex items-center gap-2 px-6 py-3 rounded-lg border border-[#30363d] text-[#e6edf3] hover:border-[#2f81f7] transition-colors">
              <ExternalLink size={14} /> GitHub
            </a>
          </div>
        </section>

        {/* What is this site */}
        <section className="px-6 pb-16 max-w-5xl mx-auto">
          <div className="rounded-2xl border border-[#30363d] bg-[#161b22] p-8">
            <h2 className="text-xl font-bold text-white mb-2 flex items-center gap-2">
              <Layers size={20} className="text-[#2f81f7]" />
              這個網站涵蓋什麼？
            </h2>
            <p className="text-[#8b949e] text-sm mb-6 leading-relaxed">
              從原始碼出發深入分析 5 個 Kubernetes 生態系專案，並附一份按時間軸推進的 30 天 hands-on lab。
            </p>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div className="p-4 rounded-xl border border-blue-500/20 bg-blue-500/5">
                <div className="flex items-center gap-2 mb-2">
                  <GitBranch size={15} className="text-blue-400" />
                  <span className="text-sm font-semibold text-blue-400">Kubernetes 核心</span>
                </div>
                <p className="text-xs text-[#8b949e] leading-relaxed">k8s 控制平面、kubelet、kube-proxy、scheduler 與其 CRD / API server 設計。</p>
              </div>
              <div className="p-4 rounded-xl border border-teal-500/20 bg-teal-500/5">
                <div className="flex items-center gap-2 mb-2">
                  <Cpu size={15} className="text-teal-400" />
                  <span className="text-sm font-semibold text-teal-400">網路與儲存</span>
                </div>
                <p className="text-xs text-[#8b949e] leading-relaxed">cilium 的 eBPF datapath、multus 多網路、ceph 分散式儲存。</p>
              </div>
              <div className="p-4 rounded-xl border border-rose-500/20 bg-rose-500/5">
                <div className="flex items-center gap-2 mb-2">
                  <Cpu size={15} className="text-rose-400" />
                  <span className="text-sm font-semibold text-rose-400">虛擬化平台</span>
                </div>
                <p className="text-xs text-[#8b949e] leading-relaxed">KubeVirt 的 VMI 生命週期、virt-controller / handler / launcher 三層架構。</p>
              </div>
            </div>
          </div>
        </section>

        {/* Learning Paths */}
        <section className="px-6 pb-16 max-w-5xl mx-auto">
          <h2 className="text-lg font-semibold text-[#8b949e] uppercase tracking-wider mb-6 text-center">學習路徑建議</h2>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-5">
            {LEARNING_PATHS.map(lp => (
              <div key={lp.level} className={`rounded-xl border p-5 ${lp.color}`}>
                <div className={`text-sm font-bold mb-1 ${lp.labelColor}`}>{lp.level}</div>
                <div className="text-xs text-[#8b949e] mb-4">{lp.title}</div>
                <ol className="space-y-3">
                  {lp.steps.map(step => (
                    <li key={step.label}>
                      <div className="text-xs font-semibold text-[#e6edf3] mb-0.5">{step.label}</div>
                      <div className="text-xs text-[#8b949e] leading-relaxed">{step.desc}</div>
                    </li>
                  ))}
                </ol>
              </div>
            ))}
          </div>
        </section>

        {/* Projects */}
        <section className="px-6 pb-24 max-w-5xl mx-auto">
          <h2 className="text-lg font-semibold text-[#8b949e] uppercase tracking-wider mb-8 text-center">涵蓋專案</h2>
          {PROJECT_IDS.length === 0 ? (
            <div className="rounded-2xl border border-dashed border-[#30363d] p-10 text-center text-[#8b949e]">
              尚未加入任何專案。請依 <code className="text-[#2f81f7]">BOOTSTRAP.md</code> 加入。
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
              {PROJECT_IDS.map(id => {
                const proj = PROJECTS[id]
                const cc = COLOR_CLASSES[proj.color] || COLOR_CLASSES.blue
                return (
                  <Link key={id} href={`/${id}`}
                    className={`group flex flex-col p-6 rounded-2xl border border-[#30363d] bg-[#161b22] transition-all duration-200 ${cc.card} hover:bg-[#21262d]`}>
                    <div className="flex items-start justify-between mb-3">
                      <span className={`px-2.5 py-1 rounded-full text-xs font-semibold border ${cc.badge}`}>
                        {proj.shortName}
                      </span>
                      <span className={`px-2 py-0.5 rounded-full text-xs border ${proj.difficultyColor}`}>
                        {proj.difficulty}
                      </span>
                    </div>
                    <h3 className="text-xl font-bold text-white mb-2 group-hover:text-[#2f81f7] transition-colors">
                      {proj.displayName}
                    </h3>
                    <p className="text-sm text-[#8b949e] leading-relaxed flex-1 mb-4">
                      {proj.description}
                    </p>
                    <div className="flex items-center gap-4 text-xs text-[#8b949e]">
                      <span className="flex items-center gap-1"><Map size={11} /> 功能地圖</span>
                      <span className="flex items-center gap-1"><BookOpen size={11} /> {proj.features.length} 功能</span>
                      <span className="flex items-center gap-1"><HelpCircle size={11} /> 測驗</span>
                    </div>
                  </Link>
                )
              })}
            </div>
          )}
        </section>

        {/* Footer */}
        <footer className="px-6 py-10 border-t border-[#30363d] text-center text-xs text-[#8b949e]">
          框架 fork 自{' '}
          <a href="https://github.com/hwchiu/molearn" target="_blank" rel="noopener noreferrer"
            className="text-[#2f81f7] hover:underline">
            hwchiu/molearn
          </a>
          ，感謝 @hwchiu。
        </footer>
      </main>
    </div>
  )
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/app/page.tsx
git -c commit.gpgsign=false commit -m "feat(sp-1): rewrite homepage with learning-k8s hero and empty-state safe

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 8: Update `next-site/components/SiteHeader.tsx`

**Files:**
- Modify: `next-site/components/SiteHeader.tsx`

- [ ] **Step 1: Replace SiteHeader.tsx**

Write this exact content to `next-site/components/SiteHeader.tsx`:

```typescript
import Link from 'next/link'
import { BookOpen, Github } from 'lucide-react'
import type { ProjectId } from '@/lib/projects'
import { PROJECTS, PROJECT_IDS } from '@/lib/projects'

interface Props {
  currentProject?: ProjectId
}

export function SiteHeader({ currentProject }: Props) {
  return (
    <header className="sticky top-0 z-50 border-b border-[#30363d] bg-[#0d1117]/90 backdrop-blur">
      <div className="max-w-screen-2xl mx-auto px-6 h-14 flex items-center gap-4">
        <Link href="/" className="flex items-center gap-2 font-bold text-white hover:text-[#2f81f7] transition-colors shrink-0">
          <BookOpen size={18} className="text-[#2f81f7]" />
          <span>learning-k8s</span>
        </Link>
        <span className="text-[#30363d] shrink-0">/</span>

        {/* Project switcher */}
        <nav className="flex items-center gap-1">
          {PROJECT_IDS.map(id => {
            const p = PROJECTS[id]
            const isActive = id === currentProject
            return (
              <Link
                key={id}
                href={`/${id}`}
                className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
                  isActive
                    ? `bg-[#161b22] border ${p.accentClass}`
                    : 'text-[#8b949e] hover:text-white hover:bg-[#161b22]'
                }`}
              >
                {p.shortName}
              </Link>
            )
          })}
        </nav>

        <div className="ml-auto flex items-center gap-3">
          <a href="#" target="_blank" rel="noopener noreferrer"
            className="text-[#8b949e] hover:text-white transition-colors">
            <Github size={18} />
          </a>
        </div>
      </div>
    </header>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add next-site/components/SiteHeader.tsx
git -c commit.gpgsign=false commit -m "feat(sp-1): rebrand SiteHeader to learning-k8s with placeholder repo link

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 9: Create root `README.md`

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md**

Write this exact content to `/Users/ikaros/Documents/code/learning-k8s/README.md`:

````markdown
# learning-k8s

> 個人 Kubernetes 生態系深度學習網站。從原始碼出發分析 k8s / cilium / kubevirt / ceph / multus，並附 30 天 hands-on lab。

## 涵蓋專案（預計）

| 專案 | 版本 | 主要學習目標 |
|------|------|------|
| kubernetes | v1.36.0 | 控制平面、kubelet、scheduler、kube-proxy 內部運作 |
| cilium | v1.19.3 | eBPF datapath、Network Policy、Hubble 觀測 |
| kubevirt | v1.8.2 | VMI 生命週期、virt-controller / handler / launcher、live migration |
| ceph | v19.2.3 (Squid LTS) | RADOS、CRUSH、RBD、CephFS、RGW |
| multus-cni | v4.2.4 | Meta-plugin、NetworkAttachmentDefinition、delegate flow |
| learning-plan | — | 30 天動手實驗計畫，依時間軸推進 |

## 技術 stack

| Layer | Tech |
|---|---|
| Framework | Next.js 14 App Router（`output: 'export'`） |
| Language | TypeScript |
| Styling | Tailwind CSS（GitHub Dark tokens） |
| MDX | next-mdx-remote + remark-gfm + rehype-slug |
| Syntax highlight | shiki |
| Icons | lucide-react |
| Validate | Python 3（`scripts/validate.py`） |

## 本地開發

```bash
git clone <this-repo> learning-k8s
cd learning-k8s

# 第一次或更新依賴後
make setup

# 開發伺服器
make dev   # → http://localhost:3000

# 靜態建置
make build

# 完整驗證（含 build）— commit 前必跑
make validate

# 快速驗證（不含 build）
make validate-quick
```

## 專案架構

```
learning-k8s/
├── next-site/             ← Next.js 14 + MDX 主體
│   ├── app/               ← App Router（框架，不動）
│   ├── components/        ← React 元件（框架，不動）
│   ├── lib/projects.ts    ← ★ 加新專案改這裡
│   ├── content/{project}/ ← ★ MDX 與 quiz.json 放這裡
│   └── public/diagrams/   ← 靜態圖表（PNG）
├── docs/superpowers/      ← Spec / plan 文件
├── scripts/
│   ├── validate.py
│   └── diagram-generators/
├── skills/                ← AI workflow skills（沿用 molearn）
└── versions.json          ← 各專案分析的 commit 版本
```

## 致謝

框架 fork 自 [hwchiu/molearn](https://github.com/hwchiu/molearn)，並沿用其 GitHub Dark 設計系統與 AI workflow skills。

## License

MIT — 見 `LICENSE`。
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git -c commit.gpgsign=false commit -m "docs(sp-1): add learning-k8s README

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 10: Create root `CLAUDE.md`

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: Write CLAUDE.md**

Write this exact content to `/Users/ikaros/Documents/code/learning-k8s/CLAUDE.md`:

````markdown
# CLAUDE.md — learning-k8s

> 給未來 AI session 的指引。讀完這份再動手。

## 專案性質

個人 Kubernetes 生態系深度學習網站。從原始碼出發分析 5 個專案，並附 30 天 hands-on lab。內容是給作者自己看的，不是公開教學站。

**已涵蓋（或計畫涵蓋）的專案：**

| 專案 | 版本 | 子計畫 |
|------|------|------|
| kubernetes | v1.36.0 | SP-3 |
| cilium | v1.19.3 | SP-4 |
| kubevirt | v1.8.2 | SP-5 |
| ceph | v19.2.3 (Squid LTS) | SP-6 |
| multus-cni | v4.2.4 | SP-7 |
| learning-plan | — | SP-2（30 天動手實驗，掛在 PROJECTS 裡走既有 `[project]` 路由） |

子計畫的 spec / plan 都在 `docs/superpowers/{specs,plans}/`。

## 內容語言（強制）

- 所有 zh 內容**必須是繁體中文，且使用台灣用語**
- 大陸 / 港式用語禁止：軟體（非软件/软体）、網路（非网络）、檔案（非文件）、程式（非程序）、預設（非默认）、資料（非数据）、使用者（非用户）、影片（非视频）、解析度（非分辨率）、滑鼠（非鼠标）
- 程式碼註解仍維持英文（與 upstream 慣例一致）

### 技術名詞保留英文（never-translate 清單）

下列詞彙**永遠**用英文原文，不要中譯：

`node`, `cluster`, `controller`, `namespace`, `container`, `image`, `workload`, `bare-metal`, `gateway`, `scheduling`, `rolling update`, `label`, `Pod`, `Deployment`, `Service`, `ConfigMap`, `Secret`, `PV`, `PVC`, `StorageClass`, `CRD`, `webhook`, `reconcile`, `operator`, `daemon`, `sidecar`, `taint`, `toleration`, `affinity`

## 強制流程

### 每次 commit 前

```bash
make validate
```

必須 exit 0 才能 commit。`validate.py` 會檢查：
- MDX frontmatter（`layout: doc` + `title:`）
- 圖片引用都存在且非 1×1 placeholder
- QuizQuestion 語法（quotes、answer 格式）
- quiz.json 格式（id 整數、answer 0-indexed）
- `projects.ts` 裡所有 slug 都有對應 MDX 檔
- Next.js build 必須 exit 0

### 加新專案的 5 步驟

詳見 `BOOTSTRAP.md`。摘要：

1. `git submodule add` 子專案到 root
2. 在 `next-site/lib/projects.ts` 的 `PROJECTS` 物件新增條目
3. `mkdir -p next-site/content/{project}/features` 與 `echo '[]' > next-site/content/{project}/quiz.json`
4. 寫 MDX（須通過 zero-fabrication 規則 — 見 `skills/analyzing-source-code/SKILL.md`）
5. `make validate`

### 分析新專案的方法論

完全沿用 `skills/analyzing-source-code/SKILL.md` 的 6 個 Phase（Setup → Explore × 5 → Plan → Write → Story → Integrate → Verify）。

## Lab 指令的驗證等級

30 天 lab 的指令必須先驗證才能寫進文件，但**驗證的等級依環境決定**：

- 可在 kind / minikube 跑的指令 → 必須在我本機跑過確認回傳值
- 需要真實 Proxmox + 3-node k8s + ceph cluster 的指令 → 以原始碼層級 + 官方文件交叉驗證；MDX 內以「在你環境跑後對照」標註
- 涉及破壞性操作（drain、reboot、ceph pool delete）→ 必須附明確警告與回退步驟

## 不要做的事

- 翻譯 never-translate 清單裡的詞
- 用大陸用語（程序 / 默认 / 视频 / 网络 / 文件…）
- 在 MDX 中 import `<Callout>` / `<QuizQuestion>` 等元件（它們是全域註冊的，加 import 反而會壞）
- 直接在 MDX 中寫測驗題；測驗一律放 `quiz.json`
- 加 Mermaid 圖表；圖表一律靜態 PNG，存 `next-site/public/diagrams/{project}/`
- 在 MDX 寫不存在的函式 / 型別名稱（zero-fabrication，違反就退稿）

## 技術 stack 對照

| Layer | Tech | 備註 |
|---|---|---|
| Framework | Next.js 14.2.5 App Router | `output: 'export'`，可純靜態部署 |
| MDX | next-mdx-remote 5 | frontmatter 用 gray-matter |
| Validation | Python 3 + `scripts/validate.py` | 跑 `make validate` 觸發 |

## 工作流程：brainstorm → spec → plan → implement

每個子計畫（SP-N）都走這個循環：

1. `superpowers:brainstorming` → spec 落到 `docs/superpowers/specs/`
2. `superpowers:writing-plans` → plan 落到 `docs/superpowers/plans/`
3. `superpowers:subagent-driven-development` 或 `superpowers:executing-plans` → 實作

不要省略任何階段。
````

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git -c commit.gpgsign=false commit -m "docs(sp-1): add CLAUDE.md guiding future AI sessions (Taiwan Mandarin enforced)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 11: Create root `BOOTSTRAP.md`

**Files:**
- Create: `BOOTSTRAP.md`

- [ ] **Step 1: Write BOOTSTRAP.md**

Write this exact content to `/Users/ikaros/Documents/code/learning-k8s/BOOTSTRAP.md`:

````markdown
# BOOTSTRAP.md — 加入新專案的 5 步驟

> 給 AI 看：你**只需要動 3 個地方**，框架程式碼不用碰。

```
框架（不動）           內容（你的工作範圍）
─────────────────      ──────────────────────────────
next-site/app/         next-site/lib/projects.ts        ← 新增專案條目
next-site/components/  next-site/content/{project}/     ← 新增 .mdx 文件
next-site/lib/（除    next-site/content/{project}/quiz.json
   projects.ts）       next-site/public/diagrams/{project}/  ← 新增圖表 PNG
```

## Step 1：加入 git submodule（若該子計畫需要原始碼）

```bash
git submodule add https://github.com/{org}/{repo}.git {local-name}
git -C {local-name} checkout {tag}
```

## Step 2：在 `next-site/lib/projects.ts` 登錄

在 `PROJECTS` 物件新增條目：

```typescript
'my-project': {
  id: 'my-project',
  displayName: 'My Project',
  shortName: 'MP',
  description: '一句話說明（繁中台灣用語）',
  githubUrl: 'https://github.com/...',
  submodulePath: path.join(REPO_ROOT, 'my-project'),
  color: 'blue',
  accentClass: 'border-blue-500 text-blue-400',
  features: ['overview', 'architecture'],
  featureGroups: [
    { label: '從這裡開始', icon: '🚀', slugs: ['overview'] },
    { label: '核心架構',   icon: '🏗',  slugs: ['architecture'] },
  ],
  usecases: [],
  difficulty: '🟡 中階',
  difficultyColor: 'text-yellow-400 bg-yellow-400/10 border-yellow-400/30',
  problemStatement: '...',
  story: { protagonist: '', challenge: '', scenes: [], outcome: '' },
  learningPaths: { beginner: [], intermediate: [], advanced: [] },
}
```

## Step 3：建立內容目錄

```bash
mkdir -p next-site/content/my-project/features
echo '[]' > next-site/content/my-project/quiz.json
```

## Step 4：寫 MDX

每個 feature 一個 `.mdx`：

```mdx
---
layout: doc
title: My Project — 主題名稱
description: 一句話說明這頁
---

## 場景

工程師遇到什麼問題……（先說場景，再說機制）

## 架構

![架構圖](/diagrams/my-project/architecture.png)

<Callout type="info" title="重點">
  關鍵說明（Callout 是全域元件，**不要 import**）
</Callout>

## 程式碼細節

接下來的程式碼展示 reconcile 主流程。

```go
// File: my-project/controllers/foo_controller.go
func (r *FooReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    ...
}
```
```

## Step 5：驗證

```bash
make validate    # 必須 exit 0
```

## 寫作 5 條規則

1. 場景優先（先說工程師遇到什麼問題，再說機制）
2. 禁止流水帳（不要「函數 A 做 X，函數 B 做 Y」連續列）
3. 圖先於文字（架構圖在程式碼之前）
4. 程式碼前要有一句說明（「接下來的程式碼展示……」）
5. 一頁一主題（讀超過 5 分鐘就拆）

## Quiz 格式

`next-site/content/{project}/quiz.json`：

```json
[
  {
    "id": 1,
    "question": "題目（不含題號，頁面會自動加 1.）",
    "options": ["正解", "誘答 1", "誘答 2", "誘答 3"],
    "answer": 0,
    "explanation": "為什麼正解對、其他錯在哪"
  }
]
```

- `id` 從 1 起遞增整數
- `answer` 是 0-indexed
- 題目須基於 MDX 內容，**禁止杜撰**

## 圖表

- 不要用 Mermaid
- 一律靜態 PNG，存 `next-site/public/diagrams/{project}/{name}.png`
- MDX 引用：`![說明](/diagrams/{project}/name.png)`
- 需 AI 生成圖表時，用 `skills/fireworks-tech-graph/SKILL.md` 流程
````

- [ ] **Step 2: Commit**

```bash
git add BOOTSTRAP.md
git -c commit.gpgsign=false commit -m "docs(sp-1): add BOOTSTRAP.md — 5-step guide to add a new project

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 12: First-time install + initial build

**Files:**
- Modify: `next-site/node_modules/`, `next-site/package-lock.json` (refreshed if needed), `next-site/.next/`, `next-site/out/`

- [ ] **Step 1: Install dependencies**

```bash
cd /Users/ikaros/Documents/code/learning-k8s/next-site
npm install
```
Expected: exits 0. If you see "added N packages, audited..." you're good. Warnings about deprecated packages are OK.

If `npm install` fails with native-deps mismatch (sharp / esbuild), fall back:
```bash
rm -rf node_modules package-lock.json
npm install
```
And re-commit the new `package-lock.json` (small diff is acceptable).

- [ ] **Step 2: Run build**

```bash
cd /Users/ikaros/Documents/code/learning-k8s/next-site
npm run build
```
Expected: exits 0. Output ends with something like `✓ Generating static pages (X/X)` and prints route summary. The `[project]/...` routes will show 0 entries (because PROJECT_IDS is empty).

If build fails with `Cannot find module './vendor-chunks/...'`:
```bash
rm -rf .next
npm run build
```

If build fails with TypeScript error mentioning a stale ProjectId reference, grep the error file and widen the type to `string`:
```bash
grep -n "ProjectId" <file mentioned in error>
```

- [ ] **Step 3: Verify out/ exists**

```bash
ls /Users/ikaros/Documents/code/learning-k8s/next-site/out/index.html
```
Expected: prints the path (no error).

- [ ] **Step 4: Commit any package-lock.json drift**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git status next-site/package-lock.json
# If modified:
git add next-site/package-lock.json
git -c commit.gpgsign=false commit -m "chore(sp-1): refresh package-lock.json from npm install

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
# If unmodified, skip this step.
```

---

### Task 13: Smoke-test the dev server

**Files:** none modified

- [ ] **Step 1: Start dev server in background**

```bash
cd /Users/ikaros/Documents/code/learning-k8s/next-site
npm run dev > /tmp/learning-k8s-dev.log 2>&1 &
echo $! > /tmp/learning-k8s-dev.pid
sleep 6
```

- [ ] **Step 2: Verify homepage renders**

```bash
curl -fsS http://localhost:3000/ -o /tmp/index.html
grep -c "從原始碼學習" /tmp/index.html
grep -c "hwchiu/molearn" /tmp/index.html
```
Expected: both `grep -c` print at least `1` (hero text and footer ack present).

- [ ] **Step 3: Verify 404 path is handled (not 500)**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/this-does-not-exist
```
Expected: `404`.

- [ ] **Step 4: Stop dev server**

```bash
kill "$(cat /tmp/learning-k8s-dev.pid)" 2>/dev/null
rm -f /tmp/learning-k8s-dev.pid /tmp/index.html
```

If kill fails (process already exited), continue.

---

### Task 14: Run `make validate`

**Files:** none modified

- [ ] **Step 1: Run validate-quick**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate-quick
```
Expected: exits 0. Output ends with `✓ All checks passed!`. Warnings about "No quiz.json files found" are acceptable.

- [ ] **Step 2: Run full validate (includes build)**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate
```
Expected: exits 0. Same `✓ All checks passed!` ending.

- [ ] **Step 3: If validate fails**

Read the error message:
- If it complains about `BOOTSTRAP.md / Makefile / README.md` containing "vitepress" — open those files and remove any "vitepress" string.
- If it complains about a missing image, double-check the homepage doesn't reference any `/diagrams/...` path that doesn't exist (it shouldn't — homepage uses lucide-react icons only).
- If `check_build` fails, see Task 12 fallbacks.

Fix and re-run. Do not proceed to Task 15 until both `validate-quick` and `validate` exit 0.

---

### Task 15: Final cleanup commit

**Files:** any drift from .gitignore-protected files

- [ ] **Step 1: Check for stragglers**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git status
```

If anything other than `next-site/.next/`, `next-site/out/`, `next-site/node_modules/` appears, decide:
- Source files → `git add` and commit
- Build output → ensure `.gitignore` excludes them; if not, add and commit `.gitignore`

- [ ] **Step 2: Verify .gitignore covers build artifacts**

```bash
cat /Users/ikaros/Documents/code/learning-k8s/.gitignore
```

Expected to contain (if not, add and commit):
- `node_modules`
- `.next`
- `out`

If missing entries, append them:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
echo "
# build artifacts
node_modules/
.next/
out/
" >> .gitignore
git add .gitignore
git -c commit.gpgsign=false commit -m "chore(sp-1): ensure .gitignore excludes build artifacts

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

- [ ] **Step 3: Final verification**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git log --oneline -20
make validate
```

Expected: `make validate` exits 0; `git log` shows the SP-1 commits in sequence.

- [ ] **Step 4: Mark SP-1 complete**

SP-1 is done when:
- ✅ `make validate` exits 0
- ✅ Homepage renders Taiwan Mandarin hero ("從原始碼學習 Kubernetes 生態系")
- ✅ Footer shows "hwchiu/molearn" acknowledgement
- ✅ No reference to "MoLearn" / "molearn" / "cluster-api" / "hwchiu" in `next-site/app/`, `next-site/components/`, `next-site/lib/` (verify via final grep below)
- ✅ `versions.json` is `{}`
- ✅ `next-site/content/` is empty
- ✅ `.gitmodules` is empty

```bash
cd /Users/ikaros/Documents/code/learning-k8s
grep -rn "MoLearn\|molearn\|cluster-api\|hwchiu" next-site/app next-site/components next-site/lib 2>&1 | grep -v -e "skills/" -e "molearn/" || echo "OK: no leakage"
```
Expected: prints `OK: no leakage`. (Acceptable: any match within the homepage footer ack — that's the only intended `hwchiu/molearn` reference.)

If the grep prints `hwchiu/molearn` from `next-site/app/page.tsx`'s footer, that's expected and acceptable.

---

## Self-review checklist

After SP-1 lands, before opening SP-2 brainstorm, confirm:

1. **Spec coverage**:
   - § Architecture (final repo layout) → covered by Tasks 1, 9, 10, 11
   - § Files COPY/MODIFY/CREATE/SKIP → Tasks 1 (COPY/SKIP), 2-8 (MODIFY/REWRITE), 9-11 (CREATE)
   - § Branding → Tasks 6 (layout), 7 (page), 8 (header), 9 (README footer mention)
   - § Verification → Tasks 12, 13, 14
   - § Error handling → covered as fallbacks within Task 12 and Task 14
   - § CLAUDE.md Taiwan Mandarin requirement → Task 10 explicitly enforces

2. **No placeholders** in this plan — all code blocks contain real, copy-pasteable content.

3. **Type consistency**:
   - `ProjectId = string` introduced in Task 2 is used by Tasks 3 (github-urls), 4 (code-extractor), 5 (source page), 8 (SiteHeader prop type)
   - `PROJECTS: Record<ProjectId, ProjectMeta> = {}` in Task 2 is consumed by `PROJECT_IDS = Object.keys(PROJECTS)` in same file, then by Tasks 7 (homepage map), 8 (header nav)
   - `ProjectMeta.githubUrl` field is consumed by Tasks 3, 4, 5

All references are consistent.
