import Link from 'next/link'
import { BookOpen, Github } from 'lucide-react'
import type { ProjectId } from '@/lib/projects'
import { PROJECTS, PROJECT_IDS } from '@/lib/projects'

interface Props {
  currentProject?: ProjectId
}

export function SiteHeader({ currentProject }: Props) {
  return (
    <header className="sticky top-0 z-50 border-b border-[#30363d] bg-[#0d1117]/90 backdrop-blur">
      <div className="max-w-screen-2xl mx-auto px-6 h-14 flex items-center gap-4">
        <Link href="/" className="flex items-center gap-2 font-bold text-white hover:text-[#2f81f7] transition-colors shrink-0">
          <BookOpen size={18} className="text-[#2f81f7]" />
          <span>MoLearn</span>
        </Link>
        <span className="text-[#30363d] shrink-0">/</span>

        {/* Project switcher */}
        <nav className="flex items-center gap-1">
          {PROJECT_IDS.map(id => {
            const p = PROJECTS[id]
            const isActive = id === currentProject
            return (
              <Link
                key={id}
                href={`/${id}`}
                className={`px-3 py-1 rounded text-sm font-medium transition-colors ${
                  isActive
                    ? `bg-[#161b22] border ${p.accentClass}`
                    : 'text-[#8b949e] hover:text-white hover:bg-[#161b22]'
                }`}
              >
                {p.shortName}
              </Link>
            )
          })}
        </nav>

        <div className="ml-auto flex items-center gap-3">
          <a href="https://github.com/hwchiu/molearn" target="_blank" rel="noopener noreferrer"
            className="text-[#8b949e] hover:text-white transition-colors">
            <Github size={18} />
          </a>
        </div>
      </div>
    </header>
  )
}
