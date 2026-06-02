// learning-k8s defaults to root deployment.
// If deploying to GitHub Pages under a subpath, set NEXT_PUBLIC_BASE_PATH at build time.
import { execSync } from 'node:child_process'

const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? ''

// Capture the git short SHA at build time so every page can show which commit it was built from.
// Falls back to an env override (useful in CI where .git may be absent) then to 'unknown'.
function resolveGitSha() {
  if (process.env.NEXT_PUBLIC_GIT_SHA) return process.env.NEXT_PUBLIC_GIT_SHA
  try {
    const sha = execSync('git rev-parse --short HEAD', { encoding: 'utf8' }).trim()
    let dirty = ''
    try {
      if (execSync('git status --porcelain', { encoding: 'utf8' }).trim()) dirty = '-dirty'
    } catch {}
    return sha + dirty
  } catch {
    return 'unknown'
  }
}

const gitSha = resolveGitSha()

const nextConfig = {
  output: 'export',
  trailingSlash: true,
  images: { unoptimized: true },
  basePath,
  assetPrefix: basePath,
  env: {
    NEXT_PUBLIC_BASE_PATH: basePath,
    NEXT_PUBLIC_GIT_SHA: gitSha,
  },
}

export default nextConfig
