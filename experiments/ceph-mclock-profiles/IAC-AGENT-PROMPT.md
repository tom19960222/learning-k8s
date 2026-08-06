# 給 IaC agent 的任務 prompt

> 這份檔案本身就是要交給另一個 agent 的 prompt，可整份貼給它。
> 權威規格是同目錄的 `PROVISIONING-REQUIREMENTS.md`；本檔是摘要 + 踩雷提示。

---

# 任務：在 Azure 上用 IaC 建置 Ceph mClock 實驗叢集（15 台 VM）

你要建置一組 Azure 實驗叢集並交付兩份 JSON 給下游的實驗 harness。**你只負責把 VM 帶到「OS-ready」狀態** — 不部署 Ceph、不碰資料盤。交付後會有一支 **27 條檢查**的驗收腳本逐項驗證，任一條 FAIL 就退回重做。

## 完整需求文件（權威來源，先讀完再動手）

GitHub：`tom19960222/learning-k8s` 分支 `worktree-bridge-cse_01W3khzyRKGDNfM5yFHeVNGV`
路徑：`experiments/ceph-mclock-profiles/PROVISIONING-REQUIREMENTS.md`

下面是摘要與最容易踩雷的地方，細節一律以該文件為準。

## 規格摘要

**Region `japanwest`**（不可換 — L8s_v3 對此 subscription 只在這裡開放，其他 region 實掃是 NotAvailableForSubscription）
**Resource Group `ceph-mclock-profiles`**（新建）
**15 台 VM / 88 vCPU，on-demand，不可用 Spot，不可設 auto-shutdown**

| 主機名 | SKU | 數量 | OS disk |
|---|---|---|---|
| `mclock-admin` | Standard_D4s_v5 | 1 | **128 GB** |
| `mclock-mon-1`, `mclock-mon-2` | Standard_D2s_v5 | 2 | 64 GB |
| `mclock-osd-1` … `mclock-osd-8` | Standard_L8s_v3 | 8 | 64 GB |
| `mclock-client-1` … `mclock-client-4` | Standard_D4s_v5 | 4 | 64 GB |

全部資源帶 tags：`project=ceph-mclock-profiles`、`owner=ikaros`、`lifetime=ephemeral`。開啟 boot diagnostics（夜間 reboot 自救要看 console）。

**網路**：單一 VNet + 單一 subnet（建議 `10.60.0.0/16` / `10.60.1.0/24`），15 台全在同一 subnet。**每台單 NIC + Accelerated Networking 開啟**（Azure 頻寬是 per-VM，加第二張 NIC 沒用，不要加）。private IP **靜態分配**：admin=`.10`、mon=`.11`–`.12`、osd=`.21`–`.28`、client=`.31`–`.34`。**Public IP 只有 admin 一顆**（Static/Standard），其餘 14 台純內網、經 admin 跳板。NSG：internet inbound 只開 `<OPERATOR_IP>/32` → admin:22（跟使用者要這個 IP），subnet 內部全開，outbound 全開。

**OS**：**Ubuntu 22.04 LTS**（`Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest`），帳號 `ikaros` + passwordless sudo，停用密碼登入，timezone UTC。hostname 設成上表名稱，且**每台的 `/etc/hosts` 都要有全部 15 台的「主機名 ↔ private IP」對照**（cephadm 靠 hostname 運作，必須互解）。

SSH authorized key（15 台都裝）：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJGTPObK0yNl7+z15+cLNJPoaOS6AFLa7xQA9XNDUdeP learning-k8s-2026-05-22
```

**套件**：

- 全部 15 台：`chrony curl jq python3 lvm2 sysstat iperf3 nvme-cli netcat-openbsd fping`（並確認 `iptables` 可用）
- osd-1..8 另加：`fio`
- Ceph 官方 apt repo **pin 19.2.2 / jammy**：`deb https://download.ceph.com/debian-19.2.2/ jammy main` + `https://download.ceph.com/keys/release.asc`。admin 裝 `cephadm ceph-common`；mon/osd/admin 裝 `podman`；client 裝 `ceph-common` + `fio`

## 五個最容易做錯的地方

1. **kernel 必須是 6.8（HWE），15 台一致**。jammy 的**預設 GA kernel 是 5.15**，直接部署 22.04 拿到的就是 5.15 → 驗收會 FAIL。必須 `apt install linux-generic-hwe-22.04` → **reboot** → 確認 `uname -r` 是 `6.8.*`。**不要**裝 `linux-azure`（生產不是那個）。理由：實驗用 krbd 打 client IO，krbd 行為隨 kernel 版本改變，lab 與生產（22.04 + 6.8）不一致的話結論無法外推。
2. **不可用 Ubuntu 24.04**。除了 kernel 對映的理由，`download.ceph.com` 對 Squid **完全沒有發布 noble 套件**（`debian-19.2.2/dists/noble/` 與 `debian-squid/dists/noble/` 皆 HTTP 404），且 Ceph 官方 Squid OS 支援矩陣把 **22.04 列為 tier A**、24.04 根本不在表上。
3. **必須用按版號的 repo，不可用滾動的 `debian-squid/`** — 後者已滾到 19.2.5，pool 內沒有任何 19.2.2 的 deb，指定版號安裝會失敗。另有兩個 apt 細節：**`universe` 必須啟用**（相依的 `librdkafka1`、`libthrift-0.16.0` 在 universe），以及**加 apt pin 指向 `download.ceph.com`**（`jammy-updates` 自帶 `ceph-common 17.2.9` Quincy 會打架）。裝完務必 `ceph --version` 確認是 19.2.2 而非 17.2.x。
4. **OSD 的 1.92TB local NVMe 必須保持 raw** — 不分割、不建檔案系統、不掛載、不進 fstab、不被 cloud-init 的 `disk_setup`/`mounts` 碰到。Ceph OSD 要直接吃 raw block device，動了它整個實驗得重來。（L8s_v3 另有一顆 ~80GB SCSI resource disk 掛在 `/mnt`，那顆隨意。）
5. **unattended-upgrades 必須完全停用** — `apt-daily.timer`、`apt-daily-upgrade.timer` 都要 disabled **且** masked，套件移除或停用。實驗要連續跑 72–96 小時，任何自動更新或自動重啟都會污染資料。

