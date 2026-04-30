# SP-7: multus-cni v4.2.4 first-wave MVP design

## Goal

給「已經懂 CNI 與 Pod 網路」的讀者一張 multus-cni v4.2.4 (latest stable) 的最短地圖：理解 multus 是什麼、為什麼存在 (single-CNI limit)、thick vs thin 部署差異、delegate 機制、與 NAD CRD 的關係。MDX × 4 + 5 題 quiz。

## Scope

### In scope
- meta-plugin 概念 (multus 不自己接 veth/route — 把 CNI op 轉發給 list of delegates)
- 兩個 binary: thin `multus` vs thick (`multus-shim` + `multus-daemon`) 的差別
- NetworkAttachmentDefinition (NAD) CRD：annotation `k8s.v1.cni.cncf.io/networks` → NAD lookup → delegate config
- `CmdAdd` flow：parse annotation → resolve NAD list → 對每個 delegate 呼叫 libcni → master delegate 的 result 是給 kubelet 看的
- thick 模式：shim 做為 CNI binary 透過 unix socket 把 op 送到 daemon，daemon 用 informer cache 減 apiserver load
- network-status annotation writeback (告訴外部「這個 Pod 有哪些 network interface」)
- 與 SR-IOV 的整合點 (`k8s.v1.cni.cncf.io/resourceName`、deviceID)

### Out of scope (留 SP-7b 或不做)
- e2e test framework 細節
- DRA / dynamic resource allocation 整合 (multus v4.2 還沒)
- whereabouts IPAM (獨立 plugin)
- thin entrypoint script 細節 (`thin_entrypoint`)
- cert-approver、kubeconfig_generator 內部
- IP pool 管理 / per-CNI IPAM 細節

## 4 頁切法

### Page 1 — `architecture.mdx`：meta-plugin 與 NAD CRD

**場景**：你在 KubeVirt VM 上同時要 cilium pod network + 一個 SR-IOV 介面接 storage VLAN。kubelet 一次只 invoke 一個 CNI binary，怎麼辦？答：把 multus 當成「the one CNI」，multus 內部再 fan-out 到 cilium + sriov。

- 為什麼 kubelet 一次只 invoke 一個 CNI plugin (CNI spec 限制)
- multus = meta-plugin，sits in the CNI exec path
- NetworkAttachmentDefinition (NAD) CRD 是什麼：把「另一個 CNI 的 config」存進 k8s API
- pod annotation `k8s.v1.cni.cncf.io/networks`: list 要附加的 NAD
- default network vs additional networks
- thin vs thick 部署一句話介紹 (細節在 page 3)

**source code**：
- `cmd/multus/main.go` — thin entry
- `cmd/multus-shim/main.go` — thick CNI binary
- `cmd/multus-daemon/main.go` — thick server
- `pkg/types/types.go:29` — `NetConf`
- `pkg/types/types.go:130` — `NetworkSelectionElement` (annotation 解析後的型別)
- `deployments/multus-daemonset-thick.yml` — daemonset 部署

### Page 2 — `delegate-and-cmdadd.mdx`：delegate 機制與 CmdAdd flow

**場景**：Pod 帶 annotation `k8s.v1.cni.cncf.io/networks: "macvlan-conf,sriov-net"`。multus 收到 kubelet 的 ADD，怎麼把這變成兩個額外 interface？

- `pkg/k8sclient/k8sclient.go` 解析 annotation → `[]NetworkSelectionElement`
- 對每個 element 查 NAD CRD 拿 raw CNI config → 包成 `DelegateNetConf`
- `pkg/multus/multus.go:742` `CmdAdd` 主流程
- `DelegateAdd` (`multus.go:396`) 用 libcni `invoke.DelegateAdd` 呼叫實際 CNI binary
- master plugin (default network) 的 result 才是回給 kubelet 的 (其他附加網路只進 network-status)
- error handling: 第 N 個 delegate 失敗時 reverse-call DEL on 0..N-1
- `CmdDel` 反向

**source code**：
- `pkg/multus/multus.go:396` `DelegateAdd`
- `pkg/multus/multus.go:565` `DelegateDel`
- `pkg/multus/multus.go:601` `delPlugins`
- `pkg/multus/multus.go:742` `CmdAdd`
- `pkg/multus/multus.go:1002` `CmdDel`
- `pkg/types/types.go:100` `DelegateNetConf`
- `pkg/k8sclient/k8sclient.go:222` `parsePodNetworkAnnotation`
- `pkg/k8sclient/k8sclient.go:448` `GetNetworkDelegates`

### Page 3 — `thick-shim-and-daemon.mdx`：thick mode 為什麼存在

**場景**：thin mode 每個 Pod ADD/DEL 都要 multus binary 自己連 apiserver 查 NAD/Pod，high churn cluster 把 apiserver 打爆。怎麼辦？

