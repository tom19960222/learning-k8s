# learning-k8s 實驗語彙

這份 glossary 固定系統行為實驗裡容易混淆的領域語言，避免把不同量測層級的數字都簡稱為「IOPS」。

## Ceph mClock

**宣告容量（declared capacity）**：
mClock 以 `osd_mclock_max_capacity_iops_ssd` 表示的單顆 OSD 名義容量，用來換算 scheduler 的 reservation、weight 與 limit；它不是裸裝置 IOPS，也不是整個 cluster 的 client 吞吐。
_Avoid_: 實際 IOPS、磁碟 IOPS

**宣告容量落差（declared-capacity gap）**：
宣告容量與另一個明確標示量測層級的 capacity reference 之間的差距；描述時必須指出 reference 是 raw NVMe、per-OSD BlueStore 或 cluster client ceiling。
_Avoid_: capacity 錯估、真實 IOPS 落差

**OSD startup bench**：
OSD 啟動時由 Ceph 經 BlueStore 執行的短時間 4 KiB 寫入量測，結果可成為宣告容量的來源。
_Avoid_: raw NVMe benchmark、client ceiling

**raw NVMe throughput**：
建立 OSD 前直接對裸 NVMe 裝置量到的吞吐，只代表裝置層能力，不含 BlueStore、replication 與 client datapath 成本。
_Avoid_: OSD capacity、Ceph IOPS

**client ceiling**：
cluster 健康時，以不限速 client workload 經完整 RBD datapath 量到的 aggregate 吞吐上限。
_Avoid_: per-OSD capacity、raw device ceiling
