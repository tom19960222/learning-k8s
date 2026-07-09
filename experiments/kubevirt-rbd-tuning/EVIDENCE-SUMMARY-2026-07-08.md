# EVIDENCE SUMMARY — 2026-07-08（環境世代 gen-1：FSID ab33c12c…、make start 後 ceph 重建即換代）

> bundle 原始檔在本機 `results/`（gitignored）；本檔是可進 git 的索引。頁面數字只准引用本檔或 bundle。

## E-00 環境盤點 — done

- Bundle：`results/E-00/20260708-*/snapshot.txt`、`memory-target-fix.txt`
- 版本：ceph **19.2.4**（pinned 19.2.3，patch 差）/ ceph-csi **v3.14.0** ✓ / KubeVirt **v1.5.0** ✓ / k8s v1.32.13 / 全節點 kernel **6.8.0-1059-azure**、Ubuntu 22.04
- 拓樸：3 mon（mgr active 在 mon-0）+ 3 OSD host × 3 OSD（L8s_v3，**1 顆 1.7T NVMe 切 3 OSD ~100G**，叢集 900G）；pool `kubevirt` size3/min_size2/pg64；workers D8s_v5×2 有 `/dev/kvm`
- **關鍵發現①**：cephadm autotune 把 `osd_memory_target` 抬到 **15.7G/OSD**——已修正：autotune=false、移除 host 級覆寫、釘回預設 **4294967296（4G）**（`memory-target-fix.txt` 有 verify 輸出）。E-21 的 A/B 就以 4G/8G 對照。
- **關鍵發現②**：`osd_mclock_max_capacity_iops_ssd` 實測值 ~**6000 IOPS/OSD**（osd.0=6242、osd.1=5992…）——mClock 用它算配額，這就是本環境 OSD 端天花板的量級（3 OSD 共享單 NVMe 的結果）。解讀高 QD 實驗時以此為分母。
- mClock profile 未顯式設定（= 預設 balanced）；`osd_op_num_shards_ssd` 未顯式設定（= 預設 8）。
- Kyverno `rbd-block-disk-group` policy 存在（RBD 裸裝置 GID 6 workaround）。
- RTT（cp→3 OSD 私網）：均 <1ms（詳 snapshot）。

## Baseline 生效驗證 — done（繼承錨點 T3 實錘）

- Bundle：`results/E-00-baseline-verify/qemu-cmdline.txt`
- data 盤 blockdev = `{"driver":"host_device","filename":"/dev/data","aio":"native",...,"cache":{"direct":true,"no-flush":false}}`、device `write-cache:"on"`、**json 無 num-queues 欄**（=AUTO）→ **「全留空 = cache=none + io=native + queues=vCPU」在 v1.5.0 真機成立**。
- guest `/sys/block/vdb/mq` = **4**（=vCPU 數）——H-026/繼承錨點 T3 confirmed。
- QEMU 行程名 = **`qemu-kvm`**（pid 84，非 qemu-system）——RUNBOOK 已修正 pgrep。
- host krbd 預設讀值：`nr_requests=128`、`read_ahead_kb=128`、scheduler=`none`（rbd0）。

## E-03 三邊界觀測驗證 — done（verdict: confirmed）

- Bundle：`results/E-03/<ts>/`（guest-iostat / host-iostat / qmp-domblkstat / guest-mq-count）
- 同一 60s 窗（E-01 round-1 的 rr 負載中）：guest vdb **27005 r/s** vs host rbd0 **26998 r/s**（差 0.03% ≪ 10% 判準）；`virsh domblkstat` 差分可用（rd_req 增量/60 與 iostat 同量級）。
- 虛擬化稅初值：guest await 1.12ms − host await 1.03ms ≈ **0.09ms/op**（qd32 高載時）。
- 三邊界收集管線全部自動化可用 → 後續實驗照此收。

## E-01 噪音帶 — done（H-008 **violated**：Azure 專屬叢集比 PVE 生產穩一個數量級）

