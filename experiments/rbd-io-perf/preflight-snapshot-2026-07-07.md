# E-00 pre-flight environment snapshot（手動盤點版，2026-07-07）

> 全程 read-only（ssh ioperf@192.168.16.7，sudo 唯讀指令）。harness 的 `run/preflight.sh` 完成後會再自動重跑一次覆核。

## 版本

| 項目 | 值 | 對 pinned submodule |
|---|---|---|
| PVE | 9.0.11（node: pve3） | — |
| pve-qemu-kvm | 10.1.2-1 | qemu v9.1.0 → **差一個大版**，錨點引用需標註 |
| kernel | 6.14.11-4-pve | linux 6.8.0-52 → krbd 行為差異需標註 |
| ceph | 19.2.3-pve2（squid） | v19.2.3 → **同版** ✅ |

## 叢集拓樸

- 3 node：pve / pve2 / pve3；mon×3（quorum pve2,pve3,pve）、mgr active=pve2、mds×1(+standby)。
- 11 OSD = 9 hdd + **2 ssd**：osd.0（ssd 256G，host pve）、osd.8（ssd 224G，host pve3）。
- **hyperconverged 確認**：測試 node pve3 上跑 osd.4/5/7（hdd）+ osd.8（ssd）→ H-031 的節點選擇無從迴避（SSD OSD 只在 pve 與 pve3，pve3 是指定測試 node），依 guardrail（記憶體監控 + 有界負載）執行。
- **基線 HEALTH_WARN**：`BLUESTORE_SLOW_OP_ALERT: osd.0`——**ioperf pool 兩顆 SSD OSD 之一**。每筆寫入都要等 osd.0 ack（size=2、兩顆全在每個 PG 的 acting set），此警告是量測的一級 confound，E-02/E-03 解讀必帶。guardrail 的差分基線把它記為既有狀態。

## 測試 pool

- `ioperf`：rbd、128 PG、**size=2 / min_size=2**、crush rule `ssd-only`（chooseleaf host）→ 每個 object 恰好 osd.0 + osd.8 各一份，無分散空間。
- **min_size=2 風險註記**：任一 SSD OSD down，pool IO 全停（我們不動 ceph，只是 taint/abort 偵測要盯 osd.0/osd.8 up 狀態）。
- 容量：SSD class 480G raw、已用 116G（24%）；pool MAX AVAIL 127G。**磁碟預算**（使用者要求留 20–30% 空間、一次一台 VM）：boot 10G + data 16G，image 變體逐顆建刪不並存，峰值約 42G stored ≈ 84G raw → SSD class 用量峰值 ~42%，符合要求。
- 同 SSD class 上還有 `ssd` 與 `cache` pool（prod 在用）→ 我們的負載會與 prod cache IO 互相干擾；A/B 交錯 + 每輪記併發負載（`ceph -s` client io）。

## 網路

- ceph `public_network` = 192.168.16.0/24（client→OSD 走這）；`cluster_network` = 172.17.0.66/29（OSD 複寫，vmbr2/enp1s0f1）。
- **pve3 的 public 介面 = vmbr0 → enp5s0，ethtool 協商 100Mb/s**（MAC 前綴 e8:9c:25 為 Realtek 2.5G 系列，疑似線/埠協商問題）。影響：從 pve3 出發、primary 在遠端 osd.0 的 PG（約半數），client IO 封頂 ~11 MB/s；primary 在本機 osd.8 的 PG 走 local + cluster net（10G）快路徑 → **所有延遲/吞吐預期雙峰**。已回報使用者裁示（先修線再測 vs 照現況測）。
- vmbr1 → enp1s0f0（10G，Link yes）：測試 VM 的 guest 網路（192.168.18.0/24 DHCP）——只承載我們 ssh 進 guest 的流量，不在 ceph datapath 上。

### 網路查證 v2（使用者要求確認「應該只有 management 是 1G 其他都 10G」）

