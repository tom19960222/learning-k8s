import Link from 'next/link'
import { SiteHeader } from '@/components/SiteHeader'
import { PROJECTS, PROJECT_IDS } from '@/lib/projects'
import { ExternalLink, BookOpen, Map, HelpCircle, ArrowRight, Layers, Cpu, GitBranch } from 'lucide-react'

const COLOR_CLASSES: Record<string, { badge: string; card: string }> = {
  blue:   { badge: 'bg-blue-500/10 text-blue-400 border-blue-500/30',   card: 'hover:border-blue-500/50' },
  orange: { badge: 'bg-orange-500/10 text-orange-400 border-orange-500/30', card: 'hover:border-orange-500/50' },
  purple: { badge: 'bg-purple-500/10 text-purple-400 border-purple-500/30', card: 'hover:border-purple-500/50' },
}

const LEARNING_PATHS = [
  {
    level: '🟢 初學者',
    title: '第一次接觸 CAPI',
    color: 'border-green-500/30 bg-green-500/5',
    labelColor: 'text-green-400',
    steps: [
      { label: '① 從 Cluster API 開始', desc: '理解宣告式叢集管理的核心概念與架構設計' },
      { label: '② 選擇一個 Provider', desc: '深入 MAAS 或 Metal3 Provider，了解裸機如何整合' },
      { label: '③ 完成互動測驗', desc: '測試你對各專案的理解，確認學習成果' },
    ],
  },
  {
    level: '🟡 中階工程師',
    title: '已懂 Kubernetes，要學 CAPI',
    color: 'border-yellow-500/30 bg-yellow-500/5',
    labelColor: 'text-yellow-400',
    steps: [
      { label: '① CAPI 控制器解析', desc: '直接深入 Reconcile 邏輯、狀態機與 Provider 合約' },
      { label: '② Provider 實作對比', desc: '比較 MAAS 與 Metal3 在相同合約下的不同設計決策' },
      { label: '③ Edge case 分析', desc: '研究錯誤處理、冪等性、Finalizer 的處理方式' },
    ],
  },
  {
    level: '🔴 資深工程師',
    title: '要深度貢獻或 debug',
    color: 'border-red-500/30 bg-red-500/5',
    labelColor: 'text-red-400',
    steps: [
      { label: '① 原始碼結構分析', desc: '從 code layout 到 interface 設計，理解可擴充性考量' },
      { label: '② 跨元件追蹤流程', desc: '追蹤一個 Cluster 建立請求穿越所有控制器的完整路徑' },
      { label: '③ 測驗挑戰模式', desc: '以進階題目驗證你對實作細節的掌握程度' },
    ],
  },
]

