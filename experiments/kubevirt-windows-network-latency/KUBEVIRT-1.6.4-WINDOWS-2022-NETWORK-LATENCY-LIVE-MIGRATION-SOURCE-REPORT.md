# KubeVirt v1.6.4：Windows Server 2022 低 network latency 且可 live migration 的 VM spec 研究

> 研究日期：2026-09-02
> KubeVirt：`v1.6.4`，tag object `655938eb5f51ffbda995ccafbd2cde980370a674`，release commit `ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f`
> `virt-launcher` x86_64：CentOS Stream 9 `qemu-kvm 9.1.0-19.el9`、libvirt `10.10.0-13.el9`
> QEMU source 基準：CentOS Stream dist-git commit `52929cc849fce4520d89da98ea06c517be46a5cb`；upstream baseline `v9.1.0` commit `fd1952d814da738ed107e05583b3e02ac11e88ff`
> 範圍：VM spec、guest NetKVM/RSS、host placement 與 migration policy。沒有對實際 NIC、CNI、Windows image 或 production cluster 做 benchmark。

## 兩分鐘決策摘要

**結論：若「live migration 必須保留」是硬條件，預設方案應是 `virtio-net + vhost-net + multiqueue`，搭配 dedicated pCPU、獨立 emulator thread，以及所有 migration 目的 node 都可重現的 CPU／NUMA／hugepage 條件。資料面優先走跨 node 共通的 Multus L2 bridge；不要把 PCI hostdev、DPDK VF 直通或 `hypervPassthrough` 放進這個基準。**

建議先從 4 個 vCPU、4 個 virtio queue 起跑，不直接堆到很多 vCPU。KubeVirt v1.6.4 的 `networkInterfaceMultiqueue: true` 不是任意 queue 數：程式會以 VMI vCPU 數建立 queue，最多 256，並在 libvirt interface driver 指定 `name="vhost"`。Windows NetKVM 還必須真的協商 `VIRTIO_NET_F_MQ`，RSS 也必須啟用；否則 YAML 看起來開了 multiqueue，封包仍可能集中在一個 CPU／queue。

| 項目 | 基準決策 | live migration 影響 |
|---|---|---|
| NIC model | `virtio` | QEMU 有 virtio device migration state；來源與目的端的 machine type、QEMU 與 NetKVM feature negotiation 仍須一致 |
| datapath | Multus secondary L2 bridge 作資料面；pod masquerade 作管理面 | 兩個 node 必須接到同一 L2／VLAN，MAC 與 guest IP 必須保持；不要把 pod bridge annotation 當成一般解法 |
| queue | `networkInterfaceMultiqueue: true`；4 vCPU 起跑 | queue 數是 vCPU 數；目的端必須能建立同樣 queue/device state |
| CPU | `dedicatedCpuPlacement: true`、`isolateEmulatorThread: true`、1 socket × N cores × 1 thread | KubeVirt 會在目的端重建 pinning；目的 node 仍要有足夠的 exclusive pCPU |
| CPU model | baseline 先省略 `model`，讓 v1.6.4 使用 `host-model`；盤點完所有候選 node 後再 pin 共同 named model；`unsafeMigrationOverride: false` | `host-passthrough` 可能多拿到 host feature，卻擴大跨 node 不相容風險；不能只看效能選它 |
| NUMA／hugepage | 第一輪先 2 MiB hugepage；只有跨 NUMA 已被量測為瓶頸才開 `guestMappingPassthrough` | 所有目的 node 都要有相同資源與可相容 topology，否則 VM 可執行但 migration 排程不一定成功 |
| Hyper-V | 明列可 migration 的 enlightenments；禁止 `hypervPassthrough` | KubeVirt source 直接把 `hypervPassthrough` 標成 non-migratable |
| migration | pre-copy、專用 migration network、先不開 post-copy／auto-converge | post-copy 遇到 migration network 故障可能讓 VM crash；auto-converge 會犧牲 workload 效能 |
| SR-IOV | 不作第一版 | v1.6.4 已有 SR-IOV live migration，但做法是 migration 前 detach VF、目的端再 attach，需另外量測 Windows 裝置重綁與封包中斷 |

