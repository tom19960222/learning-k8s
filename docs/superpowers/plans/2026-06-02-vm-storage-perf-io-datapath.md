# VM Disk IO 效能調教 — vm-storage-perf 新分類 + RBD IO datapath 首頁 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重新對齊 KubeVirt v1.5.0 的 repo 版本、新增 Linux kernel 與 ceph-csi submodule、建立跨層分類 `vm-storage-perf`，並產出 krbd 主軸的 RBD IO datapath 一頁。

**Architecture:** 先做版本 re-pin（subagent 平行下載、主線序列化 git 寫入），再 re-verify 受影響的既有頁行號，接著建立新 project 與內容目錄，最後 source-first 撰寫 datapath 頁。所有驗證以 `make validate`（含 Next.js build）exit 0 為閘門；source 引用以本地 pinned submodule 為 single source of truth。

**Tech Stack:** git submodule（shallow / single-branch）、Next.js 14 App Router（static export）、MDX（next-mdx-remote）、Python validate.py、Bash。

> 本 plan 不是 code-TDD；「測試」是 `make validate` gate + source 行號核對。每個 Task 結束都 commit。
> Commit 用 `git commit --no-gpg-sign`；push 用 `GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push`。
> 分支：`vm-storage-perf-io-datapath`（已存在、spec 已 commit 於此）。

---

## File Structure

新增 / 修改的檔案與職責：

- `.gitmodules`（修改）— qemu/libvirt/kubevirt 的 `branch =` 改版本；新增 linux、ceph-csi 兩條 submodule。
- `qemu/`、`libvirt/`、`kubevirt/`（submodule re-pin）— checkout 到新 tag。
- `linux/`、`ceph-csi/`（新 submodule）— 新增並 checkout。
- `next-site/lib/projects.ts`（修改）— 新增 `vm-storage-perf` project 條目。
- `next-site/content/vm-storage-perf/features/rbd-io-datapath.mdx`（新增）— datapath 主頁。
- `next-site/content/vm-storage-perf/quiz.json`（新增）— `[]`。
- `next-site/content/kubevirt/features/windows-vm-features.mdx`（可能修改）— re-verify 後修正 libvirt/qemu/kubevirt 行號。
- 其餘 kubevirt 內容頁（可能修改）— re-verify 後修正 kubevirt 行號。

---

## Task 1: Re-pin qemu submodule v11.0.0 → v9.1.0

**Files:**
- Modify: `.gitmodules`（`submodule "qemu"` 的 `branch`）
- Submodule: `qemu/`

> 可由 subagent A 平行執行「下載」部分（`git fetch` 新 tag），但 `.gitmodules` 與 index 寫入在主線序列化。下方步驟為主線最終要跑的完整序列。

- [ ] **Step 1: 改 .gitmodules 的 qemu branch**

把 `.gitmodules` 中：
```
[submodule "qemu"]
	path = qemu
	url = https://github.com/qemu/qemu.git
	branch = v11.0.0
	shallow = true
```
的 `branch = v11.0.0` 改成 `branch = v9.1.0`。

- [ ] **Step 2: fetch + checkout v9.1.0**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s/qemu
git fetch --depth 1 origin tag v9.1.0
git checkout v9.1.0
cd ..
```
Expected: `HEAD is now at ... v9.1.0`（detached HEAD 正常）。

- [ ] **Step 3: 驗證版本**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
git -C qemu describe --tags
ls qemu/block/rbd.c qemu/hw/block/virtio-blk.c qemu/block/block-backend.c
```
Expected: `v9.1.0`；三個檔案都存在（datapath 頁要引用）。

- [ ] **Step 4: Commit**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add .gitmodules qemu
git commit --no-gpg-sign -m "submodule: re-pin qemu v11.0.0 -> v9.1.0（對齊 kubevirt v1.5.0）"
```

---

## Task 2: Re-pin libvirt submodule v12.3.0 → v10.10.0

**Files:**
- Modify: `.gitmodules`（`submodule "libvirt"` 的 `branch`）
- Submodule: `libvirt/`

- [ ] **Step 1: 改 .gitmodules 的 libvirt branch**

把 `submodule "libvirt"` 的 `branch = v12.3.0` 改成 `branch = v10.10.0`。

- [ ] **Step 2: fetch + checkout v10.10.0**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s/libvirt
git fetch --depth 1 origin tag v10.10.0
git checkout v10.10.0
cd ..
```
Expected: `HEAD is now at ... v10.10.0`。

