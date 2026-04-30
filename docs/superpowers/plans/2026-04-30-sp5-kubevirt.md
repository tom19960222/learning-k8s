# SP-5: kubevirt v1.8.2 — Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax.

**Goal:** 把 kubevirt v1.8.2 加入站內，提供 4 頁 MVP（architecture / controllers / virt-handler-and-launcher / live-migration）+ 5 題 quiz；`make validate` 全綠。

**Architecture:** sp-5 spec 已 commit；submodule + versions.json 已 commit。本 plan 的 task：(1) 探索驗證 grep-pass、(2) 寫 ProjectMeta + 4 MDX + quiz、(3) validate + smoke。

**Tech Stack:** git submodule、Next.js 14 + MDX、Python 3 validate.py。

---

## File structure (post-SP-5)

```
learning-k8s/
├── kubevirt/                                     ← already added (commit 4245f9e)
├── next-site/
│   ├── lib/projects.ts                           ← MODIFY
│   └── content/kubevirt/
│       ├── features/
│       │   ├── architecture.mdx                  ← CREATE
│       │   ├── controllers.mdx                   ← CREATE
│       │   ├── virt-handler-and-launcher.mdx     ← CREATE
│       │   └── live-migration.mdx                ← CREATE
│       └── quiz.json                             ← CREATE
└── docs/superpowers/{specs,plans}/...            ← spec already committed
```

---

## Tasks

### Task 1: 探索驗證 grep-pass

**Files:** none modified

- [ ] **Step 1: virt-* 5 process 進入點存在**

```bash
ls kubevirt/cmd/virt-{operator,api,controller,handler,launcher}/*.go 2>&1
```

- [ ] **Step 2: 驗證 controllers**

```bash
grep -n "^type Controller \|^func (c \*Controller) Execute\|^func (c \*Controller) sync" \
    kubevirt/pkg/virt-controller/watch/vm/vm.go \
    kubevirt/pkg/virt-controller/watch/vmi/vmi.go \
    kubevirt/pkg/virt-controller/watch/migration/migration.go
```

預期看到 VM (line 282 Controller, 335 Execute, 3173 sync), VMI (221 Controller, 283 Execute), Migration (120 Controller, 304 Execute, 1769 sync)。

- [ ] **Step 3: 驗證 virt-handler 主迴圈**

```bash
grep -n "^func.*VirtualMachineController.*Run\|^func.*VirtualMachineController.*Execute\|^func.*VirtualMachineController.*sync\b\|^func.*processVmUpdate\|^func NewVirtualMachineController" kubevirt/pkg/virt-handler/vm.go
```

預期 NewVirtualMachineController (120), Run (242), Execute (290), sync (1354), processVmUpdate (2130)。

- [ ] **Step 4: 驗證 virt-launcher virtwrap manager**

```bash
grep -n "^type DomainManager interface\|^func NewLibvirtDomainManager\|^func (l \*LibvirtDomainManager) MigrateVMI" kubevirt/pkg/virt-launcher/virtwrap/manager.go
grep -n "^func generateMigrationFlags\|^func (l \*LibvirtDomainManager) startMigration\|^func newMigrationMonitor" kubevirt/pkg/virt-launcher/virtwrap/live-migration-source.go
```

預期 manager.go: DomainManager (135), NewLibvirtDomainManager (239), MigrateVMI (683)；live-migration-source.go: generateMigrationFlags (96), startMigration (285), newMigrationMonitor (407)。

- [ ] **Step 5: migration-proxy 與 converter 存在**

```bash
ls kubevirt/pkg/virt-handler/migration-proxy/ kubevirt/pkg/virt-launcher/virtwrap/converter/converter.go 2>&1
```

不需 commit。

---

### Task 2: 寫 ProjectMeta + 4 MDX + quiz

**Files:**
- Modify: `next-site/lib/projects.ts`
- Create: `next-site/content/kubevirt/features/architecture.mdx`
- Create: `next-site/content/kubevirt/features/controllers.mdx`
- Create: `next-site/content/kubevirt/features/virt-handler-and-launcher.mdx`
- Create: `next-site/content/kubevirt/features/live-migration.mdx`
- Create: `next-site/content/kubevirt/quiz.json`

