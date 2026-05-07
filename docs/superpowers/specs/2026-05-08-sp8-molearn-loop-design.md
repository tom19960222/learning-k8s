# SP-8 — molearn 對照迭代 loop 設計

| 欄位 | 值 |
|---|---|
| 子計畫 | SP-8 |
| 起始日 | 2026-05-08 |
| 主軸 | 以 `hwchiu/molearn` 為參考，迭代打磨 learning-k8s |
| 不動 | next-site UI / 元件 / CSS、既有 submodule 版本、Makefile、package.json、LICENSE |
| 停止條件 | 6 個 project 的 8 項 rubric 分數全部 ≥ 9/10 |

## 1. 背景

`hwchiu/molearn` 是 learning-k8s 的同架構姊妹專案：同樣 Next.js App Router + MDX + QuizQuestion + skills/ 工作流，但分析對象是 CAPI / MAAS / Metal3。它在文件密度、metadata 設計、教學節奏上有可借鑒的選擇。

本 SP 的目標：**把 molearn 的好做法移植回 learning-k8s**，迭代到我（AI）以「初學者」角度讀也覺得無可挑剔。

## 2. 初學者 persona

評分時以這個 persona 為基準（不能設定得太低也不能太高）：

- 工程師背景：寫過 3 年後端，跑過 docker / docker-compose
- 知道 k8s 是什麼但沒架過、沒讀過 source
- 懂 Linux 基本、知道 syscall 是什麼
- **不熟** CNI / CSI / cgroup v2 / eBPF / virtio 內部機制

「卡住點」的訊號：
1. 讀到一個段落要回頭翻第三方資料才看得懂
2. 術語沒前後文鋪陳直接出現
3. quiz 題目跟前文沒連動
4. image / 圖示未交代來源或抽象等級不一致

## 3. 8 項 rubric（停止條件）

每項 0-10 分，**6 個 project × 8 項 = 48 個分數**全部 ≥ 9 才停。允許某些項目對特定 project 標 `N/A`（見下表「適用性」欄），`N/A` 視為已達標。

| # | 項目 | 評分標準（10 分滿） | 適用性 |
|---|---|---|---|
| 1 | 導航 / 結構清晰度 | sidebar 與 features 分群一致；30 秒內知道這個 project 在講什麼；章節順序符合認知路徑 | 全部 |
| 2 | 內容深淺與漸進性 | 每篇 MDX「為什麼存在 → 怎麼用 → 原始碼怎麼實作」三段齊；不跳級、不堆名詞 | 全部 |
| 3 | Quiz 連動性 | 題目與同章節 MDX 一一對得上；`quiz.json` answer 是 0-indexed 整數；distractor 充足；難度梯度合理 | 全部 |
| 4 | 圖表與視覺輔助 | 該有圖的地方有 PNG（非 1×1 placeholder）；圖檔位於 `public/diagrams/{project}/`；有 alt 文字 | 全部 |
| 5 | 動手體驗 | lab 指令在可達環境（kind/minikube）真的可跑；破壞性指令有警告與回退；原始碼引用對得到行 | 主要 learning-plan；其他 project 若有 hands-on 段落才評，否則 `N/A` |
| 6 | 學習路徑（learningPaths）| beginner/intermediate/advanced step 順序合理；每個 step 都有 note 解釋為何看；終點明確 | 5 個原始碼 project 適用；`learning-plan` 本身即路徑，標 `N/A` |
| 7 | AI workflow 文件（skills/）| analyzing-source-code、寫 MDX、加新 project 三流程能讓另一個 AI session 照做；zero-fabrication 規則明確 | 全部（skills/ 是 repo-level，每個 project 共用同份分數）|
| 8 | 語言一致性 | 100% 台灣繁中；never-translate 詞全留英文；無大陸用語；註解英文；frontmatter 正確 | 全部 |

## 4. 範圍

### 可動

- `next-site/content/**/*.mdx`、`quiz.json`
- `next-site/lib/projects.ts`（含 metadata / story / learningPaths schema 與資料）
- `next-site/public/diagrams/**`（補圖、換圖）
- `skills/**`、`docs/superpowers/specs/**`、`docs/superpowers/plans/**`
- `scripts/validate.py` 的規則
- `CLAUDE.md` 的工作流條文

### 不動

- `next-site/app/**`、`next-site/components/**`、`next-site/styles/**`
- 既有 5 個 submodule（kubernetes / cilium / kubevirt / ceph / multus-cni）的版本
- `Makefile`、`package.json` 依賴
- `LICENSE`

### molearn 的角色

`./molearn` 是**只讀參考**。從它的 MDX 寫法、metadata 結構、skills 文件、quiz 設計、圖表規範學東西。**不**複製它的程式碼進來，**不**改它。

## 5. 每輪 Loop 的執行方式

每輪用 **subagent 並行**避免主對話 context 爆炸：

```
loop N 開始
  ├── Agent A (Beginner Read):    讀完 6 個 project，產出 pain-points 清單（≤500 字）
  ├── Agent B (Molearn Compare):  對照 molearn 對等位置，產出 reference 清單（≤500 字）
  └── Agent C (Rubric Scorer):    用 §3 rubric 給 6 project × 8 項打分

→ 主對話整合三份 → 列出本輪要改的項目（分數 < 9）
→ Apply 階段：每個項目一個 subagent 改 + 跑 validate + commit
   commit message 開頭：[loop-N][項目]
→ Re-score：跑一次 Agent C，輸出 final-rubric
   全部 ≥9 → 停；否則 N+1
```

每輪在 `docs/superpowers/loop/{N}-summary.md` 寫 ≤200 字摘要。

## 6. 失敗 / 卡住處理

| 情況 | 處理 |
|---|---|
| 某項分數一直卡 < 9 | 寫進 `loop/blocker-{項目}.md` 標 `needs-user-decision`，暫停 loop 等使用者 |
| molearn 沒對應參考 | 標 `no-molearn-reference`，照一般 best practice 改，commit message 註明 |
| 改動破壞 `make validate` | 先 revert，找根因，不靠 `--no-verify` 強推 |
| commit / merge 衝突 | 自己嘗試 rebase / merge 解；解不了再 escalate |
| repo 出大事（誤刪、submodule 損壞） | 暫停 loop，escalate |

## 7. 產出物

```
docs/superpowers/specs/2026-05-08-sp8-molearn-loop-design.md   ← 本 spec
docs/superpowers/plans/2026-05-08-sp8-molearn-loop-plan.md     ← writing-plans 階段
docs/superpowers/loop/{N}-pain-points.md
docs/superpowers/loop/{N}-molearn-references.md
docs/superpowers/loop/{N}-rubric.md
docs/superpowers/loop/{N}-final-rubric.md
docs/superpowers/loop/{N}-summary.md
.gitmodules                                                     ← 多一條 molearn
molearn/                                                        ← submodule
```

## 8. 非目標（明確排除）

- 不重寫 next-site UI 元件
- 不把 molearn 的 CAPI / MAAS / Metal3 內容併進 learning-k8s
- 不送 PR 回 hwchiu/molearn
- 不為了 rubric 分數犧牲既有的台灣繁中 / 技術名詞保留英文規則
