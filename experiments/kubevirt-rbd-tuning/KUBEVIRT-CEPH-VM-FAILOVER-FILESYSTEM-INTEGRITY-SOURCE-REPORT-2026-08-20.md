# KubeVirt／Ceph VM 斷電 failover：filesystem 完整性 source-first production 決策報告

> 研究日期：2026-08-20
> 決策依據：[GitHub Issue #32](https://github.com/tom19960222/learning-k8s/issues/32)；完整性優先，fencing 確認完成前不得在其他 node 重啟 VM
> 交付性質：指定版本 source review；未讀取 production、未執行故障實驗，也不把既有舊版本 Lab 當成這套環境的證據

## 兩分鐘決策摘要

**結論：在 single writer、flush contract 正常、storage hardware 誠實履約且沒有未知 defect 的前提下，這套 source contract 應把 compute-only worker 突然斷電收斂成 guest filesystem 的正常 journal／log recovery，而不是需要 `fsck` 或 `xfs_repair` 的 structural corruption。既然 production 已看到後者，就不能把它當成「斷電本來就會這樣」，也不能靠盲調 timeout 或 CSI sidecar 解決。先阻止多 writer，再逐層證明 effective cache、flush 與 krbd mapping，才有資格談 failover。**

生產處置順序如下：

1. **先守住 fencing-before-restart。** 舊 node 的寫入能力沒有被硬體 fencing 排除前，不得建立新 node 上的 writer。Kubernetes force-detach 與 `VolumeAttachment` 刪除只是 control-plane sequencing，不是 host fencing；ceph-csi 的 `ControllerUnpublishVolume` 在 v3.14.0 甚至是 NOOP。
2. **保留 RWO attach serialization。** `CSIDriver.spec.attachRequired` 必須是 `true`；不得為了縮短 RTO 關掉。Rook v1.17.2 的 source default 也是 `true`，而且明確警告 RWO RBD 關掉後可能造成 data corruption。
3. **查 effective disk，不接受「YAML 看起來對」。** 對每顆 root/data disk，把 VMI effective spec、libvirt domain XML、QEMU block graph/cmdline、launcher `/dev/<volume>`、host `/sys/bus/rbd/devices/*` 串成同一顆 disk。KubeVirt v1.6.4 的 `cache`／`io` 留空會在啟動前動態決定，不是固定 YAML default。
4. **完整性優先的 Block PVC 目標是不用 host page cache。** 對可 O_DIRECT 的 block backend，KubeVirt 省略 `cache`／`io` 時預期會產生 `cache=none, io=native`；這是 source 決策邏輯，production 仍須以 XML/QMP 證明。不要主動改成 `writeback`；它雖不等於忽略 flush，卻增加一層 node 斷電會失去的 host page cache，沒有必要先承擔這個變因。
5. **不要關 filesystem recovery 保護。** ext4 保持 barrier 與 `data=ordered` 預設；XFS 這版已沒有可用的 `nobarrier`。不得以 ext4 `noload`／`norecovery` 或 XFS `norecovery` 逃避 journal/log recovery；它們不是修復 corruption 的參數。
6. **不要把 timeout 當 durability。** Kubernetes 的 6 分鐘 force-detach、ceph-csi watcher retry、krbd `osd_request_timeout` 都只改變失敗多久才顯現或 orchestration 何時繼續。它們不讓已 acknowledgement 的 write 更 durable。
7. **先做唯讀稽核，再決定升級或實驗。** production QEMU/libvirt 版本、external-attacher v4.8.0 finalizer 實作、現場 RBD image features、OSD media write-cache contract 都不在目前 pinned source 組合內；未補證據前不得宣稱「改某個參數就能根治」。

### 現在不要做的事

- 不要在 fencing 未確認完成前 force-delete 舊 VMI／Pod、加 out-of-service taint，然後在新 node 重開。
- 不要把 `CSI_RBD_ATTACH_REQUIRED=false` 當 failover 加速。
- 不要把 registrar、CSI liveness、leader-election 或 attach/detach timeout 當 filesystem 完整性參數。
- 不要把 `cache=none` 說成「guest 沒有 write cache」；QEMU 的 `none` 是 direct I/O 且仍保留 flush，語意不是 no-cache/no-flush。
- 不要把 `cache=writeback` 直接定罪成這次 corruption 的已證實根因；source 只能證明它增加 volatile host cache，因果仍需 effective-state 證據與可回退實驗。
- 不要把 application 沒有送出 `fsync`／等價 durability operation 所造成的資料遺失，誤判成 filesystem metadata structural corruption。

## 1. 問題、判定標準與版本釘定

### 1.1 要回答的問題

本報告只回答四件事：

1. guest acknowledgement 之後，一次需要 durability 的 write／flush 要穿過哪些層，哪裡才是 Ceph 的持久化邊界？
2. ext4／XFS 正常 crash recovery 與 repair-required structural corruption 如何區分？
3. 哪些設定真的改變 durability 或多 writer 風險，哪些只改 RTO、效能或可觀測性？
4. 不改 production 的前提下，如何把 default、configured 與 effective runtime 拆開查清楚？

### 1.2 Failure model

- 突然斷電的是只承載 compute workload 的 worker；Ceph MON／OSD 持續可用。
- VM root disk 與 data disk 都是 Ceph RBD、host krbd、PVC `volumeMode: Block`。
- ext4 與 XFS 都在範圍內。
- 問題是 filesystem 無法 mount、必須 `fsck`／`xfs_repair` 的 structural corruption；正常 journal／log replay 不算 failure。
- 完整性高於 RTO。硬體 fencing 已存在，但本報告不設計 fencing，只把「確認來源 node 已失去寫入能力」當重啟前置條件。
- 不研究 application-specific transaction consistency；application 若沒有發出 durability operation，下層不能替它創造保證。

### 1.3 Source baseline

| 元件 | 指定版本／commit | 本報告中的角色 |
|---|---|---|
| KubeVirt | v1.6.4 / `ac5324e8f6e7cda1cfe92542df3ceb0cd0d8e68f` | Disk API、defaulting、Block PVC、domain XML |
| Kubernetes | v1.31.6 / `6b3560758b37680cb713dfc71da03c04cadd657c` | Block volume lifecycle、VolumeAttachment、node-loss force-detach |
| ceph-csi | v3.14.0 / `0d0e1f832cf7d0184ef332e2f947725e02e66135` | krbd map、Stage／Publish／Unstage |
| csi-node-driver-registrar | v2.13.0 / `9b41324b20f609bce4dda9e50cc484c4ef4f5949` | kubelet plugin registration responsibility boundary |
| Rook | v1.17.2 / `f6266772d2095c8af312745d9cbe045c98a380df` | generated CSI images、args、`attachRequired` |
| Ceph | v19.2.2 / `0eceb0defba60152a8182f7bd87d164b639885b8` | OSD acknowledgement、replication、BlueStore persistence |
| Ubuntu kernel | 6.8.0-52.53 / `6e81b9ec35b52955f286e56ffc159e1c934bce10` | ext4、XFS、block layer、virtio-blk、krbd/libceph |
| QEMU | production version **未知**；v9.1.0 / `fd1952d…` 僅作 reference | cache／flush 機制參考，不可冒充 deployed behavior |
| libvirt | production version與 source **未釘定** | domain XML 到 QEMU block graph 必須 runtime 驗證 |
| external-attacher | Rook source default v4.8.0；source **未納入** | finalizer／retry 細節保留為 evidence gap |

### 1.4 證據標記

| 標記 | 意義 | 可以支撐什麼 |
|---|---|---|
| **source-proven** | 指定版本 source 直接顯示的分支、default、flag 或 completion condition | 機制結論 |
| **reference-source-proven** | 非 deployed、但版本已釘定的 reference source | 只能解釋機制與設計實驗，不可冒充 production behavior |
| **upstream-commit-proven** | upstream exact commit 與 diff 可查，但尚未釘 first release／backport | 只能證明 main 已有變更，不能直接下升級建議 |
| **documentation-supported** | 同版本官方說明與 source 一致 | 幫助解讀，不能覆蓋 source |
| **inference** | 多個 source hop 合在一起的因果判斷 | 必須同句寫出前提與限制 |
| **runtime-required** | source 能說明怎麼查，但沒有 production readback | 不可寫成現場事實 |
| **experiment-needed** | source 無法證明 timing、硬體誠實性或 incident 因果 | 不列為無條件參數要求 |

## 2. 一次 durability operation 的完整路徑

先把後文反覆使用的三個詞講清楚：

- **FUA（Force Unit Access）**：要求這次 write 在回覆前到達裝置宣告的持久化邊界；backend 沒有 native FUA 時，Linux／QEMU 可以用 write 後 flush 模擬。
- **ONDISK**：Ceph client 要求 OSD 只在 ObjectStore transaction commit 後完成 request；它不等於「已驗證每顆 NAND 都不怕斷電」。
- **acting set**：這一刻實際承擔 PG write 的 OSD 集合；degraded 時可能少於 pool target `size`。

以下是本報告唯一承認的 end-to-end seam：

```text
application fsync/sync or filesystem transaction
  → ext4 journal / XFS log orders metadata and data
  → Linux guest block layer emits write + flush/FUA semantics
  → virtio-blk sends writes and VIRTIO_BLK_T_FLUSH
  → QEMU/libvirt effective block graph
  → launcher /dev/<volume> block device
  → host krbd/libceph request with ONDISK completion requirement
  → primary OSD + replica transaction commit
  → BlueStore/BlueFS/block device stable-media boundary
  → fenced old node cannot write; new node maps and mounts the same image
  → ext4 journal / XFS log replays committed records
  → normal recovery completes, or a verifier/error marks it repair-required
```

control plane 是另一條路，不能拿來填 data path 的空白：

```text
Kubernetes VolumeAttachment
  → ceph-csi ControllerPublish (NOOP)
  → NodeStage: rbd map + staging bind
  → NodePublish: staging bind to Pod target
```

第一條決定已 acknowledgement write 的 durability；第二條決定哪個 node 何時可以看到 block device。兩條都必須正確，但「attach 成功」不能證明「write 已落地」，「write 已落地」也不能取代 fencing。

### 2.1 最可能把 hard power loss 放大成 structural corruption 的三類斷點

| 斷點 | 會發生什麼 | 參數能否處理 |
|---|---|---|
| application 沒送 durability operation | 最近的 application data／transaction 可能遺失；filesystem 應仍靠 journal/log recovery 保持結構可 mount | filesystem／storage 參數不能替 application 補 `fsync` |
| 某一層提早 acknowledgement、忽略 flush，或硬體 write cache 說謊 | journal/log 以為 ordering 已成立，斷電後可能看到缺頁、舊 metadata 或不完整 transaction | 先查 effective cache／flush；軟體參數仍無法修正失信硬體 |
| fencing 前出現第二個 writer | 兩個 kernel/filesystem instance 可能同時改同一 RBD image；單機 filesystem 不具 shared-disk 協調能力 | 只能用 fencing、attach serialization與 writer ownership 防止；timeout 不是解法 |

因此，這次「需要 repair 才能 mount」不能只用「斷電導致未 flush 的 application data」解釋。這個症狀至少表示應追查 durability chain 被破壞、未 fenced 的多 writer、kernel／QEMU／Ceph defect，或儲存媒體違反 flush contract。

## 3. Guest filesystem 與 virtio 邊界

### 3.1 ext4

Ubuntu 6.8.0-52 source 的 ext4 預設啟用 barrier；journal 支援 revoke 時，預設 data mode 是 `ordered`。`fsync` 先處理 file data，再 commit journal；當 commit path 沒帶 barrier 時，還會補 block-device flush。這表示正常斷電後，dirty filesystem 應走 JBD2 scan、revoke 與 replay，而不是直接被分類成 structural corruption。

以下狀態要分開看：

- **正常 recovery**：superblock 表示未乾淨卸載，mount 期間執行 JBD2 recovery。
- **structural corruption**：例如 superblock checksum、group descriptor 或 root inode 驗證失敗，source 回 `EFSBADCRC`／`EFSCORRUPTED`。
- **危險繞過**：dirty filesystem 使用 `noload`／`norecovery`；read-write mount 會被 source 拒絕，不能當修復方式。

完整性優先的 production policy：保留 ext4 barrier 與 `data=ordered`；不要用 `nobarrier`、`data=writeback` 或 `noload` 當 failover tuning。這些設定不是縮短 RTO 的安全旋鈕。

### 3.2 XFS

這版 XFS 已移除 `barrier`／`nobarrier` mount option；同步 log force 直接提交 `REQ_PREFLUSH | REQ_FUA`。dirty log 只有在 tail 與 head 不同時才進入兩階段 recovery；filesystem 已標 `needsrepair` 時則拒絕 mount，要求 repair。

因此 XFS 的判讀也要分三層：

- **正常 recovery**：dirty log 被分析並 replay。
- **repair-required**：`needsrepair` 或 metadata verifier 使 mount 失敗。
- **只讀鑑識**：`norecovery` 只允許 read-only，而且內容可能不一致；它不是 production recovery 設定。

完整性優先 policy 不是「替 XFS 打開 barrier」；在此 kernel 根本沒有那個旋鈕。真正要查的是 guest queue 的 flush 能力、QEMU effective cache、host krbd completion 與 fencing。

### 3.3 guest FUA 如何穿過 virtio

virtio-blk 會協商 FLUSH 與 write-cache configuration，但 Linux driver 對這個 queue 宣告 `writeback=true, fua=false`。因此 guest block layer 看到需要 FUA 的 request 時，會在必要時轉成 write 後的 POSTFLUSH；wire 上由 virtio driver送出獨立 `VIRTIO_BLK_T_FLUSH`。

這個細節排除一個常見誤解：**不能寫成「guest FUA bit 原封不動穿過 virtio」**。在這版 kernel，保留下來的是 durability semantics，實作形狀是 flush。

## 4. KubeVirt、libvirt 與 QEMU effective disk

### 4.1 root 與 data disk 沒有不同 converter

KubeVirt v1.6.4 對 `vmi.Spec.Domain.Devices.Disks` 使用同一條 per-disk conversion。root disk 的特殊之處只是可能帶 `bootOrder`；只要 root/data 都是相同類型的 Block PVC，它們會進入同一個 launcher block-device 與 converter path。

但「同一路徑」不等於「同一有效值」。每顆 Disk 各自有 `bus`、`cache`、`io`、`dedicatedIOThread`，所以稽核必須逐顆做，不能抽一顆 data disk 代表 root disk。

### 4.2 `cache`／`io` 留空的真正語意

對 `volumeMode: Block`，KubeVirt 會把 volume render 成 compute container 的 `VolumeDevice` `/dev/<volume-name>`，再以 `os.Stat` 確認為 block device，最後產生 `<disk type='block'><source dev='…'><driver type='raw'>`。

啟動前才做兩個決策：

1. `cache` 省略：以 `O_DIRECT` probe backend；成功選 `none`，失敗選 `writethrough`。若使用者明示 `none` 但 direct I/O 不可用，VMI 啟動失敗。
2. `io` 省略：只有 effective `cache=none` 且 backend 是 block device，或 file 已 preallocated，才補 `native`；否則保持省略。

所以 production 可採用的陳述是：「對存在且支援 O_DIRECT 的 Block PVC，source 預期 `cache=none, io=native`。」不能把它縮成「KubeVirt default 永遠是 none/native」。

### 4.3 QEMU reference 能證明與不能證明的事

QEMU v9.1.0 reference 對 cache mode 的定義如下；production 必須先查實際 QEMU version：

| domain cache mode | QEMU reference writeback | direct | no-flush | operational meaning |
|---|---:|---:|---:|---|
| `none` | on | on | off | bypass host page cache；guest flush 仍有效 |
| `writethrough` | off | off | off | 每次 write 走 FUA，backend 不支援時以 flush 模擬 |
| `writeback` | on | off | off | 使用 host page cache；flush 沒被關掉，但多一層 volatile state |

只有 `no-flush=on`／unsafe 類模式才是刻意忽略 flush；KubeVirt API 不接受 unsafe cache mode。`cache=none` 也不是 guest write cache 關閉，而是 direct I/O 與正常 flush semantics 的組合。

### 4.4 v1.6.4 已定位但不能過度解讀的 regression

`SetDriverCacheMode` 在選到 `Source.Dev` 後，`isBlockDev` 仍維持 false，因而呼叫 `CheckFile` 而不是 `CheckBlockDevice`。兩個 checker 對已存在 device 都以 `O_RDONLY | O_DIRECT` probe，主要差異是 `CheckFile` 在 path 不存在時可嘗試建立。因此：

- source-proven：分類分支有錯；後續 main commit `d7c683cde613869fda86e333957976b6bba8faa6` 改用 `BackendIsBlock()`。
- 尚未證明：這會讓正常、已存在的 `/dev/<volume>` 選錯 cache mode，或就是 production corruption 根因。
- upgrade advice：先取得該 fix 首次進入的正式 release tag與 backport 狀態；目前不能聲稱某個指定 release 已包含。

## 5. CSI、Rook、Kubernetes 與 failover sequencing

### 5.1 `VolumeAttachment` 不是 device，也不是 fencing

ceph-csi v3.14.0 的 RBD `ControllerPublishVolume` 只驗證 request 後回空 `PublishContext`；`ControllerUnpublishVolume` 同樣回成功。真正 map 在 node side：

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

舊 node 斷電時，kubelet 無法執行正常的 Unpublish／Unstage。控制面刪除 `VolumeAttachment`，不會隔空讓舊 host kernel unmap krbd，也不會證明舊 node 已失去寫入能力。

### 5.2 Rook 與 registrar 的正確責任

Rook v1.17.2 source default 對 RBD 設 `attachRequired=true`，並把它寫進 `CSIDriver`；只有這個值為 true 才部署 external-attacher。這個 control 是 RWO writer serialization 的必要防線，不能為了 failover 速度關掉。

node-driver-registrar 只做三件事：連 CSI socket取得 driver name、建立 kubelet registration socket、回 `GetInfo`／registration status。它不碰 Kubernetes API、不建立 `VolumeAttachment`、不 map RBD、不處理 flush，也不提供 fencing。調 registrar timeout 或 liveness 不可能修正 filesystem corruption。

### 5.3 Kubernetes 的 6 分鐘不是 failover RTO

attach/detach controller 的最大 unmount wait 是 6 分鐘，但 timer 不是從 node 斷電那一刻開始，而是 volume 已不再存在於 desired state 後才開始。之後還要滿足 unhealthy+timeout 或 out-of-service taint，才會略過 mounted safety；後面仍有舊 VA 刪除、external-attacher、new VA、ceph-csi watcher check、NodeStage/Publish 與 VMI startup。

因此不能把這些 timeout 相加後宣稱「VM 會在 N 分鐘恢復」。它們是 availability sequencing，和已 acknowledgement write 的 durability 是兩件事。

### 5.4 root/data disk 的 CSI 結論

Kubernetes與 ceph-csi lower layer 只看 PV、volume handle／attributes、volumeMode、access mode、target path與 node name，沒有 root/data role。若兩顆 disk 的 `volumeMode`、access mode、StorageClass/PV attributes 與 pool policy相同，durability path相同；上層差異只在 root 通常跟 VM lifecycle 綁定，data disk 可能 hotplug/unplug。

## 6. host krbd 的 write-through contract

kernel 6.8.0-52 的 krbd queue 只接 READ、WRITE、DISCARD 與 WRITE_ZEROES，沒有 `REQ_OP_FLUSH`。這不是「Ceph 忘了實作 flush」：krbd 沒有宣告 write cache，也沒有宣告 native FUA，所以 block layer 把它呈現為 write-through device；libceph 對每個 request 要求 `CEPH_OSD_FLAG_ONDISK`，收到帶 ONDISK 的 reply 才完成 request。

因此這條路徑的 durability 形狀是：

```text
guest flush/FUA ordering
  → QEMU 等先前 host writes 完成
  → krbd 每筆 write 本身等待 Ceph ONDISK completion
  → host rbd device 不需要另一個 volatile write cache flush
```

production expected invariant 是 host `/sys/class/block/rbdN/queue/write_cache` 顯示 `write through`、`fua` 顯示 `0`。這兩個值合在一起才符合 source；看到 `fua=0` 不能單獨判定 unsafe。

### 6.1 exclusive-lock 與 fencing 不是同一件事

image 有 `exclusive-lock` feature 時，krbd write 前必須取得 lock；`object-map` 或 `lock_on_read` 還會讓 read 也要求 lock。這能降低同一 image 被多個 client 同時寫入的機會，但不是硬體 fencing：

- 舊 node partition、watch 失效、blocklist 與 lock handoff 都有各自的時間與錯誤路徑。
- `exclusive` map option 會拒絕 peer 要求釋放 lock，可能直接阻擋 handoff／live migration。
- Ceph lock 成功不能證明來源 node 已斷電；完整性優先流程仍以硬體 fencing 為重啟 gate。

### 6.2 timeout 只改失敗呈現

krbd 的 block mq ops 沒有 `.timeout` handler。即使 sysfs `io_timeout` 初值看起來是 30 秒，generic block layer 到期後只會重新掛 timer，不會 abort request。真正能讓 libceph OSD request 回 `ETIMEDOUT` 的是 `osd_request_timeout`，而 default `0` 是無限等待。

所以：

- 調 `/sys/block/rbdN/queue/io_timeout` 期待 30 秒後 failover，是 ineffective。
- 設非零 `osd_request_timeout` 可能把暫時 network partition 轉成 guest I/O error與 filesystem shutdown；它是故障政策，需要可回退 lab，不是完整性修正。

### 6.3 Ceph `ONDISK` 不是 replica 多數決

Ceph v19.2.2 replicated backend 對一次 mutation 建立的 commit wait set，是當下整個 `acting_recovery_backfill` set，包含 primary：

1. primary local ObjectStore transaction `on_commit` 後，移除 primary。
2. 每個 replica 也在自己的 ObjectStore `on_commit` 後，才回 ONDISK，primary再移除該 replica。
3. wait set 清空後，`PrimaryLogPG::repop_all_committed()` 才標成 all committed，之後才執行 client的 `ACK | ONDISK` reply callback。

因此 `min_size` 不是「收到幾份就提早 ACK」的 quorum。它決定 current acting set 少到什麼程度時 PG 還允許 write：

- `size=3,min_size=2`、PG active+clean且三份都在 write set：成功 ONDISK代表當下三份都 commit。
- degraded 到兩份仍可 write：成功 ONDISK只代表當下兩份都 commit。
- 若政策要求「每筆成功 write 必須先落滿 size份」，可評估 `min_size=size`；代價是少一份就停止 write。

compute-only node 在收到 ONDISK 之後消失，已完成的 storage transaction不依賴 compute node RAM。若 node 在收到 reply前消失，該 write可能已 durable、也可能尚未 durable；這是 ambiguous completion，application不得由「沒收到成功」推論「一定沒寫入」。

### 6.4 BlueStore 的 persistent boundary

BlueStore commit 的精確意思是「crash後可恢復的 transaction已穩定」，不一定是 payload已位於最後 logical extent：

- 一般 data write先以 direct AIO送 block device，AIO完成後仍被追蹤為 unstable。
- KV sync cycle必要時先 flush data device，再同步提交 RocksDB transaction。
- RocksDB WAL啟用時，final sync transaction使用 `WriteOptions.sync=true`；BlueFS-backed WAL的 `Sync()` 進入 `BlueFS::fsync()`，等待AIO、flush dirty device，必要時同步 metadata log。
- kernel block backend的 `flush()` 最後用 `fdatasync()`。
- deferred write先把 payload編碼成 RocksDB deferred transaction key；ONDISK可代表這份可 replay transaction已 durable，final extent之後才 materialize，並在 stable後移除 deferred key。

所以報告不能把 ONDISK 翻成「已寫進 NAND、任何斷電都不會失去」。Ceph source最多證明 `fdatasync()` 成功返回；NVMe／RAID controller／hypervisor是否誠實履行 flush、是否有 PLP／BBU，必須由硬體證據或非 production power-cut實驗補上。

### 6.5 RBD features 不要混進 OSD persistence

| Feature | 正確角色 | 不是什麼 |
|---|---|---|
| `exclusive-lock` | single-client ownership、lock handoff與cache coherency | 不改OSD replica commit或media flush |
| `object-map` | object existence metadata與查詢最佳化 | 不是data journal，不增加replica |
| `journaling` | userspace librbd journal/replay/mirroring | production krbd不走這條userspace write path |
| `fast-diff` | 差異追蹤／維運最佳化 | 不提高power-loss durability |

production是host krbd，因此不能用 `src/librbd/io/ImageRequest.cc` 的journaling path替現場write背書。

## 7. 參數與控制矩陣

### 7.1 Mandatory integrity controls

| 層 | 控制／設定 | Production 要求 | 保證什麼 | 不保證什麼 | 如何變更 |
|---|---|---|---|---|---|
| Failover | hardware fencing before restart | 來源 node 的寫入能力被確認排除後，才允許新 node 啟動 VM | 避免兩個 host 同時成為 writer | 不保證最後一次 application transaction 已 `fsync` | 維運流程／HA controller |
| Kubernetes/Rook | `CSIDriver.spec.attachRequired=true` | 保持 Rook default，不得為縮短 RTO 關閉 | 保留 RWO attachment serialization | 不是 fencing；不證明 host 已 unmap | generated CSIDriver；需控制面 rollout |
| Disk audit | VMI → domain XML → QMP/cmdline → host krbd identity 全對上 | root/data 每顆都查 | 讓後續建議針對真正 effective path | 不會自動修正 drift | 唯讀稽核 |
| KubeVirt/QEMU | effective block graph 必須保留 flush | 逐顆確認 cache／AIO mode；不得出現 `no-flush`／unsafe 等忽略 flush 的語意 | 讓 guest journal／log 的 ordering 可以傳到 host backend | `writeback` 本身不是 corruption 證據；不證明 OSD media 誠實 | VM restart 才套用新 domain |
| ext4 | barrier on、預設 `data=ordered`、錯誤時至少 remount-ro | 不得用 `nobarrier`／`data=writeback`／`errors=continue` | 保留 journal ordering並限制錯誤擴散 | 不替 application 補 `fsync` | mount/fstab；通常需 remount或 reboot |
| XFS | 保留內建 log FLUSH/FUA、正常 recovery | 不用也不能新增 `barrier`；不得以 `norecovery` 正常服務 | 保留 log ordering與 crash replay | 不保證未 `fsync` data | kernel 固定；mount policy |
| Application | database WAL／`fsync` contract | 對聲稱已提交的 transaction 必須明確同步 | 建立 application durability boundary | 不處理底層提早 ack／硬體失信 | application config/code |
| CSI/krbd | RWO volume single-writer；現場證明 krbd | PV access mode、VA、host mapping與 lock owner一致 | 防止 orchestration 層明顯多 attach | 不取代 fencing；不保證 Ceph replica commit | PV/SC 建置期＋runtime audit |
| Ceph pool | 明確核准 `size`／`min_size`／CRUSH failure domain | 查實際 pool 與 acting set，不只看 `HEALTH_OK` | 決定成功 write 的 current commit參與者與可承受故障 | 不保證 device flush 誠實 | pool policy；online但高風險 |
| Ceph OSD | BlueStore且durability debug bypass全部關閉 | blackhole/omit-write/omit-kv為false，crash injection為0 | 保留source-proven data/KV commit path | 不證明硬體PLP | daemon config；不要任意改 |
| OSD media | controller/device履行flush，或有PLP/BBU | 保存model/firmware/cache/PLP證據 | 讓`fdatasync`／flush有物理意義 | Ceph config無法修補失信硬體 | 硬體選型與驗證 |

### 7.2 Conditional controls

| 設定 | 何時才考慮 | 本報告的限制 |
|---|---|---|
| KubeVirt 明示 `cache: none` | 要把 O_DIRECT 不可用變成啟動失敗，而不是靜默 fallback 到 `writethrough` | 對正常 Block PVC 可能與省略值完全相同；先查 effective state |
| KubeVirt `cache: writeback` | workload 明確需要 host page cache，且已在隔離 lab 驗證 flush、斷電 recovery 與效能收益 | flush 正常時不能直接判成 corruption 根因；但會擴大未同步資料留在 node-local volatile cache 的窗口 |
| KubeVirt 明示 `io: native` | 已證明 effective direct I/O，且需要固定 runtime contract | `native` 搭非 direct cache 在 QEMU reference 會開啟失敗；不是完整性增益 |
| ext4 `data=journal` | 有明確資料 journaling需求且接受效能／功能代價 | 代價高，會限制 delayed allocation、O_DIRECT、fast commit；不是第一線修復 |
| ext4 `data_err=abort` | 希望 ordered-data writeback error 直接 abort journal | 以 availability 換 fail-stop；需故障測試 |
| XFS `wsync` | HA namespace operation 需要更強同步 | 不能取代 file data `fsync` |
| krbd `lock_on_read` | object-map 或嚴格 single-owner read有明確需求 | 可能增加 lock contention |
| `abort_on_full` | 希望 full 時回 ENOSPC，不無限等 | 只改 failure mode，不增加 durability |
| Ceph `min_size=size` | 每筆成功 write 必須落滿目標 size，高於 degraded write availability | 任一 replica缺失即停止write；先評估業務可用性 |
| Ceph `size=3,min_size=2` | 接受 degraded 到兩份仍可 write | 健康 full acting set仍等全員；degraded成功只代表當下兩份 |
| RBD `exclusive-lock` | single-writer ownership與handoff policy需要 | 不取代hardware fencing或application flush |

### 7.3 Ineffective for structural-corruption prevention

| 設定／做法 | 為什麼無效 |
|---|---|
| 調 node-driver-registrar | 不在 attach data path，也不碰 write／flush／krbd |
| 開 CSI liveness metrics | 只輸出 gauge，不是 nodeplugin restart probe |
| 把 `ControllerPublishVolume` 成功當 device ready | ceph-csi RBD controller RPC 是 NOOP；map 在 NodeStage |
| 事後改 StorageClass `mapOptions` | 既有 PV 的 CSI attributes immutable，不會跟著 SC 改 |
| 調 `queue_depth`、discard、read affinity | 影響 concurrency、space reclaim或 read locality，沒有 durability contract |
| 調 Kubernetes 6 分鐘 timer／leader election | 影響 availability sequencing，不改 acknowledgement boundary |
| 調 `/sys/block/rbdN/queue/io_timeout` | krbd 沒 timeout callback，timer 到期不會 abort request |
| ext4 調小 `commit=` 取代 `fsync` | 只限制 journal transaction age，不建立 application transaction boundary |
| 因 guest／host `fua=0` 就判定 unsafe | virtio 可用 POSTFLUSH 模擬；krbd 每筆 write 等 ONDISK completion |
| mClock、OSD queue、recovery priority | 改 scheduling 與 latency，不改 all-current-participants commit gate |
| `object-map`／`fast-diff` | 是 metadata／維運最佳化，不是 write journal或replica durability |
| 對 krbd 啟用 librbd journaling期待改變 write path | host krbd不走userspace librbd journaling path |

### 7.4 Unsafe or misleading

| 設定／操作 | 風險 |
|---|---|
| fencing 前 force restart／out-of-service taint | 可略過 mounted safety，製造第二個 writer |
| `CSI_RBD_ATTACH_REQUIRED=false` | 移除 RWO attachment serialization；Rook source明確警告 data corruption |
| 把 `cache: writeback` 當成無條件 throughput tuning | 增加 host volatile page cache；若未驗證 flush 與 power-loss recovery，就不能用效能假設直接推到 production |
| `io: native` 搭非 direct cache | admission 可能通過，但 QEMU reference 會 runtime failure |
| ext4 `nobarrier`／`data=writeback`／`errors=continue` | 削弱 ordering或讓錯誤後繼續寫入 |
| ext4 `noload`／XFS `norecovery` 當正常開機方式 | 刻意略過 replay，暴露未恢復的不一致狀態 |
| XFS `nouuid` 用在可寫 duplicate image | 關閉 duplicate-mount UUID protection，可能讓 clone/snapshot 被雙重寫入 |
| `unmapOptions: force`／`rbd unmap --force` | freeze queue、mark disk dead；不是診斷工具 |
| krbd `exclusive` 未經設計就套用 | 可能拒絕 peer lock handoff，阻擋 migration/failover |
| pool `size=1` 或 `min_size=1` | storage failure後沒有足夠 replica安全邊界 |
| RocksDB `disableWAL=true` | final sync transaction失去本報告依賴的 WAL sync durability |
| `objectstore_blackhole`／BlueStore omit-write／omit-kv／crash injection | 直接繞過 data 或 KV commit，只能用於開發故障注入 |

### 7.5 Upgrade or experiment required

| 項目 | 為什麼不能直接下結論 | 下一個證據 |
|---|---|---|
| KubeVirt `SetDriverCacheMode` 後續 fix | v1.6.4 有分類 regression，但尚未證明 valid block device會選錯 cache | 查 first release/backport tag；用相同 Block PVC比較 domain XML |
| production QEMU/libvirt | Issue 沒釘版本，reference v9.1.0 不能冒充現場 | `virsh version`、QEMU binary version、QMP `query-block` |
| external-attacher v4.8.0 | Rook 有 image default，但本研究沒有其 source | pin source，追 finalizer與 force-detach retry |
| 非零 `osd_request_timeout` | 可能把 hang 轉成 guest I/O error與 filesystem shutdown | 隔離 lab 做 partition／recovery A/B |
| `mounter: rbd-nbd`／fallback | failure model、userspace process lifecycle不同；Rook example仍標 Alpha healer | 獨立 source trace與故障實驗 |
| kernel/Ceph 升級 | 目前沒有 incident signature指向特定已修 bug | 蒐集 exact corruption、dmesg、lock/watch timeline，再做 precise diff |

## 8. 唯讀 production 稽核

以下命令只讀；本研究沒有執行。所有 `<...>` 都必須由 operator 換成實際名稱，不要整段盲貼。

### 8.0 先證明 deployed version

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

Expected invariant：Kubernetes、KubeVirt、Rook、ceph-csi／sidecar image 與 host kernel 必須逐項對到 §1.3 的 pinned baseline；有差異就先記為 version gap，不能套用本報告的精確行號結論。guest kernel、QEMU／libvirt 與 Ceph version 分別在 §8.2、§8.5、§8.6 補齊。

### 8.1 先對齊 VM、Pod、PV 與 host node

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

Expected invariant：root/data 都明確是 `Block`、RWO、核准的 RBD CSI driver；真正有效的 `mounter`／`mapOptions` 以 PV `volumeAttributes` 為準，不能用目前 StorageClass 猜舊 PV。

### 8.2 驗 VMI → libvirt → QEMU

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

Expected invariant：同一顆 disk 的 VMI name、domain alias／target、QMP block node與 launcher device必須一一對上；每顆 Block PVC 要看見 `type=block`、`source dev=...`，並記錄 effective `cache`／`io`。launcher device 的 major:minor 必須再與 §8.4 host `rbdN` 完全相同，不能只靠 volume name 或 `/dev/rbd0` 猜。先記錄實際 QEMU/libvirt version，再套用該版本語意。

### 8.3 驗 attach serialization 與 CSI 實作

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

Expected invariant：`attachRequired=true`；active RWO PV 不應有兩個成功 attachment；舊 VA 若仍 active，不得以新 VA 或 Pod 狀態假設舊 host 已 fenced。`attached=true` 也不能代替 host mapping查核。

### 8.4 驗 host krbd，不輸出敏感 connection material

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

Expected invariant：device identity 與 PV handle/image 對得上，且 major:minor 與 launcher `/dev/<volume>` 相同；`write_cache=write through`、`fua=0`；單 writer image 的 watcher／lock owner符合預期。不要把 `io_timeout=30000` 解讀成 request 30 秒後必定回錯。`config_info` 可能含 connection或credential material，本報告不建議直接輸出到共用 ticket／chat。

### 8.5 guest filesystem 與 queue

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

Expected invariant：driver 是 `virtio_blk`；ext4 effective mount沒有 `nobarrier`、`noload`、`data=writeback`、`errors=continue`；XFS 沒有 `needs repair`、corruption或 forced shutdown。`recovery complete`、`Starting recovery`、`Ending recovery` 本身可以是正常 unclean-shutdown recovery。

### 8.6 驗 Ceph current write set 與 persistent path

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

Expected invariant：相關 PG 是 `active+clean`，沒有 `undersized`、`degraded`、`inconsistent`；`size`／`min_size` 符合核准政策；實際 RBD data object的acting OSD數量與host failure domain符合預期；steady state只有預期 writer／lock owner；OSD objectstore是BlueStore。

另外確認以下安全值：

```text
objectstore_blackhole = false
bluestore_debug_omit_block_device_write = false
bluestore_debug_omit_kv_commit = false
bdev_inject_crash = 0
```

`bluestore_rocksdb_options` 與 annex不得包含 `disableWAL=true`。這些檢查只證明software path沒有被debug／custom option繞過；media還要查：

```bash
lsblk -o NAME,KNAME,TYPE,MODEL,ROTA,FSTYPE,MOUNTPOINTS
sudo nvme id-ctrl -H /dev/<NVME_CONTROLLER> |
  grep -E 'vid|ssvid|mn |fr |vwc|Volatile Write Cache'
sudo nvme smart-log /dev/<NVME_CONTROLLER>
sudo smartctl -x /dev/<DEVICE> |
  grep -E 'Device Model|Model Number|Firmware Version|Write Cache|Power_Loss|Unsafe_Shutdowns'
```

它們能盤點write cache、device identity、firmware與error state，但仍不能取代vendor PLP證明或非production power-cut實驗。

### 8.7 incident 發生時最小證據包

不做 repair 前先保存唯讀證據：

1. VM/VMI/PVC/PV/VolumeAttachment JSON與事件時間線。
2. virt-launcher domain XML、QMP `query-block`、QEMU/libvirt version。
3. 新舊 node 的 RBD mapping、watcher／lock owner、kernel log。
4. guest 前一次 boot與本次 boot的 kernel log；ext4/XFS mount failure原文。
5. 在既有、已隔離的 image snapshot／clone 上執行 `fsck -n` 或 `xfs_repair -n` 的輸出；若尚無副本，建立 snapshot／clone 是另需授權的 production mutation。不要先對唯一副本做寫入式 repair。
6. Ceph health detail、OSD slow/error log、blocklist與 image status，時間要與斷電／fencing／新 VMI啟動對齊。

## 9. Source evidence ledger

這份 ledger 使用 upstream repository相對路徑；每列的 version 是證據的一部分。`source-proven` 只涵蓋「證明範圍」，不能拿來延伸成欄位中明列的限制之外。

### 9.1 ext4、XFS、block layer、virtio與 krbd

| ID | Claim | Component/version | Source anchor | Source 證明 | 限制 | Strength |
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
| L-11 | XFS沒有 `barrier`／`nobarrier` 旋鈕 | Linux 6.8.0-52 | `Documentation/admin-guide/xfs.rst:249-261`; `fs/xfs/xfs_super.c:98-150` | option已移除且 parser無欄位 | 不能用舊版文件下建議 | source-proven |
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

### 9.2 KubeVirt、QEMU reference 與 virt-launcher

| ID | Claim | Component/version | Source anchor | Source 證明 | 限制 | Strength |
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

| ID | Claim | Component/version | Source anchor | Source 證明 | 限制 | Strength |
|---|---|---|---|---|---|---|
| C-01 | Rook defaults pin CSI v3.14、registrar v2.13、attacher v4.8 | Rook v1.17.2 | `pkg/operator/ceph/csi/spec.go:129-141` | source image defaults | runtime ConfigMap可覆寫 | source-proven |
| C-02 | RBD attachRequired default true | Rook v1.17.2 | `pkg/operator/ceph/csi/csi.go:299-305`; `pkg/operator/ceph/csi/csidriver.go:35-60` | generated CSIDriver值 | runtime object才是現場事實 | source-proven |
| C-03 | 關RWO attach有data-corruption warning | Rook v1.17.2 | `deploy/examples/operator.yaml:526-535` | upstream operator警告 | 文件警告不是單獨mechanism proof | documentation-supported |
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

| ID | Claim | Component/version | Source anchor | Source 證明 | 限制 | Strength |
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

## 10. 已定位缺陷、版本差異與不該亂升級的地方

### 10.1 已有精確 source evidence

1. **KubeVirt v1.6.4 cache backend分類 regression。** `SetDriverCacheMode` 對 `Source.Dev` 仍走 `CheckFile`；後續 main commit `d7c683cde613869fda86e333957976b6bba8faa6` 改用 `BackendIsBlock()`。目前沒有足夠tag/backport evidence聲稱哪個正式release已修，也沒有證據把它直接連到這次corruption。
2. **Ubuntu kernel source已包含兩個RBD exclusive mapping修正。** changelog列出「don't assume lock owner／LOCKED state」；現有state-aware code在 `drivers/block/rbd.c:4337-4358`。它只能證明修正已存在，不能說incident就是同一個bug。
3. **同一kernel changelog含XFS legacy recovery allocation與ext4 fast-commit replay修正。** 缺少incident signature、upstream commit與可重現case，因此不列為升級理由。

### 10.2 不足以聲稱已修的項目

- production QEMU/libvirt版本未知；不能拿QEMU v9.1.0 reference替它下verdict。
- external-attacher v4.8.0 source未納入，finalizer字串、加入／移除與retry細節不能由Kubernetes API type反推。
- 未做Ceph v19.2.2到後續Squid patch release的durability diff。
- 未取得production corruption signature；不能把「kernel／Ceph升級」列成無條件解法。

升級要進mandatory前，至少要有「incident錯誤訊息／stack或on-disk signature → exact upstream issue/commit → first fixed release/backport → 相同path驗證」四段證據。

## 11. Residual risk 與 open findings

即使矩陣中的mandatory項目全部成立，仍有以下無法由參數消除的風險：

1. application沒有正確使用`fsync`／WAL protocol，或錯誤處理ambiguous completion。
2. production QEMU/libvirt block graph與KubeVirt期待不同，或現場有sidecar／hook改寫domain。
3. device firmware、RAID controller、hypervisor或NVMe write cache謊報flush completion，且沒有PLP／BBU。
4. 未fenced node在partition恢復後重新取得network與write能力；exclusive-lock/watch/blocklist交接有時間窗。
5. kernel、QEMU、libvirt、Ceph未識別bug；目前source trace只能說明contract，不能證明實作無缺陷。
6. degraded PG在`min_size`允許下持續write，成功write的replica數少於target `size`。
7. repair工具先寫回唯一image而沒有snapshot，破壞後續root-cause鑑識。

目前必須保留的open findings：

- guest與host是否都真的是Ubuntu kernel 6.8.0-52.53。
- 每顆root/data disk的effective bus/cache/io、QEMU/libvirt版本與block graph。
- host backend是否全為krbd，是否有volume偷偷走rbd-nbd或userspace librbd。
- incident當時舊node是否確實完成fencing；新舊node的VA、watcher、lock與blocklist時間線。
- pool `size`／`min_size`、CRUSH failure domain、實際acting set、OSD store layout與media cache/PLP。
- ext4／XFS exact mount options、repair-required signature與offline no-write checker輸出。
- application是否對聲稱已提交的資料使用正確durability API。

## 12. Ordered production checklist

這是建議直接採用的順序；本報告提供的命令全部唯讀。任何 snapshot／clone、設定變更或重啟都必須另行核准，不包含在本次執行範圍：

1. **唯讀核對restart gate**：確認HA流程把hardware fencing success放在new VMI creation之前；若不符合，另開核准的change workflow，本報告不替你修改或凍結production流程。
2. **匯出現況**：保存VM/VMI/PVC/PV/StorageClass/CSIDriver/VolumeAttachment與Rook CSI workload JSON。
3. **逐顆對盤**：root與每顆data disk從VMI name一路對到domain XML、QMP block node、launcher `/dev/<volume>`、host `rbdN`與RBD image。
4. **查effective cache**：記錄production QEMU/libvirt version；確認Block PVC沒有意外落到host-page-cache writeback或unsafe/no-flush語意。
5. **查guest recovery contract**：ext4保留barrier/ordered/remount-ro；XFS不用`norecovery`；保存本次與前次boot kernel log。
6. **查single-writer**：`attachRequired=true`；active RWO PV沒有第二個成功VA；新舊node watcher／lock／mapping與fencing時間線一致。
7. **查krbd contract**：host queue為`write through,fua=0`，identity與image對得上；不要把generic `io_timeout`當abort保證。
8. **查Ceph current write set**：pool policy、PG state、acting OSD與CRUSH failure domain符合核准值；確認debug durability bypass全關。
9. **查media boundary**：保存OSD device model、firmware、controller cache與PLP/BBU證明；沒有就列為風險，不能用`HEALTH_OK`掩蓋。
10. **保存corruption evidence**：優先使用事前snapshot／已隔離clone跑只讀checker；若沒有副本，先取得建立snapshot／clone的變更授權。保留exact error與time correlation，之後才決定repair。
11. **只針對已證明缺口變更**：例如effective cache drift、unsafe mount、attachRequired錯誤、pool policy或硬體不符合；每項獨立change與rollback。
12. **其餘進lab**：QEMU mode、timeout、`min_size=size`、kernel/Ceph upgrade、rbd-nbd等都先做可回退、prediction-first實驗，不直接在production試。

## 13. 最終判定

這份exact-version source review沒有找到一個「只要改這個參數就能保證不再corruption」的旋鈕。相反地，它把問題縮成兩個production gate與三個evidence gap：

- Gate 1：**fencing完成前絕不建立第二個writer**。
- Gate 2：**guest durability operation必須一路對到Ceph all-current-participants ONDISK commit**。
- Gap 1：production QEMU/libvirt effective block graph尚未讀取。
- Gap 2：incident當下的新舊node mapping／watcher／lock／fencing時間線尚未保存。
- Gap 3：OSD media是否誠實履行flush／具PLP尚未證明。

只要這三個gap尚未補齊，就不能把repair-required ext4／XFS corruption歸因於「正常斷電」，也不能把任一timeout、CSI sidecar或performance knob包裝成修復。完整性優先的正確下一步是完成本報告的唯讀稽核，依證據找出斷掉的hop，再把有風險的變更帶到隔離lab驗證。