> 註：libvirt upstream 為 gitlab.com（`.gitmodules` 既有 url）。若 tag fetch 失敗，改用 `git fetch --depth 1 origin refs/tags/v10.10.0:refs/tags/v10.10.0`。

- [ ] **Step 3: 驗證版本與 datapath 引用檔**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
git -C libvirt describe --tags
ls libvirt/src/qemu/qemu_command.c
```
Expected: `v10.10.0`；`qemu_command.c` 存在。

- [ ] **Step 4: Commit**

```bash
git add .gitmodules libvirt
git commit --no-gpg-sign -m "submodule: re-pin libvirt v12.3.0 -> v10.10.0（對齊 kubevirt v1.5.0）"
```

---

## Task 3: Re-pin kubevirt submodule v1.8.2 → v1.5.0

**Files:**
- Modify: `.gitmodules`（`submodule "kubevirt"` 的 `branch`）
- Submodule: `kubevirt/`

- [ ] **Step 1: 改 .gitmodules 的 kubevirt branch**

把 `submodule "kubevirt"` 的 `branch = v1.8.2` 改成 `branch = v1.5.0`。

- [ ] **Step 2: fetch + checkout v1.5.0**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s/kubevirt
git fetch --depth 1 origin tag v1.5.0
git checkout v1.5.0
cd ..
```
Expected: `HEAD is now at 522b44c0ce ... v1.5.0`。

- [ ] **Step 3: 驗證版本與 converter 路徑**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
git -C kubevirt describe --tags
ls kubevirt/pkg/virt-launcher/virtwrap/converter/
```
Expected: `v1.5.0`；converter 目錄存在（datapath / 既有頁會引用）。

- [ ] **Step 4: Commit**

```bash
git add .gitmodules kubevirt
git commit --no-gpg-sign -m "submodule: re-pin kubevirt v1.8.2 -> v1.5.0"
```

---

## Task 4: 新增 linux-hwe-6.8 submodule @ applied/6.8.0-52.53_22.04.1

**Files:**
- Modify: `.gitmodules`（新增 `submodule "linux"`）
- Submodule: `linux/`（新增）

> 這是最大的 repo（即使 shallow 也最慢）。subagent C 適合單獨負責下載。launchpad 匿名 URL 已驗證可 `ls-remote`（exit 0）。

- [ ] **Step 1: shallow add linux submodule（指定 tag）**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
git submodule add --depth 1 -b applied/6.8.0-52.53_22.04.1 \
  https://git.launchpad.net/ubuntu/+source/linux-hwe-6.8 linux
```
Expected: clone 成功，`linux/` 出現。

> 若 `git submodule add -b <tag>` 因 tag-not-branch 報錯，改用：
> ```bash
> git submodule add https://git.launchpad.net/ubuntu/+source/linux-hwe-6.8 linux
> cd linux && git fetch --depth 1 origin tag applied/6.8.0-52.53_22.04.1 && git checkout applied/6.8.0-52.53_22.04.1 && cd ..
> ```
> 並在 `.gitmodules` 的 `submodule "linux"` 手動加 `branch = applied/6.8.0-52.53_22.04.1` 與 `shallow = true`。

- [ ] **Step 2: 驗證 datapath 要用的 kernel 路徑都在**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
ls linux/drivers/block/rbd.c \
   linux/net/ceph/osd_client.c \
   linux/drivers/block/virtio_blk.c \
   linux/virt/kvm/eventfd.c \
   linux/drivers/virtio/virtio_ring.c
