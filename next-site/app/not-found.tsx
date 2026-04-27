import Link from 'next/link'
export default function NotFound() {
  return (
    <div className="min-h-screen flex items-center justify-center">
      <div className="text-center">
        <h1 className="text-6xl font-bold text-[#2f81f7] mb-4">404</h1>
        <p className="text-[#8b949e] mb-6">找不到此頁面</p>
        <Link href="/" className="text-[#2f81f7] hover:underline">返回首頁</Link>
      </div>
    </div>
  )
}
