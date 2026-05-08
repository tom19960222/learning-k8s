# Loop 3 — Final Rubric (Post-Apply)

> Re-scored by 主對話自評。
> 評分依據與 1-rubric.md / 2-final-rubric.md 同份 spec §3 rubric。

## 分數矩陣（loop-2 → loop-3 final）

| project | r1 | r2 | r3 | r4 (2→3) | r5 | r6 | r7 | r8 |
|---|---|---|---|---|---|---|---|---|
| kubernetes | 9 | 9 | 9 | N/A→**7** | N/A | 9 | 9 | 9 |
| cilium | 9 | 9 | 9 | N/A→**7** | N/A | 9 | 9 | 9 |
| kubevirt | 9 | 9 | 9 | N/A→**7** | N/A | 9 | 9 | 9 |
| ceph | 9 | 9 | 9 | N/A→**7** | N/A | 9 | 9 | 9 |
| multus | 9 | 9 | 9 | N/A→**7** | N/A | 9 | 9 | 9 |
| learning-plan | 9 | 9 | 9 | N/A→**7** | 9 | N/A | 9 | 9 |

> r4 從 N/A 改回實質評分。loop-3 為每 project 補 1 張 architecture/roadmap PNG，把分數從 3 推到 7。**仍未 ≥ 9**：每 project 還需 2-3 張關鍵流程圖（live-migration / CRUSH placement / eBPF datapath / watch fan-out 等），才能達到 spec §3 r4「該有圖的地方有 PNG」的條件。

## 變化明細

### r4 全部：N/A → 7

每 project 補 1 張高品質 PNG（commit hash 對應）：

| project | PNG | commit | 大小 |
|---|---|---|---|
| kubernetes | `public/diagrams/kubernetes/architecture.png` | `23fb10f` | 378 KB |
| cilium | `public/diagrams/cilium/architecture.png` | `3fee3cd` | 511 KB |
| kubevirt | `public/diagrams/kubevirt/architecture.png` | `1bac0c5` | 519 KB |
| ceph | `public/diagrams/ceph/architecture.png` | `ef32523` | 534 KB |
| multus | `public/diagrams/multus/architecture.png` | `5c569c8` | 624 KB |
| learning-plan | `public/diagrams/learning-plan/roadmap.png` | `b023221` | 268 KB |

風格：全部 Style 2 (Dark Terminal)，hand-rolled SVG + rsvg-convert -w 1920 PNG，跟 molearn 既有 PNG 風格對齊。每張 PNG 在對應 MDX 都有具體 alt 文字 + caption。

### 為什麼 r4 是 7 不是 9

每 project 仍有多個高視覺需求的 features 沒有 PNG：

- **kubernetes**：18 features 中 1 個有 PNG。仍缺：watch fan-out（api-server）、controller informer/work queue、CNI ADD 時序、CSI volume lifecycle、pod-to-pod datapath（VXLAN）
- **cilium**：4 features 中 1 個有 PNG。仍缺：eBPF datapath（bpf_lxc/bpf_host hook）、L7 proxy redirect、KPR 取代 kube-proxy
- **kubevirt**：6 features 中 1 個有 PNG。仍缺：live-migration cutover 時序、virt-handler/launcher 內部 PID tree、VM → VMI → Pod 資料流
- **ceph**：5 features 中 1 個有 PNG。仍缺：CRUSH placement（PG → OSD）、BlueStore 內部結構、straw2 演算法視覺
- **multus**：4 features 中 1 個有 PNG。仍缺：thick mode chroot-exec 流程、delegate plugin fan-out 時序
- **learning-plan**：roadmap 覆蓋整體；仍缺：Day 30 整合 demo 拓樸圖、Day 27 live-migration memory dirty page 時序

## 是否觸發停止條件

**否。** 6 個 r4 cell 仍在 7/10，尚未達 9。其他 42 cell 維持 ≥ 9。

## 下一輪計畫（loop-4）

每 project 補 1 張「**最關鍵的第二張圖**」，目標把 r4 推到 8/10：

| project | 第二張圖 | 對應 MDX |
|---|---|---|
| kubernetes | `controller-flow.png` (informer → workqueue → reconcile loop) | `controllers.mdx` |
| cilium | `ebpf-datapath.png` (tc clsact / XDP / cgroup hook 對應 bpf_*.c) | `agent-and-datapath.mdx` |
| kubevirt | `live-migration.png` (precopy / postcopy / cutover 時序) | `live-migration.mdx` |
| ceph | `crush-placement.png` (object → PG → OSD 對應 + CRUSHMap 階層) | `crush-and-placement.mdx` |
| multus | `delegate-flow.png` (CNI ADD 從 shim → daemon → delegate fan-out 時序) | `delegate-and-cmdadd.mdx` |
| learning-plan | `day-30-topology.png` (整合 demo VM + Service + ceph PV + multus secondary NIC) | `day-30.mdx` |

預估 r4 達 8。要 9 還需要 loop-5（再 1-2 張 / 高需求 project）。

## 對 round 3 的回顧（≤100 字）

最大價值是「打通工具鏈」：rsvg-convert 安裝 + fireworks-tech-graph skill 用法 + 6 張 hand-rolled SVG 的風格基線，後續每加一張圖成本 = 設計時間 ≈ 一個 agent。每張 PNG ~300-600KB、Dark Terminal 風格與 molearn 一致。下一輪以「關鍵流程圖」為主軸，補完 high-visual-need 的 features。