```
Expected: 五個檔案都存在（datapath 各跳的 source 錨點）。

- [ ] **Step 3: Commit**

```bash
git add .gitmodules linux
git commit --no-gpg-sign -m "submodule: add linux-hwe-6.8 @ applied/6.8.0-52.53_22.04.1（host kernel）"
```

---

## Task 5: 新增 ceph-csi submodule @ v3.14.0

**Files:**
- Modify: `.gitmodules`（新增 `submodule "ceph-csi"`）
- Submodule: `ceph-csi/`（新增）

- [ ] **Step 1: shallow add ceph-csi submodule**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
git submodule add --depth 1 -b v3.14.0 \
  https://github.com/ceph/ceph-csi.git ceph-csi
```
Expected: clone 成功，`ceph-csi/` 出現。

- [ ] **Step 2: 驗證 mounter / krbd 相關路徑**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
git -C ceph-csi describe --tags
ls ceph-csi/internal/rbd/
```
Expected: `v3.14.0`；`internal/rbd/` 存在（krbd map 邏輯：rbd attach / nodeserver）。

- [ ] **Step 3: Commit**

```bash
git add .gitmodules ceph-csi
git commit --no-gpg-sign -m "submodule: add ceph-csi v3.14.0"
```

---

## Task 6: Re-verify + 修正既有頁的 source 行號（re-pin 副作用）

**Files:**
- Test/Verify: `next-site/content/kubevirt/features/windows-vm-features.mdx`
- Test/Verify: `next-site/content/kubevirt/features/topology-spread-constraints.mdx` 與其餘 kubevirt 頁
- Modify: 上述任何對不上的頁

> windows-vm-features 引用 libvirt/qemu/kubevirt 三 repo 共多處；topology-spread 等只引用 kubevirt。三個 repo 都已 re-pin，行號可能偏移。

- [ ] **Step 1: 列出所有受影響的 File: 引用**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
grep -rnE "File: \`?(kubevirt|libvirt|qemu)/" next-site/content/kubevirt/features/
```
Expected: 印出全部引用清單（windows-vm-features + topology-spread-constraints）。

- [ ] **Step 2: 逐一核對每個引用的程式碼片段是否仍在標示行附近**

對每個 `File: <repo>/<path>` + 其下 code block：在新版 submodule 開該檔，確認引用的程式碼片段仍存在；若頁面有寫明行號（如「(line N)」或片段內容），比對片段是否一致、行號是否需更新。
範例核對指令（逐檔調整）：
```bash
# 例：windows-vm-features 引用 libvirt/src/qemu/qemu_command.c 的某段
grep -n "<片段裡的關鍵 token>" libvirt/src/qemu/qemu_command.c
grep -n "<片段裡的關鍵 token>" qemu/target/i386/cpu.c
grep -n "<片段裡的關鍵 token>" qemu/hw/acpi/aml-build.c
```
Expected: 找到對應行；記錄新舊行號差異。

- [ ] **Step 3: 修正對不上的引用**

- 行號偏移：更新頁面中的行號 / 片段到新版對應內容。
- 邏輯已改寫：用新版 source 更新該段敘述與 code block（source 為準）。
- 邏輯已消失：於該頁標註「此段在 v9.1.0/v10.10.0/v1.5.0 已移除/重構」並調整敘述。
逐頁用 Edit 修正。

