# Loop 4 — Final Rubric (Post-Apply)

> Re-scored by 主對話自評。

## 分數矩陣（loop-3 → loop-4 final）

| project | r1 | r2 | r3 | r4 (3→4) | r5 | r6 | r7 | r8 |
|---|---|---|---|---|---|---|---|---|
| kubernetes | 9 | 9 | 9 | 7→**8** | N/A | 9 | 9 | 9 |
| cilium | 9 | 9 | 9 | 7→**8** | N/A | 9 | 9 | 9 |
| kubevirt | 9 | 9 | 9 | 7→**8** | N/A | 9 | 9 | 9 |
| ceph | 9 | 9 | 9 | 7→**8** | N/A | 9 | 9 | 9 |
| multus | 9 | 9 | 9 | 7→**8** | N/A | 9 | 9 | 9 |
| learning-plan | 9 | 9 | 9 | 7→**8** | 9 | N/A | 9 | 9 |

## 變化明細

### r4 全部：7 → 8

每 project 補第 2 張 PNG（關鍵流程圖）：

| project | 圖 | commit | 大小 |
|---|---|---|---|
| kubernetes | controller-flow.png | `a382e7b` | 298 KB |
| cilium | ebpf-datapath.png | `c7b95d3` | 509 KB |
| kubevirt | live-migration.png | `567cbe8` | 405 KB |
| ceph | crush-placement.png | `468d0a6` | 388 KB |
| multus | delegate-flow.png | `b886dc2` | 434 KB |
| learning-plan | day-30-topology.png | `14b2ce3` (+ SVG/PNG `b36e7bb`) | 578 KB |

每 project 現在有 2 張 PNG（architecture/roadmap + 關鍵流程），覆蓋「最會卡讀者」的兩個面向。

### 為什麼 r4 是 8 不是 9

每 project 仍有 ~1-2 個 high-visual-need feature 沒有 dedicated PNG：

- **kubernetes**：仍缺 CSI volume lifecycle + CNI ADD 時序
- **cilium**：仍缺 identity-and-policy 的 PolicyMap + L7 redirect
- **kubevirt**：仍缺 virt-handler/launcher Pod 內 process tree
- **ceph**：仍缺 BlueStore 內部結構（BlueFS + RocksDB + Allocator）
- **multus**：仍缺 thick-shim/daemon chroot-exec 內部 process
- **learning-plan**：仍缺 Day 27 live-migration memory dirty page tracking

要推到 9 需要每 project 再補 1 張，總共 6 張。

## 是否觸發停止條件

**否。** 6 個 r4 cell 仍 8/10。其他 42 cell 維持 ≥ 9。

## 下一輪計畫（loop-5）

每 project 補第 3 張 PNG，目標 r4 = 9：

| project | 第 3 張圖 | 對應 MDX |
|---|---|---|
| kubernetes | `csi-volume-lifecycle.png` (provisioner / attacher / node-driver-registrar 五個 sidecar 的時序) | `csi-rpc-and-sidecars.mdx` |
| cilium | `policy-l7-redirect.png` (per-endpoint PolicyMap → 拒/放/redirect 到 envoy) | `identity-and-policy.mdx` |
| kubevirt | `virt-handler-launcher-tree.png` (Pod 內 PID 1 monitor → virt-launcher → libvirtd → qemu) | `virt-handler-and-launcher.mdx` |
| ceph | `bluestore-internals.png` (BlueStore object 寫入 → BlueFS → RocksDB → Allocator) | `osd-and-bluestore.mdx` |
| multus | `thick-shim-internals.png` (chroot exec 機制 + SysProcAttr + multus.sock UDS RPC 內部) | `thick-shim-and-daemon.mdx` |
| learning-plan | `live-migration-cutover.png` (Day 27 memory dirty page iter 1..N → cutover atomic) | `day-27.mdx` |

預估 r4 達 9。loop-5 後即可停。

## 對 round 4 的回顧（≤100 字）

工具鏈穩定後產能很高：6 個 agent 平均 5 分鐘出一張 ~400KB Dark Terminal SVG/PNG，validate 全綠。第 2 張 PNG 攻擊每 project 最痛的「需要時序/swimlane」題目（informer、eBPF datapath、live migration、CRUSH、delegate fan-out、Day 30 topology），分數從 7 推到 8 是預期內。要 9 需要再補一張覆蓋 process tree / 內部結構級別的細節（loop-5 計畫）。
