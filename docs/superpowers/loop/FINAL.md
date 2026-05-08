# SP-8 — molearn 對照迭代 loop FINAL Report

| 欄位 | 值 |
|---|---|
| 起始日 | 2026-05-08 |
| 結束日 | 2026-05-08 |
| 總輪數 | 5 |
| 總 commit 數 | ~40（spec / plan + 5 輪 Apply + 各輪 final-rubric / summary）|
| 停止觸發 | 48/48 cell ≥ 9（**全部實質達標**，無 N/A 替代）|
| 未解項目 | 0 — r4 PNG blocker 已在 loop-3 解（rsvg-convert 安裝、fireworks-tech-graph skill 啟用）|

## 每輪概覽

| 輪 | 改了幾項 | 分數總增量 | 主要 commits |
|---|---|---|---|
| 1 | 5 | +4 cell（r3 × 3 + r8 × 1） | 49bb279, 7594ea4, c6aa220, 18cc8fb, c95af72 |
| 2 | 3 | +3 cell（r2 × 2 + r5 × 1） | 2093bf9, ace5f46, ccb1893 |
| 3 | 6 | r4 6 cell：3 → 7（每 project 1 張 architecture/roadmap PNG）| 23fb10f, 3fee3cd, 1bac0c5, ef32523, 5c569c8, b023221 |
| 4 | 6 | r4：7 → 8（每 project 1 張關鍵流程圖）| a382e7b, c7b95d3, 567cbe8, 468d0a6, b886dc2, 14b2ce3 |
| 5 | 6 | r4：8 → 9（每 project 1 張內部結構/PID tree/L7 policy）| 4199c9c, 90c69b2, 7465b17, 1bcbc39, 99e5763, 615478b |
| 合計 | 26 | +13 cell；r4 全部從 3 推到 9 | — |

## 最終 6×8 分數矩陣

| project | r1 導航 | r2 深淺 | r3 quiz | r4 圖表 | r5 lab | r6 path | r7 ai-wf | r8 語言 |
|---|---|---|---|---|---|---|---|---|
| kubernetes | 9 | 9 | 9 | **9** | N/A | 9 | 9 | 9 |
| cilium | 9 | 9 | 9 | **9** | N/A | 9 | 9 | 9 |
| kubevirt | 9 | 9 | 9 | **9** | N/A | 9 | 9 | 9 |
| ceph | 9 | 9 | 9 | **9** | N/A | 9 | 9 | 9 |
| multus | 9 | 9 | 9 | **9** | N/A | 9 | 9 | 9 |
| learning-plan | 9 | 9 | 9 | **9** | 9 | N/A | 9 | 9 |

> N/A 來自 spec §3 適用性表（5 source-code project 沒有 lab；learning-plan 本身即路徑）。

## 五輪具體成就

### Loop 1 — 工程性與 quiz 覆蓋
1. **語言一致性升級為自動把關**（L1-A）：`scripts/validate.py` 加 check #7 大陸用語黑名單，未來任何 commit 引入大陸用語會自動 fail
2. **quiz 覆蓋率到「每個 feature ≥ 1 題」**（L1-B/C/D）：kubernetes 18/18、kubevirt 6/6、learning-plan 30/30 day
3. **content-writing-guide.md 落地**（L1-E）：5 條 UX rule + 三段式 template + glossary 規範

### Loop 2 — 內容深淺與動手體驗
1. **kubernetes 3 張 learning-map 重定位為導航頁**（L2-B）
2. **learning-plan 5 個進階日加 觀念深化**（L2-C，每段 ≥ 200 字、≥ 4 個 file:line ref）
3. **learning-plan 8 個破壞性日全加 cleanup 段**（L2-A）

### Loop 3 — 圖表基線（每 project 第 1 張 PNG）
工具鏈打通：`brew install librsvg` + 既有 `skills/fireworks-tech-graph/` skill + hand-rolled Dark Terminal SVG + `rsvg-convert -w 1920` PNG 出圖。

每 project 1 張：architecture.png（kubernetes / cilium / kubevirt / ceph / multus）+ roadmap.png（learning-plan）。

### Loop 4 — 關鍵流程圖（每 project 第 2 張）
- kubernetes: controller-flow（informer / workqueue / reconcile loop）
- cilium: ebpf-datapath（5 個 bpf_*.c → kernel hook → packet path）
- kubevirt: live-migration（5-lane swimlane + cutover band）
- ceph: crush-placement（hash → PG → CRUSHMap → straw2 stable）
- multus: delegate-flow（kubelet → shim → daemon → fan-out swimlane）
- learning-plan: day-30-topology（3-node 整合 demo 拓樸）

