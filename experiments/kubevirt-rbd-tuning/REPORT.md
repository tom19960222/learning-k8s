# KubeVirt VM on Ceph RBD — 生產調教與故障行為研究總結報告

> 研究代號 kubevirt-rbd-tuning（charter v3）｜2026-07-07 啟動、2026-07-10 收官
> 30 個真機實驗（29 個 bundle，E-40/E-41 合併執行）、34 條 hypothesis 全數 triage｜逐實驗證據：`EVIDENCE-SUMMARY-2026-07-08.md`｜假說與 verdict：`HYPOTHESES.md`
> 版本錨點：kubevirt v1.5.0 / ceph-csi v3.14.0 / linux 6.8 / libvirt v10.10.0 / qemu v9.1.0 / ceph v19.2.3（實機 19.2.4）

---

## TL;DR（給只看一頁的人）

**問題**：生產關鍵系統的 KubeVirt VM，disk 走 ceph-csi + krbd 到 Ceph RBD。要調 IO 效能、要撐住故障，該動哪些參數？線上改得動嗎？故障時 VM 會怎樣？

**答案分三句：**

1. **調教的答案短得驚人：預設值幾乎全對。** 30 個實驗裡，唯一量到「數量級」差異的旋鈕不在 storage stack，而是 k8s 資源設定——virt-launcher 的 **CPU limit 低於 vCPU 數會讓 IO p99 惡化 7.4 倍、IOPS 砍半，且 p50 不變**（只看平均永遠發現不了）。其餘 QEMU/Ceph 端旋鈕不是不可分辨、就是預設已是最佳。
2. **想調也未必改得動：一半的旋鈕有「線上可調性」硬牆。** VMI 層旋鈕 live migration 套用不了、只能停機重啟；krbd 層 map options（如 queue_depth）在 PV 建立時凍結，實測連 patch PV 的後門都被 k8s API 拒絕——**要在 StorageClass 設計期就決定，事後只能重建 PVC 搬資料**。
3. **穩定性的真正威脅是三個盲區，不是缺調教**：(a) **gray failure**——一台 OSD host 網路 +50ms，全叢集寫入慢 40 倍，但 `ceph health` 全程 OK 零告警；(b) **KubeVirt 預設沒有可靠的 node 失效 failover**——node 硬斷後 VM 卡「假 Running」11 分鐘以上；(c) **複合故障**——mon quorum 全失時 IO 照跑（假象），此時再死一顆 OSD 就是無限期 hang，且恢復順序有硬約束（先 mon 後 OSD）。

**生產最重要的三個行動**：CPU limit ≥ vCPU 數寫進 VM 模板審查；監控加 client p99 + per-OSD latency + host RTT（別只信 ceph health）；部署 NodeHealthCheck 之類的 node-loss 自動化。

---

## 1. 緣起：為什麼做這個研究

團隊的 VM workload 跑在 KubeVirt 上，disk 由 ceph-csi 以 krbd 掛載 Ceph RBD。網路上調教文章很多，但對「生產關鍵系統」它們都答不了三個問題：

1. **這個旋鈕線上改得動嗎？** 改一個參數是 `kubectl patch` 就好，還是要停機、要 rolling restart 整個 Ceph、還是根本改不動？
2. **改了值不值得？** 多數文章只給均值或 throughput；latency-first 的系統要看 p99/p99.9，而尾延遲常常和均值反向。
3. **degraded 的時候會怎樣？** OSD 掛掉、網路半死、pool 快滿、node 斷電——VM 的 IO 是變慢、還是卡死？卡多久？有沒有告警？

前一輪研究（v2，PVE 生產叢集）只能動 VM 端參數；本輪（v3）建了專屬 Azure 實驗叢集，**全 stack 可調、可任意破壞**，把三個問題一次量完。判準先講清楚：**穩定優先、latency 優先**——degraded 時允許 throughput 下降，但 p99/p99.9 要可控、不雪崩、不卡死。

## 2. 方法：怎麼保證結論可信

- **Hypothesis backlog + prediction 先行**：34 條假說，每條實驗前先寫死預測，跑完只准比對、不准改寫。預測被推翻（violated）照實記——本研究最有價值的結論裡一半是 violated。
- **三態 verdict、機器判定**：confirmed / violated / indistinguishable，由腳本比對差異是否超過實測噪音帶，不靠肉眼。
- **噪音帶先量**（E-01）：同設定重複 5 輪，IOPS CoV 0.4–2.0%，判準取 `max(2×CoV, 5%)`。附帶推翻一條假說：Azure 專屬叢集比 PVE 生產環境穩一個數量級（後者 CoV 23%）。
- **n≥3、A/B 交錯、生效驗證前置**：每個變體開跑前先從 QEMU cmdline / host sysfs / ceph config 斷言參數真的生效，杜絕「調了個寂寞」。
- **觀測三邊界互洽**（E-03）：guest iostat vs host rbd iostat 差 0.03%——數字可信，且三層差分能把延遲歸因到 virtio/QEMU 段或網路/Ceph 段。

