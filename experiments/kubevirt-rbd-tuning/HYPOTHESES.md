# kubevirt-rbd-tuning — Hypothesis Backlog

## Charter（v3，2026-07-07）

> 系列脈絡：v1（KubeVirt 軸，被三個 baseline 幻覺推翻）→ v2（PVE 生產叢集軸，`experiments/rbd-io-perf/`，只動 VM 參數不動 ceph）→ **v3（本份）：回到 KubeVirt 軸，專屬 Azure 實驗環境，全 stack 可調，生產穩定性優先**。v2 的 confirmed 事實見文末「繼承錨點」。

- Goal: 在專屬 Azure 實驗環境（獨立 cephadm Ceph cluster + k8s external ceph + KubeVirt）量測 KubeVirt / KVM / QEMU / krbd / Ceph 全 stack 旋鈕對 VM disk IO 的實際效果，並以生產關鍵系統的優先序評價——每個旋鈕產出三個維度的結論：(a) 正常態 latency 與 throughput 效果（latency 優先，但正常態不犧牲 throughput）、(b) degraded 態行為（p99/p99.9 可控、不雪崩、不卡死；此時 throughput 允許下降）、(c) **生產線上可調性分類**（runtime 可改／要重啟 VM／要 live migration／要重建 PVC／建置期定死，含不相容風險）。所有 claim 錨定 pinned source 或 evidence bundle；量不出可信差異的旋鈕誠實標記 indistinguishable。
- Scope:
  - in：五層旋鈕（① KubeVirt VMI、② libvirt/QEMU、③ guest virtio/block、④ host krbd map options + sysfs、⑤ Ceph cluster/pool/image——**含 OSD daemon 層與 mClock，本輪專屬叢集全開**）；故障注入實驗（OSD down、OSD node down、recovery/backfill、slow OSD、min_size 不滿、mon quorum 邊界）；線上可調性驗證（VMI immutability、live migration 套用路徑、ceph config set 生效性、mapOptions 對既有 PV 的效力）；disk bus 選擇（virtio-blk vs virtio-scsi）作為穩定性旋鈕；Azure 環境規格書 + 建置驗收 preflight；harness（`experiments/kubevirt-rbd-tuning/`）；新 MDX 專題頁。
  - out：librbd / rbd-nbd 軸（生產鏈是 ceph-csi + krbd；librbd 僅在結論中引用 v2 E-04 的對照數字）；CephFS / NFS / 其他 storage backend；Windows guest；跨環境絕對數字移植（Azure 量到的是相對排序與機制驗證，絕對值不代表生產）；Azure 本身的產品評測（VM size / disk tier 只為壓低噪音服務）。
- 使用者裁示（framing dialog，2026-07-07）：
  - attach 路徑 = **ceph-csi + krbd**（PVC volumeMode=Block → rbd map → /dev/rbdX → virt-launcher/QEMU），KubeVirt 標準鏈。
  - 版本錨點 = **kubevirt v1.5.0**（維持 pinned submodule，不升 v1.8.2）。
  - 穩定的操作型定義 = degraded 不雪崩 + p99/p99.9 可控 + **latency 盡最大努力維持最小值；throughput 只有在 degraded 時才允許變小**（正常態 latency 與 throughput 都要顧）。
  - 線上可調性 = 不確定，**正是研究重點**（→ H-001/H-002/H-003）。
  - IO 卡死情境 = 知道會 hang，**要量化邊界**：一張「degraded 情境 × hang 時長 × guest 可見症狀」實測對照表（→ H-005/H-006 與故障注入實驗群）。
  - Ceph 側旋鈕 = **納入，全 stack 都可調**（專屬叢集）；每個 ceph 旋鈕同樣附生產線上可調性分析。
- Version anchors: pinned submodules——kubevirt v1.5.0 / qemu v9.1.0 / libvirt v10.10.0 / linux 6.8.0-52（krbd T1 基準）/ ceph v19.2.3 / ceph-csi v3.14.0 / kubernetes v1.36.0。**Azure 實機的 kernel / qemu / kubevirt 部署版本由 preflight 記錄**，與 pinned 的差異在結論誠實標註。
- 環境（使用者定案的形狀，細部規格由實驗計畫開規格書）：獨立 Ceph cluster（cephadm）＝ 3× mon VM + 3× OSD node VM（每台 3 個 OSD daemon，**OSD 用 local NVMe**，共 9 OSD）；k8s cluster 以 **external ceph** 接入（與使用者生產拓樸同型）；KubeVirt VM 跑在 k8s node 上（Azure nested virtualization）。規格書需求：k8s worker ≥2 台（live migration 實驗的硬前提）、local NVMe 重開即清空（實驗腳本必須能全自動重建 OSD）。
- Tiers available:
  - T1：pinned submodules（kubevirt / qemu / libvirt / linux / ceph / ceph-csi / kubernetes）。
  - T2：官方文件（kubevirt.io、docs.ceph.com、QEMU docs、kernel.org）。
  - T3：專屬 Azure 環境——**完全可破壞**（故障注入、OSD 殺掉、網路分區全部允許；一切可用重建回復）；約束是成本與重建時間，不是安全性。Gate 2 僅適用於「會讓實驗環境本身要整個重建、成本大」的操作。

## Hypotheses

