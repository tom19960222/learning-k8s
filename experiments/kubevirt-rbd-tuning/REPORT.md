# KubeVirt VM on Ceph RBD — 生產調教與故障行為研究總結報告

> 研究代號 kubevirt-rbd-tuning（本系列第 3 輪；前一輪在 Proxmox VE〔PVE〕生產叢集上只能動 VM 端參數，本輪為專屬實驗環境、全 stack 可調）｜2026-07-07 啟動、2026-07-10 收官
> 30 個真機實驗（規劃 35 個：4 個裁定不執行、1 個〔E-52〕併入其他實驗執行）｜逐實驗原始數據：`EVIDENCE-SUMMARY-2026-07-08.md`（檔名為建檔日；滾動追加的 ledger，涵蓋至 07-10 收官）
> 版本：kubevirt v1.5.0 / ceph-csi v3.14.0 / kernel 6.8 / libvirt v10.10.0 / qemu v9.1.0 / ceph 19.2.4

---

## 0. 這份報告怎麼讀

- **§1 前提**：我們的系統長什麼樣、實驗環境是什麼、「有效」的判定標準。
- **§2 實驗規劃總覽**：35 個實驗一張表（含 4 個不執行的與理由）——每個實驗調什麼參數、為什麼做、預期什麼、結果如何。**趕時間看這張表 + §6 參數建議總表就夠**。
- **§3~§5 逐實驗詳情**：每個實驗固定五欄——調整的參數／為什麼測／預期（實驗前寫死）／結果（實測數字與效果量）／建議。分三組：效能調教（§3）、穩定性與故障行為（§4）、線上可調性（§5）。
- **§6 參數建議總表**：所有參數的最終建議值與理由，可直接當 checklist 用。
- **§7 完整總結**、**§8 侷限與事故記錄**。

Ceph 故障生命週期三行 primer（§4 會反覆用到）：OSD（存資料的 daemon）失聯先被標 **down**（資料還在、IO 由其餘副本續供）；持續 down 達 600 秒（`mon_osd_down_out_interval`）被標 **out**，觸發 **backfill**（把它的資料重建到其他 OSD）；若它回來，改走 **recovery**（補追 down 期間的變更）。**peering** 是每次成員變動時 PG（資料分片群）重新協商的短暫窗口。`noout` 是「維護中，別把它標 out」的旗標。

名詞約定（fio 負載縮寫）：`rr`=4k 隨機讀、`rw`=4k 隨機寫、`sr`/`sw`=1M 循序讀寫；`qd1/qd8/qd32`=同時在途 IO 數（queue depth），qd1 代表延遲敏感型（資料庫 commit）、qd32 代表高並行型。`p99`=第 99 百分位延遲（100 筆裡最慢那 1 筆的等級）；尾延遲（p99/p99.9）是生產關鍵系統的體感，**均值會騙人**——本研究兩個最大的災難（E-15、E-32）均值層面都幾乎看不見。

## 1. 前提

**我們的系統形狀**：生產關鍵 VM 跑在 KubeVirt 上，disk 走 `ceph-csi + krbd` 掛 Ceph RBD（PVC volumeMode=Block → node 上 `rbd map` 成 /dev/rbdX → QEMU 直接吃 block device）。這條鏈上有五層可調參數：KubeVirt VMI 欄位 → QEMU → guest 內核 → host krbd → Ceph 叢集。

**要回答的三個問題**：
1. 每個參數**調了有沒有用**、效果多大？（效能軸）
2. 每個參數**線上改得動嗎**？改動的代價是什麼？（可調性軸）
3. **故障時 VM 會怎樣**——變慢、卡死、丟資料？告警看得到嗎？（穩定性軸）

**判定標準（先於實驗定案）**：穩定優先、latency 優先。正常態 latency 與 throughput 都要顧；degraded 時允許 throughput 下降，但 p99/p99.9 要可控、不雪崩、不卡死、不丟資料。

**實驗環境**：Azure 專屬叢集（可任意破壞）——3 mon + 3 OSD host（每台 1 顆 NVMe 切 3 OSD，共 9 OSD；pool size=3/min_size=2）+ k8s 2 worker（nested KVM）+ KubeVirt v1.5.0，與生產拓樸同型（external ceph）。「生產」在本報告中指前一輪研究所在的 Proxmox VE（PVE）叢集；本輪絕對數字不代表生產，見移植性標記。

**受測 VM 與負載矩陣（所有實驗共用）**：VM = 4 vCPU / 8Gi RAM、Ubuntu 24.04 guest；受測資料盤 = 獨立 RBD PVC（volumeMode: Block, 16Gi）→ guest `/dev/vdb`，已 pre-fill；baseline = KubeVirt 全預設（cache/io 留空）。正常態矩陣 = {隨機讀, 隨機寫}×4k×{qd1, qd8, qd32} + {循序讀, 循序寫}×1M×qd16，共 8 個 pattern，每輪 60s（+15s 暖機）、O_DIRECT、n≥3；每 pattern 收 IOPS/BW 與 p50/p90/p99/p99.9/max。逐實驗比對的「26~29 個指標」= 8 pattern × 上述統計量，經樣本數門檻過濾（如 qd1 樣本不足不報 p99.9）與個別實驗加測項增減所致。degraded 實驗改用固定負載長窗（4k 隨機寫 qd8 + 隨機讀 qd1 並行，1 秒粒度延遲記錄 + 注入/恢復時刻戳記）。

**結論可信度的五道防線**：
1. **預測先寫死**：每個實驗跑之前把預期結果寫進 bundle，跑完只准比對不准改寫——被推翻就標 violated 照實報告（本研究約三成預測被推翻，那三成最有價值）。
2. **噪音帶先量**（E-01）：判定「有差異」的門檻 = `max(2×變異係數, 5%)`，差異小於門檻一律標 indistinguishable（不可分辨），不編故事。
3. **n≥3、A/B 交錯**：排除時間漂移。
4. **生效驗證前置**：每個變體開跑前先從 QEMU cmdline / sysfs / ceph config 證明參數真的生效，杜絕「調了個寂寞」。
5. **觀測互洽**（E-03）：guest 與 host 兩層量到的 IOPS 差 0.03%，數字可信。

**移植性標記**：結論分「機制級」（可搬到任何環境：機制、相對排序、方法）與「數值級」（僅限本環境：絕對數字、倍率——本環境單 NVMe 切 3 OSD 會放大某些倍率）。

## 2. 實驗規劃總覽（規劃 35 個：30 獨立執行 + 1 併入執行 + 4 裁定不做）

一列一個實驗：調什麼、為什麼、預期（實驗前寫死）、結果。✅=預期命中、❌=預期被推翻、➖=不可分辨（差異小於噪音帶）。