這是一個**source-backed 起始設定**，不是 latency 保證。network p99/p99.9 受實體 NIC queue、IRQ affinity、NUMA、CNI、MTU、交換器、Windows DPC、NetKVM 版本與 workload flow 數影響；VM spec 無法單獨控制完整路徑。

## 版本鏈：實際跑的不是 vanilla QEMU

KubeVirt release tag 可在官方 [v1.6.4 release](https://github.com/kubevirt/kubevirt/releases/tag/v1.6.4) 驗證。這個 tag 指到 release commit `ac5324e…`。

`virt-launcher` 的 image 由 repo 的 RPM tree 組出；v1.6.4 的 [rpm/BUILD.bazel](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/rpm/BUILD.bazel#L1152-L1197) 對 x86_64 納入：

- `libvirt-client/daemon/libraries 10.10.0-13.el9`
- `qemu-kvm-common/core 9.1.0-19.el9`

同一份 lock 來源可在 [WORKSPACE](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/WORKSPACE#L6723-L6783) 看到 RPM 名稱與官方 CentOS Stream URL。CentOS Stream dist-git 的精確 build commit 是 [`52929cc…`](https://gitlab.com/redhat/centos-stream/rpms/qemu-kvm/-/tree/52929cc849fce4520d89da98ea06c517be46a5cb)；其 [`qemu-kvm.spec`](https://gitlab.com/redhat/centos-stream/rpms/qemu-kvm/-/blob/52929cc849fce4520d89da98ea06c517be46a5cb/qemu-kvm.spec#L151-162) 宣告 `Version: 9.1.0`、`Release: 19`，並在後續段落套用 Red Hat machine type、migration、virtio-net 等 downstream patches。

因此本文引用 upstream QEMU `v9.1.0` 時，只是在說明共同機制；若 upstream 與 CentOS patch 有差異，以 `52929cc…` 的 spec、patch 集與實際 `virt-launcher` binary 為準。部署後還要在 launcher 內讀 `qemu-kvm --version`、`virsh dumpxml` 與 QEMU command line，不能用這份 build definition 取代 runtime 證據。

## 建議 VM spec

以下片段刻意拆成「管理 NIC」與「低 latency 資料 NIC」。管理 NIC 使用 pod masquerade，讓 KubeVirt 明確判定 pod network 可 migration；資料 NIC 使用 Multus L2 bridge，避開 pod masquerade 的 NAT 路徑。`latency-l2` 對應的 CNI 必須讓所有候選 node 位於同一 L2/VLAN。

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: windows-2022-lowlat
  namespace: vm-prod
  labels:
    workload: windows-2022-lowlat
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        workload: windows-2022-lowlat
    spec:
      evictionStrategy: LiveMigrate
      domain:
        cpu:
          sockets: 1
          cores: 4
          threads: 1
          dedicatedCpuPlacement: true
          isolateEmulatorThread: true
        memory:
          guest: 8Gi
          hugepages:
            pageSize: 2Mi
        resources:
          requests:
            memory: 8Gi
        clock:
          utc: {}
          timer:
            hpet:
              present: false
            hyperv: {}
            pit:
              tickPolicy: delay
            rtc:
              tickPolicy: catchup
        features:
          acpi: {}
          apic: {}
          hyperv:
            relaxed: {}
            vapic: {}
            spinlocks:
              spinlocks: 8191
            vpindex: {}
            runtime: {}
            synic: {}
            synictimer: {}
            frequencies: {}
            tlbflush: {}
            ipi: {}
          smm: {}
        firmware:
          bootloader:
            efi:
              secureBoot: true
        devices:
          networkInterfaceMultiqueue: true
          autoattachMemBalloon: false
          interfaces:
            - name: default
              model: virtio
              masquerade: {}
            - name: latency-net
              model: virtio
              bridge: {}
          disks:
            - name: rootdisk
              disk:
                bus: virtio
      networks:
        - name: default
          pod: {}
        - name: latency-net
          multus:
            networkName: vm-prod/latency-l2
      volumes:
        - name: rootdisk
          persistentVolumeClaim:
            # 必須是來源與目的 node 可同時存取、且 KubeVirt 判為 shared 的 volume。
            claimName: windows-2022-root-rwx
```

### 這份 spec 哪些值不能直接照抄

1. baseline 故意省略 `machine.type` 與 `cpu.model`：v1.6.4 的 CPU API 預設是 `host-model`，machine type 則由該版本與 architecture 的 default 決定。這讓 YAML 不會假裝某個 RHEL machine type 或 Intel CPU model 在所有環境都存在，但也代表它不應在 upgrade 前原封不動長期漂移。
2. production 上線前，先從**所有** migration 候選 node 取得 libvirt capabilities、可用 machine type、CPU model／feature 與實際 domain XML，再 pin 共同值。AMD、不同 Intel 世代或 mixed stepping cluster 若找不到兼顧效能的共同 model，就先切 homogeneous migration pool。
3. 2 MiB hugepage 需要每個候選 node 預留。若目的 node 沒有足夠 page，問題發生在排程／migration 可用性，不是 QEMU 自動降回一般 page。
4. `autoattachMemBalloon: false` 是固定記憶體、降低背景裝置活動的 low-jitter 假設；代價是失去 balloon 回收。是否真的改善 p99 必須 A/B。
5. root PVC 必須符合這個 cluster 的 shared-storage 判定。KubeVirt v1.6.4 會拒絕無法確認 shared access 或非 shared PVC 的 live migration；source 檢查見 [virt-handler/vm.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-handler/vm.go#L1727-L1802)。

完成 inventory 後，再把環境實際共同值以 overlay pin 回 VM template；下列名稱只是格式示意，**不是 baseline 預設值**：

```yaml
spec:
  template:
    spec:
      domain:
        machine:
          type: <all-target-nodes-common-machine-type>
        cpu:
          model: <libvirt-baseline-common-cpu-model>
```

## 為什麼這組設定能降低 latency

### 1. virtio-net、vhost-net 與 multiqueue

KubeVirt API 對 `networkInterfaceMultiqueue` 的說明是：virtio interface 啟用 vhost multiqueue，queue 數還會受 guest CPU 數等因素影響，見 [schema.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/staging/src/kubevirt.io/api/core/v1/schema.go#L493-L509)。實作更精確：

- 只有 `model: virtio` 才計算 queue。
- queue 數等於 VMI vCPU 數。
- 上限 256。
- queue 大於 0 時，產生 libvirt `<driver name='vhost' queues='N'/>`。

來源是 [converter/network.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-launcher/virtwrap/converter/network.go#L35-L65) 與 [queue 計算](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-launcher/virtwrap/converter/network.go#L129-L153)。QEMU 9.1 的 vhost-net 實作會把 virtio-net 的 queue pair 交給 kernel vhost backend，並處理 start/stop，見 [hw/net/vhost_net.c](https://gitlab.com/qemu-project/qemu/-/blob/fd1952d814da738ed107e05583b3e02ac11e88ff/hw/net/vhost_net.c#L357-473)。

這支持的結論是「減少 QEMU userspace datapath 工作、讓多個 flow 可分散處理」，但不能推出「queue 越多，單一 request latency 越低」。RSS 會維持同一 flow 的 CPU affinity；單一 TCP flow 不會因 4 queue 直接變成四倍快。過多 vCPU 也會增加排程、cache 與 migration RAM dirtying 的間接成本，所以先用 4 queue，再依 flow 數與 p99 擴充。

### 2. dedicated pCPU 與 emulator thread 隔離

KubeVirt API 明定 `dedicatedCpuPlacement` 會配置並 pin vCPU，`isolateEmulatorThread` 會多要一顆 dedicated pCPU 放 emulator thread，見 [CPU schema](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/staging/src/kubevirt.io/api/core/v1/schema.go#L318-L357)。converter 會實際產生 `emulatorpin`；目的端 migration 會依目的 node CPU set／topology 重算 domain，而不是沿用來源 pCPU 編號，見 [vcpu.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-launcher/virtwrap/converter/vcpu/vcpu.go#L480-L527) 與 [live-migration-source.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-launcher/virtwrap/live-migration-source.go#L144-L210)。

這能降低 vCPU 被其他 Pod 搶占、QEMU emulator 與 guest vCPU 互搶的 jitter。它**不等於**完整 pin 住實體 NIC IRQ、softirq、vhost worker 與 CNI thread。這些還要在 node 上查 `/proc/interrupts`、IRQ affinity、vhost thread、CPU manager policy 與 NUMA locality。VM spec 本身不能保證 queue、IRQ、VF/PF 與記憶體都在同一 NUMA node。

### 3. NUMA 與 hugepage

`guestMappingPassthrough` 會建立與 exclusive host CPU placement 相容的 guest NUMA topology，使 CPU 與記憶體不跨 host NUMA boundary；API 契約見 [schema.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/staging/src/kubevirt.io/api/core/v1/schema.go#L342-L373)。converter 會建立 strict NUMA memory binding 與 per-cell hugepage，見 [vcpu.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-launcher/virtwrap/converter/vcpu/vcpu.go#L640-L675)。

它適合已證明 remote-NUMA memory access 是 tail latency 來源的 VM；不應無條件開啟。開啟後 migration 目的端必須有可重現的 exclusive CPU、NUMA 與 hugepage 形狀，會縮小可排程 node 集合。建議流程是：

1. 先用 dedicated CPU + 2 MiB hugepage 做 baseline。
2. 同時記錄 guest latency、host NIC NUMA、vhost/IRQ CPU、`numastat` 與 domain XML。
3. 只有觀察到 cross-node access 才加入 `guestMappingPassthrough`。
4. 在至少兩個目的 node 都做 migration 往返測試。

### 4. Hyper-V enlightenments 與 timer

KubeVirt 官方 Windows VMI 範例本來就使用 `hypervclock`、關閉 HPET，以及 `relaxed`、`vapic`、spinlock 8191，見 [examples/vmi-windows.yaml](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/examples/vmi-windows.yaml#L17-L40)。本文多列 `vpindex/runtime/synic/synictimer/tlbflush/ipi/frequencies`，理由來自 QEMU 9.1 的官方 Hyper-V 說明：

- `hv-vapic` 提供 exit-less EOI。
- `hv-time` 的 Reference TSC page 讓 timestamp read 不必 VM exit。
- `hv-stimer` 避免部分 Windows 退回頻繁使用 HPET／RTC，否則即使 idle 也可能增加 CPU 消耗。
- `hv-tlbflush` 與 `hv-ipi` 減少跨 vCPU TLB shootdown／IPI 的 hypervisor exit。

依賴關係與限制見 [QEMU v9.1 hyperv.rst](https://gitlab.com/qemu-project/qemu/-/blob/fd1952d814da738ed107e05583b3e02ac11e88ff/docs/system/i386/hyperv.rst#L37-178)。KubeVirt 會把這些 API 欄位轉成 libvirt Hyper-V feature，見 [converter.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-launcher/virtwrap/converter/converter.go#L1029-L1114)。

普通 Windows Server 2022 不建議開 `reenlightenment` 或 `evmcs`：QEMU 說明明確指出前者是 nested Hyper-V migration 情境，還要求目的端相同 TSC frequency 或 TSC scaling；後者也是 nested、Intel-only，且可能關閉其他 virtualization feature。若 Windows 2022 內要跑 Hyper-V role，應另開一個 nested-virtualization profile，不與一般低 latency profile 混用。

最重要的 migration guardrail 是**禁止**：

```yaml
features:
  hypervPassthrough: {}
```

KubeVirt API 已標示它會使 VM non-migratable，virt-handler 也直接回報 `VMI uses hyperv passthrough`，見 [schema.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/staging/src/kubevirt.io/api/core/v1/schema.go#L1128-L1144) 與 [vm.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-handler/vm.go#L1214-L1229)。

## network binding 的 migration 取捨

### 建議：pod masquerade 管理面 + Multus bridge 資料面

KubeVirt v1.6.4 的 migratability check 對 pod network 接受：

- masquerade binding；
- 帶特定 annotation 的 pod bridge；
- 宣告支援 migration 的 binding plugin。

程式碼見 [pkg/network/vmispec/interface.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/network/vmispec/interface.go#L57-L91)。secondary Multus bridge 不會觸發「pod network binding 不可 migration」這個阻擋；但能否保持連線取決於 CNI、L2 reachability、MAC learning、DHCP／IP 與交換器，不是這段 check 保證的。

資料面選 Multus bridge 的理由是少一層 pod masquerade/NAT，而仍保留 emulated virtio device state。需逐項驗證：

- source／destination node 接同一 VLAN，MTU 完全一致；
- guest 固定 MAC 與 IP 在 migration 後不變；
- upstream switch 的 MAC move 收斂時間；
- migration 完成後 gratuitous ARP／neighbor refresh 是否生效；
- 既有 TCP flow 的 packet loss、reordering 與 outage。

不要以 `kubevirt.io/allow-pod-bridge-network-live-migration` 當常態設計。那個 annotation 只讓 migratability check 放行 pod bridge，不會替你證明 pod IP／MAC 語意與連線連續性。

### SR-IOV：v1.6.4 可以 migration，但不是透明 VF state migration

KubeVirt v1.6.4 已把 `SRIOVLiveMigration` 列為 GA，見 [featuregate/inactive.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-config/featuregate/inactive.go#L99-L107)。migration 前，launcher 會找出 SR-IOV host devices、等待 device-removed event，最多 30 秒，detach 後才呼叫 libvirt migration；見 [live-migration-source.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-launcher/virtwrap/live-migration-source.go#L124-L143) 與 [prepareDomainForMigration](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-launcher/virtwrap/live-migration-source.go#L1050-L1101)。官方 functional test 也明確要求兩個 node 有 SR-IOV resource、固定 MAC，並檢查 migration 後 VF 回到 guest，見 [tests/network/sriov.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/tests/network/sriov.go#L257-L294)。

所以它滿足「KubeVirt 可以執行 live migration」，但不是 QEMU 把同一顆 VF 的完整 hardware state 無縫搬走。對 Windows 2022 要實測 device removal/re-add、NetKVM／vendor VF driver、RSS config 是否保留，以及 outage 是否可接受。在得到 p99 與 migration loss 證據前，不應取代 virtio-net 基準。

一般 `domain.devices.hostDevices`／PCI GPU 更直接：KubeVirt 會把它們標成 non-migratable，見 [vm.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-handler/vm.go#L1186-L1234)。QEMU 新版雖有 VFIO device migration 協定，KubeVirt v1.6.4 的這個 VMI eligibility gate 仍是眼前限制；不能用上游 QEMU 能力推論 KubeVirt hostdev 已可 migration。

### DPDK／vhost-user

DPDK 不是單一 KubeVirt interface binding：

- guest DPDK + SR-IOV VF：受上面的 detach/re-attach migration 模型限制。
- host DPDK/vhost-user binding plugin：只有 plugin 明確宣告 migration 且 backend 能保存／還原 device state，KubeVirt eligibility 才可能放行。
- generic PCI hostdev：KubeVirt v1.6.4 直接阻擋。

QEMU vhost-user protocol 的 migration 需要 backend state transfer 與一致的 queue/config state，官方協定見 [vhost-user.rst](https://gitlab.com/qemu-project/qemu/-/blob/fd1952d814da738ed107e05583b3e02ac11e88ff/docs/interop/vhost-user.rst#L495-575)。因此「DPDK latency 最低」不能直接轉成「DPDK 又能 live migration」；需要指定 exact backend、CNI/plugin 與 QEMU device type後重新做 source trace。

## Windows Server 2022 guest 端

### 先釐清兩種不同的 RSS

KubeVirt v1.6.4 的 VM spec **沒有**欄位可要求 QEMU 開啟 virtio 1.1 device-side `VIRTIO_NET_F_RSS`。QEMU 9.1 在 vhost-net backend 無法載入 eBPF RSS 時也會清掉該 feature；因此不要用 sidecar 硬加 libvirt `<driver rss='on'/>`，更不要為了 QEMU software RSS 關掉 vhost 快速路徑。這個限制可從 [QEMU v9.1.0 feature negotiation](https://github.com/qemu/qemu/blob/fd1952d814da738ed107e05583b3e02ac11e88ff/hw/net/virtio-net.c#L760-L810) 與 [RSS commit path](https://github.com/qemu/qemu/blob/fd1952d814da738ed107e05583b3e02ac11e88ff/hw/net/virtio-net.c#L1284-L1300) 證明。

但這**不等於 Windows NDIS RSS 不可用**。兩者是不同層次：

- QEMU `VIRTIO_NET_F_RSS`：device/backend 幫 guest 算 hash 與 redirect；本組態不應依賴。
- NetKVM／Windows RSS：guest driver 可自行算 Toeplitz hash，再依 NDIS indirection table 把 receive processing 分散到 guest CPU／queue。

截至本研究日，virtio-win upstream commit [`bbd46150…`](https://github.com/virtio-win/kvm-guest-drivers-windows/tree/bbd46150d35be9d9aa4ea2ae4edcb542880fa4a0) 的 NetKVM source 顯示：driver 會分別協商 `VIRTIO_NET_F_MQ` 與 device-side RSS；即使 device-side RSS 不存在，仍向 NDIS 宣告 software RSS capabilities、在 receive path 自行計算 hash，並用 MQ control command 設定 queue pairs。證據見 [`ParaNdis_Common.cpp`](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/bbd46150d35be9d9aa4ea2ae4edcb542880fa4a0/NetKVM/Common/ParaNdis_Common.cpp#L925-L966)、[`ParaNdis6_RSS.cpp`](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/bbd46150d35be9d9aa4ea2ae4edcb542880fa4a0/NetKVM/wlh/ParaNdis6_RSS.cpp#L69-L126) 與 [`ParaNdis_RX.cpp`](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/bbd46150d35be9d9aa4ea2ae4edcb542880fa4a0/NetKVM/Common/ParaNdis_RX.cpp#L850-L890)。

這個 virtio-win commit **不是** KubeVirt v1.6.4 自動配對的 guest driver：KubeVirt 不會 pin Windows image 內的 NetKVM。production 判斷仍必須以實際 driver 版本、`Get-NetAdapterRss`、NetKVM runtime statistics 與多 flow CPU/queue 分布為準。可確認的是：不要把「QEMU device-side RSS 被關閉」誤寫成「Windows guest RSS 一定無效」。

### NetKVM 與 RSS 是要驗證的 guest gate

KubeVirt/QEMU 提供 queue 只完成 host 一半。NetKVM source 會在 control queue 存在時協商 `VIRTIO_NET_F_MQ`，讀取 hardware queue 數；RSS 支援還受 `*RSS`、`*NumRssQueues` 與 driver 實作影響，見前一節釘選的 source。virtio-win 沒有隨 KubeVirt `virt-launcher` 一起版本鎖定，所以 production image 必須自己 pin、簽章驗證與回歸測試 NetKVM 版本，不能寫「使用最新版」就結案。

Windows Server 2022 的 Microsoft 官方調校指南指出 RSS 會把 receive processing 分散到多個 CPU，並建議低 latency workload 檢查 RSS、interrupt moderation、offload 與 processor affinity；同時提醒最佳值依 workload 而定，見 [Network Adapter Performance Tuning](https://learn.microsoft.com/en-us/windows-server/networking/technologies/network-subsystem/net-sub-performance-tuning-nics) 與 [RSS 架構](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/introduction-to-receive-side-scaling)。

部署後至少保存：

```powershell
Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, LinkSpeed
Get-NetAdapterRss -Name '<latency NIC>' | Format-List *
Get-NetAdapterAdvancedProperty -Name '<latency NIC>' |
  Where-Object RegistryKeyword -Match 'RSS|Rsc|LSO|Checksum|Interrupt|Queue'
Get-NetAdapterStatistics -Name '<latency NIC>' | Format-List *
```

建議先保持 checksum offload 啟用。LSO、RSC 與 interrupt moderation 對 throughput 常有利，但可能把 packet batching latency 拉高；應各自做 A/B，不能一次全關再把結果歸因給其中一項。RSS 應開啟，`*NumRssQueues` 不得高於 QEMU 實際 queue，且 CPU set 要避開 emulator／高 IRQ 干擾 CPU。Microsoft 也指出 RSS 不把同一實體 core 的 hyper-thread 當成等價獨立 core；這也是 VM topology 先用 `threads: 1`、host 端確認完整 core isolation 的原因。

### vRSS 名詞邊界

在 Hyper-V 說明裡，vRSS 常指 Hyper-V virtual switch 對 VMQ／VPort 的接收分散。這裡的 hypervisor 是 KVM/QEMU，實際鏈是 virtio-net MQ + NetKVM RSS；不要把 Hyper-V host 的 vRSS/VMQ cmdlet 原封不動套到 KubeVirt node。Windows guest 內應以 `Get-NetAdapterRss` 與 NetKVM runtime statistics 驗證，而不是假設看到多 vCPU 就有 vRSS。

## migration policy：不要用 migration 調校破壞 steady-state latency

KubeVirt v1.6.4 cluster migration configuration 暴露 `bandwidthPerMigration`、`completionTimeoutPerGiB`、`progressTimeout`、`allowAutoConverge`、`allowPostCopy`、`allowWorkloadDisruption` 與專用 migration `network`；預設平行數為每 node 2、cluster 5，bandwidth 預設不限制，兩個 timeout 預設 150，見 [types.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/staging/src/kubevirt.io/api/core/v1/types.go#L3074-L3124) 與 [virt-config.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-config/virt-config.go#L38-L48)。MigrationPolicy 可依 namespace/VMI label 覆寫其中一部分，見 [migrations/v1alpha1/types.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/staging/src/kubevirt.io/api/migrations/v1alpha1/types.go#L29-L65)。

建議建立獨立 migration network，避免 pre-copy RAM 流量與 VM 資料面搶同一 uplink／queue。第一輪 policy：

```yaml
apiVersion: migrations.kubevirt.io/v1alpha1
kind: MigrationPolicy
metadata:
  name: windows-lowlat-precopy
spec:
  selectors:
    namespaceSelector:
      migration-profile: windows-lowlat
    virtualMachineInstanceSelector:
      workload: windows-2022-lowlat
  allowAutoConverge: false
  allowPostCopy: false
  allowWorkloadDisruption: false
  # 範例為 512 MiB/s（約 4.29 Gbit/s），不是 512 Mbit/s。
  # 應以 migration NIC 可用容量扣掉服務流量與同時 migration 的 headroom 後重算。
  bandwidthPerMigration: 512Mi
  completionTimeoutPerGiB: 150
```

同時在 `KubeVirt.spec.configuration.migrations.network` 指到專用 NAD。`bandwidthPerMigration` 是 Kubernetes byte quantity，KubeVirt 會先轉成 MiB/s 再交給 libvirt，source 見 [generateMigrationParams](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-launcher/virtwrap/live-migration-source.go#L814-L842)。因此範例 `512Mi` 是 512 MiB/s（約 4.29 Gbit/s）；若寫 `2Gi`，語意會是 2 GiB/s（約 17.18 Gbit/s），不是 2 Gbit/s。範例值不是建議值，應以 NIC 容量、同時 migration 數、VM dirty rate 與服務流量 headroom 重算。

KubeVirt source 明說：

- `allowAutoConverge` 會以犧牲 VMI performance/availability 換收斂。
- post-copy 遇到 network failure 可能讓 VMI crash。
- migration 先走 pre-copy，timeout 後才依設定切 post-copy／pause／cancel。

因此 low-latency service 的預設應先保護 steady-state：pre-copy + migration network + 限制同時 migration。只有 dirty rate 高到 pre-copy 無法收斂、而業務明確接受 migration network failure 風險，才另測 post-copy。KubeVirt 會在 log 暴露 `ExpectedDowntime`、dirty rate 與 memory bandwidth，見 [live-migration-source.go](https://github.com/kubevirt/kubevirt/blob/ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f/pkg/virt-launcher/virtwrap/live-migration-source.go#L726-L744)；這些是驗收資料，不是 VM spec 裡可直接承諾的 downtime。

`unsafeMigrationOverride` 必須維持 false。它的定義就是在 compatibility check 判斷不安全時仍強行 migration；用它通過測試只會把 source/destination CPU、machine type 或 device 差異轉成 guest 風險。

## 必做 runtime 驗證

### Gate 1：設定真的生效

1. VMI condition `LiveMigratable=True`，且 message 為空。
2. `virsh dumpxml`：NIC model 是 virtio，driver 是 vhost，queues=4；有 vcpupin 與 emulatorpin；memory backing、machine type、Hyper-V feature 符合預期。
3. QEMU command line：確認實際 binary、machine、CPU model、`-netdev tap,...vhost=on,queues=4` 與 virtio-net vectors/queues。
4. Windows：NetKVM driver version／簽章、RSS enabled、indirection table 與 queue 數。
5. host：vhost thread、tap queue、NIC IRQ、NUMA 與 exclusive pCPU 的實際 affinity。

### Gate 2：steady-state latency

至少分單一 flow、4 flow、queue 數以上 flow 三組；每組保存 p50/p95/p99/p99.9/max、packet loss、CPU/DPC、softirq 與 NIC drops。A/B 至少包含：

- 1 queue vs multiqueue；
- shared CPU vs dedicated + isolated emulator；
- 一般 page vs 2 MiB hugepage；
- RSS off/on；
- interrupt moderation、RSC、LSO 各自單變因；
- masquerade vs Multus bridge。

### Gate 3：migration 時間線

持續送固定頻率的小封包與長連線，至少 migration 往返 20 次，記錄：

- migration 前 60 秒、migration 全程、完成後 60 秒的 p99/p99.9；
- 最長連續 packet loss、TCP retransmit、connection reset；
- QEMU expected/actual downtime、dirty rate、migration bandwidth；
- Windows event log、NIC link flap、RSS queue 是否重設；
- source failure／cancel 能否回復；目的 node 缺 hugepage、CPU model 不符時是否安全拒絕。

驗收值必須由 workload owner 定義。若只有「migration 成功」而沒有 packet loss 與 tail latency，不能宣稱達成需求。

## 不應採用的捷徑

1. **`host-passthrough` + `unsafeMigrationOverride`**：steady-state 可能較快，但把 node 差異風險延後到 migration／guest。
2. **只開 multiqueue、不驗 Windows RSS**：host 建了 queue 不代表 guest 有使用。
3. **盲目增加 vCPU**：KubeVirt 會同步增加 network queues，單一 flow 不會因此線性降低 latency，migration 與 NUMA 約束反而增加。
4. **SR-IOV 等同零中斷 migration**：v1.6.4 是 detach/re-attach VF，需量測 Windows 裝置事件與 outage。
5. **把 pod bridge annotation 當連線連續性保證**：它只影響 eligibility check。
6. **開 `hypervPassthrough`**：source 明確判定 non-migratable。
7. **先開 post-copy**：network 故障可讓 VM crash；它是收斂工具，不是 latency 魔法。
8. **只測平均 RTT**：CPU contention、IRQ 與 migration 的問題通常先出現在 p99/p99.9 與最長 outage。

## 證據分級與尚未知

| 主張 | 分級 | 說明 |
|---|---|---|
| v1.6.4 launcher 使用 QEMU RPM 9.1.0-19.el9、libvirt 10.10.0-13.el9 | source-proven | KubeVirt release build tree；實際 cluster 仍需 runtime image/digest 驗證 |
| multiqueue queue 數等於 vCPU、上限 256，且指定 vhost driver | source-proven | KubeVirt converter |
| Hyper-V passthrough、generic PCI hostdev 會阻擋 migration | source-proven | KubeVirt migratability condition |
| SR-IOV migration 會先 detach VF，再 migration | source-proven | KubeVirt live migration source + functional test |
| dedicated CPU／emulator pin 會降低本環境 p99 | experiment-needed | source 只證明配置行為，不證明效果量 |
| 2 MiB hugepage 比一般 page latency 低 | experiment-needed | workload、TLB miss 與 NUMA 決定結果 |
| Multus bridge 比 masquerade latency 低且 migration 不斷線 | experiment-needed | datapath 推論合理，但 CNI／L2／switch 是部署條件 |
| 4 vCPU／4 queue 是最優值 | experiment-needed | 它是可控起點，不是通用 optimum |
| Windows NetKVM/RSS 在 migration 後維持 queue state | runtime-required | driver 版本不由 KubeVirt release pin |

## 最終建議

先建立一個 homogeneous migration node pool，固定 machine type 與共同 CPU model；用 4 vCPU、dedicated pCPU、isolated emulator、2 MiB hugepage、virtio-net multiqueue、Windows NetKVM RSS，以及 Multus L2 資料面。migration 走另一張 network，保持 pre-copy，不開 auto-converge/post-copy/unsafe override。這是同時守住 steady-state latency 與 live migration 的最低風險起點。

若這個版本在實機仍無法達到 latency SLO，下一步不是直接切 SR-IOV，而是先用同一量測矩陣找出瓶頸位於 guest DPC、vhost/IRQ、CNI/NAT、NUMA 還是實體 network。只有證據指向 virtio datapath 上限，才做 SR-IOV profile，並把 migration 時的 VF detach/re-attach outage 當成獨立 SLO 驗收。
