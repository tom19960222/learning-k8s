---
name: site-bootstrap
description: Complete blueprint for scaffolding the Kubernetes learning documentation site from scratch. Contains the full design system, all component source code, directory structure, and deployment setup. Any AI reading this file should be able to produce an identical site.
---

# Site Bootstrap — Complete Blueprint

This document is fully self-contained. An AI that has never seen this project can read this file and scaffold an identical documentation site for a new organization.

---

## Design Philosophy

The site is a **GitHub-dark-themed, static-exported Next.js documentation site** for deep technical content about Kubernetes ecosystem projects. The design deliberately mirrors GitHub's dark interface to reduce cognitive friction for engineers who spend their day in GitHub.

**Three non-negotiable design decisions:**

1. **Static export only** — `output: 'export'` in next.config.js. No server runtime, deploys to GitHub Pages or any CDN with zero config.
2. **MDX for content** — Every documentation page is an `.mdx` file in `content/`. Components like `<Callout>` and `<QuizQuestion>` are imported directly into MDX.
3. **Content separated from routing** — Feature pages live in `content/{project}/features/{slug}.mdx`. The route `/{project}/features/{slug}` is generated from that directory. Changing the content tree doesn't require touching routing code.

---

## Tech Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| Framework | Next.js App Router | 14.2.5 |
| Language | TypeScript | ^5 |
| Styling | Tailwind CSS | ^3.4.1 |
| MDX rendering | next-mdx-remote | ^5.0.0 |
| Frontmatter parsing | gray-matter | ^4.0.3 |
| GFM tables/strikethrough | remark-gfm | ^4.0.1 |
| Heading IDs | rehype-slug | ^6.0.0 |
| Syntax highlighting | shiki | ^1.14.1 |
| Heading slugify (consistent) | github-slugger | ^2.0.0 |
| Icons | lucide-react | ^0.427.0 |
| Class merging | tailwind-merge + clsx | ^2.5.2 / ^2.1.1 |

### Complete package.json

```json
{
  "name": "your-site-name",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "next lint"
  },
  "dependencies": {
    "next": "14.2.5",
    "react": "^18",
    "react-dom": "^18",
    "next-mdx-remote": "^5.0.0",
    "gray-matter": "^4.0.3",
    "remark-gfm": "^4.0.1",
    "rehype-slug": "^6.0.0",
    "shiki": "^1.14.1",
    "github-slugger": "^2.0.0",
    "lucide-react": "^0.427.0",
    "tailwind-merge": "^2.5.2",
    "clsx": "^2.1.1"
  },
  "devDependencies": {
    "@types/node": "^20",
    "@types/react": "^18",
    "@types/react-dom": "^18",
    "autoprefixer": "^10.0.1",
    "postcss": "^8",
    "tailwindcss": "^3.4.1",
    "typescript": "^5"
  }
}
```

---

## Design Tokens

All colors are defined as CSS custom properties in `app/globals.css`. **Never hardcode color hex values in component files** — always reference these tokens or their Tailwind equivalents.

```css
/* app/globals.css */
@tailwind base;
@tailwind components;
@tailwind utilities;

:root {
  --background: #0d1117;   /* GitHub dark page background */
  --foreground: #e6edf3;   /* Primary text */
  --surface: #161b22;      /* Card/panel background */
  --surface-2: #21262d;    /* Secondary surface, code bg */
  --border: #30363d;       /* All borders */
  --muted: #8b949e;        /* Secondary text, placeholder */
  --accent: #2f81f7;       /* Blue accent — active states, links */
}

html {
  background-color: #0d1117;
  color: #e6edf3;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif;
}

/* Prose adjustments for MDX content */
.prose-content {
  max-width: 65ch;
}

/* Code block scrollbar styling */
pre::-webkit-scrollbar { height: 6px; }
pre::-webkit-scrollbar-track { background: transparent; }
pre::-webkit-scrollbar-thumb { background: #30363d; border-radius: 3px; }
```

### Tailwind configuration

```javascript
// tailwind.config.ts
import type { Config } from 'tailwindcss'

const config: Config = {
  content: [
    './app/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        gh: {
          bg: '#0d1117',
          surface: '#161b22',
          surface2: '#21262d',
          border: '#30363d',
          muted: '#8b949e',
          accent: '#2f81f7',
          fg: '#e6edf3',
        }
      }
    }
  },
  plugins: [],
}
export default config
```

---

## Directory Structure

```
next-site/
├── app/
│   ├── globals.css                    # Design tokens + Tailwind base
│   ├── layout.tsx                     # Root layout (dark html, antialiased body)
│   ├── page.tsx                       # Homepage (project cards grid)
│   └── [project]/
│       ├── layout.tsx                 # SiteHeader + ProjectSidebar + main area
│       ├── page.tsx                   # Project landing page (story + learning paths)
│       ├── feature-map/
│       │   └── page.tsx               # Visual overview of all features
│       ├── quiz/
│       │   └── page.tsx               # Interactive quiz (reads quiz.json)
│       └── features/
│           └── [slug]/
│               └── page.tsx           # MDX feature page with ToC
├── components/
│   ├── SiteHeader.tsx                 # Top nav with project switcher tabs
│   ├── ProjectSidebar.tsx             # Left sidebar with grouped feature nav
│   ├── TableOfContents.tsx            # Right sticky ToC (IntersectionObserver)
│   ├── Callout.tsx                    # info/warning/tip/danger boxes
│   ├── QuizQuestion.tsx               # Interactive multiple-choice quiz component
│   ├── ProjectStory.tsx               # Timeline narrative for landing pages
│   └── MDXComponents.tsx              # MDX element overrides
├── content/
│   └── {project-id}/
│       ├── quiz.json                  # Quiz questions data
│       └── features/
│           └── {slug}.mdx             # Each documentation page
├── lib/
│   ├── projects.ts                    # Project registry (all metadata)
│   ├── content-loader.ts              # Reads .mdx files from content/
│   └── extract-headings.ts            # Parses headings for ToC
├── next.config.mjs
├── tailwind.config.ts
├── tsconfig.json
└── postcss.config.js
```

