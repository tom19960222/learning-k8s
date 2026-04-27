'use client'
import ReactFlow, {
  Background,
  Controls,
  MiniMap,
  type Node,
  type Edge,
  BackgroundVariant,
} from 'reactflow'
import 'reactflow/dist/style.css'
import { useRouter } from 'next/navigation'

const CATEGORY_COLORS: Record<string, string> = {
  controller: '#2f81f7',
  api:        '#3fb950',
  lifecycle:  '#f0883e',
  addon:      '#a371f7',
  infra:      '#79c0ff',
  tooling:    '#8b949e',
}

interface FeatureMapNode {
  id: string
  label: string
  description: string
  featureSlug: string
  category: string
  position: { x: number; y: number }
}

interface FeatureMapEdge {
  id: string
  source: string
  target: string
  label?: string
  animated?: boolean
}

interface FeatureMapData {
  projectId: string
  nodes: FeatureMapNode[]
  edges: FeatureMapEdge[]
}

interface Props {
  data: FeatureMapData
  projectId: string
  compact?: boolean
}

export function FeatureMapGraph({ data, projectId, compact = false }: Props) {
  const router = useRouter()

  const nodes: Node[] = data.nodes.map(n => ({
    id: n.id,
    position: n.position,
    data: {
      label: (
        <div className="text-center px-2 py-1">
          <div className="font-semibold text-xs text-white">{n.label}</div>
          {!compact && <div className="text-[10px] text-gray-400 mt-0.5 leading-tight max-w-[140px]">{n.description}</div>}
        </div>
      ),
    },
    style: {
      background: '#161b22',
      border: `1.5px solid ${CATEGORY_COLORS[n.category] || '#30363d'}`,
      borderRadius: '8px',
      width: compact ? 120 : 180,
      cursor: 'pointer',
    },
  }))

  const edges: Edge[] = data.edges.map(e => ({
    id: e.id,
    source: e.source,
    target: e.target,
    label: e.label,
    animated: e.animated,
    style: { stroke: '#30363d' },
    labelStyle: { fill: '#8b949e', fontSize: 10 },
  }))

  const height = compact ? 300 : 600

  return (
    <div style={{ height }} className="w-full rounded-xl overflow-hidden border border-[#30363d]">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        fitView
        attributionPosition="bottom-right"
        onNodeClick={(_, node) => {
          const original = data.nodes.find(n => n.id === node.id)
          if (original) {
            router.push(`/${projectId}/features/${original.featureSlug}`)
          }
        }}
      >
        <Background variant={BackgroundVariant.Dots} color="#21262d" gap={20} />
        <Controls />
        {!compact && <MiniMap nodeColor={() => '#21262d'} maskColor="#0d111788" />}
      </ReactFlow>
    </div>
  )
}
