# VM Disk IO 效能調教 — 參數目錄頁 + 實驗計畫頁（Design Spec）

> Status: approved (brainstorming 階段確認)
> Date: 2026-06-02
> Scope: 在既有 `vm-storage-perf` 分類下新增兩頁——可調參數目錄、效能實驗計畫。接續 `rbd-io-datapath` 頁（已 merge 進 master）。
> 前置依賴：submodules 已對齊 KubeVirt v1.5.0（kubevirt v1.5.0 / libvirt v10.10.0 / qemu v9.1.0 / linux 6.8.0-52 / ceph-csi v3.14.0 / ceph v19.2.3），datapath 頁的 ①–⑤ 五層結構已存在。

## 目標

`rbd-io-datapath` 頁把「一個 IO 從 VM 到 Ceph 的完整路徑」拆透了。這兩頁建立在它上面，回答接下來兩個問題：

1. **這條路徑上每一層有哪些參數可以調？調了影響多大、優先調哪個？**（參數目錄）
2. **怎麼系統化地驗證這些調整？**（實驗計畫，從 impact 最高的 5–10 個參數開始）

兩頁都掛在既有 `vm-storage-perf` project 下，新增一個 featureGroup「效能調教」。

## 頁面整合（projects.ts）

修改 `next-site/lib/projects.ts` 的 `vm-storage-perf` 條目：

- `features`: `['rbd-io-datapath']` → `['rbd-io-datapath', 'rbd-io-tuning-catalog', 'rbd-io-experiment-plan']`
- `featureGroups`: 在既有 `{ label: 'IO 路徑', icon: '🔬', slugs: ['rbd-io-datapath'] }` 後新增：
  ```ts
  { label: '效能調教', icon: '🎛️', slugs: ['rbd-io-tuning-catalog', 'rbd-io-experiment-plan'] },
  ```
- `learningPaths`: intermediate / advanced 各加一筆指向新頁（catalog → experiment-plan 的閱讀順序）。

新增檔案：
- `next-site/content/vm-storage-perf/features/rbd-io-tuning-catalog.mdx`
- `next-site/content/vm-storage-perf/features/rbd-io-experiment-plan.mdx`

## 頁 A：rbd-io-tuning-catalog（參數目錄）

**組織方式：按 datapath 五層分組**，沿用 datapath 頁的 ①–⑤ 跳結構，讀者看完 datapath 能直接接上。

