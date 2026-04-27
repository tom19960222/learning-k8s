export interface Heading {
  id: string
  text: string
  level: number
}

// Mimics github-slugger behavior (same as rehype-slug) — Unicode-aware to handle CJK
function slugify(text: string): string {
  return text
    .toLowerCase()
    .trim()
    // Keep Unicode letters (including CJK), numbers, spaces, hyphens — remove everything else
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/[\s_]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '')
}

// Strip MDX/markdown inline formatting from heading text
function stripFormatting(text: string): string {
  return text
    .replace(/`([^`]+)`/g, '$1')   // inline code
    .replace(/\*\*([^*]+)\*\*/g, '$1') // bold
    .replace(/\*([^*]+)\*/g, '$1')  // italic
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1') // links
    .trim()
}

export function extractHeadings(markdown: string): Heading[] {
  const headings: Heading[] = []
  const lines = markdown.split('\n')

  let inCodeBlock = false
  for (const line of lines) {
    if (line.startsWith('```')) {
      inCodeBlock = !inCodeBlock
      continue
    }
    if (inCodeBlock) continue

    const match = line.match(/^(#{2,3})\s+(.+)$/)
    if (match) {
      const level = match[1].length
      const raw = match[2].trim()
      const text = stripFormatting(raw)
      const id = slugify(text)
      if (id) headings.push({ id, text, level })
    }
  }

  return headings
}
