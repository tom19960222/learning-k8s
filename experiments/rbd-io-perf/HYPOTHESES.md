# rbd-io-perf — Hypothesis Backlog

## Charter
- Goal: 驗證並修正 `rbd-io-experiment-plan` 的實驗設計（計畫正確性 + 覆蓋完整性），並在 homelab 以受控實驗量出各 🔴/🟡 旋鈕相對 baseline 的真實效果——所有 claim 錨定 pinned source 或 evidence bundle，量不出可信差異的旋鈕誠實標記為「在此環境不可分辨」。
- Scope:
  - in：krbd datapath、五層旋鈕（VMI / QEMU / guest virtio / krbd map options / RBD layout + ceph 端）、實驗 harness 自動化（experiments/ 慣例）、`rbd-io-tuning-catalog` 與 `rbd-io-experiment-plan` 兩頁 MDX 的錯誤修正與缺口補充。
  - out：librbd datapath 全展開、virtio-scsi、網路層調教（jumbo frame / TCP tuning）、跨環境可移植的絕對 benchmark 數字。
- Version anchors: kubevirt v1.5.0 / libvirt v10.10.0 / qemu v9.1.0 / linux 6.8.0-52（Ubuntu HWE）/ ceph v19.2.3 / ceph-csi v3.14.0 / rook v1.19.6（全部 submodule pinned）。
- 環境（待 pre-flight 確認）：.160 單節點 k0s + KubeVirt（待裝，版本對齊 v1.5.0）+ Rook external ceph-csi；cephadm 叢集 3 mon（.166/.167/.164）+ 9 OSD（.169/.171/.174）。媒體與網路使用者稱「SATA SSD + 10G」但未確認 → pre-flight 以 `ceph osd metadata`（rotational）與 `ethtool` 實測。
- Tiers available:
  - T1：pinned submodules（kubevirt / qemu / libvirt / linux / ceph / ceph-csi）。
  - T2：官方文件（docs.ceph.com、kernel.org queue-sysfs、QEMU docs、KubeVirt docs）。
  - T3：homelab 真機。**VM/client 層（VMI / QEMU / krbd map / image layout）= automation-safe**；**cluster 層（osd_op_num_shards、mClock profile）= gated**，須 ok-to-stop → 注入 → 收集 → 立即回退 → HEALTH_OK 才下一步。使用者裁示：保留彈性，可全測也可只測 VM/client 層。

## Gate 1 裁示（2026-07-06）

使用者裁示：**照建議全收**。優先序如下；cluster-scope 項目維持 gated（手動觸發、ok-to-stop → 回退 → HEALTH_OK）。

- **P0（修計畫本身，動筆前必修）**：H-001、H-002、H-005、H-007、H-021、H-022、H-023
- **P1（harness 內建規則與斷言）**：H-006、H-008、H-009、H-010、H-012、H-014、H-015、H-016、H-017、H-018、H-020、H-024、H-025
- **P2（新研究線）**：H-003（baseline 首輪自帶回答）、H-004（rxbounce 觀測 + 變體）、H-011（queue_depth 機制重推）、H-013（io_uring）、H-019（mClock，gated）
- **io_uring 路線**：兩條都做——先在實驗 0 用 host 層 fio `ioengine=libaio` vs `io_uring` 對照；若差異顯著，第二階段再寫 `OnDefineDomain` hook sidecar 驗證 QEMU 層。

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
- Status: proposed
- Tier: T1
- Origin: matrix「KubeVirt 控制面 × stale × 變體切換」
- Notes: 決定 harness 的變體切換機制：建議每個變體一份完整 VMI manifest，delete → wait gone → apply → wait ready。

### H-013: io_uring 變體無法從 VMI 欄位設定，virsh edit 會被 virt-launcher 重生覆蓋；可行路徑是 KubeVirt hook sidecar（`OnDefineDomain`）改 domain XML，或以 host 層 fio `ioengine=io_uring` 對照近似
- Status: proposed
- Tier: T1
- Origin: matrix「libvirt/QEMU 層 × stale × io_uring 變體」
- Notes: v1.5.0 pkg/hooks 存在 OnDefineDomain（已驗）。sidecar 是正路但工程量大；host 層 fio 對照（見 H-021）是務實替代，兩者取捨進 Gate 1。

### H-014: .160 Rook external 部署的 ceph-csi 實際版本與 StorageClass 預設值不等於 pinned v3.14.0 的假設，mapOptions / imageFeatures 行為可能有差
- Status: proposed
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

## 設計備忘（非 hypothesis，Gate 1 一併裁示）

- **結果記錄模板**：現有空表把「5 layout 的 4M/16M/stripe」「6 queue_depth 的 64/128/256」壓成單列，實際需要每變體 × 每 pattern 一列；harness 應輸出結構化 JSON/CSV，再生成 md 表。
- **QMP `query-blockstats`**：datapath 頁明寫可用它切出 QEMU block layer 與 krbd 的各自貢獻，但實驗計畫沒收——建議納入標準 metric。
- **觀測窗同步**：guest 內外時鐘對齊問題以 harness 的相對時間戳解決，不依賴 guest NTP。
- **實驗 2/3 的比較基準**：計畫寫「相對實驗 1 再加」，代表 2/3 的 baseline 是實驗 1 變體而非原始 baseline——harness 的 diff 與報表要明示比較對象。
