# rbd-io-perf — Hypothesis Backlog

## Charter（v2，2026-07-07 前提變更）

> 變更記錄：v1（2026-07-06）以 .160 k0s + KubeVirt 為 T3 環境；2026-07-07 使用者變更前提——KubeVirt 只是 control plane、不在 data path 上，T3 改為**實際在用的 Proxmox VE + Ceph cluster**，只動 VM 參數不動 ceph。v1 charter 見 git 歷史（commit 495b233）。

- Goal: 驗證並修正 `rbd-io-experiment-plan` 的實驗設計（計畫正確性 + 覆蓋完整性），並在生產 PVE cluster 上以受控實驗量出各 QEMU / krbd / librbd / image-layout 旋鈕相對 baseline 的真實效果——所有 claim 錨定 pinned source 或 evidence bundle，量不出可信差異的旋鈕誠實標記為「在此環境不可分辨」。
- Scope:
  - in：PVE VM 參數層（`qm` 設定：cache / aio / iothread / queues via args）、自有測試 image 的 client 側操作（建檔參數、per-image `conf_*` 覆寫、手動 `rbd map` 帶 map options）、專屬測試用 storage id（krbd=1，測完刪）、krbd vs librbd 雙軸對照、實驗 harness 自動化、兩頁 MDX 的錯誤修正與缺口補充。
  - out：**任何 ceph cluster / daemon / config 變更**（osd_op_num_shards、mClock 變體全剪，read-only 記錄除外）、其他 VM 與其磁碟、需要重啟 ceph 或造成其他 VM down 的一切操作、網路層調教、跨環境絕對數字。
- 使用者裁示的操作邊界：(a) 既有 pool 建自有測試 image（含 object-size/striping）(b) 自有 image 的 `rbd image-meta conf_*` 覆寫 (c) 手動 `rbd map`（queue_depth/rxbounce 等 options）(d) storage.cfg 新增專屬測試 storage id——**全部允許**；底線＝不重啟 ceph、不讓其他 VM down（慢可以接受）。
- Version anchors: pinned submodules（qemu v9.1.0 / linux 6.8.0-52 / ceph v19.2.3 …）作 T1 對照基準；**PVE 實機的 pve-qemu / kernel / ceph 版本由 pre-flight 記錄**，與 pinned 版本的差異在結論中誠實標註。kubevirt v1.5.0 anchors 僅用於頁面修正（頁面仍是 KubeVirt 軸）。
- 環境（待使用者提供 + pre-flight 確認）：生產 PVE cluster（node 清單、ssh 存取方式待提供），內建 ceph cluster；OSD 佈局（是否 hyperconverged）、媒體、網路、pool 使用率全由 pre-flight read-only 盤點。**krbd 可用性未知（使用者未調過）→ pre-flight 專項驗證**。
- Tiers available:
  - T1：pinned submodules（qemu / linux / ceph / kubevirt / libvirt）。
  - T2：官方文件（docs.ceph.com、kernel.org、QEMU docs、PVE docs/wiki）。
  - T3：生產 PVE cluster。**全部實驗限 automation-safe**（僅自有 VM/image/storage id；courtesy guardrails：HEALTH_ERR / 持續 slow_ops / pool nearfull 邊界 → abort）；無 gated cluster 實驗。

## Gate 1 裁示（2026-07-06）

使用者裁示：**照建議全收**。優先序如下；cluster-scope 項目維持 gated（手動觸發、ok-to-stop → 回退 → HEALTH_OK）。

- **P0（修計畫本身，動筆前必修）**：H-001、H-002、H-005、H-007、H-021、H-022、H-023
- **P1（harness 內建規則與斷言）**：H-006、H-008、H-009、H-010、H-012、H-014、H-015、H-016、H-017、H-018、H-020、H-024、H-025
- **P2（新研究線）**：H-003（baseline 首輪自帶回答）、H-004（rxbounce 觀測 + 變體）、H-011（queue_depth 機制重推）、H-013（io_uring）、H-019（mClock，gated）
- **io_uring 路線**：兩條都做——先在實驗 0 用 host 層 fio `ioengine=libaio` vs `io_uring` 對照；若差異顯著，第二階段再寫 `OnDefineDomain` hook sidecar 驗證 QEMU 層。

