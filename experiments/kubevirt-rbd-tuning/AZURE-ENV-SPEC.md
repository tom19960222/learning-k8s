# kubevirt-rbd-tuning — Azure 實驗環境規格書（v1，待使用者確認後建置）

> 形狀由使用者定案（2026-07-07 framing dialog）：獨立 Ceph cluster（3 mon + 3 OSD node × 3 OSD daemon，
> local NVMe）+ k8s 以 external ceph 接入。本文件把它落成可照建的規格。
> 規格反推自 `EXPERIMENT-PLAN.md` 的需求，右欄註明「為什麼」。

## 拓樸總覽（9 台 VM，單一 VNet）

```
resource group: rg-kubevirt-rbd-tuning（region 任選，全部資源同 region + 同 zone）
vnet 10.60.0.0/16
  subnet ceph    10.60.1.0/24   … mon×3、osd×3
  subnet k8s     10.60.2.0/24   … k8s×3
（同 subnet 亦可；分開只是 tc netem 注入時比對方便）
proximity placement group：全 9 台同 PPG
```

| 角色 | 台數 | VM size | 規格 | 為什麼 |
|---|---|---|---|---|
| ceph-mon-{1..3} | 3 | **Standard_D2s_v5** | 2 vCPU / 8 GiB，OS disk P6 64GiB | mon/mgr 輕量；mgr 跑在 mon-1/2（cephadm 預設 2 個 standby） |
| ceph-osd-{1..3} | 3 | **Standard_L32s_v3**（主案） | 32 vCPU / 256 GiB / **4× 1.92TB local NVMe（用 3 顆，1 顆閒置備援）**，OS disk P6 | 使用者要求 3 顆**實體** NVMe/台 = 3 OSD daemon 各自獨占媒體；Lsv3 家族 NVMe 顆數只有 1/2/4/6/8/10，最小滿足 3 顆的是 L32s_v3。⚠ 需先調 quota（見下節） |

Fallback（quota 調不下來或要省成本時）：`Standard_L8s_v3`（1× NVMe 以 LVM 切 3 LV = 3 OSD daemon 共媒體，總 vCPU 50 塞進預設 65 quota）——代價是 3 daemon 共享一顆碟的 IOPS，E-22（shards）與 per-OSD 隔離類實驗解讀力下降。

### Quota 需求（2026-07-07 以 az CLI 實查，subscription `Azure subscription 2025`）

實查結果：所有候選 region 的 `Total Regional vCPUs` 與 `standardLSv3Family` 預設都是 **65**；
southeastasia 目前用量 0（最乾淨）、japaneast 已用 26、eastus 已用 13。

主案總需求：OSD 32×3=96 + mon 2×3=6 + k8s 4+8×2=20 = **122 vCPU**。

| Quota 項 | 現值 | 需調至 |
|---|---|---|
| Total Regional vCPUs（southeastasia） | 65 | **≥130** |
| standardLSv3Family | 65 | **≥96** |
| standardDSv5Family | 65 | 不用調（需 26） |

```bash
az extension add --name quota
SCOPE=/subscriptions/67638d45-2cd3-41c7-9e70-87082e5ae065/providers/Microsoft.Compute/locations/southeastasia
az quota update --scope $SCOPE --resource-name cores              --limit-object value=130
az quota update --scope $SCOPE --resource-name standardLSv3Family --limit-object value=96
# 建置前驗證：az vm list-usage --location southeastasia -o table | grep -Ei 'Total Regional|LSV3'
```
| k8s-cp-1 | 1 | **Standard_D4s_v5** | 4 vCPU / 16 GiB，OS disk P10 128GiB | control plane 不跑 VM |
| k8s-w-{1..2} | 2 | **Standard_D8s_v5** | 8 vCPU / 32 GiB，OS disk P10 | **Dv5 支援 nested virtualization**（KVM 硬體加速）；2 台 worker 是 live migration 實驗（E-19/41/42/50）的硬前提；8 vCPU = VM 4 vCPU + 噪音 pod + 系統餘裕 |

