# Content Writing Guide

This guide defines quality standards for all documentation pages in this site. Technical accuracy is necessary but not sufficient — pages must also be readable, progressive, and scenario-driven.

**Every page author (human or AI) must follow the 5 UX rules below.**

---

## The 5 UX Rules

These rules exist because documentation written without them tends to feel like a specification sheet: accurate but hard to learn from. Engineers read docs to solve problems, not to memorize facts.

---

### Rule 1: Scene Before Mechanism

**Every feature page must open with a scenario (1-2 sentences) before any code or technical definition.**

The scenario answers: "What problem does a real engineer face that makes this feature relevant?"

❌ Bad opening:
```
## MachineController

MachineController is a Kubernetes controller that reconciles Machine objects.
It implements the controller-runtime Reconciler interface and watches
for Machine CR creation, update, and deletion events.
```

✅ Good opening:
```
## MachineController

When you apply a Machine YAML, something needs to translate that declaration into
a real provisioned server. MachineController is what bridges that gap — it watches
for new Machine CRs and drives them through the provisioning lifecycle until the
physical machine joins the cluster as a Node.
```

The bad opening tells you *what* it is. The good opening tells you *why it exists*.

---

### Rule 2: No Waterfall Listing

**Never write "Function A does X, Function B does Y, Function C does Z" as a prose inventory.**

This pattern forces readers to hold multiple disconnected facts in memory before any meaning emerges. Instead, explain the flow: what triggers what, what depends on what, what happens when something goes wrong.

❌ Bad (waterfall listing):
```
## MachineReconciler 的實作

MachineReconciler 呼叫 reconcileMachine() 函數。
reconcileMachine() 呼叫 getMAASmachine() 從 MAAS API 取得機器狀態。
getMAASmachine() 使用 HTTP client 發送 GET 請求到 MAAS endpoint。
回傳的機器物件包含 SystemID、Hostname、PowerState 等欄位。
MachineReconciler 接著呼叫 patchMachine() 更新 status。
```

✅ Good (scene → flow → code):
```
## 機器從申請到就緒

當你建立一個 MAAsMachine CR，三件事會依序發生：

1. **偵測** — Reconciler 發現新 CR，查詢 MAAS 找到對應的實體機
2. **啟動** — 透過 MAAS API 觸發 PXE boot，等待 OS 安裝完成
3. **交接** — 機器就緒後設定 `providerID`，通知 CAPI 開始 bootstrap

以下是步驟 1 的核心邏輯，位於 `controllers/maasmachine_controller.go`：
```go
// File: controllers/maasmachine_controller.go
machine, err := r.MaasClient.GetMachineByHostname(ctx, maasRef.Hostname)
if err != nil {
    return ctrl.Result{}, fmt.Errorf("querying MAAS: %w", err)
}
```
```

The bad version lists functions. The good version tells a story with numbered steps, then shows the code for one specific step.

---

### Rule 3: Architecture Diagram Before Code

**If a page has both a concept diagram and code snippets, the diagram comes first.**

Code shows *how* something is implemented. A diagram shows *what* the system looks like. Readers need the mental model before they can make sense of implementation details.

Order within a section:
1. Scenario / problem statement (Rule 1)
2. Architecture diagram or flow diagram
3. High-level explanation of the diagram
4. Code blocks (Rule 5 applies to each)
5. Edge cases and gotchas

---

### Rule 4: Progressive Disclosure

**Structure each page: Overview → Why it matters → How it works → Code detail → Edge cases.**

Junior engineers read top-down and stop when they have enough context. Senior engineers skip to the code. Neither should be forced to wade through the other's content to get what they need.

**Page structure template:**
```
## Overview
  1-2 paragraph scenario + what this page covers

## 為什麼需要它
  The problem this solves. What breaks without it.

## 工作原理
  High-level flow, diagram, key concepts.
  No implementation code yet.

## 實作細節
  Code blocks with file paths.
  Data structures, function signatures.

## 注意事項與邊界情況
  What can go wrong. Non-obvious behavior.
  <Callout type="warning"> blocks go here.
```

---

### Rule 5: Explain Before Quote

**Every code block must be preceded by one sentence explaining what the reader is about to see.**

❌ Bad (code dropped without context):
```
The reconciler processes machines in a loop.

```go
// File: controllers/machine_controller.go
for _, m := range machines {
    if err := r.reconcileOne(ctx, m); err != nil {
        ...
    }
}
```
```

