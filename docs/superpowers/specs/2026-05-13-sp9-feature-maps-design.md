# SP-9: Feature-map JSON 補齊 design

## Goal

每個 project 的 `/{project}/feature-map` 頁面目前都顯示「功能地圖尚未建立」，因為 `loadFeatureMap()` 找不到 `feature-map.json`。本 SP 為 6 個 project (kubernetes/cilium/kubevirt/ceph/multus/learning-plan) 各補一份 `feature-map.json`，模仿 hwchiu/molearn 的 schema：projectId + nodes[] + edges[]，每個 node 的 `featureSlug` 指向既有 MDX（zero-fabrication）。

## Non-goals

- 不寫 `features/feature-map.mdx` 敘事頁（page.tsx 不會合併 MDX，只 render graph）。
- 不重畫任何 PNG diagram。
- 不調整 `FeatureMapGraph.tsx` 元件本身。
- 不為 molearn 已有但本 repo 沒有的 project（cluster-api, rook 等）做任何事。

## Schema（沿用 `next-site/components/FeatureMapGraph.tsx` 既有 type）

```json
{
  "projectId": "<project-id>",
  "nodes": [
    {
      "id": "<unique-in-this-graph>",
      "label": "<繁中標籤>",
      "description": "<≤40 中文字描述>",
      "featureSlug": "<必須對應到 content/{project}/features/*.mdx>",
      "category": "infra | api | controller | lifecycle | addon | tooling",
      "position": { "x": 150|400|650, "y": 50 + 170*row }
    }
  ],
  "edges": [
    { "id": "e-<src>-<dst>", "source": "<id>", "target": "<id>", "label": "<動詞>", "animated": true (optional) }
  ]
}
```

### Constraints

- 每個 `featureSlug` 必須對應到 `next-site/content/{project}/features/<slug>.mdx`，否則點擊節點會 404。
- `id` 在單一 graph 內唯一；用 kebab-case，通常等於 `featureSlug`。
- `position.x` 限制三欄 (150/400/650) 以與 molearn 風格一致。
- `position.y` 起始 50，每列 +170；總 row 數控制在 4 列內 (≤ y=560)。
- `category` 只能用 `FeatureMapGraph.CATEGORY_COLORS` 已有的六個值。
- 邊的 `label` 用英文動詞（defines/manages/delegates/triggers/uses…），與 molearn 一致。
- `animated: true` 留給「資料流向」或「跨層觸發」的關鍵邊。

## 各 project 的 node 設計

### kubernetes (8 nodes)

| id | label | featureSlug | category | (x,y) |
|---|---|---|---|---|
| architecture | 整體架構 | architecture | infra | (400, 50) |
| api-server | API Server | api-server | api | (150, 220) |
| controllers | Controller Manager | controllers | controller | (400, 220) |
| kubelet | kubelet | kubelet | infra | (650, 220) |
| extension-interfaces | 擴展介面 | extension-interfaces | api | (400, 390) |
| cni-learning-map | CNI 子體系 | cni-learning-map | addon | (150, 560) |
| csi-learning-map | CSI 子體系 | csi-learning-map | addon | (400, 560) |
| runtime-learning-map | Runtime 子體系 | runtime-learning-map | addon | (650, 560) |

Edges: architecture→{api-server, controllers, kubelet}(defines); controllers→extension-interfaces(exposes); extension-interfaces→{cni,csi,runtime}-learning-map(specifies); kubelet→{cni,csi,runtime}-learning-map(invokes, animated)

理由：把三張 learning-map 當 gateway，避免一張圖塞 18 個 node。kubelet 與 extension-interfaces 都連到三個 learning-map 反映「規格定義」vs「執行端」兩條路徑。

### cilium (4 nodes，全 MDX 都進)

| id | featureSlug | category | (x,y) |
|---|---|---|---|
| architecture | architecture | infra | (400, 50) |
| agent-and-datapath | agent-and-datapath | controller | (400, 220) |
| identity-and-policy | identity-and-policy | api | (150, 390) |
| hubble-and-observability | hubble-and-observability | addon | (650, 390) |

Edges: architecture→agent-and-datapath(deploys); agent→identity-and-policy(enforces); agent→hubble(feeds, animated); identity→hubble(observed by)

### kubevirt (6 nodes，全 MDX 都進)

| id | featureSlug | category | (x,y) |
|---|---|---|---|
| architecture | architecture | infra | (400, 50) |
| controllers | controllers | controller | (150, 220) |
| virt-handler-and-launcher | virt-handler-and-launcher | controller | (650, 220) |
| live-migration | live-migration | lifecycle | (150, 390) |
| topology-spread-constraints | topology-spread-constraints | api | (400, 390) |
| windows-vm-features | windows-vm-features | addon | (650, 390) |

Edges: architecture→{controllers, virt-handler-and-launcher}(defines); controllers→virt-handler-and-launcher(delegates, animated); controllers→live-migration(coordinates); live-migration→virt-handler-and-launcher(triggers, animated); controllers→topology-spread-constraints(uses); virt-handler-and-launcher→windows-vm-features(supports)

### ceph (4 nodes，全 MDX 都進)

| id | featureSlug | category | (x,y) |
|---|---|---|---|
| architecture | architecture | infra | (400, 50) |
| osd-and-bluestore | osd-and-bluestore | lifecycle | (150, 220) |
| crush-and-placement | crush-and-placement | controller | (650, 220) |
| rbd-and-csi | rbd-and-csi | api | (400, 390) |

Edges: architecture→{osd-and-bluestore, crush-and-placement}(deploys/defines); crush-and-placement→osd-and-bluestore(maps to, animated); rbd-and-csi→crush-and-placement(queries); rbd-and-csi→osd-and-bluestore(writes via, animated)

### multus (4 nodes，全 MDX 都進)

| id | featureSlug | category | (x,y) |
|---|---|---|---|
| architecture | architecture | infra | (400, 50) |
| k8s-integration-and-status | k8s-integration-and-status | api | (150, 220) |
| delegate-and-cmdadd | delegate-and-cmdadd | controller | (650, 220) |
| thick-shim-and-daemon | thick-shim-and-daemon | lifecycle | (400, 390) |

Edges: architecture→{k8s-integration-and-status, delegate-and-cmdadd}(defines); k8s-integration-and-status→delegate-and-cmdadd(triggers); delegate-and-cmdadd→thick-shim-and-daemon(runs in, animated)

### learning-plan (5 nodes，按週聚合 30 天)

30 天逐日列為節點會塞爆畫面；改用週聚合，每個節點 link 到該週首日。

| id | label | featureSlug | category | (x,y) |
|---|---|---|---|---|
| week1 | Week 1 — 基礎 | day-01 | infra | (150, 50) |
| week2 | Week 2 — 進階 | day-08 | api | (400, 50) |
| week3 | Week 3 — 整合 | day-15 | controller | (650, 50) |
| week4 | Week 4 — 實戰 | day-22 | lifecycle | (400, 220) |
| finale | Final — 完賽總結 | day-30 | addon | (400, 390) |

Edges: week1→week2→week3→week4→finale 鏈狀，全部 animated。

## 驗收

1. `make validate` exit 0。
2. 每個 `/{project}/feature-map` 頁面不再出現「功能地圖尚未建立」。
3. 每個 graph 的所有 node 點擊後跳轉到對應 `/{project}/features/{slug}`，沒有 404。
4. 沒有 MDX 內容被改動。
