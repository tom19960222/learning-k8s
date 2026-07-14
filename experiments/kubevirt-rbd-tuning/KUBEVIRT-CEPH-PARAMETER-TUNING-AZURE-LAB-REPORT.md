# KubeVirt VM 使用 Ceph RBD 的參數調教：兩次 Azure Lab 實驗與生產決策報告

> 實驗期間：2026-07-07 至 2026-07-13  
> 受測版本：KubeVirt v1.5.0、Ceph v19.2.4、Linux kernel 6.8、libvirt v10.10.0、QEMU v9.1.0；第一次 Lab 確認 ceph-csi v3.14.0，第二次 Lab 的 ceph-csi image 版本未留在可取得的證據中  
> 實驗規模：第一次 Azure Lab 執行 30 項實驗；第二次 Azure Lab 重新量測基準，並重跑 4 項最可能受儲存媒體拓樸影響的實驗  
> 閱讀方式：若只需要決策，先看「管理摘要」與「參數決策總表」；若要判斷結果能否套用到其他環境，再讀「兩次 Azure Lab」與「限制」

## 管理摘要

這項研究不是要找一組「所有 KubeVirt 與 Ceph 環境都適用」的神奇參數，而是回答三個可以落地的問題：哪些設定錯了會造成重大損失、哪些參數在特定 workload 下確實有收益、哪些流傳的調教方法在這個版本與資料路徑上沒有作用。

受測 VM 的資料盤由 ceph-csi 掛載為 host 上的 krbd block device，再交給 QEMU 與 guest 使用。研究涵蓋 KubeVirt、QEMU、guest kernel、krbd 與 Ceph OSD 五個層次。判斷原則在實驗前就固定為：**資料正確性優先，其次是 tail latency，最後才是平均 throughput**。

結論可收斂成六件事：

1. **CPU limit 不得低於 VM 的 vCPU 數。** 在 4 vCPU VM 同時承受 CPU 與 I/O 負載時，CPU limit 從 4 降為 2，4 KiB 隨機讀 IOPS 由 7,042 降為 3,352，p99 latency 由 7.6 ms 升為 55.8 ms（7.4 倍），但 p50 幾乎不變。只看平均值或 Guaranteed QoS 都會漏掉這個問題。
2. **KubeVirt disk 的 `cache` 欄位應維持留空，並驗證 QEMU 實際採用 direct／none。** `writeback` 雖使部分寫入 throughput 看似提高 272% 至 1,997%，卻讓 p99.9 由 3.3 ms 增至 71 ms（約 21.5 倍）、產生 1.5 至 3.5 秒停頓；node 硬斷時還會遺失約最後 6 秒已向 guest 回報成功的寫入。這是資料正確性決策，不是單純的效能調教。
3. **高並行新 workload 可以考慮 krbd `queue_depth=256`。** 直接實測的是 64 與 256，而不是預設 128 與 256。第二次 Azure Lab 中，256 相對 64 使高並行讀取增加 9%、寫入增加 28%，p99 同時改善；低並行 I/O 沒有可辨識差異。這個參數建立 PV 時即固化，既有 PVC 要改只能建新 StorageClass、新 PVC 並搬移資料。
4. **guest block scheduler 應維持 `none`。** 相對 `mq-deadline`，`none` 的循序讀取增加 39.7%、循序寫入增加 30.1%。Ubuntu 24.04 搭配 virtio-blk 的預設已是 `none`，因此這是映像檔與設定管理的 guardrail，而不是要求全面變更。
5. **Ceph OSD 故障的主要傷害不是 OSD 剛被標成 down，而是後續 backfill、flapping、gray failure 與容量／副本下限被突破。** 短暫 OSD down 幾乎無感；一台仍在線但增加 50 ms 網路延遲的 OSD host，卻使寫入 latency 變成 40 倍、讀取變成 19 倍，而且 `ceph health` 全程維持 `HEALTH_OK`。
6. **大多數進階參數不值得改。** `osd_op_num_shards_ssd` 8→16、`osd_memory_target` 4 GiB→8 GiB、`osd_mclock_profile` balanced→high_client_ops、`osd_scrub_sleep` 0→0.1，以及單盤 `dedicatedIOThread` 都沒有超出噪音帶的收益。部分參數的變更成本反而比收益高，例如 OSD rolling restart 造成約 1.2 至 1.9 秒的 client 讀取尖峰。

兩次 Azure Lab 的角色不同。第一次 Lab 在每台 OSD host 上用一顆 NVMe 切出三個 OSD，適合大量功能與故障實驗，但共用 NVMe 是可能放大同碟爭用的干擾因素。第二次 Lab 改為每個 OSD 獨占一顆 NVMe，用於降低並檢視這項干擾，只重跑最可能受影響的項目。參數決策的方向在第二次 Lab 仍成立；backfill 的觀察則由「持續變慢」修正為：**第二次 Lab 的典型請求維持正常，但仍有少量約 1 秒尖峰；每秒延遲均值的懲罰由 24 倍降為 14 倍，並未消失。**因為兩次 Lab 還有其他差異，不能把數字變化完全歸因於媒體配置。

## 系統脈絡與名詞

### 受測 I/O 路徑

受測資料盤的實際路徑如下：

1. KubeVirt 的 VM template 宣告一顆 PVC block disk。
2. ceph-csi 在 VM 所在的 k8s node 上以 krbd 將 RBD image map 成 `/dev/rbdN`。
3. virt-launcher 內的 QEMU 直接使用該 block device。
4. guest 看到 virtio block device，本研究中為 `/dev/vdb`。
5. krbd 透過網路把 I/O 送到 Ceph OSD；pool 使用三份副本。

因此，同一個 I/O 會穿過五個可調層次：KubeVirt VM template、QEMU、guest kernel、host krbd、Ceph cluster。報告不會把這些層次的 queue 混在一起：

- fio `iodepth`：測試程式同時送出的 I/O 數量。
- krbd `queue_depth`：單一 RBD device 允許的在途 request 上限。
- guest block queue：guest kernel 在 virtio block device 上的 queue 與 scheduler。
- `osd_op_num_shards_ssd`：OSD 內部處理 operation 的分片數量。

它們名稱相似，但位置、變更方式與效果都不同。

後文使用的縮寫與環境名詞如下：

- **VMI（VirtualMachineInstance）**：KubeVirt 實際運行中的 VM instance，與可編輯的 VM template 不同。
- **CFS（Completely Fair Scheduler）**：Linux CPU scheduler；CPU limit 會由它的 bandwidth quota 機制執行。
- **CoV（coefficient of variation，變異係數）**：標準差除以平均值，用來表示重複量測的相對噪音。
- **NSG（Network Security Group）**：Azure 的網路存取控制；第二次 Lab 因 NSG 阻擋 private IP，無法從執行端讀取 host 的 krbd runtime 設定。
- **`config_info`**：krbd 暴露的 runtime device configuration readback，可用來確認 map option 是否實際生效。
- **效能餘裕（headroom）**：在 client 負載之外，CPU、網路或儲存媒體仍可提供的剩餘能力。

### Ceph 故障生命週期