- [ ] **Step 4: validate（確保沒改壞 MDX）**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate
```
Expected: `VALIDATE_EXIT=0`、`All checks passed!`。

- [ ] **Step 5: Commit（若有修正）**

```bash
git add next-site/content/kubevirt/features/
git commit --no-gpg-sign -m "kubevirt 內容頁: re-verify source 行號對齊 re-pin 後版本（v1.5.0 / libvirt 10.10.0 / qemu 9.1.0）"
```
若 Step 2 核對後完全沒有需要改的，跳過 commit，並在執行回報中註明「既有頁行號 re-verify 後無需修正」。

---

## Task 7: 建立 vm-storage-perf project（projects.ts + 內容目錄骨架）

**Files:**
- Modify: `next-site/lib/projects.ts`
- Create: `next-site/content/vm-storage-perf/quiz.json`
- Create: `next-site/content/vm-storage-perf/features/`（目錄，由 Task 8 放檔）

- [ ] **Step 1: 在 PROJECTS 末尾（rook 後）新增 vm-storage-perf 條目**

在 `next-site/lib/projects.ts` 的 `PROJECTS` 物件，於 `'rook': { ... }` 條目之後、`}` 收尾前，新增：
```ts
  'vm-storage-perf': {
    id: 'vm-storage-perf',
    displayName: 'VM Disk IO 效能調教',
    shortName: 'VM IO',
    description: '跨 KubeVirt / libvirt / QEMU / Linux kernel / Ceph 五層，追 VM disk IO 全路徑與效能調教',
    githubUrl: '',
    submodulePath: '',
    color: 'cyan',
    accentClass: 'border-cyan-500 text-cyan-400',
    features: ['rbd-io-datapath'],
    featureGroups: [
      { label: 'IO 路徑', icon: '🔬', slugs: ['rbd-io-datapath'] },
    ],
    usecases: [],
    difficulty: '🔴 進階',
    difficultyColor: 'text-red-400 bg-red-400/10 border-red-400/30',
    problemStatement: 'KubeVirt VM 的 disk 在 Ceph RBD 上，一個 IO 從 guest 內到 OSD 要穿過 virtio、KVM、QEMU、host kernel krbd、libceph 五層。每一層都有可調參數會影響效能。這個分類從原始碼層拆完整 datapath，再逐步建立可調參數目錄與效能實驗計畫。',
    story: {
      protagonist: '🧑‍💻 平台 SRE 你自己',
      challenge: 'KubeVirt VM 跑在 Ceph RBD 上，benchmark 數字不如預期。但 IO 從 guest 到 OSD 經過太多層，不知道瓶頸在哪、也不知道該調哪個參數。決定先把整條 datapath 從原始碼拆透，再來做效能調教。',
      scenes: [
        { step: 1, icon: '🔬', actor: '你', action: '讀 rbd-io-datapath：一個 4K write 的九跳', detail: 'guest virtio-blk → vring/ioeventfd → KVM vmexit → QEMU block layer → host /dev/rbdX → krbd → libceph → TCP → OSD。每一跳對應一個資料結構與關鍵函式。' },
      ],
      outcome: '從此 VM disk IO 不是黑盒。看到延遲時知道該量哪一跳、調哪一層的參數。',
    },
    learningPaths: {
      beginner: [
        { slug: 'rbd-io-datapath', note: '先把一個 IO 從 VM 到 Ceph 的完整路徑走一遍' },
      ],
      intermediate: [
        { slug: 'rbd-io-datapath', note: '每一跳的資料結構與關鍵函式，建立後續調參的地圖' },
      ],
      advanced: [
        { slug: 'rbd-io-datapath', note: '邊界與除錯：延遲落在哪一跳怎麼判斷' },
      ],
    },
  },
```

- [ ] **Step 2: 建內容目錄與空 quiz.json**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
mkdir -p next-site/content/vm-storage-perf/features
echo '[]' > next-site/content/vm-storage-perf/quiz.json
```

- [ ] **Step 3: 確認 difficulty 型別合法**

`ProjectMeta.difficulty` 型別是 `'🟢 入門' | '🟡 中階' | '🔴 進階'`。確認上面用的是 `'🔴 進階'`（合法）。
Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
grep -n "difficulty:" next-site/lib/projects.ts | grep "vm-storage-perf" -A0 || grep -n "🔴 進階'" next-site/lib/projects.ts | tail -1
```
Expected: 看到 `difficulty: '🔴 進階'`。

- [ ] **Step 4: validate（此時 features 只宣告 rbd-io-datapath 但檔案還沒寫 → 預期 validate 會抓到缺 MDX）**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate; echo "VALIDATE_EXIT=$?"
```
Expected: **FAIL**，錯誤訊息指出 `vm-storage-perf` 的 `rbd-io-datapath` slug 找不到對應 MDX（validate.py 檢查 projects.ts slug 都要有 MDX 檔）。這是預期的——Task 8 補上 MDX 後就會過。

> 因此 Task 7 與 Task 8 合併成一個 commit（Step 5 不單獨 commit，留到 Task 8）。

- [ ] **Step 5:（不 commit，續 Task 8）**

不在此 commit，因為 validate 尚未綠。

