# kubevirt-rbd-tuning — 實驗計畫 v3（草稿，Gate 1 已裁示、待環境建置）

> Charter 與 hypothesis backlog 見 `HYPOTHESES.md`。本文件是實驗執行藍本；
> 真機跑完後結果回填到各實驗的回填表，最終轉寫成 MDX 專題頁。
> 環境規格見 `AZURE-ENV-SPEC.md`。

## 方法論規則（全實驗共用）

繼承 v2 六規則 + 本輪新增四條：

1. **一個實驗只動一個變因**，其餘固定；比較基準若非原始 baseline 會明寫。
2. **prediction 先行**：預期在跑之前寫死；verdict 三態 `confirmed` / `violated` / `indistinguishable`，由機器比對，事後不改口。
3. **n≥3 + 噪音帶**：判準用 E-01 實測的 Azure 噪音帶（CoV），不沿用 PVE 數字；必要時升 n≥5。
4. **A/B 交錯執行**（A/B/A/B…），每輪記 `ceph -s` 併發狀態。
5. **生效驗證是量測前置**：`kubectl get vmi -o yaml`、virt-launcher 內 `/proc/<qemu>/cmdline`、krbd 軸加 `rbd showmapped` + `/sys/block/rbdX/queue/*` 讀值，全對才跑 fio。
6. **量測有效性**：測試盤 pre-fill；fio `--ramp_time=15`；觀測窗對齊；recovery/backfill 出現該輪作廢重跑。
7. **（新）完整百分位 + stall 斷言**：每輪收 p50/p90/p99/p99.9/max + fio latency log（`--write_lat_log`、`--log_avg_msec=1000`）；正常態實驗斷言 `max_lat < 1s`（H-026）。
8. **（新）樣本數門檻**：p99.9 只在該 pattern 樣本數 ≥100k 時報告，否則只報 p99 並明說（H-027）。
9. **（新）placement 固定**：同一實驗所有變體沿用同一顆 RBD image；不得已重建時 bundle 收 `ceph osd map` 抽樣證明分佈等價（H-028）。
10. **（新）collector 新鮮度**：每輪 snapshot 帶時間戳並斷言新鮮；collector 失敗該輪標 invalid（observer-lying 防線）。

## 共用 fio 矩陣

```
正常態矩陣（每個 E-1x 實驗跑全套）：
  {randread, randwrite} × 4k × {qd1, qd8, qd32}   … 60s + 15s ramp
  {read, write} × 1M × qd16                        … 60s + 15s ramp
  全部 --direct=1 --ioengine=libaio --filename=/dev/vdb（raw block，已 pre-fill）
  收：IOPS/BW、p50/p90/p99/p99.9/max、lat log

degraded 固定負載（每個 E-3x 實驗）：
  4k randwrite qd8 長窗（注入前 120s + 注入 + 恢復後 300s），1s 粒度 lat log
  + 注入/恢復時刻戳記；另一 job 4k randread qd1 同窗並行（讀寫症狀分開看）
```

## 基準 VM 與磁碟

- VM：4 vCPU / 8Gi、Ubuntu 24.04 guest、boot = RBD PVC（rook-ceph-block SC）、
  資料盤 = 獨立 RBD PVC `volumeMode: Block` 16Gi → guest `/dev/vdb`。
- Baseline 設定 = KubeVirt 全預設（繼承錨點：留空即 `cache=none` + `io=native`、
  `num-queues`=vCPU 數）。所有變體相對此 baseline。

## 線上可調性分類（P0 已定案的骨架，實驗回填佐證）

