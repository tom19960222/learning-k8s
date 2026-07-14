# kubevirt-rbd-tuning Evidence Summary — 2026-07-13（世代 2：clean 6-OSD 重跑）

> **為什麼有這份**：世代 1（2026-07-08）跑在 Azure **L8s_v3 fallback＝1 顆 NVMe 用 LVM 切 3 OSD、3 daemon 共媒體**。
> 使用者把環境 redeploy 成 **L16s_v3、每台 2 顆實體 NVMe 各 1 OSD＝6 OSD（每 OSD 獨占媒體）**，要求把當初被「共媒體」污染的
> 四個實驗重跑：**E-02（host ceiling）、E-19（krbd queue_depth）、E-22（osd_op_num_shards）、E-30（單 OSD down→backfill）**。
>
> Bundle 在 `results/`（git-ignored）；本檔為索引。連線變數 `tools/env-gen2.sh`。
> 世代 1 索引見 `EVIDENCE-SUMMARY-2026-07-08.md`；跨世代**絕對數字不可直接比**，比的是「結論是否成立 / 倍率是否縮小」。

## 環境（世代 2）

| 項 | 值 |
|---|---|
| 叢集 | cyshih-kubevirt-ceph-lab @ japanwest（redeploy）、FSID `fbae2fb0-7eb8-11f1-b6cd-3daca6682563` |
| 拓樸 | 3 mon + **3 OSD host × 2 顆實體 NVMe 各 1 OSD = 6 OSD**；每 OSD 獨占 1 顆 1.74 TiB NVMe（**共媒體污染消除**） |
| pool | `kubevirt` size3/min_size2/pg64（與世代 1 同，可比結論） |
| 版本 | ceph 19.2.4、KubeVirt v1.5.0、k8s v1.32.13、kernel 6.8-azure、ceph-csi（SC `ceph-rbd`，**plain ceph-csi 非 Rook**） |
| baseline VM | ns vmtest、PVC data-baseline RWX Block 16Gi、4 vCPU / 8Gi、data 盤 `/dev/vdb` |

## E-00 環境盤點 — done

`results/E-00/<ts>/snapshot.txt`。6 OSD HEALTH_OK；`osd_memory_target` 已是預設 4G（**無 autotune 汙染**，世代 1 曾被抬到 15.7G 要釘）。

- **⚠ 新環境 caveat（值得寫進頁面）**：cephadm 在 OSD 建立時跑的 mclock 校準
  `osd_mclock_max_capacity_iops_ssd` 在**同型 NVMe 上嚴重不均**——osd.0/1/3/5 ≈ 6.5k，但 **osd.2 = 31.9k、osd.4 = 68.2k**（同硬體 5–10× 差）。
  這是 cold-cache bench fluke。**E-02 aggregate 讀 qd32 實測 37.1k ≈ 6×6.5k=39k → 證實 ~6.5k 才是真 per-OSD 天花板**，
  兩顆 outlier 是 over-measured。以 realistic default 保留、記為環境觀察（生產者可能永遠沒注意到，但它會讓 mclock QoS 配額在 OSD 間不對稱）。

## E-02 host ceiling — done（寫側天花板不再是災難）

`results/E-02/<ts>/`。worker k8s-1 直接 `rbd map`（繞過 VM），3 輪平均，CoV 0.2–2.2%。

| pattern | IOPS | p99(us) | MB/s |
|---|---|---|---|
| rr-qd1 | 1,054 | 1,346 | 4.1 |
| rr-qd8 | 10,057 | 1,144 | 39.3 |
| rr-qd32 | **37,107** | 1,423 | 144.9 |
| rw-qd1 | 636 | 2,310 | 2.5 |
| rw-qd8 | 6,502 | 2,225 | 25.4 |
| rw-qd32 | **20,892** | 2,736 | 81.6 |
| sr-1m | — | 13,129 | **3,111** |
| sw-1m | — | 42,555 | **1,168** |

- **關鍵**：讀 qd32 = 37.1k ≈ aggregate mclock 天花板（6×6.5k）。
- **與世代 1 對照（重要）**：world-1 host rr-qd32 = 36,602（= 聚合天花板 9×6000=54k 的 **68%**；guest 26,771 = **50%**，單 VM qd32 打不滿聚合）→ world-2 host = 37,107（= 聚合 6×6,500≈39k 的 **95%，近乎打滿**；guest 28,859 = 74%）。
  交付數字 **+1.4% 幾乎沒變、但成因不同**：world-1 是 client 並行度用不完（68%）、world-2 是被真天花板卡住（95%）。**E-02 是四實驗裡受拓樸影響最小者**——穩態單 client 讀不製造「多來源搶同碟」的爭用，共媒體懲罰無從現形（要 backfill/多 VM 齊發才咬人）。
  （先前拿「17.7 MB/s→1,168 MB/s」佐證有誤：17.7 來自更早 PVE 消費級 SSD 研究、非本系列世代 1，撤回。）
- 虛擬化稅（host vs guest baseline E-01）：集中 rr-qd32（host +28.6% / guest −22.2%）、sr-1m −16.9%；寫/低 QD −5～+3%（機制與世代 1 一致）。

## E-01 noise band — done

