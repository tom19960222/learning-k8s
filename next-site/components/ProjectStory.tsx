import { ChevronRight } from 'lucide-react'

interface StoryScene {
  step: number
  icon: string
  actor: string
  action: string
  detail: string
}

interface Story {
  protagonist: string
  challenge: string
  scenes: StoryScene[]
  outcome: string
}

export function ProjectStory({ story }: { story: Story }) {
  return (
    <div className="mb-10">
      <h2 className="text-base font-semibold text-white mb-4 flex items-center gap-2">
        📖 一個真實場景
      </h2>
      <div className="rounded-xl border border-[#30363d] bg-[#0d1117] overflow-hidden">
        {/* Protagonist + Challenge */}
        <div className="px-6 py-5 border-b border-[#30363d] bg-[#161b22]">
          <div className="flex items-start gap-3">
            <div>
              <div className="text-sm font-semibold text-white mb-1">{story.protagonist}</div>
              <p className="text-sm text-[#8b949e] leading-relaxed">{story.challenge}</p>
            </div>
          </div>
        </div>

        {/* Story Scenes */}
        <div className="px-6 py-5 space-y-0">
          {story.scenes.map((scene, idx) => (
            <div key={scene.step} className="flex gap-4">
              {/* Timeline */}
              <div className="flex flex-col items-center">
                <div className="w-9 h-9 rounded-full bg-[#161b22] border border-[#30363d] flex items-center justify-center text-lg flex-shrink-0">
                  {scene.icon}
                </div>
                {idx < story.scenes.length - 1 && (
                  <div className="w-px flex-1 bg-[#30363d] my-1 min-h-[24px]" />
                )}
              </div>

              {/* Content */}
              <div className={`pb-5 ${idx === story.scenes.length - 1 ? '' : ''}`}>
                <div className="flex items-center gap-2 mb-1">
                  <span className="text-xs font-mono text-[#2f81f7] bg-[#2f81f7]/10 px-2 py-0.5 rounded">
                    {scene.actor}
                  </span>
                </div>
                <p className="text-sm font-medium text-[#e6edf3] mb-1">{scene.action}</p>
                <p className="text-xs text-[#8b949e] leading-relaxed">{scene.detail}</p>
              </div>
            </div>
          ))}
        </div>

        {/* Outcome */}
        <div className="px-6 py-4 bg-[#0f2a1a] border-t border-[#238636]/30">
          <div className="flex items-start gap-2">
            <span className="text-green-400 text-base flex-shrink-0">🎉</span>
            <p className="text-sm text-[#3fb950] leading-relaxed">{story.outcome}</p>
          </div>
        </div>
      </div>
    </div>
  )
}