- Bundle：`results/E-01/<ts>/e01/round-{1..5}-A/`（n=5 連跑；deviation：未跨 2h 時段）
- **IOPS CoV 0.4–2.0%**（v2 PVE 4k qd1 讀是 23.4%）；p99 CoV 0.5–7.9%；p999 除 sw-1m（35.2%）外 ≤9%。
- band.json（git 追蹤，`band = max(2×CoV, 5%)`）：多數 metric 判準落在 5%；sw-1m p999 判準 70%（seq write 尾端本質性抖，該 metric 幾乎只能出 indistinguishable——誠實限制）。
- **gen-1 baseline 錨點數字**：rr qd1/8/32 = **968 / 8458 / 26771** IOPS；rw = **597 / 5322 / 14751**；
  seq read/write = **2838 / 1233 MiB/s**。rr-qd1 p50=0.97ms、rw-qd1 p50=1.63ms。
- p999 樣本數規則生效：qd1 pattern（58k/36k 樣本 < 1e5）不報 p999。
- 對照 mClock 天花板 9×6000=54k：rr-qd32 已用到 27k（50%）；單 VM 單盤打不滿叢集。

## E-02 host 層天花板／虛擬化稅 — done

- Bundle：`results/E-02/<ts>/e02/`（k8s-1 直接 map /dev/rbd0，n=3；同 pool 新 image，非 guest 那顆——placement 差異已知）
- **虛擬化稅（host 相對 guest 的優勢）**：rr-qd32 **+36.7%**（26771→36602）、rr-qd8 +17.4%、rw-qd1 +11.9%、rw-qd8 +11.6%、rr-qd1 +9.0%；**rw-qd32 +4.7%、seq read/write +2.7%/+1.2% = indistinguishable**。
- 解讀：虛擬層（virtio+QEMU）的代價集中在高並行小塊隨機讀；寫側與大塊頻寬瓶頸在 ceph 端，虛擬層幾乎免費。rr-qd32 的 36.7% 缺口是 E-13（多 queue）/E-14（IOThread）最該追的 headroom。
- verdict 檔：`results/E-02/<ts>/verdict-vs-guest.txt`；throwaway image/key 已清理，HEALTH_OK。

## E-10 cache mode — done（H-004 **confirmed**；附帶抓到 cache-regime 量測陷阱）

- Bundle：`results/E-10/20260708-015243/`（A/wt/wb 交錯 n=3；生效斷言全過：A=direct:true,wc:on／wt=false,off／wb=false,on）
- **writeback（vs baseline none）**：rw-qd1 IOPS **+1997%**（592→12424）、p99 −95.6%——host RAM ack 的假象；但 rw-qd8 **p999 +2064%**（3.3ms→71ms）、rw-qd32 p99 +1354%（4ms→57.6ms）、sw-1m **max +1089%（1.52s，另輪 3.47s，STALL-FLAG）**。均值好看、尾延遲爆炸+整秒 stall。
- **writethrough（vs none）**：寫側嚴格劣化——rw-qd8/32 IOPS −35%/−37%、p99 +40%/+22%、rw-qd8 max +1666%（209ms）；讀側 qd1/qd8 帶內。
- **量測陷阱（一等發現）**：wt/wb 都關 O_DIRECT → 讀經 host page cache，16G 測試盤 < 32G worker RAM → **讀側數字是 RAM 不是 ceph**（sr-1m 2709→14630 IOPS ≈ 14.3GiB/s、rr-qd32 +161~176%）。生產 working set >> host RAM 時讀側增益消失；本實驗讀側結論僅在 cache-hit regime 成立。
- **latency-first 生產結論（機制級）**：維持預設 `cache=none`——wt 嚴格劣於 none；wb 的寫側均值增益以 p99.9 崩壞 + 秒級 stall 為代價（另有 E-40 crash consistency 未驗）。
- verdict 檔：`verdict-wt.txt`、`verdict-wb.txt`。

## E-12 io mode — done（prediction **violated**：threads 不輸 native，高 QD 讀還略勝）