## Gate 1'（2026-07-07 前提變更後的 re-triage）

T3 環境改為生產 PVE cluster、只動 VM 參數不動 ceph。對 backlog 的影響：

- **Killed**（KubeVirt 控制面不再是 T3 路徑）：H-012、H-013、H-014——各條目內已標記理由。H-001 / H-002 維持 confirmed，其頁面修正 artifacts 不受影響（頁面仍是 KubeVirt 軸）。
- **Cluster-scope 剪除**：H-019 的 mClock 變體實驗剪除；降級為 pre-flight read-only 記錄 `osd_op_queue` / `osd_mclock_profile` 供天花板解讀。
- **Retarget（環境置換，假設本身不變）**：
  - H-003：虛擬化稅改在 PVE 量；krbd 軸用 host `/dev/rbdX` 邊界，librbd 軸以 QMP `query-blockstats` 取代 host iostat（沒有 host block device）。
  - H-006：「StorageClass imageFeatures」改讀「PVE `rbd create` 的預設 features」；併入 krbd 可行性檢查（H-030）。
  - H-010：nested 稅不再適用（PVE 實體機）；schedstat 差分照舊，另記 host loadavg 與同節點其他 VM 負載。
  - H-016：生產叢集永遠有背景活動——recovery/backfill → 該輪延後重試；scrub / 其他 client 負載 → 記錄並靠交錯輪次（H-029）吸收，不再要求「無背景活動」。
  - H-017：CPU governor 只 read-only 記錄（生產節點不改設定）；漂移控制改靠 H-029。
  - H-020：QEMU PID/uptime 斷言改用 `qm status` 與 `/var/run/qemu-server/<vmid>.pid`。
- **新增**：H-026 ～ H-033（見下），其中 H-026 / H-028 已於前提變更研究時完成 T1 驗證。
- **krbd/librbd 軸**：krbd 可用性由 pre-flight 驗證（H-030）；可用則雙軸（krbd vs librbd 對照為頭牌實驗），不可用則 librbd 單軸 + 手動 map 的 host 層 krbd 對照點。

## Hypotheses

### H-001: KubeVirt v1.5.0 對 block device 後端在 `cache` 留空時自動設 `cache=none` 並推導 `io=native`，因此實驗 1 的 baseline 與變體是同一組設定，量不出任何差異
- Status: confirmed
- Tier: T1
- Origin: framing-dialog（前置研究發現）
- Prediction: `SetDriverCacheMode` 在 mode=="" 且 block device 支援 direct IO 時設 CacheNone。
- Evidence: kubevirt/pkg/virt-launcher/virtwrap/converter/converter.go:387-423（`SetDriverCacheMode`：L419-420 `if mode == "" && supportDirectIO { mode = v1.CacheNone }`）；manager.go:838-842（對每顆 disk 無條件呼叫，接著 `SetOptimalIOMode`）。
- Artifacts:（待 Gate 3）實驗 1 改為 none vs writethrough vs writeback 三方對照；`rbd-io-experiment-plan` baseline Callout（「留空時不會主動開 O_DIRECT」）與 baseline 說明、`rbd-io-tuning-catalog` 相應敘述需修正。
- Notes: 這表示「最樸素 baseline」在 KubeVirt 上根本不存在——留空即 cache=none + io=native。

### H-002: 計畫的 baseline VMI 只有一顆 datadisk、沒有 boot volume，VM 開不起來；補上 boot 盤後資料盤是 `/dev/vdb`，計畫內所有 `--filename=/dev/vda` 都指向錯誤的裝置
- Status: confirmed
- Tier: T1
- Origin: framing-dialog（前置研究發現）
- Evidence: rbd-io-experiment-plan.mdx L36-64（volumes 僅 datadisk PVC，無 containerDisk / cloud-init）；fio 矩陣 L76-97 全部 `--filename=/dev/vda`。
- Artifacts:（待 Gate 3）baseline VMI 補 boot volume + cloud-init（裝 fio、鎖版本）；fio 指令全數改 `/dev/vdb`；頁面同步修正。