### 2.1 基建與判準（4 個——不調參數，為了讓後面的數字可信）

| 編號 | 做什麼 | 為什麼 | 預期 | 結果 |
|---|---|---|---|---|
| E-00 | 環境盤點 | 所有數字掛在版本 snapshot 下 | 版本與 pinned 對齊 | ✅ 對齊；另抓到 cephadm autotune 把 osd_memory_target 抬到 15.7G，已釘回預設 4G（不釘的話讀側數字全被 cache 美化） |
| E-01 | 噪音帶量測（同設定重複 5 輪） | 定「差異可信」的全域門檻 | Azure 噪音比 PVE 生產叢集大 | ❌ **小一個數量級**（CoV 0.4–2.0% vs PVE 的 23%）——判準定為多數 metric 5% |
| E-02 | host 直接 map rbd 跑（不經 VM） | 量「虛擬化稅」與 ceph 端天花板 | host 明顯快於 guest | ✅ 稅集中在高並行隨機讀（qd32 +36.7%）；寫入與循序**幾乎免費**（+1~5%，瓶頸在 ceph 端） |
| E-03 | 三層觀測互洽驗證 | 確保數字可信、延遲可歸因到層 | 三層 IOPS 一致 | ✅ guest vs host 差 0.03% |

### 2.2 效能調教（11 個——每個調一個參數，A/B 對照）

| 編號 | 調整的參數（值域） | 為什麼 | 預期 | 結果 |
|---|---|---|---|---|
| E-10 | VMI `cache`：**none(預設)** / writethrough / writeback | impact 推論最高的旋鈕 | wb 均值↑但尾延遲爆；wt 寫變慢 | ✅ wb 寫均值 +272~1997% 但 **p99.9 +2064%、1.5~3.5 秒整段卡住**；wt 寫 −35~37% 嚴格劣化 → **維持 none** |
| E-11 | VMI `bus`：**virtio-blk(預設)** / virtio-scsi | bus 的效能代價 | scsi 高並行較慢 | ➖ IOPS 全同；但 scsi max latency 全面較差（+20~150%）→ **維持 virtio-blk** |
| E-12 | VMI `io`：**native(預設)** / threads | AIO 提交模型 | threads 較慢 | ❌ threads 不輸、qd32 讀還 **+12.4%**——「native 必勝」不成立；仍維持預設（增益小、CPU 代價未量） |
| E-13 | `blockMultiQueue`：開 / **不開(預設)** | 驗「開了=沒開」 | 兩者相同（QEMU 已自動=vCPU 數） | ✅ guest queue 數兩變體都=4，**開了=沒開**，不用設 |
| E-14 | `dedicatedIOThread`：開 / **不開(預設)** | IOThread 獨佔值不值 | 單盤無差 | ✅ 單盤無感、也收不回虛擬化稅 → 單盤 VM 不用開 |
| E-15 | **pod CPU limit**：4(=vCPU) / 2(<vCPU) | 驗「CFS throttle 是隱形尾延遲殺手」 | 被 throttle 側 p99.9 差一個數量級 | ✅ **p99 7.6→55.8ms（×7.4）、IOPS 砍半、p50 不變**——全研究唯一數量級旋鈕；門檻=limit≥vCPU 數（兩變體都是 Guaranteed QoS，QoS class 不是重點） |
| E-17 | guest scheduler：**none** / mq-deadline | guest 再排程是否多餘 | none 略優、可能帶內 | ✅ 超預期：none 循序讀 **+39.7%**、寫 +30.1% → **必須是 none**（檢查清單項） |
| E-18 | guest `read_ahead_kb`：128/512/4096 | 循序讀路徑 | 4096 循序讀較快 | ❌ 全帶內——O_DIRECT 負載繞過 page cache，readahead **根本不參與**；資料庫型（direct IO）不用碰 |
| E-19 | krbd `queue_depth`：64/**128(預設)**/256 | 並行上限甜蜜點；驗「調高會傷 qd1 延遲」 | 高並行↑、qd1 p99↑（排隊代價） | 一半 ❌：高並行 **+10~21% 且 p99 反而更好**；**qd1 零代價**（cap 對低並行無感）→ 256 純加分，但屬建置期參數（見 E-51） |
| E-21 | `osd_memory_target`：**4G(預設)** / 8G | BlueStore cache 對讀 p99 | 8G 讀 p99 較好 | ➖ 全帶內——12G 聚合 cache 已蓋住 16G 測試盤熱資料，加倍無多餘命中；收益只在 working set > cache 時出現 |
| E-22 | `osd_op_num_shards`：**8(預設)** / 16 | OSD 並行分片；順便量 rolling restart 代價 | 效果帶內；rolling 有尖峰 | ✅ 效果帶內（8 已足）；**rolling restart 9 OSD 期間 client 讀 p99 → 1360ms**——改這類參數本身就是一次 degraded 事件 |

### 2.3 穩定性與故障行為（13 個——固定 baseline 設定，注入故障）

