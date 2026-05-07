# Loop 1 — Molearn References

## Rubric #1 — 導航 / 結構
- **molearn 做法**：`molearn/next-site/lib/projects.ts` 的 `featureGroups` 第一群普遍叫「從這裡開始」，並讓 `architecture` 之外多放一個 `feature-map`（如 `molearn/next-site/content/rook/features/feature-map.mdx`、`kubevirt/features/feature-map.mdx`）作為視覺鳥瞰入口；同時 `feature-map.json` 提供節點 + 邊的 schema 給互動圖。
- **learning-k8s 現狀**：`next-site/lib/projects.ts` featureGroups 結構齊全（kubernetes 已有 `cni-learning-map` / `csi-learning-map` / `runtime-learning-map`），但 `kubevirt` / `cilium` / `ceph` / `multus` 缺鳥瞰 map MDX，sidebar 第一個落地頁就是 `architecture`。
- **可借鑒**：對 6+ 頁的 project（kubevirt、ceph、kubernetes）補一張 `feature-map.mdx`（含一張 PNG + 學習路徑表），放進 featureGroups 第一群的第一條 slug。

## Rubric #2 — 內容深淺
- **molearn 做法**：`molearn/skills/analyzing-source-code/content-writing-guide.md` 明文定 5 條 UX rule（Scene Before Mechanism / No Waterfall Listing / Diagram Before Code / Progressive Disclosure / Explain Before Quote），並給「概述 → 為什麼需要它 → 工作原理 → 實作細節 → 注意事項與邊界情況」模板。`molearn/next-site/content/kubevirt/features/architecture.mdx:9` 的開場就是工程師問題情境。
- **learning-k8s 現狀**：`skills/analyzing-source-code/SKILL.md` 與 molearn 同一份 770 行 SKILL.md，但**沒有 content-writing-guide.md**。MDX 開頭多以「場景」起手（`next-site/content/kubevirt/features/architecture.mdx:7`），但缺三段式（為什麼／怎麼用／原始碼）的明確規範。
- **可借鑒**：把 molearn 的 `content-writing-guide.md` 5 rule 與三段式 template 移植到 learning-k8s 的 `skills/analyzing-source-code/`（不抄文字、自己重寫成繁中規範）。

## Rubric #3 — Quiz 連動
- **molearn 做法**：`molearn/next-site/content/kubevirt/quiz.json` 用 3-digit ID（301、302…）對應 `kubevirt` 命名空間，每題 explanation 直接點到 MDX 章節名，且依章節順序排列。
- **learning-k8s 現狀**：`next-site/content/kubevirt/quiz.json` 用 1、2、3…的 simple ID，題目 explanation 紮實但**沒有跟 MDX 章節順序對齊**；多 project 共用 1 起跳的 ID 會在 cross-project 顯示 list 時撞號。
- **可借鑒**：採 molearn 的 namespace ID（kubevirt 300+、ceph 600+ 等），quiz.json 內題目順序按 sidebar features 順序排，explanation 加「見 /xxx/features/yyy」反向連結。

## Rubric #4 — 圖表
- **molearn 做法**：`molearn/next-site/public/diagrams/{kubevirt,rook}/` 每 project 都有 `architecture.png` + `feature-map.png` + 流程圖（如 `storage-request-flow.png`），MDX 引用前一律有一行解說（content-writing-guide rule 5）。
- **learning-k8s 現狀**：`next-site/public/diagrams/` 為空目錄，6 個 project 完全沒 PNG，全靠 MDX 內 ASCII art（如 `kubevirt/features/architecture.mdx:13` 的 box drawing）。
- **可借鑒**：以 molearn 的「每 project 至少 architecture.png + feature-map.png」當基線，用 `skills/fireworks-tech-graph/`（兩邊都有）批次生 PNG；MDX 引用前一定先有句解說。

## Rubric #5 — 動手體驗
- **molearn 做法**：`molearn/next-site/content/{project}/usecases/*.mdx`（如 `kubevirt/usecases/live-migration-maintenance.mdx`）以場景化 usecase 串知識，但**不是 lab 指令**。
- **learning-k8s 現狀**：`next-site/content/learning-plan/features/day-01.mdx` 已有「🟢 已驗證 / 🟡 待驗證 / 🔴 破壞性」三色標記，是更完整的 hands-on 體驗。其他 project 的 features MDX 不含可跑指令。
- **可借鑒**：molearn 的 usecases 章節（每 project 2-4 篇情境式短文）可移植到非 learning-plan 的 project，補足「為什麼要學」的 motivation；不取代 lab。

## Rubric #6 — learningPaths
- **molearn 做法**：`molearn/next-site/lib/projects.ts:97-112` 三層 path（beginner/intermediate/advanced），每 step 含 `slug` + `note`，note 都是「為什麼這時候看」一句話。CAPI 的 beginner→advanced 重複出現 `architecture` 但 note 切角度。
- **learning-k8s 現狀**：`next-site/lib/projects.ts:166-194` 結構完全一致，note 品質實際上比 molearn 更精煉。
- **可借鑒**：實際上 learning-k8s 已經做得更好；可逆向把 learning-k8s 的寫法 backport 給未來新 project。

## Rubric #7 — AI workflow（skills/）
- **molearn 做法**：`molearn/AGENT.md` 寫明「AI 只動 3 個地方」邊界 + 禁止路徑表 + skill 觸發時機表。`molearn/skills/analyzing-source-code/{SKILL.md,content-writing-guide.md,exploration-prompts.md}` 三件套；`molearn/scripts/validate.py` 473 行包含「框架邊界檢查 CHECK 8」。
- **learning-k8s 現狀**：`CLAUDE.md` 寫了 never-translate 清單與 5 步驟新增 project，但沒有 AGENT.md 等級的「禁止路徑表」；`skills/analyzing-source-code/` 只有 SKILL.md，缺 content-writing-guide 與 exploration-prompts。`scripts/validate.py` 349 行，沒有框架邊界檢查。
- **可借鑒**：(1) 加 content-writing-guide.md + exploration-prompts.md；(2) 在 validate.py 加「禁改 next-site/app, components, styles」的邊界檢查。

## Rubric #8 — 語言一致性
- **molearn 做法**：`molearn/next-site/content/kubevirt/features/architecture.mdx` 等 MDX 全繁中、技術名詞保留英文（virt-api、Pod、CRD…）；偶見大陸式詞如「進程」、「網路」混用情形不嚴重。
- **learning-k8s 現狀**：CLAUDE.md 有完整 never-translate 清單與大陸用語禁用表，比 molearn 嚴格；day-01.mdx 等檔案符合規範。
- **可借鑒**：learning-k8s 已比 molearn 嚴。可把這份規範 codify 進 validate.py（grep 黑名單詞 → fail），讓未來新 MDX 自動把關。

## 最值得借鑒前 3 名
1. **`content-writing-guide.md` + 三段式 template**：把寫作品質從「資訊正確」提升到「讀得進去」。
2. **每 project 的 `feature-map.mdx` + PNG 鳥瞰**：解決多頁 project（kubevirt 6 頁、kubernetes 18 頁）找不到入口的問題。
3. **validate.py 框架邊界檢查 + namespace 化 quiz ID**：兩個都是低成本、立刻防回歸的工程性改善。

## molearn 沒有對照 / 不適用的維度
- **Rubric #5 動手體驗**：molearn 沒有 30 天 lab 等級的 hands-on，無對照可借鑒；learning-plan 自走己路即可。
- **Rubric #6 learningPaths**：learning-k8s 已優於 molearn，反向參考即可。
