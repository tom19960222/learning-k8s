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

````mdx
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
````

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
