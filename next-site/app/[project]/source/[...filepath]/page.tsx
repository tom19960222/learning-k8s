import { getProject, PROJECT_IDS } from '@/lib/projects'
import { notFound } from 'next/navigation'
import { ExternalLink } from 'lucide-react'

export function generateStaticParams() {
  // Provide one dummy entry per project so static export doesn't fail
  return PROJECT_IDS.map(project => ({
    project,
    filepath: ['README.md'],
  }))
}

export const dynamicParams = false

export default function SourcePage({ params }: { params: { project: string; filepath: string[] } }) {
  const project = getProject(params.project)
  if (!project) notFound()

  const file = params.filepath.join('/')
  const bases: Record<string, string> = {
    'cluster-api': 'https://github.com/kubernetes-sigs/cluster-api',
    'cluster-api-provider-maas': 'https://github.com/spectrocloud/cluster-api-provider-maas',
    'cluster-api-provider-metal3': 'https://github.com/metal3-io/cluster-api-provider-metal3',
  }
  const githubUrl = `${bases[project.id] ?? ''}/blob/main/${file}`

  return (
    <div className="max-w-4xl mx-auto px-8 py-10">
      <div className="mb-6">
        <div className="font-mono text-sm text-[#8b949e] mb-2">{project.shortName} / {file}</div>
        <h1 className="text-2xl font-bold text-white">{file.split('/').pop()}</h1>
      </div>
      <a href={githubUrl} target="_blank" rel="noopener noreferrer"
        className="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-[#161b22] border border-[#30363d] text-sm text-[#2f81f7] hover:border-[#2f81f7] transition-colors">
        <ExternalLink size={14} /> 在 GitHub 查看原始碼
      </a>
    </div>
  )
}