export default function HomePage() {
  return (
    <div className="min-h-screen flex flex-col">
      <SiteHeader />
      <main className="flex-1">

        {/* Hero */}
        <section className="px-6 py-24 max-w-5xl mx-auto text-center">
          <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-[#161b22] border border-[#30363d] text-xs text-[#8b949e] mb-8">
            <span className="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse"></span>
            以原始碼為基礎的深度學習
          </div>
          <h1 className="text-5xl md:text-6xl font-bold text-white mb-6 leading-tight tracking-tight">
            深入 Kubernetes<br />
            <span className="text-[#2f81f7]">基礎設施管理</span>
          </h1>
          <p className="text-xl text-[#8b949e] max-w-2xl mx-auto mb-10 leading-relaxed">
            從功能視角出發，逐層深入 Cluster API 生態系的原始碼。<br />
            理解每個 Controller 的設計決策與實作細節。
          </p>
          <div className="flex items-center justify-center gap-4">
            <Link href="/cluster-api"
              className="inline-flex items-center gap-2 px-6 py-3 rounded-lg bg-[#2f81f7] text-white font-semibold hover:bg-blue-600 transition-colors">
              開始學習 <ArrowRight size={16} />
            </Link>
            <a href="https://github.com/hwchiu/molearn" target="_blank" rel="noopener noreferrer"
              className="inline-flex items-center gap-2 px-6 py-3 rounded-lg border border-[#30363d] text-[#e6edf3] hover:border-[#2f81f7] transition-colors">
              <ExternalLink size={14} /> GitHub
            </a>
          </div>
        </section>

        {/* What is CAPI Ecosystem */}
        <section className="px-6 pb-16 max-w-5xl mx-auto">
          <div className="rounded-2xl border border-[#30363d] bg-[#161b22] p-8">
            <h2 className="text-xl font-bold text-white mb-2 flex items-center gap-2">
              <Layers size={20} className="text-[#2f81f7]" />
              什麼是 Cluster API 生態系？
            </h2>
            <p className="text-[#8b949e] text-sm mb-6 leading-relaxed">
              Kubernetes 擅長管理容器，但誰來管理 Kubernetes 叢集本身？這就是 Cluster API（CAPI）的誕生背景。
            </p>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div className="p-4 rounded-xl border border-blue-500/20 bg-blue-500/5">
                <div className="flex items-center gap-2 mb-2">
                  <GitBranch size={15} className="text-blue-400" />
                  <span className="text-sm font-semibold text-blue-400">Cluster API（核心）</span>
                </div>
                <p className="text-xs text-[#8b949e] leading-relaxed">定義統一的叢集管理抽象層：Cluster、Machine、MachineSet 等 CRD，以及 Provider 合約介面。</p>
              </div>
              <div className="p-4 rounded-xl border border-orange-500/20 bg-orange-500/5">
                <div className="flex items-center gap-2 mb-2">
                  <Cpu size={15} className="text-orange-400" />
                  <span className="text-sm font-semibold text-orange-400">MAAS Provider（裸機）</span>
                </div>
                <p className="text-xs text-[#8b949e] leading-relaxed">透過 Canonical MAAS 平台管理實體伺服器，將 MAAS 機器生命週期橋接到 CAPI 合約。</p>
              </div>
              <div className="p-4 rounded-xl border border-purple-500/20 bg-purple-500/5">
                <div className="flex items-center gap-2 mb-2">
                  <Cpu size={15} className="text-purple-400" />
                  <span className="text-sm font-semibold text-purple-400">Metal3 Provider（裸機）</span>
                </div>
                <p className="text-xs text-[#8b949e] leading-relaxed">直接透過 BMC 控制裸機，以 BareMetalHost Operator 在 K8s 生態系內完整管理實體伺服器。</p>
              </div>
            </div>
          </div>
        </section>

        {/* Learning Paths */}
        <section className="px-6 pb-16 max-w-5xl mx-auto">
          <h2 className="text-lg font-semibold text-[#8b949e] uppercase tracking-wider mb-6 text-center">學習路徑建議</h2>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-5">
            {LEARNING_PATHS.map(lp => (
              <div key={lp.level} className={`rounded-xl border p-5 ${lp.color}`}>
                <div className={`text-sm font-bold mb-1 ${lp.labelColor}`}>{lp.level}</div>
                <div className="text-xs text-[#8b949e] mb-4">{lp.title}</div>
                <ol className="space-y-3">
                  {lp.steps.map(step => (
                    <li key={step.label}>
                      <div className="text-xs font-semibold text-[#e6edf3] mb-0.5">{step.label}</div>
                      <div className="text-xs text-[#8b949e] leading-relaxed">{step.desc}</div>
                    </li>
                  ))}
                </ol>
              </div>
            ))}
          </div>
        </section>

        {/* Projects */}
        <section className="px-6 pb-24 max-w-5xl mx-auto">
          <h2 className="text-lg font-semibold text-[#8b949e] uppercase tracking-wider mb-8 text-center">涵蓋專案</h2>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
            {PROJECT_IDS.map(id => {
              const proj = PROJECTS[id]
              const cc = COLOR_CLASSES[proj.color] || COLOR_CLASSES.blue
              return (
                <Link key={id} href={`/${id}`}
                  className={`group flex flex-col p-6 rounded-2xl border border-[#30363d] bg-[#161b22] transition-all duration-200 ${cc.card} hover:bg-[#21262d]`}>
                  <div className="flex items-start justify-between mb-3">
                    <span className={`px-2.5 py-1 rounded-full text-xs font-semibold border ${cc.badge}`}>
                      {proj.shortName}
                    </span>
                    <span className={`px-2 py-0.5 rounded-full text-xs border ${proj.difficultyColor}`}>
                      {proj.difficulty}
                    </span>
                  </div>
                  <h3 className="text-xl font-bold text-white mb-2 group-hover:text-[#2f81f7] transition-colors">
                    {proj.displayName}
                  </h3>
                  <p className="text-sm text-[#8b949e] leading-relaxed flex-1 mb-4">
                    {proj.description}
                  </p>
                  <div className="flex items-center gap-4 text-xs text-[#8b949e]">
                    <span className="flex items-center gap-1"><Map size={11} /> 功能地圖</span>
                    <span className="flex items-center gap-1"><BookOpen size={11} /> {proj.features.length} 功能</span>
                    <span className="flex items-center gap-1"><HelpCircle size={11} /> 測驗</span>
                  </div>
                </Link>
              )
            })}
          </div>
        </section>
      </main>
    </div>
  )
}