- **OSD**：實際儲存物件的 Ceph daemon。
- **PG（placement group）**：Ceph 將物件分組並映射到一組 OSD 的單位。
- **down**：monitor 判定 OSD 無法服務，但它還沒有被移出資料配置。
- **out**：OSD 持續 down 超過 `mon_osd_down_out_interval` 後被移出，Ceph 開始把資料補到其他 OSD。
- **peering**：PG 成員變動後重新確認狀態與權威資料的過程。
- **backfill**：把完整物件搬到新的 OSD，使副本數恢復。
- **recovery**：OSD 回來後補上失聯期間缺少的變更。
- **`noout`**：暫時阻止 down OSD 被自動標成 out 的 cluster flag；它是有期限的維運控制，不是常駐調教參數。

### latency 的讀法

- p50 是典型 request。
- p99 是最慢 1% request 的邊界。
- p99.9 是最慢 0.1% request 的邊界，只有樣本數足夠時才報告。
- 故障實驗另外保存 1 秒時間窗，因為 60 秒總結可能把短暫但完整的 I/O stall 平均掉。

本研究同時看 IOPS、bandwidth、p50、p99、p99.9 與最大 latency。CPU limit 實驗證明 p50 幾乎不變時，p99 仍可惡化 7.4 倍；因此「平均值正常」不能推導「VM I/O 正常」。

## 研究問題與判定準則

研究回答三類問題：

1. **效能**：參數調整後，latency 或 throughput 是否超出環境噪音帶？
2. **穩定性**：故障或資源壓力下，VM 是變慢、卡死、回報錯誤，還是遺失已確認寫入？
3. **可調性**：參數能 runtime 生效，還是需要 VM restart、OSD rolling restart 或重建 PVC？

參數排序不是把所有百分比直接混在一起，而是依下列定性準則排序：

- 是否避免資料遺失、I/O 無限阻塞或數量級 tail latency 惡化。
- 是否有可重現的正向效能收益。
- 適用範圍是所有 VM，還是只有高並行、direct I/O 或媒體飽和的 workload。
- 參數是否有直接生效證據，或只有行為級 A/B 證據。
- 變更需要 runtime、VM restart、OSD rolling restart，還是 PVC 重建。

## 兩次 Azure Lab 與可比性邊界

### 環境比較

| 項目 | 第一次 Azure Lab：共用 NVMe | 第二次 Azure Lab：每個 OSD 獨占 NVMe |
|---|---|---|
| 執行日期 | 2026-07-08 至 2026-07-10 | 2026-07-13 |
| OSD host | Azure Standard_L8s_v3：8 vCPU、64 GiB RAM；每台 1 顆約 1.7 TiB local NVMe | Azure Standard_L16s_v3：16 vCPU、128 GiB RAM；每台 2 顆約 1.74 TiB local NVMe |
| OSD 與媒體關係 | 每顆 NVMe 以 LVM 切成 3 個約 100 GiB LV，每個 LV 對應 1 個 OSD；共 9 OSD、約 900 GiB 可用於實驗的 raw OSD 空間 | 每顆 NVMe 對應 1 個 OSD；共 6 OSD，每個 OSD 獨占媒體 |
| K8s worker | 2 台 Azure Standard_D8s_v5；每台 8 vCPU、32 GiB RAM，支援 nested KVM | 相同規格 |
| K8s control plane／Ceph monitor | Control plane 為 Standard_D4s_v5（4 vCPU、16 GiB）；3 台 monitor 為 Standard_D2s_v5（2 vCPU、8 GiB） | 相同角色配置；第二次 Lab 重建後仍為 3 monitor、1 control plane、2 worker |
| pool | `size=3`、`min_size=2`、`pg_num=64` | 相同 |
| 受測 VM | 4 vCPU、8 GiB RAM、Ubuntu 24.04、16 GiB block PVC | 相同 |
| Host OS／kernel | Ubuntu 22.04、kernel 6.8.0-1059-azure | Kernel 6.8 Azure；重建摘要未保留完整 patch 與 host OS image id |
| k8s／KubeVirt | k8s v1.32.13、KubeVirt v1.5.0 | 相同主版本 |
| Ceph | v19.2.4 | v19.2.4 |
| CSI | Plain ceph-csi v3.14.0，非 Rook | Plain ceph-csi，StorageClass 名稱與環境連線設定重建；image 版本沒有留在目前可取得的摘要中 |
| 基準網路 | Control plane 到 3 台 OSD host 的 private-network RTT 均低於 1 ms | 沒有保留完整 RTT matrix；同為 Azure private network，不能假設數值與第一次完全相同 |
| `osd_memory_target` 基準 | cephadm autotune 曾給約 15.7 GiB；實驗前顯式設為 4 GiB | 建立後已是 4 GiB |
| 主要用途 | 完整參數、故障與可調性矩陣 | 降低並檢視共媒體干擾，重跑最可能受影響的項目 |

這不是嚴格的單變因 A/B。第二次 Lab 同時改變 OSD 數量、OSD 對媒體的映射、部分 CSI 連線細節與 mClock 自動校準結果。因此跨 Lab 只比較：

- 結論方向是否重現。
- 相對效果是否仍存在。
- 共媒體是否改變瓶頸成因。
- 哪些絕對倍率必須降級為環境限定。

不能把兩次 Lab 的絕對 IOPS 差異直接歸因於「每個 OSD 獨占 NVMe」。

### 第二次 Lab 重跑範圍

第二次 Lab 先重新量測環境與噪音帶，再重跑四項：

1. host 直接 map RBD 的 I/O 天花板。
2. krbd `queue_depth` 64 與 256。
3. `osd_op_num_shards_ssd` 8 與 16。
4. 單一 OSD down、600 秒後自動 out，接著發生 backfill 的完整時間線。

Cache mode、CPU limit、guest scheduler、node 硬斷資料一致性與 failover 沒有重跑，因為它們的作用點不在 OSD 與 NVMe 的映射。本報告會明確標示「未重跑」，不把第一次 Lab 的倍率包裝成跨世代重現。

## 實驗方法與證據品質

### 正常狀態負載

受測資料盤先完整 pre-fill，避免薄配置與第一次讀取造成偏差。正常狀態矩陣包含：

- 4 KiB 隨機讀與隨機寫，`iodepth` 為 1、8、32。
- 1 MiB 循序讀與循序寫，`iodepth=16`。
- 每個 pattern 暖機 15 秒、正式量測 60 秒。
- 使用 O_DIRECT，避免 guest page cache 把 storage 路徑遮住。
- 每個變體至少執行 3 輪，A/B 交錯，避免時間漂移偏向固定一側。

O_DIRECT 代表這份報告可以直接支援資料庫與 direct I/O workload，但不能用來推論 buffered file service 的 readahead 收益。

### 故障狀態負載

故障實驗持續執行 4 KiB 隨機寫（`iodepth=8`）與低並行隨機讀，並保存每秒 latency、故障注入與回復時間。單 OSD backfill 結果中的 mean、median 與 max，都是「每秒 latency 時間序列」的統計，不是直接對所有單筆 I/O 混算。

### 判定防線

1. 每個實驗在執行前先寫下 prediction，結果不符合就明確記錄為被推翻。
2. 基準設定重複 5 輪；有效差異門檻為 `max(2 × CoV, 5%)`。
3. 變體執行前先從 QEMU command line、guest sysfs、host 設定或 `ceph config show` 驗證參數生效。
4. guest 與 host 觀測到的 IOPS 差異只有 0.03%，證明主要量測路徑互相吻合。
5. 對於沒拿到直接生效證據的項目，結論會降低信心，而不是假設參數一定生效。