---

## Complete Component Source Code

### `app/layout.tsx`

```tsx
import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  title: 'K8s Deep Dive',
  description: 'Deep source-code analysis of Kubernetes ecosystem projects',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-TW" className="bg-[#0d1117]">
      <body className="antialiased text-[#e6edf3]">
        {children}
      </body>
    </html>
  )
}
```

### `app/page.tsx` (Site Homepage)

> This is the **site-wide homepage** (`/`). It renders a hero section, a CAPI ecosystem explainer, learning paths, and project cards. It does NOT use `SiteHeader` with a `currentProject` prop — the header renders without any active tab.

```tsx
import Link from 'next/link'
import { SiteHeader } from '@/components/SiteHeader'
import { PROJECTS, PROJECT_IDS } from '@/lib/projects'
import { ExternalLink, BookOpen, Map, HelpCircle, ArrowRight } from 'lucide-react'

const LEARNING_PATHS = [
  {
    level: '🟢 初學者',
    title: '第一次接觸此生態系',
    color: 'border-green-500/30 bg-green-500/5',
    labelColor: 'text-green-400',
    steps: [
      { label: '① 從核心專案開始', desc: '理解宣告式管理的核心概念與架構設計' },
      { label: '② 選擇一個延伸專案', desc: '了解 Provider 如何整合到核心框架' },
      { label: '③ 完成互動測驗', desc: '測試你對各專案的理解，確認學習成果' },
    ],
  },
  {
    level: '🟡 中階工程師',
    title: '已懂 Kubernetes，要深入原始碼',
    color: 'border-yellow-500/30 bg-yellow-500/5',
    labelColor: 'text-yellow-400',
    steps: [
      { label: '① 控制器解析', desc: '直接深入 Reconcile 邏輯、狀態機與 Provider 合約' },
      { label: '② 實作對比', desc: '比較各 Provider 在相同合約下的不同設計決策' },
      { label: '③ Edge case 分析', desc: '研究錯誤處理、冪等性、Finalizer 的處理方式' },
    ],
  },
  {
    level: '🔴 資深工程師',
    title: '要深度貢獻或 debug',
    color: 'border-red-500/30 bg-red-500/5',
    labelColor: 'text-red-400',
    steps: [
      { label: '① 原始碼結構分析', desc: '從 code layout 到 interface 設計，理解可擴充性考量' },
      { label: '② 跨元件追蹤流程', desc: '追蹤一個請求穿越所有控制器的完整路徑' },
      { label: '③ 測驗挑戰模式', desc: '以進階題目驗證你對實作細節的掌握程度' },
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
          <h1 className="text-5xl md:text-6xl font-bold text-white mb-6 leading-tight tracking-tight">
            深入 Kubernetes<br />
            <span className="text-[#2f81f7]">基礎設施管理</span>
          </h1>
          <p className="text-xl text-[#8b949e] max-w-2xl mx-auto mb-10 leading-relaxed">
            從功能視角出發，逐層深入原始碼。理解每個 Controller 的設計決策與實作細節。
          </p>
          <div className="flex items-center justify-center gap-4">
            <Link href={`/${PROJECT_IDS[0]}`}
              className="inline-flex items-center gap-2 px-6 py-3 rounded-lg bg-[#2f81f7] text-white font-semibold hover:bg-blue-600 transition-colors">
              開始學習 <ArrowRight size={16} />
            </Link>
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
          <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
            {PROJECT_IDS.map(id => {
              const proj = PROJECTS[id]
              return (
                <Link key={id} href={`/${id}`}
                  className="group flex flex-col p-6 rounded-2xl border border-[#30363d] bg-[#161b22] hover:bg-[#21262d] transition-all duration-200">
                  <h3 className="text-xl font-bold text-white mb-2 group-hover:text-[#2f81f7] transition-colors">
                    {proj.name}
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
        </section>
      </main>
    </div>
  )
}
```

### `app/[project]/page.tsx` (Project Landing Page)

> This is the **per-project homepage** (`/{project}`). It renders: project header, problem statement, ProjectStory timeline, navigation cards (feature map / features / quiz), learning paths, and all features list.

