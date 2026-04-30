---
date: 2026-04-30
project: ceph
version: v19.2.3 (Squid LTS)
status: approved
---

# SP-6: ceph v19.2.3 first-wave MVP — design

## 目的

把 ceph v19.2.3 (Squid LTS) 的核心運作壓成 4 頁，足夠讓 SP-2 30 天 lab 第三週 (Day 15-21: ceph + rook) 有原始碼可對照。沿用 SP-3/4/5 的形狀：4 MDX + 5 題 quiz。ceph 的 codebase 巨大 (~1M LOC C++ + Python)，本 SP 嚴格走「RADOS 核心 + RBD」路線；CephFS / RGW / multi-site / NVMeoF gateway 留給 SP-6b 第二波。

## 範圍（嚴格 YAGNI）

只做 first-wave MVP。**不**包含：

- **CephFS** (MDS) 內部運作 — 只在 architecture 提一句
- **RGW** (S3 object) — 只提名字
- **NVMe-oF gateway**
- **Multi-site replication / mirroring (RBD/RGW)**
- **Crimson** (新一代 OSD 引擎，async/Seastar) — 提一句
- **erasure coding 的 algebra 內部** — 提到 ECBackend 存在但不展開
- **rook-ceph operator 的 reconcile loop** — 留給 SP-6b（如做的話）
- **dashboard / orchestrator (cephadm)** 的細節

第一波只覆蓋：MON/OSD/MGR + CRUSH + BlueStore + librbd + ceph-csi 的接點。

## 4 頁切法

選擇 **bottom-up**：先看誰存什麼 (architecture) → 怎麼決定存哪 (CRUSH) → 怎麼真的存 (OSD + BlueStore) → 上層 client 看到什麼 (RBD + CSI)。理由：ceph 的反直覺核心是「沒有中央 metadata server 也能定位 object」，這個故事必須從 CRUSH 講起；不講 CRUSH 直接跳 RBD 會講不通為什麼能 scale。

### 頁 1：`architecture.mdx`（daemon 與 RADOS 架構）

**核心問題**：你 ssh 進 ceph cluster 任一台機器，看到一堆 ceph-mon、ceph-osd、ceph-mgr process。它們各自做什麼？client 寫一個 RBD volume，整段路徑經過誰？

**內容大綱**：

- **三類 daemon**（per node 可能多種共存）：
  - **MON** (`ceph-mon`)：Paxos quorum，維護 cluster state（OSDMap、MONmap、MGRmap、PGmap、CRUSHMap）。所有 client 與 daemon 必須先連 MON 拿到 map 才能定位 object。typical 3 或 5 個（奇數 quorum）
  - **OSD** (`ceph-osd`)：每個磁碟一個 daemon。實際存 RADOS object、做 replication、recovery、scrubbing
  - **MGR** (`ceph-mgr`)：metric aggregation、dashboard、orchestrator (cephadm) 控制平面。1 active + N standby
  - **MDS** (`ceph-mds`)：只有用 CephFS 才需要；提到不展開
  - **RGW**：S3 / Swift gateway；本 SP 不展開
- **RADOS** (Reliable Autonomic Distributed Object Store) — 上面所有 daemon 的下層：一個分散式 object store，所有 client 都用 librados 對它做 PUT/GET
- **client 的 path**：
  1. 連任一 MON 拿 OSDMap (含 CRUSHMap)
  2. 在本機算 object → PG → OSD set (用 CRUSH，**不用查表**)
  3. 直連 primary OSD 寫
  4. primary 自己 replicate 到 secondary OSD（依 pool 的 size, 預設 3）
  5. 寫成功後 ack 給 client
- 跟 k8s 的接點預告：rook-ceph operator 把整個 cluster 當 CRD 管；ceph-csi 把 librbd 包成 PVC backend (詳細見頁 4)

**關鍵 file/symbol**：

- `src/ceph_mon.cc:249` — MON main
- `src/ceph_osd.cc:120` — OSD main
- `src/ceph_mgr.cc` — MGR main
- `src/mon/Monitor.h:108` — `class Monitor`（含 `std::unique_ptr<Paxos> paxos;`）
- `src/osdc/Objecter.h:1689` — `class Objecter`（client 端 RADOS dispatcher）
- `src/librados/` — librados 實作

### 頁 2：`crush-and-placement.mdx`（為什麼不用中央 metadata server）

**核心問題**：HDFS / GFS 用 NameNode 記「哪個 block 在哪個 node」。ceph 沒有這個東西。它怎麼定位 object？答：CRUSH。每個 client 自己算。

**內容大綱**：

- **PG (Placement Group)** 是中介層：object → PG (用 hash) → OSD set (用 CRUSH)
  - 為什麼要 PG？把 N 個 object 「分組」後，CRUSH 算的是「PG 該放哪幾個 OSD」而不是「每個 object 該放哪幾個 OSD」。N 個 object 可能 trillion；PG 數量可控（典型 hundreds 到 thousands per pool）
  - PG ID = `pool_id.hash(object_name) % pg_num`
