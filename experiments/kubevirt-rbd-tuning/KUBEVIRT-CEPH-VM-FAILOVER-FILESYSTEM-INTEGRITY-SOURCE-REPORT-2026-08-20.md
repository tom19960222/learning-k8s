# KubeVirt VM 斷電後的 Ceph RBD 完整性：原始碼調查與生產建議

> 研究日期：2026-08-20
> 依據：[GitHub Issue #32](https://github.com/tom19960222/learning-k8s/issues/32)
> 原則：資料完整性優先。舊 node 完成 fencing 前，不得在其他 node 重啟 VM。
> 證據範圍：指定版本原始碼；尚未讀取生產環境，也沒有執行故障實驗。

## 一句話結論

只要同一時間只有一個能寫入的 VM、每一層都確實傳遞 `flush`，而且底層裝置沒有謊報寫入完成，compute node 突然斷電後，ext4 或 XFS 應該做正常的 journal／log replay，不該壞到必須 `fsck` 或 `xfs_repair`。生產環境既然已經出現後者，就要找出哪一層違反了這個前提，不能把它當成正常斷電結果，也不能靠調短 timeout 蒙混過去。

## 兩分鐘決策摘要

| 現在要做什麼 | 原因 | 不處理的代價 |
|---|---|---|
| fencing 完成後才能在新 node 啟動 VM | Kubernetes 刪掉 `VolumeAttachment` 不代表舊 host 已經解除 RBD mapping | 可能同時出現兩個 writer，這比單純斷電更容易毀損檔案系統 |
| 保持 `CSIDriver.spec.attachRequired=true` | 這是 RWO volume 的 attach 排他機制；Rook 也明確警告不可關閉 | 為了快幾分鐘而拆掉一道防止多重掛載的保護 |
| 系統碟和每顆資料碟都要逐顆對盤 | YAML 只代表設定意圖；真正生效的是 libvirt XML、QEMU block graph 和 host krbd mapping | 查錯 disk 或誤判 `cache`／`io`，後續調整全部失去依據 |
| 先確認 `flush` 沒有被忽略 | `cache=none`、`writethrough`、`writeback` 都不能只看名稱判斷；重點是實際 block graph 是否保留 flush | journal 以為資料已經穩定，實際上仍留在揮發性 cache |
| 保留 ext4／XFS 的正常 recovery | ext4 的 barrier、XFS 的 log flush，以及兩者的 replay 都是斷電後恢復的核心 | 用 `noload`、`norecovery` 等選項略過 replay，反而會把不一致內容直接暴露出來 |
| timeout、CSI sidecar 和 queue tuning 先不要動 | 它們主要影響多久報錯或何時重新排程，不會讓資料更耐斷電 | RTO 可能改變，但結構損壞的根因仍在 |

### 先不要做

- fencing 尚未確認前，不要 force-delete 舊 VMI／Pod、加 out-of-service taint 後直接在新 node 重開。
- 不要把 `CSI_RBD_ATTACH_REQUIRED=false` 當成加速 failover 的方法。
- 不要把 registrar、CSI liveness、leader election 或 attach/detach timeout 當成完整性參數。
- 不要把 `cache=none` 解讀成「guest 沒有 write cache」。它代表 direct I/O，而且 flush 仍然有效。
- 不要先認定 `cache=writeback` 就是事故根因。它會多一層揮發性 host cache，但是否造成這次損壞仍要看實際設定與故障證據。
- 不要把應用程式沒有呼叫 `fsync` 造成的近期資料遺失，和檔案系統結構損壞混為一談。

## 1. 這份報告要解決什麼

這次要釐清的不是「斷電會不會掉最後幾筆資料」，而是為什麼 VM 在 compute node 斷電後，檔案系統會壞到無法 mount，必須執行修復工具。

報告回答四個問題：

1. guest 完成一次需要持久化的寫入後，資料會經過哪些層，Ceph 到哪裡才回覆成功？
2. ext4／XFS 的正常斷電 recovery，和真正需要修復的結構損壞有什麼差別？
3. 哪些設定真的影響完整性，哪些只影響效能、錯誤時間或 failover 速度？
4. 在不變更生產環境的前提下，要怎麼查出實際生效的設定？

### 調查前提

- 斷電的是只承載 VM 的 compute node；Ceph MON 和 OSD 持續運作。
- VM 系統碟與資料碟都是 Ceph RBD，host 使用 krbd，PVC 是 `volumeMode: Block`。
- ext4 與 XFS 都在調查範圍。
- 正常的 journal／log replay 不算事故；無法 mount、必須 `fsck`／`xfs_repair` 才算本報告要追的結構損壞。
- 完整性高於 RTO。fencing 已存在，本報告不重新設計它，只把「舊 node 已失去寫入能力」當成重啟前置條件。
- 應用程式若沒有呼叫 `fsync` 或等價操作，底層無法替它創造持久化保證。

### 研究版本

| 元件 | 指定版本／commit | 這份報告查什麼 |
|---|---|---|
| KubeVirt | v1.6.4 / `ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f` | Disk API、defaulting、Block PVC、domain XML |
| Kubernetes | v1.31.6 / `6b3560758b37680cb713dfc71da03c04cadd657c` | Block volume lifecycle、VolumeAttachment、node-loss force-detach |
| ceph-csi | v3.14.0 / `0d0e1f832cf7d0184ef332e2f947725e02e66135` | krbd map、Stage／Publish／Unstage |
| csi-node-driver-registrar | v2.13.0 / `9b41324b20f609bce4dda9e50cc484c4ef4f5949` | kubelet plugin registration responsibility boundary |
| Rook | v1.17.2 / `f6266772d2095c8af312745d9cbe045c98a380df` | generated CSI images、args、`attachRequired` |
| Ceph | v19.2.2 / `0eceb0defba60152a8182f7bd87d164b639885b8` | OSD acknowledgement、replication、BlueStore persistence |
| Ubuntu kernel | 6.8.0-52.53 / `6e81b9ec35b52955f286e56ffc159e1c934bce10` | ext4、XFS、block layer、virtio-blk、krbd/libceph |
| QEMU | 生產版本**未知**；v9.1.0 / `fd1952d…` 只作機制參考 | 不可把參考版本當成現場行為 |
| libvirt | 生產版本與原始碼**未釘定** | domain XML 到 QEMU block graph 必須現場確認 |
| external-attacher | Rook 預設 v4.8.0；原始碼**未納入** | finalizer 與 retry 細節仍是證據缺口 |

### 怎麼看證據標記

| 標記 | 意義 | 可以支撐什麼 |
|---|---|---|
| **source-proven** | 指定版本原始碼直接顯示的行為或預設值 | 可以說明機制 |
| **reference-source-proven** | 版本已釘定，但不是生產環境使用的參考原始碼 | 只能幫助理解與設計實驗 |
| **upstream-commit-proven** | upstream commit 與 diff 可查，但還不知道進入哪個正式版本 | 不能直接下升級建議 |
| **documentation-supported** | 同版本官方說明與原始碼一致 | 補充解讀，不取代原始碼 |
| **inference** | 把多段證據串起來後得到的推論 | 必須同時寫出前提與限制 |
| **runtime-required** | 原始碼告訴我們怎麼查，但尚未讀取生產環境 | 不能寫成現場事實 |
| **experiment-needed** | 原始碼無法回答時間、硬體行為或事故因果 | 必須用隔離實驗補證據 |

## 2. 一筆資料怎麼走到 Ceph

先說三個後面會一直出現的詞：

- **FUA（Force Unit Access）**：要求這筆資料到達裝置宣告的持久化邊界後才能回覆。若 backend 沒有原生 FUA，Linux 或 QEMU 可以在寫入後補一次 `flush`。
- **ONDISK**：krbd 要求 Ceph OSD 完成 ObjectStore transaction 後才回覆。它證明軟體走完承諾的持久化路徑，不代表我們已經驗證每顆 SSD 的實體 NAND。
- **acting set**：當下實際負責某個 PG 寫入的 OSD 集合。PG degraded 時，這個集合可能少於 pool 設定的 `size`。

一筆需要持久化的資料，完整路徑如下：

```text
應用程式呼叫 fsync／sync，或檔案系統提交 transaction
  → ext4 journal／XFS log 排好資料與 metadata 的順序
  → guest Linux block layer 送出 write 與 flush／FUA
  → virtio-blk 送出資料與 VIRTIO_BLK_T_FLUSH
  → QEMU／libvirt 實際生效的 block graph
  → virt-launcher 裡的 /dev/<volume>
  → host krbd 要求 Ceph 回 ONDISK
  → primary OSD 與當下所有 replica 完成 transaction
  → BlueStore／BlueFS／block device 的持久化邊界
  → 舊 node 已 fenced，新 node 重新 map 並 mount 同一個 image
  → ext4 journal／XFS log replay
  → 正常恢復，或檢查器發現結構錯誤並要求修復
```

Kubernetes 管理 volume 的路徑是另一回事：

```text
Kubernetes VolumeAttachment
  → ceph-csi ControllerPublish (NOOP)
  → NodeStage: rbd map + staging bind
  → NodePublish: staging bind to Pod target
```

第一條決定資料何時算穩定；第二條只決定哪個 node 何時看得到 block device。`attach` 成功不代表資料已落地，資料已落地也不能取代 fencing。

### 最該先查的三個斷點

| 斷點 | 會發生什麼 | 參數能否處理 |
|---|---|---|
| 應用程式沒有呼叫 `fsync` | 最近幾筆資料可能消失，但檔案系統結構仍應靠 journal／log recovery 保持可 mount | 儲存層參數無法替應用程式補上持久化邊界 |
| 某一層提早回覆、忽略 `flush`，或硬體 cache 謊報完成 | journal／log 以為順序已成立，斷電後卻看到舊 metadata 或不完整 transaction | 先查實際生效的 cache 與 flush；軟體無法修補失信硬體 |
| fencing 前出現第二個 writer | 兩個 kernel 可能同時修改同一個 RBD image；ext4／XFS 不是 shared-disk 檔案系統 | 只能靠 fencing、RWO attach 排他與 writer ownership 防止；timeout 沒用 |

所以，「斷電後必須 repair 才能 mount」不能只用「應用程式最後幾筆資料沒 flush」解釋。至少要查：完整寫入路徑在哪裡斷掉、是否曾出現第二個 writer、是否踩到 kernel／QEMU／Ceph bug，以及底層裝置有沒有違反 flush 承諾。

## 3. ext4、XFS 與 virtio 各自保證什麼

### 3.1 ext4

Ubuntu 6.8.0-52 的 ext4 預設開啟 barrier。journal 支援 revoke 時，預設 data mode 是 `ordered`。`fsync` 會先等檔案資料完成，再提交 journal；若 journal commit 沒有帶 barrier，ext4 會再補一次 block-device `flush`。

正常斷電後，未乾淨卸載的 ext4 應該走 JBD2 scan、revoke、replay。這是正常 recovery，不是檔案系統已經損壞。

以下狀態要分開看：

- **正常 recovery**：superblock 顯示上次沒有乾淨卸載，mount 時執行 JBD2 recovery。
- **真的壞了**：superblock checksum、group descriptor 或 root inode 驗證失敗，kernel 回 `EFSBADCRC`／`EFSCORRUPTED`。
- **不安全的繞過**：對 dirty filesystem 使用 `noload`／`norecovery`。read-write mount 會被拒絕，這也不是修復方法。

生產環境應保留 barrier 與 `data=ordered`，不要把 `nobarrier`、`data=writeback` 或 `noload` 當成 failover tuning。

### 3.2 XFS

這版 XFS 已經沒有 `barrier`／`nobarrier` mount option。需要同步 log 時，XFS 會直接送出 `REQ_PREFLUSH | REQ_FUA`。dirty log 的 head 與 tail 不同時才進入兩階段 recovery；若檔案系統已標記 `needsrepair`，mount 會被拒絕。

因此 XFS 的判讀也要分三層：

- **正常 recovery**：分析並 replay dirty log。
- **需要修復**：`needsrepair` 或 metadata verifier 讓 mount 失敗。
- **只讀鑑識**：`norecovery` 只能搭配 read-only，而且內容可能不一致，不能拿來正常提供服務。

所以，XFS 的重點不是找一個已經不存在的 barrier 開關，而是確認 guest queue 的 flush 能力、QEMU 實際 cache mode、host krbd 的完成條件與 fencing。

### 3.3 FUA 經過 virtio 後會變成什麼

virtio-blk 會協商 FLUSH 與 write-cache 能力，但這版 Linux driver 對 queue 宣告 `writeback=true, fua=false`。guest block layer 收到需要 FUA 的 request 時，會在必要時改成「先寫入、再 flush」；virtio driver 在 wire 上送出獨立的 `VIRTIO_BLK_T_FLUSH`。

也就是說，guest 的 FUA bit 並不是原封不動穿過 virtio。保留下來的是「資料要穩定後才能完成」的語意，實際做法是 `flush`。

## 4. 真正生效的 disk 設定不一定寫在 YAML 裡

### 4.1 系統碟與資料碟走同一條轉換路徑

KubeVirt v1.6.4 逐顆處理 `vmi.Spec.Domain.Devices.Disks`。系統碟唯一可能的特殊欄位是 `bootOrder`；只要系統碟和資料碟都是同類型的 Block PVC，後面的 block-device 與轉換路徑就相同。

不過，同一路徑不代表設定值相同。每顆 disk 都有自己的 `bus`、`cache`、`io`、`dedicatedIOThread`，所以不能只查一顆資料碟就推論系統碟也一樣。

### 4.2 `cache`／`io` 留空時，KubeVirt 會在啟動前決定

對 `volumeMode: Block`，KubeVirt 會把 volume 放到 compute container 的 `/dev/<volume-name>`，用 `os.Stat` 確認它是 block device，再產生 `<disk type='block'><source dev='…'><driver type='raw'>`。

啟動前才做兩個決策：

1. 沒寫 `cache`：用 `O_DIRECT` 測 backend。成功就選 `none`，失敗就選 `writethrough`。若明確指定 `none`，但 direct I/O 不可用，VMI 會啟動失敗。
2. 沒寫 `io`：只有實際 `cache=none` 且 backend 是 block device，或檔案已 preallocated，才補成 `native`；其他情況維持省略。

因此，原始碼只支持這句話：「對已存在且支援 O_DIRECT 的 Block PVC，預期結果是 `cache=none, io=native`。」它不是所有環境都固定套用的 YAML 預設值。

### 4.3 QEMU 的 cache mode 到底代表什麼

以下是 QEMU v9.1.0 的定義，只能用來解釋機制。生產環境必須先查實際 QEMU 版本。

| cache mode | QEMU writeback | direct | no-flush | 實際意思 |
|---|---:|---:|---:|---|
| `none` | on | on | off | 繞過 host page cache；guest flush 仍有效 |
| `writethrough` | off | off | off | 每次 write 要求 FUA，backend 不支援時用 flush 模擬 |
| `writeback` | on | off | off | 使用 host page cache；flush 仍有效，但多一層揮發性資料 |

真正刻意忽略 flush 的是 `no-flush=on`／unsafe 類模式；KubeVirt API 不接受 unsafe cache mode。`cache=none` 代表 direct I/O 加上正常 flush，不代表 guest write cache 已關閉。

### 4.4 v1.6.4 有一個 bug，但目前不能把事故算在它頭上

`SetDriverCacheMode` 選到 `Source.Dev` 後，`isBlockDev` 仍是 false，所以程式呼叫 `CheckFile`，而不是 `CheckBlockDevice`。兩個檢查對已存在的 device 都使用 `O_RDONLY | O_DIRECT`；主要差異是 path 不存在時，`CheckFile` 可能嘗試建立檔案。

- **已確認**：這個分類分支有錯；後續 main commit `d7c683cde613869fda86e333957976b6bba8faa6` 改用 `BackendIsBlock()`。
- **尚未確認**：正常且已存在的 `/dev/<volume>` 是否因此選錯 cache mode，更沒有證據能把這次結構損壞歸因於它。
- **升級前要補的證據**：這個修正第一次進入哪個正式版本、是否有 backport，以及相同 Block PVC 在修正前後的 domain XML 差異。

## 5. Kubernetes 能安排接手，但不能替你 fencing

### 5.1 `VolumeAttachment` 不是實體 device，也不是 fencing

ceph-csi v3.14.0 的 RBD `ControllerPublishVolume` 只驗證 request，然後回傳空的 `PublishContext`；`ControllerUnpublishVolume` 也直接成功。真正的 RBD mapping 發生在 node：

```text
NodeStageVolume
  → watcher in-use check
  → rbd map --device-type krbd
  → /dev/rbdX
  → bind to staging file

NodePublishVolume
  → bind staging file to Pod block target

NodeUnpublishVolume
  → unmount/delete Pod target only

NodeUnstageVolume
  → unmount staging
  → rbd unmap
  → remove stash
```

舊 node 斷電後，kubelet 當然無法執行正常的 Unpublish／Unstage。控制面刪除 `VolumeAttachment`，不會隔空讓舊 host kernel 執行 krbd unmap，也不能證明舊 node 已失去寫入能力。

### 5.2 Rook 與 registrar 各自只負責什麼

Rook v1.17.2 預設把 RBD 的 `attachRequired` 設為 `true`，並寫進 `CSIDriver`；只有這個值為 true 才會部署 external-attacher。這是 RWO volume 避免同時 attach 到多個 node 的必要防線，不能為了縮短 failover 而關掉。

node-driver-registrar 只負責連上 CSI socket、取得 driver name、建立 kubelet registration socket，再回報 registration status。它不碰 Kubernetes API、不建立 `VolumeAttachment`、不 map RBD、不處理 flush，也不提供 fencing。調 registrar timeout 或 liveness，無法修復檔案系統結構損壞。

### 5.3 Kubernetes 的 6 分鐘不是完整 failover 時間

attach/detach controller 最多等 6 分鐘再 force detach，但計時不是從 node 斷電當下開始，而是 volume 已經不在 desired state 後才開始。時間到後，還要符合 node unhealthy 或 out-of-service 條件，才會略過「volume 仍 mounted」的保護。接著仍有舊 `VolumeAttachment` 刪除、external-attacher、新 attachment、ceph-csi watcher 檢查、NodeStage／Publish 和 VMI 啟動。

所以不能把幾個 timeout 相加，就宣稱 VM 會在幾分鐘內恢復。這些時間只影響接手流程，和已回覆成功的資料是否真的穩定是兩回事。

### 5.4 CSI 不知道哪顆是系統碟

Kubernetes 和 ceph-csi 只看 PV、volume handle／attributes、volumeMode、access mode、target path 與 node name，不知道哪顆是系統碟。兩顆 disk 若使用相同的 volumeMode、access mode、PV attributes 與 pool policy，底層持久化路徑就相同。差別只在上層 lifecycle：系統碟通常跟著 VM，資料碟可能 hotplug／unplug。

## 6. host krbd 與 Ceph 何時才算寫入完成

kernel 6.8.0-52 的 krbd queue 只處理 READ、WRITE、DISCARD、WRITE_ZEROES，沒有 `REQ_OP_FLUSH`。這不是 Ceph 漏做 flush。krbd 沒有宣告 write cache，也沒有宣告原生 FUA，因此 Linux 把它視為 write-through device；libceph 對每筆 request 都要求 `CEPH_OSD_FLAG_ONDISK`，收到 ONDISK reply 才算完成。

因此，這條路徑何時算完成可以寫成：

```text
guest flush/FUA ordering
  → QEMU 等先前 host writes 完成
  → krbd 每筆 write 本身等待 Ceph ONDISK completion
  → host rbd device 不需要另一個 volatile write cache flush
```

生產環境應看到 `/sys/class/block/rbdN/queue/write_cache` 為 `write through`，`fua` 為 `0`。兩個值要一起看；只看到 `fua=0`，不能直接判定不安全。

### 6.1 `exclusive-lock` 不是硬體 fencing

image 開啟 `exclusive-lock` 時，krbd 寫入前必須先取得 lock；`object-map` 或 `lock_on_read` 還可能讓讀取也需要 lock。它能降低多個 client 同時寫同一個 image 的機會，但不能取代硬體 fencing：

- 舊 node 網路中斷、watch 失效、blocklist 與 lock handoff 都有各自的時間窗和錯誤路徑。
- `exclusive` map option 會拒絕 peer 要求釋放 lock，可能直接阻擋 handoff／live migration。
- Ceph lock 成功不能證明舊 node 已經斷電；重啟 gate 仍然必須看硬體 fencing。

### 6.2 timeout 只決定多久回錯，不會讓資料更安全

krbd 的 block mq ops 沒有 `.timeout` handler。即使 sysfs 的 `io_timeout` 顯示 30 秒，generic block layer 到期後也只會重新掛 timer，不會中止 request。真正能讓 libceph OSD request 回 `ETIMEDOUT` 的是 `osd_request_timeout`；預設值 `0` 代表無限等待。

所以：

- 調 `/sys/block/rbdN/queue/io_timeout`，不會讓 krbd 在 30 秒後自動 failover。
- 設定非零 `osd_request_timeout`，可能把暫時網路中斷轉成 guest I/O error 或檔案系統 shutdown。這是錯誤處理政策，必須先在隔離 lab 驗證，不是完整性修正。

### 6.3 Ceph `ONDISK` 不是收到多數 replica 就算完成

Ceph v19.2.2 對一筆 replicated write 建立的等待集合，是當下整個 `acting_recovery_backfill` set，包含 primary：

1. primary 本機 ObjectStore transaction 完成 `on_commit` 後，才從集合移除 primary。
2. 每個 replica 也要等自己的 `on_commit` 完成才回 ONDISK，primary 收到後才移除該 replica。
3. 集合清空後，`PrimaryLogPG::repop_all_committed()` 才標記 all committed，最後才回覆 client `ACK | ONDISK`。

所以 `min_size` 不是「收到幾份就提早回覆」的 quorum。它只決定 acting set 少到什麼程度時，PG 還允許寫入：

- `size=3,min_size=2`，而且 PG 是 active+clean：成功回覆代表當下三份都已 commit。
- PG degraded 到只剩兩份仍可寫：成功回覆只代表當下兩份已 commit。
- 若政策要求每筆成功 write 都必須落滿 `size` 份，可以評估 `min_size=size`；代價是少一份 replica 就停止寫入。

compute node 在收到 ONDISK 後消失，已完成的 transaction 不依賴該 node 的 RAM。若 node 在收到 reply 前消失，這筆 write 可能已經穩定，也可能尚未穩定；應用程式不能因為「沒收到成功」就假設「一定沒寫入」。

### 6.4 BlueStore 的 ONDISK 到底保證到哪裡

BlueStore commit 的精確意思是「crash 後可恢復的 transaction 已經穩定」，不一定表示資料已經放到最後的 logical extent：

- 一般資料先透過 direct AIO 寫入 block device；AIO 完成後，BlueStore 仍把它視為尚未穩定。
- KV sync cycle 會在需要時先 flush data device，再同步提交 RocksDB transaction。
- RocksDB WAL 開啟時，最後的 sync transaction 使用 `WriteOptions.sync=true`。若 WAL 位於 BlueFS，`Sync()` 會進入 `BlueFS::fsync()`，等待 AIO、flush dirty device，必要時同步 metadata log。
- kernel block backend 最後以 `fdatasync()` 實作 `flush()`。
- deferred write 會先把資料編碼成 RocksDB key。此時 ONDISK 可能代表「可 replay 的 transaction 已穩定」，而不是資料已經搬到最後位置；資料穩定後才移除 deferred key。

因此，ONDISK 不能翻成「已寫進 NAND，任何斷電都不會掉」。Ceph 原始碼最多證明 `fdatasync()` 成功返回；NVMe、RAID controller 或 hypervisor 是否真的履行 flush，以及是否有 PLP／BBU，仍要靠硬體資料或非生產環境的斷電實驗確認。

### 6.5 這些 RBD features 不是持久化保證

| Feature | 它負責什麼 | 它不負責什麼 |
|---|---|---|
| `exclusive-lock` | single-client ownership、lock handoff、cache coherency | 不改 OSD replica commit 或 media flush |
| `object-map` | 記錄 object 是否存在，加速查詢 | 不是資料 journal，也不增加 replica |
| `journaling` | userspace librbd 的 journal／replay／mirroring | host krbd 不走這條 userspace write path |
| `fast-diff` | 差異追蹤與維運最佳化 | 不提高斷電持久性 |

生產環境使用 host krbd，不能拿 `src/librbd/io/ImageRequest.cc` 的 userspace journaling path 替現場寫入背書。

## 7. 哪些要保留，哪些不要亂動

### 7.1 必須保留

| 層 | 控制／設定 | 生產要求 | 能保護什麼 | 不能保證什麼 | 變更方式 |
|---|---|---|---|---|---|
| Failover | restart 前先做 hardware fencing | 確認來源 node 已失去寫入能力，才能在新 node 啟動 VM | 避免兩台 host 同時寫同一顆 disk | 不保證應用程式最後一筆 transaction 已執行 `fsync` | 維運流程／HA controller |
| Kubernetes/Rook | `CSIDriver.spec.attachRequired=true` | 保持 Rook 預設值，不得為縮短 RTO 關閉 | 讓 RWO volume 依序 attach | 不是 fencing，也不證明 host 已 unmap | 重新產生 CSIDriver；需 rollout 控制面 |
| Disk 稽核 | VMI → domain XML → QMP／cmdline → host krbd 全部對上 | 系統碟與每顆資料碟都要查 | 確認後續建議套在真正生效的路徑 | 不會自動修正設定落差 | 唯讀檢查 |
| KubeVirt/QEMU | 實際 block graph 必須保留 flush | 逐顆確認 cache／AIO mode；不得出現忽略 flush 的 `no-flush`／unsafe 語意 | 讓 guest journal／log 的寫入順序能傳到 host backend | `writeback` 本身不是損壞證據，也不證明 OSD media 誠實 | VM 重新啟動後才會套用新 domain |
| ext4 | barrier 開啟、預設 `data=ordered`，發生錯誤時至少 remount-ro | 不得使用 `nobarrier`、`data=writeback` 或 `errors=continue` | 保留 journal ordering，並限制錯誤繼續擴散 | 不會替應用程式補做 `fsync` | mount／fstab；通常要 remount 或 reboot |
| XFS | 保留內建的 log FLUSH／FUA 與正常 recovery | 不必也不能新增 `barrier`；不得把 `norecovery` 當正常服務模式 | 保留 log ordering 與斷電後 replay | 不保證尚未 `fsync` 的資料 | kernel 內建；mount policy |
| 應用程式 | database WAL／`fsync` 約定 | 聲稱已提交的 transaction 必須明確同步 | 建立應用程式自己的持久化界線 | 無法補救底層提早回覆或硬體失信 | 應用程式設定／程式碼 |
| CSI/krbd | RWO volume 維持 single-writer，並在現場確認使用 krbd | PV access mode、VolumeAttachment、host mapping 與 lock owner 必須一致 | 避免編排層明顯的重複 attach | 不取代 fencing，也不保證 Ceph replica 已完成 commit | PV／StorageClass 建立時設定，加上執行期間稽核 |
| Ceph pool | 明確核准 `size`、`min_size` 與 CRUSH failure domain | 查實際 pool 與 acting set，不能只看 `HEALTH_OK` | 決定成功寫入要等哪些 OSD，以及能承受多少故障 | 不保證 device 真的履行 flush | pool policy；可線上變更但風險高 |
| Ceph OSD | 使用 BlueStore，並關閉所有持久化除錯 bypass | blackhole、omit-write、omit-kv 都是 false，crash injection 是 0 | 保留原始碼所顯示的 data／KV commit 路徑 | 不證明硬體有 PLP | daemon 設定；不要任意修改 |
| OSD media | controller／device 確實履行 flush，或具備 PLP／BBU | 保存型號、firmware、cache 與 PLP 證據 | 讓 `fdatasync`／flush 對實體儲存有意義 | Ceph 設定無法修補不誠實的硬體 | 硬體選型與驗證 |

### 7.2 看情況再用

| 設定 | 何時才考慮 | 本報告的限制 |
|---|---|---|
| KubeVirt 明示 `cache: none` | 要把 O_DIRECT 不可用變成啟動失敗，而不是默默退回 `writethrough` | 對正常 Block PVC 可能與留空完全相同；先查實際值 |
| KubeVirt `cache: writeback` | workload 明確需要 host page cache，且已在隔離 lab 驗證 flush、斷電 recovery 與效能收益 | flush 正常時不能直接把它當成損壞原因；但未同步資料會在 node 本機的揮發性 cache 停留更久 |
| KubeVirt 明示 `io: native` | 已證明實際使用 direct I/O，而且需要把執行設定固定下來 | QEMU v9.1.0 中，`native` 搭配非 direct cache 會開啟失敗；它不是完整性增益 |
| ext4 `data=journal` | 有明確資料 journaling需求且接受效能／功能代價 | 代價高，會限制 delayed allocation、O_DIRECT、fast commit；不是第一線修復 |
| ext4 `data_err=abort` | 希望 ordered-data writeback error 直接 abort journal | 以 availability 換 fail-stop；需故障測試 |
| XFS `wsync` | HA namespace operation 需要更強同步 | 不能取代 file data `fsync` |
| krbd `lock_on_read` | object-map 或嚴格 single-owner read有明確需求 | 可能增加 lock contention |
| `abort_on_full` | 希望空間用盡時回覆 ENOSPC，不要一直等待 | 只改變失敗方式，不提高持久性 |
| Ceph `min_size=size` | 每筆成功寫入都必須落到目標 `size`，願意犧牲 degraded write 的可用性 | 任一 replica 缺失就停止寫入；要先評估業務能否接受 |
| Ceph `size=3,min_size=2` | 接受 degraded 到兩份時仍可寫入 | 健康時仍會等完整 acting set；degraded 時成功只代表當下兩份 |
| RBD `exclusive-lock` | single-writer ownership 與 handoff policy 有明確需要 | 不取代 hardware fencing 或應用程式 flush |

### 7.3 對結構損壞沒有幫助

| 設定／做法 | 為什麼無效 |
|---|---|
| 調 node-driver-registrar | 它不在 attach 的資料路徑，也不處理 write、flush 或 krbd |
| 開 CSI liveness metrics | 只會輸出 gauge，不是 nodeplugin 的重新啟動 probe |
| 把 `ControllerPublishVolume` 成功當成 device 已就緒 | ceph-csi RBD 的 controller RPC 是 NOOP；真正 map 發生在 NodeStage |
| 事後修改 StorageClass `mapOptions` | 既有 PV 的 CSI attributes 不可變，不會跟著 StorageClass 更新 |
| 調 `queue_depth`、discard、read affinity | 只影響 concurrency、空間回收或讀取位置，沒有持久化保證 |
| 調 Kubernetes 6 分鐘 timer／leader election | 只影響接手順序與可用性，不改變寫入何時算完成 |
| 調 `/sys/block/rbdN/queue/io_timeout` | krbd 沒有 timeout callback，timer 到期不會中止 request |
| 用較小的 ext4 `commit=` 取代 `fsync` | 只縮短 journal transaction 的最長時間，不會建立應用程式 transaction 的持久化界線 |
| 看到 guest／host `fua=0` 就判定不安全 | virtio 可以用 POSTFLUSH 模擬；krbd 每筆 write 會等待 ONDISK completion |
| 調 mClock、OSD queue 或 recovery priority | 只改變 scheduling 與 latency，不改變「目前所有參與者都 commit」這道門檻 |
| `object-map`／`fast-diff` | 它們是 metadata 與維運最佳化，不是 write journal，也不增加 replica 持久性 |
| 對 krbd 啟用 librbd journaling，期待它改變寫入路徑 | host krbd 不走 userspace librbd journaling path |

### 7.4 危險或容易誤導

| 設定／操作 | 風險 |
|---|---|
| fencing 前強制重啟或加上 out-of-service taint | 可能略過 mounted safety，製造第二個 writer |
| `CSI_RBD_ATTACH_REQUIRED=false` | 拿掉 RWO attach 的順序控制；Rook 原始碼旁的範例明確警告可能造成 data corruption |
| 把 `cache: writeback` 當成無條件的吞吐量調校 | 會增加 host 揮發性 page cache；未驗證 flush 與斷電 recovery 前，不能直接放進生產環境 |
| `io: native` 搭配非 direct cache | admission 可能通過，但 QEMU v9.1.0 會在執行時開啟失敗 |
| ext4 `nobarrier`／`data=writeback`／`errors=continue` | 削弱 ordering或讓錯誤後繼續寫入 |
| ext4 `noload`／XFS `norecovery` 當正常開機方式 | 刻意略過 replay，暴露未恢復的不一致狀態 |
| XFS `nouuid` 用在可寫 duplicate image | 關閉 duplicate-mount UUID protection，可能讓 clone/snapshot 被雙重寫入 |
| `unmapOptions: force`／`rbd unmap --force` | freeze queue、mark disk dead；不是診斷工具 |
| krbd `exclusive` 未經設計就套用 | 可能拒絕 peer lock handoff，阻擋 migration/failover |
| pool `size=1` 或 `min_size=1` | 儲存故障後沒有足夠的 replica 安全邊界 |
| RocksDB `disableWAL=true` | final sync transaction失去本報告依賴的 WAL sync durability |
| `objectstore_blackhole`／BlueStore omit-write／omit-kv／crash injection | 直接繞過 data 或 KV commit，只能用於開發故障注入 |

### 7.5 先補證據再決定

| 項目 | 為什麼不能直接下結論 | 下一個證據 |
|---|---|---|
| KubeVirt `SetDriverCacheMode` 後續修正 | v1.6.4 有分類 bug，但尚未證明有效的 block device 會因此選錯 cache | 查第一個納入修正的 release／backport tag；用相同 Block PVC 比較 domain XML |
| 生產環境 QEMU/libvirt | Issue 沒有釘版本，QEMU v9.1.0 只能當參考 | `virsh version`、QEMU binary version、QMP `query-block` |
| external-attacher v4.8.0 | Rook 有預設 image，但本次研究沒有納入它的原始碼 | 釘定原始碼，追 finalizer 與 force-detach retry |
| 非零 `osd_request_timeout` | 可能把無限等待變成 guest I/O error 與 filesystem shutdown | 在隔離 lab 對 partition／recovery 做 A/B 實驗 |
| `mounter: rbd-nbd`／fallback | 故障模式與 userspace process lifecycle 不同；Rook 範例仍把 healer 標成 Alpha | 另外追原始碼並做故障實驗 |
| kernel／Ceph 升級 | 目前沒有事故特徵指向某個已修 bug | 先蒐集精確的損壞訊息、dmesg、lock／watch 時間線，再做版本差異比對 |

## 8. 生產環境唯讀檢查

以下命令只讀，本次研究沒有在生產環境執行。執行前要把所有 `<...>` 換成實際名稱，不要整段直接貼上。

### 8.0 先確認實際版本

```bash
kubectl version -o json |
  jq '{client:.clientVersion.gitVersion,server:.serverVersion.gitVersion}'

kubectl get kubevirt -A -o json |
  jq '.items[] | {namespace:.metadata.namespace,
                  name:.metadata.name,
                  observed:.status.observedKubeVirtVersion,
                  target:.status.targetKubeVirtVersion}'

kubectl -n rook-ceph get deployment rook-ceph-operator -o json |
  jq '.spec.template.spec.containers[] | {name,image}'

kubectl -n rook-ceph exec <CSI_RBDPLUGIN_POD_ON_VM_NODE> -c csi-rbdplugin -- \
  uname -r
```

判讀方式：Kubernetes、KubeVirt、Rook、ceph-csi／sidecar image 與 host kernel 都要逐項對到 §1 的研究版本。只要版本不同，就先記下差異，不能直接套用本報告的精確行號。guest kernel、QEMU／libvirt 與 Ceph 版本分別在 §8.2、§8.5、§8.6 補齊。

### 8.1 先把 VM、Pod、PV 與 host node 對起來

```bash
kubectl -n <VM_NAMESPACE> get vm <VM_NAME> -o json |
  jq '.spec.template.spec.domain.devices.disks'

kubectl -n <VM_NAMESPACE> get vmi <VMI_NAME> -o json |
  jq '{node:.status.nodeName,
       disks:.spec.domain.devices.disks,
       volumes:.spec.volumes,
       volumeStatus:.status.volumeStatus}'

kubectl -n <VM_NAMESPACE> get pvc <ROOT_PVC> <DATA_PVC> \
  -o custom-columns='PVC:.metadata.name,PV:.spec.volumeName,SC:.spec.storageClassName,MODE:.spec.volumeMode,ACCESS:.spec.accessModes[*],PHASE:.status.phase'

kubectl get pv <ROOT_PV> <DATA_PV> -o json |
  jq '.items[]? // . |
      {pv:.metadata.name,
       mode:.spec.volumeMode,
       access:.spec.accessModes,
       driver:.spec.csi.driver,
       handle:.spec.csi.volumeHandle,
       attrs:.spec.csi.volumeAttributes}'
```

應該看到：系統碟與資料碟都是 `Block`、RWO，並使用核准的 RBD CSI driver。真正生效的 `mounter`／`mapOptions` 以 PV `volumeAttributes` 為準，不能拿目前的 StorageClass 猜既有 PV。

### 8.2 確認 VMI → libvirt → QEMU

```bash
POD=$(kubectl -n <VM_NAMESPACE> get pod \
  -l kubevirt.io=virt-launcher \
  --field-selector=status.phase=Running -o json |
  jq -r --arg v <VMI_NAME> \
    '.items[] | select(.metadata.annotations["kubevirt.io/domain"]==$v) | .metadata.name' |
  head -1)

kubectl -n <VM_NAMESPACE> get pod "$POD" -o json |
  jq '.spec.containers[] | select(.name=="compute") | {volumeDevices,volumeMounts}'

kubectl -n <VM_NAMESPACE> exec "$POD" -c compute -- \
  sh -c 'virsh list --name; virsh version'

DOM=$(kubectl -n <VM_NAMESPACE> exec "$POD" -c compute -- \
  virsh list --name | head -1)

kubectl -n <VM_NAMESPACE> exec "$POD" -c compute -- \
  virsh dumpxml "$DOM" |
  sed -n '/<disk /,/<\/disk>/p'

kubectl -n <VM_NAMESPACE> exec "$POD" -c compute -- \
  virsh qemu-monitor-command "$DOM" --pretty \
  '{"execute":"query-block"}'

kubectl -n <VM_NAMESPACE> exec "$POD" -c compute -- sh -c \
  'p=$(pgrep -xo qemu-kvm || pgrep -xo qemu-system-x86_64);
   tr "\0" "\n" </proc/$p/cmdline'

kubectl -n <VM_NAMESPACE> exec "$POD" -c compute -- sh -c '
  for v in /dev/<ROOT_VOLUME_NAME> /dev/<DATA_VOLUME_NAME>; do
    set -- $(stat -Lc "%t %T" "$v")
    major=$((0x$1)); minor=$((0x$2))
    printf "path=%s type=%s major:minor=%s:%s sysfs=" \
      "$v" "$(stat -Lc %F "$v")" "$major" "$minor"
    readlink -f "/sys/dev/block/${major}:${minor}"
  done'
```

應該看到：同一顆 disk 的 VMI name、domain alias／target、QMP block node 與 launcher device 能一一對上。每顆 Block PVC 都要看到 `type=block`、`source dev=...`，並記錄實際 `cache`／`io`。launcher device 的 major:minor 必須與 §8.4 的 host `rbdN` 完全相同，不能只靠 volume name 或 `/dev/rbd0` 猜。先記錄實際 QEMU／libvirt 版本，再按該版本解讀。

### 8.3 確認 RWO attach 順序與 CSI 實作

```bash
kubectl get csidriver rook-ceph.rbd.csi.ceph.com -o json |
  jq '{name:.metadata.name,attachRequired:.spec.attachRequired}'

kubectl -n rook-ceph get daemonset csi-rbdplugin -o json |
  jq '{updateStrategy:.spec.updateStrategy,
       containers:[.spec.template.spec.containers[] | {name,image,args}]}'

kubectl -n rook-ceph get deployment csi-rbdplugin-provisioner -o json |
  jq '.spec.template.spec.containers[] | {name,image,args}'

kubectl get volumeattachment -o json |
  jq -r '.items[]
    | select(.spec.attacher=="rook-ceph.rbd.csi.ceph.com")
    | [.metadata.name,
       .spec.source.persistentVolumeName,
       .spec.nodeName,
       (.status.attached|tostring),
       (.metadata.deletionTimestamp // "-"),
       ((.metadata.finalizers // [])|join(",")),
       (.status.attachError.message // "-"),
       (.status.detachError.message // "-")]
    | @tsv'
```

應該看到：`attachRequired=true`，使用中的 RWO PV 沒有兩個成功的 attachment。舊 VolumeAttachment 若仍有效，不能因為新 VolumeAttachment 或 Pod 看起來正常，就假設舊 host 已完成 fencing。`attached=true` 也不能取代 host mapping 查核。

### 8.4 確認 host krbd，避免輸出敏感連線資料

先選出 VM node 上的 RBD CSI Pod，再在該 Pod 的 privileged plugin container 讀 host state：

```bash
kubectl -n rook-ceph get pod -l app=csi-rbdplugin \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount'

kubectl -n rook-ceph exec <CSI_RBDPLUGIN_POD_ON_VM_NODE> -c csi-rbdplugin -- \
  rbd device list --format json --device-type krbd

kubectl -n rook-ceph exec <CSI_RBDPLUGIN_POD_ON_VM_NODE> -c csi-rbdplugin -- \
  sh -c 'for d in /sys/bus/rbd/devices/*; do
    [ -d "$d" ] || continue
    id=${d##*/}
    printf "id=%s pool=" "$id"; tr -d "\n" <"$d/pool"
    printf " name="; tr -d "\n" <"$d/name"
    printf " features="; tr -d "\n" <"$d/features"
    printf "\n"
  done'
```

找到對應的 `rbdN` 後，在 host 或同一 privileged container 讀 queue：

```bash
RBDDISK=rbd0
RBDDEV="/dev/${RBDDISK}"
set -- $(stat -Lc '%t %T' "$RBDDEV")
major=$((0x$1)); minor=$((0x$2))
printf 'device=%s major:minor=%s:%s sysfs=%s\n' \
  "$RBDDEV" "$major" "$minor" "$(readlink -f "/sys/dev/block/${major}:${minor}")"
cat "/sys/class/block/${RBDDISK}/queue/write_cache"
cat "/sys/class/block/${RBDDISK}/queue/fua"
cat "/sys/class/block/${RBDDISK}/queue/io_timeout"
cat "/sys/class/block/${RBDDISK}/queue/nr_requests"
```

應該看到：device identity 能對到 PV handle／image，major:minor 也與 launcher `/dev/<volume>` 相同；`write_cache=write through`、`fua=0`；single-writer image 的 watcher／lock owner 符合預期。`io_timeout=30000` 不代表 request 一定會在 30 秒後回錯。`config_info` 可能含連線或 credential 資料，不要直接貼到共用 ticket 或聊天頻道。

### 8.5 確認 guest filesystem 與 queue

```bash
MNT=/
DEV=/dev/vda1
DISK=vda

uname -r
findmnt -T "$MNT" -o TARGET,SOURCE,FSTYPE,OPTIONS
lsblk -o NAME,KNAME,TYPE,FSTYPE,MOUNTPOINTS,ROTA
readlink -f "/sys/class/block/${DISK}/device/driver"
cat "/sys/class/block/${DISK}/queue/write_cache"
cat "/sys/class/block/${DISK}/queue/fua"
cat "/sys/class/block/${DISK}/queue/io_timeout"
journalctl -k -b --no-pager |
  grep -E 'EXT4-fs|JBD2|XFS|virtio_blk|I/O error|Buffer I/O|blk_update_request'
```

ext4 再查：

```bash
sudo tune2fs -l "$DEV" |
  grep -E 'Filesystem state|Filesystem features|Default mount options|Errors behavior|Filesystem errors'
```

XFS 再查：

```bash
sudo xfs_info "$MNT"
journalctl -k -b --no-pager |
  grep -E 'XFS .*Starting recovery|XFS .*Ending recovery|needs repair|Corruption|shut down|Log I/O'
```

應該看到：driver 是 `virtio_blk`；ext4 實際 mount option 沒有 `nobarrier`、`noload`、`data=writeback`、`errors=continue`；XFS 沒有 `needs repair`、corruption 或 forced shutdown。`recovery complete`、`Starting recovery`、`Ending recovery` 本身可能只是正常的斷電後 recovery，不能單獨當成結構損壞證據。

### 8.6 確認 Ceph 當下寫入成員與持久化路徑

下列輸出留在受限的 incident bundle；`ceph health detail`、CRUSH tree、watcher／lock與硬體資訊可能含 hostname、IP、client ID、image或device識別資訊，貼到共用 ticket／chat 前必須遮蔽。設定只查 durability allowlist，不匯出全域 config。

```bash
ceph -s -f json-pretty
ceph health detail
ceph versions
ceph osd pool get <POOL> all
ceph osd crush rule dump <CRUSH_RULE>
ceph osd tree -f json-pretty
ceph pg ls-by-pool <POOL> -f json-pretty
ceph osd map <POOL> <REAL_RBD_DATA_OBJECT>
rbd info <POOL>/<IMAGE> --format json
rbd status <POOL>/<IMAGE> --format json |
  jq '{watcherCount:(.watchers | length)}'
rbd lock list <POOL>/<IMAGE> --format json
ceph osd metadata <OSD_ID> -f json |
  jq '{id,osd_objectstore,rotational,bluefs,bluefs_dedicated_db,bluefs_dedicated_wal}'

for key in objectstore_blackhole \
           bluestore_debug_omit_block_device_write \
           bluestore_debug_omit_kv_commit \
           bdev_inject_crash \
           bluestore_rocksdb_options \
           bluestore_rocksdb_options_annex; do
  ceph config show-with-defaults osd.<OSD_ID> "$key"
done
```

應該看到：相關 PG 是 `active+clean`，沒有 `undersized`、`degraded`、`inconsistent`；`size`／`min_size` 符合核准政策；實際 RBD data object 的 acting OSD 數量與 host failure domain 符合預期；穩定狀態只有預期的 writer／lock owner；OSD objectstore 是 BlueStore。

另外確認以下安全值：

```text
objectstore_blackhole = false
bluestore_debug_omit_block_device_write = false
bluestore_debug_omit_kv_commit = false
bdev_inject_crash = 0
```

`bluestore_rocksdb_options` 與 annex 不得包含 `disableWAL=true`。這些檢查只能證明軟體路徑沒有被 debug／custom option 繞過；儲存硬體還要查：

```bash
lsblk -o NAME,KNAME,TYPE,MODEL,ROTA,FSTYPE,MOUNTPOINTS
sudo nvme id-ctrl -H /dev/<NVME_CONTROLLER> |
  grep -E 'vid|ssvid|mn |fr |vwc|Volatile Write Cache'
sudo nvme smart-log /dev/<NVME_CONTROLLER>
sudo smartctl -x /dev/<DEVICE> |
  grep -E 'Device Model|Model Number|Firmware Version|Write Cache|Power_Loss|Unsafe_Shutdowns'
```

這些資訊能盤點 write cache、device identity、firmware 與錯誤狀態，但不能取代供應商的 PLP 證明或非生產環境的斷電實驗。

### 8.7 事故發生時至少要保存什麼

執行 repair 前，先保存以下唯讀證據：

1. VM/VMI/PVC/PV/VolumeAttachment JSON與事件時間線。
2. virt-launcher domain XML、QMP `query-block`、QEMU/libvirt version。
3. 新舊 node 的 RBD mapping、watcher／lock owner 與 kernel log。
4. guest 前一次 boot 與本次 boot 的 kernel log，以及 ext4／XFS mount 失敗原文。
5. 在既有、已隔離的 image snapshot／clone 上執行 `fsck -n` 或 `xfs_repair -n` 的輸出。若尚無副本，建立 snapshot／clone 是另一項需要授權的生產變更；不要先對唯一副本執行寫入式 repair。
6. Ceph health detail、OSD slow／error log、blocklist 與 image status；時間要與斷電、fencing、新 VMI 啟動對齊。

## 9. 原始碼證據 ledger

這裡保留完整代號，方便回查。路徑都是 upstream repository 的相對路徑，版本本身也是證據的一部分。`source-proven` 只代表原始碼能直接支持該列結論，不能跨過「限制」欄繼續延伸。

### 9.1 ext4、XFS、block layer、virtio與 krbd

| ID | 結論 | 元件／版本 | 原始碼位置 | 直接支持 | 限制 | 證據等級 |
|---|---|---|---|---|---|---|
| L-01 | ext4 default barrier on | Linux 6.8.0-52 | `fs/ext4/super.c:4358-4402` `ext4_set_def_opts` | mount初始化會設 barrier，除非 on-disk default覆寫 | effective mount仍可被 option覆寫 | source-proven |
| L-02 | ext4 default通常是 `data=ordered` | Linux 6.8.0-52 | `fs/ext4/super.c:4933-4956` | journal有 revoke且未明示 mode時選 ordered | journal capability不同可能選 journal | source-proven |
| L-03 | ext4 `fsync` 等 data與journal commit，必要時補 device flush | Linux 6.8.0-52 | `fs/ext4/fsync.c:97-180` | 明確 durability operation的 kernel path | 不涵蓋 application未呼叫 `fsync` 的 write | source-proven |
| L-04 | JBD2 commit使用 PREFLUSH/FUA | Linux 6.8.0-52 | `fs/jbd2/commit.c:146-156,777-785,881-896` | journal commit ordering與外部data device flush | 下層必須誠實履行 | source-proven |
| L-05 | ext4正常 crash recovery 是 scan/revoke/replay | Linux 6.8.0-52 | `fs/jbd2/recovery.c:300-341` | dirty mount正常 replay流程 | 只 replay有效 journal transaction | source-proven |
| L-06 | ext4 structural error與 replay不同 | Linux 6.8.0-52 | `fs/ext4/super.c:4638-4643,4890-4894,5480-5484` | checksum、group descriptor、root inode錯誤回 corruption code | 不直接告訴 incident 根因 | source-proven |
| L-07 | dirty ext4不能以 rw `noload`／`norecovery` 服務 | Linux 6.8.0-52 | `fs/ext4/super.c:5358-5381`; `Documentation/admin-guide/ext4.rst:144-170` | rw mount拒絕；ro只適合鑑識 | 不等於 repair方法 | source-proven |
| L-08 | ext4 journal預設主要保護 metadata；writeback更弱 | Linux 6.8.0-52 | `Documentation/filesystems/ext4/journal.rst:6-35` | data modes的crash contract | bundled docs，不取代 application contract | documentation-supported |
| L-09 | XFS `fsync` 等 data並同步 force log | Linux 6.8.0-52 | `fs/xfs/xfs_file.c:101-198` | file data與inode log ordering | 只涵蓋 fsync範圍 | source-proven |
| L-10 | XFS同步 log I/O送 PREFLUSH/FUA | Linux 6.8.0-52 | `fs/xfs/xfs_log.c:1899-1933,3180-3248` | stable log force如何下到 block layer | backend必須履約 | source-proven |
| L-11 | XFS沒有 `barrier`／`nobarrier` 旋鈕 | Linux 6.8.0-52 | `Documentation/admin-guide/xfs.rst:249-261`; `fs/xfs/xfs_super.c:98-150` | option已移除且 parser無欄位 | 不能用舊版說明下建議 | source-proven |
| L-12 | XFS dirty log做兩階段 recovery | Linux 6.8.0-52 | `fs/xfs/xfs_log_recover.c:3235-3303,3384-3515` | normal replay path與finish | 只 replay committed record | source-proven |
| L-13 | XFS `needsrepair` 明確拒絕 mount | Linux 6.8.0-52 | `fs/xfs/xfs_super.c:1609-1613` | repair-required state回 `EFSCORRUPTED` | 不指向特定下層原因 | source-proven |
| L-14 | XFS `norecovery` 必須 ro且可能不一致 | Linux 6.8.0-52 | `fs/xfs/xfs_super.c:1397-1405`; `Documentation/admin-guide/xfs.rst:152-164` | 跳過 log recovery的限制 | 只適合 offline鑑識 | source-proven |
| L-15 | guest block layer會把無native FUA的FUA改成post-flush | Linux 6.8.0-52 | `block/blk-flush.c:1-33,103-117,397-460` | flush sequence state machine | 取決於queue advertise的WC/FUA | source-proven |
| L-16 | virtio-blk advertise FLUSH/WCE但queue FUA=false | Linux 6.8.0-52 | `drivers/block/virtio_blk.c:1078-1103,1349-1351,1632-1646` | guest queue capability | backend runtime feature negotiation仍要查 | source-proven |
| L-17 | guest FLUSH變成 `VIRTIO_BLK_T_FLUSH` | Linux 6.8.0-52 | `drivers/block/virtio_blk.c:239-265,427-463` | wire command建立與送出 | QEMU後續行為不在此tree | source-proven |
| L-18 | krbd不接受 block `REQ_OP_FLUSH` | Linux 6.8.0-52 | `drivers/block/rbd.c:4774-4797` | rbd queue只處理read/write/discard/zeroout | 要連同write-through contract解讀 | source-proven |
| L-19 | krbd queue未advertise WC/FUA | Linux 6.8.0-52 | `drivers/block/rbd.c:4945-5004`; `block/blk-core.c:397-448` | queue init沒有write-cache設定 | absence inference；runtime sysfs必查 | inference |
| L-20 | libceph每筆request要求ONDISK且等ONDISK reply | Linux 6.8.0-52 | `net/ceph/osd_client.c:2491-2500,3856-3887` | krbd write-through completion條件 | 還要Ceph server與media履約 | source-proven |
| L-21 | normal force-unmap對open device回EBUSY，force會mark dead | Linux 6.8.0-52 | `drivers/block/rbd.c:7238-7305` | unmap safety與force副作用 | 不涵蓋CSI呼叫時機 | source-proven |
| L-22 | exclusive-lock image寫入前須持lock | Linux 6.8.0-52 | `drivers/block/rbd.c:3417-3548` | krbd lock gate | lock不是hardware fencing | source-proven |
| L-23 | `exclusive` map option會拒絕peer release | Linux 6.8.0-52 | `drivers/block/rbd.c:4320-4364` | peer handoff回EROFS路徑 | 是否適合現場需migration設計 | source-proven |
| L-24 | rbd generic `io_timeout`不abort request | Linux 6.8.0-52 | `drivers/block/rbd.c:4945-4947`; `block/blk-mq.c:1557-1570` | rbd沒有timeout handler，timer重設 | 不代表所有I/O永不錯 | source-proven |
| L-25 | `osd_request_timeout=0` 是無限 | Linux 6.8.0-52 | `include/linux/ceph/libceph.h:72-79`; `net/ceph/osd_client.c:3440-3515` | nonzero才會ETIMEDOUT | timeout對filesystem影響需實驗 | source-proven |
| L-26 | source changelog列入兩個RBD exclusive mapping修正 | Linux 6.8.0-52 | `debian/changelog:2303,2316-2317`; `drivers/block/rbd.c:4337-4358` | 這份Ubuntu source已含state-aware lock code | 不證明incident是同一個bug | source-proven |
| L-27 | source changelog列入XFS legacy recovery與ext4 fast-commit修正 | Linux 6.8.0-52 | `debian/changelog:1594,2044` | package maintainer記錄fix已納入 | 缺upstream commit與incident signature，不作causal attribution | documentation-supported |

### 9.2 KubeVirt、QEMU 參考版本與 virt-launcher

| ID | 結論 | 元件／版本 | 原始碼位置 | 直接支持 | 限制 | 證據等級 |
|---|---|---|---|---|---|---|
| K-01 | Block PVC進launcher `/dev/<volume>` | KubeVirt v1.6.4 | `pkg/virt-controller/services/rendervolumes.go:564-590` | compute container使用VolumeDevice | 不證明backend是krbd | source-proven |
| K-02 | virt-launcher runtime確認block device | KubeVirt v1.6.4 | `pkg/virt-launcher/virtwrap/manager.go:999-1019,1671-1694` | `os.Stat`與block map | 現場path需runtime查 | source-proven |
| K-03 | converter產生block/raw/source dev | KubeVirt v1.6.4 | `pkg/virt-launcher/virtwrap/converter/converter.go:658-694,721-730` | domain disk source形狀 | libvirt後續轉換未釘 | source-proven |
| K-04 | root/data共用per-disk conversion | KubeVirt v1.6.4 | `pkg/virt-launcher/virtwrap/converter/converter.go:130-215,1625-1671` | 所有disk同迴圈；boot只是order欄位 | 個別spec仍可能不同 | source-proven |
| K-05 | amd64 bus omitted default是SATA | KubeVirt v1.6.4 | `pkg/defaults/amd64.go:22-46`; `staging/src/kubevirt.io/api/core/v1/defaults.go:69-74,101-120` | target/bus defaulting | Preference或其他mutation可改effective值 | source-proven |
| K-06 | omitted cache依O_DIRECT選none或writethrough | KubeVirt v1.6.4 | `pkg/virt-launcher/virtwrap/converter/converter.go:254-285,370-430` | preStart cache決策 | productionbackend要runtime驗證 | source-proven |
| K-07 | omitted io只在none+block/preallocated選native | KubeVirt v1.6.4 | `pkg/virt-launcher/virtwrap/converter/converter.go:433-471` | io決策條件 | 保持省略時QEMU/libvirt default未知 | source-proven |
| K-08 | cache/io在preStart才套到所有disk | KubeVirt v1.6.4 | `pkg/virt-launcher/virtwrap/manager.go:848-855,1143-1173,1373-1406` | 動態effective XML生成時機 | 未讀production XML | source-proven |
| K-09 | cache/io值分開admission validation | KubeVirt v1.6.4 | `pkg/virt-api/webhooks/validating-webhook/admitters/vmi-create-admitter.go:2140-2161` | API允許的enum | 不驗證所有cache/io組合可runtime開啟 | source-proven |
| K-10 | IOThreads與`io: threads`不是同一概念 | KubeVirt v1.6.4 | `staging/src/kubevirt.io/api/core/v1/schema.go:210-217,699-715`; `pkg/virt-launcher/virtwrap/converter/converter.go:1306-1410` | policy/dedicated placement獨立於AIO backend | 效能效果需實驗 | source-proven |
| K-11 | QEMU cache=none是writeback on/direct on/no-flush off | QEMU v9.1.0 reference | `qemu-options.hx:1575-1594` | reference cache matrix | production version未知 | reference-source-proven |
| K-12 | write-cache off會用FUA，必要時flush模擬 | QEMU v9.1.0 reference | `block/block-backend.c:1392-1427`; `block/io.c:1042-1115` | writethrough semantics | production version未知 | reference-source-proven |
| K-13 | virtio FLUSH進QEMU block flush；NO_FLUSH才跳過 | QEMU v9.1.0 reference | `hw/block/virtio-blk.c:342-356,795-880`; `block/io.c:2975-3052` | reference guest flush處理 | production version未知 | reference-source-proven |
| K-14 | native AIO要求direct I/O | QEMU v9.1.0 reference | `block/file-posix.c:619-641,714-732` | 不相容組合會open fail | libvirt可能先拒絕或轉換 | reference-source-proven |
| K-15 | v1.6.4 block分類branch有regression | KubeVirt v1.6.4 | `pkg/virt-launcher/virtwrap/converter/converter.go:254-285,370-394` | Source.Dev後仍走CheckFile | valid existing device未證明選錯cache | source-proven |
| K-16 | upstream main修正block backend分類 | KubeVirt upstream commit | [`d7c683cde613869fda86e333957976b6bba8faa6`](https://github.com/kubevirt/kubevirt/commit/d7c683cde613869fda86e333957976b6bba8faa6), `pkg/virt-launcher/virtwrap/converter/converter.go` | 改用resolved backend與`BackendIsBlock()`，新增block-device test | first release／backport未知，不可直接建議升級到某版 | upstream-commit-proven |

### 9.3 Kubernetes、ceph-csi、Rook與 registrar

| ID | 結論 | 元件／版本 | 原始碼位置 | 直接支持 | 限制 | 證據等級 |
|---|---|---|---|---|---|---|
| C-01 | Rook defaults pin CSI v3.14、registrar v2.13、attacher v4.8 | Rook v1.17.2 | `pkg/operator/ceph/csi/spec.go:129-141` | source image defaults | runtime ConfigMap可覆寫 | source-proven |
| C-02 | RBD attachRequired default true | Rook v1.17.2 | `pkg/operator/ceph/csi/csi.go:299-305`; `pkg/operator/ceph/csi/csidriver.go:35-60` | generated CSIDriver值 | runtime object才是現場事實 | source-proven |
| C-03 | 關RWO attach有data-corruption warning | Rook v1.17.2 | `deploy/examples/operator.yaml:526-535` | upstream operator警告 | 說明中的警告不能單獨證明機制 | documentation-supported |
| C-04 | registrar只有socket registration mounts/args | Rook v1.17.2 | `pkg/operator/ceph/csi/template/rbd/csi-rbdplugin.yaml:35-60` | generated sidecar responsibility | runtime pod可覆寫 | source-proven |
| C-05 | 真正host access在csi-rbdplugin | Rook v1.17.2 | `pkg/operator/ceph/csi/template/rbd/csi-rbdplugin.yaml:61-124` | `/dev`,`/sys`,`/lib/modules`, kubelet mounts | 不證明每次map成功 | source-proven |
| C-06 | ControllerPublish/Unpublish是NOOP | ceph-csi v3.14.0 | `internal/rbd/controllerserver.go:1672-1702` | controller attach不map/unmap | Kubernetes仍用VA sequencing | source-proven |
| C-07 | dynamic RBD default mounter是krbd | ceph-csi v3.14.0 | `internal/rbd/nodeserver.go:211-215`; `internal/rbd/rbd_util.go:48-55` | omitted mounter default | static/migration volume另查 | source-proven |
| C-08 | mapOptions從VolumeContext解析並傳rbd map | ceph-csi v3.14.0 | `internal/rbd/rbd_attach.go:278-338,395-405,435-485` | option進krbd command | kernel是否接受仍要runtime驗證 | source-proven |
| C-09 | NodeStage才map與建立staging bind | ceph-csi v3.14.0 | `internal/rbd/nodeserver.go:309-470,756-856` | true host attach path | dead node無法執行RPC | source-proven |
| C-10 | NodePublish只做staging到Pod bind | ceph-csi v3.14.0 | `internal/rbd/nodeserver.go:701-753,859-875` | raw block target建立 | 不增加durability | source-proven |
| C-11 | NodeUnpublish不unmap；Unstage才unmap | ceph-csi v3.14.0 | `internal/rbd/nodeserver.go:923-1091`; `internal/rbd/rbd_attach.go:556-617` | normal teardown boundaries | dead node路徑不成立 | source-proven |
| C-12 | RWO map前做watcher in-use check | ceph-csi v3.14.0 | `internal/rbd/rbd_util.go:550-595`; `internal/rbd/rbd_attach.go:341-365,514-535` | 仍使用時map失敗 | watcher不是fencing | source-proven |
| C-13 | K8s Block lifecycle是Stage→Publish→Unpublish→Unstage | Kubernetes v1.31.6 | `pkg/volume/csi/csi_block.go:180-204,253-277,401-526` | generic block order | external sidecar不在此source | source-proven |
| C-14 | Detach刪VA並等消失 | Kubernetes v1.31.6 | `pkg/volume/csi/csi_attacher.go:426-491` | control-plane detach語意 | finalizer實作需attacher source | source-proven |
| C-15 | force-detach max wait是6分鐘 | Kubernetes v1.31.6 | `pkg/controller/volume/attachdetach/attach_detach_controller.go:66-97` | fixed timer config | 不是從node crash起算或完整RTO | source-proven |
| C-16 | timer開始與略過mounted safety有額外條件 | Kubernetes v1.31.6 | `pkg/controller/volume/attachdetach/reconciler/reconciler.go:165-287` | desired-state與unhealthy/out-of-service條件 | fencing仍是外部前提 | source-proven |
| C-17 | 舊attachment存在會擋新node attach | Kubernetes v1.31.6 | `pkg/controller/volume/attachdetach/reconciler/reconciler.go:315-359` | logical multi-attach guard | logical detach不等於host unmap | source-proven |
| C-18 | 既有PV CSI source/attributes immutable | Kubernetes v1.31.6 | `pkg/apis/core/validation/validation.go:2102-2119` | 改SC不改舊PV | 新PV仍會讀新SC | source-proven |
| C-19 | registrar只回GetInfo/registration status | registrar v2.13.0 | `cmd/csi-node-driver-registrar/main.go:75-115,168-193`; `cmd/csi-node-driver-registrar/node_register.go:38-90` | plugin registration scope | 不涵蓋kubelet後續註冊 | source-proven |
| C-20 | registrar不需Kubernetes RBAC | registrar v2.13.0 | `README.md:69-81` | 不碰Kubernetes API | README與source responsibility一致 | documentation-supported |

### 9.4 Ceph RBD／OSD／BlueStore

| ID | 結論 | 元件／版本 | 原始碼位置 | 直接支持 | 限制 | 證據等級 |
|---|---|---|---|---|---|---|
| O-01 | source版本是19.2.2 | Ceph v19.2.2 | `CMakeLists.txt:3-5` | project version字串 | commit由tag export外部釘定 | source-proven |
| O-02 | protocol定義ACK/ONDISK want/is flags | Ceph v19.2.2 | `src/include/rados.h:447-455`; `src/messages/MOSDOpReply.h:51-57,143-153` | request/reply flag語意 | flag名不證明硬體NAND | source-proven |
| O-03 | primary mutation送current acting set並要求ONDISK | Ceph v19.2.2 | `src/osd/ReplicatedBackend.cc:950-973,1021-1058` | replica request與participants | acting set可因degraded改變 | source-proven |
| O-04 | commit wait set初始化為完整acting_recovery_backfill | Ceph v19.2.2 | `src/osd/ReplicatedBackend.cc:498-526` | all-current-participants gate | 不是pool target size的永恆保證 | source-proven |
| O-05 | primary local commit移除primary，set空才完成 | Ceph v19.2.2 | `src/osd/ReplicatedBackend.cc:531-574` | local ObjectStore on_commit gate | hardware honesty另計 | source-proven |
| O-06 | replica只在local commit後回ONDISK | Ceph v19.2.2 | `src/osd/ReplicatedBackend.cc:607-629,1153-1189` | replica on_commit與reply順序 | replica可能不在degraded set | source-proven |
| O-07 | all committed後才reply client ACK/ONDISK | Ceph v19.2.2 | `src/osd/PrimaryLogPG.cc:11285-11348,11372-11416,4300-4315` | client callback gate | client斷線前後有ambiguous completion | source-proven |
| O-08 | min_size只決定acting set可否write | Ceph v19.2.2 | `src/osd/PeeringState.h:2356-2364`; `src/osd/osd_types.h:1450-1454` | writeability gate | stretch constraint另有條件 | source-proven |
| O-09 | default size3的min_size公式得2 | Ceph v19.2.2 | `src/common/config.h:352-356` | compiled default formula | production pool可能覆寫 | source-proven |
| O-10 | non-deferred data用block device AIO | Ceph v19.2.2 | `src/os/bluestore/BlueStore.cc:16705-16729` | data write submission | AIO complete不等於final sync | source-proven |
| O-11 | data AIO完成後才進KV與finishing states | Ceph v19.2.2 | `src/os/bluestore/BlueStore.cc:13769-13864` | transaction state order | state machine仍依backend成功 | source-proven |
| O-12 | deferred payload先存RocksDB key | Ceph v19.2.2 | `src/os/bluestore/BlueStore.cc:15103-15135` | crash-replay payload path | ONDISK不一定final extent已materialize | source-proven |
| O-13 | KV sync前必要時flush data device | Ceph v19.2.2 | `src/os/bluestore/BlueStore.cc:14472-14508` | unstable I/O與bdev flush gate | controller/device需誠實 | source-proven |
| O-14 | stable deferred key才移除並同步KV | Ceph v19.2.2 | `src/os/bluestore/BlueStore.cc:14560-14576,14676-14718` | replay record lifecycle與sync commit | 不代表physical location不會變 | source-proven |
| O-15 | KV_DONE後才queue on_commit | Ceph v19.2.2 | `src/os/bluestore/BlueStore.cc:14077-14089` | BlueStore commit連到OSD ONDISK | hardware boundary仍在下層 | source-proven |
| O-16 | RocksDB final sync在WAL啟用時sync=true | Ceph v19.2.2 | `src/kv/RocksDBStore.cc:1587-1613`; `src/kv/RocksDBStore.h:240-254` | sync option與disableWAL default false | custom option可破壞 | source-proven |
| O-17 | BlueFS Sync進fsync並flush dirty bdev | Ceph v19.2.2 | `src/os/bluestore/BlueRocksEnv.cc:239-246`; `src/os/bluestore/BlueFS.cc:3759-3823` | WAL/metadata log stable path | 僅BlueFS-backed RocksDB | source-proven |
| O-18 | KernelDevice flush以fdatasync實作 | Ceph v19.2.2 | `src/blk/kernel/KernelDevice.cc:462-502,634-640` | software stable boundary | 不能保證RAID/NVMe誠實 | source-proven/inference |
| O-19 | exclusive-lock/object-map/journaling是single-client features | Ceph v19.2.2 | `src/include/rbd/features.h:20-24,84-90` | feature分類與default | 分類不等於persistent-media guarantee | source-proven |
| O-20 | object-map invalid時回退為object可能存在 | Ceph v19.2.2 | `src/librbd/ObjectMap.cc:84-106` | query optimization語意 | userspace librbd path | source-proven |
| O-21 | librbd journaling有獨立feature與write path | Ceph v19.2.2 | `src/librbd/Journal.cc:386-391,903-943,1281-1311`; `src/librbd/io/ImageRequest.cc:423-483` | userspace journal/replay | production krbd不走此class | source-proven |
| O-22 | disableWAL會讓final sync不能設sync | Ceph v19.2.2 | `src/kv/RocksDBStore.cc:1540-1557,1605-1606`; `src/kv/RocksDBStore.h:240-254` | unsafe custom option後果 | production config需查 | source-proven |
| O-23 | omit-kv與omit-block-write會繞過commit | Ceph v19.2.2 | `src/os/bluestore/BlueStore.cc:14044,14575,14871,16706` | debug bypass的實際branch | 僅在非default配置 | source-proven |
| O-24 | blackhole/crash injection會丟I/O或注入crash | Ceph v19.2.2 | `src/blk/kernel/KernelDevice.cc:482-487,1017-1047,1064-1066` | debug failure path | 僅在非default配置 | source-proven |

## 10. 已知 bug 與版本缺口

### 10.1 已經確認的事

1. **KubeVirt v1.6.4 的 cache backend 分類有 bug。** `SetDriverCacheMode` 遇到 `Source.Dev` 仍會走 `CheckFile`。upstream main 的 commit `d7c683cde613869fda86e333957976b6bba8faa6` 已改用 `BackendIsBlock()`。但目前不知道第一個納入修正的正式版本，也沒有證據顯示這個 bug 造成了本次損壞。
2. **Ubuntu kernel 原始碼已包含兩個 RBD exclusive mapping 修正。** changelog 提到「don't assume lock owner／LOCKED state」，目前的 state-aware code 位於 `drivers/block/rbd.c:4337-4358`。這只能證明修正已經存在，不能反推本次事故就是同一個 bug。
3. **同一份 kernel changelog 還有 XFS legacy recovery allocation 與 ext4 fast-commit replay 修正。** 目前缺少事故特徵、對應的 upstream commit 與可重現案例，因此不能拿它們當成升級理由。

### 10.2 還不能說哪個版本已經修好

- 生產環境的 QEMU／libvirt 版本未知，不能用 QEMU v9.1.0 的參考原始碼替現場下結論。
- 本次沒有納入 external-attacher v4.8.0 原始碼，不能從 Kubernetes API type 反推 finalizer 字串、加入／移除時機與 retry 細節。
- 尚未比較 Ceph v19.2.2 與後續 Squid patch release 的持久化路徑差異。
- 尚未取得生產事故的精確損壞特徵，不能把「升級 kernel／Ceph」列成無條件解法。

要把升級列為必要措施，至少要串起四段證據：事故的錯誤訊息、stack 或 on-disk 特徵 → 對應的 upstream issue／commit → 第一個修正版或 backport → 在相同路徑完成驗證。

## 11. 這份報告還不能回答什麼

即使 §7.1 全部符合，以下風險仍不能靠調一個參數消除：

1. 應用程式沒有正確使用 `fsync`／WAL protocol，或沒有處理「送出成功但回覆遺失」這種不確定狀態。
2. 生產環境的 QEMU／libvirt block graph 與 KubeVirt 預期不同，或被 sidecar／hook 改寫 domain。
3. device firmware、RAID controller、hypervisor 或 NVMe write cache 提早回覆 flush completion，而且沒有 PLP／BBU。
4. 未完成 fencing 的 node 在 partition 恢復後重新取得網路與寫入能力；exclusive-lock、watch、blocklist 交接本身有時間窗。
5. kernel、QEMU、libvirt 或 Ceph 仍有未知 bug。原始碼追查能說明正常約定，不能證明實作完全沒有缺陷。
6. PG degraded 時，`min_size` 仍允許寫入；此時成功寫入的 replica 數可能低於目標 `size`。
7. repair 工具先寫回唯一 image，卻沒有 snapshot，導致後續無法鑑識根因。

還缺以下現場證據：

- guest 與 host 是否真的都使用 Ubuntu kernel 6.8.0-52.53。
- 系統碟與每顆資料碟實際的 bus／cache／io、QEMU／libvirt 版本與 block graph。
- host backend 是否全為 krbd，有沒有 volume 走 rbd-nbd 或 userspace librbd。
- 事故當下舊 node 是否確實完成 fencing，以及新舊 node 的 VolumeAttachment、watcher、lock、blocklist 時間線。
- pool `size`／`min_size`、CRUSH failure domain、實際 acting set、OSD store layout 與 media cache／PLP。
- ext4／XFS 實際 mount option、需要 repair 的精確訊息，以及離線唯讀 checker 輸出。
- 應用程式是否對聲稱已提交的資料使用正確的持久化 API。

## 12. 建議執行順序

以下命令與查核都是唯讀。snapshot／clone、設定變更與重新啟動都要另外核准，不在本次執行範圍內。

1. **先核對 restart 條件**：確認 HA 流程一定先收到 hardware fencing 成功，再建立新的 VMI。若流程不符合，另開變更工作；本報告不會替現場修改或凍結生產流程。
2. **匯出現況**：保存 VM、VMI、PVC、PV、StorageClass、CSIDriver、VolumeAttachment 與 Rook CSI workload JSON。
3. **逐顆對盤**：從 VMI name 一路對到 domain XML、QMP block node、launcher `/dev/<volume>`、host `rbdN` 與 RBD image；系統碟和每顆資料碟都要查。
4. **查實際 cache**：記錄生產環境的 QEMU／libvirt 版本；確認 Block PVC 沒有意外使用 host page cache 的 writeback，或任何 unsafe／no-flush 語意。
5. **查 guest recovery 約定**：ext4 保留 barrier、ordered、remount-ro；XFS 不使用 `norecovery`；保存本次與前次 boot 的 kernel log。
6. **查 single-writer**：`attachRequired=true`；使用中的 RWO PV 沒有第二個成功的 VolumeAttachment；新舊 node 的 watcher、lock、mapping 與 fencing 時間線一致。
7. **查 krbd**：host queue 是 `write through,fua=0`，device identity 能對到 image；不要把通用的 `io_timeout` 當成中止 request 的保證。
8. **查 Ceph 當下寫入成員**：pool policy、PG state、acting OSD 與 CRUSH failure domain 符合核准值，持久化除錯 bypass 全部關閉。
9. **查實體儲存界線**：保存 OSD device 型號、firmware、controller cache 與 PLP／BBU 證明。缺少證據就列為風險，不能用 `HEALTH_OK` 帶過。
10. **保存損壞證據**：優先在事前 snapshot 或已隔離 clone 上跑唯讀 checker。若沒有副本，先取得建立 snapshot／clone 的變更授權。保留原始錯誤與時間關係，再決定是否 repair。
11. **只修已證明的缺口**：例如實際 cache 與預期不符、不安全的 mount option、`attachRequired` 錯誤、pool policy 或硬體不符合。每項變更都要能獨立回退。
12. **其他項目先進 lab**：QEMU mode、timeout、`min_size=size`、kernel／Ceph 升級、rbd-nbd 都要先做可回退且事前寫明預期結果的實驗，不要直接在生產環境嘗試。

## 13. 最後判斷

沒有任何單一參數可以保證 ext4／XFS 不再損壞。生產流程真正不能退讓的只有兩件事：

1. fencing 完成前，絕不能讓第二個 writer 啟動。
2. guest 的持久化操作必須保留 flush／FUA 語意，一路走到 Ceph 對當下所有 acting OSD 完成 ONDISK commit。

目前仍缺三塊關鍵證據：生產環境實際的 QEMU／libvirt block graph；事故當下新舊 node 的 mapping、watcher、lock 與 fencing 時間線；OSD media 是否真的履行 flush，或具備 PLP。

這三塊補齊前，不能把需要 repair 的 ext4／XFS 損壞說成「正常斷電」，也不能把 timeout、CSI sidecar 或效能調校包裝成修復。下一步是完成 §8 的唯讀檢查，找出寫入路徑在哪一層失去保證，再把需要變更的項目帶到隔離 lab 驗證。