```tsx
import Link from 'next/link'
import { getProject, PROJECT_IDS } from '@/lib/projects'
import { notFound } from 'next/navigation'
import { ExternalLink, Map, BookOpen, HelpCircle, Lightbulb, ArrowRight } from 'lucide-react'
import { ProjectStory } from '@/components/ProjectStory'

export function generateStaticParams() {
  return PROJECT_IDS.map(id => ({ project: id }))
}

const PATH_CONFIG = [
  {
    key: 'beginner' as const,
    label: '🟢 初學者',
    subtitle: '第一次接觸此專案',
    borderColor: 'border-green-500/30',
    bgColor: 'bg-green-500/5',
    textColor: 'text-green-400',
    dotColor: 'bg-green-400',
  },
  {
    key: 'intermediate' as const,
    label: '🟡 中階工程師',
    subtitle: '已懂 Kubernetes，要學此專案',
    borderColor: 'border-yellow-500/30',
    bgColor: 'bg-yellow-500/5',
    textColor: 'text-yellow-400',
    dotColor: 'bg-yellow-400',
  },
  {
    key: 'advanced' as const,
    label: '🔴 資深工程師',
    subtitle: '要深度貢獻或 debug',
    borderColor: 'border-red-500/30',
    bgColor: 'bg-red-500/5',
    textColor: 'text-red-400',
    dotColor: 'bg-red-400',
  },
]

export default function ProjectPage({ params }: { params: { project: string } }) {
  const project = getProject(params.project)
  if (!project) notFound()

  return (
    <div className="max-w-4xl mx-auto px-8 py-10">
      {/* Header */}
      <div className="mb-8">
        <h1 className="text-4xl font-bold text-white mb-3">{project.name}</h1>
        <p className="text-lg text-[#8b949e] mb-4">{project.description}</p>
        <a href={project.repoUrl} target="_blank" rel="noopener noreferrer"
          className="inline-flex items-center gap-1.5 text-sm text-[#2f81f7] hover:underline">
          <ExternalLink size={13} /> GitHub Repository
        </a>
      </div>

      {/* Story */}
      {project.story && <ProjectStory story={project.story} />}

      {/* Navigation Cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
        <Link href={`/${project.id}/features/${project.features[0]}`}
          className="flex flex-col gap-2 p-5 rounded-xl border border-[#30363d] bg-[#161b22] hover:border-[#2f81f7] transition-colors">
          <BookOpen size={20} className="text-[#2f81f7]" />
          <div className="font-semibold text-white">功能說明 ({project.features.length})</div>
          <div className="text-sm text-[#8b949e]">深入解析每個功能模組的設計與原始碼</div>
        </Link>
        <Link href={`/${project.id}/quiz`}
          className="flex flex-col gap-2 p-5 rounded-xl border border-[#30363d] bg-[#161b22] hover:border-[#2f81f7] transition-colors">
          <HelpCircle size={20} className="text-[#2f81f7]" />
          <div className="font-semibold text-white">互動測驗</div>
          <div className="text-sm text-[#8b949e]">測試你對此專案的理解程度</div>
        </Link>
      </div>

      {/* All Features */}
      <div>
        <h2 className="text-base font-semibold text-white mb-4">所有功能模組</h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
          {project.features.map((slug, i) => (
            <Link key={slug} href={`/${project.id}/features/${slug}`}
              className="flex items-center gap-3 p-3 rounded-lg border border-[#30363d] hover:border-[#2f81f7] hover:bg-[#161b22] transition-colors">
              <span className="text-xs font-mono text-[#8b949e] w-5">{String(i + 1).padStart(2, '0')}</span>
              <span className="text-sm text-[#e6edf3]">{slug}</span>
            </Link>
          ))}
        </div>
      </div>
    </div>
  )
}
```

### `components/SiteHeader.tsx`

```tsx
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
        <Link
          href="/"
          className="flex items-center gap-2 font-bold text-white hover:text-[#2f81f7] transition-colors shrink-0"
        >
          <BookOpen size={18} className="text-[#2f81f7]" />
          <span>K8s Deep Dive</span>
        </Link>
        <span className="text-[#30363d] shrink-0">/</span>
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
          <a
            href="https://github.com/your-org/repo"
            target="_blank"
            rel="noopener noreferrer"
            className="text-[#8b949e] hover:text-white transition-colors"
          >
            <Github size={18} />
          </a>
        </div>
      </div>
    </header>
  )
}
```

### `components/ProjectSidebar.tsx`

```tsx
'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { PROJECTS } from '@/lib/projects'
import type { ProjectId } from '@/lib/projects'

interface Props { project: ProjectId }

export function ProjectSidebar({ project }: Props) {
  const proj = PROJECTS[project]
  const pathname = usePathname()
  const isActive = (slug: string) => !!pathname?.endsWith(`/features/${slug}`)

  return (
    <aside className="w-56 flex-shrink-0 border-r border-[#30363d] h-[calc(100vh-3.5rem)] sticky top-14 overflow-y-auto py-6 px-3">
      <div className="mb-5 px-2">
        <Link
          href={`/${project}`}
          className="text-sm font-bold text-white hover:text-[#2f81f7] transition-colors block leading-tight"
        >
          {proj.shortName}
        </Link>
        <span className="text-xs text-[#8b949e] mt-0.5 block">{proj.displayName}</span>
      </div>
      <nav className="space-y-0.5">
        {proj.featureGroups.map((group) => (
          <div key={group.label} className="pt-4">
            <p className="px-2 text-[10px] font-semibold uppercase tracking-widest text-[#484f58] mb-1 flex items-center gap-1.5">
              <span>{group.icon}</span>
              <span>{group.label}</span>
            </p>
            <div className="space-y-0.5">
              {group.slugs.map(slug => (
                <Link
                  key={slug}
                  href={`/${project}/features/${slug}`}
                  className={`block px-2 py-1.5 rounded-md text-[0.8rem] transition-colors ${
                    isActive(slug)
                      ? 'bg-[#2f81f7]/15 text-[#2f81f7] font-medium border-l-2 border-[#2f81f7] pl-[6px]'
                      : 'text-[#8b949e] hover:bg-[#21262d] hover:text-white'
                  }`}
                >
                  {proj.featureLabels?.[slug] || slug}
                </Link>
              ))}
            </div>
          </div>
        ))}
      </nav>
    </aside>
  )
}
```

### `components/TableOfContents.tsx`