第二次 Lab 的 `queue_depth` 因 Azure NSG 阻擋 node private IP，沒有取得 host `config_info`（krbd runtime 設定 readback）；目前只有 64 與 256 產生一致且顯著不同結果的行為級 A/B 證據。這足以支持「值得建立專用 StorageClass 再驗證」，但不足以支持未經驗證的全域翻新。

容量耗盡實驗也必須精確解讀：實驗是暫時依序把 `nearfull_ratio`、`backfillfull_ratio`、`full_ratio` 設為 0.10、0.15、0.20，全部低於當時約 26% 的使用率，使 cluster 進入 nearfull／full 狀態；並沒有真的將數百 GiB 或 TiB 的空間寫滿。完成後依序恢復為 0.85、0.90、0.95，cluster 回到 `HEALTH_OK`。這個方法驗證的是狀態機與 client 行為，不是量測真實填滿所需時間。

## 參數決策總表：依生產價值由高至低

「回報」包含避免損失與正向增益，不只代表 throughput 增加。排序先看資料正確性與可避免的重大退化，再看效能收益，最後才是低收益的微調。

| 順序 | 參數或控制項 | 決策類型 | 實測比較 | 第一次 Lab 結果 | 第二次 Lab | 是否值得調整 | 建議 | 變更代價與證據信心 |
|---|---|---|---|---|---|---|---|---|
| 1 | virt-launcher CPU limit | 必要 guardrail | 4 vCPU VM：limit 4 vs 2，並加 CPU 壓力 | limit 2：IOPS 7,042→3,352；p99 7.6→55.8 ms（7.4 倍） | 未重跑；與 OSD 媒體拓樸無關 | **值得，優先最高** | template 檢查應保證 CPU limit 不低於 vCPU 數；本實驗不能證明更高 limit 或 CPU pinning 的額外收益 | 需 VM restart；client 效果證據強，但未取得 cgroup `throttled_usec` |
| 2 | KubeVirt disk `cache` | 正確性 guardrail | 欄位留空／writethrough／writeback；另做 node 硬斷 | writeback p99.9 3.3→71 ms、1.5～3.5 秒 stall；node 硬斷遺失約最後 6 秒已確認寫入；留空／none 無遺失 | 未重跑；作用點不在 OSD 媒體 | **值得維持正確設定** | configured value 留空；部署後驗證 QEMU effective state 為 direct／none | 需 VM restart；效能與資料一致性均有直接實驗 |
| 3 | krbd `queue_depth` | 條件式正向調教 | **直接比較 64 vs 256**；128 是預設但沒有同矩陣的 128→256 效果量 | 高並行讀 +10.3%、寫 +20.8%；低並行無差 | 高並行讀 +9%、寫 +28%；p99 改善；低並行無差 | **只對高並行新 workload 值得** | 保留一般 SC 的 128；另建 `queue_depth=256` SC 給明確高並行 workload | 建立 PV 時固化；既有 PVC 要搬資料；第二次 Lab 僅行為級生效證據 |
| 4 | guest block scheduler | 必要 guardrail | `mq-deadline` vs `none` | `none`：循序讀 +39.7%、寫 +30.1% | 未重跑 | **值得檢查** | virtio-blk device 維持 `none`；若映像檔或設定管理改成其他 scheduler，改回 | runtime；直接 sysfs 生效證據 |
| 5 | pool `size`／`min_size` | 可用性 guardrail | 固定 `size=3`、`min_size=2`，注入副本不足 | 低於 `min_size` 後 I/O 阻塞 302.8 秒直到 OSD 恢復 | 未重跑 | **不要為效能降低** | 維持 3／2，failure domain 為 host | pool 設計決策；變更可能觸發資料移動 |
| 6 | `noout` | 有期限的維運控制 | OSD flapping，有／無 `noout` | p99.9 1,146→335 ms（降低 71%）；仍有 peering 尖峰 | 未重跑 | **維護與 flapping 時值得** | 短期維護前設；flapping 時止血；故障排除或維護結束立即 unset | runtime；長期保留會延後資料重建並降低冗餘安全度 |
| 7 | `nearfull_ratio`／`backfillfull_ratio`／`full_ratio` | 容量 guardrail | 注入值 0.10／0.15／0.20；恢復值 0.85／0.90／0.95 | full 期間寫入卡 96 秒，非 ENOSPC／EIO；解除後原 request 成功 | 未重跑 | **維持原 ratio，調高告警優先度** | 維持 0.85／0.90／0.95；`CephOSDNearFull` 與 `CephCapacityForecast` 必須在 full 前促成行動 | runtime；狀態機證據強，非真實寫滿測試 |
| 8 | `osd_request_timeout` | 避免錯誤安全感 | 0 vs 30 秒，PG 因副本不足而不可用 | 設 30 秒仍阻塞 302.8 秒，沒有 timeout | 未重跑 | **不值得依賴** | 不把它當成防卡死保險；application 需自行設定 timeout／健康檢查 | PV 建立時固化；結果與原始碼推論仍有未解矛盾 |
| 9 | `osd_op_num_shards_ssd` | 維持預設 | 8 vs 16 | 效能不可分辨；rolling restart 讀 p99 到 1,360 ms | 效能仍不可分辨；restart 峰值 1,206～1,889 ms | **不值得調** | 維持 8 | 需 OSD rolling restart；兩次 Lab 方向一致，信心高 |
| 10 | KubeVirt disk `bus` | 維持預設 | YAML `virtio`（QEMU virtio-blk）vs `scsi`（virtio-scsi） | IOPS 差異不超過 4.4%；virtio-scsi max latency 多 20%～150% | 未重跑 | **不值得調** | 維持 `bus: virtio`；不要把 virtio-scsi 誤當成 30 秒 timeout 保護 | 需 VM restart；來源與實驗均不支持 timeout 說法 |
| 11 | `osd_memory_target` | 條件式、目前無收益 | 4 GiB vs 8 GiB | 4 GiB→8 GiB 的低並行讀 IOPS 964→935（-3.0%），p99 1,401→1,532 µs（+9.4%），均落在各自噪音帶；RSS 改變證明 runtime 生效 | 基準維持 4 GiB，未重跑 4→8 | **目前不值得** | 先量 BlueStore cache 命中率與記憶體壓力；證明 cache 不足時再重測 | runtime；本次沒有量到 cache 壓力，不能宣稱 working set 已被完整覆蓋 |
| 12 | KubeVirt disk `io` | 維持預設 | 欄位留空／native vs threads | threads 在高並行讀取 +12.4%，其餘大多不可分辨；CPU 成本未量 | 未重跑 | **證據不足以調整** | 維持 native | 需 VM restart；增益只出現在單一 pattern |
| 13 | `osd_mclock_profile` | 飽和時才可能有用 | balanced vs high_client_ops，backfill 中量測 | client latency 1.31 vs 1.31 ms，無差 | 未重跑 profile；第二次 Lab 發現自動 capacity calibration outlier | **本環境不值得調** | 維持 balanced；媒體真正飽和時另行驗證 | runtime；本次沒有足夠爭用可供 scheduler 仲裁 |
| 14 | `osd_scrub_sleep` | 維持預設 | 0 vs 0.1，全 pool deep-scrub | p99 約 1 ms 不變，兩設定不可分辨 | 未重跑 | **本環境不值得調** | 維持預設；HDD 或飽和 cluster 另測 | runtime；僅適用 NVMe 仍有充足效能餘裕的條件 |
| 15 | `blockMultiQueue` | 不需顯式設定 | 不設 vs `true` | 兩邊 guest queue 都是 4；23／29 個指標在噪音帶內，高並行 IOPS 也未超過 5% 判定下限；其餘差異來自時間漂移或單次 max | 未重跑 | **不值得調** | 不設 | 需 VM restart；QEMU v9.1.0 限定，舊版本需另查 |
| 16 | `dedicatedIOThread` | 單盤不啟用 | off vs on | 17／26 個指標在噪音帶內，高並行 IOPS 低於 5% 判定下限；其餘 edge metric 雙向抖動 | 未重跑 | **單盤不值得** | 單盤 VM 維持關閉；多盤尚未驗證，不直接建議開啟 | 需 VM restart；只覆蓋單盤 |
| 17 | guest `read_ahead_kb` | 對 direct I/O 不參與 | 128／512／4096 KiB | 所有受測 pattern 與檔位都低於各自 5%～10% 噪音門檻 | 未重跑 | **direct I/O 不值得調** | 資料庫型 workload 維持預設；buffered I/O 另案測試 | runtime；結論不能外推 file service |