### H-001: 在 KubeVirt v1.5.0，改 VM 物件 template 的 disk driver 欄位（cache / io / blockMultiQueue / dedicatedIOThread）不會被 live migration 套用——running VMI 的 spec 不會跟著變，VM 只會被標 RestartRequired，唯一套用路徑是 stop/start（有 downtime）
- Status: confirmed（T1+T3：E-50 2026-07-08 實錘——patch 後 RestartRequired 出現、migration ×2 cmdline 不變；revert 不清條件。bundle results/E-42/20260708-063540）
- Tier: T1
- Origin: framing-dialog（使用者答「不確定——這正是要研究的重點」）
- Prediction: 改 template disk 欄位後 VM 出現 `RestartRequired` condition；後續 migration 不改 QEMU cmdline。
- Evidence: kubevirt/pkg/virt-config/virt-config.go:93（預設 `VMRolloutStrategyStage`＝壓到下次重開）；types.go:2621-2624（Stage/LiveUpdate 語意）；pkg/virt-controller/watch/vm/vm.go:2838-2869（`validLiveUpdateDisks`：非 hotplug volume 的既有 disk 一旦 DeepEqual 不等即非 live-updatable）→ vm.go:2940-2942（`setRestartRequired("a non-live-updatable field was changed…")`）。LiveUpdate 白名單只有 volumes/disks(hotplug)、CPU sockets、memory guest、nodeSelector/affinity/tolerations（vm.go:2901-2924）。
- Artifacts:（待 Gate 3）新頁「線上可調性」一節；E-50 真機驗證。
- Notes: 生產含義：VMI 層旋鈕全部歸類「需 VM 重啟」；live migration 不是 disk 旋鈕的零停機套用工具（但仍是節點維運工具，見 H-019/E-42）。

### H-002: StorageClass 的 `mapOptions` 只在 PV 建立時固化；對既有 PVC，事後改 StorageClass 不會改變下次 map 的 options，也沒有不重建 PVC 的線上修改路徑——krbd 層旋鈕（queue_depth / alloc_size / rxbounce）對存量磁碟實質上「建置期定死」
- Status: confirmed（T1+T3：E-51 2026-07-09 閉環——patch PV volumeAttributes 被 API 拒（source immutable）→ mapOptions 無 escape hatch，krbd 層旋鈕對存量盤確定建置期定死）
- Tier: T1
- Origin: framing-dialog（線上可調性軸）
- Prediction: NodeStage 從 volume context 讀 mapOptions；SC 參數只在 provision 時進 PV。
- Evidence: ceph-csi/internal/rbd/rbd_attach.go:314-318（`req.GetVolumeContext()["mapOptions"]`——attach 時從 PV `volumeAttributes` 讀）；examples/rbd/storageclass.yaml:61-70（mapOptions 是 SC parameter，provision 時由 external-provisioner 寫進 PV volume context）。例外：read-affinity（`read_from_replica`+`crush_location`）由 CSI configmap 在每次 map 時重讀（internal/util/read_affinity.go:47-76、nodeserver.go:283-292）——這組是唯一 runtime 可改的 krbd 選項。
- Artifacts:（待 Gate 3）新頁可調性分類表；E-51 驗證「kubectl edit pv volumeAttributes + 完整 unstage/restage」這條非官方路徑是否實際生效。
- Notes: 生產含義：queue_depth 等 map options 要在 StorageClass 設計期定案；`osd_request_timeout`（H-032）也是 map option，同受此限。

### H-003: Ceph 側旋鈕的線上可調性兩極：`osd_mclock_profile` 等 mClock 參數 runtime `ceph config set` 即生效不需重啟；`osd_op_num_shards` 是 startup 參數必須 rolling restart OSD（生產有 degraded 視窗）；pool 的 `pg_num` 可線上調但會觸發 backfill（本身就是一次 degraded 事件）
- Status: confirmed（T1+T3：runtime 側 E-21 RSS 佐證 `ceph config set osd_memory_target` 行為級生效（=E-52 證據）；startup 側 E-22 實錄 rolling restart 9 OSD 的 client 代價 p99→1360ms）
- Tier: T1
- Origin: framing-dialog（Ceph 納入全 stack 後的可調性映射）
- Prediction: options yaml 的 flags 呈兩極分佈；mClock 有 runtime conf 監聽。
- Evidence: ceph/src/common/options/osd.yaml.in——`osd_op_num_shards`、`osd_op_num_threads_per_shard` flags=`[startup]`；`osd_scrub_sleep`、`osd_max_backfills`、`osd_recovery_max_active` flags=`[runtime]`；`osd_mclock_profile` 無 startup flag 且 src/osd/scheduler/mClockScheduler.cc:580-596 的 `handle_conf_change` 顯式監聽並即時重算；global.yaml.in:3818-3844 `osd_memory_target` flags=`[runtime]`。
- Artifacts:（待 Gate 3）新頁 Ceph 層每個旋鈕的可調性欄；E-52 用可觀測 client 行為（非 config get）驗證 runtime 生效。
- Notes: 注意 mClock 下 `osd_max_backfills`/`osd_recovery_max_active` 被 mClock 接管，需 `osd_mclock_override_recovery_settings=true` 才可手調——E-39 設計要計入。

### H-004: `cache=writeback` 相對 `cache=none` 拉高平均 throughput，但 p99.9 顯著惡化（flush 聚積 + 突發回寫），且 host 記憶體壓力下有整段 stall 風險——以本 charter 的 latency-first 判準，writeback 在生產是負分
- Status: confirmed（E-10 2026-07-08：rw-qd8 p999 +2064%、sw-1m max 1.5~3.5s stall；bundle results/E-10/20260708-015243）
- Tier: T3
- Origin: framing-dialog（穩定定義：p99/p99.9 可控）
- Prediction:
- Evidence:
- Artifacts:
- Notes: v2 E-05 在 librbd 軸量過 writeback（rbd_cache 機制）；krbd 軸的 writeback 是 host page cache，機制不同、要重量。fio 矩陣必須收完整 latency 百分位（p50/p90/p99/p99.9/max）。

