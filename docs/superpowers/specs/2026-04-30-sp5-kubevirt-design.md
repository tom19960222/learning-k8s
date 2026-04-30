---
date: 2026-04-30
project: kubevirt
version: v1.8.2
status: approved
---

# SP-5: kubevirt v1.8.2 first-wave MVP — design

## 目的

把 kubevirt v1.8.2 的內部運作壓成 4 個可讀的分析頁，足夠讓 SP-2 30 天 lab 第四週 (Day 22-30: kubevirt + 整合) 有原始碼可對照。沿用 SP-3 / SP-4 形狀：4 頁 MDX + 5 題 quiz，每頁的 file path / function / line number 都用 grep 在 v1.8.2 tag 上驗證過。

## 範圍（YAGNI）

只做 first-wave MVP。不包含：

- **device plugin** 細節 (KVM device、tun/tap、SR-IOV、GPU passthrough)
- **CDI** (Containerized Data Importer) 內部 — 只在 VMI controller 提到 DataVolume integration，CDI 本體留給未來 SP
- **virt-exportserver / virt-exportproxy** (VM disk export)
- **virtctl client tool**
- **virt-chroot** filesystem isolation 細節
- **TPM、SEV launch security、access credentials、guest-agent commands** 等進階 feature
- **decentralized live migration** (cross-cluster) — 只談 in-cluster live migration

第二波要不要做 device plugin / CDI 之後再決定 (可能 SP-5b / SP-6b 跟 ceph 一起)。

## 4 頁切法

選擇 **component / lifecycle 混合**：先是架構地圖 (誰是誰)，然後三條最重要的縱向 pipeline——VM lifecycle (control plane)、Pod-internal (data plane)、live migration (跨 node 協調)。理由：kubevirt 5 個 process 的職責邊界很硬，但讀者真正想懂的是「我 apply 一個 VM yaml 之後到底發生什麼」與「live migration 是真的在搬什麼」。按 lifecycle 切比按 component 切更直觀。

### 頁 1：`architecture.mdx`（5 個 process + 3 個 CRD）

**核心問題**：`kubectl get pods -n kubevirt` 看到 virt-operator / virt-api / virt-controller / virt-handler / virt-launcher 五種 Pod。它們各自做什麼？VM、VMI、VMIM 三個 CRD 的關係？

**內容大綱**：

- 整體 process map：virt-operator (Deployment, installer/CRD lifecycle) / virt-api (Deployment, admission webhook + subresource API) / virt-controller (Deployment, cluster-wide controllers) / virt-handler (DaemonSet, per-node) / virt-launcher (per-VMI Pod, 不是 fixed Deployment)
- 三個核心 CRD：
  - `VirtualMachine` (VM) — desired state，可以 stop/start
  - `VirtualMachineInstance` (VMI) — 一次運行 (像 Pod；VM 控制 VMI 的 ownerReference)
  - `VirtualMachineInstanceMigration` (VMIM) — 一次 migration job
- `kubectl apply VM.yaml` 的端到端：apiserver → virt-api admission → virt-controller VM controller 建 VMI → VMI controller 建 virt-launcher Pod → scheduler 排到 node → 該 node 的 virt-handler watch 到 → 透過 gRPC 跟 virt-launcher 對話 → libvirt → QEMU
- `kubectl virt vnc <vm>` 怎麼通 — virt-api 提供 subresource API (websocket proxy) 連到 virt-handler 連到 virt-launcher
- 為什麼 virt-launcher 不是 DaemonSet — 1 VMI 1 Pod 的 isolation，因為要把 QEMU 進去 cgroup/namespace 圍起來

**關鍵 file/symbol**：

- `cmd/virt-operator/virt-operator.go` — operator main
- `cmd/virt-api/virt-api.go` + `pkg/virt-api/api.go` — API server
- `cmd/virt-controller/virt-controller.go` + `pkg/virt-controller/watch/application.go` — controllers
- `cmd/virt-handler/virt-handler.go` — handler main
- `cmd/virt-launcher/virt-launcher.go` — launcher main

### 頁 2：`controllers.mdx`（virt-controller 的三條 pipeline）