`osd_mclock_max_capacity_iops_ssd` 沒有排入可直接調整的參數。第二次 Lab 中，同型 NVMe 的自動校準結果分成約 6,500、31,900、68,200 IOPS，差距達 5 至 10 倍；aggregate 讀取天花板約 37,100 IOPS，接近 6 × 6,500，表示兩個高值很可能是建立 OSD 時的短期量測失真。生產建議是換碟或重建 OSD 後抽查 outlier，再用代表性 workload 重測；現有證據不足以指定一個應覆寫的固定值。

## 必須建立的 guardrail

### CPU limit 不得低於 vCPU 數

- **調整內容**：4 vCPU VM 的 virt-launcher CPU limit 由 4 降為 2；兩組 `requests=limits`，都屬 Guaranteed QoS。
- **測試原因**：確認 CFS quota 是否會讓 VM 的 I/O completion thread 週期性無法執行。
- **事前預期**：CPU 配額不足會明顯惡化 p99／p99.9，但 p50 可能不變。
- **實測結果**：在 guest 同時執行 4 個 CPU 壓力 thread 時，隨機讀 IOPS 由 7,042 降為 3,352；p50 由 938 µs 變成 946 µs，幾乎相同；p99 由 7.6 ms 變成 55.8 ms；p99.9 惡化 5.6 倍。
- **決策**：VM template 審查必須檢查 CPU limit 不低於 vCPU 數。這項實驗只證明「低於 vCPU 數有重大風險」，沒有證明 limit 等於 vCPU 數是所有 workload 的最適值，也沒有執行 CPU pinning 的正向收益實驗。

### Cache mode 必須以資料正確性決策

- **調整內容**：KubeVirt `spec.template.spec.domain.devices.disks[].cache` 留空、`writethrough`、`writeback`。留空後另從 QEMU 驗證 effective state 為 direct／none。
- **測試原因**：`writeback` 經常被當成免費 throughput，但它把 guest 的完成回報提前到資料仍留在 host page cache 的時間點。
- **事前預期**：writeback 提升平均 throughput，卻惡化 tail latency 與 crash consistency；writethrough 整體較慢。
- **實測結果**：writeback 讓部分 4 KiB 隨機寫 IOPS 看似增加 272% 至 1,997%，但 p99.9 由 3.3 ms 增至 71 ms，循序寫入發生 1.5 至 3.5 秒 stall。writethrough 寫入 IOPS 下降 35% 至 37%，沒有補償收益。Node 硬斷後，writeback 遺失約最後 6 秒已確認寫入；留空／none 對照組沒有遺失。
- **決策**：生產關鍵 VM 將 `cache` 欄位留空，部署後驗證實際 QEMU 狀態。只有能接受 node 級災難遺失最近數秒已確認寫入的非關鍵 workload，才有資格另案評估 writeback。

### Guest block scheduler 維持 `none`

- **調整內容**：`/sys/block/vdb/queue/scheduler` 的 `mq-deadline` 與 `none`。
- **測試原因**：RBD 與 OSD 已各自排程，確認 guest 再排序是否增加無效工作。
- **事前預期**：`none` 略好，可能落在噪音帶內。
- **實測結果**：`none` 的循序讀取由 1,640 提升到 2,291 MiB/s（+39.7%），循序寫入增加 30.1%，高並行隨機讀取增加 6% 且 p99 降低 7.7%。
- **決策**：Ubuntu 24.04 virtio-blk 預設已是 `none`，不需要全面改參數；需要防止映像檔或設定管理把它改成 `mq-deadline` 或其他 scheduler。

### 副本下限與容量是兩條 I/O 卡死線

Pool 固定使用 `size=3`、`min_size=2`，且 CRUSH failure domain 為 host。短暫失去一個 OSD host 時，每個 PG 仍有兩份副本，I/O 可以繼續；當同一 PG 只剩一份可用副本，寫入在本實驗中阻塞 302.8 秒，直到 OSD 回來才完成。

容量狀態具有相同行為。Nearfull 階段只告警、寫入正常；full 階段寫入卡住 96 秒，沒有回傳 ENOSPC 或 EIO，ratio 恢復後原 request 才成功完成。因此：

- 不為小幅寫入效能降低 `size` 或 `min_size`。
- `CephOSDNearFull` 與 `CephCapacityForecast` 應在 full 前觸發實際擴容或清理動作。
- Application 不能假設 storage full 一定會快速回傳錯誤，仍需自己的 request deadline 與健康檢查。

## 有條件才值得做的正向調教

### 高並行新 workload：krbd `queue_depth=256`

- **調整內容**：透過不同 StorageClass 建立 `queue_depth=64` 與 `queue_depth=256` 的新 PVC。128 是環境預設，但沒有在相同的四工高並行矩陣中直接量出 128→256 效果量。
- **測試原因**：確認提高 krbd 在途 request 上限能否提高高並行 throughput，以及是否會傷害低並行 latency。
- **事前預期**：高並行 throughput 上升，但低並行 p99 可能因更深 queue 而惡化。
- **第一次 Lab**：256 相對 64，高並行讀取 +10.3%、寫入 +20.8%，p99 改善 11% 至 15%；`iodepth=1` 差異不可分辨。
- **第二次 Lab**：高並行讀取 49,799→54,304 IOPS（+9%），寫入 28,759→36,817 IOPS（+28%）；p99 分別改善約 15.2% 與 29.5%；低並行差異仍不可分辨。
- **決策**：保留一般 StorageClass 的 128；對確定存在大量並行 I/O 的新 workload 建立 256 專用 StorageClass。第二次 Lab 缺少 host `config_info` 直接證據，所以上線時必須補做 map option 生效驗證。
- **變更限制**：StorageClass 只影響新 PV；直接 patch PV 會被 k8s API 以 `spec.persistentvolumesource is immutable after creation` 拒絕。既有 PVC 要改只能搬資料。