| 分類 | 含義 | 已知成員（P0 T1 證據） |
|---|---|---|
| A. runtime 即生效 | 不動 VM/OSD | `osd_mclock_profile`、`osd_memory_target`、scrub/backfill 節流（H-003）；csi configmap 的 read-affinity（H-002）；guest sysfs（scheduler/nr_requests/readahead） |
| B. 需 VM 重啟 | stop/start，有停機 | VMI 層全部：cache/io/bus/blockMultiQueue/dedicatedIOThread/CPU 拓樸（H-001——live migration **不能**套用） |
| C. 需 OSD rolling restart | 每台短暫 degraded | `osd_op_num_shards`（H-003） |
| D. 建置期定死 | 重建 PVC/pool 才能改 | krbd mapOptions：queue_depth/alloc_size/rxbounce/**osd_request_timeout**（H-002/H-032）；image object-size/striping；pool size/pg_num(改=backfill) |

## 實驗總覽

| 階段 | 編號 | 目的 | 變因（調整的參數） | 對應假設 |
|---|---|---|---|---|
| 0 | E-00 | 環境盤點與版本 snapshot | 無（read-only） | — |
| 0 | E-01 | Azure 噪音帶，定全域判準 | 無（baseline n=5） | H-008 |
| 0 | E-02 | host 層天花板（不經 VM） | k8s node 直接 rbd map 跑 fio | — |
| 0 | E-03 | 三邊界觀測路徑驗證 | guest iostat / host rbdX / QMP | H-025 |
| 1 | E-10 | cache mode | `cache`: none/writethrough/writeback | H-004 |
| 1 | E-11 | bus 效能代價 | `bus`: virtio-blk vs virtio-scsi | H-006(改寫後) |
| 1 | E-12 | AIO 提交模型 | `io`: native vs threads | — |
| 1 | E-13 | 多 queue 反向對照 | queues: 強制 1 vs auto(=vCPU) | 繼承錨點 |
| 1 | E-14 | IOThread 配置 | `dedicatedIOThread`: on/off | — |
| 1 | E-15 | cgroup throttle 傷害 | pod CPU limit: 有 vs Guaranteed | H-018 |
| 1 | E-16 | CPU 拓樸投資收益 | `dedicatedCpuPlacement`+`isolateEmulatorThread`（node 有/無競爭 × on/off） | H-031 |
| 1 | E-17 | guest 排程器 | scheduler: none vs mq-deadline | — |
| 1 | E-18 | readahead 讀路徑 | guest/host `read_ahead_kb` 128/512/4096 | — |
| 1 | E-19 | krbd 並行甜蜜點 | mapOptions `queue_depth`: 64/128/256 | H-009 |
| 1 | E-20 | image layout | `object-size` 4M/16M ± striping | — |
| 1 | E-21 | BlueStore cache | `osd_memory_target`: 4G vs 8G | H-023 |
| 1 | E-22 | OSD shard 並行 | `osd_op_num_shards`（rolling restart） | — |
| 1 | E-23 | replication tax | pool `size`: 2 vs 3（量化用，不推薦） | H-024 |
| 2 | E-30 | 單 OSD 乾淨 down | 注入：`ceph orch daemon stop osd.N` | H-005 |
| 2 | E-31 | OSD node 全滅 | 注入：stop OSD node VM | H-005 |
| 2 | E-32 | gray failure（慢 OSD） | 注入：單 OSD cgroup io/net 延遲 | H-011 |
| 2 | E-33 | 封包遺失 | 注入：tc netem loss 0.1/0.5% | H-012 |
| 2 | E-34 | OSD flapping | 注入：週期 stop/start ± noout | H-013 |
| 2 | E-35 | mon 故障階梯 | 注入：mon down 1/3 → 2/3；quorum 失後疊 OSD kill | H-014 |
| 2 | E-36 | 卡死邊界與有界等待 | min_size 不滿 × `osd_request_timeout` 0/30/120s | H-005/H-032/H-010 |
| 2 | E-37 | scrub 干擾與節流 | deep-scrub 注入 × `osd_scrub_sleep` | H-021 |
| 2 | E-38 | pool full 行為 | 填滿至 nearfull→full | H-022 |
| 2 | E-39 | degraded 保 latency | recovery 中 `osd_mclock_profile`: balanced vs high_client_ops | H-007 |
| 2 | E-40 | crash consistency | cache none vs writeback × QEMU kill -9 + fio verify | H-015 |
| 2 | E-41 | node 硬斷 failover 預算 | k8s node 強制關機，量各段 timeout | H-017 |
| 2 | E-42 | migration 的 IO 代價 | 高負載中 live migration（±writeback 變體） | H-019/H-020 |
| 2 | E-43 | 控制面故障域隔離 | 逐一 kill csi/virt-handler/kubelet | H-016 |
| 3 | E-50 | 可調性真機確認：VMI 欄位 | template 改 + migration → cmdline 比對 | H-001 |
| 3 | E-51 | 可調性真機確認：mapOptions | 改 SC（無效）＋edit PV（escape hatch） | H-002 |
| 3 | E-52 | 可調性真機確認：ceph runtime | `ceph config set` → 行為級驗證 | H-003 |

P3（時間剩才做）：E-23、E-43、H-030 的 triage 決策樹驗證。

---

## 各實驗協定（六欄格式）

### E-00 環境盤點
- **目的**：釘住 T3 環境的實際版本與拓樸，之後所有數字掛在這個 snapshot 下。
- **變因**：無（read-only）。
- **調整的參數**：無。
- **做法**：收 kernel/qemu/libvirt/kubevirt/ceph/csi 版本、`ceph -s`/`osd tree`/pool 設定、
  k8s node/SC/csi 部署參數、Azure VM size 與 NVMe 型號、網路 RTT 矩陣（node 間 ping/iperf3）。
- **預期結果**：kernel=6.8（與 pinned 對齊）、ceph=19.2.3、kubevirt=1.5.0；偏差如實記錄。
- **回填**：environment snapshot 表（新頁附錄）。

### E-01 Azure 噪音帶
- **目的**：量出本環境的 run-to-run 變異，定義全域「差異可信」判準（H-008）。
- **變因**：無——同一 baseline 設定重複。
- **調整的參數**：無。
- **做法**：baseline VM 連跑 fio 矩陣 n=5（不同時段各一輪，至少跨 2 個小時段），
  算每 pattern 的 CoV；同步收 node steal time、`ceph -s`。
- **預期結果**：CoV 高於 v2 PVE 實測（4k qd1 讀 23%）為 confirmed；
  若 qd32/seq CoV >15%，後續全部實驗升 n≥5 並拉長 runtime 至 120s。
- **回填**：pattern × {mean, CoV, p99 帶寬} 表 → 全域噪音帶宣告。

### E-02 host 層天花板
- **目的**：取得不經虛擬化的 ceph 能力上限，作為所有 VM 實驗的 headroom 分母。
- **變因**：量測位置（host vs guest，非旋鈕）。
- **調整的參數**：無。
- **做法**：k8s node 上手動 `rbd map` 專屬測試 image → 對 `/dev/rbdX` 跑同一 fio 矩陣
  n=3 → unmap 清理。
- **預期結果**：host qd32 randread IOPS 顯著高於 guest baseline；
  「虛擬化稅」= (guest − host)/host 逐 pattern 算出。
- **回填**：host vs guest 對照表 + 虛擬化稅百分比。

### E-03 觀測路徑驗證
- **目的**：證明三邊界觀測（guest iostat / host `/dev/rbdX` iostat / QMP blockstats）可自動化取得且互洽（H-025）。
- **變因**：無。
- **調整的參數**：無。
- **做法**：baseline 負載中同時收三邊界 60s，比對 IOPS 互洽（誤差 <10%）；
  QMP 走 `kubectl exec virt-launcher -- virsh qemu-monitor-command`。
- **預期結果**：三者 IOPS 一致；guest await ≥ host await（差值=virtio+QEMU 段）。
- **回填**：三邊界互洽表 + harness 收集器定案。

### E-10 cache mode
- **目的**：全 stack impact 最高旋鈕的正常態效果；驗 H-004（writeback 平均↑但 p99.9 爆）。
- **變因**：disk cache mode。
- **調整的參數**：VMI `disks[].cache` ∈ {留空(=none, baseline), writethrough, writeback}。
- **做法**：改 VM template → stop/start（B 類可調性）→ 生效驗證（QEMU cmdline 的
  cache.direct/write-cache 組合）→ fio 矩陣 A/B/A 交錯 n≥3。
- **預期結果**：writeback 的 randwrite qd1 平均 IOPS 高於 baseline 超噪音帶，
  但 p99.9 惡化超噪音帶且 max 出現 >100ms 尖峰；writethrough 寫入全面變慢；
  randread 三者差異落噪音帶內。
- **回填**：8 pattern × 3 變體 × {IOPS, p50, p99, p99.9, max} + verdict。

### E-11 bus：virtio-blk vs virtio-scsi
- **目的**：bus 的純效能代價（H-006 violated 後，穩定性理由已取消——兩者都永不逾時）。
- **變因**：disk bus。
- **調整的參數**：VMI `disks[].disk.bus` ∈ {virtio(baseline), scsi}。
- **做法**：同 E-10 流程；生效驗證看 QEMU cmdline 的 device 型別
  （virtio-blk-pci vs virtio-scsi-pci+scsi-hd）。
- **預期結果**：scsi 的 4k 高 QD IOPS 低於 virtio-blk 超噪音帶（路徑較長），
  qd1 差異落噪音帶內。
- **回填**：同格式對照表。

### E-12 io：native vs threads
- **目的**：AIO 提交模型的實測差距。
- **變因**：QEMU aio 模式。
- **調整的參數**：VMI `disks[].io` ∈ {留空(=native, baseline), threads}。
- **做法**：同 E-10 流程；生效驗證 cmdline `aio=` 值。
- **預期結果**：threads 在 qd32 randread IOPS 低於 native 超噪音帶、QEMU CPU 較高；
  qd1 差異落噪音帶內。
- **回填**：對照表 + QEMU 行程 CPU（schedstat 差分）。

### E-13 多 queue 反向對照
- **目的**：驗證「blockMultiQueue 在新 QEMU 是 no-op」的繼承錨點在真機成立。
- **變因**：virtio-blk num-queues。
- **調整的參數**：強制 queues=1（需以 annotation/patch 手段壓到 1，做法在生效驗證步確認）
  vs 預設 auto(=4)。
- **做法**：生效驗證 guest `/sys/block/vdb/mq/` 目錄數；fio 矩陣加 `--numjobs=4` 變體
  （多 CPU 提交才吃得到多 queue）。
- **預期結果**：qd32×numjobs4 randread 上 queues=1 低於 auto 超噪音帶；
  單 job pattern 差異落噪音帶內。
- **回填**：對照表（單 job 與 numjobs4 分列）。

### E-14 dedicatedIOThread
- **目的**：IOThread 獨佔對單盤/雙盤場景的效果。
- **變因**：ioThreads 配置。
- **調整的參數**：`disks[].dedicatedIOThread: true` vs 預設。
- **做法**：單盤跑一輪；再加第二顆資料盤雙盤並行跑一輪（獨佔的主場）。
- **預期結果**：單盤差異落噪音帶；雙盤並行時 dedicated 的合計 IOPS 高於共用超噪音帶。
- **回填**：單盤/雙盤兩張對照表。

### E-15 cgroup throttle 傷害
- **目的**：驗 H-018——CPU limit 造成的 CFS throttling 是隱形尾延遲殺手。
- **變因**：virt-launcher pod QoS。
- **調整的參數**：VMI resources：requests=limits（Guaranteed, baseline）vs
  limits 壓到 vCPU 需求的 ~110%（可 throttle）。
- **做法**：guest 內 CPU 壓力（stress-ng 2 核）+ fio 4k randread qd8 並行；
  收 cgroup `cpu.stat` 的 throttled_usec 佐證 throttle 真的發生。
- **預期結果**：被 throttle 變體 p99.9 高於 Guaranteed 一個數量級、
  lat log 出現 ~100ms 級週期尖峰；throttled_usec >0。
- **回填**：對照表 + throttled_usec + lat 時序圖。

### E-16 CPU 拓樸投資
- **目的**：驗 H-031——dedicatedCpuPlacement+isolateEmulatorThread 買到的尾延遲穩定。
- **變因**：CPU 拓樸設定（2×2 設計：node 有/無競爭 × 設定 on/off）。
- **調整的參數**：`dedicatedCpuPlacement: true` + `isolateEmulatorThread: true` vs 預設。
- **做法**：node 競爭用鄰居 pod stress-ng 製造；四格各跑 fio 矩陣精簡版
  （4k randread qd1/qd8）n=3。
- **預期結果**：有競爭時 dedicated 的 p99.9 顯著低於預設；無競爭時差異落噪音帶。
- **回填**：2×2 表。

### E-17 guest IO scheduler
- **目的**：guest 端再排程對 RBD 底層是否多餘。
- **變因**：guest scheduler。
- **調整的參數**：`/sys/block/vdb/queue/scheduler` ∈ {none, mq-deadline(Ubuntu 預設)}。
- **做法**：A 類可調性（runtime sysfs），同 VM 內切換即測；fio 矩陣 n≥3。
- **預期結果**：none 的 qd32 p99 略優（少一層排隊），幅度可能落噪音帶 → indistinguishable 可接受。
- **回填**：對照表。

### E-18 readahead
- **目的**：seqread 路徑上 guest/host 兩層 readahead 的貢獻。
- **變因**：read_ahead_kb（guest 與 host 分開兩個子實驗）。
- **調整的參數**：guest `/sys/block/vdb/queue/read_ahead_kb` ∈ {128(預設), 512, 4096}；
  host `/sys/block/rbdX/queue/read_ahead_kb` 同三檔。
- **做法**：A 類 runtime 切換；主 pattern = 1M seqread + 4k seqread qd1。
- **預期結果**：guest 4096 的 seqread BW 高於 128 超噪音帶；randread 不受影響。
- **回填**：3×2 對照表。

### E-19 krbd queue_depth
- **目的**：驗 H-009——並行上限的甜蜜點與 latency 代價。
- **變因**：krbd map option `queue_depth`。
- **調整的參數**：SC `mapOptions: "krbd:queue_depth=N"`，N ∈ {64, 128(預設), 256}。
- **做法**：D 類可調性——每變體建新 SC + 新 PVC（違反 placement 規則 9 →
  每變體收 `ceph osd map` 證明分佈可比）；生效驗證 host `/sys/block/rbdX/queue/nr_requests`。
- **預期結果**：qd32×numjobs4 高並行 IOPS 隨 N 上升；qd1 p99 隨 N 上升（排隊效應）
  ——若 qd1 不受影響則 H-009 violated（誠實記錄）。
- **回填**：N × pattern 對照表。

### E-20 image layout
- **目的**：object-size/striping 對大 IO 與小 IO 的結構性影響。
- **變因**：image layout（建檔期）。
- **調整的參數**：object-size 4M(預設)/16M；+1 個 striping 變體（su=64k, sc=4）。
- **做法**：D 類——每變體新 image（placement 規則同 E-19）；pre-fill 後跑矩陣。
- **預期結果**：16M 的 1M seqwrite BW 高於 4M；striping 的 seq 更高但 4k rand 差異落噪音帶。
- **回填**：3 變體對照表。

### E-21 osd_memory_target
- **目的**：驗 H-023——runtime 可調的讀 p99 改善。
- **變因**：OSD 記憶體目標。
- **調整的參數**：`ceph config set osd osd_memory_target` 4G(預設) vs 8G。
- **做法**：A 類 runtime；調完等 cache 暖 10 分鐘再測；working set 控制在 16G
  （單盤全量，聚合 cache 8G×9=72G 蓋得住 vs 4G×9=36G 邊緣）。
- **預期結果**：8G 變體 randread qd1 p99 低於 4G 超噪音帶；write 側無差。
- **回填**：對照表 + OSD RSS 佐證。

### E-22 osd_op_num_shards
- **目的**：C 類旋鈕代表——量效果同時量「rolling restart 的代價」。
- **變因**：OSD shard 數。
- **調整的參數**：`osd_op_num_shards_ssd` 8(預設) vs 16（startup flag → rolling restart）。
- **做法**：改 config → `ceph orch restart osd`（逐台，等 HEALTH_OK）→ 測；
  rolling 期間順便收 client p99 時序（= 免費的 C 類代價數據）。
- **預期結果**：16 shards 在高 QD 差異落噪音帶內（9 OSD × NVMe 下 8 已夠）；
  rolling restart 期間 client p99 有可測尖峰。
- **回填**：效果對照表 + restart 代價時序。

### E-23 replication tax（P3）
- **目的**：量化 size=3 的寫入代價，讓「降副本換效能」死心（H-024）。
- **變因**：pool size。
- **調整的參數**：測試 pool `size` 2 vs 3（min_size=2）。
- **做法**：D 類——兩個 pool 各建 image 測寫入側矩陣。
- **預期結果**：size=2 randwrite 延遲低 20-40%；結論固定「生產維持 3」。
- **回填**：對照表 + 明確的「不推薦」結論。

### E-30〜E-38 degraded 矩陣（共用協定）
- **目的**：產出「degraded 情境 × client 行為 × guest 症狀 × ceph 信號 × 恢復」對照表
  （H-005/H-011/H-012/H-013/H-014/H-021/H-022）——使用者要的量化邊界。
- **變因**：注入情境（每實驗一種）；VM 設定固定 baseline。
- **調整的參數／注入做法**：
  - E-30 `ceph orch daemon stop osd.N`（乾淨 down，等 out → 回復）
  - E-31 stop 整台 OSD node VM（3 OSD 同滅）
  - E-32 單 OSD 行程 cgroup io.latency / 對單 OSD port tc netem delay 500ms（gray）
  - E-33 k8s node 出口 tc netem loss 0.1% / 0.5%（只對 ceph public 網段）
  - E-34 單 OSD systemd 週期 stop/start（120s 週期 ×5 輪）± `ceph osd set noout`
  - E-35 mon down 1/3 → 觀察；再 down 至 2/3（quorum 失）→ 觀察穩態 IO
    → 疊加 kill 一顆 OSD（複合故障）→ 全回復
  - E-36 pool min_size=2 + 停 2 顆同 PG OSD（不滿）→ IO hang →
    分別在 `osd_request_timeout` ∈ {0(預設), 30, 120}s 的三顆盤上重複 → 回復後收 guest fs 狀態（H-010）
  - E-37 `ceph pg deep-scrub` 齊發 × `osd_scrub_sleep` 0 vs 0.1
  - E-38 小測試 pool 填到 nearfull → full → 觀察寫入行為 → 清理
- **共用做法**：degraded 固定負載（4k randwrite qd8 + randread qd1 並行）長窗；
  時間軸記注入/告警/恢復戳記；收 guest dmesg（hung task）、`ceph -s`/health codes 時序、
  client lat 1s 粒度時序；**每格記錄亮起的 ceph 健康碼**（回饋 ceph-alert 專案）。
- **共用預期**（各實驗細項在執行前寫死進 bundle prediction 檔）：
  - E-30/31：p99 尖峰僅在 peering 窗（秒級），IO 不中斷，HEALTH_WARN 正確亮。
  - E-32：p99 全 VM 惡化但 **HEALTH_OK 不變**（gray failure 無信號→confirmed 即高價值）。
  - E-33：0.1% loss 使 p99.9 惡化 >5×，平均變動 <20%。
  - E-34：flapping 的 p99 惡化總量 > E-30 單次 down；noout 顯著壓低。
  - E-35：quorum 失後穩態 IO 持續 ≥5 分鐘無錯；疊 OSD kill 後 IO 無限 hang 且無法自癒。
  - E-36：timeout=0 無限 hang + guest 120s hung task；30/120s 準時轉 -ETIMEDOUT，
    但 guest fs remount read-only（恢復後需人工 remount → H-010 的二次傷害實錄）。
  - E-37：scrub_sleep=0 時 p99 惡化超噪音帶；0.1 壓回帶內。
  - E-38：nearfull 只告警不影響 IO；觸 full 後寫入 hang（非 ENOSPC）。
- **回填**：一張總表（情境 × 尖峰幅度 × 持續時間 × guest 症狀 × 健康碼 × 恢復方式）
  + 每情境 lat 時序圖。

### E-39 mClock degraded A/B
- **目的**：驗 H-007——degraded 時保 client latency 的頭牌 Ceph 旋鈕。
- **變因**：mClock profile。
- **調整的參數**：`osd_mclock_profile` balanced(預設) vs high_client_ops（A 類 runtime）。
- **做法**：E-30 的注入（單 OSD down→out 觸發 backfill）為背景，
  backfill 進行中以 `ceph config set` 切 profile A/B/A；同步收 recovery 速率
  （`ceph -s` recovery io）與 client p99。
- **預期結果**：high_client_ops 下 client p99 惡化幅度 < balanced 的一半，
  recovery 完成時間拉長 >1.5×。
- **回填**：profile × {client p99, recovery 耗時} 對照 + 時序圖。

### E-40 crash consistency
- **目的**：驗 H-015——cache mode 的 correctness 代價。
- **變因**：cache mode（none vs writeback）× 注入（QEMU kill -9）。
- **調整的參數**：同 E-10 的 cache 變體。
- **做法**：guest 內 fio `--verify=crc32c` 持續寫 → host 上 `kill -9` QEMU →
  VMI 重啟 → fio verify-only 回讀 + guest fsck；各變體重複 3 次。
- **預期結果**：writeback 至少 1/3 次出現 verify 錯誤或 fs 異常；none 全數乾淨。
- **回填**：變體 × 次數 × {verify 結果, fs 狀態} 表。

### E-41 node 硬斷 failover 預算
- **目的**：驗 H-017——量出 VM 從 node 死亡到他處恢復 IO 的各段耗時。
- **變因**：無（單一注入劇本；旋鈕掃描屬後續）。
- **調整的參數**：記錄各段預設 timeout（node-monitor-grace、pod GC、krbd watcher、csi attach）。
- **做法**：VM 帶 RWX block PVC + `evictionStrategy` 設定妥當；Azure 強制 stop k8s worker →
  時間軸記：NotReady、pod 刪除、新 pod 排程、PVC attach 成功、rbd map 成功、guest IO 恢復。
- **預期結果**：總時間分鐘級；ceph watcher/lock 段 ≤60s 且非最大項（k8s node 判死才是）。
- **回填**：分段時間預算表（生產 SLO 直接可用）。

### E-42 live migration 的 IO 代價
- **目的**：驗 H-019——維運工具的 IO 擾動可控性；附驗 H-020（writeback 不擋 migration）。
- **變因**：migration 時機（負載中）；子變體 cache=writeback。
- **調整的參數**：無旋鈕（觀測型）；writeback 子變體驗證 migration 可行 + fio verify 跨 migration。
- **做法**：4k randwrite qd8 進行中 `virtctl migrate` ×3 次；lat log 1s 粒度
  找暫停窗；writeback 子輪加 `--verify` 檢查資料一致。
- **預期結果**：每次 migration 出現一次 <1s 的 lat 尖峰，無 IO error；
  writeback 輪 migration 成功（H-020 violated 的真機確認）且 verify 乾淨。
- **回填**：3 次 migration 的暫停窗表 + writeback 子輪結果。

### E-43 控制面故障域隔離（P3）
- **目的**：驗 H-016——控制面 crash 不傷資料面。
- **變因**：被 kill 的元件（csi nodeplugin / virt-handler / kubelet）。
- **調整的參數**：無。
- **做法**：fio 進行中逐一 delete pod / systemctl stop kubelet 60s → 恢復；斷言 lat 無擾動。
- **預期結果**：三者皆無可測影響（p99 落噪音帶內）。
- **回填**：元件 × verdict 表。

### E-50 可調性確認：VMI 欄位
- **目的**：H-001 的 T3 確認。
- **變因**：套用手段（migration vs stop/start）。
- **調整的參數**：template `cache` none→writethrough（可見於 cmdline 的變更）。
- **做法**：改 template → 確認 RestartRequired condition → `virtctl migrate` →
  目標端 cmdline 比對（預期**不變**）→ stop/start → cmdline 比對（預期變）。
- **預期結果**：migration 不套用、restart 套用——H-001 confirmed 於 T3。
- **回填**：兩路徑 × cmdline diff 結果。

### E-51 可調性確認：mapOptions
- **目的**：H-002 的 T3 確認 + escape hatch 實測。
- **變因**：修改路徑（改 SC vs edit PV）。
- **調整的參數**：`queue_depth` 128→256。
- **做法**：改 SC → VM stop/start → host `nr_requests` 讀值（預期**不變**）；
  `kubectl edit pv` volumeAttributes → stop/start（完整 unstage/restage）→ 讀值（預期變）。
- **預期結果**：SC 改動無效、PV 直改生效（非官方路徑，寫明支援風險）。
- **回填**：兩路徑 × 讀值結果。

### E-52 可調性確認：ceph runtime
- **目的**：H-003 的 T3 行為級確認。
- **變因**：驗證方式（config get vs 行為觀測）。
- **調整的參數**：`osd_mclock_profile`、`osd_memory_target`。
- **做法**：`ceph config set` 後不重啟，分別以 E-39 的 client p99 差異、OSD RSS 變化
  確認行為真的改變（不只 config get 顯示新值）。
- **預期結果**：兩者 runtime 生效可觀測。
- **回填**：參數 × 行為證據表。

## 執行順序與 Gate

```
E-00 → E-01 → E-02 → E-03           （環境與方法論，全綠才往下）
→ E-50/51/52（可調性確認，便宜且獨立）
→ E-10 → E-11 → E-12 → E-13 → E-14  （VMI 層）
→ E-15 → E-16                        （CPU 層）
→ E-17 → E-18                        （guest 層）
→ E-19 → E-20                        （D 類：SC/image 重建）
→ E-21 → E-22                        （Ceph 正常態）
→ E-30 → E-37 → E-33 → E-32 → E-34   （degraded：由淺入深）
→ E-31 → E-35 → E-36 → E-38          （深度破壞）
→ E-39 → E-40 → E-41 → E-42          （組合劇本）
→（時間允許）E-23 → E-43
```

- **Gate 2**（本輪弱化版）：環境專屬可破壞，故障注入不需逐項請示；
  例外＝會讓環境要整組重建的操作（刪 mon 資料、重灌 cephadm）先確認。
- **Gate 3**：每完成一個階段回 HYPOTHESES.md triage，全部完成後才動筆 MDX。