**核心問題**：你 apply 一個 VM，virt-controller 怎麼把它變成跑著的 VMI？背後幾條 controller 的 reconcile loop 怎麼接力？

**內容大綱**：

- virt-controller 的 supervisor 模式：跟 kube-controller-manager 一樣，是 1 process 跑多 controller
- **VM controller** (`pkg/virt-controller/watch/vm/vm.go`) — 把 VM 翻譯成 VMI；處理 spec 變更、`spec.runStrategy` (Always/Manual/Halted/RerunOnFailure)、status 維護
- **VMI controller** (`pkg/virt-controller/watch/vmi/vmi.go`) — 把 VMI 翻譯成 virt-launcher Pod；建立 templateService.RenderLaunchManifest 出來的 Pod spec；維護 VMI phase (Pending → Scheduling → Scheduled → Running)
- **Migration controller** (`pkg/virt-controller/watch/migration/migration.go`) — 把 VMIM 翻譯成「另起一個 target virt-launcher Pod」；協調 source / target 之間的狀態切換
- 三條 controller 都用 client-go informer + work queue + Execute()/sync() 模式 (跟 [k8s controller](/kubernetes/features/controllers) 同一套骨架)
- ownerReferences chain：VM → VMI → virt-launcher Pod

**關鍵 file/symbol**：

- `pkg/virt-controller/watch/application.go` — controller manager 主框架
- `pkg/virt-controller/watch/vm/vm.go:282` — `Controller` (VM); `:335` `Execute`; `:3173` `sync`
- `pkg/virt-controller/watch/vmi/vmi.go:221` — `Controller` (VMI); `:283` `Execute`
- `pkg/virt-controller/watch/migration/migration.go:120` — `Controller`; `:304` `Execute`; `:1769` `sync`

### 頁 3：`virt-handler-and-launcher.mdx`（per-node + per-VMI Pod）

**核心問題**：scheduler 把 virt-launcher Pod 放到 node B。從這時起到 QEMU 真的跑起來、guest OS boot 起來，發生了什麼？

**內容大綱**：

- virt-handler 是 DaemonSet：每 node 一個，watch 自己 node 上 VMI，跟自己 node 上各個 virt-launcher Pod 對話
- virt-handler 的主迴圈在 `pkg/virt-handler/vm.go` `VirtualMachineController.Execute` (line 290) → `execute(key)` (line 306) → `sync()` (line 1354) / `processVmUpdate()` (line 2130)
- virt-launcher Pod 內 process tree：
  - virt-launcher-monitor (PID 1, watchdog)
  - virt-launcher (cmd-server, 跟 virt-handler 對話)
  - libvirtd / virtqemud
  - QEMU process
- gRPC 介面 (`handler-launcher-com`)：virt-handler 對 virt-launcher 發 SyncVMI / KillVMI / MigrateVMI；virt-launcher 對 virt-handler 發 DomainEvent (libvirt event 的 wrapping)
- DomainManager (`pkg/virt-launcher/virtwrap/manager.go:135`)：virt-launcher 內的核心 abstraction，把「啟動 / 暫停 / 遷移 VM」翻成 libvirt API call
- VMI spec → libvirt domain XML：converter (`pkg/virt-launcher/virtwrap/converter/converter.go`) 做翻譯
- CNI / networking：virt-launcher Pod 起來後，virt-handler 透過 `pkg/network/` 設定 bridge/macvtap 把 Pod 的 net namespace 接給 QEMU；這就是 secondary network (multus) 在 kubevirt 的接點
- storage：DataVolume / PVC mount 進 virt-launcher Pod，再透過 libvirt domain XML 描述為 QEMU disk

**關鍵 file/symbol**：

- `cmd/virt-handler/virt-handler.go:202` — `virtHandlerApp.Run`
- `pkg/virt-handler/vm.go:120` — `NewVirtualMachineController`
- `pkg/virt-handler/vm.go:290` — `Execute`; `:306` `execute`; `:1354` `sync`; `:2130` `processVmUpdate`
- `cmd/virt-launcher/virt-launcher.go:343` — `main`
- `pkg/virt-launcher/virtwrap/manager.go:135` — `DomainManager` interface; `:239` `NewLibvirtDomainManager`
- `pkg/virt-launcher/virtwrap/converter/converter.go` — VMI → libvirt XML

