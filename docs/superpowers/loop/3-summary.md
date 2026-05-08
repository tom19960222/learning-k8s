# Loop 3 Summary

## 本輪改了什麼

每 project 補 1 張 architecture/roadmap PNG（hand-rolled Dark Terminal SVG → rsvg-convert -w 1920 PNG）：

| commit | project | 圖 | 大小 |
|---|---|---|---|
| `23fb10f` | kubernetes | architecture.png | 378 KB |
| `3fee3cd` | cilium | architecture.png | 511 KB |
| `1bac0c5` | kubevirt | architecture.png | 519 KB |
| `ef32523` | ceph | architecture.png | 534 KB |
| `5c569c8` | multus | architecture.png | 624 KB |
| `b023221` | learning-plan | roadmap.png | 268 KB |

工具鏈確認：`brew install librsvg` → 用 fireworks-tech-graph skill 風格 hand-roll SVG → rsvg-convert -w 1920 → 自動加進 MDX `![alt](/diagrams/{project}/...)` + 中文 caption。

## 分數變化

| cell | loop-2 final → loop-3 final |
|---|---|
| 全部 r4 | N/A → 7 |

未動：其他 42 cell 維持 ≥ 9。

## 停止判斷

**否，進 loop-4。** 6 個 r4 cell 仍 7/10。需每 project 補 1 張關鍵流程圖才能推到 8。

## 下一輪打算動

每 project 1 張「最關鍵的第二張圖」：
- kubernetes: controller-flow（informer → workqueue → reconcile）
- cilium: ebpf-datapath（tc/XDP/cgroup hook）
- kubevirt: live-migration（precopy/postcopy/cutover 時序）
- ceph: crush-placement（object → PG → OSD 對應）
- multus: delegate-flow（shim → daemon → delegate fan-out 時序）
- learning-plan: day-30-topology（整合 demo 全 stack）
