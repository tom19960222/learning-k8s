# Loop 1 — Pain Points (Beginner Read)

## kubernetes
1. `next-site/content/kubernetes/features/architecture.mdx:60` — 術語沒鋪陳 — `kube-scheduler` 段落直接出現「predicate + score 算法」，beginner 在 architecture 頁第一次看到，沒任何解釋；建議加一句「過濾 + 排序」白話對照或 forward link 到 controllers 頁。
2. `next-site/content/kubernetes/features/api-server.mdx:104-113` — 圖未交代 — watch fan-out 用純 ASCII art + 一句「in-memory delta-FIFO + multicast」，beginner 不知道 delta-FIFO 是什麼資料結構；建議補一句「就是有順序的 event queue」。
3. `next-site/content/kubernetes/features/controllers.mdx:107` — 章節順序卡 — 突然冒出 `scheduleOnePodGroup` / PodGroup gang scheduling，對 single-pod path 還沒消化的讀者是雜訊；建議搬到「進階補充」或刪掉。
4. `next-site/content/kubernetes/features/kubelet.mdx:139-147` — 要回頭翻第三方資料 — 提到 `crictl` 但沒給最小可跑指令，beginner 想動手驗證得自己 google；建議補 `crictl ps` / `crictl pods` 兩行。
5. `next-site/content/kubernetes/features/cni-plugin-primitives.mdx:43-65` — 術語沒鋪陳 — `netlink`、`tc clsact`、`veth pair`、`bridge` 連續出現，沒交代 netlink 是什麼介面；beginner 卡住。建議在 bridge plugin 章節前加 2 句「netlink = kernel network 設定的 syscall family」。
6. `next-site/content/kubernetes/features/csi-rpc-and-sidecars.mdx:46-56` — quiz 不連動 — sidecar 表列 5 種 sidecar，但 kubernetes/quiz.json 沒有任何題目測這個；CSI 段落只考 controllers 與 architecture，學完無 retention check。
7. `next-site/content/kubernetes/features/kubelet-csi-mount-path.mdx:117-135` — 術語沒鋪陳 — `mount propagation` `rshared` / `rslave` 直接丟，beginner 不知 Linux mount namespace 行為；建議連到 oci-container-primitives 的 mount namespace 段落。

## cilium
1. `next-site/content/cilium/features/architecture.mdx:62-87` — 術語沒鋪陳 — Hive cell DI 段直接寫 `cell.Module`、`Provide`、`Invoke`，beginner 沒寫過 DI framework，看不懂；建議用一行「想成 Spring / wire 的 Go 版」對照熟悉概念。
2. `next-site/content/cilium/features/agent-and-datapath.mdx:99-111` — 要回頭翻第三方資料 — 表格列 `bpf_lxc.c` / `bpf_host.c` / `bpf_xdp.c` / `bpf_overlay.c` / `bpf_sock.c` 與 hook 點 (tc clsact、XDP、cgroup connect4)，但 beginner 沒讀過 eBPF 入門；建議在 architecture 頁先放 1 段「eBPF 是什麼 + tc/XDP/cgroup hook 各自在哪」。
3. `next-site/content/cilium/features/identity-and-policy.mdx:96-114` — 章節順序卡 — L7 proxy redirect 在 PolicyMap 介紹之後立刻登場，但 beginner 還沒消化「per-endpoint BPF map」就被丟進 envoy redirect 細節。建議拆成兩段，中間加一個「先複習 PolicyMap 再進 L7」過場。
4. `next-site/content/cilium/features/hubble-and-observability.mdx:13-23` — 術語沒鋪陳 — `perf event ring buffer` / `BPF perf event array map` 第一次出現沒解釋，beginner 不知道 perf 跟 ring buffer 是 Linux 既有設施；建議補一句「Linux kernel 給 user-space stream event 的標準機制」。
5. `next-site/content/cilium/features/architecture.mdx:137-141` — 圖未交代 — KPR (kube-proxy replacement) 一段純文字描述「啟用後可以停掉 kube-proxy DaemonSet」，沒任何圖示對照；beginner 不知道 KPR 取代了 datapath 哪一段。

