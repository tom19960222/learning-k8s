# VM Disk IO 效能調教 — 新分類 + RBD IO datapath 首頁（Design Spec）

> Status: approved (brainstorming 階段確認)
> Date: 2026-06-02
> Scope: 建立新跨層分類 `vm-storage-perf`，重新對齊 KubeVirt v1.5.0 的相關 repo 版本，產出第一頁「RBD IO datapath」。參數目錄與實驗計畫頁為後續 round，不在本 spec。

## 目標

回答一個問題：**一台 KubeVirt VM、disk 在 Ceph RBD 上（krbd 路徑），guest 裡一個 IO 操作怎麼一路到 Ceph OSD**——經過哪些 library、哪些 kernel 機制、哪些 Ceph 機制。產出一頁 source-first 的 datapath 文章，並建立一個未來可持續長大的跨層分類，後續再掛「可調參數目錄」與「效能實驗計畫」兩頁。

## 版本基準（嚴格對齊 KubeVirt v1.5.0 + host kernel）

以 KubeVirt **v1.5.0**（commit `522b44c0ce`）的 virt-launcher image 實際 ship 版本為準：

| 元件 | 版本 / tag | 依據（single source of truth） | 動作 |
|---|---|---|---|
| kubevirt | `v1.5.0` (`522b44c0ce`) | 使用者指定 | submodule v1.8.2 → **v1.5.0** re-pin |
| QEMU | `v9.1.0` | v1.5.0 `rpm/BUILD.bazel`：`qemu-kvm-core-9.1.0-12.el9` | submodule v11.0.0 → **v9.1.0** re-pin |
| libvirt | `v10.10.0` | v1.5.0 `rpm/BUILD.bazel`：`libvirt-*-10.10.0-4.el9` | submodule v12.3.0 → **v10.10.0** re-pin |
| Linux kernel | `applied/6.8.0-52.53_22.04.1` | 使用者 host：`6.8.0-52-generic #53~22.04.1-Ubuntu` | **新增** submodule，from `https://git.launchpad.net/ubuntu/+source/linux-hwe-6.8`（`applied/...` tag = Ubuntu patch 已套用，貼合 running kernel）|
| ceph-csi | `v3.12.x`（clone 時確認該系列最新 patch tag） | krbd mounter 路徑 | **新增** submodule |
| ceph | `v19.2.3` | 既有 submodule | 不動 |

備註：
- **KVM 沒有獨立 repo**——它是 kernel 樹內的 `virt/kvm/` + `arch/x86/kvm/`。「研究 KVM」= 讀 Linux kernel。
- Launchpad 的 `ubuntu/+source/linux-hwe-6.8` 為**匿名可 clone**（已驗證 `git ls-remote` exit 0、186 refs，目標 tag `applied/6.8.0-52.53_22.04.1` 與 `import/6.8.0-52.53_22.04.1` 皆存在）。團隊路徑 `~ubuntu-kernel/...` 需認證、不可用。
- 全部以 `git submodule add` + shallow（依專案慣例 `project_clone_with_submodule`）加到 repo root。

### Re-pin 副作用（必須處理）

重新 pin libvirt/qemu/kubevirt 會讓既有頁面的 source 行號可能對不上：
- `next-site/content/kubevirt/features/windows-vm-features.mdx`：引用 libvirt/qemu 共 **5 處** `File:` 行號。
- 其餘 kubevirt 內容頁：對 v1.8.2 撰寫，行號可能偏移。

**動作**：re-pin 後逐一 re-verify 受影響行號，對不上就修正到新版本對應行。此工作算進本次範圍。若某段邏輯在新版本已不存在/大改，於該頁標註並調整敘述（source 為準）。

## IO datapath 頁面（唯一首批產出）

- 路徑：`next-site/content/vm-storage-perf/features/rbd-io-datapath.mdx`
- 主軸：**krbd**（ceph-csi 預設 mounter；PVC `volumeMode: Block`，host 把 RBD map 成 `/dev/rbdX`，QEMU 以 host block device 為 backend）。librbd 路徑只在關鍵點用一兩句標差異，不另闢主線。
- 結構（遵循 `source-first-topic-page`：scene → mechanism → source → 邊界）：

```
## 場景：guest 裡一個 4K write 到底經過幾層
## 全路徑一張圖（ASCII）
## ① guest 內：application → VFS → guest block layer → virtio-blk driver
## ② guest→host 邊界：virtio ring (vring) → KVM ioeventfd → vmexit
## ③ virt-launcher：QEMU virtio-blk device → QEMU block layer
## ④ QEMU→host kernel：QEMU 對 /dev/rbdX 發 IO（aio 模式）
## ⑤ host kernel：krbd (drivers/block/rbd.c) → libceph (net/ceph)
## ⑥ 上線：TCP → OSD → BlueStore（接回既有 ceph 頁）
## 每一跳的「資料結構 + 關鍵函式」對照表
## 邊界與除錯（每層怎麼驗證、延遲落在哪一跳怎麼判斷）
## 接下來（指向後續：參數目錄頁、實驗計畫頁）
```