- thin mode 的痛點: 每次 CNI invocation = 一次 apiserver round trip
- thick mode：CNI 階段用 `multus-shim` (極小 binary 只做「把 args 打包成 HTTP」)，daemon 跑 in DaemonSet 持續持有 informer cache
- Unix socket at `/run/multus/multus.sock`
- HTTP endpoints `/cni`、`/delegate`、`/healthz`、`/readyz`
- `pkg/server/api/shim.go:48` shim 端 `CmdAdd` (POST 到 socket)
- `pkg/server/server.go:87` daemon 端 `HandleCNIRequest`
- daemon 啟動 pod & NAD informer (`server.go:168` `newNetDefInformer`、`server.go:183` `newPodInformer`)
- chroot 機制 (daemon 在 daemonset Pod 內，但 CNI exec 要看到 host 的 `/opt/cni/bin`)

**source code**：
- `cmd/multus-shim/main.go` — shim binary
- `cmd/multus-daemon/main.go` — daemon binary
- `pkg/server/server.go:87` `HandleCNIRequest`
- `pkg/server/server.go:219` `NewCNIServer`
- `pkg/server/server.go:365` `Start`
- `pkg/server/api/api.go:39` `MultusCNIAPIEndpoint = "/cni"`
- `pkg/server/api/socket.go:26` `SocketPath`
- `pkg/server/api/shim.go:48` shim CmdAdd
- `pkg/server/exec_chroot.go` — chroot 執行 delegate

### Page 4 — `k8s-integration-and-status.mdx`：annotation、NAD、狀態回寫

**場景**：你 Pod 起來了，外部 (kubectl get pod -o yaml、observability tool) 要怎麼知道 Pod 有幾個 interface 各自分到什麼 IP？

- pod annotation 兩個方向：
  - input: `k8s.v1.cni.cncf.io/networks` (要附加哪些 NAD)
  - output: `k8s.v1.cni.cncf.io/network-status` (附加完的結果)
- annotation 簡寫格式 `<namespace>/<name>@<interface>` vs JSON 格式
- NAD `spec.config` 是 raw CNI config string (不是 yaml — 是 stringified JSON)
- `SetPodNetworkStatusAnnotation` 把 delegate 的 result 寫回 pod
- SR-IOV 整合：NAD annotation `k8s.v1.cni.cncf.io/resourceName` 對到 device-plugin allocation；deviceID 從 PCI 分配傳到 delegate
- 與 cilium 的接點：cilium 通常做 default network，multus 把 SR-IOV 之類加在 secondary

**source code**：
- `pkg/k8sclient/k8sclient.go:51` annotation key constants (`networkAttachmentAnnot`)
- `pkg/k8sclient/k8sclient.go:139` `SetPodNetworkStatusAnnotation`
- `pkg/k8sclient/k8sclient.go:175` `parsePodNetworkObjectName` (簡寫格式 parser)
- `pkg/k8sclient/k8sclient.go:222` `parsePodNetworkAnnotation`
- `pkg/k8sclient/k8sclient.go:291` `getKubernetesDelegate` (NAD → DelegateNetConf)

## Quiz (5 題)

1. multus 是 meta-plugin。為什麼一個 CNI plugin 還要 wrap 其他 CNI plugin？kubelet 不能自己 invoke N 個 CNI 嗎？
2. NAD CRD `spec.config` 內存的是什麼？為什麼是 string 不是 typed yaml？
3. thick mode 比 thin mode 多了 multus-daemon DaemonSet。換來什麼？(提示: apiserver load)
4. Pod 帶 `k8s.v1.cni.cncf.io/networks: "sriov-net"`。multus 收到 ADD 之後怎麼知道 sriov-net 對應的 CNI config？
5. 你 Pod 有 cilium (default) + macvlan + sriov 三個 interface，回給 kubelet 的 CNI Result 用哪個 delegate 的 result？其他兩個的資訊跑哪去？

## ProjectMeta

- id: `multus`
- displayName: Multus CNI
- color: `green` (orange/blue/purple/teal/rose 已被佔走)
- 4 features (依上述 4 頁)
- featureGroups: 一個 group `network-multiplexing` 包 4 頁
- story: 5 scenes following user 從 KubeVirt VM 需要多介面 → 認識 NAD → 解析 delegate → thick mode → 看 status

## 與其他 SP 的關聯

- **SP-2 (lab)**：Day 18-19 (cilium + KubeVirt) 會用到 multus 給 VM 加儲存網
- **SP-4 (cilium)**：cilium 是 default network，multus 把 cilium 之外的網加上去
- **SP-5 (kubevirt)**：VMI 用 `multus` networks 接多 interface

## 不做的事

- 不寫 thin entrypoint script 細節
- 不寫 dynamic networks API
- 不展開 cert-approver / kubeconfig_generator
- 不細寫 e2e test framework
