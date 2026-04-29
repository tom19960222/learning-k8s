---
date: 2026-04-30
project: cilium
version: v1.19.3
status: approved
---

# SP-4: cilium v1.19.3 first-wave MVP — design

## 目的

把 cilium v1.19.3 的內部運作壓成 4 個可讀的分析頁，足夠讓 SP-2 30 天 lab 的第二週 (Day 8-14: cilium + multus) 有原始碼可對照。沿用 SP-3 (kubernetes) 的形狀：架構總覽 + 3 個切面，每頁的 function name 與 file path 都用 grep 在 v1.19.3 tag 上驗證過。

## 範圍（YAGNI）

只做 first-wave MVP。下列**不**包含：

- BGP 控制平面 (`pkg/bgp/`)
- Cluster Mesh / multi-cluster (`clustermesh-apiserver/`)
- WireGuard 加密 (`bpf_wireguard.c`)
- Egress Gateway (`pkg/egressgateway/`)
- Service Mesh / Envoy 整合細節 (只在 L7 policy 提到 proxy 機制)
- KPR (kube-proxy replacement) 詳細路徑 — 只在 architecture 提一句

第二波 (SP-4b) 要不要做這些之後再決定。

## 4 頁切法

選擇 **component-oriented**：先看誰是誰，再看每個 component 在做什麼。理由：cilium 比 kubernetes 更「黏」(eBPF 跨 control/data plane)，按 component 切比按 layer 切更容易抓邊界。

### 頁 1：`architecture.mdx`（控制平面架構）

**核心問題**：`kubectl apply -f cnp.yaml` (CiliumNetworkPolicy) → policy 真的生效，誰做了什麼？

**內容大綱**：

- 整體 process map：
  - **cilium-agent** — DaemonSet，每 node 一個，做 endpoint regeneration、bpf compile/load、policy compute、CNI 後端
  - **cilium-operator** — 1 個 (HA leader-elected)，負責 cluster-wide 工作 (IP allocation、CRD 同步、garbage collection)
  - **hubble-relay** — 可選，把 N 個 node 的 hubble gRPC aggregate 起來
  - **CNI plugin** — `/opt/cni/bin/cilium-cni`，被 containerd 呼叫，透過 unix socket 跟 cilium-agent 對話
- 為什麼 cilium 用 **Hive cell DI** 而不是直接 main.go：`pkg/<feature>/cell.go` pattern、依存圖、shutdown order。daemon `cells.go` 是入口
- `kubectl apply CNP` → operator/agent 流程 (簡述，policy 細節留到頁 3)
- 跟 kube-proxy 的關係：cilium 可以做 KPR (kube-proxy replacement)，提到不展開

**關鍵 file/symbol**：