**環境**：Azure 專屬叢集——3 mon + 3 OSD host（每台 1 顆 NVMe 切 3 OSD，共 9 OSD；size=3/min_size=2）+ k8s（2 worker，nested KVM）+ KubeVirt v1.5.0。與生產拓樸同型（external ceph）、可整台斷電。

**結論的移植性**每條都標了級別：**機制級**（可移植：機制、相對排序、方法）vs **數值級**（僅限本環境：絕對數字、倍率）。

## 3. 發現一：線上可調性——一半的旋鈕改不動

全 stack 旋鈕按「怎麼改」分四類（源碼查證 + 真機閉環）：

| 類別 | 改法 | 例子 | 真機驗證 |
|---|---|---|---|
| **A** | runtime 即改即生效 | `osd_mclock_profile`、`osd_memory_target`、scrub 節流 | E-21：`ceph config set` 後 OSD RSS 實際改變 |
| **B** | 要 VM stop/start（停機） | cache / io / blockMultiQueue / dedicatedIOThread / CPU limit | E-50：patch 後只標 `RestartRequired`，live migration ×2 不套用 |
| **C** | 要 OSD rolling restart | `osd_op_num_shards` | E-22：rolling 9 OSD 期間 client 讀 p99 → 1360ms |
| **D** | **建置期定死**（重建 PVC 才能改） | krbd map options：queue_depth / alloc_size / `osd_request_timeout` | E-51：patch PV 被 API 拒（`persistentvolumesource is immutable`）——**無 escape hatch** |

三個直覺被推翻（全部源碼級證據，詳見專題頁）：

1. **「換 virtio-scsi 就有 30s timeout，卡死變 IO error」——錯**。kernel 6.8 的 `virtscsi_eh_timed_out` 無條件重設計時器，**兩種 bus 都永不逾時**。
2. **「cache=writeback 會擋 live migration」——錯**。QEMU ≥4.0 有 drop-cache capability，libvirt 放行。writeback 的真代價在別處（見發現三）。
3. **「唯一的有界等待旋鈕 `osd_request_timeout` 能防卡死」——錯**。E-36 真機：min_size 不滿情境下 timeout=30 **完全不觸發**（blocked 302.8s、無 -ETIMEDOUT）——在它最該出場的情境它沒有出場（機制矛盾仍開放，H-034）。

**含義**：「要不要有界等待、queue_depth 設多少」是**建置期架構決策**，不是出事後能補救的；D 類參數要進 StorageClass 設計 checklist。

## 4. 發現二：正常態調教——預設值幾乎全對，例外在 k8s 層

15 個正常態 A/B 實驗的重點（完整表見附錄 A）：

**唯一的數量級旋鈕（E-15，機制級可移植）**：

| virt-launcher CPU limit | IOPS | p50 | p99 |
|---|---|---|---|
| limit=4（=vCPU 數） | 7042 | 938us | 7.6ms |
| **limit=2（<vCPU 數）** | **3352（砍半）** | 946us | **55.8ms（×7.4）** |

兩個變體**都是 Guaranteed QoS**——「用 Guaranteed 就安全」是錯的，真正門檻是 **limit ≥ vCPU 數**（否則 CFS quota throttling 週期性凍結 IO completion 執行緒）。p50 不變＝均值監控完全看不到，是最容易誤設又最難察覺的一條。

**其餘值得記的**：

- **cache=none（預設）維持**（E-10）：writeback 寫側均值 +272~1997% 好看，但 p999 +2064%、出現 1.5~3.5s 整段 stall；writethrough 寫側嚴格劣化。
- **guest IO scheduler 維持 none**（E-17）：被改成 mq-deadline 的話 seq read 差 39.7%——RBD 已自帶排序，guest 再排一層是純開銷。這是「檢查清單項」：發現誰改了要改回來。
- **krbd queue_depth=256 純加分但 D 類**（E-19）：高並行 +10~21% IOPS 且 p99 同時改善、qd1 零代價（預測的排隊懲罰不存在——queue_depth 是 cap，低並行碰不到）。要用得在 SC 建立時設。
- **io=native vs threads、virtio-blk vs scsi、blockMultiQueue、dedicatedIOThread（單盤）、readahead**：全部 indistinguishable 或預設已優——「native 必勝」「多 queue 要手開」等說法在新版 stack 不成立。
- **Ceph 端旋鈕在 headroom 充足時全部不可分辨**（E-21 memory_target / E-22 shards / E-37 scrub_sleep / E-39 mClock profile）：NVMe + 有餘裕的叢集沒有爭用可仲裁，QoS 微調沒有用武之地。**該投資的是容量 headroom，不是參數**。反而改 startup 參數（C 類）要付一段 rolling restart degraded 窗——E-22 實錄 shards 8→16 零收益、代價是 client 讀 p99 秒級惡化。