| 編號 | 注入什麼 | 為什麼 | 預期 | 結果 |
|---|---|---|---|---|
| E-30 | 停 1 顆 OSD（乾淨 down），等自動 out、再回歸 | 最常見故障的完整生命週期 | 尖峰只在 peering 秒級窗 | ✅+細化：down 當下近乎無感；**真正傷害在 600 秒後 auto-out 觸發的 backfill——隨機讀 ×24** |
| E-31 | 硬斷整台 OSD host（3 顆 OSD 同滅） | 「掉一台」比「掉一顆」慘多少 | 同型但更寬 | ❌ 更好：**與掉一顆幾乎相同**（一次 38ms 尖峰）——min_size 撐住就沒事。⚠ 僅斷 ~4 分鐘、未跨 auto-out 門檻（見詳情 caveat） |
| E-32 | 一台 OSD host 網路 +50ms（gray failure，OSD 沒死） | 驗「半死比死更傷且無告警」 | p99 惡化但 HEALTH_OK 不變 | ✅ **寫 ×40、讀 ×19，`ceph health` 全程 OK 零告警**——本研究最重要發現；size=3 下一台慢 host 毒化全部寫入 |
| E-33 | 網路封包遺失 0.1%/0.5% | 驗「丟包炸尾延遲」 | p99.9 惡化 >5× | ❌ 最壞 **1.1×**——低 RTT 下 TCP 快速重傳吸收；**Ceph 怕延遲不怕丟包**（與 E-32 對照），網路監控重心=RTT |
| E-34 | OSD 反覆 down/up（flapping）± `noout` | flapping vs 單次故障；noout 值多少 | flapping 更傷；noout 顯著壓低 | ✅ mean ×12、p999 1146ms；**noout 把 p999 砍 71%**（止血有效，但 peering 尖峰仍在） |
| E-35 | mon 停 1/3 → 停 2/3（quorum 失）→ 再殺 1 顆 OSD | 複合故障：管理面死了資料面撐多久 | quorum 失後穩態 IO 照跑；疊 OSD 死→無限 hang | ✅ 全命中：quorum 失**穩態 IO 照跑**（假象）；疊加後寫入卡進**不可中斷 D-state**；恢復順序硬約束=**先 mon 後 OSD** |
| E-36 | 停同一 PG 的 2 顆 OSD（min_size 不滿）× `osd_request_timeout` 0/30 | 驗「唯一的有界等待參數」能否把卡死轉成可控錯誤 | timeout=30 的盤 30 秒收到 IO error | ❌ **完全不觸發**：blocked 302.8s 直到 OSD 回歸，零錯誤零訊息——**這參數在最該出場的情境不出場，不能依賴**（機制矛盾開放中 H-034） |
| E-37 | 全 pool deep-scrub × `osd_scrub_sleep` 0/0.1 | 驗「scrub 打擾 client」 | sleep=0 時 p99 惡化 | ❌ 全程平坦——NVMe headroom 吸收；scrub 節流參數在有餘裕的叢集**沒有用武之地** |
| E-38 | pool 推到 nearfull → full | 容量耗盡時寫入是報錯還是卡死 | nearfull 只告警；full 後寫入 hang（非 ENOSPC） | ✅ **full 後寫入卡 96 秒直到解除、不是報錯**——應用只會看到卡住；**nearfull 是唯一能行動的告警窗，必須當立即行動級** |
| E-39 | backfill 進行中切 `osd_mclock_profile`：balanced / high_client_ops | 驗「degraded 時保 latency 的頭牌 Ceph 參數」 | high_client_ops 使 client 惡化減半 | ❌ **兩個 profile 無差**（headroom 下沒有爭用可仲裁）；對照 E-30 挖出真凶=**down 期間累積的寫入債**（recovery 擋 client），管理 out 時機比調 QoS 有效 |
| E-40 | node 硬斷電 × cache none/writeback（回讀已確認寫入） | cache mode 的資料一致性代價 | writeback 丟資料；none 乾淨 | ✅（注入升級後）：**writeback 丟最後 ~6 秒「已回報成功」的寫入**；none **0 遺失**；光 kill QEMU 不丟——代價只在 node 級災難兌現 |
| E-41 | 硬斷 k8s node，計時 VM 在他處恢復 | 做出 failover 時間預算表 | 分鐘級、可分段計時 | ❌ 更糟：**預設根本不 failover**——VMI 卡死 node「假 Running」11 分鐘+，force-delete 被擋；另一輪 ~5 分鐘後 eviction 觸發重排（慢且不可靠）→ **必須部署 NodeHealthCheck** |
| E-42 | 高 IO 負載中 live migration ×3 | 維運動作本身的 IO 代價 | 每次 <1s 尖峰、無錯誤 | ✅ 零中斷、最差 1 秒窗 8ms——**節點維運放心用 migration** |

### 2.4 線上可調性驗證（2 個——參數「改不改得動」的真機閉環）

| 編號 | 驗什麼 | 預期 | 結果 |
|---|---|---|---|
| E-50 | 改 VMI disk 欄位後，live migration 能不能把新值帶上去 | 不能；只有 stop/start 能 | ✅ patch 後 VM 標 `RestartRequired`、migration ×2 後參數不變——**VMI 層參數=停機參數**；且 revert spec 也不清除 RestartRequired |
| E-51 | krbd map options 對存量磁碟有沒有任何線上修改路徑 | 改 SC 無效；直接 patch PV 或許可以 | 一半 ❌：改 SC 無效（預期中）；**patch PV 被 k8s API 直接拒絕（immutable）——連後門都沒有**，唯一路徑=重建 PVC 搬資料 |

（規劃中的第 35 個實驗 E-52「ceph config set runtime 生效驗證」不需獨立跑，併入 E-21/E-39 執行：OSD 記憶體用量隨設定實變、mClock profile 切換即時生效——runtime 類參數確認可線上調。）

### 2.5 裁定不執行的 4 個

| 編號 | 原計畫 | 不做的理由 |
|---|---|---|
| E-16 | `dedicatedCpuPlacement`+`isolateEmulatorThread` 在 node 競爭下的收益 | 使用者裁定：主風險已由 E-15 回答（limit≥vCPU 即安全線），正面收益驗證不值 kubelet CPUManager 改機成本 |
| E-20 | image object-size/striping | E-02 已證瓶頸不在 layout；建置期參數且收益推論小，列入低優先 backlog |
| E-23 | pool size=2 vs 3 的寫入代價 | 結論預先固定（生產維持 3），量化列入低優先 backlog；E-32 反而量到了 size=3 的真實代價形狀 |
| E-43 | 逐一 kill csi/virt-handler/kubelet | 機制推論明確（krbd 是 kernel 態、與控制面解耦），列入低優先 backlog |

## 3. 逐實驗詳情：效能調教

> 每個實驗五欄：調整的參數／為什麼測／預期／結果／建議。數字未標註者皆為本環境實測（數值級）；「建議」為機制級、可移植。

### E-10 cache mode —— 最重要的「不要動」

- **調整的參數**：VMI `spec.template.spec.domain.devices.disks[].cache`：留空（=none，O_DIRECT 直寫）／writethrough／writeback（host page cache）
- **為什麼測**：這是 impact 推論最高的旋鈕，網路教學最愛推 writeback「提升效能」。
- **預期**：writeback 寫入均值變好但 p99.9 爆炸、出現 >100ms 尖峰；writethrough 寫入全面變慢；讀側無差。
- **結果**：預期全中、幅度更狠。writeback：4k 隨機寫均值 +272~1997%（qd1 592→12424 IOPS——host RAM 直接回報成功的假象），但 **p99.9 +2064%（3.3ms→71ms）、循序寫出現 1.5~3.5 秒整段卡住**。writethrough：寫入 IOPS −35~37%、p99 +22~40%，嚴格劣化無任何補償。附帶抓到量測陷阱：wt/wb 模式下讀走 host RAM，讀側「+161~176%」是假增益（生產 working set 大於 RAM 時消失）。
- **建議**：**cache 欄位留空（=none）**。writeback 唯一適用場景：能接受尾延遲爆炸＋node 硬斷丟最後 ~6 秒資料（E-40 實測）的非關鍵 workload。

### E-11 disk bus —— 換了沒好處