## kubevirt
1. `next-site/content/kubevirt/features/architecture.mdx:172-176` — 術語沒鋪陳 — virtctl vnc / console 一段提 `websocket tunneling` / `framebuffer` / `extension API`，beginner 不熟 apiserver aggregation layer，整段 4 跳 proxy 太密；建議拆步驟列表並加圖。
2. `next-site/content/kubevirt/features/controllers.mdx:74-93` — 要回頭翻第三方資料 — `templateService.RenderLaunchManifest` 是 KubeVirt 自己的概念但只用一段 bullet 點過；beginner 不知道進去看什麼。建議補一個最小範例 (VMI YAML → 翻成的 Pod YAML 片段)。
3. `next-site/content/kubevirt/features/virt-handler-and-launcher.mdx:72-81` — 圖未交代 — Pod 內 process tree (`virt-launcher-monitor` / `virt-launcher` / `libvirtd` / `qemu-kvm`) 用 ASCII tree，beginner 不知道每層為何要 fork；只 monitor 那行補了「PID 1 watchdog」，其它三層沒解釋為何不能合併。
4. `next-site/content/kubevirt/features/live-migration.mdx:101-126` — 章節順序卡 — precopy / postcopy / paused fallback 三種策略連續出現在 flag 表後，beginner 還沒消化 `LIVE`/`PEER2PEER`/`AUTO_CONVERGE` flag 就被丟進策略對比；建議先講「為什麼會不收斂」再進策略表。
5. `next-site/content/kubevirt/features/topology-spread-constraints.mdx:46-50` — 術語沒鋪陳 — 一開頭就要求讀者懂 Kubernetes scheduler 的 `labelSelector` 與 Pod label 機制，但這頁掛在 KubeVirt block 而不是 Kubernetes block；beginner 從 KubeVirt 入門路線進來會卡。
6. `next-site/content/kubevirt/features/windows-vm-features.mdx:181-211` — 要回頭翻第三方資料 — 11 個 Hyper-V enlightenment 各自一段解釋（`relaxed` / `vapic` / `synic` / `synictimer` ...），beginner 不熟 Windows kernel / Hyper-V 用語，需要邊讀邊查 MSDN；建議在頁首先放一張「哪些是基礎、哪些是進階、哪些只 nested 用」的分群表。

## ceph
1. `next-site/content/ceph/features/architecture.mdx:36-44` — 術語沒鋪陳 — MON 段第一次提 `Paxos quorum`，beginner 沒讀過 distributed consensus paper；建議用一句「過半投票才算數」白話釋義並 forward link 到 advanced 段。
2. `next-site/content/ceph/features/crush-and-placement.mdx:84-95` — 要回頭翻第三方資料 — `straw2` 算法那段只說「ln(uniform random)/weight, 挑最大」一行 C 註解，沒給直覺；beginner 不會理解為何這樣能 stable。建議補 1 段「跟 modular hash 對比，加 item 影響哪些 PG」白話。
3. `next-site/content/ceph/features/osd-and-bluestore.mdx:181-200` — 章節順序卡 — BlueFS 出現在 Allocator 之後但 RocksDB 之前，beginner 不懂 RocksDB 為何需要 filesystem，會跟 Allocator 混淆；建議調成 RocksDB → 為何需要 BlueFS → Allocator 順序。
4. `next-site/content/ceph/features/rbd-and-csi.mdx:71-97` — 圖未交代 — `class extension` 機制、`cls_rbd.cc` server-side class 段落沒圖；beginner 不知道 class 是 OSD load 的 .so，跟 client lib 的關係模糊。建議加一張「client lib ↔ OSD class .so」對照圖。
5. `next-site/content/ceph/features/architecture.mdx:165-168` — quiz 不連動 — rook 與 ceph-csi 在最後簡介一段，但 ceph/quiz.json 完全沒考；beginner 看完無 retention check。建議補 1 題「rook 與 ceph-csi 的職責邊界」。

