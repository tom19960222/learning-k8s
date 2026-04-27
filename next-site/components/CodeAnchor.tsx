import { extractCodeSnippet } from '@/lib/code-extractor'
import { CodeAnchorClient } from './CodeAnchorClient'
import type { ProjectId } from '@/lib/projects'
import type { ReactNode } from 'react'

interface Props {
  project: ProjectId
  file: string
  lineStart: number
  lineEnd: number
  fn?: string
  label?: string
  children?: ReactNode
}

export async function CodeAnchor({ project, file, lineStart, lineEnd, fn, label, children }: Props) {
  const snippet = await extractCodeSnippet(project, file, lineStart, lineEnd, fn)
  return <CodeAnchorClient snippet={snippet} label={label}>{children}</CodeAnchorClient>
}
