---
name: quiz-generation
description: Use when generating interactive team quiz questions from existing project documentation. Produces quiz.json format for the React QuizQuestion component (zh-TW, 4-choice, with explanation). Supports automatic topic decomposition based on project complexity. Model-agnostic — works with any AI tool.
---

# Quiz Generation Skill

## 概述

從現有的專案文件（`next-site/content/{project}/features/`）產生互動式測驗題目，輸出為 `content/{project}/quiz.json` 格式，供工程師自我評測。

**核心原則：**
- 題目必須基於文件內容，**禁止杜撰**
- **涉及函數名稱、類型名稱、欄位名稱的題目，必須在原始碼中 grep 確認名稱存在後才能出題**
- 每題必須有清楚的正確選項與錯誤誘答（distractors）
- 中文繁體（zh-TW），術語保留英文原名
- 題目難度要有層次：概念理解 → 細節掌握 → 情境應用

## 整體流程

```
Phase A: 主題分析（自動分解，不使用固定模板）
Phase B: 平行出題（每個主題一輪 AI 對話）
Phase C: 組裝為 quiz.json
Phase D: 整合驗證（npm run build）
```

---

## Phase A: 主題分析（Topic Decomposition）

### 前置步驟：確認原始碼路徑

在開始分析之前，先確認專案的原始碼 submodule 是否可用：

```bash
# 確認 submodule 已初始化
ls {project}/

# 若目錄為空，初始化 submodule
git submodule update --init {project}
```

**記錄此路徑，在 Phase B 出題時用於驗證函數/類型名稱。**

### 演算法：動態主題分解

**不使用固定分類**，根據專案的重要度與特性自動決定測驗分區。

#### Step 1: 讀取文件結構

```bash
ls next-site/content/{project}/features/
```

列出所有文件頁面，了解該專案文件的廣度。

#### Step 2: 計算複雜度信號

對每個主題頁面，計算以下信號：

| 信號 | 說明 | 計算方式 |
|------|------|---------|
| **頁面數量** | 文件頁面總數 | `ls next-site/content/{project}/features/*.mdx \| wc -l` |
| **內容深度** | 每頁平均行數 | `wc -l next-site/content/{project}/features/*.mdx` |
| **CRD/API 覆蓋率** | 是否有 CRD/API 專屬頁面 | 頁面存在 → +2 |
| **元件數量** | 核心元件個數 | 元件頁面數 |
| **整合複雜度** | 外部整合頁面數 | 整合頁面數 |

#### Step 3: 分類決策

根據信號決定「要出幾個主題分區」：

| 文件頁面數 | 建議主題數 | 說明 |
|-----------|-----------|------|
| 1–4 頁    | 2–3 個    | 輕量專案 |
| 5–9 頁    | 3–5 個    | 中型專案 |
| 10+ 頁   | 5–8 個    | 大型專案 |

#### Step 4: 命名主題分區

每個主題分區命名規則：
- 使用 emoji + 中文名稱，例如：`🏗️ 基礎架構`
- 每個分區對應文件中的一個**邏輯群組**，而非逐頁對應
- 確保分區間不重疊，各自有清晰的知識邊界

**大型專案常見分區模式：**
```
🏗️ 基礎架構      ← 架構、設計原則、部署模型
⚙️ 核心元件      ← 各 daemon/controller 的職責
🌐 API 與網路    ← CRD、API 規格、網路配置
💾 儲存與輔助元件 ← 儲存、snapshot、helper 元件
🚀 進階功能      ← migration、高可用、效能調優
🔬 深入剖析      ← monitoring、metrics、問題排查
📖 實用指南      ← 操作流程、最佳實踐
```

**中小型專案示例：**
```
⚙️ 核心架構與元件
🔄 操作流程與 CRD
🌐 整合與觀測性
```

#### Step 5: 決定每個分區的題目數

- 基本：每個分區 **20 題**（快速測驗）
- 標準：每個分區 **30 題**（完整評測）
- 深度：每個分區 **40 題**（全面訓練）

---

## Phase B: 出題

每個主題分區發送一輪獨立的 AI 對話，可以並行運行（每個分區一個對話視窗），也可以循序執行。

### 給每個分區的 Prompt 模板

**Send this prompt to your AI for each topic section:**