估算成本（pay-as-you-go 級距，僅供量級參考，實際以你的訂閱與 region 為準）：
主案 L32s_v3 ≈ $2.7/hr ×3 + D8s_v5 ≈ $0.38/hr ×2 + D4s_v5 ≈ $0.19 + D2s_v5 ≈ $0.10 ×3
≈ **$9.3/hr ≈ $225/天（24h 開機）**；fallback（L8s_v3）≈ $3.1/hr ≈ $75/天。
建議實驗時段開機、離場 deallocate（⚠ L 系列 deallocate 即清空 NVMe → 見「重建自動化」）。

## 共同設定（9 台）

| 項目 | 值 | 為什麼 |
|---|---|---|
| OS | **Ubuntu 24.04 LTS**（noble） | kernel 6.8 與 pinned linux submodule 對齊——krbd 的 T1 證據直接適用 T3 |
| Accelerated networking | 全部啟用 | 壓低網路噪音（H-008） |
| 帳號 | `ikaros` + repo 內 `.ssh/id_ed25519.pub` | 沿用既有工作流 |
| sudo | NOPASSWD | harness 自動化 |
| 其他套件 | osd/k8s node：`fio jq tc(iproute2) stress-ng lvm2 chrony` | E-02/E-15/E-32/E-33 需要 |
| NSG | 只開 22 給你的來源 IP；VNet 內全通 | 實驗叢集不對外 |

## Ceph cluster（cephadm）

| 項目 | 值 | 為什麼 |
|---|---|---|
| 版本 | **v19.2.3**（`cephadm bootstrap --image quay.io/ceph/ceph:v19.2.3`） | 對齊 pinned submodule |
| bootstrap | mon-1 為 seed；`--mon-ip 10.60.1.x` | — |
| mon/mgr | mon×3（label 指定）、mgr×2 | 標準 HA；E-35 要 down mon 所以必須 3 顆真 daemon |
| OSD | 主案：每台 3 顆實體 NVMe 各一 OSD → `ceph orch daemon add osd <host>:/dev/nvme{0,1,2}n1`（第 4 顆不入 cluster）；fallback（L8s_v3）：單 NVMe 切 3 LV | 3 daemon 各占媒體，per-OSD 故障注入（E-30/32/34）隔離乾淨 |
| E-21 注意 | L32s_v3 記憶體 256 GiB，`osd_memory_target` 8G×3 綽綽有餘；**E-01 前先把 target 顯式設回 4G 預設**（cephadm 在大記憶體機上 autotune 可能給更高值，會汙染 baseline） | 主案機器太大反而要防 autotune 偏離預設 |
| pool | `kubevirt`（RBD app，pg_num 128，size=3/min_size=2）+ `ioperf-scratch`（E-23/E-38 用，可隨建隨刪） | 主 pool 與破壞性 pool 分離 |
| Prometheus | cephadm 內建 monitoring stack 開啟 | degraded 實驗的 metric 時序（含健康碼記錄） |
| ⚠ 不要調 | 其餘一切保持預設（mClock balanced、shards 預設…） | 預設值就是 baseline |

## k8s + KubeVirt + external ceph