### H-005: degraded 情境的 guest 可見症狀可分級量化：單 OSD down（size=3 pool 仍滿足 min_size）→ p99 尖峰僅在 peering 視窗（秒級）、IO 不中斷；OSD node down（3 OSD）→ 同上但尖峰更寬；min_size 不滿 → IO 無限期 hang，guest 在 `hung_task_timeout_secs`（預設 120s）出現 jbd2 hung task 警告——「慢」與「卡死」的邊界可以畫成一張表
- Status: confirmed＋細化（E-30/E-31/E-36/E-38 拼出邊界表）：單 OSD down 未 out=無感、OSD node down（3 OSD）同樣輕（min_size 撐住、僅 38ms peering 尖峰）——「失效顆數不是重點，min_size 才是」；min_size 不滿=無限 hang（302.8s 直到恢復）；真正的傷害視窗在 auto-out 後的 backfill（rr-qd1 ×24，→H-033）
- Tier: T3
- Origin: framing-dialog（使用者：「知道但想量化邊界」）
- Prediction:
- Evidence:
- Artifacts:
- Notes: 這是故障注入實驗群的骨幹（degraded matrix）。每個情境要收：注入時刻、client p99 時間序列、guest dmesg、恢復時刻、恢復後是否自癒。Azure 專屬叢集可以安全做 min_size 不滿的情境（v2 PVE 絕不可能）。

### H-006: disk bus 選 virtio-scsi（而非 virtio-blk）時，SCSI 層 per-command timeout + error handler 會把「Ceph 卡死 → guest 無限 hang」轉成「30s 後 guest 收到 IO error」——bus 選擇是把不可控卡死轉成可控失敗的穩定性旋鈕
- Status: **violated**（T1——兩種 bus 都永不逾時；有界等待的真旋鈕在 libceph 層，見 H-032）
- Tier: T1
- Origin: framing-dialog（IO 卡死情境的 pre-mortem 延伸）
- Prediction: virtio-blk 無 timeout（對）；virtio-scsi 30s 後 abort → IO error（**錯**）。
- Evidence: virtio-blk 半邊如預期——linux/drivers/block/virtio_blk.c:1239-1246 `virtio_mq_ops` 無 `.timeout`，block/blk-mq.c `blk_mq_rq_timed_out` 在無 handler 時僅 `blk_add_timer(req)` 無限重設。virtio-scsi 半邊被推翻——drivers/scsi/virtio_scsi.c:786-789 `virtscsi_eh_timed_out` **無條件回 `SCSI_EH_RESET_TIMER`**，scsi_error.c:335+ 的 `scsi_timeout` 收到即回 `BLK_EH_RESET_TIMER` 重設計時器，永不進 abort/error handler。sd 層的 30s timeout 形同虛設。
- Artifacts:（待 Gate 3）新頁「卡死行為」一節要明寫這條反直覺結論；E-11 保留為純效能對照（bus 的穩定性理由取消）。
- Notes: violated 的價值：網路上常見「換 virtio-scsi 就有 timeout」的說法在 pinned kernel 6.8 不成立。有界等待請看 H-032。

### H-007: recovery/backfill 進行中，`osd_mclock_profile=high_client_ops` 相對預設 `balanced` 能把 client p99 惡化幅度壓低（機制：mClock 給 client ops 更高保留額度），代價是 recovery 完成時間拉長——這是「degraded 時保 latency、犧牲 throughput／恢復速度」最直接的 Ceph 側旋鈕
- Status: violated（本環境 indistinguishable，E-39）——backfill 窗兩 profile 無差（OSD headroom 夠大，mClock 沒有要仲裁的競爭）；真正傷害來源是熱物件 recovery 債（→H-033），profile 旋鈕救不到
- Tier: T3
- Origin: framing-dialog（degraded 不雪崩 + Ceph 全 stack 納入）
- Prediction:
- Evidence:
- Artifacts:
- Notes: v2 charter 把 mClock 全剪（生產不可碰），本輪是頭牌 Ceph 實驗。注入方式：殺一顆 OSD 等 backfill 開始，A/B 對照兩個 profile 下的 client p99 時間序列。runtime 可調性連動 H-003。

### H-008: Azure 環境的量測噪音帶（同設定重複輪 CoV）大於 v2 PVE 實機（4k randread qd1 CoV 23%），nested virt + 共享宿主 + Azure 網路抖動是主因——所有後續實驗的判準（差異 > 噪音帶）必須用 Azure 實測的噪音帶，不能沿用 PVE 數字
- Status: violated（E-01 2026-07-08）——Azure 專屬叢集噪音比 PVE 生產**小一個數量級**（IOPS CoV 0.4–2.0% vs 23%）；nested virt 稅存在但穩定；判準帶改用 band.json 實測值
- Tier: T3
- Origin: framing-dialog（前置研究驚訝點：Azure 稅）
- Prediction:
- Evidence:
- Artifacts:
- Notes: baseline 實驗（E-0x）第一個要回答的問題。若 CoV 大到蓋掉多數旋鈕效果，實驗設計要升級（n≥5、更長 runtime、A/B 交錯粒度更細），或誠實縮小可回答的問題集。連帶要量 Azure local NVMe 的原生能力與 VM size 的 IOPS cap（規格書要選 cap 遠高於 Ceph 需求的 size）。

### H-009: krbd `queue_depth` 拉高（128→256+）提升高並行 throughput，但同時拉高 qd1 與中低並行的 p99（更深的 host 端排隊）——以 latency-first 判準，正確設定是「夠用就好」而非「越大越好」，且最佳值依 workload 並行度而異
- Status: **部分 violated（E-19 2026-07-09）**：高並行 throughput 提升成立（+10~21%），但「拉高 qd1 p99」不成立——qd1 零代價、高並行 p99 反而改善。queue_depth 是 cap，低並行不受更大 cap 影響 → 純加分。bundle results/E-19
- Tier: T3
- Origin: framing-dialog（latency 盡最大努力維持最小值）
- Prediction:
- Evidence:
- Artifacts:
- Notes: v2 的 E-10 只設計了 throughput 視角；本輪同一實驗要加 p99 視角與低並行對照。與 H-002（此旋鈕對存量盤定死）連動——若真的定死，結論要寫進「建置期 checklist」而非「調教手冊」。

