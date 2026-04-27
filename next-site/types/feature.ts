export interface FeatureMapNode {
  id: string
  label: string
  description: string
  featureSlug: string
  category: 'controller' | 'api' | 'lifecycle' | 'addon' | 'infra' | 'tooling'
  position: { x: number; y: number }
}

export interface FeatureMapEdge {
  id: string
  source: string
  target: string
  label?: string
  animated?: boolean
}

export interface FeatureMap {
  projectId: string
  nodes: FeatureMapNode[]
  edges: FeatureMapEdge[]
}

export interface FeatureFrontmatter {
  title: string
  description?: string
  weight?: number
  tags?: string[]
}