```tsx
'use client'
import { useEffect, useState } from 'react'
import type { Heading } from '@/lib/extract-headings'

export function TableOfContents({ headings }: { headings: Heading[] }) {
  const [activeId, setActiveId] = useState<string>('')

  useEffect(() => {
    if (headings.length === 0) return
    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries
          .filter(e => e.isIntersecting)
          .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)
        if (visible.length > 0) setActiveId(visible[0].target.id)
      },
      { rootMargin: '-60px 0px -66% 0px', threshold: 0 }
    )
    headings.forEach(({ id }) => {
      const el = document.getElementById(id)
      if (el) observer.observe(el)
    })
    return () => observer.disconnect()
  }, [headings])

  if (headings.length === 0) return null

  return (
    <aside className="hidden xl:block w-64 flex-shrink-0">
      <div className="sticky top-[3.5rem] max-h-[calc(100vh-3.5rem)] overflow-y-auto py-6 px-3">
        <p className="text-xs font-semibold uppercase tracking-wider text-[#8b949e] mb-3 px-2">
          本頁目錄
        </p>
        <nav>
          <ul className="space-y-0.5">
            {headings.map(({ id, text, level }) => (
              <li key={id}>
                <a
                  href={`#${id}`}
                  onClick={(e) => {
                    e.preventDefault()
                    document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
                    setActiveId(id)
                  }}
                  className={`block text-[0.8rem] leading-snug py-1.5 px-2 rounded transition-colors border-l-2 ${
                    level === 3 ? 'ml-3' : ''
                  } ${
                    activeId === id
                      ? 'border-[#2f81f7] text-[#2f81f7] font-medium bg-[#2f81f7]/10'
                      : 'border-transparent text-[#8b949e] hover:text-white hover:border-[#484f58]'
                  }`}
                >
                  {text}
                </a>
              </li>
            ))}
          </ul>
        </nav>
      </div>
    </aside>
  )
}
```

### `components/Callout.tsx`

```tsx
import { Info, AlertTriangle, Lightbulb, AlertCircle } from 'lucide-react'
import type { ReactNode } from 'react'

type CalloutType = 'info' | 'warning' | 'tip' | 'danger'
interface Props { type?: CalloutType; title?: string; children: ReactNode }

const styles: Record<CalloutType, { border: string; bg: string; icon: ReactNode; label: string }> = {
  info:    { border: 'border-blue-500/50',   bg: 'bg-blue-500/5',   icon: <Info size={15} className="text-blue-400" />,           label: '資訊' },
  warning: { border: 'border-yellow-500/50', bg: 'bg-yellow-500/5', icon: <AlertTriangle size={15} className="text-yellow-400" />, label: '注意' },
  tip:     { border: 'border-green-500/50',  bg: 'bg-green-500/5',  icon: <Lightbulb size={15} className="text-green-400" />,      label: '提示' },
  danger:  { border: 'border-red-500/50',    bg: 'bg-red-500/5',    icon: <AlertCircle size={15} className="text-red-400" />,      label: '警告' },
}

export function Callout({ type = 'info', title, children }: Props) {
  const s = styles[type]
  return (
    <div className={`my-4 rounded-lg border ${s.border} ${s.bg} p-4`}>
      <div className="flex items-center gap-2 mb-2 font-semibold text-sm">
        {s.icon}
        <span>{title || s.label}</span>
      </div>
      <div className="text-sm text-[#e6edf3] leading-7">{children}</div>
    </div>
  )
}
```

### `components/QuizQuestion.tsx`

```tsx
'use client'
import { useState } from 'react'
import { CheckCircle, XCircle } from 'lucide-react'

interface Props {
  question: string
  options: string[]
  answer: number
  explanation: string
}

export function QuizQuestion({ question, options, answer, explanation }: Props) {
  const [selected, setSelected] = useState<number | null>(null)
  const isAnswered = selected !== null
  const isCorrect = selected === answer

  return (
    <div className="my-6 rounded-xl border border-[#30363d] bg-[#161b22] overflow-hidden">
      <div className="px-5 py-4 border-b border-[#30363d]">
        <p className="text-white font-medium leading-7">{question}</p>
      </div>
      <div className="p-4 space-y-2">
        {options.map((opt, i) => {
          let cls = 'w-full text-left px-4 py-3 rounded-lg border text-sm transition-colors '
          if (!isAnswered)
            cls += 'border-[#30363d] hover:border-[#2f81f7] hover:bg-[#21262d] text-[#e6edf3]'
          else if (i === answer)
            cls += 'border-green-500 bg-green-500/10 text-green-400'
          else if (i === selected)
            cls += 'border-red-500 bg-red-500/10 text-red-400'
          else
            cls += 'border-[#30363d] text-[#8b949e] opacity-50'
          return (
            <button
              key={i}
              className={cls}
              onClick={() => !isAnswered && setSelected(i)}
              disabled={isAnswered}
            >
              <span className="mr-2 font-mono text-xs opacity-60">
                {String.fromCharCode(65 + i)}.
              </span>
              {opt}
            </button>
          )
        })}
      </div>
      {isAnswered && (
        <div className={`px-5 py-4 border-t ${isCorrect ? 'border-green-500/30 bg-green-500/5' : 'border-red-500/30 bg-red-500/5'}`}>
          <div className="flex items-start gap-2">
            {isCorrect
              ? <CheckCircle size={16} className="text-green-400 mt-0.5 flex-shrink-0" />
              : <XCircle size={16} className="text-red-400 mt-0.5 flex-shrink-0" />
            }
            <p className="text-sm text-[#e6edf3]">{explanation}</p>
          </div>
        </div>
      )}
    </div>
  )
}
```

### `components/ProjectStory.tsx`

```tsx
interface StoryScene {
  step: number
  icon: string
  actor: string
  action: string
  detail: string
}

