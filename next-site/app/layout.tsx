import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  title: 'Kubernetes 深潛 — k8s / cilium / kubevirt / ceph / multus 原始碼學習站',
  description: '從原始碼深度分析 Kubernetes 與其生態系，附 30 天 hands-on lab',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="zh-TW" className="dark">
      <body className="antialiased min-h-screen">
        {children}
      </body>
    </html>
  )
}