- **調整的參數**：`disks[].disk.bus`：virtio（=virtio-blk，預設）／scsi（virtio-scsi）
- **為什麼測**：流傳說法「virtio-scsi 有 30 秒 timeout，卡死會變成可處理的 IO error」；源碼查證已推翻（兩種 bus 都永不逾時，kernel 6.8 的 `virtscsi_eh_timed_out` 無條件重設計時器），剩效能對照。
- **預期**：scsi 高並行 IOPS 較低（路徑較長）。
- **結果**：IOPS 全部不可分辨（≤4.4%）；但 scsi 的 max latency 全面較差（+20~150%）。
- **建議**：**維持 virtio-blk**。不要為了「以為有 timeout 保護」換 scsi——保護不存在，尾延遲還更差。

### E-12 io mode —— 常識被推翻但不用動

- **調整的參數**：`disks[].io`：留空（=native，Linux AIO）／threads（執行緒池）
- **為什麼測**：「native 一定比 threads 快」是調教文章的標配說法。
- **預期**：threads 在 qd32 隨機讀較慢。
- **結果**：**推翻**——threads 不輸，qd32 隨機讀反而 +12.4%、p99 −7.2%，其餘 22/26 個指標帶內。
- **建議**：**維持預設（native）**——增益只在單一 pattern、且 threads 的 CPU 代價未量；但「native 必勝」的說法可以從團隊知識庫刪掉。

### E-13 blockMultiQueue —— 開了等於沒開

- **調整的參數**：`blockMultiQueue: true` vs 不設
- **為什麼測**：驗證「新 QEMU 上這個開關是 no-op」——QEMU 預設 AUTO 已把 queue 數設為 vCPU 數。
- **預期**：兩變體 guest queue 數相同、效能相同。
- **結果**：✅ 7/7 次驗證兩變體 guest queue 都=4；QEMU 指令列唯一差異=顯式寫出 `num-queues:4`（本來就會自動解析成 4）；23/29 指標帶內，超帶項查明為時間漂移。
- **建議**：**不用設**。唯一用途是老 QEMU（<AUTO 支援）或需要顯式固定 queue 數的場景。

### E-14 dedicatedIOThread —— 單盤無感

- **調整的參數**：`disks[].dedicatedIOThread: true` vs 預設共用
- **為什麼測**：QEMU 陣營常推「IO 執行緒獨佔」；也想知道能否收回 E-02 量到的 36.7% 高並行虛擬化稅。
- **預期**：單盤差異帶內；（雙盤並行是它的主場，本輪未排）。
- **結果**：單盤 17/26 指標帶內、邊緣項雙向抖動；**收不回虛擬化稅**（qd32 IOPS 帶內）——瓶頸不在「缺一條獨立 IO 執行緒」。
- **建議**：**單盤 VM 不用開**。多盤高並行 VM 要用前先在自己環境重測（雙盤變體列入低優先 backlog）。

### E-15 CPU limit —— 全研究唯一的數量級旋鈕 ⚠

- **調整的參數**：virt-launcher pod 的 CPU limit：4（=vCPU 數）vs 2（<vCPU 數）。**兩個變體都是 Guaranteed QoS**（requests=limits）。
- **為什麼測**：假說「CFS quota throttling 是隱形的尾延遲殺手」——k8s 資源層完全不在任何 storage 調教文件裡。
- **預期**：被 throttle 變體 p99.9 差一個數量級、出現 ~100ms 級週期尖峰。
- **結果**：guest 有 CPU 負載時，limit=2 使 **IOPS 7042→3352（砍半）、p99 7.6ms→55.8ms（×7.4）、p99.9 ×5.6——而 p50 幾乎不變（938→946us）**。機制：4 個 vCPU 執行緒＋emulator 共享 2 核配額，CFS 以 100ms 週期整段凍結，IO completion 跟著凍。
- **建議（本報告最重要的一條）**：**VM 的 CPU limit 必須 ≥ vCPU 數**，寫進 VM 模板審查規則；或用 `dedicatedCpuPlacement` 徹底免除 CFS quota。注意兩個陷阱：(1)「Guaranteed QoS 就安全」是錯的——門檻是 limit 對 vCPU 數，不是 QoS class；(2) p50/均值完全看不到這個問題，**監控必須看 p99**。

### E-17 guest IO scheduler —— 必須是 none

- **調整的參數**：guest 內 `/sys/block/vdb/queue/scheduler`：none vs mq-deadline
- **為什麼測**：RBD 底層已有自己的排序與並行；guest 再排一層是否純開銷。
- **預期**：none 略優，幅度可能落在噪音帶內。
- **結果**：超出預期——none 循序讀 **+39.7%（1640→2291 MiB/s）**、循序寫 +30.1%、qd32 隨機讀 +6%（p99 −7.7%）。
- **建議**：**guest 內 block device 的 scheduler 必須是 none**（Ubuntu 24.04 virtio-blk 預設即是）。這是檢查清單項不是調教項：**發現映像檔或設定管理把它改成 mq-deadline/bfq，要改回來**。

### E-18 guest readahead —— 對 direct IO 是「非參數」

- **調整的參數**：guest `/sys/block/vdb/queue/read_ahead_kb`：128（預設）/512/4096
- **為什麼測**：循序讀路徑上的教科書參數。
- **預期**：4096 的循序讀吞吐較高。
- **結果**：**全部帶內**——事後看是機制必然：測試負載是 O_DIRECT（資料庫型），完全繞過 page cache，readahead 根本不參與。
- **建議**：direct IO 型服務（資料庫、本研究的目標 workload）**不用碰 readahead**；buffered IO 型（檔案服務）另案評估。

### E-19 krbd queue_depth —— 純加分，但要在建置期決定

- **調整的參數**：StorageClass `mapOptions: "krbd:queue_depth=N"`：64／128（預設）／256
- **為什麼測**：並行上限的甜蜜點；驗證「調高會付出低並行延遲代價」的直覺。
- **預期**：高並行 IOPS 隨 N 上升；qd1 p99 也隨 N 上升（更深排隊）。
- **結果**：前半中、後半推翻——**qd256 高並行 +10.3%（讀）/+20.8%（寫）且 p99 同時改善 11~15%；qd1 完全零代價**（queue_depth 是上限 cap，in-flight=1 時根本碰不到）。
- **建議**：**高並行 workload 的 StorageClass 設 `queue_depth=256`**——純加分無代價。為什麼不乾脆全部 SC 預設 256？兩個保守理由：本輪只在單 VM 單盤驗證（多 VM 高並行齊發時更深的 host 端佇列是否引入新的競爭未測）；且它建置期定死、錯了無法回頭（E-51）——所以建議「預設 128 照舊、明確有 qd>128 需求的 workload 開新 SC 用 256」，而不是全域翻新。