### H-003: 在 nested KubeVirt + SATA SSD + 10G 環境，4k randwrite qd1 的虛擬化稅（guest await − host await）占總延遲比例未知（使用者答「沒概念」）
- Status: proposed
- Tier: T3
- Origin: framing-dialog（known-unknown 轉換）
- Prediction:（Falsify 時由機制推出數量級後填入）
- Notes: 這是 baseline 第一輪就能回答的核心問題；也是「哪些旋鈕值得調」的分母。

### H-004: 不加 `rxbounce` map option 時，Linux guest 高並行 read workload 會觸發 krbd bad crc → messenger 連線重建 → p99 延遲尖峰
- Status: proposed
- Tier: T3
- Origin: framing-dialog（unknown-unknown 轉換）
- Notes: kernel 6.8.0-52 支援 rxbounce 已驗（linux/net/ceph/ceph_common.c:299 `fsparam_flag("rxbounce", ...)`）。上游對 VM-on-krbd 的已知建議；catalog 未列（候選新參數條目）。T3 作法：所有實驗全程收 host dmesg 中 `bad crc`/`osd... socket closed`；若出現，加 rxbounce on/off 變體。

### H-005: 未 pre-fill 的 thin RBD image 上跑 randread，大量 op 打到未配置 extent、OSD 以 ENOENT fast path 回應，randread IOPS 虛高（pre-fill 前後差異超過噪音帶數倍）
- Status: proposed
- Tier: T3
- Origin: matrix「RBD image state × lying × fio」
- Notes: 經典 Ceph benchmark 陷阱；計畫完全沒提 pre-fill。harness 規則候選：每顆測試盤建立後先 `fio --rw=write --bs=1M` 寫滿一遍再測。

### H-006: 各變體的 StorageClass `imageFeatures` 不一致（exclusive-lock / object-map / fast-diff）會改變 write path 行為（首寫 object-map 更新、map 後首寫取鎖），使變體間比較被 confound
- Status: proposed
- Tier: T1
- Origin: matrix「ceph-csi provisioning × partial × 變體一致性」
- Notes: ceph-csi example 預設 `imageFeatures: "layering"`（examples/rbd/storageclass.yaml:39），但 .160 Rook 建的 SC 實際值未知 → pre-flight 讀取；harness 斷言所有變體 `rbd info` features 一致。

### H-007: 同設定連跑 5 次 baseline，qd1 p99 的變異係數（CoV）會大於 5%，單次執行無法分辨小於 ~15% 的旋鈕差異
- Status: proposed
- Tier: T3
- Origin: persona（統計學家視角）
- Notes: 計畫沒有重複次數、噪音帶、判準——沒有這些，任何「A 比 B 快」的結論都不可信。harness 候選規則：每點 n≥3、宣告噪音帶、verdict 由機器比對（difference > noise band 才算 confirmed）。

### H-008: fio 不加 `--ramp_time` 時，前段 allocation / 暖身效應使 60 秒平均漂移，加 ramp 前後結果差異可測
- Status: proposed
- Tier: T3
- Origin: pre-mortem（「結論出爐後發現量到的是暖身段」）
- Notes: 候選修正：`--ramp_time=15 --runtime=60`；配合 H-005 pre-fill。

### H-009: guest 與 host 的 iostat 收集窗若不與 fio measurement window 對齊，「虛擬化稅」差值計算失真
- Status: proposed
- Tier: T3
- Origin: matrix「觀測管線 × lying × iostat」
- Notes: harness 設計題：同步時間戳、只取 fio measurement window 內的整窗平均、丟棄 ramp 段。

### H-010: 以 top 瞬時值量 QEMU thread CPU 誤差大，且 nested 環境的 steal time 使 CPU% 系統性失真
- Status: proposed
- Tier: T3
- Origin: matrix「觀測管線 × lying × QEMU CPU」
- Notes: 候選改法：讀 `/proc/<pid>/task/<tid>/schedstat` 差分（fio 前後），另記 guest steal（`mpstat` %steal）。