- Bundle：`results/E-12/<ts>/`（A=native, th=threads 交錯 n=3；aio 欄位斷言全過）
- **rr-qd32：threads +12.4% IOPS（27563→30993）、p99 −7.2%**——超出噪音帶，方向與「native 優於 threads」的常識相反；其餘 22/26 個 metric 全部 indistinguishable（max 類除外，n=3 下單發 outlier 不穩）。
- 機制假說（待 E-14 交叉驗證）：O_DIRECT + krbd 下，native AIO 的提交集中在單一 event loop；thread pool 把阻塞 IO 攤到多工作緒，在高並行時提交面更寬。
- 生產結論（機制級）：**維持預設（留空=native）即可**——threads 的 qd32 增益不大、且未量 QEMU CPU 代價（本輪未收 schedstat，deviation）；沒有改的理由，但「native 一定比較快」的說法在本 stack 不成立。
- verdict 檔：`verdict-threads.txt`。

## E-13 blockMultiQueue no-op 驗證 — done（confirmed：錨點成立，開了=沒開）

- Bundle：`results/E-13/20260708-095032/`（A=不設 vs mq=`blockMultiQueue: true` 交錯 n=3）
- **錨點實錘**：7/7 次生效驗證 guest `/sys/block/vdb/mq` 目錄數**兩變體都=4**；cmdline diff 顯示唯一實質差異=mq 變體對所有 virtio-blk 裝置顯式寫入 `"num-queues":4`，A 變體省略、QEMU AUTO 預設自動解析為 vCPU 數=4——**blockMultiQueue 只是把 QEMU 已在做的預設值顯式化**（繼承錨點 v2 H-026：virtio-blk.c:1997 的 AUTO 行為，T3 confirmed）。
- fio：23/29 metric indistinguishable；超帶項（rr-qd1 iops −6.5%、sr-1m p99 +9.6%）經 per-round 檢視為時間漂移（兩變體各自單調下滑、A 側自身 −5.2%；sr-1m 是 E-17 實錄漂移最大 pattern），max 類三項雙向亂跳（spiky、band.json 無 max 校準）——佇列拓樸完全相同下無機制可產生真差異。verdict.md 內全數照實列出。
- 生產結論（機制級）：**新 QEMU（AUTO num-queues）上 blockMultiQueue 不用開**——它不會給你更多 queue，也不會更快；唯一用途是老 QEMU（無 AUTO）或需要顯式固定 queue 數的場景。真 queues=1 反向對照需 hook sidecar，維持 optional-skip（設計期已記 deviation）。
- verdict 檔：`verdict.md`（機器輸出 verdict-raw.txt 照抄）。

## E-14 dedicatedIOThread — done（單盤輪：confirmed「無感」）

- Bundle：`results/E-14/<ts>/`（A/io 交錯 n=3；device iothread 欄位斷言全過）
- 26 metric 中 17 個 indistinguishable；邊緣超帶：rr-qd1 +5.4%、rw-qd8 +8.4%（正向）、rr-qd32 p99 **+8%（反向劣化）**；max 類雙向亂跳（n=3 單發 outlier）。
- **關鍵否定結論：單盤 dedicatedIOThread 收不回 E-02 的 rr-qd32 +36.7% 虛擬化稅**（IOPS 帶內）——qd32 瓶頸不在「缺一條獨立 iothread」。與 E-12（threads +12.4%）合看：提交路徑寬度有影響但不是主稅源。
- 雙盤並行輪（dedicated 的設計主場）延後列 P3。生產結論（機制級）：單盤 VM 不用開。

## E-30 單 OSD 乾淨 down — done（degraded 矩陣第 1 列；H-005 單 OSD 部分 confirmed+細化）

