# Loop 1 — Initial Rubric

評分依據 spec §3 的 8 項 rubric，0–10 分（越高越好）。`N/A` 視為已達標。

證據引用優先以 file:line 標示；ASCII / structural 觀察以「sectional」描述。

## 分數矩陣

| project | r1 導航 | r2 深淺 | r3 quiz | r4 圖表 | r5 lab | r6 path | r7 ai-wf | r8 語言 |
|---|---|---|---|---|---|---|---|---|
| kubernetes | 9 | 8 | 7 | 3 | N/A | 9 | 9 | 9 |
| cilium | 9 | 9 | 9 | 3 | N/A | 9 | 9 | 9 |
| kubevirt | 9 | 9 | 8 | 3 | N/A | 9 | 9 | 9 |
| ceph | 9 | 9 | 9 | 3 | N/A | 9 | 9 | 9 |
| multus | 9 | 9 | 9 | 3 | N/A | 9 | 9 | 9 |
| learning-plan | 9 | 8 | 7 | 3 | 8 | N/A | 9 | 8 |

> r7（AI workflow）為 repo-level，6 個 project 共用同分（skills/ 是 cross-project shared）。
> r4（圖表）全部低分，因為 `next-site/public/diagrams/` 整個目錄是空的（見下方說明）。

## 扣分明細（< 9 的 cell）

### kubernetes

- **r2（深淺）— 8/10**
  - `next-site/content/kubernetes/features/runtime-learning-map.mdx:1-89` 與 `cni-learning-map.mdx:1-50` 性質是「外部文章對照表」，主要列 ithelp 連結與「放進本專案的分析角度」表格，沒有完整走「為什麼存在 → 怎麼用 → 原始碼怎麼實作」三段；對純初學者讀來像目錄而非教材。
  - `csi-learning-map.mdx` 同樣性質（103 行，導航為主）。三張地圖頁與其他深度頁面（如 `api-server.mdx` 163 行 / `kubelet.mdx` 202 行）落差大，整體深度不一致。

- **r3（quiz）— 7/10**
  - `next-site/content/kubernetes/quiz.json` 共 19 題對應 18 features。但 q1-q5 集中在 architecture / api-server / controllers / kubelet（重複 controller 概念兩次：q3 的 informer/work-queue 雖好但放單題即可）；`cni-learning-map`、`csi-learning-map`、`runtime-learning-map`、`kubelet-csi-mount-path`、`pod-to-pod-datapath`、`node-ipam-and-flannel`、`storage-api-and-binding`、`pod-network-lifecycle` 等 8 個 features 沒有專屬題目（它們的觀念被併進其他題的 explanation）。「同章節 MDX 一一對得上」這條沒達標。

- **r4（圖表）— 3/10**
  - `next-site/public/diagrams/` 目錄為空（`ls -la` 確認），全 18 個 MDX 都用 fenced ASCII box 表達架構（例 `architecture.mdx:15-37`、`api-server.mdx`、`controllers.mdx` 都有 ASCII art 但無 PNG 引用）。
  - spec §3 r4 要求「該有圖的地方有 PNG（非 1×1 placeholder）；圖檔位於 `public/diagrams/{project}/`」。kubernetes 高度需要圖示的主題：apiserver request flow、controller informer/work queue、CNI ADD 時序、CSI volume lifecycle、pod-to-pod datapath（VXLAN encap），完全沒有 PNG。給 3 分（ASCII art 仍提供結構視覺）。

### cilium

- **r4（圖表）— 3/10**
  - `next-site/public/diagrams/cilium/` 不存在（`/Users/ikaros/Documents/code/learning-k8s/next-site/public/diagrams/` 整個空）。
  - 4 個 features 全靠 ASCII：`architecture.mdx:14-37` process map、`agent-and-datapath.mdx:14-24` CNI ADD flow、`agent-and-datapath.mdx:151-181` endpoint regen 整段。eBPF datapath、PolicyMap per-endpoint、perf event ring 都是視覺敏感主題，沒有圖等於把責任丟給讀者腦補。

