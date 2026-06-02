# VM Disk IO 效能調教 — 參數目錄頁 + 實驗計畫頁 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在既有 `vm-storage-perf` 分類下新增兩頁——按 datapath 五層分組的可調參數目錄，與從 impact 最高 5–10 個參數出發的效能實驗計畫。

**Architecture:** 兩頁都是 source-first MDX，建立在已 merge 的 `rbd-io-datapath` 頁之上（沿用 ①–⑤ 五層結構）。先研究（讀 pinned submodule + 官方文件、建 evidence ledger），再寫。impact 一律機制推論 + 標來源，不給捏造 benchmark。先做頁 A（參數目錄，產出 impact 總表），頁 B（實驗計畫）的參數選擇與順序以頁 A 總表為準。

**Tech Stack:** Next.js 14 App Router（static export）、MDX（next-mdx-remote）、Python validate.py、Bash。pinned submodules：kubevirt v1.5.0 / libvirt v10.10.0 / qemu v9.1.0 / linux 6.8.0-52 / ceph-csi v3.14.0 / ceph v19.2.3。

> 非 code-TDD；「測試」是 `make validate`（含 Next.js build）exit 0 + source-existence 核對。
> Commit `git commit --no-gpg-sign`；push `GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push`。
> 分支：`vm-storage-perf-tuning`（已存在、spec 已 commit 於此）。

---

## File Structure

- `next-site/lib/projects.ts`（修改）— `vm-storage-perf` 條目加 2 個 slug + 新 featureGroup「效能調教」+ learningPaths。
- `next-site/content/vm-storage-perf/features/rbd-io-tuning-catalog.mdx`（新增）— 參數目錄，五層分組 + impact 總表。
- `next-site/content/vm-storage-perf/features/rbd-io-experiment-plan.mdx`（新增）— 實驗計畫，5–10 個高 impact 參數協定。

實作順序：Task 1（projects.ts 接線，但 validate 會因缺 MDX 紅，故與 Task 2 合併 commit）→ Task 2（頁 A）→ Task 3（頁 B）→ Task 4（終驗 + push）。

---

## 已驗證的 source 錨點（給實作者的起手地圖，行號可能 ±幾行，引用前再確認）

**① KubeVirt VMI（`kubevirt/staging/src/kubevirt.io/api/core/v1/schema.go`）：**
- `Cache DriverCache`（line 648；註解 "CacheNone, CacheWriteThrough" :646）
- `IO DriverIO`（line 652；註解 "native, default, threads" :650）
- `DedicatedIOThread *bool`（line 644；"implies useIOThreads = true"）
- `IOThreadsPolicy`（:30-35 shared/auto/supplementalPool；欄位 :206）、`IOThreads *DiskIOThreads`（:209；type 定義 :1599）
- `BlockSize`（:658；`CustomBlockSize{Logical,Physical}` :668；`MatchVolume` :677）
- `Shareable`（:660）、`ErrorPolicy`（:664）、Hugepages（:387,411）

**② libvirt/QEMU converter（`kubevirt/pkg/virt-launcher/virtwrap/converter/converter.go`）：**
- `SetOptimalIOMode`（:440-467）：cache=none + block device → io=native（O_DIRECT）
- `disk.Driver.Queues = numQueues`（:205-206，僅 virtio bus）；`multiQueueMaxQueues=256`（:74）
- `discard=unmap`（:196）

**② QEMU aio（`qemu/block/file-posix.c`）：**
- aio option "threads, native, io_uring"（:555-557）；`BDRV_O_NATIVE_AIO`（:619）；`use_linux_io_uring`（:640）；aio=native 需 O_DIRECT（:717 報錯）
- virtio-blk `num_queues`（`qemu/hw/block/virtio-blk.c` :1061,1260 multi-queue 分支）

**④ host krbd（`ceph-csi/internal/rbd/rbd_attach.go`）：**
- `appendKRbdDeviceTypeAndOptions`（function；`--device-type krbd --options noudev`，userOptions 可覆蓋）
- krbd 真正的 map options（`alloc_size` / `read_from_replica` / `crush_location` / `queue_depth`）由 kernel `drivers/block/rbd.c` 的 `rbd_parse_param` 解析 + 官方 rbd man page；引用 `linux/drivers/block/rbd.c` 對應 token + 官方文件。