- Bundle：`results/E-30/<ts>/`（timeline.txt epoch 對齊；dg lat log 1s 粒度；health.jsonl 5s）
- 分相位結果（1s 窗 clat，baseline rw-qd8=1.48ms / rr-qd1=0.96ms）：
  | 相位 | rw-qd8 mean/max | rr-qd1 mean/max |
  |---|---|---|
  | peering（down 瞬間 20s） | 1.59 / 3.70ms | 1.09 / 3.80ms |
  | down 未 out（580s） | **1.44 / 1.51ms（=baseline）** | **0.95 / 1.00ms（=baseline）** |
  | **auto-out → backfill** | 3.95 / **76.4ms** | **22.73 / 1010.9ms（×24，整秒窗）** |
  | re-in recovery | 4.46 / **309.3ms** | 1.87 / 71.9ms |
  | post | 1.49ms（全自癒） | 0.96ms |
- **頭條結論（機制級）**：單 OSD 故障本身近乎無感；**真正的傷害視窗是 `mon_osd_down_out_interval`（600s）到期後的 backfill 與回歸後的 recovery**——隨機讀在 backfill 期整整劣化 24 倍。維運含義：短暫維護先 `ceph osd set noout`；預期外故障要嘛 10 分鐘內救回、要嘛接受 backfill 視窗（E-39 測 mClock 能壓多少）。
- guest 症狀：無 hung task、無 remount、恢復後 direct read OK（`guest-symptoms.txt`）。健康碼：OSD_DOWN、PG_AVAILABILITY、PG_DEGRADED。
- Deviation：script 的 health-ok-again 戳記誤判（grep 過鬆），實際恢復以 health.jsonl 為準；後窗數據證實 T1+150s 已回 baseline。

## E-39 mClock backfill A/B — done（verdict: **indistinguishable**，但挖出關鍵機制）

- Bundle：`results/E-39/<ts>/{balanced,high_client_ops}/`（60G scratch、立即 `osd out` 觸發、各 240s 窗）
- backfill 窗 client latency：balanced rw 2.39ms/rr 1.31ms vs high_client_ops rw 2.36ms/rr 1.31ms——**帶內無差**；recovery 速率 467 vs 617 MB/s（NVMe headroom 大到兩個 profile 都沒讓 client 等）。
- **與 E-30 對照的機制發現（一等）**：同樣是 backfill，E-30 是 rr ×24、這裡只有 +38%。差異＝E-30 先經歷 600s「down 未 out」的持續寫入 → 累積 degraded 物件債 → out 後**熱物件 recovery 擋 client op**；E-39 立即 out 無債。**傷害來源是 hot-object recovery debt，不是 backfill 資料搬移**（→ 新假設 H-033）。
- 生產含義：mClock profile 在 OSD 有 headroom 時不用調（runtime 可調留作飽和時的工具）；真正該管理的是 down-未-out 期間的寫入債——監控 degraded objects 數比切 profile 更重要。
- Deviation：high_client_ops 輪的 pre 窗被前一輪殘餘 recovery 汙染（pre rw 3.16ms），backfill 窗本體可比。

## E-42 live migration IO 代價 — done（H-019 confirmed，優於預期）

- Bundle：`results/E-42/<ts>/`（rw-qd8 負載中 migration ×3，lat log 1s 粒度跨 migration 連續）
- **IO 零中斷**：無任何 >2.5s log 斷點；migration 期間最差 1s 窗 = 3.8 / 8.0 / 7.2ms（baseline 1.53ms）；三次 phase 全 Succeeded。
- 生產結論（機制級）：live migration 對 disk IO 的擾動在 1s 粒度下僅為個位數 ms 的短暫抬升——節點維運可放心用（記憶體密集 workload 的 dirty-page 收斂是另一題，不在本實驗範圍）。

## E-50 可調性真機確認 — done（H-001 T1+T3 全 confirmed）

- Bundle：同 E-42 bundle（合併執行）
- patch `cache=writethrough`（不重啟）→ **`RestartRequired` condition 出現** ✓；migration ×2 有效樣本後 cmdline 仍 `"direct":true`（=none）✓——**live migration 不套用 disk 旋鈕，T3 實錘**（mig-3 樣本無效：migration 中新舊 pod 並存抓錯 pod，空檔案誤報 violated——deviation 記錄）。
- **額外發現**：revert patch（spec 改回原樣）後 `RestartRequired` **不會自動清除**——碰過非 live-updatable 欄位，條件就掛著直到重啟。生產含義：改錯 VM template 沒有「改回去就當沒發生」。

