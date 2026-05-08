# Loop 4 Summary

## 本輪改了什麼

每 project 補 1 張關鍵流程 PNG（hand-rolled Dark Terminal SVG → rsvg-convert -w 1920）：

| commit | project | 圖 | 大小 |
|---|---|---|---|
| `a382e7b` | kubernetes | controller-flow.png（informer/workqueue/reconcile loop）| 298 KB |
| `c7b95d3` | cilium | ebpf-datapath.png（bpf_*.c → kernel hook → packet path）| 509 KB |
| `567cbe8` | kubevirt | live-migration.png（5-lane swimlane + cutover band）| 405 KB |
| `468d0a6` | ceph | crush-placement.png（hash → PG → CRUSHMap → straw2 stable）| 388 KB |
| `b886dc2` | multus | delegate-flow.png（kubelet → shim → daemon → fan-out swimlane）| 434 KB |
| `14b2ce3` (+`b36e7bb`) | learning-plan | day-30-topology.png（3-node 整合 demo 拓樸）| 578 KB |

注：R4-Lp 在被 rate limit 切斷前已寫完 SVG（commit `b36e7bb` "Added by Claude Code"），主對話接手做 PNG export + MDX 引用 + commit `14b2ce3`。

## 分數變化

| cell | loop-3 final → loop-4 final |
|---|---|
| 全部 r4 | 7 → 8 |

未動：其他 42 cell 維持 ≥ 9。

## 停止判斷

**否，進 loop-5。** 6 個 r4 cell 仍 8/10。每 project 再補 1 張就能到 9。

## 下一輪打算動

每 project 第 3 張 PNG：
- kubernetes: csi-volume-lifecycle（5 sidecar 時序）
- cilium: policy-l7-redirect（PolicyMap + envoy）
- kubevirt: virt-handler-launcher-tree（Pod 內 PID 1 monitor + libvirtd + qemu）
- ceph: bluestore-internals（BlueStore + BlueFS + RocksDB + Allocator）
- multus: thick-shim-internals（chroot exec 機制）
- learning-plan: live-migration-cutover（Day 27 memory dirty page）
