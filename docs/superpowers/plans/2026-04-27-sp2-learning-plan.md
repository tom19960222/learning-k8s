# SP-2: 30-Day Learning Plan — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the full 30-day hands-on lab curriculum as MDX content under `next-site/content/learning-plan/features/`, plus the `learning-plan` ProjectMeta in `lib/projects.ts` and a 12-question quiz, end-to-end build green.

**Architecture:** One task creates the ProjectMeta entry and content directory. Four parallel-able tasks (run sequentially per subagent-driven-development discipline) each write one block's worth of day-pages (7-9 MDX files each, following an 8-section template). One task creates the quiz. One final task runs `make validate` and commits any drift. All work happens under `next-site/content/learning-plan/` plus a single edit to `next-site/lib/projects.ts`. Calendar baseline: Day 1 = Mon 2026-04-27.

**Tech Stack:** Next.js 14 + MDX (next-mdx-remote), TypeScript (one ProjectMeta object), JSON (quiz), Python `scripts/validate.py` for verification.

**Success criteria:**
- `make validate` exits 0
- `http://localhost:3000/learning-plan` renders landing + 4-group sidebar
- All 30 day-pages render with the 8-section template intact
- Each shell command in MDX carries a 🟢/🟡/🔴 verification tier comment

---

## File structure (post-SP-2)

```
learning-k8s/
├── next-site/
│   ├── lib/projects.ts                     (MODIFY — add learning-plan entry)
│   └── content/learning-plan/
│       ├── features/
│       │   ├── day-01.mdx                  (CREATE — Block 1)
│       │   ├── day-02.mdx                  (CREATE — Block 1)
│       │   ├── ...
│       │   ├── day-07.mdx                  (CREATE — Block 1)
│       │   ├── day-08.mdx                  (CREATE — Block 2)
│       │   ├── ...
│       │   ├── day-14.mdx                  (CREATE — Block 2)
│       │   ├── day-15.mdx                  (CREATE — Block 3)
│       │   ├── ...
│       │   ├── day-21.mdx                  (CREATE — Block 3)
│       │   ├── day-22.mdx                  (CREATE — Block 4)
│       │   ├── ...
│       │   └── day-30.mdx                  (CREATE — Block 4)
│       └── quiz.json                       (CREATE)
└── docs/superpowers/
    ├── specs/2026-04-27-sp2-learning-plan-design.md   (already committed)
    └── plans/2026-04-27-sp2-learning-plan.md          (this file)
```

---

## Constants the implementer must use

### Verification tier comment style

Every shell or YAML code block's first line is a comment marking its verification tier. Examples:

```bash
# 🟢 已驗證 (kind / 顯然正確)
kubectl get nodes -o wide
```

```bash
# 🟡 已對照官方文件 / 原始碼
cilium status --wait
```

```bash
# 🔴 需在你環境跑後對照 (依 cluster 狀態而異)
ceph osd tree
```

### Tier guidance per command type

| Command pattern | Tier |
|---|---|
| `kubectl get / describe / explain / api-resources / version` | 🟢 |
| `kubectl logs / kubectl exec / kubectl port-forward` | 🟡 |
| `kubectl apply / create / delete / drain` | 🟡 |
| `helm install / helm upgrade` | 🟡 |
| `iptables-save`, `ip a`, `tcpdump`, `crictl ...` | 🟡 |
| `cilium status / cilium monitor / cilium bpf ...` | 🟡 |
| `ceph -s / ceph osd tree / rbd ...` | 🔴 (具體值依 cluster) |
| `virtctl console / virtctl migrate` | 🟡 |
| `go run / make / docker build` | 🟢 (本機可驗) |
| Anything reading specific node IP / hostname / volume ID | 🔴 |

### Frontmatter (every MDX file)

```yaml
---
layout: doc
title: Day NN — <title in zh-TW>
description: <one-line in zh-TW>
---
```

`layout: doc` and `title:` are **mandatory** (validate.py enforces them). Description is recommended.

### Day-page 8-section template

```mdx
## 今日目標
- (3-5 bullets)

## 今日在 30 天計畫中的位置
(1-2 段落)

## 前置條件
- 昨日 [day-NN-1](/learning-plan/features/day-NN-1) 已完成
- 環境檢查指令（每行 code 帶 verification tier 注解）

## 動手做
### 1. <第一個小節主題>
(一句前置說明)

```bash
# <verification tier>
<command>
```

```
<expected output, exact for 🟢 / skeleton for 🟡 / pattern for 🔴>
```

(1-2 句解讀)

### 2. <第二個小節主題>
…(repeat)

## 觀念深化
5-15 行：原始碼 / 設計概念連結。連到 upstream 官方文件 / GitHub blob。

## 收穫檢查
- (3-5 個自問題)

## 參考資料
- [標題](URL) — 簡介
- [標題](URL) — 簡介

## 明日預告
1-2 句。
```

The Day 1 page replaces "## 前置條件 / 昨日連結" with a "## 開始之前" section listing the user's expected baseline (Proxmox cluster + 3-node k8s + Proxmox ceph). The Day 30 page replaces "## 明日預告" with "## 30 天回顧" summarizing the path.

### Hard "do NOT" list

- Do NOT add `import { Callout } from ...` or `import { QuizQuestion } from ...` — they are global components.
- Do NOT use `<QuizQuestion>` inside any day-page MDX. Quiz lives only in `quiz.json`.
- Do NOT cross-link to `/kubernetes/...`, `/cilium/...`, `/multus/...`, `/ceph/...`, `/kubevirt/...` — those project pages don't exist yet (SP-3..SP-7). Link to upstream GitHub URLs instead.
- Do NOT use Mermaid diagrams. (None of the day-pages need diagrams; if a concept needs visualization, link to upstream docs that include the diagram.)
- Do NOT fabricate function names, file paths, or specific log lines. If unsure, write a conceptual description instead.
- Do NOT use Mainland Chinese vocabulary (软件 / 网络 / 文件-as-file / 程序 / 默认 / 数据 / 用户 / 视频). Use Taiwan equivalents.

### Cross-day linking rule

- Every day NN ≥ 2 links its 前置條件 to `[day-NN-1](/learning-plan/features/day-NN-1)`.
- Every day NN ≤ 29 links its 明日預告 to `[day-NN+1](/learning-plan/features/day-NN+1)`.
- Pad day numbers: `day-01`, `day-09`, `day-10`, `day-30`.

### Upstream version-pinned source URL pattern

When linking to source on GitHub, use the **tag** version, not main:

| Project | URL prefix |
|---|---|
| kubernetes | `https://github.com/kubernetes/kubernetes/blob/v1.36.0/...` |
| cilium | `https://github.com/cilium/cilium/blob/v1.19.3/...` |
| multus-cni | `https://github.com/k8snetworkplumbingwg/multus-cni/blob/v4.2.4/...` |
| kubevirt | `https://github.com/kubevirt/kubevirt/blob/v1.8.2/...` |
| ceph | `https://github.com/ceph/ceph/blob/v19.2.3/...` |

---

## Tasks

### Task 1: Register `learning-plan` in projects.ts + create content scaffold