另外：**LSv3 quota 只剩 1 vCPU 餘裕**（上限 65、要用 64）→ **8 台 L8s_v3 必須全數建成，缺一即視為 provision 失敗**。建議原子化建立，失敗就整批清掉重試，不可交付殘缺拓撲。

**不要做這些**：不 bootstrap Ceph、不建 CRUSH / OSD、不裝 prometheus/grafana、不建 load balancer / Azure Bastion / recovery vault、不調 sysctl / IO scheduler / CPU governor（harness 自己管，你調了會引入未記錄的變因）。

## 交付物

### 1. `inventory.json`

```json
{
  "admin_public_ip": "x.x.x.x",
  "nodes": [
    {"name": "mclock-admin",   "role": "admin",  "private_ip": "10.60.1.10"},
    {"name": "mclock-mon-1",   "role": "mon",    "private_ip": "10.60.1.11"},
    {"name": "mclock-osd-1",   "role": "osd",    "private_ip": "10.60.1.21",
     "rack": "rack1", "nvme_device": "/dev/disk/by-id/nvme-..."},
    {"name": "mclock-client-1","role": "client", "private_ip": "10.60.1.31"}
  ]
}
```

15 台全列。**OSD 條目必須有 `rack` 與 `nvme_device`**：rack 固定為 osd-1/2=`rack1`、osd-3/4=`rack2`、osd-5/6=`rack3`、osd-7/8=`rack4`（harness 據此建 CRUSH failure domain）；`nvme_device` 給 canonical 穩定路徑（建議 `/dev/disk/by-id/nvme-...`，不要用會浮動的 `/dev/nvme0n1`）。

### 2. `attestation.json`

ssh 進去驗不到的 Azure 控制面事實由你出具證明：

```json
{
  "accelerated_networking_all": true,
  "vm_priority_all": "Regular",
  "auto_shutdown_none": true,
  "tags_applied": true,
  "public_ip_only_admin": true,
  "hourly_rate_usd": {"L8s_v3": 0.0, "D4s_v5": 0.0, "D2s_v5": 0.0},
  "generated_at": "2026-07-26T12:00:00Z",
  "subscription_id": "..."
}
```

**驗收會驗值不只驗存在**：boolean 必須是期望值、`vm_priority_all` 必須是 `"Regular"`、費率必須是**正數**（填 0 會 FAIL）、`generated_at` 距驗收時間 <24 小時、`subscription_id` 要與 operator 端 `az account show` 一致。費率填 japanwest 實際 on-demand 單價（參考：L8s_v3 ≈ $0.818/hr、D4s_v5 ≈ $0.248/hr、D2s_v5 ≈ $0.124/hr，以實際 subscription 為準）。

### 3. IaC 程式碼與 state 的存放位置

實驗收官後要用同一套刪掉整個 RG，請告知路徑與執行方式。

## 驗收方式（請自己先跑過等價檢查）

交付後 operator 會執行 `azure/verify-provision.sh`，**27 條**檢查全過才開始實驗，包括：15 台 ssh 可達（14 台經 admin ProxyJump）與 passwordless sudo、hostname 正確、15 台互解 `/etc/hosts`、**OS = 22.04**、**`uname -r` = `6.8.*`**、OSD 的 NVMe 是 raw 且尺寸落在 1.7–2.2 TB 且與 inventory 相符、apt timers masked、chrony offset < 100ms、swap 為空、`ceph --version` = 19.2.2（不是 distro 的 17.2）、podman/fio/`modprobe rbd`/sysstat/iperf3/nc/fping/iptables 齊備、內網 ping < 2ms、**14 台非 admin 全數查 IMDS 確認無 public IP**（查不到也算 FAIL）、attestation 全欄位驗值。

## 前提與待確認

- 使用者必須先親手刪除 japanwest 舊 RG `CYSHIH-KUBEVIRT-CEPH-LAB`（釋出 60 vCPU quota）
- 開始前確認 quota 三層：Total Regional ≥88、LSv3 family ≥64、DSv5 family ≥24（`az vm list-usage -l japanwest`）
- 跟使用者要 `<OPERATOR_IP>`（NSG 放行來源）
- IaC 工具（Terraform / Bicep / az CLI script）你熟哪個用哪個
