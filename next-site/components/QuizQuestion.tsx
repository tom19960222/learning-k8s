'use client'
import { useState } from 'react'
import { CheckCircle, XCircle } from 'lucide-react'

interface Props {
  question: string
  options: string[]
  answer: number
  explanation: string
}

export function QuizQuestion({ question, options, answer, explanation }: Props) {
  const [selected, setSelected] = useState<number | null>(null)
  const isAnswered = selected !== null
  const isCorrect = selected === answer

  return (
    <div className="my-6 rounded-xl border border-[#30363d] bg-[#161b22] overflow-hidden">
      <div className="px-5 py-4 border-b border-[#30363d]">
        <p className="text-white font-medium leading-7">{question}</p>
      </div>
      <div className="p-4 space-y-2">
        {options.map((opt, i) => {
          let cls = 'w-full text-left px-4 py-3 rounded-lg border text-sm transition-colors '
          if (!isAnswered) cls += 'border-[#30363d] hover:border-[#2f81f7] hover:bg-[#21262d] text-[#e6edf3]'
          else if (i === answer) cls += 'border-green-500 bg-green-500/10 text-green-400'
          else if (i === selected) cls += 'border-red-500 bg-red-500/10 text-red-400'
          else cls += 'border-[#30363d] text-[#8b949e] opacity-50'

          return (
            <button key={i} className={cls} onClick={() => !isAnswered && setSelected(i)} disabled={isAnswered}>
              <span className="mr-2 font-mono text-xs opacity-60">{String.fromCharCode(65 + i)}.</span>
              {opt}
            </button>
          )
        })}
      </div>
      {isAnswered && (
        <div className={`px-5 py-4 border-t ${isCorrect ? 'border-green-500/30 bg-green-500/5' : 'border-red-500/30 bg-red-500/5'}`}>
          <div className="flex items-start gap-2">
            {isCorrect
              ? <CheckCircle size={16} className="text-green-400 mt-0.5 flex-shrink-0" />
              : <XCircle size={16} className="text-red-400 mt-0.5 flex-shrink-0" />}
            <p className="text-sm text-[#e6edf3]">{explanation}</p>
          </div>
        </div>
      )}
    </div>
  )
}