### H-011: krbd 的 `tag_set.nr_hw_queues = num_present_cpus()`，queue_depth 是 per-hctx tag 深度，host 端實際 in-flight 上限不等於 queue_depth 單一數字——實驗 6 的機制主張與 `nr_requests` 生效驗證都要重新推導
- Status: proposed
- Tier: T1
- Origin: matrix「krbd × stale/lying × 生效驗證」
- Notes: rbd.c:4962 已驗 nr_hw_queues=num_present_cpus()。待 T1 確認：tag 是否 per-hctx 獨立（無 BLK_MQ_F_TAG_HCTX_SHARED 時 in-flight 總上限 = queue_depth × nr_hw_queues？）以及 `/sys/block/rbdN/queue/nr_requests` 讀值語意。catalog「host 端允許的 in-flight request 數」敘述可能過度簡化。

### H-012: VMI 幾乎所有 spec 欄位 immutable，「改 VMI 重啟」的實際操作是 delete + recreate（或 VM 物件 + RunStrategy）——harness 用 patch 會失敗或殘留舊 domain
- Status: ~~proposed~~ killed — 2026-07-07 前提變更：T3 改 PVE，變體切換改用 `qm set` + 自有 VM 冷重啟，KubeVirt 控制面不在路徑上
- Tier: T1
- Origin: matrix「KubeVirt 控制面 × stale × 變體切換」
- Notes: 決定 harness 的變體切換機制：建議每個變體一份完整 VMI manifest，delete → wait gone → apply → wait ready。

### H-013: io_uring 變體無法從 VMI 欄位設定，virsh edit 會被 virt-launcher 重生覆蓋；可行路徑是 KubeVirt hook sidecar（`OnDefineDomain`）改 domain XML，或以 host 層 fio `ioengine=io_uring` 對照近似
- Status: ~~proposed~~ killed — 2026-07-07 前提變更：PVE `qm` 直接暴露 `aio=io_uring`（且為預設），hook sidecar 路線不再需要；host 層對照保留在實驗 0
- Tier: T1
- Origin: matrix「libvirt/QEMU 層 × stale × io_uring 變體」
- Notes: v1.5.0 pkg/hooks 存在 OnDefineDomain（已驗）。sidecar 是正路但工程量大；host 層 fio 對照（見 H-021）是務實替代，兩者取捨進 Gate 1。

### H-014: .160 Rook external 部署的 ceph-csi 實際版本與 StorageClass 預設值不等於 pinned v3.14.0 的假設，mapOptions / imageFeatures 行為可能有差
- Status: ~~proposed~~ killed — 2026-07-07 前提變更：ceph-csi/Rook 不在 PVE 路徑上；版本錨定改由 PVE pre-flight 承接（見 H-033）
- Tier: T3
- Origin: matrix「ceph-csi × partial × 版本錨定」
- Notes: pre-flight：讀 csi provisioner image tag、現有 SC yaml；差異記入 charter 版本錨點。

### H-015: `/sys/block/rbdN/queue/nr_requests` 的讀值在掛 IO scheduler 時不等於 tag 深度（blk-mq 語意），實驗 6 的生效驗證要同時記 scheduler 與 nr_requests
- Status: proposed
- Tier: T1
- Origin: matrix「觀測管線 × lying × 生效驗證讀值」
- Notes: 與 H-011 相關但獨立可驗：T1 讀 blk-mq nr_requests 更新邏輯；T3 對照 map option 前後讀值。

### H-016: 60 秒測程內若 scrub / deep-scrub / balancer / recovery 在背景啟動，該輪數字被污染而無任何標記
- Status: proposed
- Tier: T3
- Origin: matrix「ceph cluster × slow × 無哨兵」
- Notes: harness 規則候選：每輪前後抓 `ceph -s`（scrub/recovery/degraded 計數），有背景活動則該輪標記 tainted 自動重跑；連續 tainted 則中止。