## 5. 發現三：degraded 行為——失效本身無感，傷害在別處

9 個故障注入實驗拼出的全景（數值級倍率、機制級結論）：

### 5.1 傷害排序：backfill 債 > flapping > gray >>> 失效本身

| 情境 | client 衝擊 | ceph 告警 |
|---|---|---|
| 單 OSD down、未 out（E-30） | **≈0**（peering 瞬間 3.8ms 尖峰） | OSD_DOWN |
| 整台 host 3 OSD down（E-31） | **≈0**（一次 38ms 尖峰；min_size=2 撐住） | WARN |
| auto-out 後 backfill（E-30） | **隨機讀 ×24**、整秒級尖峰 | PG_DEGRADED |
| OSD flapping（E-34） | rr mean ×12、p999 1146ms；**noout 後 p999 −71%** | OSD_DOWN |
| **一台 host +50ms gray（E-32）** | **寫 ×40、讀 ×19** | **全程 HEALTH_OK，零告警** |
| 封包遺失 0.1–0.5%（E-33） | ≈0（最壞 1.1×；TCP 快速重傳吸收） | 無 |
| deep-scrub（E-37） | 0（headroom 吸收） | 無 |

三個機制級結論：

1. **「失效顆數」不是重點，min_size 才是**：掉一顆 OSD 和掉整台 host（3 OSD）衝擊幾乎相同——只要每個 PG 還剩 min_size 份副本，IO 續存。
2. **傷害在「out 之後」**：E-30 vs E-39 對照顯示，痛的不是 backfill 資料搬移本身，而是 down-未-out 期間累積的**熱物件 recovery 債**（該期間被寫過的物件，恢復時會擋 client op）。維運上「控制 out 時機」（短維護先 `noout`、故障要嘛 10 分鐘內救回要嘛接受 backfill 窗）比調任何 QoS 都有效。
3. **gray failure 是觀測盲區（本研究最重要的單一發現）**：size=3 + CRUSH per-host 放置 → 每筆寫入要等三台 host 各一份副本 ack → **任何一台 host 變慢 = 全叢集寫入變慢**，而 OSD 沒死、heartbeat 沒超時，`ceph health` 完全不露餡。監控必須有 client 端 p99、`ceph osd perf` 的 per-OSD latency、host 間 RTT。另外 E-32/E-33 對照給了網路診斷的優先序：**Ceph-on-TCP 對延遲遠比對丟包敏感**（+50ms → ×40；0.5% loss → 1.1×），先看 RTT。

### 5.2 卡死的邊界：guest IO 只會「無限等」，不會「失敗」

- min_size 不滿 → 寫入無限期 blocked（E-36：302.8s 直到 OSD 回歸，恢復後 op 直接成功）。
- pool 觸及 full_ratio → 同型 hang（E-38：卡 96s，**非 ENOSPC 非 EIO**）；nearfull 只告警不擋寫——**nearfull 是唯一能行動的視窗，必須當「立即行動」告警線**。
- client 側沒有可靠的「轉成有界失敗」旋鈕（發現一的三個 violated）。防線只能建在：不讓 PG inactive（size/min_size 設計、容量規劃、快速換件）+ application 層 timeout。

### 5.3 複合故障：mon quorum 的假象與恢復順序（E-35）

- 2/3 mon down（quorum 失）：**穩態 IO 照跑**——client 拿既有 osdmap 直連 OSD，不需要 mon。看起來沒事，其實「變更平面」已死。
- quorum 失 + 再死一顆 OSD：對受影響 PG 的寫入**無限期 hang、卡進不可中斷 D-state**（SIGKILL 都殺不掉）——沒有 mon 發新 osdmap，client 永遠不知道 OSD 死了，也沒有 recovery 能繞開。
- **恢復順序是硬約束：先救 mon quorum、再救 OSD**，反過來無效。且 quorum 失時 `ceph -s` 自己也連不上——觀測面一起死，mon 監控要走 mgr 之外的路（blackbox 探測）。