### Working set 超過 cache 時才重測 `osd_memory_target`

- **調整內容**：4 GiB 與 8 GiB，runtime 切換。
- **測試原因**：較大的 BlueStore cache 理論上可改善讀取 latency。
- **事前預期**：8 GiB 的隨機讀 p99 較低。
- **實測結果**：低並行隨機讀取 IOPS 由 964 變成 935（-3.0%），p99 由 1,401 µs 變成 1,532 µs（+9.4%），都落在各自噪音帶；其餘 IOPS／p99 也不可分辨。OSD RSS 從約 1.1 GiB 變成 1.5 GiB，證明參數確實生效。本次沒有直接量 BlueStore cache 命中率，因此只能說「沒有觀察到 cache 壓力」，不能宣稱 16 GiB working set 已被某個簡化的 aggregate cache 容量完整覆蓋。
- **決策**：先以 working set、BlueStore cache 命中率與 host 記憶體壓力證明 cache 不足，再設計 4／8 GiB A/B。不要只因 host 記憶體很多就提高 target；也要抽查 cephadm autotune 是否已悄悄改變 baseline。

## 維持預設或不要調整的參數

### Disk bus：維持 KubeVirt `bus: virtio`

KubeVirt YAML 的 `bus: virtio` 在本環境產生 QEMU virtio-blk；`bus: scsi` 產生 virtio-scsi。兩者 IOPS 差異不超過 4.4%，virtio-scsi 的最大 latency 反而高 20% 至 150%。Linux kernel 6.8 的錯誤處理也不支持「virtio-scsi 會在 30 秒後把 Ceph hang 轉成 I/O error」的說法。維持 `bus: virtio`。

### QEMU I/O mode：維持 native

`io` 欄位留空後實際採 native AIO；threads 在高並行隨機讀取中增加 12.4%、p99 降低 7.2%，但其餘 22／26 指標不可分辨，而且沒有量 threads 的 CPU 成本。單一 pattern 的增益不足以支持全面變更，維持 native。

### `blockMultiQueue`：不需顯式設定

在 QEMU v9.1.0，未設定與 `blockMultiQueue: true` 的 guest queue 數都為 4，等於 VM vCPU 數；command line 唯一差異是顯式出現 `num-queues=4`。23／29 個指標在噪音帶內，高並行 IOPS 也沒有跨過 5% 判定下限；其餘差異可由時間漂移或單次 max 解釋。此結論與 QEMU 版本有關，不能直接外推到沒有 AUTO queue 行為的舊版本。

### `dedicatedIOThread`：單盤 VM 不啟用

單盤 VM 啟用或停用 `dedicatedIOThread`，17／26 個指標在噪音帶內，高並行 IOPS 沒有跨過 5% 判定下限；其餘 edge metric 呈雙向抖動，也沒有收回 host 與 guest 之間的高並行讀取差距。多盤並行尚未實驗，因此只下「單盤不啟用」的結論，不推論多盤一定有收益。

### Guest readahead：direct I/O 不調

`read_ahead_kb` 的 128、512、4096 KiB 在 O_DIRECT 測試中，所有受測 pattern 與檔位差異都低於各自 5% 至 10% 的噪音門檻，因為 O_DIRECT 繞過 page cache，readahead 根本不參與。這不是證明 readahead 永遠沒用；buffered file service 必須另外設計實驗。

### `osd_op_num_shards_ssd`：維持 8

第一次 Lab 的 8→16 對高並行讀寫沒有可辨識收益；第二次 Lab 改成每個 OSD 獨占 NVMe 後，讀取 -2.1%、寫入 -1.8%，仍在噪音帶內。這排除了「共媒體把 shards 收益蓋掉」的主要疑慮。

變更本身需要 OSD rolling restart。第一次 Lab 的 client 讀取 p99 升到 1,360 ms；第二次 Lab 的每秒峰值為 1,206 至 1,889 ms。即使設定最後沒有收益，變更過程仍是一段真實 degraded 事件，因此維持 8。

### `osd_mclock_profile`：有 headroom 時維持 balanced

Backfill 期間切換 balanced 與 high_client_ops，client latency 都是約 1.31 ms，沒有可辨識差異。這不代表 mClock 永遠無效，而是 NVMe 尚有 headroom 時沒有爭用可仲裁。媒體飽和、HDD 或多 tenant workload 需要另行實驗；本環境維持 balanced。

### `osd_scrub_sleep`：有 headroom 時維持預設

全 pool deep-scrub 確實在量測期間執行，但 `osd_scrub_sleep=0` 與 0.1 的 client p99 都約 1 ms。NVMe headroom 吸收了 scrub 負載。本結論不能外推到 HDD 或已接近飽和的 cluster。

### `osd_request_timeout`：不要當成防卡死保險

將 map option 設為 30 秒並確認 host 可見後，PG 因副本不足而不可用時，寫入仍阻塞 302.8 秒，直到 OSD 恢復；沒有 timeout、kernel 訊息或 I/O error。這與原始碼閱讀的預期不一致，機制尚未閉環。決策不是「一定永遠無效」，而是「目前沒有證據能讓生產依賴它」。

## 會改變參數或維運決策的故障實驗

### OSD down 不痛，600 秒後的資料重建才痛

第一次 Lab 停止一個 OSD 後，down 當下 peering 尖峰只有約 3.8 ms；接下來 580 秒、尚未被標成 out 的期間與 baseline 相同。跨過 600 秒 `mon_osd_down_out_interval` 後，Ceph 將 OSD 標成 out 並開始 backfill，隨機讀取的每秒 latency 均值由 0.96 ms 增至 22.73 ms（24 倍）。

因此短期維護的決策點不是「能不能承受 OSD down」，而是「是否會跨過自動 out 並進入不必要的資料重建」。可預期在門檻內恢復的維護，應先設 `noout`；若確定無法快速恢復，就應接受並管理 backfill，而不是在兩種策略間反覆切換。

### Flapping 時 `noout` 有效，但必須有解除條件

單一 OSD 每 60 秒 down／up、重複 5 次，使低並行讀取 p99.9 到 1,146 ms。設定 `noout` 後 p99.9 降至 335 ms，減少 71%；但每次成員變動仍要 peering，所以尖峰沒有歸零。

`noout` 的 runbook 必須同時寫入：

1. 啟用條件：已確認短期維護，或偵測到 OSD flapping 需要先停止反覆 backfill。
2. 解除條件：維護完成、OSD 穩定回歸，或已決定讓 Ceph 正式重建資料。
3. 逾時檢查：長期 `noout` 會讓資料停留在降副本狀態，不可被當成常駐設定。

### Gray failure 比乾淨失效更危險，而且 `ceph health` 看不見

在一台 OSD host 上加入 50 ms 網路延遲，OSD heartbeat 仍正常，沒有 OSD 被標為 down，`ceph health` 全程 `HEALTH_OK`。然而寫入 latency 由 1.73 ms 增至 69.6 ms（40 倍），讀取約 19 倍。

Pool 的三份副本分布在三台 host；每筆寫入要等待三份副本完成，因此一台慢 host 會拖住所有寫入。讀取通常由 primary OSD 回應，所以主要傷害落在 primary 位於慢 host 的 PG。

