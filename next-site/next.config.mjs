// learning-k8s defaults to root deployment.
// If deploying to GitHub Pages under a subpath, set NEXT_PUBLIC_BASE_PATH at build time.
const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? ''

const nextConfig = {
  output: 'export',
  trailingSlash: true,
  images: { unoptimized: true },
  basePath,
  assetPrefix: basePath,
  env: {
    NEXT_PUBLIC_BASE_PATH: basePath,
  },
}

export default nextConfig