### H-017: host 層漂移（PVE CPU governor / C-states / 同節點其他 Pod 搶 CPU）造成的 run-to-run 變異，大於部分 🟡 旋鈕的真實效果
- Status: proposed
- Tier: T3
- Origin: pre-mortem（「旋鈕結論其實是 governor 切換造成」）
- Notes: pre-flight 記 governor / 節點負載；與 H-007 的噪音帶量測互相印證。

### H-018: 實驗跨多日執行時，pool 填充度 / fragmentation / 叢集狀態漂移使晚期變體與早期 baseline 不可比
- Status: proposed
- Tier: T3
- Origin: pre-mortem
- Notes: harness 規則候選：每個 session 開頭重跑 baseline 哨兵點（2 個 fio pattern），落在既有噪音帶外則整個 session 的比較基準重建。

### H-019: ceph v19 預設 mclock_scheduler 的 QoS profile 對 client ops 設上限，高 QD 實驗（queue_depth 256 等）量到的天花板是 mClock 而非任何虛擬化旋鈕
- Status: proposed
- Tier: T1
- Origin: negative-space（catalog 完全未列 mClock）
- Notes: T1 確認 v19.2.3 的 osd_op_queue 預設與 osd_mclock_profile 預設值；T3 變體（high_client_ops vs balanced）屬 cluster-scope gated。與實驗 7（osd_op_num_shards）同層且交互——shards 改動在 mClock 下的意義要重新敘述。

### H-020: fio 執行中 VMI 重啟 / QEMU OOM / 節點壓力驅逐會讓該輪無效且不被察覺
- Status: proposed
- Tier: T3
- Origin: matrix「VM × crash × 無斷言」
- Notes: harness 每輪斷言 QEMU PID 不變 + VMI ready 且未重啟（restartCount / uptime）。

### H-021: 缺「實驗 0：host 上直接對 /dev/rbdX 跑同一 fio 矩陣」——沒有 ceph 側天花板就無法計算 headroom，也無法把「瓶頸不在你調的那層」操作化
- Status: proposed
- Tier: T3
- Origin: negative-space
- Notes: 實驗 0 同時可做 host 層 `ioengine=libaio` vs `io_uring` 對照，近似回答 KubeVirt 給不到的 io_uring 缺口（H-013 的替代路徑）。這是新實驗，排在所有 VM 實驗之前跑。

### H-022: fio 矩陣沒有 seqread，readahead 整條讀路徑（guest read_ahead_kb、host /sys/block/rbdX/queue/read_ahead_kb）完全未覆蓋
- Status: proposed
- Tier: T3
- Origin: negative-space（矩陣 = randread/randwrite/seqwrite，讀側只有 4k random）
- Notes: 候選：矩陣加 `seqread 1M`；readahead 作為新的精簡協定實驗。

### H-023: 實驗 1 未測 writethrough（guest 看到 WCE off，每寫等同帶 flush）與 writeback；且計畫「buffered + fsync=1 會拉開 none vs writeback」的預測機制上可疑——fsync=1 使每寫都強制 fdatasync，兩種 cache 可能趨同
- Status: proposed
- Tier: T1
- Origin: negative-space + pre-mortem（預測本身可能被違反）
- Notes: T1：追 QEMU virtio-blk WCE 與 cache mode 對應、flush 路徑；重寫該 job 的預測（可能改成 direct=0 無 fsync 對照 + fsync=1 對照兩條）。與 H-001 合併成「cache 三方對照」新實驗 1。

### H-024: 高 QD 變體（queue_depth=256、qd32×numjobs4）的 in-flight 需求會先撞 guest 端 vring 上限（virtio queue-size 預設 256）或 guest nr_requests，量到的是 guest 端瓶頸而非目標旋鈕
- Status: proposed
- Tier: T3
- Origin: matrix「guest virtio × partial × 高 QD 實驗」
- Notes: harness 每輪記 guest 端 aqu-sz 與 host 端 aqu-sz，斷言壓力真的到達被測層。

