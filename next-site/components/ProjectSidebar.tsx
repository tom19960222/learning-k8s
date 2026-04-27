'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { PROJECTS } from '@/lib/projects'
import type { ProjectId } from '@/lib/projects'

interface Props {
  project: ProjectId
}

const FEATURE_LABELS: Record<string, string> = {
  'architecture': '系統架構總覽',
  'controller-core': 'Core Controllers',
  'controller-kcp': 'KubeadmControlPlane',
  'controller-topology': 'Topology Controller',
  'api-cluster-machine': 'Cluster & Machine API',
  'api-machineset-machinedeployment': 'MachineSet & Deployment',
  'api-kubeadm-controlplane': 'KubeadmControlPlane API',
  'bootstrap-kubeadmconfig': 'Bootstrap Config',
  'machine-lifecycle': 'Machine 生命週期',
  'machine-health-check': '健康檢查',
  'clusterclass-topology': 'ClusterClass 拓樸',
  'addons-clusterresourceset': 'ClusterResourceSet',
  'provider-contracts-runtime-hooks': 'Provider 合約',
  'clusterctl': 'clusterctl CLI',
  'controllers': 'Controllers',
  'api-types': 'API Types',
  'integration': 'MAAS 整合',
  'bmh-lifecycle': 'BMH 生命週期',
  'crds-cluster': 'Cluster CRDs',
  'crds-machine': 'Machine CRDs',
  'labelsync': 'Label Sync',
  'node-reuse': 'Node Reuse',
  'data-templates': 'Data Templates',
  'ipam': 'IPAM',
  'remediation': 'Remediation',
  'advanced-features': '進階功能',
}

const USECASE_LABELS: Record<string, string> = {
  'multi-team-platform': '多團隊 Cluster 管理',
  'cluster-self-healing': '自動修復與版本升級',
  'on-demand-baremetal': '按需分配裸機環境',
  'edge-auto-recovery': '邊緣節點自動修復',
  'bulk-os-upgrade': '批量裸機 OS 升級',
  'stateful-storage': '有狀態應用持久化存儲',
  'vm-container-mixed': 'VM 與 Container 混合部署',
  'multi-tenant-network': '多租戶網路隔離',
}

export function ProjectSidebar({ project }: Props) {
  const proj = PROJECTS[project]
  const pathname = usePathname()

  const isActive = (slug: string) => !!pathname?.endsWith(`/features/${slug}`)
  const isUseCaseActive = (slug: string) => !!pathname?.endsWith(`/usecases/${slug}`)
  const isFeatureMap = !!pathname?.endsWith('/feature-map')
  const isQuiz = !!pathname?.endsWith('/quiz')

  return (
    <aside className="w-56 flex-shrink-0 border-r border-[#30363d] h-[calc(100vh-3.5rem)] sticky top-14 overflow-y-auto py-6 px-3">
      {/* Project title */}
      <div className="mb-5 px-2">
        <Link href={`/${project}`} className="text-sm font-bold text-white hover:text-[#2f81f7] transition-colors block leading-tight">
          {proj.shortName}
        </Link>
        <span className="text-xs text-[#8b949e] mt-0.5 block">{proj.displayName}</span>
      </div>

      <nav className="space-y-0.5">
        {/* Feature map */}
        <Link href={`/${project}/feature-map`}
          className={`flex items-center gap-2 px-2 py-2 rounded-md text-sm transition-colors ${
            isFeatureMap
              ? 'bg-[#21262d] text-white font-medium'
              : 'text-[#8b949e] hover:bg-[#21262d] hover:text-white'
          }`}>
          <span>🗺</span>
          <span>功能地圖</span>
        </Link>

        {/* Use Cases */}
        {proj.usecases.length > 0 && (
          <div className="pt-4">
            <p className="px-2 text-[10px] font-semibold uppercase tracking-widest text-[#484f58] mb-1 flex items-center gap-1.5">
              <span>🎯</span>
              <span>使用情境</span>
            </p>
            <div className="space-y-0.5">
              {proj.usecases.map(slug => (
                <Link key={slug} href={`/${project}/usecases/${slug}`}
                  className={`block px-2 py-1.5 rounded-md text-[0.8rem] transition-colors ${
                    isUseCaseActive(slug)
                      ? 'bg-[#2da44e]/15 text-[#2da44e] font-medium border-l-2 border-[#2da44e] pl-[6px]'
                      : 'text-[#8b949e] hover:bg-[#21262d] hover:text-white'
                  }`}>
                  {USECASE_LABELS[slug] || slug}
                </Link>
              ))}
            </div>
          </div>
        )}

        {/* Grouped features */}
        {proj.featureGroups.map((group) => (
          <div key={group.label} className="pt-4">
            <p className="px-2 text-[10px] font-semibold uppercase tracking-widest text-[#484f58] mb-1 flex items-center gap-1.5">
              <span>{group.icon}</span>
              <span>{group.label}</span>
            </p>
            <div className="space-y-0.5">
              {group.slugs.map(slug => (
                <Link key={slug} href={`/${project}/features/${slug}`}
                  className={`block px-2 py-1.5 rounded-md text-[0.8rem] transition-colors ${
                    isActive(slug)
                      ? 'bg-[#2f81f7]/15 text-[#2f81f7] font-medium border-l-2 border-[#2f81f7] pl-[6px]'
                      : 'text-[#8b949e] hover:bg-[#21262d] hover:text-white'
                  }`}>
                  {FEATURE_LABELS[slug] || slug}
                </Link>
              ))}
            </div>
          </div>
        ))}

        {/* Quiz */}
        <div className="pt-4">
          <p className="px-2 text-[10px] font-semibold uppercase tracking-widest text-[#484f58] mb-1 flex items-center gap-1.5">
            <span>🧪</span>
            <span>自我測驗</span>
          </p>
          <Link href={`/${project}/quiz`}
            className={`block px-2 py-1.5 rounded-md text-[0.8rem] transition-colors ${
              isQuiz
                ? 'bg-[#21262d] text-white font-medium'
                : 'text-[#8b949e] hover:bg-[#21262d] hover:text-white'
            }`}>
            互動測驗
          </Link>
        </div>
      </nav>
    </aside>
  )
}
