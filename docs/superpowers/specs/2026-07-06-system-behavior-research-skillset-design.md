# System Behavior Research Skill Set（EFAS 迴圈 generalize）設計

- 日期：2026-07-06
- 狀態：spec 已核可，待寫 implementation plan
- 來源：SP-6 ceph 線（alert redesign → alert-real-lab → incident-bundle）累積出的隱性方法論，本設計把它顯性化、generalize 成可重用的 skill set。

## 緣起

ceph 線的實際工作流程已自然長成一個研究迴圈：source-first 文章頁 → alert rules 設計 → 25 個 scenario 的真機驗證框架（inject → observe → collect → rollback → assert）→ evidence summary → findings 回寫成文章頁與 rule 修改。其中最有價值的發現（mgr exporter 在真 quorum loss 後仍回報 `sum(ceph_mon_quorum_status)=3` 的 stale telemetry）來自「觀測路徑本身也會壞」這類邊界——這類邊界靠結構化窮舉可以在動手前系統性找到，而不是靠運氣。

本設計把這套流程抽象成通用方法論，做成 repo 內的 skill set，讓之後任何「系統行為研究」（Ceph、Kubernetes、資料庫、網路設備、任何有 source of truth 可驗證的 infra）都能重複使用。

## 已裁決的設計決策

| 問題 | 決定 |
|---|---|
| 適用範圍 | 任何「系統行為研究」：有 source of truth（原始碼／真環境／文件）可驗證的技術系統。不綁定本 repo 的 MDX/alert 產出格式。 |
| 存放位置 | 本 repo `skills/`，與 `analyzing-source-code` 等既有 skill 同一套規則管理。 |
| 自主程度 | 三閘門制：AI 自動跑各 stage，只在 (1) backlog 優先序裁決 (2) 破壞性／不可回退操作 (3) 發現的取捨 三處停下等人。 |
| 架構 | C+：一個核心 orchestrator skill + 兩個可單用的衛星 skill（邊界窮舉、實驗合約）。 |
| 本輪範圍 | 只做計畫（spec → plan），不實作 skill。 |

## 方法論全貌：Frame → Enumerate → Falsify → Automate → Synthesize

核心觀念：AI 的槓桿在三件事——窮舉（人腦會漏、AI 不會累）、對抗（AI 可廉價扮演「想弄壞你設計的人」）、閉環（從 claim 到 evidence 到 artifact 不偷懶地走完）。人保留兩件事：決定什麼值得深入（taste／優先序），以及把關不可回退的操作。

### Stage 0 — Frame（定框）

兩步：

1. **AI 先做初步研究**：快速掃 source of truth（原始碼、環境、文件）。目的不是回答問題，是讓接下來的提問有料——沒讀過東西的 AI 只能問泛泛的問題。
2. **Brainstorming 式問答**：一次一題（互動形式借鑑 `superpowers:brainstorming`，但目標不同——不是收斂設計，是**測繪使用者的知識邊界**）。提問策略刻意涵蓋三區：
   - 使用者知道的（確認共識、建立版本錨點）
   - 使用者知道自己不知道的（使用者主動提出的疑問）
   - 使用者不知道自己不知道的（AI 從初步研究看到、但使用者的提問從未觸及的區域；pre-mortem 式提問的主戰場）

   **關鍵機制：使用者答不出來或答「不確定」的問題，直接轉成研究項目進 backlog。**

產出：研究章程（目標、範圍、版本錨點、驗證等級定義）寫進 `HYPOTHESES.md` header + 第一批種子假設。

### Stage 1 — Enumerate（窮舉）

Invoke 衛星 skill `enumerating-adversarial-boundaries`。用結構化軸填矩陣，而非開放式地問「還有什麼要注意」：

```
組件軸 × 故障模式軸（crash / slow / partial / stale / lying）× 觀測路徑軸（訊號送達？延遲？說謊？）
```

輔以 pre-mortem prompt（「假設它在真事故時失效，寫出五種原因」）、negative-space 檢查（「全部 X 對照現有 Y，哪些沒有對應」）、多視角平行（SRE／Code Reviewer／跨模型）。

產出：假設寫入 backlog，狀態 `proposed`。每條是可證偽的句子（「X 情況下 Y 會在 Z 時間內發生」），標驗證等級。

### ⛩ Gate 1：使用者對 backlog 做優先序裁決

### Stage 2 — Falsify（研究與預測）

每條假設走三層證據交叉：原始碼 → 官方文件 → 真環境。AI 可平行 fan-out，但每個 claim 必須落回 evidence 錨點（file:line 或環境輸出）。研究的終點不是「理解了」，是**寫下可比對的 prediction**（狀態 `predicted`）。

### Stage 3 — Automate（實驗）

照衛星 skill `designing-falsifiable-experiments` 的合約執行：

```
inject → observe → collect evidence bundle → rollback → assert 恢復基線
```

紀律：**跑之前先寫下預期結果，跑完機器比對**（實驗版 TDD）。prediction 與 observation 不一致的地方是整個迴圈最有價值的產出，也是 AI 事後合理化最容易吃掉的東西——必須由機器比對，不靠人眼。

AI 可全自動跑的邊界：冪等、可回退、有 ok-to-stop 類前置檢查的 scenario。

**⛩ Gate 2：破壞性／不可回退操作由使用者直接控**（與 CLAUDE.md 現行規則一致：每步可回退、確認恢復才進下一步）。

產出：假設標 `confirmed` 或 `violated` + evidence bundle。