interface Story {
  protagonist: string
  challenge: string
  scenes: StoryScene[]
  outcome: string
}

export function ProjectStory({ story }: { story: Story }) {
  return (
    <div className="mb-10">
      <h2 className="text-base font-semibold text-white mb-4 flex items-center gap-2">
        📖 一個真實場景
      </h2>
      <div className="rounded-xl border border-[#30363d] bg-[#0d1117] overflow-hidden">
        <div className="px-6 py-5 border-b border-[#30363d] bg-[#161b22]">
          <div className="text-sm font-semibold text-white mb-1">{story.protagonist}</div>
          <p className="text-sm text-[#8b949e] leading-relaxed">{story.challenge}</p>
        </div>
        <div className="px-6 py-5 space-y-0">
          {story.scenes.map((scene, idx) => (
            <div key={scene.step} className="flex gap-4">
              <div className="flex flex-col items-center">
                <div className="w-9 h-9 rounded-full bg-[#161b22] border border-[#30363d] flex items-center justify-center text-lg flex-shrink-0">
                  {scene.icon}
                </div>
                {idx < story.scenes.length - 1 && (
                  <div className="w-px flex-1 bg-[#30363d] my-1 min-h-[24px]" />
                )}
              </div>
              <div className="pb-5">
                <span className="text-xs font-mono text-[#2f81f7] bg-[#2f81f7]/10 px-2 py-0.5 rounded">
                  {scene.actor}
                </span>
                <p className="text-sm font-medium text-[#e6edf3] mb-1 mt-1">{scene.action}</p>
                <p className="text-xs text-[#8b949e] leading-relaxed">{scene.detail}</p>
              </div>
            </div>
          ))}
        </div>
        <div className="px-6 py-4 bg-[#0f2a1a] border-t border-[#238636]/30">
          <div className="flex items-start gap-2">
            <span className="text-green-400 text-base flex-shrink-0">🎉</span>
            <p className="text-sm text-[#3fb950] leading-relaxed">{story.outcome}</p>
          </div>
        </div>
      </div>
    </div>
  )
}
```

### `components/MDXComponents.tsx`

This file is imported in the feature page route and passed to `MDXRemote` as the `components` prop.

```tsx
import { Callout } from './Callout'
import { QuizQuestion } from './QuizQuestion'

export const MDX_COMPONENTS = {
  // Custom components available in MDX files
  Callout,
  QuizQuestion,
  // HTML element overrides
  h1: (props: any) => (
    <h1 className="text-3xl font-bold text-white mt-8 mb-4" {...props} />
  ),
  h2: (props: any) => (
    <h2 className="text-2xl font-bold text-white mt-8 mb-3 border-b border-[#30363d] pb-2" {...props} />
  ),
  h3: (props: any) => (
    <h3 className="text-xl font-semibold text-white mt-6 mb-2" {...props} />
  ),
  p: (props: any) => (
    <p className="text-[#e6edf3] leading-7 mb-4" {...props} />
  ),
  ul: (props: any) => (
    <ul className="list-disc pl-6 mb-4 space-y-1 text-[#e6edf3]" {...props} />
  ),
  ol: (props: any) => (
    <ol className="list-decimal pl-6 mb-4 space-y-1 text-[#e6edf3]" {...props} />
  ),
  li: (props: any) => (
    <li className="leading-7" {...props} />
  ),
  code: (props: any) => (
    <code className="bg-[#21262d] text-[#e3b341] px-1.5 py-0.5 rounded text-sm font-mono" {...props} />
  ),
  pre: (props: any) => (
    <pre className="bg-[#161b22] rounded-lg overflow-x-auto mb-4 p-4" {...props} />
  ),
  table: (props: any) => (
    <div className="overflow-x-auto mb-4">
      <table className="w-full border-collapse text-sm" {...props} />
    </div>
  ),
  th: (props: any) => (
    <th className="bg-[#21262d] text-[#e6edf3] p-2 border border-[#30363d] text-left font-semibold" {...props} />
  ),
  td: (props: any) => (
    <td className="p-2 border border-[#30363d] text-[#8b949e]" {...props} />
  ),
  a: (props: any) => (
    <a className="text-[#2f81f7] hover:underline" {...props} />
  ),
  blockquote: (props: any) => (
    <blockquote className="border-l-4 border-[#2f81f7] pl-4 italic text-[#8b949e] my-4" {...props} />
  ),
  strong: (props: any) => (
    <strong className="text-white font-semibold" {...props} />
  ),
  hr: () => <hr className="border-[#30363d] my-8" />,
}
```

---

## Library Files

### `lib/projects.ts` — TypeScript interfaces and project registry

```typescript
export type ProjectId = string

export interface FeatureGroup {
  label: string    // Section header in sidebar e.g. "核心架構"
  icon: string     // Emoji e.g. "🏗"
  slugs: string[]  // Feature slugs in this group
}

export interface StoryScene {
  step: number
  icon: string    // Emoji for timeline node
  actor: string   // Who is acting e.g. "小王" or "ClusterController"
  action: string  // Short description of action
  detail: string  // Longer explanation
}

export interface ProjectStory {
  protagonist: string   // Main character e.g. "小王，SRE 工程師"
  challenge: string     // The problem they face
  scenes: StoryScene[]  // 4-6 scenes
  outcome: string       // Happy ending
}

