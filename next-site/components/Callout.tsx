import { Info, AlertTriangle, Lightbulb, AlertCircle } from 'lucide-react'
import type { ReactNode } from 'react'

type CalloutType = 'info' | 'warning' | 'tip' | 'danger'

interface Props {
  type?: CalloutType
  title?: string
  children: ReactNode
}

const styles: Record<CalloutType, { border: string; bg: string; icon: ReactNode; label: string }> = {
  info:    { border: 'border-blue-500/50',   bg: 'bg-blue-500/5',   icon: <Info size={15} className="text-blue-400" />,         label: '資訊' },
  warning: { border: 'border-yellow-500/50', bg: 'bg-yellow-500/5', icon: <AlertTriangle size={15} className="text-yellow-400" />, label: '注意' },
  tip:     { border: 'border-green-500/50',  bg: 'bg-green-500/5',  icon: <Lightbulb size={15} className="text-green-400" />,    label: '提示' },
  danger:  { border: 'border-red-500/50',    bg: 'bg-red-500/5',    icon: <AlertCircle size={15} className="text-red-400" />,    label: '警告' },
}

export function Callout({ type = 'info', title, children }: Props) {
  const s = styles[type]
  return (
    <div className={`my-4 rounded-lg border ${s.border} ${s.bg} p-4`}>
      <div className="flex items-center gap-2 mb-2 font-semibold text-sm">
        {s.icon}
        <span>{title || s.label}</span>
      </div>
      <div className="text-sm text-[#e6edf3] leading-7">{children}</div>
    </div>
  )
}