### H-010: 對 guest 檔案系統掛載加 IO 錯誤處理設定（ext4 `errors=` / `data=` 模式）與 guest `hung_task` 相關 sysctl，不改變 hang 的發生，但決定 hang 解除後 guest 是自癒還是 remount read-only——degraded 恢復後的「二次傷害」由 guest 端設定決定
- Status: not-run（P3）＋附帶觀察：E-36/E-38/E-35 的 hang 解除後 IO 都直接成功完成、無 remount read-only（O_DIRECT 探針情境，未觸發 jbd2 error 路徑）；ext4 errors=/data= 變體未測
- Tier: T3
- Origin: framing-dialog（degraded 症狀對照表的 guest 端維度）
- Prediction:
- Evidence:
- Artifacts:
- Notes: 使用者的雪崩定義包含「guest 檔案系統變 read-only」。故障注入實驗每輪要記錄恢復後 guest mount 狀態與是否需要人工介入。

### H-011: 單顆 OSD 進入 gray failure（活著但每 op 加 ~500ms，未 crash）時，凡 primary 落在該 OSD 的 PG 其 client IO 全面變慢、VM 整體 p99 顯著惡化，但 `ceph -s` 維持 HEALTH_OK、mon 不會標它 down——「慢」比「死」更傷且無告警
- Status: confirmed（E-32 2026-07-09，注入改為 host 級 tc netem 50ms——cephadm/podman 下 per-OSD cgroup 限速不可行）：寫 ×40、讀 ×19，`ceph -s` 全程 HEALTH_OK、無任何告警——gray failure 是實測最傷且完全無信號的情境；size=3 per-host replica 下一台慢 host 毒化全部寫入
- Tier: T3
- Origin: matrix「osd × slow × lying」
- Notes: 注入：OSD node 上 cgroup io.latency 或 tc netem 單獨對一顆 OSD 的行程／連線。要收 `ceph -s`、`osd perf`（commit/apply latency 是否露餡）與 client p99 時間序列。與 accumulated class「observer lying」同型：判斷「ceph 健康信號能不能看見 gray failure」本身就是結論的一部分。

### H-012: client→OSD 網路注入 0.1–0.5% 封包遺失時，平均 latency 幾乎不動但 p99.9 爆炸成長（TCP 重傳 RTO 200ms 級 + krbd 每 OSD 單一 TCP 連線的 head-of-line blocking）——網路品質對尾延遲的影響大於任何 QEMU 旋鈕
- Status: violated（E-33 2026-07-09）——0.1%/0.5% loss 對 client 幾乎無影響（最壞 1.1×）：低 RTT 下 TCP 快速重傳吸收、不觸發 RTO。跨實驗洞察：Ceph-on-TCP 對「延遲」（E-32 ×40）遠比「丟包」敏感 → 網路監控重心放 RTT 不是 loss
- Tier: T3
- Origin: matrix「network × partial × slow」
- Notes: tc netem loss 注入在 k8s node 出口（只對 ceph public 網段）。若 confirmed，新頁要把「先確認網路品質再調參」寫成前置 checklist 第一條。

### H-013: OSD flapping（反覆 down/up 循環）造成的週期性 peering 風暴，對 client p99 的傷害大於同一顆 OSD 乾淨地 down 掉一次；`noout`/`mon_osd_down_out_interval` 的設定決定 flapping 期間的重複 backfill 量
- Status: confirmed（E-34 2026-07-09）：flapping 的週期性 peering 風暴使 p999 至 1146ms；**noout 砍 p999 71%（一半以上）**——發現 flapping 先手動 noout/out 的維運結論成立
- Tier: T3
- Origin: matrix「osd × partial（間歇）」
- Notes: 注入：systemd 循環 stop/start 單顆 OSD（週期 60–120s）。這是 degraded matrix 的一格；維運面結論（發現 flapping 先手動 out 而不是等自動處理）比數字本身重要。

### H-014: mon 掉 1/3 對 client IO 無可測影響；mon quorum 全失（2/3 down）時穩態 IO 短期照常（client 不需要 mon 做穩態 IO），但此時再疊加任何 OSD 故障，client 拿不到新 osdmap，IO 對死 OSD 無限期 hang 且叢集無法自癒——複合故障的傷害遠大於兩個單一故障之和
- Status: confirmed（E-35 2026-07-09）：STAGE2 quorum 失後穩態 IO 照跑（client 不需 mon）；STAGE3 疊加 osd.3 kill → 寫入 D-state 無限 hang、無自癒（client 拿不到新 osdmap）——複合故障傷害遠大於單故障之和，恢復順序硬約束＝先 mon 後 OSD。附 8h 滯留事故與外部 watchdog 鐵律（見 EVIDENCE E-35）
- Tier: T3
- Origin: matrix「mon × crash」+ pre-mortem（複合鏈）
- Notes: 兩段實驗：先驗 quorum 失去後穩態 IO 能撐多久（osdmap 訂閱、auth ticket 過期邊界），再疊 OSD kill 驗複合。此情境 `ceph -s` 本身連不上——觀測面也一起死，符合 pre-mortem「觀測路徑參與失效」要求。