**③ guest virtio / ⑤ Ceph：** 多為 sysfs / CLI / ceph.conf 旋鈕，無單一 code 行可引。規則：能在 `linux/` 或 `ceph/` source 找到對應機制就引（如 virtio_ring vring size、rbd.c queue_depth），純維運旋鈕（`/sys/block/*/queue/scheduler`、`rbd image-meta`、`osd_op_num_shards`）引官方文件 URL，查不到固定來源就明確寫「依環境實測，無固定 source」。**禁止捏造行號或參數名**。

---

## Task 1+2: 建頁 A（rbd-io-tuning-catalog）+ projects.ts 接線

**Files:**
- Modify: `next-site/lib/projects.ts`
- Create: `next-site/content/vm-storage-perf/features/rbd-io-tuning-catalog.mdx`

- [ ] **Step 1: projects.ts 加 slug + featureGroup + learningPaths**

在 `next-site/lib/projects.ts` 的 `'vm-storage-perf'` 條目：

(a) `features` 陣列改成：
```ts
    features: ['rbd-io-datapath', 'rbd-io-tuning-catalog', 'rbd-io-experiment-plan'],
```

(b) `featureGroups` 改成（在既有 IO 路徑後加一組）：
```ts
    featureGroups: [
      { label: 'IO 路徑', icon: '🔬', slugs: ['rbd-io-datapath'] },
      { label: '效能調教', icon: '🎛️', slugs: ['rbd-io-tuning-catalog', 'rbd-io-experiment-plan'] },
    ],
```

(c) `learningPaths` 的 `intermediate` 與 `advanced` 各加一筆（接在既有那筆後）：
```ts
      intermediate: [
        { slug: 'rbd-io-datapath', note: '每一跳的資料結構與關鍵函式，建立後續調參的地圖' },
        { slug: 'rbd-io-tuning-catalog', note: '每一層有哪些參數可調、impact 多大、優先調哪個' },
      ],
      advanced: [
        { slug: 'rbd-io-datapath', note: '邊界與除錯：延遲落在哪一跳怎麼判斷' },
        { slug: 'rbd-io-experiment-plan', note: '從 impact 最高的幾個參數開始系統化驗證' },
      ],
```

- [ ] **Step 2: 研究——逐層驗證每個旋鈕存在（建 evidence ledger，不寫檔）**

對每個要寫進頁 A 的參數，確認 source 或官方文件依據。用實際指令核對（範例，逐一做）：
```bash
cd /Users/ikaros/Documents/code/learning-k8s
# ① KubeVirt
grep -n "Cache DriverCache\|IO DriverIO\|DedicatedIOThread\|BlockSize \|IOThreadsPolicy" kubevirt/staging/src/kubevirt.io/api/core/v1/schema.go
# ② converter io-mode / queues
grep -n "SetOptimalIOMode\|Driver.Queues\|multiQueueMaxQueues\|Discard = \"unmap\"" kubevirt/pkg/virt-launcher/virtwrap/converter/converter.go
# ② QEMU aio
grep -n "threads, native, io_uring\|BDRV_O_NATIVE_AIO\|use_linux_io_uring" qemu/block/file-posix.c
grep -n "num_queues" qemu/hw/block/virtio-blk.c | head
# ④ krbd
grep -n "appendKRbdDeviceTypeAndOptions\|--options" ceph-csi/internal/rbd/rbd_attach.go
grep -n "queue_depth\|alloc_size\|read_from_replica\|crush_location" linux/drivers/block/rbd.c | head
```
規則：**只有確認存在的參數才寫進 MDX**。純維運旋鈕（sysfs / ceph.conf）引官方文件 URL；查不到固定 source 就在該參數的「來源」欄寫「依環境實測，無固定 source」。

- [ ] **Step 3: 寫 rbd-io-tuning-catalog.mdx**