## E-36 卡死邊界 × osd_request_timeout — done（H-032 **T3 violated**，附未解機制矛盾）

- Bundle：`results/E-36/<ts>/`（第三跑有效；前兩跑無效：CJK 標點變數雷、O_DIRECT 未對齊 EINVAL——教訓入 STATE）
- 注入：停 PG 2.5 acting 的 osd.8+osd.0（min_size 不滿）300s。兩顆盤 probe（0.2s 一發 4k direct write）各在 T0+12~21s 撞進 inactive PG 後整條凍結。
- **結果**：baseline 盤 blocked 293s（預期）；**t30 盤（config_info 實證帶 osd_request_timeout=30）blocked 302.8s——沒有 30s abort、無 -ETIMEDOUT、dmesg 零 timeout 訊息**。恢復後兩盤 op 成功完成、direct read OK、無 hung task（probe 週期短，未持續 120s 同一 op 等待——hung task 條目由後續長 hold 情境補）。
- **機制矛盾（open question → H-034）**：pinned source 讀起來必觸發（osd_client.c:3479 掃 o_requests、:3504 掃 homeless；r_start_stamp 僅 account_request 設一次不重置；handle_timeout 每 5s 跑）——T3 卻無 abort。待查方向：inactive PG 的 calc_target 路徑、resend 時 req 重建？、rbd obj_request 層的重試包裝。
- **生產含義（立即生效）**：**不要把 osd_request_timeout 當救命索**——在它最該出場的 min_size 情境下實測不觸發。「卡死轉有界失敗」目前沒有已驗證的 client 側旋鈕；防線只能靠 (1) 不讓 PG inactive（容量規劃、min_size/size 設計、快速換件）(2) application 層 timeout。

## E-17 guest IO scheduler — done（confirmed：none 優，且幅度超預期）

- Bundle：`results/E-17/<ts>/`（同 VM runtime 切換交錯 n=3；guest vdb 預設=**none**）
- **none vs mq-deadline**：seq read **+39.7%**（1640→2291 MiB/s）、seq write **+30.1%**、rr-qd32 +6.0%（p99 −7.7%、max −45%）；qd1/qd8 隨機小 IO 帶內。
- 機制：底層 RBD 已有自己的排序與並行，guest 再排一層 mq-deadline 對高吞吐 pattern 是純開銷。
- 生產結論（機制級）：**維持 none**（Ubuntu 24.04 virtio-blk 預設即是）——這是「檢查清單」項不是「調教」項：發現誰把它改成 mq-deadline/bfq 要改回來。
- ⚠ 跨實驗漂移：本輪 mq-deadline 側 sr-1m 遠低於 E-01 baseline（-42%），none 側亦 -19%——pool 狀態隨實驗演進（+60G scratch、多輪寫入）。A/B 交錯內部可比；**跨實驗絕對值比較需 sentinel 重跑**（方法論規則的實證）。

## E-18 guest readahead — done（indistinguishable，且是機制必然）

- Bundle：`results/E-18/<ts>/`（128/512/4096 ×3 輪，全 pattern 全檔位帶內）
- **事後看是設計必然**：矩陣是 `--direct=1`，O_DIRECT 繞過 page cache → `read_ahead_kb` 完全不參與。
- 機制結論（比數字有價值）：**readahead 只影響 buffered read**——對 direct IO workload（資料庫、本研究的 latency-first profile）它是「非旋鈕」。buffered 變體（會被 guest page cache 混淆）列 P3 不追。
- 生產結論：direct IO 型服務不用碰 readahead；buffered 型（檔案服務等）另案。

## E-21 osd_memory_target 4G vs 8G — done（indistinguishable；邊界條件是關鍵）