### H-025: 多變體 PVC + pre-fill（≥8 顆 20G image，3x replication ≈ 480G raw）會把 pool 推向 nearfull，觸發容量告警或影響效能
- Status: proposed
- Tier: T3
- Origin: pre-mortem（capacity-ladder 實驗的教訓）
- Notes: pre-flight 容量檢查（`ceph df`）；每個變體測完即刪 PVC + 確認 rbd rm 完成再開下一個。

### H-026: 在 QEMU v9.1，virtio-blk-pci 的 `num-queues` 預設為 AUTO、realize 時解析成 vCPU 數，因此「不設 queues 的 baseline 是單 virtqueue」的頁面前提錯誤——blockMultiQueue / queues 實驗的 baseline 與變體可能又是同一組設定
- Status: confirmed
- Tier: T1
- Origin: 前提變更研究（2026-07-07，PVE 重規劃時發現）
- Prediction: pinned qemu v9.1 中 num-queues 預設非 1。
- Evidence: qemu/hw/block/virtio-blk.c:1997-1998（`DEFINE_PROP_UINT16("num-queues", ..., VIRTIO_BLK_AUTO_NUM_QUEUES)`）、qemu/hw/virtio/virtio-blk-pci.c:56-58（AUTO → `virtio_pci_optimal_num_queues(0)` = vCPU 數）。
- Artifacts:（待 Gate 3）`rbd-io-tuning-catalog` blockMultiQueue 條目與 `rbd-io-experiment-plan` 實驗 3 敘述需修正；PVE 上實驗 3 改為反向對照（`--args` 強制 `queues=1` vs 預設 auto）。
- Notes: 與 H-001 同型的「baseline 幻覺」。T3 驗證：PVE 預設 VM 的 guest `ls /sys/block/vda/mq/` 應已見多個 hw queue。libvirt 中間層已查證（2026-07-07）：libvirt/src/qemu/qemu_command.c:1692 `"p:num-queues", disk->queues`——`p:` 修飾詞在值為 0（domain XML 未設 queues）時不輸出屬性，QEMU AUTO 預設直通；整條鏈（KubeVirt converter 只在 blockMultiQueue 時設 Queues → libvirt 未設不輸出 → QEMU AUTO=vCPU 數）T1 完整。

### H-027: PVE RBD storage 預設 `krbd=0`（QEMU 內建 librbd driver），與頁面 krbd 軸 datapath 不同；同一顆 image 以 krbd vs librbd 掛載，延遲 / IOPS / QEMU CPU 差異可測
- Status: proposed
- Tier: T3
- Origin: negative-space（前提變更後的軸差異）
- Notes: 這是 PVE 上獨有的頭牌實驗（KubeVirt+ceph-csi 做不到同機切換）。librbd 軸沒有 host `/dev/rbdX` 可觀測——觀測面改用 QMP `query-blockstats` + `rbd perf image iostat`（mgr 端 read-only）。

### H-028: librbd 軸上 QEMU 的 cache 模式直接控制 `rbd_cache`（`cache=none` → `rbd_cache=false`），cache 實驗在兩軸機制不同：krbd 軸調的是 host page cache，librbd 軸調的是 librbd cache
- Status: confirmed
- Tier: T1
- Origin: 前提變更研究（2026-07-07）
- Prediction: qemu block/rbd.c 依 BDRV cache flag 設 rbd_cache。
- Evidence: qemu/block/rbd.c:961-963（`rados_conf_set(*cluster, "rbd_cache", "true"/"false")`）、:1121（以 `!(flags & BDRV_O_NOCACHE)` 傳入）。
- Artifacts:（待 Gate 3）tuning-catalog ⑤ 層「librbd-only 旋鈕」Callout 可補上這條互動；實驗 1' 在 librbd 軸的假設要按此機制寫。
- Notes: per-image `rbd image-meta set conf_rbd_cache` 覆寫與 QEMU 這個設定的優先序，Falsify 階段要先在 T1/T2 釐清再寫預測。

