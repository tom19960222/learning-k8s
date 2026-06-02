import { GitCommit } from 'lucide-react'

// Shows which commit the site was built from, on every page (rendered once in the root layout).
// The SHA is captured at build time in next.config.mjs as NEXT_PUBLIC_GIT_SHA.
const REPO_URL = 'https://github.com/tom19960222/learning-k8s'

export function BuildVersion() {
  const sha = process.env.NEXT_PUBLIC_GIT_SHA ?? 'unknown'
  // Strip a "-dirty" suffix (or anything non-hex) before building the commit URL.
  const cleanSha = sha.replace(/[^0-9a-f].*$/i, '')
  const isLinkable = cleanSha.length > 0 && sha !== 'unknown'
  const href = isLinkable ? `${REPO_URL}/commit/${cleanSha}` : REPO_URL

  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      title={`本頁內容建置自 commit ${sha}`}
      className="fixed bottom-3 right-3 z-[60] flex items-center gap-1.5 rounded-full border border-[#30363d] bg-[#0d1117]/90 px-2.5 py-1 font-mono text-xs text-[#8b949e] backdrop-blur transition-colors hover:border-[#2f81f7] hover:text-[#2f81f7]"
    >
      <GitCommit size={13} />
      <span>{sha}</span>
    </a>
  )
}