### H-015: `cache=writeback` 下 QEMU 行程被 kill（模擬 OOM/crash）會遺失 guest 已收到完成回報的寫入（host page cache 未回寫），fio + verify 可實測到資料不一致；`cache=none` 同注入無遺失——crash consistency 是 cache mode 的隱藏代價，生產選型必須計入
- Status: 部分 violated＋機制修正（E-40 2026-07-09）：**光 kill QEMU/pod 不丟**（host page cache 存活 + rbd unmap flush）——本假說的注入手法測不到遺失；**host 硬斷才丟**：writeback 丟最後 ~6s acked 寫入（≈335 blocks），cache=none 對照 0 遺失。crash consistency 代價 confirmed 但兌現條件是 node 級災難
- Tier: T3
- Origin: matrix「virt-launcher/QEMU × crash」
- Notes: 用 fio `--verify=crc32c` 寫入中 `kill -9` QEMU，重啟後 verify。這把 H-004（writeback 尾延遲）從效能問題升級成 correctness 問題。

### H-016: ceph-csi nodeplugin、virt-handler、kubelet 任一 crash 對運行中 VM 的 IO 完全無影響（krbd map 是 kernel 狀態、QEMU 行程獨立於控制面），只有新 attach/detach/migration 動作被阻斷——控制面與資料面的故障域分離可實測驗證
- Status: not-run（P3）——T1 機制推論維持（krbd map 是 kernel 狀態、QEMU 行程獨立於控制面）；E-41 附帶佐證：node 硬斷後 VMI 卡 phantom Running 期間 guest 早已死於 node 層，控制面 daemon 單獨 crash 的資料面隔離未單獨注入
- Tier: T3
- Origin: matrix「控制面 daemon × crash」
- Notes: 生產價值：控制面升級／重啟不需要維運視窗。逐一 kill + fio 全程跑 + 斷言無 p99 擾動。

### H-017: k8s node 硬斷（模擬 Azure VM 強制關機）後，VM 重新排程到他節點的總停機時間由一串 timeout 疊加決定——node NotReady 判定 + pod 強制刪除 + krbd watcher 逾時（預設 30s）+ csi attach——其中 ceph 側 watcher/exclusive-lock 是可調的顯著項，量化每段占比後可以給出「VM failover 時間預算表」
- Status: violated——比預測更糟（E-41 2026-07-09）：預設**沒有可預期的 failover**。writeback 輪 VMI 卡 dead-node phantom Running 11min+（force-delete 被 stuck finalizer 擋）；none 輪 pod eviction（~300s NoExecute）有觸發重排——auto-failover「可能發生但慢且不可靠」。時間預算表無從談起，前提（會 failover）不成立；生產必須加 NodeHealthCheck/machine-health-check
- Tier: T3
- Origin: matrix「node × crash × stale（鎖持有者已死但鎖還在）」
- Notes: 需要 k8s worker ≥2 + RWX block PVC 或對應 eviction 設定。這是使用者生產最會遇到的完整故障劇本；產出是時間預算表 + 各段的旋鈕。

### H-018: virt-launcher pod 帶 CPU limit（非 Guaranteed QoS）時，CFS quota throttling（100ms 週期）會把 guest IO p99.9 拉高一個數量級以上（IO completion 執行緒被 throttle 整段凍結）；Guaranteed QoS 或 `dedicatedCpuPlacement` 消除此效應——k8s 資源設定是隱形的 IO 尾延遲旋鈕，舊 catalog 完全沒有這一層
- Status: **confirmed（E-15 2026-07-09，並修正判準）**：limit=2<4vCPU 使 p99 7.6→55.8ms(×7.4)、IOPS 砍半、p50 不變。關鍵修正：**兩變體皆 Guaranteed QoS**，真正門檻是 limit≥vCPU 數而非 QoS class。bundle results/E-15
- Tier: T3
- Origin: negative-space（catalog 的 knob 空間缺 CPU/cgroup 層）
- Notes: 注入：guest 內 CPU 忙 + IO 並行，對照 limit 有無。KubeVirt 端旋鈕：resources、dedicatedCpuPlacement、isolateEmulatorThread。線上可調性：改 QoS 要重建 pod（= VM 重啟或 migration）。

### H-019: 對高 IO 負載中的 VM 做 live migration，切換瞬間 IO 暫停時間 ≤ migration downtime 設定（預設 ~150ms 級），p99 出現單次尖峰但無 IO 錯誤、無 fs read-only——live migration 作為「零停機套用旋鈕」與「節點維運」工具的 IO 代價可量化且可控
- Status: confirmed（E-42 2026-07-08）：負載中 migration IO 零中斷、最差 1s 窗 8ms——migration 作為節點維運工具的 IO 代價可放心；但不是旋鈕套用工具（H-001）
- Tier: T3
- Origin: negative-space（維運動作本身當作擾動源來量）
- Notes: 與 H-001 連動：若 H-001 confirmed（migration 不能套用 disk 旋鈕），本實驗仍然值得做——維運（kernel 升級、節點汰換）永遠需要 migration，它的 IO 影響是生產 SLO 的一部分。

