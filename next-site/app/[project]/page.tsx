import Link from 'next/link'
import { getProject, PROJECT_IDS } from '@/lib/projects'
import { notFound } from 'next/navigation'
import { ExternalLink, Map, BookOpen, HelpCircle, Lightbulb, ArrowRight } from 'lucide-react'
import { ProjectStory } from '@/components/ProjectStory'

export function generateStaticParams() {
  return PROJECT_IDS.map(id => ({ project: id }))
}

const PATH_CONFIG = [
  {
    key: 'beginner' as const,
    label: '🟢 初學者',
    subtitle: '第一次接觸此專案的朋友',
    borderColor: 'border-green-500/30',
    bgColor: 'bg-green-500/5',
    textColor: 'text-green-400',
    dotColor: 'bg-green-400',
  },
  {
    key: 'intermediate' as const,
    label: '🟡 中階工程師',
    subtitle: '已懂 Kubernetes，要學此 Provider',
    borderColor: 'border-yellow-500/30',
    bgColor: 'bg-yellow-500/5',
    textColor: 'text-yellow-400',
    dotColor: 'bg-yellow-400',
  },
  {
    key: 'advanced' as const,
    label: '🔴 資深工程師',
    subtitle: '要深度貢獻或 debug',
    borderColor: 'border-red-500/30',
    bgColor: 'bg-red-500/5',
    textColor: 'text-red-400',
    dotColor: 'bg-red-400',
  },
]

export default function ProjectPage({ params }: { params: { project: string } }) {
  const project = getProject(params.project)
  if (!project) notFound()

  const colorMap: Record<string, string> = {
    blue: 'text-blue-400 border-blue-500',
    orange: 'text-orange-400 border-orange-500',
    purple: 'text-purple-400 border-purple-500',
  }
  const accentColor = colorMap[project.color] || 'text-blue-400 border-blue-500'

  return (
    <div className="max-w-4xl mx-auto px-8 py-10">

      {/* Header */}
      <div className="mb-8">
        <div className="flex items-center gap-3 mb-4">
          <div className={`inline-flex items-center gap-2 px-3 py-1 rounded-full border text-xs font-mono ${accentColor}`}>
            {project.shortName}
          </div>
          <span className={`px-2.5 py-1 rounded-full text-xs border ${project.difficultyColor}`}>
            {project.difficulty}
          </span>
        </div>
        <h1 className="text-4xl font-bold text-white mb-3">{project.displayName}</h1>
        <p className="text-lg text-[#8b949e] mb-4">{project.description}</p>
        <a href={project.githubUrl} target="_blank" rel="noopener noreferrer"
          className="inline-flex items-center gap-1.5 text-sm text-[#2f81f7] hover:underline">
          <ExternalLink size={13} /> GitHub Repository
        </a>
      </div>

      {/* Quick Understanding */}
      <div className="mb-8 rounded-xl border border-[#30363d] bg-[#161b22] p-6">
        <h2 className="text-base font-semibold text-white mb-3 flex items-center gap-2">
          <Lightbulb size={16} className="text-yellow-400" />
          快速理解：這個專案解決什麼問題？
        </h2>
        <p className="text-sm text-[#8b949e] leading-relaxed">{project.problemStatement}</p>
      </div>

      {/* Story */}
      <ProjectStory story={project.story} />

      {/* Navigation Cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
        <Link href={`/${project.id}/feature-map`}
          className="group flex flex-col gap-2 p-5 rounded-xl border border-[#30363d] bg-[#161b22] hover:border-[#2f81f7] transition-colors">
          <Map size={20} className="text-[#2f81f7]" />
          <div className="font-semibold text-white">功能地圖</div>
          <div className="text-sm text-[#8b949e]">互動式元件關係圖，了解各功能模組如何協作</div>
        </Link>
        <Link href={`/${project.id}/features/${project.features[0]}`}
          className="group flex flex-col gap-2 p-5 rounded-xl border border-[#30363d] bg-[#161b22] hover:border-[#2f81f7] transition-colors">
          <BookOpen size={20} className="text-[#2f81f7]" />
          <div className="font-semibold text-white">功能說明 ({project.features.length})</div>
          <div className="text-sm text-[#8b949e]">深入解析每個功能模組的設計、實作與原始碼</div>
        </Link>
        <Link href={`/${project.id}/quiz`}
          className="group flex flex-col gap-2 p-5 rounded-xl border border-[#30363d] bg-[#161b22] hover:border-[#2f81f7] transition-colors">
          <HelpCircle size={20} className="text-[#2f81f7]" />
          <div className="font-semibold text-white">互動測驗</div>
          <div className="text-sm text-[#8b949e]">測試你對此專案的理解程度</div>
        </Link>
      </div>

      {/* Learning Paths */}
      <div className="mb-10">
        <h2 className="text-base font-semibold text-white mb-4">建議學習路徑</h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          {PATH_CONFIG.map(cfg => {
            const steps = project.learningPaths[cfg.key]
            return (
              <div key={cfg.key} className={`rounded-xl border p-4 ${cfg.borderColor} ${cfg.bgColor}`}>
                <div className={`text-xs font-bold mb-0.5 ${cfg.textColor}`}>{cfg.label}</div>
                <div className="text-xs text-[#8b949e] mb-3">{cfg.subtitle}</div>
                <ol className="space-y-2.5">
                  {steps.map((step, i) => (
                    <li key={step.slug}>
                      <Link href={`/${project.id}/features/${step.slug}`}
                        className="group/step flex items-start gap-2">
                        <span className={`mt-1 w-1.5 h-1.5 rounded-full flex-shrink-0 ${cfg.dotColor}`}></span>
                        <div>
                          <div className="flex items-center gap-1">
                            <span className="text-xs font-semibold text-[#e6edf3] group-hover/step:text-[#2f81f7] transition-colors">
                              {i + 1}. {step.slug}
                            </span>
                            <ArrowRight size={10} className="text-[#8b949e] opacity-0 group-hover/step:opacity-100 transition-opacity" />
                          </div>
                          <div className="text-xs text-[#8b949e] leading-relaxed">{step.note}</div>
                        </div>
                      </Link>
                    </li>
                  ))}
                </ol>
              </div>
            )
          })}
        </div>
      </div>

      {/* All Features */}
      <div>
        <h2 className="text-base font-semibold text-white mb-4">所有功能模組</h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
          {project.features.map((slug, i) => (
            <Link key={slug} href={`/${project.id}/features/${slug}`}
              className="flex items-center gap-3 p-3 rounded-lg border border-[#30363d] hover:border-[#2f81f7] hover:bg-[#161b22] transition-colors">
              <span className="text-xs font-mono text-[#8b949e] w-5">{String(i + 1).padStart(2, '0')}</span>
              <span className="text-sm text-[#e6edf3]">{slug}</span>
            </Link>
          ))}
        </div>
      </div>
    </div>
  )
}