✅ Good (one sentence before the block):
```
The reconciler iterates over all machines in the queue, stopping on the first error
to avoid cascading failures:

```go
// File: controllers/machine_controller.go
for _, m := range machines {
    if err := r.reconcileOne(ctx, m); err != nil {
        return ctrl.Result{}, fmt.Errorf("reconciling machine %s: %w", m.Name, err)
    }
}
```
```

---

## MDX Page Templates

### Template: Architecture Page (`architecture.mdx`)

```mdx
---
title: "{Project} — 系統架構"
description: "系統元件、資料流與核心設計決策"
---

# {Project} — 系統架構

## 概述

{1-2 sentence scenario: what problem does this system solve for an operator or developer?}

{Project} 由以下幾個核心元件組成：

| 元件 | 職責 |
|------|------|
| {Component A} | {one line} |
| {Component B} | {one line} |
| {Component C} | {one line} |

## 架構圖

下圖顯示各元件之間的控制流與資料流：

![{Project} 系統架構](/diagrams/{project}/architecture.png)

{2-3 sentences explaining the diagram — what the arrows mean, what the numbered steps represent.}

## 核心元件說明

### {Component A}

{Scenario: when would an engineer care about this component?}

{Component A} 負責...（解釋職責，不要只列函數名稱）

以下是它的主要入口點，位於 `{path/to/file.go}`：

```go
// File: {path/to/file.go}
{actual code from the file}
```

<Callout type="tip" title="設計決策">
  {Why was it designed this way? What alternative was rejected and why?}
</Callout>

### {Component B}

{same pattern}

## 資料流

{Explain the flow of data through the system. Use numbered steps. Reference the diagram.}

1. 當使用者建立 `{Resource}` 時，{what happens first}
2. {Component A} 收到事件後，{what it does}
3. ...

## 狀態機（如適用）

{If the resource has a Phase/State field, explain the transitions here.}

![{Project} 狀態轉換圖](/diagrams/{project}/state-machine.png)

| 狀態 | 觸發條件 | 下一狀態 |
|------|---------|---------|
| {State A} | {condition} | {State B} |
| {State B} | {condition} | {State C} |

<Callout type="warning" title="注意">
  {Important non-obvious behavior, e.g., what happens if the system crashes mid-transition}
</Callout>

## 相關頁面

<Callout type="info" title="延伸閱讀">
  - [{Feature page title}](../{slug}) — {one line about what's there}
  - [{Another page}](../{slug}) — {one line}
</Callout>
```

---

### Template: Feature Detail Page (`{feature}.mdx`)

```mdx
---
title: "{Project} — {Feature Name}"
description: "{One-line description}"
---

# {Project} — {Feature Name}

## 使用情境

{Concrete scenario: who needs this, what are they trying to accomplish, what breaks without this feature?}

## 工作原理

{High-level explanation without code. Answer: what are the key steps? who is involved? what are the inputs and outputs?}

{diagram if applicable}

![{Feature} 流程圖](/diagrams/{project}/{feature}-flow.png)

## 核心邏輯

### {Sub-feature or Step 1}

{One sentence explaining what the code below does.}

```go
// File: {real/path/to/file.go}
{actual code from grep/view}
```

{1-2 sentences interpreting the code — what to notice, what's non-obvious.}

### {Step 2 / Sub-feature 2}

{One sentence explaining what the code below does.}

```go
// File: {real/path/to/file.go}
{actual code}
```

## 設定選項

| 參數 | 類型 | 預設值 | 說明 |
|------|------|--------|------|
| `{field}` | `{type}` | `{default}` | {what it controls} |

## 注意事項

<Callout type="warning" title="常見陷阱">
  {What breaks in production. What limits exist. What's not obvious from the docs.}
</Callout>

<Callout type="tip" title="最佳實踐">
  {Recommendation based on the code analysis.}
</Callout>

## 相關頁面

<Callout type="info" title="延伸閱讀">
  - [{Related page}](../{slug}) — {one line}
</Callout>
```

---

### Template: Quiz Page (`app/[project]/quiz/page.tsx`)

The quiz page is a React route that reads from `content/{project}/quiz.json`. It does not use MDX. See [quiz-generation/SKILL.md](../quiz-generation/SKILL.md) for how to generate quiz questions.

The quiz.json format:
```json
[
  {
    "section": "🏗️ 核心架構",
    "question": "1. {question text}",
    "options": [
      "{option A}",
      "{option B}",
      "{option C}",
      "{option D}"
    ],
    "answer": 0,
    "explanation": "{why the answer is correct, and why others are wrong}"
  }
]
```

---

## Component Usage in MDX

### `<Callout>`

Use for important asides, warnings, tips, and contextual notes.

