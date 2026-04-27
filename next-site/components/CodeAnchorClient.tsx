'use client'
import { useState } from 'react'
import { ChevronDown, ChevronRight, ExternalLink, Copy, Check } from 'lucide-react'
import type { CodeSnippet } from '@/lib/code-extractor'
import type { ReactNode } from 'react'

interface Props {
  snippet: CodeSnippet
  label?: string
  children?: ReactNode
}

export function CodeAnchorClient({ snippet, label, children }: Props) {
  const [open, setOpen] = useState(false)
  const [copied, setCopied] = useState(false)

  const handleCopy = async () => {
    await navigator.clipboard.writeText(snippet.rawCode)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div className="my-3 rounded-lg border border-[#30363d] overflow-hidden">
      <button
        onClick={() => setOpen(!open)}
        className="w-full flex items-center gap-2 px-3 py-2 bg-[#161b22] hover:bg-[#21262d] transition-colors text-left"
      >
        {open ? <ChevronDown size={14} className="text-[#2f81f7]" /> : <ChevronRight size={14} className="text-[#2f81f7]" />}
        <span className="font-mono text-xs text-[#2f81f7]">
          {snippet.functionName ? `${snippet.functionName}()` : snippet.filename}
        </span>
        <span className="text-xs text-[#8b949e]">
          L{snippet.lineStart}–{snippet.lineEnd}
        </span>
        {label && <span className="text-xs text-[#8b949e] ml-2">— {label}</span>}
        {children && <span className="text-xs text-white ml-2">{children}</span>}
        <a
          href={snippet.githubUrl}
          target="_blank"
          rel="noopener noreferrer"
          onClick={e => e.stopPropagation()}
          className="ml-auto text-[#8b949e] hover:text-[#2f81f7]"
        >
          <ExternalLink size={12} />
        </a>
      </button>
      {open && (
        <div className="relative">
          <button
            onClick={handleCopy}
            className="absolute top-2 right-2 z-10 p-1.5 rounded bg-[#21262d] text-[#8b949e] hover:text-white"
          >
            {copied ? <Check size={12} /> : <Copy size={12} />}
          </button>
          <div
            className="overflow-x-auto"
            dangerouslySetInnerHTML={{ __html: snippet.highlightedHtml }}
          />
        </div>
      )}
    </div>
  )
}
