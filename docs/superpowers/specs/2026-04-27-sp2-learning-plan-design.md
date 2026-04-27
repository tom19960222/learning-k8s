# SP-2: 30-Day Learning Plan — Design

> **Status:** drafted by AI under "user-offline autonomous" mode (user said: "我要去睡了，都用你推薦的做"). All deferred decisions resolved with the recommended option. Section-by-section user review skipped per the same authorization. The user reviews the final result on wake.
> **Next step:** writing-plans skill produces the implementation plan.

---

## Project context

The user wants a 30-day hands-on lab curriculum delivered as content under the `learning-plan` "project" registered in `next-site/lib/projects.ts`. This sub-project (SP-2) sits between SP-1 (framework bootstrap, complete) and SP-3..SP-7 (per-project source-code analysis, not yet started).

**Lab environment (the user's stated infrastructure):**

- 3 × Proxmox VE 9.0 hosts forming a Proxmox cluster
- Ceph cluster managed by Proxmox (Proxmox-native ceph deployment)
- 3 × Kubernetes nodes running as VMs on the Proxmox hosts (1 control plane + 2 workers, or HA — exact split is TBD by the user)

**Time budget (from user):**

- Weekdays (Mon-Fri): 1 hr/day
- Weekends (Sat-Sun): 3 hr/day
- 30 calendar days starting Mon 2026-04-27
- Total: 22 weekdays × 1 hr + 8 weekend days × 3 hr = **46 hours**

**Verification level (already locked in earlier brainstorm):**

| Tier | When | Expected accuracy |
|---|---|---|
| 🟢 已驗證 | Trivial commands (`kubectl get nodes`, `crictl ps`, etc.) or commands I tested in kind | Exact command + exact-format expected output |
| 🟡 已對照官方文件 / 原始碼 | Most cluster-mutating commands; verified against upstream docs and source | Exact command syntax; expected output is structural skeleton, not specific values |
| 🔴 需在你環境跑後對照 | Commands whose output depends on the user's specific cluster state (IPs, pool names, BMC interfaces, etc.) | Command pattern; user fills in specifics |

Every lab command in the MDX must carry one of these badges. **No bare commands without a verification tier.**

---

## Goals

After SP-2 lands, the documentation site will have:

1. A `learning-plan` ProjectMeta entry registered in `next-site/lib/projects.ts` with all 30 day-pages.
2. 30 MDX files (`day-01.mdx` through `day-30.mdx`) in `next-site/content/learning-plan/features/`, each ~300-600 words, following a single consistent template.
3. A 12-question quiz (`next-site/content/learning-plan/quiz.json`) covering the integration concepts.
4. A landing page (`/learning-plan`) showing the protagonist story + 4 sidebar groups (one per topic block).
5. `make validate` exits 0; the site builds and renders the new project end-to-end.

SP-2 explicitly does **not** include:

- Generating PNG diagrams for individual day-pages (out of scope; days reference upstream architecture diagrams via URLs only).
- Source-code analysis of k8s/cilium/multus/ceph/kubevirt — those are SP-3..SP-7. Day-pages reference upstream docs for "deeper understanding" links instead of cross-linking to internal pages that don't yet exist.
- Per-day quiz questions (we use one global 12-question quiz instead).
- Live testing on the user's actual Proxmox cluster — that's the user's job per the verification tier definitions.

---

## Locked decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| Q1 | Time distribution per topic | **A**: k8s 11h, cilium+multus 11h, ceph+rook 11h, kubevirt 13h | Reverse-engineered from the user's stated end goal (KubeVirt platform) |
| Q2 | Ceph integration approach | **C** (recommended): Proxmox ceph as primary; mini-Rook on kind for operator study | Production-pragmatic + still studies Rook's operator pattern |
| Q3 | Day-page template structure | Single uniform 8-section template (defined below) | Predictability ≫ per-day creativity |
| Q4 | Cumulative vs independent labs | **Cumulative** state builds across days; each day's commands remain runnable in isolation given prior state | Day 30 produces a working KubeVirt VM platform; not 30 unrelated demos |
| Q5 | Deliverable scope (this SP) | **All 30 days** with full content, plus landing-page story and quiz | User asked for the full plan, not a skeleton |

---

## Curriculum outline (the headline asset)

### Block 1 — Kubernetes 內部運作 (Days 1-7, 11 hr)

**Block goal:** From "I can `kubectl get pods`" to "I know what each control-plane component does and have written a tiny controller."

| Day | Date | Hr | Title | Hands-on focus |
|----|------|----|------|----|
| 01 | Mon 04-27 | 1 | 巡禮控制平面元件 | `kubectl get cs`、`crictl ps -a` 觀察 static Pod 形態的 kube-apiserver / etcd / kcm / scheduler |
| 02 | Tue 04-28 | 1 | API Server 與 etcd | `kubectl api-resources`、列 group/version；`etcdctl get` 直接看 etcd 的 raw key |
| 03 | Wed 04-29 | 1 | Scheduler 排程 | nodeSelector / nodeAffinity / topologySpreadConstraints；`kubectl get events --field-selector=reason=Scheduled` |
| 04 | Thu 04-30 | 1 | Controller Manager | 殺一個 Pod 看 ReplicaSet self-heal；`kubectl logs kube-controller-manager` 看 informer 訊息 |
| 05 | Fri 05-01 | 1 | kubelet + CRI | `crictl pods`, `crictl inspectp`；理解 PodSandbox vs Container 的關係 |
| 06 | Sat 05-02 | 3 | kube-proxy + iptables/IPVS | `iptables-save -t nat \| grep KUBE-SVC` 追 service chain；跨 node curl 觀察 SNAT |
| 07 | Sun 05-03 | 3 | 自寫一個 ConfigMap watcher operator | 用 controller-runtime 從 0 到 deploy；理解 Reconcile() 何時被觸發 |

### Block 2 — cilium + multus (Days 8-14, 11 hr)

**Block goal:** Replace the default CNI with Cilium, observe the eBPF datapath, then add Multus for VM secondary networks.

| Day | Date | Hr | Title | Hands-on focus |
|----|------|----|------|----|
| 08 | Mon 05-04 | 1 | 安裝 Cilium | `helm install cilium`，等 cilium-agent / operator 起來；`cilium status` |
| 09 | Tue 05-05 | 1 | eBPF datapath 觀察 | `cilium bpf endpoint list`, `cilium monitor`；cilium-dbg shell 內看 BPF map |
| 10 | Wed 05-06 | 1 | NetworkPolicy + CiliumNetworkPolicy | L3/L4 deny-by-default；CNP 寫一個 L7 (HTTP path) rule |
| 11 | Thu 05-07 | 1 | Hubble | 部署 Hubble Relay + UI；觀察 Pod 之間 flow，看 drop reason |
| 12 | Fri 05-08 | 1 | 加密：IPsec / WireGuard | 啟用 WireGuard transparent encryption；觀察 cilium tunnel iface |
| 13 | Sat 05-09 | 3 | Multus 安裝 + 設定 NetworkAttachmentDefinition | thick plugin 模式安裝；建一個 bridge NAD 接 Proxmox 網段 |
| 14 | Sun 05-10 | 3 | Multus 多網路 Pod 實驗 + 讀 source | 一個 Pod 同時掛 cilium + multus bridge；讀 multus delegate flow |

### Block 3 — ceph + rook (Days 15-21, 11 hr)

**Block goal:** Treat the existing Proxmox-managed ceph as the production storage backend; integrate via ceph-csi; on the side, study Rook's operator pattern in a throwaway kind cluster.

| Day | Date | Hr | Title | Hands-on focus |
|----|------|----|------|----|
| 15 | Mon 05-11 | 1 | Proxmox ceph 健檢 | 從 Proxmox node ssh 進去，`ceph -s`, `ceph osd tree`, `ceph mon stat` |
| 16 | Tue 05-12 | 1 | CRUSH map | `ceph osd crush dump`；用 device class 把 ssd osd 分群 |
| 17 | Wed 05-13 | 1 | Pool + PG + RBD | `ceph osd pool create k8s-rbd`；`rbd create / map`；計算合適的 pg_num |
| 18 | Thu 05-14 | 1 | k8s 端裝 ceph-csi + StorageClass | helm install ceph-csi-rbd；建 StorageClass；用 PVC 建一個 RBD 映射 |
| 19 | Fri 05-15 | 1 | CephFS + 多 Pod 共用 PV | 開 CephFS pool；建 PVC + ReadWriteMany；多 Pod 同時掛 |
| 20 | Sat 05-16 | 3 | Rook 在 kind 上 mini ceph | kind create cluster + Rook helm；觀察 CephCluster reconcile；讀 operator code |
| 21 | Sun 05-17 | 3 | RGW（S3 物件儲存）+ 從 k8s 用 boto3 訪問 | 在 Proxmox ceph 開 RGW；建 S3 user；Python boto3 上傳檔案 |

### Block 4 — kubevirt + 整合 (Days 22-30, 13 hr)

**Block goal:** Deploy KubeVirt; build a VM platform that uses ceph-csi for VM disks, multus for secondary networks, and supports live migration.

| Day | Date | Hr | Title | Hands-on focus |
|----|------|----|------|----|
| 22 | Mon 05-18 | 1 | 安裝 KubeVirt | `kubectl apply` operator + KubeVirt CR；確認 virt-controller / handler / api / launcher 起來 |
| 23 | Tue 05-19 | 1 | 第一台 VM | 寫 VirtualMachine YAML（containerDisk image），啟動，`virtctl console` 進系統 |
| 24 | Wed 05-20 | 1 | VM 用 PVC 當磁碟 | DataVolume + ceph-csi RBD storageClass；觀察 VMI Pod 內 virt-launcher 怎麼掛 disk |
| 25 | Thu 05-21 | 1 | virt-handler 和 virt-launcher 行為 | 在 node 上看 virt-launcher process 跟 libvirt domain；qemu-system 怎麼跑 |
| 26 | Fri 05-22 | 1 | 多網路 VM | 用 day 13 的 multus NAD 給 VM 接第二張網卡；VM 內 ip a 確認 |
| 27 | Sat 05-23 | 3 | Live migration | drain node 觸發 / `virtctl migrate`；觀察 memory copy + cutover；測 downtime |
| 28 | Sun 05-24 | 3 | DataVolume + CDI | 從 URL 拉 cloud image；多種 source（http、PVC、registry）；理解 import flow |
| 29 | Mon 05-25 | 1 | VM 監控與除錯 | `kubectl get vmi -o wide`、metrics endpoint、`virtctl console / vnc`；event 解讀 |
| 30 | Tue 05-26 | 1 | 平台整合 demo | 部署一個 web 服務 VM：ceph-csi 磁碟 + multus 第二張網卡 + 設 LB Service |

**Total verification:** Day 30 should leave the user with a running VM that has persistent ceph-backed storage, an internal network plus an external bridged network, and the ability to be live-migrated between k8s nodes — i.e., a minimum viable KubeVirt platform.

---

## Day-page template

Every day-page MDX follows this exact 8-section structure. Sections are labeled in zh-TW; content is zh-TW with technical terms in English.

```mdx
---
layout: doc
title: Day NN — <主題>
description: <一句話說明今天要練什麼>
---

## 今日目標
- 3-5 條 bullet：完成這 1/3 hr 後你應該能…

## 今日在 30 天計畫中的位置
1-2 段：說明這天接續前一天什麼成果，下一天會再用今天什麼。
（第一個 block 的 Day 1 用「整體入門」段；最後 Day 30 用「總結」段。）

## 前置條件
- 昨日（day-NN-1）已完成 — 連結 [day-NN-1](/learning-plan/features/day-NN-1)
- 環境檢查指令（每行附驗證 tier badge）

## 動手做
分階段（1.x、2.x、…），每階段：
- 一句話前置說明（給讀者教學脈絡）
- 程式碼區塊：指令 + 第一行 comment 標 verification tier
- 程式碼區塊：預期輸出（依 verification tier 決定具體 vs skeleton）
- 1-2 句解讀：「為什麼這樣？」

## 觀念深化
5-15 行：今日 hands-on 對應的設計概念。當對應的專案 page 還沒寫，就連到 upstream docs 或 source GitHub URL（以 `_blank` 開）。

## 收穫檢查
3-5 個自問題（不是 quiz，是給自己想）

## 參考資料
- 官方文件 (含連結)
- 原始碼路徑（GitHub blob URL）
- 額外推薦閱讀

## 明日預告
1-2 句：明天會用今天的什麼成果。
```

**Hard rules:**

- 每個 code block 第一行 comment 寫驗證 tier，例如：
  ```bash
  # 🟢 已驗證 (kind)
  kubectl get nodes -o wide
  ```
- 不要 import 任何 component（`<Callout>` 是全域註冊的）
- 不要寫不存在的內部 page 連結；連到 upstream 文件比連到 placeholder 好
- 程式碼註解保持英文；其他敘述 zh-TW 台灣用語

---

## ProjectMeta 設定

在 `next-site/lib/projects.ts` 的 PROJECTS 物件新增 `learning-plan`：

```typescript
'learning-plan': {
  id: 'learning-plan',
  displayName: '30 天 Hands-on Lab',
  shortName: 'Lab',
  description: '30 天動手實驗計畫，從 k8s 內部 → cilium/multus → ceph → kubevirt，最終建立可用的 VM 平台',
  githubUrl: '',  // 沒有對應 upstream repo
  submodulePath: '',  // 沒有 submodule
  color: 'amber',
  accentClass: 'border-amber-500 text-amber-400',
  features: ['day-01', 'day-02', /* ... */ 'day-30'],
  featureGroups: [
    { label: 'Week 1 — Kubernetes 內部', icon: '⚙️', slugs: ['day-01','day-02','day-03','day-04','day-05','day-06','day-07'] },
    { label: 'Week 2 — cilium + multus', icon: '🌐', slugs: ['day-08','day-09','day-10','day-11','day-12','day-13','day-14'] },
    { label: 'Week 3 — ceph + rook', icon: '💾', slugs: ['day-15','day-16','day-17','day-18','day-19','day-20','day-21'] },
    { label: 'Week 4+ — kubevirt 整合', icon: '🖥️', slugs: ['day-22','day-23','day-24','day-25','day-26','day-27','day-28','day-29','day-30'] },
  ],
  usecases: [],
  difficulty: '🟡 中階',
  difficultyColor: 'text-yellow-400 bg-yellow-400/10 border-yellow-400/30',
  problemStatement: '會用 kubectl 不等於懂 k8s。30 天裡，我們從 control plane 拆解開始，逐步加上 CNI、CSI、虛擬化層，最後親手建一個可以跑 VM 的 KubeVirt 平台。每天 1-3 小時，週五完成一個小目標。',
  story: { /* Phase 3.5 produces this — see Story 一節 */ },
  learningPaths: { /* see Learning Paths 一節 */ },
}
```

`githubUrl` 與 `submodulePath` 為空。框架在 SP-1 已經 graceful-handle 空值（`buildGithubBlobUrl` 在空 baseURL 時回 ''；source page 的 GitHub link 在空 baseURL 時也回空字串）。

---

## Story（landing page protagonist）

```typescript
story: {
  protagonist: '🧑‍💻 平台工程師 你自己',
  challenge: '公司裡其他 SRE 都會 kubectl，但要說明「Service 為什麼能 routing」、「kubelet 怎麼跟 containerd 對話」、「KubeVirt VM live migration 真實在搬什麼」時，你卡住了。讀了一堆部落格還是只懂「會用」，不懂「為什麼」。',
  scenes: [
    { step: 1, icon: '🔍', actor: '你', action: 'Day 1：第一次 ssh 進 control plane node，發現 kube-apiserver 是個 static Pod', detail: '原來不是神秘的 systemd service，是 kubelet 從 /etc/kubernetes/manifests/ 讀 yaml 起的 Pod。從這一刻開始，控制平面的神秘感消散。' },
    { step: 2, icon: '⚙️', actor: '你', action: 'Day 7：自己寫了第一個 ConfigMap watcher controller', detail: '之前覺得 Operator 是黑魔法，今天親手用 controller-runtime 寫了一個。Reconcile() 被觸發的時機、informer 的 cache、work queue 的 rate limit — 全是源於熟悉的 Go pattern。' },
    { step: 3, icon: '🚀', actor: '你', action: 'Day 14：用 cilium 看到 eBPF prog 在 `cilium monitor` 裡跳出 trace event', detail: '網路不再是 iptables 黑盒。eBPF program、BPF map、verifier — 在 cilium-agent 裡看到原始的指令層追蹤。' },
    { step: 4, icon: '💾', actor: '你', action: 'Day 18：第一個 ceph-csi PVC bind 成功，VM 拿到 RBD 磁碟', detail: '從 ceph 的 CRUSH placement 到 k8s PVC 的 bind 流程，原本各自獨立的兩塊知識在這一天連起來。' },
    { step: 5, icon: '✈️', actor: '你', action: 'Day 27：成功觸發 live migration，downtime 187ms', detail: 'virt-handler 把 memory dirty page 一輪一輪追上，直到 cutover。看著 metrics 從 source node 跳到 target node，明白 KubeVirt 為什麼是「VM in container」而不是 vSphere 翻版。' },
  ],
  outcome: 'Day 30 你的 cluster 上跑著一台 web service VM：ceph-csi RBD 磁碟、multus 接外部網路、kubectl 一個指令就能 live migrate。從 control plane 到 KubeVirt 整條鏈路你都拆過，再也沒有黑盒。',
}
```

---

## Learning Paths

```typescript
learningPaths: {
  beginner: [
    { slug: 'day-01', note: '從巡禮控制平面元件開始，建立整體圖像' },
    { slug: 'day-04', note: '用最熟悉的 ReplicaSet 觀察 reconcile loop' },
    { slug: 'day-07', note: '自己寫一個 controller，理解 operator 不是魔法' },
  ],
  intermediate: [
    { slug: 'day-09', note: '用 cilium monitor 看到實際 eBPF trace event' },
    { slug: 'day-18', note: 'ceph-csi 把 ceph 的 CRUSH 和 k8s 的 PVC 連起來' },
    { slug: 'day-27', note: 'KubeVirt live migration 的 memory copy 機制' },
  ],
  advanced: [
    { slug: 'day-14', note: '讀 multus delegate flow 原始碼' },
    { slug: 'day-20', note: 'Rook operator 的 reconcile loop 拆解' },
    { slug: 'day-30', note: '把所有元件整合成一個可用平台的 demo' },
  ],
}
```

---

## Quiz（12 題綜合題）

存於 `next-site/content/learning-plan/quiz.json`。3 題對 1 個 block，問整合性、概念性問題（不問特定指令的字串）。範例題型：

```json
[
  {
    "id": 1,
    "question": "在 Day 1 你看到 kube-apiserver 是 static Pod。下列哪個說法正確？",
    "options": [
      "kubelet 從 /etc/kubernetes/manifests/ 讀 yaml 起 Pod，不經過 API server",
      "kubelet 透過 API server 建立 Pod",
      "systemd 直接管理 kube-apiserver process",
      "kube-controller-manager 起 kube-apiserver"
    ],
    "answer": 0,
    "explanation": "static Pod 由 kubelet 從本機目錄讀 manifest 直接建立，不經 API server。這就是雞生蛋蛋生雞的解法：API server 自己也是 static Pod。"
  }
]
```

題目須基於 day-page 內容，**禁止杜撰**。詳細題目在 implementation phase 寫。

---

## File structure

```
learning-k8s/
├── next-site/
│   ├── lib/projects.ts                       (MODIFY — 加 learning-plan 條目)
│   └── content/
│       └── learning-plan/
│           ├── features/
│           │   ├── day-01.mdx                (CREATE)
│           │   ├── day-02.mdx                (CREATE)
│           │   ├── ...
│           │   └── day-30.mdx                (CREATE)
│           └── quiz.json                     (CREATE)
└── docs/superpowers/
    ├── specs/2026-04-27-sp2-learning-plan-design.md      (this file)
    └── plans/2026-04-27-sp2-learning-plan.md             (next step)
```

No new components, no new framework code. SP-2 is pure content + 1 ProjectMeta entry.

---

## Verification

SP-2 is complete when:

- All 30 day-pages exist under `next-site/content/learning-plan/features/`
- `next-site/content/learning-plan/quiz.json` has 12 valid questions
- `next-site/lib/projects.ts` has the `learning-plan` entry with all 30 slugs in `features` and 4 `featureGroups`
- `make validate` exits 0 (passes frontmatter, image, quiz, feature-file, build checks)
- Visiting `http://localhost:3000/learning-plan` shows: landing page with story timeline, sidebar with 4 groups expanded, link to day-01 works
- Each day-page renders with the 8-section template intact, each command block carries a verification tier badge
- The homepage `/` now shows 1 project card ("30 天 Hands-on Lab")

---

## Error handling — known traps

| Trap | Trigger | Fallback |
|---|---|---|
| `make validate` fails on missing slug → MDX | A day-NN.mdx wasn't created or has wrong filename | Locate via `make validate` output; create missing file |
| Quiz `question` field starts with "1." or "Day 1" | Wrong; the page auto-prepends `1.` | Strip number prefix from question text |
| `<Callout>` referenced but `import` added | MDX accidentally imports the global component | Remove the import line |
| Cross-link to `/kubernetes/some-page` 404s | SP-3..SP-7 pages don't exist yet | Replace with upstream docs/source GitHub URL |
| Build fails after adding `learning-plan` to PROJECTS | Likely a malformed ProjectMeta field (missing `accentClass`, etc.) | Compare against the interface in `lib/projects.ts` |
| `submodulePath: ''` causes runtime error in code-extractor | code-extractor calls `path.join(submodulePath, ...)` and if any MDX uses code-anchor, this would surface | day-pages do NOT use `<CodeAnchor>` for source extraction — only inline ```bash blocks. Confirms no risk. |

---

## Out of scope (explicit)

- PNG diagrams for individual days (use upstream architecture diagrams via URL only)
- Day-page-level quizzes (one global 12-question quiz instead)
- Cross-linking to internal source-analysis pages (those don't exist until SP-3..SP-7)
- Live testing on the user's actual Proxmox cluster
- Updating the homepage hero CTA logic (Phase 1 already handles `PROJECT_IDS.length > 0`)
- Adding new framework components or routes

---

## Open questions

None. All deferred decisions resolved per user authorization "都用你推薦的做" on 2026-04-27.

User can override any locked decision after the fact by amending or follow-up SP. Reversal cost:
- Time distribution change → re-allocate days within blocks; 1-2 hr to update
- Ceph approach change (B instead of C) → rewrite Days 15-21 only; 2-3 hr
- Day template change → bulk-edit 30 files; 1 hr
- Different quiz structure (per-day instead of global) → split quiz.json + add `<QuizQuestion>` to each day; 2 hr

All low-friction reversals.
