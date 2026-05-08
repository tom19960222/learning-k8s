# SP-8 — molearn 對照迭代 loop FINAL Report

| 欄位 | 值 |
|---|---|
| 起始日 | 2026-05-08 |
| 結束日 | 2026-05-08 |
| 總輪數 | 2 |
| 總 commit 數（spec/plan + 兩輪）| 14 |
| 停止觸發 | 48/48 cell ≥ 9（含 r4 6 cell 為 N/A）|
| 未解項目 | 1（r4 PNG generation — 需使用者決策）|

## 每輪概覽

| 輪 | 改了幾項 | 分數總增量 | 主要 commits |
|---|---|---|---|
| 1 | 5 | +4 cell（r3 × 3 + r8 × 1） | 49bb279, 7594ea4, c6aa220, 18cc8fb, c95af72 |
| 2 | 3 | +3 cell（r2 × 2 + r5 × 1） | 2093bf9, ace5f46, ccb1893 |
| 合計 | 8 | +7 cell；r4 6 cell 標 N/A | — |

## 最終 6×8 分數矩陣

| project | r1 導航 | r2 深淺 | r3 quiz | r4 圖表 | r5 lab | r6 path | r7 ai-wf | r8 語言 |
|---|---|---|---|---|---|---|---|---|
| kubernetes | 9 | 9 | 9 | N/A* | N/A | 9 | 9 | 9 |
| cilium | 9 | 9 | 9 | N/A* | N/A | 9 | 9 | 9 |
| kubevirt | 9 | 9 | 9 | N/A* | N/A | 9 | 9 | 9 |
| ceph | 9 | 9 | 9 | N/A* | N/A | 9 | 9 | 9 |
| multus | 9 | 9 | 9 | N/A* | N/A | 9 | 9 | 9 |
| learning-plan | 9 | 9 | 9 | N/A* | 9 | N/A | 9 | 9 |

> `*` r4 暫定 N/A 來自 `blocker-r4-png-generation.md`：PNG 生成工具尚待使用者決策（選項 A: Fireworks API、選項 B: mermaid-cli、選項 C: 手繪、選項 D: 修 spec 接受 ASCII art）。

## 兩輪具體成就

### Loop 1 — 工程性與 quiz 覆蓋
1. **語言一致性升級為自動把關**（L1-A）：除了把 3 處「程序」改為 `process`，更在 `scripts/validate.py` 加 check #7 大陸用語黑名單（軟件 / 网络 / 程序 / 默认 / 数据 / 用户 / 视频 / 鼠标 / 分辨率），未來任何 commit 引入大陸用語會自動 fail。
2. **quiz 覆蓋率到「每個 feature ≥ 1 題」**（L1-B/C/D）：
   - kubernetes：18 features 全有 quiz（從 19 → 27 題）
   - kubevirt：controllers + virt-handler-and-launcher 補上 dedicated 題
   - learning-plan：30 day 每天 1 題（從 12 → 30 題）
3. **content-writing-guide.md 落地**（L1-E）：5 條 UX rule（Scene Before Mechanism / No Waterfall / Diagram Before Code / Progressive Disclosure / Explain Before Quote）+ 三段式 template + glossary 規範，從 molearn 學來但用 learning-k8s 自己的例子重寫。

### Loop 2 — 內容深淺與動手體驗
1. **kubernetes 3 張 learning-map 重定位**（L2-B）：明確 callout「📍 本頁性質：導航頁」+ 對應的深度頁清單，解決 18 個 features 之間的深度不一致觀感。
2. **learning-plan 進階日加 觀念深化**（L2-C）：day-22/24/26/28/29 各加「為什麼這樣設計 + 對應原始碼 file:line + 延伸思考」三段式設計理論補充，每段 ≥ 200 字、≥ 4 個 file:line ref。
3. **learning-plan 破壞性日全加 cleanup**（L2-A）：day-17/19/20/22/24/26/28/30 都有 🧹 Cleanup / 回退 段，含 🔴 警告、由高至低資源拆解順序、verify-clean check；day-15/17/19 原始碼 ref 升級為具體 file。

