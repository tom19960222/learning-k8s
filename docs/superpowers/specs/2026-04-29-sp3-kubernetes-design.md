# SP-3: kubernetes v1.36.0 原始碼分析（第一波 MVP）— Design

> **Status:** drafted under autonomous mode (使用者已授權「都用你推薦的做」). 後續 plan / implement 都接著推進，使用者醒來看總結即可。

---

## Project context

第三個子計畫，分析 kubernetes 本體原始碼。沿用 molearn 的 `skills/analyzing-source-code/SKILL.md` 方法論，但用「第一波 MVP」深度（每個專案 3-5 頁）作交付目標。

依先前 brainstorm 鎖定：
- **版本：** kubernetes v1.36.0（commit `02d6d2a6`）
- **Submodule 策略：** 淺 clone（`--depth 1` at tag）以節省磁碟與時間
- **內容語言：** 繁體中文台灣用語；技術名詞英文（never-translate 清單）
- **頁數：** 4 頁 MDX + 1 個 quiz.json（5 題）

---

## Goals

SP-3 完成後：

- `kubernetes/` submodule 在 root，checkout 在 `v1.36.0`，加進 `.gitmodules`
- `versions.json` 含 kubernetes 條目（commit + tag + analyzed_at）
- `lib/projects.ts` PROJECTS 多一筆 `kubernetes`
- `next-site/content/kubernetes/features/` 4 個 MDX：`architecture` / `api-server` / `controllers` / `kubelet`
- `next-site/content/kubernetes/quiz.json` 5 題
- `make validate` exit 0
- 首頁出現第二張 project card（learning-plan + kubernetes）

---

## Locked decisions

| # | 議題 | 選項 |
|---|---|---|
| 1 | 頁面數量 | 4 頁（architecture / api-server / controllers / kubelet）。Scheduler 拆出單獨頁留待第二波 |
| 2 | 主題色 | `blue`（k8s 官方藍） |
| 3 | submodule 策略 | shallow clone (`--depth 1`) at tag `v1.36.0` |
| 4 | source 引用 | 所有 GitHub URL pinned 到 `/blob/v1.36.0/`；MDX 內每段 code block 第一行 comment 標 file path |
| 5 | controller 範例選擇 | 用 ReplicaSet 當代表（最簡單、最容易追） |
| 6 | kubelet 章節聚焦 | CRI 介面與 Pod sandbox 概念，不深入 device manager / volume manager |
| 7 | 是否寫 use case | 不寫。MVP 階段只有 features，learningPaths 可以靠 features |

---

## Page outline

### 1. architecture.mdx（控制平面整體圖）

讀者問題：「我會用 kubectl，但 control plane 到底有哪些東西？kubelet 怎麼跟它對話？」

- **場景**：SRE 第一次 ssh 進 control plane node，想搞清楚到底有哪些 process
- **架構：** 4 control plane components（kube-apiserver / etcd / kube-controller-manager / kube-scheduler）+ kubelet（per node）+ kube-proxy（per node）
- **資料流**：使用者 `kubectl apply` → API server → etcd → controllers watch → scheduler bind → kubelet pull image → CRI runtime
- **Static Pod 的角色**：解釋 control plane 自己怎麼起來
- **Source links**：`cmd/kube-apiserver/`、`cmd/kubelet/`、`cmd/kube-scheduler/`、`cmd/kube-controller-manager/`、`cmd/kube-proxy/`

### 2. api-server.mdx（API server + etcd 互動）

讀者問題：「`kubectl apply` 之後到底發生什麼？admission 跑哪些 stage？watch 為什麼能即時推播？」

- **場景**：apply 一個 Deployment，從 HTTP request 到 etcd write 的完整路徑
- **三層 admission**：mutating webhook → validating webhook → object schema validation
- **storage layer**：generic registry → etcd v3 client
- **Watch fan-out**：apiserver 自己 watch etcd 一次，然後把 events 多工分送給所有 client（不是每個 client 各自 watch etcd）
- **Source links**：
  - `staging/src/k8s.io/apiserver/pkg/server/handler.go`（HTTP request 入口）
  - `staging/src/k8s.io/apiserver/pkg/admission/`（admission chain）
  - `staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go`（etcd 互動）

### 3. controllers.mdx（controller-manager + scheduler + informer 模式）

讀者問題：「ReplicaSet 控制 Pod 要 reconcile，但 reconcile 何時被觸發？scheduler 跟 controller-manager 怎麼分工？」

- **場景**：刪一個 Pod，2 秒後新 Pod 出現 — 中間誰做了什麼？
- **informer + work queue 模式**：cache + delta FIFO + rate-limited queue
- **ReplicaSet controller** 的 `Reconcile()` 主流程（用 `pkg/controller/replicaset/replica_set.go`）
- **Scheduler 主迴圈**：watch unscheduled Pod → predicate filtering → priority scoring → Bind
- **Source links**：
  - `pkg/controller/replicaset/replica_set.go`（ReplicaSet controller）
  - `pkg/scheduler/scheduler.go`（scheduler 主迴圈）
  - `staging/src/k8s.io/client-go/tools/cache/`（informer 實作）

### 4. kubelet.mdx（kubelet + CRI）

讀者問題：「kubelet 怎麼把 Pod 變成 container？containerd 跟 docker 為什麼互換？sandbox 是什麼？」

- **場景**：Pod yaml 進入 cluster → 落到 worker node → kubelet 接手 → Pod 跑起來。worker node 上實際發生什麼
- **CRI gRPC**：kubelet ↔ containerd / CRI-O 之間的契約
- **Pod sandbox**：pause container 持有 network namespace；其他 container 共用
- **`syncPod` 主迴圈**：管理 sandbox lifecycle、container restart、CNI 呼叫
- **Source links**：
  - `pkg/kubelet/kubelet.go`（主進入點）
  - `pkg/kubelet/kuberuntime/kuberuntime_manager.go`（CRI 呼叫）
  - `pkg/kubelet/cri/`（CRI client wrapper）
  - `cri-api` 介面定義 [`pkg/apis/runtime/v1/api.proto`](https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto)