## 6. 發現四：KubeVirt 的 node 失效與資料一致性

**E-41——KubeVirt 預設沒有可靠的 node 失效 failover（重大）**：k8s node 硬斷電後，VMI 卡在死 node 上「假 Running」**11 分鐘以上**，完全沒重排；手動 force-delete 還被 stuck finalizer 擋（死 node 無法確認 pod 終止）。另一輪未人工介入，靠 pod eviction（~300s NoExecute toleration）觸發了重排——所以自動 failover「可能發生，但慢且不可靠」。**生產要 VM 高可用，NodeHealthCheck / machine-health-check 是必需品，不是加分項。**

**E-40——cache=writeback 在 node 硬斷時丟資料**：guest 已收到寫入完成回報的資料，host 硬斷後回讀——**最後 ~6 秒的 acked 寫入遺失**（host page cache 未 flush）；cache=none 對照組 **0 遺失**。關鍵區分：光 kill QEMU/pod 不丟（page cache 在 host 存活），**只有 host 層硬失效才丟**——代價只在 node 級災難兌現，但兌現時丟的是「最近幾秒」，最難察覺、guest 檔案系統可能靜默損壞。這把 cache mode 從效能選擇升級成 correctness 決策。

**E-42——live migration 本身很便宜**：高 IO 負載中遷移，IO 零中斷、最差 1 秒窗 8ms。節點維運（kernel 升級、汰換）可放心用 migration——只是別指望用它套用 disk 參數（B 類的牆）。

## 7. 生產行動清單

**建置期（之後改不動或很貴）：**
- [ ] StorageClass 設計時定案 krbd map options——需要高並行的 workload 設 `queue_depth=256`（純加分）；`osd_request_timeout` 不設（實測不可靠，見 E-36）
- [ ] VM 模板：cache 留空（=none）、io 留空（=native）、不開 blockMultiQueue/dedicatedIOThread（單盤無感）、bus 用 virtio-blk
- [ ] **CPU limit ≥ vCPU 數**寫進 VM 模板審查規則（或 dedicatedCpuPlacement）
- [ ] pool size=3 / min_size=2；容量規劃把 nearfull(0.85) 當硬線

**監控（ceph health 看不到的）：**
- [ ] client 端 IO p99/p99.9（p50 與均值會騙人：E-15、E-32 的災難 p50 都近乎不動）
- [ ] `ceph osd perf` per-OSD commit/apply latency + OSD host 間 RTT（gray failure 唯一的訊號）
- [ ] degraded objects 數量（backfill 債的領先指標）
- [ ] nearfull 告警 = 立即行動級；mon quorum 用 blackbox 探測（quorum 失時 mgr 指標一起死）

**維運應變：**
- [ ] 短暫維護 OSD/host：先 `ceph osd set noout`
- [ ] 發現 OSD flapping：立即 noout 止血（實測 p999 −71%），再查根因
- [ ] 複合故障恢復順序：**先 mon quorum、後 OSD**
- [ ] 改 Ceph startup 參數（C 類）排維護窗——rolling restart 本身就是一段 degraded
- [ ] 部署 NodeHealthCheck / machine-health-check，並演練 node 硬斷（E-41 的 phantom Running 要在演練中見過才不會 3am 慌）

## 8. 侷限與研究品質

- **數值是環境綁定的**：本環境 OSD 是 1 顆 NVMe 切 3（同碟鄰居效應會放大倍率，如 E-30 的 ×24）；nested 虛擬化。可移植的是機制、相對排序與重測 harness，不是絕對數字。
- **headroom regime**：Ceph 端 QoS 旋鈕的 indistinguishable 結論只在「媒體有餘裕」時成立；HDD 或打滿的叢集要重測（harness 可直接重跑）。
- **誠實記錄的反面教材**：E-35 執行時因 guest 寫入卡 D-state、腳本 timeout/trap 全數失效，叢集在故障態滯留 ~8 小時才被人工發現（恢復無損）。教訓已成鐵律寫進 RUNBOOK：**破壞性 + 可能 IO-hang 的實驗必須配獨立的外部 watchdog（硬期限無條件恢復）**——in-script timeout 對 D-state 免疫、trap 在 hang 時不觸發。
- **開放問題**：H-034（`osd_request_timeout` 在 PG inactive 下為何不觸發——與源碼閱讀矛盾）、H-033 閉環變體（recovery 債的直接驗證）。

## 附錄 A：30 個實驗總覽

