import path from 'path'

export type ProjectId = 'cluster-api' | 'cluster-api-provider-maas' | 'cluster-api-provider-metal3' | 'rook' | 'kube-ovn' | 'kubevirt'

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

export const PROJECTS: Record<ProjectId, ProjectMeta> = {
  'cluster-api': {
    id: 'cluster-api',
    displayName: 'Cluster API',
    shortName: 'CAPI',
    description: '宣告式 Kubernetes 叢集生命週期管理框架，定義 Provider 合約與核心 CRD',
    githubUrl: 'https://github.com/kubernetes-sigs/cluster-api',
    submodulePath: path.join(REPO_ROOT, 'cluster-api'),
    color: 'blue',
    accentClass: 'border-blue-500 text-blue-400',
    features: [
      'architecture', 'controller-core', 'controller-kcp', 'controller-topology',
      'api-cluster-machine', 'api-machineset-machinedeployment', 'api-kubeadm-controlplane',
      'bootstrap-kubeadmconfig', 'machine-lifecycle', 'machine-health-check',
      'clusterclass-topology', 'addons-clusterresourceset',
      'provider-contracts-runtime-hooks', 'clusterctl',
    ],
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: '控制器原理', icon: '🔄', slugs: ['controller-core', 'controller-kcp', 'controller-topology'] },
      { label: 'API 資源設計', icon: '📋', slugs: ['api-cluster-machine', 'api-machineset-machinedeployment', 'api-kubeadm-controlplane', 'bootstrap-kubeadmconfig'] },
      { label: '機器生命週期', icon: '⚙️', slugs: ['machine-lifecycle', 'machine-health-check'] },
      { label: '進階管理', icon: '🏗', slugs: ['clusterclass-topology', 'addons-clusterresourceset', 'provider-contracts-runtime-hooks', 'clusterctl'] },
    ],
    usecases: ['multi-team-platform', 'cluster-self-healing'],
    difficulty: '🟡 中階',
    difficultyColor: 'text-yellow-400 bg-yellow-400/10 border-yellow-400/30',
    problemStatement: '想像你需要管理 50 個 Kubernetes 叢集，分散在 AWS、裸機、vSphere 等不同環境。每個環境的建立方式都不同，維運成本極高。Cluster API 定義了一套統一的「語言」：你只需要宣告「我想要一個有 3 個 master + 5 個 worker 的叢集」，由各個 Provider 去翻譯並執行。就像 Kubernetes 統一了容器管理，CAPI 統一了叢集管理。',
    story: {
      protagonist: '🧑‍💻 SRE 工程師 小王',
      challenge: '公司決定多雲策略：AWS 生產叢集 + 裸機測試叢集 + vSphere 開發叢集，三套完全不同的建置流程，每次新叢集要花 2 週。',
      scenes: [
        { step: 1, icon: '📝', actor: '小王', action: '寫一份 YAML 宣告「我要一個有 3 master + 5 worker 的叢集」', detail: '使用 Cluster、MachineDeployment 等 CRD，就像寫 Kubernetes Deployment 一樣簡單。' },
        { step: 2, icon: '🔄', actor: 'Cluster API Controller', action: '接收宣告，開始 Reconcile Loop', detail: '持續比對「期望狀態」與「實際狀態」，發現缺少機器就通知 Provider 去建立。' },
        { step: 3, icon: '🏗️', actor: 'Infrastructure Provider（AWS/MAAS/vSphere）', action: '收到指令，去對應平台建立實際資源', detail: '每個 Provider 只需實作 CAPI 合約的幾個欄位（status.ready, spec.providerID），核心邏輯由 CAPI 統一管理。' },
        { step: 4, icon: '⚙️', actor: 'Bootstrap Provider（KubeadmConfig）', action: '產生 cloud-init 腳本，讓新機器自動加入叢集', detail: '控制節點用 kubeadm init，工作節點用 kubeadm join，全程自動化，無需 SSH 進機器手動操作。' },
        { step: 5, icon: '✅', actor: '小王', action: '叢集就緒，kubectl get cluster 看到 Provisioned', detail: '3 個 master、5 個 worker 全部健康。同樣的流程在 AWS、裸機、vSphere 上完全一致。' },
      ],
      outcome: '從此小王的團隊用同一套 GitOps workflow 管理所有環境的叢集。新環境 PR 合併 = 叢集自動建立，省下 90% 的手動作業。',
    },
    learningPaths: {
      beginner: [
        { slug: 'architecture', note: '了解整體設計思想與各元件角色' },
        { slug: 'api-cluster-machine', note: '了解用什麼「表單」操作叢集與機器' },
        { slug: 'machine-lifecycle', note: '追蹤一台機器從申請到就緒的完整流程' },
      ],
      intermediate: [
        { slug: 'architecture', note: '快速瀏覽，確認架構印象' },
        { slug: 'controller-core', note: '重點理解 Reconcile 邏輯與狀態機' },
        { slug: 'provider-contracts-runtime-hooks', note: '了解 Provider 擴充點與合約設計' },
      ],
      advanced: [
        { slug: 'controller-kcp', note: '深入 KubeadmControlPlane 控制器原始碼' },
        { slug: 'clusterclass-topology', note: '理解 ClusterClass 拓樸管理與 patch engine' },
        { slug: 'machine-health-check', note: '分析錯誤處理與自癒機制的 edge case' },
      ],
    },
  },
  'cluster-api-provider-maas': {
    id: 'cluster-api-provider-maas',
    displayName: 'CAPI Provider MAAS',
    shortName: 'CAPM',
    description: '整合 Canonical MAAS 裸機管理平台，實作 InfraCluster / InfraMachine Provider 合約',
    githubUrl: 'https://github.com/spectrocloud/cluster-api-provider-maas',
    submodulePath: path.join(REPO_ROOT, 'cluster-api-provider-maas'),
    color: 'orange',
    accentClass: 'border-orange-500 text-orange-400',
    features: ['architecture', 'controllers', 'machine-lifecycle', 'api-types', 'integration'],
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: '核心機制', icon: '🔄', slugs: ['controllers', 'machine-lifecycle'] },
      { label: 'API 與整合', icon: '📋', slugs: ['api-types', 'integration'] },
    ],
    usecases: ['on-demand-baremetal'],
    difficulty: '🟡 中階',
    difficultyColor: 'text-yellow-400 bg-yellow-400/10 border-yellow-400/30',
    problemStatement: '想像你管理著一個有 100 台實體伺服器的數據中心。每次需要新 Kubernetes 節點，你都要：登入 MAAS UI → 找到空閒的機器 → 分配 IP → 選 OS image → 等待部署 → 設定 Kubernetes。這個流程費時且容易出錯。MAAS Provider 讓這一切變成一個 YAML 宣告，Kubernetes 自動透過 MAAS API 完成剩下的事，讓裸機如同雲端資源一樣彈性。',
    story: {
      protagonist: '🏢 基礎設施工程師 小李',
      challenge: '機房有 200 台裸機伺服器，客戶要求能像雲端一樣按需建立 Kubernetes 叢集。目前靠 Ansible playbook 手動建，出錯率高、無版本控制。',
      scenes: [
        { step: 1, icon: '📋', actor: '小李', action: '把 200 台實體機登記進 MAAS，為每台機器定義 hostname、IP 範圍、電源管理', detail: 'MAAS 負責裸機的 PXE boot、OS 安裝、網路設定。這是 MAAS Provider 的「基礎設施層」。' },
        { step: 2, icon: '📝', actor: '小李', action: '寫一份 MaasMachine + MaasCluster YAML 宣告「我要 3 台 control-plane + 5 台 worker」', detail: '透過 machineType（機器標籤）指定要選哪類裸機，例如 gpu=true 或 role=compute。' },
        { step: 3, icon: '🔍', actor: 'MaasClusterReconciler', action: '向 MAAS API 查詢符合條件的可用機器', detail: '呼叫 MAAS REST API /machines?tags=xxx，選出空閒機器，為它們分配 IP 並設定 DNS。' },
        { step: 4, icon: '⚡', actor: 'MaasMachineReconciler', action: '透過 MAAS 觸發 PXE boot，安裝 OS，等待機器上線', detail: '機器安裝完成後設定 providerID=maas://hostname，CAPI 核心收到 ready 訊號即開始 bootstrap。' },
        { step: 5, icon: '✅', actor: '小李', action: '叢集建立完成，kubectl get cluster 顯示 Provisioned', detail: '整個流程不需 SSH 進任何機器。損壞的機器自動觸發替換流程。' },
      ],
      outcome: '小李的團隊現在用 Git PR 管理叢集生命週期。200 台裸機的利用率從 40% 提升到 85%，故障恢復時間從 4 小時降至 20 分鐘。',
    },
    learningPaths: {
      beginner: [
        { slug: 'architecture', note: '了解 MAAS Provider 與 CAPI 的整合架構' },
        { slug: 'api-types', note: '認識 MaasMachine / MaasCluster CRD 欄位' },
        { slug: 'machine-lifecycle', note: '追蹤裸機從 Allocate 到 Deploy 的完整流程' },
      ],
      intermediate: [
        { slug: 'architecture', note: '快速複習 Provider 合約對應關係' },
        { slug: 'controllers', note: '深入 Reconcile 邏輯與 MAAS API 互動' },
        { slug: 'integration', note: '理解與上層 CAPI 核心的整合方式' },
      ],
      advanced: [
        { slug: 'api-types', note: '分析 CRD 設計決策與欄位語意' },
        { slug: 'controllers', note: '追蹤錯誤路徑與冪等性保證' },
        { slug: 'machine-lifecycle', note: '分析複雜狀態轉換與 finalizer 處理' },
      ],
    },
  },
  'cluster-api-provider-metal3': {
    id: 'cluster-api-provider-metal3',
    displayName: 'CAPI Provider Metal3',
    shortName: 'CAPM3',
    description: '整合 Metal3 BareMetalHost Operator，以 BMO 管理裸機生命週期',
    githubUrl: 'https://github.com/metal3-io/cluster-api-provider-metal3',
    submodulePath: path.join(REPO_ROOT, 'cluster-api-provider-metal3'),
    color: 'purple',
    accentClass: 'border-purple-500 text-purple-400',
    features: [
      'architecture', 'bmh-lifecycle', 'crds-cluster', 'crds-machine',
      'labelsync', 'node-reuse', 'data-templates', 'ipam', 'remediation', 'advanced-features',
    ],
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: '裸機生命週期', icon: '⚙️', slugs: ['bmh-lifecycle', 'crds-cluster', 'crds-machine'] },
      { label: '資料與網路', icon: '🌐', slugs: ['data-templates', 'ipam'] },
      { label: '運維與自癒', icon: '🔧', slugs: ['labelsync', 'node-reuse', 'remediation', 'advanced-features'] },
    ],
    usecases: ['edge-auto-recovery', 'bulk-os-upgrade'],
    difficulty: '🔴 進階',
    difficultyColor: 'text-red-400 bg-red-400/10 border-red-400/30',
    problemStatement: 'Metal3 解決的問題與 MAAS Provider 類似，但走的是另一條路：它不依賴外部平台，而是讓 Kubernetes 自己管理裸機——透過 BMC（伺服器遠端管理介面，如 iDRAC / iLO）直接控制電源、開機、掛載 ISO。整個裸機生命週期完全在 Kubernetes 生態系內閉環。代價是元件更多、概念更複雜，但換來的是更強的可擴充性與對底層硬體的完整掌控。',
    story: {
      protagonist: '📡 電信工程師 小張',
      challenge: '要在全台 50 個邊緣機房部署 5G MEC 節點，每個機房有 2-4 台裸機。節點壞了需要自動修復，不能靠人工介入——機房根本沒人。',
      scenes: [
        { step: 1, icon: '🔩', actor: '小張', action: '在每個機房部署 Ironic 服務，連接裸機 BMC（IPMI/Redfish）', detail: 'Ironic 是 Metal3 的裸機控制層，透過 BMC 可以遠端開關機、PXE 開機、設定 BIOS。BareMetalHost CRD 代表每台實體機器。' },
        { step: 2, icon: '📝', actor: '小張', action: '宣告 BareMetalHost 和 Metal3Machine，描述要部署的 OS image 與網路設定', detail: 'Metal3Data CRD 管理每台機器的 network config 和 meta-data 模板，可以批量產生 cloud-init 設定。' },
        { step: 3, icon: '⚙️', actor: 'Metal3MachineReconciler', action: '選定一台 available 狀態的 BareMetalHost，開始 provisioning', detail: '透過 Ironic 觸發 PXE boot + OS image 寫入磁碟。整個流程狀態機包含：available → provisioning → provisioned。' },
        { step: 4, icon: '🩺', actor: 'Metal3RemediationReconciler', action: '偵測到某台節點的 MachineHealthCheck 失敗（長時間 NotReady）', detail: '自動觸發 BMC 強制重啟（或 OS 重新安裝），無需人工通報。故障處理從告警到修復完全自動化。' },
        { step: 5, icon: '✅', actor: '小張', action: '50 個邊緣機房全部穩定運行，節點故障率 < 0.1%', detail: '每個機房的狀態都在 management cluster 的 BareMetalHost 列表中可見，GitOps 管理所有設定變更。' },
      ],
      outcome: '小張的團隊從此告別凌晨 3 點的緊急通知。50 個邊緣節點的自動修復率達到 95%，人工介入只需要在物理硬體損壞時才觸發。',
    },
    learningPaths: {
      beginner: [
        { slug: 'architecture', note: '了解 BMO / CAPM3 / CAPI 三層架構關係' },
        { slug: 'crds-machine', note: '認識 Metal3Machine / BareMetalHost CRD' },
        { slug: 'bmh-lifecycle', note: '追蹤裸機從 Registering 到 Provisioned 的狀態機' },
      ],
      intermediate: [
        { slug: 'architecture', note: '確認各元件職責邊界' },
        { slug: 'crds-cluster', note: '理解叢集層級資源設計' },
        { slug: 'remediation', note: '深入故障自癒與節點修復機制' },
      ],
      advanced: [
        { slug: 'data-templates', note: '分析 Metal3DataTemplate 與 cloud-init 整合' },
        { slug: 'ipam', note: '研究 IP 位址管理與 IPAddressClaim 設計' },
        { slug: 'advanced-features', note: '探索 node-reuse、labelsync 等進階功能原始碼' },
      ],
    },
  },
  'rook': {
    id: 'rook',
    displayName: 'Rook',
    shortName: 'Rook',
    description: '雲端原生儲存協調器，將 Ceph 等分散式儲存系統轉化為 Kubernetes 原生服務',
    githubUrl: 'https://github.com/rook/rook',
    submodulePath: path.join(REPO_ROOT, 'rook'),
    color: 'teal',
    accentClass: 'border-teal-500 text-teal-400',
    features: [
      'feature-map', 'architecture', 'ceph-cluster', 'storage-classes',
      'osds-monitors', 'ceph-controllers', 's3-object-store', 'csi-driver',
    ],
    featureGroups: [
      { label: '從這裡開始', icon: '🗺️', slugs: ['feature-map', 'architecture'] },
      { label: 'Ceph 核心', icon: '🗄️', slugs: ['ceph-cluster', 'osds-monitors', 'ceph-controllers'] },
      { label: '儲存服務', icon: '💾', slugs: ['storage-classes', 's3-object-store', 'csi-driver'] },
    ],
    usecases: ['stateful-storage'],
    difficulty: '🟡 中階',
    difficultyColor: 'text-yellow-400 bg-yellow-400/10 border-yellow-400/30',
    problemStatement: '在 Kubernetes 叢集中，Pod 需要持久化儲存，但傳統的 NFS 或本地磁碟無法滿足雲端原生的彈性與高可用性需求。Rook 把 Ceph 這套企業級分散式儲存系統包裝成 Kubernetes Operator，讓你用宣告式 YAML 管理整個儲存叢集——從磁碟格式化、Monitor 選舉到 S3 物件儲存，全部自動化。',
    story: {
      protagonist: '📦 平台工程師 小陳',
      challenge: '公司的 Kubernetes 平台需要為 10 個微服務團隊提供持久化儲存。有些服務需要高效能 Block Storage（資料庫），有些需要共享 File System（報表），還有 AI 團隊需要 S3-compatible Object Storage 存訓練資料。',
      scenes: [
        { step: 1, icon: '🔧', actor: '小陳', action: '在每台 Node 掛上空白磁碟，部署 Rook Operator', detail: 'Rook Operator 是整個系統的大腦，它持續監控 CephCluster CRD，自動發現可用磁碟並規劃 OSD（Object Storage Daemon）部署位置。' },
        { step: 2, icon: '🗄️', actor: 'Rook Operator', action: '建立 Ceph Monitor 仲裁叢集（通常 3 個），確保儲存 metadata 高可用', detail: 'Monitor 負責維護 Cluster Map——記錄哪些 OSD 存活、資料分佈在哪裡。這是 Ceph 的核心元件，Rook 會自動處理 Monitor 的選舉與故障替換。' },
        { step: 3, icon: '💾', actor: 'Rook Operator', action: '為每顆磁碟部署 OSD Pod，開始接受讀寫請求', detail: 'OSD 是實際儲存資料的元件，Rook 透過 Job 自動完成磁碟格式化（BlueStore）、OSD 初始化，並注入 TLS 憑證讓各 OSD 安全通訊。' },
        { step: 4, icon: '📋', actor: '小陳', action: '建立 CephBlockPool + StorageClass，讓開發團隊直接用 PVC 申請儲存', detail: 'StorageClass 背後是 Rook CSI Driver，PVC 建立時自動呼叫 Ceph RBD API 建立 image，並掛載到指定 Pod。讀寫延遲約 1ms，適合資料庫工作負載。' },
        { step: 5, icon: '✅', actor: 'AI 團隊', action: '透過 CephObjectStore + S3 Endpoint 上傳訓練資料集', detail: 'Rook 部署 RGW（Rados Gateway）元件提供 S3 API，完全相容 AWS S3 SDK。AI 團隊無需改程式碼，直接把 endpoint 從 AWS S3 換成內部位址即可。' },
      ],
      outcome: '小陳的團隊現在用同一套 Rook 平台提供三種儲存服務。磁碟故障時 Ceph 自動重新平衡資料，MTTF（平均故障修復時間）從 4 小時降至 0（自動修復，無需人工介入）。',
    },
    learningPaths: {
      beginner: [
        { slug: 'feature-map', note: '從全景地圖了解 Rook 的所有功能模組與學習路徑' },
        { slug: 'architecture', note: '了解 Rook + Ceph 的整體架構與元件角色' },
        { slug: 'ceph-cluster', note: '認識 CephCluster CRD 與部署設定' },
        { slug: 'storage-classes', note: '了解如何透過 StorageClass 使用儲存' },
      ],
      intermediate: [
        { slug: 'osds-monitors', note: '深入 Monitor 仲裁機制與 OSD 生命週期' },
        { slug: 'ceph-controllers', note: '研究 Rook Operator 的 Reconcile 邏輯' },
        { slug: 'csi-driver', note: '理解 CSI Driver 與 PVC 動態佈建流程' },
      ],
      advanced: [
        { slug: 'ceph-controllers', note: '追蹤跨 Controller 的協作與狀態機' },
        { slug: 's3-object-store', note: '研究 RGW 部署與 S3 相容層設計' },
        { slug: 'osds-monitors', note: '分析 OSD 故障處理與資料重新平衡機制' },
      ],
    },
  },
  'kube-ovn': {
    id: 'kube-ovn',
    displayName: 'Kube-OVN',
    shortName: 'KOVN',
    description: '基於 OVN 的企業級 Kubernetes CNI，提供 VPC、子網路管理、QoS、BGP 等進階網路功能',
    githubUrl: 'https://github.com/kubeovn/kube-ovn',
    submodulePath: path.join(REPO_ROOT, 'kube-ovn'),
    color: 'green',
    accentClass: 'border-green-500 text-green-400',
    features: [
      'architecture', 'vpc-subnet', 'ipam',
      'ovn-integration', 'controllers', 'qos-security', 'bgp',
      'underlay', 'load-balancing', 'nat-gateway',
    ],
    featureGroups: [
      { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
      { label: '網路模型', icon: '🌐', slugs: ['vpc-subnet', 'ipam', 'ovn-integration'] },
      { label: 'Underlay 網路模式', icon: '🔌', slugs: ['underlay'] },
      { label: '服務與對外連通', icon: '🌍', slugs: ['load-balancing', 'bgp', 'nat-gateway'] },
      { label: '控制器與安全策略', icon: '⚙️', slugs: ['controllers', 'qos-security'] },
    ],
    usecases: ['multi-tenant-network'],
    difficulty: '🔴 進階',
    difficultyColor: 'text-red-400 bg-red-400/10 border-red-400/30',
    problemStatement: '預設的 Kubernetes 網路只有一個扁平的 Pod CIDR——所有 Pod 在同一個廣播域，沒有隔離、沒有 QoS、無法精確控制 IP。Kube-OVN 在 Kubernetes 上構建了一套完整的虛擬網路基礎設施：每個 Namespace 可以有獨立的 VPC 和子網路，Pod 可以綁定靜態 IP，跨叢集流量可以走 BGP 路由，安全策略細粒度到單一 Pod。',
    story: {
      protagonist: '🌐 網路工程師 小林',
      challenge: '電信公司在 Kubernetes 上部署多租戶平台，不同客戶的工作負載必須嚴格隔離。同時需要支援有狀態服務（資料庫）的固定 IP，以及 5G UPF 工作負載的低延遲高吞吐量需求。',
      scenes: [
        { step: 1, icon: '🏗️', actor: '小林', action: '為每個客戶建立獨立的 VPC（Virtual Private Cloud）', detail: 'Kube-OVN 的 VPC CRD 在 OVN 邏輯層建立獨立的路由器與交換機，不同 VPC 的 Pod IP 可以重疊，流量完全隔離，就像公有雲的 VPC 一樣。' },
        { step: 2, icon: '📋', actor: '小林', action: '在每個 VPC 內建立子網路，指定 CIDR 和 Gateway', detail: 'Subnet CRD 對應 OVN 邏輯交換機，Kube-OVN 的 IPAM 模組負責從子網路 CIDR 分配 IP，支援靜態 IP（annotate Pod）和動態分配。' },
        { step: 3, icon: '⚡', actor: 'Kube-OVN CNI', action: '為每個 Pod 配置虛擬網卡，透過 OVS Flow 實現轉發', detail: 'CNI plugin 呼叫本機 ovs-vsctl 建立 veth pair，並向 OVN Northbound DB 注冊 Logical Switch Port，OVN 自動計算並下發轉發規則到每台 Node 的 OVS。' },
        { step: 4, icon: '🔒', actor: '小林', action: '設定 Security Policy 限制特定 Pod 只能訪問指定服務', detail: 'Kube-OVN 的 Security Group 和 ACL 直接對應到 OVN ACL 規則，在 OVS datapath 層攔截，不需要 iptables，效能更高且規則更精確。' },
        { step: 5, icon: '📡', actor: '5G 工作負載', action: '透過 BGP 將 Pod IP 宣告到物理網路，實現直接路由', detail: 'Kube-OVN 整合 GoBGP，可以將選定的子網路透過 BGP 宣告到上游路由器，讓 5G 核心網設備直接以 IP 路由到 Pod，繞過 Node 的 NAT，延遲降低 50%。' },
      ],
      outcome: '小林的團隊成功在同一個 Kubernetes 叢集上服務 20 個客戶，每個客戶的 VPC 完全隔離，5G 工作負載達到亞毫秒級網路延遲，滿足電信等級 SLA 要求。',
    },
    learningPaths: {
      beginner: [
        { slug: 'architecture', note: '了解 Kube-OVN 與 OVN/OVS 的整體架構' },
        { slug: 'vpc-subnet', note: '認識 VPC 和 Subnet CRD 的設計' },
        { slug: 'ipam', note: '了解 IP 地址管理機制' },
      ],
      intermediate: [
        { slug: 'ovn-integration', note: '深入 OVN Northbound DB 與 Kubernetes 的同步機制' },
        { slug: 'underlay', note: '理解 Overlay 與 Underlay 網路模式的差異與選擇' },
        { slug: 'controllers', note: '研究各 Controller 的 Reconcile 邏輯' },
        { slug: 'qos-security', note: '理解 QoS 與安全策略的實作' },
      ],
      advanced: [
        { slug: 'load-balancing', note: '分析 OVN Load Balancer 取代 iptables/IPVS 的原理' },
        { slug: 'nat-gateway', note: '研究 VPC NAT Gateway 與 EIP 的設計與高可用限制' },
        { slug: 'bgp', note: '追蹤 BGP 整合與跨叢集路由設計' },
      ],
    },
  },
  'kubevirt': {
    id: 'kubevirt',
    displayName: 'KubeVirt',
    shortName: 'KV',
    description: '在 Kubernetes 上運行虛擬機器的擴充套件，讓 VM 與容器共享同一套編排平台',
    githubUrl: 'https://github.com/kubevirt/kubevirt',
    submodulePath: path.join(REPO_ROOT, 'kubevirt'),
    color: 'rose',
    accentClass: 'border-rose-500 text-rose-400',
    features: [
      'feature-map', 'architecture', 'vmi-lifecycle', 'virt-controller',
      'virt-handler', 'vm-storage', 'vm-network', 'live-migration',
    ],
    featureGroups: [
      { label: '從這裡開始', icon: '🗺️', slugs: ['feature-map', 'architecture'] },
      { label: 'VM 生命週期', icon: '🖥️', slugs: ['vmi-lifecycle', 'virt-controller', 'virt-handler'] },
      { label: '儲存與網路', icon: '🌐', slugs: ['vm-storage', 'vm-network'] },
      { label: '進階功能', icon: '✈️', slugs: ['live-migration'] },
    ],
    usecases: ['vm-container-mixed'],
    difficulty: '🔴 進階',
    difficultyColor: 'text-red-400 bg-red-400/10 border-red-400/30',
    problemStatement: '企業的基礎設施中仍有大量虛擬機器無法輕易容器化——Legacy 應用程式、Windows 工作負載、需要完整 OS 的測試環境。KubeVirt 讓這些 VM 直接跑在 Kubernetes 上，用同一套 kubectl 管理，共用同一套網路與儲存策略，讓「容器化遷移」不再是全有全無的選擇。',
    story: {
      protagonist: '🖥️ 虛擬化工程師 小吳',
      challenge: '公司決定淘汰 vSphere 平台，但有 200 台 VM 短期內無法容器化（包含 Windows Server、SAP、老舊 Java 應用）。管理層要求「今年就遷移到 Kubernetes」，但又不能打斷現有業務。',
      scenes: [
        { step: 1, icon: '📝', actor: '小吳', action: '把 VM 定義寫成 VirtualMachine CRD，指定 CPU、Memory、磁碟 image 路徑', detail: 'VirtualMachine 是持久的 VM 定義，類似 Deployment；VirtualMachineInstance 是實際執行的 VM，類似 Pod。關機後再開機的 VM 保留同一份定義。' },
        { step: 2, icon: '🎮', actor: 'virt-controller', action: '收到 VM 建立請求，建立 VMI 物件並選擇最適合的 Node 排程', detail: 'virt-controller 就像 VM 的 Deployment Controller，負責確保 VM 維持期望狀態。它計算 VMI 的資源需求（含 KVM overhead），並與 Kubernetes Scheduler 協作選擇具備 KVM 能力的 Node。' },
        { step: 3, icon: '⚙️', actor: 'virt-handler', action: '在目標 Node 上以 libvirt/KVM 啟動虛擬機器', detail: 'virt-handler 是每台 Node 上的 DaemonSet，類似 kubelet 之於 Pod。它監聽到 VMI 被排程到本機後，呼叫 virt-launcher 建立一個隔離的 QEMU 行程，使用 KVM 硬體加速。' },
        { step: 4, icon: '🌐', actor: '小吳', action: '設定 VM 使用 Multus 附加第二張網卡直連物理網路', detail: 'KubeVirt 整合 Multus CNI，VM 可以有多個網路介面：一個走 Pod Network 連 Kubernetes 服務，一個走 SR-IOV 或 bridge 直連物理交換機，滿足低延遲需求。' },
        { step: 5, icon: '✈️', actor: '小吳', action: '觸發 Live Migration，把執行中的 VM 搬移到另一台 Node', detail: 'KubeVirt 支援不停機的 VM 遷移，透過 QEMU 的 memory migration 功能把 VM 記憶體狀態複製到目標 Node，整個切換過程 downtime 小於 1 秒。' },
      ],
      outcome: '小吳的團隊在 3 個月內把 200 台 VM 遷移到 KubeVirt，現在用同一套 GitOps 流程管理 VM 和容器。vSphere 授權費用省下 40 萬美元/年。',
    },
    learningPaths: {
      beginner: [
        { slug: 'feature-map', note: '從全景地圖了解 KubeVirt 的所有功能模組與學習路徑' },
        { slug: 'architecture', note: '了解 KubeVirt 元件架構與 VM 如何跑在 Kubernetes 上' },
        { slug: 'vmi-lifecycle', note: '追蹤 VM 從建立到執行的完整生命週期' },
        { slug: 'vm-storage', note: '了解 VM 磁碟與 PVC 的整合方式' },
      ],
      intermediate: [
        { slug: 'virt-controller', note: '深入 virt-controller 的 Reconcile 邏輯' },
        { slug: 'virt-handler', note: '研究 virt-handler 與 libvirt/KVM 的互動' },
        { slug: 'vm-network', note: '理解 VM 網路模型與 Multus 整合' },
      ],
      advanced: [
        { slug: 'live-migration', note: '分析 Live Migration 的實作與狀態機' },
        { slug: 'virt-handler', note: '追蹤 QEMU 行程管理與隔離機制' },
        { slug: 'virt-controller', note: '研究 VM 排程與資源計算的邊界條件' },
      ],
    },
  },
}

export const PROJECT_IDS: ProjectId[] = Object.keys(PROJECTS) as ProjectId[]

export function getProject(id: string): ProjectMeta | undefined {
  return PROJECTS[id as ProjectId]
}