```mdx
<Callout type="info" title="背景知識">
  This is informational context.
</Callout>

<Callout type="warning" title="注意">
  This warns about non-obvious behavior or common mistakes.
</Callout>

<Callout type="tip" title="提示">
  This offers a practical recommendation.
</Callout>

<Callout type="danger" title="警告">
  This warns about something that can cause data loss or security issues.
</Callout>
```

**When to use each type:**

| Type | Use for |
|------|---------|
| `info` | Background context, related concepts, cross-references |
| `warning` | Common mistakes, non-obvious limitations, version differences |
| `tip` | Best practices, performance hints, workflow recommendations |
| `danger` | Data loss risks, security issues, breaking change warnings |

**Callout placement rules:**
- `warning` and `danger`: place AFTER the explanation, not before. The reader needs context before the caution is meaningful.
- `tip`: place AFTER the main explanation, as a "now that you understand, here's how to use it well" addition.
- `info`: can appear anywhere, often best at the start of a section to provide context.

---

### `<QuizQuestion>`

Use in quiz pages (via quiz.json) — **not in regular feature MDX pages**.

The component is used by the quiz route at `app/[project]/quiz/page.tsx` and reads from `content/{project}/quiz.json`. Individual feature pages should not embed quiz questions.

---

## Diagram Usage

All diagrams are static PNG files (generated with `skills/fireworks-tech-graph/`).

**Where to store them:** `next-site/public/diagrams/{project}/{diagram-name}.png`

**How to reference in MDX:**
```mdx
![Architecture overview](/diagrams/{project}/architecture.png)
```

**Naming conventions:**
- `architecture.png` — overall system architecture
- `state-machine.png` — resource phase/state transitions
- `{feature}-flow.png` — flow diagram for a specific feature
- `{feature}-sequence.png` — sequence diagram for multi-actor flows

**When a diagram is needed:**
- Any page that describes a multi-step flow with 3+ actors → sequence or flow diagram
- Any page that describes resource lifecycle states → state machine diagram
- The architecture page → always needs an architecture diagram

If a diagram generator script is needed, save it in `scripts/diagram-generators/{project}-{diagram}.py`.

---

## Common Writing Anti-Patterns

### Anti-pattern: The Definition Dump

Writing a page that starts with a list of definitions:

```
## 基本概念

**Machine**: A Machine is a Kubernetes custom resource that...
**MachineSet**: A MachineSet is a Kubernetes custom resource that...
**MachineDeployment**: A MachineDeployment is a Kubernetes custom resource that...
```

**Fix:** Start with a scenario where an engineer needs to understand these things. Introduce each concept *when the scenario calls for it*, not in a batch at the beginning.

---

### Anti-pattern: The Wall of Code

A section that is 80% code blocks with minimal explanation between them.

**Fix:** Apply Rule 5 (explain before quote) to every block. After each block, add 1-2 sentences interpreting what the code shows. Then move to the next block.

---

### Anti-pattern: The Shallow Architecture Section

```
## 架構

這個專案包含 Controller、API Server 和 Webhook 三個元件。
Controller 負責協調資源。API Server 提供 API。Webhook 驗證資源。
```

**Fix:** Each component deserves a dedicated subsection explaining *what problem it solves* (not just what it does), *how it interacts with the others*, and *what would break if it were removed*.

---

### Anti-pattern: Missing Cross-References

Pages written in isolation with no links to related pages.

**Fix:** Every page must end with a `<Callout type="info">` block listing 2-4 related pages with one-line descriptions of what's there.

---

## Language Reference

**Approved zh-TW phrasing for common documentation patterns:**

| English | zh-TW |
|---------|-------|
| "reconcile loop" | 協調迴圈 |
| "watches for changes" | 監聽變化 / 監控事件 |
| "owner reference" | 擁有者參考 |
| "control plane" | 控制平面 |
| "data plane" | 資料平面 |
| "bootstrap" | 引導啟動（keep "bootstrap" in code) |
| "provision" | 佈建 |
| "drain a node" | 排空節點 |
| "cordon a node" | 隔離節點 |
| "garbage collect" | 垃圾回收 |
| "leader election" | Leader 選舉 |
| "lease" | 租約 (keep "Lease" for the Kubernetes resource) |

**Always keep in English (never translate):** Controller, Reconciler, CRD, CR, Webhook, Operator, Pod, Node, Namespace, ConfigMap, Secret, Deployment, StatefulSet, DaemonSet, ReplicaSet, Service, Ingress, PersistentVolume, PersistentVolumeClaim, StorageClass, RBAC, ClusterRole, ServiceAccount, Finalizer, OwnerReference, Phase, Status, Spec, Annotation, Label, Selector.
