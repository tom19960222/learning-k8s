import { PROJECTS } from './projects'
import type { ProjectId } from './projects'

function baseUrl(project: ProjectId): string {
  const meta = PROJECTS[project]
  if (!meta) return ''
  return meta.githubUrl
}

export function buildGithubBlobUrl(project: ProjectId, file: string, lineStart?: number, lineEnd?: number): string {
  const base = baseUrl(project)
  if (!base) return ''
  let url = `${base}/blob/main/${file}`
  if (lineStart) url += `#L${lineStart}`
  if (lineEnd) url += `-L${lineEnd}`
  return url
}

export function buildGithubTreeUrl(project: ProjectId, dir: string): string {
  const base = baseUrl(project)
  if (!base) return ''
  return `${base}/tree/main/${dir}`
}