### H-020: `cache=writeback`（非 direct cache）在 libvirt/QEMU 層會被判定為 unsafe migration 而阻擋 live migration（shared storage 上 host page cache 不一致風險）——writeback 附帶「失去 live migration 能力」的不相容
- Status: **violated**（T1——現代 QEMU 上 writeback 不會擋 migration）
- Tier: T1
- Origin: pre-mortem（複合：旋鈕 × 維運能力的不相容）
- Prediction: libvirt `qemuMigrationSrcIsSafe` 對 cache≠none/directsync 報 `VIR_ERR_MIGRATE_UNSAFE`（**錯**——漏了 drop-cache capability 分支）。
- Evidence: libvirt/src/qemu/qemu_migration.c:1691-1777——cache≠none/directsync 時先檢查 `QEMU_CAPS_MIGRATION_FILE_DROP_CACHE`（qemu_capabilities.c:1558，探測 `blockdev-add/arg-type/+file/drop-cache`，QEMU v9.1 具備）→ 有此能力即視為安全放行。KubeVirt 端：virt-handler vm.go:2484-2551 `checkVolumesForMigration` 只檢查 PVC access mode（RWX），完全不看 cache；virt-launcher live-migration-source.go:99-107 預設不帶 `MIGRATE_UNSAFE`（僅 `unsafeMigrationOverride` 顯式開才帶）。
- Artifacts:（待 Gate 3）新頁可調性/不相容表修正：writeback 的代價是 H-004（尾延遲）+ H-015（crash consistency），**不含**失去 migration；E-42 可加一輪 writeback 變體實測 migration 中的資料一致性（fio verify 跨 migration）。
- Notes: 老 QEMU（<4.0 無 drop-cache）才會被擋——寫頁面時註明版本邊界，避免讀者拿舊經驗反駁。

### H-021: deep-scrub 與 client 負載重疊時 client p99 顯著上升；`osd_scrub_sleep` / `osd_scrub_load_threshold` / scrub 時窗設定（全部 runtime 可調）能把影響壓進噪音帶——scrub 是生產最常見的「自己人造成的 degraded」，卻不在任何舊實驗裡
- Status: violated（本環境，E-37 2026-07-08）：deep-scrub 對 client 零可測擾動（NVMe headroom 吸收）——「scrub 傷 client」在 headroom 充足的環境不成立；osd_scrub_sleep 0 vs 0.1 亦 indistinguishable
- Tier: T3
- Origin: negative-space（degraded 情境空間：scrub/deep-scrub UNCOVERED）
- Notes: 注入：`ceph pg deep-scrub` 手動觸發對測試 pool 的 PG。連動 accumulated class「signal co-occurrence」：記錄 scrub 期間哪些健康碼／metric 同時動。

### H-022: pool 用量觸及 `full_ratio` 時 client 寫入不是收到 ENOSPC 錯誤而是被無限期阻擋（hang），guest 症狀與 min_size 不滿同型（jbd2 hung task）；`nearfull_ratio` 到 `full_ratio` 之間是唯一的告警視窗——容量耗盡是穩定性邊界而非單純容量問題
- Status: confirmed（E-38 2026-07-09）：full 下寫入 hang 96s **非 EIO**、恢復後該筆寫入成功完成（與 min_size hang 同型）；nearfull 只告警不擋寫——nearfull 是必須行動的告警線。踩雷：full_ratio 注入要三個 ratio 依序設否則被拒
- Tier: T3
- Origin: negative-space（degraded 情境空間：full/nearfull UNCOVERED）
- Notes: 小 pool 快速填滿即可注入，成本低。與 H-005 的症狀表合併成同一張「degraded 情境 × guest 症狀」矩陣的兩列。

### H-023: `osd_memory_target`（runtime 可調）向上調整可測地改善讀取 p99（BlueStore cache 命中率上升），是少數「不停機、立即生效、單調有利於 latency」的 Ceph 側旋鈕；效果量級與 working set 是否放得進 cache 強相關
- Status: indistinguishable（本環境，E-21 2026-07-08）：4G vs 8G 全 pattern 帶內——機制條件未觸發（4G×3 OSD 聚合 cache 已涵蓋 16G 測試盤熱資料，8G 無多餘命中可拿）；RSS 差異證明旋鈕本身生效。收益只在 working set > cache 的 regime，本環境誠實標記量不到
- Tier: T3
- Origin: negative-space（Ceph runtime 可調 knob 清單比對）
- Notes: Azure OSD node 記憶體要在規格書預留調整空間。若 indistinguishable（working set 太小全命中／太大全不命中）要誠實標記並說明邊界條件。

### H-024: 同 workload 下 pool `size=3` 相對 `size=2` 的寫入 latency 代價可量化（多一副本的並行寫 + 等待最慢者），但結論固定為「生產維持 size=3，代價已知」——量化 replication tax 是為了讓人死心，不是為了推薦降副本
- Status: not-run（P3，使用者未排）——結論本來就固定「生產維持 size=3」；E-32 附帶提供了 size=3 的反面代價實測（per-host replica 使慢 host 毒化全部寫入），replication tax 的量化留未來
- Tier: T3
- Origin: negative-space（pool 層 knob）
- Notes: 低優先；價值在新頁的「哪些 knob 看起來誘人但不准動」一節。

### H-025: 在 KubeVirt v1.5.0 的 virt-launcher pod 內可以用 `virsh qemu-monitor-command` 取得 QMP `query-blockstats`（read-only），提供 librbd/QEMU block layer 邊界的觀測數字；此路徑在 harness 全程可自動化且對 VM 無擾動
- Status: synthesized（E-03 2026-07-08）：三邊界觀測（guest iostat / host rbdX iostat / ceph osd perf）實測互洽、差分可歸因——krbd 軸不需 QMP blockstats（host 有 rbdX block device 可直接量）；QMP 路徑留給 librbd 軸（out of scope）
- Tier: T3
- Origin: matrix「觀測路徑 × 是否可達」
- Notes: 觀測面自身的驗證——harness 的三邊界量測（guest iostat / host rbdX iostat / QMP blockstats）每條都要先證明拿得到、值可信。

### H-026: fio 60 秒聚合報表（含 p99）會完全遮蔽亞秒級的整段 stall（0.5s stall 只占 0.8% 樣本，落在 p99 之下）——不收 per-window latency log 就宣稱「不卡死」是站不住的；harness 必須收 fio `--write_lat_log` + max latency 並對 stall 設獨立斷言
- Status: synthesized（已固化為 harness 規則並實戰驗證）：每輪收 max/p999 + degraded 用時間序列；E-10 的 wb 1.5~3.5s stall、E-22 的 rolling p99 1360ms 正是靠 max/p999 抓到（60s 聚合 p99 均看不見）
- Tier: T3
- Origin: persona（adversary：讓聚合數字說謊）+ accumulated class「observer lying」
- Notes: harness 規則候選：每輪斷言 `max_lat < stall_threshold`，degraded 實驗改用時間序列圖而非單一百分位。