**Files:**
- Modify: `next-site/lib/projects.ts`
- Create: `next-site/content/learning-plan/features/` (empty dir)
- Create: `next-site/content/learning-plan/quiz.json` (initial `[]`)

- [ ] **Step 1: Read current projects.ts**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
cat next-site/lib/projects.ts
```

Confirm the file matches the post-SP-1 state: `ProjectId = string`, `PROJECTS = {}`, `PROJECT_IDS = Object.keys(PROJECTS)`, `PROJECT_IDS_FOR_STATIC_EXPORT` fallback present.

- [ ] **Step 2: Edit projects.ts to insert the learning-plan entry**

Use the Edit tool to replace this block:

```typescript
// Empty until SP-2..SP-7 register their projects.
export const PROJECTS: Record<ProjectId, ProjectMeta> = {}
```

with:

```typescript
// Registered projects. SP-2 added learning-plan; SP-3..SP-7 will add the others.
export const PROJECTS: Record<ProjectId, ProjectMeta> = {
  'learning-plan': {
    id: 'learning-plan',
    displayName: '30 天 Hands-on Lab',
    shortName: 'Lab',
    description: '30 天動手實驗計畫，從 k8s 內部 → cilium/multus → ceph → kubevirt，最終建立可用的 VM 平台',
    githubUrl: '',
    submodulePath: '',
    color: 'amber',
    accentClass: 'border-amber-500 text-amber-400',
    features: [
      'day-01','day-02','day-03','day-04','day-05','day-06','day-07',
      'day-08','day-09','day-10','day-11','day-12','day-13','day-14',
      'day-15','day-16','day-17','day-18','day-19','day-20','day-21',
      'day-22','day-23','day-24','day-25','day-26','day-27','day-28','day-29','day-30',
    ],
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
    story: {
      protagonist: '🧑‍💻 平台工程師 你自己',
      challenge: '公司裡其他 SRE 都會 kubectl，但要說明「Service 為什麼能 routing」、「kubelet 怎麼跟 containerd 對話」、「KubeVirt VM live migration 真實在搬什麼」時，你卡住了。讀了一堆部落格還是只懂「會用」，不懂「為什麼」。',
      scenes: [
        { step: 1, icon: '🔍', actor: '你', action: 'Day 1：第一次 ssh 進 control plane node，發現 kube-apiserver 是個 static Pod', detail: '原來不是神秘的 systemd service，是 kubelet 從 /etc/kubernetes/manifests/ 讀 yaml 起的 Pod。從這一刻開始，控制平面的神秘感消散。' },
        { step: 2, icon: '⚙️', actor: '你', action: 'Day 7：自己寫了第一個 ConfigMap watcher controller', detail: '之前覺得 Operator 是黑魔法，今天親手用 controller-runtime 寫了一個。Reconcile() 被觸發的時機、informer 的 cache、work queue 的 rate limit — 全是源於熟悉的 Go pattern。' },
        { step: 3, icon: '🚀', actor: '你', action: 'Day 14：用 cilium 看到 eBPF prog 在 cilium monitor 裡跳出 trace event', detail: '網路不再是 iptables 黑盒。eBPF program、BPF map、verifier — 在 cilium-agent 裡看到原始的指令層追蹤。' },
        { step: 4, icon: '💾', actor: '你', action: 'Day 18：第一個 ceph-csi PVC bind 成功，VM 拿到 RBD 磁碟', detail: '從 ceph 的 CRUSH placement 到 k8s PVC 的 bind 流程，原本各自獨立的兩塊知識在這一天連起來。' },
        { step: 5, icon: '✈️', actor: '你', action: 'Day 27：成功觸發 live migration，downtime 187ms', detail: 'virt-handler 把 memory dirty page 一輪一輪追上，直到 cutover。看著 metrics 從 source node 跳到 target node，明白 KubeVirt 為什麼是「VM in container」而不是 vSphere 翻版。' },
      ],
      outcome: 'Day 30 你的 cluster 上跑著一台 web service VM：ceph-csi RBD 磁碟、multus 接外部網路、kubectl 一個指令就能 live migrate。從 control plane 到 KubeVirt 整條鏈路你都拆過，再也沒有黑盒。',
    },
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
    },
  },
}
```

- [ ] **Step 3: Create content scaffold**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
mkdir -p next-site/content/learning-plan/features
echo '[]' > next-site/content/learning-plan/quiz.json
```

- [ ] **Step 4: TypeScript syntax check**

```bash
cd /Users/ikaros/Documents/code/learning-k8s/next-site
npx tsc --noEmit 2>&1 | head -30
```

Acceptable: no errors related to `lib/projects.ts`. (Other TypeScript output unrelated to this file is fine.)