`results/E-01/<ts>/`，guest baseline ×5 輪，產 `band.json`（世代 2，已裝到本目錄；世代 1 存為 `band-2026-07-08-gen1.json`）。
CoV 極低（iops 0.1–0.7%、p99 0.5–1.5%）——clean 環境噪音比世代 1 小。guest baseline 均值：
rr-qd1=985、rr-qd8=9,218、rr-qd32=28,859、rw-qd1=605、rw-qd8=5,945、rw-qd32=19,070 IOPS；sr-1m=2,584、sw-1m=1,206 MB/s。

## E-19 krbd queue_depth — done（confirmed，效果比世代 1 更明顯）

`results/E-19/<ts>/`。qd64 vs qd256（baseline qd128=E-01）。

| pattern | qd64 | qd256 | 256 vs 64 |
|---|---|---|---|
| rr-qd1 | 974 | 963 | −1.1%（帶內） |
| rw-qd1 | 596 | 603 | +1.2%（帶內） |
| rr-qd32x4 | 49,799 | 54,304 | **+9.0%**（p99 4708→3992 改善） |
| rw-qd32x4 | 28,759 | 36,817 | **+28.0%**（p99 8454→5953 改善） |

- **高並行 queue_depth=256 純加分（讀 +9.0%、寫 +28.0%，p99 同步改善）；qd1 零代價。**
- **與世代 1 對照**：讀 rr-qd32×4 世代 1 +10.3% → 世代 2 +9.0%（**幾乎相同**）；寫 rw-qd32×4 世代 1 19,798→23,914（+20.8%）→ 世代 2 28,759→36,817（**+28.0%**，絕對 IOPS 也墊高）。
  → **「共媒體壓低 queue_depth 效果」只成立在寫側**（高並行寫要填滿獨立媒體佇列）；讀側新舊無差。
- caveat：生效驗證（host config_info）因 NSG 擋 worker internal IP 未能跑，改以行為級 A/B 差異證明生效；
  qd256 寫 36.8k 部分受 osd.2/4 mclock outlier 額外配額，絕對倍率含環境噪音。

## E-22 osd_op_num_shards_ssd — done（confirmed，「8 已足」非共媒體假象）

`results/E-22/<ts>/`。shards8 vs shards16（生效驗證 config show=16）。

- **shards 效果全帶內**：rr-qd1 −3.1%、rr-qd32x4 −2.1%、rw-qd32x4 −1.8%——**即使 clean per-OSD 隔離乾淨，shards=16 對 8 仍無增益**。
  世代 1 曾疑「共媒體蓋掉 shard 效果」；本世代證實「8 已足」是真結論。
- **rolling restart 6 OSD 的 client 代價**（degraded randread qd1，1s 平均）：to16 峰值 **1,889ms**、to8 峰值 **1,206ms**——
  與世代 1 的 ~1,360ms 同量級。**改這類參數 = 一次 degraded 事件**（要當維運事件排程）。

## E-30 單 OSD 乾淨 down → backfill — done（**頭牌污染塌陷：×24 是共媒體假象**）

`results/E-30/<ts>/`。stop osd.3、down 751s（跨 600s auto-out）、degraded 負載收 client p99。
健康時序證實 auto-out 觸發：t+611s OSD_DOWN 消失→PG_DEGRADED（remap/backfill）。

| 相 | client 讀 median | mean | max |
|---|---|---|---|
| pre baseline | 0.92 ms | 0.92 | 1.0 ms |
| down 0–600s | **0.90 ms** | 0.99 | 54 ms |
| auto-out/backfill 600–751s | **0.90 ms** | 13 | **1007 ms** |
| post-recover | 0.93 ms | 1.58 | 75 ms |

- **世代 1（共媒體）**：backfill 階段 rr-qd1 **mean 22.73ms（×24 vs 0.96ms）、max 1,011ms，「整秒窗」持續性劣化**。
- **世代 2（clean 獨占）**：backfill 階段 rr-qd1 **mean 13.04ms（×14 vs 0.92ms）、max 1,007ms，但 median 仍 0.90ms（×1.0）**。
  → **精確講：不是歸零，是「持續變零星」**——均值懲罰約砍半（×24→×14）、最大尖峰兩代都 ~1s，但 median 不動代表典型請求正常、只有約 4/149 秒被單發尖峰拉高。這是拓樸影響最大的一條。
- 成立條件：本環境每 OSD 實資料 ~8G、backfill 窗僅約 150s；生產 TB 級/OSD backfill 歷時更久 → 尖峰**次數**更多，
  唯「dedicated media → recovery 不與 client 搶同碟 → median 不受持續污染」的機制可移植。

## 一句話總結（世代 2）
clean 每 OSD 獨占 NVMe 重跑四個「共媒體污染」實驗，**拓樸影響分三級**：
(1) **大＝E-30 backfill**（rr-qd1 mean ×24→×14、median ×1.0，持續→零星）；
(2) **中＝E-19 寫側**（+20.8%→+28.0%、絕對 24k→37k）；
(3) **幾乎無＝E-19 讀側/E-22/E-02**（讀 +10.3%→+9.0%、shards 兩代帶內、讀天花板 36.6k→37.1k）。
核心教訓：**共媒體只在「有人跟 client 搶同碟」（backfill/recovery、高並行寫）時放大倍率；穩態單 VM 天花板與不缺並行的參數換不換媒體都差不多。機制級排序（queue_depth 有用、shards 8 已足、writeback 危險…）不變。**