- **CRUSH (Controlled Replication Under Scalable Hashing)**：
  - input：object name + cluster topology (CRUSHMap：root → datacenter → rack → host → osd 樹) + rule (例如「3 replica，跨 host」)
  - output：N 個 OSD ID (有序 — 第一個是 primary)
  - 性質：
    - **deterministic**：同 input 永遠出同 output
    - **balanced**：object 大致均勻分布
    - **decentralized**：client 自己算，不需要查中央 server
    - **stable**：cluster 變動 (加 OSD / 拔 OSD) 時，**只有少數 PG 需要重 placement**（不是全部 reshuffle）
- **CRUSHMap** 三個元素：
  - hierarchy (devices, buckets) — 物理拓撲
  - bucket types (host, rack, datacenter, root) — 故障域層級
  - rules — 「對 pool X 用幾個 replica、要跨哪個 bucket type」
- **Stable property 來自 straw2 algorithm**：bucket 內部用 weighted random，加 OSD 只影響「該 bucket 內的少數 PG」。算法在 `src/crush/mapper.c`
- **PG 狀態**：active+clean / degraded / undersized / inconsistent / scrubbing 等。`ceph -s` 看 PGmap 就是看這些狀態
- 為什麼這設計重要：拿掉中央 metadata server → cluster 沒有 SPOF metadata 路徑 → object 定位是 O(1) 的算式（沒有 lookup latency）

**關鍵 file/symbol**：

- `src/crush/mapper.c:2016` — `crush_do_rule`（核心 placement function）
- `src/crush/CrushWrapper.h:51` — `class CrushWrapper`（C++ wrapper）
- `src/crush/builder.c` — CRUSHMap 建構
- `src/crush/hash.c` — bucket hash 函式
- `src/crush/types.h` — bucket types

### 頁 3：`osd-and-bluestore.mdx`（OSD daemon 主迴圈 + 本地 storage 引擎）

**核心問題**：primary OSD 收到 write op，到資料真的落盤、replicate 到 secondary、ack 回 client，背後 OSD 內部跑了什麼？BlueStore 為什麼不用 filesystem 而是直接管 raw block？

**內容大綱**：

- **OSD daemon 結構**：
  - 一個 OSD daemon 服務一塊磁碟（或一個 LVM 邏輯 volume）
  - 內含多個 PG instances（OSD 可能是 100~200 個 PG 的 primary 或 secondary）
  - 主入口 `class OSD` (`src/osd/OSD.h:1062`)；tick `OSD::tick()` 在 OSD.cc:6337
- **PG / PrimaryLogPG**：
  - `class PG` (`src/osd/PG.h:166`) — 抽象 PG
  - `class PrimaryLogPG : public PG` (`src/osd/PrimaryLogPG.h:60`) — 預設的 replicated pool 實作
  - 還有 `ECBackend` (`src/osd/ECBackend.h`) — erasure-coded pool 的對應實作
  - `do_op` / `do_request` 處理 client request；replication 透過 `Connection` 對 secondary OSD 發 sub-op
- **OSD 寫操作 flow（簡化）**：
  ```
  client → primary OSD (走 messenger thread)
            ├─ PrimaryLogPG.do_op → ObjectStore (BlueStore)
            ├─ 同步發 sub-op 給 secondary OSDs
            ├─ 等所有 secondary 回 commit
            └─ ack client (write applied + committed)
  ```
- **BlueStore**：OSD 的 default object storage backend (取代舊 FileStore + xfs)
  - 為什麼不用 ext4/xfs？舊 FileStore 把每個 RADOS object 存成 filesystem file，metadata 在 filesystem inode。問題：
    - **double write**：filesystem journal + object journal
    - **fsync 不夠細**：filesystem 的 sync 太粗，影響 latency
    - **metadata on-disk format 不可控**
  - BlueStore 直接管 raw block device + RocksDB on top of small custom FS (BlueFS)
    - object data → 直接寫 raw block (no filesystem)
    - object metadata、PG log、collection state → RocksDB（kv-store）
    - RocksDB 的 .sst 檔放在 BlueFS（極簡 FS，只給 RocksDB 用）
  - `class BlueStore` (`src/os/bluestore/BlueStore.h:236`)
  - `class Allocator` (`src/os/bluestore/Allocator.h:24`)；多種策略 (BitmapAllocator、AvlAllocator)
  - `class BlueFS` (`src/os/bluestore/BlueFS.h:249`)
- **recovery / backfill / scrubbing**：
  - **recovery**：peer 短暫掛掉再回來 → 用 PG log 重放缺漏的 ops
  - **backfill**：peer 不見了 → 從另一個 OSD 完整 copy PG 的 object
  - **scrubbing**：定期 cross-check primary vs secondary 的 object checksum；deep-scrub 連 data 都 compare
- **Crimson**：v19 還是 classic OSD（多 thread + messenger）；Crimson 是新一代 OSD（Seastar / shared-nothing），目前 experimental，不在本 SP

**關鍵 file/symbol**：