- **實體層**：pve3 有三張卡——Intel 82599ES 10G ×2（enp1s0f0 → vmbr1 guest 網、enp1s0f1 → vmbr2 ceph cluster net，皆 MTU 9000、協商 10G ✅）+ Realtek RTL8111 **1G**（enp5s0 → vmbr0 management）。
- **enp5s0 兩側（本卡與 switch link partner）都 advertise 1000baseT，卻協商在 100Mb/s** → 幾乎可確定是線材問題（斷對）或埠接觸不良；換線應可回 1G。**【2026-07-07 更新】使用者已換線，ethtool 確認回到 1000Mb/s Full**——client IO 封頂由 ~11 MB/s 回到 ~112 MB/s；seq 類實驗（E-09/E-13）仍會被 1G 壓縮差異，結論標註「public net = 1G」。
- **架構層**：`ceph.conf` 的 `public_network = 192.168.16.0/24` 就是 management 網段 → **client→OSD/mon 的資料流量走 management NIC**。「ceph 走 10G」只對 OSD 複寫（cluster_network，vmbr2）成立；所有 VM 磁碟 IO 到遠端 OSD 的 client 流量其實走這張 1G（現況 100Mb）卡。要把 client IO 搬到 10G 需改 ceph `public_network` + mon 重新定址——invasive 的 ceph 變更，不在本實驗邊界內（僅告知使用者）。
- **對實驗的影響**：修回 1G 後，遠端 primary（osd.0）的 client IO 上限 ~112 MB/s——高 QD 4k 與 seq 實驗可能觸頂（E-02 量化）；旋鈕對照實驗（cache / aio / iothread / 雙軸）不受影響（各變體走同一條網）。所有結論標註「public net = 1G（management 共用）」。

### cloud image

- cephfs `template/iso/` 只有安裝 ISO（live-server / netinst），**無 cloud image** → Phase 2 依使用者指示下載 Ubuntu 24.04 cloud image（~600MB）至 cephfs。

## PVE 預設與其他

- storage.cfg：`ioperf`（rbd、`krbd 0`、pool ioperf）已由使用者建好；**cluster 已有 `krbd 1` 的先例**（`ceph-ssd` storage，pool ssd）→ E-01 krbd 可行性風險大降；krbd 軸屆時新增 `ioperf-krbd` storage id。
- 既有 VM 樣本（qm config 103）：`scsihw: virtio-scsi-single`、disk `iothread=1`——PVE 實務預設與 KubeVirt 軸不同（H-033 成立方向）；E-03 以測試 VM 的實際 qm config / QEMU cmdline 為準。
- mClock：`osd_op_queue=mclock_scheduler`、profile=`balanced`（僅記錄，不動）。
- pve3 硬體：8 cores、32G RAM（avail ~15G）、governor=performance、/dev/kvm 存在。
- **fio 未安裝於 node**（E-02 需要；`fio --enghelp` 的 rbd engine 支援待安裝後確認）——待使用者同意 `apt install fio`。
- VMID 1031–1039 全空 ✅；帳號 ioperf + NOPASSWD sudo 運作正常 ✅。

## SSD 調查（2026-07-08，Gate 3 授權）

`ceph device ls` + `ceph device get-health-metrics`（read-only）：

- **osd.0 = Crucial_CT275MX300SSD1（MX300 275GB，2016 消費級 TLC，無 PLP）**：WEAR **90%**、Ave_Block-Erase_Count 1360（額定 ~1500 P/E）、Power_On_Hours 29,154、Total_LBAs_Written ≈23.7TB（相對額定 80TBW 不高——Ceph 小寫的 write amplification 把 P/E 吃掉了）、Reallocated 7。
- **osd.8 = OCZ-ARC100（2014 入門消費級，無 PLP）**：mgr 未回報 wear。
- 結論：E-02 的 33 IOPS 寫入天花板與 osd.0 長期 BLUESTORE_SLOW_OP_ALERT 的根因即此二盤——無 PLP 消費 SSD 上 BlueStore 每寫真 flush，磨損 90% 的 MX300 更是雪上加霜。建議更換為有 PLP 的資料中心級 SSD。