- Bundle：`results/E-21/20260708-153326/`（4G=A / 8G=B 交錯 n=3，各 round 600s 暖機；RSS 佐證 rss-before/after.txt）
- **IOPS/p99 全 pattern indistinguishable**：rr-qd1 4G 964 IOPS/p99 1401us vs 8G 935/1532us（帶內）；只有 max 類雙向抖動（rr max +10~11%、seq/rw max −11~35%，n=3 outlier）。
- **RSS 佐證行為級生效**（=E-52 的證據）：osd.1 RSS 在 8G 輪爬到 ~1505MB、4G 輪 ~1135MB——`ceph config set` 確實改變了 OSD 記憶體用量（runtime 生效 confirmed），但**兩者都遠低於 target**（8G target 下才 1.5G）。
- **為什麼 indistinguishable（邊界條件，比 verdict 重要）**：測試盤 16G，4G×3 OSD=12G 聚合 cache 已足以涵蓋單盤熱資料 → 8G 沒有多命中可拿。**這證實 E-00 當初釘回 4G 的判斷**：若不釘、任 autotune 給 15.7G，baseline 讀側數字會被 cache 全命中美化。生產含義：`osd_memory_target` 的收益只在 **working set > 當前 cache** 時才出現——本環境單 VM 打不到那個 regime；大 working set 或多 VM 聚合負載才需要加記憶體（本環境無法量化該增益，誠實標記）。
- verdict 檔：`verdict-8g.txt`。
- ⚠ 執行 deviation：subagent 監聽器在 ALL-DONE（17:36）後死亡、未完成收尾；數據完整，由主線 orchestrator 事後補記錄+commit。此為「subagent 長時監聽不穩」的實證 → 改用「background bash 跑實驗 + 短命 subagent 只做收尾」模式。

## E-11 bus virtio-blk vs virtio-scsi — done（IOPS indistinguishable，但 scsi 尾延遲較差）

- Bundle：`results/E-11/<ts>/`（A=virtio-blk / scsi=virtio-scsi 交錯 n=3；cmdline device 型別斷言全過）
- **IOPS 全 8 pattern indistinguishable**（差異 ≤4.4% 全落 5% 帶內）——兩 bus 穩態吞吐相同。
- **但 virtio-scsi 的 max latency 全面較高**：rw-qd8 max +150%、rr-qd8 +70%、rr-qd32 +34%、sw-1m +20%——SCSI 中間層較長路徑在尾端露出代價。
- 生產結論（機制級）：**維持 virtio-blk 預設**。結合 H-006 violated（scsi 並不提供想像中的 timeout 保護——見「三個被推翻的直覺」），virtio-scsi 對本研究的 latency-first 目標**沒有任何優勢、且尾延遲更差**——不要為了「以為有 timeout」而換 bus。
- verdict 檔：`verdict-scsi.txt`。

## E-37 deep-scrub × osd_scrub_sleep — done（indistinguishable；NVMe headroom 再次吸收）

- Bundle：`results/E-37/<ts>/`（sleep=0 vs 0.1，各段對 kubevirt pool 全 64 PG 觸發 deep-scrub，rr-qd1+rw-qd8 負載 480s）
- **scrub 確實執行**（PG scrub 時戳 01:42–01:45 落在實驗窗內；pool 76GiB/19.5k 物件非空）——但 **client rr-qd1 全程平坦 0.98ms、p99 1.0ms、max 1.0ms，兩檔位無差**，無 health 碼。
- 機制結論：NVMe + headroom 下 deep-scrub 的背景 IO 不與輕量 client 競爭 → `osd_scrub_sleep` 無可觀測效果。**與 E-39（mClock 同因 headroom 無感）同一模式**。
- **合併生產結論（跨 E-37/E-39，機制級）**：在 NVMe + 有 headroom 的叢集，Ceph 側 QoS 節流旋鈕（mClock profile、scrub_sleep）多半不可分辨——沒有爭用可仲裁。**該投資的是容量 headroom，不是 QoS 微調**；這些旋鈕的用武之地在媒體飽和（HDD、或 client 打滿）時，本環境測不到那個 regime（誠實標記）。
- Caveat：輕 client（qd1/qd8）+ 快媒體；HDD 或飽和 client 下結論會不同。

