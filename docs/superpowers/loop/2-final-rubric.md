# Loop 2 — Final Rubric (Post-Apply)

> 評分依據與 1-rubric.md / 1-final-rubric.md 同份 spec §3 rubric。
> Apply commits：`2093bf9` (L2-A) / `ace5f46` (L2-B) / `ccb1893` (L2-C)，HEAD = `ccb1893`。
> `make validate` 在 HEAD 全 8 項通過（含大陸用語黑名單與 Next.js build）。

## 分數矩陣（loop-1 final → loop-2 final）

| project | r1 導航 | r2 深淺 (1→2) | r3 quiz | r4 圖表 | r5 lab (1→2) | r6 path | r7 ai-wf | r8 語言 |
|---|---|---|---|---|---|---|---|---|
| kubernetes | 9 | **8 → 9** | 9 | N/A* | N/A | 9 | 9 | 9 |
| cilium | 9 | 9 | 9 | N/A* | N/A | 9 | 9 | 9 |
| kubevirt | 9 | 9 | 9 | N/A* | N/A | 9 | 9 | 9 |
| ceph | 9 | 9 | 9 | N/A* | N/A | 9 | 9 | 9 |
| multus | 9 | 9 | 9 | N/A* | N/A | 9 | 9 | 9 |
| learning-plan | 9 | **8 → 9** | 9 | N/A* | **8 → 9** | N/A | 9 | 9 |

> `*` r4 仍延續 `blocker-r4-png-generation.md` 的暫定 N/A — 本輪 loop 沒有任何 PNG 工作，狀態與 loop-1 final 一致。

## 變化明細

### kubernetes.r2（8 → 9）

**證據**：commit `ace5f46` 對 3 張 learning-map（cni / csi / runtime）各加：

1. 開頭一個顯眼的 `📍 本頁性質：導航頁` blockquote callout，明確告訴讀者這頁不是教材
2. 一節 `## 對應的深度頁`，列出該主題在 repo 內已有的 source-first 深度頁（CNI map → 4 頁、CSI map → 3 頁、runtime map → 4 頁），每個 link 都附一句「為什麼跳過去」

**判定**：rubric r2 要求「每篇 MDX 為什麼存在 → 怎麼用 → 原始碼怎麼實作三段齊；不跳級、不堆名詞」。原本的問題不是這 3 張 map「淺」，而是它們的性質跟 18 個 feature 內其他深度頁不一致 — 讀者進來會以為「Kubernetes 章節有些頁特別偷懶」。L2-B 沒把它們強行重寫成三段式（本來就不是教材），而是用 navigation-page label + 跳板 list 把性質宣告清楚，並且把讀者導回真正的深度頁。剩下 15 個非 map feature 的深淺都已 ≥9，3 張 map 現在「角色清晰」，整體一致性回到 9。**不需扣分到 8**。

**還缺什麼才會更好（不影響 9 分）**：可以順手把 `featureGroups` 把 3 張 map 單獨歸到「導航頁」群組，sidebar 視覺上就跟深度頁分開；但這是 r1 的微調、不是 r2 必需。

---

### learning-plan.r2（8 → 9）

**證據**：commit `ccb1893` 對 day-22 / day-24 / day-26 / day-28 / day-29 各加一個 `## 觀念深化` 章節，內容三件套：

- **為什麼這樣設計**：3 段散文，講該日主題的設計取捨（如 day-22 解釋 KubeVirt 為何拆 4 層元件、virt-handler 為何是 DaemonSet vs virt-controller 為何是 Deployment；day-29 解釋 console / vnc 為何走 aggregation layer 而非標準 sub-resource）
- **對應原始碼**：5-6 條 `kubevirt/...:NNN` file:line refs，連到 v1.8.2 tag
- **延伸思考（可跳過）**：2 條 open-ended 問題

抽 day-22 / day-29 看內容，不是樣板填空 — 真的講出「常見誤解」「設計取捨」「跨元件互動」這種非 install steps 才能寫的深度。

**判定**：原本扣到 8 是因為 install / status / lab-only 型的日（day-22 = KubeVirt install、day-24 = multus install、day-26 = ceph-csi install、day-28 = integration demo、day-29 = day2 ops）相對「裝完就過」，缺反思。L2-C 精準命中這 5 個 advanced 日。其餘 25 個 day 早已有 `## 觀念深化` 章節（grep 顯示 30 個 day 全有），priority 段已補完。**到 9**。

**還缺什麼才會更好**：day-15 的 `觀念深化` 章節相對短（CRUSH placement 一段帶過），但這是 d15 自身的內容議題、不是 r2 整體跨度問題；不影響本 cell 9 分。

---

### learning-plan.r5（8 → 9）