### E-21 osd_memory_target —— 本環境加倍無感，邊界條件是重點

- **調整的參數**：`ceph config set osd osd_memory_target`：4G（預設）vs 8G（runtime 生效）
- **為什麼測**：唯一「不停機、單調有利於讀延遲」的 Ceph 側候選參數。
- **預期**：8G 的隨機讀 p99 較好。
- **結果**：**全帶內**。OSD RSS 實際改變（1.1G→1.5G，證明參數生效），但 4G×3 OSD 的聚合 cache 已蓋住 16G 測試盤的熱資料——加倍拿不到多餘命中。
- **建議**：**收益只在 working set > 現有 cache 時出現**——加記憶體前先確認你在那個 regime（看 BlueStore cache 命中率），否則是浪費。附帶教訓：cephadm autotune 會自動把它抬很高（本環境 15.7G），做效能對比前要留意這個變數。

### E-22 osd_op_num_shards —— 零收益，改動本身還要付費

- **調整的參數**：`osd_op_num_shards_ssd`：8（預設）vs 16——**startup 參數，改了要 rolling restart 全部 OSD**
- **為什麼測**：OSD 並行分片是常見的「進階調教」項；順便量「改 startup 參數」這個動作本身的代價。
- **預期**：效果帶內（9 OSD NVMe 下 8 已夠）；rolling 期間 client 有尖峰。
- **結果**：兩個都中。效果全帶內；**rolling restart 9 顆 OSD 期間 client qd1 讀 mean ×39、p99 至 1360ms**——每顆 OSD 重啟時它主管的 PG 讀阻塞於 peering 窗，9 顆累積成秒級。
- **建議**：**shards 維持預設 8**。更重要的普遍結論：**任何 startup 類 Ceph 參數的變更＝一次全叢集 rolling restart＝一段 client 尾延遲秒級惡化的 degraded 窗**——要改就排維護窗，且先確認收益值得（本例不值得）。

## 4. 逐實驗詳情：穩定性與故障行為

### E-30 單 OSD down 完整生命週期 —— 傷害不在故障當下

- **注入**：`ceph orch daemon stop osd.N`，等 600 秒自動標 out（觸發 backfill），再回歸（觸發 recovery）。負載：4k 隨機寫 qd8 + 隨機讀 qd1 並行長窗。
- **為什麼測**：最常見的故障；要把「哪一段才痛」量出來。
- **預期**：p99 尖峰只在 peering 窗（秒級）、IO 不中斷、告警正確亮。
- **結果**：✅ 加上關鍵細化——分相位量測：down 當下 peering 尖峰僅 3.8ms；**down 但未 out 的 580 秒完全=baseline**；auto-out 後 backfill 相**隨機讀 mean ×24（0.96→22.7ms）、出現整秒級尖峰**；回歸後 recovery 相寫入 max 309ms；之後全自癒。
- **建議**：短暫維護（重開機、換記憶體）**先 `ceph osd set noout`**，避免觸發無意義的 backfill；預期外故障要嘛 10 分鐘內救回、要嘛接受 backfill 窗。監控 degraded objects 數量（傷害的領先指標，見 E-39）。

### E-31 整台 OSD host 硬斷 —— 掉一台 ≈ 掉一顆

- **注入**：Azure 強制關機一台 OSD host（3/9 OSD 瞬間消失），down ~4 分鐘後開回。
- **為什麼測**：「整台掛掉」是生產最怕的劇本之一；想知道比單 OSD 慘多少。
- **預期**：與 E-30 同型但尖峰更寬。
- **結果**：❌ 比預期好——**幾乎無感**：僅一次 38ms peering 尖峰、qd1 讀 mean 0.99→1.18ms，health 只到 WARN，回機後數十秒 HEALTH_OK。機制：size=3 + CRUSH 每 host 一副本 → 掉一整台後每個 PG 仍剩 2 副本 = min_size 滿足，IO 續存。
- **⚠ Caveat（重要）**：本實驗 host 只斷了 ~4 分鐘，**未跨過 600 秒 auto-out 門檻、未進入 backfill 相**。若 host 長時間回不來，1/3 的叢集資料會觸發重建，屆時進入的是 E-30 量到的 backfill 劇本（隨機讀 ×24 等級、且規模是單 OSD 的三倍）——「無感」只在及時救回（或先設 noout）的前提下成立，長斷情境本輪未驗證。
- **建議**：**容錯的關鍵是 min_size 是否滿足，不是失效顆數**——在「斷線短於 out 門檻」的前提下，單 host 災難是無感事件。host 預期長時間離線時，決策點在 out 門檻前：要嘛 `noout` 撐到修復、要嘛有計畫地接受一次大型 backfill。演練重點放在「連續故障」「gray failure」與「長斷 host」。

### E-32 gray failure（慢 host）—— 本研究最重要的發現 ⚠

- **注入**：一台 OSD host 網卡加 50ms 延遲（OSD 全部活著、heartbeat 正常——模擬 NIC 劣化/壅塞/半死）。
- **為什麼測**：「半死比死更傷且無告警」是本研究立項時最在意的假說。
- **預期**：client p99 惡化、但 `ceph health` 維持 OK（若命中即為高價值發現）。
- **結果**：✅ 幅度驚人——**寫入 mean ×40（1.73→69.6ms）、讀 ×19，`ceph -s` 全程 HEALTH_OK、零告警、無 OSD 被標 down**。機制：寫入要等 3 副本全部 ack、CRUSH 每 host 一副本 → **每一筆寫入都要等那台慢 host** → 一台 gray 毒化全叢集寫入。讀「只」×19 因為只有 primary 落在慢 host 的 ~1/3 PG 受害。
- **建議**：**不能只用 ceph health 判斷 storage 健康**。監控必須加三樣，起手式閾值（以各自環境 baseline 校準，本環境 baseline：client qd1 ~1ms、叢集內 RTT <1ms）：(1) client 端 p99 > 3× 自身 7 日 baseline 持續 5 分鐘；(2) `ceph osd perf` 單一 OSD 的 commit/apply latency 高於全體中位數 5 倍（NVMe 叢集絕對值 >20ms 即可疑）；(3) OSD host 間 RTT > 5× baseline（NVMe 低延遲叢集 >2ms 即異常）。現成規則：本 repo `experiments/ceph-alert-rules/`（已含 gray-failure 相關規則並經真機驗證）。

### E-33 封包遺失 —— 意外的「不用怕」