## E-34 OSD flapping × noout — done（confirmed：noout 砍尾延遲一半以上）

- Bundle：`results/E-34/<ts>/`（osd.3 週期 stop60/start60 ×5，default vs `ceph osd set noout`；degraded 負載 rr-qd1+rw-qd8）
- flapping 對 client 傷害顯著（vs pre 0.94ms）：
  | | rr-qd1 mean | rr-qd1 p99 | rr-qd1 p999/max | rw-qd8 p999 |
  |---|---|---|---|---|
  | default | 11.19ms（×12） | 176ms | **1146ms** | 100ms |
  | **noout** | 6.41ms（×7） | 128ms | **335ms** | 139ms |
- **noout 效果 confirmed**：mean −43%、p999 **−71%（1146→335ms）**——不觸發 out→backfill 資料搬移，把傷害限縮在「純 peering」層級。但注意 **noout 不能消除傷害**：每次 down/up 的 PG re-peering 仍讓 qd1 讀尖峰到 335ms（primary 重選期間讀阻塞）。
- 讀比寫痛：rr-qd1（單深度延遲敏感）受創遠大於 rw-qd8——flapping 期間每筆讀等 primary 重新可用。
- 健康碼：default=OSD_DOWN/PG_DEGRADED；noout 多一個 OSDMAP_FLAGS（noout 旗標本身告警）。
- 生產結論（機制級）：**偵測到 OSD flapping 立即 `ceph osd set noout`**（阻止重複 backfill），同時查 flap 根因（網路/碟）——noout 是止血、不是治本。與 E-30 合看：down 的傷害全在「out→backfill」那段，控制 out 就控制大部分傷害。

## E-32 gray failure（慢 OSD host）— done（**confirmed，本研究最重要 degraded 發現之一**）

- Bundle：`results/E-32/<最新 ts>/`（v3 有效版：cyshih-osd-1 的 osd.3/4/5 網卡 +50ms netem；v1/v2 cgroup 磁碟限速無效見 STATE）
- **一個 host +50ms 延遲的衝擊（vs pre）**：
  | | pre | inject | 倍率 | health |
  |---|---|---|---|---|
  | rr-qd1（讀） | 1.05ms | mean **20.1ms** / p99 29.9 / max 32 | **×19** | HEALTH_OK 全程 |
  | rw-qd8（寫） | 1.73ms | mean **69.6ms** / p99 76 / p999 79 | **×40** | HEALTH_OK 全程 |
- **兩個一等結論**：
  1. **觀測盲區 confirmed**：一台 host gray（NIC 問題/壅塞/半死）能讓 client 寫入慢 40 倍，但 `ceph health` 全程 OK、無 OSD 標 down、無告警——**光看 ceph health 完全看不到**。這正是 charter 最在意的失敗模式。
  2. **size=3 + per-host replica 放置 → 一台慢 host 毒化「所有」寫入**：每個 write 要等 3 副本 ack，CRUSH 每 host 放一副本 → 每個 write 都碰到慢 host 的那顆副本 → 全域寫延遲 = 慢 host 延遲。讀只中 ~1/3（primary 落在慢 host 的 PG）故「僅」×19。
- **生產含義（可移植）**：(a) 不能只靠 `ceph health` 判健康——要監控 client 端 p99 / `ceph osd perf` 的 per-OSD latency / 網路 RTT；(b) 3-host 叢集裡任何一台的網路/磁碟 gray 都會拖垮全叢集寫延遲，且無告警——host 級健康探針（網路 RTT、逐 OSD latency 告警）是必要補強。回饋 ceph-alert 專案：需要「client latency 高但 health OK」的 gray-failure 告警規則。
- 恢復乾淨（post rr 1.45ms/rw 3.67ms 回落）；netem 已確認清除（fq_codel 預設）。