---

## Task 8: 研究並撰寫 rbd-io-datapath.mdx

**Files:**
- Create: `next-site/content/vm-storage-perf/features/rbd-io-datapath.mdx`

> 這是核心研究頁。先研究（讀 source、建 evidence ledger），再寫。不平行——單一連貫敘事。
> 遵循 `source-first-topic-page` 與 `content-writing-guide`：scene → 圖 → explain-before-quote → source 錨點 → 邊界。每個 code block 前一句說明；用 ` ```File: repo/path ` 純 fence（**不**用 `<CodeAnchor>`，因為本 project `submodulePath` 為空，避免 code-extractor 解析空路徑）。

- [ ] **Step 1: 建 evidence ledger（研究，不寫檔）**

逐跳讀 source、記錄「claim / file / 行範圍 / 關鍵符號 / 如何證明」。最少涵蓋：
- guest virtio-blk submit：`linux/drivers/block/virtio_blk.c`（`virtio_queue_rq` / `virtblk_request`）
- vring：`linux/drivers/virtio/virtio_ring.c`（`virtqueue_add` / `vring_interrupt`）
- guest→host kick / ioeventfd：`linux/virt/kvm/eventfd.c`（ioeventfd）＋ QEMU `qemu/hw/virtio/virtio.c`（`virtio_queue_notify`）
- QEMU virtio-blk device：`qemu/hw/block/virtio-blk.c`（`virtio_blk_handle_request` / `virtio_blk_submit_multireq`）
- QEMU block layer：`qemu/block/block-backend.c`（`blk_aio_*`）
- host block device backend：QEMU 對 `/dev/rbdX` 的 aio（`qemu/block/file-posix.c`）
- krbd：`linux/drivers/block/rbd.c`（`rbd_queue_workfn` / `rbd_img_request`）
- libceph：`linux/net/ceph/osd_client.c`（`ceph_osdc_start_request`）＋ `net/ceph/messenger*.c`（TCP 上線）
- libvirt disk XML → QEMU blockdev：`libvirt/src/qemu/qemu_command.c`
- ceph-csi krbd map：`ceph-csi/internal/rbd/`（nodeserver / rbd attach）

用實際讀檔指令確認行號，例如：
```bash
cd /Users/ikaros/Documents/code/learning-k8s
grep -n "virtio_queue_rq\|virtblk_request" linux/drivers/block/virtio_blk.c | head
grep -n "rbd_queue_workfn\|rbd_img_request" linux/drivers/block/rbd.c | head
grep -n "ceph_osdc_start_request" linux/net/ceph/osd_client.c | head
grep -n "virtio_blk_handle_request" qemu/hw/block/virtio-blk.c | head
```
Expected: 每個關鍵符號都有命中行號，記進 ledger。**只有進 ledger 的符號才能寫進 MDX**（zero-fabrication）。

- [ ] **Step 2: 寫 rbd-io-datapath.mdx**

依下列結構撰寫（frontmatter 用 `layout: doc` + `title:` + `description:`，zh-TW 台灣用語，never-translate 清單保留英文）：
```
---
layout: doc
title: VM Disk IO — KubeVirt + Ceph RBD（krbd）一個 IO 從 guest 到 OSD 的完整路徑
description: <一句具體 zh-TW 摘要，含「krbd 主軸、九跳、五層、每跳 source 錨點」>
---