- **注入**：OSD host 網卡 0.1%、0.5% 隨機丟包。
- **為什麼測**：「丟包炸尾延遲」（TCP 重傳 RTO 200ms 級）是網路圈常識。
- **預期**：0.1% loss 就讓 p99.9 惡化 >5×。
- **結果**：❌ **最壞才 1.1×**。機制：叢集內 RTT <1ms，現代 TCP（SACK/快速重傳）在 ~1 個 RTT 內修復串流中的丟包，根本不觸發 RTO；且 0.1~0.5% 下多數 IO 沒中獎。
- **建議**：與 E-32 合成一條網路監控方針：**Ceph-on-TCP 對「延遲」極度敏感（+50ms→×40）、對「稀疏丟包」極度遲鈍（0.5%→1.1×）**——網路排查與告警的第一優先是 RTT/延遲，不是丟包率。

### E-34 OSD flapping ± noout —— 止血鍵值多少錢

- **注入**：單 OSD 週期性 stop 60s/start 60s ×5 輪；對照組先 `ceph osd set noout`。
- **為什麼測**：flapping（網路抖動、碟半壞造成的反覆上下線）是常見劣化模式；noout 是標準止血動作，想量它值多少。
- **預期**：flapping 傷害 > 單次 down；noout 顯著壓低。
- **結果**：✅ flapping 使 qd1 讀 mean ×12、p999 至 1146ms；**noout 後 mean −43%、p999 −71%（→335ms）**——擋掉重複 backfill，把傷害限縮在純 peering。但 noout 不能歸零：每次 down/up 的 primary 重選仍讓讀尖峰到 335ms。
- **建議**：**偵測到 flapping 立即 `ceph osd set noout` 止血**，同時查根因（網路/碟）——noout 是止血不是治本，事後記得 unset。

### E-35 mon quorum 階梯 + 複合故障 —— 恢復順序是硬約束

- **注入**：三段：停 1/3 mon（quorum 保住）→ 停 2/3 mon（quorum 失去）→ quorum 失狀態下再殺 1 顆 OSD。
- **為什麼測**：驗「複合故障的傷害遠大於兩個單一故障之和」；以及管理面全滅時資料面能撐多久。
- **預期**：1/3 無感；quorum 失後穩態 IO 照跑 ≥5 分鐘；疊加 OSD 死後 IO 無限 hang 且無法自癒。
- **結果**：✅ 三段全中。quorum 失去後**穩態 IO 完全正常**（client 拿既有 osdmap 直連 OSD，不需要 mon）——這是危險的假象：管理面已死、但看起來沒事；此時疊加 OSD 死亡，受影響 PG 的寫入**卡進不可中斷 D-state（SIGKILL 都殺不掉）**——沒有 mon 發新地圖，client 永遠不知道 OSD 死了。恢復實測：**必須先救回 mon quorum、再救 OSD**，順序反了無效。
- **建議**：(1) mon 監控不能依賴 mgr/Prometheus 指標——quorum 失去時觀測面一起死，要用外部 blackbox 探測 mon 端口；(2) 把「先 mon 後 OSD」寫進事故 runbook；(3) mon 只剩 2/3 時就當 P1 處理——再掉任何東西就是上面的劇本。

### E-36 min_size 不滿 × osd_request_timeout —— 救命索不存在 ⚠

- **注入**：停掉同一 PG 的 2 顆 OSD（size=3/min_size=2 不滿 → PG 不可用）300 秒；對照兩顆盤：`osd_request_timeout` 未設（預設 0=永不）vs 30 秒。
- **為什麼測**：源碼上這是**唯一**能把「無限卡死」轉成「N 秒後收到 IO error」的 client 側參數；它可靠嗎？
- **預期**：未設的盤無限 hang；timeout=30 的盤 30 秒收到 -ETIMEDOUT。
- **結果**：❌ **timeout 完全不觸發**——設定實證生效（host config 可見），但寫入 blocked 302.8 秒直到 OSD 回歸，無錯誤、無 kernel 訊息，恢復後該筆寫入直接成功。與源碼閱讀矛盾（理論上必觸發），機制環節仍在追查（開放問題 H-034）。
- **建議**：**不要把 `osd_request_timeout` 當防卡死的保險**——在它最該出場的情境（PG 不可用）實測不出場。防卡死的防線只能是：(1) 不讓 PG 掉到 min_size 以下（size=3/min_size=2、快速換件、容量規劃）；(2) application 層自己的 timeout/健康檢查。

### E-37 deep-scrub 干擾 —— 有餘裕就無感

- **注入**：對全 pool 64 個 PG 齊發 deep-scrub；對照 `osd_scrub_sleep` 0（激進）vs 0.1（節流）。
- **為什麼測**：scrub 是「自己人造成的 degraded」最常見來源。
- **預期**：sleep=0 時 client p99 惡化、0.1 壓回。
- **結果**：❌ scrub 確實在跑（時戳實證），但 client 全程平坦（p99 1.0ms 不動）、兩檔位無差——NVMe headroom 直接吸收。
- **建議**：與 E-39 合併成一條：**在 NVMe + 有餘裕的叢集，Ceph 的 QoS/節流類參數（scrub_sleep、mClock profile）多半不可分辨——沒有爭用可仲裁**。該投資的是容量 headroom；這些參數的主場在媒體飽和（HDD 或打滿）的叢集。

### E-38 pool full —— 容量耗盡是卡死事件，不是報錯事件

- **注入**：調 ratio 把 pool 推過 nearfull、再推過 full。
- **為什麼測**：容量耗盡時應用看到什麼——優雅的 ENOSPC 還是卡住？
- **預期**：nearfull 只告警；full 後寫入 hang 而非報錯。
- **結果**：✅ nearfull：告警亮、寫入完全不受阻。full：**寫入卡 96 秒（跨整個 full 窗），不是 ENOSPC 不是 EIO**；解除後那筆寫入直接成功。行為與 min_size 不滿（E-36）同型。
- **建議**：**nearfull（預設 85%）必須設為「立即行動」級告警**——它是卡死前唯一的窗口；跨過 full（95%）就是全部 VM 寫入凍結，唯一解法是釋放空間。容量規劃把 nearfull 當硬線，不是舒適線。

### E-39 mClock profile —— 頭牌 QoS 參數沒用，真凶另有其人

