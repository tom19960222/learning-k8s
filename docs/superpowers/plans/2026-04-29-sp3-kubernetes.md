# SP-3: kubernetes v1.36.0 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 把 kubernetes v1.36.0 加入站內，提供 4 頁 MVP 內容（architecture / api-server / controllers / kubelet）+ 5 題 quiz；`make validate` 全綠。

**Architecture:** 一個 task 加 git submodule 做 shallow clone；一個 task 跑 5 個輕量探索並產出 Structure Planner 摘要；接下來把 4 頁 MDX 與 quiz 一次寫好（用 sonnet subagent 或 inline）；最後 task 驗證並 commit。

**Tech Stack:** git submodule、Next.js 14 + MDX、Python 3 validate.py。

---

## File structure (post-SP-3)

```
learning-k8s/
├── kubernetes/                                  ← NEW git submodule (shallow @ v1.36.0)
├── .gitmodules                                  ← MODIFY (加 kubernetes 條目)
├── versions.json                                ← MODIFY ({} → {kubernetes: ...})
├── next-site/
│   ├── lib/projects.ts                          ← MODIFY (PROJECTS 加 kubernetes)
│   └── content/kubernetes/
│       ├── features/
│       │   ├── architecture.mdx                 ← CREATE
│       │   ├── api-server.mdx                   ← CREATE
│       │   ├── controllers.mdx                  ← CREATE
│       │   └── kubelet.mdx                      ← CREATE
│       └── quiz.json                            ← CREATE
└── docs/superpowers/{specs,plans}/...           ← already committed
```

---

## Tasks

### Task 1: 加 git submodule + versions.json

**Files:**
- Create dir: `kubernetes/` (git submodule)
- Modify: `.gitmodules`
- Modify: `versions.json`

- [ ] **Step 1: 加 submodule（shallow）**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git submodule add --depth 1 -b v1.36.0 https://github.com/kubernetes/kubernetes.git kubernetes 2>&1 | tail -10
```

如果 `--depth 1 -b v1.36.0` 不被支援（git 舊版），fallback：

```bash
git submodule add https://github.com/kubernetes/kubernetes.git kubernetes
git -C kubernetes fetch --depth 1 origin tag v1.36.0
git -C kubernetes checkout v1.36.0
```

驗證：
```bash
git -C kubernetes log --oneline -1
```
Expected: `02d6d2a6 ...` (Kubernetes v1.36.0 tag commit).

- [ ] **Step 2: 設 submodule 的 branch tracking**

```bash
git config -f .gitmodules submodule.kubernetes.branch v1.36.0
git config -f .gitmodules submodule.kubernetes.shallow true
cat .gitmodules
```

Expected: 含 `[submodule "kubernetes"]`、`url`、`branch = v1.36.0`、`shallow = true`。

- [ ] **Step 3: 更新 versions.json**

```bash
COMMIT=$(git -C kubernetes rev-parse HEAD)
TODAY=$(date +%Y-%m-%d)
cat > versions.json <<EOF
{
  "kubernetes": {
    "commit": "$COMMIT",
    "tag": "v1.36.0",
    "analyzed_at": "$TODAY"
  }
}
EOF
cat versions.json
```

- [ ] **Step 4: Commit**

```bash
git add .gitmodules kubernetes versions.json
git -c commit.gpgsign=false commit -m "feat(sp-3): add kubernetes v1.36.0 submodule (shallow clone)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: 探索 + Structure Planner（輕量版）

**Files:** none modified — 此 task 產出資訊給後續 task 使用

依 `skills/analyzing-source-code/SKILL.md` 的 5 個 Exploration，但 MVP 模式只需要為 4 個 page 產出材料。