| 實驗 | 主題 | verdict | 一句話 |
|---|---|---|---|
| E-00 | 環境盤點 | done | 版本對齊；抓到 autotune 把 osd_memory_target 抬到 15.7G（已釘回 4G） |
| E-01 | 噪音帶 | **violated** | Azure 專屬叢集 CoV 0.4–2.0%，比 PVE 生產穩一個數量級 |
| E-02 | host 天花板 | done | 虛擬化稅集中在高並行隨機讀（qd32 +36.7%）；寫與 seq 免費 |
| E-03 | 三邊界觀測 | confirmed | guest/host 差 0.03%；延遲可分層歸因 |
| E-10 | cache mode | confirmed | wb 均值好看、p999 +2064% + 秒級 stall；wt 嚴格劣化；維持 none |
| E-11 | bus blk/scsi | indist. | IOPS 同；scsi 尾延遲較差且無 timeout 好處；維持 virtio-blk |
| E-12 | io native/threads | **violated** | threads 不輸 native（qd32 讀 +12.4%）；維持預設即可 |
| E-13 | blockMultiQueue | confirmed | 開了=沒開（QEMU AUTO 本就=vCPU 數） |
| E-14 | dedicatedIOThread | confirmed | 單盤無感；收不回虛擬化稅 |
| E-15 | **CPU limit** | **confirmed（強）** | limit<vCPU → p99 ×7.4、IOPS 砍半、p50 不變 |
| E-17 | guest scheduler | confirmed | none 優（seq +30~40%）；檢查清單項 |
| E-18 | readahead | indist. | O_DIRECT 下非旋鈕（機制必然） |
| E-19 | queue_depth | 部分 violated | 256 純加分、qd1 零代價；但 D 類定死 |
| E-21 | osd_memory_target | indist. | 聚合 cache 已蓋住 working set；收益要大 working set 才出現 |
| E-22 | op_num_shards | indist. | 8 已足；rolling restart 代價實錄（C 類） |
| E-30 | 單 OSD down | confirmed+細化 | down 未 out 無感；auto-out 後 backfill rr ×24 |
| E-31 | 整台 host 硬斷 | confirmed | 3/9 OSD 同死衝擊≈單 OSD；min_size 是關鍵 |
| E-32 | **gray failure** | **confirmed** | 一台 host +50ms → 寫 ×40，health 全程 OK（盲區） |
| E-33 | 封包遺失 | **violated** | 0.5% loss 幾乎無感；延遲比丟包致命 |
| E-34 | flapping | confirmed | noout 砍 p999 71%；止血不治本 |
| E-35 | mon quorum 複合 | confirmed | quorum 失穩態 IO 照跑；+OSD 死=D-state hang；先 mon 後 OSD |
| E-36 | osd_request_timeout | **violated** | min_size 情境不觸發；不能當救命索（H-034 開放） |
| E-37 | deep-scrub | indist. | headroom 吸收；QoS 微調無用武之地 |
| E-38 | pool full | confirmed | full=hang 非 ENOSPC；nearfull 是唯一行動窗 |
| E-39 | mClock profile | indist. | headroom 下無差；傷害來源=recovery 債（H-033） |
| E-40 | crash consistency | confirmed | wb 硬斷丟 ~6s acked 寫入；none 零丟失 |
| E-41 | **node 失效 failover** | **violated（更糟）** | 預設不 failover；phantom Running 11min+；需 NodeHealthCheck |
| E-42 | live migration 代價 | confirmed | IO 零中斷、最差 1s 窗 8ms；維運可放心 |
| E-50 | 可調性（VMI 層） | confirmed | patch 只標 RestartRequired；migration 不套用；revert 不清條件 |
| E-51 | 可調性（krbd 層） | confirmed | patch PV 被 API 拒；D 類無 escape hatch |

（E-16/E-20/E-23/E-43 經裁定不執行或列 P3；理由見 HYPOTHESES.md 對應條目）

## 附錄 B：hypothesis triage 統計

34 條全數定案：**confirmed 11、violated 8 + 部分 violated 2、indistinguishable 1、synthesized（方法論規則落地）7、not-run 4、open 1**（H-034）。violated 比例約三成——這正是研究的價值所在：網路常識在 pinned 版本上有三成不成立。

## 附錄 C：重測方法

harness 完整保存在 repo `experiments/kubevirt-rbd-tuning/`：`RUNBOOK.md`（照抄可跑的指令，含 E-35 事故換來的外部 watchdog 鐵律）、`EXPERIMENT-PLAN.md`（每實驗目的/變因/預期）、`tools/fio_stats.py`（噪音帶與 verdict 機器判定）、`band.json`（判準）。換環境重測：先跑 E-00/E-01 重建噪音帶，再挑要驗的實驗。