### 頁 4：`live-migration.mdx`（memory copy 與 cutover）

**核心問題**：你在 source node 上跑 web service VM，下個指令 live migrate 到 target node，downtime ~200ms。background 是真的把 RAM 抄一份過去？怎麼處理 dirty page？什麼時候 cutover？

**內容大綱**：

- VirtualMachineInstanceMigration (VMIM) CRD → Migration controller 接到 → 在 target node 起一個 virt-launcher Pod (mode: target) → 等 target ready → 通知 source virt-handler 啟動 migration
- libvirt MigrateVMI 模式：
  - **precopy** (default)：先全量抄 memory，再 iteratively 抄 dirty page 直到 dirty rate < bandwidth；最後 pause source、抄最後一輪、resume target
  - **postcopy**：source 直接 pause、resume target；target 缺哪個 page 就 page-fault 拉回來。downtime 短但可能有效能 dip
  - **paused fallback**：dirty rate 一直高於 bandwidth 不收斂時，可以用 cancel 或 paused → 收斂後再 resume
- migration-proxy (`pkg/virt-handler/migration-proxy/`)：一條 unix socket → TCP proxy，讓 libvirt 跨 node 對話 (libvirt 預設只在 unix socket)
- migrationMonitor (`pkg/virt-launcher/virtwrap/live-migration-source.go:407`)：監控 progress、判斷 cutover、對接 migration policy (auto-converge、postcopy 切換)
- cutover 點：libvirt 的 DowntimeMs 設定影響「最後一輪暫停的最大允許 downtime」；如果 N 輪 dirty 還沒收斂到那個門檻就觸發 fallback
- migration policy CRD (`migrationpolicy.go`)：cluster-wide / namespace-scoped policy，定 bandwidth、allowAutoConverge、postCopy on/off

**關鍵 file/symbol**：

- `pkg/virt-controller/watch/migration/migration.go:120` — Migration controller
- `pkg/virt-launcher/virtwrap/manager.go:683` — `LibvirtDomainManager.MigrateVMI`
- `pkg/virt-launcher/virtwrap/live-migration-source.go:96` — `generateMigrationFlags`
- `pkg/virt-launcher/virtwrap/live-migration-source.go:285` — `LibvirtDomainManager.startMigration`
- `pkg/virt-launcher/virtwrap/live-migration-source.go:407` — `newMigrationMonitor`
- `pkg/virt-handler/migration-proxy/` — socket proxy

## Quiz 設計（5 題）

1. **virt-launcher 為什麼是 per-VMI Pod 而不是 DaemonSet** — isolation 與 QEMU lifecycle 的對應
2. **VM / VMI / VMIM 三 CRD 的關係** — VM = desired state，VMI = 一次 run，VMIM = 一次 migration
3. **virt-handler / virt-launcher 為什麼透過 gRPC 對話而不是直接 libvirt** — virt-launcher 在 Pod 內，network namespace + cgroup 隔離；gRPC 是 cross-Pod 的合理協定
4. **live migration 為什麼會收不收斂** — dirty rate vs bandwidth；何時觸發 postcopy / pause fallback
5. **migration-proxy 的角色** — libvirt 預設 unix socket only；要 cross-node 必須有 TCP proxy

## 驗證等級

- 所有 function name / line number → grep 在 `kubevirt/` submodule v1.8.2 tag 上跑過
- 不寫任何 lab 命令；不需要實機 cluster 驗證

## 跟現有 SP 的接點

- `next-site/lib/projects.ts`：在 `PROJECTS` 加 `kubevirt` 條目，4 個 features (architecture / controllers / virt-handler-and-launcher / live-migration)
- `next-site/content/kubevirt/quiz.json` 5 題
- learning-plan Day 22-30 的源碼參考可以指到這 4 頁
- `versions.json` 加 `kubevirt` 條目

## 不做的事

- 不 import 元件；不 mermaid；不 placeholder 圖
- 不展開 CDI / DataVolume internals (只提到接點)
- 不寫 lab 命令；lab 在 SP-2 day-pages
- 不展開 device plugin、TPM、SEV、virtiofs、export 等進階 feature