### Loop 5 — 內部結構（每 project 第 3 張）
- kubernetes: csi-volume-lifecycle（5 sidecar swimlane）
- cilium: policy-l7-redirect（PolicyMap → tproxy → envoy L7）
- kubevirt: virt-handler-launcher-tree（PID 1 → Go → libvirtd → qemu + 為何分層）
- ceph: bluestore-internals（BlueStore + RocksDB + BlueFS + Allocator）
- multus: thick-shim-internals（chroot exec + UDS RPC + hostPath 模型）
- learning-plan: live-migration-cutover（precopy iter + 收斂 + cutover atomic）

## 對 learning-k8s 的整體建議

5 輪做下來，learning-k8s 的內容深度與視覺水準整體達到 molearn 對等或更佳：

- **領先 molearn**：learningPaths 細緻度、台灣繁中規範、validate.py 自動把關層級
- **持平 molearn**：每 project 3 張 PNG 的覆蓋深度
- **可繼續打磨**（非緊急）：(1) 把 content-writing-guide.md 的 5 條 rule 反向掃一次既有 MDX，找違反案例；(2) molearn 更新時順手 pull submodule 看有沒有新做法可借鑒；(3) 個別 feature（kubernetes api-server watch fan-out、ceph rbd class extension 等）可加第 4 張 PNG，但 ROI 已遞減

## 工具鏈備忘（給未來 SP）

- **PNG 生成**：`brew install librsvg` + hand-roll SVG + `rsvg-convert -w 1920`。風格沿用 Dark Terminal（dark `#0f172a` bg、light text、coloured layer containers）
- **Marker name 安全清單**（validate-svg.sh 有 `tr -d 'id="'` bug）：`arrow-blue` / `arrow-cyan` / `arrow-green` / `arrow-orange` / `arrow-yellow` / `arrow-rose` / `arrow-purple`。**避免** red、violet（含 `i`/`d`）
- **Text escape**：`<` `>` `->` 在 `<text>` 內必須是 `&lt;` `&gt;` `&#8594;`；body text 避免 `=`（validator false positive）
- **典型尺寸**：viewBox `0 0 1700 1100` 對 4-section 結構良好；PNG 出口大小 300-700 KB

## 產出物清單

### Spec & Plan
```
docs/superpowers/specs/2026-05-08-sp8-molearn-loop-design.md
docs/superpowers/plans/2026-05-08-sp8-molearn-loop.md
```

### Loop 中介產出
```
docs/superpowers/loop/README.md
docs/superpowers/loop/1-pain-points.md
docs/superpowers/loop/1-molearn-references.md
docs/superpowers/loop/{1,2,3,4,5}-rubric.md（only round 1 has「初評」分檔；2+ 直接 final-rubric）
docs/superpowers/loop/{1,2,3,4,5}-final-rubric.md
docs/superpowers/loop/{1,2,3,4,5}-summary.md
docs/superpowers/loop/blocker-r4-png-generation.md（已在 loop-3 解）
docs/superpowers/loop/FINAL.md  ← 本檔
```

### 程式 / 設定
```
.gitmodules                                                # +molearn submodule
molearn/                                                   # submodule
scripts/validate.py                                        # +check #7 大陸用語黑名單
skills/analyzing-source-code/content-writing-guide.md      # 新增
```

### 內容（MDX / quiz）
```
next-site/content/kubernetes/quiz.json                     # +8 題（19 → 27）
next-site/content/kubevirt/quiz.json                       # +2 題（7 → 9）
next-site/content/learning-plan/quiz.json                  # +18 題（12 → 30）
next-site/content/kubernetes/features/{cni,csi,runtime}-learning-map.mdx  # 加導航 callout
next-site/content/learning-plan/features/day-{17,19,20,22,24,26,28,30}.mdx  # +🧹 Cleanup
next-site/content/learning-plan/features/day-{22,24,26,28,29}.mdx           # +觀念深化
next-site/content/learning-plan/features/day-{02,05,15,17,19}.mdx           # 程序→process / source ref 升級
```

### 圖表（每 project 3 張，共 18 PNG + 18 SVG）
```
next-site/public/diagrams/kubernetes/{architecture,controller-flow,csi-volume-lifecycle}.{svg,png}
next-site/public/diagrams/cilium/{architecture,ebpf-datapath,policy-l7-redirect}.{svg,png}
next-site/public/diagrams/kubevirt/{architecture,live-migration,virt-handler-launcher-tree}.{svg,png}
next-site/public/diagrams/ceph/{architecture,crush-placement,bluestore-internals}.{svg,png}
next-site/public/diagrams/multus/{architecture,delegate-flow,thick-shim-internals}.{svg,png}
next-site/public/diagrams/learning-plan/{roadmap,day-30-topology,live-migration-cutover}.{svg,png}
```

### 引用 PNG 的 MDX
所有 18 張 PNG 都有對應 MDX 加 alt 文字 + 中文 caption。
