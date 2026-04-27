

const isProd = process.env.NODE_ENV === 'production'
const basePath = isProd ? '/molearn' : ''

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