```
你是一位專業的 Kubernetes 教育工作者，請為「{分區名稱}」主題出 {N} 道選擇題。

## 來源文件（必須閱讀）
以下是你出題時必須參考的文件，請完整閱讀後再出題：
- next-site/content/{project}/features/{page1}.mdx
- next-site/content/{project}/features/{page2}.mdx
{其他相關頁面}

## 原始碼路徑（函數/類型名稱驗證用）
- 專案 submodule 路徑：{project}/
- **出題時若涉及具體函數名稱、類型名稱、欄位名稱，必須先 grep 原始碼確認存在**

## 出題要求

1. **題目格式**：單選，4 個選項（A/B/C/D），1 個正確答案
2. **語言**：繁體中文，技術術語保留英文原名
3. **難度分布**（每 30 題）：
   - 10 題：概念理解（What is / What does）
   - 10 題：細節掌握（How / When / Which）
   - 10 題：情境應用（Given ... what happens / which approach）
4. **禁止**：模糊選項、「以上皆是」、不看文件就能猜出的答案
5. **必須**：每題有清楚的解釋，說明「為什麼是這個答案」以及「其他選項為何錯誤」

## ⛔ 零捏造原則（Zero Fabrication Rule）

**出題時嚴格禁止以下行為：**
- ❌ 使用文件中未明確出現的函數名稱或類型名稱
- ❌ 根據命名慣例「猜測」函數名稱（如 `handleReconcile()`、`processEvent()` 等）
- ❌ 在 explanation 中引用未經驗證的實作細節

**若題目涉及函數/類型名稱，必須：**
1. 先 grep 原始碼確認存在：`grep -r "FuncName" {project}/`
2. 在 explanation 中標注來源：「此函數定義於 `{project}/path/to/file.go`」
3. 若 grep 無結果，**改出不涉及具體名稱的概念題**

## 輸出格式

每道題按以下 JSON 格式輸出。**最終輸出必須是一個合法的 JSON 陣列，不要有任何其他文字。**

> ⚠️ **不要在 `question` 欄位加題號（如「1. 」）**— quiz page 在渲染時會自動加上 `${i+1}. ` 前綴，手動加號碼會導致「1. 1. 題目…」的雙重編號。

```json
[
  {
    "id": 1,
    "question": "{題目文字（不含題號）}",
    "options": [
      "{選項A}",
      "{選項B}",
      "{選項C}",
      "{選項D}"
    ],
    "answer": 0,
    "explanation": "{解釋為什麼此選項正確，其他選項為何錯誤}"
  },
  {
    "id": 2,
    "question": "{題目文字（不含題號）}",
    "options": ["{選項A}", "{選項B}", "{選項C}", "{選項D}"],
    "answer": 1,
    "explanation": "..."
  }
]
```

**JSON 規則：**
- `id` 為整數，從 1 開始遞增（整個 quiz.json 全域唯一）
- `answer` 是 0-indexed（第一個選項為 0，第四個為 3）
- `question` **不含題號** — page.tsx 自動補上
- 所有字串值內的雙引號用 `\"` 跳脫
- 不要在陣列最後一個元素後加逗號

---

## Phase C: 組裝為 quiz.json

### C1: 合併各分區的 JSON 輸出

每個分區的 AI 輸出一個 JSON 陣列。將所有陣列合併為一個：

```python
import json
import re

# 各分區的 AI 輸出（貼到各個字串變數）
sections = [
    """[  # 貼入分區1的 JSON 輸出
      {...},
      {...}
    ]""",
    """[  # 貼入分區2的 JSON 輸出
      {...},
      {...}
    ]""",
    # ... 其他分區
]

all_questions = []
for section_json in sections:
    # 清除可能的 AI metadata 殘留（如 "Here are the questions:" 等說明文字）
    # 找到 JSON 陣列的起始位置
    start = section_json.find('[')
    end = section_json.rfind(']') + 1
    if start == -1 or end == 0:
        print("WARNING: Could not find JSON array in section output")
        continue
    clean_json = section_json[start:end]
    questions = json.loads(clean_json)
    all_questions.extend(questions)

# 寫入 quiz.json
output_path = 'next-site/content/{project}/quiz.json'
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(all_questions, f, ensure_ascii=False, indent=2)

print(f"Written {len(all_questions)} questions to {output_path}")
```

### C2: 驗證 JSON 格式

```python
import json

with open('next-site/content/{project}/quiz.json', 'r') as f:
    questions = json.load(f)

issues = []
for i, q in enumerate(questions):
    if 'question' not in q:
        issues.append(f"Question {i}: missing 'question'")
    if 'options' not in q or len(q['options']) != 4:
        issues.append(f"Question {i}: 'options' must have exactly 4 items")
    if 'answer' not in q or not isinstance(q['answer'], int) or not (0 <= q['answer'] <= 3):
        issues.append(f"Question {i}: 'answer' must be integer 0-3")
    if 'explanation' not in q:
        issues.append(f"Question {i}: missing 'explanation'")

if issues:
    for issue in issues:
        print(f"ERROR: {issue}")
else:
    print(f"✓ All {len(questions)} questions valid")
```