### Stage 4 — Synthesize（收斂）

每個 finding 必走三路，缺一路就是漏水：

1. **報告**：evidence summary、findings 文章頁。
2. **實體 artifact**：script、alert rule、runbook 的具體修改。一個 finding 若沒有改變任何 artifact，它只是 trivia。
3. **回饋矩陣**：新發現的故障類別寫回窮舉軸（`axes.md`），下一輪窮舉自動涵蓋同類邊界——迴圈越轉越強的原因。

**⛩ Gate 3：使用者裁決哪些發現值得深入或成文。**

`violated` 假設與新故障類別回流到 backlog 與 axes，形成迴圈。

### 駕駛要點（寫進核心 SKILL.md 的操作紀律）

- 一次一個可證偽問題，不接受「幫我研究 X」等級的模糊輸入（Stage 0 的職責就是把它變具體）。
- Producer 與 verifier 分開：寫 rule 的 session 不驗 rule，用不同 agent 或跨模型驗。
- Artifacts 是跨 session 記憶體：`HYPOTHESES.md`、evidence summary、axes 讓下一個 session 不用重推脈絡。

## Skill Set 結構（C+）

命名沿用 repo 動名詞慣例：

```
skills/
  researching-system-behavior/        # 核心 orchestrator
    SKILL.md                          # 5 stages、3 gates、backlog 狀態機、半途進入條件
    references/
      framing-dialog.md               # Stage 0 提問策略（三區測繪、答不出→入 backlog）
      hypothesis-backlog.md           # HYPOTHESES.md 格式與生命週期
      evidence-tiers.md               # 三層驗證與 claim 錨點規則
      synthesis-rules.md              # finding→三路、回饋矩陣

  enumerating-adversarial-boundaries/ # 衛星 1：可單用於 review／設計把關
    SKILL.md                          # 窮舉矩陣方法、何時算窮舉完成
    references/
      axes.md                         # 窮舉軸模板 + 跨輪次累積的故障類別
      prompt-patterns.md              # pre-mortem、negative-space、多視角 prompt 庫

  designing-falsifiable-experiments/  # 衛星 2：可單用於「寫一個可回退實驗」
    SKILL.md                          # scenario 合約：prediction 先行、五段結構、回退斷言
    references/
      scenario-checklist.md           # 冪等性、前置檢查、evidence bundle 規格
```

耦合規則：

- 核心引用兩顆衛星；衛星互不相識、也不知道核心存在。
- 衛星 1 可被 `reviewing-source-first-pages`、多視角 review 迴圈等既有流程直接引用（輸出可以只是 findings 清單，不強制進實驗；但輸出格式與 `HYPOTHESES.md` 相容，之後可升級成完整研究）。
- 衛星 2 可單用於任何「想寫一個可回退實驗」的情境。
- 三閘門與 stage 轉換規則只寫在核心一份（DRY）。

## 檔案合約（跨 session 記憶體）

- **`HYPOTHESES.md`**：每個研究一份，放該研究目錄下。header 是研究章程；每條假設一個 entry：可證偽敘述、驗證等級、prediction、evidence 連結、產出的 artifact、狀態。狀態機：

  ```
  proposed → predicted → confirmed / violated → synthesized
  ```

  這是唯一的跨 stage 接口，也是半途進入的判定依據（檔案在哪個狀態，就從哪個 stage 續跑）。

- **`axes.md`**（衛星 1 內，全域累積）：故障類別軸隨每輪發現成長。例：ceph 線挖到的「觀測者說謊」類別寫入後，下次研究任何系統都自動涵蓋同類邊界。

- **Evidence bundle**：raw 輸出目錄不進 git；committed 的 `EVIDENCE-SUMMARY` 當索引。直接沿用 `experiments/ceph-alert-real-lab` 已驗證的做法。

## 整合與邊界

- Skill 本體用英文寫（repo 慣例、model-agnostic）。
- 方法論 output-agnostic；核心 SKILL.md 內一小節 output adapter：「在 learning-k8s 內，報告路走 `source-first-topic-page`、圖走 `fireworks-tech-graph`、測驗走 `quiz-generation`」。
- Stage 0 與 `superpowers:brainstorming` 的關係寫明：形式借鑑（一次一題）、目標不同（測繪知識邊界 vs 收斂設計），避免觸發混淆。
- 三閘門直接引用 CLAUDE.md 的破壞性操作規則，不重寫。

## 非目標

- 本輪不實作 skill（spec → plan 後另開實作）。
- 不涵蓋非技術系統的研究（文獻調查、市場研究）。
- 不取代 `analyzing-source-code`（整個新專案的首次分析）與 `source-first-topic-page`（單一專題頁產出）；本 skill set 是研究方法層，產出端銜接它們。

## 驗收方式（實作階段執行，此處先定標準）

1. **Dry-run**：拿一個真題目（下一個 ceph 主題或其他 SP 新題目）跑完整迴圈，五個 stage、三個閘門、`HYPOTHESES.md` 狀態機全部走過。
2. **回測**：把 `ceph-alert-real-lab` 對照方法論走一遍，確認框架能還原出當時的關鍵發現（stale telemetry 應落在「mon × 真故障 × 觀測路徑說謊」格），證明框架不是事後諸葛。
3. **衛星單用**：衛星 1 在一次 review 迴圈中單獨觸發並產出 findings 清單；衛星 2 單獨產出一個符合合約的 scenario script。
4. 三個 skill 通過 `superpowers:writing-skills` 的驗證流程後才算完成。