#### Step 2.1: 註冊 kubevirt 在 projects.ts

color 用 `purple`（已存在於 page.tsx COLOR_CLASSES）。

ProjectMeta 結構參考 cilium / kubernetes，內容覆蓋 4 features、3 difficulty paths、story 5 scenes（VM apply → controller → handler → launcher → migration）。

#### Step 2.2: 寫 4 MDX

每個 MDX：
- `layout: doc`、`title: KubeVirt — <主題>`、`description: <一句話>`
- 場景優先；ASCII 圖；code block 第一行 comment 標 `// File: <path>`；URL 用 `https://github.com/kubevirt/kubevirt/blob/v1.8.2/...`
- forbidden: import statements、`<QuizQuestion>`、大陸用語、杜撰 symbol

骨架見 spec § 4 頁切法。

#### Step 2.3: 寫 quiz.json (5 題)

題目：
1. virt-launcher 為什麼是 per-VMI Pod
2. VM / VMI / VMIM 三 CRD 關係
3. virt-handler / virt-launcher 為什麼用 gRPC
4. live migration 收斂與 cutover
5. migration-proxy 的角色

#### Step 2.4: Commit

```bash
git add next-site/lib/projects.ts next-site/content/kubevirt/
git -c commit.gpgsign=false commit -m "feat(sp-5): write 4 MDX + 5-question quiz for kubevirt v1.8.2

architecture, controllers, virt-handler-and-launcher, live-migration.
Source URLs pinned to v1.8.2. Function names grep-verified.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: validate + smoke

- [ ] **Step 1: make validate**

```bash
cd /Users/ikaros/Documents/code/learning-k8s && make validate 2>&1 | tail -30
```

- [ ] **Step 2: dev smoke**

```bash
cd /Users/ikaros/Documents/code/learning-k8s/next-site
nohup npm run dev > /tmp/sp5-dev.log 2>&1 &
echo $! > /tmp/sp5-dev.pid
sleep 8
PORT=$(grep -oE 'localhost:[0-9]+' /tmp/sp5-dev.log | tail -1 | cut -d: -f2)
curl -fsS http://localhost:$PORT/kubevirt/ | grep -c -i "kubevirt\|VMI"
curl -fsS http://localhost:$PORT/kubevirt/features/architecture/ | grep -c -i "virt-handler\|virt-launcher\|VMI"
curl -fsS http://localhost:$PORT/kubevirt/features/controllers/ | grep -c -i "controller\|reconcile"
curl -fsS http://localhost:$PORT/kubevirt/features/virt-handler-and-launcher/ | grep -c -i "libvirt\|qemu\|virtwrap"
curl -fsS http://localhost:$PORT/kubevirt/features/live-migration/ | grep -c -i "migration\|memory\|postcopy"
curl -fsS http://localhost:$PORT/kubevirt/quiz/ | grep -c -i "VMIM\|gRPC\|migration"
kill $(cat /tmp/sp5-dev.pid) 2>/dev/null; sleep 1
kill -9 $(cat /tmp/sp5-dev.pid) 2>/dev/null
rm -f /tmp/sp5-dev.pid /tmp/sp5-dev.log
```

每個 grep ≥ 1。

- [ ] **Step 3: 修補 (如需要)**

如果有問題，fix 後 commit。否則 SP-5 結束。

---

## Self-review

1. **Spec coverage:** Tasks 1-3 對應 spec § 範圍 + 4 頁切法 + Quiz + 跟現有 SP 接點。
2. **Placeholders:** Task 2 的 MDX content 沒寫完整 (與 SP-3/SP-4 plan 風格一致 — 用 spec § 各頁的 outline 當骨架，實作時參考 cilium MDX 風格寫足內容)。
3. **Type consistency:** ProjectMeta 用既有 interface；color 用 `purple`（page.tsx 已支援）。
