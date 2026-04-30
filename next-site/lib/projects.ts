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
    features: ['architecture', 'api-server', 'controllers', 'kubelet'],
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: '控制平面', icon: '🧠', slugs: ['api-server', 'controllers'] },
      { label: 'Node 端', icon: '🖥️', slugs: ['kubelet'] },
    ],
    usecases: [],
    difficulty: '🟡 中階',
    difficultyColor: 'text-yellow-400 bg-yellow-400/10 border-yellow-400/30',
    problemStatement: '你會用 kubectl 操作 cluster，但 control plane 4 個 process、kubelet、kube-proxy 在背後到底做什麼？API server 收到 request 之後怎麼走進 etcd？scheduler 怎麼挑 node？kubelet 又怎麼跟 containerd 對話？這 4 頁 MVP 從架構切入，逐層拆到 reconcile loop 與 CRI 介面。',
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
        { slug: 'controllers', note: '從最直觀的 ReplicaSet reconcile 開始' },
        { slug: 'kubelet', note: '看 Pod 在 node 上的真實長相' },
      ],
      intermediate: [
        { slug: 'api-server', note: 'admission chain 與 watch fan-out 是 cluster 觀察的關鍵' },
        { slug: 'controllers', note: '深入 informer / work queue / rate limiter' },
        { slug: 'kubelet', note: 'CRI 介面與 Pod sandbox' },
      ],
      advanced: [
        { slug: 'api-server', note: '研究 storage layer 與 etcd 互動細節' },
        { slug: 'controllers', note: 'leader election、shared informer、跨 controller 的 ownership chain' },
        { slug: 'kubelet', note: 'CRI 之外：device plugin、CNI、CSI 的整合面' },
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