維運決策是補上 `ceph health` 之外的三層訊號。以下門檻是依第一次 Lab 的 client p99 約 1 ms、host RTT 低於 1 ms 所提出的**起始值**，上線前仍要用各環境 7 日 baseline 校準：

- Client p99 高於自身 7 日同時段 baseline 3 倍，持續 5 分鐘；由 workload／平台 SRE 負責。
- 單一 OSD commit／apply latency 高於全體中位數 5 倍，且 NVMe cluster 絕對值超過 20 ms，持續 5 分鐘；由 storage SRE 負責。
- OSD host 間 RTT 高於 7 日 baseline 5 倍，或 NVMe 低延遲 cluster 絕對值超過 2 ms，持續 5 分鐘；由 network／storage SRE 共同負責。

本 repo 的自訂 rule 位於 `experiments/ceph-alert-rules/rules/ceph-production-coverage.yml`：`CephOSDLatencyOutlier` 目前要求 commit latency 同時超過 100 ms 與全體中位數 3 倍，持續 10 分鐘；`CephDaemonSlowOps` 以最近 5 分鐘的 slow-ops metric 判斷，持續 1 分鐘。它們不是 Ceph upstream 預設 rule，門檻也比上述 gray-failure 起始值保守。Storage SRE 應先以 shadow／warning 驗證較敏感門檻，再決定是否修改正式 rule。兩條 rule 都不能取代 client p99 與 host RTT，因為此次 gray failure 的核心事實就是 Ceph health plane 沒有宣告故障。

### Full 與副本不足都表現為 hang，不是快速失敗

當 pool 因 ratio 注入進入 full，寫入卡住 96 秒，沒有回傳 ENOSPC；解除 full 後原 request 成功。當 PG 低於 `min_size`，寫入同樣一直等待，OSD 恢復後才完成。`osd_request_timeout=30` 沒有改變這個結果。

因此 nearfull 不是一般 warning，而是最後可安全行動的窗口。告警、容量預測、application deadline 與回復 runbook 必須在 full 前運作，不能把 client 快速收到錯誤當成設計前提。

### Node 硬斷同時驗證 cache correctness 與 VM failover

Node 硬斷證實 writeback 會遺失約最後 6 秒已確認寫入，而留空／none 對照組沒有遺失。相同實驗也發現 KubeVirt 的預設 failover 不可預測：一次 VMI 在死 node 上顯示 `Running` 超過 11 分鐘，手動 force-delete 又被 finalizer 擋住；另一次約 5 分鐘後才由 eviction 觸發重排。

所以 VM 高可用不能只靠共享 Ceph RBD。生產需要部署並演練 NodeHealthCheck 或等效的 node-loss 自動化，且值班人員要知道「VMI 顯示 Running，但所在 node 已失聯」是可能狀態。

### Monitor quorum 與 OSD 複合故障：先恢復 monitor

三個 monitor 停一個時 quorum 仍在，client I/O 無感。停兩個失去 quorum 後，既有 client 仍可用舊 osdmap 直接存取 OSD，因此穩態 I/O 暫時正常；這不是健康，而是控制面已失效但資料面尚未需要新 map。

此時再停止一個 OSD，受影響 PG 的寫入進入不可中斷 D-state，因為沒有 monitor 發布新 osdmap，client 與 OSD 都無法完成新的 peering。實測恢復順序是硬條件：先恢復 monitor quorum，再處理 OSD。

這次實驗也暴露自動化缺陷：D-state 讓 guest 指令無法被 `timeout` 或 SIGKILL 終止，主腳本沒有結束，trap 也沒有執行，cluster 在故障狀態滯留約 8 小時才由人工發現。之後所有可能造成 I/O hang 的破壞性實驗，都必須使用獨立於主腳本行程樹的 external watchdog，在硬期限到達時直接執行回復。

## 兩次 Lab 的重跑結果：哪些方向重現，哪些數字改變

### Host I/O 天花板：數字接近，瓶頸成因不同

第一次 Lab 的 host 高並行隨機讀取為 36,602 IOPS；第二次為 37,107 IOPS，只增加 1.4%。但第一次只使用估算 aggregate ceiling 的 68%，第二次已使用約 95%。

這表示「交付數字接近」不等於「系統條件相同」。第一次 Lab 是單一 client 的並行度沒有填滿 9 個 OSD 的估算上限；第二次 Lab 則接近 6 個 OSD 的實際上限。這組穩態單一 client 測試沒有呈現與媒體配置變更相稱的交付數字差異，不能用它量化共媒體的因果效果。

### krbd `queue_depth`：寫入收益數字改變，讀取方向重現

64→256 的高並行讀取收益由第一次 Lab 的 10.3% 變成第二次的 9%，幾乎相同；寫入收益則由 20.8% 增為 28%，且第二次 Lab 的絕對 IOPS 更高。

觀察結果與「共媒體爭用會壓低高並行寫入」的機制一致，但兩次 Lab 同時改變 OSD 數量、mClock calibration 與 CSI 環境，不能由這組跨 Lab 重跑單獨證明因果。可以保留的結論只有：`queue_depth` 對高並行讀寫的正向方向在兩次 Lab 都出現，而低並行 I/O 在兩次都沒有可辨識代價。

### `osd_op_num_shards_ssd`：零收益不是共媒體假象

第一次 Lab 的 8→16 對高並行讀取約 +2.2%、寫入 +0.1%；第二次分別為 -2.1% 與 -1.8%，全部落在噪音帶。每個 OSD 獨占 NVMe 後仍沒有收益，足以維持 8。

### Backfill：從持續變慢改為零星尖峰，但沒有消失

第一次 Lab 在 backfill 階段，低並行隨機讀取的每秒 latency 均值由 0.96 ms 增至 22.73 ms（24 倍），且時間序列呈現連續多個慢窗，最大值約 1.011 秒。

第二次 Lab 的 baseline 為 0.92 ms；backfill 階段每秒 latency 均值為 13.04 ms（14 倍），median 仍為 0.90 ms（baseline 的 1.0 倍），最大值約 1.007 秒。149 個 1 秒樣本中，約 4 秒被零星尖峰拉高。

精確結論是：**相同的每秒延遲均值懲罰由 24 倍降為 14 倍；第二次 Lab 的 median 維持 baseline 的 1.0 倍；兩次 max 都約 1 秒；第一次「持續」、第二次「零星」的判斷來自每秒時間序列。**不能把第一次的 24 倍誤讀成 median，也不能把第二次描述成 backfill 已無影響。

第二次 Lab 每個 OSD 約只有 8 GiB 實際資料，backfill 約 150 秒。生產每個 OSD 若有數 TiB 資料，backfill 時間與尖峰次數都可能大幅增加。結果與「獨占媒體減少持續爭用」的機制一致，但因 OSD 數量、mClock calibration 與 CSI 環境同時改變，這次跨 Lab 重跑不能單獨證明因果；14 倍與 4／149 秒更不能直接移植。

## 變更落地矩陣

