# SP-8 molearn 對照迭代 loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `hwchiu/molearn` 加為只讀參考，迭代打磨 learning-k8s 直到 6 project × 8 rubric 全部 ≥ 9/10。

**Architecture:** 每輪 loop 用 3 個並行 subagent（Beginner Read / Molearn Compare / Rubric Scorer）產出 pain-points + reference + 分數矩陣；主對話整合後派送 Apply subagents 各自改一個項目並 commit；最後 Re-score 決定停或繼續。

**Tech Stack:** Next.js 14 + MDX、Python 3 validate.py、git submodule、subagent 並行（superpowers:dispatching-parallel-agents）。

---

## File Structure

新建：
- `molearn/`（submodule，只讀）
- `.gitmodules`（追加 molearn 條目）
- `docs/superpowers/loop/README.md`（loop 流程說明）
- `docs/superpowers/loop/{N}-pain-points.md`（每輪）
- `docs/superpowers/loop/{N}-molearn-references.md`（每輪）
- `docs/superpowers/loop/{N}-rubric.md`（每輪初評）
- `docs/superpowers/loop/{N}-final-rubric.md`（每輪 Apply 後重評）
- `docs/superpowers/loop/{N}-summary.md`（每輪摘要）
- `docs/superpowers/loop/blocker-{項目}.md`（如有）

修改（依每輪 Apply 結果）：
- `next-site/content/**/*.mdx`、`quiz.json`
- `next-site/lib/projects.ts`
- `next-site/public/diagrams/**`
- `skills/**`
- `scripts/validate.py`、`CLAUDE.md`（必要時）

不動：`next-site/{app,components,styles}/**`、既有 5 個 submodule、`Makefile`、`package.json`、`LICENSE`。

---

## Task 1: Bootstrap — 加 molearn submodule + 建 loop 目錄

**Files:**
- Modify: `.gitmodules`
- Create: `molearn/`（submodule）
- Create: `docs/superpowers/loop/README.md`

- [ ] **Step 1.1: 在 repo root 加 molearn 為 shallow submodule**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
git submodule add --depth 1 https://github.com/hwchiu/molearn.git molearn
```

Expected: `.gitmodules` 多一條 `[submodule "molearn"]`，`molearn/` 目錄被建立並 checkout HEAD。

如果失敗（網路 / 權限），escalate；不要自行用 clone + 複製。

- [ ] **Step 1.2: 確認 .gitmodules 風格與既有條目一致**

Read `.gitmodules`，確認 molearn 的條目格式跟其他五個一樣（可省略 `branch` / `shallow = true`，因為這是參考用，不需要鎖版本）。

預期內容片段：
```
[submodule "molearn"]
	path = molearn
	url = https://github.com/hwchiu/molearn.git
```

- [ ] **Step 1.3: 確認 molearn 目錄結構**

Run:
```bash
ls molearn/ | head -20
ls molearn/next-site/content/ 2>/dev/null
ls molearn/skills/ 2>/dev/null
```

Expected: 看到 `next-site/`、`skills/`、`README.md` 等。如果沒看到 `next-site/content/`，記到 `docs/superpowers/loop/README.md` 的「molearn 結構觀察」段。

- [ ] **Step 1.4: 跑 make validate 確認加 submodule 沒打壞既有規則**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate
```

Expected: exit 0。如果 validate.py 因為 submodule 多了一個目錄而誤掃，需要在 validate.py 加排除（只在這步才動 validate.py）。

- [ ] **Step 1.5: 建 loop scaffolding 目錄與 README**

Create `docs/superpowers/loop/README.md`:

```markdown
# SP-8 Loop 工作目錄

每輪 loop 的中介產出物。命名規則：`{N}-{stage}.md`，N 從 1 開始遞增。

## 檔案類型

| 檔案 | 由誰寫 | 內容 |
|---|---|---|
| `{N}-pain-points.md` | Agent A (Beginner Read) | 6 project 的卡住點清單，每點 ≤2 行 |
| `{N}-molearn-references.md` | Agent B (Molearn Compare) | 對應 pain-points 的 molearn 參考位置 |
| `{N}-rubric.md` | Agent C (Rubric Scorer) | 6×8 分數矩陣 + 每個 < 9 的理由 |
| `{N}-final-rubric.md` | Agent C (Re-score) | Apply 後重評矩陣，停止判斷依據 |
| `{N}-summary.md` | 主對話 | ≤200 字摘要：本輪改了什麼、下一輪打算動什麼 |
| `blocker-{項目}.md` | 任何 agent | 卡住、需使用者拍板的項目 |

## Rubric 編號（見 spec §3）

1. 導航 / 結構  2. 內容深淺  3. Quiz 連動  4. 圖表
5. 動手體驗     6. learningPaths  7. AI workflow  8. 語言一致性

## Project 列表

`kubernetes` / `cilium` / `kubevirt` / `ceph` / `multus-cni` / `learning-plan`
```

- [ ] **Step 1.6: Commit Task 1**

Run:
```bash
git add .gitmodules molearn docs/superpowers/loop/README.md
git status
git commit -m "$(cat <<'EOF'
feat(sp-8): bootstrap molearn submodule and loop scaffolding

Add hwchiu/molearn as a read-only submodule for cross-reference, and
create docs/superpowers/loop/ with a README that fixes the per-round
file naming convention.
EOF
)"
```

Expected: commit 成功，`git status` 乾淨。

---

## Task 2: Loop Iteration（可重複執行的單輪）

**這個 Task 在每一輪 loop 都會重跑一次。** 第一次執行時 N=1。每跑完一次 Step 2.6 會回報目前的停止判斷；如果還沒停，把 N+1 重跑這個 Task。

**Files (per iteration):**
- Create: `docs/superpowers/loop/{N}-pain-points.md`
- Create: `docs/superpowers/loop/{N}-molearn-references.md`
- Create: `docs/superpowers/loop/{N}-rubric.md`
- Create: `docs/superpowers/loop/{N}-final-rubric.md`
- Create: `docs/superpowers/loop/{N}-summary.md`
- Modify: 視 Apply 結果而定（content MDX / projects.ts / skills / validate）

- [ ] **Step 2.1: 並行派送 3 個 Discovery subagents**

用一個訊息發 3 個 Agent tool call（`subagent_type=Explore` 因為都是只讀分析），每個 prompt 自包含。模板：

**Agent A — Beginner Read**
```
你是初學者 persona（3 年後端、跑過 docker、知道 k8s 是什麼但沒架過、不熟 CNI/CSI/cgroup/eBPF/virtio）。

任務：把 learning-k8s 的 6 個 project 的 MDX 通讀一次：
- next-site/content/kubernetes/features/*.mdx
- next-site/content/cilium/features/*.mdx
- next-site/content/kubevirt/features/*.mdx
- next-site/content/ceph/features/*.mdx
- next-site/content/multus/features/*.mdx
- next-site/content/learning-plan/features/*.mdx

對每個 project 列出 3-7 個「卡住點」，每點格式：
- 檔案路徑與行號
- 卡住的原因（用 spec 的四個訊號之一：要回頭翻、術語沒鋪陳、quiz 不連動、圖未交代）
- 一句話建議方向

整份 ≤500 字。寫到 docs/superpowers/loop/{N}-pain-points.md。
```

**Agent B — Molearn Compare**
```
任務：對照 ./molearn/ 的 next-site/content/、lib/projects.ts、skills/，找出 learning-k8s 各 project 對應位置在 molearn 是怎麼處理的。

切入角度（對照 spec 的 8 項 rubric）：
1. molearn 的 sidebar / featureGroups 怎麼分？
2. molearn MDX 的「為什麼/怎麼用/原始碼」三段比例？
3. molearn quiz.json 的題目跟 MDX 連動怎麼做？
4. molearn 圖表規範？
5. molearn 有沒有 hands-on lab？
6. molearn learningPaths 結構？
7. molearn skills/ 的工作流文件？
8. molearn 語言風格？

每點給「molearn 檔案路徑 + 一句話描述差異」。≤500 字。寫到 docs/superpowers/loop/{N}-molearn-references.md。
```