- `daemon/cmd/daemon_main.go` — agent main
- `daemon/cmd/cells.go` — Hive cell graph 入口
- `operator/cmd/root.go` — operator main
- `plugins/cilium-cni/main.go` — CNI binary
- 概念對照：[`hive`](https://github.com/cilium/hive) 是 cilium 自己抽出來的 DI library

### 頁 2：`agent-and-datapath.mdx`（Pod → eBPF 的旅程）

**核心問題**：新 Pod 起來，cilium 怎麼把它變成可被 forwarding 的 endpoint？bpf programs 是怎麼 compile 加載到 kernel？

**內容大綱**：

- **CNI ADD** flow：containerd 呼 cilium-cni → 透過 unix socket 跟 agent 對話 → agent 建 endpoint object
- **Endpoint regeneration** loop (`pkg/endpoint/policy.go:759` `Endpoint.Regenerate`)：每個 endpoint 自己一個 sync goroutine
- **BPF datapath dynamic compile + template cache**：
  - cilium 不是「載入 prebuilt .o」——它根據 endpoint 的 ID/identity/options 算 `datapathHash`，去 `objectCache` 找 template (`pkg/datapath/loader/cache.go`)；hit → 重用編譯後 .o，miss → 產生 header file，invoke clang 編譯 `bpf/bpf_lxc.c` 寫進 cache
  - 同 config 的多個 endpoint 共用同一份 template object；config 不同才會多編
  - `compileDatapath` (`pkg/datapath/loader/compile.go:254`) 與 `compileWithOptions` (line 310)
  - `objectCache` (`pkg/datapath/loader/cache.go:27`) 與 `fetchOrCompile` (line 174)
- **eBPF programs 種類**：
  - `bpf_lxc.c` — per-pod tc ingress/egress (掛在 veth)
  - `bpf_host.c` — host network namespace 的 ingress/egress
  - `bpf_xdp.c` — XDP early drop / LB
  - `bpf_overlay.c` — vxlan tunnel encap/decap
  - `bpf_sock.c` — socket-based service LB (取代 iptables DNAT)
- **Attach** 到 tc qdisc：透過 netlink，see `pkg/datapath/loader/loader.go`
- 整段流程圖：CNI ADD → endpoint create → policy compute → BPF compile → object load → tc attach → Pod 可通訊

**關鍵 file/symbol**：

- `pkg/endpoint/policy.go:759` — `Endpoint.Regenerate`
- `pkg/datapath/loader/compile.go:254` — `compileDatapath`
- `pkg/datapath/loader/compile.go:310` — `compileWithOptions`
- `pkg/datapath/loader/cache.go:27` — `objectCache` (template cache)
- `pkg/datapath/loader/cache.go:174` — `fetchOrCompile`
- `bpf/bpf_lxc.c` — per-pod datapath
- `bpf/bpf_host.c` — host datapath
- `bpf/bpf_xdp.c` — XDP

### 頁 3：`identity-and-policy.mdx`（label → identity → BPF map）

**核心問題**：cilium policy 為什麼能不靠 IP？SecurityIdentity 跟 label 的關係是什麼？policy decision 怎麼變成 kernel 內的 BPF map?

**內容大綱**：

- **SecurityIdentity** = label set 的雜湊。`pkg/identity/identity.go:27` `Identity` struct，含 `NumericIdentity` (16-bit, 全 cluster 唯一) 與 `Labels`
  - 兩個 Pod 同 label → 同 identity；換 IP 不影響
  - reserved identities (`pkg/identity/reserved.go`)：`world`、`host`、`init`、`unmanaged` 等
  - allocator (`pkg/identity/cache/cache.go`)：從 kvstore (etcd / k8s) 拿 identity → numeric ID 對應
- **Policy compute**：
  - 來源：standard `NetworkPolicy` + cilium 自己的 `CiliumNetworkPolicy` (CNP) / `CiliumClusterwideNetworkPolicy`
  - agent watch 這些 CRD，對每個 endpoint 算出「這個 endpoint 對其他 identity 各自允許哪些 (port, proto, L7 redirect)」
  - 結果由 endpoint regeneration 寫進 PolicyMap (per-endpoint BPF hash map)
- **PolicyMap 結構** (`pkg/maps/policymap/policymap.go:107` `PolicyKey` / line 155 `PolicyEntry`)：
  - key = `(identity, dest_port, proto, direction[, port_prefix_len])`
  - value = `(flags: deny? proxy_port?)`
  - bpf_lxc.c 在 forwarding 時對這個 map 做 lookup
- **L7 policy**：
  - DNS / HTTP 規則 → policy 中 `proxy_port != 0`
  - bpf_lxc.c 看到 proxy_port → redirect 到 host 的 cilium-agent (envoy 或 built-in proxy) → proxy 解析後決定 allow/deny
  - DNS proxy 還會把回應 IP 寫進 ipcache (對應 identity)
- **FQDN policy** (`pkg/fqdn/`)：CNP 寫 `toFQDNs: ["github.com"]` → DNS proxy 攔截解析結果 → 把 IP 加進 ipcache 並關聯 identity

**關鍵 file/symbol**：

- `pkg/identity/identity.go:27` — `Identity`
- `pkg/identity/reserved.go` — reserved identities
- `pkg/identity/cache/cache.go` — identity allocator
- `pkg/maps/policymap/policymap.go:107` — `PolicyKey`
- `pkg/maps/policymap/policymap.go:155` — `PolicyEntry`
- `pkg/policy/` — policy compute
- `pkg/fqdn/` — FQDN proxy

### 頁 4：`hubble-and-observability.mdx`（每個 packet 變成 Flow event）

**核心問題**：`hubble observe` 看到的 flow 是怎麼從 kernel datapath 出來的？多 node aggregate 怎麼做的？

**內容大綱**：

- **datapath 裡的 trace point**：
  - bpf_lxc.c 在 ingress/egress 關鍵點 (drop, forward, policy verdict) call `send_trace_notify` → 寫 perf event ring buffer
  - perf event ring 是 kernel-userspace 共享 memory，不阻塞 forwarding
- **monitor agent** (`pkg/monitor/agent/agent.go`)：
  - `AttachToEventsMap` (line 106) 開 perf reader
  - `processPerfRecord` (line 376) 讀出來 fan-out 給 consumers
  - `RegisterNewConsumer` (line 285) — 任何 component 想看 datapath 事件就在這註冊
- **Hubble 註冊為 consumer** (`pkg/hubble/cell/hubbleintegration.go:208` `launch`)：
  - 接 monitor 的 raw event → `parser` 解出 flow (5-tuple, identity, verdict)
  - 存在 in-memory ring buffer (有限長度)
  - 起 gRPC server (`pkg/hubble/observer/`) 提供 `Observe` / `GetFlows` API
- **hubble-relay**：
  - 獨立 process，去 N 個 node 的 hubble agent 拉 stream
  - aggregate 後給 `hubble` CLI 或 Hubble UI
- **觀測不影響 forwarding**：所有事件走 perf event 旁路；agent 重啟不會掉封包，但會掉 event window

**關鍵 file/symbol**：

- `pkg/monitor/agent/agent.go:106` — `AttachToEventsMap`
- `pkg/monitor/agent/agent.go:376` — `processPerfRecord`
- `pkg/monitor/agent/agent.go:285` — `RegisterNewConsumer`
- `pkg/hubble/cell/hubbleintegration.go:208` — Hubble launch
- `pkg/hubble/observer/` — gRPC server
- `bpf/lib/trace.h` — `send_trace_notify` macro (datapath 內)

## Quiz 設計（5 題）

針對前述 4 頁的關鍵 mental model，每題 4 選項，正解寫足解釋。題目意圖：

1. **Hive cell DI 為什麼存在** — 對比直接 main.go 寫所有依賴，cell 解決什麼問題（依存解析、shutdown order）
2. **endpoint regeneration 與 BPF template cache** — cilium 多一步 BPF compile，但同 config 的 endpoint 透過 hash-based template cache 共用 .o，不是真的「per-endpoint 重編」
3. **SecurityIdentity ≠ IP** — 換 IP 不影響 identity 的關鍵點
4. **PolicyMap 是 per-endpoint BPF map** — 不是 cluster-wide table；每個 endpoint 自己一份
5. **Hubble 沒在 fast path** — 為什麼觀測不會影響 forwarding 性能（perf event ring 旁路）

## 驗證等級

- 所有 function name / line number → 用 `grep -n` 在 `cilium/` submodule 的 v1.19.3 tag 上跑過
- bpf C source 引用 → 直接 `ls bpf/` 與 `grep` 確認檔名與 macro 存在
- 無 lab 命令；不需要 cluster 驗證

## 跟現有 SP 的接點

- `next-site/lib/projects.ts`：在 `PROJECTS` 加 `cilium` 條目，4 個 features (architecture / agent-and-datapath / identity-and-policy / hubble-and-observability)
- `next-site/content/cilium/quiz.json` 5 題
- learning-plan Day 8-14 的「對應原始碼」連結指到這 4 頁
- `versions.json` 加 `cilium` 條目記錄 commit/tag

## 不做的事

- 不寫 mermaid 圖；圖一律 ASCII 或之後補 PNG
- 不複製 Cilium 官網既有的高層 marketing 圖；要寫就寫到 function 那層
- 不放 lab 命令；lab 在 SP-2 day-pages 已寫
- 不對 KPR / Cluster Mesh / Service Mesh 展開（留 SP-4b）