### H-027: qd1 低 IOPS 情境下 60 秒的樣本數不足以支撐 p99.9 估計（100 IOPS × 60s = 6000 樣本，p99.9 只由 6 個樣本決定，輪間跳動巨大）——p99.9 的宣稱必須附樣本數門檻（≥100k 樣本），不足就只報 p99 並明說
- Status: synthesized（已固化為 harness 規則）：qd1 低樣本情境只報 p99 不報 p99.9；p999 宣稱僅用於高並行 pattern（樣本數足）
- Tier: T3
- Origin: persona(統計學家)
- Notes: 直接影響 fio 矩陣的 runtime 設計：高百分位需求 → 拉長 runtime 或提高並行，兩者都改變量測條件——要在計畫裡明寫取捨。

### H-028: 變體間重建 RBD image 會改變 PG/primary OSD 分佈，A/B 差異可能是 placement 差異而非旋鈕效果——同一實驗內必須沿用同一顆 image（或每輪記錄 `osd map` 佐證分佈等價），這是 v2 沒有的新 confound（v2 同 pool 兩顆 OSD，本輪 9 顆分佈空間大）
- Status: synthesized（已固化為 harness 規則）：image 生命週期綁實驗不綁變體（E-1x 全輪沿用同一顆 image）；跨實驗絕對值比較需 sentinel 重跑（E-17 實證 pool 狀態漂移 -42%）
- Tier: T3
- Origin: pre-mortem（實驗自身靜默失效）
- Notes: harness 規則候選：image 生命週期綁實驗而非綁變體；每輪 bundle 收 `ceph osd map <pool> <object>` 抽樣。

### H-029: 本輪產出的最佳值（如 queue_depth 的甜蜜點）不可直接移植到使用者生產環境（不同 NVMe / 網路 / CPU），可移植的是「相對排序 + 機制解釋 + 重測 harness」——新頁必須把每個結論標記為「機制級（可移植）」或「數值級（僅限本環境）」
- Status: synthesized（已落實到頁面「邊界與除錯」一節）：每個結論標機制級（可移植）/數值級（僅限本環境）；絕對數字不搬運，可搬的是相對排序+機制+重測 harness
- Tier: T2
- Origin: pre-mortem（human/process：結論被錯誤搬運）
- Notes: 這條不是實驗，是 synthesis 規則——寫進新頁的結論格式與 harness README。

### H-030: 只靠 host 側觀測（不進 guest）就能把一筆慢 IO 歸因到正確的層——guest await vs host rbdX await vs ceph `osd perf` 三邊界差分可構成 3am 值班可用的 triage 決策樹，誤歸因率在故障注入驗證下 <1 成
- Status: 部分 synthesized：三邊界差分歸因已驗互洽（E-03）並寫進頁面「延遲歸因的除錯法」；完整 3am 決策樹 artifact + 誤歸因率驗證未做（P3）。E-32 補了關鍵一格：gray failure 時 ceph health 不露餡，要看 client p99 + per-OSD latency + RTT
- Tier: T3
- Origin: persona（3am 值班者：告警響了，哪一層的問題？）
- Notes: 產出是 runbook 型 artifact（決策樹 + 指令清單），用 H-011/H-012/H-018 的注入當測試集驗證決策樹每個分支。

### H-031: `dedicatedCpuPlacement` + `isolateEmulatorThread` 在 node 有 CPU 競爭時把 IO p99.9 抖動壓低（vCPU 與 emulator thread 不被鄰居搶核），無競爭時與預設無差——CPU 拓樸旋鈕是「花資源買尾延遲穩定」的典型 trade-off
- Status: not-run（使用者裁定不做 E-16）——主風險線已由 E-15 回答（limit≥vCPU 數）；dedicated 拓樸的正面收益驗證不值 kubelet CPUManager 改機成本
- Tier: T3
- Origin: negative-space（catalog 缺 CPU 拓樸層）+ persona（SRE）
- Notes: 與 H-018 分工：H-018 驗 cgroup throttle（QoS 錯誤設定的傷害），本條驗正面投資的收益。注入：同 node 跑 CPU 噪音 pod。

### H-032: krbd map option `osd_request_timeout=N`（libceph 層，預設 0=永不）是唯一能把「Ceph 無法回應 → guest 無限 hang」轉成「N 秒後 IO 以 -ETIMEDOUT 失敗」的 client 側旋鈕，且對 homeless request（min_size 不滿、PG 卡 peering 的情境）同樣生效；但 N 設太小會在正常 recovery 的暫態誤殺 IO，guest fs 因此 remount read-only——比 hang 更難自癒
- Status: **violated（T3，E-36 2026-07-08）**——min_size 不滿情境下 timeout=30 實測不觸發（blocked 302.8s 至恢復、無 -ETIMEDOUT、dmesg 無訊息）；機制矛盾轉 H-034 追查
- Tier: T1（機制已驗）→ T3（trade-off 量化）
- Origin: H-006 violated 後的機制重推（Falsify 階段發現）
- Prediction:（E-36 具體化：不同 N 值下 hang→error 轉換時間與 fs 後果）
- Evidence: linux/net/ceph/ceph_common.c:295（`fsparam_u32("osd_request_timeout")`）、osd_client.c:3479-3484（超時 `abort_request(req, -ETIMEDOUT)`）、osd_client.c:3504+（homeless OSD requests 同樣掃描）、libceph.h:78（`CEPH_OSD_REQUEST_TIMEOUT_DEFAULT 0`）。
- Artifacts:（待 Gate 3）E-36 加 osd_request_timeout 變體軸；新頁「卡死的邊界」一節的核心旋鈕。
- Notes: 它是 map option → 受 H-002 固化限制，生產要用必須在 StorageClass 設計期決定——「要不要有界等待」是建置期架構決策，不是事發後能補的。