- `src/ceph_osd.cc:120` — OSD main
- `src/osd/OSD.h:1062` — `class OSD`
- `src/osd/OSD.cc:6337` — `OSD::tick`
- `src/osd/PG.h:166` — `class PG`
- `src/osd/PrimaryLogPG.h:60` — `class PrimaryLogPG`
- `src/osd/ECBackend.h` — `class ECBackend` (erasure-coded backend)
- `src/os/bluestore/BlueStore.h:236` — `class BlueStore`
- `src/os/bluestore/BlueFS.h:249` — `class BlueFS`
- `src/os/bluestore/Allocator.h:24` — `class Allocator`

### 頁 4：`rbd-and-csi.mdx`（block image 與 k8s PVC 接點）

**核心問題**：你 KubeVirt VM 拿到 RBD 磁碟跑 guest OS。它在 ceph 那邊長什麼樣？ceph-csi 怎麼把 librbd 變成 k8s PVC？rook 又是什麼？

**內容大綱**：

- **RBD (RADOS Block Device)**：把一個「N GB 的 block volume」存成 RADOS pool 內一堆 4MB（預設）的 object
  - image name (e.g. `vm-disk-1`) → header object (含 size, stripe info, snapshot list)
  - data 切成 `<image_id>.<chunk_index>` 的 RADOS object（偏移量 → chunk index 是固定算式）
  - **client thin provision**：image 宣告 50GB，但只有真寫入的 chunk 會在 RADOS 落物件
- **librbd**：client 端 lib，把「block read/write at offset」翻成 RADOS object op
  - `src/librbd/` — 主邏輯
  - `src/cls/rbd/cls_rbd.cc` — 對應的 server-side class extension（在 OSD 內跑的 RPC）
- **librbd → librados → OSDMap → CRUSH → primary OSD** 整段是上述頁 1+2+3 的應用
- **snapshot / clone**：copy-on-write，全 client 端用 RADOS object snapshot operation 達成
- **ceph-csi**（k8s 的 CSI driver）：
  - 是兩個 binary：controller plugin（管 PVC create/delete）+ node plugin（管 volume mount/unmount on each node）
  - 收到 PVC 請求 → 用 ceph CLI / librbd 對 ceph cluster create RBD image → 給 k8s 一個 volume handle (RBD image ID)
  - kubelet 要 mount volume → ceph-csi node plugin 用 `rbd-nbd` 或 kernel `rbd` module map RBD image 成本機 block device → mount 成 filesystem 給 Pod
  - 程式碼在 [github.com/ceph/ceph-csi](https://github.com/ceph/ceph-csi)（不在 ceph 本 repo）
- **rook**：把整個 ceph cluster 當 k8s CRD 管的 operator
  - `CephCluster` CRD → operator 起 ceph-mon、ceph-osd 為 k8s Pod / DaemonSet
  - `CephBlockPool` CRD → 對 ceph create pool
  - `CephObjectStore` CRD → deploy RGW
  - `StorageClass` 指向 ceph-csi → 串成「rook 起 ceph、ceph-csi 給 PVC」的閉環
  - rook operator 細節（reconcile loop）留 SP-6b（如做）
- 整段對齊 Day 18 lab：你的 KubeVirt VM 拿到 RBD 磁碟，背後路徑是 librbd → CRUSH → primary OSD → BlueStore → 你的 raw block

**關鍵 file/symbol**：

- `src/librbd/` — 主目錄
- `src/librados/IoCtxImpl.h` — librados client implementation
- `src/cls/rbd/cls_rbd.cc` — server-side RBD class extension
- ceph-csi 在 [github.com/ceph/ceph-csi](https://github.com/ceph/ceph-csi)（外部 repo）
- rook 在 [github.com/rook/rook](https://github.com/rook/rook)（外部 repo）

## Quiz 設計（5 題）

1. **MON Paxos quorum** — MON 為什麼要奇數個？少於 quorum 時 cluster 會怎樣？
2. **CRUSH 的核心 property** — 為什麼 client 能自己算 object 位置不需要中央 server？
3. **PG 為什麼存在** — object 多到 trillion 時直接 object→OSD CRUSH 算式為什麼撐不住？
4. **BlueStore 不用 filesystem** — 為什麼 raw block + RocksDB 比 FileStore + xfs 好？
5. **RBD 怎麼切 object** — 50GB RBD image 在 RADOS 是一坨什麼？

## 驗證等級

- file path / line number → grep 在 `ceph/` submodule v19.2.3 上跑過
- 不寫 lab 命令 (lab 在 SP-2)；不需要實機 ceph cluster 驗證
- ceph-csi / rook 是外部 repo，引用時用 GitHub 主 page 連結（沒 pin 版本）

## 跟現有 SP 的接點

- `next-site/lib/projects.ts`：在 `PROJECTS` 加 `ceph` 條目，4 features (architecture / crush-and-placement / osd-and-bluestore / rbd-and-csi)
- `next-site/content/ceph/quiz.json` 5 題
- learning-plan Day 15-21 的源碼參考可以指到這 4 頁
- `versions.json` 加 `ceph` 條目

## 不做的事

- 不寫 mermaid，圖一律 ASCII
- 不展開 CephFS / RGW / multi-site
- 不展開 rook-ceph operator 內部
- 不展開 erasure coding algebra
- 不寫 lab 命令；lab 在 SP-2 day-pages
