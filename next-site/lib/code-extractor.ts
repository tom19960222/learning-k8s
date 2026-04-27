import { readFileSync, existsSync } from 'fs'
import path from 'path'
import { codeToHtml } from 'shiki'
import type { ProjectId } from './projects'

export interface CodeSnippet {
  highlightedHtml: string
  rawCode: string
  language: string
  filename: string
  lineStart: number
  lineEnd: number
  functionName?: string
  githubUrl: string
}

function detectLang(file: string): string {
  if (file.endsWith('.go')) return 'go'
  if (file.endsWith('.yaml') || file.endsWith('.yml')) return 'yaml'
  if (file.endsWith('.sh')) return 'bash'
  if (file.endsWith('.json')) return 'json'
  return 'text'
}

function buildGithubUrl(project: ProjectId, file: string, start: number, end: number): string {
  const bases: Record<ProjectId, string> = {
    'cluster-api': 'https://github.com/kubernetes-sigs/cluster-api',
    'cluster-api-provider-maas': 'https://github.com/spectrocloud/cluster-api-provider-maas',
    'cluster-api-provider-metal3': 'https://github.com/metal3-io/cluster-api-provider-metal3',
    'rook': 'https://github.com/rook/rook',
    'kube-ovn': 'https://github.com/kubeovn/kube-ovn',
    'kubevirt': 'https://github.com/kubevirt/kubevirt',
  }
  return `${bases[project]}/blob/main/${file}#L${start}-L${end}`
}

export async function extractCodeSnippet(
  project: ProjectId,
  file: string,
  lineStart: number,
  lineEnd: number,
  functionName?: string
): Promise<CodeSnippet> {
  const { PROJECTS } = await import('./projects')
  const submodulePath = PROJECTS[project].submodulePath
  const filePath = path.join(submodulePath, file)

  let rawCode: string
  if (existsSync(filePath)) {
    const fullContent = readFileSync(filePath, 'utf-8')
    const lines = fullContent.split('\n')
    const snippet = lines.slice(lineStart - 1, lineEnd)
    const minIndent = snippet
      .filter(l => l.trim())
      .reduce((min, l) => Math.min(min, l.match(/^(\s*)/)?.[1].length ?? 0), Infinity)
    rawCode = snippet.map(l => l.slice(minIndent === Infinity ? 0 : minIndent)).join('\n')
  } else {
    rawCode = `// 原始碼檔案未找到: ${file}\n// 請確認 git submodules 已初始化:\n// git submodule update --init --recursive`
  }

  const lang = detectLang(file)
  const highlightedHtml = await codeToHtml(rawCode, { lang, theme: 'github-dark' })

  return {
    highlightedHtml,
    rawCode,
    language: lang,
    filename: file,
    lineStart,
    lineEnd,
    functionName,
    githubUrl: buildGithubUrl(project, file, lineStart, lineEnd),
  }
}
