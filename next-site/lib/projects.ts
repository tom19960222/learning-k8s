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