---

## ProjectMeta 設定

```typescript
'kubernetes': {
  id: 'kubernetes',
  displayName: 'Kubernetes',
  shortName: 'K8s',
  description: '容器編排平台本體：4 個 control plane process + kubelet + kube-proxy 構成的分散式系統',
  githubUrl: 'https://github.com/kubernetes/kubernetes',
  submodulePath: path.join(REPO_ROOT, 'kubernetes'),
  color: 'blue',
  accentClass: 'border-blue-500 text-blue-400',
  features: ['architecture', 'api-server', 'controllers', 'kubelet'],
  featureGroups: [
    { label: '從這裡開始', icon: '🚀', slugs: ['architecture'] },
    { label: '控制平面', icon: '🧠', slugs: ['api-server', 'controllers'] },
    { label: 'Node 端', icon: '🖥️', slugs: ['kubelet'] },
  ],
  usecases: [],
  difficulty: '🟡 中階',
  difficultyColor: 'text-yellow-400 bg-yellow-400/10 border-yellow-400/30',
  problemStatement: '你會用 kubectl 操作 cluster，但 control plane 4 個 process、kubelet、kube-proxy 在背後到底做什麼？API server 收到 request 之後怎麼走進 etcd？scheduler 怎麼挑 node？kubelet 又怎麼跟 containerd 對話？這 4 頁 MVP 從架構切入，逐層拆到 reconcile loop 與 CRI 介面。',
  story: {
    protagonist: '🧑‍💻 平台 SRE 你自己',
    challenge: '會用 kubectl 大半年了，但每次有人問「Service 路由怎麼決定」、「Pod evict 是誰決定的」、「kube-controller-manager 跟 scheduler 為什麼分開」就答不上來。今天決定從原始碼層面把它徹底拆解。',
    scenes: [
      { step: 1, icon: '🏗️', actor: '你', action: '讀 architecture：先建立完整地圖', detail: '搞清楚 4 個 control plane 元件 + kubelet + kube-proxy 各自的工作切面，知道 static Pod 怎麼解決 chicken-and-egg。' },
      { step: 2, icon: '📦', actor: '你', action: '讀 api-server：HTTP request 到 etcd 的全程', detail: '從 handler chain 開始追，看到 admission、storage layer、watch fan-out — 終於理解 apiserver 為何是整個 cluster 的瓶頸點。' },
      { step: 3, icon: '🔄', actor: '你', action: '讀 controllers：reconcile loop 何時被觸發', detail: 'informer cache + work queue + rate limiter 三段式幾乎是所有 k8s controller 的共同骨架。' },
      { step: 4, icon: '🖥️', actor: '你', action: '讀 kubelet：Pod 怎麼變成 container', detail: 'CRI gRPC 介面是 docker / containerd / CRI-O 互換的契約；Pod sandbox 是 network namespace 的擁有者。' },
    ],
    outcome: '從此面對任何 k8s 問題，你能直覺地知道「這該由哪個 process 處理」「應該去哪段原始碼追」。同事看你 kubectl 的眼神不一樣了。',
  },
  learningPaths: {
    beginner: [
      { slug: 'architecture', note: '先建立全貌再深入單一元件' },
      { slug: 'controllers', note: '從最直觀的 ReplicaSet reconcile 開始' },
      { slug: 'kubelet', note: '看 Pod 在 node 上的真實長相' },
    ],
    intermediate: [
      { slug: 'api-server', note: '理解 admission chain 與 watch fan-out 是 cluster 觀察的關鍵' },
      { slug: 'controllers', note: '深入 informer / work queue / rate limiter' },
      { slug: 'kubelet', note: 'CRI 介面與 Pod sandbox' },
    ],
    advanced: [
      { slug: 'api-server', note: '研究 storage layer 與 etcd 互動細節' },
      { slug: 'controllers', note: 'leader election、shared informer、跨 controller 的 ownership chain' },
      { slug: 'kubelet', note: 'CRI 之外：device plugin、CNI、CSI 的整合面' },
    ],
  },
}
```

---

## Verification

- `git submodule status | grep kubernetes` 印出對應 commit
- `cat versions.json | jq '.kubernetes'` 印出 v1.36.0 資訊
- `make validate` exit 0
- `curl http://localhost:3000/kubernetes/` 回 200 含 problemStatement 部分文字
- `curl http://localhost:3000/kubernetes/features/architecture/` 回 200 含 "今日目標 / 場景 / 架構" 之類關鍵詞
- `curl http://localhost:3000/kubernetes/quiz/` 回 200 含至少一個問題文字

---

## Out of scope

- Scheduler 的 framework / extension points 細節（第二波）
- CRD + webhook + admission controller 寫作教學
- kubelet 的 device plugin / volume manager / probe / cgroup driver
- ETCD 內部 paxos / WAL / snapshot
- 整合 cilium / multus / kubevirt 的觀點（這個站本來就會分開講）
- 產生 PNG 架構圖（用 ASCII 與 upstream URL 替代）

---

## 自審

1. **placeholder**：無 TBD/TODO。所有 design 決策都已決定。
2. **內部一致**：4 頁與 ProjectMeta features 對應；featureGroups 包含所有 features。
3. **scope**：MVP 第一波範圍，可獨立交付。
4. **歧義**：「shallow clone」明確指 `--depth 1` at tag。「informer」相關詞彙統一用英文。