---

## Phase D: 整合驗證

### D1: 驗證 quiz page 能讀取資料

```bash
cd next-site && npm run dev
# Open http://localhost:3000/{project}/quiz
# Verify: all sections show up
# Verify: clicking an option shows explanation
# Verify: correct answer is highlighted green, wrong answer red
```

### D2: Build 驗證

```bash
cd next-site && npm run build
```

Build 失敗通常不是 quiz.json 的問題（JSON 格式錯誤會在 D1 發現），而是其他頁面的問題。

### D3: Commit

```bash
git add next-site/content/{project}/quiz.json
git commit -m "feat({project}): add {N}-question interactive quiz ({M} sections × ~{K} questions)

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## quiz.json 格式完整規範

```json
[
  {
    "id": 1,
    "question": "ClusterController 在協調 Cluster CR 時，建立 Infrastructure 物件的目的是什麼？",
    "options": [
      "在雲端或實體環境建立對應的基礎設施（VPC、機器等）",
      "產生 kubeconfig 讓工作節點加入叢集",
      "設定 Kubernetes API Server 的 TLS 憑證",
      "啟動 etcd 叢集並等待其就緒"
    ],
    "answer": 0,
    "explanation": "Infrastructure 物件（如 AWSCluster、MaasCluster）由對應的 Infrastructure Provider 實作，負責在底層環境建立實際的計算資源。kubeconfig 是由 ControlPlane 物件負責產生，TLS 和 etcd 管理也由 ControlPlane Provider 負責。"
  },
  {
    "id": 2,
    "question": "另一道題...",
    "options": ["...", "...", "...", "..."],
    "answer": 1,
    "explanation": "..."
  }
]
```

**必須遵守：**
- `id` 為整數，從 1 開始遞增（整個陣列全域唯一）
- `answer` 是 0-indexed（0 = 選項A, 1 = 選項B, 2 = 選項C, 3 = 選項D）
- `question` **不含題號** — quiz page 自動在渲染時補上 `${i+1}. ` 前綴
- `explanation` 說明為何此選項正確，且指出其他選項錯誤的原因
- 所有字串值使用合法的 JSON 跳脫（雙引號用 `\"`）

---

## 完整範例：產生 Cluster API 測驗流程

```bash
# 1. 讀取文件結構
ls next-site/content/cluster-api/features/
# → architecture.mdx, machine-lifecycle.mdx, controllers.mdx, bootstrap.mdx

# 2. Phase A: 主題分析
# 4 頁 → 建立 3 個主題分區，每區 20 題（小型專案）
# 分區：🏗️ 核心架構, ⚙️ 機器生命週期, 🔧 控制器與 Bootstrap

# 3. Phase B: 出題（3 個 AI 對話，可並行）
# 對話1 → 🏗️ 核心架構（讀 architecture.mdx）→ 輸出 JSON
# 對話2 → ⚙️ 機器生命週期（讀 machine-lifecycle.mdx）→ 輸出 JSON
# 對話3 → 🔧 控制器與 Bootstrap（讀 controllers.mdx + bootstrap.mdx）→ 輸出 JSON

# 4. Phase C: 組裝
python3 assemble_quiz.py
python3 validate_quiz.py

# 5. Phase D: 驗證
cd next-site && npm run dev
# 確認 http://localhost:3000/cluster-api/quiz 正常顯示
npm run build

# 6. Commit
git add next-site/content/cluster-api/quiz.json
git commit -m "feat(cluster-api): add 60-question interactive quiz (3 sections × 20 questions)

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## QuizQuestion React 元件使用方式（參考）

The `QuizQuestion` component is defined in `next-site/components/QuizQuestion.tsx` and is used in the quiz page route at `app/[project]/quiz/page.tsx`. It reads from quiz.json and does NOT need to be used directly in MDX files.

Props interface:
```typescript
interface Props {
  question: string     // Full question text — page.tsx prepends "${i+1}. " automatically
  options: string[]    // Exactly 4 options
  answer: number       // 0-indexed correct answer index
  explanation: string  // Shown after user selects an answer
}
```

The quiz page renders all questions as a **flat list** in array order. Questions are numbered automatically (`1.`, `2.`, etc.) — do NOT include numbers in the `question` field. See `skills/site-bootstrap/SKILL.md` for the full route source code.
