import { getProject, PROJECT_IDS } from '@/lib/projects'
import { loadFeatureMap } from '@/lib/content-loader'
import { notFound } from 'next/navigation'
import dynamic from 'next/dynamic'

const FeatureMapGraph = dynamic(
  () => import('@/components/FeatureMapGraph').then(m => m.FeatureMapGraph),
  { ssr: false }
)

export function generateStaticParams() {
  return PROJECT_IDS.map(id => ({ project: id }))
}

export default function FeatureMapPage({ params }: { params: { project: string } }) {
  const project = getProject(params.project)
  if (!project) notFound()

  const mapData = loadFeatureMap(project.id)
  if (!mapData) return (
    <div className="p-8 text-[#8b949e]">功能地圖尚未建立</div>
  )

  return (
    <div className="p-6">
      <h1 className="text-2xl font-bold text-white mb-2">{project.displayName} — 功能地圖</h1>
      <p className="text-sm text-[#8b949e] mb-6">點擊節點跳轉到對應的功能說明頁面</p>
      <FeatureMapGraph data={mapData} projectId={project.id} />
    </div>
  )
}