## E-33 封包遺失 0.1%/0.5% — done（prediction **violated**：TCP 快速重傳吸收，遠小於預期）

- Bundle：`results/E-33/<ts>/`（osd-1 網卡 netem loss 0.1% 然後 0.5%，注入已驗證於 inject.txt）
- **衝擊極小**：0.1% loss → rr/rw 皆 1.0×（無變化）；0.5% loss → rw-qd8 mean 1.1×、p999 才 2.6ms。health 全程 OK。
- **我的預測（p99.9 >5×，TCP RTO ~200ms）被推翻**。機制：低 RTT（<1ms）+ 現代 TCP（SACK/fast-retransmit），串流中的封包遺失由 3 個 dup-ACK 在 ~1 RTT 內快速重傳修復，**不觸發 RTO**；且 0.1-0.5% 下多數 op 根本沒中遺失。RTO 災難需要 tail-loss、高 RTT 或高得多的 loss 率。
- **對比 E-32 的關鍵洞察（跨實驗）**：對 Ceph-on-TCP，**穩定的延遲/壅塞（E-32 +50ms→寫 ×40）遠比稀疏封包遺失（E-33 0.5%→1.1×）致命**。診斷網路型 degraded 時，先看 RTT/延遲不是丟包率。
- 生產含義：低幅封包遺失（<1%）在低延遲 NVMe 叢集不是 client latency 的主要威脅；把監控與告警重心放在**延遲/RTT** 而非 loss。

## E-38 pool full / nearfull — done（confirmed H-022；容量耗盡是 hang 邊界非 EIO）

- Bundle：`results/E-38/<v2 ts>/`（用調 ratio 注入，非真填；v1 因 ratio out-of-order 只觸發 nearfull，反而驗到前半）
- **nearfull（v1，ratio 0.15/—/—→只 nearfull 生效）**：HEALTH_ERR「nearfull」但 **寫入不受阻（91 筆全過）**——nearfull 只告警。
- **full（v2，ratio 依序 0.10/0.15/0.20 全<用量0.26）**：health `9 full osd / 2 pool full`；client 寫入**卡 96 秒**（跨整個 FULL 窗），**恢復 ratio 後那筆寫入成功完成（非 ERR、非 ENOSPC）**，IO 完全停 97s，之後正常 resume。
- **結論（confirmed H-022，可移植）**：容量耗盡是**穩定性 hang 邊界，不是優雅的 ENOSPC**——krbd 預設無 abort_on_full → 寫入無限期阻擋直到空間釋放，行為與 min_size 不滿（E-36）同型（guest 最終 jbd2 hung task）。**唯一告警視窗是 nearfull(0.85)→full(0.95) 之間**；跨過 full 就是 VM hang，救法只有釋放空間（加 OSD/刪資料）。生產：nearfull 是必須行動的告警線，不能當普通 warning 忽略。
- ratio 已確認回退 0.85/0.90/0.95、HEALTH_OK。

## E-51 mapOptions 線上可調性 — done（H-002 T3 confirmed；PV 無 escape hatch）

- Bundle：`results/E-51/<ts>/`
- **step2 決定性結果**：`kubectl patch pv <pv> volumeAttributes.mapOptions` **被 API 直接拒絕**——
  `spec.persistentvolumesource is immutable after creation`（diff 顯示嘗試加 `mapOptions: krbd:queue_depth=256` 被 forbidden）。
- **結論（H-002 T3 confirmed，完整閉環）**：mapOptions 對存量 volume **真的無法線上修改**——改 SC 只影響新 PV（P0 源碼已證），而 PV 的 CSI source 欄位 k8s API 層 immutable、**連手動 patch 的 escape hatch 都不存在**。要改 krbd map option（queue_depth/alloc_size/rxbounce/osd_request_timeout）唯一路徑＝**重建 PVC**（資料要遷移）。這坐實了「D 類＝建置期定死」分類。
- 附註：host nr_requests 讀取（size 比對）回空未取到，非關鍵——API 拒絕已是最強證據。SC/PV 已還原、VM Running、HEALTH_OK。
