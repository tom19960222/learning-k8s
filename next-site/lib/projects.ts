import path from 'path'

export type ProjectId = string

export interface LearningPathStep {
  slug: string
  note: string
}

export interface FeatureGroup {
  label: string
  icon: string
  slugs: string[]
}

export interface StoryScene {
  step: number
  icon: string
  actor: string
  action: string
  detail: string
}

export interface ProjectStory {
  protagonist: string
  challenge: string
  scenes: StoryScene[]
  outcome: string
}

export interface ProjectMeta {
  id: ProjectId
  displayName: string
  shortName: string
  description: string
  githubUrl: string
  submodulePath: string
  color: string
  accentClass: string
  features: string[]
  featureGroups: FeatureGroup[]
  usecases: string[]
  difficulty: '🟢 入門' | '🟡 中階' | '🔴 進階'
  difficultyColor: string
  problemStatement: string
  story: ProjectStory
  learningPaths: {
    beginner: LearningPathStep[]
    intermediate: LearningPathStep[]
    advanced: LearningPathStep[]
  }
}

const REPO_ROOT = path.join(process.cwd(), '..')
export { REPO_ROOT }

// Registered projects. SP-2 added learning-plan; SP-3..SP-7 will add the others.
export const PROJECTS: Record<ProjectId, ProjectMeta> = {
  'learning-plan': {
    id: 'learning-plan',
    displayName: '30 天 Hands-on Lab',
    shortName: 'Lab',
    description: '30 天動手實驗計畫，從 k8s 內部 → cilium/multus → ceph → kubevirt，最終建立可用的 VM 平台',
    githubUrl: '',
    submodulePath: '',
    color: 'amber',
    accentClass: 'border-amber-500 text-amber-400',
    features: [
      'day-01','day-02','day-03','day-04','day-05','day-06','day-07',
      'day-08','day-09','day-10','day-11','day-12','day-13','day-14',
      'day-15','day-16','day-17','day-18','day-19','day-20','day-21',
      'day-22','day-23','day-24','day-25','day-26','day-27','day-28','day-29','day-30',
    ],
    featureGroups: [
      { label: 'Week 1 — Kubernetes 內部', icon: '⚙️', slugs: ['day-01','day-02','day-03','day-04','day-05','day-06','day-07'] },
      { label: 'Week 2 — cilium + multus', icon: '🌐', slugs: ['day-08','day-09','day-10','day-11','day-12','day-13','day-14'] },
      { label: 'Week 3 — ceph + rook', icon: '💾', slugs: ['day-15','day-16','day-17','day-18','day-19','day-20','day-21'] },
      { label: 'Week 4+ — kubevirt 整合', icon: '🖥️', slugs: ['day-22','day-23','day-24','day-25','day-26','day-27','day-28','day-29','day-30'] },
    ],
    usecases: [],
    difficulty: '🟡 中階',
    difficultyColor: 'text-yellow-400 bg-yellow-400/10 border-yellow-400/30',
    problemStatement: '會用 kubectl 不等於懂 k8s。30 天裡，我們從 control plane 拆解開始，逐步加上 CNI、CSI、虛擬化層，最後親手建一個可以跑 VM 的 KubeVirt 平台。每天 1-3 小時，週五完成一個小目標。',
    story: {
      protagonist: '🧑‍💻 平台工程師 你自己',
      challenge: '公司裡其他 SRE 都會 kubectl，但要說明「Service 為什麼能 routing」、「kubelet 怎麼跟 containerd 對話」、「KubeVirt VM live migration 真實在搬什麼」時，你卡住了。讀了一堆部落格還是只懂「會用」，不懂「為什麼」。',
      scenes: [
        { step: 1, icon: '🔍', actor: '你', action: 'Day 1：第一次 ssh 進 control plane node，發現 kube-apiserver 是個 static Pod', detail: '原來不是神秘的 systemd service，是 kubelet 從 /etc/kubernetes/manifests/ 讀 yaml 起的 Pod。從這一刻開始，控制平面的神秘感消散。' },
        { step: 2, icon: '⚙️', actor: '你', action: 'Day 7：自己寫了第一個 ConfigMap watcher controller', detail: '之前覺得 Operator 是黑魔法，今天親手用 controller-runtime 寫了一個。Reconcile() 被觸發的時機、informer 的 cache、work queue 的 rate limit — 全是源於熟悉的 Go pattern。' },
        { step: 3, icon: '🚀', actor: '你', action: 'Day 14：用 cilium 看到 eBPF prog 在 cilium monitor 裡跳出 trace event', detail: '網路不再是 iptables 黑盒。eBPF program、BPF map、verifier — 在 cilium-agent 裡看到原始的指令層追蹤。' },
        { step: 4, icon: '💾', actor: '你', action: 'Day 18：第一個 ceph-csi PVC bind 成功，VM 拿到 RBD 磁碟', detail: '從 ceph 的 CRUSH placement 到 k8s PVC 的 bind 流程，原本各自獨立的兩塊知識在這一天連起來。' },
        { step: 5, icon: '✈️', actor: '你', action: 'Day 27：成功觸發 live migration，downtime 187ms', detail: 'virt-handler 把 memory dirty page 一輪一輪追上，直到 cutover。看著 metrics 從 source node 跳到 target node，明白 KubeVirt 為什麼是「VM in container」而不是 vSphere 翻版。' },
      ],
      outcome: 'Day 30 你的 cluster 上跑著一台 web service VM：ceph-csi RBD 磁碟、multus 接外部網路、kubectl 一個指令就能 live migrate。從 control plane 到 KubeVirt 整條鏈路你都拆過，再也沒有黑盒。',
    },
    learningPaths: {
      beginner: [
        { slug: 'day-01', note: '從巡禮控制平面元件開始，建立整體圖像' },
        { slug: 'day-04', note: '用最熟悉的 ReplicaSet 觀察 reconcile loop' },
        { slug: 'day-07', note: '自己寫一個 controller，理解 operator 不是魔法' },
      ],
      intermediate: [
        { slug: 'day-09', note: '用 cilium monitor 看到實際 eBPF trace event' },
        { slug: 'day-18', note: 'ceph-csi 把 ceph 的 CRUSH 和 k8s 的 PVC 連起來' },
        { slug: 'day-27', note: 'KubeVirt live migration 的 memory copy 機制' },
      ],
      advanced: [
        { slug: 'day-14', note: '讀 multus delegate flow 原始碼' },
        { slug: 'day-20', note: 'Rook operator 的 reconcile loop 拆解' },
        { slug: 'day-30', note: '把所有元件整合成一個可用平台的 demo' },
      ],
    },
  },
  'kubernetes': {
    id: 'kubernetes',
    displayName: 'Kubernetes',
    shortName: 'K8s',
    description: '容器編排平台本體：4 個 control plane process + kubelet + kube-proxy 構成的分散式系統',
    githubUrl: 'https://github.com/kubernetes/kubernetes',
    submodulePath: path.join(REPO_ROOT, 'kubernetes'),
    color: 'blue',
    accentClass: 'border-blue-500 text-blue-400',
    features: [
      'architecture',
      'api-server',
      'controllers',
      'kubelet',
      'extension-interfaces',
      'runtime-learning-map',
      'oci-container-primitives',
      'cri-runtime-stack',
      'runtime-alternatives',
      'cni-learning-map',
      'pod-network-lifecycle',
      'cni-plugin-primitives',
      'node-ipam-and-flannel',
      'pod-to-pod-datapath',
      'csi-learning-map',
      'storage-api-and-binding',
      'csi-rpc-and-sidecars',
      'kubelet-csi-mount-path',
    ],
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: '控制平面', icon: '🧠', slugs: ['api-server', 'controllers'] },
      { label: 'Node 端', icon: '🖥️', slugs: ['kubelet'] },
      { label: 'Runtime 與擴充介面', icon: '🧩', slugs: ['extension-interfaces', 'runtime-learning-map', 'oci-container-primitives', 'cri-runtime-stack', 'runtime-alternatives'] },
      { label: 'CNI 與 Pod 網路', icon: '🌐', slugs: ['cni-learning-map', 'pod-network-lifecycle', 'cni-plugin-primitives', 'node-ipam-and-flannel', 'pod-to-pod-datapath'] },
      { label: 'CSI 與 Volume', icon: '💾', slugs: ['csi-learning-map', 'storage-api-and-binding', 'csi-rpc-and-sidecars', 'kubelet-csi-mount-path'] },
    ],
    usecases: [],
    difficulty: '🟡 中階',
    difficultyColor: 'text-yellow-400 bg-yellow-400/10 border-yellow-400/30',
    problemStatement: '你會用 kubectl 操作 cluster，但 control plane 4 個 process、kubelet、kube-proxy、CRI runtime、CNI、CSI 在背後到底做什麼？API server 收到 request 之後怎麼走進 etcd？scheduler 怎麼挑 node？kubelet 怎麼跟 containerd 對話？Pod IP 是誰分配、誰寫 route、誰做 VXLAN 封裝？PVC Bound 之後，又是誰呼叫 CSI driver 把 volume mount 進 Pod？這個專案從架構切入，逐層拆到 reconcile loop、CRI、CNI、CSI 與 Linux datapath/mount namespace。',
    story: {
      protagonist: '🧑‍💻 平台 SRE 你自己',
      challenge: '會用 kubectl 大半年了，但每次有人問「Service 路由怎麼決定」、「Pod evict 是誰決定的」、「kube-controller-manager 跟 scheduler 為什麼要分開」就答不上來。今天決定從原始碼層面把它徹底拆解。',
      scenes: [
        { step: 1, icon: '🏗️', actor: '你', action: '讀 architecture：先建立完整地圖', detail: '搞清楚 4 個 control plane 元件加 kubelet 加 kube-proxy 各自的工作切面，知道 static Pod 怎麼解決 chicken-and-egg。' },
        { step: 2, icon: '📦', actor: '你', action: '讀 api-server：HTTP request 到 etcd 的全程', detail: '從 handler chain 開始追，看到 admission、storage layer、watch fan-out — 終於理解 apiserver 為何是整個 cluster 的瓶頸點。' },
        { step: 3, icon: '🔄', actor: '你', action: '讀 controllers：reconcile loop 何時被觸發', detail: 'informer cache + work queue + rate limiter 三段式幾乎是所有 k8s controller 的共同骨架。' },
        { step: 4, icon: '🖥️', actor: '你', action: '讀 kubelet：Pod 怎麼變成 container', detail: 'CRI gRPC 介面是 docker、containerd、CRI-O 互換的契約；Pod sandbox 是 network namespace 的擁有者。' },
      ],
      outcome: '從此面對任何 k8s 問題，你能直覺地知道「這該由哪個 process 處理」、「應該去哪段原始碼追」。同事看你 kubectl 的眼神不一樣了。',
    },
    learningPaths: {
      beginner: [
        { slug: 'architecture', note: '先建立全貌再深入單一元件' },
        { slug: 'extension-interfaces', note: '理解 CRI/CNI/CSI/Device Plugin 為什麼是 Kubernetes 的擴充骨架' },
        { slug: 'runtime-learning-map', note: '快速對照 9 篇外部文章與本專案新增內容' },
        { slug: 'cni-learning-map', note: '快速對照 8 篇 CNI 文章與本專案新增內容' },
        { slug: 'csi-learning-map', note: '快速對照 5 篇 CSI 文章與本專案新增內容' },
        { slug: 'controllers', note: '從最直觀的 ReplicaSet reconcile 開始' },
        { slug: 'kubelet', note: '看 Pod 在 node 上的真實長相' },
        { slug: 'pod-network-lifecycle', note: '先釐清 kubelet、CRI runtime、CNI plugin 誰呼叫誰' },
        { slug: 'storage-api-and-binding', note: '先分清 PV/PVC/StorageClass 與 CSI driver 的責任邊界' },
      ],
      intermediate: [
        { slug: 'api-server', note: 'admission chain 與 watch fan-out 是 cluster 觀察的關鍵' },
        { slug: 'controllers', note: '深入 informer / work queue / rate limiter' },
        { slug: 'oci-container-primitives', note: '補齊 OCI、runc、containerd-shim、Linux namespace 的基礎' },
        { slug: 'cri-runtime-stack', note: 'CRI 介面、containerd、CRI-O 與 crictl 除錯路徑' },
        { slug: 'cni-plugin-primitives', note: '從 CNI spec、bridge、veth、host-local IPAM 拆到 Linux network stack' },
        { slug: 'node-ipam-and-flannel', note: '把 controller-manager NodeIPAM 與 flannel subnet.env 串起來' },
        { slug: 'csi-rpc-and-sidecars', note: '拆 CSI Controller/Node/Identity RPC 與 external sidecar 的接線' },
      ],
      advanced: [
        { slug: 'api-server', note: '研究 storage layer 與 etcd 互動細節' },
        { slug: 'controllers', note: 'leader election、shared informer、跨 controller 的 ownership chain' },
        { slug: 'kubelet', note: 'CRI 之外：device plugin、CNI、CSI 的整合面' },
        { slug: 'runtime-alternatives', note: '用 RuntimeClass、gVisor、Kata、KubeVirt 分析隔離與 VM workload 取捨' },
        { slug: 'pod-to-pod-datapath', note: '從 route、ARP、FDB、VXLAN 拆跨節點 Pod-to-Pod 封包路徑' },
        { slug: 'kubelet-csi-mount-path', note: '從 kubelet volume manager 追到 NodePublishVolume、NFS mount 與 mount propagation' },
      ],
    },
  },
  'cilium': {
    id: 'cilium',
    displayName: 'Cilium',
    shortName: 'Cilium',
    description: 'eBPF-based CNI 與 service mesh：把 networking、observability、policy 全部 push 進 kernel datapath',
    githubUrl: 'https://github.com/cilium/cilium',
    submodulePath: path.join(REPO_ROOT, 'cilium'),
    color: 'teal',
    accentClass: 'border-teal-500 text-teal-400',
    features: ['architecture', 'agent-and-datapath', 'identity-and-policy', 'hubble-and-observability'],
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: '控制平面 + datapath', icon: '⚙️', slugs: ['agent-and-datapath'] },
      { label: 'Policy 模型', icon: '🛡️', slugs: ['identity-and-policy'] },
      { label: '觀測性', icon: '🔭', slugs: ['hubble-and-observability'] },
    ],
    usecases: [],
    difficulty: '🔴 進階',
    difficultyColor: 'text-red-400 bg-red-400/10 border-red-400/30',
    problemStatement: 'iptables 早就撐不住現代 cluster 的 service / policy 數量，但 eBPF 又像黑魔法。Cilium 把 datapath、policy、observability 全用 eBPF 實作 — 這 4 頁從原始碼層拆開：cilium-agent 怎麼把 Pod 變成 endpoint、SecurityIdentity 怎麼取代 IP、Hubble 為什麼觀測不影響 forwarding。',
    story: {
      protagonist: '🧑‍💻 平台 SRE 你自己',
      challenge: '上次 cluster 裡 iptables 規則破萬，conntrack 開始爆掉。聽說 cilium 用 eBPF 取代整套 — 但 BPF 對你還是黑盒。今天決定從 cilium-agent 的 main 函式開始追到 kernel BPF program，把 cilium 拆透。',
      scenes: [
        { step: 1, icon: '🏗️', actor: '你', action: '讀 architecture：先搞清楚誰是誰', detail: 'cilium-agent (per-node) / cilium-operator (cluster-wide) / hubble-relay (aggregator) 各自的職責邊界，以及 Hive cell DI 為什麼是 cilium 的核心 pattern。' },
        { step: 2, icon: '⚙️', actor: '你', action: '讀 agent-and-datapath：BPF 從哪來', detail: 'endpoint regeneration loop、clang 動態 compile bpf_lxc.c、template cache 共用 .o、tc qdisc attach — 從 Go 那層追到 .c 那層。' },
        { step: 3, icon: '🛡️', actor: '你', action: '讀 identity-and-policy：label 怎麼變 policy decision', detail: 'SecurityIdentity 是 label set 的雜湊；PolicyMap 是 per-endpoint BPF hash map，bpf_lxc.c 直接 lookup。L7 / FQDN policy 透過 proxy_port redirect 到 user-space proxy。' },
        { step: 4, icon: '🔭', actor: '你', action: '讀 hubble-and-observability：trace event 從哪冒出來', detail: 'datapath send_trace_notify 寫 perf event ring → monitor agent 讀出來 fan-out → Hubble parse 成 Flow → gRPC server。觀測完全旁路，不在 fast path。' },
      ],
      outcome: '從此 cilium-agent 不是黑盒。你可以指出某個 packet drop 是 PolicyMap 拒的還是 routing 沒到，知道為什麼換 IP 不會破壞 policy，也理解 Hubble 為何能不影響性能地觀測每個 flow。',
    },
    learningPaths: {
      beginner: [
        { slug: 'architecture', note: '先建立全貌：3 個 process + Hive cell DI' },
        { slug: 'hubble-and-observability', note: '從 hubble observe 反推 datapath，最容易動手' },
        { slug: 'identity-and-policy', note: '理解 cilium 的 policy model 跟 NetworkPolicy 差在哪' },
      ],
      intermediate: [
        { slug: 'agent-and-datapath', note: 'endpoint regeneration + BPF 動態 compile' },
        { slug: 'identity-and-policy', note: '深入 PolicyMap 與 L7 proxy redirect' },
        { slug: 'hubble-and-observability', note: '從 perf event ring 到 Flow 的 parser pipeline' },
      ],
      advanced: [
        { slug: 'agent-and-datapath', note: '研究 bpf_lxc.c / bpf_host.c 與 template cache 的互動' },
        { slug: 'identity-and-policy', note: 'FQDN policy + DNS proxy 與 ipcache 的 race condition' },
        { slug: 'architecture', note: 'Hive cell graph 與 shutdown order，以及 KPR / Cluster Mesh 第二波路徑' },
      ],
    },
  },
  'kubevirt': {
    id: 'kubevirt',
    displayName: 'KubeVirt',
    shortName: 'KubeVirt',
    description: '在 k8s 上跑 VM 的 operator：5 個 process + 3 個 CRD 把 libvirt/QEMU 包成 Kubernetes 第一公民',
    githubUrl: 'https://github.com/kubevirt/kubevirt',
    submodulePath: path.join(REPO_ROOT, 'kubevirt'),
    color: 'purple',
    accentClass: 'border-purple-500 text-purple-400',
    features: ['architecture', 'controllers', 'virt-handler-and-launcher', 'live-migration'],
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: '控制平面', icon: '🧠', slugs: ['controllers'] },
      { label: 'Node + Pod 內部', icon: '🖥️', slugs: ['virt-handler-and-launcher'] },
      { label: 'Live Migration', icon: '✈️', slugs: ['live-migration'] },
    ],
    usecases: [],
    difficulty: '🔴 進階',
    difficultyColor: 'text-red-400 bg-red-400/10 border-red-400/30',
    problemStatement: 'KubeVirt 把整個 libvirt/QEMU stack 塞進 k8s — VM 變成 CRD，VM Pod 內跑 QEMU，live migration 由 controller 協調。但 5 個 virt-* process 各自做什麼？VM / VMI / VMIM 三個 CRD 怎麼接力？live migration 是真的把 RAM 抄一份過去？這 4 頁從原始碼層拆。',
    story: {
      protagonist: '🧑‍💻 平台 SRE 你自己',
      challenge: '老闆要在 k8s 上跑舊系統的 VM。你聽過 KubeVirt 但搞不懂為什麼有 virt-operator / virt-api / virt-controller / virt-handler / virt-launcher 五種 Pod。今天決定從 cmd entry point 一路拆到 libvirt MigrateVMI。',
      scenes: [
        { step: 1, icon: '🏗️', actor: '你', action: '讀 architecture：5 個 process + 3 個 CRD', detail: 'VirtualMachine (desired) → VirtualMachineInstance (一次 run) → virt-launcher Pod (跑 QEMU)。virt-handler 是 DaemonSet 跟 kubelet 平起平坐。' },
        { step: 2, icon: '🔄', actor: '你', action: '讀 controllers：三條 reconcile pipeline', detail: 'VM controller / VMI controller / Migration controller 各自的 sync()，全部用 informer + work queue + Execute 模式。跟 k8s 內建 controller 一樣的骨架。' },
        { step: 3, icon: '🖥️', actor: '你', action: '讀 virt-handler-and-launcher：Pod 內 process tree', detail: 'virt-launcher-monitor / virt-launcher / libvirtd / QEMU 四層 process。virt-handler 透過 cmd-server gRPC 跟 launcher 對話；launcher 內 DomainManager 把 VMI spec 翻成 libvirt domain XML。' },
        { step: 4, icon: '✈️', actor: '你', action: '讀 live-migration：memory 真的在搬', detail: 'precopy → iteration → cutover。dirty rate 不收斂時 fallback 到 postcopy。migration-proxy 把 libvirt 的 unix socket 走 TCP 跨 node。' },
      ],
      outcome: '從此面對 KubeVirt 任何狀況 (VM 卡 Pending、migration 失敗、QEMU panic)，你能直覺知道「該去哪個 process 看 log」、「該追哪段原始碼」。第 27 天 lab 你看著 live migration downtime 187ms 跳到 target node，懂為什麼這個數字長這樣。',
    },
    learningPaths: {
      beginner: [
        { slug: 'architecture', note: '先建立全貌：5 process + 3 CRD' },
        { slug: 'controllers', note: 'VM → VMI → Pod 三條 reconcile 接力' },
        { slug: 'virt-handler-and-launcher', note: '看 Pod 內真實 process tree' },
      ],
      intermediate: [
        { slug: 'controllers', note: '深入 templateService 與 ownerReferences chain' },
        { slug: 'virt-handler-and-launcher', note: 'virtwrap DomainManager 跟 libvirt 的接點' },
        { slug: 'live-migration', note: 'precopy / postcopy 的取捨' },
      ],
      advanced: [
        { slug: 'live-migration', note: 'migrationMonitor 與 auto-converge 邏輯' },
        { slug: 'virt-handler-and-launcher', note: 'CNI bind 進 Pod net namespace 給 QEMU 的時序' },
        { slug: 'architecture', note: 'virt-operator 的 install/upgrade strategy job' },
      ],
    },
  },
  'ceph': {
    id: 'ceph',
    displayName: 'Ceph',
    shortName: 'Ceph',
    description: '分散式 storage：MON Paxos quorum + OSD 用 CRUSH 算式定位 object，不需要中央 metadata server',
    githubUrl: 'https://github.com/ceph/ceph',
    submodulePath: path.join(REPO_ROOT, 'ceph'),
    color: 'rose',
    accentClass: 'border-rose-500 text-rose-400',
    features: ['architecture', 'crush-and-placement', 'osd-and-bluestore', 'rbd-and-csi'],
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: 'Placement 演算法', icon: '🧮', slugs: ['crush-and-placement'] },
      { label: 'OSD + Storage 引擎', icon: '💾', slugs: ['osd-and-bluestore'] },
      { label: 'RBD + k8s 接點', icon: '🔗', slugs: ['rbd-and-csi'] },
    ],
    usecases: [],
    difficulty: '🔴 進階',
    difficultyColor: 'text-red-400 bg-red-400/10 border-red-400/30',
    problemStatement: 'HDFS 用 NameNode 記 block 位置，ceph 沒有這個東西 — client 自己用 CRUSH 算式定位 object。這 4 頁從原始碼層拆：MON 的 Paxos quorum、CRUSH 為什麼能不用中央 server、OSD + BlueStore 怎麼真的存資料、RBD 怎麼接 k8s PVC。',
    story: {
      protagonist: '🧑‍💻 平台 SRE 你自己',
      challenge: '你的 KubeVirt VM 要用持久 storage。聽說 ceph 是 cloud-native 的標準解，但 ceph 對你還是黑盒：MON / OSD / MDS / RGW 一堆 daemon、CRUSH 是什麼魔法、BlueStore 為什麼不用 filesystem。今天決定從 ceph_osd.cc 開始把它拆透。',
      scenes: [
        { step: 1, icon: '🏗️', actor: '你', action: '讀 architecture：3 類 daemon + RADOS', detail: 'MON (Paxos quorum, cluster state), OSD (per disk, 真正存資料), MGR (metric/orchestrator)。RADOS 是底層 object store，所有東西都建在它上面。' },
        { step: 2, icon: '🧮', actor: '你', action: '讀 CRUSH：為什麼不用中央 metadata server', detail: 'object → PG (hash) → OSD set (CRUSH algorithm)。client 拿 CRUSHMap 後自己算，O(1) 沒有 lookup。加 OSD 時只有少數 PG 需要重 placement (stable property 來自 straw2)。' },
        { step: 3, icon: '💾', actor: '你', action: '讀 OSD + BlueStore：raw block 直接管', detail: 'PrimaryLogPG.do_op 走完整 replicate flow。BlueStore 直接管 raw block + RocksDB metadata，避開 filesystem 的 double write 與粗 fsync。' },
        { step: 4, icon: '🔗', actor: '你', action: '讀 RBD + ceph-csi：50GB image 是一坨什麼', detail: 'RBD image = 一個 header object + N 個 4MB data object。librbd 把 block read/write 翻成 RADOS object op；ceph-csi 把 librbd 包成 k8s PVC backend；rook 是 operator 把整套部署當 CRD 管。' },
      ],
      outcome: '從此 ceph 不是黑盒。你看 ceph -s 知道每個 PG 狀態 (active+clean / degraded / scrubbing) 真實意義；ceph osd df 看 OSD 利用率不平均時知道是 CRUSH 的 weight 問題；KubeVirt VM 看到 RBD 慢時知道該追 BlueStore 還是 client 端。',
    },
    learningPaths: {
      beginner: [
        { slug: 'architecture', note: '先建立全貌：3 類 daemon + RADOS' },
        { slug: 'rbd-and-csi', note: '從 PVC 反推 ceph，最容易動手' },
        { slug: 'crush-and-placement', note: 'CRUSH 為什麼比中央 NameNode 好' },
      ],
      intermediate: [
        { slug: 'crush-and-placement', note: '深入 PG 與 stable placement property' },
        { slug: 'osd-and-bluestore', note: 'replication / recovery / scrubbing flow' },
        { slug: 'rbd-and-csi', note: 'RBD image → RADOS object 切片邏輯' },
      ],
      advanced: [
        { slug: 'osd-and-bluestore', note: 'BlueStore allocator 演算法、BlueFS for RocksDB' },
        { slug: 'crush-and-placement', note: 'straw2 算法為什麼 stable，CRUSHMap rule 設計' },
        { slug: 'architecture', note: 'MON Paxos 的 leader / peon 角色' },
      ],
    },
  },

  'multus': {
    id: 'multus',
    displayName: 'Multus CNI',
    shortName: 'Multus',
    description: 'CNI meta-plugin：kubelet 一次只 invoke 一個 CNI，multus 把這個位置霸佔住，再 fan-out 到任意數量的 delegate plugin',
    githubUrl: 'https://github.com/k8snetworkplumbingwg/multus-cni',
    submodulePath: path.join(REPO_ROOT, 'multus-cni'),
    color: 'green',
    accentClass: 'border-green-500 text-green-400',
    features: ['architecture', 'delegate-and-cmdadd', 'thick-shim-and-daemon', 'k8s-integration-and-status'],
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: 'Delegate 機制', icon: '🔀', slugs: ['delegate-and-cmdadd'] },
      { label: 'Thick mode 部署', icon: '🧵', slugs: ['thick-shim-and-daemon'] },
      { label: 'K8s 整合', icon: '🔌', slugs: ['k8s-integration-and-status'] },
    ],
    usecases: [],
    difficulty: '🟡 中階',
    difficultyColor: 'text-yellow-400 bg-yellow-400/10 border-yellow-400/30',
    problemStatement: 'CNI spec 規定 kubelet 一次只 invoke 一個 plugin。但 KubeVirt VM 同時要 cilium pod network + SR-IOV storage VLAN，怎麼辦？multus 把自己塞進那個唯一位置，再對 list of delegate plugin 各自呼叫一次。這 4 頁從原始碼拆：meta-plugin 概念、CmdAdd 的 fan-out flow、thick mode 為什麼用 socket 取代 thin、annotation 與 NAD CRD 的關係。',
    story: {
      protagonist: '🧑‍💻 平台 SRE 你自己',
      challenge: '你的 KubeVirt VM 要同時接 cilium 的 pod network 跟 storage 廠商給的 SR-IOV VLAN。CNI spec 不允許多個 CNI plugin — 但 multus 把自己包成「the one CNI」再 fan-out。今天從 cmd/multus/main.go 開始，把 multus 對 NAD 的整套邏輯拆透。',
      scenes: [
        { step: 1, icon: '🏗️', actor: '你', action: '讀 architecture：meta-plugin 是什麼', detail: 'kubelet → CNI plugin 是 1:1 規定。multus 把自己塞進那個位置，內部再呼叫實際的 CNI plugin。NAD CRD 把「另一個 CNI 的 config」存進 k8s API。' },
        { step: 2, icon: '🔀', actor: '你', action: '讀 delegate flow：CmdAdd 怎麼 fan-out', detail: 'pkg/multus/multus.go:742 CmdAdd 解析 pod annotation → 查 NAD CRD → 對每個 delegate 走 libcni invoke。master plugin 的 result 才回給 kubelet。' },
        { step: 3, icon: '🧵', actor: '你', action: '讀 thick mode：shim + daemon 的拆分', detail: 'thin mode 每次 ADD/DEL 都打 apiserver。thick 把 CNI binary 縮成 shim 只 POST 到 unix socket，daemon 用 informer cache 接住。' },
        { step: 4, icon: '🔌', actor: '你', action: '讀 k8s 整合：annotation in / status out', detail: 'k8s.v1.cni.cncf.io/networks 是 input，network-status 是 output。SR-IOV 的 deviceID 透過 resourceName annotation 從 device-plugin 傳進 delegate config。' },
      ],
      outcome: '從此 multus 不是黑盒。你看 Pod 拿了多 IP 知道哪個 delegate 給的；多 NIC VM 失敗時知道該追 NAD config 還是 delegate plugin；cilium + SR-IOV 共存的設計能講清楚誰負責什麼。',
    },
    learningPaths: {
      beginner: [
        { slug: 'architecture', note: '先建立全貌：CNI 限制與 meta-plugin 概念' },
        { slug: 'k8s-integration-and-status', note: 'annotation 與 NAD CRD 是面對使用者的介面' },
        { slug: 'delegate-and-cmdadd', note: 'CmdAdd flow 是核心邏輯' },
      ],
      intermediate: [
        { slug: 'delegate-and-cmdadd', note: '深入 fan-out 與 master plugin' },
        { slug: 'thick-shim-and-daemon', note: 'thick 模式 socket protocol' },
        { slug: 'k8s-integration-and-status', note: 'SR-IOV deviceID 整合' },
      ],
      advanced: [
        { slug: 'thick-shim-and-daemon', note: 'informer cache 設計與 chroot exec' },
        { slug: 'delegate-and-cmdadd', note: 'reverse-DEL on partial failure 的 idempotence' },
        { slug: 'k8s-integration-and-status', note: 'NAD spec.config 為何 string + namespace isolation' },
      ],
    },
  },
}

export const PROJECT_IDS: ProjectId[] = Object.keys(PROJECTS)

export function getProject(id: string): ProjectMeta | undefined {
  return PROJECTS[id]
}

/**
 * Returns PROJECT_IDS padded with a single placeholder so that
 * generateStaticParams() never returns [] when using `output: export`.
 * Next.js 14 errors on empty generateStaticParams with static export.
 * The placeholder param triggers notFound() at render time.
 */
export const PROJECT_IDS_FOR_STATIC_EXPORT: ProjectId[] =
  PROJECT_IDS.length > 0 ? PROJECT_IDS : ['__placeholder__']