- [ ] **Step 5: validate-quick**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate-quick 2>&1 | tail -20
```

Should fail at check `[5] Feature Files vs projects.ts` because we listed 30 day slugs but no MDX files exist yet. That's expected — the next tasks fill them in. Note the error and proceed.

- [ ] **Step 6: Commit (intermediate state — known-failing validate)**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/lib/projects.ts next-site/content/learning-plan/quiz.json
git -c commit.gpgsign=false commit -m "feat(sp-2): register learning-plan ProjectMeta with 30-day curriculum

Adds the 30-day hands-on lab project with 4 weekly featureGroups,
protagonist story, and learning paths. Day-page MDX files come in
the next 4 commits; build is intentionally not green between this
commit and the day-page commits.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Block 1 — Days 1-7 (Kubernetes 內部)

**Files:**
- Create: `next-site/content/learning-plan/features/day-01.mdx` … `day-07.mdx`

Each MDX follows the 8-section template above. The implementer subagent gets the brief inline (see "Block 1 brief" section below) and writes all 7 files in one task.

- [ ] **Step 1: Write all 7 MDX files**

Use the Block 1 brief (below). For each day, follow the template exactly. Use:
- Taiwan Mandarin (繁體中文台灣用語)
- Verification tier badges on every code block
- Cross-day links pad with leading zero
- Source URL pattern uses pinned tag (v1.36.0)
- No `import` statements, no `<QuizQuestion>`, no Mermaid

- [ ] **Step 2: Spot-check one file**

Open `day-01.mdx`. Confirm it has all 8 sections. Confirm at least 3 code blocks have tier badges.

- [ ] **Step 3: Commit**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/content/learning-plan/features/day-0*.mdx next-site/content/learning-plan/features/day-07.mdx
git -c commit.gpgsign=false commit -m "feat(sp-2): write Block 1 day-pages (Days 1-7, Kubernetes 內部)

Days 1-5 are 1-hr weekday labs; Days 6-7 are 3-hr weekend labs.
Coverage: control plane components → API server / etcd → scheduler →
controller manager → kubelet/CRI → kube-proxy/iptables → controller-runtime
operator from scratch.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

#### Block 1 brief

**Block goal:** From "I can `kubectl get pods`" to "I have written a tiny operator and understand each control-plane component's job."

**Day 1 — Mon 04-27 — 巡禮控制平面元件 (1 hr)**

- Goals: List the 4 control-plane processes (kube-apiserver, etcd, kube-controller-manager, kube-scheduler), find them on the cluster, understand they are static Pods.
- 開始之前 (Day 1 has no prior day): assume the user has 3-node k8s cluster with kubeadm (or similar) bootstrap on top of Proxmox. List `kubectl version --short` and `kubectl get nodes -o wide` as baseline checks (🟢).
- Hands-on:
  1. `kubectl get componentstatuses` (note: deprecated since 1.19 but still informative). Tier 🟡 (deprecated, may not exist). Alternative: `kubectl get pods -n kube-system` and grep for the 4 components.
  2. ssh to control-plane node. Run `crictl ps -a | head -10` (🟡) — show the static Pod containers.
  3. `ls /etc/kubernetes/manifests/` (🟡) — show the 4 yaml files that define the static Pods.
  4. `cat /etc/kubernetes/manifests/kube-apiserver.yaml | head -30` (🟡) — point out `command:` args.
- 觀念深化: kubelet acts as the bootstrap; it watches `/etc/kubernetes/manifests/` and runs whatever Pod manifests it finds there. This is how the API server itself comes up before any API server exists. Reference: [Static Pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/) and [kubeadm internals](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/kubeadm-init/).
- 參考資料:
  - https://kubernetes.io/docs/concepts/overview/components/
  - https://github.com/kubernetes/kubernetes/blob/v1.36.0/cmd/kube-apiserver/apiserver.go (entry point)
- 明日預告: Day 2 用 `etcdctl` 直接看 etcd 裡 raw key，理解 API server 與 etcd 的關係。

**Day 2 — Tue 04-28 — API Server 與 etcd (1 hr)**

- Goals: Discover etcd is the source of truth; API server is a façade; raw keys reveal the resource model.
- Hands-on:
  1. `kubectl api-resources --verbs=list -o wide | head -20` (🟢) — see groups, versions, namespaced.
  2. ssh control-plane node, `crictl ps | grep etcd` (🟡), then `crictl exec -it <etcd-container-id> sh` and run `etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry --prefix --keys-only | head -20` (🟡). Show keys like `/registry/pods/kube-system/kube-apiserver-...`.
  3. Read raw value: `etcdctl ... get /registry/configmaps/default/some-cm -w simple` — explain it is protobuf, not pretty JSON.
- 觀念深化: API server is a stateless reverse-proxy + admission pipeline + watch fan-out in front of etcd. Read [API server architecture](https://kubernetes.io/docs/reference/using-api/api-concepts/) and the entry point [staging/src/k8s.io/apiserver/...](https://github.com/kubernetes/kubernetes/tree/v1.36.0/staging/src/k8s.io/apiserver).
- 明日預告: Day 3 看 scheduler 如何選 node。

**Day 3 — Wed 04-29 — Scheduler 排程 (1 hr)**

- Goals: Trigger a scheduling decision and watch the Bind happen.
- Hands-on:
  1. `kubectl run scheduler-demo --image=busybox --command -- sleep 3600` (🟢).
  2. `kubectl get events --field-selector reason=Scheduled` (🟢).
  3. Apply a Pod with `nodeSelector: kubernetes.io/hostname=<one-node>` and watch it bind (🟡).
  4. Apply a Pod with impossible `nodeSelector` and watch it stay Pending; `kubectl describe pod` shows scheduler messages (🟢).
  5. `kubectl logs -n kube-system kube-scheduler-<control-plane-node> --tail=50` (🟡).
- 觀念深化: scheduler is a separate process that watches Pods with empty `spec.nodeName` and runs predicate + score plugins. Reference: [scheduler framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/).
- Source: https://github.com/kubernetes/kubernetes/blob/v1.36.0/pkg/scheduler/scheduler.go
- 明日預告: Day 4 用 controller-manager 模擬 self-heal。

**Day 4 — Thu 04-30 — Controller Manager (1 hr)**

- Goals: Watch a ReplicaSet self-heal after Pod deletion; observe controller-manager logs.
- Hands-on:
  1. `kubectl create deployment heal-demo --image=nginx --replicas=3` (🟢).
  2. `kubectl get pods -l app=heal-demo -o wide` (🟢) — note 3 Pods running.
  3. `kubectl delete pod <one-pod-name>` (🟢) — observe a new Pod replacing it within ~2s.
  4. `kubectl logs -n kube-system kube-controller-manager-<control-plane-node> --tail=200 | grep replicaset` (🟡) — show informer events firing.
- 觀念深化: kube-controller-manager is a single process running ~20 controllers in goroutines. Each controller has a workqueue + informer cache. Reference: [kube-controller-manager](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/) and source [pkg/controller/replicaset/](https://github.com/kubernetes/kubernetes/tree/v1.36.0/pkg/controller/replicaset).
- 明日預告: Day 5 把鏡頭轉到 worker node 上的 kubelet 與 CRI。

**Day 5 — Fri 05-01 — kubelet + CRI (1 hr)**

- Goals: On a worker node, observe how a Pod becomes a sandbox + containers via CRI.
- Hands-on:
  1. ssh worker node. `crictl pods --name nginx` (🟡) — list a Pod sandbox.
  2. `crictl ps --pod <sandbox-id>` (🟡) — list its containers.
  3. `crictl inspectp <sandbox-id> | head -60` (🟡) — see network namespace path.
  4. `nsenter -t <pid-in-inspectp> -n ip a` (🟡) — see Pod's eth0.
- 觀念深化: kubelet talks gRPC to containerd (or CRI-O) over CRI. Pod = 1 sandbox container (`pause`) + N application containers sharing its network namespace. Reference: [CRI specification](https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto), source [pkg/kubelet/cri/](https://github.com/kubernetes/kubernetes/tree/v1.36.0/pkg/kubelet/cri).
- 明日預告: Day 6 是第一個 weekend，3 hr 拆解 kube-proxy 的 service routing。

**Day 6 — Sat 05-02 — kube-proxy + iptables/IPVS (3 hr)**

- Goals: Trace a Service IP packet from client Pod to backend Pod through iptables (or IPVS) chains.
- Hands-on:
  1. `kubectl create deployment kp-demo --image=nginx --replicas=3` + `kubectl expose deployment kp-demo --port=80` (🟢). Note the ClusterIP.
  2. ssh any node. `iptables-save -t nat | grep KUBE-SVC` (🟡) — locate the chain for our service IP.
  3. Walk the chain: `KUBE-SERVICES → KUBE-SVC-XXXX → KUBE-SEP-YYYY → DNAT to Pod IP`. Explain probability-based load balancing.
  4. Repeat with IPVS mode (if cluster uses IPVS): `ipvsadm -L -n | grep <ClusterIP>`.
  5. Curl the Service from another Pod and `tcpdump -i any port 80 -nnvv` (🟡) on a node — observe SNAT.
- 觀念深化: kube-proxy is a per-node DaemonSet that watches Service + Endpoints and re-programs iptables (or IPVS) rules. There is no proxy *process* in the data path — the kernel does the rewriting. Reference: [kube-proxy modes](https://kubernetes.io/docs/reference/networking/virtual-ips/), source [pkg/proxy/iptables/proxier.go](https://github.com/kubernetes/kubernetes/blob/v1.36.0/pkg/proxy/iptables/proxier.go).
- 明日預告: Day 7 寫一個自己的 controller。

**Day 7 — Sun 05-03 — 自寫一個 ConfigMap watcher operator (3 hr)**

- Goals: Use kubebuilder/controller-runtime to scaffold a tiny operator that watches ConfigMaps and writes a status.
- Hands-on:
  1. Install [kubebuilder](https://book.kubebuilder.io/) v4 (🟡).
  2. `kubebuilder init --domain example.com --repo example.com/cmwatcher` (🟡).
  3. `kubebuilder create api --group demo --version v1 --kind ConfigMapWatcher --resource --controller` (🟡).
  4. Edit `internal/controller/configmapwatcher_controller.go` to: list ConfigMaps in the watched namespace and update `.status.count`.
  5. `make install` (CRD installed in cluster) and `make run` (run controller locally against the cluster) (🟡).
  6. Apply a `ConfigMapWatcher` CR and watch the status update.
- 觀念深化: The whole controller is ~200 lines of Go. The `Reconcile()` function is fired by an informer watching the resource (and any resources you `.Owns()`). The work queue dedupes events; the rate limiter prevents storms. Reference: [controller-runtime book](https://book.kubebuilder.io/cronjob-tutorial/controller-implementation.html).
- 明日預告: Week 2 開始。Day 8 安裝 cilium。

---

### Task 3: Block 2 — Days 8-14 (cilium + multus)

**Files:**
- Create: `next-site/content/learning-plan/features/day-08.mdx` … `day-14.mdx`

- [ ] **Step 1: Write all 7 MDX files following the Block 2 brief**

- [ ] **Step 2: Spot-check day-08.mdx**

Open it. Confirm 8 sections, tier badges, cross-day links to day-07 and day-09.

- [ ] **Step 3: Commit**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/content/learning-plan/features/day-08.mdx next-site/content/learning-plan/features/day-09.mdx next-site/content/learning-plan/features/day-1[0-4].mdx
git -c commit.gpgsign=false commit -m "feat(sp-2): write Block 2 day-pages (Days 8-14, cilium + multus)

Days 8-12 are 1-hr weekday labs; Days 13-14 are 3-hr weekend labs.
Coverage: install cilium → eBPF datapath → NetworkPolicy/L7 → Hubble →
encryption → multus install → multus delegate flow source read.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

#### Block 2 brief

**Block goal:** Replace the default CNI with Cilium, observe its eBPF data path, then layer Multus for VM secondary networks.

**Day 8 — Mon 05-04 — 安裝 Cilium (1 hr)**

- Caveat upfront: replacing the running CNI may disrupt traffic; do this on a non-production lab cluster.
- Hands-on:
  1. `helm repo add cilium https://helm.cilium.io/` (🟢).
  2. `kubectl -n kube-system delete daemonset <existing-cni>` if applicable (🟡, destructive — list pre-conditions).
  3. `helm install cilium cilium/cilium --version 1.19.3 --namespace kube-system --set kubeProxyReplacement=false` (🟡; for a beginner-friendly setup leave kube-proxy in place).
  4. `kubectl -n kube-system get pods -l k8s-app=cilium -w` (🟡) — wait until all Ready.
  5. `cilium status --wait` (🟡, requires `cilium` CLI installed).