- 每一跳都要有 source 錨點（每個引用 `File: repo/path (line N)`，以本地 pinned submodule 為準，不用 GitHub blob URL）。預期錨點區（實際行號於研究時驗證）：
  - virtio-blk guest 端：`linux/drivers/block/virtio_blk.c`
  - vring / ioeventfd：`linux/virt/kvm/eventfd.c` + `qemu/hw/virtio/virtio.c`
  - QEMU block：`qemu/block/block-backend.c`、virtio-blk device：`qemu/hw/block/virtio-blk.c`
  - krbd：`linux/drivers/block/rbd.c`、libceph：`linux/net/ceph/osd_client.c`
  - libvirt disk XML → QEMU `-blockdev`：`libvirt/src/qemu/qemu_command.c`
- 這頁**只描述路徑、不調參數**。它是後續「參數目錄 / 優先序 / impact」與「實驗計畫」兩頁的地基：每個可調參數都會掛在這頁的某一跳上。
- zero-fabrication：不存在的函式/型別不得寫入；source 與外部文件衝突時 source 為準；不確定就標註或省略。

## 新分類落地（projects.ts + 內容目錄）

在 `next-site/lib/projects.ts` 的 `PROJECTS` 新增跨層 project：

| 欄位 | 值 |
|---|---|
| `id` | `vm-storage-perf` |
| `displayName` | `VM Disk IO 效能調教` |
| `shortName` | `VM IO` |
| `description` | 跨 KubeVirt / libvirt / QEMU / Linux kernel / Ceph 五層，追 VM disk IO 全路徑與效能調教 |
| `githubUrl` | `''`（跨 repo，無單一上游）|
| `submodulePath` | 空字串（跨 repo，不綁單一 submodule）|
| `color` | `cyan`（未使用色；現用 amber/blue/purple/teal/green/rose）|
| `accentClass` | `border-cyan-500 text-cyan-400` |
| `features` | `['rbd-io-datapath']` |
| `featureGroups` | `[{ label: 'IO 路徑', icon: '🔬', slugs: ['rbd-io-datapath'] }]` |
| `difficulty` | `🔴 進階` |
| `usecases` | `[]` |
| `story` / `learningPaths` / `problemStatement` | 比照其他 project 填最小可用內容 |

- 內容目錄：`next-site/content/vm-storage-perf/features/`，並 `echo '[]' > next-site/content/vm-storage-perf/quiz.json`。
- 跨層 project 的 source 引用會橫跨 5 個 repo 路徑——`File: repo/path (line N)` 格式本就支援，但這是本站第一個非單一 submodule 的 project。
- **風險點**：`submodulePath` 留空可能影響 source viewer（`app/[project]/source/[...filepath]`）或 sidebar/header 的 GitHub 連結。實作時驗證留空是否報錯；若報錯，給安全 fallback（例如該 project 不顯示 source 連結，或 `submodulePath` 指 repo root）。`make validate` 必須 exit 0。

## 平行 subagent 計畫（clone 階段）

clone 彼此獨立，開 4 個平行 background subagent，各負責一個 repo 的網路抓取：

| subagent | 工作 |
|---|---|
| A | qemu re-pin v11.0.0 → v9.1.0 |
| B | libvirt re-pin v12.3.0 → v10.10.0 |
| C | 新增 linux-hwe-6.8 submodule @ `applied/6.8.0-52.53_22.04.1`（最大、最慢）|
| D | 新增 ceph-csi submodule + kubevirt re-pin v1.8.2 → v1.5.0 |

**並行的是「下載」，不是「git 寫入」**：`.gitmodules` 與 git index 的寫入由主線序列化完成（subagent 回報後逐一處理），避免 index/`.gitmodules` 競寫衝突。

研究與寫頁本身**不平行**——datapath 是單一連貫敘事，拆 subagent 會失去連貫並重複 context。

## 驗證與完成準則

- 每個 datapath 實作 claim 都有對應 pinned submodule 的 source 證據。
- 新 slug `rbd-io-datapath` 經 `projects.ts` 解析正常；新 project 在站上可瀏覽。
- re-pin 後既有頁（特別是 `windows-vm-features.mdx`）行號 re-verify 完成、修正完成。
- `make validate` exit 0（含 Next.js build）。
- 完成回報列出：變更路徑、版本 re-pin 結果、validate 結果、re-verify 修正清單、刻意省略的 source gap。

## 明確不做（YAGNI / 後續 round）

- 參數目錄頁（可調參數、優先序、impact 大小）——後續。
- 效能實驗計畫頁（前 3 個參數）——後續。
- librbd 路徑的完整獨立拆解——只在 datapath 頁標差異。
- RHEL/CentOS Stream kernel source——已選 Ubuntu HWE 6.8。
- 任何效能 benchmark 實測——本批為 source 分析，不跑 lab。