**Agent C — Rubric Scorer**
```
任務：用 docs/superpowers/specs/2026-05-08-sp8-molearn-loop-design.md §3 的 8 項 rubric，給 learning-k8s 6 個 project 打分（0-10），不適用標 N/A。

格式（Markdown 表格）：
| project | r1 | r2 | r3 | r4 | r5 | r6 | r7 | r8 |
| kubernetes | ... | ... | ... | ... | ... | ... | ... | ... |
| cilium | ... |
| kubevirt | ... |
| ceph | ... |
| multus-cni | ... |
| learning-plan | ... |

每個 < 9 的格子下方寫一段 ≤2 行的扣分理由，引用具體檔案。

如果 N>1，**同時也列出**上一輪 final-rubric 的分數做對比（兩欄並排）。

寫到 docs/superpowers/loop/{N}-rubric.md。
```

3 個 Agent 用一個訊息並行送出。等三份都回。

- [ ] **Step 2.2: 整合三份檔案，列出本輪 Apply 清單**

讀 `{N}-pain-points.md`、`{N}-molearn-references.md`、`{N}-rubric.md`。

挑選本輪要動的項目（**主對話自己決定**，不派 agent）：
- 條件：rubric 該格 < 9 **且** pain-points 有對應卡住點 **且** molearn 有參考位置（沒有就標 `no-molearn-reference` 但仍可動）。
- 排序：影響面廣的先動（影響多個 project 的 skills/ 改動 > 單一 project 的 MDX 微調）。
- 限額：每輪最多動 5 個項目，避免單輪改太大難以追蹤。

把清單寫進 `{N}-summary.md` 的「本輪計畫」段落（後面 Step 2.6 會補完整摘要）。

- [ ] **Step 2.3: 並行派送 Apply subagents**

每個項目一個 subagent（`subagent_type=general-purpose`，需要寫檔），每個 prompt 自包含：

模板：
```
任務：[一句話描述要改什麼，例如「補 next-site/content/cilium/features/datapath.mdx 的『為什麼存在』段落」]

背景：
- learning-k8s spec 在 docs/superpowers/specs/2026-05-08-sp8-molearn-loop-design.md
- 本輪 pain-point：[從 {N}-pain-points.md 引用]
- molearn 參考：[從 {N}-molearn-references.md 引用，或標 no-molearn-reference]

可動範圍（spec §4）：MDX / projects.ts / public/diagrams / skills / validate.py / CLAUDE.md
不動：next-site/app|components|styles、其他 submodule、Makefile、package.json、LICENSE

語言：台灣繁中、never-translate 詞保留英文（見 CLAUDE.md）

完成後：
1. 跑 cd /Users/ikaros/Documents/code/learning-k8s && make validate，貼最後 5 行
2. git add 改動的檔案
3. git commit -m "fix(sp-8)[loop-{N}][項目代號]: 簡述"
4. 回報：改了哪些檔案、validate 結果、commit hash

如果 make validate 失敗，revert 改動，回報失敗原因，不要強推。
如果遇到必須使用者決定的卡點，寫 docs/superpowers/loop/blocker-{項目}.md 並回報，不要 commit。
如果 commit / merge 衝突，先嘗試 git pull --rebase 解；解不了 escalate。
```

並行送出。等全部回完。

- [ ] **Step 2.4: 主對話檢查每個 Apply 結果**

對每個 subagent 的回報：
- 確認 commit hash 真實存在：`git log --oneline -1 <hash>`
- 確認 validate 真的過：自己再跑一次 `make validate`
- 如果有 subagent 回 revert，把該項目記到 `{N}-blockers.md`

如果 `make validate` 在某個 commit 後爆炸（subagent 沒抓到），定位到出問題的 commit，`git revert <hash>` 並把該項目改記為 blocker。

- [ ] **Step 2.5: 派送 Re-score subagent**