- **注入**：立即 `osd out` 觸發 backfill（搬 60G），backfill 進行中對照 `osd_mclock_profile` balanced vs high_client_ops。
- **為什麼測**：這是官方文件「degraded 時保 client latency」的頭牌參數（runtime 可調）。
- **預期**：high_client_ops 使 client 惡化減半、recovery 拉長 >1.5×。
- **結果**：❌ **兩個 profile 完全無差**（client 1.31ms vs 1.31ms）——headroom 太大，recovery 沒讓 client 等。但對照 E-30 挖出真正的機制：同樣是 backfill，E-30 讀 ×24、這裡只 +38%——差別是 E-30 有 600 秒「down 但未 out」期間的持續寫入，累積了**熱物件 recovery 債**（這些物件恢復時會擋 client op）；E-39 立即 out、無債。
- **建議**：**degraded 傷害管理的重點是「控制 out 時機、縮短 down 窗」而不是切 QoS profile**。監控 degraded objects 數量；mClock profile 留作媒體飽和時的工具。

### E-40 crash consistency —— writeback 的隱形帳單

- **注入**：guest 持續寫入（每筆記序號、確認回報成功）→ node 硬斷電 → 回機後回讀比對。對照 cache=writeback vs none。原計畫用 kill QEMU 注入，執行中發現不夠狠（見結果），升級為 node 硬斷。
- **為什麼測**：E-10 只證明 writeback 尾延遲差；資料一致性代價要單獨釘死。
- **預期**：writeback 丟資料；none 乾淨。
- **結果**：✅（含方法論修正）：**光 kill QEMU/pod 不丟**（host page cache 還在、unmap 時會 flush）——很多人以此測試就宣稱 writeback 安全，是錯的；**node 硬斷才見真章：writeback 丟最後 ~6 秒「guest 已收到成功回報」的寫入**（kernel 每 ~5 秒才回寫較舊資料）；**cache=none 同注入 0 遺失**（O_DIRECT 每筆直穿到 Ceph）。
- **建議**：cache mode 是 **correctness 決策**不只是效能選擇：生產關鍵 VM 用 none；若有 workload 想用 writeback，明確簽收「node 級災難丟最近數秒已確認寫入」的風險——而且丟的是最近幾秒，最難察覺。

### E-41 node 硬斷 failover —— 預設行為是「不救」 ⚠

- **注入**：Azure 強制關機跑著 VM 的 k8s worker，計時 VM 在其他 node 恢復的每一段。
- **為什麼測**：原目標是做出「failover 時間預算表」（NotReady 判定→pod 刪除→重排→attach→開機，各段多久）。
- **預期**：總時間分鐘級、可分段計時、ceph attach 段不是瓶頸。
- **結果**：❌ 比預期糟得多——**預算表做不出來，因為預設根本不 failover**：VMI 卡在死 node 上顯示 Running（假象）**11 分鐘以上**毫無動作；手動 force-delete 被 stuck finalizer 擋住（死 node 無法確認 pod 終止）。恢復靠把 node 開回來。另一輪不人工介入，~5 分鐘後 k8s 預設 eviction 觸發了重排——所以自動 failover「可能發生，但慢且不可保證」。
- **建議**：**生產要 VM 高可用，必須部署 node-loss 自動化（NodeHealthCheck / machine-health-check）**——這是必需品不是加分項。並且把「node 硬斷後 VMI 假 Running」加入演練劇本，值班人員要看過這個畫面。

### E-42 live migration 的 IO 代價 —— 好消息

- **注入**：4k 隨機寫 qd8 進行中 `virtctl migrate` ×3 次，1 秒粒度連續記錄延遲。
- **為什麼測**：migration 是節點維運（kernel 升級、汰換）的日常工具，它自己的 IO 擾動是 SLO 的一部分。
- **預期**：每次一個 <1 秒的尖峰、無 IO 錯誤。
- **結果**：✅ 比預期更好——**零中斷**（無任何 >2.5s 記錄斷點）、migration 期間最差 1 秒窗 3.8/8.0/7.2ms（baseline 1.53ms）、三次全部成功。
- **建議**：**節點維運放心排 migration**，IO 面的代價是個位數 ms 的短暫抬升。（記憶體密集 workload 的 dirty-page 收斂是另一題。）

## 5. 逐實驗詳情：線上可調性

### E-50 VMI 欄位的套用路徑 —— migration 不是免停機的後門

- **驗什麼**：改 VM template 的 disk 參數後，live migration 能不能把新值帶到新 node（=零停機套用）？
- **預期**：不能——controller 只會標 `RestartRequired`，唯一套用路徑是 stop/start。
- **結果**：✅ patch cache 欄位 → `RestartRequired` 出現；migration ×2 後 QEMU 參數不變。**額外發現**：把 spec 改回原樣，`RestartRequired` **不會消失**——碰過非 live-updatable 欄位就掛著直到重啟。
- **建議**：**把 VMI 層參數（cache/io/bus/CPU limit 等）當「停機參數」規劃**——變更要排 VM 重啟窗；改錯了也沒有「改回去就當沒發生」，動手前先確認。

### E-51 krbd map options —— 連後門都沒有

- **驗什麼**：存量磁碟的 map options（queue_depth 等）有沒有任何線上修改路徑？兩條候選：改 StorageClass、直接 patch PV。
- **預期**：改 SC 無效（源碼已證只影響新 PV）；patch PV 的 volumeAttributes 或許是非官方後門。
- **結果**：改 SC 無效 ✅；**patch PV 被 k8s API 直接拒絕**（`spec.persistentvolumesource is immutable after creation`）——後門不存在 ❌。
- **建議**：**krbd 層參數是「建置期定死」**：唯一修改路徑=建新 SC + 新 PVC + 搬資料。所以 queue_depth、`osd_request_timeout` 這類決策**必須進 StorageClass 設計 checklist**，上線後才想調就是一次資料搬遷工程。

## 6. 參數建議總表（checklist）