### kubevirt

- **r3（quiz）— 8/10**
  - `next-site/content/kubevirt/quiz.json` 共 7 題對應 6 features。controllers feature（`features/controllers.mdx`，190 行的 reconcile pipeline 拆解）沒有專屬題目（q2/q3 算 partial 涵蓋）；`virt-handler-and-launcher` 跟 `architecture` 共享 q1/q3 也偏混雜。distractor 品質好，扣分主要在「一一對得上」未完全達標。

- **r4（圖表）— 3/10**
  - `next-site/public/diagrams/kubevirt/` 不存在。`architecture.mdx:14-44` 的 5-process map、`live-migration.mdx:13-53` 整段 VMIM lifecycle、`topology-spread-constraints.mdx:48-75` 的「VM → VMI → Pod」資料流都是 ASCII。live migration cutover、precopy/postcopy 取捨需要時序圖才直觀。

### ceph

- **r4（圖表）— 3/10**
  - `next-site/public/diagrams/ceph/` 不存在。`architecture.mdx:14-34`（3 類 daemon）、`crush-and-placement.mdx:15-19`（PG → OSD 對應）、`crush-and-placement.mdx:93-117`（CRUSHMap 階層）、`osd-and-bluestore.mdx`（BlueStore 內部結構）全靠 ASCII。CRUSH 演算法的「stable property」與 straw2 是 ceph 最反直覺的部分，純文字寫了 165 行也很難取代一張圖。

### multus

- **r4（圖表）— 3/10**
  - `next-site/public/diagrams/multus/` 不存在。`architecture.mdx:13-22` CNI 1:1 限制、`architecture.mdx:28-49` meta-plugin fan-out、`thick-shim-and-daemon.mdx` 的 thin/thick 拓樸都是 ASCII。multus 的「把自己塞進唯一 CNI 位置再 fan-out」需要圖才一目瞭然。

### learning-plan

- **r2（深淺）— 8/10**
  - `next-site/content/learning-plan/features/day-01.mdx:7-13` 開頭目標清楚，但其「觀念深化」段（line 126-133）只有 2 段文字，三段論（為什麼 → 怎麼用 → 原始碼）只觸到前兩段。Day 1 是入門可接受，但同樣模式在 Day 22 等較進階日（`day-22.mdx` 的「觀念深化」段缺失，只有「動手做」+ 收穫檢查）也出現。
  - 30 天裡多日落在「裝 / 巡禮 / 查狀態」型，原始碼層次的拆解集中在 day-04（自寫 controller）、day-09（cilium eBPF）、day-14（multus 原始碼）、day-27（live migration）等少數幾天，其他日多為 hands-on commands。

- **r3（quiz）— 7/10**
  - `next-site/content/learning-plan/quiz.json` 共 12 題對應 30 天，每題明確標 `Day N`（q1=day-1, q2=day-3, ..., q12=day-30），但只覆蓋 1, 3, 4, 9, 10, 14, 16, 18, 21, 25, 27, 30 共 12 天，剩下 18 天沒有對應題目。「題目與同章節 MDX 一一對得上」對 30 天教材而言覆蓋率僅 40%。

- **r4（圖表）— 3/10**
  - `next-site/public/diagrams/learning-plan/` 不存在。30 天本來最適合用 PNG 標 milestone（Day 14 完成 multus、Day 18 ceph-csi RBD bind、Day 27 live migration cutover），但全部沒有。`day-30.mdx:18-39` 的「環境健檢」段落、`day-15.mdx` 的「Proxmox ceph 健檢」都是純文字，Day 30 的「整合 demo 拓樸」最該有架構圖。

