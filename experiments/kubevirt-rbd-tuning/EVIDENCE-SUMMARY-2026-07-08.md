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