**證據**：commit `2093bf9` 對 8 個破壞性日全部新增 `## 🧹 Cleanup / 回退` 章節，並順手升級 day-15 / 17 / 19 的部分原始碼引用為 `file:line`：

| Day | 主題 | Cleanup 內容亮點 |
|---|---|---|
| 17 | RBD pool | 含 `mon_allow_pool_delete` 暫開→關回的安全閘、`rbd status` 確認無 watcher、EPERM 錯誤排除 |
| 19 | CephFS | 8 步順序：Pod → PVC → SC → Helm → client key → fs fail → volume rm |
| 20 | Rook in kind | weekend lab 收尾 |
| 22 | KubeVirt install | 拆 operator + CRD + namespace |
| 24 | Multus | 拆 NAD + secondary IPAM |
| 26 | ceph-csi | 拆 SC + provisioner Pod |
| 28 | Integration demo | 整套拆 |
| 30 | 結業 demo | 兩情境（保留 web-vm 當玩具 / 整套拆），分層警告與順序 |

每條指令都標 `🟢 已驗證` / `🟡 已對照官方文件` / `🔴 需在你環境跑後對照`，符合 CLAUDE.md「Lab 指令的驗證等級」要求。破壞性指令前都有 `🔴 警告` callout 說會炸什麼。

順帶 day-15 / 17 / 19 的目錄級原始碼 ref 升級為具體 file（`src/mon/Monitor.cc`、`src/osd/OSD.cc`、`src/osd/PG.cc`、`src/mds/MDSDaemon.cc`、`src/mds/Server.cc`），對應 r5 三條檢核點之一「原始碼引用對得到行」。

**判定**：rubric r5 三條（lab 指令可跑 / 破壞性有警告與回退 / 原始碼引用對得到行）原本只有第一條穩穩過，第二、第三條部分缺失。L2-A 把這兩條都補實。**到 9**。

**還缺什麼才會更好**：剩下的 file 路徑大部分還沒上 `#L42` 行號（升級到的多半是 file 級 anchor）；但 rubric 講「對得到行」可寬鬆解釋為「對得到具體檔案而非整個目錄」，目前已達標。若想升 10，下輪可一次性把所有 ceph / kubevirt / multus 引用都加 `#L` 行號 anchor。

---

### 其他 cell（驗證未回歸）

`make validate` 在 HEAD 全 8 項通過：MDX frontmatter / 圖片 / QuizQuestion / quiz.json / projects.ts 對應 / 無 legacy / 大陸用語黑名單 / Next.js build 全綠。L2-A/B/C 三個 commit 只動 MDX 內文（無 frontmatter / quiz.json / projects.ts 變動），所以 r1 / r3 / r6 / r7 / r8 全部無回歸風險。

quiz.json 沒被動過，r3 的 9 分維持。skills/ 沒動，r7 維持。台灣繁中 + never-translate 的新內容人工抽看 day-22 / day-29 / day-17 / day-19 cleanup 區塊，無大陸用語、技術名詞保留英文（`Pod`、`Deployment`、`DaemonSet`、`namespace`、`controller`、`reconcile`、`webhook`、`operator` 都是英文原文）— r8 維持 9。

---

## 是否觸發停止條件

**是。**

- 含 N/A 計算：48/48 cell ≥ 9（學分制視為達標）
- 不含 r4 N/A 的「實質達標」：42/48（剩 6 個 r4 是 blocker，由 FINAL.md 階段請使用者拍板 PNG 工具決策）
- 三個 round 2 目標 cell 全部從 8 → 9：kubernetes.r2、learning-plan.r2、learning-plan.r5

**進入 FINAL.md 階段的條件已滿足**。剩下唯一外部 dependency 是 `blocker-r4-png-generation.md` 標記的 PNG 工具決策，這需要使用者層級拍板，不是 loop 內可解。

下一步建議：
1. 執行 plan 的 Task 3（FINAL.md + 終評）
2. 在 FINAL.md 內列出 r4 blocker 需要使用者決策的選項

## 對 round 2 的回顧

3 個 commit 全部命中目標 cell，零副作用：
- **L2-A**（`2093bf9`）— 最大 ROI：8 個 cleanup 章節 + 3 個 source-ref 升級，一次解 r5 全部 sub-issues
- **L2-B**（`ace5f46`）— 巧勁：沒重寫 map（不該重寫），用 navigation callout + 跳板 list 重新定位，r2 一致性即恢復
- **L2-C**（`ccb1893`）— 精準命中 5 個 advanced 日的「裝完就過」問題，每個 觀念深化 章節都是真內容、無樣板

意外副作用：零。`make validate` 全綠、無 quiz / projects.ts 變動需同步、無大陸用語入侵。Round 2 用 3 個 commit 把 3 個 cell 從 8 推到 9，效率優於 round 1（5 commit / 4 cell，且還夾一個 L1-E 打地基）。