frontmatter `layout: doc` + `title:` + `description:`（zh-TW 一句摘要）。結構：
```
## 場景：datapath 拆完了，現在每一層能調什麼
## 怎麼用這頁（每參數格式說明 + impact 圖例 🔴🟡🟢）
## ① KubeVirt VMI 層
   ### cache（第 ④ 跳：QEMU→host）
   ### io（aio mode 入口）
   ### ioThreadsPolicy + dedicatedIOThread
   ### multi-queue (driver.queues)
   ### blockSize / discard / hugepages …
## ② libvirt / QEMU 層
   ### aio mode (threads / native / io_uring)
   ### cache.direct (O_DIRECT) …
## ③ guest virtio 層
   ### guest IO scheduler / nr_requests / rq_affinity …
## ④ host krbd 層
   ### rbd map --options (queue_depth / alloc_size / read_from_replica / crush_location)
   ### host sysfs /sys/block/rbdX/queue/* …
## ⑤ Ceph / RBD 層
   ### RBD object-size / striping
   ### OSD 端 (osd_op_num_shards …)
   ### librbd-only 旋鈕（rbd_cache 等）——明確標「krbd 路徑不走」
## 全參數 impact 總表（按 🔴→🟡→🟢 排序，這張表是實驗計畫頁的依據）
## 接下來 / 相關頁面
```
每個參數用 spec 定義的固定 5 欄格式（在哪設 / 作用機制 / impact / 來源 / 風險前提）。每層開頭一句接回 datapath 頁對應跳。每個 code/設定範例前一句說明（explain-before-quote）。impact 理由一律機制推論，不寫死 benchmark 數字。

- [ ] **Step 4: 裸 `<` 自檢 + validate**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
grep -nE "[^\`| =/_(-]<[0-9a-zA-Z]" next-site/content/vm-storage-perf/features/rbd-io-tuning-catalog.mdx | grep -vE "\`[^\`]*<"
make validate; echo "VALIDATE_EXIT=$?"
```
Expected：裸 `<` 掃描為空；`VALIDATE_EXIT=0`、`All checks passed!`（projects.ts 宣告了 3 個 slug，rbd-io-experiment-plan 還沒建 → 預期 validate 會抓缺 MDX 而 **FAIL**）。

> 因此 Task 2 暫不獨立通過 validate；Step 5 commit 仍要做（頁 A + projects.ts 是完整一塊），完整綠留到 Task 3 補上頁 B。為避免 commit 一個 validate 紅的狀態，**改為：Task 2 不 commit，直接續 Task 3，兩頁一起 commit**。

- [ ] **Step 5:（不 commit，續 Task 3）**

頁 A 寫完、裸 `<` 掃描乾淨即可。先不 commit（避免留下 validate 紅的 commit）。

---

## Task 3: 建頁 B（rbd-io-experiment-plan）

**Files:**
- Create: `next-site/content/vm-storage-perf/features/rbd-io-experiment-plan.mdx`

- [ ] **Step 1: 從頁 A 總表選 impact 最高 5–10 個**

以頁 A 的 impact 總表為準（不是另起爐灶）。預定 Top 5（完整協定）：
1. cache mode（① cache: none vs writethrough）
2. IOThreads（① ioThreadsPolicy + dedicatedIOThread）
3. virtio multi-queue（① driver.queues）
4. aio mode（② threads / native / io_uring）
5. RBD object-size / striping（⑤）
第 6–N（精簡協定，隨 impact 遞減）：host krbd queue_depth、guest scheduler、read_from_replica、nr_requests 等，數量取到 5–10 之間視頁 A 總表而定。

- [ ] **Step 2: 寫 rbd-io-experiment-plan.mdx**

frontmatter 同規範。結構：
```
## 場景：拿到 datapath + 參數目錄後，怎麼系統化驗證
## 實驗方法論（受控變因：先 baseline，一次只動一個參數，量同一組 metric）
## 共用 baseline（抽一份，不重複）
   - VMI YAML（baseline disk：cache 預設、單 queue、無 dedicated iothread）
   - fio job 設定（randread / randwrite / seqwrite 矩陣 × iodepth × bs；附完整 fio 指令）
   - 要收的 metric（IOPS / lat p50,p99 / QEMU thread CPU / host iostat -x /dev/rbdX）
   - 怎麼確認參數生效（virsh dumpxml 對照、qemu cmdline、rbd showmapped）