**每個參數固定格式：**
```
### <參數名>（第 X 跳）
- **在哪設**：KubeVirt VMI spec / libvirt domain XML / QEMU -blockdev / krbd map option / ceph.conf / sysfs …
- **作用機制**：改變 datapath 哪一跳的什麼行為（連回 datapath 頁該節 `./rbd-io-datapath#...` 或敘述對應跳）
- **impact**：🔴 高 / 🟡 中 / 🟢 低或情境性 —— 一句機制理由
- **來源**：`File: repo/path` 或官方文件 URL；查不到明確來源就寫「依環境實測，無固定來源」
- **風險 / 前提**：correctness 代價、版本前提、與其他參數的交互
```

**每層涵蓋「實務上調得動的都列」（每層 5–10 個，實作時逐一驗 source 存在後才寫）：**

| 層 | 預計涵蓋的旋鈕（source 已初步偵察確認存在於 v1.5.0） |
|---|---|
| **① KubeVirt VMI** | `disk.cache`（none/writethrough，schema.go:645-648）、`disk.io`（native/threads，schema.go:649+）、`ioThreadsPolicy`（shared/auto/supplementalPool，schema.go:30-35,206）+ `dedicatedIOThread`（schema.go:644）、virtio `blockSize`、`disk.bus=virtio`、`disk` discard（converter.go:196 `discard=unmap`）、hugepages（schema.go:387,411）、multi-queue（converter.go:74 `multiQueueMaxQueues=256`, :205-206） |
| **② libvirt / QEMU** | `-blockdev` aio mode（native / io_uring / threads；converter.go:445-467 自動 io=native when cache=none；file-posix.c raw_co_prw 的 io_uring/laio 分支）、`cache.direct`（O_DIRECT）、`driver.queues`（virtio multi-queue，qemu_command.c）、iothread 綁定 |
| **③ guest virtio** | guest 端 block IO scheduler（none / mq-deadline，`/sys/block/vdX/queue/scheduler`）、`nr_requests`、`rq_affinity`、virtio-blk queue depth（virtio_blk.c / virtio_ring.c 的 vring 大小） |
| **④ host krbd** | `rbd map` options（krbd device-type options，rbd_attach.go appendKRbdDeviceTypeAndOptions）：`alloc_size`、`read_from_replica`、`crush_location`、`queue_depth`；host sysfs `/sys/block/rbdX/queue/*`（nr_requests, scheduler, read_ahead_kb） |
| **⑤ Ceph / RBD** | RBD image features（`object-size` / striping `--stripe-unit` `--stripe-count`、`exclusive-lock`）、`osd_op_num_threads_per_shard` / `osd_op_num_shards`（OSD 端）、client 端調整。**librbd-only 旋鈕（如 `rbd_cache`、`rbd_readahead_*`）明確標「krbd 路徑不走，屬 librbd」**，避免誤導（延續 datapath 頁 krbd 主軸）。 |

**頁尾總表**：把所有參數按 impact（🔴→🟡→🟢）排一次，欄位 = 參數 | 層 | 在哪設 | impact 一句話 | 風險。這張表同時是頁 B「選哪 5–10 個」的依據。

## 頁 B：rbd-io-experiment-plan（實驗計畫）

從頁 A 總表取 **impact 最高的 5–10 個參數**。**深度隨 impact 遞減**（漸進，不是二分）：impact 越高寫越詳細，Top 5 寫完整協定。

**預定的高 impact 參數順序（機制推論，最終以頁 A 總表為準）：**
1. **cache mode**（① `cache: none` vs writethrough）— `none` 走 O_DIRECT 繞過整層 host page cache copy。最高、最易驗。
2. **IOThreads**（① `ioThreadsPolicy` + `dedicatedIOThread`）— 把 virtio-blk 處理移出 QEMU main event loop，解單執行緒序列化。
3. **virtio multi-queue**（① `driver.queues`）— 多 vCPU 平行提交，解單一 virtqueue 序列化。
4. **aio mode**（② native / io_uring / threads）— 改變 QEMU 對 /dev/rbdX 的提交模型。
5. **RBD object-size / striping**（⑤）— 改變一個 IO 切成幾個 object op、跨幾顆 OSD 平行。
6.–10.（其餘 host krbd queue_depth、guest scheduler、read_from_replica、nr_requests…）— 精簡度隨 impact 遞減。

**頁面結構：**
```
## 場景：拿到 datapath + 參數目錄後，怎麼系統化驗證
## 實驗方法論（受控變因：一次只動一個參數；先 baseline 再單調）
## 共用 baseline（抽一份，不重複）
   - VMI YAML（baseline disk 設定）
   - fio job 設定（randread / randwrite / seq × iodepth × bs 的矩陣）
   - 要收的 metric（IOPS / lat p50,p99 / QEMU thread CPU / host iostat /dev/rbdX）
   - 怎麼確認參數生效（virsh dumpxml / qemu cmdline / rbd showmapped 對照）
## 實驗 1：cache mode（完整協定）
   - 假設（機制預期，標明「推論非實測」）
   - VMI YAML diff
   - fio 跑法
   - 收集 metric
   - 生效驗證
## 實驗 2：IOThreads（完整協定）
## 實驗 3：multi-queue（完整協定）
## 實驗 4：aio mode（完整協定）
## 實驗 5：RBD object-size / striping（完整協定）
## 實驗 6–N：（精簡協定，隨 impact 遞減：假設 + 改哪個旋鈕 + 量哪個 metric + 生效驗證一行）
## 結果記錄模板（表格，留空給使用者填實測）
## 邊界：什麼情況這些參數無感 / 反效果
```

**驗證等級（依 CLAUDE.md）**：這些指令需要真實 Proxmox + 3-node k8s + ceph，無法在本機 kind/minikube 跑。所以：
- 參數的存在與語意 → 以原始碼（pinned submodule）+ 官方文件交叉驗證。
- fio / virsh / rbd 指令 → 屬通用工具用法，可寫具體指令，但標「在你環境跑後對照」，不假裝實測過、不給捏造的 benchmark 數字。
- 涉及破壞性操作（改 RBD image features、重啟 VM）→ 附前提與回退。

## 內容規範（兩頁共通）

- zh-TW 台灣用語；never-translate 清單保留英文。
- impact 等級與任何數字一律標來源；機制推論與實測值明確區分（推論寫「機制上預期」，不寫死數字）。
- 不 import MDX 元件；`<Callout>` 可直接用（全域註冊）。
- 不用 `<CodeAnchor>`（本 project submodulePath 為空）；用純 ` ```File: repo/path ` fence。
- 不用 Mermaid；要圖用 ASCII。
- MDX 陷阱：prose 裡裸 `<` + 字母/數字會壞 build，比較式寫成 inline code（如 `` `< 0.4s` ``）。
- 每個 code block 前一句說明（explain-before-quote）。
- zero-fabrication：不存在的參數 / 函式不得寫入；source 與外部文件衝突時 source 為準。

## 驗證與完成準則

- 頁 A 每個參數的存在與語意都有 source 或官方文件依據；impact 理由是機制推論。
- 頁 B 的 5–10 個參數來自頁 A 總表；協定深度隨 impact 遞減；指令標驗證等級。
- 新 slug `rbd-io-tuning-catalog`、`rbd-io-experiment-plan` 經 `projects.ts` 解析正常。
- `make validate` exit 0（含 Next.js build）。
- 完成回報：變更路徑、validate 結果、每層涵蓋的參數數、刻意省略或標「依環境實測」的項目。

## 明確不做（YAGNI）

- 不跑真實 benchmark、不給實測數字（環境不在本機）。
- 不拆 librbd 路徑的完整調教（krbd 主軸；librbd-only 參數只標註不展開）。
- 不涵蓋網路層調教（MTU / jumbo frame / TCP）——那是另一個主題，本批聚焦 block IO datapath。
- 不改既有 datapath 頁（只連回，不重寫）。
