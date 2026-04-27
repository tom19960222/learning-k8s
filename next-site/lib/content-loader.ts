import { readFileSync, existsSync } from 'fs'
import path from 'path'
import matter from 'gray-matter'
import type { ProjectId } from './projects'

const CONTENT_ROOT = path.join(process.cwd(), 'content')

export function loadFeatureSource(project: ProjectId, slug: string): string {
  const mdxPath = path.join(CONTENT_ROOT, project, 'features', `${slug}.mdx`)
  if (!existsSync(mdxPath)) return ''
  return readFileSync(mdxPath, 'utf-8')
}

export function loadFeatureMatter(project: ProjectId, slug: string) {
  const source = loadFeatureSource(project, slug)
  if (!source) return { frontmatter: {}, content: '' }
  const { data, content } = matter(source)
  return { frontmatter: data, content }
}

export function listFeatureSlugs(project: ProjectId): string[] {
  const dir = path.join(CONTENT_ROOT, project, 'features')
  if (!existsSync(dir)) return []
  const { readdirSync } = require('fs')
  return readdirSync(dir)
    .filter((f: string) => f.endsWith('.mdx'))
    .map((f: string) => f.replace(/\.mdx$/, ''))
}

export function loadUseCaseSource(project: ProjectId, slug: string): string {
  const mdxPath = path.join(CONTENT_ROOT, project, 'usecases', `${slug}.mdx`)
  if (!existsSync(mdxPath)) return ''
  return readFileSync(mdxPath, 'utf-8')
}

export function loadFeatureMap(project: ProjectId): any | null {
  const jsonPath = path.join(CONTENT_ROOT, project, 'feature-map.json')
  if (!existsSync(jsonPath)) return null
  return JSON.parse(readFileSync(jsonPath, 'utf-8'))
}

export function loadQuizData(project: ProjectId): any[] {
  const jsonPath = path.join(CONTENT_ROOT, project, 'quiz.json')
  if (!existsSync(jsonPath)) return []
  return JSON.parse(readFileSync(jsonPath, 'utf-8'))
}