```
任務：跟 {N}-rubric.md 同樣 rubric，重新給 6 project × 8 項打分。

差異：這次是 Apply 完成後的狀態。

格式：跟 {N}-rubric.md 一樣的表格，但檔名是 docs/superpowers/loop/{N}-final-rubric.md。

額外加一段：
- 跟 {N}-rubric.md 比，哪些格子分數變了
- 是否 6×8 (扣除 N/A) 全部 ≥ 9
- 如果還沒，哪幾格仍 < 9
```

等回。

- [ ] **Step 2.6: 寫本輪 summary 並判斷停止**

讀 `{N}-final-rubric.md`。寫 `docs/superpowers/loop/{N}-summary.md` ≤200 字：

```markdown
# Loop {N} Summary

## 本輪改了什麼
- [項目 1]：[一句話] (commit <hash>)
- [項目 2]：...

## 分數變化
- [項目 X]：[原分] → [新分]

## 停止判斷
- 全部 ≥9：是 / 否
- [若否] 下一輪打算動：[項目清單]
- [若是] 收工，不再進下一輪
```

Commit:
```bash
git add docs/superpowers/loop/{N}-*.md
git commit -m "docs(sp-8): loop-{N} summary and rubric"
```

**判斷出口：**
- 全部 ≥ 9 → loop 結束，跳到 Task 3
- 仍有 < 9 且非 blocker → N+1，重跑 Task 2
- 剩下都是 blocker → 跳到 Task 3 並在最終回報註明

---

## Task 3: 結束 Loop — 終評與清理

**Files:**
- Create: `docs/superpowers/loop/FINAL.md`

- [ ] **Step 3.1: 整合所有輪的 final-rubric**

寫 `docs/superpowers/loop/FINAL.md`：
- 表頭：起始日 / 結束日 / 共幾輪
- 每輪一行：N、改了幾項、分數總增量
- 最終 6×8 分數矩陣
- 仍未達標的項目（如有）與原因（blocker）
- 對 learning-k8s 的整體建議（≤200 字）

- [ ] **Step 3.2: 若有 blocker，整理成 follow-up 清單**

把所有 `blocker-*.md` 列在 FINAL.md「未解項目」段，標明每個需要使用者怎麼決定。

- [ ] **Step 3.3: 跑最終 make validate**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate
```

Expected: exit 0。

- [ ] **Step 3.4: Commit FINAL**

```bash
git add docs/superpowers/loop/FINAL.md
git commit -m "$(cat <<'EOF'
docs(sp-8): final molearn-loop report

Wraps SP-8 with the final rubric matrix, per-round delta, and any
unresolved blockers requiring user decisions.
EOF
)"
```

- [ ] **Step 3.5: 推上 origin（若使用者授權）**

**不要**自動 push。在最終回報結束時請使用者決定是否 `git push`。

---

## Self-Review

**1. Spec coverage:**
- §1 背景：Task 1 加 submodule 對應 ✓
- §2 persona：Step 2.1 Agent A prompt 引用 ✓
- §3 8 項 rubric：Step 2.1 Agent C + Step 2.5 引用 ✓
- §4 範圍：Step 2.3 prompt 明列 ✓
- §5 並行 subagent：Task 2 三段並行 + Apply 並行 ✓
- §6 失敗處理：Step 2.3 prompt 含 revert / blocker / 衝突 rebase ✓
- §7 產出物清單：File Structure + 每個 Step 對應 ✓
- §8 非目標：Task 2.3 prompt 的「不動」清單對應 ✓

**2. Placeholder scan:** 無 TBD/TODO；每個 subagent prompt 都自包含；所有檔案路徑明確。

**3. Type consistency:** 檔名格式 `{N}-stage.md` 全文一致；rubric 編號 1-8 全文一致；`make validate` 指令全文一致。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-08-sp8-molearn-loop.md`.

兩個執行選項：

1. **Subagent-Driven（推薦）** — 我每個 Task 派一個 fresh subagent，Task 之間給你看結果再進下一個。
2. **Inline Execution** — 在這個對話直接跑，每個 Task 結束 checkpoint。

選哪個？
