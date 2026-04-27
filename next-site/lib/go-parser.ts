import { readFileSync, existsSync } from 'fs'

interface GoFunction {
  name: string
  signature: string
  body: string
  lineStart: number
  lineEnd: number
  comments: string[]
}

export function extractGoFunctions(filePath: string): GoFunction[] {
  if (!existsSync(filePath)) return []
  const content = readFileSync(filePath, 'utf-8')
  const lines = content.split('\n')
  const results: GoFunction[] = []

  let i = 0
  while (i < lines.length) {
    // collect comments before func
    const comments: string[] = []
    while (i < lines.length && (lines[i].trimStart().startsWith('//') || lines[i].trim() === '')) {
      if (lines[i].trimStart().startsWith('//')) {
        comments.push(lines[i].trimStart().slice(2).trim())
      }
      i++
    }
    if (i >= lines.length) break

    const funcMatch = lines[i].match(/^func\s+(\([^)]*\)\s+)?(\w+)\s*\(/)
    if (!funcMatch) { i++; continue }

    const name = funcMatch[2]
    const signature = lines[i]
    const lineStart = i + 1
    let depth = 0
    const bodyLines: string[] = [lines[i]]
    do {
      depth += (lines[i].match(/\{/g) || []).length
      depth -= (lines[i].match(/\}/g) || []).length
      if (i > lineStart - 1) bodyLines.push(lines[i])
      if (depth > 0) i++
    } while (depth > 0 && i < lines.length)

    const lineEnd = i + 1
    results.push({ name, signature, body: bodyLines.join('\n'), lineStart, lineEnd, comments })
    i++
  }

  return results
}