- [ ] **Step 1: 探索控制平面進入點**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
ls kubernetes/cmd/ | grep -E "^(kube-apiserver|kube-controller-manager|kube-scheduler|kubelet|kube-proxy)$"
head -40 kubernetes/cmd/kube-apiserver/apiserver.go
head -40 kubernetes/cmd/kubelet/kubelet.go
head -40 kubernetes/cmd/kube-scheduler/scheduler.go
head -40 kubernetes/cmd/kube-controller-manager/controller-manager.go
```

確認 5 個 cmd 進入點存在。記錄各自 `main()` 在哪幾行。

- [ ] **Step 2: 探索 ReplicaSet controller**

```bash
ls kubernetes/pkg/controller/replicaset/
grep -n "func.*Reconcile\|func.*syncReplicaSet" kubernetes/pkg/controller/replicaset/*.go | head -10
```

記錄 `syncReplicaSet` / `manageReplicas` 等函式所在 file:line。

- [ ] **Step 3: 探索 scheduler**

```bash
grep -n "func.*scheduleOne\|func.*RunOnce" kubernetes/pkg/scheduler/*.go kubernetes/pkg/scheduler/schedule_one.go 2>/dev/null | head -10
```

記錄 scheduler main loop function。

- [ ] **Step 4: 探索 apiserver handler chain**

```bash
ls kubernetes/staging/src/k8s.io/apiserver/pkg/server/ | head
ls kubernetes/staging/src/k8s.io/apiserver/pkg/admission/
ls kubernetes/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/
```

確認 admission 與 registry 存在。

- [ ] **Step 5: 探索 kubelet CRI**

```bash
ls kubernetes/pkg/kubelet/
ls kubernetes/pkg/kubelet/kuberuntime/
grep -n "func.*SyncPod\|func.*syncPod" kubernetes/pkg/kubelet/kubelet.go kubernetes/pkg/kubelet/kuberuntime/*.go | head
```

- [ ] **Step 6: Structure Planner 摘要（記在筆記）**

把以上探索結果摘要，給後續寫作 task 用：
- architecture.mdx：用到的 cmd 進入點與整體圖
- api-server.mdx：handler.go / admission / registry 三段
- controllers.mdx：ReplicaSet syncReplicaSet + scheduler scheduleOne + informer
- kubelet.mdx：kubelet.SyncPod + kuberuntime + CRI

不需要 commit，這是 plan 內部 task。

---

### Task 3: 寫 4 個 MDX + quiz + 註冊 ProjectMeta

**Files:**
- Modify: `next-site/lib/projects.ts`
- Create: `next-site/content/kubernetes/features/architecture.mdx`
- Create: `next-site/content/kubernetes/features/api-server.mdx`
- Create: `next-site/content/kubernetes/features/controllers.mdx`
- Create: `next-site/content/kubernetes/features/kubelet.mdx`
- Create: `next-site/content/kubernetes/quiz.json`

#### Step 3.1: 註冊 kubernetes 在 projects.ts

用 Edit tool 把 `PROJECTS` 物件結尾的 `}` 之前插入 kubernetes 條目（spec § ProjectMeta 段已給完整 TypeScript）。

#### Step 3.2: 建內容目錄
```bash
cd /Users/ikaros/Documents/code/learning-k8s
mkdir -p next-site/content/kubernetes/features
```

#### Step 3.3: 寫 4 MDX

每個 MDX 共同要求：

```yaml
---
layout: doc
title: Kubernetes — <主題>
description: <一句話>
---
```

**寫作 5 條規則：**
1. 場景優先（先說工程師遇到什麼問題）
2. 禁止流水帳
3. 圖先於文字 — 但本次只用 ASCII 圖（不依賴 PNG）
4. 程式碼前要有一句說明
5. 一頁一主題

**每個 code block 必須**：第一行 comment 標 `// File: <path>` 對 Go code，或 `# File: <path>` 對 shell。

**Source 引用：** 都用 `https://github.com/kubernetes/kubernetes/blob/v1.36.0/...`

**Forbidden:**
- import statements
- `<QuizQuestion>`（quiz 在 quiz.json）
- 大陸用語
- 杜撰函式名 — 只引用 grep 過、確實存在於 v1.36.0 的 symbol

**4 個 MDX 各自骨架：**

#### architecture.mdx

```mdx
---
layout: doc
title: Kubernetes — 控制平面架構
description: 從 kubectl apply 到 Pod 跑起來的完整路徑：4 個 control plane process + 每 node 的 kubelet/kube-proxy 各自負責什麼
---

## 場景
SRE 第一次 ssh 進 control plane node ...

## 架構全貌
（ASCII 圖：4 control plane + worker nodes 上的 kubelet/kube-proxy + CRI runtime）

## 5 個元件職責
（每個元件 1-2 段：kube-apiserver / etcd / kube-controller-manager / kube-scheduler / kubelet + kube-proxy）

## kubectl apply 的旅程
（步驟列：HTTP request → admission → etcd → controller watches → scheduler bind → kubelet pulls image → CRI run）

## Static Pod：control plane 自己怎麼起來
（kubelet watch /etc/kubernetes/manifests/）

## 原始碼進入點
- cmd/kube-apiserver/apiserver.go
- cmd/kube-controller-manager/controller-manager.go
- cmd/kube-scheduler/scheduler.go
- cmd/kubelet/kubelet.go
- cmd/kube-proxy/proxy.go

每個都附 v1.36.0 GitHub URL
```

#### api-server.mdx

```mdx
---
layout: doc
title: Kubernetes — API Server 與 etcd
description: 一個 kubectl apply 從 HTTP request 到 etcd write 的完整路徑：handler chain → admission → storage → watch fan-out
---

## 場景
你 kubectl apply 一個 Deployment，幾秒後 Pod 就跑起來。中間經過了多少層處理？

## 從 HTTP request 進入
（apiserver 的 handler chain；reference handler.go）

## Admission：mutating → validating → schema
（不寫 webhook 細節；只說明三層的順序與目的）

## Storage layer：generic registry → etcd v3
（reference store.go）

## Watch fan-out
（為什麼 100 個 client watch deployments，apiserver 只 watch etcd 1 次）

## 整段路徑回顧（ASCII flow）
HTTP → handler → admission(mutating) → admission(validating) → schema validation → storage → etcd → watch event → return to client

## Source links
- staging/src/k8s.io/apiserver/pkg/server/handler.go
- staging/src/k8s.io/apiserver/pkg/admission/
- staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go
```

#### controllers.mdx

```mdx
---
layout: doc
title: Kubernetes — Controllers（含 Scheduler）
description: ReplicaSet 怎麼 self-heal、scheduler 怎麼 bind Pod 到 node、informer/work queue 為什麼是所有 controller 的共同骨架
---

## 場景
你 kubectl delete pod，2 秒後新 Pod 出現。是誰在維持 desired state？

## ReplicaSet controller 主流程
（pkg/controller/replicaset/replica_set.go 的 syncReplicaSet）

## informer + work queue 模式
（cache → delta FIFO → rate-limited queue → worker goroutine → Reconcile）

## Scheduler：scheduleOne 主迴圈
（pkg/scheduler/schedule_one.go 的 scheduleOne）

## kube-controller-manager 是個 process 跑多 controller
（informer 共享、leader election）

## ReplicaSet ↔ Scheduler ↔ kubelet 的交接
（ReplicaSet 建 Pod 但 spec.nodeName 空 → scheduler 補上 → kubelet watch到本機 Pod）

## Source links
- pkg/controller/replicaset/replica_set.go
- pkg/scheduler/schedule_one.go
- staging/src/k8s.io/client-go/tools/cache/
```

#### kubelet.mdx

```mdx
---
layout: doc
title: Kubernetes — kubelet 與 CRI
description: kubelet 在 worker node 上怎麼把 Pod 變成 container：syncPod 主迴圈、CRI gRPC、Pod sandbox、CNI 整合
---

## 場景
Pod 落到 worker node 上 → kubelet 接手 → 過幾秒就 Running。中間 kubelet 跟 containerd 怎麼對話？

## kubelet 是個 daemon
（cmd/kubelet/kubelet.go 進入點）

## syncPod 主迴圈
（kuberuntime_manager.go 的 SyncPod）

## CRI gRPC 介面
（PodSandbox + Container 兩種 RPC group；reference cri-api proto）

## Pod sandbox = pause container
（持有 network namespace；其他 container 共用）

## CNI 呼叫時機
（sandbox 建立後，呼叫 CNI plugin 給 sandbox 分配 IP）

## Source links
- pkg/kubelet/kubelet.go
- pkg/kubelet/kuberuntime/kuberuntime_manager.go
- pkg/kubelet/cri/
- https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
```

#### Step 3.4: 寫 quiz.json（5 題）

```json
[
  {
    "id": 1,
    "question": "kube-apiserver 自己也是 static Pod。誰負責把它在開機時拉起來？",
    "options": ["kubelet 從 /etc/kubernetes/manifests/ 讀 yaml 直接起 Pod，不經 API server", "systemd service 直接執行 kube-apiserver binary", "kube-controller-manager 啟動 apiserver", "etcd 啟動 apiserver"],
    "answer": 0,
    "explanation": "static Pod 的設計就是讓 kubelet 在沒有 API server 的情況下也能起 Pod，因此 control plane 可以 self-bootstrap。"
  },
  {...4 more questions, see plan execution for full content}
]
```

完整 5 題在實作時寫；題目 cover：
1. static Pod / control plane bootstrap
2. apiserver watch fan-out
3. ReplicaSet self-heal 觸發機制
4. scheduler bind 是寫 spec.nodeName
5. CRI sandbox = pause container 的角色

#### Step 3.5: 中間 commit
```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/lib/projects.ts \
        next-site/content/kubernetes/features/ \
        next-site/content/kubernetes/quiz.json
git -c commit.gpgsign=false commit -m "feat(sp-3): write 4 MDX + 5-question quiz for kubernetes v1.36.0

Architecture, api-server, controllers, kubelet — first wave MVP.
Source URLs pinned to v1.36.0. Function names grep-verified.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: validate + smoke

- [ ] **Step 1: make validate**
```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate 2>&1 | tail -25
```

如果 build 失敗，常見原因：
- `[5] Feature Files vs projects.ts`：檔名拼錯 → 對齊 features list
- frontmatter 缺 `layout: doc` → 補上
- TypeScript projects.ts 物件 syntax error → tsc --noEmit 找

- [ ] **Step 2: dev smoke**

```bash
cd /Users/ikaros/Documents/code/learning-k8s/next-site
nohup npm run dev > /tmp/sp3-dev.log 2>&1 &
echo $! > /tmp/sp3-dev.pid
sleep 8
PORT=$(grep -oE 'localhost:[0-9]+' /tmp/sp3-dev.log | tail -1 | cut -d: -f2)
echo "Dev on port $PORT"
curl -fsS http://localhost:$PORT/ | grep -c "Kubernetes\|kubernetes"
curl -fsS http://localhost:$PORT/kubernetes/ | grep -c "control plane\|architecture"
curl -fsS http://localhost:$PORT/kubernetes/features/architecture/ | grep -c "場景\|架構"
curl -fsS http://localhost:$PORT/kubernetes/features/kubelet/ | grep -c "CRI\|sandbox"
curl -fsS http://localhost:$PORT/kubernetes/quiz/ | grep -c "static Pod"
kill $(cat /tmp/sp3-dev.pid) 2>/dev/null
sleep 1
kill -9 $(cat /tmp/sp3-dev.pid) 2>/dev/null
rm -f /tmp/sp3-dev.pid /tmp/sp3-dev.log
```

每個 grep 應該 ≥ 1。

- [ ] **Step 3: 最終 commit**

如果有任何修補需要 commit：
```bash
git add -A
git -c commit.gpgsign=false commit -m "fix(sp-3): <description>

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

否則 SP-3 就此結束。

---

## Self-review

1. **Spec coverage:** Tasks 1-4 對應 spec § Architecture / Page outline / ProjectMeta / Verification。
2. **Placeholders:** 唯一的 placeholder 在 Task 3.4 的 quiz.json — 只列了 1 題範例 + 4 題主題；實作時要補完整。其他都具體。
3. **Type consistency:** ProjectMeta 結構與 SP-2 一致。`color: 'blue'` 在 page.tsx COLOR_CLASSES 已支援。