## 實驗 1：cache mode（完整協定：假設→YAML diff→fio→metric→生效驗證）
## 實驗 2：IOThreads（完整協定）
## 實驗 3：multi-queue（完整協定）
## 實驗 4：aio mode（完整協定）
## 實驗 5：RBD object-size / striping（完整協定）
## 實驗 6–N：精簡協定（假設 + 改哪個旋鈕 + 量哪個 metric + 生效驗證一行）
## 結果記錄模板（表格，留空給使用者填實測）
## 邊界：什麼情況這些參數無感 / 反效果
## 接下來 / 相關頁面
```
每個實驗的「假設」段明確標「機制上預期 X（推論，非實測）」。fio / virsh / rbd 指令屬通用工具用法可寫具體，但在需要真實 Proxmox+ceph 的地方標「在你環境跑後對照」。不寫死任何 benchmark 數字。破壞性操作（改 RBD image features 需重建/重 map、改 cache 需重啟 VM）附前提與回退。

- [ ] **Step 3: 裸 `<` 自檢 + validate（此時應全綠）**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
grep -nE "[^\`| =/_(-]<[0-9a-zA-Z]" next-site/content/vm-storage-perf/features/rbd-io-experiment-plan.mdx | grep -vE "\`[^\`]*<"
make validate; echo "VALIDATE_EXIT=$?"
```
Expected：裸 `<` 為空；`VALIDATE_EXIT=0`、`All checks passed!`（兩個新 slug 都有 MDX，build 通過）。

- [ ] **Step 4: Commit（頁 A + 頁 B + projects.ts 一起）**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
git add next-site/lib/projects.ts next-site/content/vm-storage-perf/features/rbd-io-tuning-catalog.mdx next-site/content/vm-storage-perf/features/rbd-io-experiment-plan.mdx
git commit --no-gpg-sign -m "Add vm-storage-perf 效能調教：參數目錄 + 實驗計畫兩頁"
```

---

## Task 4: 終驗 + push

**Files:** 無

- [ ] **Step 1: 全綠驗證 + slug 解析**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
make validate; echo "VALIDATE_EXIT=$?"
grep -n "rbd-io-tuning-catalog\|rbd-io-experiment-plan" next-site/lib/projects.ts
ls next-site/content/vm-storage-perf/features/
```
Expected：`VALIDATE_EXIT=0`；兩 slug 在 projects.ts 的 features + featureGroups；features/ 下有三個 mdx。

- [ ] **Step 2: push**

```bash
cd /Users/ikaros/Documents/code/learning-k8s
GIT_SSH_COMMAND='ssh -i .ssh/id_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none' git push
```
Expected：push 成功到 `origin/vm-storage-perf-tuning`。

- [ ] **Step 3: 回報**

列出：變更路徑、頁 A 每層涵蓋的參數數、頁 B 選了哪幾個參數（及為何）、標「依環境實測 / 無固定 source」的項目、`make validate` 結果。

---

## Self-Review（plan 對 spec 覆蓋檢查）

- projects.ts 加 2 slug + 新 featureGroup「效能調教」+ learningPaths → Task 1。✓
- 頁 A 按 datapath 五層分組、每參數固定 5 欄格式、每層 5–10 旋鈕、librbd-only 標註、impact 總表 → Task 2。✓
- 頁 B 從總表取 5–10、深度隨 impact 遞減（Top 5 完整）、共用 baseline、假設標推論、驗證等級標註、結果模板 → Task 3。✓
- impact 機制推論 + 標來源、zero-fabrication、無捏造 benchmark → Task 2/3 各步驟明訂。✓
- 不用 `<CodeAnchor>`（submodulePath 空）、裸 `<` 自檢、Callout 免 import → 步驟明訂。✓
- make validate exit 0 → Task 3/4 gate。✓
- 明確不做（真實 benchmark、librbd 完整拆、網路層、改 datapath 頁）→ 未排入 Task。✓

Placeholder scan：無 TBD/TODO；研究步驟給了實際核對指令；MDX 結構給了完整 section 樹。Type 一致性：slug 名（rbd-io-tuning-catalog / rbd-io-experiment-plan）、featureGroup label（效能調教）、icon（🎛️）在 Task 1/3/4 一致。

> 註：頁 A 與頁 B 是同一分支上的連續創作，且頁 B 依賴頁 A 的 impact 總表，故合併成一個 commit（Task 3 Step 4），避免中間留下 validate 紅的狀態。這偏離「每 task 一 commit」是刻意的，因為兩頁是一個不可分的內容單元。