| 生效層級 | 代表設定 | 生效方式 | 服務影響 | 驗證方式 | 回復方式 |
|---|---|---|---|---|---|
| Runtime | guest scheduler、`osd_memory_target`、`osd_mclock_profile`、`osd_scrub_sleep`、`noout`、容量 ratio | 寫入 sysfs 或 `ceph config set`／cluster flag | 通常不需要停 VM；錯誤設定仍可能立即影響 client | guest sysfs、`ceph config show`、cluster flag、client latency | 設回原值並確認行為恢復 |
| VM restart | KubeVirt disk cache、bus、io、`blockMultiQueue`、`dedicatedIOThread`、virt-launcher CPU 資源 | 修改 VM template 後 stop/start | VM 停機；live migration 不會套用新欄位 | VMI spec、QEMU command line、guest device | template 設回原值後再次 stop/start |
| OSD rolling restart | `osd_op_num_shards_ssd` 等 startup 參數 | 逐一 restart OSD | 每顆 OSD peering；client tail latency 可達秒級 | `ceph config show`、daemon startup config、client 時間序列 | 安全地逐一設回並再次 rolling restart |
| PV 建立期 | krbd `queue_depth`、`osd_request_timeout` 等 map options | StorageClass 建立新 PV 時固化 | 既有 PVC 無法線上改；需要資料搬移 | Host `rbd device list`／`config_info`、行為 A/B | 搬回原 PVC 或原 StorageClass |
| Pool／架構期 | `size`、`min_size`、failure domain、image layout | Pool 或 volume 建立與資料重配置 | 可能觸發大量 backfill，或改變可用性 | `ceph osd pool get`、CRUSH mapping、degraded 演練 | 另排資料重配置與風險評估 |

修改 VM template 後，running VMI 只會被標為 `RestartRequired`；連續做兩次 live migration 都不會套用新的 disk 參數。把 template 改回原值也不會清除 `RestartRequired`，只有 stop/start 才真正重新建立 QEMU。變更管理必須把這些欄位當停機參數。

## 限制、事故與未解問題

### 可以移植的是機制，不是所有倍率

- Azure worker 使用 nested virtualization；絕對 VM latency 不等於 bare-metal KubeVirt。
- 第一次 Lab 的三個 OSD 共用單一 NVMe；觀察結果與共媒體放大 backfill、recovery 與高並行寫入爭用的機制一致，但本研究不能單獨量化其因果效果。
- 第二次 Lab 同時改變 OSD 數量與媒體配置，不是嚴格單變因 A/B。
- 第二次 Lab 每個 OSD 約 8 GiB 有效資料、backfill 約 150 秒，不能外推到數 TiB OSD 的事件歷時與尖峰次數。
- Ceph 端有充足 NVMe headroom；mClock 與 scrub 結論不能外推到 HDD 或媒體飽和 cluster。
- 正常狀態負載使用 O_DIRECT；readahead 結論不能外推 buffered I/O。
- `queue_depth=256` 的第二次 Lab 缺少 host 直接生效讀值，只能以顯著且一致的 A/B 行為支援。
- CPU limit 實驗沒有取得 cgroup `throttled_usec`，但 client 效果量明確；也沒有執行 CPU pinning 的正向收益實驗。

### 實驗過程中的有效失敗

Gray failure 最初嘗試用 systemd cgroup IOPS 限制單一 OSD，但 cephadm／podman 的實際 cgroup 層級使限制沒有作用。這兩次結果被判定為無效，不拿來支持結論；第三次改用 host 網卡 `tc netem +50ms`，並以 client latency 與 OSD liveness 驗證注入確實成立。

Monitor quorum 複合故障實驗發生約 8 小時故障態滯留，原因是 guest I/O 進入不可中斷 D-state，導致腳本內 timeout、SIGKILL 與 trap 都無法完成回復。這不是環境本身無法恢復，而是自動化把回復動作放在可能被卡住的同一條行程樹。External watchdog 已成為後續破壞性實驗的硬性前提。

### 仍未回答的問題

1. 為什麼 `osd_request_timeout=30` 在 PG inactive 時沒有觸發，與 client 原始碼路徑的預期不一致？
2. 多 VM 同時使用 `queue_depth=256` 時，是否會把單 VM 的正向收益轉化為 host queue 競爭？
3. 多盤並行 VM 啟用 `dedicatedIOThread` 是否有收益？單盤結果不能回答。
4. HDD 或已飽和 NVMe cluster 中，high_client_ops 與 scrub 節流的實際收益和 recovery 代價是多少？
5. 每個 OSD 有數 TiB 資料時，獨占媒體能把 backfill 的典型 latency 維持到什麼程度？
6. `osd_mclock_max_capacity_iops_ssd` 的自動校準 outlier 應如何以可重現 workload 重量並安全覆寫？

## 結論與下一步

### 現在就做

1. 在 VM template policy 中檢查 CPU limit 不低於 vCPU 數。
2. 保持 KubeVirt disk `cache` 欄位留空，並在版本升級或 template 變更後驗證 QEMU effective state。
3. 在 guest 映像檔驗證 virtio block device scheduler 為 `none`。
4. 將 repo 自訂的 `CephOSDNearFull`、`CephCapacityForecast`、`CephOSDLatencyOutlier`、client p99 與 OSD host RTT 納入同一套事件視圖；storage SRE 負責 rule，workload SRE 負責 client SLI，network SRE 負責 RTT，先以 shadow／warning 驗證正文提出的起始門檻。
5. 在維護 runbook 寫清楚 `noout` 的啟用、解除與逾時檢查；複合故障寫明先恢復 monitor quorum。
6. 部署並演練 NodeHealthCheck 或等效 node-loss 自動化，不能把共享 RBD 誤當成完整 VM HA。

### 條件成立再做

1. 明確存在大量並行 I/O 的新 workload，建立 `queue_depth=256` 專用 StorageClass，先小範圍驗證 map option 生效與多 VM 競爭。
2. Working set 大於現有 BlueStore cache 且命中率不足，再測 `osd_memory_target`。
3. HDD 或媒體飽和時，再測 high_client_ops 與 scrub 節流。

### 不要做

1. 不為平均 throughput 把關鍵 VM 改成 writeback。
2. 不把 virtio-scsi 當成 I/O timeout 保護。
3. 不在沒有實測收益時把 `osd_op_num_shards_ssd` 改成 16，承擔一次 rolling restart。
4. 不期待 live migration 套用新的 VMI disk 參數。
5. 不把 `osd_request_timeout` 當成 application deadline 的替代品。
6. 不長期保留 `noout`。

## 附錄 A：完整實驗 ledger

正文只詳細展開會改變參數或維運決策的故障實驗；其餘實驗仍完整列在這裡。代號只作為原始證據索引，不是正文閱讀前提。