| 層 | 參數 | 建議 | 依據 | 效果量 | 可調性 |
|---|---|---|---|---|---|
| KubeVirt | `cache` | **留空（=none）** | E-10/E-40 | 動了：尾延遲 +2064%、node 硬斷丟 ~6s 資料 | 停機參數 |
| KubeVirt | `io` | 留空（=native） | E-12 | 改 threads：±帶內~+12% 單一 pattern | 停機參數 |
| KubeVirt | `bus` | virtio-blk | E-11 | 改 scsi：max latency +20~150%，無補償 | 停機參數 |
| KubeVirt | `blockMultiQueue` | 不設 | E-13 | 0（開了=沒開） | 停機參數 |
| KubeVirt | `dedicatedIOThread` | 單盤不開 | E-14 | 0（單盤） | 停機參數 |
| k8s | **CPU limit** | **≥ vCPU 數（入模板審查）** | E-15 | **違反：p99 ×7.4、IOPS 砍半、p50 不動** | 停機參數 |
| guest | IO scheduler | **none（入檢查清單）** | E-17 | 被改掉：循序 −30~40% | runtime |
| guest | `read_ahead_kb` | direct IO 型不用碰 | E-18 | 0（O_DIRECT 不參與） | runtime |
| krbd | `queue_depth` | 高並行 workload 的 SC 設 **256** | E-19/E-51 | +10~21% IOPS 且 p99 更好；qd1 零代價 | **建置期定死** |
| krbd | `osd_request_timeout` | **不設、不依賴** | E-36 | 該觸發時不觸發（開放問題） | 建置期定死 |
| Ceph | `osd_memory_target` | 維持 4G，除非 working set > cache | E-21 | 本環境 0；留意 autotune 亂抬 | runtime |
| Ceph | `osd_op_num_shards` | 維持 8 | E-22 | 0；改動本身=一次 degraded 窗 | rolling restart |
| Ceph | `osd_mclock_profile` | 維持 balanced；留作飽和時工具 | E-39 | headroom 下 0 | runtime |
| Ceph | `osd_scrub_sleep` | 維持預設 | E-37 | headroom 下 0 | runtime |
| Ceph | pool `size`/`min_size` | **3 / 2 不動**；failure domain=host | E-31/E-36 | min_size 是續命線 | 建置期 |
| Ceph | `nearfull_ratio` | 0.85 維持，但**告警升級為立即行動** | E-38 | 跨 full=全 VM 寫入凍結 | runtime |
| 維運 | `noout` | 維護前必設；flapping 立即設 | E-30/E-34 | p999 −71%（flapping 場景） | runtime |
| k8s | NodeHealthCheck | **必裝** | E-41 | 沒裝：node 硬斷後 VM 卡假 Running 11min+ | 部署層 |
| 監控 | client p99 / per-OSD latency / RTT | **必加**（ceph health 之外；起手式閾值見 E-32 建議欄，規則在 repo `experiments/ceph-alert-rules/`） | E-32/E-15 | 兩大災難 ceph health 與 p50 全看不見 | — |

## 7. 完整總結

**效能面**：這條 stack 的預設值（cache=none、io=native、virtio-blk、scheduler=none、shards=8…）在 kubevirt v1.5.0 / kernel 6.8 / ceph 19.2 的組合上**幾乎全是最佳解**。30 個實驗只找到兩個值得動手的地方：**CPU limit ≥ vCPU 數**（違反時 p99 ×7.4，全研究唯一數量級旋鈕）與**高並行 workload 的 queue_depth=256**（+10~21% 純加分，但要在建置期決定）。網路教學裡的「writeback 加速」「換 virtio-scsi 有 timeout」「native 必勝」「調 readahead」在這個版本組合上全數不成立或有毒。

**可調性面**：參數分四級——runtime（Ceph 多數 QoS 參數、guest sysfs）／VM 停機（VMI 全部欄位；migration 不是後門）／rolling restart（Ceph startup 參數；改動本身=degraded 窗）／**建置期定死**（krbd map options；連 patch PV 的後門都被 API 擋掉）。結論：**queue_depth 與 timeout 策略是 StorageClass 設計期的架構決策**，上線後改=搬資料。

**穩定性面**：乾淨的故障（掉 OSD、掉整台 host〔及時救回時〕、丟包、scrub）在 size=3/min_size=2 + NVMe headroom 下**全部近乎無感**——不用怕。真正要防的是四件事：**(1) gray failure**（一台慢 host 毒化全叢集寫入 ×40 且零告警——監控必須看 client p99/per-OSD latency/RTT）；**(2) 傷害集中在 out 之後的 backfill/recovery 債**（管理 out 時機：維護先 noout、flapping 立即 noout）；**(3) 容量與 min_size 是僅有的兩條「卡死線」**（跨過去 IO 無限凍結而非報錯，且 client 側沒有可靠的 timeout 保險——nearfull 告警當立即行動級）；**(4) KubeVirt 預設不會救 node 級災難**（NodeHealthCheck 必裝；writeback 在 node 硬斷時丟最近 ~6 秒已確認寫入）。

一句話版本：**參數照預設、CPU limit 別設錯、SC 設計期想清楚、監控補三個盲區指標、裝 NodeHealthCheck、nearfull 當火警——剩下的 Ceph 自己會撐住。**

**接下來做什麼（按優先序）**：
1. **監控補三個盲區指標**（client p99 / per-OSD latency / host RTT，閾值見 E-32）＋ nearfull 告警升級為立即行動級——E-32/E-38 兩個「無聲災難」的唯一防線，先做。
2. **VM 模板審查規則：CPU limit ≥ vCPU 數**——一條規則消滅全研究最大的效能地雷（E-15）。
3. **部署並演練 NodeHealthCheck**（含「node 硬斷後 VMI 假 Running」的演練劇本）——E-41 的洞，不裝就沒有 VM 高可用。
4. **StorageClass 設計 checklist 落地**（queue_depth 策略、不依賴 osd_request_timeout；含 E-51「建置期定死」的教育）——影響所有新 workload 上線。
5. **維運 runbook 更新**：維護前 noout、flapping 立即 noout、複合故障先 mon 後 OSD、Ceph startup 參數變更需排維護窗。
6. （backlog）追查 H-034、驗證長斷 host（E-31 caveat）與多 VM 齊發下的 queue_depth=256。

## 8. 侷限與事故記錄

- **數值級結論不可直接搬運**：本環境 OSD 是單 NVMe 切 3（同碟效應放大倍率，如 E-30 的 ×24）、nested 虛擬化。可搬的是機制、相對排序、以及完整的重測 harness（`RUNBOOK.md` 照抄可跑、`tools/fio_stats.py` 機器判 verdict）。
- **headroom regime**：「Ceph QoS 參數不可分辨」只在媒體有餘裕時成立；HDD 或飽和叢集要重測。
- **開放問題**（編號為研究內部 hypothesis 編號，詳見 `HYPOTHESES.md`）：H-034 = `osd_request_timeout` 在 PG 不可用時為何不觸發（源碼讀起來必觸發、真機就是不觸發，見 E-36）；H-033 = 「recovery 債」機制的直接驗證變體（E-39 一節的機制推論，尚缺閉環實驗）。
- **事故（誠實記錄）**：E-35 執行中 guest 寫入卡進 D-state → 腳本的 timeout 殺不掉（SIGKILL 對不可中斷睡眠無效）→ SSH 永久 hang → 收尾與回報機制全部失效 → **實驗叢集在故障態滯留約 8 小時**才被人工發現（恢復無損）。教訓已入 RUNBOOK 鐵則：破壞性 + 可能 IO-hang 的操作，**恢復機制必須活在獨立的行程樹裡**（外部 watchdog、硬期限無條件恢復）——這條同樣適用於任何自動化維運腳本。