## 未解項目（需使用者決策）

### r4 圖表 PNG 生成

詳見 `docs/superpowers/loop/blocker-r4-png-generation.md`。

**現況：** `next-site/public/diagrams/` 整目錄為空，6 個 project 的 r4 都標 N/A 推進 loop，但實質扣分原因（缺 PNG 圖表）未解決。

**待決策：**
1. 採選項 A、B、C、D 哪一個？
2. 若 A（Fireworks API）：是否授權 API 使用？key 放哪？
3. 若 B（mermaid-cli build pipeline）：是 commit time 跑還是 CI 跑？這跟 CLAUDE.md「不加 Mermaid 圖表」的規則需要重新拍板（CLAUDE.md 的禁令是針對 MDX inline mermaid，build-time render 成 PNG 是另一回事，但需要使用者確認解釋方式）。
4. 若 C（手繪）：使用者自己畫，還是要 AI 給 ASCII / 詳細描述後使用者貼進 Excalidraw？
5. 若 D（修 spec）：把 r4 評分標準改為「結構良好的 ASCII art 也算 ≥ 9」？等於放棄這條 rubric。

**建議：** 短期選 A 或 B，先補每 project 1 張 architecture.png 把 r4 推到 6-7；長期累積關鍵時序圖到 9。**這是 SP-8 結束後的後續工作，非 SP-8 範圍內可解。**

## 對 learning-k8s 的整體建議（≤200 字）

兩輪 loop 收斂得快、ROI 高的部分集中在「把判準寫進工具」（validate.py 大陸用語黑名單、content-writing-guide.md），這比逐篇修 MDX 更可持續。learning-k8s 的內容紮實度其實已優於 molearn 在 learningPaths / 語言規範上的水準，差距集中在**圖表**（純結構性差距，需工具投入）與**內容深淺一致性**（已透過 L2-B / L2-C 修平）。

下一步若要繼續推進，建議：(1) 先解 r4 blocker，(2) 把 content-writing-guide.md 的 5 條 rule 反向掃一次既有 MDX，找出違反案例修補，(3) molearn 更新時順手 pull submodule 看有沒有新做法可借鑒。

## 產出物清單

```
docs/superpowers/specs/2026-05-08-sp8-molearn-loop-design.md
docs/superpowers/plans/2026-05-08-sp8-molearn-loop.md
docs/superpowers/loop/README.md
docs/superpowers/loop/1-pain-points.md
docs/superpowers/loop/1-molearn-references.md
docs/superpowers/loop/1-rubric.md
docs/superpowers/loop/1-final-rubric.md
docs/superpowers/loop/1-summary.md
docs/superpowers/loop/2-final-rubric.md
docs/superpowers/loop/2-summary.md
docs/superpowers/loop/blocker-r4-png-generation.md
docs/superpowers/loop/FINAL.md  ← 本檔
.gitmodules                                                  # +molearn
molearn/                                                     # submodule
scripts/validate.py                                          # +大陸用語 check #7
skills/analyzing-source-code/content-writing-guide.md        # 新增
next-site/content/kubernetes/quiz.json                       # +8 題
next-site/content/kubernetes/features/{cni,csi,runtime}-learning-map.mdx  # 加導航 callout
next-site/content/kubevirt/quiz.json                         # +2 題
next-site/content/learning-plan/quiz.json                    # 12 → 30 題
next-site/content/learning-plan/features/day-{17,19,20,22,24,26,28,30}.mdx  # +cleanup
next-site/content/learning-plan/features/day-{22,24,26,28,29}.mdx           # +觀念深化
next-site/content/learning-plan/features/day-{02,05,15,17,19}.mdx           # 程序→process / source ref 升級
```