export interface ProjectMeta {
  id: ProjectId
  displayName: string       // Full name e.g. "Cluster API"
  shortName: string         // Abbreviation for header tabs e.g. "CAPI"
  description: string       // One-line description
  githubUrl: string
  color: string             // 'blue' | 'orange' | 'purple' | 'green' etc.
  accentClass: string       // Tailwind class e.g. 'border-blue-500 text-blue-400'
  features: string[]        // Ordered list of feature slugs
  featureGroups: FeatureGroup[]
  featureLabels?: Record<string, string>  // slug -> display label
  difficulty: '🟢 入門' | '🟡 中階' | '🔴 進階'
  problemStatement: string  // 2-3 sentence problem context
  story: ProjectStory
}

// ─── Project registry ──────────────────────────────────────────────────────

export const PROJECTS: Record<ProjectId, ProjectMeta> = {
  'cluster-api': {
    id: 'cluster-api',
    displayName: 'Cluster API',
    shortName: 'CAPI',
    description: '宣告式 Kubernetes 叢集生命週期管理框架',
    githubUrl: 'https://github.com/kubernetes-sigs/cluster-api',
    color: 'blue',
    accentClass: 'border-blue-500 text-blue-400',
    difficulty: '🔴 進階',
    problemStatement: '管理多叢集的生命週期（建立、升級、刪除）歷來需要大量自定義腳本。Cluster API 提供統一的宣告式 API，讓基礎設施即程式碼成為可能。',
    features: ['architecture', 'machine-lifecycle', 'controllers', 'bootstrap'],
    featureGroups: [
      {
        label: '核心架構',
        icon: '🏗',
        slugs: ['architecture', 'controllers'],
      },
      {
        label: '生命週期',
        icon: '⚙️',
        slugs: ['machine-lifecycle', 'bootstrap'],
      },
    ],
    featureLabels: {
      'architecture': '系統架構',
      'machine-lifecycle': '機器生命週期',
      'controllers': '控制器深度解析',
      'bootstrap': 'Bootstrap 流程',
    },
    story: {
      protagonist: '小王，平台工程師',
      challenge: '公司需要在三個雲端管理數十個 Kubernetes 叢集，現有腳本難以維護且沒有一致的升級路徑。',
      scenes: [
        {
          step: 1,
          icon: '😰',
          actor: '小王',
          action: '被叫去修一個升級失敗的叢集',
          detail: '現有的 bash 腳本在升級 control plane 後沒有更新 worker nodes，結果 apiVersion 不一致。',
        },
        {
          step: 2,
          icon: '🔍',
          actor: '小王',
          action: '發現 Cluster API',
          detail: '搜尋「kubernetes cluster lifecycle management」找到 CAPI，看到宣告式 API 可以用 kubectl 管理叢集就像管理 Pod 一樣。',
        },
        {
          step: 3,
          icon: '🏗',
          actor: 'ClusterController',
          action: '協調叢集狀態',
          detail: 'Cluster CR 建立後，CAPI 的 ClusterController 自動建立 control plane 和 infrastructure，並管理它們的 owner reference。',
        },
        {
          step: 4,
          icon: '🎉',
          actor: '小王',
          action: '成功遷移所有叢集',
          detail: '三個月後，所有叢集都由 CAPI 管理，升級只需要修改 YAML 的版本號，再也不需要維護複雜的腳本。',
        },
      ],
      outcome: '小王的團隊現在可以用 GitOps 管理所有叢集的生命週期，叢集升級從 4 小時的手動操作縮短到 30 分鐘的自動化流程。',
    },
  },
  // Add more projects here following the same schema
}

export const PROJECT_IDS = Object.keys(PROJECTS) as ProjectId[]
```

### `lib/content-loader.ts`

```typescript
import { readFileSync, existsSync, readdirSync } from 'fs'
import path from 'path'
import matter from 'gray-matter'
import type { ProjectId } from './projects'

const CONTENT_ROOT = path.join(process.cwd(), 'content')

export function loadFeatureSource(project: ProjectId, slug: string): string {
  const mdxPath = path.join(CONTENT_ROOT, project, 'features', `${slug}.mdx`)
  if (!existsSync(mdxPath)) return ''
  return readFileSync(mdxPath, 'utf-8')
}

export function loadFeatureFrontmatter(project: ProjectId, slug: string): Record<string, any> {
  const source = loadFeatureSource(project, slug)
  if (!source) return {}
  const { data } = matter(source)
  return data
}

export function listFeatureSlugs(project: ProjectId): string[] {
  const dir = path.join(CONTENT_ROOT, project, 'features')
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter(f => f.endsWith('.mdx'))
    .map(f => f.replace(/\.mdx$/, ''))
}

export function loadQuizData(project: ProjectId): any[] {
  const jsonPath = path.join(CONTENT_ROOT, project, 'quiz.json')
  if (!existsSync(jsonPath)) return []
  return JSON.parse(readFileSync(jsonPath, 'utf-8'))
}
```

### `lib/extract-headings.ts`

```typescript
export interface Heading { id: string; text: string; level: number }

// Unicode-aware slugify — must match rehype-slug behavior for CJK headings.
// rehype-slug uses github-slugger internally; we replicate the same logic here
// so ToC anchors (#id) always match what rehype-slug injects into the DOM.
function slugify(text: string): string {
  return text
    .toLowerCase()
    .trim()
    .replace(/[^\p{L}\p{N}\s-]/gu, '')   // keep Unicode letters + numbers
    .replace(/[\s_]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '')
}