| 項目 | 值 | 為什麼 |
|---|---|---|
| k8s 發行版 | **k0s v1.33.x**（1 controller + 2 worker） | 與你既有 .160 環境同技術棧，經驗可複用；版本落在 kubevirt v1.5.0 支援帶 |
| CNI | k0s 預設（kuberouter）即可 | 不在研究軸上 |
| KubeVirt | **v1.5.0**（release manifest） | pinned 錨點 |
| feature gates | 至少開 `LiveMigration`（v1.5 預設 GA 即可）；`vmRolloutStrategy` 保持預設 Stage | E-50 要驗 Stage 行為本身 |
| external ceph 接法 | **Rook v1.19.6 external cluster 模式**（`create-external-cluster-resources.py` 在 ceph 側跑 → import 到 `rook-ceph-external`） | 與你生產拓樸同型（.160 同款）；ceph-csi 由 Rook 帶入，版本隨 Rook（E-00 記錄實際 csi 版本與 pinned v3.14.0 的差異） |
| StorageClass | `rook-ceph-block`（RWO，boot 用）+ `rook-ceph-block-rwx`（**volumeMode Block + RWX**，資料盤/ migration 用）；`imageFeatures: layering,exclusive-lock,object-map,fast-diff` | RWX block 是 live migration 硬前提（H-020 evidence：checkVolumesForMigration 只認 RWX） |
| guest 映像 | Ubuntu 24.04 cloud image（containerDisk 或 DataVolume 匯入） | guest kernel 也 6.8，對齊 |
| nested virt 驗收 | k8s worker 上 `kvm-ok` / `/dev/kvm` 存在；KubeVirt 不得 fallback 到 TCG 軟體模擬 | 軟體模擬會讓所有數字作廢——preflight 硬性斷言 |

## 實驗需求 → 規格的對應檢核

| 實驗需求 | 規格保證 |
|---|---|
| E-35 mon quorum 失去 | 3 顆獨立 mon VM，可 stop 2 台 |
| E-31 OSD node 全滅 | OSD 分 3 台，stop 1 台 = 掉 3/9 OSD，size=3 pool 仍可服務 |
| E-32/33 tc netem 注入 | OSD/k8s node 皆有 root + iproute2；ceph subnet 與 k8s subnet 分開便於篩選 |
| E-41 node 硬斷 | 2 台 worker + RWX block SC + Azure `az vm stop --skip-shutdown` |
| E-19/E-51 SC 重建 | csi 由 Rook 管，SC 可自由增刪 |
| E-21 osd_memory_target 8G×3 | OSD node 64 GiB RAM（3 daemon×8G=24G，餘裕充足） |
| E-16 node CPU 競爭 | worker 8 vCPU，噪音 pod 有核可搶 |
| H-008 噪音控制 | 同 PPG + accelerated networking + 專屬叢集無鄰居 workload |

## 重建自動化（⚠ 建置時就要準備，不是事後補）

L 系列 **deallocate 後 local NVMe 資料全失**（stop 不 deallocate 則保留但仍在計費）。
兩個選擇，建議 A：

- **A（推薦）**：實驗期間只 `az vm stop`（不 deallocate，仍計費但 NVMe 保留）；
  跨多天的長暫停才 deallocate，並用 `redeploy-osds.sh`（建置時一併寫好）自動重建：
  wipe LV → `ceph orch daemon add osd` ×9 → 等 HEALTH_OK → 重建 `kubevirt` pool 與測試 image。
- **B**：每天 deallocate 省錢，每次開工先跑 redeploy（~20 分鐘）+ E-00 快照比對。

## 交付驗收（你建好後我跑 preflight 驗這些）

1. 9 台可 ssh（repo key）、sudo -n 通。
2. `ceph -s` HEALTH_OK、mon×3 quorum、osd 9 up 9 in、版本 19.2.3。
3. k8s 3 node Ready；`rook-ceph-external` namespace 的 CephCluster `Connected`。
4. KubeVirt v1.5.0 全元件 Deployed；worker `/dev/kvm` 存在。
5. 兩個 SC 可各建 PVC 並 Bound；RWX block PVC 可同時掛雙 worker（migration 前提）。
6. 測試 VMI 可啟動、可 `virtctl migrate` 成功一次（管線驗通）。

## 建置方式建議

你手動建或給我 az CLI 權限皆可。若你要腳本，我可以先寫
`provision/`（az cli + cloud-init + cephadm/k0s/rook bootstrap 全套）在本機 dry-run 語法後交給你執行——
建置腳本本身也進 `experiments/kubevirt-rbd-tuning/`，重建能力是 charter 的一部分。