## 設計備忘（非 hypothesis，Gate 1 一併裁示）

- **degraded 症狀矩陣是一等產出**：H-005/H-011/H-012/H-013/H-014/H-021/H-022 的注入情境統一收斂成一張「情境 × client p99 行為 × guest 症狀 × ceph 健康信號 × 恢復方式」對照表，直接回答使用者「量化邊界」的需求；每格記錄當時亮起的 ceph 健康碼（feed 回 ceph-alert 專案，accumulated class「signal co-occurrence」）。
- **observer lying 防線**（accumulated class）：harness 每輪收的 `ceph -s`／collector snapshot 必須帶時間戳並斷言新鮮度；collector 失敗該輪標 invalid，不准靜默沿用上一輪數值。
- **fio 矩陣改版**：v2 矩陣（4k rand r/w × qd1/8/32 + 1M seq r/w）之上，本輪加收完整百分位（p50/p90/p99/p99.9/max）、fio latency log（stall 斷言用）、樣本數門檻檢查（H-027）；degraded 實驗用固定中等負載（如 4k randwrite qd8）跑長窗 + 注入時間標記，不用短窗矩陣。
- **成本紀律**：Azure 環境「實驗期間開機、離場關機」；harness 的 preflight 要能驗收環境重建後的一致性（local NVMe 重開即清空 → OSD 重建 → 版本/拓樸 snapshot 比對）。

## 繼承錨點（v2 已 confirmed 的事實，本輪直接引用不重驗）

- **cache 留空 ⇒ 自動 `none` + `io=native`**（v2 H-001，kubevirt converter.go:387-423）——v3 baseline 定義直接採用：KubeVirt 什麼都不設的預設已是 O_DIRECT + native AIO。
- **virtio-blk `num-queues` 預設 = vCPU 數**（v2 H-026，qemu virtio-blk.c:1997 + virtio-blk-pci.c:56 + libvirt qemu_command.c:1692）——`blockMultiQueue` 實驗必須做反向對照（強制 queues=1 vs 預設）。
- **librbd 軸 cache 控的是 `rbd_cache` 不是 host page cache**（v2 H-028，qemu block/rbd.c:961）——本輪 librbd out of scope，僅結論引用。
- **krbd 比 librbd 顯著更穩**（v2 E-04：krbd CoV 5-6% vs librbd 20-22%，krbd seqwrite +17.9%）——支持本 charter 選 krbd 主軸的穩定性理由，寫進新頁的「為什麼 krbd」一節。
- **thin image 未 pre-fill 的 randread 虛高**（v2 H-005 方法論規則）、**prediction 先行 / n≥3 噪音帶 / A/B 交錯 / 生效驗證前置**（v2 方法論六規則）——全數繼承為 v3 harness 規則。

### H-033: degraded 期間 client 延遲惡化的主因是「熱物件 recovery 債」——OSD down-未-out 期間被寫過的物件，在該 OSD out/回歸時其 recovery 會阻擋 client op（object 級鎖），惡化幅度與 down 期間寫入量成正比；純 backfill（冷資料搬移）對 client 近乎無感
- Status: synthesized——強支持未閉環（E-30 vs E-39 對照：同 backfill、rr ×24 vs +38%，唯一差=600s 寫入債；E-31/E-34 互證「失效本身無感」）；專屬驗證變體（down 600s 後才 out）未跑，留 backlog。維運結論已可用：控制 out 時機 > 調 QoS
- Tier: T3（可再驗：E-39 變體改為 down 600s 後才 out，預測重現 ×24）+ T1（osd recovery 的 object 鎖路徑）
- Origin: E-30/E-39 對照（Falsify 階段意外發現）
- Prediction:（下輪具體化）
- Evidence: results/E-30（backfill 相 rr mean 22.73ms）vs results/E-39（backfill 相 rr mean 1.31ms）
- Artifacts:（待 Gate 3）頁面 degraded 一節的核心敘事；生產監控建議（degraded objects 數）
- Notes: 若 confirmed，「加快 out」與「縮短 down 視窗」比任何 QoS 旋鈕都有效；與 mon_osd_down_out_interval 的取捨要重寫。

### H-034: osd_request_timeout 在「PG inactive（min_size 不滿）」情境下不觸發 abort 的機制——handle_timeout 的掃描路徑與該情境下 request 的實際狀態（paused？homeless？重建？）之間存在未知環節
- Status: open（留 backlog）——T1 深讀未完成；生產結論已保守化寫進頁面：不把 osd_request_timeout 當防卡死救命索
- Tier: T1（深讀 calc_target/resend/rbd obj_request 重試）→ T3（變體：手動 rbd map + 單 OSD 連線層故障 vs PG inactive 對照——分辨「連線死」與「PG 死」兩種等待的 timeout 行為差異）
- Origin: E-36 violated 後的機制重推
- Prediction:（Falsify 時具體化）
- Evidence: results/E-36/<ts>（t30 blocked 302.8s）；對照 H-032 的 T1 證據
- Artifacts:（待 Gate 3）頁面 osd_request_timeout 一節的重寫
- Notes: 若「連線死會 abort、PG inactive 不會」成立，這個旋鈕的適用範圍要重新定義成「防 OSD 連線黑洞」而非「防 PG 不可用」。
