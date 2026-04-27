import { notFound } from 'next/navigation'
import { SiteHeader } from '@/components/SiteHeader'
import { ProjectSidebar } from '@/components/ProjectSidebar'
import { getProject, PROJECT_IDS } from '@/lib/projects'
import type { ProjectId } from '@/lib/projects'

export function generateStaticParams() {
  return PROJECT_IDS.map(id => ({ project: id }))
}

export default function ProjectLayout({
  children,
  params,
}: {
  children: React.ReactNode
  params: { project: string }
}) {
  const project = getProject(params.project)
  if (!project) notFound()

  return (
    <div className="min-h-screen flex flex-col">
      <SiteHeader currentProject={project.id} />
      <div className="flex flex-1">
        <ProjectSidebar project={project.id as ProjectId} />
        <main className="flex-1 min-w-0">{children}</main>
      </div>
    </div>
  )
}