### H-029: 生產叢集背景負載隨時間變動，區塊式執行順序（先全 baseline 再全變體）會把負載漂移誤判為旋鈕效果；A/B 交錯輪次 + 每輪記錄叢集併發負載，可把此誤差壓進噪音帶
- Status: proposed
- Tier: T3
- Origin: pre-mortem（production 版「結論其實是別人的尖峰時段」）
- Notes: harness 設計規則：同一實驗的 baseline 輪與變體輪交錯執行（A/B/A/B…），每輪記 `ceph -s` 的 client io 與 pool stats；重複次數視噪音帶決定（起步 n≥3，生產環境預期要 n≥5）。

### H-030: krbd 在此 PVE cluster 的可用性未知（使用者未調過）——node kernel rbd module、PVE 建 image 的 features 與 krbd 相容性、storage `krbd=1` attach 三關任一失敗，krbd 軸降級為手動 map 或剪除
- Status: proposed
- Tier: T3
- Origin: framing-dialog（使用者：「你可能要先測試能不能用 krbd」）
- Notes: pre-flight 專項：自建 throwaway image → `rbd map` → 讀寫 → `rbd unmap`；再用專屬 storage id（krbd=1）掛一顆盤到測試 VM 驗 attach。全程只碰自有資源。

### H-031: hyperconverged node（VM 與 OSD 同機）上 krbd map 在記憶體壓力下有 client-on-OSD-node 的 writeback deadlock 風險，一旦發生是 node 級 hang、會波及其他 VM——與「其他 VM 不能 down」的邊界直接衝突
- Status: proposed
- Tier: T3
- Origin: persona（SRE 視角）
- Notes: 永不主動注入。guardrail：測試 VM 優先放非 OSD node（若拓樸允許）；fio 工作集與 buffered 工作負載限制記憶體足跡；每輪監控 node 可用記憶體，低於門檻 abort。pre-flight 先確認拓樸（哪些 node 跑 OSD）。

### H-032: 對共用 pool 的高 QD 壓測會推高其他 VM 的 IO 延遲；courtesy guardrail（HEALTH_ERR / 持續 slow_ops / pool nearfull 邊界 → abort）能把影響控制在使用者接受的「慢但不 down」範圍
- Status: proposed
- Tier: T3
- Origin: framing-dialog（使用者邊界：「不要 down 就好，慢可以」）
- Notes: abort 條件參數化、預設開啟；`HEALTH_WARN` 在生產叢集可能常態存在，不能直接當 abort 條件——用「新增的」slow_ops / ERR 與基線差分判斷。

### H-033: PVE 的 VM 預設組合（`aio=io_uring`、cache=none、SCSI controller 與 iothread 的 GUI 預設）與頁面 KubeVirt 軸的預設不同，baseline 定義必須以 pre-flight 讀到的 PVE 實際預設為準
- Status: proposed
- Tier: T3
- Origin: 前提變更（版本/預設錨定從 ceph-csi 轉移到 PVE）
- Notes: pre-flight 產出「PVE 預設 snapshot」：`qm config` 逐欄、pve-qemu / kernel / ceph 版本、storage.cfg。頁面批次 2 增補時所有 PVE 數字都標註此 snapshot。

## 設計備忘（非 hypothesis，Gate 1 一併裁示）

- **結果記錄模板**：現有空表把「5 layout 的 4M/16M/stripe」「6 queue_depth 的 64/128/256」壓成單列，實際需要每變體 × 每 pattern 一列；harness 應輸出結構化 JSON/CSV，再生成 md 表。
- **QMP `query-blockstats`**：datapath 頁明寫可用它切出 QEMU block layer 與 krbd 的各自貢獻，但實驗計畫沒收——建議納入標準 metric。
- **觀測窗同步**：guest 內外時鐘對齊問題以 harness 的相對時間戳解決，不依賴 guest NTP。
- **實驗 2/3 的比較基準**：計畫寫「相對實驗 1 再加」，代表 2/3 的 baseline 是實驗 1 變體而非原始 baseline——harness 的 diff 與報表要明示比較對象。
