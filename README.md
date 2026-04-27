# learning-k8s

> 個人 Kubernetes 生態系深度學習網站。從原始碼出發分析 k8s / cilium / kubevirt / ceph / multus，並附 30 天 hands-on lab。

## 涵蓋專案（預計）

| 專案 | 版本 | 主要學習目標 |
|------|------|------|
| kubernetes | v1.36.0 | 控制平面、kubelet、scheduler、kube-proxy 內部運作 |
| cilium | v1.19.3 | eBPF datapath、Network Policy、Hubble 觀測 |
| kubevirt | v1.8.2 | VMI 生命週期、virt-controller / handler / launcher、live migration |
| ceph | v19.2.3 (Squid LTS) | RADOS、CRUSH、RBD、CephFS、RGW |
| multus-cni | v4.2.4 | Meta-plugin、NetworkAttachmentDefinition、delegate flow |
| learning-plan | — | 30 天動手實驗計畫，依時間軸推進 |

## 技術 stack

| Layer | Tech |
|---|---|
| Framework | Next.js 14 App Router（`output: 'export'`） |
| Language | TypeScript |
| Styling | Tailwind CSS（GitHub Dark tokens） |
| MDX | next-mdx-remote + remark-gfm + rehype-slug |
| Syntax highlight | shiki |
| Icons | lucide-react |
| Validate | Python 3（`scripts/validate.py`） |

## 本地開發

```bash
git clone <this-repo> learning-k8s
cd learning-k8s

# 第一次或更新依賴後
make setup

# 開發伺服器
make dev   # → http://localhost:3000

# 靜態建置
make build

# 完整驗證（含 build）— commit 前必跑
make validate

# 快速驗證（不含 build）
make validate-quick
```

## 專案架構

```
learning-k8s/
├── next-site/             ← Next.js 14 + MDX 主體
│   ├── app/               ← App Router（框架，不動）
│   ├── components/        ← React 元件（框架，不動）
│   ├── lib/projects.ts    ← ★ 加新專案改這裡
│   ├── content/{project}/ ← ★ MDX 與 quiz.json 放這裡
│   └── public/diagrams/   ← 靜態圖表（PNG）
├── docs/superpowers/      ← Spec / plan 文件
├── scripts/
│   ├── validate.py
│   └── diagram-generators/
├── skills/                ← AI workflow skills（沿用 molearn）
└── versions.json          ← 各專案分析的 commit 版本
```

## 致謝

框架 fork 自 [hwchiu/molearn](https://github.com/hwchiu/molearn)，並沿用其 GitHub Dark 設計系統與 AI workflow skills。

## License

MIT — 見 `LICENSE`。