- 觀念深化: cilium-agent is a DaemonSet; cilium-operator is a Deployment. The agent compiles eBPF programs and loads them into the kernel for each endpoint. References: [cilium architecture](https://docs.cilium.io/en/v1.19/overview/component-overview/), source [daemon/cmd/](https://github.com/cilium/cilium/tree/v1.19.3/daemon/cmd).
- 明日預告: Day 9 用 cilium monitor 看 eBPF trace。

**Day 9 — Tue 05-05 — eBPF datapath 觀察 (1 hr)**

- Hands-on:
  1. `cilium status --verbose | head -50` (🟡).
  2. `kubectl -n kube-system exec -it ds/cilium -- cilium bpf endpoint list | head -10` (🟡) — show endpoints have an ID and IP.
  3. `kubectl -n kube-system exec -it ds/cilium -- cilium monitor --type drop` (🟡) — leave running, generate traffic from another terminal.
  4. From another Pod: `kubectl exec -it some-pod -- curl -m 2 1.2.3.4` (🟢, expects timeout) — see the drop.
- 觀念深化: BPF maps store policy / endpoint / service data. The agent owns these maps; programs read them. References: [cilium BPF reference](https://docs.cilium.io/en/v1.19/concepts/ebpf/intro/), source [bpf/](https://github.com/cilium/cilium/tree/v1.19.3/bpf).
- 明日預告: Day 10 寫 NetworkPolicy。

**Day 10 — Wed 05-06 — NetworkPolicy + CiliumNetworkPolicy (1 hr)**

- Hands-on:
  1. Create namespace + 2 Pods (`a`, `b`) (🟢).
  2. Apply a default-deny NetworkPolicy in the namespace (🟡). Verify `a → b` curl fails.
  3. Apply a CNP allowing `a → b` only on HTTP path `/healthz` (L7 rule) (🟡). Verify `/healthz` succeeds and `/other` fails.
- 觀念深化: standard NetworkPolicy is L3/L4. CiliumNetworkPolicy adds L7 (HTTP, Kafka, DNS). L7 enforcement is done by an envoy-based proxy injected into the Pod's network namespace. Reference: [CNP examples](https://docs.cilium.io/en/v1.19/security/policy/), source [pkg/policy/](https://github.com/cilium/cilium/tree/v1.19.3/pkg/policy).
- 明日預告: Day 11 部署 Hubble 視覺化。

**Day 11 — Thu 05-07 — Hubble (1 hr)**

- Hands-on:
  1. `helm upgrade cilium cilium/cilium --namespace kube-system --reuse-values --set hubble.relay.enabled=true --set hubble.ui.enabled=true` (🟡).
  2. `cilium hubble port-forward&` (🟡).
  3. `hubble observe --pod default/a` (🟡) — list flows.
  4. Open Hubble UI in browser, see graph (🔴, depends on local browser).
- 觀念深化: Hubble taps into Cilium's flow events from BPF and exposes them via gRPC. References: [Hubble](https://docs.cilium.io/en/v1.19/observability/hubble/), source [hubble/](https://github.com/cilium/cilium/tree/v1.19.3/hubble).
- 明日預告: Day 12 啟用 WireGuard transparent encryption。

**Day 12 — Fri 05-08 — Encryption: WireGuard (1 hr)**

- Hands-on:
  1. `helm upgrade cilium ... --set encryption.enabled=true --set encryption.type=wireguard` (🟡).
  2. `cilium status | grep -i encryption` (🟡).
  3. `wg show` on a node (🟡) — see the cilium WireGuard interface and peers.
  4. `tcpdump -i <node-iface> port 51871` (🟡) — observe encrypted UDP between nodes.
- 觀念深化: Cilium creates a WireGuard interface and routes all node-to-node Pod traffic through it. References: [encryption guide](https://docs.cilium.io/en/v1.19/security/network/encryption-wireguard/).
- 明日預告: Day 13 開始裝 multus，準備給 VM 用第二張網卡。

**Day 13 — Sat 05-09 — Multus 安裝 + NetworkAttachmentDefinition (3 hr)**

- Hands-on:
  1. `kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.2.4/deployments/multus-daemonset.yml` (🟡).
  2. Wait for `kube-multus-ds` DaemonSet to be Ready (🟢).
  3. Inspect what multus did: `ls /etc/cni/net.d/` on a node (🟡) — see new `00-multus.conf`. Original CNI conf renamed.
  4. Create a bridge NAD pointing at a Linux bridge that exists on the node (🟡). Provide YAML inline.
  5. Apply a Pod with `k8s.v1.cni.cncf.io/networks` annotation referencing the NAD; `kubectl exec ... -- ip a` shows 2 interfaces (🟡).
- 觀念深化: Multus is a "meta-plugin": it stays first in `/etc/cni/net.d/`, intercepts CNI calls, then delegates to the original CNI for the primary interface and to other plugins for additional interfaces. References: [Multus quickstart](https://github.com/k8snetworkplumbingwg/multus-cni/blob/v4.2.4/docs/quickstart.md).
- 明日預告: Day 14 讀 multus delegate flow 原始碼。

**Day 14 — Sun 05-10 — Multus delegate flow source read (3 hr)**

- Hands-on (mostly reading + diagram-drawing on paper):
  1. Read [pkg/multus/multus.go](https://github.com/k8snetworkplumbingwg/multus-cni/blob/v4.2.4/pkg/multus/multus.go) `cmdAdd()` from top to bottom.
  2. Trace: NetConf parsing → primary CNI Add call → delegate CNI Add for each `networks` annotation → result merging.
  3. Repeat with two VMs (KubeVirt VMs) using the same NAD — anticipate the same path.
  4. (Optional) Build multus from source: `git clone -b v4.2.4 ...; make`. Compare resulting binary to what's in the DaemonSet (🟢, 本機可驗).
- 觀念深化: Multus is a 1500-line CNI plugin. Most of its complexity is in delegate config rendering and result aggregation. Reference: [Multus design](https://github.com/k8snetworkplumbingwg/multus-cni/blob/v4.2.4/docs/how-to-use.md).
- 明日預告: Week 3 開始 — ceph 與 rook。

---

### Task 4: Block 3 — Days 15-21 (ceph + rook)

**Files:**
- Create: `next-site/content/learning-plan/features/day-15.mdx` … `day-21.mdx`

- [ ] **Step 1: Write all 7 MDX files following the Block 3 brief**

- [ ] **Step 2: Spot-check day-15.mdx + day-20.mdx**

Confirm tier badges, cross-day links, no fabricated paths.

- [ ] **Step 3: Commit**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/content/learning-plan/features/day-1[5-9].mdx next-site/content/learning-plan/features/day-2[0-1].mdx
git -c commit.gpgsign=false commit -m "feat(sp-2): write Block 3 day-pages (Days 15-21, ceph + rook)

Days 15-19 explore Proxmox-managed Ceph internals + ceph-csi integration.
Days 20-21 install Rook in a kind cluster (mini ceph) and add RGW S3.
Coverage: cluster health → CRUSH → pool/PG/RBD → ceph-csi RBD/CephFS PVC →
Rook operator reconcile → S3 access from k8s.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

#### Block 3 brief

**Block goal:** Use the existing Proxmox ceph as the production storage backend; integrate via ceph-csi; on the side, study Rook's operator pattern in a throwaway kind cluster.

**Day 15 — Mon 05-11 — Proxmox ceph 健檢 (1 hr)**

- Hands-on (all 🔴 — values depend on your cluster):
  1. ssh Proxmox node. `ceph -s` — show cluster summary.
  2. `ceph osd tree` — show CRUSH hierarchy (host > root). Identify your hosts and their OSDs.
  3. `ceph mon stat` — confirm 3 MONs, identify quorum leader.
  4. `ceph df` — see used / available capacity per pool.
- 觀念深化: Ceph has 3 daemon types in MON/OSD/MGR (+ MDS for CephFS, RGW for S3). The cluster runs on a Paxos-based MON quorum that owns the cluster map. References: [Ceph architecture](https://docs.ceph.com/en/squid/architecture/), source overview at [src/](https://github.com/ceph/ceph/tree/v19.2.3/src).
- 明日預告: Day 16 看 CRUSH map。

**Day 16 — Tue 05-12 — CRUSH map (1 hr)**

- Hands-on:
  1. `ceph osd crush dump | head -80` (🔴) — show buckets and rules.
  2. `ceph osd crush dump | jq '.rules'` (🔴) — see existing replication rule.
  3. `ceph osd crush class create ssd` if you have ssd OSDs; `ceph osd crush set-device-class ssd osd.0 osd.1` (🔴, modifies cluster).
  4. (Read-only alt) `ceph osd metadata 0 | grep -i device` to see device class (🔴).
- 觀念深化: CRUSH = Controlled Replication Under Scalable Hashing. Maps PG → OSDs deterministically, taking into account the failure domain hierarchy. Reference: [CRUSH paper](https://ceph.com/wp-content/uploads/2016/08/weil-crush-sc06.pdf), source [src/crush/](https://github.com/ceph/ceph/tree/v19.2.3/src/crush).
- 明日預告: Day 17 開 RBD pool。

**Day 17 — Wed 05-13 — Pool + PG + RBD (1 hr)**

- Hands-on:
  1. `ceph osd pool create k8s-rbd 32 32 replicated` (🔴) — pool with 32 PGs, replicated rule.
  2. `ceph osd pool application enable k8s-rbd rbd` (🔴).
  3. `rbd create k8s-rbd/test-vol --size 1G` (🔴).
  4. `rbd info k8s-rbd/test-vol` (🔴) — see object_prefix / format / features.
  5. (Optional) `rbd map k8s-rbd/test-vol` (requires ceph kmod, 🔴).
- 觀念深化: An RBD volume is a flat collection of 4 MB objects in a RADOS pool. PG count must be tuned: too few → hot OSDs; too many → memory pressure. Reference: [PG calculator](https://docs.ceph.com/en/squid/rados/operations/placement-groups/).
- 明日預告: Day 18 從 k8s 端裝 ceph-csi 連 Proxmox ceph。

**Day 18 — Thu 05-14 — k8s 裝 ceph-csi + StorageClass (1 hr)**

- Hands-on (commands 🟡 unless noted):
  1. From a Proxmox node: `ceph auth get-or-create client.k8s mon 'profile rbd' osd 'profile rbd pool=k8s-rbd'` (🔴) — generate credentials.
  2. From k8s side: `helm repo add ceph-csi https://ceph.github.io/csi-charts`.
  3. Create the ceph-csi config Secret with mon endpoints + the auth from step 1 (provide YAML inline, 🔴 — IPs and key).
  4. `helm install ceph-csi-rbd ceph-csi/ceph-csi-rbd --namespace ceph-csi-rbd --create-namespace --version 3.13.0` (🟡).
  5. Create a StorageClass referencing the cluster ID + pool (provide YAML inline).
  6. Create a PVC of 1Gi (🟡); verify `kubectl get pvc` shows Bound.
- 觀念深化: ceph-csi is two CSI drivers (rbd, cephfs). Each runs as DaemonSet (per-node node plugin) + Deployment (controller plugin). The controller calls Ceph APIs to create/delete volumes; the node plugin maps RBDs into the pod. Reference: [ceph-csi docs](https://github.com/ceph/ceph-csi/blob/v3.13.0/docs/deploy-rbd.md).
- 明日預告: Day 19 試 CephFS 多 Pod 共用 PV。

**Day 19 — Fri 05-15 — CephFS + 多 Pod 共用 PV (1 hr)**

- Hands-on:
  1. From Proxmox: `ceph fs volume create k8s-fs` (🔴).
  2. From k8s: install `ceph-csi-cephfs` similar to Day 18 (🟡).
  3. Create a CephFS StorageClass + PVC with `accessModes: [ReadWriteMany]` (🟡).
  4. Two Pods both mount the same PVC; one writes, the other reads (🟡).
- 觀念深化: CephFS uses MDS daemons to serve POSIX filesystem semantics on top of RADOS. Reference: [CephFS architecture](https://docs.ceph.com/en/squid/cephfs/architecture/).
- 明日預告: Day 20 用 kind 跑 mini Rook 看 operator。

**Day 20 — Sat 05-16 — Rook 在 kind 上 mini ceph (3 hr)**

- Hands-on (all on local laptop, no impact on Proxmox cluster):
  1. `kind create cluster --name rook-study` (🟢).
  2. `helm install --create-namespace --namespace rook-ceph rook-ceph rook-release/rook-ceph` (🟡).
  3. Apply a minimal CephCluster CR (single OSD on a directory-based storage, NOT raw disk) (🟡, sample YAML inline).
  4. `kubectl -n rook-ceph get cephcluster -w` (🟡) — observe state transitions.
  5. `kubectl -n rook-ceph logs -l app=rook-ceph-operator --tail=200` (🟡) — read operator reconcile messages.
  6. Read source: [Operator's Reconcile entry](https://github.com/rook/rook/blob/release-1.16/pkg/operator/ceph/cluster/cluster_controller.go) (🟢, source-read).
  7. `kind delete cluster --name rook-study` (🟢) when done.
- 觀念深化: Rook implements CephCluster, CephBlockPool, CephObjectStore, CephFilesystem CRDs. Each has a controller that reconciles the spec into actual ceph daemons. Reference: [Rook design](https://rook.io/docs/rook/v1.16/Getting-Started/intro/).
- 明日預告: Day 21 在 Proxmox ceph 開 RGW S3。

**Day 21 — Sun 05-17 — RGW (S3) + boto3 訪問 (3 hr)**

- Hands-on:
  1. From Proxmox: `radosgw-admin user create --uid=k8s-app --display-name="K8s App" --access-key=AKIAxxx --secret-key=secxxx` (🔴).
  2. Test from terminal: `aws s3 --endpoint-url=http://<rgw-endpoint>:7480 mb s3://test-bucket` (🔴).
  3. Run a Python Pod with `boto3` installed; mount the access/secret as Secret env vars; upload a file via boto3 client (🟡, YAML + python script inline).
  4. `radosgw-admin bucket list` (🔴) — confirm bucket appears.
- 觀念深化: RGW (Rados Gateway) is a stateless HTTP daemon that translates S3/Swift API calls into RADOS operations. Each S3 object becomes a head + tail RADOS objects. Reference: [RGW S3 API](https://docs.ceph.com/en/squid/radosgw/s3/), source [src/rgw/](https://github.com/ceph/ceph/tree/v19.2.3/src/rgw).
- 明日預告: Week 4 開始 — KubeVirt。

---

### Task 5: Block 4 — Days 22-30 (kubevirt + 整合)

**Files:**
- Create: `next-site/content/learning-plan/features/day-22.mdx` … `day-30.mdx`

- [ ] **Step 1: Write all 9 MDX files following the Block 4 brief**

- [ ] **Step 2: Spot-check day-22.mdx + day-27.mdx + day-30.mdx**

Confirm tier badges, cross-day links, no fabricated function names.

The Day 30 page replaces "明日預告" with "## 30 天回顧" — a 2-paragraph summary recapping what each block contributed and what the user can now do. Mention the 5 source-analysis projects (k8s, cilium, multus, ceph, kubevirt) as suggested next-step study.

- [ ] **Step 3: Commit**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/content/learning-plan/features/day-2[2-9].mdx next-site/content/learning-plan/features/day-30.mdx
git -c commit.gpgsign=false commit -m "feat(sp-2): write Block 4 day-pages (Days 22-30, kubevirt + 整合)

Days 22-26 are 1-hr weekday labs; Days 27-28 are 3-hr weekend; Days 29-30
are 1-hr weekday closeout. Coverage: install KubeVirt → first VM →
PVC-backed disk → virt-handler/launcher anatomy → multus VM NIC →
live migration → DataVolume/CDI → monitoring → integrated platform demo.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

#### Block 4 brief

**Block goal:** Deploy KubeVirt on the cluster; build a VM platform that uses ceph-csi for VM disks (Day 18) and multus for secondary NICs (Day 13), supports live migration, and ends with an integrated demo.

**Day 22 — Mon 05-18 — 安裝 KubeVirt (1 hr)**

- Hands-on:
  1. Verify nested virt is enabled on Proxmox VMs: `kubectl get nodes -o jsonpath='{.items[*].status.allocatable}' | grep devices.kubevirt.io/kvm` (🟡). If 0, fix Proxmox VM CPU type to `host` and reboot.
  2. `kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v1.8.2/kubevirt-operator.yaml` (🟡).
  3. `kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v1.8.2/kubevirt-cr.yaml` (🟡).
  4. `kubectl -n kubevirt wait --for=condition=Available kv kubevirt --timeout=10m` (🟡).
  5. `kubectl -n kubevirt get pods` (🟢) — see virt-controller, virt-api, virt-handler, virt-operator.
- 觀念深化: KubeVirt is a CRD-based extension that wraps libvirt/qemu. Components: `virt-operator` (manages KubeVirt itself), `virt-api` (admission webhook), `virt-controller` (reconciles VirtualMachine→VMI→Pod), `virt-handler` (per-node DaemonSet, manages VMs locally). References: [Architecture](https://kubevirt.io/user-guide/architecture/), source [pkg/virt-controller/](https://github.com/kubevirt/kubevirt/tree/v1.8.2/pkg/virt-controller).
- 明日預告: Day 23 啟動第一台 VM。

**Day 23 — Tue 05-19 — 第一台 VM (1 hr)**

- Hands-on:
  1. Apply a `VirtualMachine` with `containerDisk` source (e.g., `quay.io/containerdisks/fedora:39`) and 1Gi memory (🟡, YAML inline). Set `runStrategy: Always`.
  2. `kubectl get vm` and `kubectl get vmi` (🟢) — note the difference (VM = persistent definition; VMI = running instance).
  3. Wait for `vmi` Ready, then `virtctl console <vm-name>` (🟡). Default Fedora cloud login: skip with arrow keys / use cloud-init.
  4. Add a cloud-init userData with a root password; reapply (🟡); reconnect via console.
- 觀念深化: VirtualMachine is to Pod what Deployment is to ReplicaSet — a desired state, with VirtualMachineInstance as the single running instance. Source: [pkg/virt-controller/watch/vm.go](https://github.com/kubevirt/kubevirt/blob/v1.8.2/pkg/virt-controller/watch/vm.go).
- 明日預告: Day 24 給 VM 用 Day 18 的 ceph-csi PVC 當磁碟。

**Day 24 — Wed 05-20 — VM 用 PVC 當磁碟 (1 hr)**

- Hands-on:
  1. Create a PVC of 10Gi using the ceph-csi-rbd StorageClass from Day 18 (🟡).
  2. Apply a `DataVolume` that imports a Fedora cloud image into the PVC (or pre-stage it manually) (🟡).
  3. Apply a VirtualMachine referencing the PVC as a `persistentVolumeClaim` source (🟡). Replace the `containerDisk` from Day 23 with the PVC.
  4. `kubectl get pvc` (🟢) → Bound.
  5. `virtctl console` (🟡) — confirm OS booted from RBD volume.
- 觀念深化: KubeVirt's storage layer reuses k8s PVC. The VM's disk is qemu's representation of the block device that ceph-csi exposed at `/dev/rbd*` inside the virt-launcher Pod's mount namespace. References: [Disks and Volumes](https://kubevirt.io/user-guide/storage/disks_and_volumes/).
- 明日預告: Day 25 在 node 上看 virt-handler / virt-launcher 真實長相。

**Day 25 — Thu 05-21 — virt-handler + virt-launcher 行為 (1 hr)**

- Hands-on:
  1. Find which node a VMI is on: `kubectl get vmi -o wide` (🟢).
  2. ssh that node. `crictl pods | grep virt-launcher` (🟡) — see the launcher Pod.
  3. `crictl ps --pod <id>` — see the `compute` container running qemu.
  4. `crictl exec -it <compute-container> -- ps -ef | grep qemu` (🟡) — see the actual `qemu-system-x86_64` command line.
  5. `crictl exec -it <compute-container> -- virsh list` (🟡) — see libvirt domain.
- 觀念深化: virt-launcher is a per-VM Pod containing libvirtd + qemu, supervised by virt-handler. virt-handler watches VMI updates and decides launch/migrate/stop. Source: [pkg/virt-handler/vm.go](https://github.com/kubevirt/kubevirt/blob/v1.8.2/pkg/virt-handler/vm.go).
- 明日預告: Day 26 給 VM 接 multus 第二張網卡。

**Day 26 — Fri 05-22 — 多網路 VM (1 hr)**

- Hands-on:
  1. Reuse the Day 13 NetworkAttachmentDefinition.
  2. Edit the VM YAML: add a second `interface` and `network` referencing the NAD via `multus.networkName`.
  3. Reapply, restart VMI (`virtctl restart`).
  4. `virtctl console`, then inside VM: `ip addr` (🟡) — see 2 NICs (eth0 = pod network via cilium, eth1 = bridge network).
- 觀念深化: KubeVirt VM networking goes through CNI like a normal Pod, but each NIC is bridged into the VM's libvirt domain via tap interfaces. Multus enables additional NICs. Source: [pkg/network/](https://github.com/kubevirt/kubevirt/tree/v1.8.2/pkg/network).
- 明日預告: Day 27 是 weekend，3 hr 試 live migration。

**Day 27 — Sat 05-23 — Live migration (3 hr)**

- Hands-on:
  1. Confirm the VM uses a shared storage (PVC from Day 24, not local) (🟡).
  2. Trigger migration: `virtctl migrate <vm-name>` (🟡).
  3. Watch: `kubectl get vmim -w` (🟢) — VirtualMachineInstanceMigration resource phase transitions: Scheduling → PreparingTarget → TargetReady → Running → Succeeded.
  4. While migration runs, ping the VM from another Pod (🟡) — observe near-zero packet loss.
  5. Inspect post-migration: `kubectl get vmi -o wide` (🟢) — note new node.
  6. Read `kubectl logs -n kubevirt -l kubevirt.io=virt-handler` lines mentioning migration (🟡).
- 觀念深化: KubeVirt uses qemu's standard live migration: source qemu opens a TCP socket, target qemu connects, source dirty-page-tracks memory and ships pages; cutover when convergence threshold met. Source: [pkg/virt-handler/cmd-client/](https://github.com/kubevirt/kubevirt/tree/v1.8.2/pkg/virt-handler/cmd-client) and [pkg/virt-launcher/virtwrap/manager.go](https://github.com/kubevirt/kubevirt/blob/v1.8.2/pkg/virt-launcher/virtwrap/manager.go).
- 明日預告: Day 28 用 DataVolume 從 URL 拉 cloud image。

**Day 28 — Sun 05-24 — DataVolume + CDI (3 hr)**

- Hands-on:
  1. Install CDI: `kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/v1.62.0/cdi-operator.yaml` and `cdi-cr.yaml` (🟡, version may vary; verify against KubeVirt v1.8.2 compatibility matrix).
  2. Apply a DataVolume sourcing from `http://download.fedoraproject.org/pub/...cloud.qcow2` (🟡, URL must be reachable).
  3. `kubectl get dv -w` (🟢) — see ImportInProgress → Succeeded.
  4. Reuse the resulting PVC for a VM (🟡).
  5. Try alternative source types: `pvc:` (clone), `registry:` (OCI image), `blank:` (empty).
- 觀念深化: CDI runs an importer Pod that downloads + qemu-img-converts the source into the target PVC. Reference: [CDI architecture](https://github.com/kubevirt/containerized-data-importer/blob/main/doc/basic_flow.md).
- 明日預告: Day 29 看 VM 監控指標。

**Day 29 — Mon 05-25 — VM 監控與除錯 (1 hr)**

- Hands-on:
  1. `kubectl get vmi -o wide` (🟢) — see IP / node / phase.
  2. `kubectl describe vmi <vm>` (🟢) — read events, conditions.
  3. `kubectl -n kubevirt port-forward svc/prometheus-operated 9090` (if you have Prometheus operator; 🟡).
  4. Browse to `kubevirt_vmi_*` metrics (vCPU usage, memory, network). (🔴, depends on Prometheus install.)
  5. `virtctl vnc <vm>` (🟡) — open VNC if you need GUI debug.
- 觀念深化: KubeVirt exports per-VM metrics from virt-handler. References: [Monitoring](https://kubevirt.io/user-guide/operations/component_monitoring/).
- 明日預告: Day 30 整合所有 element。

**Day 30 — Tue 05-26 — 平台整合 demo (1 hr)**

- Hands-on:
  1. Apply: VirtualMachine with PVC disk (Day 18 ceph-csi RBD), 2 NICs (Day 26 multus), cloud-init that installs nginx serving a simple `index.html` (🟡, YAML inline).
  2. Verify: `virtctl console`, then `systemctl status nginx`; from another Pod, curl the VM's service IP (🟡).
  3. Trigger live migration to another node (Day 27 pattern); confirm nginx stays up during migration (🟡).
  4. `virtctl stop` and `virtctl start` to verify VM definition persists (🟢).
- 觀念深化: This is the minimum viable VM platform. From here you can layer: Helm chart packaging, CRD wrappers, GUI, GitOps. Reference: [Cluster API Provider KubeVirt](https://github.com/kubernetes-sigs/cluster-api-provider-kubevirt) for full lifecycle.
- 30 天回顧: (Replace 明日預告 with a 2-paragraph wrap-up.) Block 1 拆解了 control plane 的所有組成；Block 2 換上 cilium 並看到 eBPF 真實在跑；Block 3 把 ceph 接進 k8s 並理解 RADOS 的存儲模型；Block 4 把 KubeVirt 部署到位，最終你親手建出可用的 VM 平台。下一步可以深入各專案原始碼分析（站內的 SP-3..SP-7 頁），或把這套 demo 包成 GitOps workflow。

---

### Task 6: Quiz (12 questions)

**Files:**
- Create / overwrite: `next-site/content/learning-plan/quiz.json`

12 questions, 3 per block. Each question maps back to a specific day's hands-on or 觀念深化. The quiz is designed to be answerable only if the user actually did the labs.

- [ ] **Step 1: Write the quiz**

Write the quiz to `next-site/content/learning-plan/quiz.json` as a valid JSON array of 12 question objects with `id` (1-12), `question`, `options` (4 strings), `answer` (0-indexed), `explanation`. Coverage:

| ID | Block | Topic |
|----|-------|-------|
| 1 | 1 | static Pods (Day 1) |
| 2 | 1 | scheduler bind (Day 3) |
| 3 | 1 | controller-manager informer (Day 4 / Day 7) |
| 4 | 2 | cilium eBPF map ownership (Day 9) |
| 5 | 2 | CNP L7 enforcement (Day 10) |
| 6 | 2 | multus delegate flow (Day 14) |
| 7 | 3 | CRUSH placement determinism (Day 16) |
| 8 | 3 | ceph-csi controller vs node plugin (Day 18) |
| 9 | 3 | RGW object layout (Day 21) |
| 10 | 4 | virt-launcher Pod content (Day 25) |
| 11 | 4 | live migration cutover trigger (Day 27) |
| 12 | 4 | KubeVirt 整合的關鍵：哪一層在「翻譯」VM 與 Pod (Day 22 + 25) |

Question style: ask "為什麼" / "下列何者為真" / "在 X 場景下，下一步會發生什麼" — not "下列指令的輸出是什麼" (because outputs are 🔴 cluster-dependent).

Question texts must NOT begin with "1.", "Day 1", or any number prefix — `app/[project]/quiz/page.tsx` adds the prefix automatically.

- [ ] **Step 2: Validate quiz JSON**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
python3 -c "
import json
data = json.load(open('next-site/content/learning-plan/quiz.json'))
assert len(data) == 12, f'Expected 12 questions, got {len(data)}'
for i, q in enumerate(data, 1):
    assert q['id'] == i, f'Question {i} id mismatch'
    assert isinstance(q['answer'], int), f'Q{i} answer not int'
    assert 0 <= q['answer'] < len(q['options']), f'Q{i} answer out of range'
    assert not q['question'][:2].rstrip('.').isdigit(), f'Q{i} starts with number prefix'
print('quiz.json OK')
"
```

Expected: prints `quiz.json OK`.

- [ ] **Step 3: Commit**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/content/learning-plan/quiz.json
git -c commit.gpgsign=false commit -m "feat(sp-2): add 12-question quiz for the 30-day learning plan

3 questions per block (1=k8s internals, 2=cilium/multus, 3=ceph/rook,
4=kubevirt). Questions test conceptual understanding, not exact output
strings (which are cluster-dependent).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: Final validation + dev smoke + commit

**Files:** none modified expected

- [ ] **Step 1: make validate**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate 2>&1 | tail -30
```

Must exit 0. The "No quiz.json files found" warning from SP-1 is gone now (we have one). New warnings about orphaned images are unlikely (we use no images), but ignorable.

If validate fails:
- Missing MDX file → check the slug list in `projects.ts` against `ls next-site/content/learning-plan/features/`. Filename pad must be `day-01.mdx`, not `day-1.mdx`.
- Frontmatter missing → re-add `layout: doc` and `title:` to the offending file.
- Quiz format error → re-run the python validation snippet from Task 6.

Fix and re-run. Do not proceed until exit 0.

- [ ] **Step 2: Smoke-test dev server**

```bash
cd /Users/ikaros/Documents/code/learning-k8s/next-site
nohup npm run dev > /tmp/sp2-dev.log 2>&1 &
echo $! > /tmp/sp2-dev.pid
sleep 8
```

Verify:

```bash
curl -fsS http://localhost:3000/ | grep -c "30 天"
# Expected: 1+ (homepage now shows learning-plan card)

curl -fsS http://localhost:3000/learning-plan | grep -c "Day 1"
# Expected: 1+ (landing page shows story scenes)

curl -fsS http://localhost:3000/learning-plan/features/day-01 | grep -c "今日目標"
# Expected: 1+ (day-01 page renders the 8-section template)

curl -fsS http://localhost:3000/learning-plan/features/day-30 | grep -c "30 天回顧"
# Expected: 1+ (day-30 has the closing summary)

curl -fsS http://localhost:3000/learning-plan/quiz | grep -c "static Pod"
# Expected: 1+ (quiz Q1 is about static Pods)

kill "$(cat /tmp/sp2-dev.pid)" 2>/dev/null
sleep 1
kill -9 "$(cat /tmp/sp2-dev.pid)" 2>/dev/null
rm -f /tmp/sp2-dev.pid
```

- [ ] **Step 3: Final state check**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git log --oneline -10
ls next-site/content/learning-plan/features/ | wc -l   # expected: 30
make validate 2>&1 | tail -5
```

If everything green, SP-2 is complete. No additional commit needed (each task already committed its slice).

---

## Self-review checklist

- **Spec coverage:** Each section of `2026-04-27-sp2-learning-plan-design.md` mapped to a task above.
  - § Curriculum outline → Tasks 2-5 (4 blocks)
  - § ProjectMeta entry → Task 1
  - § Day-page template → enforced in each block brief
  - § Quiz → Task 6
  - § Verification rules → enforced via "Constants the implementer must use"
  - § File structure → reflected in task File: lines
  - § Verification → Task 7

- **No placeholders:** Every code block in this plan contains complete, executable content. The "block briefs" are detailed enough that a subagent can write each day-page from them without further input. Tier badges are explicit.

- **Type / naming consistency:** `learning-plan` slug used throughout. `day-NN` zero-padded. ProjectMeta interface matches the schema in `lib/projects.ts` (verified: `id`, `displayName`, `shortName`, `description`, `githubUrl`, `submodulePath`, `color`, `accentClass`, `features`, `featureGroups`, `usecases`, `difficulty`, `difficultyColor`, `problemStatement`, `story`, `learningPaths`).

- **Reversibility:** Each task is its own commit. Reverting any single block's commit removes that week's content cleanly. Reverting Task 1's commit removes the ProjectMeta entry (homepage falls back to "尚未加入任何專案" via the SP-1 empty-state guard).

All checks pass. Plan ready for execution.