- **r5（lab）— 8/10**
  - 30 個 day MDX 都有 🟢/🟡/🔴 三色驗證標記（grep 確認 day-01 到 day-30 都至少 6+ 個標記），規範與 CLAUDE.md 「Lab 指令的驗證等級」一致。
  - 扣分理由：(1) 破壞性操作的回退步驟不夠系統化。例：`day-22.mdx:46-60` 裝 KubeVirt 沒提 uninstall path；`day-30.mdx` 整合 demo 沒給 cleanup 指令。(2) 🔴「需在你環境跑後對照」標記的 output 範例多以省略號或假 IP 表示（如 `day-15.mdx:48`「id: xxxxxxxx-xxxx-…」），對初學者「對照」的可操作性偏弱。(3) 原始碼引用部分對得到行（day-14、day-18、day-27 都有），但部分 day 的「原始碼參考」是連結到目錄 (e.g. `day-15.mdx:194-196` 連到 `src/mon`、`src/osd` 整個資料夾），不是具體 file:line。

- **r8（語言）— 8/10**
  - 偵測到 3 處大陸用語「程序」當「process」用，違反 CLAUDE.md「程式（非程序）」規則：
    - `next-site/content/learning-plan/features/day-05.mdx:85`：「真正跑 nginx 程序的 container」
    - `next-site/content/learning-plan/features/day-02.mdx:148`：「API server 程序重啟後」
    - `next-site/content/learning-plan/features/day-02.mdx:162`：「kube-apiserver 程序 crash」
  - 應改成「process」（never-translate 包含 process 概念）或 「行程 / 程式」。其他面向（never-translate 詞如 controller / namespace / Pod 都保留英文、frontmatter 完整、繁中正字）都達標。

## 摘要

- **是否全部 ≥ 9**：否。
- **總共 < 9 的 cell**：13 個（r4 6 格 × 全 project + r3 3 格 + r2 2 格 + r5 1 格 + r8 1 格）。
  - r4 圖表 6 格 × 3 = 18 分缺口（最大缺口）
  - r3 quiz 連動 3 格（kubernetes / kubevirt / learning-plan）
  - r2 內容深淺 2 格（kubernetes / learning-plan）
  - r5 動手體驗 1 格（learning-plan）
  - r8 語言一致性 1 格（learning-plan）

- **最低分項目（cell-level）前 5 名**（同分依嚴重程度排序）：
  1. **kubernetes.r4 — 3/10**：18 個 MDX 全沒 PNG；apiserver / controller / CNI / CSI / pod-to-pod datapath 等高視覺需求主題只有 ASCII。
  2. **ceph.r4 — 3/10**：CRUSH stable property、PG → OSD mapping、BlueStore 結構這三個最反直覺的概念沒有圖示。
  3. **kubevirt.r4 — 3/10**：5-process 拓樸、live migration precopy/postcopy/cutover 時序、VM → VMI → Pod 資料流都是 ASCII。
  4. **learning-plan.r3 — 7/10**：30 天只 12 題（40% 覆蓋），其他 18 天沒測驗。
  5. **kubernetes.r3 — 7/10**：8 個 features（含 3 張 learning-map 與 4 個 lifecycle / datapath 細節頁）沒有專屬題目。

- **跨 project 共通低分維度**：
  - **r4（圖表）是 6 個 project 都低分的維度**（全部 3/10）。根因是 `next-site/public/diagrams/` 整個目錄是空的，從未產出 PNG。`skills/fireworks-tech-graph/` 的存在表示有產圖工具但未實際使用。下輪 loop 應大量補圖（每個 features/*.mdx 至少 1 張，30 天 lab 至少 4-5 張里程碑圖）。
  - **r3（quiz）在 kubernetes / kubevirt / learning-plan 三個 project 都未到 9**：`skills/quiz-generation/SKILL.md` 已存在但每個 feature 平均題數仍偏低。建議升級到「每個 feature 至少 1 題、key feature 2 題」基準。
  - **r2 / r5 / r8 屬個別 project 特定問題**，loop 補丁範圍可控。