## 場景：guest 裡一個 4K write 到底經過幾層
## 全路徑一張圖（ASCII，標出五層九跳）
## ① guest 內：application → VFS → guest block layer → virtio-blk driver
## ② guest→host 邊界：vring → KVM ioeventfd → vmexit
## ③ virt-launcher：QEMU virtio-blk device → QEMU block layer
## ④ QEMU→host kernel：QEMU 對 /dev/rbdX 發 aio
## ⑤ host kernel：krbd（drivers/block/rbd.c）→ libceph（net/ceph）
## ⑥ 上線：TCP messenger → OSD →（接回既有 ceph 頁）
## 每一跳的「資料結構 + 關鍵函式」對照表
## librbd 路徑差異（一兩段標註，不另闢主線）
## 邊界與除錯：延遲落在哪一跳怎麼判斷
## 接下來 / 相關頁面
```
每個 code block 前一句說明；每段 source 用 `File: repo/path (line N)`；圖在 code 之前；`接下來` 段預告後續「可調參數目錄」「實驗計畫」兩頁並連回既有 ceph `rbd-and-csi` / `osd-and-bluestore`、kubevirt `virt-handler-and-launcher`。

- [ ] **Step 3: 大陸用語 + 裸 `<` 自檢**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
# 裸 < 數字（MDX/acorn 會當 JSX）—應為空或都在 code fence/backtick 內
grep -nE "[^\`| =/_-]<[0-9a-zA-Z]" next-site/content/vm-storage-perf/features/rbd-io-datapath.mdx | grep -vE "\`[^\`]*<" | head
```
Expected: 空（無裸 `<` 風險）。若有，改成 inline code（如 `` `< 0.4s` ``）。

- [ ] **Step 4: make validate**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate; echo "VALIDATE_EXIT=$?"
```
Expected: `VALIDATE_EXIT=0`、`All checks passed!`（projects.ts 的 slug 現在有對應 MDX，build 通過）。

- [ ] **Step 5: Commit（Task 7 + 8 一起）**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/lib/projects.ts next-site/content/vm-storage-perf/
git commit --no-gpg-sign -m "Add vm-storage-perf 分類 + rbd-io-datapath：KubeVirt+Ceph RBD(krbd) IO 全路徑"
```

---

## Task 9: 終驗 + push

**Files:** 無（驗證與推送）

- [ ] **Step 1: 全綠驗證**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate; echo "VALIDATE_EXIT=$?"
git status --short
```
Expected: `VALIDATE_EXIT=0`；working tree clean（或只剩預期未追蹤檔）。

- [ ] **Step 2: 確認 .gitmodules 五個變更都在**

Run:
```bash
cd /Users/ikaros/Documents/code/learning-k8s
grep -E "qemu|libvirt|kubevirt|linux|ceph-csi" .gitmodules | grep -E "branch|path"
git submodule status | grep -E "qemu|libvirt|kubevirt|linux|ceph-csi"
```
Expected：qemu=v9.1.0、libvirt=v10.10.0、kubevirt=v1.5.0、linux=applied/6.8.0-52.53_22.04.1、ceph-csi=v3.14.0。

- [ ] **Step 3: push**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push
```
Expected: push 成功到 `origin/vm-storage-perf-io-datapath`。

- [ ] **Step 4: 回報**

列出：變更路徑、五個 submodule 版本 re-pin 結果、Task 6 re-verify 修正清單（或「無需修正」）、`make validate` 結果、刻意省略的 source gap。

---

## Self-Review（plan 對 spec 覆蓋檢查）

- 版本表（QEMU 9.1.0 / libvirt 10.10.0 / kubevirt v1.5.0 / kernel applied/6.8.0-52.53_22.04.1 / ceph-csi v3.14.0）→ Task 1-5 各一。✓
- re-pin 副作用 re-verify → Task 6。✓
- datapath 頁（krbd 主軸、結構、source 錨點、librbd 標差異）→ Task 8。✓
- 新分類 projects.ts + 內容目錄（id/displayName/cyan/features/featureGroups）→ Task 7。✓
- `submodulePath: ''` 風險 → 已查證 learning-plan 同樣空字串且 build 正常；datapath 頁用純 fence 不觸發 code-extractor，無需 fallback hack。Task 8 Step 2 明訂不用 `<CodeAnchor>`。✓
- 平行 subagent → Task 1-5 的下載可平行，git 寫入序列化（plan 步驟即主線序列）。✓
- make validate exit 0 → Task 6/8/9 各有 gate。✓
- 明確不做（參數目錄頁、實驗計畫頁、librbd 完整拆、benchmark）→ 未排入 Task。✓

Placeholder scan：無 TBD/TODO；每個 code 步驟有實際內容。Type 一致性：`difficulty: '🔴 進階'` 合法、`submodulePath`/`githubUrl` 空字串與 learning-plan 一致、欄位齊全比照其他 project。