export function extractHeadings(markdown: string): Heading[] {
  const headings: Heading[] = []
  let inCodeBlock = false
  for (const line of markdown.split('\n')) {
    if (line.startsWith('```')) { inCodeBlock = !inCodeBlock; continue }
    if (inCodeBlock) continue
    const match = line.match(/^(#{2,3})\s+(.+)$/)
    if (match) {
      const text = match[2]
        .trim()
        .replace(/`([^`]+)`/g, '$1')
        .replace(/\*\*([^*]+)\*\*/g, '$1')
      const id = slugify(text)
      if (id) headings.push({ id, text, level: match[1].length })
    }
  }
  return headings
}
```

---

## Route Files

### `app/[project]/layout.tsx`

```tsx
import { SiteHeader } from '@/components/SiteHeader'
import { ProjectSidebar } from '@/components/ProjectSidebar'
import { PROJECTS, PROJECT_IDS } from '@/lib/projects'
import type { ProjectId } from '@/lib/projects'
import { notFound } from 'next/navigation'

export async function generateStaticParams() {
  return PROJECT_IDS.map(id => ({ project: id }))
}

export default function ProjectLayout({
  children,
  params,
}: {
  children: React.ReactNode
  params: { project: string }
}) {
  if (!PROJECTS[params.project as ProjectId]) notFound()

  return (
    <div className="min-h-screen flex flex-col bg-[#0d1117]">
      <SiteHeader currentProject={params.project as ProjectId} />
      <div className="flex flex-1 max-w-screen-2xl mx-auto w-full">
        <ProjectSidebar project={params.project as ProjectId} />
        <main className="flex-1 min-w-0">
          {children}
        </main>
      </div>
    </div>
  )
}
```

### `app/[project]/features/[slug]/page.tsx`

```tsx
import { MDXRemote } from 'next-mdx-remote/rsc'
import remarkGfm from 'remark-gfm'
import rehypeSlug from 'rehype-slug'
import matter from 'gray-matter'
import { notFound } from 'next/navigation'
import { PROJECTS, PROJECT_IDS } from '@/lib/projects'
import type { ProjectId } from '@/lib/projects'
import { loadFeatureSource, listFeatureSlugs } from '@/lib/content-loader'
import { extractHeadings } from '@/lib/extract-headings'
import { TableOfContents } from '@/components/TableOfContents'
import { MDX_COMPONENTS } from '@/components/MDXComponents'

export async function generateStaticParams() {
  const params: { project: string; slug: string }[] = []
  for (const id of PROJECT_IDS) {
    for (const slug of listFeatureSlugs(id)) {
      params.push({ project: id, slug })
    }
  }
  return params
}

export default async function FeaturePage({
  params,
}: {
  params: { project: string; slug: string }
}) {
  const project = params.project as ProjectId
  if (!PROJECTS[project]) notFound()

  const source = loadFeatureSource(project, params.slug)
  if (!source) notFound()

  const { content, data: frontmatter } = matter(source)
  const headings = extractHeadings(content)

  return (
    <div className="flex gap-0">
      <article className="flex-1 min-w-0 px-10 py-8 max-w-4xl">
        <MDXRemote
          source={content}
          components={MDX_COMPONENTS}
          options={{
            mdxOptions: {
              remarkPlugins: [remarkGfm],
              rehypePlugins: [rehypeSlug],
            },
          }}
        />
      </article>
      <TableOfContents headings={headings} />
    </div>
  )
}
```

### `app/[project]/quiz/page.tsx`

> ⚠️ **Server Component — reads `quiz.json` at build time via `readFileSync`.** Do NOT use `'use client'` + `fetch()` here — the `content/` directory is not a public URL in a static export, so runtime fetch would 404 on the deployed site.

```tsx
import { getProject, PROJECT_IDS } from '@/lib/projects'
import { notFound } from 'next/navigation'
import { QuizQuestion } from '@/components/QuizQuestion'
import { existsSync, readFileSync } from 'fs'
import path from 'path'

export function generateStaticParams() {
  return PROJECT_IDS.map(id => ({ project: id }))
}

export default async function QuizPage({ params }: { params: { project: string } }) {
  const project = getProject(params.project)
  if (!project) notFound()

  const quizPath = path.join(process.cwd(), 'content', project.id, 'quiz.json')
  let quiz: any[] = []
  if (existsSync(quizPath)) {
    quiz = JSON.parse(readFileSync(quizPath, 'utf-8'))
  }

  return (
    <div className="max-w-3xl mx-auto px-8 py-10">
      <h1 className="text-3xl font-bold text-white mb-2">{project.displayName} 測驗</h1>
      <p className="text-[#8b949e] mb-8">測試你對 {project.shortName} 的理解程度</p>
      {quiz.length === 0 ? (
        <div className="text-[#8b949e]">測驗題目尚未建立</div>
      ) : (
        <div className="space-y-4">
          {quiz.map((q: any, i: number) => (
            <QuizQuestion
              key={q.id || i}
              question={`${i + 1}. ${q.question}`}
              options={q.options}
              answer={q.answer}
              explanation={q.explanation}
            />
          ))}
        </div>
      )}
    </div>
  )
}
```

---

## next.config.mjs

> ⚠️ **File must be named `next.config.mjs`** — `create-next-app@14` generates `.mjs` by default. If your file is named `next.config.js`, rename it.

```javascript
/** @type {import('next').NextConfig} */
const isProd = process.env.NODE_ENV === 'production'

const nextConfig = {
  output: 'export',           // Static HTML export for GitHub Pages / internal CDN
  trailingSlash: true,
  images: { unoptimized: true },
  // Replace 'your-repo-name' with the actual GitHub repo name
  basePath: isProd ? '/your-repo-name' : '',
  assetPrefix: isProd ? '/your-repo-name' : '',
}

export default nextConfig
```

---

## Complete Setup Procedure

### Step 1 — Bootstrap the Next.js project

```bash
npx create-next-app@14.2.5 next-site \
  --typescript \
  --tailwind \
  --app \
  --no-src-dir \
  --import-alias "@/*"
cd next-site
```

### Step 2 — Install additional dependencies

```bash
npm install \
  next-mdx-remote@^5.0.0 \
  gray-matter@^4.0.3 \
  remark-gfm@^4.0.1 \
  rehype-slug@^6.0.0 \
  shiki@^1.14.1 \
  github-slugger@^2.0.0 \
  lucide-react@^0.427.0 \
  tailwind-merge@^2.5.2 \
  clsx@^2.1.1
```

### Step 3 — Replace globals.css with the design tokens

Replace the contents of `app/globals.css` with the full CSS shown in the "Design Tokens" section above.

### Step 4 — Create the directory structure

```bash
mkdir -p \
  components \
  lib \
  content \
  app/\[project\]/features/\[slug\]
```

### Step 5 — Copy all component and library files

Create each file listed under "Component Source Code" and "Library Files" above. Copy the source code exactly as written.

### Step 6 — Create tsconfig.json with path aliases

```json
{
  "compilerOptions": {
    "target": "es2017",
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "paths": { "@/*": ["./*"] }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
```

### Step 7 — Verify the dev server starts

```bash
npm run dev
# Open http://localhost:3000 — you should see the homepage
```

### Step 8 — Build test

```bash
npm run build
# Should produce an `out/` directory with static HTML
```

---

## Adding a New Project

### Step-by-step checklist

**1. Add the git submodule (if source code analysis is needed)**

```bash
cd ..  # repo root, not next-site/
git submodule add https://github.com/org/project-name project-name
git config -f .gitmodules submodule.project-name.branch main
```

**2. Create the content directory**

```bash
mkdir -p next-site/content/project-name/features
```

**3. Add the project to `lib/projects.ts`**

Add a new entry to the `PROJECTS` object following the `ProjectMeta` schema. Required fields:
- `id` — matches the directory name in `content/` and the URL segment
- `displayName`, `shortName`, `description`
- `accentClass` — one of: `border-blue-500 text-blue-400`, `border-purple-500 text-purple-400`, `border-orange-500 text-orange-400`, `border-green-500 text-green-400`, `border-pink-500 text-pink-400`
- `featureGroups` — sidebar sections; every slug must have a corresponding `.mdx` file
- `story` — 4-6 scenes for the landing page timeline

**4. Create the first feature MDX file**

```
next-site/content/project-name/features/architecture.mdx
```

Minimum required frontmatter:

```mdx
---
title: "Project Name — 系統架構"
description: "架構概覽與核心元件說明"
---

# Project Name — 系統架構

{content here}
```

**5. Create `quiz.json` (can be empty initially)**

```bash
echo '[]' > next-site/content/project-name/quiz.json
```

**6. Run build to verify no broken routes**

```bash
cd next-site && npm run build
```

---

## Deployment — GitHub Actions for GitHub Pages

Create `.github/workflows/deploy.yml` at the repo root:

```yaml
name: Deploy to GitHub Pages

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive   # important: checks out all project submodules

      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: next-site/package-lock.json

      - name: Install dependencies
        working-directory: next-site
        run: npm ci

      - name: Build
        working-directory: next-site
        run: npm run build
        env:
          NODE_ENV: production

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: next-site/out

  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

### One-time GitHub repository setup

1. Go to **Settings → Pages → Source** and select **GitHub Actions**.
2. Update `basePath` and `assetPrefix` in `next.config.mjs` to match your repo name.
3. Push to `main` — the workflow will build and deploy automatically.

---

## Content MDX File Format

Every feature page in `content/{project}/features/{slug}.mdx` follows this pattern:

```mdx
---
title: "Project — Topic"
description: "One-line description for SEO and search"
---

# Project — Topic

Opening paragraph: what problem does this page address?

## Section Heading

Content...

<Callout type="tip" title="實用提示">
  Key insight for the reader.
</Callout>

## Another Section

More content...

```go
// File: path/to/file.go (always include the file path as first line comment)
func Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // ...
}
```

```

**Rules for MDX content:**
- `<Callout>` and `<QuizQuestion>` are available without import — they come from `MDX_COMPONENTS`
- Do NOT add `import` statements at the top of `.mdx` files — components are injected by the page
- Code blocks: always include a `// File: path/to/file.go` comment on the first line
- All text content in Traditional Chinese (zh-TW), technical terms in English

---

## quiz.json Format

```json
[
  {
    "section": "🏗️ 核心架構",
    "question": "1. ClusterController 在協調 Cluster CR 時，第一個建立的子資源是什麼？",
    "options": [
      "Infrastructure 物件（如 AWSCluster）",
      "ControlPlane 物件（如 KubeadmControlPlane）",
      "MachineDeployment 物件",
      "Secret 物件（kubeconfig）"
    ],
    "answer": 0,
    "explanation": "ClusterController 先確保 Infrastructure 就緒（實體網路、VPC 等），之後才建立 ControlPlane。順序：Infrastructure → ControlPlane → MachineDeployment。"
  }
]
```

`answer` is 0-indexed (first option = 0).
