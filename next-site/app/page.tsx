import Link from 'next/link'
import { SiteHeader } from '@/components/SiteHeader'
import { PROJECTS, PROJECT_IDS } from '@/lib/projects'
import { ExternalLink, BookOpen, Map, HelpCircle, ArrowRight, Layers, Cpu, GitBranch } from 'lucide-react'

const COLOR_CLASSES: Record<string, { badge: string; card: string }> = {
  blue:   { badge: 'bg-blue-500/10 text-blue-400 border-blue-500/30',     card: 'hover:border-blue-500/50' },
  orange: { badge: 'bg-orange-500/10 text-orange-400 border-orange-500/30', card: 'hover:border-orange-500/50' },
  purple: { badge: 'bg-purple-500/10 text-purple-400 border-purple-500/30', card: 'hover:border-purple-500/50' },
  teal:   { badge: 'bg-teal-500/10 text-teal-400 border-teal-500/30',     card: 'hover:border-teal-500/50' },
  green:  { badge: 'bg-green-500/10 text-green-400 border-green-500/30',  card: 'hover:border-green-500/50' },
  rose:   { badge: 'bg-rose-500/10 text-rose-400 border-rose-500/30',     card: 'hover:border-rose-500/50' },
  amber:  { badge: 'bg-amber-500/10 text-amber-400 border-amber-500/30',  card: 'hover:border-amber-500/50' },
}

const LEARNING_PATHS = [
  {
    level: '🟢 初學者',
    title: '剛接觸 Kubernetes 生態系',
    color: 'border-green-500/30 bg-green-500/5',
    labelColor: 'text-green-400',
    steps: [
      { label: '① 從 30 天 lab 開始', desc: '依時間軸動手做實驗，快速建立可操作的整體圖像' },
      { label: '② 配合各專案 overview', desc: '每天 lab 完成後，閱讀對應專案的概觀頁建立背景知識' },
      { label: '③ 完成互動測驗', desc: '以選擇題自我檢查，找出仍模糊的概念回頭補強' },
    ],
  },
  {
    level: '🟡 中階工程師',
    title: '已會基本操作，要懂內部運作',
    color: 'border-yellow-500/30 bg-yellow-500/5',
    labelColor: 'text-yellow-400',
    steps: [
      { label: '① 由 architecture 切入', desc: '聚焦各專案的元件職責與資料流，看清誰跟誰互動' },
      { label: '② 跟著 reconcile loop 走', desc: '挑一個 Controller，從事件進入到 status 寫回的完整路徑' },
      { label: '③ 對照 lab 結果驗證', desc: '用 kubectl describe / events 對齊原始碼上的狀態變化' },
    ],
  },
  {
    level: '🔴 資深工程師',
    title: '要深度貢獻或建構平台',
    color: 'border-red-500/30 bg-red-500/5',
    labelColor: 'text-red-400',
    steps: [
      { label: '① 跨專案閱讀', desc: '同時看 cilium / multus / kubevirt 的 CNI 介接，比較設計取捨' },
      { label: '② 邊界條件分析', desc: '研究錯誤路徑、finalizer、leader election 的失敗模式' },
      { label: '③ 自行擴充', desc: '依 lab 末段挑戰題目實作小型 controller / CNI 外掛 / VM 操作工具' },
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
            從原始碼學習<br />
            <span className="text-[#2f81f7]">Kubernetes 生態系</span>
          </h1>
          <p className="text-xl text-[#8b949e] max-w-2xl mx-auto mb-10 leading-relaxed">
            以 30 天動手實驗加 5 個專案的深度原始碼導讀，<br />
            建立可開發 KubeVirt 平台的能力。
          </p>
          <div className="flex items-center justify-center gap-4">
            {PROJECT_IDS.length > 0 ? (
              <Link href={`/${PROJECT_IDS[0]}`}
                className="inline-flex items-center gap-2 px-6 py-3 rounded-lg bg-[#2f81f7] text-white font-semibold hover:bg-blue-600 transition-colors">
                開始學習 <ArrowRight size={16} />
              </Link>
            ) : (
              <span className="inline-flex items-center gap-2 px-6 py-3 rounded-lg bg-[#161b22] border border-[#30363d] text-[#8b949e] text-sm">
                尚未加入任何專案 — 詳見 BOOTSTRAP.md
              </span>
            )}
            <a href="#" target="_blank" rel="noopener noreferrer"
              className="inline-flex items-center gap-2 px-6 py-3 rounded-lg border border-[#30363d] text-[#e6edf3] hover:border-[#2f81f7] transition-colors">
              <ExternalLink size={14} /> GitHub
            </a>
          </div>
        </section>

        {/* What is this site */}
        <section className="px-6 pb-16 max-w-5xl mx-auto">
          <div className="rounded-2xl border border-[#30363d] bg-[#161b22] p-8">
            <h2 className="text-xl font-bold text-white mb-2 flex items-center gap-2">
              <Layers size={20} className="text-[#2f81f7]" />
              這個網站涵蓋什麼？
            </h2>
            <p className="text-[#8b949e] text-sm mb-6 leading-relaxed">
              從原始碼出發深入分析 5 個 Kubernetes 生態系專案，並附一份按時間軸推進的 30 天 hands-on lab。
            </p>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div className="p-4 rounded-xl border border-blue-500/20 bg-blue-500/5">
                <div className="flex items-center gap-2 mb-2">
                  <GitBranch size={15} className="text-blue-400" />
                  <span className="text-sm font-semibold text-blue-400">Kubernetes 核心</span>
                </div>
                <p className="text-xs text-[#8b949e] leading-relaxed">k8s 控制平面、kubelet、kube-proxy、scheduler 與其 CRD / API server 設計。</p>
              </div>
              <div className="p-4 rounded-xl border border-teal-500/20 bg-teal-500/5">
                <div className="flex items-center gap-2 mb-2">
                  <Cpu size={15} className="text-teal-400" />
                  <span className="text-sm font-semibold text-teal-400">網路與儲存</span>
                </div>
                <p className="text-xs text-[#8b949e] leading-relaxed">cilium 的 eBPF datapath、multus 多網路、ceph 分散式儲存。</p>
              </div>
              <div className="p-4 rounded-xl border border-rose-500/20 bg-rose-500/5">
                <div className="flex items-center gap-2 mb-2">
                  <Cpu size={15} className="text-rose-400" />
                  <span className="text-sm font-semibold text-rose-400">虛擬化平台</span>
                </div>
                <p className="text-xs text-[#8b949e] leading-relaxed">KubeVirt 的 VMI 生命週期、virt-controller / handler / launcher 三層架構。</p>
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
          {PROJECT_IDS.length === 0 ? (
            <div className="rounded-2xl border border-dashed border-[#30363d] p-10 text-center text-[#8b949e]">
              尚未加入任何專案。請依 <code className="text-[#2f81f7]">BOOTSTRAP.md</code> 加入。
            </div>
          ) : (
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
          )}
        </section>

        {/* Footer */}
        <footer className="px-6 py-10 border-t border-[#30363d] text-center text-xs text-[#8b949e]">
          框架 fork 自{' '}
          <a href="https://github.com/hwchiu/molearn" target="_blank" rel="noopener noreferrer"
            className="text-[#2f81f7] hover:underline">
            hwchiu/molearn
          </a>
          ，感謝 @hwchiu。
        </footer>
      </main>
    </div>
  )
}
