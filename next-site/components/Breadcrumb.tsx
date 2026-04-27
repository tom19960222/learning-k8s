import Link from 'next/link'
import { ChevronRight } from 'lucide-react'

interface BreadcrumbItem { label: string; href?: string }
export function Breadcrumb({ items }: { items: BreadcrumbItem[] }) {
  return (
    <nav className="flex items-center gap-1 text-xs text-[#8b949e] mb-4">
      {items.map((item, i) => (
        <span key={i} className="flex items-center gap-1">
          {i > 0 && <ChevronRight size={10} />}
          {item.href ? <Link href={item.href} className="hover:text-white">{item.label}</Link> : <span>{item.label}</span>}
        </span>
      ))}
    </nav>
  )
}