## multus-cni
1. `next-site/content/multus/features/architecture.mdx:155-173` — 術語沒鋪陳 — thin / thick mode 對比表第一次提 `informer cache`，beginner 從 KubeVirt/cilium 線過來不一定看過 kubernetes/controllers 頁；建議加一個 forward link 或一句白話「daemon 持有一份 in-memory pod 清單」。
2. `next-site/content/multus/features/delegate-and-cmdadd.mdx:50-69` — 要回頭翻第三方資料 — `DelegateNetConf` struct 11 個欄位，beginner 看 `IfnameRequest` / `MasterPlugin` / `ConfListPlugin` / `DeviceID` / `ResourceName` 不知何者重要；建議標星號分「core / SR-IOV-only / advanced」。
3. `next-site/content/multus/features/thick-shim-and-daemon.mdx:200-225` — 章節順序卡 — `chroot exec` 跳出來在 `/delegate endpoint` 與部署 yaml 之間，beginner 還沒消化「為何 chroot」就被丟去看 SysProcAttr；建議移到部署 yaml 之後一起談 mount layout。
4. `next-site/content/multus/features/k8s-integration-and-status.mdx:152-211` — 術語沒鋪陳 — SR-IOV 段落直接出現 `device-plugin` / `PodResources gRPC` / `kubelet.sock`，beginner 沒讀過 kubelet device plugin 文件；建議在前面 architecture 頁加 1 段 sidebar「device-plugin 是什麼」。
5. `next-site/content/multus/features/delegate-and-cmdadd.mdx:225-230` — quiz 不連動 — `CmdGC` (CNI v1.1 GC) 段落只 6 行，但 multus/quiz.json 完全沒測 GC 行為；學完無 retention，建議補一題或改放 advanced 區。

## learning-plan
1. `next-site/content/learning-plan/features/day-09.mdx:67-77` — 章節順序卡 — Day 9 才開始 `cilium bpf endpoint list`，但 Day 8 還沒講 BPF map / endpoint identity 心智模型；建議 Day 8 末加一段預習或交叉連到 cilium/agent-and-datapath。
2. `next-site/content/learning-plan/features/day-14.mdx:38-78` — 術語沒鋪陳 — Day 14 一上來叫讀者 `grep "func cmdAdd" multus.go`，但前面 30 天都沒讀過原始碼，這是第一次「讀 Go source」；建議在 Day 14 開頭花 5 行教 beginner 怎麼定位函式 (gopls / IDE)。
3. `next-site/content/learning-plan/features/day-18.mdx:39-72` — 要回頭翻第三方資料 — `ceph auth get-or-create` / `profile rbd` / `ceph fsid` / `ceph mon dump` 連續出現，beginner 沒讀過 ceph CLI 手冊；建議連到 ceph/architecture 並補一句「`profile rbd` = MON 端預設 RBD 操作 cap」。
4. `next-site/content/learning-plan/features/day-27.mdx:140-167` — 圖未交代 — live migration memory dirty page tracking 6 個步驟用純文字編號列出，沒有時間軸圖；beginner 不知道 cutover 那刻 source/target 是同時暫停還是序列；建議交叉連到 kubevirt/live-migration 的 precopy 段落。
5. `next-site/content/learning-plan/features/day-01.mdx:21-50` — 術語沒鋪陳 — 「3 節點 Proxmox VE 9.0 cluster + 3 節點 k8s 1.36」當作前置條件，beginner 如果還沒裝完整 lab 環境就無法跑指令；建議在 Day 0 / 計畫首頁明確指引「沒環境的人怎麼用 kind 走完前 7 天」。
6. `next-site/content/learning-plan/features/day-30.mdx:23-39` — quiz 不連動 — Day 30 整合 demo 把 7 個元件串起來，但 learning-plan/quiz.json 沒題目測「整段 datapath 跨幾層」；30 天最後一天的 retention check 缺。

## 跨 project 共通主題
- **「術語首次出現未鋪陳」**：`Paxos quorum`、`Hive cell DI`、`netlink/tc clsact`、`mount propagation`、`PodResources gRPC`、`device-plugin` 都在 beginner 第一次接觸時就被當已知，跨 5 個 project 都出現。建議每個 project 第一頁建立「會用到的外部術語」glossary。
- **「圖示密度不夠 / 純 ASCII art 無時間軸」**：watch fan-out、KPR 取代、live migration cutover、Pod 內 process tree 都需要時間軸或 swimlane 圖；現有 ASCII art 表達不出「同時」「序列」差別。
- **quiz 不連動**：CSI sidecars、rook vs ceph-csi、multus GC、Day 30 平台整合、KubeVirt windows-vm-features 都是內容深但 quiz 沒對應題；學完無 retention check。建議每頁至少 1 quiz。
