import path from 'path'

export type ProjectId = string

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
export { REPO_ROOT }

// Empty until SP-2..SP-7 register their projects.
export const PROJECTS: Record<ProjectId, ProjectMeta> = {}

export const PROJECT_IDS: ProjectId[] = Object.keys(PROJECTS)

export function getProject(id: string): ProjectMeta | undefined {
  return PROJECTS[id]
}

/**
 * Returns PROJECT_IDS padded with a single placeholder so that
 * generateStaticParams() never returns [] when using `output: export`.
 * Next.js 14 errors on empty generateStaticParams with static export.
 * The placeholder param triggers notFound() at render time.
 */
export const PROJECT_IDS_FOR_STATIC_EXPORT: ProjectId[] =
  PROJECT_IDS.length > 0 ? PROJECT_IDS : ['__placeholder__']