| 人類可讀名稱 | 類別 | 狀態 | 事前預期 | 結果摘要 | 證據索引 |
|---|---|---|---|---|---|
| 環境與版本盤點 | 基建 | 已執行 | 版本符合研究基準 | 版本對齊；發現第一次 Lab 的 `osd_memory_target` autotune 會干擾 baseline | E-00 |
| Azure 噪音帶 | 基建 | 已執行 | Azure 噪音高於既有 Proxmox VE 環境 | 被推翻；變異係數約 0.4%～2%，第二次 Lab 更低 | E-01 |
| Host 直接存取 RBD 的天花板 | 基建 | 兩次 Lab 均執行 | Host 顯著快於 VM | 虛擬化成本集中在高並行讀取；兩次交付數字接近但瓶頸成因不同 | E-02 |
| Guest、host、QEMU 觀測互洽 | 基建 | 已執行 | 各層 IOPS 相符 | Guest 與 host 差約 0.03% | E-03 |
| QEMU cache mode | 效能／正確性 | 已執行 | writeback 平均較快但 tail latency 較差 | 命中；另由 node 硬斷證實資料遺失風險 | E-10 |
| Virtio-blk 與 virtio-scsi | 效能 | 已執行 | virtio-scsi 高並行較慢 | IOPS 無差，virtio-scsi 最大 latency 較差 | E-11 |
| Native AIO 與 threads | 效能 | 已執行 | threads 較慢 | 被推翻；高並行讀取略快，但不足以改預設 | E-12 |
| Block multi-queue 顯式開關 | 效能 | 已執行 | 新版 QEMU 下沒有差異 | 命中；兩邊 queue 都等於 vCPU 數 | E-13 |
| 單盤 dedicated I/O thread | 效能 | 已執行 | 單盤沒有差異 | 命中 | E-14 |
| CPU limit 低於 vCPU | 效能／穩定性 | 已執行 | tail latency 大幅惡化 | 命中；p99 7.4 倍、IOPS 約減半 | E-15 |
| CPU pinning 與 emulator thread isolation | 效能 | 裁定不做 | 預期能降低競爭 | 變更 kubelet 成本高，主風險已由 CPU limit 實驗回答 | E-16 |
| Guest block scheduler | 效能 | 已執行 | `none` 略好 | `none` 的循序讀寫明顯更好 | E-17 |
| Guest readahead | 效能 | 已執行 | 4096 KiB 提升循序讀取 | 被推翻；O_DIRECT 不經 page cache | E-18 |
| krbd queue depth | 效能／建置期 | 兩次 Lab 均執行 | 高並行較快，但低並行 p99 變差 | 高並行較快且 p99 改善；低並行無差 | E-19 |
| RBD object size 與 striping | 效能／建置期 | 裁定不做 | 可能影響大 block throughput | Host 天花板顯示優先度低，且變更成本高 | E-20 |
| BlueStore memory target | 效能／runtime | 已執行 | 8 GiB 改善讀取 p99 | 不可分辨；本次未觀察到 cache 壓力，但未量命中率 | E-21 |
| OSD operation shards | 效能／restart | 兩次 Lab 均執行 | 16 與 8 接近；restart 有尖峰 | 兩次都無收益；restart 造成秒級尖峰 | E-22 |
| Pool 三副本與兩副本的寫入成本 | 效能／架構 | 裁定不做 | 兩副本較快 | 生產不接受以降低副本換效能，優先度低 | E-23 |
| 單一 OSD down 到 backfill | 故障 | 兩次 Lab 均執行 | 傷害集中 peering | 修正：down 幾乎無感，主要傷害在 auto-out 後 backfill | E-30 |
| 整台 OSD host 硬斷 | 故障 | 已執行 | 比單 OSD 更嚴重 | 短於 auto-out 門檻時幾乎無感；長斷未驗 | E-31 |
| OSD host gray failure | 故障 | 已執行 | Client 變慢但 Ceph health 正常 | 命中；寫入 40 倍、讀取 19 倍 | E-32 |
| OSD 網路封包遺失 | 故障 | 已執行 | 0.1% 即使 p99.9 超過 5 倍 | 被推翻；0.5% 最壞約 1.1 倍 | E-33 |
| OSD flapping 與 noout | 故障／維運 | 已執行 | flapping 傷害大，noout 有效 | 命中；noout 將 p99.9 降低 71% | E-34 |
| Monitor quorum 與 OSD 複合故障 | 故障／維運 | 已執行 | Quorum 失去後穩態 I/O 暫時正常，疊加 OSD 故障後 hang | 命中；恢復順序必須先 monitor | E-35 |
| 副本不足與 request timeout | 故障／建置期 | 已執行 | 30 秒 timeout 將 hang 轉為錯誤 | 被推翻；阻塞約 303 秒直到 OSD 回復 | E-36 |
| Deep-scrub 與 scrub sleep | 故障／runtime | 已執行 | Scrub 影響 p99，sleep 可緩解 | 被推翻；有 headroom 時全程平坦 | E-37 |
| Nearfull 與 full 行為 | 故障／runtime | 已執行 | Nearfull 只告警，full 使 I/O hang | 命中；full 卡 96 秒且非 ENOSPC | E-38 |
| Backfill 中切換 mClock profile | 故障／runtime | 已執行 | high_client_ops 保護 client latency | 被推翻；有 headroom 時兩者無差 | E-39 |
| Node 硬斷下的 cache consistency | 故障／正確性 | 已執行 | writeback 遺失資料，none 不遺失 | 命中；writeback 遺失約最後 6 秒已確認寫入 | E-40 |
| K8s node 硬斷後 VM failover | 故障／維運 | 已執行 | 分鐘級且可拆解 | 被推翻；預設行為慢且不可預測 | E-41 |
| 高 I/O 中 live migration | 維運 | 已執行 | 短尖峰、沒有 I/O error | 命中；最差 1 秒窗約 8 ms | E-42 |
| CSI、virt-handler、kubelet 個別失效 | 故障 | 裁定不做 | Running VM 的 krbd 資料路徑不受影響 | 機制清楚且優先度低，保留 backlog | E-43 |
| VMI disk 欄位能否透過 migration 套用 | 可調性 | 已執行 | 不能，必須 stop/start | 命中；migration 兩次仍不套用 | E-50 |
| 既有 PVC 的 krbd map options 能否修改 | 可調性 | 已執行 | 改 StorageClass 無效；PV patch 可能是後門 | PV source immutable，沒有後門 | E-51 |
| Ceph runtime 參數生效 | 可調性 | 併入其他實驗 | `ceph config set` 可立即生效 | memory RSS 與 profile 切換證實，不另跑 | E-52 |

帳目對得上：規劃 35 項，30 項獨立執行，1 項併入其他實驗，4 項裁定不做。

## 附錄 B：證據索引

- 第一次 Azure Lab 的逐實驗 ledger：[`EVIDENCE-SUMMARY-2026-07-08.md`](./EVIDENCE-SUMMARY-2026-07-08.md)
- 第二次 Azure Lab 的重跑摘要：[`EVIDENCE-SUMMARY-2026-07-13.md`](./EVIDENCE-SUMMARY-2026-07-13.md)
- 原研究總結與逐實驗五欄記錄：[`REPORT.md`](./REPORT.md)
- 實驗前 prediction 與狀態：[`HYPOTHESES.md`](./HYPOTHESES.md)
- 完整實驗協定：[`EXPERIMENT-PLAN.md`](./EXPERIMENT-PLAN.md)
- 環境規格與最初建置假設：[`AZURE-ENV-SPEC.md`](./AZURE-ENV-SPEC.md)
- 實驗時序、偏差與事故記錄：[`STATE.md`](./STATE.md)
- 重跑與回復操作：[`RUNBOOK.md`](./RUNBOOK.md)

`results/` 下的原始 bundle 由 `.gitignore` 排除，目前 checkout 只保留部分資料；monitor quorum 複合故障的 raw bundle 隨舊 worktree 被清除，只有執行當下回填的 ledger 與 Git history。這些證據限制已反映在正文信心判斷，沒有把缺失的 raw bundle 描述成仍可取得。
