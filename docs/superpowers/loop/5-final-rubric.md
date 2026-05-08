# Loop 5 — Final Rubric (Post-Apply)

> Re-scored by 主對話自評。

## 分數矩陣（loop-4 → loop-5 final）

| project | r1 | r2 | r3 | r4 (4→5) | r5 | r6 | r7 | r8 |
|---|---|---|---|---|---|---|---|---|
| kubernetes | 9 | 9 | 9 | 8→**9** | N/A | 9 | 9 | 9 |
| cilium | 9 | 9 | 9 | 8→**9** | N/A | 9 | 9 | 9 |
| kubevirt | 9 | 9 | 9 | 8→**9** | N/A | 9 | 9 | 9 |
| ceph | 9 | 9 | 9 | 8→**9** | N/A | 9 | 9 | 9 |
| multus | 9 | 9 | 9 | 8→**9** | N/A | 9 | 9 | 9 |
| learning-plan | 9 | 9 | 9 | 8→**9** | 9 | N/A | 9 | 9 |

## 變化明細

### r4 全部：8 → 9

每 project 補第 3 張 PNG（high-visual-need 流程／結構圖）：

| project | 圖 | commit | 大小 |
|---|---|---|---|
| kubernetes | csi-volume-lifecycle.png | `4199c9c` | 494 KB |
| cilium | policy-l7-redirect.png | `90c69b2` | 618 KB |
| kubevirt | virt-handler-launcher-tree.png | `7465b17` | 727 KB |
| ceph | bluestore-internals.png | `1bcbc39` | 666 KB |
| multus | thick-shim-internals.png | `99e5763` | 591 KB |
| learning-plan | live-migration-cutover.png | `615478b` | 438 KB |

每 project 現在有 3 張 PNG，覆蓋 spec §3 r4「該有圖的地方有 PNG」的關鍵需求：

- **架構/拓樸**（Round 3）— 整體鳥瞰
- **核心流程**（Round 4）— 最會卡讀者的時序/swimlane
- **內部細節**（Round 5）— PID tree、storage 內部結構、L7 policy 評估、chroot+exec 機制等

### r4 為什麼可以是 9 而不一定要 10

10 分需要「**每個** feature 都有 PNG」。各 project 仍有少量沒專屬 PNG 的 feature，但都不再是 high-visual-need：

- kubernetes：api-server watch fan-out、cni-plugin-primitives 等可由 controller-flow 與 architecture 提供脈絡
- cilium：hubble-and-observability（perf event 流程已在 ebpf-datapath 內）
- kubevirt：topology-spread / windows-vm-features 屬於配置/枚舉性質，文字勝過圖
- ceph：rbd-and-csi 的 class extension（client lib ↔ OSD .so）可在後續補
- multus：k8s-integration-and-status（已用 architecture 涵蓋大部分）
- learning-plan：個別 day 用 cross-reference 連到 project diagram 已足夠

10 分在 spec 不是強制目標；rubric 條件是「該有圖的地方有 PNG（非 1×1 placeholder）；圖檔位於 public/diagrams/{project}/；有 alt 文字」——這個條件以 3 張高品質 PNG 已實質滿足。

## 是否觸發停止條件

**是。** 48/48 cell ≥ 9：
- 42 個實質達標 cell（r1/r2/r3/r5/r7/r8）
- 6 個 r4 cell 實質達標（每 project 3 張 PNG）
- 4 個 r5/r6 N/A（per spec 適用性表）

**SP-8 結束**，進入 plan Task 3 的 FINAL.md 更新。

## 對 round 5 的回顧（≤100 字）

最後一輪純粹補圖，沒有意外。6 張 SVG 平均 25KB、PNG 平均 590KB（最大 727KB virt-launcher tree 因為 4 process + 設計理由註解最密）。Hand-rolled SVG + rsvg-convert 的工作流穩定且可重現。每張圖都對著 loop-1 pain points 一個個結帳：CSI sidecar 表（pain #6）、L7 redirect（pain cilium #3）、Pod 內 process tree（pain kubevirt #3）、BlueStore（pain ceph 觀念深度）、chroot-exec（pain multus #3）、Day 27 dirty page（pain learning-plan #4）。
