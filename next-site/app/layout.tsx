import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  title: 'MoLearn — Kubernetes Source Deep Dive',
  description: '深入解析 Cluster API 生態系原始碼，以功能視角學習 Kubernetes 基礎設施管理',
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
