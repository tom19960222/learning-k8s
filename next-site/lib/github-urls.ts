import type { ProjectId } from './projects'

const GITHUB_BASES: Record<ProjectId, string> = {
  'cluster-api': 'https://github.com/kubernetes-sigs/cluster-api',
  'cluster-api-provider-maas': 'https://github.com/spectrocloud/cluster-api-provider-maas',
  'cluster-api-provider-metal3': 'https://github.com/metal3-io/cluster-api-provider-metal3',
  'rook': 'https://github.com/rook/rook',
  'kube-ovn': 'https://github.com/kubeovn/kube-ovn',
  'kubevirt': 'https://github.com/kubevirt/kubevirt',
}

export function buildGithubBlobUrl(project: ProjectId, file: string, lineStart?: number, lineEnd?: number): string {
  const base = GITHUB_BASES[project]
  let url = `${base}/blob/main/${file}`
  if (lineStart) url += `#L${lineStart}`
  if (lineEnd) url += `-L${lineEnd}`
  return url
}

export function buildGithubTreeUrl(project: ProjectId, dir: string): string {
  return `${GITHUB_BASES[project]}/tree/main/${dir}`
}
