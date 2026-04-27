'use client'

import { useEffect, useState } from 'react'
import type { Heading } from '@/lib/extract-headings'

export function TableOfContents({ headings }: { headings: Heading[] }) {
  const [activeId, setActiveId] = useState<string>('')

  useEffect(() => {
    if (headings.length === 0) return

    const observer = new IntersectionObserver(
      (entries) => {
        // Find the topmost intersecting heading
        const visible = entries
          .filter(e => e.isIntersecting)
          .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)
        if (visible.length > 0) setActiveId(visible[0].target.id)
      },
      { rootMargin: '-60px 0px -66% 0px', threshold: 0 }
    )

    headings.forEach(({ id }) => {
      const el = document.getElementById(id)
      if (el) observer.observe(el)
    })

    return () => observer.disconnect()
  }, [headings])

  if (headings.length === 0) return null

  return (
    <aside className="hidden xl:block w-64 flex-shrink-0">
      <div className="sticky top-[3.5rem] max-h-[calc(100vh-3.5rem)] overflow-y-auto py-6 px-3">
        <p className="text-xs font-semibold uppercase tracking-wider text-[#8b949e] mb-3 px-2">
          本頁目錄
        </p>
        <nav>
          <ul className="space-y-0.5">
            {headings.map(({ id, text, level }) => (
              <li key={id}>
                <a
                  href={`#${id}`}
                  onClick={(e) => {
                    e.preventDefault()
                    document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
                    setActiveId(id)
                  }}
                  className={`block text-[0.8rem] leading-snug py-1.5 px-2 rounded transition-colors border-l-2 ${
                    level === 3 ? 'ml-3' : ''
                  } ${
                    activeId === id
                      ? 'border-[#2f81f7] text-[#2f81f7] font-medium bg-[#2f81f7]/10'
                      : 'border-transparent text-[#8b949e] hover:text-white hover:border-[#484f58]'
                  }`}
                >
                  {text}
                </a>
              </li>
            ))}
          </ul>
        </nav>
      </div>
    </aside>
  )
}
