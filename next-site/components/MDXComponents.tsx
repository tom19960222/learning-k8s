import { CodeAnchor } from './CodeAnchor'
import { Callout } from './Callout'
import { QuizQuestion } from './QuizQuestion'

export const MDX_COMPONENTS = {
  CodeAnchor,
  Callout,
  QuizQuestion,
  img: ({ src, alt, ...props }: any) => {
    const base = process.env.NEXT_PUBLIC_BASE_PATH || ''
    const resolvedSrc = src?.startsWith('/') ? `${base}${src}` : src
    return (
      <img
        src={resolvedSrc}
        alt={alt}
        className="max-w-full rounded-lg my-6 border border-[#30363d]"
        {...props}
      />
    )
  },
  h1: (props: any) => <h1 className="text-3xl font-bold text-white mt-8 mb-4" {...props} />,
  h2: (props: any) => <h2 className="text-2xl font-bold text-white mt-8 mb-3 border-b border-[#30363d] pb-2" {...props} />,
  h3: (props: any) => <h3 className="text-xl font-semibold text-white mt-6 mb-2" {...props} />,
  h4: (props: any) => <h4 className="text-lg font-semibold text-[#e6edf3] mt-4 mb-1" {...props} />,
  p: (props: any) => <p className="text-[#e6edf3] leading-7 mb-4" {...props} />,
  ul: (props: any) => <ul className="list-disc pl-6 mb-4 space-y-1 text-[#e6edf3]" {...props} />,
  ol: (props: any) => <ol className="list-decimal pl-6 mb-4 space-y-1 text-[#e6edf3]" {...props} />,
  li: (props: any) => <li className="leading-7" {...props} />,
  // Inline code (no data-language = not a fenced block)
  code: ({ children, className, 'data-language': dataLanguage, ...props }: any) => {
    if (dataLanguage) {
      // Inside a fenced block — rehype-pretty-code already highlighted it
      return <code className={className} {...props}>{children}</code>
    }
    return <code className="bg-[#21262d] text-[#e3b341] px-1.5 py-0.5 rounded text-sm font-mono" {...props}>{children}</code>
  },
  // Fenced code blocks — show a language badge in top-right
  pre: ({ children, 'data-language': language, ...props }: any) => (
    <div className="relative mb-4">
      {language && (
        <span className="absolute top-2 right-3 text-[10px] font-mono uppercase tracking-widest text-[#6e7681] select-none z-10">
          {language}
        </span>
      )}
      <pre
        className="rounded-lg overflow-x-auto p-4 text-sm leading-relaxed border border-[#30363d]"
        {...props}
      >{children}</pre>
    </div>
  ),
  table: (props: any) => <div className="overflow-x-auto mb-4"><table className="w-full border-collapse text-sm" {...props} /></div>,
  th: (props: any) => <th className="bg-[#21262d] text-[#e6edf3] p-2 border border-[#30363d] text-left font-semibold" {...props} />,
  td: (props: any) => <td className="p-2 border border-[#30363d] text-[#8b949e]" {...props} />,
  a: (props: any) => <a className="text-[#2f81f7] hover:underline" {...props} />,
  blockquote: (props: any) => <blockquote className="border-l-4 border-[#2f81f7] pl-4 italic text-[#8b949e] my-4" {...props} />,
  strong: (props: any) => <strong className="text-white font-semibold" {...props} />,
  hr: () => <hr className="border-[#30363d] my-8" />,
}
